defmodule FermixCore.MCP.Inbound.SupervisorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Capabilities.Capability
  alias FermixCore.MCP.Inbound.CapabilityPort
  alias FermixCore.MCP.Inbound.Config
  alias FermixCore.MCP.Inbound.Server
  alias FermixCore.MCP.Inbound.Supervisor, as: InboundSupervisor

  defmodule StubPort do
    @behaviour CapabilityPort

    def set_capabilities(capabilities) do
      :persistent_term.put({__MODULE__, :capabilities}, capabilities)
    end

    def cleanup do
      :persistent_term.erase({__MODULE__, :capabilities})
    rescue
      ArgumentError -> :ok
    end

    @impl true
    def list_capabilities do
      {:ok, :persistent_term.get({__MODULE__, :capabilities}, [])}
    end

    @impl true
    def execute_capability(_name, _args, _context), do: {:error, :not_used}
  end

  defmodule FakeAnubisSupervisor do
    use GenServer

    def start_link(server, opts) do
      GenServer.start_link(__MODULE__, {server, opts})
    end

    @impl true
    def init({server, opts}) do
      send(Keyword.fetch!(opts, :test_owner), {:fake_anubis_started, server, opts})
      {:ok, %{server: server, opts: opts}}
    end
  end

  setup do
    previous_port = Application.get_env(:fermix_core, :mcp_inbound_capability_port)
    Application.put_env(:fermix_core, :mcp_inbound_capability_port, StubPort)

    on_exit(fn ->
      StubPort.cleanup()
      restore_env(:mcp_inbound_capability_port, previous_port)
    end)

    :ok
  end

  test "disabled config starts no Anubis server child" do
    pid =
      start_supervised!(
        {InboundSupervisor,
         config: %Config{enabled?: false}, server_supervisor: FakeAnubisSupervisor}
      )

    assert Supervisor.which_children(pid) == []
  end

  test "enabled config starts Anubis server with configured transport and timeout" do
    config = %Config{enabled?: true, transport: :stdio, request_timeout_ms: 12_345}

    start_supervised!(
      {InboundSupervisor,
       [
         config: config,
         server_supervisor: FakeAnubisSupervisor,
         server_opts: [test_owner: self()]
       ]}
    )

    assert_receive {:fake_anubis_started, Server, opts}
    assert opts[:transport] == :stdio
    assert opts[:request_timeout] == 12_345
  end

  test "warns when outbound MCP capabilities are re-exposed inbound" do
    StubPort.set_capabilities([
      capability("mcp_github_create_issue", :mcp),
      capability("file_read", :builtin)
    ])

    config = %Config{
      enabled?: true,
      expose_kinds: [:builtin, :mcp],
      allowed_tools: ["mcp_github_create_issue", "file_read"]
    }

    log =
      capture_log(fn ->
        start_supervised!(
          {InboundSupervisor,
           [
             config: config,
             server_supervisor: FakeAnubisSupervisor,
             server_opts: [test_owner: self()]
           ]}
        )
      end)

    assert log =~ "re-exposing outbound MCP capabilities"
    assert log =~ "mcp_github_create_issue"
    refute log =~ "file_read"
  end

  defp capability(name, kind) do
    Capability.new(%{
      name: name,
      description: "Test capability",
      parameters: %{"type" => "object", "properties" => %{}},
      kind: kind,
      executor: {__MODULE__, :unused, []},
      policy_class: :read_only
    })
  end

  defp restore_env(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore_env(key, value), do: Application.put_env(:fermix_core, key, value)
end
