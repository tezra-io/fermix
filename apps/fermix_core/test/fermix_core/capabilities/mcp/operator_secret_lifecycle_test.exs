defmodule FermixCore.Capabilities.MCP.OperatorSecretLifecycleTest do
  @moduledoc """
  An operator stdio MCP server that declares a secret, from `config.toml`
  through `MCP.Supervisor` to its real program (M74 E3): it is not started
  while the value is missing, `secret.set` of the value starts it with the
  value in its environment, and `secret.clear` stops it, through the one
  supervisor the set path uses.

  The home, the secret store (the stub), the status table and the PATH owner
  are the case's own; the supervisor is a second `MCP.Supervisor` beside the
  application's, reached through `Restarter`, which stands where
  `Management.Secrets` names the daemon's supervisor.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Capabilities.MCP.LoginPath
  alias FermixCore.Capabilities.MCP.Naming
  alias FermixCore.Capabilities.MCP.RuntimeStatus
  alias FermixCore.Capabilities.MCP.Supervisor, as: McpSupervisor
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Management.Secrets
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub

  @fixture Path.expand("../../../fixtures/mcp_stdio_server.exs", __DIR__)
  @bound_ms 20_000
  @server "lifecycle"
  @source {:operator, @server}
  @secret "lifecycle-secret-51be0d"

  # `Management.Secrets` takes the module whose `restart_server/2` and
  # `stop_server/1` it calls; this one calls them on the case's supervisor.
  defmodule Restarter do
    @moduledoc false

    def supervisor, do: :mcp_operator_lifecycle_supervisor

    def opts do
      [
        mcp_registry: :mcp_operator_lifecycle_registry,
        capability_registry: :mcp_operator_lifecycle_capabilities,
        runtime_status: :mcp_operator_lifecycle_status,
        login_path: :mcp_operator_lifecycle_login_path
      ]
    end

    def restart_server(source_id, spec),
      do: McpSupervisor.restart_server(supervisor(), source_id, spec, opts())

    def stop_server(source_id), do: McpSupervisor.stop_server(supervisor(), source_id, opts())
  end

  @supervisor Restarter.supervisor()
  @opts Restarter.opts()

  setup do
    home = System.get_env("FERMIX_HOME")

    core =
      Map.new(
        [:secret_writer, :profile, :mcp_servers],
        &{&1, Application.get_env(:fermix_core, &1)}
      )

    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    Application.delete_env(:fermix_core, :profile)
    SecretWriterStub.reset()

    tmp = SafeRm.make_tmp_dir!("mcp_operator_lifecycle_home")
    System.put_env("FERMIX_HOME", tmp)
    File.write!(Path.join(tmp, "config.toml"), config(System.find_executable("elixir")))
    :ok = ConfigStore.apply_mcp_config()
    :ok = RestartState.record_persisted_baseline()

    start_supervised!({RuntimeStatus, name: @opts[:runtime_status]})
    start_supervised!({CapabilityRegistry, name: @opts[:capability_registry]})
    path = System.get_env("PATH")
    start_supervised!({LoginPath, name: @opts[:login_path], read: fn -> {:ok, path} end})
    start_supervised!({McpSupervisor, [name: @supervisor, servers: []] ++ @opts})

    on_exit(fn ->
      Enum.each(core, fn {key, value} -> restore(key, value) end)
      SecretWriterStub.reset()
      Enum.each(~w(echo refuse), &Naming.unregister("mcp_#{@server}_#{&1}"))
      restore_home(home)
      SafeRm.rm_rf!(tmp)
      :ok = RestartState.record_persisted_baseline()
    end)

    :ok
  end

  test "missing a value it is not started; stored, it starts with it; cleared, it stops" do
    assert {:ok, %{started: []}} = McpSupervisor.reload(@supervisor, @opts)
    refute running?()
    assert RuntimeStatus.fetch(@opts[:runtime_status], @source) == :error

    assert {:ok, %{"present" => true}} =
             Secrets.set("mcp:#{@server}/env/API_TOKEN", @secret, mcp_supervisor: Restarter)

    assert running?()
    assert {:ok, owner, _generation} = RuntimeStatus.owner(@opts[:runtime_status], @source)
    client = Process.whereis(client_name())
    assert :ok = Anubis.Client.await_ready(client, timeout: @bound_ms)

    assert {:ok, %{result: %{"content" => [%{"text" => env}]}}} =
             Anubis.Client.call_tool(client, "environment", %{})

    assert JSON.decode!(env)["API_TOKEN"] == @secret
    os_pid = :sys.get_state(owner).os_pid

    capture_log(fn ->
      assert {:ok, %{"present" => false}} =
               Secrets.clear("mcp:#{@server}/env/API_TOKEN", mcp_supervisor: Restarter)
    end)

    refute running?()
    refute Process.alive?(owner)
    refute os_process_alive?(os_pid)

    # A later reload does not bring it back without its value.
    assert {:ok, %{started: []}} = McpSupervisor.reload(@supervisor, @opts)
    refute running?()
  end

  defp config(elixir) do
    """
    [mcp.servers.#{@server}]
    command = "#{elixir}"
    args = ["#{@fixture}", "2025-11-25", "probe"]
    env_secrets = ["API_TOKEN"]
    """
  end

  defp running? do
    @supervisor
    |> Supervisor.which_children()
    |> Enum.any?(&match?({{:mcp_server_supervisor, @source, _hash}, _pid, _type, _mods}, &1))
  end

  defp client_name,
    do: :"#{FermixCore.Capabilities.MCP.AnubisStarter.Default}.Client.operator.#{@server}"

  defp os_process_alive?(os_pid) do
    {_output, status} =
      System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

    status == 0
  end

  defp restore_home(nil), do: System.delete_env("FERMIX_HOME")
  defp restore_home(home), do: System.put_env("FERMIX_HOME", home)

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)
end
