defmodule FermixChannels.Discord.Gateway.Socket do
  @moduledoc """
  Discord Gateway WebSocket protocol handler.

  Handles the minimal M3 protocol surface: Hello, Identify, heartbeat, reconnect
  requests, and MESSAGE_CREATE dispatch events.
  """

  use WebSockex
  import Bitwise

  require Logger

  alias FermixChannels.Discord.Gateway

  @guilds_intent 1 <<< 0
  @guild_messages_intent 1 <<< 9
  @direct_messages_intent 1 <<< 12
  @message_content_intent 1 <<< 15

  # Discord DM ingress needs guild context for app mentions, guild/direct message
  # events, and message content so Fermix can read the prompt text.
  @identify_intents @guilds_intent ||| @guild_messages_intent ||| @direct_messages_intent |||
                      @message_content_intent

  @spec start_link(String.t(), map(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(url, state, opts \\ []) when is_binary(url) and is_map(state) do
    WebSockex.start(url, __MODULE__, state, opts)
  end

  @impl true
  def handle_frame({:text, payload}, state) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, event} when is_map(event) ->
        handle_gateway_event(event, update_sequence(event, state))

      {:error, reason} ->
        Logger.error("Discord gateway frame decode failed: #{Exception.message(reason)}")
        {:ok, state}
    end
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_info(:heartbeat, state) do
    state = schedule_heartbeat(state)
    {:reply, heartbeat_frame(state.sequence), state}
  end

  @impl true
  def handle_disconnect(_status, state) do
    {:reconnect, cancel_heartbeat(state)}
  end

  @impl true
  def terminate(_reason, state) do
    cancel_heartbeat(state)
    :ok
  end

  defp handle_gateway_event(%{"op" => 10, "d" => data}, state) when is_map(data) do
    interval = Map.get(data, "heartbeat_interval")

    state =
      state
      |> Map.put(:heartbeat_interval_ms, interval)
      |> schedule_heartbeat()

    {:reply, session_start_frame(state), state}
  end

  defp handle_gateway_event(%{"op" => 0, "t" => "READY", "d" => data}, state)
       when is_map(data) do
    {:ok, Map.put(state, :session_id, Map.get(data, "session_id"))}
  end

  defp handle_gateway_event(%{"op" => 0, "t" => "MESSAGE_CREATE"} = event, state) do
    Gateway.dispatch_event(state.gateway, event)
    {:ok, state}
  end

  defp handle_gateway_event(%{"op" => 1}, state) do
    {:reply, heartbeat_frame(state.sequence), state}
  end

  defp handle_gateway_event(%{"op" => 7}, state) do
    {:close, state}
  end

  defp handle_gateway_event(%{"op" => 9, "d" => true}, state) do
    {:close, state}
  end

  defp handle_gateway_event(%{"op" => 9}, state) do
    {:close, clear_session(state)}
  end

  defp handle_gateway_event(_event, state), do: {:ok, state}

  defp update_sequence(%{"s" => sequence}, state) when not is_nil(sequence) do
    Map.put(state, :sequence, sequence)
  end

  defp update_sequence(_event, state), do: state

  defp schedule_heartbeat(%{heartbeat_interval_ms: interval} = state)
       when is_integer(interval) and interval > 0 do
    state = cancel_heartbeat(state)
    ref = Process.send_after(self(), :heartbeat, interval)
    Map.put(state, :heartbeat_ref, ref)
  end

  defp schedule_heartbeat(state), do: state

  defp cancel_heartbeat(%{heartbeat_ref: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    Map.put(state, :heartbeat_ref, nil)
  end

  defp cancel_heartbeat(state), do: state

  defp session_start_frame(state) do
    if resumable_session?(state) do
      resume_frame(state)
    else
      identify_frame(state.token)
    end
  end

  defp identify_frame(token) do
    {:text,
     Jason.encode!(%{
       op: 2,
       d: %{
         token: token,
         intents: @identify_intents,
         properties: %{os: "linux", browser: "fermix", device: "fermix"}
       }
     })}
  end

  defp resume_frame(%{token: token, session_id: session_id, sequence: sequence}) do
    {:text,
     Jason.encode!(%{
       op: 6,
       d: %{
         token: token,
         session_id: session_id,
         seq: sequence
       }
     })}
  end

  defp heartbeat_frame(sequence) do
    {:text, Jason.encode!(%{op: 1, d: sequence})}
  end

  defp resumable_session?(%{session_id: session_id, sequence: sequence})
       when is_binary(session_id) and session_id != "" and is_integer(sequence) do
    true
  end

  defp resumable_session?(_state), do: false

  defp clear_session(state) do
    state
    |> Map.put(:session_id, nil)
    |> Map.put(:sequence, nil)
  end
end
