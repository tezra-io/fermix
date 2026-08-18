defmodule FermixCore.Meetings.TranscriptStoreTest do
  # Every write lands under a per-test SafeRm tmp root injected as `:root`, so
  # nothing touches the real FERMIX_HOME and the suite stays async-safe.
  use ExUnit.Case, async: true

  import Bitwise, only: [{:&&&, 2}]

  alias FermixCore.Meetings.TranscriptStore

  @meeting_id "mtg_abcdefghijk"

  setup do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("meetings-transcript")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)
    %{root: root, dir: Path.join([root, "meetings", @meeting_id])}
  end

  defp open!(root, opts \\ []) do
    {:ok, store} = TranscriptStore.open(@meeting_id, [root: root] ++ opts)
    store
  end

  defp segment(t0_ms, t1_ms, speaker, text) do
    %{t0_ms: t0_ms, t1_ms: t1_ms, speaker: speaker, text: text}
  end

  defp meta do
    %{
      meeting_id: @meeting_id,
      platform: :meet,
      url: "https://meet.google.com/abc-defg-hij",
      title: "Weekly sync",
      status: "delivered",
      end_reason: :meeting_ended,
      participants_peak: 3
    }
  end

  defp mode(path) do
    %File.Stat{mode: mode} = File.stat!(path)
    mode &&& 0o777
  end

  describe "open/2" do
    test "creates the artifact dir 0700 with a 0600 jsonl", %{root: root, dir: dir} do
      store = open!(root)

      assert TranscriptStore.dir(store) == dir
      assert File.dir?(dir)
      assert mode(dir) == 0o700
      assert mode(Path.join(dir, "transcript.jsonl")) == 0o600
    end

    test "writes no audio file unless retain_audio is true", %{root: root, dir: dir} do
      store = open!(root)
      {:ok, store} = TranscriptStore.append_audio(store, <<1, 2, 3, 4>>)
      TranscriptStore.close(store)

      refute File.exists?(Path.join(dir, "audio.raw"))
    end

    test "retain_audio opens audio.raw and appends raw pcm", %{root: root, dir: dir} do
      store = open!(root, retain_audio: true)
      {:ok, store} = TranscriptStore.append_audio(store, <<1, 2>>)
      {:ok, store} = TranscriptStore.append_audio(store, <<3, 4>>)
      TranscriptStore.close(store)

      assert File.read!(Path.join(dir, "audio.raw")) == <<1, 2, 3, 4>>
      assert mode(Path.join(dir, "audio.raw")) == 0o600
    end

    test "refuses a meeting id that could escape the meetings dir", %{root: root} do
      assert {:error, {:invalid_meeting_id, "../escape"}} =
               TranscriptStore.open("../escape", root: root)

      assert {:error, {:invalid_meeting_id, _}} = TranscriptStore.open("a/b", root: root)
    end
  end

  describe "append/2" do
    test "writes one JSON object per line and counts segments and words", %{
      root: root,
      dir: dir
    } do
      store = open!(root)
      {:ok, store} = TranscriptStore.append(store, segment(1_200, 4_300, "Ada", "hello there"))

      {:ok, store} =
        TranscriptStore.append(store, segment(4_300, 6_000, "Grace", "three more words"))

      TranscriptStore.close(store)

      lines =
        Path.join(dir, "transcript.jsonl")
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert [first, second] = lines

      assert first == %{
               "t0_ms" => 1_200,
               "t1_ms" => 4_300,
               "speaker" => "Ada",
               "text" => "hello there"
             }

      assert second["speaker"] == "Grace"
    end

    test "refuses an entry missing the schema keys", %{root: root} do
      store = open!(root)
      incomplete = Map.delete(segment(0, 500, "Ada", "no speaker key"), :speaker)

      assert_raise FunctionClauseError, fn ->
        TranscriptStore.append(store, incomplete)
      end

      TranscriptStore.close(store)
    end
  end

  describe "finalize/2" do
    setup %{root: root} do
      store = open!(root)
      {:ok, store} = TranscriptStore.append(store, segment(1_200, 4_300, "Ada", "hello there"))

      {:ok, store} =
        TranscriptStore.append(store, segment(3_725_000, 3_730_000, "Grace", "wrapping up now"))

      %{store: store}
    end

    test "renders transcript.md with hh:mm:ss stamps and bold speakers", %{
      store: store,
      dir: dir
    } do
      assert {:ok, %{dir: ^dir, segments: 2, words: 5}} = TranscriptStore.finalize(store, meta())

      assert File.read!(Path.join(dir, "transcript.md")) == """
             # Weekly sync

             **[00:00:01] Ada:** hello there
             **[01:02:05] Grace:** wrapping up now
             """

      assert mode(Path.join(dir, "transcript.md")) == 0o600
    end

    test "falls to the url as the heading when the meeting has no title", %{
      store: store,
      dir: dir
    } do
      {:ok, _result} = TranscriptStore.finalize(store, %{meta() | title: nil})

      assert File.read!(Path.join(dir, "transcript.md")) =~
               "# https://meet.google.com/abc-defg-hij\n"
    end

    test "writes meta.json verbatim plus the counters", %{store: store, dir: dir} do
      {:ok, _result} = TranscriptStore.finalize(store, meta())

      decoded = Path.join(dir, "meta.json") |> File.read!() |> Jason.decode!()

      assert decoded["meeting_id"] == @meeting_id
      assert decoded["platform"] == "meet"
      assert decoded["end_reason"] == "meeting_ended"
      assert decoded["participants_peak"] == 3
      assert decoded["segments"] == 2
      assert decoded["words"] == 5
      assert mode(Path.join(dir, "meta.json")) == 0o600
    end

    test "closes the descriptors, and a re-open appends to the same jsonl", %{
      store: store,
      root: root,
      dir: dir
    } do
      {:ok, _result} = TranscriptStore.finalize(store, meta())

      assert {:error, :terminated} =
               TranscriptStore.append(store, segment(0, 1, "Ada", "after close"))

      reopened = open!(root)
      {:ok, reopened} = TranscriptStore.append(reopened, segment(9_000, 9_500, "Alan", "again"))
      TranscriptStore.close(reopened)

      assert Path.join(dir, "transcript.jsonl")
             |> File.read!()
             |> String.split("\n", trim: true)
             |> length() == 3
    end
  end

  describe "close/1" do
    test "closes the descriptors without rendering", %{root: root, dir: dir} do
      store = open!(root)
      {:ok, store} = TranscriptStore.append(store, segment(0, 500, "Ada", "aborted"))

      assert TranscriptStore.close(store) == :ok
      assert TranscriptStore.close(store) == :ok

      refute File.exists?(Path.join(dir, "transcript.md"))
      refute File.exists?(Path.join(dir, "meta.json"))

      assert {:error, :terminated} = TranscriptStore.append(store, segment(0, 1, "Ada", "x"))
    end
  end
end
