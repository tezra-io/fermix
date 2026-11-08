defmodule FermixChannels.Mobile.Call do
  @moduledoc """
  A phone's voice call (M87): the phone's adapter of the shared voice
  component, one process per call under the mobile subtree, registered by the
  phone's device id.

  The call channel rides the phone's mobile session (`call_open`,
  `call_line`, `call_audio`, `call_close`; `priv/mobile/PROTOCOL.md`, *Calls
  from the phone*). Each `call_line` carries one object of the Realtime wire
  (`priv/realtime/PROTOCOL.md`), word for word, and audio travels as raw PCM16;
  this process converts it to and from the voice session's base64 here, and
  nowhere else. It is the `CallClient`'s adapter process, so the voice session's
  companion: the session's frames arrive in this mailbox as `{:realtime,
  event}`, and the verbs are called from here. The call's endpoint is
  `{:phone, device_id}`.

  ## The call belongs to the device, not to a session

  One mobile session is attached at a time, and frames from any other are
  dropped. A closed session, whatever its close code, detaches the call: the
  primary keeps it for a 20 s window from the detach, and the phone's next
  session re-attaches it with `call_open{resume: true}`. `call_attached` tells
  it the call's state as held here (muted, the last control applied), lines
  that came while it was away follow, and the phone re-sends any control after
  that. A control line is numbered (`control_seq`, rising per call) and states
  its result, so a repeat is dropped harmlessly. The Realtime handshake belongs
  to the call: a `client_hello` on a call whose handshake never completed is
  its first, one again at the negotiated version is answered again, and one
  at another version is refused.

  Only these end a call: the phone's `call_close` or the Realtime `call_stop`,
  a Realtime error that would close the Mac's socket, the window running out
  (`lost`), a link too slow for a call (`link_too_slow`), revocation
  (`revoked`: the call's hand-offs still running are cancelled first, since
  they run as `voice`, not as the device, and a removed phone's work must not
  finish into the chat), and an unknown device or a primary that moved on
  (`{:call_end, reason}`). A primary that restarted holds no call, so a resume
  is answered `unknown_call` (`open/5`). Nothing about a call closes the
  phone's session or its chat.

  ## The media path

  Audio going down waits in `CallAudio` (the 300 ms age bound, 500 ms of
  playback credit, 5 s behind ends the call). The phone reports
  `playback_progress` on every engine against the `playback_id` every
  `call_audio` carries: Grok's own on a Grok call, minted here (`m<n>`, a new
  one after each `playback_stop`) otherwise. A report is checked here on every
  engine as the session checks it (an unknown id, a regression, a value past
  what was sent end the call with that reason) and goes on to the session only
  on Grok. A Grok call whose audio ages out while the phone is away is
  interrupted once, cut at what was heard: Grok ends a call whose audio goes
  unacknowledged for 2 s. Audio going up that waited here 300 ms is dropped.
  Every frame goes to the session as `{:mobile_call, pid, :control | :audio,
  event}`, which the session writes ahead of everything else it has queued,
  control first (`Mobile.Session`).

  A detach and a resume go on the call's trace, the one the voice session's
  `call_ready` names: `[:fermix, :voice_live, :phone_detached]`, and
  `[:fermix, :voice_live, :phone_resumed]` whose `duration_ms` is the gap.

  ## Staying responsive

  The mobile session never waits on this process: everything reaches it as a
  message, so a call that blocks cannot hold up the phone's socket or its
  chat. What this process itself waits on is bounded: `call_start` by the
  guard's start bound and `SessionControl`'s, and `cancel_task` and
  `call_stop`, which wait without a timeout of their own, by the client's
  deadline (`CallClient`, `deadline_ms`). A crash or a kill of this process
  leaves its session to `SessionGuard`, which tears it down and so frees the
  home's call.
  """

  use GenServer, restart: :temporary

  require Logger

  alias FermixChannels.Mobile.CallAudio
  alias FermixCore.Realtime.CallClient
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.Endpoint
  alias FermixCore.Realtime.LiveTelemetry
  alias FermixCore.Realtime.Protocol
  alias FermixCore.Realtime.SessionGuard

  @calls FermixChannels.Mobile.Calls
  @call_supervisor FermixChannels.Mobile.CallSupervisor
  @window_ms 20_000
  @deadline_ms 20_000
  @max_held_lines 512
  @max_emitted 256
  @task_unsettled ~w(pending running)
  # What a client may give a call besides the device, the call and its session.
  @client_opts [:session_module, :session_starter, :session_supervisor, :session_guard]

  @typedoc "Where a call's frames go: a phone's mobile session."
  @type session :: pid()

  @typedoc "Why a call channel ended, as `call_close.reason` says it."
  @type ending :: String.t()

  # -- the mobile session's side ------------------------------------------------

  @doc """
  What a phone's `hello_ack` says of calls (`caps.call`): whether this primary
  serves one, why not when it does not, the Realtime version window a call
  needs (`min_version` is the configured engine's floor), and that it takes no
  camera yet.
  """
  @spec caps(String.t()) :: map()
  def caps(device_id) when is_binary(device_id),
    do: caps(Config.current(), voice_running?(SessionGuard), device_id)

  @doc "`caps/1` for a given config and runtime, pure."
  @spec caps(Config.t(), boolean(), String.t()) :: map()
  def caps(%Config{} = config, running?, device_id)
      when is_boolean(running?) and is_binary(device_id) do
    base = %{
      "min_version" => CallClient.engine_min_protocol_version(config),
      "max_version" => Protocol.protocol_version(),
      "camera" => false
    }

    with :ok <- readiness(config, running?),
         :ok <- Endpoint.admit_engine({:phone, device_id}, config.engine) do
      Map.put(base, "available", true)
    else
      {:error, reason} -> Map.merge(base, %{"available" => false, "reason" => to_string(reason)})
    end
  end

  @doc """
  Whether Talk to Fermix serves a call here now: on in the settings, its key
  present, and its runtime running (a setting turned on waits for a restart).
  Read at `hello_ack` and again at every `call_open`.
  """
  @spec readiness(Config.t(), boolean()) :: :ok | {:error, :voice_off | :no_key}
  def readiness(%Config{} = config, running?) when is_boolean(running?) do
    cond do
      not config.enabled? -> {:error, :voice_off}
      not Config.api_key_present?(config) -> {:error, :no_key}
      not running? -> {:error, :voice_off}
      true -> :ok
    end
  end

  @doc """
  A phone's `call_open`: hands it to the device's call, starting one for a
  new call. A resume of a call this primary does not hold (it restarted, or
  the window ran out) is answered `{:close, "unknown_call"}` for the session
  to write. `opts`: `:calls` and `:call_supervisor` (the registry and the
  supervisor), and `:call_options` given each new call.
  """
  @spec open(String.t(), session(), String.t(), boolean(), keyword()) ::
          :ok | {:close, ending()}
  def open(device_id, session, call_id, resume?, opts)
      when is_binary(device_id) and is_pid(session) and is_binary(call_id) and
             is_boolean(resume?) and is_list(opts) do
    case lookup(calls(opts), device_id) do
      {:ok, call} -> tell(call, {:call_open, session, call_id, resume?})
      :none when resume? -> {:close, "unknown_call"}
      :none -> start(device_id, session, call_id, opts)
    end
  end

  @doc """
  A phone's `call_line`, `call_audio` or `call_close`, handed to the device's
  call with when the session read it. With no call, a `call_close` is answered
  `{:close, "unknown_call"}` and anything else is dropped.
  """
  @spec deliver(String.t(), session(), String.t(), map(), binary(), keyword()) ::
          :ok | {:close, ending()}
  def deliver(device_id, session, type, header, bytes, opts)
      when is_binary(device_id) and is_pid(session) and is_binary(type) and is_map(header) and
             is_binary(bytes) and is_list(opts) do
    at = Keyword.get(opts, :clock, &monotonic_ms/0).()

    case lookup(calls(opts), device_id) do
      {:ok, call} -> tell(call, {:call_frame, session, type, header, bytes, at})
      :none when type == "call_close" -> {:close, "unknown_call"}
      :none -> :ok
    end
  end

  @doc """
  Tells the device's call, if it has one, that it cannot go on: `{:mobile_revoked,
  device_id}` (the device was removed) or `{:call_end, reason}` (an unknown
  device, a primary that moved on). A registry that does not run holds no call.
  """
  @spec notify(GenServer.server(), String.t(), term()) :: :ok
  def notify(calls \\ @calls, device_id, message) when is_binary(device_id) do
    case lookup(calls, device_id) do
      {:ok, call} -> tell(call, message)
      :none -> :ok
    end
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    name = {:via, Registry, {Keyword.fetch!(opts, :calls), Keyword.fetch!(opts, :device_id)}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  defp start(device_id, session, call_id, opts) do
    spec =
      {__MODULE__,
       Keyword.merge(Keyword.get(opts, :call_options, []),
         calls: calls(opts),
         device_id: device_id,
         call_id: call_id
       )}

    case DynamicSupervisor.start_child(
           Keyword.get(opts, :call_supervisor, @call_supervisor),
           spec
         ) do
      {:ok, call} -> tell(call, {:call_open, session, call_id, false})
      {:error, {:already_started, call}} -> tell(call, {:call_open, session, call_id, false})
      {:error, reason} -> refused_start(device_id, reason)
    end
  end

  defp refused_start(device_id, reason) do
    Logger.error("voice: a call from phone #{device_id} could not start: #{inspect(reason)}")
    {:close, "ended"}
  end

  defp lookup(calls, device_id) do
    if GenServer.whereis(calls) do
      case Registry.lookup(calls, device_id) do
        [{call, _value}] -> {:ok, call}
        [] -> :none
      end
    else
      :none
    end
  end

  defp tell(call, message) do
    send(call, message)
    :ok
  end

  defp calls(opts), do: Keyword.get(opts, :calls, @calls)

  # -- the call -------------------------------------------------------------------

  @impl true
  def init(opts) do
    device_id = Keyword.fetch!(opts, :device_id)

    {:ok,
     %{
       device_id: device_id,
       call_id: Keyword.fetch!(opts, :call_id),
       endpoint: {:phone, device_id},
       config: nil,
       client: nil,
       attached: nil,
       window: nil,
       control_seq: 0,
       muted?: false,
       held_lines: :queue.new(),
       held_count: 0,
       audio: CallAudio.new(),
       minted: 1,
       detach_interrupted?: false,
       delegations: %{},
       trace: nil,
       detached_at: nil,
       clock: Keyword.get(opts, :clock, &monotonic_ms/0),
       config_source: Keyword.get(opts, :config, &Config.current/0),
       ready: Keyword.get(opts, :ready, &readiness(&1, voice_running?(SessionGuard))),
       window_ms: Keyword.get(opts, :window_ms, @window_ms),
       deadline_ms: Keyword.get(opts, :deadline_ms, @deadline_ms),
       task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.Realtime.TaskSupervisor),
       client_opts: Keyword.take(opts, @client_opts)
     }}
  end

  @impl true
  def handle_info({:call_open, session, call_id, resume?}, state),
    do: open_call(session, call_id, resume?, state)

  def handle_info({:call_frame, session, "call_close", %{"call_id" => id}, _bytes, _at}, state),
    do: close_from(session, id, state)

  def handle_info({:call_frame, session, type, %{"call_id" => id} = header, bytes, at}, state) do
    if attached_session?(state, session) and id == state.call_id,
      do: phone_frame(type, header, bytes, at, state),
      else: {:noreply, state}
  end

  def handle_info({:realtime, event}, state), do: {:noreply, deliver_server_event(state, event)}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state), do: down(ref, reason, state)

  def handle_info({:window_expired, token}, %{window: %{token: token}} = state),
    do: finish(state, "lost")

  def handle_info({:mobile_revoked, _device_id}, state), do: revoke(state)

  def handle_info({:call_end_now, ending}, state), do: finish(state, ending)

  def handle_info({:call_end, reason}, state) do
    Logger.info("voice: phone #{state.device_id}'s call ended: #{inspect(reason)}")
    finish(state, "ended")
  end

  def handle_info(message, state) do
    Logger.debug("voice: a phone call ignored #{inspect(message, limit: 5)}")
    {:noreply, state}
  end

  # -- opening and attaching ----------------------------------------------------------

  defp open_call(session, call_id, false, %{config: nil, call_id: call_id} = state) do
    config = state.config_source.()

    case state.ready.(config) do
      :ok -> {:noreply, attach(%{state | config: config}, session, false)}
      {:error, reason} -> refuse_open(session, call_id, reason, state)
    end
  end

  defp open_call(session, call_id, _resume?, %{call_id: call_id} = state),
    do: {:noreply, attach(state, session, true)}

  defp open_call(session, call_id, true, state) do
    send_control(session, close_event(call_id, "unknown_call"))
    {:noreply, state}
  end

  # One call per phone: a second while this one runs is told where the call is.
  defp open_call(session, call_id, false, state) do
    held_by = Endpoint.format(state.endpoint)

    send_control(
      session,
      line_event(call_id, CallClient.error_frame({:call_in_progress, held_by}))
    )

    send_control(session, close_event(call_id, "ended"))
    {:noreply, state}
  end

  defp refuse_open(session, call_id, reason, state) do
    send_control(session, line_event(call_id, CallClient.error_frame(reason)))
    send_control(session, close_event(call_id, "ended"))
    {:stop, :normal, state}
  end

  defp attach(state, session, resumed?) do
    :ok = report_resume(state)
    state = state |> release_attached() |> cancel_window()
    ref = Process.monitor(session)

    state = %{
      state
      | attached: %{session: session, ref: ref},
        detach_interrupted?: false,
        detached_at: nil
    }

    send_control(session, %{
      "t" => "call_attached",
      "call_id" => state.call_id,
      "resumed" => resumed?,
      "muted" => state.muted?,
      "camera" => false,
      "control_seq" => state.control_seq
    })

    state |> release_held_lines() |> pump()
  end

  defp release_attached(%{attached: %{ref: ref}} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    %{state | attached: nil}
  end

  defp release_attached(state), do: %{state | attached: nil}

  defp release_held_lines(%{attached: %{session: session}} = state) do
    state.held_lines |> :queue.to_list() |> Enum.each(&send_control(session, &1))
    %{state | held_lines: :queue.new(), held_count: 0}
  end

  defp detach(state) do
    token = make_ref()
    timer = Process.send_after(self(), {:window_expired, token}, state.window_ms)
    :ok = trace_gap(state, &LiveTelemetry.phone_detached/1)

    %{
      state
      | attached: nil,
        window: %{token: token, timer: timer},
        detached_at: state.clock.()
    }
  end

  defp report_resume(%{detached_at: at} = state) when is_integer(at) do
    gap_ms = max(state.clock.() - at, 0)
    Logger.info("voice: phone #{state.device_id}'s call resumed after #{gap_ms} ms away")
    trace_gap(state, &LiveTelemetry.phone_resumed(&1, gap_ms))
  end

  defp report_resume(_state), do: :ok

  # A phone's gap goes on the voice session's trace, which its `call_ready`
  # named; a call whose session has not started has none, and the log line is
  # the record.
  defp trace_gap(%{trace: nil}, _emit), do: :ok

  defp trace_gap(state, emit) do
    emit.(%{
      session_id: state.trace.session_id,
      call_uuid: state.trace.call_uuid,
      engine: state.config.engine,
      provider: state.config.provider,
      model: state.config.model,
      voice: state.config.voice,
      endpoint: Endpoint.format(state.endpoint)
    })
  end

  defp cancel_window(%{window: %{timer: timer}} = state) do
    _remaining = Process.cancel_timer(timer)
    %{state | window: nil}
  end

  defp cancel_window(state), do: state

  defp attached_session?(%{attached: %{session: session}}, session), do: true
  defp attached_session?(_state, _session), do: false

  defp down(ref, _reason, %{attached: %{ref: ref}} = state) do
    Logger.info("voice: phone #{state.device_id}'s session closed; its call waits to resume")
    {:noreply, detach(state)}
  end

  defp down(ref, reason, %{client: %CallClient{session_ref: ref} = client} = state) do
    {:stop, client} = CallClient.session_down(client, reason)
    state = drain_emitted(%{state | client: client}, @max_emitted)
    close(state, "ended")
  end

  defp down(_ref, _reason, state), do: {:noreply, state}

  # -- the phone's frames ---------------------------------------------------------------

  defp phone_frame("call_line", header, bytes, _at, state) do
    case Map.get(header, "control_seq") do
      seq when is_integer(seq) and seq <= state.control_seq -> {:noreply, state}
      seq -> state |> put_control_seq(seq) |> phone_line(bytes)
    end
  end

  defp phone_frame("call_audio", _header, pcm, at, state) do
    cond do
      state.clock.() - at >= CallAudio.max_age_ms() ->
        {:noreply, state}

      match?(%CallClient{session: session} when is_pid(session), state.client) ->
        audio_up(pcm, state)

      true ->
        {:noreply, state}
    end
  end

  defp put_control_seq(state, seq) when is_integer(seq), do: %{state | control_seq: seq}
  defp put_control_seq(state, nil), do: state

  defp audio_up(pcm, state) do
    case run_client(state, &CallClient.audio(&1, pcm)) do
      {:cont, state} -> {:noreply, state}
      {:stop, state} -> end_on_error(state)
    end
  end

  defp phone_line(state, bytes) do
    case Protocol.decode_client_event(bytes, state.config) do
      {:ok, event} -> line(event, state)
      {:error, reason} -> refuse_line(reason, state)
    end
  end

  defp line(
         %{type: "client_hello", payload: %{"protocol_version" => version}},
         %{client: nil} = state
       ) do
    case Protocol.hello_reply(version) do
      {:ok, reply} -> {:noreply, state |> send_line(reply) |> new_client(version)}
      {:error, refusal} -> state |> send_line(refusal) |> close("ended")
    end
  end

  # A link can drop with the handshake in flight, so the phone sends it again
  # on resume when it never saw `server_hello`: the negotiated version again is
  # answered again; any other is refused.
  defp line(
         %{type: "client_hello", payload: %{"protocol_version" => version}},
         %{client: %CallClient{protocol_version: version}} = state
       ) do
    {:ok, reply} = Protocol.hello_reply(version)
    {:noreply, send_line(state, reply)}
  end

  defp line(%{type: "client_hello"}, state), do: refuse_line(:unexpected_client_hello, state)
  defp line(_event, %{client: nil} = state), do: refuse_line(:handshake_required, state)
  defp line(%{type: "audio_chunk"}, state), do: refuse_line(:audio_on_call_line, state)

  # Credit on every engine, checked as the session checks it; on to the
  # session only on Grok, whose ids these are.
  defp line(%{type: "playback_progress", payload: payload} = event, state) do
    %{"playback_id" => id, "played_ms" => played, "drained" => drained?} = payload

    case CallAudio.progress(state.audio, id, played, drained?) do
      {:ok, audio} -> forward_progress(event, pump(%{state | audio: audio}))
      {:error, reason} -> refuse_line(reason, state)
    end
  end

  defp line(%{type: "mute", payload: payload} = event, state) do
    case run_client(state, &CallClient.event(&1, event)) do
      {:cont, state} -> {:noreply, %{state | muted?: Map.get(payload, "enabled", true) == true}}
      {:stop, state} -> end_on_error(state)
    end
  end

  defp line(%{type: "call_stop"} = event, state) do
    {_verdict, state} = run_client(state, &CallClient.event(&1, event))
    close(state, "ended")
  end

  defp line(event, state), do: client_event(event, state)

  defp forward_progress(event, %{config: %{engine: "xai_realtime"}} = state),
    do: client_event(event, state)

  defp forward_progress(_event, state), do: {:noreply, state}

  defp client_event(event, state) do
    case run_client(state, &CallClient.event(&1, event)) do
      {:cont, state} -> {:noreply, state}
      {:stop, state} -> end_on_error(state)
    end
  end

  defp refuse_line(reason, state) do
    state |> send_line(CallClient.error_frame(reason)) |> end_on_error()
  end

  defp new_client(state, version) do
    call = self()

    client =
      state.client_opts
      |> Keyword.merge(
        endpoint: state.endpoint,
        protocol_version: version,
        config: state.config,
        emit: fn event ->
          send(call, {:call_emitted, event})
          :ok
        end,
        task_supervisor: state.task_supervisor,
        deadline_ms: state.deadline_ms
      )
      |> CallClient.new()

    %{state | client: client}
  end

  # A verb runs here, in the call's own process; what it emitted, and what the
  # session queued that it flushed, is read back in order before anything else.
  defp run_client(state, verb) do
    {verdict, client} = verb.(state.client)
    {verdict, drain_emitted(%{state | client: client}, @max_emitted)}
  end

  defp drain_emitted(state, 0), do: state

  defp drain_emitted(state, remaining) do
    receive do
      {:call_emitted, event} ->
        state |> deliver_server_event(event) |> drain_emitted(remaining - 1)
    after
      0 -> state
    end
  end

  # -- the session's frames, on their way down ---------------------------------------------

  defp deliver_server_event(state, %{type: "audio_delta", audio: audio} = event) do
    with {:ok, pcm} <- Base.decode64(audio),
         {:ok, queued} <-
           CallAudio.put(state.audio, playback_id(state, event), pcm, state.clock.()) do
      pump(%{state | audio: queued})
    else
      _invalid ->
        Logger.warning("voice: phone #{state.device_id}'s call dropped audio that was not PCM16")
        state
    end
  end

  defp deliver_server_event(state, %{type: "call_ready", call_id: id} = event) do
    %{state | trace: %{session_id: id, call_uuid: Map.get(event, :call_uuid)}}
    |> send_line(event)
  end

  defp deliver_server_event(state, %{type: "playback_stop"} = event) do
    %{state | audio: CallAudio.clear(state.audio), minted: state.minted + 1} |> send_line(event)
  end

  defp deliver_server_event(state, %{type: "task", delegation_id: id, status: status} = event) do
    %{state | delegations: Map.put(state.delegations, id, status)} |> send_line(event)
  end

  defp deliver_server_event(state, event), do: send_line(state, event)

  defp playback_id(_state, %{playback_id: id}) when is_binary(id), do: id
  defp playback_id(state, _event), do: "m#{state.minted}"

  defp send_line(state, event) do
    case encode_line(event) do
      {:ok, json} -> control(state, line_event(state.call_id, json))
      {:error, reason} -> unsent_line(state, event, reason)
    end
  end

  defp unsent_line(state, event, reason) do
    Logger.error(
      "voice: phone #{state.device_id}'s call could not carry a #{inspect(event[:type])} " <>
        "frame: #{inspect(reason)}"
    )

    state
  end

  defp encode_line(%{type: type} = event) do
    with {:ok, line} <- Protocol.encode_server_event(type, Map.delete(event, :type)) do
      {:ok, String.trim_trailing(line, "\n")}
    end
  end

  defp control(%{attached: %{session: session}} = state, event) do
    send_control(session, event)
    state
  end

  defp control(state, event) do
    held = :queue.in(event, state.held_lines)

    if state.held_count < @max_held_lines,
      do: %{state | held_lines: held, held_count: state.held_count + 1},
      else: %{state | held_lines: elem(:queue.out(held), 1)}
  end

  defp pump(state) do
    now = state.clock.()
    {audio, frames, dropped} = CallAudio.take(state.audio, now, state.attached != nil)
    state = %{state | audio: audio}
    Enum.each(frames, &send_audio(state, &1))

    cond do
      CallAudio.too_slow?(audio, now) -> link_too_slow(state)
      dropped > 0 and state.attached == nil -> interrupt_unheard(state)
      true -> state
    end
  end

  defp send_audio(%{attached: %{session: session}} = state, {playback_id, pcm}) do
    send(
      session,
      {:mobile_call, self(), :audio,
       %{
         "t" => "call_audio",
         "call_id" => state.call_id,
         "playback_id" => playback_id,
         "bytes" => pcm
       }}
    )
  end

  # Grok paces its audio by the phone's reports and ends a call whose audio
  # goes unacknowledged for 2 s; audio a detached phone never heard is
  # interrupted, once a detach, cut at what was heard.
  defp interrupt_unheard(%{detach_interrupted?: false, config: %{engine: "xai_realtime"}} = state) do
    {_verdict, state} =
      run_client(%{state | detach_interrupted?: true}, &CallClient.interrupt(&1, nil))

    state
  end

  defp interrupt_unheard(state), do: state

  # The link is too slow for a call: it ends, the session stays up. Pumping
  # happens inside handlers that go on, so the end is a message to self.
  defp link_too_slow(state) do
    send(self(), {:call_end_now, "link_too_slow"})
    state
  end

  # -- ending ------------------------------------------------------------------------------------

  defp close_from(session, call_id, %{call_id: call_id} = state) do
    if state.attached == nil or attached_session?(state, session) do
      state = %{release_attached(state) | attached: %{session: session, ref: nil}}
      close(stop_session(state), "ended")
    else
      {:noreply, state}
    end
  end

  defp close_from(session, call_id, state) do
    send_control(session, close_event(call_id, "unknown_call"))
    {:noreply, state}
  end

  defp revoke(state) do
    Logger.info("voice: phone #{state.device_id} was removed; its call ends")
    state = state |> mute_for_good() |> cancel_unsettled()
    finish(state, "revoked")
  end

  defp mute_for_good(%{client: %CallClient{session: session}} = state) when is_pid(session) do
    {_verdict, state} = run_client(state, &CallClient.mute(&1, true))
    state
  end

  defp mute_for_good(state), do: state

  # Waiting ones first: cancelling the running one starts the one behind it.
  defp cancel_unsettled(%{client: %CallClient{session: session}} = state) when is_pid(session) do
    {pending, running} =
      state.delegations
      |> Enum.filter(fn {_id, status} -> status in @task_unsettled end)
      |> Enum.split_with(fn {_id, status} -> status == "pending" end)

    Enum.reduce(pending ++ running, state, fn {id, _status}, state ->
      {_verdict, state} = run_client(state, &CallClient.task_cancel(&1, id))
      state
    end)
  end

  defp cancel_unsettled(state), do: state

  defp finish(state, ending) do
    state = stop_session(state)

    # Why it ended goes first, as the Realtime error, when the session's own
    # frames cannot say it.
    state =
      if ending in ["link_too_slow", "revoked"],
        do: send_line(state, CallClient.error_frame(ending)),
        else: state

    close(state, ending)
  end

  defp end_on_error(state) do
    state = %{state | client: state.client && CallClient.teardown(state.client)}
    close(state, "ended")
  end

  defp stop_session(%{client: %CallClient{session: session}} = state) when is_pid(session) do
    {_verdict, state} = run_client(state, &CallClient.call_stop/1)
    state
  end

  defp stop_session(state), do: state

  defp close(state, ending) do
    _state = control(state, close_event(state.call_id, ending))
    {:stop, :normal, state}
  end

  defp line_event(call_id, json) when is_binary(json),
    do: %{"t" => "call_line", "call_id" => call_id, "bytes" => json}

  defp line_event(call_id, frame) when is_map(frame) do
    {:ok, json} = encode_line(frame)
    line_event(call_id, json)
  end

  defp close_event(call_id, ending),
    do: %{"t" => "call_close", "call_id" => call_id, "reason" => ending}

  defp send_control(session, event) do
    send(session, {:mobile_call, self(), :control, event})
    :ok
  end

  defp voice_running?(guard), do: not is_nil(GenServer.whereis(guard))

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
