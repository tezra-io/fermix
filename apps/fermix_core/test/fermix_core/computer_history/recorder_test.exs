defmodule FermixCore.ComputerHistory.RecorderTest do
  # M97 §8.3, §8.8: whether this system has a recorder is the paired helper's
  # word (`Compux.Protocol.history_systems/0`), never this host's platform
  # alone, and an Always On server, at which nobody sits, has none (§19.2).
  use ExUnit.Case, async: true

  alias FermixCore.ComputerHistory

  test "a Mac has a recorder" do
    assert ComputerHistory.recorder?(system: :macos, server?: false)
  end

  test "a Linux computer has one exactly where its paired helper records there" do
    assert ComputerHistory.recorder?(system: :linux, server?: false)
    refute ComputerHistory.recorder?(system: :linux, server?: false, history_systems: [:macos])
  end

  test "this release's helper records on macOS and Linux" do
    assert Compux.Protocol.history_systems() == [:macos, :linux]
  end

  test "an Always On server has none, whatever its system" do
    refute ComputerHistory.recorder?(system: :linux, server?: true)
  end

  test "any other system has none" do
    refute ComputerHistory.recorder?(system: :other, server?: false)
  end
end
