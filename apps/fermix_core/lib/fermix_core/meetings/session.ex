defmodule FermixCore.Meetings.Session do
  @moduledoc """
  One meeting, from the moment it is requested to the moment its notes are
  delivered (MILESTONE_21 C2 §2).

  The Session is the only live process a meeting has, and the meetings row is
  its durable shadow: every transition writes the new status before anything
  else happens, so a crashed or restarted daemon leaves a row that says exactly
  how far the meeting got. `Meetings.Sweep` reads those rows at boot.

  The state machine is deliberately platform-blind. Both capture lanes speak the
  `Meetings.AudioSource` message set, so nothing here branches on Meet vs Zoom
  except the two places where the lanes genuinely differ: which source module
  starts, and whether the launch step has a deadline of its own.

  ## Two bounds worth naming

  `@max_duration_ms` is a standing watchdog armed once, when capture starts —
  a meeting nobody ends still ends. The alone timer is the other half: a
  notetaker left talking to itself after everyone hangs up would otherwise
  transcribe an empty room for four hours.

  ## Ending a meeting drains the transcript, it does not cut it

  Entering `summarizing` stops the audio source and then calls
  `StreamSession.finish/1` on the transcription stream, and keeps consuming
  segments until the stream reports closed. The last thing said in a meeting is
  usually the wrap-up and the action items, and `stop/1` would discard exactly
  that. `stop/1` is reserved for abort paths, where there is no summary to
  protect.

  ## Degradation is labelled, never silent

  A capture cut short — a crashed sidecar, a lost RTMS leg, a dead transcription
  stream — still summarizes and delivers what it has, with an explicit
  early-cut warning line, provided at least one segment was captured. With none,
  the meeting fails. A stream that closed cleanly but gave up on segments counts
  the same way: its dropped count is read out of the close summary and labels
  the meeting. Nothing is quietly shorter than it looks.

  Every collaborator is injected through `start_link/1` opts (`:source_module`,
  `:transcription`, `:summarizer`, `:delivery`, `:caffeinate`, `:installer`,
  `:timers`), which is what lets the suite drive every row of the transition
  table without a browser, a socket, or a provider call.
  """

  use GenServer, restart: :temporary

  alias FermixCore.Meetings.Caffeinate
  alias FermixCore.Meetings.Config
  alias FermixCore.Meetings.Delivery
  alias FermixCore.Meetings.SidecarInstaller
  alias FermixCore.Meetings.SpeakerTimeline
  alias FermixCore.Meetings.Store
  alias FermixCore.Meetings.Summarizer
  alias FermixCore.Meetings.Supervisor, as: MeetingsSupervisor
  alias FermixCore.Meetings.Telemetry, as: MeetingTelemetry
  alias FermixCore.Meetings.TranscriptStore
  alias FermixCore.Timeouts
  alias FermixCore.Transcription
  alias FermixCore.Transcription.Registry, as: TranscriptionRegistry
  alias FermixCore.Transcription.Segment
  alias FermixCore.Transcription.StreamSession

  require Logger

  # Internal bounds (C2 §2.0). None of these is a config key: they are the
  # shape of the feature, not a posture an operator tunes.
  @max_duration_ms 240 * 60_000
  @knock_timeout_ms 3 * 60_000
  @alone_timeout_ms 10 * 60_000
  @leave_grace_ms 10_000
  @rtms_start_timeout_ms 600_000
  @min_segments_for_summary 1

  # The Zoom lane has no OS process to watch, so its sleep guard self-bounds a
  # little past the longest meeting the watchdog allows.
  @caffeinate_slack_s 300

  # s16le mono: two bytes per sample, 16 samples per millisecond at 16 kHz.
  @bytes_per_sample 2

  # The end causes that mean the capture was cut short rather than finished.
  # `Meetings.Delivery.warning_line/1` holds the same list for the delivered
  # message; this copy labels `summary.md`, which Delivery never sees.
  @partial_reasons [:sidecar_crashed, :rtms_stream_lost, :stt_stream_failed]

  @pre_capture_states [:requested, :installing, :launching, :joining, :knocking, :admitted]
  @winding_down_states [:leaving, :max_duration, :alone_timeout]

  @no_speech_notice "No speech was captured, so there are no notes for this meeting."

  # The one registry key every Session competes for. `Meetings.check_capacity/0`
  # reads the registry before this process exists, so two joins racing each other
  # can both pass it; registering a unique key is the claim that cannot be raced.
  @capacity_key :capacity_slot

  # One retry, and only for the one thing a retry can settle: the slot's holder
  # died between refusing us and being read, which frees the slot.
  @capacity_attempts 2

  # A stream error and a monitored stream's `:DOWN` carry no close summary; the
  # drain rules below key on the dropped count, and neither path reports one.
  @unreported_drops %{segments: 0, dropped: 0}

  # `Memory.Repo.MeetingsSql` refuses an `error` longer than this many BYTES.
  @max_error_bytes 500

  defstruct [
    :id,
    :url,
    :platform,
    :title,
    :link,
    :origin,
    :session_id,
    :parent_session,
    :origin_kind,
    :status,
    :end_reason,
    :config,
    :deps,
    :capacity_key,
    :timers,
    :source,
    :stt,
    :timeline,
    :transcript,
    :artifact_dir,
    :caffeinate,
    :summary_task,
    :started_at,
    :started_at_mono,
    :phase_timer,
    :max_duration_timer,
    :alone_timer,
    roster: %{},
    samples_seen: 0,
    participants_peak: 0,
    segments: 0,
    words: 0
  ]

  @typedoc "The live state-machine value; the meetings row carries it as a string."
  @type status :: atom()

  @doc """
  Starts a Session for an already-inserted meetings row.

  Required opts: `:meeting` (the row map). Optional: `:name` (the via-Registry
  tuple `Meetings.join/2` supplies), `:link` (the `Meetings.Link` parse — the
  source args are built from it), `:config` (a `Meetings.Config` snapshot,
  resolved once by the caller), `:parent_session`, `:capacity_key` (the registry
  key the one capacity slot is claimed under — the suite gives each session its
  own so an async file does not serialize on it), and the collaborator seams
  described in the moduledoc.

  Returns `{:error, {:max_concurrent, other_id}}` when another meeting already
  holds the capacity slot: the claim is made here, in `init/1`, because that is
  the only place it is atomic against a second join.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Asks the notetaker to leave the meeting (async — the wind-down is a state)."
  @spec leave(GenServer.server()) :: :ok
  def leave(server), do: GenServer.cast(server, :leave)

  @doc """
  The current state-machine value.

  A synchronous read of an otherwise message-driven process: a caller that has
  just sent the Session a source message can use it to observe the transition
  that message caused, because a mailbox is ordered per sender.
  """
  @spec status(GenServer.server()) :: status()
  def status(server), do: GenServer.call(server, :status)

  # --- GenServer callbacks (thin) ------------------------------------------

  @impl true
  def init(opts) do
    # The audio source is started with `start_link/2` and monitored: trapping
    # exits keeps a source crash an event this process classifies (via its
    # `:DOWN`) instead of one it inherits, and guarantees `terminate/2` runs on
    # a supervisor shutdown so the sidecar and the sleep guard are released.
    Process.flag(:trap_exit, true)

    state = build_state(opts)

    case claim_capacity(state) do
      :ok -> start_run(state)
      {:error, reason} -> {:stop, reason}
    end
  end

  defp start_run(state) do
    MeetingTelemetry.run_start(telemetry_meeting(state),
      url: state.url,
      title: state.title,
      max_duration_ms: @max_duration_ms
    )

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, %{platform: :meet} = state), do: move(state, :installing)
  def handle_continue(:start, %{platform: :zoom} = state), do: move(state, :launching)

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_cast(:leave, %{status: :capturing} = state) do
    end_capture(state, :leaving, :operator_left)
  end

  def handle_cast(:leave, %{status: status} = state) when status in @pre_capture_states do
    # There is no transcript to summarize yet, so the wind-down states do not
    # apply: the meeting ends here, recorded under the reason the operator gave.
    leave_source(state)
    fail(state, :failed, :operator_left)
  end

  # Already winding down or terminal — leaving is what is happening.
  def handle_cast(:leave, state), do: {:noreply, state}

  @impl true
  def handle_info({:meeting_audio, pcm}, state), do: on_audio(pcm, state)
  def handle_info({:meeting_roster, participants}, state), do: on_roster(participants, state)

  def handle_info({:meeting_active_speaker, id, t_ms}, state) do
    {:noreply, %{state | timeline: SpeakerTimeline.note_active(state.timeline, id, t_ms)}}
  end

  def handle_info({:meeting_phase, phase, _meta}, state), do: on_phase(phase, state)
  def handle_info({:meeting_join_result, result, _meta}, state), do: on_join_result(result, state)
  def handle_info({:meeting_chat_posted}, state), do: {:noreply, state}
  def handle_info({:meeting_ended, reason}, state), do: on_meeting_ended(reason, state)
  def handle_info({:meeting_source_error, reason}, state), do: on_source_error(reason, state)
  def handle_info({:transcript_segment, _stt, segment}, state), do: on_segment(segment, state)

  def handle_info({:transcript_stream_closed, _stt, summary}, state),
    do: on_stream_end(state, summary)

  def handle_info({:transcript_stream_error, _stt, _reason}, state),
    do: on_stream_end(state, @unreported_drops)

  def handle_info({:phase_timeout, phase}, state), do: on_phase_timeout(phase, state)
  def handle_info({:capture_timeout, kind}, state), do: on_capture_timeout(kind, state)

  def handle_info({ref, result}, %{summary_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    on_summary(result, %{state | summary_task: nil})
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state), do: on_down(ref, reason, state)

  # The source is linked AND monitored; its `:DOWN` is the signal acted on, so
  # the exit signal that arrives with it carries no second fact.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state |> stop_source() |> stop_caffeinate() |> abort_stream() |> close_transcript()
    release_capacity(state)
    :ok
  end

  # --- state construction --------------------------------------------------

  defp build_state(opts) do
    meeting = Keyword.fetch!(opts, :meeting)
    origin_session_id = Map.get(meeting, :origin_session_id)
    id = Map.fetch!(meeting, :id)

    %__MODULE__{
      id: id,
      url: Map.fetch!(meeting, :url),
      platform: platform(Map.fetch!(meeting, :platform)),
      title: Map.get(meeting, :title),
      link: Keyword.get(opts, :link, %{meeting_id: nil, passcode: nil}),
      origin: %{
        session_id: origin_session_id,
        requested_by: Map.get(meeting, :requested_by, "operator")
      },
      session_id: mint_session_id(id),
      parent_session: Keyword.get(opts, :parent_session),
      origin_kind: origin_kind(origin_session_id),
      status: :requested,
      config: Keyword.get_lazy(opts, :config, &Config.load/0),
      deps: deps(opts),
      capacity_key: Keyword.get(opts, :capacity_key, @capacity_key),
      timers: timers(opts),
      timeline: SpeakerTimeline.new(),
      started_at_mono: System.monotonic_time(:millisecond)
    }
  end

  defp platform("meet"), do: :meet
  defp platform("zoom"), do: :zoom
  defp platform(platform) when platform in [:meet, :zoom], do: platform

  defp deps(opts) do
    %{
      source_module: Keyword.get(opts, :source_module),
      source_args: Keyword.get(opts, :source_args, %{}),
      installer: Keyword.get(opts, :installer, SidecarInstaller),
      transcription: Keyword.get(opts, :transcription, Transcription),
      summarizer: Keyword.get(opts, :summarizer, Summarizer),
      summarizer_opts: Keyword.get(opts, :summarizer_opts, []),
      delivery: Keyword.get(opts, :delivery, Delivery),
      delivery_opts: Keyword.get(opts, :delivery_opts, []),
      caffeinate: Keyword.get(opts, :caffeinate, Caffeinate),
      store_opts: Keyword.get(opts, :store_opts, []),
      transcript_opts: Keyword.get(opts, :transcript_opts, [])
    }
  end

  defp timers(opts) do
    defaults = %{
      join_ms: Timeouts.meetbot_join(),
      knock_ms: @knock_timeout_ms,
      alone_ms: @alone_timeout_ms,
      leave_grace_ms: @leave_grace_ms,
      launch_ms: @rtms_start_timeout_ms,
      max_duration_ms: @max_duration_ms,
      summarize_ms: Timeouts.meeting_summarize()
    }

    Map.merge(defaults, Map.new(Keyword.get(opts, :timers, %{})))
  end

  # `"meeting_<id>_<YYYYMMDD_HHMMSS>"` (C2 §11.2). The meeting id already
  # carries its own random suffix, so nothing here is truncated.
  defp mint_session_id(id) do
    now = DateTime.utc_now()

    "meeting_" <>
      id <>
      "_" <>
      Enum.map_join(
        [
          now.year,
          pad(now.month),
          pad(now.day),
          "_",
          pad(now.hour),
          pad(now.minute),
          pad(now.second)
        ],
        &to_string/1
      )
  end

  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp origin_kind(nil), do: nil
  defp origin_kind("cli:" <> _rest), do: "cli"
  defp origin_kind("cron_" <> _rest), do: "job"
  defp origin_kind("job_" <> _rest), do: "job"

  defp origin_kind(session_id) do
    case String.split(session_id, ":", parts: 3) do
      [platform, destination, _scope] when platform != "" and destination != "" -> "channel"
      _other -> nil
    end
  end

  # --- the capacity slot ----------------------------------------------------

  defp claim_capacity(state), do: claim_capacity(state, @capacity_attempts)

  # Two conflicts in a row with a holder nobody can name means sessions are
  # churning through the slot faster than it can be read — a state this daemon
  # cannot describe, so it says so rather than inventing a meeting id.
  defp claim_capacity(_state, 0), do: {:error, :capacity_slot_contended}

  defp claim_capacity(state, attempts) do
    case Registry.register(MeetingsSupervisor.registry(), state.capacity_key, state.id) do
      {:ok, _pid} -> :ok
      {:error, {:already_registered, holder}} -> refuse(state, holder, attempts)
    end
  end

  # The holder registered its own meeting id as the slot's value. An empty read
  # means it has since exited, which frees the slot — hence the bounded retry.
  defp refuse(state, holder, attempts) do
    case Registry.values(MeetingsSupervisor.registry(), state.capacity_key, holder) do
      [other_id] when is_binary(other_id) -> {:error, {:max_concurrent, other_id}}
      [] -> claim_capacity(state, attempts - 1)
    end
  end

  # Releasing here rather than leaving it to the registry's own monitor makes
  # the slot free the moment this process finishes terminating, which is what a
  # join issued right after a meeting ends observes.
  defp release_capacity(state) do
    Registry.unregister(MeetingsSupervisor.registry(), state.capacity_key)
  end

  # --- transitions ---------------------------------------------------------

  # One place writes a transition: the row first, then the phase event, then
  # the timers the state we are leaving owned.
  defp goto(state, to, fields, reason) do
    from = state.status
    write_status(state, to, fields)
    MeetingTelemetry.phase(telemetry_meeting(state), from, to, reason_atom(reason))

    state = state |> cancel_phase_timer() |> cancel_capture_timers(to)
    %{state | status: to}
  end

  defp move(state, to, fields \\ %{}, reason \\ nil) do
    state |> goto(to, fields, reason) |> enter()
  end

  # An end cause is remembered before the transition that records it: it rides
  # `meta.json`, the phase event, and the delivered notes.
  defp end_capture(state, to, reason) do
    move(%{state | end_reason: reason}, to, %{}, reason)
  end

  defp write_status(state, to, fields) do
    case Store.update_status(state.id, Atom.to_string(to), fields, state.deps.store_opts) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "meetings: #{state.id} status write #{to} failed: #{inspect(reason)} — " <>
            "the meeting continues but its row is stale"
        )
    end
  end

  # --- entry actions (one clause per state that has one) --------------------

  # Resolution only — `install/0` is a setup-card action, never a hot path.
  # `join/2` already gated on this, so a miss here is a race, not a surprise.
  defp enter(%{status: :installing} = state) do
    case state.deps.installer.binary_path() do
      {:ok, _path} -> move(state, :launching)
      {:error, _reason} -> fail(state, :failed, :sidecar_not_installed)
    end
  end

  defp enter(%{status: :launching} = state) do
    case start_source(state) do
      {:ok, state} -> {:noreply, arm_launch_timer(state)}
      {:error, reason} -> fail(state, :failed, reason)
    end
  end

  defp enter(%{status: :joining} = state) do
    {:noreply, arm_phase_timer(state, :joining, state.timers.join_ms)}
  end

  defp enter(%{status: :knocking} = state) do
    {:noreply, arm_phase_timer(state, :knocking, state.timers.knock_ms)}
  end

  # `admitted` is a pass-through: the resources open here, and the directory
  # they created rides the very next transition rather than costing the row a
  # second write for one state.
  defp enter(%{status: :admitted} = state) do
    case open_capture(state) do
      {:ok, state} -> move(state, :capturing, %{artifact_dir: state.artifact_dir})
      {:error, reason} -> leave_then_fail(state, reason)
    end
  end

  defp enter(%{status: :capturing} = state), do: {:noreply, arm_max_duration(state)}

  # The bot is already out of the meeting; nothing to ask it to leave.
  defp enter(%{status: status} = state) when status in [:removed_by_host, :meeting_ended] do
    move(state, :summarizing)
  end

  defp enter(%{status: status} = state) when status in @winding_down_states do
    leave_source(state)
    {:noreply, arm_phase_timer(state, status, state.timers.leave_grace_ms)}
  end

  defp enter(%{status: :summarizing} = state) do
    state = state |> stop_source() |> stop_caffeinate() |> rearm_watchdog()
    drain_or_finish(state)
  end

  # --- source messages ------------------------------------------------------

  defp on_audio(pcm, %{status: :capturing} = state) do
    push_pcm(state, pcm)
    write_audio(state, pcm)
    samples = div(byte_size(pcm), @bytes_per_sample)
    {:noreply, %{state | samples_seen: state.samples_seen + samples}}
  end

  # Audio that arrives before capture opens or after it closes has nowhere to
  # go: the stream and the transcript file are the capture state itself.
  defp on_audio(_pcm, state), do: {:noreply, state}

  defp on_roster(participants, state) do
    timeline = SpeakerTimeline.note_roster(state.timeline, participants)

    state = %{
      state
      | timeline: timeline,
        roster: Map.new(participants, &{&1.id, &1.name}),
        participants_peak: SpeakerTimeline.participants_peak(timeline)
    }

    {:noreply, update_alone_timer(state, length(participants))}
  end

  defp on_phase(:joining, %{status: :launching} = state) do
    started_at = DateTime.utc_now()
    move(%{state | started_at: started_at}, :joining, %{started_at: started_at})
  end

  defp on_phase(:knocking, %{status: :joining} = state), do: move(state, :knocking)

  # A phase notice for a phase already left is stale, not an error.
  defp on_phase(_phase, state), do: {:noreply, state}

  defp on_join_result(:admitted, %{status: status} = state)
       when status in [:joining, :knocking] do
    move(state, :admitted)
  end

  defp on_join_result(:knock_timeout, state) do
    leave_source(state)
    fail(state, :knock_timeout, :knock_timeout)
  end

  defp on_join_result(result, state)
       when result in [:denied, :login_required, :signin_required, :bot_blocked] do
    fail(state, result, result)
  end

  defp on_join_result(_result, state), do: {:noreply, state}

  defp on_meeting_ended(:host_removed, %{status: :capturing} = state) do
    end_capture(state, :removed_by_host, :host_removed)
  end

  defp on_meeting_ended(reason, %{status: :capturing} = state) do
    end_capture(state, :meeting_ended, reason)
  end

  # The grace window was waiting for exactly this.
  defp on_meeting_ended(_reason, %{status: status} = state)
       when status in @winding_down_states do
    move(state, :summarizing)
  end

  defp on_meeting_ended(_reason, %{status: :summarizing} = state), do: {:noreply, state}

  defp on_meeting_ended(reason, state), do: fail(state, :failed, {:meeting_ended, reason})

  defp on_source_error(reason, %{status: :capturing} = state) do
    partial_finalize(state, capture_loss_reason(state), reason)
  end

  # The source failing on its way out of a meeting we already left is the
  # source going away, not a capture that broke: the notes are still owed.
  defp on_source_error(_reason, %{status: status} = state)
       when status in @winding_down_states do
    move(state, :summarizing)
  end

  defp on_source_error(_reason, %{status: status} = state)
       when status in [:summarizing, :delivered] do
    {:noreply, state}
  end

  defp on_source_error(reason, state), do: fail(state, :failed, reason)

  defp on_source_down(reason, %{status: :capturing} = state) do
    partial_finalize(state, capture_loss_reason(state), reason)
  end

  # The source exiting during the leave grace IS the ending it was waiting for.
  defp on_source_down(_reason, %{status: status} = state)
       when status in @winding_down_states do
    move(state, :summarizing)
  end

  defp on_source_down(_reason, %{status: status} = state)
       when status in [:summarizing, :delivered] do
    {:noreply, state}
  end

  defp on_source_down(reason, state), do: fail(state, :failed, {:source_down, reason})

  defp capture_loss_reason(%{platform: :meet}), do: :sidecar_crashed
  defp capture_loss_reason(%{platform: :zoom}), do: :rtms_stream_lost

  # --- monitors -------------------------------------------------------------

  defp on_down(ref, reason, %{summary_task: %Task{ref: ref}} = state) do
    fail(%{state | summary_task: nil}, :failed, {:summarize_failed, reason})
  end

  # The stream is left in place: `on_stream_end/2` releases it inside the clause
  # that acts on it, which is how a stream released earlier stays ignorable.
  defp on_down(ref, _reason, %{stt: %{ref: ref}} = state) do
    on_stream_end(state, @unreported_drops)
  end

  defp on_down(ref, reason, %{source: %{ref: ref}} = state) do
    on_source_down(reason, %{state | source: nil})
  end

  defp on_down(_ref, _reason, state), do: {:noreply, state}

  # --- transcription messages ----------------------------------------------

  defp on_segment(%Segment{} = segment, state) do
    speaker = SpeakerTimeline.attribute(state.timeline, segment.t0_ms, segment.t1_ms)
    entry = %{t0_ms: segment.t0_ms, t1_ms: segment.t1_ms, speaker: speaker, text: segment.text}

    {:noreply, append_segment(state, entry)}
  end

  defp append_segment(%{transcript: nil} = state, _entry), do: state

  defp append_segment(state, entry) do
    case TranscriptStore.append(state.transcript, entry) do
      {:ok, transcript} ->
        %{
          state
          | transcript: transcript,
            segments: state.segments + 1,
            words: state.words + word_count(entry.text)
        }

      {:error, reason} ->
        Logger.error("meetings: #{state.id} transcript append failed: #{inspect(reason)}")
        state
    end
  end

  defp word_count(text), do: length(String.split(text))

  # The drain this state entered for is over — everything the stream had is in
  # the transcript, so the tail pipeline runs on the complete capture.
  defp on_stream_end(%{status: :summarizing, stt: stt} = state, summary) when not is_nil(stt) do
    state |> release_stream() |> drained(summary)
  end

  defp on_stream_end(%{status: :capturing, stt: stt} = state, _summary) when not is_nil(stt) do
    partial_finalize(release_stream(state), :stt_stream_failed, :transcription_stream_ended)
  end

  # The stream was released before this message was read — the summarize
  # watchdog aborted it, or an earlier terminal message from the same stream was
  # already acted on. Its ending is accounted for; running the tail pipeline a
  # second time would finalize an already-finalized transcript and fail a
  # meeting whose notes are being written.
  defp on_stream_end(%{stt: nil} = state, _summary), do: {:noreply, state}

  defp on_stream_end(state, _summary), do: {:noreply, release_stream(state)}

  # The close summary is the only place a dropped segment is counted: a backend
  # outage closes as cleanly as a silent room, so a capture that lost speech is
  # labelled here or nowhere.
  defp drained(state, %{dropped: 0}), do: finish_capture(state)

  defp drained(state, %{dropped: dropped}) when is_integer(dropped) and dropped > 0 do
    Logger.warning(
      "meetings: #{state.id} transcription dropped #{dropped} segment(s) — notes are partial"
    )

    state |> label_dropped() |> finish_dropped()
  end

  # A capture already labelled with how it was cut keeps that cause: it names
  # the same loss more precisely than the drops it produced.
  defp label_dropped(%{end_reason: reason} = state) when reason in @partial_reasons, do: state
  defp label_dropped(state), do: %{state | end_reason: :stt_stream_failed}

  # `partial_finalize/3`'s rule, applied to the drain: notes need something to
  # summarize, and "nothing was transcribed because transcription failed" is a
  # failed meeting, not a silent one.
  defp finish_dropped(%{segments: segments} = state)
       when segments >= @min_segments_for_summary do
    finish_capture(state)
  end

  defp finish_dropped(state), do: fail(state, :failed, :stt_stream_failed)

  defp partial_finalize(state, reason, detail) do
    Logger.warning("meetings: #{state.id} capture ended early (#{reason}): #{inspect(detail)}")

    if state.segments >= @min_segments_for_summary do
      end_capture(state, :summarizing, reason)
    else
      fail(%{state | end_reason: reason}, :failed, reason)
    end
  end

  # --- timers ---------------------------------------------------------------

  defp on_phase_timeout(phase, %{status: phase} = state), do: phase_expired(phase, state)
  defp on_phase_timeout(_phase, state), do: {:noreply, state}

  defp phase_expired(:launching, state), do: fail(state, :failed, :rtms_start_timeout)

  defp phase_expired(:joining, state) do
    Timeouts.expired(:meetbot_join, state.timers.join_ms, %{session_id: state.session_id})
    fail(state, :failed, :join_timeout)
  end

  defp phase_expired(:knocking, state) do
    leave_source(state)
    fail(state, :knock_timeout, :knock_timeout)
  end

  defp phase_expired(status, state) when status in @winding_down_states do
    move(stop_source(state), :summarizing)
  end

  # Still draining the transcription tail: the meeting keeps what it captured
  # and moves on, and `finish_capture/1` re-arms the same bound for the
  # summarizer itself.
  defp phase_expired(:summarizing, %{stt: stt} = state) when not is_nil(stt) do
    finish_capture(abort_stream(state))
  end

  defp phase_expired(:summarizing, state) do
    Timeouts.expired(:meeting_summarize, state.timers.summarize_ms, %{
      session_id: state.session_id
    })

    fail(shutdown_summary(state), :failed, :summarize_timeout)
  end

  defp on_capture_timeout(:max_duration, %{status: :capturing} = state) do
    end_capture(state, :max_duration, :max_duration)
  end

  defp on_capture_timeout(:alone, %{status: :capturing} = state) do
    end_capture(state, :alone_timeout, :alone_timeout)
  end

  defp on_capture_timeout(_kind, state), do: {:noreply, state}

  defp arm_phase_timer(state, phase, ms) do
    state = cancel_phase_timer(state)
    %{state | phase_timer: Process.send_after(self(), {:phase_timeout, phase}, ms)}
  end

  defp arm_launch_timer(%{platform: :zoom} = state) do
    arm_phase_timer(state, :launching, state.timers.launch_ms)
  end

  # Meet's launch deadline is the sidecar handshake, enforced inside `Sidecar.Port`.
  defp arm_launch_timer(state), do: state

  defp cancel_phase_timer(%{phase_timer: nil} = state), do: state

  defp cancel_phase_timer(state) do
    Process.cancel_timer(state.phase_timer)
    %{state | phase_timer: nil}
  end

  defp arm_max_duration(%{max_duration_timer: nil} = state) do
    message = {:capture_timeout, :max_duration}
    ref = Process.send_after(self(), message, state.timers.max_duration_ms)
    %{state | max_duration_timer: ref}
  end

  defp arm_max_duration(state), do: state

  defp cancel_capture_timers(state, :capturing), do: state

  defp cancel_capture_timers(state, _to) do
    state |> cancel_timer(:max_duration_timer) |> cancel_timer(:alone_timer)
  end

  defp cancel_timer(state, key) do
    case Map.fetch!(state, key) do
      nil -> state
      ref -> cancel_and_clear(state, key, ref)
    end
  end

  defp cancel_and_clear(state, key, ref) do
    Process.cancel_timer(ref)
    Map.put(state, key, nil)
  end

  # §2.5: "alone" is measured against the lane's own roster seat — the Meet bot
  # occupies one, the RTMS app occupies none.
  defp update_alone_timer(%{status: :capturing} = state, participant_count) do
    if participant_count - self_count(state) <= 0 do
      arm_alone_timer(state)
    else
      cancel_timer(state, :alone_timer)
    end
  end

  defp update_alone_timer(state, _participant_count), do: state

  # Already counting down: a fresh snapshot of the same empty room must not
  # restart the clock.
  defp arm_alone_timer(%{alone_timer: nil} = state) do
    ref = Process.send_after(self(), {:capture_timeout, :alone}, state.timers.alone_ms)
    %{state | alone_timer: ref}
  end

  defp arm_alone_timer(state), do: state

  defp rearm_watchdog(state) do
    arm_phase_timer(state, :summarizing, state.timers.summarize_ms)
  end

  # --- capture resources ----------------------------------------------------

  defp open_capture(state) do
    case open_stream(state) do
      {:ok, stt} -> open_transcript(state, stt)
      {:error, reason} -> {:error, {:stt_open_failed, reason}}
    end
  end

  defp open_transcript(state, stt) do
    case TranscriptStore.open(state.id, transcript_opts(state)) do
      {:ok, transcript} -> {:ok, capture_state(state, stt, transcript)}
      {:error, reason} -> release_and_fail(stt, reason)
    end
  end

  defp capture_state(state, stt, transcript) do
    %{
      state
      | stt: %{pid: stt, ref: Process.monitor(stt)},
        transcript: transcript,
        artifact_dir: TranscriptStore.dir(transcript),
        caffeinate: start_caffeinate(state)
    }
  end

  defp release_and_fail(stt, reason) do
    stop_stream(stt)
    {:error, {:transcript_open_failed, reason}}
  end

  defp transcript_opts(state) do
    Keyword.put_new(state.deps.transcript_opts, :retain_audio, state.config.retain_audio)
  end

  # F3: a blank backend means "whatever transcription is configured globally",
  # so no `:backend` opt is passed at all. A named one is resolved through the
  # transcription registry, which fails loud on a name it does not ship.
  defp open_stream(state) do
    case backend_opts(state.config.transcription_backend) do
      {:ok, backend_opts} ->
        state.deps.transcription.open_stream(self(), stream_opts(state, backend_opts))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp backend_opts(""), do: {:ok, []}

  defp backend_opts(name) do
    with {:ok, {_name, module}} <- TranscriptionRegistry.active_backend(backend: name),
         {:ok, model_opts} <- model_opts(name) do
      {:ok, [backend: module] ++ model_opts}
    end
  end

  # The shared `[fermix_core.transcription] model` belongs to the GLOBAL
  # backend — setup snaps it to that backend's family precisely because a
  # cross-family id is a hard 400 — so a per-meeting override carries its own
  # backend's default instead of inheriting it. A modelless backend (xai, local)
  # takes no model at all.
  defp model_opts(name) do
    case TranscriptionRegistry.default_model(name) do
      {:ok, model} -> {:ok, [model: model]}
      {:error, :modelless} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stream_opts(state, backend_opts) do
    [session_id: state.session_id, parent_session: state.parent_session] ++ backend_opts
  end

  defp push_pcm(%{stt: nil}, _pcm), do: :ok
  defp push_pcm(%{stt: %{pid: pid}}, pcm), do: StreamSession.push_pcm(pid, pcm)

  defp write_audio(%{transcript: nil}, _pcm), do: :ok

  defp write_audio(state, pcm) do
    case TranscriptStore.append_audio(state.transcript, pcm) do
      {:ok, _transcript} ->
        :ok

      {:error, reason} ->
        Logger.error("meetings: #{state.id} audio write failed: #{inspect(reason)}")
    end
  end

  defp release_stream(%{stt: nil} = state), do: state

  defp release_stream(%{stt: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    %{state | stt: nil}
  end

  defp abort_stream(%{stt: nil} = state), do: state

  defp abort_stream(%{stt: %{pid: pid}} = state) do
    stop_stream(pid)
    release_stream(state)
  end

  # A wedged stream must not take the Session with it: the abort is best-effort
  # by construction, and the reason it failed is already the reason we aborted.
  defp stop_stream(pid) do
    StreamSession.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp close_transcript(%{transcript: nil} = state), do: state

  defp close_transcript(state) do
    TranscriptStore.close(state.transcript)
    %{state | transcript: nil}
  end

  # --- audio source ---------------------------------------------------------

  defp start_source(state) do
    module = state.deps.source_module

    case module.start_link(self(), source_args(state)) do
      {:ok, pid} -> {:ok, put_source(state, module, pid)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_source(state, module, pid) do
    %{state | source: %{module: module, pid: pid, ref: Process.monitor(pid)}}
  end

  defp source_args(state) do
    Map.merge(
      %{
        meeting_id: state.id,
        url: state.url,
        meet_code: state.link.meeting_id,
        meeting_no: state.link.meeting_id,
        passcode: state.link.passcode,
        config: state.config,
        session_id: state.session_id
      },
      state.deps.source_args
    )
  end

  defp self_count(%{source: %{module: module}}), do: module.self_count()
  defp self_count(%{deps: %{source_module: module}}), do: module.self_count()

  defp leave_source(%{source: nil}), do: :ok
  defp leave_source(%{source: %{module: module, pid: pid}}), do: module.leave(pid)

  defp stop_source(%{source: nil} = state), do: state

  defp stop_source(%{source: %{module: module, pid: pid, ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    module.stop(pid)
    %{state | source: nil}
  end

  defp start_caffeinate(state) do
    case state.deps.caffeinate.start({:bounded, caffeinate_seconds(state)}) do
      {:ok, guard} -> guard
      :inactive -> nil
    end
  end

  defp caffeinate_seconds(state) do
    div(state.timers.max_duration_ms, 1_000) + @caffeinate_slack_s
  end

  defp stop_caffeinate(state) do
    state.deps.caffeinate.stop(state.caffeinate)
    %{state | caffeinate: nil}
  end

  # --- the tail pipeline ----------------------------------------------------

  defp drain_or_finish(%{stt: nil} = state), do: finish_capture(state)

  defp drain_or_finish(%{stt: %{pid: pid}} = state) do
    StreamSession.finish(pid)
    {:noreply, state}
  end

  defp finish_capture(state) do
    state = rearm_watchdog(state)

    case finalize_transcript(state) do
      {:ok, state} -> start_summary(state)
      {:error, reason} -> fail(state, :failed, {:transcript_finalize_failed, reason})
    end
  end

  defp finalize_transcript(%{transcript: nil} = state), do: {:error, {:no_transcript, state.id}}

  defp finalize_transcript(state) do
    case TranscriptStore.finalize(state.transcript, transcript_meta(state)) do
      {:ok, %{dir: dir}} -> {:ok, %{state | transcript: nil, artifact_dir: dir}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transcript_meta(state) do
    %{
      meeting_id: state.id,
      platform: Atom.to_string(state.platform),
      url: state.url,
      title: state.title,
      status: Atom.to_string(state.status),
      end_reason: state.end_reason,
      started_at: iso8601(state.started_at),
      ended_at: DateTime.to_iso8601(DateTime.utc_now()),
      participants_peak: state.participants_peak,
      transcription_backend: state.config.transcription_backend,
      session_id: state.session_id,
      origin_session_id: state.origin.session_id
    }
  end

  defp start_summary(%{segments: segments} = state)
       when segments >= @min_segments_for_summary do
    case File.read(Path.join(state.artifact_dir, "transcript.md")) do
      {:ok, transcript_md} ->
        {:noreply, %{state | summary_task: spawn_summary(state, transcript_md)}}

      {:error, reason} ->
        fail(state, :failed, {:transcript_read_failed, reason})
    end
  end

  defp start_summary(state), do: deliver_notes(state, @no_speech_notice)

  defp spawn_summary(state, transcript_md) do
    summarizer = state.deps.summarizer
    meeting = summarizer_meeting(state)
    opts = summarizer_opts(state)

    Task.Supervisor.async_nolink(FermixCore.TaskSupervisor, fn ->
      summarizer.run(meeting, transcript_md, opts)
    end)
  end

  defp summarizer_meeting(state) do
    %{
      id: state.id,
      title: state.title,
      platform: Atom.to_string(state.platform),
      url: state.url,
      started_at: iso8601(state.started_at),
      ended_at: DateTime.to_iso8601(DateTime.utc_now()),
      participants: Map.values(state.roster)
    }
  end

  defp summarizer_opts(state) do
    Keyword.merge(
      [session_id: state.session_id, parent_session: state.parent_session],
      state.deps.summarizer_opts
    )
  end

  defp shutdown_summary(%{summary_task: nil} = state), do: state

  defp shutdown_summary(%{summary_task: task} = state) do
    Task.Supervisor.terminate_child(FermixCore.TaskSupervisor, task.pid)
    Process.demonitor(task.ref, [:flush])
    %{state | summary_task: nil}
  end

  defp on_summary({:ok, %{text: text}}, state) do
    state |> write_summary_md(text) |> deliver_notes(text)
  end

  defp on_summary({:error, reason}, state), do: fail(state, :failed, {:summarize_failed, reason})

  defp write_summary_md(state, text) do
    path = Path.join(state.artifact_dir, "summary.md")

    case File.write(path, [warning_line(state), text, "\n"]) do
      :ok -> state
      {:error, reason} -> log_write_failure(state, path, reason)
    end
  end

  defp log_write_failure(state, path, reason) do
    Logger.error("meetings: #{state.id} could not write #{path}: #{inspect(reason)}")
    state
  end

  # The peer of `Meetings.Delivery`'s warning line, for the file Delivery never
  # touches. Both are pinned by their own tests; keep the wording in step.
  defp warning_line(%{end_reason: reason} = state) when reason in @partial_reasons do
    "⚠️ Capture ended early (#{reason}) — notes cover the first #{mm_ss(state)} only.\n\n"
  end

  defp warning_line(_state), do: ""

  defp mm_ss(state) do
    seconds = div(duration_ms(state), 1_000)
    "#{pad(div(seconds, 60))}:#{pad(rem(seconds, 60))}"
  end

  defp deliver_notes(state, text) do
    case state.deps.delivery.deliver(delivery_meeting(state), text, state.deps.delivery_opts) do
      {:ok, :sent} -> complete(state)
      {:error, :no_delivery_target} -> unresolvable(state)
      {:error, reason} -> fail(state, :failed, reason)
    end
  end

  defp delivery_meeting(state) do
    %{
      url: state.url,
      title: state.title,
      artifact_dir: state.artifact_dir,
      duration_ms: duration_ms(state),
      participants_peak: state.participants_peak,
      end_reason: state.end_reason,
      origin_session_id: state.origin.session_id
    }
  end

  # The notes exist and are on disk; only the route out was missing. Saying so
  # in the row is what keeps `list_meetings` honest about where they are.
  defp unresolvable(state) do
    fail_with(
      state,
      :failed,
      :delivery_unresolvable,
      "delivery_unresolvable: summary saved at #{state.artifact_dir}"
    )
  end

  # --- terminal states ------------------------------------------------------

  defp complete(state) do
    state = goto(state, :delivered, %{ended_at: DateTime.utc_now()}, state.end_reason)

    MeetingTelemetry.run_complete(telemetry_meeting(state), %{
      duration_ms: duration_ms(state),
      segments: state.segments,
      words: state.words,
      participants_peak: state.participants_peak
    })

    {:stop, :normal, state}
  end

  defp fail(state, status, reason),
    do: fail_with(state, status, reason_atom(reason), describe(reason))

  defp fail_with(state, status, reason, error_text) do
    state = state |> teardown() |> goto(status, terminal_fields(error_text), reason)
    MeetingTelemetry.run_error(telemetry_meeting(state), Atom.to_string(status), error_text)
    {:stop, :normal, state}
  end

  defp terminal_fields(error_text), do: %{ended_at: DateTime.utc_now(), error: error_text}

  defp leave_then_fail(state, reason) do
    leave_source(state)
    fail(state, :failed, reason)
  end

  defp teardown(state) do
    state |> stop_source() |> stop_caffeinate() |> abort_stream() |> close_transcript()
  end

  # --- shared shapes --------------------------------------------------------

  defp telemetry_meeting(state) do
    %{
      id: state.id,
      platform: state.platform,
      session_id: state.session_id,
      parent_session: state.parent_session,
      origin: state.origin_kind,
      duration_ms: duration_ms(state)
    }
  end

  defp duration_ms(state), do: System.monotonic_time(:millisecond) - state.started_at_mono

  defp reason_atom(nil), do: nil
  defp reason_atom(reason) when is_atom(reason), do: reason

  defp reason_atom(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    tuple_reason_atom(elem(reason, 0))
  end

  defp reason_atom(_reason), do: :error

  defp tuple_reason_atom(head) when is_atom(head), do: head
  defp tuple_reason_atom(_head), do: :error

  # The Store caps `error` in BYTES, so the cap is applied in bytes here — a
  # grapheme cap would let a multibyte vendor message be refused, and a refused
  # write is how a failure loses the only sentence explaining it.
  defp describe(reason) when is_binary(reason), do: truncate(reason)
  defp describe(reason), do: reason |> inspect() |> truncate()

  defp truncate(text) when byte_size(text) <= @max_error_bytes, do: text

  # The cut lands mid-codepoint at most once; the leading valid run is the
  # longest prefix that is still UTF-8.
  defp truncate(text) do
    case String.chunk(binary_part(text, 0, @max_error_bytes), :valid) do
      [valid | _rest] -> valid
      [] -> ""
    end
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
