defmodule FermixCore.Tools.MemoryRecallTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Store
  alias FermixCore.Tools.MemoryRecall

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-memory-recall-#{unique}.db")
    repo = :"mem_recall_repo_#{unique}"
    store = :"mem_recall_tool_#{unique}"
    conversation_store = :"mem_recall_history_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    start_supervised!(%{
      id: store,
      start: {Store, :start_link, [[name: store, repo: repo]]}
    })

    start_supervised!(%{
      id: conversation_store,
      start: {ConversationStore, :start_link, [[name: conversation_store, repo: repo]]}
    })

    conv_key = {"telegram", "chat_#{System.unique_integer([:positive])}"}

    context = %{
      agent_name: "test_agent",
      conversation_key: conv_key,
      memory_store: store,
      memory_repo: repo
    }

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{context: context, conv_key: conv_key, repo: repo, store: store, history: conversation_store}
  end

  describe "name/0" do
    test "returns memory_recall" do
      assert MemoryRecall.name() == "memory_recall"
    end
  end

  describe "description/0" do
    test "returns a non-empty string" do
      desc = MemoryRecall.description()
      assert is_binary(desc)
      assert byte_size(desc) > 0
    end
  end

  describe "parameters/0" do
    test "returns JSON Schema with exact and search options" do
      params = MemoryRecall.parameters()
      assert params.type == "object"
      assert Map.has_key?(params.properties, :key)
      assert Map.has_key?(params.properties, :search)
      assert Map.has_key?(params.properties, :scope)
      assert Map.has_key?(params.properties, :source)
      refute Map.has_key?(params, :required)
    end
  end

  describe "execute/2 - recall by key" do
    test "returns stored value", %{context: context, conv_key: conv_key, store: store} do
      Store.store(conv_key, "user_name", "Alice", server: store)

      assert {:ok, result} = MemoryRecall.execute(%{"key" => "user_name"}, context)
      assert result.success == true
      assert result.output == "Alice"
    end

    test "returns error for missing key", %{context: context} do
      assert {:ok, result} = MemoryRecall.execute(%{"key" => "missing"}, context)
      assert result.success == false
      assert result.error =~ "No memory found"
    end
  end

  describe "execute/2 - recall all" do
    test "returns all memories when key omitted", %{
      context: context,
      conv_key: conv_key,
      store: store
    } do
      Store.store(conv_key, "name", "Alice", server: store)
      Store.store(conv_key, "lang", "en", server: store)

      assert {:ok, result} = MemoryRecall.execute(%{}, context)
      assert result.success == true
      assert result.output =~ "name"
      assert result.output =~ "Alice"
      assert result.output =~ "lang"
      assert result.output =~ "en"
    end

    test "returns message when no memories exist", %{context: context} do
      assert {:ok, result} = MemoryRecall.execute(%{}, context)
      assert result.success == true
      assert result.output =~ "No memories"
    end
  end

  describe "execute/2 - lexical search" do
    test "returns ranked memory and history hits with source metadata", %{
      context: context,
      conv_key: conv_key,
      store: store,
      history: history
    } do
      Store.store(conv_key, "timezone", "UTC", server: store)

      ConversationStore.add_message(
        {"telegram", elem(conv_key, 1), :root},
        "user",
        "We discussed timezone handling in the chat",
        server: history
      )

      assert {:ok, result} =
               MemoryRecall.execute(%{"search" => "timezone", "source" => "all"}, context)

      assert result.success == true
      assert result.output =~ "[memories"
      assert result.output =~ "key=timezone"
      assert result.output =~ "[history"
      assert result.output =~ "timezone handling"
    end

    test "excludes archived memory hits", %{context: context, repo: repo} do
      assert {:ok, memory} =
               Repo.upsert_memory(
                 %{
                   agent_id: "main",
                   owner_id: "default",
                   scope_type: "owner",
                   scope_id: "default",
                   category: "preference",
                   key: "archived_timezone",
                   value: "Archived timezone preference"
                 },
                 server: repo
               )

      assert {:ok, _archived} =
               Repo.archive_memory(
                 %{id: memory.id, agent_id: "main", owner_id: "default", archived?: false},
                 "memory_reviewer",
                 "stale",
                 DateTime.utc_now(),
                 server: repo
               )

      assert {:ok, result} =
               MemoryRecall.execute(%{"search" => "Archived timezone", "scope" => "all"}, context)

      assert result.success == true
      assert result.output =~ "No lexical matches"
    end

    test "includes job source metadata for scheduled job memory", %{context: context, repo: repo} do
      assert {:ok, _memory} =
               Repo.upsert_memory(
                 %{
                   agent_id: "main",
                   owner_id: "default",
                   scope_type: "job",
                   scope_id: "job:daily_digest",
                   category: "job_run_summary",
                   key: "latest",
                   value: "The daily digest found a queue regression.",
                   source_id: "job:daily_digest",
                   source_type: "scheduled_job",
                   source_name: "Daily Digest",
                   source_description: "Runs every morning.",
                   session_id: "cron_daily_digest_20260502_080000",
                   run_id: "run_123"
                 },
                 server: repo
               )

      assert {:ok, result} =
               MemoryRecall.execute(
                 %{"search" => "queue regression", "scope" => "all"},
                 context
               )

      assert result.success == true
      assert result.output =~ "source_id=job:daily_digest"
      assert result.output =~ "source_type=scheduled_job"
      assert result.output =~ "source_name=\"Daily Digest\""
      assert result.output =~ "source_description=\"Runs every morning.\""
      assert result.output =~ "session_id=cron_daily_digest_20260502_080000"
      assert result.output =~ "run_id=run_123"
    end

    test "scheduled job current scope searches its own job memory", %{
      context: base_context,
      repo: repo
    } do
      assert {:ok, _memory} =
               Repo.upsert_memory(
                 %{
                   agent_id: "main",
                   owner_id: "default",
                   scope_type: "job",
                   scope_id: "job:daily_digest",
                   category: "job_run_summary",
                   key: "latest",
                   value: "The digest found a storage warning.",
                   source_id: "job:daily_digest",
                   source_type: "scheduled_job",
                   source_name: "Daily Digest",
                   source_description: "Runs every morning.",
                   session_id: "cron_daily_digest_20260502_080000",
                   run_id: "run_123"
                 },
                 server: repo
               )

      context =
        Map.merge(base_context, %{
          conversation_key: {:scheduled_job, "daily_digest", "run_456"},
          memory_source_id: "job:daily_digest",
          memory_read_scopes: ["job:self"]
        })

      assert {:ok, result} =
               MemoryRecall.execute(%{"search" => "storage warning"}, context)

      assert result.success == true
      assert result.output =~ "The digest found a storage warning."
      assert result.output =~ "source_name=\"Daily Digest\""
    end

    test "scheduled job current scope rejects history search explicitly", %{
      context: base_context
    } do
      context =
        Map.merge(base_context, %{
          conversation_key: {:scheduled_job, "daily_digest", "run_456"},
          memory_source_id: "job:daily_digest",
          memory_read_scopes: ["job:self"]
        })

      assert {:ok, result} =
               MemoryRecall.execute(
                 %{"search" => "timezone", "source" => "history"},
                 context
               )

      assert result.success == false
      assert result.error =~ "Scheduled jobs cannot access conversation history"
    end

    test "respects owner scope and history source filters", %{context: context, repo: repo} do
      assert {:ok, _memory} =
               Repo.upsert_memory(
                 %{
                   agent_id: "main",
                   owner_id: "default",
                   scope_type: "owner",
                   scope_id: "default",
                   category: "fact",
                   key: "timezone",
                   value: "UTC owner preference"
                 },
                 server: repo
               )

      assert {:ok, _message} =
               Repo.insert_message(
                 %{
                   agent_id: "main",
                   owner_id: "default",
                   channel: "telegram",
                   chat_id: "chat_history",
                   thread_scope: "root",
                   sender: "alice",
                   role: "user",
                   kind: "chat_message",
                   content: "timezone from message history"
                 },
                 server: repo
               )

      assert {:ok, history_only} =
               MemoryRecall.execute(
                 %{"search" => "timezone", "source" => "history", "scope" => "owner"},
                 context
               )

      assert history_only.success == true
      assert history_only.output =~ "[history"
      refute history_only.output =~ "[memories"
    end

    test "returns a graceful error for malformed FTS queries", %{
      context: context,
      conv_key: conv_key,
      store: store
    } do
      Store.store(conv_key, "timezone", "UTC", server: store)

      assert {:ok, result} = MemoryRecall.execute(%{"search" => "AND OR"}, context)
      assert result.success == false
      assert result.error != nil
    end

    test "prefers lexical search when key and search are both present", %{
      context: context,
      conv_key: conv_key,
      store: store
    } do
      Store.store(conv_key, "timezone", "UTC", server: store)

      assert {:ok, result} =
               MemoryRecall.execute(%{"key" => "timezone", "search" => "timezone"}, context)

      assert result.success == true
      assert result.output =~ "[memories"
      refute result.output == "UTC"
    end
  end

  describe "telemetry" do
    test "emits [:fermix, :tool, :exec] on success", %{
      context: context,
      conv_key: conv_key,
      store: store
    } do
      handler_id = attach_telemetry()
      Store.store(conv_key, "k", "v", server: store)

      MemoryRecall.execute(%{"key" => "k"}, context)

      assert_receive {:telemetry, [:fermix, :tool, :exec], measurements, metadata}
      assert is_integer(measurements.duration_ms)
      assert measurements.duration_ms >= 0
      assert metadata.tool == "memory_recall"
      assert metadata.agent == "test_agent"
      assert metadata.success == true

      :telemetry.detach(handler_id)
    end

    test "emits [:fermix, :tool, :exec] on not found", %{context: context} do
      handler_id = attach_telemetry()

      MemoryRecall.execute(%{"key" => "missing"}, context)

      assert_receive {:telemetry, [:fermix, :tool, :exec], measurements, metadata}
      assert is_integer(measurements.duration_ms)
      assert metadata.tool == "memory_recall"
      assert metadata.success == false

      :telemetry.detach(handler_id)
    end
  end

  defp attach_telemetry do
    handler_id = "test-memory-recall-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:fermix, :tool, :exec],
      fn event, measurements, metadata, _config ->
        if metadata.tool == "memory_recall" do
          send(test_pid, {:telemetry, event, measurements, metadata})
        end
      end,
      nil
    )

    handler_id
  end
end
