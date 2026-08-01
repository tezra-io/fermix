defmodule Fermix.CLI.AcpCommand do
  @moduledoc """
  `fermix acp` — the ACP stdio⇄UDS bridge (MILESTONE_29_ACP_AGENT_SURFACE.md §6.2).

  An ACP client (Buzz's `buzz-acp` harness, Zed, …) spawns `fermix acp` and talks
  newline-delimited JSON-RPC to its stdin/stdout. This verb is a **pipe, not a
  second Fermix**: it connects to the running daemon's `acp.sock`, exchanges one
  control line in each direction, and from then on copies bytes. Every protocol
  decision — sessions, prompts, tools, cancel — lives daemon-side in
  `FermixChannels.Channels.Acp`.

  Three properties are load-bearing:

    * **No boot.** A second supervision tree would fight the daemon's single
      SQLite writer and fork its memory, so a missing daemon is a fast, named
      refusal — never a local stand-in.
    * **No retry.** The ACP client owns respawn policy (Buzz backs off and
      circuit-breaks). A retry loop here would only hide which side is down.
    * **Pure stdout.** The ACP spec forbids non-protocol bytes on an agent's
      stdout, so the VM's default logger handler is moved to stderr *before*
      anything is written, and the pump never transforms, reframes, buffers by
      content, or annotates what it copies. `run/2` is not the first chance to
      make that move — `config/runtime.exs` calls `route_logs_to_stderr/0` for
      this verb before it hydrates config, because that hydration logs (an
      unresolvable `@keyring` sentinel warns) while no application has started
      yet. The move here still matters: in a release the `logger` application
      starts *after* the config provider and installs its own stdout handler.

  The handshake is two lines and nothing else: the bridge sends
  `{"fermix_bridge": 1, "app_version": …, "env": {…}}` and the daemon answers
  `{"fermix_bridge_ack": {"status": "ok"}}` or an error ack carrying its own
  message. Filtering the env is the daemon's job (one policy point, §6.2.3); the
  transport is a same-user 0600 socket, so a second filter here would add code,
  not security.
  """

  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Timeouts

  @socket_name "acp.sock"
  @bridge_version 1
  @connect_timeout_ms 2_000
  @max_ack_bytes 4_096

  # Reasons that mean "nothing is listening there" — the same classification
  # `Fermix.CLI.Daemon.Client` makes for the control socket. Anything else is a
  # different failure and gets its own message rather than being collapsed into
  # the daemon-not-running line.
  @unreachable [:enoent, :econnrefused, :timeout, :eaddrnotavail, :badarg]

  @typedoc """
  Why the VM's default logger handler could not be moved off stdout.
  """
  @type log_route_error :: {:unmovable_handler, module()} | {:add_handler_failed, term()}

  @doc """
  Run the bridge. `argv` must be empty — this verb takes no arguments.

  Returns the process exit status: `0` when the ACP client closed its stdin,
  `1` on any refusal or daemon-side loss, `2` for a usage error.

  The `opts` are test seams, not operator surface: `:socket_path`, `:stdin`,
  `:stdout`, `:stderr` and `:ack_timeout_ms` all default to the production
  values below.
  """
  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(argv, opts \\ []) when is_list(argv) and is_list(opts) do
    io = io_devices(opts)

    case argv do
      [] -> bridge(io, opts)
      _other -> usage_error(io)
    end
  end

  @doc """
  The daemon socket this bridge connects to: `<FERMIX_HOME>/acp.sock`.

  Resolved exactly as `FermixChannels.Channels.Acp.Endpoint.socket_path/0`
  resolves it, through the same `ConfigStore.fermix_home/0`. It cannot call that
  accessor: `fermix_channels` depends on `fermix_core`, never the reverse.
  """
  @spec socket_path() :: String.t()
  def socket_path, do: Path.join(ConfigStore.fermix_home(), @socket_name)

  defp io_devices(opts) do
    %{
      stdin: resolve_device(Keyword.get(opts, :stdin, :stdio)),
      stdout: resolve_device(Keyword.get(opts, :stdout, :stdio)),
      stderr: resolve_device(Keyword.get(opts, :stderr, :stderr))
    }
  end

  # `:stdio`/`:stderr` are Elixir `IO` shorthands, not devices — `:io.setopts/2`
  # needs the real one. Resolve once, up front, and use the resolved devices
  # everywhere so reads, writes and the raw-mode switch all address the same
  # device (the 2026-07 lesson: detection and execution share one constructor).
  defp resolve_device(:stdio), do: Process.group_leader()
  defp resolve_device(:stderr), do: :standard_error
  defp resolve_device(device), do: device

  defp bridge(io, opts) do
    path = Keyword.get(opts, :socket_path, socket_path())

    with :ok <- ensure_pure_stdout(io),
         {:ok, socket} <- connect(path, io),
         {:ok, leftover} <- handshake(socket, io, opts) do
      pump(socket, leftover, io)
    else
      {:halt, status} -> status
    end
  end

  defp usage_error(io) do
    IO.puts(io.stderr, "fermix acp: usage: fermix acp — the ACP bridge takes no arguments")
    2
  end

  # --- stdout purity --------------------------------------------------------

  @doc """
  Move the VM's default logger handler off stdout, onto stderr.

  Public because `run/2` is not the first byte-producing moment of a
  `fermix acp` process: `config/runtime.exs` — the boot config-provider chain,
  which runs before any application starts — hydrates config, and that hydration
  logs. Both call sites share this one implementation so the move cannot drift;
  each renders its own failure, because only the bridge can refuse to start.

  `:logger_std_h` refuses an in-place `type` change (its `changing_config/3`
  answers `:illegal_config_change`), so the move is remove-then-add: same
  module, same formatter, stderr.
  """
  @spec route_logs_to_stderr() :: :ok | {:error, log_route_error()}
  def route_logs_to_stderr do
    case :logger.get_handler_config(:default) do
      # A handler that writes to stdout is the one and only purity problem.
      {:ok, %{module: :logger_std_h, config: %{type: :standard_io}} = config} ->
        redirect_default_handler(config)

      # Already stderr, or a file handler: the guarantee holds, leave it alone.
      {:ok, %{module: :logger_std_h}} ->
        :ok

      # No default handler at all (`mix test`, a release that removed it):
      # nothing writes to stdout, which is the whole guarantee.
      {:error, {:not_found, :default}} ->
        :ok

      {:ok, %{module: module}} ->
        {:error, {:unmovable_handler, module}}
    end
  end

  @doc """
  The operator-facing sentence for a `route_logs_to_stderr/0` failure.

  Lives here with the move it explains, so the bridge and the boot chain report
  one failure in one wording.
  """
  @spec log_route_message(log_route_error()) :: String.t()
  def log_route_message({:unmovable_handler, module}) do
    "the default logger handler is #{inspect(module)}, which this bridge cannot move off " <>
      "stdout; ACP forbids non-protocol bytes there, so it will not start"
  end

  def log_route_message({:add_handler_failed, reason}) do
    "could not move Fermix logging off stdout (#{inspect(reason)})"
  end

  defp ensure_pure_stdout(io) do
    case route_logs_to_stderr() do
      :ok -> :ok
      {:error, reason} -> halt(io, log_route_message(reason))
    end
  end

  defp redirect_default_handler(config) do
    {module, rest} = Map.pop!(config, :module)
    handler_config = rest |> Map.get(:config, %{}) |> Map.put(:type, :standard_error)
    _ = :logger.remove_handler(:default)

    case :logger.add_handler(:default, module, Map.put(rest, :config, handler_config)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:add_handler_failed, reason}}
    end
  end

  # --- connect + handshake --------------------------------------------------

  defp connect(path, io) do
    case connect_socket(path) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} when reason in @unreachable -> refuse_connect(io, path)
      {:error, reason} -> halt(io, "cannot open the ACP socket (#{inspect(reason)}): #{path}")
    end
  end

  # An AF_UNIX path past the OS limit (104 bytes on macOS) makes `connect` exit
  # :badarg instead of returning an error. No listener can exist at an address
  # the OS cannot express, so it joins the unreachable reasons.
  defp connect_socket(path) do
    :gen_tcp.connect(
      {:local, to_charlist(path)},
      0,
      [:binary, {:active, false}],
      @connect_timeout_ms
    )
  catch
    :exit, :badarg -> {:error, :badarg}
  end

  defp refuse_connect(io, path) do
    {:halt,
     fail(
       io,
       "Fermix daemon not running (or [fermix_channels.acp] disabled) — " <>
         "start it with `fermix run`; socket: #{path}"
     )}
  end

  defp handshake(socket, io, opts) do
    # The deadline VALUE is shared with the daemon's own hello timer
    # (`Timeouts.acp_bridge_hello/0`) so the two ends of one exchange cannot
    # drift. The firing is reported on stderr rather than through
    # `Timeouts.expired/3`: this is a tree-less CLI process with no telemetry
    # handlers attached, and its stderr line is the artifact the operator reads.
    budget = Keyword.get(opts, :ack_timeout_ms, Timeouts.acp_bridge_hello())
    deadline = System.monotonic_time(:millisecond) + budget

    with :ok <- send_hello(socket, io),
         {:ok, line, leftover} <- read_ack(socket, deadline, budget, io),
         :ok <- interpret_ack(line, socket, io) do
      {:ok, leftover}
    end
  end

  defp send_hello(socket, io) do
    hello = %{
      "fermix_bridge" => @bridge_version,
      "app_version" => to_string(Application.spec(:fermix_core, :vsn)),
      "env" => System.get_env()
    }

    case :gen_tcp.send(socket, [Jason.encode!(hello), "\n"]) do
      :ok ->
        :ok

      {:error, reason} ->
        close_and_halt(socket, io, "could not send the bridge handshake (#{inspect(reason)})")
    end
  end

  # Bounded twice over: the ack deadline, and @max_ack_bytes — every receive
  # returns at least one byte, so at most that many iterations can run before
  # the cap refuses the line.
  defp read_ack(socket, deadline, budget, io), do: read_ack(socket, deadline, budget, io, "")

  defp read_ack(socket, deadline, budget, io, acc) do
    case :binary.split(acc, "\n") do
      [line, rest] -> {:ok, line, rest}
      [_partial] -> read_more_ack(socket, deadline, budget, io, acc)
    end
  end

  defp read_more_ack(socket, _deadline, _budget, io, acc) when byte_size(acc) > @max_ack_bytes do
    close_and_halt(socket, io, "the daemon's bridge ack exceeded #{@max_ack_bytes} bytes")
  end

  defp read_more_ack(socket, deadline, budget, io, acc) do
    case :gen_tcp.recv(socket, 0, remaining(deadline)) do
      {:ok, data} ->
        read_ack(socket, deadline, budget, io, acc <> data)

      {:error, :timeout} ->
        close_and_halt(socket, io, "no bridge ack from the Fermix daemon within #{budget}ms")

      {:error, :closed} ->
        close_and_halt(
          socket,
          io,
          "the Fermix daemon closed the connection before acking the bridge handshake"
        )

      {:error, reason} ->
        close_and_halt(socket, io, "reading the bridge ack failed (#{inspect(reason)})")
    end
  end

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp interpret_ack(line, socket, io) do
    case Jason.decode(line) do
      {:ok, %{"fermix_bridge_ack" => %{"status" => "ok"}}} ->
        :ok

      {:ok, %{"fermix_bridge_ack" => %{"status" => "error", "message" => message}}}
      when is_binary(message) ->
        close_and_halt(socket, io, "the Fermix daemon refused the bridge handshake: #{message}")

      {:ok, %{"fermix_bridge_ack" => ack}} ->
        close_and_halt(
          socket,
          io,
          "unreadable bridge ack from the Fermix daemon: #{inspect(ack)}"
        )

      {:ok, _frame} ->
        close_and_halt(socket, io, "the Fermix daemon's first line was not a bridge ack")

      {:error, _reason} ->
        close_and_halt(socket, io, "the Fermix daemon's bridge ack is not valid JSON")
    end
  end

  # --- the byte pump --------------------------------------------------------

  defp pump(socket, leftover, io) do
    with :ok <- raw_mode(io),
         :ok <- write_out(io, leftover),
         :ok <- rearm(socket) do
      relay(socket, io, spawn_reader(socket, io))
    else
      {:error, message} -> finish(socket, err(io, message))
    end
  end

  # Raw byte mode on both stdio devices, or the VM transcodes the pump: a UTF-8
  # frame written through a unicode device comes back out double-encoded
  # (`✓` → `â€ú`), and reading a UTF-8 line fails outright with
  # `{:no_translation, :unicode, :latin1}`. ACP frames are UTF-8 by
  # specification, so this is the common case, not an exotic one.
  #
  # `binary: true` is deliberately NOT set: Elixir's stdio already carries it, so
  # the only property that needs changing is the encoding — and a `StringIO`
  # (already binary) answers `:enotsup` to it, which would refuse a run for a
  # property the device already has.
  defp raw_mode(io) do
    with :ok <- :io.setopts(io.stdin, encoding: :latin1),
         :ok <- :io.setopts(io.stdout, encoding: :latin1) do
      :ok
    else
      {:error, reason} ->
        {:error, "could not put stdio into raw byte mode (#{inspect(reason)})"}
    end
  end

  # One iteration per inbound chunk, so the loop is bounded by the daemon's own
  # output; every other message ends the process. Nothing accumulates and
  # nothing retries, so it cannot spin.
  defp relay(socket, io, {reader, ref} = pair) do
    receive do
      {:tcp, ^socket, data} ->
        relay_out(data, socket, io, pair)

      {:tcp_closed, ^socket} ->
        shutdown(socket, pair, err(io, "the Fermix daemon closed the ACP connection"))

      {:tcp_error, ^socket, reason} ->
        shutdown(socket, pair, err(io, "the ACP connection failed (#{inspect(reason)})"))

      {:stdin_eof, ^reader} ->
        shutdown(socket, pair, 0)

      {:stdin_error, ^reader, reason} ->
        shutdown(
          socket,
          pair,
          err(io, "reading the ACP client's stdin failed (#{inspect(reason)})")
        )

      {:send_error, ^reader, reason} ->
        shutdown(
          socket,
          pair,
          err(io, "writing to the Fermix daemon failed (#{inspect(reason)})")
        )

      {:DOWN, ^ref, :process, ^reader, reason} ->
        shutdown(socket, pair, err(io, "the stdin reader stopped (#{inspect(reason)})"))
    end
  end

  defp relay_out(data, socket, io, pair) do
    case write_out(io, data) do
      :ok -> continue_relay(socket, io, pair)
      {:error, message} -> shutdown(socket, pair, err(io, message))
    end
  end

  defp continue_relay(socket, io, pair) do
    case rearm(socket) do
      :ok -> relay(socket, io, pair)
      {:error, message} -> shutdown(socket, pair, err(io, message))
    end
  end

  defp spawn_reader(socket, io) do
    parent = self()
    stdin = io.stdin
    spawn_monitor(fn -> read_stdin(parent, socket, stdin) end)
  end

  # The mirror image of `relay/3`: one iteration per inbound line, and each of
  # the three outcomes (EOF, read error, send error) reports once and returns,
  # ending the process.
  defp read_stdin(parent, socket, stdin) do
    case IO.binread(stdin, :line) do
      :eof -> send(parent, {:stdin_eof, self()})
      {:error, reason} -> send(parent, {:stdin_error, self(), reason})
      data when is_binary(data) -> forward(parent, socket, stdin, data)
    end
  end

  defp forward(parent, socket, stdin, data) do
    case :gen_tcp.send(socket, data) do
      :ok -> read_stdin(parent, socket, stdin)
      {:error, reason} -> send(parent, {:send_error, self(), reason})
    end
  end

  defp write_out(_io, ""), do: :ok

  defp write_out(io, data) do
    case IO.binwrite(io.stdout, data) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "writing the daemon's bytes to stdout failed (#{inspect(reason)})"}
    end
  end

  defp rearm(socket) do
    case :inet.setopts(socket, [{:active, :once}]) do
      :ok -> :ok
      {:error, reason} -> {:error, "the ACP socket stopped delivering (#{inspect(reason)})"}
    end
  end

  # The reader parks in a blocking read with nothing to unwind, so a kill is the
  # whole teardown; the socket closes on every terminal path either way.
  defp shutdown(socket, {reader, _ref}, status) do
    Process.exit(reader, :kill)
    finish(socket, status)
  end

  defp finish(socket, status) do
    _ = :gen_tcp.close(socket)
    status
  end

  # --- one printer ----------------------------------------------------------

  defp close_and_halt(socket, io, message) do
    _ = :gen_tcp.close(socket)
    halt(io, message)
  end

  defp halt(io, message), do: {:halt, err(io, message)}

  defp err(io, message), do: fail(io, "fermix acp: " <> message)

  defp fail(io, line) do
    IO.puts(io.stderr, line)
    1
  end
end
