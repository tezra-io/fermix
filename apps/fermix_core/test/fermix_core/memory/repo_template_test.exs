defmodule FermixCore.Memory.RepoTemplateTest do
  # Every database the suite opens on a new path starts as a copy of one
  # template, migrated once per run (FermixTestSupport.RepoTemplate). These hold
  # that seam to what migrating from nothing gives, so the speed costs no
  # coverage. async: false: one case runs with no template at all.
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias FermixCore.ComputerHistory
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.SafeRm

  setup do
    dir = SafeRm.make_tmp_dir!("repo-template")
    on_exit(fn -> SafeRm.rm_rf(dir) end)
    %{dir: dir, template: Application.fetch_env!(:fermix_core, :repo_template)}
  end

  test "a database opened on a new path starts as a copy of the template", ctx do
    marked = Path.join(ctx.dir, "marked-template.db")
    File.cp!(ctx.template, marked)
    :ok = execute(marked, "PRAGMA user_version = 4242")

    with_template(marked, fn ->
      stop_repo(open_repo(:from_marked, Path.join(ctx.dir, "new.db")))
    end)

    assert rows(Path.join(ctx.dir, "new.db"), "PRAGMA user_version") == [[4242]]
  end

  test "a database copied from the template has the schema migrating from nothing gives", ctx do
    copied = Path.join(ctx.dir, "copied.db")
    stop_repo(open_repo(:copied, copied))

    blank = Path.join(ctx.dir, "blank.db")
    without_template(fn -> stop_repo(open_repo(:blank, blank)) end)

    assert schema(copied) == schema(blank)
    assert schema(copied).versions != []
  end

  test "each copy gets a history identity of its own, as any stored copy does", ctx do
    first = open_repo(:first, Path.join(ctx.dir, "first.db"))
    second = open_repo(:second, Path.join(ctx.dir, "second.db"))

    assert {:ok, one} = ComputerHistory.home_identity(repo: first)
    assert {:ok, other} = ComputerHistory.home_identity(repo: second)
    refute one == other
    refute one == token(ctx.template)
  end

  test "a database that exists is opened as it is, never replaced by the template", ctx do
    path = Path.join(ctx.dir, "kept.db")
    repo = open_repo(:kept, path)
    {:ok, identity} = ComputerHistory.home_identity(repo: repo)
    stop_repo(repo)

    reopened = open_repo(:kept_again, path)

    assert {:ok, ^identity} = ComputerHistory.home_identity(repo: reopened)
  end

  defp open_repo(name, path) do
    start_supervised!({Repo, name: name, enabled: true, database_path: path}, id: name)
    name
  end

  defp stop_repo(name), do: :ok = stop_supervised!(name)

  defp without_template(fun), do: with_template(nil, fun)

  defp with_template(path, fun) do
    template = Application.fetch_env!(:fermix_core, :repo_template)

    if path,
      do: Application.put_env(:fermix_core, :repo_template, path),
      else: Application.delete_env(:fermix_core, :repo_template)

    try do
      fun.()
    after
      Application.put_env(:fermix_core, :repo_template, template)
    end
  end

  defp execute(path, sql) do
    {:ok, conn} = Sqlite3.open(path)

    try do
      Sqlite3.execute(conn, sql)
    after
      :ok = Sqlite3.close(conn)
    end
  end

  defp schema(path) do
    %{
      objects:
        rows(path, "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name"),
      versions: rows(path, "SELECT version FROM schema_migrations ORDER BY version")
    }
  end

  defp token(path) do
    [[token]] = rows(path, "SELECT token FROM computer_history_home WHERE id = 1")
    token
  end

  defp rows(path, sql) do
    {:ok, conn} = Sqlite3.open(path, mode: :readonly)

    try do
      {:ok, statement} = Sqlite3.prepare(conn, sql)
      {:ok, rows} = Sqlite3.fetch_all(conn, statement)
      :ok = Sqlite3.release(conn, statement)
      rows
    after
      :ok = Sqlite3.close(conn)
    end
  end
end
