defmodule FermixCore.Net.HttpClientTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Net.HttpClient

  defp request(opts) do
    plug = Keyword.fetch!(opts, :plug)
    Req.new(url: "https://example.test", method: :post, json: %{}, plug: plug, retry: false)
  end

  defp counter_stub(test_id, fun) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    parent = self()

    Req.Test.stub(test_id, fn conn ->
      attempt = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
      send(parent, {:attempt, attempt})
      fun.(conn, attempt)
    end)

    test_id
  end

  test "passes through a successful response on the first attempt" do
    test_id = :"http_client_ok_#{System.unique_integer([:positive])}"

    counter_stub(test_id, fn conn, _attempt ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    assert {:ok, %Req.Response{status: 200, body: "ok"}} =
             HttpClient.request(request(plug: {Req.Test, test_id}), "test")

    assert_received {:attempt, 1}
    refute_received {:attempt, 2}
  end

  test ":closed retries once and succeeds on the second attempt" do
    test_id = :"http_client_closed_then_ok_#{System.unique_integer([:positive])}"

    counter_stub(test_id, fn conn, attempt ->
      case attempt do
        1 -> Req.Test.transport_error(conn, :closed)
        _ -> Plug.Conn.send_resp(conn, 200, "recovered")
      end
    end)

    log =
      capture_log(fn ->
        assert {:ok, %Req.Response{status: 200, body: "recovered"}} =
                 HttpClient.request(request(plug: {Req.Test, test_id}), "test-label")
      end)

    assert log =~ "test-label transport closed"
    assert_received {:attempt, 1}
    assert_received {:attempt, 2}
    refute_received {:attempt, 3}
  end

  test ":econnrefused retries once and succeeds on the second attempt" do
    test_id = :"http_client_econnrefused_then_ok_#{System.unique_integer([:positive])}"

    counter_stub(test_id, fn conn, attempt ->
      case attempt do
        1 -> Req.Test.transport_error(conn, :econnrefused)
        _ -> Plug.Conn.send_resp(conn, 200, "recovered")
      end
    end)

    assert {:ok, %Req.Response{status: 200, body: "recovered"}} =
             HttpClient.request(request(plug: {Req.Test, test_id}), "test")

    assert_received {:attempt, 1}
    assert_received {:attempt, 2}
    refute_received {:attempt, 3}
  end

  test ":closed retries exactly once; a second :closed surfaces as the error" do
    test_id = :"http_client_closed_exhaust_#{System.unique_integer([:positive])}"

    counter_stub(test_id, fn conn, _attempt ->
      Req.Test.transport_error(conn, :closed)
    end)

    assert {:error, %Req.TransportError{reason: :closed}} =
             HttpClient.request(request(plug: {Req.Test, test_id}), "test")

    assert_received {:attempt, 1}
    assert_received {:attempt, 2}
    refute_received {:attempt, 3}
  end

  test ":timeout does NOT retry — single attempt, error surfaces" do
    test_id = :"http_client_timeout_#{System.unique_integer([:positive])}"

    counter_stub(test_id, fn conn, _attempt ->
      Req.Test.transport_error(conn, :timeout)
    end)

    assert {:error, %Req.TransportError{reason: :timeout}} =
             HttpClient.request(request(plug: {Req.Test, test_id}), "test")

    assert_received {:attempt, 1}
    refute_received {:attempt, 2}
  end

  test "non-2xx HTTP responses are passed through unchanged (no retry)" do
    test_id = :"http_client_500_#{System.unique_integer([:positive])}"

    counter_stub(test_id, fn conn, _attempt ->
      Plug.Conn.send_resp(conn, 500, "boom")
    end)

    assert {:ok, %Req.Response{status: 500, body: "boom"}} =
             HttpClient.request(request(plug: {Req.Test, test_id}), "test")

    assert_received {:attempt, 1}
    refute_received {:attempt, 2}
  end

  test "the shared FermixCore.Finch pool is supervised and running" do
    # The idle-age-capped pool (conn_max_idle_time) is what prevents the
    # daemon from reusing keep-alive sockets that a cloud LB RST'd while
    # the host slept — without it, the first request after idle surfaces
    # as a :closed transport error.
    assert pid = Process.whereis(FermixCore.Finch)
    assert Process.alive?(pid)
  end

  test "the shared pool caps idle connection age (the stale-socket fix)" do
    # Finch exposes no API to read pool config back, so pin the spec
    # literals — Finch's default conn_max_idle_time is :infinity, which is
    # the exact bug this pool exists to fix.
    pools = FermixCore.Application.finch_pools()

    assert pools[:default][:conn_max_idle_time] == 15_000
    assert pools["https://chatgpt.com"][:conn_max_idle_time] == 15_000
    assert pools["https://chatgpt.com"][:conn_opts] == [transport_opts: [timeout: 5_000]]
  end

  test "the chatgpt.com pool reaps idle pool processes off the request path" do
    # Finch's default pool_max_idle_time is :infinity: a pool process lives
    # forever holding sockets a peer may have RST'd, and their teardown is paid
    # by the next checkout. Reaping an idle pool process (Finch stops it and
    # auto-starts a fresh one on the next request) moves that teardown off the
    # request path. Pinned because Finch exposes no way to read pool config back.
    pools = FermixCore.Application.finch_pools()

    assert pools["https://chatgpt.com"][:pool_max_idle_time] == 60_000
    assert pools[:default][:pool_max_idle_time] == nil
  end

  test "web-search hosts ride the shared hardened pool with their fail-fast connect budget" do
    # The search backends' 3s connect budget moved here from per-request
    # `connect_options` — which had silently forked them onto Req-managed
    # dynamic Finch pools with conn_max_idle_time: :infinity (the
    # exa-fails-after-an-idle-gap :closed bug). Pin both halves: the
    # hardened idle cap AND the connect budget, per host.
    pools = FermixCore.Application.finch_pools()

    hosts = [
      "https://api.exa.ai",
      "https://api.firecrawl.dev",
      "https://api.parallel.ai",
      "https://api.perplexity.ai",
      "https://api.search.brave.com",
      "https://api.tavily.com",
      "https://html.duckduckgo.com"
    ]

    for host <- hosts do
      assert pools[host][:conn_max_idle_time] == 15_000, "#{host} is missing the idle cap"
      assert pools[host][:count] == 2, "#{host} is missing the multi-process pool"
      assert pools[host][:conn_opts] == [transport_opts: [timeout: 3_000]]
    end
  end

  test "the shared pool runs multiple pool processes so one blocked teardown can't starve checkouts" do
    # Finch's default pool count is 1: a single per-host pool process. Right
    # after wake-from-sleep that lone process can block ~5s tearing down a
    # stale socket, starving the very checkout that triggered it ("excess
    # queuing for connections"). Several pool processes mean a checkout can be
    # served while one process is busy.
    pools = FermixCore.Application.finch_pools()

    assert pools[:default][:count] == 2
    assert pools["https://chatgpt.com"][:count] == 2
  end

  test "request/2 widens the pool-checkout timeout so a briefly-blocked pool is waited out" do
    # With the Finch default 5s pool_timeout, a checkout that races a ~5s
    # post-wake stale-socket teardown has no margin and fails. A wider
    # checkout budget waits the teardown out instead of dropping the request.
    parent = self()

    req =
      Req.new(
        url: "https://example.test",
        method: :post,
        json: %{},
        retry: false,
        adapter: fn request ->
          send(parent, {:pool_timeout, request.options[:pool_timeout]})
          {request, Req.Response.new(status: 200, body: "ok")}
        end
      )

    assert {:ok, %Req.Response{status: 200}} = HttpClient.request(req, "test")
    assert_received {:pool_timeout, 15_000}
  end

  test "a Finch pool-exhaustion raise is returned as {:error, exception}, not propagated" do
    # Finch reraises a RuntimeError (not an {:error, _} tuple) when a pool
    # checkout exceeds its queue timeout ("excess queuing for connections").
    # Unwrapped, that raise crashes the caller — a starved api.telegram.org
    # pool once aborted a whole agent turn through the cosmetic typing
    # indicator. The wrapper must convert it to the {:error, Exception.t()}
    # its @spec already promises, and must NOT retry it (don't hammer a pool
    # that is already over capacity).
    parent = self()

    message =
      "Finch was unable to provide a connection within the timeout due to " <>
        "excess queuing for connections."

    req =
      Req.new(
        url: "https://example.test",
        method: :post,
        json: %{},
        retry: false,
        adapter: fn _request ->
          send(parent, :attempt)
          raise RuntimeError, message
        end
      )

    log =
      capture_log(fn ->
        assert {:error, %RuntimeError{message: ^message}} =
                 HttpClient.request(req, "telegram-typing")
      end)

    assert log =~ "telegram-typing HTTP request failed"
    assert log =~ "excess queuing"
    assert_received :attempt
    refute_received :attempt
  end

  describe "connection_unavailable?/1" do
    test "classifies the Finch pool-checkout timeout RuntimeError" do
      # The exact raise Finch reraises when a checkout exceeds the pool queue
      # timeout — pool contention, a pool process blocked tearing down stale
      # sockets, or stalled connects just after a wake from sleep.
      exception =
        RuntimeError.exception(
          "Finch was unable to provide a connection within the timeout due to " <>
            "excess queuing for connections."
        )

      assert HttpClient.connection_unavailable?(exception)
    end

    test "does not classify unrelated RuntimeErrors or non-exceptions" do
      refute HttpClient.connection_unavailable?(RuntimeError.exception("something else broke"))
      refute HttpClient.connection_unavailable?(%ArgumentError{message: "bad arg"})
      refute HttpClient.connection_unavailable?(:closed)
      refute HttpClient.connection_unavailable?("a string")
    end
  end
end
