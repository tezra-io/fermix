defmodule FermixCore.Home.EpochTest do
  use ExUnit.Case, async: true

  alias FermixCore.Home.Epoch
  alias FermixTestSupport.SafeRm

  setup do
    root = SafeRm.make_tmp_dir!("home_epoch")
    on_exit(fn -> SafeRm.rm_rf!(root) end)
    %{root: root}
  end

  test "a home with no epoch file is absent, not an epoch", %{root: root} do
    assert Epoch.read(root) == :absent
    assert Epoch.bump(root) == {:error, :absent}
    refute File.exists?(Epoch.path(root))
  end

  test "write then read round-trips one integer and a newline, mode 0600", %{root: root} do
    assert :ok = Epoch.write(root, 1)
    assert File.read!(Epoch.path(root)) == "1\n"
    assert Epoch.read(root) == {:ok, 1}
    assert Bitwise.band(File.stat!(Epoch.path(root)).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(Path.dirname(Epoch.path(root))).mode, 0o777) == 0o700
    refute File.exists?(Epoch.path(root) <> ".tmp")
  end

  test "an existing mobile directory keeps its mode", %{root: root} do
    dir = Path.join(root, "mobile")
    File.mkdir!(dir)
    File.chmod!(dir, 0o750)

    assert :ok = Epoch.write(root, 3)
    assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o750
  end

  test "bump counts from the file and writes the next epoch", %{root: root} do
    :ok = Epoch.write(root, 4)
    assert Epoch.bump(root) == {:ok, 5}
    assert Epoch.read(root) == {:ok, 5}
  end

  test "anything but one positive integer in range is invalid by name", %{root: root} do
    file = Epoch.path(root)
    File.mkdir_p!(Path.dirname(file))

    for contents <- ["0\n", "-1\n", "1", " 1\n", "1\n\n", "01\n", "x\n", "", "99999999999\n"] do
      File.write!(file, contents)
      assert {:error, {:invalid_epoch, ^file, _excerpt}} = Epoch.read(root), inspect(contents)
    end
  end

  test "a write that cannot land leaves no temp file behind", %{root: root} do
    dir = Path.join(root, "mobile")
    File.mkdir!(dir)
    File.mkdir!(Path.join(dir, "primary_epoch"))

    assert {:error, {:file, _file, _reason}} = Epoch.write(root, 1)
    refute File.exists?(Path.join(dir, "primary_epoch.tmp"))
  end

  test "the epoch is bounded on write and on bump", %{root: root} do
    assert_raise FunctionClauseError, fn -> Epoch.write(root, 0) end
    assert_raise FunctionClauseError, fn -> Epoch.write(root, Epoch.max_epoch() + 1) end

    :ok = Epoch.write(root, Epoch.max_epoch())
    assert {:error, {:epoch_overflow, _file}} = Epoch.bump(root)
    assert Epoch.read(root) == {:ok, Epoch.max_epoch()}
  end
end
