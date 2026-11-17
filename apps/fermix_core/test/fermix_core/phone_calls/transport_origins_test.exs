defmodule FermixCore.PhoneCalls.TransportOriginsTest do
  @moduledoc """
  Where a build's phone calls go, decided once at the composition root
  (`FermixCore.Application.phone_call_transport_opts/2`) and handed to every
  call's worker and to the Manager's cleanup through `PhoneCalls.CallTransport`:
  only a development build reads `FERMIX_EVAL_FIXTURE_ORIGIN`, and there every
  create, hangup and attach goes to that loopback origin, the eval runners'
  simulated GPT-Live endpoint, or is refused; a release always gets the
  vendor's origins; a test build is handed a transport that refuses every
  call. No build sends a phone call's request to the vendor while the
  variable is set, and the GPT-Live adapter itself reads nothing from the
  environment.

  The build is the decision's own argument, so each build's answer is proved
  in this one. The development build's reading is the real one
  (`Tools.WebFetch.EvalFixture.origin/1`, which honours the variable in a
  development and a test build alike). Every stand-in binds loopback only;
  every key, password and number is invented; every manifest is in a temp home
  of the test's own.

  Sets and clears the variable, one for the whole VM, so it runs alone.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Application, as: CoreApplication
  alias FermixCore.Net.Egress
  alias FermixCore.PhoneCalls.CallTransport
  alias FermixTestSupport.SafeRm

  @flag "FERMIX_EVAL_FIXTURE_ORIGIN"
  @manifest Path.join("eval-fixtures", "fixture_server.json")
  @arrival_ms 10_000
  @api_key "sk-invented-key-0094"
  @session "live_u0_eval94"
  @credentials %{api_key: @api_key, sip_password: "pw-Invented-0094"}
  @direct Egress.new([])
  @vendor [base_url: "https://api.openai.com", ws_base_url: "wss://api.openai.com"]
  @adapter_sources [
    Path.expand("../../../lib/fermix_core/phone_calls/openai_live.ex", __DIR__),
    Path.expand("../../../lib/fermix_core/phone_calls/openai_live/sideband.ex", __DIR__)
  ]

  # Answers as the vendor documents and tells the test where each request
  # arrived: a create gets a session, a hangup an empty 200, an attach the
  # WebSocket upgrade.
  defmodule Stand do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, %{test: test}) do
      send(test, {:stand_saw, conn.method, conn.host, conn.port, conn.request_path})
      answer(conn, conn.method, String.ends_with?(conn.request_path, "/attach"), test)
    end

    defp answer(conn, "GET", true, test),
      do: upgrade_adapter(conn, :websocket, {Stand.Socket, %{test: test}, []})

    defp answer(conn, "POST", false, _test) do
      {:ok, _raw, conn} = read_body(conn)

      if String.ends_with?(conn.request_path, "/hangup"),
        do: send_resp(conn, 200, ""),
        else:
          send_resp(conn, 201, ~s({"session":{"id":"live_u0_eval94"},"transport":{"type":"sip"}}))
    end
  end

  defmodule Stand.Socket do
    @moduledoc false
    @behaviour WebSock

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_in(_frame, state), do: {:ok, state}

    @impl true
    def handle_info(_message, state), do: {:ok, state}
  end

  setup do
    Process.flag(:trap_exit, true)
    previous = System.get_env(@flag)
    System.delete_env(@flag)
    on_exit(fn -> restore_flag(previous) end)

    home = SafeRm.make_tmp_dir!("phone-eval-origin-home")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home}
  end

  describe "the GPT-Live adapter" do
    test "reads nothing from the environment: its origins are its caller's or the vendor's" do
      for path <- @adapter_sources, read <- environment_reads() do
        refute File.read!(path) =~ read, "#{Path.basename(path)} reads #{inspect(read)}"
      end
    end
  end

  describe "a release build" do
    test "gets the vendor's origins, whatever the variable and the manifest say", %{home: home} do
      record_port!(home, 4194)

      for flag <- [nil, "http://127.0.0.1:4194", "http://127.0.0.1:4194/", "https://api.invalid"],
          at <- [home, Path.join(home, "no-manifest-home")] do
        put_flag(flag)
        assert CoreApplication.phone_call_transport_opts(:prod, home: at) == @vendor, "#{flag}"
      end
    end
  end

  describe "a test build" do
    test "is handed a transport that refuses every call, whatever the variable says",
         %{home: home} do
      port = stand!()
      record_port!(home, port)

      for flag <- [nil, "http://127.0.0.1:#{port}"] do
        put_flag(flag)
        opts = CoreApplication.phone_call_transport_opts(:test, home: home)
        assert opts == [refused: :test_build]
        refused_everywhere!(opts, :test_build)
      end

      # The app tree's own wiring is that one.
      call_args = Keyword.fetch!(CoreApplication.phone_calls_opts(), :call_args)
      assert call_args.transport_opts == [refused: :test_build]
      refute_received {:stand_saw, _method, _host, _port, _path}
    end
  end

  describe "a development build" do
    test "with the variable unset, the vendor's origins", %{home: home} do
      record_port!(home, 4194)

      assert CoreApplication.phone_call_transport_opts(:dev, home: home) == @vendor
    end

    test "honours the exact origin its home records, for HTTP and the sideband alike",
         %{home: home} do
      # A phone-calls seed records the simulator beside the port.
      write_manifest!(home, Jason.encode!(%{"port" => 4194, "phone_calls" => true}))
      System.put_env(@flag, "http://127.0.0.1:4194")

      opts = CoreApplication.phone_call_transport_opts(:dev, home: home)
      assert opts == [base_url: "http://127.0.0.1:4194", ws_base_url: "ws://127.0.0.1:4194"]

      for url <- Keyword.values(opts) do
        assert %URI{host: "127.0.0.1", port: 4194} = URI.parse(url)
      end
    end

    test "refuses a variable it does not honour, never naming the vendor", %{home: home} do
      path = Path.join(home, @manifest)

      System.put_env(@flag, "http://127.0.0.1:4194/")

      assert CoreApplication.phone_call_transport_opts(:dev, home: home) ==
               [
                 refused:
                   {:eval_fixture_origin,
                    {:invalid_eval_fixture_origin, "http://127.0.0.1:4194/"}}
               ]

      System.put_env(@flag, "http://127.0.0.1:4194")

      assert CoreApplication.phone_call_transport_opts(:dev, home: home) ==
               [
                 refused:
                   {:eval_fixture_origin,
                    {:eval_fixture_manifest_missing, "http://127.0.0.1:4194", path}}
               ]

      record_port!(home, 4195)

      assert CoreApplication.phone_call_transport_opts(:dev, home: home) ==
               [
                 refused:
                   {:eval_fixture_origin,
                    {:eval_fixture_port_mismatch, "http://127.0.0.1:4194", path, 4195}}
               ]
    end

    test "a create and a hangup over its wiring reach the loopback stand-in", %{home: home} do
      port = stand!()
      record_port!(home, port)
      System.put_env(@flag, "http://127.0.0.1:#{port}")
      opts = CoreApplication.phone_call_transport_opts(:dev, home: home) ++ [egress: @direct]

      assert {:ok, %{session_id: @session, http_status: 201}} =
               CallTransport.create_session(request(), opts)

      assert_receive {:stand_saw, "POST", "127.0.0.1", ^port, "/v1/live/sessions"}, @arrival_ms

      assert {:ok, :accepted} = CallTransport.hangup(@session, @api_key, opts)

      assert_receive {:stand_saw, "POST", "127.0.0.1", ^port, "/v1/live/sessions/" <> hangup},
                     @arrival_ms

      assert hangup == @session <> "/hangup"
    end

    test "a refused variable refuses the create, the hangup and the attach; nothing is sent",
         %{home: home} do
      port = stand!()
      record_port!(home, port)
      System.put_env(@flag, "http://127.0.0.1:#{port}/")
      opts = CoreApplication.phone_call_transport_opts(:dev, home: home)

      assert [refused: {:eval_fixture_origin, {:invalid_eval_fixture_origin, _value}} = reason] =
               opts

      refused_everywhere!(opts ++ [egress: @direct], reason)
      refute_received {:stand_saw, _method, _host, _port, _path}
    end

    test "the sideband over its wiring attaches to the loopback stand-in", %{home: home} do
      port = stand!()
      record_port!(home, port)
      System.put_env(@flag, "http://127.0.0.1:#{port}")
      opts = CoreApplication.phone_call_transport_opts(:dev, home: home) ++ [egress: @direct]

      assert {:ok, pid} = CallTransport.attach(@session, @credentials, opts)

      assert_receive {:stand_saw, "GET", "127.0.0.1", ^port, path}, @arrival_ms
      assert path == "/v1/live/sessions/#{@session}/attach"
      assert_receive {:phone_sideband, ^pid, :attached}, @arrival_ms
      CallTransport.stop(pid)
    end

    test "the sideband refuses a variable it does not honour", %{home: home} do
      System.put_env(@flag, "http://127.0.0.1:4194")
      opts = CoreApplication.phone_call_transport_opts(:dev, home: home) ++ [egress: @direct]

      assert {:error, {:eval_fixture_origin, {:eval_fixture_manifest_missing, _value, _path}}} =
               CallTransport.attach(@session, @credentials, opts)
    end

    test "the Manager's cleanup goes over the same wiring", %{home: home} do
      port = stand!()
      record_port!(home, port)
      System.put_env(@flag, "http://127.0.0.1:#{port}/")
      opts = CoreApplication.phone_call_transport_opts(:dev, home: home)

      assert {:error, {:not_sent, {:eval_fixture_origin, _refusal}}} =
               CallTransport.hangup(@session, @api_key, opts)

      refute_received {:stand_saw, _method, _host, _port, _path}
    end
  end

  # Every create, hangup and attach over `opts` is refused for `reason`.
  defp refused_everywhere!(opts, reason) do
    assert {:error, {:not_sent, ^reason}} = CallTransport.create_session(request(), opts)
    assert {:error, {:not_sent, ^reason}} = CallTransport.hangup(@session, @api_key, opts)
    assert {:error, ^reason} = CallTransport.attach(@session, @credentials, opts)
  end

  defp environment_reads do
    [
      "System.get_env",
      "System.fetch_env",
      "Application.get_env",
      "Application.fetch_env",
      "Mix.env",
      "EvalFixture",
      @flag
    ]
  end

  defp request do
    %{
      api_key: @api_key,
      model: "gpt-live-1",
      instructions: "Ask whether a table for two is free at seven on 2026-12-04.",
      input: [],
      voice: "marin",
      destination: "+12125550147",
      trunk: %{
        provider_url: "sips:sip.invented-carrier.test:5061",
        username: "invented-user-94",
        password: "pw-Invented-0094",
        caller_number: "+16465550108"
      }
    }
  end

  defp stand! do
    server =
      start_supervised!(
        {Bandit, plug: {Stand, %{test: self()}}, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  defp record_port!(home, port), do: write_manifest!(home, Jason.encode!(%{"port" => port}))

  defp write_manifest!(home, text) do
    path = Path.join(home, @manifest)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
  end

  defp put_flag(nil), do: System.delete_env(@flag)
  defp put_flag(value), do: System.put_env(@flag, value)

  defp restore_flag(nil), do: System.delete_env(@flag)
  defp restore_flag(value), do: System.put_env(@flag, value)
end
