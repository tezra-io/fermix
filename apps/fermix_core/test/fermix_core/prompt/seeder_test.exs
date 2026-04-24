defmodule FermixCore.Prompt.SeederTest do
  use ExUnit.Case, async: false

  alias FermixCore.Memory.Repo
  alias FermixCore.Prompt.Seeder
  alias FermixCore.Resource.Registry

  setup do
    unique = unique()
    repo_name = :"prompt_seeder_repo_#{unique}"
    db_path = Path.join(System.tmp_dir!(), "fermix-prompt-seeder-#{unique}.db")
    previous_config = Application.get_env(:fermix_core, :prompt_bootstrap, [])
    base_dir = Path.join(System.tmp_dir!(), "fermix-prompt-seeder-#{unique}")

    Application.put_env(:fermix_core, :prompt_bootstrap,
      bootstrap_dir: base_dir,
      seed_agent_file: true
    )

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Application.put_env(:fermix_core, :prompt_bootstrap, previous_config)
      File.rm_rf!(base_dir)

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        File.rm(path)
      end)
    end)

    %{agent_id: "main", base_dir: base_dir, repo: repo_name}
  end

  test "paths resolve under the configured bootstrap directory", %{
    agent_id: agent_id,
    base_dir: base_dir
  } do
    assert Seeder.agent_dir(agent_id) == Path.join(base_dir, agent_id)
    assert Seeder.agents_path(agent_id) == Path.join([base_dir, agent_id, "AGENTS.md"])
    assert Seeder.soul_path(agent_id) == Path.join([base_dir, agent_id, "SOUL.md"])
  end

  test "ensure_seeded/1 creates default AGENTS.md and leaves SOUL.md absent", %{
    agent_id: agent_id,
    repo: repo
  } do
    assert {:ok, result} = Seeder.ensure_seeded(agent_id, repo: repo)
    assert result.agents.path == Seeder.agents_path(agent_id)
    assert result.agents.approx_size > 0
    assert result.agents.approx_tokens > 0
    assert result.soul == nil

    assert File.read!(Seeder.agents_path(agent_id)) =~ "You are a helpful AI assistant"
    refute File.exists?(Seeder.soul_path(agent_id))

    assert {:ok, [revision]} = Registry.list_revisions(agent_id, :agents_md, "global", repo: repo)
    assert revision.mutation_source == "seed"
    assert revision.content == result.agents.content
  end

  test "default AGENTS.md keeps the old stable operating prompt semantics" do
    content = Seeder.default_agents_content()

    assert content =~ "You are a helpful AI assistant with access to tools."
    assert content =~ "execute shell commands, read and write files, and store/recall memories"
    assert content =~ "When you need to perform an action, use the appropriate tool."
    assert content =~ "Think step by step."
  end

  test "ensure_seeded/1 does not overwrite an existing AGENTS.md", %{agent_id: agent_id} do
    File.mkdir_p!(Seeder.agent_dir(agent_id))
    File.write!(Seeder.agents_path(agent_id), "custom instructions")

    assert {:ok, result} = Seeder.ensure_seeded(agent_id)
    assert result.agents.content == "custom instructions"
    assert File.read!(Seeder.agents_path(agent_id)) == "custom instructions"
  end

  test "ensure_seeded/1 rejects agent IDs that can escape the bootstrap directory" do
    assert {:error, {:invalid_agent_id, "../main"}} = Seeder.ensure_seeded("../main")

    assert_raise ArgumentError, ~r/invalid agent_id/, fn ->
      Seeder.agent_dir("../main")
    end
  end

  defp unique do
    System.unique_integer([:positive, :monotonic])
  end
end
