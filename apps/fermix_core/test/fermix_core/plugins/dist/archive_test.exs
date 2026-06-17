defmodule FermixCore.Plugins.Dist.ArchiveTest do
  use ExUnit.Case, async: true

  alias FermixCore.Plugins.Dist.Archive

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "fermix-archive-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(tmp) end)
    %{tmp: tmp}
  end

  # Build a .tar.gz from a list of {name_charlist, content_binary} members.
  defp tarball(tmp, name, members) do
    path = Path.join(tmp, name)
    entries = Enum.map(members, fn {n, content} -> {n, content} end)
    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    path
  end

  describe "extract/2" do
    test "extracts a clean tarball into the destination", %{tmp: tmp} do
      path =
        tarball(tmp, "clean.tar.gz", [
          {~c"plugin.json", "{\"name\":\"sample\"}"},
          {~c"skills/sample/SKILL.md", "---\nname: x\n---\n"}
        ])

      dest = Path.join(tmp, "out")
      assert :ok = Archive.extract(path, dest)
      assert File.read!(Path.join(dest, "plugin.json")) == "{\"name\":\"sample\"}"
      assert File.exists?(Path.join(dest, "skills/sample/SKILL.md"))
    end

    test "creates the destination directory when missing", %{tmp: tmp} do
      path = tarball(tmp, "mk.tar.gz", [{~c"plugin.json", "{}"}])
      dest = Path.join([tmp, "nested", "dest"])
      refute File.exists?(dest)
      assert :ok = Archive.extract(path, dest)
      assert File.exists?(Path.join(dest, "plugin.json"))
    end

    test "rejects a member with a .. path component and writes nothing", %{tmp: tmp} do
      path =
        tarball(tmp, "traversal.tar.gz", [
          {~c"plugin.json", "{}"},
          {~c"../escape.txt", "pwned"}
        ])

      dest = Path.join(tmp, "out")
      assert {:error, {:unsafe_member, :traversal, "../escape.txt"}} = Archive.extract(path, dest)
      # nothing was written — not even the clean member before the bad one
      refute File.exists?(Path.join(dest, "plugin.json"))
      refute File.exists?(Path.join(tmp, "escape.txt"))
    end

    test "rejects an absolute-path member", %{tmp: tmp} do
      path = tarball(tmp, "abs.tar.gz", [{~c"/etc/evil.txt", "x"}])
      dest = Path.join(tmp, "out")
      assert {:error, {:unsafe_member, :absolute, "/etc/evil.txt"}} = Archive.extract(path, dest)
    end

    test "rejects a member named exactly ..", %{tmp: tmp} do
      path = tarball(tmp, "dotdot.tar.gz", [{~c"..", "x"}])
      dest = Path.join(tmp, "out")
      assert {:error, {:unsafe_member, :traversal, ".."}} = Archive.extract(path, dest)
    end

    test "rejects an empty-named member with a clear error", %{tmp: tmp} do
      path = tarball(tmp, "empty.tar.gz", [{~c"", "x"}])
      dest = Path.join(tmp, "out")
      assert {:error, {:unsafe_member, :invalid_name, ""}} = Archive.extract(path, dest)
      refute File.exists?(dest)
    end

    test "rejects an archive whose declared uncompressed total exceeds the cap", %{tmp: tmp} do
      # Two members that compress tiny (zeros) but declare ~60 MB each = 120 MB > 100 MB cap.
      big = :binary.copy(<<0>>, 60 * 1024 * 1024)
      path = tarball(tmp, "bomb.tar.gz", [{~c"a.bin", big}, {~c"b.bin", big}])
      dest = Path.join(tmp, "out")
      assert {:error, {:archive_too_large, total}} = Archive.extract(path, dest)
      assert total > 100 * 1024 * 1024
      refute File.exists?(Path.join(dest, "a.bin"))
    end

    test "rejects a symlink member", %{tmp: tmp} do
      # build a tar that contains a real symlink
      src = Path.join(tmp, "src")
      File.mkdir_p!(src)
      File.write!(Path.join(src, "plugin.json"), "{}")
      File.ln_s!("plugin.json", Path.join(src, "evil_link"))

      path = Path.join(tmp, "symlink.tar.gz")

      :ok =
        :erl_tar.create(
          String.to_charlist(path),
          [
            {~c"plugin.json", String.to_charlist(Path.join(src, "plugin.json"))},
            {~c"evil_link", String.to_charlist(Path.join(src, "evil_link"))}
          ],
          [:compressed]
        )

      dest = Path.join(tmp, "out")
      assert {:error, {:unsafe_member, :link, "evil_link"}} = Archive.extract(path, dest)
      refute File.exists?(Path.join(dest, "plugin.json"))
    end

    test "returns an error for a corrupt / non-tar file", %{tmp: tmp} do
      path = Path.join(tmp, "garbage.tar.gz")
      File.write!(path, "not a tarball")
      dest = Path.join(tmp, "out")
      assert {:error, {:tar_table_failed, _reason}} = Archive.extract(path, dest)
    end
  end
end
