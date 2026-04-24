defmodule FermixCore.Memory.PromptFilesTest do
  use ExUnit.Case, async: false

  alias FermixCore.Memory.PromptFiles
  alias FermixCore.Memory.Repo

  setup do
    unique = System.unique_integer([:positive])
    repo_name = :"prompt_files_repo_#{unique}"
    base_dir = Path.join(System.tmp_dir!(), "fermix-prompt-files-#{unique}")
    db_path = Path.join(System.tmp_dir!(), "fermix-prompt-files-#{unique}.db")
    previous_config = Application.get_env(:fermix_core, :memory, [])

    Application.put_env(
      :fermix_core,
      :memory,
      Keyword.merge(previous_config,
        enabled: true,
        database_path: db_path,
        prompt_base_dir: base_dir,
        prompt_user_token_cap: 32,
        prompt_memory_token_cap: 36,
        repo: repo_name
      )
    )

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Application.put_env(:fermix_core, :memory, previous_config)
      File.rm_rf!(base_dir)

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        File.rm(path)
      end)
    end)

    %{agent_id: "main", owner_id: "default", base_dir: base_dir, repo: repo_name}
  end

  test "user_path/1 and memory_path/1 resolve under the configured prompt memory directory", %{
    agent_id: agent_id,
    base_dir: base_dir
  } do
    assert PromptFiles.user_path(agent_id) == Path.join([base_dir, agent_id, "USER.md"])
    assert PromptFiles.memory_path(agent_id) == Path.join([base_dir, agent_id, "MEMORY.md"])
  end

  test "load/1 returns nil content for missing or empty prompt files", %{agent_id: agent_id} do
    assert {:ok, %{user: nil, memory: nil}} = PromptFiles.load(agent_id)

    File.mkdir_p!(Path.dirname(PromptFiles.user_path(agent_id)))
    File.write!(PromptFiles.user_path(agent_id), "   \n")
    File.write!(PromptFiles.memory_path(agent_id), "")

    assert {:ok, %{user: nil, memory: nil}} = PromptFiles.load(agent_id)
  end

  test "rebuild/2 rewrites both files under hard caps without appending stale content", %{
    agent_id: agent_id,
    owner_id: owner_id,
    repo: repo
  } do
    insert_memory(repo, %{
      agent_id: agent_id,
      owner_id: owner_id,
      scope_type: "owner",
      scope_id: owner_id,
      category: "preference",
      key: "editing_style",
      value: String.duplicate("prefer concise answers ", 4),
      promote_target: "user_md"
    })

    insert_memory(repo, %{
      agent_id: agent_id,
      owner_id: owner_id,
      scope_type: "owner",
      scope_id: owner_id,
      category: "goal",
      key: "active_project",
      value: String.duplicate("ship durable prompt memory ", 4),
      promote_target: "user_md"
    })

    insert_memory(repo, %{
      agent_id: agent_id,
      owner_id: owner_id,
      scope_type: "agent",
      scope_id: agent_id,
      category: "project",
      key: "current_repo",
      value: String.duplicate("fermix umbrella app ", 4),
      promote_target: "memory_md"
    })

    insert_memory(repo, %{
      agent_id: agent_id,
      owner_id: owner_id,
      scope_type: "agent",
      scope_id: agent_id,
      category: "instruction",
      key: "repo_rule",
      value: String.duplicate("warnings are errors ", 4),
      promote_target: "memory_md"
    })

    File.mkdir_p!(Path.dirname(PromptFiles.user_path(agent_id)))
    File.write!(PromptFiles.user_path(agent_id), "STALE USER CONTENT")
    File.write!(PromptFiles.memory_path(agent_id), "STALE MEMORY CONTENT")

    assert {:ok, %{user: user_text, memory: memory_text}} =
             PromptFiles.rebuild(agent_id, owner_id)

    refute user_text =~ "STALE"
    refute memory_text =~ "STALE"
    assert user_text =~ "## Preferences"
    assert memory_text =~ "## Project Context"
    assert estimated_tokens(user_text) <= 32
    assert estimated_tokens(memory_text) <= 36
    refute user_text =~ "active project"
    refute memory_text =~ "repo rule"
    assert File.exists?(PromptFiles.user_path(agent_id))
    assert File.exists?(PromptFiles.memory_path(agent_id))

    assert Path.wildcard(Path.join(Path.dirname(PromptFiles.user_path(agent_id)), "*.tmp-*")) ==
             []
  end

  test "rebuild/2 returns normalized rendered content without changing file output", %{
    agent_id: agent_id,
    owner_id: owner_id,
    repo: repo
  } do
    insert_memory(repo, %{
      agent_id: agent_id,
      owner_id: owner_id,
      scope_type: "owner",
      scope_id: owner_id,
      category: "preference",
      key: "first_pref",
      value: "alpha",
      promote_target: "user_md"
    })

    insert_memory(repo, %{
      agent_id: agent_id,
      owner_id: owner_id,
      scope_type: "owner",
      scope_id: owner_id,
      category: "preference",
      key: "second_pref",
      value: "beta",
      promote_target: "user_md"
    })

    assert {:ok, %{user: user_text, memory: nil}} = PromptFiles.rebuild(agent_id, owner_id)

    assert user_text == File.read!(PromptFiles.user_path(agent_id))
    assert File.read!(PromptFiles.memory_path(agent_id)) == ""

    assert user_text == """
           ## Preferences
           - second pref: beta
           - first pref: alpha\
           """
  end

  test "rebuild/2 re-evaluates stored promotion hints under current policy", %{
    agent_id: agent_id,
    owner_id: owner_id,
    repo: repo
  } do
    insert_memory(repo, %{
      agent_id: agent_id,
      owner_id: owner_id,
      scope_type: "owner",
      scope_id: owner_id,
      category: "episode",
      key: "last_small_talk_topic",
      value: "weekend plans",
      promote_target: "user_md"
    })

    assert {:ok, %{user: user_text, memory: memory_text}} =
             PromptFiles.rebuild(agent_id, owner_id)

    assert user_text in [nil, ""]
    assert memory_text in [nil, ""]
  end

  defp insert_memory(repo, attrs) do
    assert {:ok, _memory} = Repo.upsert_memory(attrs, server: repo)
  end

  defp estimated_tokens(text) do
    div(byte_size(text) + 3, 4)
  end
end
