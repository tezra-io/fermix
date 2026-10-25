defmodule FermixTestSupport.WebSocketPeer do
  @moduledoc """
  A WebSocket server over TLS on 127.0.0.1 that a test drives byte by byte,
  for tests of a real client socket (`Cues.Source.Stream.Socket`). It writes
  raw frames, so a test can send what a well-behaved server never would: a
  header announcing more than follows it, fragments, pings.

  `listen/1` mints a throwaway root and a leaf for `name` (the client is handed
  the root as its `:cacerts`) and listens in the calling process, so the
  listener closes with the test. `accept/2` starts one peer, linked to the
  caller, which takes one connection, reads its upgrade request and answers it
  (`answer:` 101 by default, another status to refuse it, or `:no_tls` to leave
  the TLS handshake unanswered). The peer sends the caller:

    * `{:ws_peer, peer, {:upgrade, request}}`: the request target, its headers
      (names downcased) and the SNI name the client sent;
    * `{:ws_peer, peer, {:frame, opcode, payload}}`: each frame the client
      sends, unmasked (`opcode` is `:text`, `:binary`, `:continuation`,
      `:close`, `:ping` or `:pong`);
    * `{:ws_peer, peer, :closed}`: the client closed the connection;
    * `{:ws_peer, peer, {:tls_failed, reason}}`: the TLS handshake failed.

  `send_raw/2` writes bytes as they are, `frame/3` builds a server frame and
  `close_tcp/1` drops the connection without a close frame.
  """

  alias X509.Certificate
  alias X509.Certificate.Extension
  alias X509.PrivateKey
  alias X509.PublicKey

  @accept_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  @io_ms 10_000
  @max_request_bytes 65_536
  @opcodes %{continuation: 0, text: 1, binary: 2, close: 8, ping: 9, pong: 10}
  @opcode_names Map.new(@opcodes, fn {name, code} -> {code, name} end)

  @type listener :: %{
          listener: :ssl.sslsocket(),
          port: :inet.port_number(),
          cacerts: [binary()]
        }

  @doc "A TLS listener on 127.0.0.1 whose certificate names `opts[:name]`."
  @spec listen(keyword()) :: listener()
  def listen(opts \\ []) when is_list(opts) do
    {:ok, _apps} = Application.ensure_all_started(:ssl)
    name = Keyword.get(opts, :name, "stream.example.test")

    # A root signing a leaf, rather than one self-signed certificate: OTP
    # refuses a self-signed peer even when it is the pinned anchor.
    ca_key = PrivateKey.new_ec(:secp256r1)
    ca = Certificate.self_signed(ca_key, "/CN=Fermix Test Root", template: :root_ca)
    key = PrivateKey.new_ec(:secp256r1)

    leaf =
      Certificate.new(PublicKey.derive(key), "/CN=#{name}", ca, ca_key,
        template: :server,
        extensions: [subject_alt_name: Extension.subject_alt_name([name])]
      )

    {:ok, listener} =
      :ssl.listen(0,
        ip: {127, 0, 0, 1},
        mode: :binary,
        active: false,
        reuseaddr: true,
        cert: Certificate.to_der(leaf),
        key: {:ECPrivateKey, PrivateKey.to_der(key)}
      )

    {:ok, {_ip, port}} = :ssl.sockname(listener)
    %{listener: listener, port: port, cacerts: [Certificate.to_der(ca)]}
  end

  @doc "One peer for the next connection to `listener`, linked to the caller."
  @spec accept(listener(), keyword()) :: pid()
  def accept(%{listener: listener}, opts \\ []) when is_list(opts) do
    test = self()
    answer = Keyword.get(opts, :answer, 101)
    spawn_link(fn -> serve(listener, test, answer) end)
  end

  @doc "Writes `bytes` to the client as they are."
  @spec send_raw(pid(), iodata()) :: :ok
  def send_raw(peer, bytes) when is_pid(peer) do
    send(peer, {:send_raw, bytes})
    :ok
  end

  @doc "Drops the connection without a close frame."
  @spec close_tcp(pid()) :: :ok
  def close_tcp(peer) when is_pid(peer) do
    send(peer, :close_tcp)
    :ok
  end

  @doc """
  An unmasked server frame. `fin: false` leaves the message open; `length:`
  announces a payload length other than the one that follows.
  """
  @spec frame(atom(), binary(), keyword()) :: binary()
  def frame(opcode, payload, opts \\ []) when is_binary(payload) and is_list(opts) do
    fin = if Keyword.get(opts, :fin, true), do: 1, else: 0
    length = Keyword.get(opts, :length, byte_size(payload))
    code = Map.fetch!(@opcodes, opcode)
    <<fin::1, 0::3, code::4, 0::1, encode_length(length)::bitstring, payload::binary>>
  end

  defp encode_length(length) when length < 126, do: <<length::7>>
  defp encode_length(length) when length < 65_536, do: <<126::7, length::16>>
  defp encode_length(length), do: <<127::7, length::64>>

  # --- the peer ----------------------------------------------------------------------

  defp serve(listener, test, answer) do
    {:ok, socket} = :ssl.transport_accept(listener, @io_ms)
    handshake(socket, test, answer)
  end

  # The client's hello goes unanswered until the test ends this linked process.
  defp handshake(_socket, _test, :no_tls), do: Process.sleep(:infinity)

  defp handshake(socket, test, answer) do
    case :ssl.handshake(socket, @io_ms) do
      {:ok, tls} -> upgrade(tls, test, answer)
      {:error, reason} -> send(test, {:ws_peer, self(), {:tls_failed, reason}})
    end
  end

  defp upgrade(tls, test, answer) do
    request = tls |> read_head(<<>>) |> parse_request() |> Map.put(:sni, sni(tls))
    send(test, {:ws_peer, self(), {:upgrade, request}})
    :ok = :ssl.send(tls, reply(answer, request))
    :ok = :ssl.setopts(tls, active: true)
    relay(tls, test, <<>>)
  end

  defp read_head(tls, bytes) when byte_size(bytes) <= @max_request_bytes do
    case :binary.split(bytes, "\r\n\r\n") do
      [head, _rest] ->
        head

      [_partial] ->
        {:ok, more} = :ssl.recv(tls, 0, @io_ms)
        read_head(tls, bytes <> more)
    end
  end

  defp parse_request(head) do
    [request_line | lines] = String.split(head, "\r\n")
    ["GET", target, "HTTP/1.1"] = String.split(request_line, " ")

    headers =
      Enum.map(lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    %{target: target, headers: headers}
  end

  defp sni(tls) do
    {:ok, info} = :ssl.connection_information(tls, [:sni_hostname])
    info |> Keyword.fetch!(:sni_hostname) |> to_string()
  end

  defp reply(101, %{headers: headers}) do
    {"sec-websocket-key", key} = List.keyfind(headers, "sec-websocket-key", 0)
    accept = Base.encode64(:crypto.hash(:sha, key <> @accept_guid))

    "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\n" <>
      "sec-websocket-accept: #{accept}\r\n\r\n"
  end

  defp reply(status, _request), do: "HTTP/1.1 #{status} Refused\r\ncontent-length: 0\r\n\r\n"

  defp relay(tls, test, buffer) do
    receive do
      {:ssl, ^tls, data} ->
        relay(tls, test, report_frames(buffer <> data, test))

      {:ssl_closed, ^tls} ->
        send(test, {:ws_peer, self(), :closed})

      {:send_raw, bytes} ->
        :ok = :ssl.send(tls, bytes)
        relay(tls, test, buffer)

      :close_tcp ->
        :ok = :ssl.close(tls)
    end
  end

  defp report_frames(bytes, test) do
    case client_frame(bytes) do
      {:ok, opcode, payload, rest} ->
        send(test, {:ws_peer, self(), {:frame, opcode, payload}})
        report_frames(rest, test)

      :partial ->
        bytes
    end
  end

  # A client frame is always masked (RFC 6455 §5.1).
  defp client_frame(<<_fin::1, _rsv::3, code::4, 1::1, length::7, rest::binary>>) do
    with {:ok, length, rest} <- client_length(length, rest),
         <<mask::binary-size(4), masked::binary-size(length), rest::binary>> <- rest do
      {:ok, Map.fetch!(@opcode_names, code), unmask(masked, mask), rest}
    else
      _short -> :partial
    end
  end

  defp client_frame(<<_head::8, 0::1, _rest::bitstring>>), do: raise("an unmasked client frame")
  defp client_frame(_short), do: :partial

  defp client_length(126, <<length::16, rest::binary>>), do: {:ok, length, rest}
  defp client_length(127, <<length::64, rest::binary>>), do: {:ok, length, rest}
  defp client_length(length, rest) when length < 126, do: {:ok, length, rest}
  defp client_length(_length, _short), do: :partial

  defp unmask(masked, mask) do
    size = byte_size(masked)
    key = :binary.part(:binary.copy(mask, div(size, 4) + 1), 0, size)
    :crypto.exor(masked, key)
  end
end
