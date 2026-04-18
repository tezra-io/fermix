defmodule FermixChannels.Discord.GatewayTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Discord.Gateway

  defmodule CapturingAgent do
    def handle_message(message, test_pid) do
      send(test_pid, {:agent_message, message})
      :ok
    end
  end

  defmodule FakeSocketClient do
    def start_link(url, socket_state, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:socket_started, url, socket_state})
      Agent.start_link(fn -> %{url: url, socket_state: socket_state} end)
    end
  end

  setup do
    Req.Test.set_req_test_to_shared()

    Application.put_env(:fermix_channels, :discord,
      enabled: true,
      mode: :gateway,
      bot_token: "discord-bot-token",
      bot_user_id: "999"
    )

    on_exit(fn -> Application.delete_env(:fermix_channels, :discord) end)

    :ok
  end

  test "dispatches direct message gateway events into the shared runtime" do
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

    assert :ok = Gateway.dispatch_event(gateway, dm_event("hello gateway"))

    assert_receive {:agent_message, message}
    assert message.channel == "discord"
    assert message.chat_id == "dm-channel-1"
    assert message.content == "hello gateway"
  end

  test "connects a socket to the Discord Gateway URL" do
    test_pid = self()

    Req.Test.stub(:discord_gateway, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"url" => "wss://gateway.discord.test"}))
    end)

    {:ok, gateway} =
      start_supervised(
        {Gateway,
         [
           name: :"discord_gateway_#{System.unique_integer([:positive])}",
           agent: CapturingAgent,
           agent_server: test_pid,
           req_options: [plug: {Req.Test, :discord_gateway}],
           socket_client: FakeSocketClient,
           socket_options: [test_pid: test_pid]
         ]}
      )

    assert_receive {:socket_started, "wss://gateway.discord.test/?v=10&encoding=json",
                    socket_state}

    assert socket_state.gateway == gateway
    assert socket_state.token == "discord-bot-token"
  end

  defp dm_event(content) do
    %{
      "t" => "MESSAGE_CREATE",
      "d" => %{
        "id" => "message-1",
        "channel_id" => "dm-channel-1",
        "content" => content,
        "guild_id" => nil,
        "author" => %{"id" => "111", "username" => "alice", "bot" => false},
        "attachments" => []
      }
    }
  end
end
