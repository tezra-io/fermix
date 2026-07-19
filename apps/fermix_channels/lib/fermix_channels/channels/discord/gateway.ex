defmodule FermixChannels.Channels.Discord.Gateway do
  @moduledoc """
  Supervised Discord Gateway runtime.

  Connects to the Discord Gateway WebSocket, normalizes direct-message and
  app-mention events through `FermixChannels.Channels.Discord`, and routes them through
  the shared dispatcher.
  """

  use GenServer

  require Logger

  alias FermixChannels.Channels.Discord
  alias FermixChannels.Gateway
  alias FermixChannels.Gateway.Authorization
  alias FermixChannels.Gateway.Authorizer
  alias FermixChannels.Gateway.Queue
  alias FermixChannels.Gateway.Source

  @default_reconnect_ms 5_000

  # Ephemeral (flags 64) reply shown only to a non-owner tapper so Discord does
  # not render "This interaction failed"; the confirm ingest independently
  # rejects the tap at operator_only, so nothing is persisted.
  @not_authorized_ack "You're not authorized to approve this."

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
      agent: Keyword.get(opts, :agent, Queue),
      agent_server: Keyword.get(opts, :agent_server, Queue),
      connect?: Keyword.get(opts, :connect?, true),
      reconnect_ms: Keyword.get(opts, :reconnect_ms, @default_reconnect_ms),
      req_options: Keyword.get(opts, :req_options, []),
      socket_client:
        Keyword.get(opts, :socket_client, FermixChannels.Channels.Discord.Gateway.Socket),
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
  def handle_cast({:gateway_event, %{"t" => "INTERACTION_CREATE"} = event}, state) do
    handle_interaction(event, state)
    {:noreply, state}
  end

  def handle_cast({:gateway_event, event}, state) do
    case Discord.parse_gateway_event(event) do
      {:ok, messages} when messages != [] ->
        handle_dispatch_result(messages, state)

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

  defp handle_dispatch_result(messages, state) do
    case Gateway.ingest(messages,
           channel: Discord,
           agent: state.agent,
           agent_server: state.agent_server
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Discord gateway dispatch failed: #{inspect(reason)}")
    end
  end

  # A button tap (INTERACTION_CREATE): ack within the interaction's hard 3s
  # window, then — for the owner only — funnel the synthesized `/confirm` through
  # the unchanged confirm path (the single authority that consumes the single-use
  # token). We resolve owner-vs-guest once, up front: it selects both the ack
  # shape and whether to ingest.
  defp handle_interaction(event, state) do
    case Discord.parse_interaction(event) do
      {:ok, interaction} ->
        respond_to_tap(interaction, owner_tap?(interaction.message), state)

      :ignore ->
        :ok

      {:error, reason} ->
        Logger.error("Discord interaction parse failed: #{inspect(reason)}")
    end
  end

  # Owner: strip the used button, then ingest the synthesized `/confirm`.
  defp respond_to_tap(interaction, true, state) do
    ack_interaction(interaction, true, state)
    handle_dispatch_result([interaction.message], state)
  end

  # Non-owner: ack ephemerally and DON'T ingest. The confirm path would reject a
  # non-owner at operator_only anyway; ingesting would post the command
  # framework's public "requires owner permissions" reply to a shared channel,
  # and the un-stripped guest button could be re-tapped to flood it.
  defp respond_to_tap(interaction, false, state) do
    ack_interaction(interaction, false, state)
  end

  defp owner_tap?(message) do
    case message |> Map.from_struct() |> Source.from_message() |> Authorizer.resolve() do
      {:ok, %Authorization{role: :operator}} -> true
      _other -> false
    end
  end

  # Owner: type 7 UPDATE_MESSAGE strips the used button so it can't be re-tapped
  # (the token is single-use regardless; the confirm outcome reaches the owner
  # through the normal reply path). Guest: type 4 CHANNEL_MESSAGE_WITH_SOURCE
  # with an ephemeral "not authorized" note.
  defp ack_interaction(interaction, true, state) do
    respond_ack(interaction, %{type: 7, data: %{components: []}}, state)
  end

  defp ack_interaction(interaction, false, state) do
    respond_ack(
      interaction,
      %{type: 4, data: %{content: @not_authorized_ack, flags: 64}},
      state
    )
  end

  defp respond_ack(interaction, response, state) do
    case Discord.respond_interaction(interaction.id, interaction.token, response,
           req_options: state.req_options
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Discord interaction ack failed: #{inspect(reason)}")
    end
  end
end
