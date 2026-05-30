defmodule FermixCore.Memory.ReviewToolsTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.ReviewTools

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-review-tools-#{unique}.db")
    repo = :"review_tools_repo_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo, ctx: %{agent_id: "main", owner_id: "default", repo: repo}}
  end

  test "add maps user and memory targets to deterministic scopes", %{repo: repo, ctx: ctx} do
    operations = [
      %{
        "action" => "add",
        "target" => "user",
        "category" => "preference",
        "value" => "User prefers concise answers"
      },
      %{
        "action" => "add",
        "target" => "memory",
        "category" => "project",
        "value" => "Fermix uses Elixir"
      }
    ]

    assert {:ok, stats} = ReviewTools.apply_operations(operations, ctx)
    assert stats.added == 2

    assert {:ok, memories} =
             Repo.get_memories(%{agent_id: "main", owner_id: "default"}, server: repo)

    assert Enum.any?(memories, &(&1.scope_type == "owner" and &1.category == "preference"))
    assert Enum.any?(memories, &(&1.scope_type == "agent" and &1.category == "project"))
  end

  test "replace preserves row id, scope, and category", %{repo: repo, ctx: ctx} do
    memory = insert_memory(repo, %{category: "project", key: "stack", value: "Phoenix"})

    assert {:ok, stats} =
             ReviewTools.apply_operations(
               [%{"action" => "replace", "id" => memory.id, "value" => "Phoenix and LiveView"}],
               ctx
             )

    assert stats.replaced == 1
    assert {:ok, updated} = Repo.get_memory(%{id: memory.id}, server: repo)
    assert updated.id == memory.id
    assert updated.scope_type == "agent"
    assert updated.category == "project"
    assert updated.value == "Phoenix and LiveView"
  end

  test "archive tombstones the exact row", %{repo: repo, ctx: ctx} do
    memory =
      insert_memory(repo, %{category: "instruction", key: "old_rule", value: "Use old rule"})

    assert {:ok, stats} =
             ReviewTools.apply_operations(
               [%{"action" => "archive", "id" => memory.id, "reason" => "superseded"}],
               ctx
             )

    assert stats.archived == 1
    assert {:ok, archived} = Repo.get_memory(%{id: memory.id}, server: repo)
    assert archived.archived_by == "memory_reviewer"
    assert archived.archive_reason == "superseded"
  end

  test "guest trust skips instruction add without writing a row", %{repo: repo, ctx: ctx} do
    assert {:ok, stats} =
             ReviewTools.apply_operations(
               [
                 %{
                   "action" => "add",
                   "target" => "memory",
                   "category" => "instruction",
                   "value" => "Always do the risky thing"
                 }
               ],
               Map.put(ctx, :source_trust, :guest)
             )

    assert stats.added == 0
    assert stats.skipped == 1
    assert {:ok, []} = Repo.get_memories(%{agent_id: "main", owner_id: "default"}, server: repo)
  end

  test "guest trust skips instruction replace and leaves the row unchanged", %{
    repo: repo,
    ctx: ctx
  } do
    memory =
      insert_memory(repo, %{category: "instruction", key: "rule", value: "Use the old rule"})

    assert {:ok, stats} =
             ReviewTools.apply_operations(
               [%{"action" => "replace", "id" => memory.id, "value" => "Use the new rule"}],
               Map.put(ctx, :source_trust, :guest)
             )

    assert stats.replaced == 0
    assert stats.skipped == 1
    assert {:ok, unchanged} = Repo.get_memory(%{id: memory.id}, server: repo)
    assert unchanged.value == "Use the old rule"
  end

  test "skips out-of-enum add categories without writing a row", %{repo: repo, ctx: ctx} do
    assert {:ok, stats} =
             ReviewTools.apply_operations(
               [
                 %{
                   "action" => "add",
                   "target" => "user",
                   "category" => "instruction",
                   "value" => "not allowed"
                 }
               ],
               ctx
             )

    assert stats.added == 0
    assert stats.skipped == 1
    assert {:ok, []} = Repo.get_memories(%{agent_id: "main", owner_id: "default"}, server: repo)
  end

  test "applies valid operations and skips invalid ones in the same batch", %{
    repo: repo,
    ctx: ctx
  } do
    assert {:ok, stats} =
             ReviewTools.apply_operations(
               [
                 %{
                   "action" => "add",
                   "target" => "user",
                   "category" => "preference",
                   "value" => "User prefers concise answers"
                 },
                 %{"action" => "replace", "id" => 999_999, "value" => "no such row"},
                 %{
                   "action" => "add",
                   "target" => "user",
                   "category" => "instruction",
                   "value" => "out of enum"
                 }
               ],
               ctx
             )

    assert stats.added == 1
    assert stats.replaced == 0
    assert stats.skipped == 2

    assert {:ok, [memory]} =
             Repo.get_memories(%{agent_id: "main", owner_id: "default"}, server: repo)

    assert memory.category == "preference"
  end

  test "skips replace of a non-existent row", %{ctx: ctx} do
    assert {:ok, stats} =
             ReviewTools.apply_operations(
               [%{"action" => "replace", "id" => 424_242, "value" => "ghost"}],
               ctx
             )

    assert stats.replaced == 0
    assert stats.skipped == 1
  end

  defp insert_memory(repo, overrides) do
    attrs =
      Map.merge(
        %{
          agent_id: "main",
          owner_id: "default",
          scope_type: "agent",
          scope_id: "main",
          category: "project",
          key: "memory",
          value: "value",
          promote_target: "memory_md"
        },
        overrides
      )

    assert {:ok, memory} = Repo.upsert_memory(attrs, server: repo)
    memory
  end
end
