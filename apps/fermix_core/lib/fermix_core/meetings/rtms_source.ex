defmodule FermixCore.Meetings.RtmsSource do
  @moduledoc """
  The Zoom capture lane: three outbound WebSockets, no browser, no sidecar.

  Zoom's Real-Time Media Streams hands a registered app the meeting's audio as
  one channel per participant, so this lane needs nothing running on the
  operator's machine and attributes speech by the platform's own identity. It
  works only where RTMS is enabled for the meeting — the operator's own account,
  or a host who has approved the operator's app — which is why an unconfigured
  or unauthorized Zoom lane refuses at the join gate rather than degrading into
  a second-best capture.

  ## The three legs

  1. **event** — the account's WebSocket event subscription, opened with a
     Server-to-Server OAuth token, waited on for `meeting.rtms_started` naming
     the meeting we were asked to join.
  2. **signaling** — the meeting's own signaling server, named by that event,
     opened with an HMAC signature over the meeting and stream ids. Its reply
     names the media server.
  3. **media** — the audio stream itself. Its handshake succeeding is what
     "admitted" means on this lane; there is no lobby, no knock, no chat.

  Every leg is outbound: Fermix opens all three and Zoom never calls in.

  ## No reconnect

  A leg that drops is terminal for the source, which reports
  `{:meeting_source_error, …}` and stops. The Session then finalizes whatever
  was captured (a meeting cut short still has notes worth delivering). Retrying
  a leg mid-meeting would silently produce a transcript with an unrecorded hole
  in it, which is worse than an honest early end.
  """

  @behaviour FermixCore.Meetings.AudioSource

  use GenServer

  require Logger

  alias FermixCore.Meetings.Config
  alias FermixCore.Meetings.Rtms.Mixer
  alias FermixCore.Meetings.Rtms.Protocol
  alias FermixCore.Meetings.Rtms.Transport
  alias FermixCore.Net.HttpClient

  # Internal bounds. None of these is a config key: they describe Zoom's
  # protocol, not an operator preference.
  @oauth_timeout_ms 10_000
  @ws_connect_timeout_ms 10_000
  @handshake_timeout_ms 15_000
  @keepalive_grace_ms 30_000

  # How long we wait for `meeting.rtms_started` after subscribing. Joining
  # before the host starts the meeting is normal, so this is generous; it exists
  # so a meeting that never starts releases the session instead of pinning it.
  @rtms_start_timeout_ms 120_000

  @stop_timeout_ms 5_000

  # Roster expiry is driven by pushed audio, so a meeting nobody transmits in
  # would never empty its roster and the Session's alone-timer would never arm.
  # This sweep gives the mixer's roster clock a source independent of audio; at
  # half the TTL a participant drops at most one interval late.
  @roster_sweep_ms div(Mixer.roster_ttl_ms(), 2)

  # The phase deadlines, gathered so the suite can shorten them. Nothing else
  # may override these: they are protocol bounds, not operator settings.
  @default_timers %{
    rtms_start_timeout_ms: @rtms_start_timeout_ms,
    handshake_timeout_ms: @handshake_timeout_ms,
    keepalive_grace_ms: @keepalive_grace_ms,
    roster_sweep_ms: @roster_sweep_ms
  }

  defstruct session: nil,
            meeting_no: nil,
            config: nil,
            transport: nil,
            transport_opts: [],
            token_fn: nil,
            clock_fn: nil,
            timers: @default_timers,
            phase: :connecting,
            legs: %{},
            stream: nil,
            mixer: nil,
            timer: nil,
            sweep_timer: nil,
            advanced_at_ms: 0,
            epoch: 0

  @typedoc "Where in the three-leg choreography this source is."
  @type phase :: :connecting | :event_wait | :signaling | :media | :streaming

  @doc """
  Starts the Zoom lane for one meeting.

  `args` requires `:meeting_no` (the numeric Zoom meeting id from
  `Meetings.Link`) and `:config` (a `Meetings.Config` snapshot). `:transport`,
  `:transport_opts`, `:token_fn`, `:timers` and `:clock_fn` (the monotonic
  millisecond reading the roster sweep ages the mixer by) are the test seams —
  the suite drives the whole state machine through a scripted transport on
  shortened deadlines, and never opens a socket.
  """
  @impl FermixCore.Meetings.AudioSource
  @spec start_link(pid(), map()) :: {:ok, pid()} | {:error, term()}
  def start_link(session, args) when is_pid(session) and is_map(args) do
    GenServer.start_link(__MODULE__, {session, args})
  end

  @impl FermixCore.Meetings.AudioSource
  @spec leave(pid()) :: :ok
  def leave(source) when is_pid(source), do: GenServer.cast(source, :leave)

  @impl FermixCore.Meetings.AudioSource
  @spec stop(pid()) :: :ok
  def stop(source) when is_pid(source) do
    if Process.alive?(source), do: GenServer.stop(source, :normal, @stop_timeout_ms)
    :ok
  catch
    # Already gone, or gone while we asked: `stop/1` promises idempotence, and a
    # dead source is exactly the state it promises.
    :exit, _reason -> :ok
  end

  @doc """
  Zero: the RTMS app is not a participant. Nothing of ours appears in the Zoom
  roster, so every roster entry is somebody else and the Session's alone-timer
  counts them all.
  """
  @impl FermixCore.Meetings.AudioSource
  @spec self_count() :: non_neg_integer()
  def self_count, do: 0

  @doc "The RTMS roster is speech-recency (`Rtms.Mixer` TTL), not presence."
  @impl true
  @spec presence_roster?() :: boolean()
  def presence_roster?, do: false

  # --- GenServer ---

  @impl GenServer
  def init({session, args}) do
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      session: session,
      meeting_no: Map.fetch!(args, :meeting_no),
      config: Map.fetch!(args, :config),
      transport: Map.get(args, :transport, Transport.WebSockex),
      transport_opts: Map.get(args, :transport_opts, []),
      token_fn: Map.get(args, :token_fn, &mint_token/1),
      clock_fn: Map.get(args, :clock_fn, &monotonic_ms/0),
      timers: Map.merge(@default_timers, Map.get(args, :timers, %{})),
      mixer: Mixer.new()
    }

    {:ok, state, {:continue, :open_event_leg}}
  end

  @impl GenServer
  def handle_continue(:open_event_leg, state) do
    with {:ok, token} <- state.token_fn.(state.config),
         url = Protocol.event_ws_url(state.config.zoom_ws_subscription_id, token),
         {:ok, conn} <- open(state, :event, url) do
      {:noreply, state |> put_leg(:event, conn) |> arm(:event_wait)}
    else
      {:error, reason} -> fail(state, {:rtms_connect_failed, reason})
    end
  end

  @impl GenServer
  def handle_cast(:leave, state) do
    state = drain_mixer(state)
    close_legs(state)
    send(state.session, {:meeting_ended, :left})
    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info({:rtms_ws, :event, {:message, message}}, state),
    do: on_event(Protocol.decode_event(message), state)

  def handle_info({:rtms_ws, :signaling, {:message, message}}, state),
    do: on_signaling(Protocol.decode_signaling(message), state)

  def handle_info({:rtms_ws, :media, {:message, message}}, state),
    do: on_media(Protocol.decode_media(message), state)

  def handle_info({:rtms_ws, tag, {:closed, reason}}, state),
    do: state |> drain_mixer() |> fail({:rtms_leg_closed, tag, reason})

  def handle_info({:phase_timeout, phase, epoch}, %{phase: phase, epoch: epoch} = state),
    do: on_timeout(phase, state)

  def handle_info({:phase_timeout, _phase, _epoch}, state), do: {:noreply, state}

  def handle_info(:roster_sweep, %{phase: :streaming} = state), do: sweep_roster(state)

  # Only the streaming phase sweeps; anything else is on its way out and must
  # not re-arm the timer.
  def handle_info(:roster_sweep, state), do: {:noreply, state}

  # A leg's socket process exiting after it already told us `{:closed, …}`. That
  # message is the authoritative signal and always precedes this one, so by the
  # time an EXIT for a known leg could be handled the source has already stopped.
  def handle_info({:EXIT, pid, reason}, state) do
    case leg_tag(state, pid) do
      nil -> {:noreply, state}
      tag -> state |> drain_mixer() |> fail({:rtms_leg_closed, tag, reason})
    end
  end

  # Every terminal path (leave, denied, ended, fail, a crash) returns through
  # here, so this is where both the sockets and the sweep timer are released.
  @impl GenServer
  def terminate(_reason, state) do
    cancel(state.sweep_timer)
    close_legs(state)
    :ok
  end

  # --- Event leg ---

  defp on_event({:rtms_started, %{meeting_no: no} = stream}, %{meeting_no: no} = state)
       when state.phase == :event_wait do
    send(state.session, {:meeting_phase, :joining, %{}})
    open_signaling(%{state | stream: stream})
  end

  defp on_event({:rtms_stopped, %{meeting_no: no}}, %{meeting_no: no} = state),
    do: state |> drain_mixer() |> ended(:meeting_closed)

  defp on_event({:protocol_error, reason}, state), do: fail(state, {:rtms_protocol_error, reason})
  defp on_event(_decoded, state), do: {:noreply, state}

  defp open_signaling(state) do
    signature = signature(state)

    handshake =
      Protocol.signaling_handshake(state.stream.meeting_uuid, stream_id(state), signature)

    with {:ok, conn} <- open(state, :signaling, state.stream.server_urls),
         :ok <- state.transport.send_json(conn, handshake) do
      {:noreply, state |> put_leg(:signaling, conn) |> arm(:signaling)}
    else
      {:error, reason} -> fail(state, {:rtms_signaling_failed, reason})
    end
  end

  # --- Signaling leg ---

  defp on_signaling({:handshake_ok, media_url}, state) when state.phase == :signaling,
    do: open_media(state, media_url)

  defp on_signaling({:handshake_failed, reason}, state), do: denied(state, reason)
  defp on_signaling({:keepalive, timestamp}, state), do: keepalive(state, :signaling, timestamp)

  defp on_signaling({:protocol_error, reason}, state),
    do: fail(state, {:rtms_protocol_error, reason})

  defp on_signaling(_decoded, state), do: {:noreply, state}

  defp open_media(state, media_url) do
    signature = signature(state)
    handshake = Protocol.media_handshake(state.stream.meeting_uuid, stream_id(state), signature)

    with {:ok, conn} <- open(state, :media, media_url),
         :ok <- state.transport.send_json(conn, handshake) do
      {:noreply, state |> put_leg(:media, conn) |> arm(:media)}
    else
      {:error, reason} -> fail(state, {:rtms_media_failed, reason})
    end
  end

  # --- Media leg ---

  defp on_media(:handshake_ok, state) when state.phase == :media do
    send(state.session, {:meeting_join_result, :admitted, %{}})
    {:noreply, state |> arm_sweep() |> arm(:streaming)}
  end

  defp on_media({:handshake_failed, reason}, state), do: denied(state, reason)
  defp on_media({:keepalive, timestamp}, state), do: keepalive(state, :media, timestamp)

  defp on_media({:audio, frame}, state) when state.phase == :streaming do
    {mixer, events} =
      Mixer.push(state.mixer, frame.user_id, frame.user_name, frame.pcm, frame.timestamp)

    forward(state.session, events)
    {:noreply, arm(%{state | mixer: mixer, advanced_at_ms: state.clock_fn.()}, :streaming)}
  end

  defp on_media({:stream_ended, _reason}, state),
    do: state |> drain_mixer() |> ended(:meeting_closed)

  defp on_media({:protocol_error, reason}, state), do: fail(state, {:rtms_protocol_error, reason})
  defp on_media(_decoded, state), do: {:noreply, state}

  # --- Terminal transitions ---

  defp on_timeout(:event_wait, state), do: fail(state, :rtms_start_timeout)
  defp on_timeout(:streaming, state), do: state |> drain_mixer() |> fail(:rtms_stream_lost)
  defp on_timeout(phase, state), do: fail(state, {:rtms_handshake_timeout, phase})

  defp denied(state, reason) do
    send(state.session, {:meeting_join_result, :denied, %{detail: reason}})
    {:stop, :normal, state}
  end

  defp ended(state, reason) do
    send(state.session, {:meeting_ended, reason})
    {:stop, :normal, state}
  end

  defp fail(state, reason) do
    send(state.session, {:meeting_source_error, reason})
    {:stop, :normal, state}
  end

  # --- Plumbing ---

  defp keepalive(state, tag, timestamp) do
    case Map.fetch(state.legs, tag) do
      {:ok, conn} ->
        report(state.transport.send_json(conn, Protocol.keepalive_response(timestamp)), tag)

      :error ->
        :ok
    end

    {:noreply, rearm_when_streaming(state)}
  end

  # A keep-alive that cannot go out means the leg is already gone; its own
  # `{:closed, …}` is what ends the source, so this only has to be visible.
  defp report(:ok, _tag), do: :ok

  defp report({:error, reason}, tag) do
    Logger.warning("Zoom RTMS keep-alive on the #{tag} leg failed: #{inspect(reason)}")
    :ok
  end

  defp rearm_when_streaming(%{phase: :streaming} = state),
    do: arm(state, :streaming)

  defp rearm_when_streaming(state), do: state

  # Ages the roster by the wall time since the mixer's clock last moved (a push
  # or the previous sweep), which is what makes an all-quiet meeting reach an
  # empty roster and the Session's alone-timer arm.
  defp sweep_roster(state) do
    now_ms = state.clock_fn.()
    {mixer, events} = Mixer.tick(state.mixer, now_ms - state.advanced_at_ms)
    forward(state.session, events)

    {:noreply, arm_sweep(%{state | mixer: mixer}, now_ms)}
  end

  defp arm_sweep(state), do: arm_sweep(state, state.clock_fn.())

  defp arm_sweep(state, now_ms) do
    cancel(state.sweep_timer)
    timer = Process.send_after(self(), :roster_sweep, state.timers.roster_sweep_ms)

    %{state | sweep_timer: timer, advanced_at_ms: now_ms}
  end

  defp open(state, tag, url) do
    opts =
      Keyword.merge(state.transport_opts, tag: tag, connect_timeout_ms: @ws_connect_timeout_ms)

    state.transport.connect(url, self(), opts)
  end

  defp signature(state) do
    Protocol.signature(
      state.config.zoom_client_id,
      state.config.zoom_client_secret,
      state.stream.meeting_uuid,
      stream_id(state)
    )
  end

  defp stream_id(state), do: state.stream.rtms_stream_id

  defp put_leg(state, tag, conn), do: %{state | legs: Map.put(state.legs, tag, conn)}

  defp leg_tag(state, pid) do
    Enum.find_value(state.legs, fn {tag, conn} -> if conn == pid, do: tag end)
  end

  defp close_legs(state) do
    Enum.each(state.legs, fn {_tag, conn} -> state.transport.close(conn) end)
  end

  defp drain_mixer(state) do
    {mixer, events} = Mixer.flush(state.mixer)
    forward(state.session, events)
    %{state | mixer: mixer}
  end

  defp forward(session, events), do: Enum.each(events, &send_event(session, &1))

  defp send_event(_session, {:audio, <<>>}), do: :ok
  defp send_event(session, {:audio, pcm}), do: send(session, {:meeting_audio, pcm})

  defp send_event(session, {:active_speaker, id, t_ms}),
    do: send(session, {:meeting_active_speaker, id, t_ms})

  defp send_event(session, {:roster, participants}),
    do: send(session, {:meeting_roster, participants})

  # Entering a phase always re-arms its deadline, and the epoch makes a timeout
  # message from the phase we just left inert rather than fatal.
  defp arm(state, phase) do
    cancel(state.timer)
    epoch = state.epoch + 1
    timer = Process.send_after(self(), {:phase_timeout, phase, epoch}, deadline(state, phase))
    %{state | phase: phase, timer: timer, epoch: epoch}
  end

  defp deadline(state, :event_wait), do: state.timers.rtms_start_timeout_ms
  defp deadline(state, :signaling), do: state.timers.handshake_timeout_ms
  defp deadline(state, :media), do: state.timers.handshake_timeout_ms
  defp deadline(state, :streaming), do: state.timers.keepalive_grace_ms

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer)

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  # --- Server-to-Server OAuth ---

  defp mint_token(%Config{} = config) do
    request =
      Protocol.oauth_request(
        config.zoom_account_id,
        config.zoom_client_id,
        config.zoom_client_secret
      )

    Req.new(url: request.url, method: :post, receive_timeout: @oauth_timeout_ms)
    |> put_headers(request.headers)
    |> HttpClient.request("Zoom RTMS OAuth")
    |> handle_oauth()
  end

  defp put_headers(req, headers) do
    Enum.reduce(headers, req, fn {name, value}, acc ->
      Req.Request.put_header(acc, name, value)
    end)
  end

  defp handle_oauth({:ok, %Req.Response{status: 200, body: body}}) when is_map(body),
    do: Protocol.decode_oauth(body)

  defp handle_oauth({:ok, %Req.Response{status: status}}) do
    Logger.error("Zoom RTMS OAuth failed: HTTP #{status}")
    {:error, {:oauth_rejected, status}}
  end

  defp handle_oauth({:error, reason}) do
    Logger.error("Zoom RTMS OAuth request failed: #{inspect(reason)}")
    {:error, {:oauth_unreachable, reason}}
  end
end
