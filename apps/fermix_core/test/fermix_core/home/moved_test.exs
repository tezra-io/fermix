defmodule FermixCore.Home.MovedTest do
  use ExUnit.Case, async: true

  alias FermixCore.Home.Moved
  alias FermixTestSupport.SafeRm

  @marker %{epoch: 2, moved_at: ~U[2026-10-27 09:30:00Z], to: "aws i-0f3b1c"}

  setup do
    root = SafeRm.make_tmp_dir!("home_moved")
    on_exit(fn -> SafeRm.rm_rf!(root) end)
    %{root: root}
  end

  test "a home that never moved is absent", %{root: root} do
    assert Moved.read(root) == :absent
  end

  test "write then read round-trips the marker", %{root: root} do
    assert :ok = Moved.write(root, @marker)
    assert Moved.read(root) == {:ok, @marker}
    assert File.read!(Moved.path(root)) =~ ~s("moved_at":"2026-10-27T09:30:00Z")
  end

  test "a second move is refused and the first marker stands", %{root: root} do
    :ok = Moved.write(root, @marker)
    later = %{@marker | epoch: 3, to: "elsewhere"}

    assert Moved.write(root, later) == {:error, {:already_moved, @marker}}
    assert Moved.read(root) == {:ok, @marker}
  end

  # Only a return's activation removes it, once the server's own marker exists.
  test "remove takes the marker away, and an absent one is already removed", %{root: root} do
    :ok = Moved.write(root, @marker)

    assert :ok = Moved.remove(root)
    assert Moved.read(root) == :absent
    assert :ok = Moved.remove(root)
  end

  test "a marker that cannot be removed is named", %{root: root} do
    File.mkdir_p!(Path.join(Moved.path(root), "inside"))
    file = Moved.path(root)

    assert {:error, {:file, ^file, _posix}} = Moved.remove(root)
  end

  test "the destination must be short printable text", %{root: root} do
    file = Moved.path(root)

    for to <- ["", "line\nbreak", String.duplicate("x", 129), <<0xFF>>] do
      assert {:error, {:invalid_marker, ^file, {:to, ^to}}} =
               Moved.write(root, %{@marker | to: to})
    end

    refute File.exists?(file)
  end

  test "a marker that is not the documented shape is invalid by name", %{root: root} do
    file = Moved.path(root)

    for contents <- [
          "",
          "{}",
          "[]",
          ~s({"epoch":0,"moved_at":"2026-10-27T09:30:00Z","to":"x"}),
          ~s({"epoch":1,"moved_at":"yesterday","to":"x"}),
          ~s({"epoch":1,"moved_at":"2026-10-27T09:30:00Z","to":""})
        ] do
      File.write!(file, contents)
      assert {:error, {:invalid_marker, ^file, _detail}} = Moved.read(root), inspect(contents)
    end
  end
end
