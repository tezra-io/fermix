defmodule FermixChannels.Gateway.Commands.History do
  @moduledoc """
  `/history` — owner-only management of the on-device computer-history rail
  (MILESTONE_32 §5.3). Ingress-dispatched ahead of the turn so it lands
  immediately, and handled in the daemon with direct access to the store:

    * `/history status`            — capture/summarizer/allowlist/spool overview
    * `/history pause <10m|1h|…>`  — persist a capture pause horizon (§7.3)
    * `/history purge 10m|1h|24h|all` — erase a window from the spool + memories
    * `/history off`               — disable (un-advertises next turn); data stays

  Enabling is the wizard's job (the consent act, §5.5), never a chat command.
  """

  @behaviour FermixChannels.Gateway.Command

  require Logger

  alias FermixChannels.Gateway.Commands.Authorization
  alias FermixCore.ComputerHistory
  alias FermixCore.ComputerHistory.Capturer
  alias FermixCore.ComputerHistory.Config
  alias FermixCore.ComputerHistory.Purge
  alias FermixCore.Memory.Repo
  alias FermixCore.Setup.ConfigStore

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
    dispatch(args(message), reply_fn, repo(context))
  end

  # `:computer_history_repo` in context is a test-only injection seam; production
  # dispatch runs in the daemon against the default single-writer Repo.
  defp repo(context), do: Map.get(context, :computer_history_repo, Repo)

  defp args(message), do: String.split(message.content, ~r/\s+/, trim: true)

  defp dispatch([], reply_fn, repo), do: reply(reply_fn, status_text(repo))
  defp dispatch(["status" | _rest], reply_fn, repo), do: reply(reply_fn, status_text(repo))

  defp dispatch(["pause"], reply_fn, _repo),
    do: reply(reply_fn, "Usage: /history pause 10m|1h|24h")

  defp dispatch(["pause", duration], reply_fn, repo), do: pause(duration, reply_fn, repo)
  defp dispatch(["purge", window], reply_fn, repo), do: purge(window, reply_fn, repo)
  defp dispatch(["off" | _rest], reply_fn, _repo), do: off(reply_fn)
  defp dispatch(_other, reply_fn, _repo), do: reply(reply_fn, usage())

  # --- status -------------------------------------------------------------

  defp status_text(repo) do
    if ComputerHistory.macos?() do
      [
        enabled_line(),
        capture_line(),
        allowlist_line(),
        summarizer_line(),
        spool_line(repo),
        access_line(repo)
      ]
      |> Enum.join("\n")
    else
      "Computer history is macOS only; unavailable on this host."
    end
  end

  defp enabled_line do
    "Computer history: #{if Config.enabled?(), do: "on", else: "off"}."
  end

  # The capturer's live runtime mode — the one place a *degraded* rail becomes
  # visible to the operator (a mismatch/refusal is otherwise only in the log).
  defp capture_line, do: "Capture: #{capture_phrase(Capturer.status())}."

  defp capture_phrase(%{mode: :capturing}), do: "running"
  defp capture_phrase(%{mode: :restarting}), do: "restarting the recorder"

  defp capture_phrase(%{mode: :standing_down}),
    do: "standing down (another daemon on this Mac holds it)"

  defp capture_phrase(%{mode: :not_running}), do: "not running"

  defp capture_phrase(%{mode: :degraded, reason: reason}),
    do: "degraded — #{degrade_phrase(reason)}"

  defp capture_phrase(%{mode: mode}), do: to_string(mode)

  defp degrade_phrase({:protocol_mismatch, %{required: required, sidecar: sidecar}}),
    do: "recorder protocol v#{sidecar} ≠ required v#{required} (a compux upgrade is needed)"

  defp degrade_phrase(:observe_start_refused), do: "the recorder refused to start observing"

  defp degrade_phrase({:sidecar_restart_exhausted, _status}),
    do: "the recorder kept exiting; retries exhausted"

  defp degrade_phrase(:sidecar_unavailable), do: "the recorder binary is unavailable"
  defp degrade_phrase({:sidecar_missing, _path}), do: "the recorder binary is not installed"
  defp degrade_phrase(other), do: inspect(other)

  defp allowlist_line do
    apps = Config.apps()
    sites = Config.sites()
    "Apps allowlisted: #{count(apps)}; sites: #{count(sites)}."
  end

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

  # The one shared resolver (§22.1): subagent provider else primary — the same
  # answer the Gate and the summarizer use, so this privacy line never names a
  # different vendor than the one raw activity actually reaches.
  defp default_provider_label do
    case Config.default_summarizer_provider() do
      {:ok, provider} -> "subagent/default (#{provider})"
      {:error, _reason} -> "default provider (none configured)"
    end
  end

  defp spool_line(repo) do
    with {:ok, count} <- Repo.computer_history_count_events(server: repo),
         {:ok, state} <- Repo.computer_history_ensure_state(server: repo) do
      paused = state.pause_until || "no"

      "Spool: #{count} event(s). Last summarization: #{state.last_status || "none"}. Paused until: #{paused}."
    else
      {:error, reason} ->
        # Log the root cause — "unavailable" alone is undiagnosable from a trace.
        Logger.warning("computer_history spool status unavailable: #{inspect(reason)}")
        "Spool: unavailable."
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

  defp count([]), do: "none"
  defp count(list), do: Integer.to_string(length(list))

  # --- pause --------------------------------------------------------------

  defp pause(duration, reply_fn, repo) do
    case Purge.parse_window(duration) do
      {:ok, {:last, ms}} ->
        until = DateTime.utc_now() |> DateTime.add(ms, :millisecond) |> DateTime.to_iso8601()
        _ = Repo.computer_history_set_pause_until(until, server: repo)

        reply(
          reply_fn,
          "Computer-history capture paused until #{until}. It resumes automatically then."
        )

      _invalid ->
        reply(reply_fn, "Usage: /history pause 10m|1h|24h")
    end
  end

  # --- purge --------------------------------------------------------------

  defp purge(window, reply_fn, repo) do
    case Purge.parse_window(window) do
      {:ok, parsed} -> reply(reply_fn, run_purge(parsed, repo))
      {:error, :invalid_window} -> reply(reply_fn, "Usage: /history purge 10m|1h|24h|all")
    end
  end

  defp run_purge(window, repo) do
    case Purge.purge(window, repo: repo) do
      {:ok, %{events: events, memories: memories}} ->
        "Purged #{events} event(s) and #{memories} activity memory(ies). This cannot reach: " <>
          "replies already delivered, any summaries already sent to a remote provider, backups " <>
          "you keep yourself, or another daemon's store on the same Mac. Purge is logical deletion — " <>
          "rows leave every query, but raw bytes may linger in the database until overwritten."

      {:error, reason} ->
        "Purge failed: #{inspect(reason)}."
    end
  end

  # --- off ----------------------------------------------------------------

  defp off(reply_fn) do
    disable()

    reply(
      reply_fn,
      "Computer history disabled — nothing new is captured and the tools are hidden from the next turn. " <>
        "Stored data stays until you `/history purge`; re-enable in setup to resume with the same allowlist."
    )
  end

  # Flip app env for the immediate un-advertise, stop the live capture rail, then
  # persist to config.toml so the disable survives a restart (§5.4). The persisted
  # snapshot is built from live app env (already normalized at boot), the wizard's
  # own save pattern. Reconcile AFTER the env flip so the controller reads the
  # disabled posture and tears the capturer down now, not on the next boot.
  defp disable do
    current = Application.get_env(:fermix_core, :computer_history, [])
    Application.put_env(:fermix_core, :computer_history, Keyword.put(current, :enabled, false))

    ComputerHistory.reconcile_runtime()

    snapshot = ConfigStore.current_snapshot()

    case ConfigStore.save_snapshot(snapshot) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("computer_history disable persist failed: #{inspect(reason)}")
    end
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
