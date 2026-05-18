defmodule FermixCore.MCP.Inbound.CapabilityPort.Local do
  @moduledoc """
  In-process capability port for the daemon and standalone stdio mode.
  """

  @behaviour FermixCore.MCP.Inbound.CapabilityPort

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry

  @impl true
  def list_capabilities do
    registry = registry()
    {:ok, Registry.list(registry, include_hidden?: true)}
  rescue
    error -> {:error, {:capability_registry_unavailable, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:capability_registry_unavailable, reason}}
  end

  @impl true
  def execute_capability(name, args, context)
      when is_binary(name) and is_map(args) and is_map(context) do
    registry = registry()

    with {:ok, %Capability{} = capability} <- Registry.find(registry, name) do
      Capability.execute(capability, args, context)
    else
      :error -> {:error, :unknown_tool}
    end
  rescue
    error -> {:error, {:capability_execution_failed, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:capability_execution_failed, reason}}
  end

  defp registry do
    Application.get_env(:fermix_core, :mcp_inbound_capability_registry, Registry)
  end
end
