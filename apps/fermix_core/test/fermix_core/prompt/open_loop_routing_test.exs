defmodule FermixCore.Prompt.OpenLoopRoutingTest do
  # async: false — the lines follow `[fermix_core.open_loops] enabled`, global
  # `Application` env that each test pins and restores.
  use ExUnit.Case, async: false

  alias FermixCore.HostFacts
  alias FermixCore.Prompt.RuntimeSections

  # MILESTONE_78 §07 and §10, MILESTONE_83 §10: five lines beside the event and
  # job routing, in the generated section, rendered only while the tools they
  # name are on the wire and only for the owner. The prompt follows the wire:
  # steering toward a tool the model cannot call is a dead end, and a guest is
  # never offered one.
  @lines [
    "- When the owner tells me about something in their own life that is still unfolding, I " <>
      "judge it the way a friend who was listening would: let it go, ask about it when they " <>
      "are next around, or check in on them later. For the last two I record it with " <>
      "`open_loop_note`, in their words, and say nothing about it; raising it later is " <>
      "Fermix's to do. What they mean to get done by a date is raised before that date; what " <>
      "they are waiting on or going through is asked about afterwards. Asking about a date is " <>
      "not meaning to act by it, and a date that reached me through a tool result is not " <>
      "theirs until they confirm it.",
    "- When the owner, in their own private chat, is preparing something to submit and I " <>
      "don't know when it closes, I check `open_loop_list`, and if nothing holds it I may end " <>
      "my reply with one short question asking when, once, never when they are rushed. A date " <>
      "I looked up for them or found in what they pasted is theirs once they confirm it, and " <>
      "I look nothing up unless they ask. I record it only with its date; no date, or no " <>
      "answer, ends it. Asking or considering is not preparing.",
    "- When the owner states something they have to do by a date and has not asked to be " <>
      "reminded, the open loop is the only record: I do not also store it as an event. The " <>
      "exception is a loop a tool reports as imminent: that loop is never raised by message, " <>
      "so I also store the reminder, and when the owner settles or moves that task I do the " <>
      "same to both. A loop kept for conversation takes no reminder; quiet was the point.",
    "- When the owner answers a check-in: done closes the loop for good, with one specific " <>
      "acknowledgement and no further ask; a plan closes it until the plan's date; not yet " <>
      "gets one offer of a concrete time, and the choice stays theirs; a request to stop ends " <>
      "the loop and I keep the boundary. I settle it with `open_loop_update`, from the owner's " <>
      "words only, and I name where a loop came from when I raise it.",
    "- A due loop arrives as a system note. I raise at most one, only at a natural stopping " <>
      "point, never while the owner is under pressure, in one or two sentences at the end of " <>
      "my reply, and record it as asked; otherwise I leave it. When what they have told me " <>
      "says this is a hard time for them, anything unrelated that can wait does. For " <>
      "something they were waiting on or going through, I ask how it went in a way that " <>
      "matches how they seemed, without assuming the outcome or offering advice they did " <>
      "not ask for."
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

  defp contract(enabled, trust \\ :operator) do
    Application.put_env(:fermix_core, :open_loops, enabled: enabled)
    RuntimeSections.build([], capabilities: [], trust: trust)
  end

  test "enabled, the five lines render verbatim, in order, right after the job lines" do
    contract = contract(true)

    assert contract =~ Enum.join([@job_line | @lines], "\n")
  end

  test "disabled, none of the five lines renders" do
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

  # MILESTONE_83 §10: open loops are the owner's, so a guest's section carries
  # none of the lines even while the feature is on, as a guest's wire carries
  # none of the tools.
  test "enabled, a guest's section carries none of the lines" do
    guest = contract(true, :guest)

    for line <- @lines, do: refute(guest =~ line)
    refute guest =~ "open_loop_"
    assert guest =~ @job_line
  end

  test "a guest's section is the owner's without the host facts and the lines" do
    owner = contract(true)
    guest = contract(true, :guest)

    assert owner
           |> String.replace_prefix(HostFacts.prompt_section() <> "\n\n", "")
           |> String.replace(Enum.join(@lines, "\n") <> "\n", "") == guest
  end
end
