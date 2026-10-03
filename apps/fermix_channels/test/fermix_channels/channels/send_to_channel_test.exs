defmodule FermixChannels.Channels.SendToChannelTest do
  @moduledoc """
  M56 §4.7: `send_to_channel` through the real companion and mobile adapters,
  on a throwaway timeline. A send to the owner's chat is the ordinary
  proactive row the Mac and the phones are told of; a send to the phones is
  that row and its push; a retry in the turn is the row already written.
  """

  # The adapters announce through the application-wide companion registry and
  # read app env for the stores and the phones' sinks, so the tests run alone.
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Channels.Mobile
  alias FermixChannels.Mobile.Supervisor, as: MobileSupervisor
  alias FermixCore.Companion.Timeline
  alias FermixCore.Memory.Repo
  alias FermixCore.Tools.SendToChannel

  @repo :send_to_channel_timeline_repo
  @env ~w(companion_store mobile_store mobile_event_sink mobile_push mobile_push_launcher mobile_unfurl_launcher)a
  @text "The lease renews on 2026-11-01."

  # The shared timeline on this module's throwaway repo.
  defmodule Store do
    @opts [repo: :send_to_channel_timeline_repo]

    def append_proactive(p, key, a, o), do: Timeline.append_proactive(p, key, a, o ++ @opts)
    def history_page(p, o), do: Timeline.history_page(p, o ++ @opts)
  end

  setup do
    test_pid = self()
    previous = Map.new(@env, &{&1, Application.fetch_env(:fermix_channels, &1)})
    on_exit(fn -> Enum.each(previous, &restore/1) end)

    dir = FermixTestSupport.SafeRm.make_tmp_dir!("send-to-channel-timeline")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)
    start_supervised!({Repo, name: @repo, enabled: true, database_path: Path.join(dir, "m.db")})

    Application.put_env(:fermix_channels, :companion_store, Store)
    Application.put_env(:fermix_channels, :mobile_store, Store)

    Application.put_env(:fermix_channels, :mobile_event_sink, fn profile, event ->
      send(test_pid, {:mobile_event, profile, event})
      :ok
    end)

    Application.put_env(:fermix_channels, :mobile_push, fn profile, seq, preview ->
      send(test_pid, {:push_notify, profile, seq, preview})
      {:ok, %{status: :sent, sent: 1}}
    end)

    Application.put_env(:fermix_channels, :mobile_push_launcher, fn task -> task.() end)
    Application.put_env(:fermix_channels, :mobile_unfurl_launcher, fn _task -> :ok end)

    {:ok, _owner} = Registry.register(Companion.registry(), Companion.chat_profile(), 2)
    :ok
  end

  test "a send to the owner's chat is one row, told to the Mac and the phones; a retry is it" do
    first = SendToChannel.execute(args("companion"), context())
    second = SendToChannel.execute(args("companion"), context())

    assert {:ok, %{success: true}} = first
    assert second == first

    assert_receive {:companion_event, %{"t" => "row", "text" => @text, "server_seq" => seq}}
    assert_receive {:mobile_event, "main", %{"t" => "row", "server_seq" => ^seq}}
    refute_receive {:companion_event, %{"t" => "row"}}, 200
    refute_received {:push_notify, _profile, _seq, _preview}
    assert [%{content: @text, role: "assistant"}] = rows()
  end

  test "a send to the phones is that row and its push, once" do
    start_supervised!(%{
      id: :phone_subtree,
      start: {Agent, :start_link, [fn -> :phone_subtree end, [name: MobileSupervisor]]}
    })

    first = SendToChannel.execute(args("mobile"), context())
    assert SendToChannel.execute(args("mobile"), context()) == first
    assert {:ok, %{success: true}} = first

    assert_receive {:push_notify, "main", seq, @text}
    assert_receive {:companion_event, %{"t" => "row", "server_seq" => ^seq}}
    refute_receive {:push_notify, _profile, _seq, _preview}, 200
    assert [%{content: @text}] = rows()
  end

  test "the phones are refused while their channel does not run, and the chat gets nothing" do
    assert {:ok, %{success: false, error: error}} =
             SendToChannel.execute(args("mobile"), context())

    assert error =~ "mobile has no inbox of the owner's"
    assert error =~ "companion"
    assert rows() == []
    refute_receive {:companion_event, _event}, 200
  end

  defp args(channel), do: %{"channel" => channel, "text" => @text}

  defp context do
    %{
      agent_name: "main",
      conversation_key: Companion.chat_conversation_key(),
      session_id: "turn-1",
      source_trust: :operator,
      jobs_config: [delivery_channels: %{"companion" => Companion, "mobile" => Mobile}],
      configured_owners: %{}
    }
  end

  defp rows do
    {:ok, %{messages: rows}} = Store.history_page("main", limit: 50)
    rows
  end

  defp restore({key, {:ok, value}}), do: Application.put_env(:fermix_channels, key, value)
  defp restore({key, :error}), do: Application.delete_env(:fermix_channels, key)
end
