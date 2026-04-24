defmodule FermixCore.Prompt.SeederTest do
  use ExUnit.Case, async: false

  alias FermixCore.Prompt.Seeder

  setup do
    previous_config = Application.get_env(:fermix_core, :prompt_bootstrap, [])
    base_dir = Path.join(System.tmp_dir!(), "fermix-prompt-seeder-#{unique()}")

    Application.put_env(:fermix_core, :prompt_bootstrap,
      bootstrap_dir: base_dir,
      seed_agent_file: true
    )

    on_exit(fn ->
      Application.put_env(:fermix_core, :prompt_bootstrap, previous_config)
      File.rm_rf!(base_dir)
    end)

    %{agent_id: "main", base_dir: base_dir}
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
    agent_id: agent_id
  } do
    assert {:ok, result} = Seeder.ensure_seeded(agent_id)
    assert result.agents.path == Seeder.agents_path(agent_id)
    assert result.agents.approx_size > 0
    assert result.agents.approx_tokens > 0
    assert result.soul == nil

    assert File.read!(Seeder.agents_path(agent_id)) =~ "You are a helpful AI assistant"
    refute File.exists?(Seeder.soul_path(agent_id))
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
