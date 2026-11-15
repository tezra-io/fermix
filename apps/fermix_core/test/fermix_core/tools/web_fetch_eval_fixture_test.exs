defmodule FermixCore.Tools.WebFetchEvalFixtureTest do
  # Sets and clears FERMIX_EVAL_FIXTURE_ORIGIN (one variable for the whole VM)
  # and, for the :prod compile, Mix's environment: neither may be seen by a
  # concurrently running test. Every manifest is in a temp home of the test's
  # own, handed to the code through its `home` seam; the running home is only
  # ever named, never written.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Net.Egress
  alias FermixCore.Net.Guard
  alias FermixCore.Net.PinnedUrl
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Tools.WebFetch
  alias FermixCore.Tools.WebFetch.EvalFixture
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TelemetryCapture

  @flag "FERMIX_EVAL_FIXTURE_ORIGIN"
  @port 4173
  @origin "http://127.0.0.1:#{@port}"
  @manifest Path.join("eval-fixtures", "fixture_server.json")
  @context %{agent_name: "test_agent", conversation_key: :test}
  @source Path.expand("../../../lib/fermix_core/tools/web_fetch/eval_fixture.ex", __DIR__)

  defmodule Page do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(test) when is_pid(test), do: test

    @impl true
    def call(conn, test) do
      send(test, {:fixture_request, conn.host, conn.port, conn.request_path, conn.query_string})
      respond(conn, conn.request_path)
    end

    defp respond(conn, "/s/tok/moved") do
      conn
      |> put_resp_header("location", "/s/tok/page.html")
      |> send_resp(302, "")
    end

    defp respond(conn, _path) do
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, "<h1>Brevany night market</h1><p>Opens at 18:00</p>")
    end
  end

  # Every test starts with the flag gone, and leaves it as it found it; each
  # gets an eval home of its own with no manifest in it yet.
  setup do
    previous = System.get_env(@flag)
    System.delete_env(@flag)
    on_exit(fn -> restore_flag(previous) end)

    home = SafeRm.make_tmp_dir!("eval-fixture-home")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home}
  end

  describe "decide/2" do
    test "the exact origin is allowed, whatever its path and query", %{home: home} do
      record_port!(home, @port)
      System.put_env(@flag, @origin)

      for url <- [
            @origin,
            @origin <> "/",
            @origin <> "/s/run-case-t1/form.html",
            @origin <> "/s/tok/page.html?day=2&x=%20y",
            "HTTP://127.0.0.1:#{@port}/s/tok/page.html"
          ] do
        assert EvalFixture.decide(url, home: home) == :allow, url
      end
    end

    test "another port, host or scheme, or a userinfo trick, goes to the guard", %{home: home} do
      record_port!(home, @port)
      System.put_env(@flag, @origin)

      for url <- [
            "http://127.0.0.1:#{@port + 1}/s/tok/page.html",
            "http://127.0.0.1/s/tok/page.html",
            "http://localhost:#{@port}/s/tok/page.html",
            "http://127.0.0.2:#{@port}/s/tok/page.html",
            "http://127.0.0.1.:#{@port}/s/tok/page.html",
            "http://[::1]:#{@port}/s/tok/page.html",
            "http://[::ffff:127.0.0.1]:#{@port}/s/tok/page.html",
            "https://127.0.0.1:#{@port}/s/tok/page.html",
            "ws://127.0.0.1:#{@port}/s/tok/page.html",
            "http://owner@127.0.0.1:#{@port}/s/tok/page.html",
            "http://127.0.0.1:#{@port}@10.0.0.7/s/tok/page.html",
            "http://127.0.0.1:#{@port}\\@10.0.0.7/s/tok/page.html",
            "//127.0.0.1:#{@port}/s/tok/page.html",
            "https://example.com/docs"
          ] do
        assert EvalFixture.decide(url, home: home) == :guard, url
      end
    end

    test "with the flag unset every URL goes to the guard, manifest or none", %{home: home} do
      url = @origin <> "/s/tok/page.html"
      assert EvalFixture.decide(url, home: home) == :guard
      assert EvalFixture.decide(url, home: Path.join(home, "no-such-home")) == :guard

      record_port!(home, @port)
      assert EvalFixture.decide(url, home: home) == :guard
    end

    test "a flag in any other form is refused for every URL", %{home: home} do
      record_port!(home, @port)

      for flag <- [
            "",
            " " <> @origin,
            @origin <> "/",
            @origin <> "/s",
            @origin <> "?x",
            "http://127.0.0.1",
            "http://127.0.0.1:",
            "http://127.0.0.1:0",
            "http://127.0.0.1:65536",
            "http://127.0.0.1:0#{@port}",
            "http://127.0.0.1:+#{@port}",
            "https://127.0.0.1:#{@port}",
            "HTTP://127.0.0.1:#{@port}",
            "http://localhost:#{@port}",
            "http://[::1]:#{@port}",
            "http://10.0.0.7:#{@port}",
            "127.0.0.1:#{@port}"
          ],
          url <- [@origin <> "/s/tok/page.html", "https://example.com/docs"] do
        System.put_env(@flag, flag)

        assert EvalFixture.decide(url, home: home) ==
                 {:error, {:invalid_eval_fixture_origin, flag}},
               inspect(flag)
      end
    end

    test "the flag in a home with no manifest is refused for every URL", %{home: home} do
      System.put_env(@flag, @origin)
      path = Path.join(home, @manifest)

      for url <- [@origin <> "/s/tok/page.html", "https://example.com/docs"] do
        assert EvalFixture.decide(url, home: home) ==
                 {:error, {:eval_fixture_manifest_missing, @origin, path}}
      end
    end

    test "the flag naming another port than the manifest is refused for every URL",
         %{home: home} do
      record_port!(home, @port + 7)
      System.put_env(@flag, @origin)
      path = Path.join(home, @manifest)

      for url <- [@origin <> "/s/tok/page.html", "http://127.0.0.1:#{@port + 7}/s/tok/x"] do
        assert EvalFixture.decide(url, home: home) ==
                 {:error, {:eval_fixture_port_mismatch, @origin, path, @port + 7}}
      end
    end

    test "a manifest that cannot be read as a port is refused for every URL", %{home: home} do
      System.put_env(@flag, @origin)
      path = Path.join(home, @manifest)

      for text <- [
            "",
            "not json",
            "[]",
            "{}",
            ~s({"port": "4173"}),
            ~s({"port": 0}),
            ~s({"port": 65536}),
            ~s({"port": true}),
            ~s({"port": 4173.0}),
            ~s({"door_port": 4173})
          ] do
        write_manifest!(home, text)

        assert {:error, {:eval_fixture_manifest_unreadable, @origin, ^path, reason}} =
                 EvalFixture.decide(@origin <> "/s/tok/page.html", home: home),
               text

        assert is_binary(reason) and reason != ""
      end
    end

    test "the home read by default is the running home" do
      System.put_env(@flag, @origin)
      path = Path.join(ConfigStore.fermix_home(), @manifest)
      refute File.exists?(path), "the suite's own home carries #{path}; it never should"

      assert EvalFixture.decide(@origin <> "/s/tok/page.html") ==
               {:error, {:eval_fixture_manifest_missing, @origin, path}}
    end

    test "the first port and the last are each a valid origin", %{home: home} do
      for port <- [1, 65_535] do
        record_port!(home, port)
        origin = "http://127.0.0.1:#{port}"
        System.put_env(@flag, origin)
        assert EvalFixture.decide(origin <> "/x", home: home) == :allow
      end
    end
  end

  describe "web_fetch with the flag set" do
    test "reads a page at the exact origin through the real connect path, with one tool event",
         %{home: home} do
      port = start_page!()
      record_port!(home, port)
      System.put_env(@flag, "http://127.0.0.1:#{port}")
      TelemetryCapture.attach([[:fermix, :tool, :exec]], :emitter)

      assert {:ok, %{success: true, output: output}} =
               WebFetch.execute(
                 %{"url" => "http://127.0.0.1:#{port}/s/tok/page.html?day=2"},
                 direct_context(home)
               )

      assert output =~ "Brevany night market"
      assert output =~ "18:00"
      assert_receive {:fixture_request, "127.0.0.1", ^port, "/s/tok/page.html", "day=2"}
      assert_received {:telemetry, [:fermix, :tool, :exec], _measurements, %{tool: "web_fetch"}}
      refute_received {:telemetry, [:fermix, :tool, :exec], _measurements, _metadata}
    end

    test "follows a redirect that stays on the origin", %{home: home} do
      port = start_page!()
      record_port!(home, port)
      System.put_env(@flag, "http://127.0.0.1:#{port}")

      assert {:ok, %{success: true, output: output}} =
               WebFetch.execute(
                 %{"url" => "http://127.0.0.1:#{port}/s/tok/moved"},
                 direct_context(home)
               )

      assert output =~ "Brevany night market"
      assert_receive {:fixture_request, "127.0.0.1", ^port, "/s/tok/moved", ""}
      assert_receive {:fixture_request, "127.0.0.1", ^port, "/s/tok/page.html", ""}
    end

    test "refuses a redirect from the origin to any other private address", %{home: home} do
      record_port!(home, @port)
      System.put_env(@flag, @origin)

      for target <- [
            "http://127.0.0.1:#{@port + 1}/admin",
            "http://localhost:#{@port}/s/tok/page.html",
            "http://127.0.0.2:#{@port}/s/tok/page.html",
            "http://[::1]:#{@port}/s/tok/page.html",
            "http://owner@127.0.0.1:#{@port}/s/tok/page.html",
            "https://127.0.0.1:#{@port}/s/tok/page.html",
            "http://10.0.0.7/secret",
            "http://169.254.169.254/latest/meta-data"
          ] do
        test_pid = self()

        adapter = fn request ->
          send(test_pid, {:hop, request.url.host, request.url.port})
          {request, Req.Response.new(status: 302, headers: [{"location", target}])}
        end

        assert {:ok, %{success: false, error: error}} =
                 WebFetch.execute(
                   %{"url" => @origin <> "/s/tok/start"},
                   adapter_context(adapter, home)
                 )

        assert error =~ "blocked_url", "#{target}: #{error}"
        assert_received {:hop, "127.0.0.1", @port}
        refute_received {:hop, _host, _port}, "#{target} was dialled"
      end
    end

    test "refuses another port, host or scheme on loopback as it does today", %{home: home} do
      record_port!(home, @port)
      System.put_env(@flag, @origin)
      adapter = fn _request -> flunk("a URL off the origin must not be requested") end

      for url <- [
            "http://127.0.0.1:#{@port + 1}/s/tok/page.html",
            "http://127.0.0.1/s/tok/page.html",
            "http://localhost:#{@port}/s/tok/page.html",
            "http://127.0.0.2:#{@port}/s/tok/page.html",
            "http://[::1]:#{@port}/s/tok/page.html",
            "https://127.0.0.1:#{@port}/s/tok/page.html",
            "http://owner@127.0.0.1:#{@port}/s/tok/page.html",
            "http://127.0.0.1:#{@port}@10.0.0.7/s/tok/page.html"
          ] do
        assert {:ok, %{success: false, error: error}} =
                 WebFetch.execute(%{"url" => url}, adapter_context(adapter, home))

        assert error =~ "blocked_url", "#{url}: #{error}"
      end
    end

    test "leaves the guard and PinnedUrl as strict as ever for every other caller",
         %{home: home} do
      record_port!(home, @port)
      System.put_env(@flag, @origin)
      url = @origin <> "/s/tok/page.html"

      assert Guard.resolve_and_validate(url) == {:error, {:blocked_host, :private_address}}
      assert Guard.validate(url) == {:error, {:blocked_host, :private_address}}
      assert PinnedUrl.pin(url) == {:error, {:blocked_host, :private_address}}
    end

    test "a flag in any other form fails every call, naming the flag, and logs it",
         %{home: home} do
      record_port!(home, @port)
      System.put_env(@flag, @origin <> "/")

      assert_every_call_refused(home, [
        @flag,
        inspect(@origin <> "/"),
        "http://127.0.0.1:<port>"
      ])
    end

    test "the flag in a home with no manifest fails every call, naming both, and logs it",
         %{home: home} do
      System.put_env(@flag, @origin)

      assert_every_call_refused(home, [
        @flag,
        inspect(@origin),
        "this home has no #{Path.join(home, @manifest)}"
      ])
    end

    test "the flag naming another port than the manifest fails every call, and logs it",
         %{home: home} do
      record_port!(home, @port + 7)
      System.put_env(@flag, @origin)

      assert_every_call_refused(home, [
        @flag,
        inspect(@origin),
        "#{Path.join(home, @manifest)} records port #{@port + 7}"
      ])
    end
  end

  test "with the flag unset, web_fetch refuses 127.0.0.1 as it does today", %{home: home} do
    record_port!(home, @port)
    adapter = fn _request -> flunk("a private address must not be requested") end

    assert {:ok, %{success: false, error: "blocked_url: private_address"}} =
             WebFetch.execute(
               %{"url" => @origin <> "/s/tok/page.html"},
               adapter_context(adapter, home)
             )
  end

  # The gate itself, compiled the way a release compiles it: the module's own
  # source, under a renamed module, with Mix's environment :prod while it
  # compiles. Its compiled-in environment is then :prod, so it must allow
  # nothing and read neither the variable nor the manifest: a malformed value,
  # or a home with no manifest, would be refused if either were read.
  test "the gate compiled for :prod allows nothing and reads neither flag nor manifest",
       %{home: home} do
    probe = prod_probe!()
    bare = Path.join(home, "no-manifest-home")
    record_port!(home, @port)

    for flag <- [@origin, @origin <> "/"], at <- [home, bare] do
      System.put_env(@flag, flag)
      assert probe.decide(@origin <> "/s/tok/page.html", home: at) == :guard, inspect(flag)
      assert probe.decide("https://example.com/docs", home: at) == :guard, inspect(flag)
    end

    # The same source compiled for :test honours the same flag in the same home,
    # so the probe above is not vacuous.
    System.put_env(@flag, @origin)
    assert EvalFixture.decide(@origin <> "/s/tok/page.html", home: home) == :allow
  end

  defp assert_every_call_refused(home, fragments) do
    adapter = fn _request -> flunk("nothing is requested while the flag is refused") end

    for url <- [@origin <> "/s/tok/page.html", "https://example.com/docs"] do
      {result, log} =
        with_log(fn -> WebFetch.execute(%{"url" => url}, adapter_context(adapter, home)) end)

      assert {:ok, %{success: false, error: error}} = result
      for fragment <- fragments, do: assert(error =~ fragment, "#{fragment}: #{error}")
      assert log =~ @flag
    end
  end

  defp prod_probe! do
    probe = Module.concat(__MODULE__, ProdProbe)
    source = File.read!(@source)
    original = "defmodule FermixCore.Tools.WebFetch.EvalFixture do"
    renamed = String.replace(source, original, "defmodule #{inspect(probe)} do")
    assert renamed != source, "#{@source} no longer defines #{original}"

    {modules, diagnostics} = compile_for_prod(renamed)
    assert diagnostics == [], "the :prod compile warned: #{inspect(diagnostics)}"
    assert [{^probe, _binary}] = modules

    on_exit(fn ->
      :code.purge(probe)
      :code.delete(probe)
    end)

    probe
  end

  defp compile_for_prod(source) do
    previous = Mix.env()
    Mix.env(:prod)

    try do
      Code.with_diagnostics(fn -> Code.compile_string(source, "eval_fixture_prod_probe.ex") end)
    after
      Mix.env(previous)
    end
  end

  defp record_port!(home, port), do: write_manifest!(home, Jason.encode!(%{"port" => port}))

  defp write_manifest!(home, text) do
    path = Path.join(home, @manifest)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
  end

  defp start_page! do
    server =
      start_supervised!(
        {Bandit, plug: {Page, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    port
  end

  defp direct_context(home),
    do: Map.merge(@context, %{net_egress: Egress.new([]), eval_fixture_home: home})

  defp adapter_context(adapter, home) do
    Map.merge(@context, %{
      req_options: [adapter: adapter],
      net_resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end,
      net_egress: Egress.new([]),
      eval_fixture_home: home
    })
  end

  defp restore_flag(nil), do: System.delete_env(@flag)
  defp restore_flag(value), do: System.put_env(@flag, value)
end
