defmodule FermixCore.Realtime.SessionSupervisor do
  @moduledoc """
  Dynamic supervisor for local Realtime voice sessions.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_session(GenServer.server(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(server \\ __MODULE__, opts) when is_list(opts) do
    DynamicSupervisor.start_child(server, {FermixCore.Realtime.SessionServer, opts})
  end

  @spec active_sessions(GenServer.server()) :: non_neg_integer()
  def active_sessions(server \\ __MODULE__) do
    server
    |> DynamicSupervisor.count_children()
    |> Map.get(:active, 0)
  rescue
    _error -> 0
  end
end
