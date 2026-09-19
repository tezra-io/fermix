defmodule Fermix.CLI.BrowserBridgeCommand do
  @moduledoc """
  `fermix browser-bridge` — the pump between the browser extension and the daemon.

  Chrome starts this as the extension's native-messaging host. It is a **pure
  byte pump and nothing else**: it starts no supervision tree, reads no config,
  decodes no message. Its whole job is re-framing, because the two sides count
  bytes differently — native messaging puts a 4-byte LITTLE-endian length in
  front of each JSON message, and `browser_bridge.sock` speaks `{packet, 4}`,
  which is big-endian.

  Stdout is the wire, so it carries frames and nothing else: the logger moves to
  stderr before the first byte, exactly as `fermix acp` does, and again at boot
  in `config/runtime.exs` because a release installs its own stdout handler
  after the config provider has already logged.

  **Which extension may connect** is decided twice from one file. Chrome enforces
  the host manifest's `allowed_origins` before it starts anything; this pump
  re-reads the same manifest — the one baked into the wrapper that launched it —
  and refuses to start unless the origin Chrome passes as its first argument is
  in that list. An origin it was not installed for gets a refusal, never a
  guess.

  Exit 0 when the browser closes the stream, 1 when the daemon is unreachable or
  the connection fails, 2 on a usage error. It never retries: the browser owns
  the respawn.
  """

  alias Fermix.CLI.StdoutPurity
  alias FermixCore.Browser.Bridge.Endpoint
  alias FermixCore.Browser.Bridge.HostManifest

  @connect_timeout_ms 2_000
  # Pinned at compile time from the listener, because a guard cannot call it.
  @max_frame_bytes Endpoint.max_frame_bytes()

  @doc """
  Run the pump.

  `opts` carries the `:stdin`/`:stdout`/`:stderr` devices and a `:socket_path`,
  all of which tests inject; nothing else is configurable.
  """
  @spec run([String.t()], keyword()) :: 0 | 1 | 2
  def run(argv, opts \\ []) when is_list(argv) and is_list(opts) do
    io = io_devices(opts)

    case parse(argv) do
      {:ok, manifest, origin} -> start(manifest, origin, io, opts)
      {:error, message} -> usage_error(io, message)
    end
  end

  # `--manifest` is baked into the wrapper the browser runs, so it is always
  # first; the origin is the first argument the BROWSER passes, and anything
  # after it (a Windows parent-window handle) is not ours to read.
  defp parse(["--manifest", manifest | rest]) when is_binary(manifest) do
    case Enum.reject(rest, &String.starts_with?(&1, "--")) do
      [origin | _extra] -> {:ok, manifest, origin}
      [] -> {:error, "the browser passed no extension origin"}
    end
  end

  defp parse(argv), do: {:error, "unrecognised arguments: #{Enum.join(argv, " ")}"}

  defp start(manifest, origin, io, opts) do
    with :ok <- ensure_pure_stdout(io),
         :ok <- admitted(manifest, origin, io),
         {:ok, socket} <- connect(socket_path(opts), io) do
      pump(socket, io)
    else
      {:halt, status} -> status
    end
  end

  defp admitted(manifest, origin, io) do
    case HostManifest.allowed_origins(manifest) do
      {:ok, origins} -> check_origin(origin, origins, manifest, io)
      {:error, reason} -> halt(io, "could not read the host manifest (#{inspect(reason)})")
    end
  end

  defp check_origin(origin, origins, manifest, io) do
    if origin in origins do
      :ok
    else
      halt(
        io,
        "#{origin} is not listed in #{manifest}. Run `fermix browser bridge install` with " <>
          "that extension's id, then reload the extension."
      )
    end
  end

  defp connect(path, io) do
    opts = [:binary, {:active, false}, {:packet, 4}, {:packet_size, @max_frame_bytes}]

    case :gen_tcp.connect({:local, to_charlist(path)}, 0, opts, @connect_timeout_ms) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} -> halt(io, unreachable(path, reason))
    end
  catch
    :exit, :badarg -> halt(io, unreachable(path, :badarg))
  end

  defp unreachable(path, reason) do
    "the Fermix daemon is not running — start it with `fermix run` (#{inspect(reason)}); " <>
      "socket: #{path}"
  end

  defp pump(socket, io) do
    case raw_mode(io) do
      :ok -> relay_or_fail(socket, io)
      {:halt, status} -> finish(socket, status)
    end
  end

  defp relay_or_fail(socket, io) do
    case rearm(socket, io) do
      :ok -> relay(socket, io, spawn_reader(socket, io))
      {:halt, status} -> finish(socket, status)
    end
  end

  # Byte mode on both devices. Without it a UTF-8 frame written through a
  # unicode device comes back double-encoded, and a frame read off stdin fails
  # translating latin1 to unicode — the exact failure `fermix acp` documents.
  defp raw_mode(io) do
    with :ok <- :io.setopts(io.stdin, encoding: :latin1),
         :ok <- :io.setopts(io.stdout, encoding: :latin1) do
      :ok
    else
      {:error, reason} -> halt(io, "could not put stdio into raw byte mode (#{inspect(reason)})")
    end
  end

  defp relay(socket, io, {reader, ref} = pair) do
    receive do
      {:tcp, ^socket, frame} ->
        relay_out(frame, socket, io, pair)

      {:tcp_closed, ^socket} ->
        shutdown(socket, pair, err(io, "the Fermix daemon closed the bridge connection"))

      {:tcp_error, ^socket, reason} ->
        shutdown(socket, pair, err(io, "the bridge connection failed (#{inspect(reason)})"))

      {:stdin_eof, ^reader} ->
        shutdown(socket, pair, 0)

      {:stdin_error, ^reader, reason} ->
        shutdown(socket, pair, err(io, "reading from the browser failed (#{inspect(reason)})"))

      {:frame_error, ^reader, message} ->
        shutdown(socket, pair, err(io, message))

      {:send_error, ^reader, reason} ->
        shutdown(socket, pair, err(io, "sending to the daemon failed (#{inspect(reason)})"))

      {:DOWN, ^ref, :process, ^reader, reason} ->
        shutdown(socket, pair, err(io, "the browser reader stopped (#{inspect(reason)})"))
    end
  end

  # Daemon to browser: `{packet, 4}` stripped the big-endian length, so put the
  # little-endian one native messaging wants in front of the same bytes.
  defp relay_out(frame, socket, io, pair) do
    case IO.binwrite(io.stdout, <<byte_size(frame)::unsigned-little-32>> <> frame) do
      :ok -> continue_relay(socket, io, pair)
      {:error, reason} -> shutdown(socket, pair, err(io, "writing failed (#{inspect(reason)})"))
    end
  end

  defp continue_relay(socket, io, pair) do
    case rearm(socket, io) do
      :ok -> relay(socket, io, pair)
      {:halt, status} -> shutdown(socket, pair, status)
    end
  end

  defp rearm(socket, io) do
    case :inet.setopts(socket, [{:active, :once}]) do
      :ok -> :ok
      {:error, reason} -> halt(io, "the bridge socket stopped delivering (#{inspect(reason)})")
    end
  end

  defp spawn_reader(socket, io) do
    parent = self()
    stdin = io.stdin
    spawn_monitor(fn -> read_stdin(parent, socket, stdin) end)
  end

  defp read_stdin(parent, socket, stdin) do
    case IO.binread(stdin, 4) do
      :eof ->
        send(parent, {:stdin_eof, self()})

      <<length::unsigned-little-32>> ->
        read_body(parent, socket, stdin, length)

      {:error, reason} ->
        send(parent, {:stdin_error, self(), reason})

      partial when is_binary(partial) ->
        frame_error(parent, "the browser sent #{byte_size(partial)} of a 4-byte length header")
    end
  end

  defp read_body(parent, _socket, _stdin, 0) do
    frame_error(parent, "the browser sent a zero-length message")
  end

  defp read_body(parent, _socket, _stdin, length) when length > @max_frame_bytes do
    frame_error(
      parent,
      "the browser sent a #{length}-byte message, over the #{@max_frame_bytes}-byte limit"
    )
  end

  defp read_body(parent, socket, stdin, length) do
    case IO.binread(stdin, length) do
      body when is_binary(body) and byte_size(body) == length ->
        forward(parent, socket, stdin, body)

      :eof ->
        frame_error(parent, "the browser closed the stream inside a message")

      partial when is_binary(partial) ->
        frame_error(parent, "the browser sent #{byte_size(partial)} of a #{length}-byte message")

      {:error, reason} ->
        send(parent, {:stdin_error, self(), reason})
    end
  end

  defp forward(parent, socket, stdin, body) do
    case :gen_tcp.send(socket, body) do
      :ok -> read_stdin(parent, socket, stdin)
      {:error, reason} -> send(parent, {:send_error, self(), reason})
    end
  end

  defp frame_error(parent, message), do: send(parent, {:frame_error, self(), message})

  defp shutdown(socket, {reader, _ref}, status) do
    Process.exit(reader, :kill)
    finish(socket, status)
  end

  defp finish(socket, status) do
    _ = :gen_tcp.close(socket)
    status
  end

  defp ensure_pure_stdout(io) do
    case StdoutPurity.route_logs_to_stderr() do
      :ok -> :ok
      {:error, reason} -> halt(io, StdoutPurity.message(reason))
    end
  end

  defp socket_path(opts), do: Keyword.get(opts, :socket_path, Endpoint.socket_path())

  defp io_devices(opts) do
    %{
      stdin: resolve_device(Keyword.get(opts, :stdin, :stdio)),
      stdout: resolve_device(Keyword.get(opts, :stdout, :stdio)),
      stderr: resolve_device(Keyword.get(opts, :stderr, :stderr))
    }
  end

  # `:stdio`/`:stderr` are `IO` shorthands, not devices — `:io.setopts/2` needs
  # the real one, and detection and execution share this one constructor.
  defp resolve_device(:stdio), do: Process.group_leader()
  defp resolve_device(:stderr), do: :standard_error
  defp resolve_device(device), do: device

  defp usage_error(io, message) do
    IO.puts(io.stderr, "fermix browser-bridge: " <> message)

    IO.puts(io.stderr, """
    usage: fermix browser-bridge --manifest <path> <extension-origin>

    The browser starts this through the wrapper `fermix browser bridge install`
    writes; there is no reason to run it by hand.\
    """)

    2
  end

  defp halt(io, message), do: {:halt, err(io, message)}

  defp err(io, message) do
    IO.puts(io.stderr, "fermix browser-bridge: " <> message)
    1
  end
end
