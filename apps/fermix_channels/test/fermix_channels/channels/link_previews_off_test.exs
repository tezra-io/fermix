defmodule FermixChannels.Channels.LinkPreviewsOffTest do
  @moduledoc """
  A send that asks for `link_previews: false` (every message a cue run causes,
  M60 §9.5) builds a request that fetches nothing it names: Discord suppresses
  embeds, Slack turns unfurling off, and the phone's timeline schedules no
  preview. A send that does not ask is unchanged.
  """
  # async: false — the channels read their config from the shared app env.
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Channels.Discord
  alias FermixChannels.Channels.Mobile
  alias FermixChannels.Channels.Slack

  @text "Phoenix 1.8.2 is out: https://example.com/phoenix-1-8-2"

  defmodule TimelineStub do
    @moduledoc false
    def append(profile_id, attrs, _opts) do
      {:ok,
       Map.merge(attrs, %{
         profile_id: profile_id,
         server_seq: 9,
         created_at: ~U[2026-10-10 12:00:00Z]
       })}
    end

    def append_proactive(profile_id, _key, attrs, _opts) do
      {:ok, row} = append(profile_id, attrs, [])
      {:ok, {:created, row}}
    end
  end

  setup do
    Req.Test.set_req_test_to_shared()

    keys = [
      :discord,
      :slack,
      :mobile_store,
      :companion_store,
      :mobile_event_sink,
      :mobile_push_launcher,
      :link_preview_launcher
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:fermix_channels, &1)})
    test_pid = self()

    Application.put_env(:fermix_channels, :discord,
      enabled: true,
      mode: :gateway,
      bot_token: "discord-bot-token",
      bot_user_id: "999",
      allowed_user_ids: ["111"],
      req_options: [plug: {Req.Test, :discord_previews}]
    )

    Application.put_env(:fermix_channels, :slack,
      enabled: true,
      mode: :webhook,
      bot_token: "xoxb-test-token",
      signing_secret: "slack-signing-secret",
      allowed_user_ids: ["U12345"],
      req_options: [plug: {Req.Test, :slack_previews}]
    )

    Application.put_env(:fermix_channels, :mobile_store, TimelineStub)
    Application.put_env(:fermix_channels, :companion_store, TimelineStub)
    Application.put_env(:fermix_channels, :mobile_event_sink, fn _profile, _event -> :ok end)
    Application.put_env(:fermix_channels, :mobile_push_launcher, fn _task -> :ok end)

    Application.put_env(:fermix_channels, :link_preview_launcher, fn _task ->
      send(test_pid, :previews_launched)
      :ok
    end)

    on_exit(fn -> Enum.each(previous, &restore/1) end)
    :ok
  end

  describe "Discord" do
    test "suppresses embeds when previews are off, and only then" do
      stub_recording(:discord_previews, %{"id" => "m1"})

      assert :ok = Discord.send_message("channel-1", @text, link_previews: false)
      assert_receive {:request, body}
      assert body["flags"] == 4

      assert :ok = Discord.send_message("channel-1", @text, [])
      assert_receive {:request, body}
      refute Map.has_key?(body, "flags")
    end
  end

  describe "Slack" do
    test "turns link and media unfurling off when previews are off, and only then" do
      stub_recording(:slack_previews, %{"ok" => true, "ts" => "1.2"})

      assert :ok = Slack.send_message("C1", @text, link_previews: false)
      assert_receive {:request, body}
      assert body["unfurl_links"] == false
      assert body["unfurl_media"] == false

      assert :ok = Slack.send_message("C1", @text, [])
      assert_receive {:request, body}
      refute Map.has_key?(body, "unfurl_links")
      refute Map.has_key?(body, "unfurl_media")
    end
  end

  describe "the phone" do
    test "schedules no link preview when previews are off, and does otherwise" do
      assert :ok =
               Mobile.send_message("main", @text, link_previews: false, proactive_key: "job:r1")

      refute_received :previews_launched

      assert :ok = Mobile.send_message("main", @text, proactive_key: "job:r2")
      assert_received :previews_launched
    end
  end

  # The Mac app draws only the previews the engine fetches for it (it loads no
  # link or image itself), so skipping the fetch is the whole of previews off.
  describe "the Mac app" do
    test "schedules no link preview when previews are off, and does otherwise" do
      assert :ok =
               Companion.send_message("main", @text,
                 link_previews: false,
                 proactive_key: "job:r3"
               )

      refute_received :previews_launched

      assert :ok = Companion.send_message("main", @text, proactive_key: "job:r4")
      assert_received :previews_launched
    end
  end

  defp stub_recording(name, response) do
    test_pid = self()

    Req.Test.stub(name, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end)
  end

  defp restore({key, {:ok, value}}), do: Application.put_env(:fermix_channels, key, value)
  defp restore({key, :error}), do: Application.delete_env(:fermix_channels, key)
end
