defmodule FermixChannels.Channels.Slack.SocketModeTest do
  # Slack Socket Mode (M75 §12) against a TLS WebSocket peer on loopback that
  # the test drives frame by frame (`FermixTestSupport.WebSocketPeer`), with
  # `apps.connections.open` answered by a `Req.Test` stub: no outside network.
  # The peer's certificate names a Slack-like host and is signed by a throwaway
  # root the socket is handed as `:cacerts`; the address check answers the
  # loopback address for it.
  #
  # async: false: the Slack channel settings live in application env, the
  # `Req.Test` stub is shared with the connection's process, and the hand-off
  # and transport telemetry carry no id of their own to pin on.
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Slack
  alias FermixChannels.Channels.Slack.SocketMode
  alias FermixChannels.Gateway.Idempotency
  alias FermixChannels.Gateway.WebhookIngress
  alias FermixCore.Health
  alias FermixCore.Net.Egress
  alias FermixTestSupport.TelemetryCapture
  alias FermixTestSupport.WebSocketPeer, as: Peer

  @host "wss-primary.slack.example.test"
  @app_token "xapp-1-A0TEST-0001-c0ffee"
  @wait_ms 10_000
  @stub :slack_socket_mode

  setup do
    previous = Application.fetch_env(:fermix_channels, :slack)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:fermix_channels, :slack, value)
        :error -> Application.delete_env(:fermix_channels, :slack)
      end
    end)

    # No owner and no allowed ids: an event handed to the gateway is refused
    # there, so no turn runs and nothing is sent back.
    Application.put_env(:fermix_channels, :slack,
      enabled: true,
      mode: :socket,
      bot_token: "xoxb-socket-mode-test",
      app_token: @app_token,
      req_options: [plug: {Req.Test, @stub}]
    )

    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)

    clock = :atomics.new(1, signed: true)
    %{listener: Peer.listen(name: @host), clock: clock}
  end

  # `apps.connections.open` answers a new ticket on every call and tells the
  # test which token asked; `auth.test` answers for the bot token.
  defp stub_slack(ctx, answer \\ :ok) do
    test = self()
    calls = :counters.new(1, [])
    port = ctx.listener.port

    Req.Test.stub(@stub, fn conn ->
      case {conn.request_path, answer} do
        {"/api/apps.connections.open", :ok} ->
          :counters.add(calls, 1, 1)
          ticket = "t#{:counters.get(calls, 1)}"
          send(test, {:connections_open, Plug.Conn.get_req_header(conn, "authorization")})
          url = "wss://#{@host}:#{port}/link/?ticket=#{ticket}&app_id=A0TEST"
          Req.Test.json(conn, %{"ok" => true, "url" => url})

        {"/api/apps.connections.open", {:refused, code}} ->
          send(test, {:connections_open, Plug.Conn.get_req_header(conn, "authorization")})
          Req.Test.json(conn, %{"ok" => false, "error" => code})

        {"/api/auth.test", _answer} ->
          Req.Test.json(conn, %{"ok" => true, "team" => "Acme Lab"})

        {_other, _answer} ->
          Req.Test.json(conn, %{"ok" => true})
      end
    end)
  end

  # `extra` adds options (`:ingest`) and `:restart` sets the child's restart.
  defp start_socket_mode(ctx, extra \\ []) do
    name = :"slack_socket_mode_#{System.unique_integer([:positive])}"
    clock = ctx.clock
    {restart, extra} = Keyword.pop(extra, :restart, :permanent)
    on_exit(fn -> SocketMode.forget_poll_health(name) end)

    opts =
      [
        name: name,
        socket_opts: [
          cacerts: ctx.listener.cacerts,
          guard: fn _url -> {:ok, {127, 0, 0, 1}} end,
          egress: %Egress{}
        ],
        ping_interval_ms: 3_600_000,
        clock: fn -> :atomics.get(clock, 1) end
      ] ++ extra

    pid = start_supervised!(Supervisor.child_spec({SocketMode, opts}, id: name, restart: restart))
    {name, pid}
  end

  defp text(peer, map), do: Peer.send_raw(peer, Peer.frame(:text, Jason.encode!(map)))

  defp assert_acked(peer, envelope_id) do
    assert_receive {:ws_peer, ^peer, {:frame, :text, payload}}, @wait_ms
    assert Jason.decode!(payload) == %{"envelope_id" => envelope_id}
  end

  # Frames are handled in order, so the acknowledgement of an envelope sent
  # after `hello` proves `hello` was handled: an event to wait for, not a time.
  defp hello(peer) do
    text(peer, %{"type" => "hello", "num_connections" => 1})
    sync(peer)
  end

  # The next acknowledgement the peer sees is this envelope's: every frame sent
  # before it was handled, and none of them was acknowledged.
  defp sync(peer) do
    sync = "sync-#{System.unique_integer([:positive])}"
    text(peer, %{"envelope_id" => sync, "type" => "slash_commands", "payload" => %{}})
    assert_acked(peer, sync)
  end

  defp event_envelope(id, ts, retry_attempt) do
    %{
      "envelope_id" => id,
      "type" => "events_api",
      "accepts_response_payload" => false,
      "retry_attempt" => retry_attempt,
      "retry_reason" => if(retry_attempt == 0, do: "", else: "timeout"),
      "payload" => slack_dm(ts)
    }
  end

  # A peer for the next connection, the token that connection asked with, and
  # the ticket it dialed.
  defp accept_connection(ctx, ticket) do
    peer = Peer.accept(ctx.listener)
    assert_receive {:connections_open, ["Bearer " <> @app_token]}, @wait_ms
    assert_receive {:ws_peer, ^peer, {:upgrade, request}}, @wait_ms
    assert request.target == "/link/?ticket=#{ticket}&app_id=A0TEST"
    assert request.sni == @host
    peer
  end

  defp slack_dm(ts) do
    %{
      "type" => "event_callback",
      "team_id" => "T0TEST",
      "api_app_id" => "A0TEST",
      "event_id" => "Ev#{ts}",
      "event" => %{
        "type" => "message",
        "channel" => "D0TEST",
        "channel_type" => "im",
        "user" => "U0TEST",
        "text" => "hello over socket mode",
        "ts" => ts
      }
    }
  end

  test "hello marks the connection up, opened with the app-level token", ctx do
    stub_slack(ctx)
    {name, _pid} = start_socket_mode(ctx)
    peer = accept_connection(ctx, "t1")

    hello(peer)

    assert %{status: :connected, detail: nil, consecutive_failures: 0} =
             SocketMode.poll_health(name)
  end

  test "an events_api envelope is acknowledged and handed to the webhook path once", ctx do
    stub_slack(ctx)
    {_name, _pid} = start_socket_mode(ctx)
    peer = accept_connection(ctx, "t1")
    hello(peer)
    TelemetryCapture.attach([[:fermix, :channel, :webhook]], channel: :slack)

    ts = "#{System.unique_integer([:positive])}.000100"

    text(peer, %{
      "envelope_id" => "env-first",
      "type" => "events_api",
      "accepts_response_payload" => false,
      "retry_attempt" => 0,
      "retry_reason" => "",
      "payload" => slack_dm(ts)
    })

    assert_acked(peer, "env-first")

    assert_receive {:telemetry, [:fermix, :channel, :webhook], %{count: 1, duplicates: 0},
                    %{channel: :slack}},
                   @wait_ms

    # Slack resends an envelope whose acknowledgement it missed: acknowledged
    # again, and dropped by the webhook path's idempotency.
    text(peer, %{
      "envelope_id" => "env-retry",
      "type" => "events_api",
      "accepts_response_payload" => false,
      "retry_attempt" => 1,
      "retry_reason" => "timeout",
      "payload" => slack_dm(ts)
    })

    assert_acked(peer, "env-retry")

    assert_receive {:telemetry, [:fermix, :channel, :webhook], %{count: 0, duplicates: 1},
                    %{channel: :slack}},
                   @wait_ms

    assert :duplicate = Idempotency.check_and_record(:slack, ts)
  end

  # The envelope is acknowledged only once the hand-off answered `:ok`, as the
  # webhook answers 200 only then: one whose hand-off failed is left for Slack
  # to send again, and the resend is handed off fresh and acknowledged.
  test "a hand-off that fails is not acknowledged, and Slack's resend is", ctx do
    stub_slack(ctx)
    attempts = :counters.new(1, [])

    ingest = fn channel, module, payload ->
      :counters.add(attempts, 1, 1)

      if :counters.get(attempts, 1) == 1,
        do: {:error, {:handoff, :task_supervisor_unavailable}},
        else: WebhookIngress.ingest(channel, module, payload)
    end

    {_name, _pid} = start_socket_mode(ctx, ingest: ingest)
    peer = accept_connection(ctx, "t1")
    hello(peer)
    TelemetryCapture.attach([[:fermix, :channel, :webhook]], channel: :slack)
    ts = "#{System.unique_integer([:positive])}.000200"

    text(peer, event_envelope("env-handoff", ts, 0))
    sync(peer)
    assert :counters.get(attempts, 1) == 1

    text(peer, event_envelope("env-handoff", ts, 1))
    assert_acked(peer, "env-handoff")

    assert_receive {:telemetry, [:fermix, :channel, :webhook], %{count: 1, duplicates: 0},
                    %{channel: :slack}},
                   @wait_ms
  end

  test "a payload that is not a Slack event is acknowledged, since a resend is refused too",
       ctx do
    stub_slack(ctx)
    {_name, _pid} = start_socket_mode(ctx)
    peer = accept_connection(ctx, "t1")
    hello(peer)

    text(peer, %{
      "envelope_id" => "env-unparsable",
      "type" => "events_api",
      "payload" => %{"type" => "event_callback"}
    })

    assert_acked(peer, "env-unparsable")
  end

  # Health reads the posture without calling the process, so a stopped or
  # killed connection must not keep answering the last posture it recorded.
  test "the posture does not outlive the connection's process", ctx do
    stub_slack(ctx)
    {stopped, pid} = start_socket_mode(ctx, restart: :temporary)
    peer = accept_connection(ctx, "t1")
    hello(peer)
    assert %{status: :connected} = SocketMode.poll_health(stopped)

    :ok = GenServer.stop(pid)
    assert SocketMode.poll_health(stopped) == nil
    assert :persistent_term.get({SocketMode, stopped}, :erased) == :erased

    {killed, pid} = start_socket_mode(ctx, restart: :temporary)
    assert %{} = SocketMode.poll_health(killed)
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, @wait_ms

    assert %{} = :persistent_term.get({SocketMode, killed}, nil)
    assert SocketMode.poll_health(killed) == nil
  end

  test "a disconnect envelope closes the connection and opens one at a new address", ctx do
    stub_slack(ctx)
    {name, _pid} = start_socket_mode(ctx)
    peer = accept_connection(ctx, "t1")
    hello(peer)

    # Connected for longer than a refresh needs, so it is replaced at once.
    :atomics.put(ctx.clock, 1, 31_000)
    next_peer = Peer.accept(ctx.listener)
    text(peer, %{"type" => "disconnect", "reason" => "refresh_requested"})

    assert_receive {:ws_peer, ^peer, {:frame, :close, <<1000::16>>}}, @wait_ms
    assert_receive {:connections_open, ["Bearer " <> @app_token]}, @wait_ms
    assert_receive {:ws_peer, ^next_peer, {:upgrade, request}}, @wait_ms
    assert request.target == "/link/?ticket=t2&app_id=A0TEST"

    hello(next_peer)
    assert %{status: :connected} = SocketMode.poll_health(name)
  end

  test "a dropped connection is degraded, waits its backoff, and recovers", ctx do
    stub_slack(ctx)
    {name, pid} = start_socket_mode(ctx)
    peer = accept_connection(ctx, "t1")
    hello(peer)
    TelemetryCapture.attach([[:fermix, :channel, :transport]], channel: :slack)

    Peer.close_tcp(peer)

    assert_receive {:telemetry, [:fermix, :channel, :transport], %{consecutive_failures: 1},
                    %{status: :degraded, error_class: :socket}},
                   @wait_ms

    assert %{status: :degraded, consecutive_failures: 1} = SocketMode.poll_health(name)

    # The backoff's expiry, delivered by hand rather than waited for.
    assert %{timer: %{kind: :connect, delay_ms: 1_000, token: token}} = :sys.get_state(pid)
    next_peer = Peer.accept(ctx.listener)
    send(pid, {:connect, token})

    assert_receive {:connections_open, ["Bearer " <> @app_token]}, @wait_ms
    assert_receive {:ws_peer, ^next_peer, {:upgrade, _request}}, @wait_ms
    hello(next_peer)

    assert_receive {:telemetry, [:fermix, :channel, :transport], _measurements,
                    %{status: :recovered}},
                   @wait_ms

    assert %{status: :connected, consecutive_failures: 0} = SocketMode.poll_health(name)
  end

  test "an app-level token Slack refuses reaches health and Doctor in Slack's own words", ctx do
    stub_slack(ctx, {:refused, "invalid_auth"})
    TelemetryCapture.attach([[:fermix, :channel, :transport]], channel: :slack)
    {name, _pid} = start_socket_mode(ctx)

    assert_receive {:connections_open, ["Bearer " <> @app_token]}, @wait_ms

    assert_receive {:telemetry, [:fermix, :channel, :transport], %{consecutive_failures: 1},
                    %{status: :degraded, error_class: :auth}},
                   @wait_ms

    assert %{status: :degraded, detail: detail} = SocketMode.poll_health(name)
    assert detail == "Slack refused apps.connections.open: invalid_auth"

    report =
      Health.report(
        boot_report: %{status: :ready, failures: [], config_path: "config.toml"},
        process_resolver: fn _child -> nil end,
        transport_health: fn
          :slack_socket_health_provider -> SocketMode.poll_health(name)
          _other -> nil
        end,
        engine_role: :primary
      )

    slack = Enum.find(report.channels, &(&1.name == "slack"))
    assert %{status: :degraded, mode: :socket, transport: %{detail: ^detail}} = slack

    assert {:error, {:misconfigured, sentence}} =
             Slack.health_check(socket_health: SocketMode.poll_health(name))

    assert sentence =~ "Socket Mode is down: Slack refused apps.connections.open: invalid_auth"
  end
end
