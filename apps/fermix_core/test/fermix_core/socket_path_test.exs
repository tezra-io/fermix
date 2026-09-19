defmodule FermixCore.SocketPathTest do
  @moduledoc """
  The one `sun_path` pre-flight (M38 §4.4.6).

  The limit is resolved at runtime, never compiled in: a release cross-built on
  one OS has to measure against the OS it actually runs on.
  """

  use ExUnit.Case, async: true

  alias FermixCore.SocketPath

  test "the limit is the running OS's array size, less its NUL terminator" do
    expected =
      case :os.type() do
        {:unix, :linux} -> 107
        _other -> 103
      end

    assert SocketPath.max_bytes() == expected
  end

  test "a path within the limit passes and a longer one names both numbers" do
    limit = SocketPath.max_bytes()

    assert SocketPath.check(String.duplicate("a", limit)) == :ok

    over = String.duplicate("a", limit + 1)
    assert SocketPath.check(over) == {:error, {:path_too_long, limit + 1, limit}}
  end

  # Byte length, not character length: a multi-byte home directory name eats the
  # budget at the rate the kernel charges for it.
  test "the measurement counts bytes rather than characters" do
    limit = SocketPath.max_bytes()
    path = String.duplicate("é", limit)

    assert SocketPath.check(path) == {:error, {:path_too_long, limit * 2, limit}}
  end

  test "the refusal names the socket, both numbers and the one fix" do
    sentence = SocketPath.refusal("daemon.sock", 140, 107)

    assert sentence ==
             "the daemon.sock path is 140 bytes, over the 107-byte limit this OS allows " <>
               "for a unix socket address — set a shorter FERMIX_HOME and restart"
  end
end
