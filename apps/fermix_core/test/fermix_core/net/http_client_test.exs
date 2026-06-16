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
end
