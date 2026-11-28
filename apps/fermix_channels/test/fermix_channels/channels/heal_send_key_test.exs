defmodule FermixChannels.Channels.HealSendKeyTest do
  @moduledoc """
  M106 §5.8, §5.9: a heal can send its owner two messages, its first and,
  after a move that did not hold, its verdict. The Mac's and the phone's
  timeline keep one row per send key and answer a repeated key with the row
  they first wrote, announcing nothing (`Timeline.append_proactive/4`), so a
  verdict sent under its first message's key would never be shown. Each of a
  heal's messages has a key of its own (`Jobs.HealMessage.send_key/1`). Run
  through the real timeline on a throwaway repo; the channels read their store
  and event sinks from the shared app env, so the tests run alone. Every value
  is invented.
  """

  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Channels.Mobile
  alias FermixCore.Companion.Timeline
  alias FermixCore.Jobs.HealMessage
  alias FermixCore.Memory.Repo

  @repo :heal_send_key_test_repo
  @heal "jhl_7c41e9a05b2d3f18"
  @first ~s(Job "Harbour tide table" failed on Tuesday, March 4, 2031 at 7:10 AM WET.)
  @verdict ~s(Job "Harbour tide table" is still failing after Fermix asked for it to run again.)

  # The timeline on this module's repo.
  defmodule RepoTimeline do
    @opts [repo: :heal_send_key_test_repo]

    def append(p, a, o), do: Timeline.append(p, a, o ++ @opts)
    def append_proactive(p, key, a, o), do: Timeline.append_proactive(p, key, a, o ++ @opts)
    def history_page(p, o), do: Timeline.history_page(p, o ++ @opts)
  end

  @app_env ~w(companion_store mobile_store mobile_event_sink mobile_push_launcher
              link_preview_launcher)a

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

    dir = FermixTestSupport.SafeRm.make_tmp_dir!("heal-send-key")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

    start_supervised!(
      {Repo, name: @repo, enabled: true, database_path: Path.join(dir, "memory.db")}
    )

    {:ok, _owner} = Registry.register(Companion.registry(), Companion.chat_profile(), 2)
    :ok
  end

  test "under one key, a second message is answered with the first row and never shown" do
    key = "job_heal:" <> @heal

    assert :ok = Companion.send_message("main", @first, proactive_key: key)
    assert_receive {:companion_event, %{"t" => "row", "text" => @first}}

    assert :ok = Companion.send_message("main", @verdict, proactive_key: key)
    assert :ok = Mobile.send_message("main", @verdict, proactive_key: key)

    refute_received {:companion_event, %{"t" => "row", "text" => @verdict}}
    refute_received {:mobile_event, "main", %{"t" => "row", "text" => @verdict}}
    assert [%{content: @first}] = history()
  end

  test "a heal's first message and its verdict are each a row, on the Mac and the phones" do
    first_key = HealMessage.send_key(%{id: @heal, conclusion: "first"})
    verdict_key = HealMessage.send_key(%{id: @heal, conclusion: "verdict"})

    assert :ok = Companion.send_message("main", @first, proactive_key: first_key)
    assert :ok = Mobile.send_message("main", @verdict, proactive_key: verdict_key)

    assert_receive {:companion_event, %{"t" => "row", "text" => @first}}
    assert_receive {:companion_event, %{"t" => "row", "text" => @verdict}}
    assert_receive {:mobile_event, "main", %{"t" => "row", "text" => @verdict}}
    assert [%{content: @first}, %{content: @verdict}] = history()

    # A retry of either is still answered with its own row.
    assert :ok = Mobile.send_message("main", @verdict, proactive_key: verdict_key)
    assert [_first, _verdict] = history()
  end

  defp history do
    {:ok, %{messages: rows}} = RepoTimeline.history_page("main", limit: 10)
    rows
  end

  defp restore_env({key, {:ok, value}}), do: Application.put_env(:fermix_channels, key, value)
  defp restore_env({key, :error}), do: Application.delete_env(:fermix_channels, key)
end
