defmodule FermixCore.Jobs.HealAnswer do
  @moduledoc """
  The owner's answer to a change a heal proposed for one of their jobs (M106
  §5.7, decision D5): apply it, or leave it. No model is between the answer
  and the change, and nothing here reads a turn: what the answer is checked
  against is given as data, the checks `Jobs.HealDecision.resolve/3` takes,
  and where it came from as the card rail's surface label (`decided_from`).
  Its caller is the answer rail: a heal's card answered from its chat
  (`Jobs.HealCard`, stage S4b).

    * `apply_change/4` makes exactly the change the heal recorded. The change
      is checked again as an owner's edit is (`HealDecision.check_change/3`:
      a skill gone or a model unlisted since is refused), held field by field
      to the recorded values, then written through the path an owner's edit
      takes (`Jobs.Registry.heal_write/5`) with the heal's move to watching,
      in one transaction, only while the job is the version the change was
      drawn for. A job that moved on gets nothing and its heal closes
      superseded. A job a watcher wakes or a mandate names gets nothing.
    * `leave/3` closes the heal skipped, which keeps the same failure quiet
      for seven days; the job is untouched.

  Each returns `{:ok, :applied | :left, sentence}` or
  `{:error, reason, sentence}`: Fermix's own account of what was done, or
  that nothing was and why, which the rail shows the owner. A recorded answer
  is the heal's `answered` phase, with the kind of surface it came from as its
  `platform` (the label's first part), and a heal it closed its `closed`
  phase (`Jobs.Telemetry`). Beside each, a card the Fermix app shows is told
  how it ended (`Jobs.HealCard.announce_ended/3`): approved, denied, or
  expired for an apply that found the job moved on.
  """

  alias FermixCore.Jobs.HealCard
  alias FermixCore.Jobs.HealDecision
  alias FermixCore.Jobs.HealMessage
  alias FermixCore.Jobs.Registry
  alias FermixCore.Jobs.Scheduler
  alias FermixCore.Jobs.Telemetry, as: JobTelemetry
  alias FermixCore.Memory.Repo

  @reason_max 300
  # Each recorded field of a change, as `HealDecision.check_change/3` names
  # it in the registry's attributes.
  @attr_keys %{
    "task" => :task_prompt,
    "schedule" => :schedule,
    "skill_name" => :skill_name,
    "timeout_seconds" => :timeout_seconds,
    "provider" => :provider,
    "model" => :model,
    "clear_route_pin" => :clear_route_pin
  }

  @type reason ::
          :not_found
          | :no_proposal
          | :already_answered
          | :superseded
          | :closed
          | :not_delivered
          | :consent_scope
          | :check_refused
          | :unfaithful
          | :store_error

  @type result :: {:ok, :applied | :left, String.t()} | {:error, reason(), String.t()}

  @doc """
  Applies the change heal `heal_id` proposed, answered from `decided_from`
  (the rail's label for the chat it came from, `<platform>:<chat>:<user>`)
  at `checks.now`. `opts`: `:scheduler`, the Scheduler the edit is announced
  to, and `:app_card_listener` (`Jobs.HealCard`'s seam).
  """
  @spec apply_change(String.t(), String.t(), HealDecision.checks(), keyword()) :: result()
  def apply_change(heal_id, decided_from, checks, opts \\ [])
      when is_binary(heal_id) and is_binary(decided_from) and decided_from != "" and
             is_map(checks) and is_list(opts) do
    with {:ok, heal, job} <- waiting(heal_id, checks),
         {:ok, change} <- recorded_change(job, heal),
         :ok <- scope(job, checks),
         {:ok, attrs} <- recheck(change, job, checks),
         :ok <- faithful(attrs, change, job) do
      write(job, heal, attrs, answer(decided_from, checks), checks, opts)
    end
  end

  @doc """
  Leaves the change heal `heal_id` proposed unmade, answered from
  `decided_from` at `checks.now`: the heal closes skipped. `opts`:
  `:app_card_listener`.
  """
  @spec leave(String.t(), String.t(), HealDecision.checks(), keyword()) :: result()
  def leave(heal_id, decided_from, checks, opts \\ [])
      when is_binary(heal_id) and is_binary(decided_from) and decided_from != "" and
             is_map(checks) and is_list(opts) do
    with {:ok, heal, job} <- waiting(heal_id, checks) do
      case Repo.job_heals_call({:leave, heal.id, answer(decided_from, checks)}, repo(checks)) do
        {:ok, _closed} ->
          trace_answer(job, heal, "leave", false, decided_from)
          trace_closed(job, heal, "skipped")
          HealCard.announce_ended([heal.id], :denied, card_opts(checks, opts))

          {:ok, :left,
           "Job #{job_words(job.name)} is left as it is: the change Fermix proposed was not " <>
             "made. Fermix will not report this same failure of the job again for seven days."}

        {:error, :not_waiting} ->
          now_closed(heal.id, checks)

        {:error, reason} ->
          store_error(reason)
      end
    end
  end

  # --- which proposal, and whether it still waits ------------------------------

  defp waiting(heal_id, checks) do
    with {:ok, heal} <- read_heal(heal_id, checks),
         {:ok, job} <- proposal_job(heal, checks),
         :ok <- answerable(job, heal) do
      {:ok, heal, job}
    end
  end

  defp read_heal(heal_id, checks) do
    case Repo.job_heals_call({:get, heal_id}, repo(checks)) do
      {:ok, heal} ->
        {:ok, heal}

      {:error, :not_found} ->
        {:error, :not_found, "Fermix has no such proposal; nothing was changed."}

      {:error, reason} ->
        store_error(reason)
    end
  end

  # A proposal is a job's heal that decided `propose`: a provider's or a
  # plugin's heal, or one that decided anything else, has none.
  defp proposal_job(%{decision: "propose", job_id: job_id}, checks) when is_binary(job_id) do
    case Repo.get_scheduled_job(job_id, repo(checks)) do
      {:ok, job} -> {:ok, job}
      {:error, reason} -> store_error(reason)
    end
  end

  defp proposal_job(_heal, _checks),
    do: {:error, :no_proposal, "Fermix proposed no change there; nothing was changed."}

  # What became of a proposal that cannot take an answer now, in its words.
  defp answerable(_job, %{state: "waiting", conclusion: "first", answer: nil}), do: :ok

  defp answerable(job, %{answer: "apply", applied_at: %DateTime{}}) do
    {:error, :already_answered,
     "Fermix already made this change to job #{job_words(job.name)}; nothing more was changed."}
  end

  defp answerable(job, %{answer: "leave"}) do
    {:error, :already_answered,
     "This change to job #{job_words(job.name)} was already left unmade; nothing was changed."}
  end

  defp answerable(job, %{outcome: "superseded"}), do: superseded(job)

  defp answerable(job, %{outcome: "expired"}) do
    {:error, :closed,
     "The change Fermix proposed for job #{job_words(job.name)} expired after seven days " <>
       "without an answer; nothing was changed."}
  end

  defp answerable(job, %{outcome: "healed"}) do
    {:error, :closed,
     "Job #{job_words(job.name)} ran cleanly after Fermix proposed this, so the proposal " <>
       "closed; nothing was changed."}
  end

  defp answerable(job, %{state: state}) when state in ["open", "diagnosing"] do
    {:error, :not_delivered,
     "The change Fermix proposed for job #{job_words(job.name)} has not been sent yet; " <>
       "nothing was changed."}
  end

  defp answerable(job, _heal) do
    {:error, :closed,
     "The change Fermix proposed for job #{job_words(job.name)} is no longer waiting for an " <>
       "answer; nothing was changed."}
  end

  defp superseded(job) do
    {:error, :superseded,
     "Nothing was applied: job #{job_words(job.name)} is no longer the version Fermix drew " <>
       "this change for, so the proposal is closed."}
  end

  # The heal moved between its read and the answer's write (a clean run closed
  # it, an edit superseded it): said as it now stands.
  defp now_closed(heal_id, checks) do
    with {:ok, heal} <- read_heal(heal_id, checks),
         {:ok, job} <- proposal_job(heal, checks),
         :ok <- answerable(job, heal) do
      answerable(job, %{heal | state: "closed"})
    end
  end

  # --- the apply ------------------------------------------------------------------

  defp recorded_change(_job, %{change: change}) when is_map(change) and map_size(change) > 0,
    do: {:ok, change}

  defp recorded_change(job, _heal) do
    {:error, :store_error,
     "Nothing was applied: Fermix holds no readable change for job #{job_words(job.name)}."}
  end

  defp scope(job, checks) do
    case HealDecision.proposal_scope(job, checks.repo) do
      :ok -> :ok
      {:error, :watched} -> out_of_scope("a watcher wakes", job)
      {:error, :mandated} -> out_of_scope("a mandate names", job)
      {:error, reason} -> store_error(reason)
    end
  end

  defp out_of_scope(words, job) do
    {:error, :consent_scope,
     "Nothing was applied: #{words} job #{job_words(job.name)}, and such a job changes only " <>
       "by a direct edit."}
  end

  # The checks the proposal was drawn through, run again now.
  defp recheck(change, job, checks) do
    args = Map.new(change, fn {field, %{"to" => to}} -> {field, to} end)

    case HealDecision.check_change(args, job, checks) do
      {:ok, attrs} ->
        {:ok, attrs}

      {:error, reason} ->
        {:error, :check_refused,
         "Nothing was applied to job #{job_words(job.name)}: the change no longer passes the " <>
           "checks an edit does: #{reason_words(reason)}. The proposal still waits."}
    end
  end

  # What is written must be what the owner was shown: every recorded field's
  # value exactly, and nothing more.
  defp faithful(attrs, change, job) do
    covered = Enum.map(change, fn {field, _value} -> Map.fetch!(@attr_keys, field) end)

    differing =
      for {field, %{"to" => to}} <- change,
          Map.get(attrs, Map.fetch!(@attr_keys, field)) != to,
          do: field

    extra = for {key, _value} <- attrs, key not in covered, do: key

    case differing ++ Enum.map(extra, &Atom.to_string/1) do
      [] ->
        :ok

      fields ->
        {:error, :unfaithful,
         "Nothing was applied: the recorded change to job #{job_words(job.name)} would not be " <>
           "written as recorded (#{Enum.join(fields, ", ")}), so it was not made."}
    end
  end

  defp write(job, heal, attrs, answer, checks, opts) do
    registry_opts = [repo: checks.repo, scheduler: Keyword.get(opts, :scheduler, Scheduler)]

    case Registry.heal_write(heal.id, job.id, {:update, attrs}, {:answer, answer}, registry_opts) do
      {:ok, {:written, written, _moved}} ->
        trace_answer(job, heal, "apply", true, answer.decided_from)
        HealCard.announce_ended([heal.id], :approved, card_opts(checks, opts))
        {:ok, :applied, applied(written, heal.change)}

      {:ok, {:moved_on, _closed}} ->
        trace_answer(job, heal, "apply", false, answer.decided_from)
        trace_closed(job, heal, "superseded")
        HealCard.announce_ended([heal.id], :expired, card_opts(checks, opts))
        superseded(job)

      {:error, :not_waiting} ->
        now_closed(heal.id, checks)

      {:error, reason} ->
        {:error, :check_refused,
         "Nothing was applied to job #{job_words(job.name)}: #{reason_words(reason)}. The " <>
           "proposal still waits."}
    end
  end

  defp applied(job, change) do
    "Fermix made the change it proposed to job #{job_words(job.name)}: " <>
      Enum.join(HealMessage.change_lines(change, :applied), "; ") <>
      ". Fermix watches its next run: a clean run closes this, and a failure is reported once."
  end

  # --- shared ------------------------------------------------------------------------

  defp answer(decided_from, checks), do: %{at: checks.now, decided_from: decided_from}

  defp card_opts(checks, opts),
    do: [repo: checks.repo] ++ Keyword.take(opts, [:app_card_listener])

  # Where the answer came from, as a trace may say it: the surface's kind
  # (`telegram`, `companion`), never a chat or a user.
  defp trace_answer(job, heal, given, applied?, decided_from) do
    JobTelemetry.heal("answered", %{
      heal_id: heal.id,
      job_id: job.id,
      decision: "propose",
      answer: given,
      applied: applied?,
      platform: decided_from |> String.split(":", parts: 2) |> hd()
    })
  end

  defp trace_closed(job, heal, outcome),
    do: JobTelemetry.heal("closed", %{heal_id: heal.id, job_id: job.id, outcome: outcome})

  defp store_error(reason) do
    {:error, :store_error,
     "Nothing was changed: Fermix could not read or write the job's record " <>
       "(#{reason_words(reason)})."}
  end

  defp repo(checks), do: [server: checks.repo]

  defp job_words(name), do: "\"" <> HealMessage.shown_name(name) <> "\""

  defp reason_words(reason) when is_binary(reason), do: String.slice(reason, 0, @reason_max)
  defp reason_words(reason), do: reason |> inspect() |> String.slice(0, @reason_max)
end
