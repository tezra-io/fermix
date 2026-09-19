defmodule FermixCore.Browser.Bridge.Supervisor do
  @moduledoc """
  The browser bridge's three children, started in the order they depend on:

  1. `Grants`, the table of granted tabs — it outlives every connection, so a
     `Peer` can register into it the moment it is accepted,
  2. a `DynamicSupervisor` for the Peers, one per connected extension and
     `temporary` so a dead connection is never resurrected with a dead socket,
  3. the `Endpoint`, which binds the socket and accepts.

  `:one_for_one`: a listener restart must not take a live extension connection
  down with it. The `Endpoint` child is allowed to be **absent** — a socket it
  cannot bind makes it return `:ignore`, which costs the bridge alone.
  """

  use Supervisor

  alias FermixCore.Browser.Bridge.Endpoint
  alias FermixCore.Browser.Bridge.Grants

  @peer_supervisor FermixCore.Browser.Bridge.PeerSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The DynamicSupervisor that owns one Peer per connected extension."
  @spec peer_supervisor() :: atom()
  def peer_supervisor, do: @peer_supervisor

  @impl true
  def init(opts) do
    grants = Keyword.get(opts, :grants, Grants)
    peer_supervisor = Keyword.get(opts, :peer_supervisor, @peer_supervisor)

    children = [
      {Grants, name: grants},
      {DynamicSupervisor, name: peer_supervisor, strategy: :one_for_one},
      {Endpoint, endpoint_opts(opts, grants, peer_supervisor)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp endpoint_opts(opts, grants, peer_supervisor) do
    opts
    |> Keyword.take([:socket_path, :max_connections])
    |> Keyword.put(:name, Keyword.get(opts, :endpoint_name, Endpoint))
    |> Keyword.put(:grants, grants)
    |> Keyword.put(:peer_supervisor, peer_supervisor)
  end
end
