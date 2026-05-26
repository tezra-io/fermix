defmodule FermixCore.Plugins.CapabilitySeeder do
  @moduledoc """
  One-shot seeder for enabled plugin-owned capabilities at boot.
  """

  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Plugins.Capabilities

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts) do
    Task.start_link(fn ->
      registry = Keyword.get(opts, :capability_registry, CapabilityRegistry)
      _ = Capabilities.reload(registry)
    end)
  end
end
