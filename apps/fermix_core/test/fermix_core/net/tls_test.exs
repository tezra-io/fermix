defmodule FermixCore.Net.TlsTest do
  # async: true — every assertion is over a pure option list or a loopback
  # listener this test owns; nothing here reads or writes global state.
  use ExUnit.Case, async: true

  alias FermixCore.Net.Tls
  alias FermixCore.Transcription.WsSocket
  alias X509.Certificate
  alias X509.Certificate.Extension
  alias X509.PrivateKey
  alias X509.PublicKey

  @dial_timeout_ms 5_000

  describe "client_options/2" do
    test "verifies the named peer against the OS trust store" do
      opts = Tls.client_options("api.deepgram.com")

      assert opts[:verify] == :verify_peer
      assert opts[:server_name_indication] == ~c"api.deepgram.com"
      assert is_list(opts[:cacerts]) and opts[:cacerts] != []
      assert is_function(opts[:customize_hostname_check][:match_fun], 2)
    end

    test "an injected trust store replaces the OS store and nothing else" do
      opts = Tls.client_options("api.deepgram.com", cacerts: [<<1, 2, 3>>])

      assert opts[:cacerts] == [<<1, 2, 3>>]
      assert opts[:verify] == :verify_peer
      assert opts[:server_name_indication] == ~c"api.deepgram.com"
    end

    test "refuses a peer name there is nothing to verify against" do
      assert_raise FunctionClauseError, fn -> Tls.client_options("") end
      assert_raise FunctionClauseError, fn -> Tls.client_options(nil) end
    end
  end

  # The point of the module is the posture it hands `:ssl.connect/4`, and an
  # option list can look right while refusing everything. Both directions are
  # proved against a throwaway listener: the untrusted chain is the hole being
  # closed, the pinned one is the traffic that still has to work.
  describe "against a live TLS listener" do
    setup do
      {:ok, _apps} = Application.ensure_all_started(:ssl)

      # A throwaway root signing a `localhost` leaf, rather than one self-signed
      # certificate: OTP refuses a self-signed peer outright (`selfsigned_peer`)
      # even when that same certificate is the pinned anchor, so a lone
      # certificate could only ever prove the refusing half.
      ca_key = PrivateKey.new_ec(:secp256r1)
      ca = Certificate.self_signed(ca_key, "/CN=Fermix Test Root", template: :root_ca)

      server_key = PrivateKey.new_ec(:secp256r1)

      server =
        Certificate.new(
          PublicKey.derive(server_key),
          "/CN=localhost",
          ca,
          ca_key,
          template: :server,
          extensions: [
            subject_alt_name: Extension.subject_alt_name(["localhost"])
          ]
        )

      {:ok, listener} =
        :ssl.listen(0,
          ip: {127, 0, 0, 1},
          mode: :binary,
          active: false,
          reuseaddr: true,
          cert: Certificate.to_der(server),
          key: {:ECPrivateKey, PrivateKey.to_der(server_key)}
        )

      on_exit(fn -> :ssl.close(listener) end)

      {:ok, {_address, port}} = :ssl.sockname(listener)

      %{listener: listener, port: port, ca_der: Certificate.to_der(ca)}
    end

    test "the OS trust store refuses a chain nobody vouched for", context do
      accept_once(context.listener)

      # This is the vulnerability being closed: under WebSockex's `verify_none`
      # default the same handshake completes, and the client hands its
      # credentials to whoever answered.
      assert {:error, {:tls_alert, {:unknown_ca, _detail}}} =
               dial(context.port, Tls.client_options("localhost"))
    end

    test "a pinned trust store completes the same handshake", context do
      accept_once(context.listener)

      assert {:ok, connection} =
               dial(context.port, Tls.client_options("localhost", cacerts: [context.ca_der]))

      :ssl.close(connection)
    end

    # The option lists above are inert data until WebSockex hands them on, and
    # the key it reads them under is the whole fix: with `:ssl_options` absent
    # it falls through to `insecure: true` and this handshake completes. Dialed
    # through a production call site so nothing about the wiring is assumed.
    test "a production call site refuses the same listener through WebSockex", context do
      accept_once(context.listener)

      assert {:error, %WebSockex.ConnError{original: {:tls_alert, {:unknown_ca, _detail}}}} =
               WsSocket.start(
                 url: "wss://localhost:#{context.port}/",
                 headers: [],
                 parent: self()
               )
    end
  end

  # The listener binds 127.0.0.1 and the peer name is carried by SNI, so the
  # hostname check runs against the certificate without a DNS lookup deciding
  # whether this test passes.
  defp dial(port, options) do
    :ssl.connect({127, 0, 0, 1}, port, options ++ [active: false], @dial_timeout_ms)
  end

  # One acceptor per dial. The refusing client aborts, so the server side ends in
  # `{:error, _}`; this process owns the accepted socket and closes it on both
  # paths.
  defp accept_once(listener) do
    spawn(fn ->
      {:ok, socket} = :ssl.transport_accept(listener, @dial_timeout_ms)
      handshake_and_close(socket)
    end)
  end

  defp handshake_and_close(socket) do
    case :ssl.handshake(socket, @dial_timeout_ms) do
      {:ok, connection} -> :ssl.close(connection)
      {:error, _reason} -> :ssl.close(socket)
    end
  end
end
