defmodule Fermix.CLI.DaemonTest do
  use ExUnit.Case, async: false

  alias Fermix.CLI.Daemon
  alias Fermix.CLI.Daemon.Client

  defmodule TestCLIBridge do
    def default_timeout_ms, do: 120_000

    def dispatch_input_sync(content, opts) do
      test_pid = Application.fetch_env!(:fermix_core, :daemon_test_pid)
      send(test_pid, {:bridge_call, content, opts})

      case Application.get_env(:fermix_core, :daemon_bridge_result, :ok) do
        :ok ->
          {:ok,
           %{
             response: "daemon reply: #{content}",
             session_id: Keyword.get(opts, :session_id, "cli")
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  setup do
    previous_bridge = Application.get_env(:fermix_core, :cli_channel_bridge)
    previous_pid = Application.get_env(:fermix_core, :daemon_test_pid)
    previous_result = Application.get_env(:fermix_core, :daemon_bridge_result)
    {:ok, _sup} = Task.Supervisor.start_link(name: __MODULE__.TaskSup)
    socket_dir = mkdir!()
    socket_path = Path.join(socket_dir, "fermix.sock")
    Application.put_env(:fermix_core, :cli_channel_bridge, TestCLIBridge)
    Application.put_env(:fermix_core, :daemon_test_pid, self())
    Application.put_env(:fermix_core, :daemon_bridge_result, :ok)

    {:ok, daemon} =
      Daemon.start_link(
        name: :"daemon_#{System.unique_integer([:positive, :monotonic])}",
        socket_path: socket_path,
        task_supervisor: __MODULE__.TaskSup
      )

    on_exit(fn ->
      if Process.alive?(daemon), do: GenServer.stop(daemon, :normal, 1_000)
      restore_app_env(:cli_channel_bridge, previous_bridge)
      restore_app_env(:daemon_test_pid, previous_pid)
      restore_app_env(:daemon_bridge_result, previous_result)
      FermixTestSupport.SafeRm.rm_rf(socket_dir)
    end)

    %{socket_path: socket_path, daemon: daemon}
  end

  test "status returns ok with version + uptime", %{socket_path: socket_path} do
    Process.sleep(50)
    assert {:ok, reply} = Client.status(socket_path: socket_path, timeout: 1_000)
    assert reply["status"] == "ok"
    assert is_binary(reply["version"])
    assert is_integer(reply["uptime_ms"])
    assert reply["uptime_ms"] >= 0
  end

  test "unknown method returns error", %{socket_path: socket_path} do
    Process.sleep(50)

    assert {:ok, reply} =
             Client.request("does-not-exist", socket_path: socket_path, timeout: 1_000)

    assert reply["status"] == "error"
    assert reply["reason"] == "unknown method"
    assert reply["method"] == "does-not-exist"
  end

  test "no daemon listening returns :not_running" do
    socket_dir = mkdir!()
    socket_path = Path.join(socket_dir, "missing.sock")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(socket_dir) end)

    assert {:error, :not_running} =
             Client.status(socket_path: socket_path, timeout: 500)
  end

  test "socket file is created with 0600 permissions", %{socket_path: socket_path} do
    Process.sleep(50)
    {:ok, %File.Stat{mode: mode}} = File.stat(socket_path)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "stale socket file is replaced on init" do
    socket_dir = mkdir!()
    socket_path = Path.join(socket_dir, "stale.sock")
    File.touch!(socket_path)
    {:ok, _sup} = Task.Supervisor.start_link(name: __MODULE__.StaleSup)

    {:ok, daemon} =
      Daemon.start_link(
        name: :"stale_daemon_#{System.unique_integer([:positive, :monotonic])}",
        socket_path: socket_path,
        task_supervisor: __MODULE__.StaleSup
      )

    Process.sleep(50)
    assert {:ok, %{"status" => "ok"}} = Client.status(socket_path: socket_path, timeout: 1_000)

    GenServer.stop(daemon, :normal, 1_000)
    FermixTestSupport.SafeRm.rm_rf(socket_dir)
  end

  test "second daemon refuses to bind over a live socket", %{socket_path: socket_path} do
    Process.sleep(50)
    {:ok, _sup} = Task.Supervisor.start_link(name: __MODULE__.SecondSup)

    Process.flag(:trap_exit, true)

    result =
      Daemon.start_link(
        name: :"second_daemon_#{System.unique_integer([:positive, :monotonic])}",
        socket_path: socket_path,
        task_supervisor: __MODULE__.SecondSup
      )

    assert {:error, {:another_daemon_running, ^socket_path}} = result

    # The original daemon must still answer; the second one didn't unlink
    # the socket out from under it.
    assert {:ok, %{"status" => "ok"}} =
             Client.status(socket_path: socket_path, timeout: 1_000)
  end

  test "agent_message routes the prompt through the configured CLI bridge", %{
    socket_path: socket_path
  } do
    assert {:ok, reply} =
             Client.agent_message(
               %{"content" => "hello", "session_id" => "daemon-test", "timeout_ms" => 1_000},
               socket_path: socket_path,
               timeout: 2_000
             )

    assert reply["status"] == "ok"
    assert reply["response"] == "daemon reply: hello"
    assert reply["session_id"] == "daemon-test"

    assert_receive {:bridge_call, "hello", opts}
    assert Keyword.get(opts, :session_id) == "daemon-test"
    assert Keyword.get(opts, :timeout_ms) == 1_000
  end

  test "agent_message returns empty input errors without calling the bridge", %{
    socket_path: socket_path
  } do
    assert {:ok, reply} =
             Client.agent_message(%{"content" => "   "},
               socket_path: socket_path,
               timeout: 1_000
             )

    assert reply["status"] == "error"
    assert reply["error"] == "empty_input"
    refute_received {:bridge_call, _, _}
  end

  test "agent_message returns bridge errors with the normalized session id", %{
    socket_path: socket_path
  } do
    Application.put_env(:fermix_core, :daemon_bridge_result, {:error, :timeout})

    assert {:ok, reply} =
             Client.agent_message(
               %{"content" => "hello", "session_id" => "daemon-test"},
               socket_path: socket_path,
               timeout: 1_000
             )

    assert reply["status"] == "error"
    assert reply["error"] == "timeout"
    assert reply["session_id"] == "daemon-test"
    assert_receive {:bridge_call, "hello", opts}
    assert Keyword.get(opts, :session_id) == "daemon-test"
  end

  test "skills_list returns JSON-safe skill summaries", %{socket_path: socket_path} do
    assert {:ok, reply} = Client.request("skills_list", socket_path: socket_path, timeout: 1_000)

    assert reply["status"] == "ok"
    assert is_integer(reply["skills"]["count"])
    assert is_list(reply["skills"]["skills"])
  end

  test "skills_view returns the selected skill body", %{socket_path: socket_path} do
    assert {:ok, reply} =
             Client.request("skills_view",
               socket_path: socket_path,
               timeout: 1_000,
               params: %{"name" => "self_knowledge"}
             )

    assert reply["status"] == "ok"
    assert reply["skill"]["name"] == "self_knowledge"
    assert is_binary(reply["skill"]["body"])
  end

  test "request reassembles a reply larger than the socket line buffer" do
    # `{:packet, :line}` truncates a line past the inet driver buffer (9216
    # bytes), so a single recv would cut a large reply mid-stream. The client
    # must accumulate until the trailing newline. 300 KB is far past any buffer.
    dir = mkdir!()
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(dir) end)
    socket_path = Path.join(dir, "big.sock")
    big_value = String.duplicate("x", 300_000)
    payload = Jason.encode!(%{"status" => "ok", "body" => big_value})

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        {:packet, :line},
        {:active, false},
        {:ifaddr, {:local, to_charlist(socket_path)}}
      ])

    on_exit(fn -> :gen_tcp.close(listener) end)

    # Linked to the test pid, so it dies with the test on any failure path.
    Task.async(fn ->
      {:ok, conn} = :gen_tcp.accept(listener, 2_000)
      {:ok, _request} = :gen_tcp.recv(conn, 0, 2_000)
      :ok = :gen_tcp.send(conn, [payload, "\n"])
      :gen_tcp.recv(conn, 0, 2_000)
      :gen_tcp.close(conn)
    end)

    assert {:ok, reply} = Client.request("big", socket_path: socket_path, timeout: 2_000)
    assert reply["status"] == "ok"
    assert reply["body"] == big_value
  end

  defp mkdir! do
    path =
      Path.join(
        System.tmp_dir!(),
        "fermix-daemon-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    path
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore_app_env(key, value), do: Application.put_env(:fermix_core, key, value)
end
