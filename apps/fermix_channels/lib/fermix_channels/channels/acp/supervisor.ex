defmodule FermixChannels.Channels.Acp.Supervisor do
  @moduledoc """
  The acp channel's transport child (MILESTONE_29_ACP_AGENT_SURFACE.md §6.1),
  started by `FermixChannels.Application` through
  `ChannelRegistry.transport_children/1` when `[fermix_channels.acp] enabled` is
  true — and by nothing else when it is not (G4: one gate, whole surface).

  Three children, started in order because the later ones depend on the earlier:

  1. a unique-keys `Registry` mapping each ACP session id to the Peer that owns
     it (how the channel adapter's per-turn closures find their connection),
  2. a `DynamicSupervisor` for the Peers — one per client connection, `temporary`
     so a dead connection is never resurrected with a dead socket,
  3. the `Endpoint`, which binds the socket and accepts.

  `:one_for_one`: peers are independent of the listener and of each other, so a
  listener restart must not take live sessions down with it.

  The `Endpoint` child is allowed to be **absent**: a socket it cannot bind makes
  it return `:ignore`, which this supervisor records as not-started and starts
  around. That is deliberate — ACP is an optional transport, and an unbindable
  socket must cost the ACP surface only, never the daemon's boot. `/health`
  reports the channel `degraded` in that state.
  """

  use Supervisor

  alias FermixChannels.Channels.Acp
  alias FermixChannels.Channels.Acp.Endpoint

  @peer_supervisor FermixChannels.Channels.Acp.PeerSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The DynamicSupervisor that owns one Peer per client connection."
  @spec peer_supervisor() :: atom()
  def peer_supervisor, do: @peer_supervisor

  @impl true
  def init(opts) do
    registry = Keyword.get(opts, :registry, Acp.registry())
    peer_supervisor = Keyword.get(opts, :peer_supervisor, @peer_supervisor)

    children = [
      {Registry, keys: :unique, name: registry},
      {DynamicSupervisor, name: peer_supervisor, strategy: :one_for_one},
      {Endpoint, endpoint_opts(opts, registry, peer_supervisor)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp endpoint_opts(opts, registry, peer_supervisor) do
    opts
    |> Keyword.take([:socket_path, :max_connections, :peer_opts])
    |> Keyword.put(:registry, registry)
    |> Keyword.put(:peer_supervisor, peer_supervisor)
  end
end
