defmodule FermixCore.Realtime.ConversationRecorderTest do
  use ExUnit.Case, async: true

  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.ConversationRecorder

  defmodule FakeRepo do
    def insert_message(attrs, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:insert_message, attrs, opts})
      {:ok, Map.put(attrs, :id, 123)}
    end
  end

  defmodule FakeReviewer do
    def start_background(opts) do
      send(Keyword.fetch!(opts, :test_pid), {:request_review, opts})
      :ok
    end
  end

  test "conversation_key uses realtime channel and stable local device id" do
    assert ConversationRecorder.conversation_key("device-1") ==
             {"realtime", "local:device-1", :root}

    assert ConversationRecorder.conversation_key("device-1", "session-a") ==
             {"realtime", "local:device-1", "session-a"}
  end

  test "skips durable writes and extraction when transcript persistence is disabled" do
    config = Config.normalize(enabled: true, persist_transcripts: false)

    assert :ok =
             ConversationRecorder.record_turn(config, "device-1", "user", "hello",
               repo_module: FakeRepo,
               memory_reviewer: FakeReviewer,
               test_pid: self()
             )

    refute_received {:insert_message, _attrs, _opts}
    refute_received {:request_review, _opts}
  end

  test "writes voice_turn transcript rows with realtime source metadata and requests review" do
    config = Config.normalize(enabled: true, persist_transcripts: true)

    assert :ok =
             ConversationRecorder.record_turn(config, "device-1", "assistant", "hello back",
               repo_module: FakeRepo,
               repo: :memory_repo,
               memory_reviewer: FakeReviewer,
               agent_id: "main",
               owner_id: "owner",
               test_pid: self()
             )

    assert_receive {:insert_message, attrs, repo_opts}
    assert Keyword.get(repo_opts, :server) == :memory_repo
    assert attrs.agent_id == "main"
    assert attrs.owner_id == "owner"
    assert attrs.channel == "realtime"
    assert attrs.chat_id == "local:device-1"
    assert attrs.thread_scope == :root
    assert attrs.role == "assistant"
    assert attrs.kind == "voice_turn"
    assert attrs.content == "hello back"
    assert attrs.metadata.source_type == "realtime"
    assert attrs.metadata.source_id == "local:device-1"
    assert attrs.metadata.device_id == "device-1"

    assert_receive {:request_review, review_opts}

    assert Keyword.get(review_opts, :conversation_key) ==
             {"realtime", "local:device-1", :root}

    assert Keyword.get(review_opts, :source_type) == "realtime"
    assert Keyword.get(review_opts, :source_id) == "local:device-1"

    # The voice path no longer carries a provider/route; the reviewer
    # resolves the configured main-model route itself.
    refute Keyword.has_key?(review_opts, :provider)
    refute Keyword.has_key?(review_opts, :adapter)
    refute Keyword.has_key?(review_opts, :route_key)
  end

  test "records a Live caption verbatim as its own kind and never asks for review" do
    config = Config.normalize(enabled: true, engine: "openai_live", persist_transcripts: true)

    assert :ok =
             ConversationRecorder.record_caption(config, "device-1", "user", "book ",
               repo_module: FakeRepo,
               repo: :memory_repo,
               memory_reviewer: FakeReviewer,
               session_scope: "voice_live:1",
               start_ms: 1_200,
               end_ms: 1_640,
               test_pid: self()
             )

    assert_receive {:insert_message, attrs, _repo_opts}
    assert attrs.kind == "live_caption"
    assert attrs.role == "user"
    assert attrs.sender == "user"
    assert attrs.thread_scope == "voice_live:1"
    # Verbatim: the trailing space belongs to the sentence, not to formatting.
    assert attrs.content == "book "
    assert attrs.metadata.speaker == "user"
    assert attrs.metadata.start_ms == 1_200
    assert attrs.metadata.end_ms == 1_640
    assert attrs.metadata.transcript_kind == "live_caption"

    refute_received {:request_review, _opts}
  end

  test "a caption writes nothing when transcript persistence is disabled" do
    config = Config.normalize(enabled: true, engine: "openai_live", persist_transcripts: false)

    assert :ok =
             ConversationRecorder.record_caption(config, "device-1", "assistant", "on it",
               repo_module: FakeRepo,
               memory_reviewer: FakeReviewer,
               test_pid: self()
             )

    refute_received {:insert_message, _attrs, _opts}
    refute_received {:request_review, _opts}
  end
end
