defmodule FermixCore.Resource.DiffTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Repo
  alias FermixCore.Resource.Diff
  alias FermixCore.Resource.Registry

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-resource-diff-#{unique}.db")
    repo_name = :"resource_diff_repo_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo_name}
  end

  test "returns unified diff for changed content" do
    assert {:ok, diff} =
             Diff.unified("alpha\n", "alpha\nbeta\n",
               label_old: "old label",
               label_new: "new label"
             )

    assert diff =~ "--- old label"
    assert diff =~ "+++ new label"
    assert diff =~ "+beta"
  end

  test "returns identical for matching content" do
    assert {:ok, :identical} = Diff.unified("same\n", "same\n")
  end

  test "loads revisions before diffing", %{repo: repo} do
    assert {:ok, _first} =
             Registry.commit("main", "user_md", "global", "first\n",
               mutation_source: :imported,
               provenance: %{"trigger" => "imported"},
               repo: repo
             )

    assert {:ok, _second} =
             Registry.commit("main", "user_md", "global", "second\n",
               mutation_source: :manual_edit,
               provenance: %{"trigger" => "manual_edit"},
               repo: repo
             )

    assert {:ok, diff} =
             Diff.between_revisions("main", "user_md", "global", 1, 2, repo: repo)

    assert diff =~ "--- user_md @ revision 1"
    assert diff =~ "+++ user_md @ revision 2"
    assert diff =~ "-first"
    assert diff =~ "+second"
  end
end
