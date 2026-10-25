defmodule FermixCore.Cues.Notices do
  @moduledoc """
  Notices from Fermix about watchers, sources and mandates (M60 §7.6, §9.5).

  A notice is Fermix's own sentence, never cue text. Each is sent once per
  episode, decided by a claim the single writer makes before the send, so two
  callers never both send one:

  | kind | once per |
  |---|---|
  | `:filter_held` | hold, until `:filter_recovered` (`cue_watchers.held_notified_at`) |
  | `:filter_recovered` | hold that was notified |
  | `:filter_failed` | watcher per UTC day |
  | `:cap_reached`, `:filter_budget_reached`, `:task_provider_down` | 24 hours, the rolling window: by then every run or call counted when it was sent has left the window |
  | `:gap` | open gap, which the notice marks reported |
  | source `:auth_failed`, `:refused`, `:down`, `:unreachable`, `:too_large` | episode, ended by the source's next good moment (`last_good_at` after the notice) |
  | source `:budget_reached` | source per UTC day |
  | mandate `:unpinned` | call: its caller sends it from the change that disabled the mandate, once per approval |

  The watcher and source stamps live in `cue_watchers.notices` and
  `cue_sources.notices`. A send that fails releases its claim, so a later
  trigger tries again, and returns the error.

  A watcher notice goes to its task's delivery target through
  `Jobs.CueRun.deliver/3`, the one send path of everything a cue causes (only
  to a channel a cue run may reach), prefixed "Watcher <name>"; a source or
  mandate notice goes to the owner inbox (`Delivery.OwnerInbox`), as
  skill-curation proposals do. Every send asks the channel for no link
  previews.

  Opts: `:repo`, `:now`, `:adapter` and `:channels` (the channel seams of
  `Delivery.ChannelSend`), `:delivery_opts` (passed to the channel adapter
  with a watcher notice), `:jobs_config` and `:configured_owners` (the owner
  inbox seams), `:timeout_ms`.
  """

  require Logger

  alias FermixCore.Cues.Gaps
  alias FermixCore.Delivery.ChannelSend
  alias FermixCore.Delivery.OwnerInbox
  alias FermixCore.Jobs.CueRun
  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixCore.Memory.Repo.CuesWatchersSql

  @day_s 86_400
  @send_timeout_ms 30_000
  @gap_notices_per_sweep 5

  @watcher_rules %{
    filter_held: :held,
    filter_recovered: :recovered,
    filter_failed: :utc_day,
    filter_budget_reached: {:window, @day_s},
    cap_reached: {:window, @day_s},
    task_provider_down: {:window, @day_s}
  }
  @watcher_kinds Map.keys(@watcher_rules) ++ [:gap]

  @source_rules %{
    auth_failed: :since_last_good,
    refused: :since_last_good,
    down: :since_last_good,
    unreachable: :since_last_good,
    too_large: :since_last_good,
    budget_reached: :utc_day
  }
  @source_kinds Map.keys(@source_rules)
  @mandate_kinds [:unpinned]

  @preview_off [link_previews: false]

  @typedoc "What a notice call did."
  @type result :: :sent | :already_sent | {:error, term()}

  @doc """
  Sends watcher notice `kind` once per episode to the watcher's task's
  delivery target. `data` may hold `:waiting` (items waiting), `:cap`,
  `:budget`; a `:gap` notice needs `:gap_id`, `:source_ref`, `:count`,
  `:reason` and `:first_at`.
  """
  @spec watcher(String.t(), atom(), map(), keyword()) :: result()
  def watcher(watcher_id, kind, data, opts \\ [])

  def watcher(watcher_id, :gap, %{gap_id: gap_id} = data, opts)
      when is_binary(watcher_id) and is_binary(gap_id) and is_list(opts) do
    with {:ok, watcher} <- watcher_target(watcher_id, opts) do
      gap_notice(Map.merge(data, %{name: watcher.name, task_job_id: watcher.task_job_id}), opts)
    end
  end

  def watcher(watcher_id, kind, data, opts)
      when is_binary(watcher_id) and kind in @watcher_kinds and kind != :gap and is_map(data) and
             is_list(opts) do
    rule = Map.fetch!(@watcher_rules, kind)
    request = {:claim_watcher_notice, watcher_id, Atom.to_string(kind), rule, now(opts)}

    case call(request, opts) do
      {:ok, {:claimed, target}} ->
        text = watcher_text(kind, target.name, data)

        target.task_job_id
        |> send_to_task(text, opts)
        |> settle(
          {:release_watcher_notice, watcher_id, Atom.to_string(kind), rule, target.previous},
          opts
        )

      {:ok, :already_sent} ->
        :already_sent

      {:error, reason} ->
        failed("watcher #{watcher_id} #{kind}", reason)
    end
  end

  @doc """
  Sends source notice `kind` once per episode to the owner inbox. `data` may
  hold `:budget`.
  """
  @spec source(String.t(), atom(), map(), keyword()) :: result()
  def source(source_ref, kind, data, opts \\ [])
      when is_binary(source_ref) and kind in @source_kinds and is_map(data) and is_list(opts) do
    rule = Map.fetch!(@source_rules, kind)
    request = {:claim_source_notice, source_ref, Atom.to_string(kind), rule, now(opts)}

    case call(request, opts) do
      {:ok, {:claimed, %{previous: previous}}} ->
        source_text(kind, source_ref, data)
        |> send_to_owner(opts)
        |> settle({:release_source_notice, source_ref, Atom.to_string(kind), previous}, opts)

      {:ok, :already_sent} ->
        :already_sent

      {:error, reason} ->
        failed("source #{source_ref} #{kind}", reason)
    end
  end

  @doc """
  Sends mandate notice `kind` to the owner inbox. Its caller sends it from the
  change that disabled the mandate, which happens once per approval.
  """
  @spec mandate(String.t(), atom(), map(), keyword()) :: result()
  def mandate(name, kind, data, opts \\ [])
      when is_binary(name) and kind in @mandate_kinds and is_map(data) and is_list(opts) do
    case send_to_owner(mandate_text(kind, name), opts) do
      :ok -> :sent
      {:error, reason} -> failed("mandate #{name} #{kind}", reason)
    end
  end

  @doc """
  The `Cues.Sweeper` step for gap notices: open gaps of a watcher that no run
  reported within an hour, at most #{@gap_notices_per_sweep} per pass (each is
  a channel send). Returns how many it handled; that is always under the
  sweeper's chunk, so the step ends after one call.
  """
  @spec sweep_gaps(keyword(), DateTime.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def sweep_gaps(repo_opts, %DateTime{} = now, limit)
      when is_list(repo_opts) and is_integer(limit) and limit > 0 do
    opts = repo_opts ++ [repo: Keyword.get(repo_opts, :server, Repo), now: now]
    bound = min(limit, @gap_notices_per_sweep)

    case call({:due_gap_notices, now, bound}, opts) do
      {:ok, gaps} ->
        Enum.each(gaps, &gap_notice(&1, opts))
        {:ok, length(gaps)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- gaps ------------------------------------------------------------------------

  defp gap_notice(gap, opts) do
    stamp = CuesSql.stamp(now(opts))

    case call({:claim_gap_notice, gap.gap_id, now(opts)}, opts) do
      {:ok, :claimed} ->
        gap.task_job_id
        |> send_to_task(gap_text(gap), opts)
        |> settle({:release_gap_notice, gap.gap_id, stamp}, opts)

      {:ok, :already_sent} ->
        :already_sent

      {:error, reason} ->
        failed("gap #{gap.gap_id}", reason)
    end
  end

  defp watcher_target(watcher_id, opts) do
    case call({:get_watcher, {:id, watcher_id}}, opts) do
      {:ok, watcher} -> {:ok, watcher}
      {:error, reason} -> failed("watcher #{watcher_id} gap", reason)
    end
  end

  # --- sending -----------------------------------------------------------------------

  defp send_to_task(job_id, text, opts) do
    with {:ok, job} <- JobsRegistry.get_job(job_id, repo: Keyword.get(opts, :repo, Repo)) do
      delivery_opts =
        opts
        |> Keyword.take([:adapter, :channels])
        |> Keyword.merge(
          delivery_opts: Keyword.get(opts, :delivery_opts, []),
          timeout_ms: Keyword.get(opts, :timeout_ms, @send_timeout_ms)
        )

      case CueRun.deliver(job, text, delivery_opts) do
        {:ok, "sent"} -> :ok
        {:ok, other} -> {:error, {:not_delivered, other}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp send_to_owner(text, opts) do
    case OwnerInbox.resolve(Keyword.take(opts, [:jobs_config, :configured_owners])) do
      {:ok, inbox} ->
        ChannelSend.send(
          inbox.platform,
          inbox.destination,
          text,
          @preview_off,
          Keyword.take(opts, [:adapter, :channels])
        )

      :no_delivery_target ->
        {:error, :no_owner_inbox}
    end
  end

  defp settle(:ok, _release, _opts), do: :sent

  defp settle({:error, reason}, release, opts) do
    case call(release, opts) do
      {:error, release_error} ->
        Logger.error(
          "Cues.Notices: a failed notice's claim was not released: #{inspect(release_error)}"
        )

      _released ->
        :ok
    end

    failed(inspect(elem(release, 1)), reason)
  end

  defp failed(what, reason) do
    Logger.warning("Cues.Notices: the #{what} notice was not sent: #{inspect(reason)}")
    {:error, reason}
  end

  # --- Fermix's words ------------------------------------------------------------------

  defp watcher_text(:filter_held, name, data),
    do:
      "Watcher #{name}: its filter model cannot be reached; #{waiting(data)} Fermix tries " <>
        "again every 10 minutes."

  defp watcher_text(:filter_recovered, name, _data),
    do: "Watcher #{name}: its filter model answers again, and waiting items are being filtered."

  defp watcher_text(:filter_failed, name, _data),
    do:
      "Watcher #{name}: its filter could not judge an item after three tries, so the item " <>
        "was not passed on. Ask what the watcher dropped to see it."

  defp watcher_text(:filter_budget_reached, name, data),
    do:
      "Watcher #{name}: it reached its filter budget#{of(data, :budget, "calls")} in 24 " <>
        "hours; new items wait until there is room."

  defp watcher_text(:cap_reached, name, data),
    do:
      "Watcher #{name}: it reached its daily cap#{of(data, :cap, "runs")}; #{waiting(data)} " <>
        "They wait for room."

  defp watcher_text(:task_provider_down, name, _data),
    do:
      "Watcher #{name}: its task's model provider cannot be reached; passed items wait and " <>
        "are tried again."

  defp gap_text(gap), do: "Watcher #{gap.name}: " <> Gaps.sentence(gap)

  defp source_text(:auth_failed, ref, _data),
    do: "Cue source #{ref} stopped: its credential was refused. Update it in settings."

  defp source_text(:refused, ref, _data),
    do:
      "Cue source #{ref} stopped: the service sent an error each time Fermix connected. Some " <>
        "services allow one connection per account, so another program using the same keys " <>
        "causes this. Check its settings, then save it again or restart Fermix to try again."

  defp source_text(:down, ref, _data),
    do:
      "Cue source #{ref} has been down for more than 15 minutes. It cannot catch up, so " <>
        "what the service sent meanwhile is missed and not recorded."

  defp source_text(:unreachable, ref, _data),
    do:
      "Cue source #{ref} stopped after failing to reach its address again and again. Check it in settings."

  defp source_text(:too_large, ref, _data),
    do:
      "Cue source #{ref} stopped: its feed is larger than Fermix reads. It tries again " <>
        "when its settings change or Fermix restarts."

  defp source_text(:budget_reached, ref, data),
    do:
      "Cue source #{ref} reached its daily budget#{of(data, :budget, "items")}; it takes " <>
        "items again tomorrow (UTC)."

  defp mandate_text(:unpinned, name),
    do:
      "Mandate #{name} is disabled: the task changed since it was granted. Approve it again " <>
        "in settings to turn it back on."

  defp waiting(%{waiting: 1}), do: "1 item is waiting."
  defp waiting(%{waiting: n}) when is_integer(n) and n > 1, do: "#{n} items are waiting."
  defp waiting(_data), do: "its items wait."

  defp of(data, key, unit) do
    case Map.get(data, key) do
      n when is_integer(n) and n > 0 -> " of #{n} #{unit}"
      _absent -> ""
    end
  end

  # --- plumbing --------------------------------------------------------------------------

  defp call(request, opts) do
    repo_opts =
      [server: Keyword.get(opts, :repo, Repo)] ++ Keyword.take(opts, [:timeout, :on_timeout])

    Repo.cues_call(CuesWatchersSql, request, repo_opts)
  end

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
end
