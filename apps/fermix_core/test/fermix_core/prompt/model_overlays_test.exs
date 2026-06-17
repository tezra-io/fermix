defmodule FermixCore.Prompt.ModelOverlaysTest do
  use ExUnit.Case, async: true

  alias FermixCore.Prompt.ModelOverlays

  test "apply_codex/1 appends the behavior contract at the END (prefix stays byte-stable)" do
    instructions = "IDENTITY\n\nFERMIX rules"
    applied = ModelOverlays.apply_codex(instructions)

    assert String.starts_with?(applied, instructions)
    assert applied =~ "<tool_discipline>"
    assert applied =~ "</tool_discipline>"
    assert applied =~ "<completion_contract>"
    assert applied =~ "smallest meaningful verification step"
  end

  test "apply_codex/1 is idempotent" do
    once = ModelOverlays.apply_codex("base")
    assert ModelOverlays.apply_codex(once) == once
  end

  test "apply_codex/1 is deterministic (same input, same bytes — cache stability)" do
    assert ModelOverlays.apply_codex("base") == ModelOverlays.apply_codex("base")
  end
end
