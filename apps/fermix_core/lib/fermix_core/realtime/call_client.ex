defmodule FermixCore.Realtime.CallClient do
  @moduledoc """
  The transport-independent half of one voice connection (M91 §04, D22).

  A struct and functions that run inside the transport adapter's own process:
  the Unix socket's connection handler (`LocalVoiceSocket`) today, a serial or
  WebSocket link and the phone's call channel later. The adapter owns its
  connection, framing, handshake and encoding; this module owns the call:

    * the endpoint the call is for, the peer's realtime protocol version (what
      the Unix handshake negotiated, or the level an adapter translates), and
      the config the connection started with;
    * the per-engine minimum version, the endpoint's engine rule
      (`Endpoint.admit_engine/2`: a phone takes a call only on a task engine)
      and the owner's voice device (`Accessories.VoiceDevice.refusal/3`: the
      Mac's own call waits while a paired accessory is chosen, or while the
      choice cannot be read, M91 E3), each refused at `call_start` before any
      session exists;
    * starting the session through `SessionGuard`, which monitors the adapter
      before the session exists and binds it the moment it does, so it never
      outlives the adapter (`session_opts/1` is the default starter's half of
      the session contract);
    * the command verbs, each refused under an engine that has no clause for
      it: `task_cancel` only on the task engines, `playback_progress` only on
      Grok, and the camera (`camera`, Realtime v4) only on the task engines,
      from an endpoint that can carry its frames whose hello said it has one,
      and on only while the owner's `camera_share` is (the one refusal that
      leaves the call up);
    * the ordered flush of frames the session already queued before the
      call's own last word, and teardown;
    * the mapping of the wire's decoded events to the verbs (`event/2`), shared
      by every adapter that speaks the Realtime wire.

  Every frame leaves through the adapter's `emit` function, so the adapter
  keeps its own encoding. Each verb answers `{:cont, client}` to keep the
  connection or `{:stop, client}` after a terminal frame. The error vocabulary
  is the realtime wire's (`priv/realtime/PROTOCOL.md`).

  A session ends a call itself only on the owner's goodbye (M96 §6), and only
  for a peer at wire version 5 or later (`ends_on_goodbye`, in the session's
  start options): its `call_ended` frame is already queued, and its exit
  reaches `session_down/2`, which answers `{:ended, client}`, the button's end.

  What an adapter does, a GenServer included:

    * calls every verb from its own process, never from a task: the session's
      companion is that process, so the session's frames arrive in its mailbox
      as `{:realtime, event}`, and it writes each with `emit` (the flush before
      a refusal or `idle` drains them itself);
    * hands the session monitor's `:DOWN` (`session_ref`) to `session_down/2`
      and then ends the connection;
    * runs `teardown/1` when it ends the connection on its own, the prompt
      path that also releases the guard.

  It need not trap exits or run `teardown/1` from `terminate/2`: an adapter
  killed or crashed (a serial link stopped by its watcher on unplug, a phone's
  call ended on revocation) has its session torn down by the guard, including
  one that was still starting. `call_start` blocks the adapter while its
  session starts, up to the guard's start bound, so a GenServer adapter whose
  own loop must stay responsive owns each call from a per-call process, as the
  socket's handler task does.

  `cancel_task` and `call_stop` wait with no timeout of their own
  (`SessionControl`). The socket keeps that wait, bounded by its companion
  dropping a connection it cannot write to; an adapter whose own loop must
  outlast a stuck session (the phone's call, which a resume window and a
  revocation must still reach) gives them a `deadline_ms`. The wait then runs
  in a task under the deadline while the adapter's own mailbox keeps the
  session's frames: a cancel past it is given up and the call goes on (the
  session still processes it), and a stop past it lets the session go from the
  guard (it settles on its own, holding the home's call until it does).
  """

  alias FermixCore.Accessories.Config, as: AccessoriesConfig
  alias FermixCore.Accessories.Store, as: AccessoryStore
  alias FermixCore.Accessories.VoiceDevice
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.DeviceIdentity
  alias FermixCore.Realtime.Endpoint
  alias FermixCore.Realtime.Protocol
  alias FermixCore.Realtime.SessionControl
  alias FermixCore.Realtime.SessionGuard
  alias FermixCore.Realtime.SessionSupervisor
  alias FermixCore.Realtime.VoiceBridge
  alias FermixCore.Setup.ConfigStore

  require Logger

  # The wire version each engine's CALL requires. The handshake window still
  # admits an older companion (it may run an engine it can render); this is the
  # floor for a call, and the number the refusal reports as `min_version`.
  @engine_min_protocol_version %{"openai_realtime" => 1, "openai_live" => 2, "xai_realtime" => 3}
  # The wire version that added `camera` and the hello's `camera` flag (M87).
  @camera_min_protocol_version 4
  # The wire version that added `call_ended`, the end a session starts itself
  # when the owner says goodbye (M96): an older peer would show it as a
  # failure, so its session never ends a call that way.
  @goodbye_min_protocol_version 5
  # How many queued frames are written ahead of the call's own last word (a
  # refusal, a session-down error, a hang-up's `idle`) before the drain gives
  # up and that word is written. A session queues a handful.
  @max_flushed_frames 64

  @enforce_keys [:endpoint, :protocol_version, :config, :emit, :task_supervisor]
  defstruct [
    :endpoint,
    :protocol_version,
    :config,
    :emit,
    :task_supervisor,
    :session,
    :session_ref,
    session_module: SessionControl,
    session_starter: nil,
    # Options of the adapter's own the starter is handed besides the ones this
    # module sets (companion, endpoint, supervisors).
    starter_opts: [],
    session_supervisor: SessionSupervisor,
    session_guard: SessionGuard,
    # How long `task_cancel` and `call_stop` wait for the session (moduledoc).
    deadline_ms: :infinity,
    # Whether the peer's `client_hello` said its endpoint has a camera (v4),
    # and whether the session has the camera on (`camera/2`).
    camera?: false,
    camera_on?: false,
    # The owner's voice device and the accessory switch, read at the Mac's
    # `call_start` (`Accessories.VoiceDevice.refusal/3`).
    voice_device: nil,
    accessories_enabled?: nil
  ]

  @type emit :: (map() -> :ok | {:error, term()})
  @type t :: %__MODULE__{
          endpoint: Endpoint.t(),
          protocol_version: pos_integer(),
          config: Config.t(),
          emit: emit(),
          task_supervisor: GenServer.server(),
          session: pid() | nil,
          session_ref: reference() | nil,
          session_module: module(),
          session_starter: SessionGuard.starter(),
          starter_opts: keyword(),
          session_supervisor: GenServer.server(),
          session_guard: GenServer.server(),
          deadline_ms: timeout(),
          camera?: boolean(),
          camera_on?: boolean(),
          voice_device: (-> VoiceDevice.read()),
          accessories_enabled?: (-> boolean())
        }
  @type result :: {:cont, t()} | {:stop, t()}

  @doc """
  A connection's call half, once the peer's version is known. Required:
  `:endpoint`, `:protocol_version`, `:config`, `:emit`, `:task_supervisor`.
  The rest default to the daemon's own (`SessionControl`, the default starter,
  `SessionSupervisor`, `SessionGuard`); a test names doubles.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    endpoint = Keyword.fetch!(opts, :endpoint)
    _valid = Endpoint.format(endpoint)

    struct!(
      __MODULE__,
      opts
      |> Keyword.put_new(:session_starter, &start_session/1)
      |> Keyword.put_new(:voice_device, &chosen_voice_device/0)
      |> Keyword.put_new(:accessories_enabled?, &AccessoriesConfig.enabled?/0)
      |> Keyword.update!(:protocol_version, &positive_version!/1)
      |> Keyword.update!(:config, fn %Config{} = config -> config end)
      |> Keyword.update!(:emit, fn emit when is_function(emit, 1) -> emit end)
      |> Keyword.update(:deadline_ms, :infinity, &deadline!/1)
      |> Keyword.update(:camera?, false, fn camera? when is_boolean(camera?) -> camera? end)
      |> Keyword.update!(:voice_device, fn read when is_function(read, 0) -> read end)
      |> Keyword.update!(:accessories_enabled?, fn read when is_function(read, 0) -> read end)
    )
  end

  @doc """
  The options the default starter hands `SessionSupervisor.start_session/2`:
  which engine module runs the call, under which scope, with which
  credentials, and the endpoint's safety identifier (`Endpoint`), which only
  an OpenAI Realtime session sends; the task engines ignore it. Both
  engine-derived values come from `SessionControl`, so the scope prefix a
  trace reader searches for (`session:` vs `voice_live:`) and the module that
  gets started can never disagree about which engine is in force.
  """
  @spec session_opts(keyword()) :: {:ok, keyword()} | {:error, term()}
  def session_opts(opts) when is_list(opts) do
    endpoint = Keyword.fetch!(opts, :endpoint)
    config = Config.current()

    with {:ok, api_key} <- Config.api_key(config),
         {:ok, device_id} <-
           DeviceIdentity.ensure_device_id(ConfigStore.workspace_paths().realtime) do
      owner_id = MemoryConfig.owner_id()

      {:ok,
       opts
       |> Keyword.put(:config, config)
       |> Keyword.put(:engine_module, SessionControl.engine_module(config))
       |> Keyword.put(:api_key, api_key)
       |> Keyword.put(:device_id, device_id)
       |> Keyword.put_new(:session_scope, SessionControl.session_scope(config))
       |> Keyword.put(
         :safety_identifier,
         Endpoint.safety_identifier(endpoint, owner_id, device_id)
       )}
    end
  end

  @doc """
  Starts the call. `call_start` is the first moment both the peer's version
  and the configured engine are known, so the per-engine minimum lands here,
  and BEFORE a session exists: a task-engine session bills by the minute from
  the moment it opens, and an older peer could not render the call anyway.
  """
  @spec call_start(t()) :: result()
  def call_start(%__MODULE__{} = client) do
    cond do
      Endpoint.admit_engine(client.endpoint, client.config.engine) != :ok ->
        stop_with(:engine_not_for_phones, client)

      client.protocol_version < engine_min_protocol_version(client.config) ->
        update_required(client)

      true ->
        admit_device(client)
    end
  end

  # Only the Mac's own call is the owner's voice device's to refuse: an
  # accessory's call is its link's, and a phone's is not this Mac's.
  defp admit_device(%__MODULE__{endpoint: :desktop} = client) do
    read = client.voice_device.()

    case VoiceDevice.refusal(:desktop, read, client.accessories_enabled?.()) do
      :ok -> start_call(client)
      {:error, refusal} -> voice_device_refused(client, read, refusal)
    end
  end

  defp admit_device(client), do: start_call(client)

  defp chosen_voice_device, do: AccessoryStore.load_voice_device(ConfigStore.fermix_home())

  defp voice_device_refused(client, read, {reason, device, sentence}) do
    if match?({:error, _}, read),
      do: Logger.error("realtime: the voice device could not be read: #{inspect(elem(read, 1))}")

    frame = %{type: "error", reason: Atom.to_string(reason), sentence: sentence}
    _ = client.emit.(if device, do: Map.put(frame, :voice_device, device), else: frame)
    {:stop, client}
  end

  @doc """
  The wire's decoded events (`Protocol.decode_client_event/2`, after the
  handshake) as the call's verbs: the one mapping every adapter that speaks
  the Realtime wire shares. `audio_chunk`'s payload is the decoded PCM.
  """
  @spec event(t(), Protocol.event()) :: result()
  def event(%__MODULE__{} = client, %{type: "call_start"}), do: call_start(client)

  def event(%__MODULE__{} = client, %{type: "audio_chunk", payload: %{"audio" => audio}}),
    do: audio(client, audio)

  def event(%__MODULE__{} = client, %{type: "interrupt", payload: payload}),
    do: interrupt(client, Map.get(payload, "audio_end_ms"))

  def event(%__MODULE__{} = client, %{type: "mute", payload: payload}),
    do: mute(client, Map.get(payload, "enabled", true) == true)

  def event(%__MODULE__{} = client, %{type: "task_cancel", payload: payload}),
    do: task_cancel(client, Map.fetch!(payload, "delegation_id"))

  def event(%__MODULE__{} = client, %{type: "playback_progress", payload: payload}) do
    %{"playback_id" => playback_id, "played_ms" => played_ms, "drained" => drained?} = payload
    playback_progress(client, playback_id, played_ms, drained?)
  end

  def event(%__MODULE__{} = client, %{type: "camera", payload: %{"on" => on?}}),
    do: camera(client, on?)

  def event(%__MODULE__{} = client, %{type: "call_stop"}), do: call_stop(client)

  @doc """
  The wire version a call on `config`'s engine requires: the floor
  `call_start` refuses below, and what a phone's `hello_ack` publishes.
  """
  @spec engine_min_protocol_version(Config.t()) :: pos_integer()
  def engine_min_protocol_version(%Config{engine: engine}),
    do: Map.fetch!(@engine_min_protocol_version, engine)

  @doc "Forwards one microphone chunk."
  @spec audio(t(), binary()) :: result()
  def audio(%__MODULE__{} = client, audio) when is_binary(audio),
    do: command(client, &client.session_module.audio_chunk(&1, audio))

  @doc "Barge-in. `audio_end_ms` is how much assistant audio actually played."
  @spec interrupt(t(), non_neg_integer() | nil) :: result()
  def interrupt(%__MODULE__{} = client, audio_end_ms),
    do: command(client, &client.session_module.interrupt(&1, audio_end_ms))

  @doc "Gates microphone capture."
  @spec mute(t(), boolean()) :: result()
  def mute(%__MODULE__{} = client, enabled?) when is_boolean(enabled?),
    do: command(client, &client.session_module.mute(&1, enabled?))

  @doc """
  Cancels one backend delegation. Only the task engines have delegations: a
  Realtime call is refused here rather than forwarded to a session with no
  clause for it.
  """
  @spec task_cancel(t(), String.t()) :: result()
  def task_cancel(%__MODULE__{} = client, delegation_id) when is_binary(delegation_id) do
    if Config.hands_off_tasks?(client.config),
      do: cancel_task(client, delegation_id),
      else: stop_with(:unsupported_by_engine, client)
  end

  @doc """
  What the peer has played of one stretch of Grok audio. Only Grok sends audio
  under playback ids; a report the session refuses (an id never sent, an
  offset that went backwards or past the audio sent) ends the connection with
  its reason.
  """
  @spec playback_progress(t(), String.t(), non_neg_integer(), boolean()) :: result()
  def playback_progress(%__MODULE__{} = client, playback_id, played_ms, drained?) do
    if client.config.engine == "xai_realtime",
      do:
        command(
          client,
          &client.session_module.playback_progress(&1, playback_id, played_ms, drained?)
        ),
      else: stop_with(:unsupported_by_engine, client)
  end

  @doc """
  Turns the call's camera on or off (Realtime v4, M87 Phase 2); `camera_on?`
  is then the state the session holds. Taken from an endpoint that can carry a
  camera's frames (`Endpoint.camera?/1`) whose hello at version 4 or later said
  it has one, on a task engine: anything else is the peer's bug, refused in
  that order with `unsupported_by_endpoint` or `unsupported_by_engine`, and the
  connection ends. Turning it on also needs the owner's `camera_share`, as the
  call's config holds it: the owner may turn it off after the peer last
  heard, so `camera_off` refuses that one event, the camera stays off and the
  call goes on. The session hears of none of these.
  """
  @spec camera(t(), boolean()) :: result()
  def camera(%__MODULE__{} = client, on?) when is_boolean(on?) do
    case camera_refusal(client, on?) do
      nil -> camera_applied(command(client, &client.session_module.camera(&1, on?)), on?)
      :camera_off -> refuse_event(:camera_off, client)
      reason -> stop_with(reason, client)
    end
  end

  @doc """
  Hands the session the camera's newest frame, or `nil` to let it go (M87
  Phase 2). The frames ride the adapter's own transport, which bounds them
  and sends one only while the camera it turned on through `camera/2` is on.
  """
  @spec frame(t(), VoiceBridge.frame_input() | nil) :: result()
  def frame(%__MODULE__{} = client, frame) when is_map(frame) or is_nil(frame),
    do: command(client, &client.session_module.camera_frame(&1, frame))

  @doc """
  Ends the CALL but keeps the connection for a fresh one. The session's last
  frames were sent before it answered, so they are already queued here: they
  go first, so `idle` is the call's last frame and a fresh `call_start` never
  races the old call's `task` and `usage`.
  """
  @spec call_stop(t()) :: result()
  def call_stop(%__MODULE__{} = client) do
    client = teardown(client)
    _error_sent? = flush_queued_frames(client, false, @max_flushed_frames)
    _ = client.emit.(%{type: "state", state: "idle"})
    {:cont, client}
  end

  @doc """
  The bound session exited mid-call (its monitor, `session_ref`, fired).

  A session that ended the call on the owner's goodbye (`{:shutdown,
  :goodbye}`) already sent `call_ended`, and its exit is ordered after it: it
  is the button's end, `{:ended, client}`, nothing more is said, and the
  adapter keeps or closes its connection as after `call_stop`. Any other exit
  is a death: the peer is told, so it does not wait on silence, and the
  connection should end.
  """
  @spec session_down(t(), term()) :: {:ended | :stop, t()}
  def session_down(%__MODULE__{session: session} = client, {:shutdown, :goodbye})
      when is_pid(session) do
    _ = SessionGuard.release(client.session_guard)
    {:ended, %{client | session: nil, session_ref: nil, camera_on?: false}}
  end

  def session_down(%__MODULE__{session: session} = client, reason) when is_pid(session) do
    _ = client.emit.(error_frame({:session_down, reason}))
    _ = SessionGuard.release(client.session_guard)
    {:stop, %{client | session: nil, session_ref: nil}}
  end

  @doc """
  Tears the bound session down and releases it from the guard: an adapter's
  terminal exit runs this so a billed provider socket never outlives the
  connection, even when the guard could no longer react. A crash cannot run
  it; that path is the guard's.
  """
  @spec teardown(t()) :: t()
  def teardown(%__MODULE__{session: session} = client) when is_pid(session) do
    Process.demonitor(client.session_ref, [:flush])

    stop = fn -> {:answered, SessionGuard.teardown(session, client.session_module)} end

    case within_deadline(client, stop) do
      {:answered, :ok} -> :ok
      :past_deadline -> past_deadline(:call_stop, client)
      {:down, reason} -> Logger.warning("voice: a call's stop exited: #{inspect(reason)}")
    end

    _ = SessionGuard.release(client.session_guard)
    %{client | session: nil, session_ref: nil, camera_on?: false}
  end

  def teardown(%__MODULE__{} = client), do: client

  @doc "The wire's `error` frame for a failure reason."
  @spec error_frame(term()) :: map()
  def error_frame({:call_in_progress, held_by}) when is_binary(held_by),
    do: %{type: "error", reason: Protocol.call_in_progress(), held_by: held_by}

  def error_frame({:call_in_progress, nil}),
    do: %{type: "error", reason: Protocol.call_in_progress()}

  def error_frame(reason), do: %{type: "error", reason: reason_to_string(reason)}

  defp camera_refusal(client, on?) do
    cond do
      not camera_endpoint?(client) -> :unsupported_by_endpoint
      not Config.hands_off_tasks?(client.config) -> :unsupported_by_engine
      on? and not client.config.camera_share? -> :camera_off
      true -> nil
    end
  end

  defp camera_applied({:cont, client}, on?), do: {:cont, %{client | camera_on?: on?}}
  defp camera_applied({:stop, client}, _on?), do: {:stop, client}

  defp camera_endpoint?(client) do
    Endpoint.camera?(client.endpoint) and client.camera? and
      client.protocol_version >= @camera_min_protocol_version
  end

  defp start_call(client) do
    case ensure_session(client) do
      {:ok, client} -> session_call_start(client)
      # No session was ever started, so nothing can be queued: say the refusal
      # directly.
      {:error, reason} -> stop_with(reason, client)
    end
  end

  defp session_call_start(client) do
    case call_session(client, &client.session_module.call_start(&1)) do
      {:answered, :ok} -> {:cont, client}
      {:answered, {:error, reason}} -> flush_then_stop(reason, client)
      {:down, reason} -> flush_then_stop({:session_down, reason}, client)
    end
  end

  defp ensure_session(%{session: session} = client) when is_pid(session), do: {:ok, client}

  # The guard starts the session for this process and binds it, so it is torn
  # down on ANY adapter exit, even one in the middle of the start. The session
  # is monitored so its death reaches the adapter's loop (`session_down/2`).
  defp ensure_session(client) do
    opts =
      client.starter_opts
      |> Keyword.put(:companion, self())
      |> Keyword.put(:endpoint, client.endpoint)
      |> Keyword.put(:ends_on_goodbye, client.protocol_version >= @goodbye_min_protocol_version)
      |> Keyword.put(:session_supervisor, client.session_supervisor)
      |> Keyword.put_new(:task_supervisor, client.task_supervisor)

    guard = client.session_guard

    case SessionGuard.start_session(guard, client.session_starter, opts, client.session_module) do
      {:ok, session} -> {:ok, %{client | session: session, session_ref: Process.monitor(session)}}
      {:error, reason} -> {:error, start_refusal(reason)}
    end
  end

  defp start_refusal({:already_bound, _session}), do: :session_already_bound
  defp start_refusal(reason), do: reason

  defp command(%{session: nil} = client, _send), do: stop_with(:not_connected, client)

  defp command(client, send) do
    case call_session(client, send) do
      {:answered, :ok} -> {:cont, client}
      {:answered, {:error, reason}} -> stop_with(reason, client)
      {:down, {:shutdown, :goodbye}} -> {:cont, client}
      {:down, reason} -> flush_then_stop({:session_down, reason}, client)
    end
  end

  # A call into the session exits when the session stopped instead of
  # answering (it died, or a cancel was queued behind its settle) or did not
  # answer in time (`call_start`'s bound). Either is the session's death, told
  # the way `session_down/2` tells it, after what the session queued first,
  # instead of an adapter exit the peer would read as a bare EOF. A verb that
  # waited on a session ending the call on a goodbye is not refused: the
  # session's `call_ended` and its `:DOWN` are queued behind, and end the call
  # through `session_down/2`.
  defp call_session(client, send) do
    {:answered, send.(client.session)}
  catch
    :exit, {reason, {GenServer, :call, _args}} -> {:down, reason}
  end

  defp cancel_task(%{session: nil} = client, _delegation_id),
    do: stop_with(:not_connected, client)

  defp cancel_task(client, delegation_id) do
    cancel = &client.session_module.cancel_task(&1, delegation_id)

    case within_deadline(client, fn -> call_session(client, cancel) end) do
      {:answered, :ok} -> {:cont, client}
      {:answered, {:error, reason}} -> stop_with(reason, client)
      {:down, {:shutdown, :goodbye}} -> {:cont, client}
      {:down, reason} -> flush_then_stop({:session_down, reason}, client)
      :past_deadline -> {:cont, past_deadline(:cancel_task, client)}
    end
  end

  # The wait a verb with no timeout of its own gets: none, as SessionControl
  # waits, or the adapter's deadline, in a task the deadline kills. What the
  # session sends meanwhile stays queued in the adapter's mailbox. `wait`
  # answers `{:answered, answer}` or `{:down, reason}`.
  defp within_deadline(%{deadline_ms: :infinity}, wait), do: wait.()

  defp within_deadline(client, wait) do
    task = Task.Supervisor.async_nolink(client.task_supervisor, wait)

    case Task.yield(task, client.deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, answer} -> answer
      {:exit, reason} -> {:down, reason}
      nil -> :past_deadline
    end
  end

  defp past_deadline(verb, client) do
    Logger.warning(
      "voice: a #{Endpoint.format(client.endpoint)} call's #{verb} was not answered in " <>
        "#{client.deadline_ms} ms; the call no longer waits for it, and the session still " <>
        "handles it"
    )

    client
  end

  # The session pushes its frames to the adapter's MAILBOX, and the adapter is
  # blocked inside the call while it does, so the session's own rich `error`
  # (its published `kind`, and the vendor's words in `detail`) is sitting there
  # unwritten by the time the refusal comes back. Write what is queued first,
  # in order. If one of those frames was itself an `error`, stop on it and send
  # no second one: the peer treats the FIRST `error` as terminal, so a bare
  # `reason`-only frame would be the one it read and the diagnosis would be lost.
  defp flush_then_stop(reason, client) do
    if flush_queued_frames(client, false, @max_flushed_frames),
      do: {:stop, client},
      else: stop_with(reason, client)
  end

  # Bounded twice over: `after 0` takes only what the session has ALREADY
  # delivered, never waiting on one that is still producing, and the counter
  # caps a flood. At the cap the drain stops and the caller writes its own
  # frame as usual; on a hang-up the adapter writes whatever is left after it.
  defp flush_queued_frames(_client, error_sent?, 0), do: error_sent?

  defp flush_queued_frames(client, error_sent?, remaining) do
    receive do
      {:realtime, event} ->
        _ = client.emit.(event)
        flush_queued_frames(client, error_sent? or error_frame?(event), remaining - 1)
    after
      0 -> error_sent?
    end
  end

  defp error_frame?(%{type: "error"}), do: true
  defp error_frame?(_event), do: false

  # `min_version` here is the version the ENGINE requires, not the handshake
  # floor the adapter advertised: `required_for` names which engine raised it.
  defp update_required(client) do
    _ =
      client.emit.(%{
        type: "error",
        reason: "unsupported_protocol_version",
        kind: "update_required",
        direction: "client_too_old",
        client_version: client.protocol_version,
        min_version: engine_min_protocol_version(client.config),
        max_version: Protocol.protocol_version(),
        required_for: client.config.engine
      })

    {:stop, client}
  end

  defp stop_with(reason, client) do
    _ = client.emit.(error_frame(reason))
    {:stop, client}
  end

  # The one refusal that does not end the call: the event is answered with its
  # `error` and dropped.
  defp refuse_event(reason, client) do
    _ = client.emit.(error_frame(reason))
    {:cont, client}
  end

  defp start_session(opts) do
    session_supervisor = Keyword.fetch!(opts, :session_supervisor)
    opts = Keyword.drop(opts, [:session_supervisor])

    with {:ok, started_opts} <- session_opts(opts) do
      SessionSupervisor.start_session(session_supervisor, started_opts)
    end
  end

  defp positive_version!(version) when is_integer(version) and version > 0, do: version

  defp positive_version!(version),
    do:
      raise(
        ArgumentError,
        "protocol_version must be a positive integer, got: #{inspect(version)}"
      )

  defp deadline!(:infinity), do: :infinity
  defp deadline!(ms) when is_integer(ms) and ms > 0, do: ms

  defp deadline!(other),
    do:
      raise(
        ArgumentError,
        "deadline_ms must be :infinity or a positive integer, got: #{inspect(other)}"
      )

  # A voice key that is not saved keeps the word the wire always carried for
  # it; which provider's key is missing is readiness's to say, by name.
  defp reason_to_string({:missing_api_key, _provider}), do: "not_configured"
  # A start's crash or bad return is the guard's to log in full; the wire
  # carries the code.
  defp reason_to_string({:session_start_failed, _reason}), do: "session_start_failed"
  defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string(reason) when is_binary(reason), do: reason
  defp reason_to_string(reason), do: inspect(reason)
end
