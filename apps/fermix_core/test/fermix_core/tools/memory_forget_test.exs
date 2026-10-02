defmodule FermixCore.Tools.MemoryForgetTest do
  # async: false — forgetting republishes prompt files, whose directory and
  # repo come from the global `:fermix_core, :memory` app env.
  use ExUnit.Case, async: false

  alias FermixCore.Memory.PromptFiles
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Store
  alias FermixCore.Tools.MemoryForget
  alias FermixCore.Tools.MemoryRecall
  alias FermixCore.Tools.MemoryStore

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-memory-forget-tool-#{unique}.db")
    prompt_dir = Path.join(System.tmp_dir!(), "fermix-memory-forget-tool-prompt-#{unique}")
    repo = :"mem_forget_tool_repo_#{unique}"
    store = :"mem_forget_tool_store_#{unique}"
    previous_config = Application.get_env(:fermix_core, :memory, [])

    Application.put_env(
      :fermix_core,
      :memory,
      Keyword.merge(previous_config,
        enabled: true,
        repo: repo,
        database_path: db_path,
        prompt_base_dir: prompt_dir
      )
    )

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})
    start_supervised!(%{id: store, start: {Store, :start_link, [[name: store, repo: repo]]}})

    on_exit(fn ->
      Application.put_env(:fermix_core, :memory, previous_config)
      FermixTestSupport.SafeRm.rm_rf!(prompt_dir)

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    context = %{
      agent_name: "test_agent",
      conversation_key: {"telegram", "chat_#{unique}"},
      memory_store: store,
      memory_repo: repo,
      memory_agent_id: "main",
      memory_owner_id: "default",
      source_trust: :operator,
      # No main agent in this test: invalidation is best-effort and must not
      # reach the application's own.
      main_agent_server: :"no_main_agent_#{unique}"
    }

    %{context: context, repo: repo}
  end

  test "declares itself" do
    assert MemoryForget.name() == "memory_forget"
    assert MemoryForget.category() == :memory
    assert MemoryForget.parameters().required == ["id"]
  end

  test "the id recall shows is the id forget takes, and the fact is gone everywhere", %{
    context: context
  } do
    save = fn key, value ->
      MemoryStore.execute(%{"key" => key, "value" => value, "category" => "identity"}, context)
    end

    assert {:ok, %{success: true}} = save.("city", "Lives in Lisbon")
    assert {:ok, %{success: true}} = save.("diet", "Is vegetarian")

    assert {:ok, found} =
             MemoryRecall.execute(%{"search" => "vegetarian", "scope" => "owner"}, context)

    assert [_whole, id] =
             Regex.run(~r/\[memories rank=[^\]]+\] id=(\d+) scope=owner/, found.output)

    assert {:ok, result} = MemoryForget.execute(%{"id" => String.to_integer(id)}, context)
    assert result.success == true
    assert result.output =~ "Forgotten: id=#{id} (identity)"
    assert result.output =~ "archived rather than erased"

    assert {:ok, %{user: "## Identity\n- Lives in Lisbon"}} = PromptFiles.load("main")

    assert {:ok, %{output: after_forget}} =
             MemoryRecall.execute(%{"search" => "vegetarian", "scope" => "all"}, context)

    assert after_forget =~ "No lexical matches"
  end

  test "a conversation note is forgotten too, and its key no longer recalls", %{
    context: context
  } do
    assert {:ok, %{success: true}} =
             MemoryStore.execute(%{"key" => "draft_title", "value" => "Q3 plan"}, context)

    assert {:ok, %{output: "Q3 plan"}} = MemoryRecall.execute(%{"key" => "draft_title"}, context)

    assert {:ok, found} = MemoryRecall.execute(%{"search" => "plan"}, context)
    assert [_whole, id] = Regex.run(~r/ id=(\d+) scope=conversation/, found.output)

    assert {:ok, %{success: true, output: output}} =
             MemoryForget.execute(%{"id" => id, "reason" => "done with it"}, context)

    refute output =~ "next turn"

    assert {:ok, %{success: false, error: error}} =
             MemoryRecall.execute(%{"key" => "draft_title"}, context)

    assert error =~ "No memory found for key"
  end

  test "an unknown or missing id is an error", %{context: context} do
    assert {:ok, %{success: false, error: missing}} = MemoryForget.execute(%{}, context)
    assert missing =~ "id, a positive integer"

    assert {:ok, %{success: false, error: unknown}} =
             MemoryForget.execute(%{"id" => 424_242}, context)

    assert unknown =~ "No memory has that id"
  end

  test "emits one tool exec event under its own name", %{context: context} do
    test_pid = self()
    handler_id = "test-memory-forget-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:fermix, :tool, :exec],
      fn _event, _measurements, metadata, _config ->
        if self() == test_pid and metadata.tool == "memory_forget" do
          send(test_pid, {:tool_exec, metadata})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    MemoryForget.execute(%{"id" => 424_242}, context)

    assert_receive {:tool_exec, %{tool: "memory_forget", success: false}}
    refute_receive {:tool_exec, _metadata}, 50
  end
end
