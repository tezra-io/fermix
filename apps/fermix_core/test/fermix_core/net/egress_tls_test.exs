defmodule FermixCore.Net.EgressTlsTest do
  @moduledoc """
  What a proxy can and cannot do to an HTTPS request, proved against a real
  `CONNECT` listener on loopback that then plays the origin.

  The proxy is an untrusted hop: it must never be able to stand in for the
  peer. Each case sends a request the way a call site does, through
  `Egress.attach/3`, and the listener answers with a certificate the test
  minted.
  """

  # async: true — a loopback listener and a throwaway CA this test owns.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias FermixCore.Net.Egress
  alias X509.Certificate
  alias X509.Certificate.Extension
  alias X509.PrivateKey
  alias X509.PublicKey

  @origin "origin.test"

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ssl)

    ca_key = PrivateKey.new_ec(:secp256r1)
    ca = Certificate.self_signed(ca_key, "/CN=Egress Test Root", template: :root_ca)
    key = PrivateKey.new_ec(:secp256r1)

    cert =
      Certificate.new(PublicKey.derive(key), "/CN=#{@origin}", ca, ca_key,
        template: :server,
        extensions: [subject_alt_name: Extension.subject_alt_name([@origin])]
      )

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_address, port}} = :inet.sockname(listener)

    %{
      listener: listener,
      egress: Egress.new(proxy: "http://127.0.0.1:#{port}"),
      root: Certificate.to_der(ca),
      tls: [cert: Certificate.to_der(cert), key: {:ECPrivateKey, PrivateKey.to_der(key)}]
    }
  end

  test "a trusted origin is reached through the tunnel", context do
    task = serve(context)

    assert {:ok, %{status: 200, body: "ok"}} =
             request(context, "https://#{@origin}/resource", cacerts: [context.root])

    assert_receive {:connect, "CONNECT origin.test:443 HTTP/1.1" <> _rest}
    assert :ok = Task.await(task)
  end

  test "a certificate the trust store does not anchor is refused inside the tunnel", context do
    task = serve(context)

    assert {:error, %Req.TransportError{reason: {:tls_alert, _alert}}} =
             request(context, "https://#{@origin}/resource", [])

    assert_receive {:connect, "CONNECT origin.test:443 HTTP/1.1" <> _rest}
    assert {:error, _reason} = Task.await(task)
  end

  test "a trusted certificate for another host is refused: the proxy cannot swap the peer",
       context do
    task = serve(context)

    assert {:error, %Req.TransportError{reason: {:tls_alert, _alert}}} =
             request(context, "https://elsewhere.test/resource", cacerts: [context.root])

    assert {:error, _reason} = Task.await(task)
  end

  # The shape `web_fetch` and link previews send: the URL carries the address
  # the guard validated, and the name rides in SNI. The proxy is told the
  # address, so there is no name for it to resolve a second time, and the
  # certificate is still checked against the name.
  test "a pinned request tunnels to the validated address and verifies the name", context do
    task = serve(context)

    assert {:ok, %{status: 200, body: "ok"}} =
             request(context, "https://93.184.216.34/resource",
               cacerts: [context.root],
               server_name_indication: String.to_charlist(@origin)
             )

    assert_receive {:connect, "CONNECT 93.184.216.34:443 HTTP/1.1" <> _rest}
    assert :ok = Task.await(task)
  end

  test "a pinned request still refuses a certificate for the wrong name", context do
    task = serve(context)

    assert {:error, %Req.TransportError{reason: {:tls_alert, _alert}}} =
             request(context, "https://93.184.216.34/resource",
               cacerts: [context.root],
               server_name_indication: ~c"elsewhere.test"
             )

    assert {:error, _reason} = Task.await(task)
  end

  test "a proxy that refuses the tunnel fails the request with the proxy's answer", context do
    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(context.listener, 5_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 407 Proxy Authentication Required\r\ncontent-length: 0\r\n\r\n"
          )

        :gen_tcp.close(socket)
      end)

    {result, log} =
      with_log(fn ->
        request(context, "https://#{@origin}/resource", cacerts: [context.root])
      end)

    assert result == {:error, %Req.TransportError{reason: :proxy_auth_required}}
    assert log =~ "407"
    Task.await(task)
  end

  @tag timeout: 10_000
  test "a proxy that never answers CONNECT is bounded by the caller's connect budget", context do
    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(context.listener, 5_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)
        # Say nothing. The client must give up on its own clock.
        _ = :gen_tcp.recv(socket, 0, 5_000)
        :gen_tcp.close(socket)
      end)

    started = System.monotonic_time(:millisecond)

    {result, _log} =
      with_log(fn ->
        Req.new(
          url: "https://#{@origin}/resource",
          retry: false,
          connect_options: [timeout: 600]
        )
        |> Egress.attach(:direct, context.egress)
        |> Req.request()
      end)

    assert result == {:error, %Req.TransportError{reason: :proxy_unreachable}}

    # Two fifths of 600 ms for the tunnel; the request must not wait out Mint's 30 s.
    assert System.monotonic_time(:millisecond) - started < 3_000
    Task.await(task)
  end

  defp request(context, url, transport_opts) do
    Req.new(
      url: url,
      retry: false,
      connect_options: [timeout: 5_000, transport_opts: transport_opts]
    )
    |> Egress.attach(:direct, context.egress)
    |> Req.request()
  end

  # Accept one tunnel, answer CONNECT, then be the origin on the same socket.
  defp serve(context) do
    parent = self()

    Task.async(fn ->
      {:ok, socket} = :gen_tcp.accept(context.listener, 5_000)

      try do
        {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
        send(parent, {:connect, request})
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 Connection Established\r\n\r\n")
        answer_as_origin(socket, context.tls)
      after
        :gen_tcp.close(socket)
      end
    end)
  end

  defp answer_as_origin(socket, tls) do
    case :ssl.handshake(socket, tls, 5_000) do
      {:ok, secure} ->
        try do
          {:ok, _request} = :ssl.recv(secure, 0, 5_000)

          :ssl.send(
            secure,
            "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok"
          )
        after
          :ssl.close(secure)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
