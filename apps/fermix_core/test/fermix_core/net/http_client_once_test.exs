defmodule FermixCore.Net.HttpClientOnceTest do
  @moduledoc """
  `HttpClient.request_once/3`: one request that is sent at most once.

  The server here is a real listener on loopback that reads each request in
  full and then drops the connection without a byte of response, the case a
  dial must never repeat: the vendor may have acted on the request it read.
  It counts every request it read, and it counts before it closes, so the
  count is final once the client has seen the close.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Net.HttpClient

  @arrival_ms 10_000
  # Requests the dropping server reads before it stops accepting.
  @max_accepts 8
  # Socket reads one request may take before the reader gives up on it.
  @max_reads 64

  setup do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_address, port}} = :inet.sockname(listener)
    posts = start_supervised!({Agent, fn -> 0 end})

    %{listener: listener, posts: posts, url: "http://127.0.0.1:#{port}/v1/live/sessions"}
  end

  describe "against a server that reads the request and drops the connection" do
    setup ctx do
      start_supervised!({Task, fn -> drop_after_reading(ctx.listener, ctx.posts, 0) end})
      :ok
    end

    # The hazard this operation exists for, shown on the wrapper every other
    # caller uses: its stale-socket retry sends the same POST a second time.
    test "the retrying request/3 sends the POST twice", ctx do
      result = HttpClient.request(post(ctx.url), "test-retrying")

      assert Agent.get(ctx.posts, & &1) == 2
      assert {:error, %Req.TransportError{reason: :closed}} = result
    end

    test "request_once/3 sends it exactly once and cannot say whether it was received", ctx do
      result = HttpClient.request_once(post(ctx.url), "test-once")

      assert Agent.get(ctx.posts, & &1) == 1
      assert {:error, {:unknown, %Req.TransportError{reason: :closed}}} = result
    end

    test "request_once/3 turns off Req's own retry even when the caller asked for it", ctx do
      request = Req.merge(post(ctx.url), retry: :transient, retry_delay: 0, max_retries: 3)

      result = HttpClient.request_once(request, "test-once-req-retry")

      assert Agent.get(ctx.posts, & &1) == 1
      assert {:error, {:unknown, %Req.TransportError{reason: :closed}}} = result
    end
  end

  # A followed 307 re-sends the same POST to wherever it points: a second
  # attempt by another name.
  test "request_once/3 does not follow a redirect", ctx do
    start_supervised!({Task, fn -> redirect_to_self(ctx.listener, ctx.posts, ctx.url) end})

    result = HttpClient.request_once(post(ctx.url), "test-once-redirect")

    assert Agent.get(ctx.posts, & &1) == 1
    assert {:ok, %Req.Response{status: 307}} = result
  end

  # Port 1 on loopback: nothing listens there and no test can bind it.
  test "a refused connection provably never sent the request" do
    request = post("http://127.0.0.1:1/v1/live/sessions")

    assert {:error, {:not_sent, %Req.TransportError{reason: :econnrefused}}} =
             HttpClient.request_once(request, "test-once-refused")
  end

  describe "classifies the failure, not just the attempt" do
    defp stubbed(fun) do
      parent = self()

      adapter = fn request ->
        send(parent, :attempt)
        fun.(request)
      end

      Req.new(url: "https://example.test", method: :post, json: %{}, adapter: adapter)
    end

    test "a timeout is unknown: the server may have read the request" do
      request = stubbed(fn request -> {request, %Req.TransportError{reason: :timeout}} end)

      assert {:error, {:unknown, %Req.TransportError{reason: :timeout}}} =
               HttpClient.request_once(request, "test-once-timeout")

      assert_received :attempt
      refute_received :attempt
    end

    test "a name that does not resolve provably never sent the request" do
      request = stubbed(fn request -> {request, %Req.TransportError{reason: :nxdomain}} end)

      assert {:error, {:not_sent, %Req.TransportError{reason: :nxdomain}}} =
               HttpClient.request_once(request, "test-once-nxdomain")
    end

    test "a TLS alert is unknown: the same reason arrives after the request was written" do
      alert = {:tls_alert, {:unknown_ca, ~c"invented"}}
      request = stubbed(fn request -> {request, %Req.TransportError{reason: alert}} end)

      assert {:error, {:unknown, %Req.TransportError{reason: ^alert}}} =
               HttpClient.request_once(request, "test-once-tls")
    end

    test "no pooled connection in time provably never sent the request" do
      message =
        "Finch was unable to provide a connection within the timeout due to " <>
          "excess queuing for connections."

      request = stubbed(fn _request -> raise RuntimeError, message end)

      assert {:error, {:not_sent, %RuntimeError{message: ^message}}} =
               HttpClient.request_once(request, "test-once-pool")
    end

    test "an HTTP error status is a response, passed through unchanged" do
      request = stubbed(fn request -> {request, Req.Response.new(status: 503, body: "busy")} end)

      assert {:ok, %Req.Response{status: 503, body: "busy"}} =
               HttpClient.request_once(request, "test-once-503")

      assert_received :attempt
      refute_received :attempt
    end
  end

  defp post(url), do: Req.new(url: url, method: :post, json: %{"dial" => "+15555550123"})

  defp drop_after_reading(_listener, _posts, accepted) when accepted >= @max_accepts, do: :ok

  defp drop_after_reading(listener, posts, accepted) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, _request} = read_request(socket, "", 0)
        Agent.update(posts, &(&1 + 1))
        :ok = :gen_tcp.close(socket)
        drop_after_reading(listener, posts, accepted + 1)

      {:error, :closed} ->
        :ok
    end
  end

  defp redirect_to_self(listener, posts, url) do
    {:ok, socket} = :gen_tcp.accept(listener)
    {:ok, _request} = read_request(socket, "", 0)
    Agent.update(posts, &(&1 + 1))

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 307 Temporary Redirect\r\nlocation: #{url}\r\n" <>
          "content-length: 0\r\nconnection: close\r\n\r\n"
      )

    :ok = :gen_tcp.close(socket)
    drop_after_reading(listener, posts, 1)
  end

  defp read_request(_socket, _buffer, reads) when reads >= @max_reads,
    do: {:error, :request_too_fragmented}

  defp read_request(socket, buffer, reads) do
    {:ok, data} = :gen_tcp.recv(socket, 0, @arrival_ms)
    buffer = buffer <> data

    if complete?(buffer), do: {:ok, buffer}, else: read_request(socket, buffer, reads + 1)
  end

  defp complete?(buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, body] -> byte_size(body) >= content_length(head)
      [_head] -> false
    end
  end

  defp content_length(head) do
    case Regex.run(~r/\r\ncontent-length:\s*(\d+)/i, head) do
      [_line, length] -> String.to_integer(length)
      nil -> 0
    end
  end
end
