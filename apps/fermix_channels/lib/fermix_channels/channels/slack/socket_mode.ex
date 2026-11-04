defmodule FermixChannels.Channels.Slack.SocketMode do
  @moduledoc """
  Slack's Socket Mode transport (M75 §12): how a host with no inbound port
  takes Slack events. It runs only when `[fermix_channels.slack] mode =
  "socket"` (`Gateway.ChannelRegistry`), and only on the primary: it is a
  channel transport, so a device-role engine never starts it
  (`FermixCore.Home.Role`).

  **Connecting.** `apps.connections.open`, with the app-level token
  (`slack_app_token`, `xapp-…`, scope `connections:write`), answers a one-time
  `wss://` address (`Slack.open_socket_url/1`), which the engine's client
  WebSocket dials (`FermixCore.Cues.Source.Stream.Socket`: the public-address
  check, the OS trust store, a frame cap). Every connection asks for a new
  address; one is never reused.

  **Envelopes.** An `events_api` envelope's payload is the Events API body the
  webhook receives, and goes to `Gateway.WebhookIngress.ingest/3`, the path
  `POST /webhook/slack` takes after its signature check: one dispatch path,
  with the same idempotency, authorization and turn. The envelope is
  acknowledged once that hand-off has answered `:ok`, as the webhook answers
  200 only then: the hand-off records the event's id and starts the turn's
  task, milliseconds against Slack's 3-second window. A hand-off that fails
  (the idempotency store or the task could not answer) is not acknowledged,
  so Slack sends the envelope again, as it retries a webhook that answered
  503; the failed hand-off forgot the ids it recorded, so the resend runs
  fresh, and a resend of one that did succeed is a duplicate there. A payload
  the adapter refuses is acknowledged and logged, since a resend would be
  refused the same way. `slash_commands` and `interactive` envelopes are
  acknowledged and logged: Fermix registers no handler for them on either
  transport. `hello` marks the connection live. `disconnect` (Slack
  refreshing the connection, or the app's Socket Mode turned off) closes it
  and opens a new one.

  **Reconnecting.** A connection that ends after at least 30 seconds of life
  is replaced at once, as Slack's routine refresh asks. One that ends sooner,
  or never opened, counts as a failure, and the next attempt waits 1 second,
  doubling to at most 60, for as long as the channel runs. Every attempt asks
  for a new address.

  **Liveness.** Every 30 seconds the connection is pinged; one that said
  nothing since the last ping is closed and replaced, so a connection that
  died without a word does not leave Slack silent.

  **Health.** The connection's posture is kept in `:persistent_term` and read
  without calling the process, and only while the process runs: it is erased
  when the process stops and never answered once it is gone, so a stopped
  connection never reads as the last one it reported. `poll_health/1`
  (registered as core's
  `:slack_socket_health_provider`, so `FermixCore.Health` reports it on the
  Slack channel entry) and `Slack.health_check/1` (Doctor). A failure is
  reported in Slack's own words (`invalid_auth`, `not_allowed_token_type`, …).
  Transitions into and out of `:degraded` emit `[:fermix, :channel,
  :transport]`.

  Options, each for a test only: `:name`, `:open_url` (replaces
  `Slack.open_socket_url/1`), `:ingest` (replaces `WebhookIngress.ingest/3`),
  `:socket_opts` (handed to the socket, such as `:cacerts` and `:guard`),
  `:ping_interval_ms` and `:clock` (monotonic milliseconds).
  """

  use GenServer

  require Logger

  alias FermixChannels.Channels.Slack
  alias FermixChannels.Gateway.WebhookIngress
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixCore.Cues.Source.Stream.Socket

  @handshake_timeout_ms 10_000
  # Socket Mode envelopes carry one event each; this is far above any of them.
  @max_frame_bytes 2 * 1_024 * 1_024
  @ping_interval_ms 30_000
  # A connection this old ended normally; younger, it counts as a failure.
  @stable_ms 30_000
  @backoff_initial_ms 1_000
  @backoff_max_ms 60_000

  @type status :: :connecting | :connected | :reconnecting | :degraded
  @type health :: %{
          status: status(),
          detail: String.t() | nil,
          since: DateTime.t(),
          consecutive_failures: non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc "The posture of the Socket Mode connection `name` runs, or `nil` where none runs."
  @spec poll_health(atom()) :: health() | nil
  def poll_health(name \\ __MODULE__) when is_atom(name) do
    if Process.whereis(name), do: :persistent_term.get(health_key(name), nil)
  end

  @doc "Drops the posture `name` recorded: when it stops, and in tests."
  @spec forget_poll_health(atom()) :: :ok
  def forget_poll_health(name \\ __MODULE__) when is_atom(name) do
    _erased? = :persistent_term.erase(health_key(name))
    :ok
  end

  defp health_key(name), do: {__MODULE__, name}

  @impl true
  def init(opts) do
    state = %{
      name: Keyword.fetch!(opts, :name),
      open_url: Keyword.get(opts, :open_url, fn -> Slack.open_socket_url() end),
      ingest: Keyword.get(opts, :ingest, &WebhookIngress.ingest/3),
      socket_opts: Keyword.get(opts, :socket_opts, []),
      ping_interval_ms: Keyword.get(opts, :ping_interval_ms, @ping_interval_ms),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      socket: nil,
      monitor: nil,
      connected_at: nil,
      seen?: false,
      failures: 0,
      timer: nil,
      health: nil
    }

    {:ok, record(state, :connecting, nil), {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl true
  def handle_info({:connect, token}, %{timer: %{kind: :connect, token: token}} = state),
    do: {:noreply, connect(%{state | timer: nil})}

  def handle_info({:liveness, token}, %{timer: %{kind: :liveness, token: token}} = state),
    do: {:noreply, liveness(%{state | timer: nil})}

  def handle_info({:cue_stream, socket, event}, %{socket: socket} = state),
    do: {:noreply, on_socket_event(event, %{state | seen?: true})}

  def handle_info({:DOWN, monitor, :process, _socket, reason}, %{monitor: monitor} = state),
    do: {:noreply, ended(%{state | socket: nil, monitor: nil}, reason)}

  # A timer this process has moved past, or a socket it already retired.
  def handle_info(_stale, state), do: {:noreply, state}

  # A process killed outright never reaches this; `poll_health/1` answers nil
  # for it because the name is free.
  @impl true
  def terminate(_reason, state) do
    if state.socket, do: Socket.close(state.socket)
    forget_poll_health(state.name)
  end

  # --- connecting ------------------------------------------------------------------

  defp connect(state) do
    with {:ok, url} <- state.open_url.(),
         {:ok, socket, monitor} <- Socket.start(url, self(), socket_opts(state)) do
      %{state | socket: socket, monitor: monitor, connected_at: nil, seen?: false}
    else
      {:error, reason} -> failed(state, reason)
    end
  end

  defp socket_opts(state) do
    [handshake_timeout: @handshake_timeout_ms, max_frame_bytes: @max_frame_bytes] ++
      state.socket_opts
  end

  defp on_socket_event(:connected, state), do: arm(state, :liveness, state.ping_interval_ms)
  defp on_socket_event(:pong, state), do: state

  defp on_socket_event({:frame, frame}, state) do
    :ok = Socket.ack(state.socket)
    on_frame(frame, state)
  end

  defp on_frame({:text, text}, state) do
    case Jason.decode(text) do
      {:ok, envelope} when is_map(envelope) ->
        on_envelope(envelope, state)

      _not_an_envelope ->
        Logger.warning("Slack Socket Mode: a frame that is not a JSON object was ignored")
        state
    end
  end

  defp on_frame({:binary, _payload}, state) do
    Logger.warning("Slack Socket Mode: a binary frame was ignored")
    state
  end

  # --- envelopes -------------------------------------------------------------------

  defp on_envelope(%{"type" => "hello"}, state) do
    %{state | connected_at: state.clock.()}
    |> record(:connected, nil)
  end

  defp on_envelope(%{"type" => "disconnect"} = envelope, state) do
    reason = Map.get(envelope, "reason", "unspecified")
    Logger.info("Slack Socket Mode: Slack closed the connection (#{reason}); reconnecting")
    state |> retire() |> ended({:slack_disconnect, reason})
  end

  defp on_envelope(%{"envelope_id" => id, "type" => type} = envelope, state)
       when is_binary(id) and id != "" do
    case deliver(type, id, Map.get(envelope, "payload"), state.ingest) do
      :acknowledge -> :ok = Socket.send_text(state.socket, Jason.encode!(%{envelope_id: id}))
      :let_slack_resend -> :ok
    end

    state
  end

  defp on_envelope(envelope, state) do
    Logger.warning(
      "Slack Socket Mode: an envelope of type #{inspect(Map.get(envelope, "type"))} with no " <>
        "envelope_id was ignored"
    )

    state
  end

  defp deliver("events_api", id, payload, ingest) when is_map(payload) do
    case ingest.(:slack, Slack, payload) do
      :ok ->
        :acknowledge

      {:error, {:parse, reason}} ->
        Logger.error("Slack Socket Mode: envelope #{id} is not a Slack event: #{inspect(reason)}")
        :acknowledge

      {:error, {:handoff, reason}} ->
        Logger.error(
          "Slack Socket Mode: envelope #{id} could not be handed off (#{inspect(reason)}); " <>
            "it is not acknowledged, so Slack sends it again"
        )

        :let_slack_resend
    end
  end

  defp deliver(type, id, _payload, _ingest) when type in ["slash_commands", "interactive"] do
    Logger.info(
      "Slack Socket Mode: #{type} envelope #{id} acknowledged; Fermix takes direct messages " <>
        "and mentions only"
    )

    :acknowledge
  end

  defp deliver(type, id, _payload, _ingest) do
    Logger.warning("Slack Socket Mode: envelope #{id} of type #{inspect(type)} acknowledged only")
    :acknowledge
  end

  # --- ending and reconnecting -----------------------------------------------------

  # The socket is closed and forgotten here, so its exit reaches no one.
  defp retire(%{socket: nil} = state), do: state

  defp retire(state) do
    Process.demonitor(state.monitor, [:flush])
    :ok = Socket.close(state.socket)
    %{state | socket: nil, monitor: nil}
  end

  defp liveness(%{seen?: true, socket: socket} = state) when is_pid(socket) do
    :ok = Socket.ping(socket)
    arm(%{state | seen?: false}, :liveness, state.ping_interval_ms)
  end

  defp liveness(%{socket: socket} = state) when is_pid(socket),
    do: state |> retire() |> ended(:silent)

  defp liveness(state), do: state

  # A connection that lived long enough ended the way Slack refreshes one and
  # is replaced at once; any other end is a failure and waits its backoff, as
  # does Slack turning the app's Socket Mode off, however long it lived.
  defp ended(state, {:slack_disconnect, "link_disabled"} = reason), do: failed(state, reason)

  defp ended(state, reason) do
    if stable?(state) do
      %{state | failures: 0, connected_at: nil}
      |> record(:reconnecting, nil)
      |> arm(:connect, 0)
    else
      failed(state, reason)
    end
  end

  defp stable?(%{connected_at: nil}), do: false
  defp stable?(state), do: state.clock.() - state.connected_at >= @stable_ms

  defp failed(state, reason) do
    failures = state.failures + 1
    sentence = sentence(reason)
    Logger.warning("Slack Socket Mode: #{sentence}; attempt #{failures} failed")

    %{state | failures: failures, connected_at: nil, socket: nil, monitor: nil}
    |> record(:degraded, sentence, error_class(reason))
    |> arm(:connect, backoff(failures))
  end

  defp backoff(failures),
    do: min(@backoff_initial_ms * Integer.pow(2, failures - 1), @backoff_max_ms)

  defp arm(state, kind, delay_ms) do
    token = make_ref()
    Process.send_after(self(), {kind, token}, delay_ms)
    %{state | timer: %{kind: kind, token: token, delay_ms: delay_ms}}
  end

  # --- health ----------------------------------------------------------------------

  # The posture is written before the transition is announced, so whoever
  # hears the event reads the posture it announces.
  defp record(state, status, detail, error_class \\ :none) do
    previous = state.health && state.health.status

    health = %{
      status: status,
      detail: detail,
      since: DateTime.utc_now(),
      consecutive_failures: if(status == :degraded, do: state.failures, else: 0)
    }

    :persistent_term.put(health_key(state.name), health)
    emit_transition(previous, status, state.failures, error_class)
    %{state | health: health}
  end

  defp emit_transition(:degraded, :degraded, _failures, _class), do: :ok

  defp emit_transition(_previous, :degraded, failures, class),
    do: ChannelTelemetry.emit_transport(:slack, :degraded, failures, class)

  defp emit_transition(:degraded, :connected, failures, _class),
    do: ChannelTelemetry.emit_transport(:slack, :recovered, failures, :none)

  defp emit_transition(_previous, _status, _failures, _class), do: :ok

  # The sentence health and Doctor show, in Slack's own words where Slack gave
  # some. Never a token: none reaches a reason.
  defp sentence(:not_configured),
    do: "the app-level token (slack_app_token) is not set; add it in Channels settings"

  defp sentence({:slack, code}), do: "Slack refused apps.connections.open: #{code}"

  defp sentence({:http_status, status}),
    do: "Slack answered apps.connections.open with HTTP #{status}"

  defp sentence({:unexpected_reply, what}),
    do: "Slack answered apps.connections.open with #{what}"

  defp sentence({:network, %{__exception__: true} = exception}),
    do: "Slack could not be reached: #{Exception.message(exception)}"

  defp sentence({:network, reason}), do: "Slack could not be reached: #{inspect(reason)}"

  defp sentence({:slack_disconnect, "link_disabled"}),
    do: "Slack turned Socket Mode off for this app (link_disabled)"

  defp sentence({:slack_disconnect, reason}), do: "Slack closed the connection (#{reason})"
  defp sentence(:silent), do: "the connection stopped answering"

  defp sentence(:proxy_unsupported_transport),
    do: "Socket Mode cannot run through the outbound proxy"

  defp sentence({:upgrade_refused, status}),
    do: "Slack refused the WebSocket with HTTP #{status}"

  defp sentence({:connect_failed, reason}),
    do: "the WebSocket to Slack could not be opened (#{inspect(reason)})"

  defp sentence({:remote_closed, code}), do: "Slack closed the WebSocket (code #{inspect(code)})"

  defp sentence(reason), do: "the connection ended (#{inspect(reason)})"

  defp error_class({:slack, _code}), do: :auth
  defp error_class(:not_configured), do: :not_configured
  defp error_class({:http_status, _status}), do: :http_status
  defp error_class({:network, _reason}), do: :network
  defp error_class({:slack_disconnect, _reason}), do: :remote_closed
  defp error_class(:silent), do: :timeout
  defp error_class(_reason), do: :socket
end
