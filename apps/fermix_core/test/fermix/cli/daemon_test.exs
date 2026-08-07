defmodule Fermix.CLI.DaemonTest do
  use ExUnit.Case, async: false

  alias Fermix.CLI.Daemon
  alias Fermix.CLI.Daemon.Client
  alias FermixCore.Capabilities.MCP.RuntimeStatus

  defmodule TestPluginsRuntime do
    def apply_persisted do
      test_pid = Application.fetch_env!(:fermix_core, :daemon_test_pid)
      send(test_pid, :plugins_apply_called)

      {:ok,
       %{
         capabilities: %{registered: 0},
         skills: :handled_by_main_agent,
         main_agent: %{version: 1},
         realtime: :skipped
       }}
    end
  end

  defmodule TestPluginsRuntimeWithSkillErrors do
    # Real SkillRegistry reload summaries carry tuple `errors`; the daemon must
    # render them as strings instead of crashing the connection handler.
    def apply_persisted do
      test_pid = Application.fetch_env!(:fermix_core, :daemon_test_pid)
      send(test_pid, :plugins_apply_called)

      {:ok,
       %{
         capabilities: %{registered: 0},
         skills: :handled_by_main_agent,
         main_agent: %{
           version: 2,
           skills: 1,
           names: ["ok-skill"],
           added: [],
           removed: [],
           changed: [],
           errors: [{:invalid_skill, "broken", :bad_frontmatter}]
         },
         realtime: :skipped
       }}
    end
  end

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

  test "agent_message decodes the request cwd param and forwards it to the bridge", %{
    socket_path: socket_path
  } do
    assert {:ok, _reply} =
             Client.agent_message(
               %{"content" => "hello", "cwd" => "/home/owner/project"},
               socket_path: socket_path,
               timeout: 2_000
             )

    assert_receive {:bridge_call, "hello", opts}
    assert Keyword.get(opts, :cwd) == "/home/owner/project"
  end

  test "agent_message forwards a nil cwd when the param is absent", %{
    socket_path: socket_path
  } do
    assert {:ok, _reply} =
             Client.agent_message(
               %{"content" => "hello"},
               socket_path: socket_path,
               timeout: 2_000
             )

    assert_receive {:bridge_call, "hello", opts}
    assert Keyword.get(opts, :cwd) == nil
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

  test "plugins_apply re-applies persisted config through the plugins runtime" do
    socket_dir = mkdir!()
    socket_path = Path.join(socket_dir, "plugins.sock")
    {:ok, _sup} = Task.Supervisor.start_link(name: __MODULE__.PluginsSup)

    {:ok, daemon} =
      Daemon.start_link(
        name: :"plugins_daemon_#{System.unique_integer([:positive, :monotonic])}",
        socket_path: socket_path,
        task_supervisor: __MODULE__.PluginsSup,
        plugins_runtime: TestPluginsRuntime
      )

    on_exit(fn ->
      if Process.alive?(daemon), do: GenServer.stop(daemon, :normal, 1_000)
      FermixTestSupport.SafeRm.rm_rf(socket_dir)
    end)

    assert {:ok, reply} =
             Client.request("plugins_apply", socket_path: socket_path, timeout: 1_000)

    assert reply["status"] == "ok"
    assert is_map(reply["reload"])
    assert reply["reload"]["skills"] == "handled_by_main_agent"
    assert_receive :plugins_apply_called
  end

  test "plugins_apply renders skill reload errors instead of crashing" do
    socket_dir = mkdir!()
    socket_path = Path.join(socket_dir, "plugins_errors.sock")
    {:ok, _sup} = Task.Supervisor.start_link(name: __MODULE__.PluginsErrSup)

    {:ok, daemon} =
      Daemon.start_link(
        name: :"plugins_err_daemon_#{System.unique_integer([:positive, :monotonic])}",
        socket_path: socket_path,
        task_supervisor: __MODULE__.PluginsErrSup,
        plugins_runtime: TestPluginsRuntimeWithSkillErrors
      )

    on_exit(fn ->
      if Process.alive?(daemon), do: GenServer.stop(daemon, :normal, 1_000)
      FermixTestSupport.SafeRm.rm_rf(socket_dir)
    end)

    assert {:ok, reply} =
             Client.request("plugins_apply", socket_path: socket_path, timeout: 1_000)

    assert reply["status"] == "ok"
    assert reply["reload"]["main_agent"]["version"] == 2
    assert [error] = reply["reload"]["main_agent"]["errors"]
    assert error =~ "invalid_skill"
    assert error =~ "broken"
    assert_receive :plugins_apply_called
  end

  # M27 §7.8: the remote-MCP status table lives in the daemon's memory, so a
  # one-shot CLI VM (`fermix doctor`) can only read it over this socket op.
  test "plugins_runtime_status serializes the daemon's remote MCP status table" do
    socket_dir = mkdir!()
    socket_path = Path.join(socket_dir, "runtime_status.sock")
    {:ok, _sup} = Task.Supervisor.start_link(name: __MODULE__.RuntimeStatusSup)

    {:ok, status_server} =
      RuntimeStatus.start_link(
        name: :"runtime_status_#{System.unique_integer([:positive, :monotonic])}"
      )

    owner = spawn(fn -> Process.sleep(:infinity) end)
    source_id = {:plugin, "eden"}

    {:ok, generation} =
      RuntimeStatus.register_owner(status_server, source_id, owner, plugin: "eden")

    :ok =
      RuntimeStatus.put(
        status_server,
        source_id,
        generation,
        :upstream_contract_mismatch,
        :tool_missing
      )

    {:ok, daemon} =
      Daemon.start_link(
        name: :"runtime_status_daemon_#{System.unique_integer([:positive, :monotonic])}",
        socket_path: socket_path,
        task_supervisor: __MODULE__.RuntimeStatusSup,
        runtime_status: status_server
      )

    on_exit(fn ->
      if Process.alive?(daemon), do: GenServer.stop(daemon, :normal, 1_000)
      Process.exit(owner, :kill)
      FermixTestSupport.SafeRm.rm_rf(socket_dir)
    end)

    assert {:ok, reply} =
             Client.request("plugins_runtime_status", socket_path: socket_path, timeout: 1_000)

    assert reply["status"] == "ok"
    assert [row] = reply["runtime_status"]
    assert row["source"] == "plugin:eden"
    assert row["plugin"] == "eden"
    assert row["status"] == "upstream_contract_mismatch"
    assert row["detail"] == "tool_missing"
    assert is_integer(row["updated_at"])
    # The generation ref and owner pid are runtime bookkeeping, not operator
    # facts — §11.1 forbids exporting generation references at all.
    refute Map.has_key?(row, "generation")
    refute Map.has_key?(row, "owner")
  end

  test "plugins_runtime_status reports an error when the status table is unavailable" do
    socket_dir = mkdir!()
    socket_path = Path.join(socket_dir, "runtime_status_down.sock")
    {:ok, _sup} = Task.Supervisor.start_link(name: __MODULE__.RuntimeStatusDownSup)

    {:ok, daemon} =
      Daemon.start_link(
        name: :"runtime_status_down_daemon_#{System.unique_integer([:positive, :monotonic])}",
        socket_path: socket_path,
        task_supervisor: __MODULE__.RuntimeStatusDownSup,
        runtime_status: :"never_started_#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn ->
      if Process.alive?(daemon), do: GenServer.stop(daemon, :normal, 1_000)
      FermixTestSupport.SafeRm.rm_rf(socket_dir)
    end)

    assert {:ok, reply} =
             Client.request("plugins_runtime_status", socket_path: socket_path, timeout: 1_000)

    assert reply["status"] == "error"
    assert reply["reason"] =~ "noproc"
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
               params: %{"name" => "self-knowledge"}
             )

    assert reply["status"] == "ok"
    assert reply["skill"]["name"] == "self-knowledge"
    assert is_binary(reply["skill"]["body"])
  end

  test "request handles a reply larger than the old 9216-byte inet line buffer" do
    # With {:packet, 4} framing the inet driver delivers the full payload in one
    # recv regardless of size. 300 KB verifies there is no silent truncation.
    dir = mkdir!()
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(dir) end)
    socket_path = Path.join(dir, "big.sock")
    big_value = String.duplicate("x", 300_000)
    payload = Jason.encode!(%{"status" => "ok", "body" => big_value})

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        {:packet, 4},
        {:active, false},
        {:ifaddr, {:local, to_charlist(socket_path)}}
      ])

    on_exit(fn -> :gen_tcp.close(listener) end)

    Task.async(fn ->
      {:ok, conn} = :gen_tcp.accept(listener, 2_000)
      {:ok, _request} = :gen_tcp.recv(conn, 0, 2_000)
      :ok = :gen_tcp.send(conn, payload)
      :gen_tcp.close(conn)
    end)

    assert {:ok, reply} = Client.request("big", socket_path: socket_path, timeout: 2_000)
    assert reply["status"] == "ok"
    assert reply["body"] == big_value
  end

  test "request fails fast on an oversized frame header instead of buffering" do
    # Version skew: a pre-packet-4 daemon replies with newline-delimited JSON.
    # Read as a {:packet, 4} header, its first 4 ASCII bytes declare a ~2 GB
    # frame. The :packet_size bound turns that into an immediate :emsgsize
    # instead of buffering toward 2 GB until the timeout expires.
    dir = mkdir!()
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(dir) end)
    socket_path = Path.join(dir, "old.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        {:active, false},
        {:ifaddr, {:local, to_charlist(socket_path)}}
      ])

    on_exit(fn -> :gen_tcp.close(listener) end)

    Task.async(fn ->
      {:ok, conn} = :gen_tcp.accept(listener, 2_000)
      {:ok, _request} = :gen_tcp.recv(conn, 0, 2_000)
      :ok = :gen_tcp.send(conn, [Jason.encode!(%{"status" => "ok"}), "\n"])
      # Hold the socket open like an old daemon awaiting its next line, so
      # the client cannot mistake a close for end-of-frame.
      _ = :gen_tcp.recv(conn, 0, 2_000)
      :gen_tcp.close(conn)
    end)

    assert {:error, :emsgsize} =
             Client.request("status", socket_path: socket_path, timeout: 2_000)
  end

  test "an oversized request frame fails loud with request_too_large, not opaque emsgsize" do
    # A request whose encoded frame exceeds the 4 MiB control-socket limit (e.g.
    # large base64 image attachments via `fermix ask --attach`) is rejected
    # before send with a structured error instead of an opaque :emsgsize.
    dir = mkdir!()
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(dir) end)
    socket_path = Path.join(dir, "big-req.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        {:active, false},
        {:ifaddr, {:local, to_charlist(socket_path)}}
      ])

    on_exit(fn -> :gen_tcp.close(listener) end)

    big = String.duplicate("x", 5_000_000)

    assert {:error, {:request_too_large, size, 4_194_304}} =
             Client.agent_message(%{"content" => big}, socket_path: socket_path, timeout: 2_000)

    assert size > 4_194_304
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
