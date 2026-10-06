defmodule FermixCore.Net.EgressTest do
  # async: true — every assertion is over a struct this test builds or a
  # loopback listener it owns. Nothing here reads the `:network` or `:egress`
  # application environment: the egress under test is always passed in.
  use ExUnit.Case, async: true

  alias FermixCore.Net.Egress

  @proxied Egress.new(
             proxy: "http://proxy.test:3128",
             proxy_bypass: ["ollama.internal", ".corp.test"]
           )
  @direct Egress.new([])

  describe "normalize/1" do
    test "an absent or empty section is no proxy" do
      assert Egress.normalize(nil) == []
      assert Egress.normalize(%{}) == []
      assert Egress.normalize([]) == []
      assert Egress.new([]) == %Egress{proxy: nil, bypass: []}
    end

    test "accepts the TOML shape and the application-environment shape alike" do
      toml = %{"proxy" => "http://proxy.test:3128/", "proxy_bypass" => ["Ollama.Internal"]}
      normalized = Egress.normalize(toml)

      assert normalized == [proxy: "http://proxy.test:3128", proxy_bypass: ["ollama.internal"]]
      # Idempotent: what a save writes back is what the next load reads.
      assert Egress.normalize(normalized) == normalized
    end

    test "builds the struct every connector reads" do
      assert @proxied == %Egress{
               proxy: %{host: "proxy.test", port: 3128},
               bypass: ["ollama.internal", ".corp.test"]
             }
    end

    test "refuses a proxy it cannot use without printing the value" do
      for value <- [
            "socks5://secret.test:1080",
            "https://proxy.test:3128",
            "http://user:hunter2@proxy.test:3128",
            "http://proxy.test",
            "http://proxy.test:3128/path",
            "http://proxy.test:3128?x=1",
            "proxy.test:3128",
            "http://:3128",
            "http://proxy.test:99999",
            "http://[::1]:3128"
          ] do
        error = assert_raise ArgumentError, fn -> Egress.normalize(%{"proxy" => value}) end

        assert error.message =~ "[fermix_core.network] proxy"
        refute error.message =~ value
        refute error.message =~ "hunter2"
      end
    end

    test "refuses a proxy of the wrong type" do
      assert_raise ArgumentError, ~r/\[fermix_core.network\] proxy/, fn ->
        Egress.normalize(%{"proxy" => 3128})
      end
    end

    test "refuses bypass entries that could not mean what the operator intends" do
      for entry <- ["", "*", "*.corp.test", "http://a.test", "a.test:443", "a b", ".10.0.0.1"] do
        assert_raise ArgumentError, ~r/\[fermix_core.network\] proxy_bypass/, fn ->
          Egress.normalize(%{"proxy" => "http://proxy.test:3128", "proxy_bypass" => [entry]})
        end
      end

      assert_raise ArgumentError, ~r/\[fermix_core.network\] proxy_bypass/, fn ->
        Egress.normalize(%{"proxy" => "http://proxy.test:3128", "proxy_bypass" => "a.test"})
      end
    end

    test "names a refused bypass entry by position, never by value" do
      error =
        assert_raise ArgumentError, fn ->
          Egress.normalize(%{
            "proxy" => "http://proxy.test:3128",
            "proxy_bypass" => ["ok.test", "http://user:hunter2@internal.test"]
          })
        end

      assert error.message =~ "proxy_bypass entry 2"
      refute error.message =~ "hunter2"
      refute error.message =~ "internal.test"
    end

    # An operator who comments `proxy` out for an afternoon must not find the
    # daemon, and every CLI verb with it, refusing to start.
    test "a bypass list with no proxy is kept and has no effect" do
      assert Egress.normalize(%{"proxy_bypass" => ["a.test"]}) == [proxy_bypass: ["a.test"]]

      egress = Egress.new(proxy_bypass: ["a.test"])
      assert Egress.route(egress, "https://a.test/") == :direct
      assert Egress.route(egress, "https://b.test/") == :direct
      assert Egress.describe(egress) == nil
    end

    test "refuses an unknown key rather than running without the proxy it was meant to set" do
      assert_raise ArgumentError, ~r/\[fermix_core.network\] has unknown key\(s\): proxi/, fn ->
        Egress.normalize(%{"proxi" => "http://proxy.test:3128"})
      end
    end
  end

  describe "route/2" do
    test "everything is direct when no proxy is configured" do
      assert Egress.route(@direct, "https://api.openai.com/v1/responses") == :direct
    end

    test "a public host leaves through the proxy" do
      assert Egress.route(@proxied, "https://api.openai.com/v1/responses") ==
               {:proxy, %{host: "proxy.test", port: 3128}}

      assert {:proxy, _proxy} = Egress.route(@proxied, URI.parse("http://example.test/x"))
      assert {:proxy, _proxy} = Egress.route(@proxied, "wss://gateway.discord.gg/?v=10")
      assert {:proxy, _proxy} = Egress.route(@proxied, "https://93.184.216.34/")
    end

    test "this machine and private addresses are direct by construction" do
      for url <- [
            "http://localhost:11434/v1",
            "http://LOCALHOST:11434/v1",
            "http://127.0.0.1:9222/json/version",
            "http://[::1]:4030/",
            "https://10.1.2.3/",
            "https://192.168.1.20:8443/healthz",
            "https://172.16.0.9/",
            "https://169.254.10.10/",
            "https://100.64.0.7/",
            "https://[fd12:3456::1]/",
            "https://[fe80::1]/",
            "https://[::ffff:10.0.0.7]/"
          ] do
        assert Egress.route(@proxied, url) == :direct, "#{url} should be direct"
      end
    end

    # Ranges a public-URL guard refuses are not thereby "this network": the ones
    # that route to the internet must not slip past the proxy.
    test "a reserved or transition range that reaches the internet is proxied" do
      for url <- [
            "https://198.18.0.1/",
            "https://192.0.2.10/",
            "https://[64:ff9b::5db8:d822]/",
            "https://[2002:5db8:d822::1]/",
            "https://[::ffff:93.184.216.34]/",
            "https://172.32.0.1/",
            "https://100.128.0.1/"
          ] do
        assert {:proxy, _proxy} = Egress.route(@proxied, url), "#{url} should be proxied"
      end
    end

    test "a bypass entry is an exact host or a dotted suffix, never a substring" do
      assert Egress.route(@proxied, "http://ollama.internal:11434/v1") == :direct
      assert Egress.route(@proxied, "https://OLLAMA.internal/") == :direct
      assert Egress.route(@proxied, "https://git.corp.test/") == :direct
      assert Egress.route(@proxied, "https://a.b.corp.test/") == :direct

      for url <- [
            "https://notollama.internal/",
            "https://ollama.internal.evil.test/",
            "https://corp.test/",
            "https://evilcorp.test/",
            "https://corp.test.evil.example/"
          ] do
        assert {:proxy, _proxy} = Egress.route(@proxied, url), "#{url} should be proxied"
      end
    end

    test "a name that only looks local is not local" do
      assert {:proxy, _proxy} = Egress.route(@proxied, "https://localhost.evil.test/")
      assert {:proxy, _proxy} = Egress.route(@proxied, "https://127.0.0.1.evil.test/")
    end

    # Nothing guarantees a `.localhost` name resolves to loopback (a resolver
    # without that rule sends it to DNS), so only the bare name is local.
    test "a .localhost name goes to the proxy unless it is listed" do
      assert {:proxy, _proxy} = Egress.route(@proxied, "http://api.localhost/")

      listed = Egress.new(proxy: "http://proxy.test:3128", proxy_bypass: [".localhost"])
      assert Egress.route(listed, "http://api.localhost/") == :direct
    end
  end

  describe "connect_options/3" do
    test "a direct route keeps the caller's options byte for byte" do
      base = [timeout: 3_000, transport_opts: [server_name_indication: ~c"example.test"]]

      assert Egress.connect_options(@direct, "https://example.test", base) == base
      assert Egress.connect_options(@proxied, "http://localhost:11434", base) == base
    end

    test "an HTTPS route shares the caller's connect budget across the three proxy phases" do
      base = [timeout: 10_000, transport_opts: [server_name_indication: ~c"example.test"]]
      options = Egress.connect_options(@proxied, "https://93.184.216.34/", base)

      assert {:http, "proxy.test", 3128, proxy_opts} = options[:proxy]
      tcp = proxy_opts[:transport_opts][:timeout]
      tunnel = proxy_opts[:tunnel_timeout]
      tls = options[:transport_opts][:timeout]

      # A fifth to reach the proxy, two fifths each for the tunnel and for TLS.
      assert {tcp, tunnel, tls} == {2_000, 4_000, 4_000}
      # The origin's TLS posture is the caller's, untouched.
      assert options[:transport_opts][:server_name_indication] == ~c"example.test"
      refute Keyword.has_key?(options, :timeout)
    end

    # Finch gives a pool with no connect timeout 5 s; proxied, the three phases
    # together must stay inside that, not inside Mint's own 30 s.
    test "an unset budget is the 5 s a direct connect would get, still split" do
      options = Egress.connect_options(@proxied, "https://example.test", [])

      {:http, "proxy.test", 3128, proxy_opts} = options[:proxy]

      total =
        proxy_opts[:transport_opts][:timeout] + proxy_opts[:tunnel_timeout] +
          options[:transport_opts][:timeout]

      assert total <= 5_000
      assert total > 4_900
    end

    test "a plain HTTP route has one phase, so the budget is not split" do
      options = Egress.connect_options(@proxied, "http://example.test/x", timeout: 9_000)

      assert options[:proxy] == {:http, "proxy.test", 3128, []}
      assert options[:timeout] == 9_000
    end
  end

  describe "proxied_pools/2" do
    test "is nil without a proxy, so no second pool is started" do
      assert Egress.proxied_pools(@direct, FermixCore.Application.finch_pools()) == nil
    end

    test "mirrors the direct pool table and keeps every connect budget inside the original" do
      pools = FermixCore.Application.finch_pools()
      proxied = Egress.proxied_pools(@proxied, pools)

      assert Map.keys(proxied) == Map.keys(pools)

      for {origin, original} <- pools do
        assert Keyword.delete(proxied[origin], :conn_opts) == Keyword.delete(original, :conn_opts)

        budget = get_in(original, [:conn_opts, :transport_opts, :timeout]) || 5_000
        {:http, "proxy.test", 3128, proxy_opts} = proxied[origin][:conn_opts][:proxy]

        assert proxy_opts[:transport_opts][:timeout] + proxy_opts[:tunnel_timeout] +
                 proxied[origin][:conn_opts][:transport_opts][:timeout] <= budget
      end
    end
  end

  describe "attach/3 on a site-owned request" do
    test "adds the proxy for a proxied hop and leaves a bypassed hop as the caller built it" do
      parent = self()

      adapter = fn request ->
        send(parent, {:hop, request.url.host, request.options[:connect_options]})
        {request, Req.Response.new(status: 200)}
      end

      remote =
        Req.new(url: "https://remote.test", adapter: adapter, connect_options: [timeout: 10_000])
        |> Egress.attach(:direct, @proxied)

      assert {:ok, %{status: 200}} = Req.request(remote)
      assert_receive {:hop, "remote.test", options}
      assert {:http, "proxy.test", 3128, _proxy_opts} = options[:proxy]

      local =
        Req.new(
          url: "https://git.corp.test",
          adapter: adapter,
          connect_options: [timeout: 10_000]
        )
        |> Egress.attach(:direct, @proxied)

      assert {:ok, %{status: 200}} = Req.request(local)
      assert_receive {:hop, "git.corp.test", [timeout: 10_000]}
    end

    test "a request that set no connect options still has none on a direct hop" do
      parent = self()

      adapter = fn request ->
        send(parent, {:hop, Map.has_key?(request.options, :connect_options)})
        {request, Req.Response.new(status: 200)}
      end

      request = Req.new(url: "https://example.test", adapter: adapter)

      assert {:ok, _response} = request |> Egress.attach(:direct, @direct) |> Req.request()
      assert_receive {:hop, false}
    end

    test "a redirect is routed again, so a bypassed target does not inherit the proxy" do
      parent = self()

      adapter = fn request ->
        send(parent, {:hop, request.url.host, request.options[:connect_options]})

        response =
          if request.url.host == "remote.test",
            do: Req.Response.new(status: 302, headers: [{"location", "https://git.corp.test/x"}]),
            else: Req.Response.new(status: 200, body: "done")

        {request, response}
      end

      request =
        Req.new(url: "https://remote.test", adapter: adapter, connect_options: [timeout: 10_000])
        |> Egress.attach(:direct, @proxied)

      assert {:ok, %{status: 200}} = Req.request(request)
      assert_receive {:hop, "remote.test", first}
      assert {:http, "proxy.test", 3128, _proxy_opts} = first[:proxy]
      assert_receive {:hop, "git.corp.test", [timeout: 10_000]}
    end

    test "and the other way: a redirect out of a bypassed host picks the proxy up" do
      parent = self()

      adapter = fn request ->
        send(parent, {:hop, request.url.host, request.options[:connect_options]})

        response =
          if request.url.host == "git.corp.test",
            do: Req.Response.new(status: 302, headers: [{"location", "https://remote.test/x"}]),
            else: Req.Response.new(status: 200)

        {request, response}
      end

      request =
        Req.new(url: "https://git.corp.test", adapter: adapter)
        |> Egress.attach(:direct, @proxied)

      assert {:ok, %{status: 200}} = Req.request(request)
      assert_receive {:hop, "git.corp.test", nil}
      assert_receive {:hop, "remote.test", options}
      assert {:http, "proxy.test", 3128, _proxy_opts} = options[:proxy]
    end

    test "attaching twice routes once" do
      request =
        Req.new(url: "https://remote.test")
        |> Egress.attach(:direct, @proxied)
        |> Egress.attach(:direct, @proxied)

      assert Enum.count(request.request_steps, fn {name, _step} -> name == :fermix_egress end) ==
               1
    end
  end

  describe "a pinned plain-HTTP request" do
    defp pinned(url, egress) do
      parent = self()

      adapter = fn request ->
        send(parent, {:sent, request.url.host})
        {request, Req.Response.new(status: 200)}
      end

      Req.new(url: url, adapter: adapter, retry: false, headers: [{"host", "example.test"}])
      |> Egress.attach(:direct, egress)
      |> Req.request()
    end

    # Over plain HTTP the proxy reads `Host`: it either rewrites it to the
    # address or resolves the name itself, behind the guard. So the hop is not
    # sent at all.
    test "is refused on a proxied hop instead of handing the proxy the name" do
      assert {:error, %Req.TransportError{reason: :proxy_needs_https}} =
               pinned("http://93.184.216.34/page", @proxied)

      refute_received {:sent, _host}
    end

    test "is sent as before over HTTPS, where the name stays inside the tunnel" do
      assert {:ok, %{status: 200}} = pinned("https://93.184.216.34/page", @proxied)
      assert_received {:sent, "93.184.216.34"}
    end

    test "is sent as before with no proxy, or to a direct address" do
      assert {:ok, %{status: 200}} = pinned("http://93.184.216.34/page", @direct)
      assert_received {:sent, "93.184.216.34"}

      assert {:ok, %{status: 200}} = pinned("http://10.0.0.7/page", @proxied)
      assert_received {:sent, "10.0.0.7"}
    end

    test "an ordinary plain-HTTP request, whose Host is its own, still goes through" do
      parent = self()

      adapter = fn request ->
        send(parent, {:sent, request.options[:connect_options][:proxy]})
        {request, Req.Response.new(status: 200)}
      end

      request =
        Req.new(url: "http://example.test/page", adapter: adapter, retry: false)
        |> Egress.attach(:direct, @proxied)

      assert {:ok, %{status: 200}} = Req.request(request)
      assert_received {:sent, {:http, "proxy.test", 3128, []}}
    end
  end

  describe "attach/3 on a pooled request" do
    test "names the pool per hop, across a redirect and a bypass boundary" do
      parent = self()

      adapter = fn request ->
        send(parent, {:pool, request.url.host, request.options[:finch]})

        response =
          case request.url.host do
            "first.test" ->
              Req.Response.new(status: 302, headers: [{"location", "https://second.test"}])

            "second.test" ->
              Req.Response.new(status: 302, headers: [{"location", "http://localhost:11434/"}])

            "localhost" ->
              Req.Response.new(status: 200)
          end

        {request, response}
      end

      request = Req.new(url: "http://first.test", adapter: adapter)

      assert {:ok, %{status: 200}} = request |> Egress.attach(:pooled, @proxied) |> Req.request()
      assert_receive {:pool, "first.test", FermixCore.Finch.Proxied}
      assert_receive {:pool, "second.test", FermixCore.Finch.Proxied}
      assert_receive {:pool, "localhost", FermixCore.Finch}
    end

    test "is the shared direct pool for every hop when no proxy is configured" do
      parent = self()

      adapter = fn request ->
        send(parent, {:pool, request.options[:finch]})
        {request, Req.Response.new(status: 200)}
      end

      request = Req.new(url: "https://example.test", adapter: adapter)

      assert {:ok, _response} = request |> Egress.attach(:pooled, @direct) |> Req.request()
      assert_receive {:pool, FermixCore.Finch}
    end
  end

  describe "a failed proxy hop" do
    defp failing(url, exception, egress) do
      adapter = fn request -> {request, exception} end

      Req.new(url: url, adapter: adapter, retry: false)
      |> Egress.attach(:direct, egress)
      |> Req.request()
    end

    defp tunnel_error(detail),
      do: %Mint.HTTPError{module: Mint.TunnelProxy, reason: {:proxy, detail}}

    defp proxied_failure(exception) do
      import ExUnit.CaptureLog, only: [with_log: 1]
      with_log(fn -> failing("https://remote.test", exception, @proxied) end)
    end

    test "a tunnel the proxy will not open without a sign-in is :proxy_auth_required" do
      {result, log} = proxied_failure(tunnel_error({:unexpected_status, 407}))

      assert result == {:error, %Req.TransportError{reason: :proxy_auth_required}}
      # The status an operator needs is in the log, with the host and no path.
      assert log =~ "407"
      assert log =~ "remote.test"
    end

    test "a tunnel the proxy refuses is :proxy_refused" do
      for detail <- [{:unexpected_status, 403}, {:unexpected_trailing_responses, []}] do
        assert {{:error, %Req.TransportError{reason: :proxy_refused}}, _log} =
                 proxied_failure(tunnel_error(detail))
      end
    end

    # The transient kind: the proxy is down, slow, or reporting that it cannot
    # reach the origin just now.
    test "a proxy that is down, silent or answering 5xx is :proxy_unreachable" do
      for detail <- [:tunnel_timeout, {:unexpected_status, 502}, {:unexpected_status, 503}] do
        assert {{:error, %Req.TransportError{reason: :proxy_unreachable}}, _log} =
                 proxied_failure(tunnel_error(detail))
      end

      for reason <- [:econnrefused, :nxdomain, :ehostunreach, :enetunreach] do
        assert {{:error, %Req.TransportError{reason: :proxy_unreachable}}, _log} =
                 proxied_failure(%Req.TransportError{reason: reason})
      end
    end

    # `Exception.message/1` on a transport error formats its reason through
    # `:ssl`, which raises on anything but an atom or one of its own tuples.
    test "every proxy failure is an atom the error's own message/1 can print" do
      for reason <- [
            :proxy_unreachable,
            :proxy_auth_required,
            :proxy_refused,
            :proxy_needs_https
          ] do
        assert Egress.proxy_failure?(reason)
        assert Exception.message(%Req.TransportError{reason: reason}) == inspect(reason)
      end

      refute Egress.proxy_failure?(:econnrefused)
    end

    test "the origin's own failures are not blamed on the proxy" do
      alert = %Req.TransportError{reason: {:tls_alert, {:unknown_ca, ~c"unknown ca"}}}

      assert {:error, ^alert} = failing("https://remote.test", alert, @proxied)

      for reason <- [:timeout, :closed] do
        error = %Req.TransportError{reason: reason}
        assert {:error, ^error} = failing("https://remote.test", error, @proxied)
      end
    end

    test "nothing is rewritten on a direct hop" do
      refused = %Req.TransportError{reason: :econnrefused}

      assert {:error, ^refused} = failing("https://remote.test", refused, @direct)
      assert {:error, ^refused} = failing("http://localhost:11434", refused, @proxied)
    end
  end

  describe "the transports that cannot tunnel" do
    test "ensure_direct/2 refuses a proxied destination and nothing else" do
      assert Egress.ensure_direct("wss://api.openai.com/v1/realtime", @direct) == :ok
      assert Egress.ensure_direct("ws://127.0.0.1:9222/devtools/browser/x", @proxied) == :ok
      assert Egress.ensure_direct("wss://voice.corp.test/x", @proxied) == :ok

      assert Egress.ensure_direct("wss://api.openai.com/v1/realtime", @proxied) ==
               {:error, :proxy_unsupported_transport}
    end

    test "readiness_target/3 probes the hop the request will actually take" do
      assert Egress.readiness_target(@direct, "api.openai.com", 443) == {"api.openai.com", 443}
      assert Egress.readiness_target(@proxied, "api.openai.com", 443) == {"proxy.test", 3128}
      assert Egress.readiness_target(@proxied, "localhost", 11_434) == {"localhost", 11_434}
    end
  end

  describe "describe_failure/1" do
    test "gives each failure its own sentence an operator can act on" do
      sentences =
        Enum.map(
          [:proxy_unreachable, :proxy_auth_required, :proxy_refused, :proxy_needs_https],
          &Egress.describe_failure/1
        )

      assert length(Enum.uniq(sentences)) == 4
      assert Egress.describe_failure(:proxy_auth_required) =~ "407"
      assert Egress.describe_failure(:proxy_unreachable) =~ "could not be reached"
      assert Egress.describe_failure(:proxy_needs_https) =~ "https://"
    end
  end

  describe "describe/1" do
    test "names the proxy, or nothing" do
      assert Egress.describe(@direct) == nil
      assert Egress.describe(@proxied) == "http://proxy.test:3128"
    end
  end

  describe "through a real forward proxy on loopback" do
    setup do
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

      on_exit(fn -> :gen_tcp.close(listener) end)
      {:ok, {_address, port}} = :inet.sockname(listener)

      %{listener: listener, egress: Egress.new(proxy: "http://127.0.0.1:#{port}")}
    end

    test "a plain HTTP request reaches the proxy in absolute form, never the origin", context do
      parent = self()

      task =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(context.listener, 5_000)

          try do
            {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
            send(parent, {:proxy_saw, request})

            :ok =
              :gen_tcp.send(
                socket,
                "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok"
              )
          after
            :gen_tcp.close(socket)
          end
        end)

      # `.invalid` never resolves: only a request that went to the proxy can
      # come back 200.
      request =
        Req.new(url: "http://unresolvable.invalid/resource", retry: false)
        |> Egress.attach(:direct, context.egress)

      assert {:ok, %{status: 200, body: "ok"}} = Req.request(request)
      assert_receive {:proxy_saw, seen}
      assert seen =~ "GET http://unresolvable.invalid/resource HTTP/1.1"
      Task.await(task)
    end

    # Port 1 on loopback: nothing listens there and no test can bind it, so the
    # refusal does not depend on a just-closed port staying closed.
    test "a dead proxy fails the request; it does not fall back to a direct dial" do
      import ExUnit.CaptureLog, only: [with_log: 1]

      request =
        Req.new(url: "http://unresolvable.invalid/resource", retry: false)
        |> Egress.attach(:direct, Egress.new(proxy: "http://127.0.0.1:1"))

      {result, _log} = with_log(fn -> Req.request(request) end)

      assert result == {:error, %Req.TransportError{reason: :proxy_unreachable}}
    end
  end
end
