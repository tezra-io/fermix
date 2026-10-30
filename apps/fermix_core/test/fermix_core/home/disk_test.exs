defmodule FermixCore.Home.DiskTest do
  @moduledoc """
  The free space a capture or a move checks before it fills a disk, read from
  `df -Pk` output as macOS and GNU print it. A filesystem whose name holds a
  space (an SMB share) and a mount point that holds one, or a token that looks
  like the capacity column, must not move the columns.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Home.Disk

  @header "Filesystem   1024-blocks      Used Available Capacity  Mounted on"

  test "reads the available column of macOS output" do
    out =
      @header <>
        "\n/dev/disk3s5   239362496 201433128   4948828    98%    /System/Volumes/Data\n"

    assert Disk.parse(out) == {:ok, 4_948_828 * 1_024}
  end

  test "reads the available column of GNU output" do
    out =
      "Filesystem     1024-blocks    Used Available Capacity Mounted on\n" <>
        "/dev/root         20509264 3184500  16260404      17% /\n"

    assert Disk.parse(out) == {:ok, 16_260_404 * 1_024}
  end

  test "a filesystem name with a space does not shift the columns" do
    out =
      @header <>
        "\n//owner@nas/Family Photos  976490576 400000000 576490576    41%    " <>
        "/Volumes/Family Photos\n"

    assert Disk.parse(out) == {:ok, 576_490_576 * 1_024}
  end

  test "a mount point with a space and a capacity-like word is read as the mount point" do
    out = @header <> "\n/dev/disk4s1  1000000 250000 750000 25% /Volumes/Backup 50% Off\n"

    assert Disk.parse(out) == {:ok, 750_000 * 1_024}
  end

  test "output with no line for the filesystem is unparseable" do
    assert Disk.parse(@header <> "\n") == {:error, :df_unparseable}
    assert Disk.parse("") == {:error, :df_unparseable}
    assert Disk.parse(@header <> "\nnot a df line\n") == {:error, :df_unparseable}
  end
end
