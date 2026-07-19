defmodule FermixChannels.Channels.Discord.Gateway.SocketTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Discord.Gateway
  alias FermixChannels.Channels.Discord.Gateway.Socket

  defmodule CapturingAgent do
    def handle_message(message, test_pid) do
      send(test_pid, {:agent_message, message})
      :ok
    end
  end

  setup do
    Application.put_env(:fermix_channels, :discord,
      enabled: true,
      mode: :gateway,
      bot_token: "discord-bot-token",
      bot_user_id: "999",
      # F-02: empty allowlist now denies.
      allowed_user_ids: ["111"]
    )

    on_exit(fn -> Application.delete_env(:fermix_channels, :discord) end)

    :ok
  end

  test "identifies after hello and schedules heartbeats" do
    state = socket_state(self())
    hello = Jason.encode!(%{op: 10, d: %{heartbeat_interval: 30_000}})

    assert {:reply, {:text, identify}, state} = Socket.handle_frame({:text, hello}, state)

    assert Jason.decode!(identify) == %{
             "op" => 2,
             "d" => %{
               "token" => "discord-bot-token",
               "intents" => 37_377,
               "properties" => %{"os" => "linux", "browser" => "fermix", "device" => "fermix"}
             }
           }

    assert is_reference(state.heartbeat_ref)
    Process.cancel_timer(state.heartbeat_ref)
  end

  test "dispatches MESSAGE_CREATE frames through the gateway process" do
    {:ok, gateway} =
      start_supervised(
        {Gateway,
         [
           name: :"discord_gateway_#{System.unique_integer([:positive])}",
           agent: CapturingAgent,
           agent_server: self(),
           connect?: false
         ]}
      )

    state = socket_state(gateway)
    event = Jason.encode!(dm_event("hello socket"))

    assert {:ok, _state} = Socket.handle_frame({:text, event}, state)

    assert_receive {:agent_message, message}
    assert message.channel == "discord"
    assert message.content == "hello socket"
  end

  test "routes INTERACTION_CREATE frames to the gateway process" do
    # Point the socket's gateway at the test process so the raw dispatch is
    # observable as a plain cast, without standing up the full ack/confirm path.
    state = socket_state(self())

    event =
      Jason.encode!(%{
        op: 0,
        s: 43,
        t: "INTERACTION_CREATE",
        d: %{
          id: "interaction-1",
          token: "interaction-token-1",
          type: 3,
          channel_id: "dm-channel-1",
          data: %{custom_id: "grant:TOK12345"},
          user: %{id: "111", username: "alice"}
        }
      })

    assert {:ok, _state} = Socket.handle_frame({:text, event}, state)

    assert_receive {:"$gen_cast", {:gateway_event, %{"t" => "INTERACTION_CREATE"}}}
  end

  test "resumes an invalidated session when Discord marks it resumable" do
    state = %{socket_state(self()) | session_id: "session-1", sequence: 42}
    invalid_session = Jason.encode!(%{op: 9, d: true})

    assert {:close, state} = Socket.handle_frame({:text, invalid_session}, state)
    assert state.session_id == "session-1"
    assert state.sequence == 42

    hello = Jason.encode!(%{op: 10, d: %{heartbeat_interval: 30_000}})

    assert {:reply, {:text, resume}, state} = Socket.handle_frame({:text, hello}, state)

    assert Jason.decode!(resume) == %{
             "op" => 6,
             "d" => %{
               "token" => "discord-bot-token",
               "session_id" => "session-1",
               "seq" => 42
             }
           }

    assert is_reference(state.heartbeat_ref)
    Process.cancel_timer(state.heartbeat_ref)
  end

  test "clears invalidated sessions that Discord does not allow resuming" do
    state = %{socket_state(self()) | session_id: "session-1", sequence: 42}
    invalid_session = Jason.encode!(%{op: 9, d: false})

    assert {:close, state} = Socket.handle_frame({:text, invalid_session}, state)
    assert state.session_id == nil
    assert state.sequence == nil

    hello = Jason.encode!(%{op: 10, d: %{heartbeat_interval: 30_000}})

    assert {:reply, {:text, identify}, state} = Socket.handle_frame({:text, hello}, state)

    assert Jason.decode!(identify) == %{
             "op" => 2,
             "d" => %{
               "token" => "discord-bot-token",
               "intents" => 37_377,
               "properties" => %{"os" => "linux", "browser" => "fermix", "device" => "fermix"}
             }
           }

    assert is_reference(state.heartbeat_ref)
    Process.cancel_timer(state.heartbeat_ref)
  end

  test "sends heartbeat frames with the latest sequence" do
    state = %{socket_state(self()) | sequence: 42, heartbeat_interval_ms: 30_000}

    assert {:reply, {:text, heartbeat}, state} = Socket.handle_info(:heartbeat, state)
    assert Jason.decode!(heartbeat) == %{"op" => 1, "d" => 42}

    assert is_reference(state.heartbeat_ref)
    Process.cancel_timer(state.heartbeat_ref)
  end

  defp socket_state(gateway) do
    %{
      gateway: gateway,
      token: "discord-bot-token",
      sequence: nil,
      heartbeat_interval_ms: nil,
      heartbeat_ref: nil,
      session_id: nil
    }
  end

  defp dm_event(content) do
    %{
      op: 0,
      s: 42,
      t: "MESSAGE_CREATE",
      d: %{
        id: "message-1",
        channel_id: "dm-channel-1",
        content: content,
        guild_id: nil,
        author: %{id: "111", username: "alice", bot: false},
        attachments: []
      }
    }
  end
end
