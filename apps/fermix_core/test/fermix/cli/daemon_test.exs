defmodule Fermix.CLI.DaemonTest do
  use ExUnit.Case, async: false

  alias Fermix.CLI.Daemon
  alias Fermix.CLI.Daemon.Client
  alias FermixCore.Capabilities.MCP.RuntimeStatus
  alias FermixCore.Management.Lifecycle

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

  defmodule TestMobileProvider do
    def begin_pairing do
      call(:begin_pairing, [])
    end

    def await_pairing(session_id, timeout_ms) do
      call(:await_pairing, [session_id, timeout_ms])
    end

    def decide_pairing(session_id, approved?) do
      call(:decide_pairing, [session_id, approved?])
    end

    def cancel_pairing(session_id), do: call(:cancel_pairing, [session_id])

    def list_devices, do: call(:list_devices, [])
    def revoke_device(device_id), do: call(:revoke_device, [device_id])
    def status, do: call(:status, [])

    defp call(operation, args) do
      test_pid = Application.fetch_env!(:fermix_core, :daemon_test_pid)
      send(test_pid, {:mobile_provider_call, operation, args})

      result =
        :fermix_core
        |> Application.fetch_env!(:daemon_mobile_results)
        |> Map.fetch!(operation)

      if is_function(result, 1), do: result.(args), else: result
    end
  end

  setup do
    previous_bridge = Application.get_env(:fermix_core, :cli_channel_bridge)
    previous_pid = Application.get_env(:fermix_core, :daemon_test_pid)
    previous_result = Application.get_env(:fermix_core, :daemon_bridge_result)
    previous_mobile_results = Application.get_env(:fermix_core, :daemon_mobile_results)
    previous_mobile_provider = Application.get_env(:fermix_core, :mobile_management_provider)
    {:ok, _sup} = Task.Supervisor.start_link(name: __MODULE__.TaskSup)
    socket_dir = mkdir!()
    socket_path = Path.join(socket_dir, "fermix.sock")
    Application.put_env(:fermix_core, :cli_channel_bridge, TestCLIBridge)
    Application.put_env(:fermix_core, :daemon_test_pid, self())
    Application.put_env(:fermix_core, :daemon_bridge_result, :ok)
    Application.delete_env(:fermix_core, :mobile_management_provider)

    Application.put_env(:fermix_core, :daemon_mobile_results, %{
      begin_pairing:
        {:ok,
         %{
           session_id: "pair-session-1",
           uri: "fermix://pair?v=1",
           qr: "QR",
           expires_in_s: 120
         }},
      await_pairing:
        {:ok,
         %{
           device_id: "3f4a1a55-69a0-4f8a-9132-17d6ac728f84",
           name: "Sujeeth",
           model: "iPhone 16 Pro",
           sas: "047291"
         }},
      decide_pairing:
        {:ok,
         %{
           approved: true,
           device_id: "3f4a1a55-69a0-4f8a-9132-17d6ac728f84",
           name: "Sujeeth"
         }},
      cancel_pairing: {:ok, %{cancelled: true}},
      list_devices: {:ok, %{devices: []}},
      revoke_device: {:ok, %{device_id: "3f4a1a55-69a0-4f8a-9132-17d6ac728f84"}},
      status: {:ok, %{enabled: true, listener: :ready, paired_devices: 1}}
    })

    {:ok, daemon} =
      Daemon.start_link(
        name: :"daemon_#{System.unique_integer([:positive, :monotonic])}",
        socket_path: socket_path,
        task_supervisor: __MODULE__.TaskSup,
        management_opts: management_opts()
      )

    Application.put_env(:fermix_core, :mobile_management_provider, TestMobileProvider)

    on_exit(fn ->
      await_process_exit(daemon)
      restore_app_env(:cli_channel_bridge, previous_bridge)
      restore_app_env(:daemon_test_pid, previous_pid)
      restore_app_env(:daemon_bridge_result, previous_result)
      restore_app_env(:daemon_mobile_results, previous_mobile_results)
      restore_app_env(:mobile_management_provider, previous_mobile_provider)
      FermixTestSupport.SafeRm.rm_rf(socket_dir)
    end)

    %{socket_path: socket_path, daemon: daemon}
  end

  # M34 §4 moved `fermix status` and `fermix status --full` onto management v1.
  # Serving the retired unversioned methods as well would leave two live paths
  # to one answer, which is exactly what deleting v0 exists to prevent.
  test "the v0 status and overview methods are deleted", %{socket_path: socket_path} do
    for method <- ["status", "overview"] do
      assert {:ok, reply} = Client.request(method, socket_path: socket_path, timeout: 1_000)
      assert reply == %{"status" => "error", "reason" => "unknown method", "method" => method}
    end
  end

  test "management v1 hello returns the negotiated daemon contract", %{socket_path: socket_path} do
    assert {:ok, result} =
             Client.request_v1("hello", %{},
               request_id: "req-hello",
               socket_path: socket_path,
               timeout: 1_000
             )

    assert result["protocol"] == %{
             "current_version" => 1,
             "minimum_version" => 1,
             "maximum_version" => 1
           }

    assert result["engine"]["distribution_identity"] == "standalone"
    assert result["engine"]["engine_id"] == "fermix-engine-test"
    assert result["setup"] == %{"origin" => "http://127.0.0.1:4041", "path" => "/setup"}
  end

  test "management v1 overview returns the allowlisted projection", %{socket_path: socket_path} do
    assert {:ok, result} =
             Client.request_v1("overview.get", %{},
               request_id: "req-overview",
               socket_path: socket_path,
               timeout: 1_000
             )

    assert result["readiness"] == %{"status" => "ready", "failure_count" => 0}
    assert result["daemon"]["status"] == "running"

    assert result["memory"] == %{
             "repo" => "ready",
             "conversation_store" => "ready",
             "store" => "ready"
           }

    encoded = Jason.encode!(result)
    refute encoded =~ "/Users/"
    refute encoded =~ "database_path"
    refute encoded =~ "socket_path"
  end

  test "management v1 setup session exposes only the one-use URL and expiration", %{
    socket_path: socket_path
  } do
    assert {:ok, result} =
             Client.request_v1("setup.session.create", %{},
               request_id: "req-setup",
               socket_path: socket_path,
               timeout: 1_000
             )

    assert result == %{
             "url" => "http://127.0.0.1:4041/setup?t=daemon-launch-token",
             "expires_at_ms" => 1_800_000
           }
  end

  test "management v1 reports both version incompatibility directions", %{
    socket_path: socket_path
  } do
    assert {:error, {:management_error, "client_too_old", _message, details}} =
             Client.request_v1("hello", %{},
               request_id: "req-old",
               protocol_version: 0,
               socket_path: socket_path,
               timeout: 1_000
             )

    assert details == %{"minimum_version" => 1, "maximum_version" => 1}

    assert {:error, {:management_error, "daemon_too_old", _message, ^details}} =
             Client.request_v1("hello", %{},
               request_id: "req-new",
               protocol_version: 2,
               socket_path: socket_path,
               timeout: 1_000
             )
  end

  test "an attempted v1 request never falls through to the v0 dispatcher", %{
    socket_path: socket_path
  } do
    response = raw_request(socket_path, %{"request_id" => "req-invalid", "method" => "status"})

    assert response["request_id"] == "req-invalid"
    assert response["error"]["code"] == "invalid_request"
    refute Map.has_key?(response, "status")
    refute Map.has_key?(response, "result")
  end

  test "management v1 returns a stable unknown-method error", %{socket_path: socket_path} do
    assert {:error, {:management_error, "method_not_found", _message, details}} =
             Client.request_v1("missing.method", %{},
               request_id: "req-missing",
               socket_path: socket_path,
               timeout: 1_000
             )

    assert details == %{"method" => "missing.method"}
  end

  test "management v1 provider faults return a correlated internal error" do
    socket_dir = mkdir!()
    socket_path = Path.join(socket_dir, "management-fault.sock")

    management_opts =
      Keyword.put(management_opts(), :health_reporter, fn -> raise "provider failure" end)

    {:ok, daemon} =
      Daemon.start_link(
        name: :"fault_daemon_#{System.unique_integer([:positive, :monotonic])}",
        socket_path: socket_path,
        task_supervisor: __MODULE__.TaskSup,
        management_opts: management_opts
      )

    Process.unlink(daemon)

    on_exit(fn ->
      if Process.alive?(daemon), do: GenServer.stop(daemon)
      FermixTestSupport.SafeRm.rm_rf(socket_dir)
    end)

    assert {:error, {:management_error, "internal_error", _message, %{}}} =
             Client.request_v1("overview.get", %{},
               request_id: "req-provider-fault",
               socket_path: socket_path,
               timeout: 1_000
             )

    assert Process.alive?(daemon)
  end

  test "management v1 client rejects a mismatched response request ID" do
    result =
      request_v1_against_reply(%{
        "request_id" => "req-other",
        "result" => %{"ready" => true}
      })

    assert result == {:error, :response_request_id_mismatch}
  end

  test "management v1 client rejects malformed response envelopes" do
    invalid_responses = [
      %{"request_id" => "req-client", "result" => %{}, "extra" => true},
      %{"request_id" => "req-client", "result" => %{}, "error" => %{}},
      %{
        "request_id" => "req-client",
        "error" => %{
          "code" => "unavailable",
          "message" => "Unavailable.",
          "details" => %{},
          "extra" => true
        }
      },
      %{
        "request_id" => "req-client",
        "error" => %{
          "code" => "not_allowlisted",
          "message" => "Unknown.",
          "details" => %{}
        }
      }
    ]

    for response <- invalid_responses do
      assert {:error, :invalid_management_response} = request_v1_against_reply(response)
    end
  end

  test "unknown method returns error", %{socket_path: socket_path} do
    Process.sleep(50)

    assert {:ok, reply} =
             Client.request("does-not-exist", socket_path: socket_path, timeout: 1_000)

    assert reply["status"] == "error"
    assert reply["reason"] == "unknown method"
    assert reply["method"] == "does-not-exist"
  end

  test "mobile pairing RPCs share one leased control connection", %{
    socket_path: socket_path
  } do
    result =
      Client.with_connection(
        fn request ->
          assert {:ok, begin_reply} = request.("mobile_pair_begin", %{}, 1_000)
          assert begin_reply["result"]["session_id"] == "pair-session-1"

          assert {:ok, wait_reply} =
                   request.("mobile_pair_wait", %{"session_id" => "pair-session-1"}, 1_000)

          assert wait_reply["result"]["sas"] == "047291"

          assert {:ok, decide_reply} =
                   request.(
                     "mobile_pair_decide",
                     %{"session_id" => "pair-session-1", "approved" => true},
                     1_000
                   )

          assert decide_reply["result"]["approved"] == true
          :paired
        end,
        socket_path: socket_path,
        timeout: 1_000
      )

    assert result == :paired
    assert_received {:mobile_provider_call, :begin_pairing, []}

    assert_received {:mobile_provider_call, :await_pairing, ["pair-session-1", wait_timeout_ms]}
    assert wait_timeout_ms == 120_000
    assert_received {:mobile_provider_call, :decide_pairing, ["pair-session-1", true]}
    refute_received {:mobile_provider_call, :cancel_pairing, _args}
  end

  test "a dead pair CLI cancels its exact window while wait is still blocked", %{
    socket_path: socket_path
  } do
    test_pid = self()

    await = fn ["pair-session-1", 120_000] ->
      send(test_pid, :pair_wait_started)
      receive do: (:never -> {:error, :unexpected})
    end

    results = Application.fetch_env!(:fermix_core, :daemon_mobile_results)

    Application.put_env(
      :fermix_core,
      :daemon_mobile_results,
      Map.put(results, :await_pairing, await)
    )

    cli =
      spawn(fn ->
        Client.with_connection(
          fn request ->
            {:ok, _window} = request.("mobile_pair_begin", %{}, 1_000)

            request.("mobile_pair_wait", %{"session_id" => "pair-session-1"}, 125_000)
          end,
          socket_path: socket_path,
          timeout: 1_000
        )
      end)

    assert_receive :pair_wait_started, 1_000
    Process.exit(cli, :kill)

    assert_receive {:mobile_provider_call, :cancel_pairing, ["pair-session-1"]}, 1_000
  end

  test "normal explicit pairing cancellation stays terminal and is not repeated", %{
    socket_path: socket_path
  } do
    result =
      Client.with_connection(
        fn request ->
          assert {:ok, _window} = request.("mobile_pair_begin", %{}, 1_000)

          request.("mobile_pair_cancel", %{"session_id" => "pair-session-1"}, 1_000)
        end,
        socket_path: socket_path,
        timeout: 1_000
      )

    assert {:ok, cancel_reply} = result
    assert cancel_reply["result"]["cancelled"] == true
    assert_received {:mobile_provider_call, :cancel_pairing, ["pair-session-1"]}
    refute_receive {:mobile_provider_call, :cancel_pairing, ["pair-session-1"]}, 100
  end

  test "mobile device management and status RPCs return JSON-safe results", %{
    socket_path: socket_path
  } do
    for {method, operation, result_key} <- [
          {"mobile_devices_list", :list_devices, "devices"},
          {"mobile_status", :status, "listener"}
        ] do
      assert {:ok, reply} =
               Client.request(method, socket_path: socket_path, timeout: 1_000)

      assert reply["status"] == "ok"
      assert Map.has_key?(reply["result"], result_key)
      assert_received {:mobile_provider_call, ^operation, []}
    end

    device_id = "3f4a1a55-69a0-4f8a-9132-17d6ac728f84"

    assert {:ok, reply} =
             Client.request("mobile_device_revoke",
               socket_path: socket_path,
               timeout: 1_000,
               params: %{"device_id" => device_id}
             )

    assert reply["result"]["device_id"] == device_id
    assert_received {:mobile_provider_call, :revoke_device, [^device_id]}
  end

  test "mobile RPC validates parameters before invoking the provider", %{socket_path: socket_path} do
    assert {:ok, wait_reply} =
             Client.request("mobile_pair_wait",
               socket_path: socket_path,
               timeout: 1_000,
               params: %{"session_id" => "../../bad"}
             )

    assert wait_reply == %{"status" => "error", "reason" => "invalid session_id"}
    refute_received {:mobile_provider_call, :await_pairing, _args}

    assert {:ok, revoke_reply} =
             Client.request("mobile_device_revoke",
               socket_path: socket_path,
               timeout: 1_000,
               params: %{"device_id" => "not-a-uuid"}
             )

    assert revoke_reply == %{"status" => "error", "reason" => "invalid device_id"}
    refute_received {:mobile_provider_call, :revoke_device, _args}
  end

  test "mobile provider failures remain structured and do not crash the daemon", %{
    socket_path: socket_path
  } do
    Application.put_env(
      :fermix_core,
      :daemon_mobile_results,
      Map.put(
        Application.fetch_env!(:fermix_core, :daemon_mobile_results),
        :begin_pairing,
        {:error, :pairing_already_active}
      )
    )

    assert {:ok, reply} =
             Client.request("mobile_pair_begin", socket_path: socket_path, timeout: 1_000)

    assert reply == %{"status" => "error", "reason" => "pairing_already_active"}

    assert {:ok, %{"engine" => _engine}} = hello(socket_path)
  end

  test "no daemon listening returns :not_running" do
    socket_dir = mkdir!()
    socket_path = Path.join(socket_dir, "missing.sock")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(socket_dir) end)

    assert {:error, :not_running} =
             Client.request_v1("hello", %{}, socket_path: socket_path, timeout: 500)
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
    assert {:ok, %{"engine" => _engine}} = hello(socket_path)

    GenServer.stop(daemon, :normal, 1_000)
    FermixTestSupport.SafeRm.rm_rf(socket_dir)
  end

  test "supervisor shutdown removes the daemon socket" do
    socket_dir = mkdir!()
    socket_path = Path.join(socket_dir, "supervised.sock")
    task_supervisor = unique_name(:shutdown_task_supervisor)
    daemon_name = unique_name(:shutdown_daemon)
    {:ok, _task_supervisor} = Task.Supervisor.start_link(name: task_supervisor)

    child =
      {Daemon,
       name: daemon_name,
       socket_path: socket_path,
       task_supervisor: task_supervisor,
       management_opts: management_opts()}

    {:ok, supervisor} = Supervisor.start_link([child], strategy: :one_for_one)

    on_exit(fn ->
      await_process_exit(supervisor)
      FermixTestSupport.SafeRm.rm_rf(socket_dir)
    end)

    assert File.exists?(socket_path)
    assert {:ok, %{"engine" => _engine}} = hello(socket_path)

    :ok = Supervisor.stop(supervisor, :normal, 1_000)

    refute File.exists?(socket_path)
  end

  # M34 §2/§4: the app drains through `lifecycle.*` while `fermix stop` still
  # speaks v0 `shutdown`. Both must reach the SAME stop path — two stoppers is
  # how one of them quietly stops verifying the PID actually exits.
  test "the v0 shutdown method and a committed lifecycle lease share one stop path" do
    parent = self()
    socket_dir = mkdir!()
    socket_path = Path.join(socket_dir, "lifecycle.sock")
    task_supervisor = unique_name(:lifecycle_task_supervisor)
    {:ok, _task_supervisor} = Task.Supervisor.start_link(name: task_supervisor)

    lifecycle_name = unique_name(:lifecycle_server)

    {:ok, lifecycle} =
      Lifecycle.start_link(
        name: lifecycle_name,
        shutdown: fn -> send(parent, {:stopped, :lifecycle}) end
      )

    {:ok, daemon} =
      Daemon.start_link(
        name: unique_name(:lifecycle_daemon),
        socket_path: socket_path,
        task_supervisor: task_supervisor,
        stopper: fn -> send(parent, {:stopped, :v0}) end,
        management_opts: management_opts() ++ [lifecycle_server: lifecycle]
      )

    on_exit(fn ->
      await_process_exit(daemon)
      FermixTestSupport.SafeRm.rm_rf(socket_dir)
    end)

    assert {:ok, %{"lease_id" => lease_id, "ttl_ms" => _ttl}} =
             Client.request_v1("lifecycle.prepare", %{},
               request_id: "req-prepare",
               socket_path: socket_path,
               timeout: 1_000
             )

    assert {:error, {:management_error, "busy", _message, %{"operation" => "lifecycle"}}} =
             Client.request_v1("lifecycle.prepare", %{},
               request_id: "req-prepare-2",
               socket_path: socket_path,
               timeout: 1_000
             )

    assert {:ok, %{"status" => "committed"}} =
             Client.request_v1("lifecycle.commit", %{"lease_id" => lease_id},
               request_id: "req-commit",
               socket_path: socket_path,
               timeout: 1_000
             )

    assert_receive {:stopped, :lifecycle}, 1_000

    assert {:ok, %{"status" => "shutting_down"}} =
             Client.request("shutdown", socket_path: socket_path, timeout: 1_000)

    assert_receive {:stopped, :v0}, 1_000

    # Both seams default to the same function, so production has one stop path
    # rather than two implementations that can drift.
    assert Daemon.default_stopper() == Lifecycle.default_stopper()
    assert Daemon.default_stopper() == (&Lifecycle.stop_daemon/0)

    GenServer.stop(daemon, :normal, 1_000)
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
    assert {:ok, %{"engine" => _engine}} = hello(socket_path)
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
      await_process_exit(daemon)
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
      await_process_exit(daemon)
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
        :missing_tool,
        "eden_get_item_connections"
      )

    {:ok, daemon} =
      Daemon.start_link(
        name: :"runtime_status_daemon_#{System.unique_integer([:positive, :monotonic])}",
        socket_path: socket_path,
        task_supervisor: __MODULE__.RuntimeStatusSup,
        runtime_status: status_server
      )

    on_exit(fn ->
      await_process_exit(daemon)
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
    assert row["detail"] == "missing_tool"
    # The capability the upstream withdrew: the fact a one-shot CLI has no other
    # way to learn, and the reason this row exists at all.
    assert row["subject"] == "eden_get_item_connections"
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
      await_process_exit(daemon)
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

  defp management_opts do
    health = %{
      status: :ready,
      restart_required?: false,
      providers: [],
      failures: []
    }

    [
      identity_provider: fn -> {:ok, management_identity()} end,
      endpoint_opts: [port: 4041],
      health_reporter: fn -> health end,
      overview_provider: fn ^health -> {:ok, management_overview()} end,
      launch_token_provider: fn ->
        {:ok, %{token: "daemon-launch-token", expires_at_ms: 1_800_000}}
      end
    ]
  end

  defp management_identity do
    %{
      "engine_id" => "fermix-engine-test",
      "product_version" => "1.2.3",
      "build_id" => nil,
      "source_commit" => nil,
      "distribution_identity" => "standalone",
      "artifact_target" => nil,
      "architecture" => "arm64",
      "pid" => "4321"
    }
  end

  defp management_overview do
    %{
      generated_at: ~U[2026-08-19 10:30:00Z],
      readiness: %{status: :ready, failures: []},
      daemon: %{status: :running, version: "1.2.3", uptime_ms: 5_000, pid: "4321"},
      provider: %{active: nil, model: nil, auth_mode: nil, reasoning_effort: nil},
      channels: [],
      memory: %{
        database_path: "/Users/private/.fermix/memory.db",
        repo: :ready,
        conversation_store: :ready,
        store: :ready,
        paths: %{skills: "/Users/private/.fermix/workspace/skills"}
      },
      jobs: %{
        scheduled: 0,
        running: 0,
        paused: 0,
        failed_recent: 0,
        next: nil,
        status: :ready,
        error: nil
      },
      agents: %{
        main: %{
          health: :online,
          activity: :idle,
          status: :idle,
          active_conversations: 0,
          pending_conversations: 0
        },
        skill_workers: 0,
        running_skill_workers: 0
      },
      realtime: %{
        enabled: false,
        status: :disabled,
        provider: nil,
        model: nil,
        socket_path: "/Users/private/.fermix/realtime.sock",
        socket_alive: nil,
        active_sessions: 0,
        active_clients: 0,
        companion_connected?: false
      },
      capabilities: %{builtin: 0, skill: 0, mcp: 0, total: 0},
      paths: %{home: "/Users/private/.fermix"}
    }
  end

  defp request_v1_against_reply(response) do
    dir = mkdir!()
    socket_path = Path.join(dir, "management-client.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        {:active, false},
        {:packet, 4},
        {:ifaddr, {:local, to_charlist(socket_path)}}
      ])

    task =
      Task.async(fn ->
        {:ok, conn} = :gen_tcp.accept(listener, 1_000)
        {:ok, _request} = :gen_tcp.recv(conn, 0, 1_000)
        :ok = :gen_tcp.send(conn, Jason.encode!(response))
        :gen_tcp.close(conn)
      end)

    try do
      Client.request_v1("hello", %{},
        request_id: "req-client",
        socket_path: socket_path,
        timeout: 1_000
      )
    after
      Task.await(task, 1_000)
      :gen_tcp.close(listener)
      FermixTestSupport.SafeRm.rm_rf(dir)
    end
  end

  defp raw_request(socket_path, request) do
    {:ok, conn} =
      :gen_tcp.connect(
        {:local, to_charlist(socket_path)},
        0,
        [:binary, {:active, false}, {:packet, 4}, {:packet_size, 4_194_304}],
        1_000
      )

    try do
      :ok = :gen_tcp.send(conn, Jason.encode!(request))
      {:ok, frame} = :gen_tcp.recv(conn, 0, 1_000)
      Jason.decode!(frame)
    after
      :gen_tcp.close(conn)
    end
  end

  defp await_process_exit(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      1_000 -> raise "supervised daemon did not exit with its parent"
    end
  end

  defp hello(socket_path) do
    Client.request_v1("hello", %{}, socket_path: socket_path, timeout: 1_000)
  end

  defp unique_name(prefix) do
    String.to_atom("#{prefix}_#{System.unique_integer([:positive, :monotonic])}")
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
