defmodule FermixChannels.Channels.MessageOriginTest do
  @moduledoc """
  A message a scheduled job's or a cue's run sends names where it came from
  (`origin`, companion PROTOCOL.md *Where a message came from*). The Mac's and
  the phone's timeline store it on the row, through the real timeline on a
  throwaway repo, so the live `row` and every history page carry it; every
  other channel sends exactly what it sends without it. The channels read
  their config, the companion registry and the mobile event sink from the
  shared app env, so the tests run alone.
  """

  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Channels.Discord
  alias FermixChannels.Channels.Mobile
  alias FermixChannels.Channels.Slack
  alias FermixChannels.Channels.Telegram
  alias FermixChannels.Channels.WhatsApp
  alias FermixChannels.Companion.Output
  alias FermixChannels.Mobile.Protocol, as: MobileProtocol
  alias FermixCore.Companion.Protocol, as: CompanionProtocol
  alias FermixCore.Companion.Timeline
  alias FermixCore.Memory.Repo

  @repo :message_origin_test_repo
  @job %{"kind" => "job", "name" => "Morning briefing"}
  @cue %{"kind" => "cue", "name" => "codex-limits"}
  @text "Two meetings today, the first at 10."

  # The timeline on this module's repo.
  defmodule RepoTimeline do
    @opts [repo: :message_origin_test_repo]

    def append(p, a, o), do: Timeline.append(p, a, o ++ @opts)
    def append_proactive(p, key, a, o), do: Timeline.append_proactive(p, key, a, o ++ @opts)
    def history_page(p, o), do: Timeline.history_page(p, o ++ @opts)
  end

  @app_env ~w(
    companion_store mobile_store mobile_event_sink mobile_push_launcher link_preview_launcher
    telegram slack discord whatsapp
  )a

  setup do
    test_pid = self()
    previous = Map.new(@app_env, &{&1, Application.fetch_env(:fermix_channels, &1)})
    on_exit(fn -> Enum.each(previous, &restore_env/1) end)

    Application.put_env(:fermix_channels, :companion_store, RepoTimeline)
    Application.put_env(:fermix_channels, :mobile_store, RepoTimeline)
    Application.put_env(:fermix_channels, :mobile_push_launcher, fn _task -> :ok end)
    Application.put_env(:fermix_channels, :link_preview_launcher, fn _task -> :ok end)

    Application.put_env(:fermix_channels, :mobile_event_sink, fn profile, event ->
      send(test_pid, {:mobile_event, profile, event})
      :ok
    end)

    dir = FermixTestSupport.SafeRm.make_tmp_dir!("message-origin")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

    start_supervised!(
      {Repo, name: @repo, enabled: true, database_path: Path.join(dir, "memory.db")}
    )

    {:ok, _owner} = Registry.register(Companion.registry(), Companion.chat_profile(), 2)
    :ok
  end

  describe "the Mac's and the phone's timeline" do
    test "a job's message is a row naming the job, on the Mac, the phones and in history" do
      assert :ok = Companion.send_message("main", @text, proactive_key: "job:run_1", origin: @job)

      assert_receive {:companion_event, %{"t" => "row", "metadata" => metadata} = mac_row}
      assert metadata == %{"origin" => @job}
      assert {:ok, _line} = CompanionProtocol.encode_server_event("row", Map.delete(mac_row, "t"))

      assert_receive {:mobile_event, "main", %{"t" => "row"} = phone_row}
      assert phone_row["metadata"] == %{"origin" => @job}

      assert {:ok, _frames} =
               MobileProtocol.encode_server_event("row", Map.delete(phone_row, "t"), 1, <<>>, [])

      assert [%{"content" => @text, "metadata" => %{"origin" => @job}}] = history()
    end

    test "a cue's message through the phone's channel names the watcher" do
      opts = [proactive_key: "job:run_2", link_previews: false, origin: @cue]
      assert :ok = Mobile.send_message("main", @text, opts)

      assert_receive {:mobile_event, "main", %{"t" => "row", "metadata" => %{"origin" => @cue}}}
      assert_receive {:companion_event, %{"t" => "row", "metadata" => %{"origin" => @cue}}}
      assert [%{"metadata" => %{"origin" => @cue}}] = history()
    end

    # A reminder, a turn's reply and a Live call's row name no origin.
    test "a delivery that names no origin stores none" do
      assert :ok = Companion.send_message("main", @text, proactive_key: "reminder:rem_1")

      assert_receive {:companion_event, %{"t" => "row"} = mac_row}
      refute Map.has_key?(mac_row, "metadata")
      assert [message] = history()
      refute Map.has_key?(message, "metadata")
    end

    test "an origin outside its shape is refused, and nothing is written" do
      bad = %{"kind" => "reminder", "name" => "Pay rent"}

      assert {:error, {:invalid_field, "origin.kind"}} =
               Companion.send_message("main", @text, proactive_key: "job:run_3", origin: bad)

      refute_received {:companion_event, _row}
      assert [] = history()
    end
  end

  describe "every other channel" do
    setup do
      Req.Test.set_req_test_to_shared()

      Application.put_env(:fermix_channels, :telegram,
        bot_token: "telegram-bot-token",
        allowed_user_ids: ["111"]
      )

      Application.put_env(:fermix_channels, :slack,
        enabled: true,
        mode: :webhook,
        bot_token: "xoxb-test-token",
        signing_secret: "slack-signing-secret",
        allowed_user_ids: ["U12345"]
      )

      Application.put_env(:fermix_channels, :discord,
        enabled: true,
        mode: :gateway,
        bot_token: "discord-bot-token",
        bot_user_id: "999",
        allowed_user_ids: ["111"]
      )

      Application.put_env(:fermix_channels, :whatsapp,
        enabled: true,
        mode: :webhook,
        access_token: "whatsapp-access-token",
        phone_number_id: "123456789",
        verify_token: "verify-token",
        app_secret: "app-secret",
        allowed_sender_ids: ["15551234567"]
      )

      :ok
    end

    test "sends exactly what it sends without the origin" do
      channels = [
        {Telegram, "123", :origin_telegram, %{"ok" => true, "result" => %{"message_id" => 1}}},
        {Slack, "C1", :origin_slack, %{"ok" => true, "ts" => "1.2"}},
        {Discord, "channel-1", :origin_discord, %{"id" => "m1"}},
        {WhatsApp, "15551234567", :origin_whatsapp, %{"messages" => [%{"id" => "wamid.1"}]}}
      ]

      for {channel, destination, stub, response} <- channels do
        stub_recording(stub, response)
        opts = [proactive_key: "job:run_1", req_options: [plug: {Req.Test, stub}]]

        assert :ok = channel.send_message(destination, @text, opts)
        assert_receive {:request, ^stub, without}

        assert :ok = channel.send_message(destination, @text, opts ++ [origin: @cue])
        assert_receive {:request, ^stub, with_origin}

        assert with_origin == without, "#{inspect(channel)} sent the origin on"
        refute elem(with_origin, 1) =~ "codex-limits"
      end
    end
  end

  defp history do
    assert {:ok, %{messages: rows}} = RepoTimeline.history_page("main", limit: 10)

    Enum.map(rows, fn row ->
      assert {:ok, message} = Output.timeline_message(row)
      message
    end)
  end

  defp stub_recording(name, response) do
    test_pid = self()

    Req.Test.stub(name, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, name, {conn.request_path, body}})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end)
  end

  defp restore_env({key, {:ok, value}}), do: Application.put_env(:fermix_channels, key, value)
  defp restore_env({key, :error}), do: Application.delete_env(:fermix_channels, key)
end
