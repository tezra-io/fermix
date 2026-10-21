defmodule FermixChannels.Mobile.Iroh do
  @moduledoc """
  Remote reach: the rail that lets a paired phone reach this daemon from any
  network through `fermix-iroh` and Fermix's relays (M62).

  A small `rest_for_one` supervisor, the last child of `Mobile.Supervisor` and
  the one its live switch (`[fermix_channels.mobile] iroh`) starts and stops:

  1. the connections' `DynamicSupervisor`, one `Iroh.BridgeConnection` per iroh
     stream;
  2. `Iroh.Bridge`, the bridge socket the helper connects to;
  3. `Iroh.Helper`, the helper itself.

  A bridge that goes down takes the helper with it, since the helper's streams
  died with the socket; a helper fault restarts nothing, because `Iroh.Helper`
  never stops over one (it reports and retries).

  `start_link/1` returns `:ignore` while the switch is off, so the child stays
  registered and the switch can start it again (the phone subtree's own
  pattern).
  """

  use Supervisor

  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.Iroh.Bridge
  alias FermixChannels.Mobile.Iroh.Helper

  @doc "Whether `[fermix_channels.mobile] iroh` is on in the running config; on unless set off."
  @spec switch_on?() :: boolean()
  def switch_on? do
    :fermix_channels |> Application.get_env(:mobile, []) |> Keyword.get(:iroh, true) == true
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      shutdown: :infinity
    }
  end

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    switch = Keyword.get(opts, :switch, &switch_on?/0)

    if switch.() == true, do: Supervisor.start_link(__MODULE__, opts), else: :ignore
  end

  @impl true
  def init(opts) do
    root = Keyword.fetch!(opts, :root)
    names = Keyword.fetch!(opts, :names)
    socket_path = Bridge.socket_path(root)

    children = [
      {DynamicSupervisor, name: names.bridge_connections, strategy: :one_for_one},
      {Bridge,
       name: names.bridge,
       socket_path: socket_path,
       connection_supervisor: names.bridge_connections,
       connection_opts: [session_opts: Keyword.fetch!(opts, :session_opts)]},
      Supervisor.child_spec(
        {Helper,
         [
           name: names.iroh_helper,
           root: root,
           bridge_socket: socket_path,
           bridge: names.bridge,
           device_store: names.device_store,
           identity_exists?: fn -> identity_exists?(root) end,
           emit: &FermixChannels.Telemetry.emit_transport(:mobile_iroh, &1, &2, &3)
         ] ++ Keyword.get(opts, :helper_opts, [])},
        shutdown: 10_000
      )
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp identity_exists?(root) do
    case Identity.paths(root: root) do
      {:ok, paths} -> File.exists?(paths.gateway_key)
      {:error, _reason} -> false
    end
  end
end
