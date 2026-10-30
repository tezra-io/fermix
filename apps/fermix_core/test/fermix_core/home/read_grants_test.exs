defmodule FermixCore.Home.ReadGrantsTest do
  @moduledoc """
  M75 §11: the folders a desktop lets its primary read, each one the owner
  approved: private on disk, never added twice, bounded, removable by the
  owner, and a file that is not theirs is refused by name rather than read as
  no grant.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Home.ReadGrants
  alias FermixTestSupport.SafeRm

  @at ~U[2026-10-27 09:30:00Z]

  setup do
    home = SafeRm.make_tmp_dir!("desktop-read-grants")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home}
  end

  test "no file is no grant; a grant is kept privately, oldest first, once", %{home: home} do
    assert {:ok, []} = ReadGrants.list(home)

    assert :ok = ReadGrants.add(home, "/Users/ana/Downloads", @at)
    assert :ok = ReadGrants.add(home, "/Users/ana/Taxes", @at)
    assert :ok = ReadGrants.add(home, "/Users/ana/Downloads", @at)

    assert {:ok, ["/Users/ana/Downloads", "/Users/ana/Taxes"]} = ReadGrants.folders(home)

    assert {:ok, [%{path: "/Users/ana/Downloads", granted_at: "2026-10-27T09:30:00Z"} | _]} =
             ReadGrants.list(home)

    assert File.stat!(ReadGrants.path(home)).mode |> Bitwise.band(0o777) == 0o600
    assert File.stat!(Path.dirname(ReadGrants.path(home))).mode |> Bitwise.band(0o777) == 0o700
  end

  test "at most 64 folders", %{home: home} do
    for n <- 1..ReadGrants.max_grants(), do: :ok = ReadGrants.add(home, "/data/f#{n}", @at)

    assert {:error, :too_many_grants} = ReadGrants.add(home, "/data/one-more", @at)
    assert {:ok, folders} = ReadGrants.folders(home)
    assert length(folders) == 64
  end

  test "a grant removed is gone from the file, the others kept in order", %{home: home} do
    for folder <- ~w(/Users/ana/Downloads /Users/ana/Taxes /Users/ana/Photos),
        do: :ok = ReadGrants.add(home, folder, @at)

    assert {:ok, left} = ReadGrants.remove(home, ["/Users/ana/Taxes", "/private/Users/ana/Taxes"])
    assert Enum.map(left, & &1.path) == ["/Users/ana/Downloads", "/Users/ana/Photos"]
    assert {:ok, ["/Users/ana/Downloads", "/Users/ana/Photos"]} = ReadGrants.folders(home)
    assert File.stat!(ReadGrants.path(home)).mode |> Bitwise.band(0o777) == 0o600

    assert {:error, :not_granted} = ReadGrants.remove(home, ["/Users/ana/Taxes"])
    assert {:ok, [_, _]} = ReadGrants.list(home)
  end

  test "removing from a home that holds no grant is not granted", %{home: home} do
    assert {:error, :not_granted} = ReadGrants.remove(home, ["/Users/ana/Downloads"])
    refute File.exists?(ReadGrants.path(home))
  end

  test "a file that is not a grants file is refused by name", %{home: home} do
    File.mkdir_p!(Path.dirname(ReadGrants.path(home)))
    File.write!(ReadGrants.path(home), ~s({"v":1,"grants":[{"path":"relative"}]}))

    assert {:error, {:invalid_read_grants, path}} = ReadGrants.list(home)
    assert path == ReadGrants.path(home)
    assert {:error, {:invalid_read_grants, ^path}} = ReadGrants.remove(home, ["/x"])
  end
end
