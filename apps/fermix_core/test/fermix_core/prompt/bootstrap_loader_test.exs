defmodule FermixCore.Prompt.BootstrapLoaderTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Prompt.BootstrapLoader
  alias FermixCore.Prompt.Seeder

  setup do
    previous_config = Application.get_env(:fermix_core, :prompt_bootstrap, [])
    base_dir = Path.join(System.tmp_dir!(), "fermix-bootstrap-loader-#{unique()}")

    Application.put_env(:fermix_core, :prompt_bootstrap,
      bootstrap_dir: base_dir,
      seed_agent_file: false
    )

    on_exit(fn ->
      Application.put_env(:fermix_core, :prompt_bootstrap, previous_config)
      File.rm_rf!(base_dir)
    end)

    %{agent_id: "main", base_dir: base_dir}
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

  test "load/1 rejects agent IDs that can escape the bootstrap directory" do
    assert {:error, {:invalid_agent_id, "../../etc"}} = BootstrapLoader.load("../../etc")
  end

  defp unique do
    System.unique_integer([:positive, :monotonic])
  end
end
