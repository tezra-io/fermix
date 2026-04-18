defmodule FermixChannels.Discord.Gateway do
  @moduledoc """
  Supervised Discord Gateway runtime.

  Connects to the Discord Gateway WebSocket, normalizes direct-message and
  app-mention events through `FermixChannels.Discord`, and routes them through
  the shared dispatcher.
  """

  use GenServer

  require Logger

  alias FermixChannels.Discord
  alias FermixChannels.Dispatcher
  alias FermixCore.Agents.MainAgent

  @default_reconnect_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec dispatch_event(GenServer.server(), map()) :: :ok
  def dispatch_event(server \\ __MODULE__, event) when is_map(event) do
    GenServer.cast(server, {:gateway_event, event})
  end

  @impl true
  def init(opts) do
    state = %{
      agent: Keyword.get(opts, :agent, MainAgent),
      agent_server: Keyword.get(opts, :agent_server, MainAgent),
      connect?: Keyword.get(opts, :connect?, true),
      reconnect_ms: Keyword.get(opts, :reconnect_ms, @default_reconnect_ms),
      req_options: Keyword.get(opts, :req_options, []),
      socket_client: Keyword.get(opts, :socket_client, FermixChannels.Discord.Gateway.Socket),
      socket_options: Keyword.get(opts, :socket_options, []),
      socket: nil,
      socket_ref: nil
    }

    if state.connect? do
      send(self(), :connect)
    end

    {:ok, state}
  end

  @impl true
  def handle_cast({:gateway_event, event}, state) do
    case Discord.parse_gateway_event(event) do
      {:ok, messages} when messages != [] ->
        Dispatcher.dispatch(messages,
          channel: Discord,
          agent: state.agent,
          agent_server: state.agent_server
        )

      {:ok, []} ->
        :ok

      {:error, reason} ->
        Logger.error("Discord gateway event failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:connect, %{socket: nil} = state) do
    {:noreply, connect_socket(state)}
  end

  def handle_info(:connect, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{socket_ref: ref} = state) do
    Logger.error("Discord gateway socket exited: #{inspect(reason)}")

    state =
      state
      |> Map.put(:socket, nil)
      |> Map.put(:socket_ref, nil)
      |> schedule_reconnect()

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.socket), do: Process.exit(state.socket, :shutdown)
    :ok
  end

  defp connect_socket(state) do
    with {:ok, token} <- Discord.bot_token(),
         {:ok, url} <- Discord.gateway_url(req_options: state.req_options),
         {:ok, socket} <- start_socket(state, url, token) do
      ref = Process.monitor(socket)

      Logger.info("Discord gateway socket connected")

      %{state | socket: socket, socket_ref: ref}
    else
      {:error, reason} ->
        Logger.error("Discord gateway connect failed: #{inspect(reason)}")
        schedule_reconnect(state)
    end
  end

  defp start_socket(state, url, token) do
    socket_state = %{
      gateway: self(),
      token: token,
      sequence: nil,
      heartbeat_interval_ms: nil,
      heartbeat_ref: nil,
      session_id: nil
    }

    state.socket_client.start_link(url, socket_state, state.socket_options)
  end

  defp schedule_reconnect(%{connect?: false} = state), do: state

  defp schedule_reconnect(state) do
    Process.send_after(self(), :connect, state.reconnect_ms)
    state
  end
end
