defmodule Fermix.CLI.ChatCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.ChatCommand
  alias Fermix.CLI.Daemon

  defmodule TestCLIBridge do
    def default_timeout_ms, do: 120_000

    def dispatch_input_sync(content, opts) do
      test_pid = Application.fetch_env!(:fermix_core, :chat_command_test_pid)
      send(test_pid, {:chat_command_bridge_call, content, opts})

      case Application.get_env(:fermix_core, :chat_command_bridge_result, :ok) do
        :ok ->
          {:ok,
           %{
             response: "chat reply: #{content}",
             session_id: Keyword.get(opts, :session_id, "cli")
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  setup do
    previous_home = System.get_env("FERMIX_HOME")
    previous_bridge = Application.get_env(:fermix_core, :cli_channel_bridge)
    previous_pid = Application.get_env(:fermix_core, :chat_command_test_pid)
    previous_result = Application.get_env(:fermix_core, :chat_command_bridge_result)

    socket_dir = mkdir!()
    task_sup = :"chat_command_task_sup_#{System.unique_integer([:positive, :monotonic])}"
    System.put_env("FERMIX_HOME", socket_dir)
    Application.put_env(:fermix_core, :cli_channel_bridge, TestCLIBridge)
    Application.put_env(:fermix_core, :chat_command_test_pid, self())
    Application.put_env(:fermix_core, :chat_command_bridge_result, :ok)

    {:ok, _sup} = Task.Supervisor.start_link(name: task_sup)

    {:ok, daemon} =
      Daemon.start_link(
        name: :"chat_command_daemon_#{System.unique_integer([:positive, :monotonic])}",
        socket_path: Path.join(socket_dir, "daemon.sock"),
        task_supervisor: task_sup
      )

    on_exit(fn ->
      if Process.alive?(daemon), do: GenServer.stop(daemon, :normal, 1_000)
      restore_env("FERMIX_HOME", previous_home)
      restore_app_env(:cli_channel_bridge, previous_bridge)
      restore_app_env(:chat_command_test_pid, previous_pid)
      restore_app_env(:chat_command_bridge_result, previous_result)
      FermixTestSupport.SafeRm.rm_rf!(socket_dir)
    end)

    :ok
  end

  test "prints daemon agent reply for argv content" do
    test_self = self()

    output =
      capture_io(fn ->
        send(test_self, {:chat_exit, ChatCommand.run(["hello", "world"])})
      end)

    assert_receive {:chat_exit, 0}
    assert output == "chat reply: hello world\n"
    assert_receive {:chat_command_bridge_call, "hello world", opts}
    assert Keyword.get(opts, :session_id) == "cli"
  end

  test "passes session and timeout options" do
    test_self = self()

    output =
      capture_io(fn ->
        send(
          test_self,
          {:chat_exit, ChatCommand.run(["--session", "scenario-1", "--timeout", "1000", "hello"])}
        )
      end)

    assert_receive {:chat_exit, 0}
    assert output == "chat reply: hello\n"
    assert_receive {:chat_command_bridge_call, "hello", opts}
    assert Keyword.get(opts, :session_id) == "scenario-1"
    assert Keyword.get(opts, :timeout_ms) == 1_000
  end

  test "prints JSON success envelope" do
    test_self = self()

    output =
      capture_io(fn ->
        send(test_self, {:chat_exit, ChatCommand.run(["--json", "hello"])})
      end)

    assert_receive {:chat_exit, 0}
    decoded = Jason.decode!(output)
    assert decoded["status"] == "ok"
    assert decoded["response"] == "chat reply: hello"
    assert decoded["session_id"] == "cli"
  end

  test "prints daemon bridge errors and exits 1" do
    Application.put_env(:fermix_core, :chat_command_bridge_result, {:error, :timeout})

    output =
      capture_io(:stderr, fn ->
        assert ChatCommand.run(["hello"]) == 1
      end)

    assert output == "fermix: timeout\n"
    assert_receive {:chat_command_bridge_call, "hello", opts}
    assert Keyword.get(opts, :session_id) == "cli"
  end

  test "rejects cumulative encoded attachments over the daemon frame cap" do
    dir = mkdir!()
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

    first = Path.join(dir, "first.jpg")
    second = Path.join(dir, "second.jpg")
    File.write!(first, :binary.copy(<<1>>, 1_700_000))
    File.write!(second, :binary.copy(<<2>>, 1_700_000))

    output =
      capture_io(:stderr, fn ->
        assert ChatCommand.run(["--attach", first, "--attach", second]) == 1
      end)

    assert output =~ "exceeds daemon frame cap"
    refute_received {:chat_command_bridge_call, _content, _opts}
  end

  test "prints JSON error envelope with session id" do
    Application.put_env(:fermix_core, :chat_command_bridge_result, {:error, :timeout})
    test_self = self()

    output =
      capture_io(fn ->
        send(
          test_self,
          {:chat_exit, ChatCommand.run(["--json", "--session", "scenario-error", "hello"])}
        )
      end)

    assert_receive {:chat_exit, 1}
    decoded = Jason.decode!(output)

    assert decoded == %{
             "status" => "error",
             "error" => "timeout",
             "session_id" => "scenario-error"
           }
  end

  test "emits valid JSON error envelope when daemon sends malformed JSON" do
    # Simulate the recv_line truncation: a daemon that sends invalid JSON (e.g. a
    # 9216-byte partial body). The client gets a Jason.DecodeError struct back from
    # Client.agent_message; render_error must not crash on that non-string reason.
    socket_dir = mkdir!()
    socket_path = Path.join(socket_dir, "daemon.sock")

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        {:active, false},
        {:packet, :line},
        {:ifaddr, {:local, to_charlist(socket_path)}},
        {:reuseaddr, true}
      ])

    acceptor =
      Task.async(fn ->
        {:ok, conn} = :gen_tcp.accept(listen_socket, 5_000)
        # recv the client request then send back malformed JSON (no closing brace)
        _ = :gen_tcp.recv(conn, 0, 5_000)
        :gen_tcp.send(conn, "{\"status\":\"ok\",\"response\": TRUNCATED\n")
        :gen_tcp.close(conn)
      end)

    prev_home = System.get_env("FERMIX_HOME")
    System.put_env("FERMIX_HOME", socket_dir)

    output =
      capture_io(fn ->
        assert ChatCommand.run(["--json", "--timeout", "2000", "hello"]) == 1
      end)

    Task.await(acceptor, 5_000)

    decoded = Jason.decode!(output)
    assert decoded["status"] == "error"
    assert is_binary(decoded["error"]) and decoded["error"] != ""

    restore_env("FERMIX_HOME", prev_home)
    :gen_tcp.close(listen_socket)
    FermixTestSupport.SafeRm.rm_rf!(socket_dir)
  end

  test "reads stdin only when --stdin is provided" do
    test_self = self()

    output =
      capture_io("from stdin\n", fn ->
        send(test_self, {:chat_exit, ChatCommand.run(["--stdin"])})
      end)

    assert_receive {:chat_exit, 0}
    assert output == "chat reply: from stdin\n"
  end

  test "returns usage error for missing message" do
    output =
      capture_io(:stderr, fn ->
        assert ChatCommand.run([]) == 2
      end)

    assert output =~ "usage: fermix ask"
  end

  test "returns usage error for non-positive timeout" do
    output =
      capture_io(:stderr, fn ->
        assert ChatCommand.run(["--timeout", "0", "hello"]) == 2
      end)

    assert output =~ "usage: fermix ask"
  end

  test "returns not-running error when daemon is unavailable" do
    previous_home = System.get_env("FERMIX_HOME")
    missing_home = mkdir!()
    System.put_env("FERMIX_HOME", missing_home)

    output =
      capture_io(:stderr, fn ->
        assert ChatCommand.run(["hello"]) == 3
      end)

    assert output =~ "fermix: not running"

    restore_env("FERMIX_HOME", previous_home)
    FermixTestSupport.SafeRm.rm_rf!(missing_home)
  end

  defp mkdir! do
    path =
      Path.join(
        System.tmp_dir!(),
        "fermix-chat-command-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    path
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
  defp restore_app_env(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore_app_env(key, value), do: Application.put_env(:fermix_core, key, value)
end
