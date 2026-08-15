defmodule FermixChannels.Mobile.MdnsAdvertiser do
  @moduledoc """
  Explicit lifecycle for the `_fermix._tcp.local.` advertisement.

  `mdns_lite` is a `runtime: false` dependency, so a disabled mobile channel
  starts no UDP listener. This process starts it only when advertising is
  enabled and removes its one service when the mobile tree stops.
  """

  use GenServer

  require Logger

  @service_id :fermix_mobile

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec status(GenServer.server()) :: :advertising | :disabled
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    # `terminate/2` is the only thing that withdraws the service and stops the
    # owned `mdns_lite` app. A supervisor shuts a child down with an exit signal,
    # which kills an untrapped GenServer outright and never calls `terminate/2` —
    # so without this the UDP responder outlives the mobile tree and keeps
    # answering for `_fermix._tcp` after the channel is gone.
    Process.flag(:trap_exit, true)
    enabled = Keyword.get(opts, :enabled, false)
    state = build_state(opts, enabled)
    if enabled, do: start_advertising(state), else: {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = if state.advertising?, do: :advertising, else: :disabled
    {:reply, status, state}
  end

  @impl true
  def terminate(_reason, %{advertising?: true} = state) do
    case shutdown_advertising(state) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("mobile mDNS shutdown failed: #{inspect(reason)}")
        :ok
    end
  end

  def terminate(_reason, _state), do: :ok

  defp build_state(opts, enabled) do
    %{
      enabled?: enabled,
      advertising?: false,
      port: Keyword.get(opts, :port, 4_031),
      host_label: Keyword.get(opts, :host_label, default_host_label()),
      start_mdns:
        Keyword.get(opts, :start_mdns, fn -> Application.ensure_all_started(:mdns_lite) end),
      stop_mdns: Keyword.get(opts, :stop_mdns, fn -> Application.stop(:mdns_lite) end),
      add_service: Keyword.get(opts, :add_service, &MdnsLite.add_mdns_service/1),
      remove_service: Keyword.get(opts, :remove_service, &MdnsLite.remove_mdns_service/1),
      owns_mdns?: false
    }
  end

  defp start_advertising(state) do
    with {:ok, apps} <- state.start_mdns.(),
         state = %{state | owns_mdns?: :mdns_lite in apps},
         :ok <- add_service(state) do
      {:ok, %{state | advertising?: true}}
    else
      {:error, reason} -> {:stop, {:mdns_start_failed, reason}}
      other -> {:stop, {:invalid_mdns_reply, other}}
    end
  end

  defp add_service(state) do
    case state.add_service.(service(state)) do
      :ok -> :ok
      {:error, reason} -> cleanup_start_failure(state, reason)
      other -> cleanup_start_failure(state, {:invalid_service_reply, other})
    end
  end

  defp cleanup_start_failure(state, reason) do
    case stop_owned_mdns(state) do
      :ok -> {:error, reason}
      {:error, stop_reason} -> {:error, {:cleanup_failed, reason, stop_reason}}
    end
  end

  defp stop_owned_mdns(%{owns_mdns?: false}), do: :ok
  defp stop_owned_mdns(state), do: state.stop_mdns.()

  defp shutdown_advertising(state) do
    removal = state.remove_service.(@service_id)
    stop = stop_owned_mdns(state)

    case {removal, stop} do
      {:ok, :ok} -> :ok
      {{:error, reason}, :ok} -> {:error, {:remove_failed, reason}}
      {:ok, {:error, reason}} -> {:error, {:stop_failed, reason}}
      {{:error, remove}, {:error, stop}} -> {:error, {:remove_and_stop_failed, remove, stop}}
      other -> {:error, {:invalid_shutdown_reply, other}}
    end
  end

  defp service(state) do
    %{
      id: @service_id,
      protocol: "fermix",
      transport: "tcp",
      port: state.port,
      txt_payload: %{v: "1", name: state.host_label}
    }
  end

  defp default_host_label do
    case :inet.gethostname() do
      {:ok, host} -> to_string(host)
      {:error, _reason} -> "fermix"
    end
  end
end
