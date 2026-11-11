defmodule FermixChannels.Gateway.Commands.History do
  @moduledoc """
  `/history` — owner-only management of the on-device computer-history rail
  (MILESTONE_32 §5.3). Ingress-dispatched ahead of the turn so it lands
  immediately, and handled in the daemon with direct access to the store:

    * `/history status`            — capture/summarizer/allowlist/spool overview
    * `/history pause <10m|1h|…>`  — persist a capture pause horizon (§7.3)
    * `/history purge 10m|1h|24h|all` — erase a window from the spool + memories
    * `/history off`               — disable (un-advertises next turn); data stays
    * `/history off <computer>`    — switch a computer's history off (M97 §8.5)

  Enabling is the wizard's job (the consent act, §5.5), never a chat command.
  """

  @behaviour FermixChannels.Gateway.Command

  require Logger

  alias FermixChannels.Gateway.Commands.Authorization
  alias FermixCore.ComputerHistory
  alias FermixCore.ComputerHistory.Capturer
  alias FermixCore.ComputerHistory.Config
  alias FermixCore.ComputerHistory.Controller
  alias FermixCore.ComputerHistory.Delivery
  alias FermixCore.ComputerHistory.Gate
  alias FermixCore.ComputerHistory.Purge
  alias FermixCore.ComputerHistory.Spool
  alias FermixCore.Computers
  alias FermixCore.Memory.Repo

  # The spool's own retention horizon: a coverage state older than the events it
  # describes is not current information.
  @coverage_window_ms :timer.hours(48)

  @impl true
  def name, do: "history"

  @impl true
  def aliases, do: []

  @impl true
  def description, do: "Manage computer history: status, pause, purge, off."

  # Strict operator-only: `/history` reads and mutates the owner's own private
  # activity (purge deletes it, off disables capture), so an allowlisted guest
  # must never reach it — the sandbox-mutation precedent, not the looser
  # owner_only branch.
  @impl true
  def authorize(message, metadata, context),
    do: Authorization.operator_only(message, metadata, context)

  @impl true
  def execute(message, reply_fn, context) do
    host = %{
      repo: repo(context),
      spool: Map.get(context, :computer_history_spool, Spool),
      recorder?: Map.get_lazy(context, :computer_history_recorder?, &ComputerHistory.recorder?/0),
      computers: Map.get_lazy(context, :computer_history_computers, &Computers.list/0),
      deliver: Map.get(context, :computer_history_deliver, &Delivery.deliver/1),
      switch_off: Map.get(context, :computer_history_switch_off, &Delivery.switch_off/2),
      controller: controller(context)
    }

    dispatch(args(message), reply_fn, host)
  end

  # `:computer_history_repo` / `:computer_history_spool` /
  # `:computer_history_recorder?` / `:computer_history_computers` /
  # `:computer_history_deliver` / `:computer_history_switch_off` /
  # `:computer_history_controller` in context are test-only injection seams;
  # production dispatch runs in the daemon against the home's single-writer
  # Repo, this machine's store and recorder, the home's computers, the real
  # delivery and the real Controller.
  defp repo(context), do: Map.get(context, :computer_history_repo, Repo)

  defp controller(context), do: Map.get(context, :computer_history_controller, Controller)

  defp args(message), do: String.split(message.content, ~r/\s+/, trim: true)

  defp dispatch([], reply_fn, host), do: reply(reply_fn, status_text(host))
  defp dispatch(["status" | _rest], reply_fn, host), do: reply(reply_fn, status_text(host))

  defp dispatch(["pause"], reply_fn, _host),
    do: reply(reply_fn, "Usage: /history pause 10m|1h|24h")

  defp dispatch(["pause", duration], reply_fn, host),
    do: pause(duration, reply_fn, host)

  defp dispatch(["purge", window], reply_fn, host),
    do: purge(window, reply_fn, host)

  defp dispatch(["off"], reply_fn, host),
    do: off(reply_fn, host.recorder?, host.controller)

  defp dispatch(["off" | name], reply_fn, host),
    do: reply(reply_fn, off_computer(Enum.join(name, " "), host))

  defp dispatch(_other, reply_fn, _host), do: reply(reply_fn, usage())

  # --- status -------------------------------------------------------------

  # This machine's own lines where it records, the home's, then one block per
  # computer of the home (M97 §8.5).
  defp status_text(%{repo: repo, spool: spool} = host) do
    [machine_lines(host), home_lines(repo, spool, host), computer_blocks(host)]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp machine_lines(%{recorder?: true, spool: spool}),
    do: [
      enabled_line(),
      capture_line(),
      allowlist_line(),
      coverage_line(spool),
      summarizer_line()
    ]

  defp machine_lines(%{recorder?: false, computers: []}),
    do: "Computer history: no computer of this home records it yet; a Mac records."

  defp machine_lines(%{recorder?: false}),
    do: "Computer history: kept on this home for its computers. #{home_summarizer_line()}"

  defp home_lines(repo, spool, %{recorder?: true}),
    do: [chain_line(), spool_line(spool), memory_line(repo, spool), access_line(repo)]

  defp home_lines(repo, _spool, %{recorder?: false}),
    do: [chain_line(), memory_line(repo, nil), access_line(repo)]

  defp enabled_line do
    "Computer history: #{if Config.enabled?(), do: "on", else: "off"}."
  end

  # The capturer's live runtime mode — the one place a *degraded* rail becomes
  # visible to the operator (a mismatch/refusal is otherwise only in the log).
  defp capture_line, do: "Capture: #{capture_phrase(Capturer.status())}."

  defp capture_phrase(%{mode: :capturing}), do: "running"
  defp capture_phrase(%{mode: :handshaking}), do: "starting the recorder"
  defp capture_phrase(%{mode: :restarting}), do: "restarting the recorder"

  defp capture_phrase(%{mode: :standing_down}),
    do: "standing down (another daemon on this Mac holds it)"

  defp capture_phrase(%{mode: :not_running}), do: "not running"
  defp capture_phrase(%{mode: :not_answering}), do: "not answering (it may still be running)"

  defp capture_phrase(%{mode: :degraded, reason: reason}),
    do: "degraded — #{degrade_phrase(reason)}"

  defp capture_phrase(%{mode: mode}), do: to_string(mode)

  # A pre-v6 recorder has no observe_start verb at all — it answers with a
  # positional frame rather than a version — so there is no number to name.
  defp degrade_phrase({:protocol_mismatch, %{required: required, sidecar: :pre_v6}}),
    do: "recorder speaks a pre-v6 protocol ≠ required v#{required} (a compux upgrade is needed)"

  defp degrade_phrase({:protocol_mismatch, %{required: required, sidecar: sidecar}}),
    do: "recorder protocol v#{sidecar} ≠ required v#{required} (a compux upgrade is needed)"

  defp degrade_phrase(:handshake_timeout),
    do: "the recorder never answered the start request (a compux upgrade or reinstall is needed)"

  defp degrade_phrase(:observe_start_refused), do: "the recorder refused to start observing"

  defp degrade_phrase({:sidecar_restart_exhausted, _status}),
    do: "the recorder kept exiting; retries exhausted"

  defp degrade_phrase(:sidecar_unavailable), do: "the recorder binary is unavailable"
  defp degrade_phrase({:sidecar_missing, _path}), do: "the recorder binary is not installed"
  defp degrade_phrase(other), do: inspect(other)

  # Consent is per app, and only per app (M32.1 §2.1): allowlisting a browser is
  # consent to record every site visited inside it, so there is no site count.
  defp allowlist_line, do: "Apps allowlisted: #{count(Config.apps())}."

  # Per-app coverage states the recorder reported in the retention window (§8.4a):
  # an app it can only read titles in observes no typed text at all, which changes
  # what history can answer about that app — and it is otherwise visible only as a
  # gap row nobody reads. Omitted entirely when there is nothing to report.
  defp coverage_line(spool) do
    case Spool.coverage_gaps(coverage_since(), server: spool) do
      {:ok, []} ->
        nil

      {:ok, pairs} ->
        "Coverage: #{coverage_clauses(pairs)}"

      {:error, reason} ->
        Logger.warning("computer_history coverage gaps unavailable: #{inspect(reason)}")
        nil
    end
  end

  defp coverage_since, do: System.system_time(:millisecond) - @coverage_window_ms

  # The SQL filter (`Spool.coverage_gaps/2`) is the contract for
  # which reasons arrive here, so a reason with no bucket is a code defect, not
  # input to absorb: it RAISES rather than landing in whichever clause happens to
  # be last (an unbucketed reason silently rendering as "AX refused" would tell
  # the owner the wrong thing about their own coverage).
  defp coverage_clauses(pairs) do
    buckets = Enum.group_by(pairs, &bucket!/1, fn {app, _reason} -> app end)

    [
      title_only_clause(apps(buckets, :title_only)),
      private_unknown_clause(apps(buckets, :private_unknown)),
      ax_refused_clause(apps(buckets, :ax_refused))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("; ")
    |> Kernel.<>(".")
  end

  defp bucket!({_app, "title_only"}), do: :title_only
  defp bucket!({_app, "private_unknown"}), do: :private_unknown
  defp bucket!({_app, "ax_refused" <> _names}), do: :ax_refused

  defp bucket!({app, reason}) do
    raise ArgumentError,
          "computer_history coverage gap #{inspect(reason)} for #{inspect(app)} has no status " <>
            "clause; the coverage_gaps SQL filter and these buckets are one contract"
  end

  defp apps(buckets, bucket), do: buckets |> Map.get(bucket, []) |> Enum.uniq()

  defp title_only_clause([]), do: nil

  defp title_only_clause(apps),
    do: "title-only for #{Enum.join(apps, ", ")} (no typed text is observable there)"

  # Browsers whose private-window state the recorder cannot positively classify:
  # consent is per app so page addresses still flow, but typed text needs a
  # positive not-private signal and there is none, so it is withheld (inv. 26).
  defp private_unknown_clause([]), do: nil

  defp private_unknown_clause(apps),
    do:
      "private-window state unknown for #{Enum.join(apps, ", ")} " <>
        "(page URLs are recorded there; typed text is not)"

  defp ax_refused_clause([]), do: nil

  defp ax_refused_clause(apps),
    do: "AX refused for #{Enum.join(apps, ", ")} (the app declined to report changes)"

  defp summarizer_line do
    case Config.summarizer() do
      :local ->
        "Summarizer: on-device (local)."

      :default_provider ->
        "Summarizer: #{default_provider_label()} (raw activity leaves this Mac)."

      {:provider, provider} ->
        "Summarizer: #{provider} (raw activity leaves this Mac)."
    end
  end

  # Whether recall can surface in chat at all, and on which providers (§9.4). The
  # chain rule can deny every owner turn — a configured, capturing, summarizing
  # rail that never appears in a reply — and this is the line that says so, from
  # the same resolver the doctor row and the setup card read, resolved as if
  # history surfaces, since the rest of this status body describes it.
  defp chain_line, do: Gate.chain_posture_sentence(Gate.chain_posture(surfaces?: true))

  # The route the home summarizes its computers' sittings on: what each sitting
  # sent here reaches.
  defp home_summarizer_line do
    case Config.summarizer() do
      :local -> "Summarizer: on-device (local)."
      :default_provider -> "Summarizer: #{default_provider_label()}."
      {:provider, provider} -> "Summarizer: #{provider}."
    end
  end

  # The one shared resolver (§22.1): subagent provider else primary — the same
  # answer the Gate and the summarizer use, so this privacy line never names a
  # different vendor than the one raw activity actually reaches.
  defp default_provider_label do
    case Config.default_summarizer_provider() do
      {:ok, provider} -> "subagent/default (#{provider})"
      {:error, _reason} -> "default provider (none configured)"
    end
  end

  # The unsummarized count is always shown: a summarizer that has fallen behind
  # is otherwise invisible until the spool starts expiring under it.
  defp spool_line(spool) do
    with {:ok, count} <- Spool.count_events(server: spool),
         {:ok, {unsummarized, oldest_ts}} <- Spool.unsent_stats(server: spool),
         {:ok, state} <- Spool.state(server: spool),
         {:ok, link} <- Spool.link(server: spool) do
      paused = pause_display(state.pause_until)

      "Spool: #{count} event(s), #{unsummarized} unsummarized#{lag_display(unsummarized, oldest_ts)}. " <>
        expired_clause(link.expired_unsent) <>
        "Last summarization: #{state.last_status || "none"}. Paused until: #{paused}."
    else
      {:error, reason} ->
        # Log the root cause — "unavailable" alone is undiagnosable from a trace.
        Logger.warning("computer_history spool status unavailable: #{inspect(reason)}")
        "Spool: unavailable."
    end
  end

  # M97 §8.1: raw events that expired before they were ever sent are counted
  # and shown, never hidden.
  defp expired_clause(0), do: ""
  defp expired_clause(1), do: "1 event expired before it was sent. "
  defp expired_clause(count), do: "#{count} events expired before they were sent. "

  # The two derived layers (§24.4): how much journal there is, how much current
  # work, when the roll-up last ran, and whether a sitting is still open. A
  # roll-up that stopped happening is otherwise invisible until "what am I working
  # on" goes stale.
  defp memory_line(repo, spool) do
    with {:ok, notes} <- Repo.computer_history_count_memories(server: repo, kind: :session),
         {:ok, threads} <- Repo.computer_history_count_memories(server: repo, kind: :thread),
         {:ok, state} <- Repo.computer_history_ensure_state(server: repo),
         {:ok, open_since} <- open_since(spool) do
      "Memory: #{quantity(notes, "session note")}, #{quantity(threads, "active thread")}" <>
        rollup_clause(state.last_rollup_ts) <> open_clause(open_since) <> "."
    else
      {:error, reason} ->
        Logger.warning("computer_history memory status unavailable: #{inspect(reason)}")
        "Memory: unavailable."
    end
  end

  defp open_since(nil), do: {:ok, nil}

  defp open_since(spool) do
    with {:ok, state} <- Spool.state(server: spool), do: {:ok, state.session_open_since_ts}
  end

  # -- one block per computer (M97 §8.5) --------------------------------------------

  defp computer_blocks(%{computers: []}), do: []

  defp computer_blocks(%{computers: computers, repo: repo}) do
    with {:ok, rows} <- Repo.computer_history_home(:computer_rows, [], server: repo),
         {:ok, notes} <- Repo.computer_history_home(:notes_by_computer, [], server: repo) do
      rows = Map.new(rows, &{&1.computer_id, &1})
      notes = Map.new(notes)
      Enum.map(computers, &computer_block(&1, Map.get(rows, &1.device_id), notes, repo))
    else
      {:error, reason} ->
        Logger.warning("computer_history computer status unavailable: #{inspect(reason)}")
        "Computers: unavailable."
    end
  end

  defp computer_block(computer, row, notes, repo) do
    "#{computer.name}: history #{offer_phrase(computer)}; #{seen_phrase(computer)}; " <>
      "#{report_phrase(row)}; #{sitting_phrase(row)}; " <>
      "#{quantity(Map.get(notes, computer.device_id, 0), "session note")}" <>
      pending_phrase(computer, row, repo) <> off_phrase(row) <> "."
  end

  # What the computer last reported of its recorder (M97 §8.5): its state, what
  # it has not sent, and its coverage, with how old the report is. The home
  # holds no raw record of a computer, so this is the only way it knows.
  defp report_phrase(%{report: report, report_at: at}) when is_binary(report) do
    case Jason.decode(report) do
      {:ok, %{"recorder" => state} = fields} ->
        "recorder #{recorder_word(state)}#{unsent_clause(fields)}#{remote_coverage(fields)} " <>
          "(reported #{age_phrase(System.system_time(:millisecond) - at)} ago)"

      _unreadable ->
        "recorder report unreadable"
    end
  end

  defp report_phrase(_row), do: "no recorder report yet"

  defp recorder_word("standing_down"), do: "standing down"
  defp recorder_word("not_running"), do: "not running"
  defp recorder_word("not_answering"), do: "not answering"
  defp recorder_word(state), do: state

  defp unsent_clause(%{"unsent" => 0, "expired_unsent" => expired}),
    do: ", nothing unsent" <> expired_remote(expired)

  defp unsent_clause(%{"unsent" => unsent, "oldest_unsent_ts" => oldest} = fields) do
    ", #{unsent} event(s) unsent#{lag_display(unsent, oldest)}" <>
      expired_remote(fields["expired_unsent"])
  end

  defp expired_remote(count) when is_integer(count) and count > 0,
    do: ", #{count} expired before they were sent"

  defp expired_remote(_count), do: ""

  defp remote_coverage(fields) do
    [
      {"title_only", "title-only"},
      {"private_unknown", "private-window state unknown"},
      {"ax_refused", "AX refused"}
    ]
    |> Enum.flat_map(fn {key, words} ->
      case Map.get(fields, key, 0) do
        0 -> []
        count -> ["#{words} in #{quantity(count, "app")}"]
      end
    end)
    |> case do
      [] -> ""
      clauses -> ", coverage: " <> Enum.join(clauses, ", ")
    end
  end

  defp off_phrase(%{off_requested_at: at}) when is_integer(at),
    do: "; asked to switch its history off, not yet done there"

  defp off_phrase(_row), do: ""

  defp offer_phrase(computer) do
    case Enum.find(computer.offers, &(&1.id == "history")) do
      %{state: :on} -> "on"
      %{state: state, sentence: sentence} when is_binary(sentence) -> "#{state} (#{sentence})"
      %{state: state} -> "#{state}"
      nil -> "not said"
    end
  end

  defp seen_phrase(%{connected: true}), do: "connected"
  defp seen_phrase(%{last_seen: nil}), do: "not seen yet"

  defp seen_phrase(%{last_seen: %DateTime{} = at}),
    do: "away, last seen #{age_phrase(DateTime.diff(DateTime.utc_now(), at, :millisecond))} ago"

  # A row a delivery, an off or a report made has no sitting in it yet.
  defp sitting_phrase(nil), do: "no sitting received"
  defp sitting_phrase(%{last_submission_at: nil}), do: "no sitting received"

  defp sitting_phrase(%{last_submission_at: at, last_status: status, last_reason: reason}) do
    word = if reason, do: "#{status}, #{reason}", else: status
    "last sitting #{age_phrase(System.system_time(:millisecond) - at)} ago (#{word})"
  end

  # The purges and pauses from chat it has not applied: until it does, the home
  # takes nothing from it inside them.
  defp pending_phrase(computer, row, repo) do
    mark = if row, do: row.delivered_mark, else: 0

    case Repo.computer_history_home(:intervals_after, [computer.device_id, mark, 256],
           server: repo
         ) do
      {:ok, []} -> ""
      {:ok, pending} -> "; #{length(pending)} purge or pause not yet applied there"
      {:error, _reason} -> "; purges and pauses not yet applied there: unknown"
    end
  end

  defp quantity(1, noun), do: "1 #{noun}"
  defp quantity(count, noun), do: "#{count} #{noun}s"

  defp rollup_clause(nil), do: ""

  defp rollup_clause(ts) when is_integer(ts),
    do: " (last roll-up #{age_phrase(System.system_time(:millisecond) - ts)} old)"

  defp open_clause(nil), do: ""

  # How long it has been going, not when it started: the owner asks "am I in the
  # middle of something", and a duration answers that without a clock reading.
  defp open_clause(ts) when is_integer(ts),
    do: "; open sitting for #{age_phrase(System.system_time(:millisecond) - ts)}"

  defp lag_display(0, _oldest_ts), do: ""

  defp lag_display(_unsummarized, oldest_ts) when is_integer(oldest_ts) do
    " (oldest #{age_phrase(System.system_time(:millisecond) - oldest_ts)} old)"
  end

  defp lag_display(_unsummarized, _oldest_ts), do: ""

  defp age_phrase(ms) do
    minutes = div(max(ms, 0), 60_000)
    hours = div(minutes, 60)

    cond do
      minutes < 1 -> "under a minute"
      hours < 1 -> "#{minutes}m"
      true -> "#{hours}h #{rem(minutes, 60)}m"
    end
  end

  # The access audit (§22.8): what the agent has read from history — recorded in
  # the store itself, so it survives trace rotation and the owner can check it.
  defp access_line(repo) do
    case Repo.computer_history_access_stats(server: repo) do
      {:ok, {0, _last}} ->
        "Agent reads: none recorded."

      {:ok, {count, last_ts}} ->
        "Agent reads: #{count} recorded (last: #{format_ts(last_ts)})."

      {:error, reason} ->
        Logger.warning("computer_history access stats unavailable: #{inspect(reason)}")
        "Agent reads: unavailable."
    end
  end

  defp format_ts(ts) when is_integer(ts) do
    ts |> DateTime.from_unix!(:millisecond) |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp format_ts(_other), do: "unknown"

  # An expired horizon reads as not paused (Ingest resumed at the horizon); an
  # unparseable one is shown raw — that is the value the owner repairs, and
  # Ingest fails closed (keeps dropping) until it is cleared.
  defp pause_display(nil), do: "no"

  defp pause_display(until) when is_binary(until) do
    case DateTime.from_iso8601(until) do
      {:ok, horizon, _offset} ->
        if DateTime.compare(DateTime.utc_now(), horizon) == :lt, do: until, else: "no"

      {:error, _reason} ->
        "#{until} (unparseable — capture stays paused until cleared)"
    end
  end

  defp count([]), do: "none"
  defp count(list), do: Integer.to_string(length(list))

  # --- pause --------------------------------------------------------------

  # A pause from chat (M97 §8.5) is recorded on the home, which then takes no
  # sitting stamped inside it from any machine; this machine pauses at once, and
  # each connected computer is told.
  defp pause(duration, reply_fn, host) do
    case Purge.parse_window(duration) do
      {:ok, {:last, ms}} ->
        now = System.system_time(:millisecond)
        reply(reply_fn, pause_everywhere(now, now + ms, host))

      _invalid ->
        reply(reply_fn, "Usage: /history pause 10m|1h|24h")
    end
  end

  # The horizon is enforced by each machine's Ingest (each batch re-reads it) and
  # by the home's refusal, so the success reply is true the moment the writes
  # land, and a failed write is never reported as a pause the owner then relies
  # on. The two stores share no transaction, so the reply says which stood: once
  # the home recorded it, the pause stands (the home summarizes nothing inside
  # it) even when this machine could not apply it yet, which its scheduler does
  # at its next tick.
  defp pause_everywhere(now, until_ms, host) do
    until = until_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

    case Repo.computer_history_home(:pause_window, [now, until_ms, now, :all], server: host.repo) do
      {:ok, _id} ->
        pause_text(apply_here(now, host), until) <> told(host)

      {:error, reason} ->
        Logger.error("computer_history pause persist failed: #{inspect(reason)}")

        "Couldn't record the pause (#{inspect(reason)}): nothing changed and capture is NOT " <>
          "paused. Check the daemon log and try again."
    end
  end

  defp pause_text(here, until) when here in [:ok, :none],
    do: "Computer-history capture paused until #{until}. It resumes automatically then."

  defp pause_text({:failed, reason}, until) do
    "The pause is recorded on this home until #{until}: nothing stamped inside it is " <>
      "summarized from any computer. This Mac's recorder could not be paused yet " <>
      "(#{inspect(reason)}). Fermix tries again every five minutes, and deletes what this Mac " <>
      "recorded inside the pause once it does."
  end

  # This machine's own pending intervals, the new one among them (M97 §8.5,
  # history_submit HS-2): every one above its mark, in order, before its mark
  # moves. A home with no recorder keeps no store.
  defp apply_here(_now, %{recorder?: false}), do: :none

  defp apply_here(now, host) do
    case Delivery.apply_here(
           repo: host.repo,
           spool: host.spool,
           now: DateTime.from_unix!(now, :millisecond)
         ) do
      {:ok, _events} ->
        :ok

      {:error, reason} ->
        Logger.error("computer_history pause was not applied here yet: #{inspect(reason)}")
        {:failed, reason}
    end
  end

  # --- purge --------------------------------------------------------------

  defp purge(window, reply_fn, host) do
    case Purge.parse_window(window) do
      {:ok, parsed} -> reply(reply_fn, run_purge(parsed, host))
      {:error, :invalid_window} -> reply(reply_fn, "Usage: /history purge 10m|1h|24h|all")
    end
  end

  # The home's transaction commits whole or not at all; once it did, the purge
  # stands, and the reply says whether this machine's own raw record went too
  # (see `Purge`).
  defp run_purge(window, host) do
    spool = if host.recorder?, do: host.spool

    case Purge.purge(window, repo: host.repo, spool: spool) do
      {:ok, result} ->
        purged_text(result) <>
          " Threads that drew on that window were removed too; the next roll-up rewrites the " <>
          "thread list from the surviving threads and the session notes written since the last " <>
          "roll-up." <>
          told(host) <>
          " This cannot reach: replies already delivered, any summaries already sent to a " <>
          "remote provider, backups (yours, and your Fermix server's if you have one), or " <>
          "another daemon's store on the same Mac. Purge is logical deletion — rows leave every " <>
          "query, but raw bytes may linger in the database until overwritten."

      {:error, reason} ->
        "Purge failed (#{inspect(reason)}): nothing was deleted. Check the daemon log and try " <>
          "again."
    end
  end

  defp purged_text(%{here: {:failed, reason}, memories: memories}) do
    "Deleted #{memories} activity memory(ies) on this home, and the purge stands: nothing " <>
      "from that window is summarized from any computer. This Mac's raw record in that window " <>
      "could not be deleted yet (#{inspect(reason)}); Fermix tries again every five minutes " <>
      "until it is."
  end

  defp purged_text(%{events: events, memories: memories}),
    do: "Purged #{events} event(s) and #{memories} activity memory(ies)."

  # What the home's computers were told (M97 §8.5): a computer that is away is
  # told when it next connects, and until then the home takes nothing from it in
  # that window.
  defp told(%{computers: []}), do: ""

  defp told(host) do
    %{applied: applied, away: away, failed: failed} = host.deliver.(repo: host.repo)

    [applied_clause(applied), later_clause(away ++ failed)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join()
  end

  defp applied_clause([]), do: ""
  defp applied_clause(names), do: " Applied on #{Enum.join(names, ", ")}."

  defp later_clause([]), do: ""

  defp later_clause(names) do
    " #{Enum.join(names, ", ")} #{if length(names) == 1, do: "gets", else: "get"} it when " <>
      "next connected; until then this home takes nothing from them inside that window."
  end

  # --- off ----------------------------------------------------------------

  defp off(reply_fn, macos?, controller),
    do: reply(reply_fn, off_text(disable(macos?, controller)))

  # `/history off <computer>` (M97 §7.2, §8.5): narrowing may come from
  # anywhere. The home records it at once and takes nothing more from that
  # computer; the computer switches its own history off when told, now if it
  # is connected, once it is back if not.
  defp off_computer(name, host) do
    case find_computer(name, host.computers) do
      {:ok, computer} ->
        computer_off_text(computer.name, host.switch_off.(computer, repo: host.repo))

      :error ->
        no_such_computer(name, host.computers)
    end
  end

  defp find_computer(name, computers) do
    wanted = String.downcase(name)

    case Enum.find(computers, &(&1.device_id == name or String.downcase(&1.name) == wanted)) do
      nil -> :error
      computer -> {:ok, computer}
    end
  end

  defp no_such_computer(name, []),
    do: "This home has no computer named #{name}. /history off alone switches off this one."

  defp no_such_computer(name, computers),
    do:
      "This home has no computer named #{name}. Its computers: " <>
        Enum.map_join(computers, ", ", & &1.name) <> "."

  defp computer_off_text(name, :done) do
    "Computer history is off on #{name}: it records nothing more and sends nothing to this " <>
      "home. Its notes stay here until you /history purge; only someone at #{name} can switch " <>
      "it on again."
  end

  defp computer_off_text(name, :away) do
    "#{name} is away. Its computer history goes off once it is back, and until then this " <>
      "home summarizes nothing from it."
  end

  defp computer_off_text(name, {:failed, reason}) do
    "#{name} could not be told now (#{inspect(reason)}). This home summarizes nothing from it " <>
      "from now on, and tells it again every five minutes until its history is off."
  end

  defp computer_off_text(_name, {:error, reason}) do
    Logger.error("computer_history off for a computer was not recorded: #{inspect(reason)}")

    "Couldn't record that (#{inspect(reason)}): nothing changed. Check the daemon log and try " <>
      "again."
  end

  # One reply per {stop, save} outcome. "Nothing new is captured" goes out only
  # when the Controller confirmed the stop: its reconcile returns only once the
  # Capturer has exited.
  defp off_text({:ok, :ok}) do
    "Computer history disabled — nothing new is captured and the tools are hidden from the next turn. " <>
      "Stored data stays until you `/history purge`; re-enable in setup to resume with the same allowlist."
  end

  # The live rail IS stopped (env flipped + the stop confirmed) — only the
  # durable half failed, and saying otherwise would let a privacy-relevant
  # disable silently evaporate at the next restart.
  defp off_text({:ok, {:error, reason}}) do
    "Computer history capture is stopped for now, but saving the setting failed " <>
      "(#{inspect(reason)}) — it will turn back ON at the next daemon restart. " <>
      "Fix write access to machine.toml in your Fermix home and run /history off again."
  end

  # Nobody confirmed the recorder stopped, so the reply must not say it did.
  defp off_text({{:error, stop_reason}, :ok}) do
    "Computer history disabled and the setting is saved, but the recorder could not be confirmed " <>
      "stopped (#{unconfirmed_phrase(stop_reason)}) — it may still be capturing. Check `/history status`: " <>
      "\"Capture: not running\" means it has stopped; if it has not, run /history off again. " <>
      "The tools are hidden from the next turn; stored data stays until you `/history purge`."
  end

  defp off_text({{:error, stop_reason}, {:error, save_reason}}) do
    "Computer history is disabled for now, but the recorder could not be confirmed stopped " <>
      "(#{unconfirmed_phrase(stop_reason)}) and saving the setting failed (#{inspect(save_reason)}) — " <>
      "capture may still be running, and it will turn back ON at the next daemon restart. " <>
      "Fix write access to machine.toml in your Fermix home, run /history off again and " <>
      "check `/history status`."
  end

  # Why the stop is unconfirmed, in words; the full exit reason is in the error
  # log `ComputerHistory.reconcile_runtime/1` wrote.
  defp unconfirmed_phrase({:reconcile_failed, {:noproc, _call}}),
    do: "its controller is not running"

  defp unconfirmed_phrase({:reconcile_failed, {:timeout, _call}}),
    do: "its controller did not answer in time"

  defp unconfirmed_phrase({:reconcile_failed, _exit}), do: "its controller failed mid-call"

  # Flip app env for the immediate un-advertise, stop the live capture rail,
  # then persist `enabled = false` to this machine's `machine.toml` so the
  # disable survives a restart (§5.4), all in `ComputerHistory.switch_off/1`,
  # the one off a computer told from chat runs too. The stop runs only where
  # this system has a recorder, the only place the rail records, and the save
  # runs whatever the stop's outcome: the durable disable must not depend on the
  # live stop. Returns both outcomes for the reply.
  defp disable(recorder?, controller) do
    %{stop: stop, save: save} =
      ComputerHistory.switch_off(recorder?: recorder?, controller: controller)

    {stop, save}
  end

  # --- shared -------------------------------------------------------------

  defp usage do
    "Usage: /history status | /history pause 10m|1h|24h | /history purge 10m|1h|24h|all | /history off"
  end

  defp reply(reply_fn, text) do
    reply_fn.({:text, text})
    :ok
  end
end
