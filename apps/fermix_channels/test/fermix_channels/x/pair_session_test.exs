defmodule FermixChannels.X.PairSessionTest do
  # The one pairing session (M63) against a stand-in Connect the test answers
  # call by call: each enrollment call reaches the test as
  # `{:enrollment, call, args, task}` and waits for `{:answer, value}`. The
  # loopback is the real one: the test plays the browser, writing each
  # callback to the port the start's link names with the `Host` a browser
  # sends. The ten-minute clock is injected and its expiry delivered by hand,
  # so nothing waits for time, and every session lives under a home of the
  # test's own.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixChannels.Test.XConnectHelper, as: Fixtures
  alias FermixChannels.X.Pairing
  alias FermixChannels.X.PairSession
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.WireSchema

  @origin "https://connect.fermix.example"
  @confirm_url "https://connect.fermix.example/confirm/frS-OLNTPoRzRh9g6Vk4QCCF"
  @enrollment_id "enr_5c1e9a3b7d2f"
  # A code in the contract's shape: 32 bytes of base64url.
  @code "TmjhwWYSW1Xzea591xi7qX5yLIFxNjO1fOVhLnU-a_U"
  # A call that crosses the loopback, a task and the session process.
  @await_ms 10_000
  @connect_schema :fermix_core
                  |> Application.app_dir("priv/connect/protocol.schema.json")
                  |> File.read!()
                  |> Jason.decode!()

  defmodule FakeEnrollment do
    @moduledoc false

    def create(origin, label, opts), do: ask(opts, :create, [origin, label])

    def prove(origin, enrollment_id, code, code_verifier, opts),
      do: ask(opts, :prove, [origin, enrollment_id, code, code_verifier])

    defp ask(opts, call, args) do
      send(Keyword.fetch!(opts, :test_pid), {:enrollment, call, args, self()})

      receive do
        {:answer, value} -> value
      end
    end
  end

  setup do
    home = SafeRm.make_tmp_dir!("x-pair-session")
    on_exit(fn -> SafeRm.rm_rf(home) end)
    clock = start_supervised!({Agent, fn -> 1_000 end})
    test_pid = self()

    opts = [
      pairing: [root: home],
      enrollment: FakeEnrollment,
      enrollment_opts: [test_pid: test_pid],
      clock: fn -> ~U[2026-10-16 05:01:02.345Z] end,
      monotonic: fn -> Agent.get(clock, & &1) end,
      timer: fn message, ms -> send(test_pid, {:timer, message, ms}) end,
      host_name: fn -> "Studio-Mac.local" end,
      on_approved: fn ->
        send(test_pid, :channel_started)
        {:ok, :started}
      end,
      emit: fn status, duration_us, _session ->
        send(test_pid, {:emitted, status, duration_us})
      end
    ]

    ctx = %{opts: opts, pairing: [root: home], home: home, clock: clock}
    Map.merge(ctx, session_server(ctx, []))
  end

  # A session server of the test's own, with `extra` over the setup's seams.
  defp session_server(ctx, extra) do
    name = :"x_pair_session_#{System.unique_integer([:positive])}"
    opts = Keyword.merge(ctx.opts, [name: name] ++ extra)
    server = start_supervised!({PairSession, opts}, id: name)
    %{server: server, call: [server: server]}
  end

  defp created do
    {:ok,
     %{
       enrollment_id: @enrollment_id,
       confirm_url: @confirm_url,
       expires_at: ~U[2026-10-16 05:10:00Z]
     }}
  end

  defp proof(overrides \\ %{}) do
    {connect_public, _seed} = Fixtures.connect_key()

    {:ok,
     Map.merge(
       %{
         instance_id: "ins_7f3c2a9e1b4d",
         tenant_id: "1234567890",
         handle: "@sujeeth",
         key_generation: 1,
         tenant_generation: 1,
         connect_key_id: "c2026a",
         connect_public_key: Base.url_encode64(connect_public, padding: false)
       },
       overrides
     )}
  end

  # Answers the call the session is making now, which must be `call`.
  defp answer(call, value) do
    assert_receive {:enrollment, ^call, args, task}
    send(task, {:answer, value})
    args
  end

  # Starts a session and answers its enrollment, returning the start's reply.
  defp start!(ctx, value \\ created()) do
    caller = Task.async(fn -> PairSession.start(@origin, ctx.call) end)
    answer(:create, value)
    Task.await(caller, @await_ms)
  end

  # An open session and the authorization request its link carries, as the
  # browser reads it.
  defp open!(ctx) do
    assert {:ok, %{session: session, confirm_url: url}} = start!(ctx)
    assert_receive {:timer, {:expire, id}, _ms}
    assert id == session.session_id
    {session, authorization(url)}
  end

  defp authorization(url) do
    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    %URI{port: port} = URI.parse(query["redirect_uri"])
    %{url: url, query: query, port: port, state: query["state"]}
  end

  # One browser request to the loopback, answered with its status line.
  defp browser_get(port, target, host \\ nil) do
    {:ok, conn} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    host = host || "127.0.0.1:#{port}"
    request = "GET #{target} HTTP/1.1\r\nHost: #{host}\r\nConnection: close\r\n\r\n"
    :ok = :gen_tcp.send(conn, request)
    {:ok, response} = :gen_tcp.recv(conn, 0, @await_ms)
    :ok = :gen_tcp.close(conn)
    response |> String.split("\r\n", parts: 2) |> hd()
  end

  defp callback(auth, query), do: browser_get(auth.port, "/callback?" <> URI.encode_query(query))

  defp approve!(auth), do: callback(auth, %{"code" => @code, "state" => auth.state})

  defp callback_url(auth, query),
    do: "http://127.0.0.1:#{auth.port}/callback?" <> URI.encode_query(query)

  # The listener the waiting loopback task owns, monitored, so a case can wait
  # for it to close rather than for time.
  defp monitor_listener(ctx, port) do
    %{flow: %Task{pid: flow}} = :sys.get_state(ctx.server)

    listener =
      Enum.find(Port.list(), fn candidate ->
        Port.info(candidate, :connected) == {:connected, flow} and
          :inet.port(candidate) == {:ok, port}
      end)

    assert listener, "no listener on port #{port}"
    {listener, Port.monitor(listener)}
  end

  defp assert_closed(port),
    do: assert({:error, :econnrefused} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary]))

  # Bounded by tries, never by time: each try is a round trip the session
  # answers after every message it already holds.
  defp wait_for(fun, tries \\ 50_000) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("the session never reached the expected state")
      true -> wait_for(fun, tries - 1)
    end
  end

  defp waiting?(server, count), do: length(:sys.get_state(server).waiting) == count

  defp challenge(verifier),
    do: :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

  describe "opening" do
    test "a start opens a session and answers the authorization link once", ctx do
      assert {:ok, %{session: session, confirm_url: url}} = start!(ctx)

      assert %{state: :awaiting_browser, ttl_ms: 600_000, origin: @origin} = session
      assert %{handle: nil, failure: nil} = session

      assert session.session_id =~
               ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

      refute session.session_id == @enrollment_id

      assert {:ok, read} = PairSession.get(session.session_id, ctx.call)
      assert read == session
      refute Map.has_key?(read, :confirm_url)

      assert_receive {:timer, {:expire, _id}, 600_000}
      assert {:ok, public_key} = Pairing.public_key(ctx.pairing)

      assert [@confirm_url, _query] = String.split(url, "?", parts: 2)
      auth = authorization(url)
      assert auth.port in 1..65_535

      assert auth.query == %{
               "response_type" => "code",
               "client_id" => Pairing.key_id(public_key),
               "redirect_uri" => "http://127.0.0.1:#{auth.port}/callback",
               "scope" => "",
               "code_challenge" => auth.query["code_challenge"],
               "code_challenge_method" => "S256",
               "state" => auth.state
             }

      assert WireSchema.errors(
               auth.query,
               WireSchema.ref("authorizationRequest"),
               @connect_schema
             ) ==
               []
    end

    test "the enrollment carries the origin and the host's label", ctx do
      caller = Task.async(fn -> PairSession.start(@origin, ctx.call) end)
      assert [@origin, "Studio-Mac.local"] = answer(:create, created())
      assert {:ok, _started} = Task.await(caller, @await_ms)
    end

    test "one session at a time: a start while one opens or is open is busy", ctx do
      caller = Task.async(fn -> PairSession.start(@origin, ctx.call) end)
      assert_receive {:enrollment, :create, _args, task}

      assert {:error, :pairing_active} = PairSession.start(@origin, ctx.call)

      send(task, {:answer, created()})
      assert {:ok, _started} = Task.await(caller, @await_ms)
      assert {:error, :pairing_active} = PairSession.start(@origin, ctx.call)
    end

    test "a pairing record on disk, readable or not, refuses the start", ctx do
      {:ok, public_key} = Pairing.ensure_key(ctx.pairing)
      {connect_public, _seed} = Fixtures.connect_key()
      record = Fixtures.record(connect_public, %{key_id: Pairing.key_id(public_key)})
      :ok = Pairing.save(record, ctx.pairing)

      assert {:error, :already_paired} = PairSession.start(@origin, ctx.call)

      File.chmod!(Pairing.record_path(ctx.pairing), 0o644)
      assert {:error, :already_paired} = PairSession.start(@origin, ctx.call)
      refute_received {:enrollment, :create, _args, _task}
    end

    test "a key that cannot be created refuses the start", ctx do
      dir = Path.dirname(Pairing.key_path(ctx.pairing))
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o755)

      log =
        capture_log(fn ->
          assert {:error, :key_unavailable} = PairSession.start(@origin, ctx.call)
        end)

      assert log =~ "the instance key could not be created"
      refute_received {:enrollment, :create, _args, _task}
    end

    test "Connect's refusals open nothing and name their reason", ctx do
      for {answer, reason} <- [
            {{:error, :connect_unreachable}, :connect_unreachable},
            {{:error, {:connect_refused, "rate_limited"}}, :connect_refused},
            {{:error, :unsupported_protocol}, :unsupported_protocol},
            {{:error, {:key_unavailable, :gone}}, :key_unavailable}
          ] do
        assert {:error, ^reason} = start!(ctx, answer)
        assert PairSession.latest(ctx.call) == nil
      end
    end

    test "an origin the contract cannot name is refused at the call", ctx do
      assert_raise ArgumentError, fn -> PairSession.start("https://x.example/path", ctx.call) end
    end
  end

  # The loopback's own configuration and its two failures, against a stand-in
  # for `OAuthFlow.await_authorization/2` the test drives: the real listener
  # cannot be made to fail on demand.
  describe "the loopback" do
    setup ctx do
      test_pid = self()

      authorize = fn provider, opts ->
        send(test_pid, {:authorize, provider, opts, self()})

        receive do
          {:authorized, result} -> result
        end
      end

      session_server(ctx, authorize: authorize)
    end

    test "is one authorization attempt at Connect's link, on a port the OS picks", ctx do
      caller = Task.async(fn -> PairSession.start(@origin, ctx.call) end)
      # The ten minutes started before the enrollment was opened.
      assert_receive {:enrollment, :create, _args, task}
      Agent.update(ctx.clock, &(&1 + 90_000))
      send(task, {:answer, created()})

      assert_receive {:authorize, provider, opts, _flow}
      {:ok, public_key} = Pairing.public_key(ctx.pairing)

      assert %{
               id: :fermix_connect,
               authorize_url: @confirm_url,
               token_url: "https://connect.fermix.example/v1/enrollments/enr_5c1e9a3b7d2f/prove",
               redirect_host: "127.0.0.1",
               redirect_port: 0,
               redirect_path: "/callback",
               scopes: [],
               fixed_port?: true,
               hardened_callback?: true,
               client_registration: :static
             } = provider

      assert provider.client_id == Pairing.key_id(public_key)
      assert opts[:paste_message] == :x_pair_callback
      assert opts[:timeout_ms] == 510_000

      assert :ok = opts[:opener].(@confirm_url <> "?state=example")

      assert {:ok, %{confirm_url: @confirm_url <> "?state=example"}} =
               Task.await(caller, @await_ms)
    end

    test "one that cannot listen opens nothing and says so", ctx do
      caller = Task.async(fn -> PairSession.start(@origin, ctx.call) end)
      answer(:create, created())
      assert_receive {:authorize, _provider, _opts, flow}

      log =
        capture_log(fn ->
          send(flow, {:authorized, {:error, {:listen_failed, 0, :eaddrnotavail}}})
          assert {:error, :loopback_unavailable} = Task.await(caller, @await_ms)
        end)

      assert log =~ "the listener the browser returns to failed"
      assert PairSession.latest(ctx.call) == nil
    end

    test "one that stops accepting fails the session", ctx do
      caller = Task.async(fn -> PairSession.start(@origin, ctx.call) end)
      answer(:create, created())
      assert_receive {:authorize, _provider, opts, flow}
      :ok = opts[:opener].(@confirm_url <> "?state=example")
      assert {:ok, %{session: session}} = Task.await(caller, @await_ms)

      capture_log(fn ->
        send(flow, {:authorized, {:error, {:accept_failed, :closed}}})
        assert_receive {:emitted, :failed, _duration_us}
      end)

      assert {:ok, %{state: :failed, failure: %{reason: :loopback_unavailable}}} =
               PairSession.get(session.session_id, ctx.call)
    end

    test "its own deadline ends the session expired", ctx do
      caller = Task.async(fn -> PairSession.start(@origin, ctx.call) end)
      answer(:create, created())
      assert_receive {:authorize, _provider, opts, flow}
      :ok = opts[:opener].(@confirm_url <> "?state=example")
      assert {:ok, %{session: session}} = Task.await(caller, @await_ms)

      send(flow, {:authorized, {:error, :callback_timeout}})
      assert_receive {:emitted, :expired, _duration_us}

      assert {:ok, %{state: :expired, ttl_ms: nil, failure: nil}} =
               PairSession.get(session.session_id, ctx.call)
    end
  end

  describe "the browser's return" do
    test "an approval proves the key with the code and writes the record of section 1", ctx do
      {session, auth} = open!(ctx)

      assert approve!(auth) == "HTTP/1.1 200 OK"
      assert [@origin, @enrollment_id, @code, verifier] = answer(:prove, proof())
      assert challenge(verifier) == auth.query["code_challenge"]

      assert_receive {:emitted, :approved, _duration_us}
      assert_receive :channel_started

      assert {:ok, %{state: :approved, ttl_ms: nil, failure: nil, handle: "@sujeeth"}} =
               PairSession.get(session.session_id, ctx.call)

      {:ok, public_key} = Pairing.public_key(ctx.pairing)
      assert {:ok, record} = Pairing.load(ctx.pairing)

      assert %Pairing{
               version: 1,
               origin: @origin,
               instance_id: "ins_7f3c2a9e1b4d",
               tenant_id: "1234567890",
               handle: "@sujeeth",
               key_generation: 1,
               tenant_generation: 1,
               connect_key_id: "c2026a",
               paired_at: "2026-10-16T05:01:02Z"
             } = record

      assert record.key_id == Pairing.key_id(public_key)
      assert_closed(auth.port)
    end

    test "a denial in the browser ends the session denied and asks Connect nothing", ctx do
      {session, auth} = open!(ctx)

      assert callback(auth, %{"error" => "access_denied", "state" => auth.state}) =~ " 400 "
      assert_receive {:emitted, :denied, _duration_us}

      assert {:ok, %{state: :denied, ttl_ms: nil, handle: nil}} =
               PairSession.get(session.session_id, ctx.call)

      assert {:error, :unpaired} = Pairing.load(ctx.pairing)
      refute_received {:enrollment, :prove, _args, _task}
    end

    test "a request of another attempt or host is refused and the session keeps waiting", ctx do
      {session, auth} = open!(ctx)
      wrong_state = %{"code" => @code, "state" => String.duplicate("A", 32)}

      assert callback(auth, wrong_state) == "HTTP/1.1 400 Bad Request"
      denied_elsewhere = %{"error" => "access_denied", "state" => "another-attempt-state"}
      assert callback(auth, denied_elsewhere) == "HTTP/1.1 400 Bad Request"

      target = "/callback?" <> URI.encode_query(%{"code" => @code, "state" => auth.state})

      assert browser_get(auth.port, target, "localhost:#{auth.port}") ==
               "HTTP/1.1 400 Bad Request"

      assert {:ok, %{state: :awaiting_browser}} = PairSession.get(session.session_id, ctx.call)
      refute_received {:enrollment, :prove, _args, _task}

      assert approve!(auth) == "HTTP/1.1 200 OK"
      assert [_origin, _id, @code, _verifier] = answer(:prove, proof())
      assert_receive {:emitted, :approved, _duration_us}
    end

    test "a callback Connect would never send fails the session and proves nothing", ctx do
      for {query, reason} <- [
            {%{"error" => "server_error"}, :connect_refused},
            {%{}, :unsupported_protocol},
            {%{"code" => "short"}, :unsupported_protocol}
          ] do
        {session, auth} = open!(ctx)

        capture_log(fn ->
          callback(auth, Map.put(query, "state", auth.state))
          assert_receive {:emitted, :failed, _duration_us}
        end)

        assert {:ok, %{state: :failed, failure: %{reason: ^reason}}} =
                 PairSession.get(session.session_id, ctx.call)

        refute_received {:enrollment, :prove, _args, _task}
      end
    end
  end

  describe "pasting the address" do
    test "an address pasted from a browser elsewhere completes the same way", ctx do
      {session, auth} = open!(ctx)
      url = callback_url(auth, %{"code" => @code, "state" => auth.state})

      assert {:ok, %{state: :awaiting_browser}} =
               PairSession.paste(session.session_id, url, ctx.call)

      assert [@origin, @enrollment_id, @code, verifier] = answer(:prove, proof())
      assert challenge(verifier) == auth.query["code_challenge"]
      assert_receive {:emitted, :approved, _duration_us}
      assert {:ok, _record} = Pairing.load(ctx.pairing)
    end

    test "a pasted denial ends the session denied", ctx do
      {session, auth} = open!(ctx)
      url = callback_url(auth, %{"error" => "access_denied", "state" => auth.state})

      assert {:ok, _waiting} = PairSession.paste(session.session_id, url, ctx.call)
      assert_receive {:emitted, :denied, _duration_us}
    end

    test "an address from another attempt changes nothing", ctx do
      {session, auth} = open!(ctx)

      for url <- [
            callback_url(auth, %{"code" => @code, "state" => String.duplicate("B", 32)}),
            "http://127.0.0.1:1/callback?" <>
              URI.encode_query(%{"code" => @code, "state" => auth.state}),
            "not an address"
          ] do
        assert {:ok, %{state: :awaiting_browser}} =
                 PairSession.paste(session.session_id, url, ctx.call)
      end

      assert approve!(auth) == "HTTP/1.1 200 OK"
      assert [_origin, _id, @code, _verifier] = answer(:prove, proof())
      assert_receive {:emitted, :approved, _duration_us}
    end

    test "a finished session has nothing waiting for an address", ctx do
      {session, auth} = open!(ctx)
      {:ok, _cancelled} = PairSession.cancel(session.session_id, ctx.call)
      url = callback_url(auth, %{"code" => @code, "state" => auth.state})

      assert {:error, :pairing_not_waiting} = PairSession.paste(session.session_id, url, ctx.call)
    end
  end

  describe "proving" do
    test "each refusal of the proof names its reason and writes nothing", ctx do
      for {connect, reason} <- [
            {{:error, {:connect_refused, "proof_rejected"}}, :proof_rejected},
            {{:error, {:connect_refused, "already_active"}}, :connect_refused},
            {{:error, {:connect_refused, "tenant_already_paired"}}, :connect_refused},
            {{:error, {:connect_refused, "key_already_paired"}}, :connect_refused},
            {{:error, :connect_unreachable}, :connect_unreachable},
            {{:error, :unsupported_protocol}, :unsupported_protocol},
            {{:error, {:key_unavailable, :gone}}, :key_unavailable}
          ] do
        {session, auth} = open!(ctx)
        approve!(auth)

        capture_log(fn ->
          answer(:prove, connect)
          assert_receive {:emitted, :failed, _duration_us}
        end)

        assert {:ok, %{state: :failed, failure: %{reason: ^reason}, handle: nil}} =
                 PairSession.get(session.session_id, ctx.call)

        assert {:error, :unpaired} = Pairing.load(ctx.pairing)
        refute_received :channel_started
      end
    end

    test "a record that cannot be written fails the session and says what to do", ctx do
      {session, auth} = open!(ctx)
      dir = Path.dirname(Pairing.record_path(ctx.pairing))
      File.chmod!(dir, 0o500)
      on_exit(fn -> File.chmod(dir, 0o700) end)
      approve!(auth)

      log =
        capture_log(fn ->
          answer(:prove, proof())
          assert_receive {:emitted, :failed, _duration_us}
        end)

      assert {:ok, %{state: :failed, failure: %{reason: :record_unwritable}}} =
               PairSession.get(session.session_id, ctx.call)

      assert log =~ "remove that installation from the Connect account page"
      File.chmod!(dir, 0o700)
    end

    test "a cancel, a paste or the expiry during the proof leaves its outcome to it", ctx do
      {session, auth} = open!(ctx)
      approve!(auth)
      assert_receive {:enrollment, :prove, _args, task}

      cancel = Task.async(fn -> PairSession.cancel(session.session_id, ctx.call) end)
      url = callback_url(auth, %{"code" => @code, "state" => auth.state})
      paste = Task.async(fn -> PairSession.paste(session.session_id, url, ctx.call) end)
      wait_for(fn -> waiting?(ctx.server, 2) end)

      send(ctx.server, {:expire, session.session_id})
      assert {:ok, %{state: :awaiting_browser}} = PairSession.get(session.session_id, ctx.call)

      send(task, {:answer, proof()})

      for waiter <- [cancel, paste],
          do: assert({:ok, %{state: :approved}} = Task.await(waiter, @await_ms))

      assert {:ok, _record} = Pairing.load(ctx.pairing)
    end
  end

  describe "ending and reading" do
    test "ten minutes after the start the session expires and its port closes", ctx do
      {session, auth} = open!(ctx)
      {listener, monitor} = monitor_listener(ctx, auth.port)
      Agent.update(ctx.clock, &(&1 + 90_000))

      assert {:ok, %{ttl_ms: 510_000}} = PairSession.get(session.session_id, ctx.call)

      send(ctx.server, {:expire, session.session_id})

      assert {:ok, %{state: :expired, ttl_ms: nil}} =
               PairSession.get(session.session_id, ctx.call)

      assert_receive {:emitted, :expired, 90_000_000}
      assert_receive {:DOWN, ^monitor, :port, ^listener, _reason}
      assert_closed(auth.port)
    end

    test "cancel closes an open session and its port, and the session stays readable", ctx do
      {session, auth} = open!(ctx)
      {listener, monitor} = monitor_listener(ctx, auth.port)

      assert {:ok, %{state: :cancelled, ttl_ms: nil}} =
               PairSession.cancel(session.session_id, ctx.call)

      assert_receive {:DOWN, ^monitor, :port, ^listener, _reason}
      assert_closed(auth.port)

      assert {:ok, %{state: :cancelled}} = PairSession.get(session.session_id, ctx.call)
      assert_receive {:emitted, :cancelled, _duration_us}
      assert PairSession.latest(ctx.call) == %{session_id: session.session_id, state: :cancelled}
    end

    test "a finished session answers a cancel unchanged", ctx do
      {session, auth} = open!(ctx)
      callback(auth, %{"error" => "access_denied", "state" => auth.state})
      assert_receive {:emitted, :denied, _duration_us}
      {:ok, denied} = PairSession.get(session.session_id, ctx.call)

      assert {:ok, ^denied} = PairSession.cancel(session.session_id, ctx.call)
    end

    test "a session this daemon does not hold is unknown", ctx do
      assert PairSession.latest(ctx.call) == nil

      for result <- [
            PairSession.get("unknown", ctx.call),
            PairSession.paste("unknown", "http://127.0.0.1:1/callback", ctx.call),
            PairSession.cancel("unknown", ctx.call)
          ],
          do: assert(result == {:error, :unknown_pairing_session})
    end

    test "a new start replaces the finished session", ctx do
      {first, _auth} = open!(ctx)
      {:ok, _cancelled} = PairSession.cancel(first.session_id, ctx.call)
      {second, _auth} = open!(ctx)

      assert {:error, :unknown_pairing_session} = PairSession.get(first.session_id, ctx.call)

      assert {:ok, %{state: :awaiting_browser}} = PairSession.get(second.session_id, ctx.call)

      assert PairSession.latest(ctx.call) == %{
               session_id: second.session_id,
               state: :awaiting_browser
             }
    end

    test "latest answers nil when no session server runs" do
      assert PairSession.latest(server: :x_pair_session_not_running) == nil
    end
  end
end
