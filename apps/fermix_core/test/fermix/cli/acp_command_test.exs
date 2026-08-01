defmodule Fermix.CLI.AcpCommandTest do
  @moduledoc """
  The `fermix acp` bridge verb (MILESTONE_29_ACP_AGENT_SURFACE.md §6.2, §12
  Stage 4): connect to the daemon's `acp.sock`, one hello line, one ack line,
  then a byte pump in both directions.

  The hard requirement under test is **stdout purity** — the ACP spec forbids
  non-protocol bytes on an agent's stdout — so every case asserts what reached
  the captured stdout device, not only the exit status.
  """

  use ExUnit.Case, async: false

  alias Fermix.CLI.AcpCommand
  alias FermixCore.Setup.ConfigStore
  alias FermixTestSupport.SafeRm

  @connect_refusal_prefix "Fermix daemon not running"

  defmodule ScriptedIn do
    @moduledoc false
    # A minimal Erlang io device answering the `{:get_line, :latin1, _}` requests
    # `IO.binread(device, :line)` makes.
    #
    # A StringIO cannot stand in for stdin here: it reports EOF the instant the
    # pump starts, which ends the run before the daemon's bytes are pumped back —
    # the test would race its own fixture. This device parks the single reader
    # until the test pushes a line or closes it, so stdin EOF happens exactly
    # when the test says so.

    @spec start_link() :: pid()
    def start_link do
      spawn_link(fn -> loop(%{pending: [], parked: nil, closed?: false}) end)
    end

    @spec push(pid(), binary()) :: :ok
    def push(device, data) do
      send(device, {:push, data})
      :ok
    end

    @spec close(pid()) :: :ok
    def close(device) do
      send(device, :close)
      :ok
    end

    defp loop(state) do
      receive do
        {:io_request, from, ref, {:get_line, :latin1, _prompt}} ->
          loop(settle(%{state | parked: {from, ref}}))

        # The bridge puts stdin into raw byte mode; this device is already raw
        # (it replies with exactly the bytes the test pushed).
        {:io_request, from, ref, {:setopts, _opts}} ->
          send(from, {:io_reply, ref, :ok})
          loop(state)

        {:io_request, from, ref, request} ->
          send(from, {:io_reply, ref, {:error, {:unsupported_io_request, request}}})
          loop(state)

        {:push, data} ->
          loop(settle(%{state | pending: state.pending ++ [data]}))

        :close ->
          loop(settle(%{state | closed?: true}))
      end
    end

    # The pump has exactly one stdin reader, so settling is a single reply and
    # never a fan-out.
    defp settle(%{parked: nil} = state), do: state

    defp settle(%{pending: [data | rest], parked: {from, ref}} = state) do
      send(from, {:io_reply, ref, data})
      %{state | pending: rest, parked: nil}
    end

    defp settle(%{pending: [], closed?: true, parked: {from, ref}} = state) do
      send(from, {:io_reply, ref, :eof})
      %{state | parked: nil}
    end

    defp settle(state), do: state
  end

  # A short socket path on purpose: a Unix socket address is capped around 104
  # bytes, which a nested tmp directory blows straight through.
  setup do
    logger = snapshot_default_logger()
    {:ok, stdout} = StringIO.open("")
    {:ok, stderr} = StringIO.open("")

    socket_path =
      Path.join(System.tmp_dir!(), "fermix-acp-cli-#{System.unique_integer([:positive])}.sock")

    on_exit(fn ->
      restore_default_logger(logger)
      SafeRm.rm(socket_path)
    end)

    {:ok, socket_path: socket_path, stdin: ScriptedIn.start_link(), out: stdout, err: stderr}
  end

  describe "socket resolution" do
    test "resolves acp.sock under FERMIX_HOME, exactly as the daemon's listener does" do
      assert Path.basename(AcpCommand.socket_path()) == "acp.sock"
      assert Path.dirname(AcpCommand.socket_path()) == ConfigStore.fermix_home()
    end
  end

  describe "connect failures" do
    test "refuses with one stderr line and exit 1 when nothing is listening", ctx do
      assert AcpCommand.run([], opts(ctx)) == 1

      assert stderr(ctx) ==
               "Fermix daemon not running (or [fermix_channels.acp] disabled) — " <>
                 "start it with `fermix run`; socket: #{ctx.socket_path}\n"

      assert stdout(ctx) == ""
    end

    test "the same refusal covers a socket path the OS cannot address", ctx do
      unaddressable = Path.join(System.tmp_dir!(), String.duplicate("a", 200) <> ".sock")

      assert AcpCommand.run([], opts(ctx, socket_path: unaddressable)) == 1
      assert stderr(ctx) =~ @connect_refusal_prefix
      assert stderr(ctx) =~ unaddressable
      assert stdout(ctx) == ""
    end
  end

  describe "the bridge handshake" do
    test "sends one hello line carrying the bridge version, app version and the whole env", ctx do
      System.put_env("FERMIX_ACP_BRIDGE_TEST_MARKER", "marker-42")
      on_exit(fn -> System.delete_env("FERMIX_ACP_BRIDGE_TEST_MARKER") end)

      {socket, task} = connect_bridge(ctx)

      {hello, ""} = recv_line(socket)

      assert %{"fermix_bridge" => 1, "app_version" => version, "env" => env} =
               Jason.decode!(hello)

      assert version == to_string(Application.spec(:fermix_core, :vsn))
      assert env["FERMIX_ACP_BRIDGE_TEST_MARKER"] == "marker-42"
      assert Map.has_key?(env, "PATH")

      :ok = :gen_tcp.send(socket, ok_ack())
      ScriptedIn.close(ctx.stdin)

      assert Task.await(task, 5_000) == 0
      assert stdout(ctx) == ""
    end

    test "surfaces the daemon's own refusal message and exits 1", ctx do
      {socket, task} = connect_bridge(ctx)
      {_hello, ""} = recv_line(socket)

      :ok = :gen_tcp.send(socket, error_ack("too many ACP connections (max 64)"))

      assert Task.await(task, 5_000) == 1
      assert stderr(ctx) =~ "too many ACP connections (max 64)"
      assert stdout(ctx) == ""
    end

    test "exits 1 when the ack line is not valid JSON", ctx do
      {socket, task} = connect_bridge(ctx)
      {_hello, ""} = recv_line(socket)

      :ok = :gen_tcp.send(socket, "not json at all\n")

      assert Task.await(task, 5_000) == 1
      assert stderr(ctx) =~ "not valid JSON"
      assert stdout(ctx) == ""
    end

    test "exits 1 when the first line is a protocol frame instead of an ack", ctx do
      {socket, task} = connect_bridge(ctx)
      {_hello, ""} = recv_line(socket)

      :ok = :gen_tcp.send(socket, ~s({"jsonrpc":"2.0","id":1,"result":{}}\n))

      assert Task.await(task, 5_000) == 1
      assert stderr(ctx) =~ "ack"
      assert stdout(ctx) == ""
    end

    test "exits 1 when no ack arrives before the deadline", ctx do
      {_socket, task} = connect_bridge(ctx, ack_timeout_ms: 100)

      assert Task.await(task, 5_000) == 1
      assert stderr(ctx) =~ "100ms"
      assert stdout(ctx) == ""
    end

    test "exits 1 when the daemon closes before acknowledging", ctx do
      {socket, task} = connect_bridge(ctx)
      {_hello, ""} = recv_line(socket)

      :ok = :gen_tcp.close(socket)

      assert Task.await(task, 5_000) == 1
      assert stderr(ctx) =~ "closed"
      assert stdout(ctx) == ""
    end
  end

  describe "the byte pump" do
    test "copies frames both ways byte for byte and exits 0 on stdin EOF", ctx do
      {socket, task} = bridge_after_ack(ctx)

      # UTF-8 plus JSON-escaped newlines inside a string: a pump that re-encoded
      # or reframed anything would show up here.
      inbound = [
        ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":2}}\n),
        ~s({"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"t":"héllo — ok\\n\\tdone"}}\n),
        ~s({"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"s-1"}}\n)
      ]

      Enum.each(inbound, &ScriptedIn.push(ctx.stdin, &1))
      assert recv_bytes(socket, IO.iodata_length(inbound)) == IO.iodata_to_binary(inbound)

      # Non-ASCII on the way back too: a device left in the VM's default unicode
      # mode double-encodes these bytes instead of copying them.
      outbound = ~s({"jsonrpc":"2.0","id":1,"result":{"text":"réponse — ✓"}}\n)
      :ok = :gen_tcp.send(socket, outbound)
      wait_until(fn -> stdout(ctx) == outbound end)

      ScriptedIn.close(ctx.stdin)
      assert Task.await(task, 5_000) == 0
      assert stdout(ctx) == outbound
      assert stderr(ctx) == ""
    end

    test "reassembles a daemon frame split across several socket writes", ctx do
      {socket, task} = bridge_after_ack(ctx)

      chunk = String.duplicate("x", 120_000)
      frame = ~s({"jsonrpc":"2.0","id":9,"result":{"text":"#{chunk}#{chunk}"}}\n)
      {head, tail} = String.split_at(frame, 100_000)

      :ok = :gen_tcp.send(socket, head)
      :ok = :gen_tcp.send(socket, tail)
      wait_until(fn -> byte_size(stdout(ctx)) == byte_size(frame) end)

      ScriptedIn.close(ctx.stdin)
      assert Task.await(task, 5_000) == 0
      assert stdout(ctx) == frame
    end

    test "forwards a large client frame without splitting it", ctx do
      {socket, task} = bridge_after_ack(ctx)

      frame = ~s({"jsonrpc":"2.0","id":3,"params":{"blob":"#{String.duplicate("z", 250_000)}"}}\n)
      ScriptedIn.push(ctx.stdin, frame)

      assert recv_bytes(socket, byte_size(frame)) == frame

      ScriptedIn.close(ctx.stdin)
      assert Task.await(task, 5_000) == 0
      assert stdout(ctx) == ""
    end

    test "forwards protocol bytes that shared the ack's TCP segment", ctx do
      {socket, task} = connect_bridge(ctx)
      {_hello, ""} = recv_line(socket)

      frame = ~s({"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}\n)
      :ok = :gen_tcp.send(socket, ok_ack() <> frame)
      wait_until(fn -> stdout(ctx) == frame end)

      ScriptedIn.close(ctx.stdin)
      assert Task.await(task, 5_000) == 0
      assert stdout(ctx) == frame
    end

    test "exits 1 with one stderr line when the daemon disappears mid-session", ctx do
      {socket, task} = connect_bridge(ctx)
      {_hello, ""} = recv_line(socket)

      frame = ~s({"jsonrpc":"2.0","id":1,"result":{}}\n)
      :ok = :gen_tcp.send(socket, ok_ack() <> frame)
      wait_until(fn -> stdout(ctx) == frame end)
      :ok = :gen_tcp.close(socket)

      assert Task.await(task, 5_000) == 1
      assert stdout(ctx) == frame
      assert length(String.split(String.trim_trailing(stderr(ctx), "\n"), "\n")) == 1
      assert stderr(ctx) =~ "closed"
    end
  end

  describe "stdout purity" do
    test "the logger's default handler writes to stderr before any pumping", ctx do
      install_stdio_default_handler()
      {socket, task} = bridge_after_ack(ctx)

      frame = ~s({"jsonrpc":"2.0","id":1,"result":{}}\n)
      :ok = :gen_tcp.send(socket, frame)
      wait_until(fn -> stdout(ctx) == frame end)

      assert {:ok, %{config: %{type: :standard_error}}} = :logger.get_handler_config(:default)

      ScriptedIn.close(ctx.stdin)
      assert Task.await(task, 5_000) == 0
      assert stdout(ctx) == frame
    end

    test "a VM with no default handler is already pure and is left alone", ctx do
      _ = :logger.remove_handler(:default)
      {socket, task} = bridge_after_ack(ctx)

      frame = ~s({"jsonrpc":"2.0","id":1,"result":{}}\n)
      :ok = :gen_tcp.send(socket, frame)
      wait_until(fn -> stdout(ctx) == frame end)

      assert :logger.get_handler_config(:default) == {:error, {:not_found, :default}}

      ScriptedIn.close(ctx.stdin)
      assert Task.await(task, 5_000) == 0
      assert stdout(ctx) == frame
    end

    test "a scripted session's stdout is byte-exact the daemon's bytes", ctx do
      {socket, task} = connect_bridge(ctx)
      {_hello, ""} = recv_line(socket)

      daemon_bytes =
        Enum.map_join(1..20, fn id ->
          ~s({"jsonrpc":"2.0","id":#{id},"result":{"sessionUpdate":"chunk #{id} ✓"}}\n)
        end)

      :ok = :gen_tcp.send(socket, ok_ack())
      ScriptedIn.push(ctx.stdin, ~s({"jsonrpc":"2.0","id":1,"method":"initialize"}\n))
      {_client_frame, ""} = recv_line(socket)
      :ok = :gen_tcp.send(socket, daemon_bytes)
      wait_until(fn -> stdout(ctx) == daemon_bytes end)

      ScriptedIn.close(ctx.stdin)
      assert Task.await(task, 5_000) == 0
      assert stdout(ctx) == daemon_bytes
      assert stderr(ctx) == ""
    end
  end

  describe "arguments" do
    test "takes none: anything else is a usage error on stderr with exit 2", ctx do
      assert AcpCommand.run(["--session", "x"], opts(ctx)) == 2
      assert stderr(ctx) =~ "usage"
      assert stdout(ctx) == ""
    end
  end

  # --- fixture helpers ------------------------------------------------------

  defp opts(ctx, extra \\ []) do
    Keyword.merge(
      [socket_path: ctx.socket_path, stdin: ctx.stdin, stdout: ctx.out, stderr: ctx.err],
      extra
    )
  end

  defp start_bridge(ctx, extra) do
    Task.async(fn -> AcpCommand.run([], opts(ctx, extra)) end)
  end

  # Stands in for `Channels.Acp.Endpoint`: binds the socket, accepts the bridge's
  # connection, and hands it to the test process so the daemon side is scripted
  # line by line.
  defp connect_bridge(ctx, extra \\ []) do
    :ok = listen_daemon(ctx)
    task = start_bridge(ctx, extra)
    {accept_socket(), task}
  end

  defp bridge_after_ack(ctx) do
    {socket, task} = connect_bridge(ctx)
    {_hello, ""} = recv_line(socket)
    :ok = :gen_tcp.send(socket, ok_ack())
    {socket, task}
  end

  defp listen_daemon(ctx) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        {:active, false},
        {:ifaddr, {:local, ctx.socket_path}},
        {:reuseaddr, true}
      ])

    test = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen, 5_000)
      :ok = :gen_tcp.controlling_process(socket, test)
      send(test, {:accepted, socket})
    end)

    on_exit(fn -> :gen_tcp.close(listen) end)
    :ok
  end

  defp accept_socket do
    receive do
      {:accepted, socket} -> socket
    after
      5_000 -> flunk("the bridge never connected to the fake daemon socket")
    end
  end

  defp ok_ack, do: Jason.encode!(%{"fermix_bridge_ack" => %{"status" => "ok"}}) <> "\n"

  defp error_ack(message) do
    Jason.encode!(%{"fermix_bridge_ack" => %{"status" => "error", "message" => message}}) <> "\n"
  end

  defp stdout(ctx), do: ctx.out |> StringIO.contents() |> elem(1)
  defp stderr(ctx), do: ctx.err |> StringIO.contents() |> elem(1)

  # Bounded: 200 receives at most, each with its own 1 s socket deadline.
  defp recv_line(socket), do: recv_line(socket, "", 200)

  defp recv_line(_socket, acc, 0), do: flunk("no complete line arrived; got #{inspect(acc)}")

  defp recv_line(socket, acc, tries) do
    case :binary.split(acc, "\n") do
      [line, rest] -> {line, rest}
      [_partial] -> recv_line(socket, acc <> recv_some(socket), tries - 1)
    end
  end

  defp recv_some(socket) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, data} -> data
      {:error, reason} -> flunk("fake daemon read failed: #{inspect(reason)}")
    end
  end

  defp recv_bytes(socket, count) do
    case :gen_tcp.recv(socket, count, 5_000) do
      {:ok, data} -> data
      {:error, reason} -> flunk("fake daemon read of #{count} bytes failed: #{inspect(reason)}")
    end
  end

  # Bounded poll: 200 tries at 10 ms, then the test fails rather than hanging.
  defp wait_until(fun), do: wait_until(fun, 200)
  defp wait_until(_fun, 0), do: flunk("the expected pump output never arrived")

  defp wait_until(fun, tries) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, tries - 1)
    end
  end

  # The verb moves the VM's default logger handler to stderr; restore whatever
  # this test VM started with so the rest of the suite is unaffected.
  # `ExUnit.start(capture_log: true)` normally leaves no `:default` handler at
  # all, which is why the snapshot is the raw result, absence included.
  defp snapshot_default_logger, do: :logger.get_handler_config(:default)

  defp restore_default_logger({:ok, config}) do
    {module, rest} = Map.pop!(config, :module)
    _ = :logger.remove_handler(:default)
    :ok = :logger.add_handler(:default, module, Map.delete(rest, :id))
  end

  defp restore_default_logger({:error, {:not_found, :default}}) do
    _ = :logger.remove_handler(:default)
    :ok
  end

  # A real `fermix acp` process boots with the stdout-writing default handler
  # this test VM lacks; install one so the redirect has something to fix.
  defp install_stdio_default_handler do
    _ = :logger.remove_handler(:default)

    :ok =
      :logger.add_handler(:default, :logger_std_h, %{
        config: %{type: :standard_io},
        level: :error
      })
  end
end
