defmodule FermixCore.Computers.RemoteTest do
  # M97 §6.4: what the model reads of a call that ran on a computer. Every
  # result names the computer, so a path is never mistaken for the server's.
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Computers.Computer
  alias FermixCore.Computers.Outcome
  alias FermixCore.Computers.Remote
  alias FermixCore.Computers.ToolResult

  @studio %Computer{device_id: "a1", name: "studio Mac", platform: :macos, connected: true}

  defp ok(result) do
    {json, part} = ToolResult.encode(result)
    %Outcome{status: :ok, result: json, part_bytes: part, target: "notes.txt"}
  end

  # A tool that ran and failed, as a computer answers it: the error's first
  # line as the message, the whole result beside it.
  defp failed(result, message) do
    {json, part} = ToolResult.encode(result)
    %Outcome{status: :failed, message: message, result: json, part_bytes: part}
  end

  test "the tool's own answer follows the computer's name" do
    assert %{success: true, output: "On studio Mac:\nhello"} =
             Remote.result(ok(Tool.success("hello")), @studio)

    error = "File not found: /Users/pat/notes.txt"

    assert %{success: false, error: "On studio Mac: File not found: /Users/pat/notes.txt"} =
             Remote.result(failed(Tool.error(error), error), @studio)
  end

  test "a tool's failure reaches the model whole, not only its first line" do
    output = :binary.copy("b", 300 * 1_024)
    whole = "Command failed (exit code 2):\n" <> output
    outcome = failed(Tool.error(whole), "Command failed (exit code 2):")
    assert is_binary(outcome.part_bytes)

    assert %{success: false, error: error} = Remote.result(outcome, @studio)
    assert error == "On studio Mac: " <> whole
  end

  test "an answer whose status and result disagree is not a tool's result" do
    for outcome <- [
          ok(Tool.error("File not found: /Users/pat/notes.txt")),
          failed(Tool.success("hello"), "It failed.")
        ] do
      assert %{success: false, error: error} = Remote.result(outcome, @studio)
      assert error == "On studio Mac: The computer's answer is not a tool's result."
    end
  end

  test "images come back as the tool gave them, their summary naming the computer" do
    image = %{type: :image, mime_type: "image/png", data: <<9, 9, 9>>}

    assert %{success: true, output: "On studio Mac:\nReference 1", images: [^image]} =
             Remote.result(ok(Tool.success_with_images("Reference 1", [image])), @studio)
  end

  test "a path outside the computer's sandbox is allowed only at that computer" do
    outcome =
      Outcome.refused(:outside_sandbox, "/Users/pat/Private is outside this computer's sandbox.")

    assert %{success: false, error: error} = Remote.result(outcome, @studio)

    assert error ==
             "On studio Mac: /Users/pat/Private is outside this computer's sandbox. Someone at " <>
               "studio Mac can allow the folder; it cannot be allowed from here."
  end

  test "every other ending is the outcome's own sentence, naming the computer" do
    for outcome <- [
          %Outcome{status: :unknown, target: "make release"},
          %Outcome{status: :timed_out, deadline_ms: 40_000},
          %Outcome{status: :cancelled},
          Outcome.refused(:off, "Switched off on this Mac."),
          %Outcome{status: :failed, message: "It stopped before it finished."}
        ] do
      assert %{success: false, error: error} = Remote.result(outcome, @studio)
      assert error == Outcome.sentence(outcome, "studio Mac")
      assert error =~ "studio Mac"
    end
  end

  test "an effect whose answer was lost after it ran says so, and is not an error" do
    outcome = %Outcome{status: :ok, receipt_only: true, target: "make release"}

    assert %{success: true, output: "studio Mac did it, but its answer was lost on the way back."} =
             Remote.result(outcome, @studio)
  end

  test "an answer that is not a tool result fails, naming the computer" do
    outcome = %Outcome{status: :ok, result: %{"kind" => "picture"}}

    assert %{
             success: false,
             error: "On studio Mac: The computer's answer is not a tool's result."
           } =
             Remote.result(outcome, @studio)
  end
end
