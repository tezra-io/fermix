defmodule Fermix.CLI.VersionSkewTest do
  use ExUnit.Case, async: true

  alias Fermix.CLI.VersionSkew

  test "nil when the daemon runs the same version as this binary" do
    assert VersionSkew.note("0.5.7", "0.5.7") == nil
  end

  test "nil when the daemon reply carries no version" do
    assert VersionSkew.note(nil, "0.5.7") == nil
  end

  test "names both versions and the restart fix on a mismatch" do
    note = VersionSkew.note("0.5.6", "0.5.7")

    assert note =~ "daemon is running 0.5.6"
    assert note =~ "installed binary is 0.5.7"
    assert note =~ "`fermix restart`"
  end

  test "defaults the binary side to this build's version" do
    vsn = to_string(Application.spec(:fermix_core, :vsn))

    assert VersionSkew.note(vsn) == nil
    assert VersionSkew.note("0.0.1") =~ "installed binary is #{vsn}"
  end
end
