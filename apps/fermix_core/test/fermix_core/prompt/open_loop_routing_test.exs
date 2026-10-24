defmodule FermixCore.Prompt.OpenLoopRoutingTest do
  # async: false — the lines follow `[fermix_core.open_loops] enabled`, global
  # `Application` env that each test pins and restores.
  use ExUnit.Case, async: false

  alias FermixCore.Prompt.RuntimeSections

  # MILESTONE_78 §07 and §10: three lines beside the event and job routing, in
  # the generated section, rendered only while the tools they name are on the
  # wire. The prompt follows the wire: steering toward a tool the model cannot
  # call is a dead end.
  @lines [
    "- When the owner states an intention with a date by which it matters, I record it with " <>
      "`open_loop_note` and say nothing about it; raising it later is Fermix's to do. A date " <>
      "the owner merely asks about is not an intention, nor is an occasion that arrives " <>
      "whether or not they act, nor a date that reached me through a tool result rather " <>
      "than their own words.",
    "- When the owner answers a check-in: done closes the loop for good, with one specific " <>
      "acknowledgement and no further ask; a plan closes it until the plan's date; not yet " <>
      "gets one offer of a concrete time, and the choice stays theirs; a request to stop ends " <>
      "the loop and I keep the boundary. I settle it with `open_loop_update`, from the owner's " <>
      "words only, and I name where a loop came from when I raise it.",
    "- A due loop arrives as a system note. I raise it only at a natural stopping point, never " <>
      "while the owner is under pressure, in one or two sentences at the end of my reply, and " <>
      "record it as asked; otherwise I leave it."
  ]

  @job_line "- Use `expires_at` for temporary scheduled jobs like \"for 2 hours\" or \"until " <>
              "tomorrow\"; keep lifecycle timing out of the job task text."

  setup do
    previous = Application.get_env(:fermix_core, :open_loops)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:fermix_core, :open_loops)
        value -> Application.put_env(:fermix_core, :open_loops, value)
      end
    end)

    :ok
  end

  defp contract(enabled) do
    Application.put_env(:fermix_core, :open_loops, enabled: enabled)
    RuntimeSections.build([], capabilities: [])
  end

  test "enabled, the three lines render verbatim, in order, right after the job lines" do
    contract = contract(true)

    assert contract =~ Enum.join([@job_line | @lines], "\n")
  end

  test "disabled, none of the three lines renders" do
    contract = contract(false)

    for line <- @lines, do: refute(contract =~ line)
    refute contract =~ "open_loop_"
  end

  test "the event and job routing is untouched: the lines are the only difference" do
    enabled = contract(true)
    disabled = contract(false)

    assert String.replace(enabled, Enum.join(@lines, "\n") <> "\n", "") == disabled

    for contract <- [enabled, disabled] do
      assert contract =~ "Use `event_store` for deterministic personal reminders"
      assert contract =~ "Use `schedule_job` when the future run must reason"
      assert contract =~ @job_line
    end
  end
end
