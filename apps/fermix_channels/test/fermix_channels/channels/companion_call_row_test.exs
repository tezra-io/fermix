defmodule FermixChannels.Channels.CompanionCallRowTest do
  @moduledoc """
  The one write for a GPT-Live call's rows (M56 §4.5), through the real
  timeline on a throwaway repo: the row it writes, the key it dedupes on, and
  what the Mac and the phones are told. The companion registry and the mobile
  event sink are application-wide, so the tests run alone.
  """

  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Companion.Output
  alias FermixChannels.Mobile.Protocol, as: MobileProtocol
  alias FermixCore.Companion.Protocol, as: CompanionProtocol
  alias FermixCore.Companion.Timeline
  alias FermixCore.Memory.Repo

  @repo :companion_call_row_test_repo
  @call_uuid "3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b"

  # The timeline on this module's repo.
  defmodule RepoTimeline do
    @opts [repo: :companion_call_row_test_repo]

    def append_proactive(p, key, a, o), do: Timeline.append_proactive(p, key, a, o ++ @opts)
    def history_page(p, o), do: Timeline.history_page(p, o ++ @opts)
  end

  @app_env ~w(companion_store mobile_event_sink)a

  setup do
    test_pid = self()
    previous = Map.new(@app_env, &{&1, Application.fetch_env(:fermix_channels, &1)})
    on_exit(fn -> Enum.each(previous, &restore_env/1) end)
    Application.put_env(:fermix_channels, :companion_store, RepoTimeline)

    Application.put_env(:fermix_channels, :mobile_event_sink, fn profile, event ->
      send(test_pid, {:mobile_event, profile, event})
      :ok
    end)

    dir = FermixTestSupport.SafeRm.make_tmp_dir!("companion-call-row")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

    start_supervised!(
      {Repo, name: @repo, enabled: true, database_path: Path.join(dir, "memory.db")}
    )

    {:ok, _owner} = Registry.register(Companion.registry(), Companion.chat_profile(), 2)
    :ok
  end

  test "a result shown in the chat is an assistant text row carrying its call" do
    text = "The form is at https://x.test/form.\n\nIt asks for a name and a city."

    assert {:ok, %{server_seq: seq} = row} =
             Companion.write_call_row(Companion.chat_profile(), text, shared_call())

    assert %{role: "assistant", kind: "text", content: ^text, proactive_key: key} = row
    assert key == "voice:#{@call_uuid}:dg_01H9:1"

    assert {:ok, %{messages: [stored]}} = RepoTimeline.history_page("main", limit: 10)
    assert {:ok, message} = Output.timeline_message(stored)

    assert message == %{
             "server_seq" => seq,
             "role" => "assistant",
             "content" => text,
             "kind" => "text",
             "media_refs" => [],
             "metadata" => %{"call" => shared_call()},
             "ts" => message["ts"]
           }
  end

  test "the Mac hears the row with its kind and call, the phones the whole message" do
    assert {:ok, %{server_seq: seq}} =
             Companion.write_call_row("main", "See https://x.test/a", shared_call())

    assert_receive {:companion_event, mac_row}

    assert %{
             "t" => "row",
             "profile_id" => "main",
             "server_seq" => ^seq,
             "role" => "assistant",
             "text" => "See https://x.test/a",
             "kind" => "text",
             "metadata" => %{"call" => %{"event" => "shared", "uuid" => @call_uuid}}
           } = mac_row

    assert {:ok, _line} = CompanionProtocol.encode_server_event("row", Map.delete(mac_row, "t"))

    assert_receive {:mobile_event, "main", phone_row}

    assert %{
             "t" => "row",
             "server_seq" => ^seq,
             "kind" => "text",
             "media_refs" => [],
             "metadata" => %{"call" => %{"task_id" => "dg_01H9", "revision" => 1}}
           } = phone_row

    assert {:ok, _frames} =
             MobileProtocol.encode_server_event("row", Map.delete(phone_row, "t"), 1, <<>>, [])
  end

  test "the same task revision written twice is one row, announced once" do
    assert {:ok, %{server_seq: seq}} = Companion.write_call_row("main", "first", shared_call())
    assert_receive {:companion_event, %{"t" => "row", "server_seq" => ^seq}}
    assert_receive {:mobile_event, "main", %{"t" => "row", "server_seq" => ^seq}}

    assert {:ok, %{server_seq: ^seq, content: "first"}} =
             Companion.write_call_row("main", "a retry", shared_call())

    refute_receive {:companion_event, _row}, 100
    refute_receive {:mobile_event, _profile, _row}, 100

    next = %{shared_call() | "revision" => 2}
    assert {:ok, %{server_seq: other}} = Companion.write_call_row("main", "corrected", next)
    assert other > seq
  end

  test "a call map in any other shape, or a profile not the chat's, writes nothing" do
    assert {:error, {:missing_field, "call.task_id"}} =
             Companion.write_call_row("main", "x", Map.delete(shared_call(), "task_id"))

    assert {:error, {:unknown_field, "call.text"}} =
             Companion.write_call_row("main", "x", Map.put(shared_call(), "text", "x"))

    assert {:error, :unsupported_profile} =
             Companion.write_call_row("phone", "x", shared_call())

    assert {:ok, %{messages: []}} = RepoTimeline.history_page("main", limit: 10)
    refute_receive {:companion_event, _row}, 100
  end

  # Stage 5 writes a result shown during the call; the other events get their
  # keys with the stage that writes them.
  test "an event with no row key of its own is refused" do
    ended = %{"uuid" => @call_uuid, "event" => "ended"}

    assert {:error, {:unkeyed_call_event, "ended"}} =
             Companion.write_call_row("main", "Voice call, 6 minutes", ended)
  end

  test "a text past 32 KB is cut at the end, on a character, behind a marker" do
    text = "a" <> String.duplicate("é", 20_000)

    assert {:ok, %{content: shown}} = Companion.write_call_row("main", text, shared_call())

    assert byte_size(shown) <= 32_768
    assert String.valid?(shown)
    assert String.starts_with?(shown, "aéé")
    assert String.ends_with?(shown, Companion.call_row_cut_marker())
  end

  defp shared_call do
    %{"uuid" => @call_uuid, "event" => "shared", "task_id" => "dg_01H9", "revision" => 1}
  end

  defp restore_env({key, {:ok, value}}), do: Application.put_env(:fermix_channels, key, value)
  defp restore_env({key, :error}), do: Application.delete_env(:fermix_channels, key)
end
