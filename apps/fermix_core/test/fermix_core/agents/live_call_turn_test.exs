defmodule FermixCore.Agents.LiveCallTurnTest do
  use ExUnit.Case, async: true

  alias FermixCore.Agents.LiveCallTurn

  @call %{started_at: ~U[2026-10-03 14:05:00Z], silence_allowed?: true}

  test "no call, no line" do
    assert LiveCallTurn.note(nil) == nil
  end

  test "the sentinel ends a turn silently only where the snapshot allowed it" do
    assert LiveCallTurn.silent?(@call, "[SILENT]")
    assert LiveCallTurn.silent?(@call, "  [SILENT]\n")
    refute LiveCallTurn.silent?(%{@call | silence_allowed?: false}, "[SILENT]")
    refute LiveCallTurn.silent?(nil, "[SILENT]")
    refute LiveCallTurn.silent?(@call, "[SILENT] noted")
    refute LiveCallTurn.silent?(@call, "Noted.")
  end

  test "a draft is held back only while it could still become the sentinel" do
    for draft <- ["", "[", "[SIL", "[SILENT]", "\n[SILENT]\n"] do
      assert LiveCallTurn.sentinel_prefix?(draft), "#{inspect(draft)} was not held"
    end

    for draft <- ["S", "[N", "[SILENT] and more", "Sure"] do
      refute LiveCallTurn.sentinel_prefix?(draft), "#{inspect(draft)} was held"
    end
  end
end
