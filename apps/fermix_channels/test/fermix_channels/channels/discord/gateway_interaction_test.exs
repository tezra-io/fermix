defmodule FermixChannels.Channels.Discord.GatewayInteractionTest do
  @moduledoc """
  The Discord one-tap Approve button (SANDBOX_ACCESS_APPROVAL_FLOW): an
  INTERACTION_CREATE button click acks the interaction (owner => strip button,
  guest => ephemeral "not authorized") and funnels the synthesized `/confirm`
  through the UNCHANGED operator-only, single-use confirm path — never
  ConfigMutation.persist directly. Hermetic: the Discord REST calls (interaction
  callback + reply) are served by a Req.Test stub, never a live gateway.
  """
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Discord.Gateway
  alias FermixChannels.Gateway.Commands.Sandbox, as: SandboxCommand
  alias FermixChannels.Gateway.Commands.Sandbox.Confirmations
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Sandbox.PathPolicy

  @channel_id "dm-channel-1"

  defmodule CapturingAgent do
    def handle_message(message, server) do
      send(server, {:agent_message, message})
      :ok
    end
  end

  setup do
    Req.Test.set_req_test_to_shared()

    home = FermixTestSupport.SafeRm.make_tmp_dir!("discord-interaction")
    root = Path.join(home, "project")
    File.mkdir_p!(root)

    previous_home = System.get_env("FERMIX_HOME")
    previous_sandbox = Application.get_env(:fermix_core, :sandbox)
    previous_discord = Application.get_env(:fermix_channels, :discord)

    System.put_env("FERMIX_HOME", home)

    # 111 is the discord owner (operator); 222 is an allow-listed guest.
    # `req_options` routes the confirm/public reply path through the stub too, so
    # a stray public channel message would be captured rather than escaping to a
    # live REST call.
    Application.put_env(:fermix_channels, :discord,
      enabled: true,
      mode: :gateway,
      bot_token: "discord-bot-token",
      bot_user_id: "999",
      owner_user_id: "111",
      allowed_user_ids: ["111", "222"],
      req_options: [plug: {Req.Test, :discord}]
    )

    Application.put_env(
      :fermix_core,
      :sandbox,
      SandboxConfig.normalize(
        home: home,
        mode: :strict,
        workspace_root: Path.join(home, "workspace")
      )
    )

    on_exit(fn ->
      restore_env("FERMIX_HOME", previous_home)
      restore(:fermix_core, :sandbox, previous_sandbox)
      restore(:fermix_channels, :discord, previous_discord)
      FermixTestSupport.SafeRm.rm_rf!(home)
    end)

    %{root: root}
  end

  test "an owner tap acks with type 7 (strip button), persists, and auto-resumes", %{root: root} do
    test_pid = self()
    stub_discord(test_pid)

    origin =
      grant_origin("111",
        resume: %{content: "finish it", reply_target: @channel_id, sender: "alice"}
      )

    {:ok, token, :new} = SandboxCommand.store_pending_grant(request(root), origin)

    gateway = start_gateway()

    assert :ok = Gateway.dispatch_event(gateway, interaction_event(token, "111"))

    # ACK-first: the interaction callback fires with the interaction id + token.
    assert_receive {:discord_request,
                    "/api/v10/interactions/interaction-1/interaction-token-1/callback", ack},
                   2_000

    assert ack["type"] == 7
    assert ack["data"]["components"] == []

    # ...and the confirm funnels through the unchanged path: persist + auto-resume.
    assert_receive {:agent_message, resumed}, 2_000
    assert resumed.content == "finish it"
    assert resumed.metadata.resumed_from_grant == token
    assert PathPolicy.canonical_path(root) in SandboxConfig.current().allowed_roots

    # Single-use: a second tap of the same button finds no pending record.
    assert :error = Confirmations.peek(token)
  end

  test "a guild guest tap acks ephemerally, never persists, and posts NO public reply",
       %{root: root} do
    test_pid = self()
    stub_discord(test_pid)

    origin =
      grant_origin("111", resume: %{content: "x", reply_target: @channel_id, sender: "alice"})

    {:ok, token, :new} = SandboxCommand.store_pending_grant(request(root), origin)

    gateway = start_gateway()

    assert :ok = Gateway.dispatch_event(gateway, guild_interaction_event(token, "222"))

    # The rejected guest gets an ephemeral ack (type 4, flags 64) — so Discord
    # never shows "interaction failed".
    assert_receive {:discord_request,
                    "/api/v10/interactions/interaction-1/interaction-token-1/callback", ack},
                   2_000

    assert ack["type"] == 4
    assert ack["data"]["flags"] == 64
    assert ack["data"]["content"] =~ "authorized"

    # A non-owner tap is NOT ingested: no public "requires owner permissions"
    # message is posted to the shared channel (which the un-stripped button could
    # otherwise be re-tapped to flood).
    refute_receive {:discord_request, "/api/v10/channels/" <> _rest, _body}, 300

    # Nothing persists and the owner's token survives intact.
    refute_receive {:agent_message, _resumed}, 300
    refute PathPolicy.canonical_path(root) in SandboxConfig.current().allowed_roots
    assert {:ok, _record} = Confirmations.peek(token)
  end

  defp start_gateway do
    start_supervised!(
      {Gateway,
       [
         name: :"discord_gateway_#{System.unique_integer([:positive])}",
         agent: CapturingAgent,
         agent_server: self(),
         connect?: false,
         req_options: [plug: {Req.Test, :discord}]
       ]}
    )
  end

  # Serves every Discord REST call (interaction callback + the confirm reply
  # message) so the flow is fully hermetic; captures each by path + decoded body.
  defp stub_discord(test_pid) do
    Req.Test.stub(:discord, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = if body == "", do: %{}, else: Jason.decode!(body)
      send(test_pid, {:discord_request, conn.request_path, decoded})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"id" => "reply-id"}))
    end)
  end

  # DM interaction: the tapper identity rides `user.id`.
  defp interaction_event(token, tapper_id) do
    %{
      "t" => "INTERACTION_CREATE",
      "d" => %{
        "id" => "interaction-1",
        "token" => "interaction-token-1",
        "type" => 3,
        "channel_id" => @channel_id,
        "data" => %{"custom_id" => "grant:#{token}", "component_type" => 2},
        "user" => %{"id" => tapper_id, "username" => "tapper"}
      }
    }
  end

  # Guild interaction: the tapper identity rides `member.user.id` and the button
  # sits in a shared channel where a public reply would be visible to everyone.
  defp guild_interaction_event(token, tapper_id) do
    %{
      "t" => "INTERACTION_CREATE",
      "d" => %{
        "id" => "interaction-1",
        "token" => "interaction-token-1",
        "type" => 3,
        "channel_id" => @channel_id,
        "guild_id" => "guild-1",
        "data" => %{"custom_id" => "grant:#{token}", "component_type" => 2},
        "member" => %{"user" => %{"id" => tapper_id, "username" => "tapper"}}
      }
    }
  end

  defp grant_origin(user_id, opts) do
    %{
      channel: "discord",
      chat_id: @channel_id,
      thread_ts: nil,
      user_id: user_id,
      resume: Keyword.fetch!(opts, :resume)
    }
  end

  defp request(root),
    do: %{path: root, reason: "the task needs it", diff: "allowed_roots + #{root}"}

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
