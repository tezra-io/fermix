defmodule Mix.Tasks.Fermix.ResourceTest do
  use ExUnit.Case, async: false

  alias FermixCore.Memory.Repo
  alias FermixCore.Resource.Registry

  setup do
    memory_env = Application.fetch_env(:fermix_core, :memory)
    shell = Mix.shell()
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-resource-task-#{unique}.db")
    repo_name = :"resource_task_repo_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})
    Mix.shell(Mix.Shell.Process)

    Application.put_env(
      :fermix_core,
      :memory,
      Keyword.merge(memory_config(memory_env), enabled: true, repo: repo_name)
    )

    on_exit(fn ->
      restore_memory_env(memory_env)
      Mix.shell(shell)
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo_name}
  end

  test "list, history, show, and diff expose resource revisions", %{repo: repo} do
    seed_resource_history(repo)

    run_task("fermix.resource.list", [])
    list_output = shell_output()
    assert list_output =~ "Resource"
    assert list_output =~ "user_md"
    assert list_output =~ "checkpoint"
    assert list_output =~ "telegram:chat-1:root"
    assert list_output =~ "manual_edit"

    run_task("fermix.resource.history", ["user_md", "--limit", "1"])
    history_output = shell_output()
    assert history_output =~ "Rev"
    assert history_output =~ "manual_edit"
    refute history_output =~ "imported"

    run_task("fermix.resource.show", ["user_md", "1"])
    assert shell_output() =~ "first\n"

    run_task("fermix.resource.diff", ["user_md", "1", "2"])
    diff_output = shell_output()
    assert diff_output =~ "--- user_md @ revision 1"
    assert diff_output =~ "+++ user_md @ revision 2"
    assert diff_output =~ "+second"

    run_task("fermix.resource.diff", ["user_md", "1", "1"])
    assert shell_output() =~ "Revisions 1 and 1 have identical content."
  end

  test "show supports scoped checkpoint resources", %{repo: repo} do
    assert {:ok, _revision} =
             Registry.commit("main", "checkpoint", "telegram:chat-1:root", "summary body\n",
               mutation_source: :compaction,
               provenance: %{"trigger" => "compaction"},
               repo: repo
             )

    run_task("fermix.resource.show", ["checkpoint", "--scope", "telegram:chat-1:root"])

    assert shell_output() =~ "summary body\n"
  end

  test "rollback previews diff, confirms, rewrites file, and creates revision", %{repo: repo} do
    path = temp_resource_path("rollback-task")
    File.write!(path, "second\n")

    assert {:ok, _first} =
             Registry.commit("main", "user_md", "global", "first\n",
               mutation_source: :imported,
               provenance: %{"trigger" => "imported"},
               resource_path: path,
               repo: repo
             )

    assert {:ok, _second} =
             Registry.commit("main", "user_md", "global", "second\n",
               mutation_source: :manual_edit,
               provenance: %{"trigger" => "manual_edit"},
               resource_path: path,
               repo: repo
             )

    send(self(), {:mix_shell_input, :yes?, true})
    run_task("fermix.resource.rollback", ["user_md", "1"])

    output = shell_output()
    assert output =~ "Rolling back user_md from revision 2 to revision 1."
    assert output =~ "Caveat: rolling back USER.md restores the file only"
    assert output =~ "Diff (current -> target):"
    assert output =~ "Rolled back. New revision: 3"
    assert output =~ "File rewritten: #{path}"
    assert File.read!(path) == "first\n"
  end

  test "rollback documents unsupported checkpoint rollback", %{repo: repo} do
    assert {:ok, _revision} =
             Registry.commit("main", "checkpoint", "telegram:chat-1:root", "summary",
               mutation_source: :compaction,
               provenance: %{"trigger" => "compaction"},
               repo: repo
             )

    assert_raise Mix.Error, ~r/checkpoint rollback is not implemented/, fn ->
      run_task("fermix.resource.rollback", [
        "checkpoint",
        "1",
        "--scope",
        "telegram:chat-1:root"
      ])
    end

    assert shell_output() =~ "Checkpoint rollback is not supported"
  end

  defp seed_resource_history(repo) do
    assert {:ok, _first} =
             Registry.commit("main", "user_md", "global", "first\n",
               mutation_source: :imported,
               provenance: %{"trigger" => "imported"},
               repo: repo
             )

    assert {:ok, _second} =
             Registry.commit("main", "user_md", "global", "first\nsecond\n",
               mutation_source: :manual_edit,
               provenance: %{"trigger" => "manual_edit"},
               repo: repo
             )

    assert {:ok, _checkpoint} =
             Registry.commit("main", "checkpoint", "telegram:chat-1:root", "summary\n",
               mutation_source: :compaction,
               provenance: %{"trigger" => "compaction"},
               repo: repo
             )
  end

  defp run_task(name, args) do
    Mix.Task.reenable(name)
    Mix.Task.run(name, args)
  end

  defp shell_output do
    receive do
      {:mix_shell, :info, [message]} -> message <> "\n" <> shell_output()
      {:mix_shell, :yes?, [_message]} -> shell_output()
    after
      0 -> ""
    end
  end

  defp memory_config({:ok, config}), do: config
  defp memory_config(:error), do: []

  defp restore_memory_env({:ok, config}), do: Application.put_env(:fermix_core, :memory, config)
  defp restore_memory_env(:error), do: Application.delete_env(:fermix_core, :memory)

  defp temp_resource_path(name) do
    unique = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "#{name}-#{unique}")
    File.mkdir_p!(dir)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(dir) end)
    Path.join(dir, "RESOURCE.md")
  end
end
