defmodule FermixCore.MCP.Inbound.ServerTest do
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.Capability
  alias FermixCore.MCP.Inbound.CapabilityPort
  alias FermixCore.MCP.Inbound.Config
  alias FermixCore.MCP.Inbound.Server
  alias Hermes.MCP.Error
  alias Hermes.Server.Base, as: HermesServerBase
  alias Hermes.Server.Frame
  alias Hermes.Server.Registry, as: HermesRegistry
  alias Hermes.Server.Session.Supervisor, as: HermesSessionSupervisor

  defmodule StubPort do
    @behaviour CapabilityPort

    def setup(owner, capabilities, result \\ {:ok, %{success: true, output: "done", error: nil}}) do
      :persistent_term.put({__MODULE__, :owner}, owner)
      :persistent_term.put({__MODULE__, :capabilities}, capabilities)
      :persistent_term.put({__MODULE__, :result}, result)
    end

    def cleanup do
      erase(:owner)
      erase(:capabilities)
      erase(:result)
    end

    @impl true
    def list_capabilities do
      case :persistent_term.get({__MODULE__, :capabilities}, []) do
        {:error, reason} -> {:error, reason}
        capabilities -> {:ok, capabilities}
      end
    end

    @impl true
    def execute_capability(name, args, context) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:stub_execute, name, args, context})
      :persistent_term.get({__MODULE__, :result})
    end

    defp erase(key) do
      :persistent_term.erase({__MODULE__, key})
    rescue
      ArgumentError -> :ok
    end
  end

  setup do
    previous_config = Application.get_env(:fermix_core, :mcp_inbound)
    previous_port = Application.get_env(:fermix_core, :mcp_inbound_capability_port)

    Application.put_env(:fermix_core, :mcp_inbound_capability_port, StubPort)

    Application.put_env(:fermix_core, :mcp_inbound, %Config{
      enabled?: true,
      tool_overrides: %{"echo" => %{description_override: "MCP echo"}}
    })

    StubPort.setup(self(), [capability("echo")])

    telemetry_id = attach_call_telemetry()

    on_exit(fn ->
      :telemetry.detach(telemetry_id)
      StubPort.cleanup()
      restore_env(:mcp_inbound, previous_config)
      restore_env(:mcp_inbound_capability_port, previous_port)
    end)

    :ok
  end

  test "tools/list returns exposed capabilities as MCP tool descriptors" do
    assert {:reply, %{"tools" => [tool]}, _frame} =
             Server.handle_request(%{"method" => "tools/list"}, frame())

    assert tool["name"] == "echo"
    assert tool["description"] == "MCP echo"
    assert tool["inputSchema"]["type"] == "object"
    assert_receive {:inbound_listed, %{count: 1}, metadata}
    assert metadata.client_name == "test-client"
  end

  test "server_info uses configured inbound MCP identity" do
    Application.put_env(:fermix_core, :mcp_inbound, %Config{
      enabled?: true,
      server_name: "fermix-dev",
      server_version: "9.9.9"
    })

    assert Server.server_info() == %{"name" => "fermix-dev", "version" => "9.9.9"}
  end

  test "Hermes wire boundary returns configured identity and dynamic tools" do
    ensure_hermes_registry_started()

    Application.put_env(:fermix_core, :mcp_inbound, %Config{
      enabled?: true,
      server_name: "fermix-dev",
      server_version: "9.9.9",
      tool_overrides: %{"echo" => %{description_override: "Wire echo"}}
    })

    session_id = "wire-session"
    server = start_wire_server()

    assert %{"result" => %{"serverInfo" => %{"name" => "fermix-dev", "version" => "9.9.9"}}} =
             server |> request(initialize_request(), session_id) |> decode_response()

    GenServer.cast(server, {:notification, initialized_notification(), session_id, %{}})
    :sys.get_state(server)

    assert %{"result" => %{"tools" => [%{"name" => "echo", "description" => "Wire echo"}]}} =
             server |> request(tools_list_request(), session_id) |> decode_response()

    assert %{"result" => %{"content" => [%{"text" => "done"}], "isError" => false}} =
             server |> request(tools_call_request(), session_id) |> decode_response()

    assert_receive {:stub_execute, "echo", %{"text" => "hello"}, _context}
  end

  test "tools/call validates args, executes through the active port, and replies with text" do
    request = %{
      "method" => "tools/call",
      "params" => %{"name" => "echo", "arguments" => %{"text" => "hello"}}
    }

    assert {:reply, %{"content" => [%{"text" => "done"}], "isError" => false}, _frame} =
             Server.handle_request(request, frame())

    assert_receive {:stub_execute, "echo", %{"text" => "hello"}, context}
    assert context.source == :mcp_inbound
    assert context.mcp_inbound_client.client_name == "test-client"

    assert_receive {:inbound_call, %{duration_ms: duration_ms}, metadata}
    assert is_integer(duration_ms)
    assert metadata.tool_name == "echo"
    assert metadata.result == :ok
  end

  test "malformed args fail at the boundary and never execute the capability" do
    request = %{
      "method" => "tools/call",
      "params" => %{"name" => "echo", "arguments" => %{}}
    }

    assert {:error, %Error{reason: :invalid_params, data: %{message: message}}, _frame} =
             Server.handle_request(request, frame())

    assert is_binary(message)
    refute_receive {:stub_execute, _, _, _}
    assert_receive {:inbound_call, %{duration_ms: 0}, metadata}
    assert metadata.tool_name == "echo"
    assert metadata.result == {:error, :invalid_params}
  end

  test "unknown tools return invalid params and emit rejection telemetry" do
    request = %{
      "method" => "tools/call",
      "params" => %{"name" => "missing", "arguments" => %{}}
    }

    assert {:error, %Error{reason: :invalid_params}, _frame} =
             Server.handle_request(request, frame())

    refute_receive {:stub_execute, _, _, _}
    assert_receive {:inbound_call, %{duration_ms: 0}, metadata}
    assert metadata.tool_name == "missing"
    assert metadata.result == {:error, :unknown_tool}
  end

  test "port errors preserve their reason in the MCP error payload" do
    StubPort.setup(self(), {:error, :daemon_unavailable})

    request = %{
      "method" => "tools/call",
      "params" => %{"name" => "echo", "arguments" => %{"text" => "hello"}}
    }

    assert {:error, %Error{reason: :execution_error, data: %{reason: reason}}, _frame} =
             Server.handle_request(request, frame())

    assert reason =~ "daemon_unavailable"
  end

  test "unsupported successful capability payloads fail loud" do
    StubPort.setup(self(), [capability("echo")], {:ok, %{custom_thing: true}})

    request = %{
      "method" => "tools/call",
      "params" => %{"name" => "echo", "arguments" => %{"text" => "hello"}}
    }

    assert {:error, %Error{reason: :execution_error, data: %{reason: reason}}, _frame} =
             Server.handle_request(request, frame())

    assert reason =~ "invalid_capability_payload"
  end

  test "malformed built-in tool result maps fail loud" do
    StubPort.setup(self(), [capability("echo")], {:ok, %{success: false, output: "", error: nil}})

    request = %{
      "method" => "tools/call",
      "params" => %{"name" => "echo", "arguments" => %{"text" => "hello"}}
    }

    assert {:error, %Error{reason: :execution_error, data: %{reason: reason}}, _frame} =
             Server.handle_request(request, frame())

    assert reason =~ "invalid_capability_payload"
  end

  defp capability(name) do
    Capability.new(%{
      name: name,
      description: "Echo input",
      parameters: %{
        "type" => "object",
        "required" => ["text"],
        "properties" => %{"text" => %{"type" => "string"}}
      },
      kind: :builtin,
      executor: {__MODULE__, :unused, []},
      policy_class: :read_only
    })
  end

  defp frame do
    %Frame{
      private: %{
        mcp_inbound_client: %{
          client_name: "test-client",
          client_version: "1.0",
          session_id: "session-1"
        }
      }
    }
  end

  defp ensure_hermes_registry_started do
    case Process.whereis(HermesRegistry) do
      nil -> start_supervised!(HermesRegistry)
      _pid -> :ok
    end
  end

  defp start_wire_server do
    server = HermesRegistry.server(:"inbound_wire_server_#{System.unique_integer([:positive])}")

    start_supervised!(
      {HermesSessionSupervisor, server: Server, registry: HermesRegistry},
      id: :inbound_wire_session_supervisor
    )

    start_supervised!(
      {HermesServerBase,
       module: Server,
       name: server,
       transport: [layer: Hermes.Server.Transport.STDIO, name: :inbound_wire_transport],
       registry: HermesRegistry},
      id: :inbound_wire_base
    )

    server
  end

  defp request(server, payload, session_id) do
    GenServer.call(server, {:request, payload, session_id, %{}})
  end

  defp decode_response({:ok, encoded}) do
    Jason.decode!(String.trim(encoded))
  end

  defp initialize_request do
    %{
      "jsonrpc" => "2.0",
      "id" => "init-1",
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-03-26",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "wire-client", "version" => "1.0"}
      }
    }
  end

  defp initialized_notification do
    %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
  end

  defp tools_list_request do
    %{"jsonrpc" => "2.0", "id" => "tools-1", "method" => "tools/list", "params" => %{}}
  end

  defp tools_call_request do
    %{
      "jsonrpc" => "2.0",
      "id" => "call-1",
      "method" => "tools/call",
      "params" => %{"name" => "echo", "arguments" => %{"text" => "hello"}}
    }
  end

  defp attach_call_telemetry do
    handler_id = "test-inbound-server-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      [
        [:fermix, :mcp, :inbound, :tools_listed],
        [:fermix, :mcp, :inbound, :call]
      ],
      fn
        [:fermix, :mcp, :inbound, :tools_listed], measurements, metadata, _config ->
          send(test_pid, {:inbound_listed, measurements, metadata})

        [:fermix, :mcp, :inbound, :call], measurements, metadata, _config ->
          send(test_pid, {:inbound_call, measurements, metadata})
      end,
      nil
    )

    handler_id
  end

  defp restore_env(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore_env(key, value), do: Application.put_env(:fermix_core, key, value)
end
