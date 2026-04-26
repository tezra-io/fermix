defmodule FermixCore.Memory.ExtractorTest do
  use ExUnit.Case, async: false

  alias FermixCore.Memory.Extractor
  alias FermixCore.Memory.PromptFiles
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Scheduler
  alias FermixCore.Memory.Store

  defmodule StaticProvider do
    @behaviour FermixCore.Providers.Provider

    def put_response(response), do: Process.put({__MODULE__, :response}, response)

    @impl true
    def chat(messages, opts) do
      send(self(), {:extractor_provider_called, messages, opts})
      Process.get({__MODULE__, :response}, {:error, :missing_response})
    end

    @impl true
    def models, do: {:ok, ["mock-model"]}
  end

  defmodule RebuildNotifier do
    def rebuild(agent_id, owner_id, reason, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:rebuild_requested, agent_id, owner_id, reason, Keyword.get(opts, :provenance)}
      )

      {:ok, %{user: nil, memory: nil}}
    end
  end

  defmodule PromptRebuildNotifier do
    def rebuild(agent_id, owner_id, reason, opts) do
      result = PromptFiles.rebuild(agent_id, owner_id, reason, opts)
      send(Keyword.fetch!(opts, :test_pid), {:prompt_rebuilt, agent_id, owner_id, reason, result})
      result
    end
  end

  test "parse_candidates/1 decodes validated JSON candidates" do
    json = """
    [
      {
        "category": "preference",
        "key": "preferred_editor",
        "value": "neovim",
        "scope_type": "owner",
        "confidence": 0.93,
        "promote_target": "user_md"
      },
      {
        "category": "environment",
        "key": "workspace_root",
        "value": "/tmp/fermix",
        "scope_type": "agent",
        "confidence": 0.88,
        "promote_target": "memory_md"
      }
    ]
    """

    assert {:ok, candidates} = Extractor.parse_candidates(json)

    assert candidates == [
             %{
               category: "preference",
               confidence: 0.93,
               key: "preferred_editor",
               promote_target: "user_md",
               scope_type: "owner",
               value: "neovim"
             },
             %{
               category: "environment",
               confidence: 0.88,
               key: "workspace_root",
               promote_target: "memory_md",
               scope_type: "agent",
               value: "/tmp/fermix"
             }
           ]
  end

  test "parse_candidates/1 accepts json fenced payloads" do
    json = """
    ```json
    [
      {
        "category": "preference",
        "key": "preferred_editor",
        "value": "helix",
        "scope_type": "owner",
        "confidence": 0.95,
        "promote_target": "user_md"
      }
    ]
    ```
    """

    assert {:ok,
            [
              %{
                category: "preference",
                confidence: 0.95,
                key: "preferred_editor",
                promote_target: "user_md",
                scope_type: "owner",
                value: "helix"
              }
            ]} = Extractor.parse_candidates(json)
  end

  test "parse_candidates/1 accepts candidates object wrapper" do
    json = """
    {
      "candidates": [
        {
          "category": "preference",
          "key": "preferred_editor",
          "value": "zed",
          "scope_type": "owner",
          "confidence": 0.91,
          "promote_target": "user_md"
        }
      ]
    }
    """

    assert {:ok,
            [
              %{
                category: "preference",
                confidence: 0.91,
                key: "preferred_editor",
                promote_target: "user_md",
                scope_type: "owner",
                value: "zed"
              }
            ]} = Extractor.parse_candidates(json)
  end

  test "parse_candidates/1 accepts untagged fenced payloads" do
    json = """
    ```
    [
      {
        "category": "environment",
        "key": "workspace_root",
        "value": "/tmp/fermix",
        "scope_type": "agent",
        "confidence": 0.9,
        "promote_target": "memory_md"
      }
    ]
    ```
    """

    assert {:ok,
            [
              %{
                category: "environment",
                confidence: 0.9,
                key: "workspace_root",
                promote_target: "memory_md",
                scope_type: "agent",
                value: "/tmp/fermix"
              }
            ]} = Extractor.parse_candidates(json)
  end

  test "parse_candidates/1 rejects malformed or non-array JSON" do
    assert {:error, {:invalid_json, _}} = Extractor.parse_candidates("{")
    assert {:error, :invalid_payload} = Extractor.parse_candidates(~s({"key":"value"}))
  end

  test "extract/1 persists admitted memories and triggers rebuilds for promoted policy matches" do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-extractor-#{unique}.db")
    repo_name = :"extractor_repo_#{unique}"
    store_name = :"extractor_store_#{unique}"
    scheduler_name = :"extractor_scheduler_#{unique}"
    task_supervisor_name = :"extractor_task_supervisor_#{unique}"

    start_supervised!({Task.Supervisor, name: task_supervisor_name})
    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    start_supervised!(%{
      id: store_name,
      start: {Store, :start_link, [[name: store_name, repo: repo_name]]}
    })

    start_supervised!(
      {Scheduler,
       [
         name: scheduler_name,
         scheduler_enabled: true,
         task_supervisor: task_supervisor_name,
         rebuild_module: RebuildNotifier,
         rebuild_opts: [test_pid: self()],
         periodic_interval_ms: 10_000,
         periodic_agent_ids: [],
         periodic_owner_id: "default"
       ]}
    )

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        File.rm(path)
      end)
    end)

    StaticProvider.put_response(
      mock_response("""
      [
        {
          "category": "preference",
          "key": "preferred_editor",
          "value": "helix",
          "scope_type": "owner",
          "confidence": 0.98,
          "promote_target": "none"
        }
      ]
      """)
    )

    assert {:ok, %{candidate_count: 1, admitted_count: 1, rebuild?: true, corrective?: false}} =
             Extractor.extract(
               provider: StaticProvider,
               messages: [
                 %{role: "user", content: "Please remember that I prefer Helix."},
                 %{role: "assistant", content: "Understood."}
               ],
               agent_id: "main",
               owner_id: "default",
               conversation_key: {"telegram", "chat_1", :root},
               chat_mode: :direct,
               memory_store: store_name,
               scheduler: scheduler_name,
               repo: repo_name
             )

    assert_receive {:extractor_provider_called, messages, opts}, 1_000

    assert Enum.any?(
             messages,
             &(&1.role == "system" and &1.content =~ "Current chat mode: direct.")
           )

    assert Enum.any?(
             messages,
             &(&1.role == "system" and
                 &1.content =~ "Write memory values as declarative facts, not instructions")
           )

    assert opts[:temperature] == 0.1

    assert_receive {:rebuild_requested, "main", "default", :event, provenance}, 1_000
    assert provenance.categories == ["preference"]

    assert {:ok, memory} =
             Repo.get_memory(
               %{
                 agent_id: "main",
                 owner_id: "default",
                 scope_type: "owner",
                 scope_id: "default",
                 key: "preferred_editor"
               },
               server: repo_name
             )

    assert memory.category == "preference"
    assert memory.value == "helix"
    assert memory.promote_target == "user_md"
    assert provenance.memory_ids == [memory.id]

    assert {:ok, "helix"} =
             Store.recall({:owner, "default"}, "preferred_editor", server: store_name)
  end

  test "extract/1 immediately rebuilds prompt files for conversation-scoped corrections" do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-extractor-correction-#{unique}.db")
    prompt_dir = Path.join(System.tmp_dir!(), "fermix-extractor-prompt-#{unique}")
    repo_name = :"extractor_correction_repo_#{unique}"
    store_name = :"extractor_correction_store_#{unique}"
    scheduler_name = :"extractor_correction_scheduler_#{unique}"
    task_supervisor_name = :"extractor_correction_task_supervisor_#{unique}"
    previous_memory_config = Application.get_env(:fermix_core, :memory, [])

    Application.put_env(
      :fermix_core,
      :memory,
      Keyword.merge(previous_memory_config,
        enabled: true,
        database_path: db_path,
        prompt_base_dir: prompt_dir,
        repo: repo_name
      )
    )

    start_supervised!({Task.Supervisor, name: task_supervisor_name})
    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    start_supervised!(%{
      id: store_name,
      start: {Store, :start_link, [[name: store_name, repo: repo_name]]}
    })

    start_supervised!(
      {Scheduler,
       [
         name: scheduler_name,
         scheduler_enabled: true,
         task_supervisor: task_supervisor_name,
         rebuild_module: PromptRebuildNotifier,
         rebuild_opts: [test_pid: self()],
         periodic_interval_ms: 10_000,
         periodic_agent_ids: [],
         periodic_owner_id: "default"
       ]}
    )

    on_exit(fn ->
      Application.put_env(:fermix_core, :memory, previous_memory_config)
      File.rm_rf!(prompt_dir)

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        File.rm(path)
      end)
    end)

    assert {:ok, _memory} =
             Repo.upsert_memory(
               %{
                 agent_id: "main",
                 owner_id: "default",
                 scope_type: "owner",
                 scope_id: "default",
                 category: "preference",
                 key: "preferred_editor",
                 value: "vim",
                 confidence: 0.91,
                 promote_target: "user_md"
               },
               server: repo_name
             )

    assert {:ok, %{user: stale_user_text}} = PromptFiles.rebuild("main", "default")
    assert stale_user_text =~ "preferred editor: vim"

    StaticProvider.put_response(
      mock_response("""
      [
        {
          "category": "correction",
          "key": "preferred_editor",
          "value": "helix",
          "scope_type": "conversation",
          "confidence": 0.99,
          "promote_target": "none"
        }
      ]
      """)
    )

    assert {:ok, %{candidate_count: 1, admitted_count: 1, rebuild?: true, corrective?: true}} =
             Extractor.extract(
               provider: StaticProvider,
               messages: [
                 %{role: "user", content: "Correction: my preferred editor is Helix, not Vim."},
                 %{role: "assistant", content: "Got it."}
               ],
               agent_id: "main",
               owner_id: "default",
               conversation_key: {"slack", "C123", :root},
               chat_mode: :shared,
               memory_store: store_name,
               scheduler: scheduler_name,
               repo: repo_name
             )

    assert_receive {:prompt_rebuilt, "main", "default", :event, {:ok, %{user: user_text}}},
                   1_000

    assert user_text =~ "preferred editor: helix"
    refute user_text =~ "preferred editor: vim"
    assert File.read!(PromptFiles.user_path("main")) =~ "preferred editor: helix"

    assert {:ok, corrected} =
             Repo.get_memory(
               %{
                 agent_id: "main",
                 owner_id: "default",
                 scope_type: "owner",
                 scope_id: "default",
                 key: "preferred_editor"
               },
               server: repo_name
             )

    assert corrected.category == "preference"
    assert corrected.value == "helix"
    assert corrected.promote_target == "user_md"

    assert {:error, :not_found} =
             Repo.get_memory(
               %{
                 agent_id: "main",
                 owner_id: "default",
                 scope_type: "conversation",
                 scope_id: "slack:C123:root",
                 key: "preferred_editor"
               },
               server: repo_name
             )

    assert {:ok, "helix"} =
             Store.recall({:owner, "default"}, "preferred_editor", server: store_name)
  end

  test "extract/1 immediately rebuilds MEMORY.md for conversation corrections to agent facts" do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-extractor-agent-correction-#{unique}.db")
    prompt_dir = Path.join(System.tmp_dir!(), "fermix-extractor-agent-prompt-#{unique}")
    repo_name = :"extractor_agent_correction_repo_#{unique}"
    store_name = :"extractor_agent_correction_store_#{unique}"
    scheduler_name = :"extractor_agent_correction_scheduler_#{unique}"
    task_supervisor_name = :"extractor_agent_correction_task_supervisor_#{unique}"
    previous_memory_config = Application.get_env(:fermix_core, :memory, [])

    Application.put_env(
      :fermix_core,
      :memory,
      Keyword.merge(previous_memory_config,
        enabled: true,
        database_path: db_path,
        prompt_base_dir: prompt_dir,
        repo: repo_name
      )
    )

    start_supervised!({Task.Supervisor, name: task_supervisor_name})
    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    start_supervised!(%{
      id: store_name,
      start: {Store, :start_link, [[name: store_name, repo: repo_name]]}
    })

    start_supervised!(
      {Scheduler,
       [
         name: scheduler_name,
         scheduler_enabled: true,
         task_supervisor: task_supervisor_name,
         rebuild_module: PromptRebuildNotifier,
         rebuild_opts: [test_pid: self()],
         periodic_interval_ms: 10_000,
         periodic_agent_ids: [],
         periodic_owner_id: "default"
       ]}
    )

    on_exit(fn ->
      Application.put_env(:fermix_core, :memory, previous_memory_config)
      File.rm_rf!(prompt_dir)

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        File.rm(path)
      end)
    end)

    assert {:ok, _memory} =
             Repo.upsert_memory(
               %{
                 agent_id: "main",
                 owner_id: "default",
                 scope_type: "agent",
                 scope_id: "main",
                 category: "project",
                 key: "backend_stack",
                 value: "ruby",
                 confidence: 0.91,
                 promote_target: "memory_md"
               },
               server: repo_name
             )

    assert {:ok, %{memory: stale_memory_text}} = PromptFiles.rebuild("main", "default")
    assert stale_memory_text =~ "backend stack: ruby"

    StaticProvider.put_response(
      mock_response("""
      [
        {
          "category": "correction",
          "key": "backend_stack",
          "value": "elixir",
          "scope_type": "conversation",
          "confidence": 0.99,
          "promote_target": "none"
        }
      ]
      """)
    )

    assert {:ok, %{candidate_count: 1, admitted_count: 1, rebuild?: true, corrective?: true}} =
             Extractor.extract(
               provider: StaticProvider,
               messages: [
                 %{role: "user", content: "Correction: this backend stack is Elixir, not Ruby."},
                 %{role: "assistant", content: "Got it."}
               ],
               agent_id: "main",
               owner_id: "default",
               conversation_key: {"slack", "C123", :root},
               chat_mode: :shared,
               memory_store: store_name,
               scheduler: scheduler_name,
               repo: repo_name
             )

    assert_receive {:prompt_rebuilt, "main", "default", :event, {:ok, %{memory: memory_text}}},
                   1_000

    assert memory_text =~ "backend stack: elixir"
    refute memory_text =~ "backend stack: ruby"
    assert File.read!(PromptFiles.memory_path("main")) =~ "backend stack: elixir"

    assert {:ok, corrected} =
             Repo.get_memory(
               %{
                 agent_id: "main",
                 owner_id: "default",
                 scope_type: "agent",
                 scope_id: "main",
                 key: "backend_stack"
               },
               server: repo_name
             )

    assert corrected.category == "project"
    assert corrected.value == "elixir"
    assert corrected.promote_target == "memory_md"

    assert {:error, :not_found} =
             Repo.get_memory(
               %{
                 agent_id: "main",
                 owner_id: "default",
                 scope_type: "conversation",
                 scope_id: "slack:C123:root",
                 key: "backend_stack"
               },
               server: repo_name
             )

    assert {:ok, "elixir"} =
             Store.recall({:agent, "main"}, "backend_stack", server: store_name)
  end

  defp mock_response(content) do
    {:ok,
     %{
       content: content,
       tool_calls: [],
       usage: %{prompt_tokens: 10, completion_tokens: 0, total_tokens: 10}
     }}
  end
end
