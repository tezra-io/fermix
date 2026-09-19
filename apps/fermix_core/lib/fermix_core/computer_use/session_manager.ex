defmodule FermixCore.ComputerUse.SessionManager do
  @moduledoc """
  Finds or lazily starts the one `ComputerUse.Session` per conversation, so the
  long-lived OS-driver process is opened only when the tool is actually used (not
  per turn) and reused across actions in the same conversation.

  `ensure/3` is keyed by `conversation_key`; it resolves the session's origin from
  the call context and **fails closed** for an unattended host-mode origin (§7.6)
  before any process or sidecar is started. It also refuses while the global
  `CaptureHealth` breaker is open, so a wedged capture host stops being handed
  fresh sidecars (`WATCH_HARDENING.md` §3). The driver defaults to `PortDriver`
  (the real sidecar) in production; tests inject a stub driver, so the manager is
  fully exercised without the binary.
  """

  alias FermixCore.ComputerUse
  alias FermixCore.ComputerUse.CaptureHealth
  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Safety
  alias FermixCore.ComputerUse.Session
  alias FermixCore.ComputerUse.Supervisor, as: CuSupervisor

  @doc """
  Find or start the computer-use session for `context`'s conversation. Returns the
  session pid, or fails closed for an unattended host origin.
  """
  @spec ensure(Config.t(), map(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure(%Config{} = config, context, opts \\ []) when is_map(context) do
    key = conversation_key(context)

    case Registry.lookup(CuSupervisor.registry(), key) do
      [{pid, _}] -> {:ok, pid}
      [] -> start_session(key, config, context, opts)
    end
  end

  @doc "The running session for this conversation, if any."
  @spec lookup(map()) :: {:ok, pid()} | :error
  def lookup(context) when is_map(context) do
    case Registry.lookup(CuSupervisor.registry(), conversation_key(context)) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Tear down the computer-use session for `context`'s conversation, if one is
  running. Idempotent — a no-op when none exists (or the context carries no
  conversation key). An attended surface (e.g. the realtime voice session) calls
  this on end-of-call so a host session never outlives the attended human (§7.6).
  """
  @spec abort(map()) :: :ok
  def abort(context) when is_map(context) do
    with true <- registry_running?(),
         true <- Map.has_key?(context, :conversation_key),
         {:ok, pid} <- lookup(context) do
      # Tear down through the supervisor, NOT `Session.abort/1` (GenServer.stop):
      # `terminate_child` removes the child (runs `Session.terminate/2` to release
      # held input) and — unlike a pid `GenServer.stop` — returns `{:error,
      # :not_found}` rather than EXITING if the pid already died in a teardown
      # race, so this backstop never crashes its caller.
      DynamicSupervisor.terminate_child(CuSupervisor.session_supervisor(), pid)
      :ok
    else
      _ -> :ok
    end
  end

  @doc """
  Pause the computer-use session for `context`'s conversation (`/pause`): the human
  is reclaiming the machine. Unlike `abort/1`, the session, its TCC-warm sidecar, and
  the task stay ALIVE and resumable — `pause` just flips the session's guard so it
  refuses actions until `resume/1`. Idempotent + race-safe (a clean no-op when the
  registry is absent).

  Returns `:paused` when the session was idle, `:paused_in_flight` when one action is
  already inside the helper — it cannot be recalled over this protocol and will
  finish, which is the difference `/pause` has to tell the human — or `:no_session`.
  The in-flight fact is read from the session's registry entry rather than asked of
  the session, which is blocked in the driver for exactly as long as that action runs.
  """
  @spec pause(map()) :: :paused | :paused_in_flight | :no_session
  def pause(context) when is_map(context) do
    case entry(context) do
      {:ok, pid, _value} -> pause_session(pid, context)
      :error -> :no_session
    end
  end

  @doc "Resume a paused session (`/resume`). Returns `:resumed` or `:no_session`."
  @spec resume(map()) :: :resumed | :no_session
  def resume(context) when is_map(context) do
    case entry(context) do
      {:ok, pid, _value} -> resume_session(pid)
      :error -> :no_session
    end
  end

  @doc """
  The `cua_…` lifecycle id a running session was minted with, read from its registry
  entry. `nil` for a session started outside the registry (tests, direct callers) and
  while computer-use is not running.

  Read rather than asked: the session may be blocked inside a driver call for the
  whole sidecar budget, and recording which session a tool call ran in must never
  wait on that.
  """
  @spec session_id(term()) :: String.t() | nil
  def session_id(pid) when is_pid(pid) do
    with true <- registry_running?(),
         [key] <- Registry.keys(CuSupervisor.registry(), pid),
         [{^pid, %{session_id: id}}] <- Registry.lookup(CuSupervisor.registry(), key) do
      id
    else
      _ -> nil
    end
  end

  # Total on purpose. A caller may put any `GenServer.server()` on the context as
  # `:computer_use_session` (a name, a via tuple, a stale term), and this is called
  # while RECORDING what a tool call did — raising here would lose the exec event
  # for the action that ran. An unresolvable session simply has no id to record.
  def session_id(_session), do: nil

  # Cast FIRST, then read the flag. The order strictly narrows the window: every
  # execute that has not yet passed its paused precheck when the cast lands is now
  # refused, so the only action this can still report is one already past it —
  # which is exactly what the flag says. Reading first left a gap where an execute
  # started after the read and dispatched while `/pause` had already answered
  # "yours". A session that ended in between has nothing under way.
  defp pause_session(pid, context) do
    Session.pause(pid)

    case entry(context) do
      {:ok, _pid, value} -> if in_flight?(value), do: :paused_in_flight, else: :paused
      :error -> :paused
    end
  end

  defp resume_session(pid) do
    Session.resume(pid)
    :resumed
  end

  # The value a session publishes for itself (`Session.publish_in_flight/2`). A
  # session that has not published yet has no action under way.
  defp in_flight?(%{in_flight?: true}), do: true
  defp in_flight?(_value), do: false

  # The registry ENTRY (pid + published value), not just the pid: `/pause` needs
  # both, and reading them in one lookup keeps them from describing two moments.
  defp entry(context) do
    with true <- registry_running?(),
         true <- Map.has_key?(context, :conversation_key),
         [{pid, value}] <- Registry.lookup(CuSupervisor.registry(), conversation_key(context)) do
      {:ok, pid, value}
    else
      _ -> :error
    end
  end

  # The registry only exists while computer-use is enabled + ready — its whole
  # supervisor is gated on `ComputerUse.ready?/0`. A teardown backstop runs on
  # EVERY attended-surface exit (incl. when CU is disabled), so it must be a clean
  # no-op — not an `ArgumentError` from `Registry.lookup` — when it isn't running.
  defp registry_running?, do: is_pid(Process.whereis(CuSupervisor.registry()))

  defp start_session(key, config, context, opts) do
    origin = origin(context)

    with :ok <- precheck_host_origin(config, origin),
         :ok <- CaptureHealth.status(),
         {:ok, driver} <- resolve_driver(opts) do
      child = {Session, session_opts(key, config, context, origin, driver)}

      case DynamicSupervisor.start_child(CuSupervisor.session_supervisor(), child) do
        {:ok, pid} -> {:ok, pid}
        # A concurrent action started it first — reuse the winner.
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp session_opts(key, config, context, origin, driver) do
    [
      name: {:via, Registry, {CuSupervisor.registry(), key}},
      config: config,
      driver: driver,
      origin: origin,
      parent_session: Map.get(context, :session_id),
      agent: to_string(Map.get(context, :agent_name, "computer_use"))
    ]
  end

  # Tests inject a stub driver via opts; production resolves the installed sidecar
  # binary through the plugin store and FAILS CLOSED if it's unavailable (covers a
  # TOCTOU between the ready? check that registered the tool and session start).
  defp resolve_driver(opts) do
    case Keyword.get(opts, :driver) do
      nil -> default_driver()
      driver -> {:ok, driver}
    end
  end

  # The Session re-checks the origin gate in init; prechecking here returns a clean
  # `{:error, _}` instead of a supervisor `{:stop, _}` for the common refusal.
  # Computer-use is host-desktop control only, so the gate applies uniformly.
  defp precheck_host_origin(%Config{}, origin) do
    if Safety.host_start_allowed?(origin),
      do: :ok,
      else: {:error, {:host_start_refused, origin}}
  end

  defp default_driver, do: ComputerUse.driver_spec()

  # Fail closed by default: a turn must EXPLICITLY declare an attended origin
  # (`:interactive`/`:voice`) to start a host session. Anything that never set
  # `:computer_use_origin` — a scheduled job, an unforeseen call path — is treated as
  # `:unattended` and refused in host mode (§7.6), never silently granted control.
  defp origin(context), do: Map.get(context, :computer_use_origin, :unattended)

  defp conversation_key(context), do: Map.fetch!(context, :conversation_key)
end
