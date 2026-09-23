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

  require Logger

  alias FermixCore.ComputerUse
  alias FermixCore.ComputerUse.CaptureHealth
  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.OperatorStop
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

    with :ok <- OperatorStop.check(key, Map.get(context, :session_id)) do
      case Registry.lookup(CuSupervisor.registry(), key) do
        [{pid, _}] -> {:ok, pid}
        [] -> start_session(key, config, context, opts)
      end
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

  @typedoc "What a `/pause` or `/resume` may tell the human about this conversation."
  @type verdict :: Session.control_verdict() | :no_session

  @doc """
  Pause the computer-use session for `context`'s conversation (`/pause`): the human
  is reclaiming the machine. Unlike `abort/1`, the session, its TCC-warm sidecar, and
  the task stay ALIVE and resumable — `pause` installs a barrier in the helper and
  flips the session's own guard so it refuses actions until `resume/1`. Idempotent +
  race-safe (a clean no-op when the registry is absent).

  The verdict is the helper's ACKNOWLEDGEMENT of the barrier: `:paused`,
  `:paused_in_flight` when the ack names an action already under way that will finish
  (which is the difference `/pause` has to tell the human), `:unconfirmed` when the
  barrier could not be proven installed — the session is then reset, which
  definitively returns the machine — or `:no_session`.
  """
  @spec pause(map()) :: verdict()
  def pause(context) when is_map(context) do
    case session(context) do
      {:ok, pid} -> control(pid, &Session.pause/1)
      :error -> :no_session
    end
  end

  @doc """
  Resume a paused session (`/resume`). `:resumed`; `:unconfirmed` when lifting the
  barrier was not acknowledged, in which case the session is reset so the next action
  starts a helper with no barrier on it; or `:no_session`.
  """
  @spec resume(map()) :: verdict()
  def resume(context) when is_map(context) do
    case session(context) do
      {:ok, pid} -> control(pid, &Session.resume/1)
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

  # A control is a call now, because the answer is the helper's acknowledgement and
  # the session has to wait for it. Two exits are possible between the registry read
  # and the reply, and they mean opposite things: a session that ENDED has already
  # handed the machine back (its teardown releases held input and ends the helper),
  # while a session that did not answer at all leaves the barrier unproven.
  defp control(pid, verb) do
    verb.(pid)
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] -> :no_session
    :exit, _reason -> abandon(pid)
  end

  # `:unconfirmed` means ONE thing on every surface that renders it — the helper
  # was shut down — so it has to be true here too. A session that did not answer
  # inside the control budget is wedged on something other than the barrier, and
  # leaving it alive while telling the human it was ended is exactly the lie this
  # verdict exists to avoid. Synchronous and bounded by the session's own child
  # spec shutdown, so it returns only once the machine really is back.
  defp abandon(pid) do
    Logger.warning("computer_use: a session did not answer a control; ending it")
    DynamicSupervisor.terminate_child(CuSupervisor.session_supervisor(), pid)
    :unconfirmed
  end

  # The running session for this conversation, guarded: the registry only exists
  # while computer-use is enabled + ready, and a context need not carry a
  # conversation at all.
  defp session(context) do
    with true <- registry_running?(),
         true <- Map.has_key?(context, :conversation_key),
         [{pid, _value}] <- Registry.lookup(CuSupervisor.registry(), conversation_key(context)) do
      {:ok, pid}
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
