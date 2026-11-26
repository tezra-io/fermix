defmodule FermixCore.Jobs.HealDecision do
  @moduledoc """
  What code makes of a heal run's decision (M106 §5.5, §5.6, decision D4):
  the checks that say whether it is carried out as asked, kept as a
  proposal, or not carried out at all. `resolve/3` only reads; the heal run
  carries the plan out (`Jobs.HealRun`), every job write fenced on its lease.

    * `rerun`: only for a job that may run now (enabled, scheduled or running,
      not past its expiry, and not one a cue wakes, which never runs by hand).
    * `raise_limit`: only upward, only for a job whose limit is below the
      engine's default run limit (`Jobs.Runner.default_timeout_ms/0`; a job
      with no limit of its own runs at it), and at most to it. A job at or
      above it, or an ask past it, gets a proposal of the same limit instead;
      a limit not above the job's own is refused.
    * `pause`: only for a job that is not paused already.
    * A raised limit, a pause and a proposal each carry the version of the job
      they were resolved against (`job_version/1`). A move is written only
      while the job is still that version (`Memory.Repo.heal_job_write/5`), so
      a check made against the job read before the diagnosis can never be
      carried out on a job the owner changed while the diagnosis ran.
    * `propose`: checked as an owner's edit is (`Tools.UpdateJob.change_attrs/2`,
      `Jobs.Registry.check_update/3` and the skill's tool check), then stored
      as the exact change (each field with its `from` and `to`) and the job's
      version it was drawn for (`job_version/1`). Applied only by the owner's
      answer on the proposal's card (`Jobs.HealAnswer`), never here. A
      proposal is offered only on a card the owner can answer and read
      whole (`fit_card/3`, stage S4b): one whose inbox can hold no card's
      answer, or whose card would pass the card's bound, is kept as `tell`,
      never cut.
    * A job a watcher wakes or a mandate names changes only on the owner's own
      consent turn (M60 S6, §10.4), so its heal may rerun, pause or tell: a
      raised limit or a proposal for it is kept as `tell`.
    * `tell`, and no decision (`none`), change nothing.

  A decision the checks refuse is never carried out and never dropped: the
  plan keeps what was asked (`requested`) and why it was refused
  (`refusal`), which the heal run traces and logs, and goes on as `tell`.
  """

  alias FermixCore.Cues.Card
  alias FermixCore.Cues.Mandates
  alias FermixCore.Cues.Watchers
  alias FermixCore.Jobs.Registry
  alias FermixCore.Jobs.Runner
  alias FermixCore.Tools.JobRegistrySupport, as: Support
  alias FermixCore.Tools.UpdateJob

  @refusal_detail_max 300

  # The job's definition, the version a heal's move or proposal is drawn for:
  # every field an owner's edit, pause or resume can write
  # (`Memory.Repo.owner_job_fields/0`) but the three a run's claim and settle
  # also write. A test holds the two lists to the store's.
  @version_fields [
    :task_prompt,
    :description,
    :skill_name,
    :provider,
    :model,
    :delivery_mode,
    :delivery_target,
    :schedule_kind,
    :schedule_expr,
    :timeout_seconds,
    :allowed_tools,
    :enabled?
  ]
  @run_written_fields [:next_run_at, :state, :updated_at]

  @type plan :: %{
          decision: String.t(),
          requested: String.t() | nil,
          refusal: String.t() | nil,
          refusal_detail: String.t() | nil,
          note: String.t() | nil,
          change: map() | nil,
          change_job_version: DateTime.t() | nil,
          change_job_digest: String.t() | nil
        }

  @typedoc """
  What the checks read: the store, the skill and capability registries, and
  the time (a job past its expiry never runs again).
  """
  @type checks :: %{
          repo: GenServer.server(),
          skill_registry: GenServer.server(),
          capability_registry: GenServer.server(),
          now: DateTime.t()
        }

  @doc "The plan for `decision` (a `Jobs.HealDiagnosis` decision, or nil) on `job`."
  @spec resolve(map() | nil, map(), checks()) :: plan()
  def resolve(nil, job, checks) when is_map(job) and is_map(checks) do
    %{
      decision: "none",
      requested: nil,
      refusal: nil,
      refusal_detail: nil,
      note: nil,
      change: nil,
      change_job_version: nil,
      change_job_digest: nil
    }
  end

  def resolve(%{decision: choice, note: note} = decision, job, checks)
      when is_atom(choice) and is_binary(note) and is_map(job) and is_map(checks) do
    asked = Atom.to_string(choice)

    plan = %{
      decision: asked,
      requested: asked,
      refusal: nil,
      refusal_detail: nil,
      note: note,
      change: nil,
      change_job_version: nil,
      change_job_digest: nil
    }

    decide(choice, decision, job, checks, plan)
  end

  @doc """
  The version of `job` a heal's move or proposal is drawn for (M106 §5.6,
  §5.7): a digest of its definition (`version_fields/0`), never what a run's
  claim and settle write. Two reads of a job no owner write touched give the
  same digest; an edit, a pause and a resume each move it. Pure: the store
  fences every job write that belongs to a heal on it
  (`Memory.Repo.heal_job_write/5`), and an owner write that moves it
  supersedes a waiting proposal.
  """
  @spec job_version(map()) :: String.t()
  def job_version(job) when is_map(job) do
    values = Enum.map(@version_fields, &Map.get(job, &1))

    :sha256
    |> :crypto.hash(:erlang.term_to_binary(values, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  @doc "The fields of a job's definition `job_version/1` reads."
  @spec version_fields() :: [atom()]
  def version_fields, do: @version_fields

  @doc """
  The fields an owner's write may set that a run's claim and settle write
  too, so no version reads them.
  """
  @spec run_written_fields() :: [atom()]
  def run_written_fields, do: @run_written_fields

  @doc """
  Whether `job` may get a proposal, or have one applied: never one a watcher
  wakes or a mandate names, which changes only by the owner's own edit on
  their consent turn (M60 S6, §10.4). A watcher that cannot be read is no
  proof there is none.
  """
  @spec proposal_scope(map(), GenServer.server()) ::
          :ok | {:error, :watched | :mandated | {:watcher_unreadable, term()}}
  def proposal_scope(job, repo) when is_map(job) do
    case Watchers.watcher_for_job(job.id, repo: repo) do
      {:ok, nil} -> mandate_free(job)
      {:ok, _watcher} -> {:error, :watched}
      {:error, reason} -> {:error, {:watcher_unreadable, reason}}
    end
  end

  @doc """
  A proposal offered only on a card (M106 §5.7, D5): `plan` as it is when it
  proposes nothing, or when the owner's inbox can hold a card's answer
  (`card_chat?`, `Delivery.OwnerInbox.answer_origin/1`) and the whole card,
  `card_chars` characters as one plain message, fits `Cues.Card.max_chars/0`.
  Otherwise the proposal is refused and goes on as `tell`, its own reason
  recorded: `no_card_chat`, or `card_too_large` with the card's length. A
  card is never cut, as a watcher's is not.
  """
  @spec fit_card(plan(), boolean(), non_neg_integer()) :: plan()
  def fit_card(%{decision: "propose"} = plan, false, _card_chars),
    do:
      refuse(plan, {:no_card_chat, "the owner's inbox has no chat a card's answer can come from"})

  def fit_card(%{decision: "propose"} = plan, true, card_chars)
      when is_integer(card_chars) and card_chars > 0 do
    if card_chars <= Card.max_chars(),
      do: plan,
      else:
        refuse(
          plan,
          {:card_too_large, "#{card_chars} characters; a card holds #{Card.max_chars()}"}
        )
  end

  def fit_card(%{decision: decision} = plan, card_chat?, _card_chars)
      when decision != "propose" and is_boolean(card_chat?),
      do: plan

  @doc """
  `plan` refused for `reason`: nothing is carried out and the heal goes on as
  `tell`, keeping what was asked and why it was refused.
  """
  @spec refuse(plan(), term()) :: plan()
  def refuse(plan, reason) when is_map(plan) do
    %{
      plan
      | decision: "tell",
        change: nil,
        change_job_version: nil,
        change_job_digest: nil,
        refusal: tag(reason),
        refusal_detail: detail(reason)
    }
  end

  defp decide(:tell, _decision, _job, _checks, plan), do: plan

  defp decide(:rerun, _decision, job, checks, plan) do
    if runnable_now?(job, checks.now), do: plan, else: refuse(plan, :not_runnable)
  end

  defp decide(:pause, _decision, job, _checks, plan) do
    if job.enabled? and job.state in ["scheduled", "running"],
      do: %{plan | change_job_digest: job_version(job)},
      else: refuse(plan, :not_running)
  end

  defp decide(:raise_limit, %{timeout_seconds: asked}, job, checks, plan) do
    case consent_free(job, checks) do
      :ok -> raise_limit(asked, job, checks, plan)
      {:error, reason} -> refuse(plan, reason)
    end
  end

  defp decide(:propose, %{change: change}, job, checks, plan) do
    case consent_free(job, checks) do
      :ok -> propose(change, job, checks, plan)
      {:error, reason} -> refuse(plan, reason)
    end
  end

  # The same gates `Scheduler.run_now/3` and `run_job_now` apply, read ahead
  # of the send so the message never promises a run that cannot start.
  defp runnable_now?(job, now) do
    job.enabled? and job.state in ["scheduled", "running"] and not Registry.cue_job?(job) and
      not expired?(job, now)
  end

  defp expired?(%{expires_at: %DateTime{} = expires_at}, now),
    do: DateTime.compare(now, expires_at) != :lt

  defp expired?(_job, _now), do: false

  defp raise_limit(asked, job, checks, plan) do
    ceiling = div(Runner.default_timeout_ms(), 1_000)
    current = job.timeout_seconds || ceiling

    cond do
      asked <= current ->
        refuse(plan, :not_upward)

      current >= ceiling or asked > ceiling ->
        %{"timeout_seconds" => asked} |> propose(job, checks, plan) |> past_ceiling()

      true ->
        change = %{"timeout_seconds" => %{"from" => job.timeout_seconds, "to" => asked}}

        %{
          plan
          | change: change,
            change_job_version: job.updated_at,
            change_job_digest: job_version(job)
        }
    end
  end

  # A raise Fermix may not make alone becomes a proposal, said so in the trace.
  defp past_ceiling(%{decision: "propose"} = plan), do: %{plan | refusal: "past_ceiling"}
  defp past_ceiling(refused), do: refused

  @doc """
  `change` (`update_job`'s arguments) checked as an owner's edit of `job` is
  (`Tools.UpdateJob.change_attrs/2`, `Jobs.Registry.check_update/3`, the
  skill's tool check), from no chat: the registry's attributes it would
  write, or the check's refusal. A proposal is drawn through it, and an
  answer applying one checks it again (`Jobs.HealAnswer`).
  """
  @spec check_change(map(), map(), checks()) :: {:ok, map()} | {:error, term()}
  def check_change(change, job, checks) when is_map(change) and is_map(job) and is_map(checks) do
    context = validation_context(checks)

    with {:ok, attrs, skill} <- UpdateJob.change_attrs(change, context),
         {:ok, _patch} <- Registry.check_update(job.id, attrs, repo: checks.repo, now: checks.now),
         :ok <- Support.check_skill_tools(job, skill, context) do
      {:ok, attrs}
    end
  end

  defp propose(change, job, checks, plan) do
    with {:ok, attrs} <- check_change(change, job, checks),
         {:ok, diff} <- diff(change, attrs, job) do
      %{
        plan
        | decision: "propose",
          change: diff,
          change_job_version: job.updated_at,
          change_job_digest: job_version(job)
      }
    else
      {:error, reason} -> refuse(plan, {:invalid_change, reason})
    end
  end

  # An owner's edit made from no chat: a delivery to "the origin" has none to
  # resolve, so it is refused as one from a context without a conversation.
  defp validation_context(checks) do
    %{
      source_trust: :operator,
      skill_registry: checks.skill_registry,
      capability_registry: checks.capability_registry,
      memory_repo: checks.repo
    }
  end

  # Each field the change names, as the job has it and as it would be; a
  # change that would leave every field as it is changes nothing.
  defp diff(change, attrs, job) do
    diff =
      Map.new(change, fn {field, value} ->
        {field, %{"from" => current(field, job), "to" => wanted(field, value, attrs)}}
      end)

    if Enum.all?(diff, &unchanged?/1), do: {:error, :no_change}, else: {:ok, diff}
  end

  defp current("task", job), do: job.task_prompt
  defp current("schedule", job), do: job.schedule_expr
  defp current("skill_name", job), do: job.skill_name
  defp current("timeout_seconds", job), do: job.timeout_seconds
  defp current("provider", job), do: job.provider
  defp current("model", job), do: job.model
  defp current("delivery_mode", job), do: job.delivery_mode
  defp current("delivery_target", job), do: job.delivery_target

  defp current("clear_route_pin", %{provider: provider} = job) when is_binary(provider),
    do: %{"provider" => provider, "model" => job.model}

  defp current("clear_route_pin", _job), do: nil

  # A delivery is stored as `update_job` resolves it; every other value
  # exactly as `update_job` would write it, as given.
  defp wanted("delivery_mode", _value, attrs), do: Map.get(attrs, :delivery_mode)
  defp wanted("delivery_target", _value, attrs), do: Map.get(attrs, :delivery_target)
  defp wanted(_field, value, _attrs), do: value

  defp unchanged?({"clear_route_pin", %{"from" => from}}), do: is_nil(from)
  defp unchanged?({_field, %{"from" => from, "to" => to}}), do: from == to

  # A job a watcher wakes or a mandate names changes only on the owner's
  # consent turn, so its heal neither raises its limit nor proposes.
  defp consent_free(job, checks) do
    case proposal_scope(job, checks.repo) do
      :ok -> :ok
      {:error, reason} when reason in [:watched, :mandated] -> {:error, :consent_required}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mandate_free(job) do
    case Mandates.names_for_job(job.id) do
      [] -> :ok
      [_name | _rest] -> {:error, :mandated}
    end
  end

  defp tag({tag, _detail}) when is_atom(tag), do: Atom.to_string(tag)
  defp tag(tag) when is_atom(tag), do: Atom.to_string(tag)

  defp detail({_tag, detail}) when is_binary(detail),
    do: String.slice(detail, 0, @refusal_detail_max)

  defp detail({_tag, detail}),
    do: detail |> inspect() |> String.slice(0, @refusal_detail_max)

  defp detail(_tag), do: nil
end
