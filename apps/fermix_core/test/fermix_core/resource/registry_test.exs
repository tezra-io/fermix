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
        File.rm(path)
      end)
    end)

    %{repo: repo_name}
  end

  test "registers a resource and commits revision one", %{repo: repo} do
    assert {:ok, resource} =
             Registry.ensure_registered("main", "agents_md", "global",
               resource_path: "/tmp/AGENTS.md",
               repo: repo
             )

    assert resource.current_revision == 0

    assert {:ok, %Revision{} = revision} =
             Registry.commit("main", "agents_md", "global", "hello",
               mutation_source: :seed,
               provenance: %{"trigger" => "seed", "description" => "initial"},
               resource_path: "/tmp/AGENTS.md",
               repo: repo
             )

    assert revision.revision == 1
    assert revision.parent_revision == nil
    assert revision.mutation_source == "seed"
    assert revision.provenance == %{"trigger" => "seed", "description" => "initial"}
    assert revision.byte_size == 5
    assert %DateTime{} = revision.created_at

    assert {:ok, 1} = Registry.current_revision("main", "agents_md", "global", repo: repo)

    assert {:ok, revision.content_hash} ==
             Registry.current_hash("main", "agents_md", "global", repo: repo)
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

  test "rejects unknown resource types and mutation sources", %{repo: repo} do
    assert {:error, {:unsupported_resource_type, "unknown"}} =
             Registry.ensure_registered("main", "unknown", "global", repo: repo)

    assert {:error, {:unsupported_mutation_source, "unknown"}} =
             Registry.commit("main", "agents_md", "global", "body",
               mutation_source: :unknown,
               repo: repo
             )
  end
end
