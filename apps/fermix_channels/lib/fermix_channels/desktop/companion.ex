defmodule FermixChannels.Desktop.Companion do
  @moduledoc """
  The companion family of a desktop session, on the primary (M75 §6, B1).

  A desktop's engine carries each connection to its own `companion.sock` as
  one `channel` (`Desktop.Tunnel` on the desktop). For each channel the
  primary runs an ordinary, unchanged `Companion.Connection`, started with the
  options its own companion endpoint gives its connections
  (`Companion.Endpoint.connection_opts/1`), so approvals, proposals, search,
  history and turn streams work exactly as on the local socket. A
  `Desktop.CompanionPump` per channel owns the other end of that
  connection's socket and moves its lines to and from the desktop.

  At most 4 channels are open at once; a fifth, and a channel number already
  open, is answered `companion_close` with its reason, and the session stays
  open. The channels end with the session.

  A test names its seams as the family's options (`Desktop.Peer`'s
  `{module, options}`): `:endpoint` (the companion
  endpoint), `:supervisor` (where the connections and pumps run,
  `FermixChannels.Desktop.TunnelSupervisor`), `:socket_dir` (where each
  connection's private socket is made, `<home>/mobile`).
  """

  @behaviour FermixChannels.Desktop.Family

  require Logger

  alias FermixChannels.Companion.Endpoint
  alias FermixChannels.Desktop.CompanionPump
  alias FermixChannels.Desktop.Peer
  alias FermixCore.Setup.ConfigStore

  @max_channels 4

  @doc "The most channels a desktop holds open at once."
  @spec max_channels() :: pos_integer()
  def max_channels, do: @max_channels

  @impl true
  def init(%{device_id: device_id, registry: registry} = context) do
    opts = Map.get(context, :options, [])

    {:ok,
     %{
       device_id: device_id,
       registry: registry,
       endpoint: Keyword.get(opts, :endpoint, Endpoint),
       supervisor: Keyword.get(opts, :supervisor, FermixChannels.Desktop.TunnelSupervisor),
       socket_dir:
         Keyword.get_lazy(opts, :socket_dir, fn ->
           Path.join(ConfigStore.fermix_home(), "mobile")
         end),
       channels: %{}
     }}
  end

  @impl true
  def handle_event("companion_open", %{"channel" => channel}, _payload, state),
    do: {:ok, open(channel, prune(state))}

  def handle_event("companion_line", %{"channel" => channel}, line, state) do
    case Map.fetch(state.channels, channel) do
      {:ok, pump} -> :ok = CompanionPump.line(pump, line)
      :error -> close(state, channel, "That channel is not open.")
    end

    {:ok, state}
  end

  def handle_event("companion_close", %{"channel" => channel}, _payload, state) do
    case Map.pop(state.channels, channel) do
      {nil, _channels} -> {:ok, state}
      {pump, channels} -> {:ok, stop_pump(%{state | channels: channels}, pump)}
    end
  end

  @impl true
  def handle_info({:pump_ended, channel, pump}, state) do
    case Map.fetch(state.channels, channel) do
      {:ok, ^pump} -> {:ok, %{state | channels: Map.delete(state.channels, channel)}}
      _other -> {:ok, state}
    end
  end

  def handle_info(message, state) do
    Logger.debug("desktop companion family ignored #{inspect(message)}")
    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.channels, fn {_channel, pump} -> stop_pump(state, pump) end)
  end

  defp open(channel, state) do
    cond do
      Map.has_key?(state.channels, channel) ->
        close(state, channel, "That channel is already open.")

      map_size(state.channels) >= @max_channels ->
        close(state, channel, "Four chats are already open from this desktop.")

      true ->
        start_pump(channel, state)
    end
  end

  defp start_pump(channel, state) do
    opts = [
      device_id: state.device_id,
      channel: channel,
      family: self(),
      registry: state.registry,
      endpoint: state.endpoint,
      supervisor: state.supervisor,
      socket_dir: state.socket_dir
    ]

    case DynamicSupervisor.start_child(state.supervisor, {CompanionPump, opts}) do
      {:ok, pump} ->
        %{state | channels: Map.put(state.channels, channel, pump)}

      {:error, reason} ->
        Logger.error("desktop companion: channel #{channel} did not open: #{inspect(reason)}")
        close(state, channel, "The server could not open this chat.")
    end
  end

  # A pump that died without saying so no longer holds its channel.
  defp prune(state),
    do: %{
      state
      | channels: Map.filter(state.channels, fn {_channel, pump} -> Process.alive?(pump) end)
    }

  defp stop_pump(state, pump) do
    _ = DynamicSupervisor.terminate_child(state.supervisor, pump)
    state
  end

  defp close(state, channel, reason) do
    event = %{"t" => "companion_close", "channel" => channel, "reason" => reason}

    case Peer.send(state.device_id, event, <<>>, registry: state.registry) do
      :ok -> :ok
      {:error, error} -> Logger.warning("desktop companion: close not sent: #{inspect(error)}")
    end

    state
  end
end
