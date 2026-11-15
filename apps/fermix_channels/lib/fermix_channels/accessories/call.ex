defmodule FermixChannels.Accessories.Call do
  @moduledoc """
  One accessory call (M91 §04-§06): the per-call process that owns the call's
  `FermixCore.Realtime.CallClient`, with endpoint `accessory:<accessory_id>`
  and the realtime protocol level this adapter translates (the current one,
  so every engine's frames are rendered). Started and linked by the
  accessory's link, so it can block on its session's start while the link
  keeps reading; it traps exits, so the link's end, however it ends, tears
  its session down, and `SessionGuard` does the same should this process
  itself die.

  Engine to accessory:

    * `state` → `call.state`, once per change; a reply ending (the state
      leaving `speaking`) closes the reply's speaker segment.
    * `audio_delta` → `spk.begin`, speaker PCM and `spk.end`, within credit
      (`Call.Speaker`); `playback_stop` → `spk.flush` (URGENT), when there is
      anything to flush.
    * a GPT-Live or Grok `task`, and OpenAI Realtime's `tool_event`s and its
      reconnects → `task.event` (`FermixCore.Accessories.Tasks`, M91 D21).
    * `error`, or the session ending → the call ends. A session that ended
      the call itself (`call_ended`, the owner's goodbye, M96 §6.2) ends it
      with that reason, once the session has gone: the robot hears
      `call.end {reason: "goodbye"}`.

  Accessory to engine:

    * five 960-byte microphone frames → one 4,800-byte chunk (`audio`), with
      the gaps in their sequence numbers counted and the audio used, and
      each chunk's RMS level kept for the call's link event (the loudest,
      the mean, and the silent chunks), so a call that heard nothing says
      whether the robot sent silence;
    * `spk.flushed` → `interrupt(played_ms)`; `playback.progress` → Grok's
      `playback_progress`; `mic.state` → `mute`; `call.end_request` → the end.

  The Mac (M91 E3): every engine frame and mute is also folded into the
  call's `Call.View` (the voice it started with, its state, transcript lines,
  tasks and usage), sent to the link as `{:call_view, stream, call_id, view}`
  at each change, from the call's start; `accessories.status` reads it there.

  A refused start becomes `call.result refused` with the refusal's code (the
  lease's `call_in_progress` among them) before any `call.start`. A
  call-ending fault (`credit_overgrant`, `segment_limit` and the rest, or
  two minutes of audio held for want of credit) ends the call cleanly. As it
  ends, its link counters are reported under the call's session id
  (`[:fermix, :accessory, :call_link]`), then the session is torn down; the
  link tells the accessory `call.end`.
  """

  use GenServer, restart: :temporary

  alias FermixChannels.Accessories.Call.Speaker
  alias FermixChannels.Accessories.Call.View
  alias FermixCore.Accessories.Tasks
  alias FermixCore.Accessories.Telemetry
  alias FermixCore.Realtime.CallClient
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.Endpoint
  alias FermixCore.Realtime.Protocol
  alias FermixCore.Realtime.SessionControl

  require Logger

  @mic_chunk_bytes 4_800
  # A chunk whose RMS is under this is silence, not speech.
  @silent_rms 50
  @seq_modulus 4_294_967_296
  @call_states ~w(connecting listening thinking speaking muted reconnecting)
  @robot_errors %{
    "credit_overgrant" => :credit_overgrant,
    "credit_exceeded" => :credit_exceeded,
    "segment_limit" => :segment_limit,
    "segment_sequence" => :segment_sequence
  }
  # The robot's `diag.counters`, each under its own name in the call's link
  # event (`FermixCore.Accessories.Telemetry`).
  @robot_counters %{
    uptime_s: :robot_uptime_s,
    frames_rx: :robot_frames_rx,
    frames_tx: :robot_frames_tx,
    crc_errors: :robot_crc_errors,
    resync_bytes: :robot_resync_bytes,
    pcm_seq_gaps: :robot_pcm_seq_gaps,
    mic_overflows: :robot_mic_overflows,
    spk_underflows: :robot_spk_underflows
  }
  # The robot's levels of its latest microphone opening, beside them.
  @robot_levels %{
    mic_rms: :robot_mic_rms,
    mic_peak: :robot_mic_peak,
    ref_rms: :robot_ref_rms,
    ref_peak: :robot_ref_peak,
    out_rms: :robot_out_rms,
    out_peak: :robot_out_peak
  }
  # Why a session ended a call itself (`call_ended.reason`, M96): each is the
  # call's end reason and the robot's `call.end` reason.
  @ended_reasons %{"goodbye" => :goodbye}
  @client_opts [:session_module, :session_starter, :session_supervisor, :session_guard]
  @token ~r/\A[a-z][a-z0-9_]{0,47}\z/

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    config = Keyword.get_lazy(opts, :config, &Config.current/0)

    state = %{
      link: Keyword.fetch!(opts, :link),
      stream: Keyword.fetch!(opts, :stream),
      request: Keyword.get(opts, :request),
      source: Keyword.fetch!(opts, :source),
      endpoint: Keyword.fetch!(opts, :endpoint),
      config: config,
      opts: opts,
      clock: clock,
      utc_now: Keyword.get(opts, :utc_now, &DateTime.utc_now/0),
      started_ms: clock.(),
      client: nil,
      session_id: SessionControl.session_scope(config),
      view: View.new(config),
      speaker: Speaker.new(),
      tasks: Tasks.new(),
      mic: <<>>,
      mic_seq: nil,
      mic_live?: false,
      mic_level: %{max: 0, total: 0},
      robot_diag: Keyword.get(opts, :robot_diag),
      robot_levels: %{},
      engine_muted?: false,
      sent_state: nil,
      # Why the session ended the call itself (`call_ended`), until it goes.
      ended_reason: nil,
      counters: %{
        mic_frames: 0,
        mic_chunks: 0,
        pcm_seq_gaps: 0,
        task_events: 0,
        task_faults: 0,
        mic_frames_before_live: 0,
        mic_chunks_silent: 0,
        interrupts: 0,
        interrupt_played_ms_total: 0
      }
    }

    publish(state)
    {:ok, state, {:continue, :start}}
  end

  # -- the start ------------------------------------------------------------------------

  @impl true
  def handle_continue(:start, state) do
    client = new_client(state, state.session_id)

    case CallClient.call_start(client) do
      {:cont, client} -> {:noreply, accepted(%{state | client: client})}
      {:stop, client} -> refused(state, client)
    end
  end

  defp new_client(state, session_id) do
    me = self()

    state.opts
    |> Keyword.take(@client_opts)
    |> Keyword.merge(
      endpoint: state.endpoint,
      protocol_version: Protocol.protocol_version(),
      config: state.config,
      emit: fn event ->
        send(me, {:emitted, event})
        :ok
      end,
      task_supervisor:
        Keyword.get(state.opts, :task_supervisor, FermixCore.Realtime.TaskSupervisor),
      starter_opts: [session_scope: session_id]
    )
    |> CallClient.new()
  end

  # Admitted: the accessory hears the result (for its own request), the call's
  # stream, and that it is connecting; the session's own frames follow.
  defp accepted(state) do
    if state.request,
      do: to_link(state, %{type: "call.result", request: state.request, result: "accepted"})

    to_link(state, %{type: "call.start", stream: state.stream, call: state.session_id})
    state |> viewed(&View.admitted(&1, state.utc_now.())) |> send_state("connecting")
  end

  # A session that started and then refused the call is torn down here, the
  # prompt path; the guard would on this process's exit anyway.
  defp refused(state, client) do
    _client = CallClient.teardown(client)
    error = first_error()
    code = refusal_code(error)
    held_by = if held = Map.get(error, :held_by), do: " (the call is at #{held})", else: ""
    Logger.info("accessory call #{state.stream} was refused: #{code}#{held_by}")

    if state.request,
      do:
        to_link(state, %{
          type: "call.result",
          request: state.request,
          result: "refused",
          code: code
        })

    {:stop, {:shutdown, {:refused, code}}, state}
  end

  # What the refusal said, as the call client wrote it. The client wrote
  # everything the session had queued first, so only the error is wanted.
  defp first_error do
    receive do
      {:emitted, %{type: "error"} = error} -> error
    after
      0 -> %{}
    end
  end

  defp refusal_code(%{kind: kind}) when is_binary(kind), do: token(kind, "call_refused")
  defp refusal_code(%{reason: reason}) when is_binary(reason), do: token(reason, "call_refused")
  defp refusal_code(_error), do: "call_refused"

  # -- the call -------------------------------------------------------------------------

  @impl true
  def handle_info({:realtime, event}, state),
    do: on_engine(viewed(state, &View.engine(&1, event)), event)

  def handle_info({:emitted, event}, state),
    do: on_engine(viewed(state, &View.engine(&1, event)), event)

  def handle_info({:robot, message}, state), do: on_robot(state, message)
  def handle_info({:mic, seq, pcm}, state), do: {:noreply, on_mic(state, seq, pcm)}

  def handle_info({:robot_diag, counters, levels}, state),
    do: {:noreply, %{state | robot_diag: counters, robot_levels: levels}}

  def handle_info({:robot_error, code}, state),
    do: finish(state, Map.fetch!(@robot_errors, code))

  def handle_info({:end, reason}, state) when is_atom(reason), do: finish(state, reason)
  def handle_info({:mute, muted?}, state), do: mac_mute(state, muted?)
  def handle_info(:interrupt, state), do: {:noreply, flush(state)}

  def handle_info({:cancel_task, delegation_id}, state),
    do: verb(state, &CallClient.task_cancel(&1, delegation_id))

  def handle_info(
        {:DOWN, ref, :process, _session, reason},
        %{client: %{session_ref: ref}} = state
      ) do
    case CallClient.session_down(state.client, reason) do
      {:ended, client} -> finish(%{state | client: client}, state.ended_reason || :call_ended)
      {:stop, client} -> finish(%{state | client: client}, :session_ended)
    end
  end

  # The link went, however it went: the session goes with it.
  def handle_info({:EXIT, link, _reason}, %{link: link} = state), do: finish(state, :link_gone)
  def handle_info({:EXIT, _other, _reason}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Logger.debug("accessory call ignored an unexpected message: #{inspect(message, limit: 8)}")
    {:noreply, state}
  end

  # -- engine to accessory ----------------------------------------------------------------

  defp on_engine(state, %{type: "state", state: value}),
    do: {:noreply, engine_state(state, value)}

  defp on_engine(state, %{type: "audio_delta", audio: audio} = delta) do
    case Base.decode64(audio) do
      {:ok, pcm} -> speak(state, pcm, Map.get(delta, :playback_id))
      :error -> bad_audio(state)
    end
  end

  defp on_engine(state, %{type: "playback_stop"}), do: {:noreply, flush(state)}
  defp on_engine(state, %{type: "task"} = frame), do: {:noreply, task_frame(state, frame)}
  defp on_engine(state, %{type: "tool_event"} = event), do: {:noreply, tool_event(state, event)}

  defp on_engine(state, %{type: "error"} = error),
    do: finish(state, :session_error, error_reason(error))

  # Only recorded: the session is still settling, and its exit ends the call
  # (a teardown from here would wait on that settle).
  defp on_engine(state, %{type: "call_ended", reason: reason}) when is_binary(reason),
    do: {:noreply, %{state | ended_reason: Map.get(@ended_reasons, reason, :call_ended)}}

  defp on_engine(state, _event), do: {:noreply, state}

  defp bad_audio(state) do
    Logger.error("accessory call #{state.stream}: the engine sent audio that is not base64")
    {:noreply, state}
  end

  # `idle` is the session ending; its end arrives as its exit.
  defp engine_state(state, "idle"), do: state

  defp engine_state(state, value) when value in @call_states do
    state =
      if state.sent_state == "speaking" and value != "speaking",
        do: reply_ended(state),
        else: state

    state = if value == "reconnecting", do: reconnected(state), else: state
    send_state(state, value)
  end

  defp engine_state(state, value) do
    Logger.debug("accessory call: no call.state for the engine's #{inspect(value)}")
    state
  end

  defp send_state(%{sent_state: value} = state, value), do: state

  defp send_state(state, value) do
    to_link(state, %{type: "call.state", stream: state.stream, state: value})
    %{state | sent_state: value}
  end

  defp reply_ended(state), do: pump(%{state | speaker: Speaker.reply_ended(state.speaker)})

  defp speak(state, pcm, playback_id) do
    case Speaker.audio(state.speaker, pcm, playback_id) do
      {:ok, speaker} -> {:noreply, pump(%{state | speaker: speaker})}
      {:error, :speaker_backlog} -> finish(state, :speaker_backlog)
    end
  end

  defp pump(state) do
    {out, speaker} = Speaker.pump(state.speaker)
    Enum.each(out, &speaker_out(state, &1))
    %{state | speaker: speaker}
  end

  defp speaker_out(state, {:begin, segment, playback_id}),
    do:
      to_link(state, %{
        type: "spk.begin",
        stream: state.stream,
        segment: segment,
        playback_id: playback_id
      })

  defp speaker_out(state, {:pcm, pcm}), do: send(state.link, {:call_pcm, state.stream, pcm})

  defp speaker_out(state, {:end, segment}),
    do: to_link(state, %{type: "spk.end", stream: state.stream, segment: segment})

  defp flush(state) do
    case Speaker.flush(state.speaker) do
      {true, speaker} ->
        to_link(state, %{type: "spk.flush", stream: state.stream}, true)
        %{state | speaker: speaker}

      {false, speaker} ->
        %{state | speaker: speaker}
    end
  end

  defp task_frame(state, frame) do
    case Tasks.from_task_frame(frame) do
      {:ok, event} -> task_events(state, [event])
      :skip -> state
      {:error, field} -> task_fault(state, {:task_frame, field})
    end
  end

  # OpenAI Realtime's tool batches are tasks the Mac shows too (D21).
  defp tool_event(state, event) do
    case Tasks.tool_event(state.tasks, event) do
      {:ok, events, tasks} ->
        %{state | tasks: tasks} |> batch_viewed(events) |> task_events(events)

      {:fault, reason, tasks} ->
        task_fault(%{state | tasks: tasks}, reason)
    end
  end

  defp reconnected(state) do
    {events, tasks} = Tasks.reconnect(state.tasks)
    %{state | tasks: tasks} |> batch_viewed(events) |> task_events(events)
  end

  defp batch_viewed(state, events), do: viewed(state, &View.task_events(&1, events))

  defp task_events(state, events) do
    Enum.each(events, &to_link(state, Map.merge(&1, %{type: "task.event", stream: state.stream})))
    count(state, :task_events, length(events))
  end

  defp task_fault(state, reason) do
    Logger.warning(
      "accessory call #{state.stream}: a task frame the accessory cannot carry: #{inspect(reason)}"
    )

    count(state, :task_faults, 1)
  end

  # -- accessory to engine ----------------------------------------------------------------

  defp on_robot(state, %{type: "credit", bytes: bytes}) do
    case Speaker.credit(state.speaker, bytes) do
      {:ok, speaker} -> {:noreply, pump(%{state | speaker: speaker})}
      {:error, :credit_overgrant} -> overgrant(state)
    end
  end

  defp on_robot(state, %{type: "spk.drained", segment: segment}),
    do: {:noreply, pump(%{state | speaker: Speaker.drained(state.speaker, segment)})}

  defp on_robot(state, %{type: "spk.flushed", played_ms: played_ms}) do
    state
    |> count(:interrupts, 1)
    |> count(:interrupt_played_ms_total, played_ms)
    |> put_in([:counters, :interrupt_played_ms_last], played_ms)
    |> verb(&CallClient.interrupt(&1, played_ms))
  end

  defp on_robot(state, %{type: "playback.progress"} = progress) do
    verb(
      state,
      &CallClient.playback_progress(
        &1,
        progress.playback_id,
        progress.played_ms,
        progress.drained
      )
    )
  end

  defp on_robot(state, %{type: "mic.state", state: "off", reason: "mic_backlog"}),
    do: finish(state, :mic_backlog)

  defp on_robot(state, %{type: "mic.state", state: mic}) do
    state = if mic == "live", do: %{state | mic_live?: true}, else: state
    muted? = mic != "live"
    # A mute already in force keeps its owner: the accessory confirms the Mac's.
    state = viewed(state, &View.muted(&1, if(muted?, do: &1.muted_by || :accessory)))
    if muted? == state.engine_muted?, do: {:noreply, state}, else: engine_mute(state, muted?)
  end

  defp on_robot(state, %{type: "call.end_request"}), do: finish(state, :end_request)

  # The accessory granted past its own bound: a host-side refusal, then the end.
  defp overgrant(state) do
    to_link(state, %{type: "error", code: "credit_overgrant", message_type: "credit"})
    finish(state, :credit_overgrant)
  end

  defp mac_mute(state, muted?) do
    to_link(state, %{type: "mute.set", stream: state.stream, muted: muted?}, true)
    state |> viewed(&View.muted(&1, if(muted?, do: :mac))) |> engine_mute(muted?)
  end

  defp engine_mute(state, muted?) do
    case CallClient.mute(state.client, muted?) do
      {:cont, client} ->
        {:noreply, %{state | client: client, engine_muted?: muted?}}

      {:stop, client} ->
        finish(%{state | client: client}, :session_error, error_reason(first_error()))
    end
  end

  defp verb(state, fun) do
    case fun.(state.client) do
      {:cont, client} ->
        {:noreply, %{state | client: client}}

      {:stop, client} ->
        finish(%{state | client: client}, :session_error, error_reason(first_error()))
    end
  end

  defp on_mic(state, seq, pcm) do
    state
    |> mic_seq(seq)
    |> count(:mic_frames, 1)
    |> take_mic(pcm)
  end

  # PROTOCOL.md (accessory), *Calls*: capture starts at the host's
  # `listening`, and the robot says `mic.state live` before its audio. A frame
  # before that is a contract fault (HW-08's host-side proof): counted, said
  # once as a fault, and never forwarded, since no mic-live mark was shown.
  defp take_mic(%{mic_live?: true} = state, pcm),
    do: state |> Map.update!(:mic, &(&1 <> pcm)) |> forward_mic()

  defp take_mic(state, _pcm) do
    if state.counters.mic_frames_before_live == 0 do
      Logger.warning(
        "accessory call #{state.stream}: microphone audio before the robot said it is live"
      )

      Telemetry.emit_fault(:mic_before_live, :call, 1)
    end

    count(state, :mic_frames_before_live, 1)
  end

  # The first frame is the base; a gap is counted and the audio still used.
  defp mic_seq(%{mic_seq: nil} = state, seq), do: %{state | mic_seq: seq}

  defp mic_seq(state, seq) do
    state =
      if seq == rem(state.mic_seq + 1, @seq_modulus),
        do: state,
        else: count(state, :pcm_seq_gaps, 1)

    %{state | mic_seq: seq}
  end

  defp forward_mic(%{mic: <<chunk::binary-size(@mic_chunk_bytes), rest::binary>>} = state) do
    case CallClient.audio(state.client, chunk) do
      {:cont, client} ->
        %{state | client: client, mic: rest} |> count(:mic_chunks, 1) |> level(rms(chunk))

      {:stop, client} ->
        send_end(%{state | client: client, mic: rest}, :session_error)
    end
  end

  defp forward_mic(state), do: state

  # One pass over the chunk's int16 samples, no allocation per sample; the
  # sum of squares stays a small integer (2,400 samples of at most 2^30).
  defp rms(chunk), do: round(:math.sqrt(sum_squares(chunk, 0) / div(byte_size(chunk), 2)))

  defp sum_squares(<<sample::little-signed-16, rest::binary>>, acc),
    do: sum_squares(rest, acc + sample * sample)

  defp sum_squares(<<>>, acc), do: acc

  defp level(state, rms) do
    state = %{
      state
      | mic_level: %{max: max(state.mic_level.max, rms), total: state.mic_level.total + rms}
    }

    if rms < @silent_rms, do: count(state, :mic_chunks_silent, 1), else: state
  end

  # Levels only once a chunk was forwarded: no audio has no level.
  defp level_counters(%{counters: %{mic_chunks: 0}}), do: %{}

  defp level_counters(%{counters: %{mic_chunks: chunks}, mic_level: level}),
    do: %{mic_rms_max: level.max, mic_rms_mean: round(level.total / chunks)}

  # A refused chunk ends the call from the loop, not from inside the reduce.
  defp send_end(state, reason) do
    send(self(), {:end, reason})
    state
  end

  # -- the end --------------------------------------------------------------------------

  defp finish(state, reason, wire_reason \\ nil) do
    report(state, reason)
    if state.client, do: CallClient.teardown(state.client)
    {:stop, {:shutdown, {:call_ended, wire_reason || Atom.to_string(reason)}}, state}
  end

  defp report(state, reason) do
    counters =
      state.counters
      |> Map.merge(Speaker.counters(state.speaker))
      |> Map.merge(robot_counters(state.robot_diag))
      |> Map.merge(robot_levels(state.robot_levels))
      |> Map.merge(level_counters(state))
      |> Map.put(:duration_ms, max(state.clock.() - state.started_ms, 0))

    Telemetry.emit_call_link(state.session_id, counters, %{
      endpoint: Endpoint.format(state.endpoint),
      engine: state.config.engine,
      source: state.source,
      reason: reason
    })
  end

  # The robot's own counters, since its boot, as it last reported them; none
  # when it reported none this attach.
  defp robot_counters(nil), do: %{}

  defp robot_counters(%{} = diag) do
    for {name, key} <- @robot_counters,
        Map.has_key?(diag, name),
        into: %{},
        do: {key, Map.fetch!(diag, name)}
  end

  # The levels of the robot's latest report in this call; none when that
  # report carried none (`Control` has them all six or none).
  defp robot_levels(%{} = levels) do
    for {name, key} <- @robot_levels,
        Map.has_key?(levels, name),
        into: %{},
        do: {key, Map.fetch!(levels, name)}
  end

  defp error_reason(%{kind: kind}) when is_binary(kind), do: token(kind, "session_error")
  defp error_reason(%{reason: reason}) when is_binary(reason), do: token(reason, "session_error")
  defp error_reason(_error), do: "session_error"

  # A wire reason is a token of at most 48 characters: anything else is the
  # fallback word, never a peer- or vendor-supplied string verbatim.
  defp token(value, fallback), do: if(Regex.match?(@token, value), do: value, else: fallback)

  defp to_link(state, message, urgent? \\ false),
    do: send(state.link, {:call_send, state.stream, message, urgent?})

  # The view changed: the link hears it, with the call's id.
  defp viewed(state, fun) do
    view = fun.(state.view)
    if view == state.view, do: state, else: publish(%{state | view: view})
  end

  defp publish(state) do
    send(state.link, {:call_view, state.stream, state.session_id, state.view})
    state
  end

  defp count(state, key, n), do: update_in(state.counters[key], &(&1 + n))
end
