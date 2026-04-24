defmodule FermixCore.Prompt.PromptComposerTest do
  use ExUnit.Case, async: false

  alias FermixCore.Memory.PromptFiles
  alias FermixCore.Prompt.PromptComposer
  alias FermixCore.Prompt.RuntimeSections
  alias FermixCore.Prompt.Seeder

  setup do
    unique = System.unique_integer([:positive, :monotonic])
    bootstrap_dir = Path.join(System.tmp_dir!(), "fermix-composer-bootstrap-#{unique}")
    memory_dir = Path.join(System.tmp_dir!(), "fermix-composer-memory-#{unique}")
    previous_bootstrap = Application.get_env(:fermix_core, :prompt_bootstrap, [])
    previous_memory = Application.get_env(:fermix_core, :memory, [])

    Application.put_env(:fermix_core, :prompt_bootstrap,
      bootstrap_dir: bootstrap_dir,
      seed_agent_file: false
    )

    Application.put_env(
      :fermix_core,
      :memory,
      Keyword.merge(previous_memory, prompt_base_dir: memory_dir, agent_id: "main")
    )

    on_exit(fn ->
      Application.put_env(:fermix_core, :prompt_bootstrap, previous_bootstrap)
      Application.put_env(:fermix_core, :memory, previous_memory)
      File.rm_rf!(bootstrap_dir)
      File.rm_rf!(memory_dir)
    end)

    %{agent_id: "main"}
  end

  test "compose/1 returns system messages in documented order", %{agent_id: agent_id} do
    write_bootstrap(agent_id, "SOUL.md", "soul content")
    write_bootstrap(agent_id, "AGENTS.md", "agents content")
    write_memory(agent_id, "USER.md", "user content")
    write_memory(agent_id, "MEMORY.md", "memory content")

    assert {:ok, messages} = PromptComposer.compose(agent_id: agent_id, available_skills: [])

    assert Enum.map(messages, & &1.role) == List.duplicate("system", 5)

    assert Enum.map(messages, & &1.content) == [
             "soul content",
             "agents content",
             "user content",
             "memory content",
             RuntimeSections.build([])
           ]
  end

  test "compose/1 omits absent optional parts but keeps AGENTS fallback and runtime", %{
    agent_id: agent_id
  } do
    assert {:ok, messages} = PromptComposer.compose(agent_id: agent_id, available_skills: [])

    assert length(messages) == 2
    [agents, runtime] = messages
    assert agents.content =~ "You are a helpful AI assistant"
    assert runtime.content =~ "## Runtime Contract"
  end

  test "compose_with_metadata/1 exposes accounting for every emitted part", %{agent_id: agent_id} do
    write_bootstrap(agent_id, "SOUL.md", "soul content")
    write_bootstrap(agent_id, "AGENTS.md", "agents content")
    write_memory(agent_id, "USER.md", "user content")

    assert {:ok, result} =
             PromptComposer.compose_with_metadata(agent_id: agent_id, available_skills: [])

    assert Enum.map(result.accounting, & &1.name) == [:soul, :agents, :user, :runtime]

    assert Enum.find(result.accounting, &(&1.name == :soul)) == %{
             name: :soul,
             source_path: Seeder.soul_path(agent_id),
             approx_size: byte_size("soul content"),
             approx_tokens: 3
           }

    assert Enum.find(result.accounting, &(&1.name == :runtime)).source_path == nil
    assert Enum.all?(result.accounting, &(&1.approx_size > 0))
  end

  defp write_bootstrap(agent_id, file, content) do
    path = Path.join(Seeder.agent_dir(agent_id), file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp write_memory(agent_id, file, content) do
    path = Path.join(Path.dirname(PromptFiles.user_path(agent_id)), file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end
end
