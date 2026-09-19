defmodule FermixCore.Prompt.BootstrapLoaderTest do
  use ExUnit.Case, async: false

  alias FermixCore.Memory.Repo
  alias FermixCore.Prompt.BootstrapLoader
  alias FermixCore.Prompt.BootstrapPaths
  alias FermixCore.Prompt.Defaults
  alias FermixCore.Resource.Registry

  setup do
    unique = unique()
    repo_name = :"bootstrap_loader_repo_#{unique}"
    db_path = Path.join(System.tmp_dir!(), "fermix-bootstrap-loader-#{unique}.db")
    previous_config = Application.get_env(:fermix_core, :prompt_bootstrap, [])
    base_dir = Path.join(System.tmp_dir!(), "fermix-bootstrap-loader-#{unique}")

    Application.put_env(:fermix_core, :prompt_bootstrap, bootstrap_dir: base_dir)

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Application.put_env(:fermix_core, :prompt_bootstrap, previous_config)
      FermixTestSupport.SafeRm.rm_rf!(base_dir)

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{agent_id: "main", base_dir: base_dir, repo: repo_name}
  end

  test "load/1 returns present IDENTITY.md, FERMIX.md, and SOUL.md with metadata", %{
    agent_id: agent_id
  } do
    File.mkdir_p!(BootstrapPaths.agent_dir(agent_id))
    File.write!(BootstrapPaths.identity_path(agent_id), "i am aira")
    File.write!(BootstrapPaths.fermix_path(agent_id), "agent instructions")
    File.write!(BootstrapPaths.soul_path(agent_id), "calm voice")

    assert {:ok, result} = BootstrapLoader.load(agent_id)

    assert result.identity.content == "i am aira"
    assert result.identity.path == BootstrapPaths.identity_path(agent_id)
    assert result.identity.status == :present

    assert result.fermix.content == "agent instructions"
    assert result.fermix.path == BootstrapPaths.fermix_path(agent_id)
    assert result.fermix.status == :present
    assert result.fermix.approx_size == byte_size("agent instructions")
    assert result.fermix.approx_tokens == 5

    assert result.soul.content == "calm voice"
    assert result.soul.path == BootstrapPaths.soul_path(agent_id)
    assert result.soul.status == :present
  end

  test "load/1 falls back for missing IDENTITY.md and FERMIX.md, omits missing SOUL.md", %{
    agent_id: agent_id
  } do
    assert {:ok, result} = BootstrapLoader.load(agent_id)

    assert result.identity.content == Defaults.identity_md()
    assert result.identity.path == BootstrapPaths.identity_path(agent_id)
    assert result.identity.status == :fallback
    assert result.identity.approx_size > 0
    assert result.identity.approx_tokens > 0

    assert result.fermix.content == Defaults.fermix_md()
    assert result.fermix.path == BootstrapPaths.fermix_path(agent_id)
    assert result.fermix.status == :fallback
    assert result.fermix.approx_size > 0
    assert result.fermix.approx_tokens > 0

    assert result.soul == nil
  end

  test "load/1 treats empty IDENTITY.md, FERMIX.md, and SOUL.md as not present", %{
    agent_id: agent_id
  } do
    File.mkdir_p!(BootstrapPaths.agent_dir(agent_id))
    File.write!(BootstrapPaths.identity_path(agent_id), "")
    File.write!(BootstrapPaths.fermix_path(agent_id), " \n\n")
    File.write!(BootstrapPaths.soul_path(agent_id), "")

    assert {:ok, result} = BootstrapLoader.load(agent_id)
    assert result.identity.content == Defaults.identity_md()
    assert result.identity.status == :fallback
    assert result.fermix.content == Defaults.fermix_md()
    assert result.fermix.status == :fallback
    assert result.soul == nil
  end

  test "load/1 imports pre-existing bootstrap files and dedupes unchanged reloads", %{
    agent_id: agent_id,
    repo: repo
  } do
    File.mkdir_p!(BootstrapPaths.agent_dir(agent_id))
    File.write!(BootstrapPaths.identity_path(agent_id), "identity body")
    File.write!(BootstrapPaths.fermix_path(agent_id), "agent instructions")
    File.write!(BootstrapPaths.soul_path(agent_id), "soul identity")

    assert {:ok, _result} = BootstrapLoader.load(agent_id, repo: repo)
    assert {:ok, _result} = BootstrapLoader.load(agent_id, repo: repo)

    assert {:ok, [identity]} =
             Registry.list_revisions(agent_id, :identity_md, "global", repo: repo)

    assert identity.mutation_source == "imported"
    assert identity.content == "identity body"

    assert {:ok, [fermix]} = Registry.list_revisions(agent_id, :fermix_md, "global", repo: repo)
    assert fermix.mutation_source == "imported"
    assert fermix.content == "agent instructions"

    assert {:ok, [soul]} = Registry.list_revisions(agent_id, :soul_md, "global", repo: repo)
    assert soul.mutation_source == "imported"
    assert soul.content == "soul identity"
  end

  test "load/1 records edited bootstrap files as manual revisions", %{
    agent_id: agent_id,
    repo: repo
  } do
    File.mkdir_p!(BootstrapPaths.agent_dir(agent_id))
    File.write!(BootstrapPaths.fermix_path(agent_id), "agent instructions")

    assert {:ok, _result} = BootstrapLoader.load(agent_id, repo: repo)

    File.write!(BootstrapPaths.fermix_path(agent_id), "updated agent instructions")
    assert {:ok, _result} = BootstrapLoader.load(agent_id, repo: repo)

    assert {:ok, [latest, imported]} =
             Registry.list_revisions(agent_id, :fermix_md, "global", repo: repo)

    assert latest.mutation_source == "manual_edit"
    assert latest.content == "updated agent instructions"
    assert imported.mutation_source == "imported"
  end

  test "load/1 rejects agent IDs that can escape the bootstrap directory" do
    assert {:error, {:invalid_agent_id, "../../etc"}} = BootstrapLoader.load("../../etc")
  end

  test "load_live/2 prefers the installed LIVE.md and captures a revision", %{
    agent_id: agent_id,
    repo: repo
  } do
    File.mkdir_p!(BootstrapPaths.agent_dir(agent_id))
    File.write!(BootstrapPaths.live_path(agent_id), "operator live rules")

    assert {:ok, file} = BootstrapLoader.load_live(agent_id, repo: repo)

    assert file.name == :live
    assert file.path == BootstrapPaths.live_path(agent_id)
    assert file.content == "operator live rules"
    assert file.status == :present
    assert file.approx_size == byte_size("operator live rules")

    assert {:ok, [revision]} = Registry.list_revisions(agent_id, :live_md, "global", repo: repo)
    assert revision.mutation_source == "imported"
    assert revision.content == "operator live rules"
  end

  test "load_live/2 falls back to the shipped template when LIVE.md is missing", %{
    agent_id: agent_id,
    repo: repo
  } do
    assert {:ok, file} = BootstrapLoader.load_live(agent_id, repo: repo)

    assert file.content == Defaults.live_md()
    assert file.status == :fallback
    assert {:error, :not_found} = Registry.current_hash(agent_id, :live_md, "global", repo: repo)
  end

  test "load_live/2 rejects agent IDs that can escape the bootstrap directory" do
    assert {:error, {:invalid_agent_id, "../../etc"}} = BootstrapLoader.load_live("../../etc")
  end

  # LIVE.md is the Live voice frontend's prompt (M41 §6.1) and must never reach
  # a Core text prompt, so it is deliberately absent from `load/2`'s map.
  test "load/2 never returns LIVE.md", %{agent_id: agent_id} do
    File.mkdir_p!(BootstrapPaths.agent_dir(agent_id))
    File.write!(BootstrapPaths.live_path(agent_id), "operator live rules")

    assert {:ok, result} = BootstrapLoader.load(agent_id, realtime?: true)
    refute Map.has_key?(result, :live)
  end

  defp unique do
    System.unique_integer([:positive, :monotonic])
  end
end
