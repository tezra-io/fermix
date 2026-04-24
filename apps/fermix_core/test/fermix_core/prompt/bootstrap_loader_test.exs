defmodule FermixCore.Prompt.BootstrapLoaderTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Memory.Repo
  alias FermixCore.Prompt.BootstrapLoader
  alias FermixCore.Prompt.Seeder
  alias FermixCore.Resource.Registry

  setup do
    unique = unique()
    repo_name = :"bootstrap_loader_repo_#{unique}"
    db_path = Path.join(System.tmp_dir!(), "fermix-bootstrap-loader-#{unique}.db")
    previous_config = Application.get_env(:fermix_core, :prompt_bootstrap, [])
    base_dir = Path.join(System.tmp_dir!(), "fermix-bootstrap-loader-#{unique}")

    Application.put_env(:fermix_core, :prompt_bootstrap,
      bootstrap_dir: base_dir,
      seed_agent_file: false
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

  test "load/1 returns present AGENTS.md and SOUL.md with metadata", %{agent_id: agent_id} do
    File.mkdir_p!(Seeder.agent_dir(agent_id))
    File.write!(Seeder.agents_path(agent_id), "agent instructions")
    File.write!(Seeder.soul_path(agent_id), "calm voice")

    assert {:ok, result} = BootstrapLoader.load(agent_id)
    assert result.agents.content == "agent instructions"
    assert result.agents.path == Seeder.agents_path(agent_id)
    assert result.agents.status == :present
    assert result.agents.approx_size == byte_size("agent instructions")
    assert result.agents.approx_tokens == 5

    assert result.soul.content == "calm voice"
    assert result.soul.path == Seeder.soul_path(agent_id)
    assert result.soul.status == :present
  end

  test "load/1 falls back for missing AGENTS.md and omits missing SOUL.md", %{
    agent_id: agent_id
  } do
    assert {:ok, result} = BootstrapLoader.load(agent_id)
    assert result.agents.content =~ "You are a helpful AI assistant"
    assert result.agents.path == Seeder.agents_path(agent_id)
    assert result.agents.status == :fallback
    assert result.agents.approx_size > 0
    assert result.agents.approx_tokens > 0
    assert result.soul == nil
  end

  test "load/1 treats empty AGENTS.md and SOUL.md as not present", %{agent_id: agent_id} do
    File.mkdir_p!(Seeder.agent_dir(agent_id))
    File.write!(Seeder.agents_path(agent_id), " \n\n")
    File.write!(Seeder.soul_path(agent_id), "")

    assert {:ok, result} = BootstrapLoader.load(agent_id)
    assert result.agents.content =~ "You are a helpful AI assistant"
    assert result.agents.status == :fallback
    assert result.soul == nil
  end

  test "load/1 seeds default AGENTS.md when enabled", %{agent_id: agent_id} do
    previous_config = Application.get_env(:fermix_core, :prompt_bootstrap, [])

    Application.put_env(
      :fermix_core,
      :prompt_bootstrap,
      Keyword.put(previous_config, :seed_agent_file, true)
    )

    assert {:ok, result} = BootstrapLoader.load(agent_id)
    assert result.agents.status == :present
    assert File.read!(Seeder.agents_path(agent_id)) == result.agents.content
  end

  test "load/1 falls back when seeding cannot write AGENTS.md", %{
    agent_id: agent_id,
    base_dir: base_dir
  } do
    File.mkdir_p!(base_dir)
    blocking_path = Path.join(base_dir, "not-a-directory")
    File.write!(blocking_path, "block mkdir_p")

    previous_config = Application.get_env(:fermix_core, :prompt_bootstrap, [])

    Application.put_env(:fermix_core, :prompt_bootstrap,
      bootstrap_dir: blocking_path,
      seed_agent_file: true
    )

    log =
      capture_log(fn ->
        assert {:ok, result} = BootstrapLoader.load(agent_id)
        assert result.agents.content =~ "You are a helpful AI assistant"
        assert result.agents.status == :fallback
        assert result.soul == nil
      end)

    assert log =~ "prompt bootstrap seed failed for main"
    Application.put_env(:fermix_core, :prompt_bootstrap, previous_config)
  end

  test "load/1 imports pre-existing bootstrap files and dedupes unchanged reloads", %{
    agent_id: agent_id,
    repo: repo
  } do
    File.mkdir_p!(Seeder.agent_dir(agent_id))
    File.write!(Seeder.agents_path(agent_id), "agent instructions")
    File.write!(Seeder.soul_path(agent_id), "soul identity")

    assert {:ok, _result} = BootstrapLoader.load(agent_id, repo: repo)
    assert {:ok, _result} = BootstrapLoader.load(agent_id, repo: repo)

    assert {:ok, [agents]} = Registry.list_revisions(agent_id, :agents_md, "global", repo: repo)
    assert agents.mutation_source == "imported"
    assert agents.content == "agent instructions"

    assert {:ok, [soul]} = Registry.list_revisions(agent_id, :soul_md, "global", repo: repo)
    assert soul.mutation_source == "imported"
    assert soul.content == "soul identity"
  end

  test "load/1 records edited bootstrap files as manual revisions", %{
    agent_id: agent_id,
    repo: repo
  } do
    File.mkdir_p!(Seeder.agent_dir(agent_id))
    File.write!(Seeder.agents_path(agent_id), "agent instructions")

    assert {:ok, _result} = BootstrapLoader.load(agent_id, repo: repo)

    File.write!(Seeder.agents_path(agent_id), "updated agent instructions")
    assert {:ok, _result} = BootstrapLoader.load(agent_id, repo: repo)

    assert {:ok, [latest, imported]} =
             Registry.list_revisions(agent_id, :agents_md, "global", repo: repo)

    assert latest.mutation_source == "manual_edit"
    assert latest.content == "updated agent instructions"
    assert imported.mutation_source == "imported"
  end

  test "load/1 rejects agent IDs that can escape the bootstrap directory" do
    assert {:error, {:invalid_agent_id, "../../etc"}} = BootstrapLoader.load("../../etc")
  end

  defp unique do
    System.unique_integer([:positive, :monotonic])
  end
end
