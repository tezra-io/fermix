defmodule FermixCore.Home.ComputerNameTest do
  # Every host fact is a seam: no case reads this machine's name.
  use ExUnit.Case, async: true

  alias FermixCore.Home.ComputerName

  @mac {:unix, :darwin}
  @linux {:unix, :linux}

  # A Mac's BSD hostname (the EC2 test's Mac read as "sujeeths") is not a name its
  # owner chose; the computer name Sharing shows is (EC2 test finding 9).
  test "a Mac is named by the computer name its owner gave it, never its hostname" do
    opts = [
      os_type: @mac,
      scutil: fn -> {:ok, "Orchard’s Mac mini\n"} end,
      hostname: fn -> flunk("a Mac's hostname is never read") end
    ]

    assert ComputerName.read(opts) == {:ok, "Orchard’s Mac mini"}
  end

  test "a server keeps its own hostname" do
    opts = [
      os_type: @linux,
      scutil: fn -> flunk("only a Mac has a computer name") end,
      hostname: fn -> {:ok, ~c"ip-10-0-4-17"} end
    ]

    assert ComputerName.read(opts) == {:ok, "ip-10-0-4-17"}
  end

  test "a name is at most 64 bytes, cut between characters" do
    long = String.duplicate("é", 40)

    assert {:ok, name} = ComputerName.read(os_type: @mac, scutil: fn -> {:ok, long} end)
    assert byte_size(name) == 64
    assert name == String.duplicate("é", 32)

    ascii = String.duplicate("a", 80)
    assert {:ok, cut} = ComputerName.read(os_type: @linux, hostname: fn -> {:ok, ascii} end)
    assert cut == String.duplicate("a", 64)
  end

  test "a name that cannot be read is an error with its reason, never a stand-in" do
    assert ComputerName.read(os_type: @mac, scutil: fn -> {:error, "scutil exited 1: "} end) ==
             {:error, "scutil exited 1: "}

    assert ComputerName.read(os_type: @mac, scutil: fn -> {:ok, "  \n"} end) ==
             {:error, "this Mac has no computer name"}

    assert ComputerName.read(os_type: @linux, hostname: fn -> {:error, :einval} end) ==
             {:error, "the hostname could not be read: :einval"}
  end
end
