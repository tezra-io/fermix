defmodule FermixCore.Home.DiskTest do
  @moduledoc """
  The free space a capture or a move checks before it fills a disk, read from
  `df -Pk` output as macOS and GNU print it. A filesystem whose name holds a
  space (an SMB share) and a mount point that holds one, or a token that looks
  like the capacity column, must not move the columns.

  How full the home's filesystem is (`usage/2`), for the disk warning of
  `home.status.summary` (M75 L14): used over used plus available, warned at
  85%, read from the same output, and once through the real `df` on this
  machine's temporary directory.
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

  describe "parse_usage/1" do
    test "a nearly full macOS disk is used over used plus available, and warns" do
      out =
        @header <>
          "\n/dev/disk3s5   239362496 201433128   4948828    98%    /System/Volumes/Data\n"

      assert {:ok, %{used: used, nearly_full: true}} = Disk.parse_usage(out)
      assert_in_delta used, 201_433_128 / (201_433_128 + 4_948_828), 1.0e-9
    end

    test "a GNU disk with room does not warn, and root's reserve counts as used" do
      # 20509264 blocks, 3184500 used, 16260404 available: the 1064360 blocks
      # kept back for root are not available to the engine, so they are not room.
      out =
        "Filesystem     1024-blocks    Used Available Capacity Mounted on\n" <>
          "/dev/root         20509264 3184500  16260404      17% /\n"

      assert {:ok, %{used: used, nearly_full: false}} = Disk.parse_usage(out)
      assert_in_delta used, 3_184_500 / (3_184_500 + 16_260_404), 1.0e-9
    end

    test "the warning starts at 85% used, not before" do
      line = fn used, available ->
        @header <> "\n/dev/sda1  #{used + available}  #{used}  #{available}  0%  /\n"
      end

      assert {:ok, %{used: 0.85, nearly_full: true}} = Disk.parse_usage(line.(85, 15))
      assert {:ok, %{used: 0.84, nearly_full: false}} = Disk.parse_usage(line.(84, 16))
      assert Disk.nearly_full_at() == 0.85
    end

    test "a name or mount point with spaces does not shift the columns" do
      out =
        @header <> "\n//owner@nas/Family Photos  1000 900 100    90%    /Volumes/Backup 50% Off\n"

      assert {:ok, %{used: 0.9, nearly_full: true}} = Disk.parse_usage(out)
    end

    test "a filesystem with no size, or no line for it, has no reading" do
      assert Disk.parse_usage(
               @header <> "\nmap auto_home  0  0  0  -  /System/Volumes/Data/home\n"
             ) ==
               {:error, :df_no_size}

      assert Disk.parse_usage(@header <> "\n") == {:error, :df_unparseable}
      assert Disk.parse_usage("") == {:error, :df_unparseable}
    end
  end

  test "usage/2 reads the filesystem that holds a directory not made yet, through df" do
    dir = Path.join(System.tmp_dir!(), "fermix-disk-#{System.unique_integer([:positive])}/home")

    assert {:ok, %{used: used, nearly_full: nearly_full}} = Disk.usage(dir, supervised: true)

    assert used >= 0.0 and used <= 1.0
    assert nearly_full == used >= Disk.nearly_full_at()
  end
end
