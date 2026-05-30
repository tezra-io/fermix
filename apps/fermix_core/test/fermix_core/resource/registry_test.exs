defmodule FermixCore.Resource.RegistryTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Repo
  alias FermixCore.Resource.Registry
  alias FermixCore.Resource.Revision

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-resource-registry-#{unique}.db")
    repo_name = :"resource_registry_repo_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo_name}
  end

  test "registers a resource and commits revision one", %{repo: repo} do
    assert {:ok, resource} =
             Registry.ensure_registered("main", "fermix_md", "global",
               resource_path: "/tmp/FERMIX.md",
               repo: repo
             )

    assert resource.current_revision == 0

    assert {:ok, %Revision{} = revision} =
             Registry.commit("main", "fermix_md", "global", "hello",
               mutation_source: :seed,
               provenance: %{"trigger" => "seed", "description" => "initial"},
               resource_path: "/tmp/FERMIX.md",
               repo: repo
             )

    assert revision.revision == 1
    assert revision.parent_revision == nil
    assert revision.mutation_source == "seed"
    assert revision.provenance == %{"trigger" => "seed", "description" => "initial"}
    assert revision.byte_size == 5
    assert %DateTime{} = revision.created_at

    assert {:ok, 1} = Registry.current_revision("main", "fermix_md", "global", repo: repo)

    assert {:ok, revision.content_hash} ==
             Registry.current_hash("main", "fermix_md", "global", repo: repo)
  end

  test "identical content is unchanged and does not create duplicate revisions", %{repo: repo} do
    assert {:ok, first} =
             Registry.commit("main", "user_md", "global", "same",
               mutation_source: :imported,
               provenance: %{"trigger" => "imported"},
               repo: repo
             )

    assert {:ok, :unchanged} =
             Registry.commit("main", "user_md", "global", "same",
               mutation_source: :manual_edit,
               provenance: %{"trigger" => "manual_edit"},
               repo: repo
             )

    assert {:ok, [history]} = Registry.list_revisions("main", "user_md", "global", repo: repo)
    assert history.id == first.id
    assert history.mutation_source == "imported"
  end

  test "concurrent identical commits create one revision", %{repo: repo} do
    results =
      1..8
      |> Task.async_stream(
        fn _index ->
          Registry.commit("main", "fermix_md", "global", "same",
            mutation_source: :manual_edit,
            provenance: %{"trigger" => "manual_edit"},
            repo: repo
          )
        end,
        max_concurrency: 8,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    created_count = Enum.count(results, &match?({:ok, %Revision{}}, &1))
    unchanged_count = Enum.count(results, &(&1 == {:ok, :unchanged}))

    assert created_count == 1
    assert unchanged_count == 7

    selector = %{agent_id: "main", resource_type: "fermix_md", scope_id: "global"}

    assert {:ok, 1} = Repo.revision_count(selector, server: repo)
    assert {:ok, [revision]} = Registry.list_revisions("main", "fermix_md", "global", repo: repo)
    assert revision.content == "same"
    assert revision.revision == 1
  end

  test "changed content increments revisions and exposes history", %{repo: repo} do
    assert {:ok, first} =
             Registry.commit("main", "memory_md", "global", "one",
               mutation_source: :scheduler_rebuild,
               provenance: %{"trigger" => "scheduler_rebuild"},
               repo: repo
             )

    assert {:ok, second} =
             Registry.commit("main", "memory_md", "global", "two",
               mutation_source: :extraction_rebuild,
               provenance: %{"trigger" => "extraction_rebuild", "memory_ids" => [42]},
               repo: repo
             )

    assert second.revision == 2
    assert second.parent_revision == 1
    assert first.content_hash != second.content_hash

    assert {:ok, second} == Registry.get_revision("main", "memory_md", "global", 2, repo: repo)

    assert {:ok, [latest, oldest]} =
             Registry.list_revisions("main", "memory_md", "global", repo: repo)

    assert {latest.revision, oldest.revision} == {2, 1}
  end

  test "queries current data for scoped checkpoint resources", %{repo: repo} do
    scope_id = "telegram:chat-1:root"

    assert {:ok, revision} =
             Registry.commit("main", "checkpoint", scope_id, "summary",
               mutation_source: :compaction,
               provenance: %{"trigger" => "compaction", "messages_summarized" => 8},
               repo: repo
             )

    assert {:ok, 1} = Registry.current_revision("main", "checkpoint", scope_id, repo: repo)

    assert {:ok, revision.content_hash} ==
             Registry.current_hash("main", "checkpoint", scope_id, repo: repo)

    assert {:ok, [revision]} ==
             Registry.list_revisions("main", "checkpoint", scope_id, repo: repo)
  end

  test "lists registered resources for an agent", %{repo: repo} do
    assert {:ok, _revision} =
             Registry.commit("main", "fermix_md", "global", "agents",
               mutation_source: :seed,
               provenance: %{"trigger" => "seed"},
               repo: repo
             )

    assert {:ok, _revision} =
             Registry.commit("main", "checkpoint", "telegram:chat-1:root", "summary",
               mutation_source: :compaction,
               provenance: %{"trigger" => "compaction"},
               repo: repo
             )

    assert {:ok, resources} = Registry.list_resources("main", repo: repo)

    assert Enum.map(resources, &{&1.resource_type, &1.scope_id, &1.current_revision}) == [
             {"checkpoint", "telegram:chat-1:root", 1},
             {"fermix_md", "global", 1}
           ]
  end

  test "rollback appends a revision, preserves history, and rewrites file", %{repo: repo} do
    path = temp_resource_path("rollback-user")
    File.write!(path, "current")

    assert {:ok, first} =
             Registry.commit("main", "user_md", "global", "first",
               mutation_source: :imported,
               provenance: %{"trigger" => "imported"},
               resource_path: path,
               repo: repo
             )

    assert {:ok, second} =
             Registry.commit("main", "user_md", "global", "second",
               mutation_source: :scheduler_rebuild,
               provenance: %{"trigger" => "scheduler_rebuild"},
               resource_path: path,
               repo: repo
             )

    assert {:ok, rollback} = Registry.rollback("main", "user_md", "global", 1, repo: repo)

    assert rollback.revision == 3
    assert rollback.parent_revision == 2
    assert rollback.content == first.content
    assert rollback.content_hash == first.content_hash
    assert rollback.mutation_source == "rollback"

    assert rollback.provenance == %{
             "trigger" => "rollback",
             "target_revision" => 1,
             "from_revision" => 2,
             "description" => "Operator rolled back from revision 2 to revision 1"
           }

    assert {:ok, 3} = Registry.current_revision("main", "user_md", "global", repo: repo)
    assert File.read!(path) == "first"

    assert {:ok, second} == Registry.get_revision("main", "user_md", "global", 2, repo: repo)

    assert {:ok, [latest, middle, oldest]} =
             Registry.list_revisions("main", "user_md", "global", repo: repo)

    assert {latest.revision, middle.revision, oldest.revision} == {3, 2, 1}
  end

  test "rollback rejects nonexistent target revision", %{repo: repo} do
    path = temp_resource_path("rollback-missing-target")
    File.write!(path, "only")

    assert {:ok, _revision} =
             Registry.commit("main", "memory_md", "global", "only",
               mutation_source: :imported,
               provenance: %{"trigger" => "imported"},
               resource_path: path,
               repo: repo
             )

    assert {:error, :not_found} = Registry.rollback("main", "memory_md", "global", 9, repo: repo)

    assert {:ok, [revision]} = Registry.list_revisions("main", "memory_md", "global", repo: repo)
    assert revision.revision == 1
    assert File.read!(path) == "only"
  end

  test "rollback to current content is a no-op", %{repo: repo} do
    path = temp_resource_path("rollback-current-target")
    File.write!(path, "current")

    assert {:ok, _first} =
             Registry.commit("main", "fermix_md", "global", "first",
               mutation_source: :imported,
               provenance: %{"trigger" => "imported"},
               resource_path: path,
               repo: repo
             )

    assert {:ok, second} =
             Registry.commit("main", "fermix_md", "global", "second",
               mutation_source: :manual_edit,
               provenance: %{"trigger" => "manual_edit"},
               resource_path: path,
               repo: repo
             )

    assert {:ok, :already_at_target} =
             Registry.rollback("main", "fermix_md", "global", 2, repo: repo)

    assert {:ok, [^second, first]} =
             Registry.list_revisions("main", "fermix_md", "global", repo: repo)

    assert first.revision == 1
    assert File.read!(path) == "current"
  end

  test "rollback rewrites file-backed resources with temporary file cleanup", %{repo: repo} do
    path = temp_resource_path("rollback-atomic-file")

    assert {:ok, _first} =
             Registry.commit("main", "soul_md", "global", "soul v1\n",
               mutation_source: :imported,
               provenance: %{"trigger" => "imported"},
               resource_path: path,
               repo: repo
             )

    assert {:ok, _second} =
             Registry.commit("main", "soul_md", "global", "soul v2\n",
               mutation_source: :manual_edit,
               provenance: %{"trigger" => "manual_edit"},
               resource_path: path,
               repo: repo
             )

    assert {:ok, _rollback} = Registry.rollback("main", "soul_md", "global", 1, repo: repo)

    assert File.read!(path) == "soul v1\n"
    assert Path.wildcard("#{path}.tmp-*") == []
  end

  test "checkpoint rollback is explicitly not implemented", %{repo: repo} do
    assert {:ok, _revision} =
             Registry.commit("main", "checkpoint", "telegram:chat-1:root", "summary",
               mutation_source: :compaction,
               provenance: %{"trigger" => "compaction"},
               repo: repo
             )

    assert {:error, :checkpoint_rollback_not_implemented} =
             Registry.rollback("main", "checkpoint", "telegram:chat-1:root", 1, repo: repo)
  end

  test "rejects unknown resource types and mutation sources", %{repo: repo} do
    assert {:error, {:unsupported_resource_type, "unknown"}} =
             Registry.ensure_registered("main", "unknown", "global", repo: repo)

    assert {:error, {:unsupported_mutation_source, "unknown"}} =
             Registry.commit("main", "fermix_md", "global", "body",
               mutation_source: :unknown,
               repo: repo
             )
  end

  defp temp_resource_path(name) do
    unique = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "#{name}-#{unique}")
    File.mkdir_p!(dir)

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(dir) end)

    Path.join(dir, "RESOURCE.md")
  end
end
