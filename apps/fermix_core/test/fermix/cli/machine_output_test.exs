defmodule Fermix.CLI.MachineOutputTest do
  @moduledoc "The machine-mode envelope shared by every `--json` verb (M38 §4.6)."

  use ExUnit.Case, async: true

  alias Fermix.CLI.MachineOutput

  test "the success envelope is exactly the published shape" do
    assert MachineOutput.ok(%{"active" => true}) ==
             ~s({"ok":true,"result":{"active":true},"schema_version":1})

    assert Jason.decode!(MachineOutput.ok(%{"active" => true})) == %{
             "schema_version" => 1,
             "ok" => true,
             "result" => %{"active" => true}
           }
  end

  test "the failure envelope carries one code and one sentence" do
    assert Jason.decode!(MachineOutput.error(:user_manager_unreachable)) == %{
             "schema_version" => 1,
             "ok" => false,
             "error" => %{
               "code" => "user_manager_unreachable",
               "sentence" => MachineOutput.sentence(:user_manager_unreachable)
             }
           }
  end

  test "a code outside the published vocabulary raises rather than inventing one" do
    assert_raise FunctionClauseError, fn -> MachineOutput.error(:not_a_code) end
  end

  # Every code the CLI can print has a sentence, and a missing one is a compile-
  # time-shaped hole that only shows at the moment an operator needs the words.
  test "every published code renders a sentence" do
    details = [
      reason: "The service home must be an absolute path.",
      path: "/home/o/.config/systemd/user/fermix.service",
      home: "/home/o/.fermix",
      user: "operator",
      output: "Access denied"
    ]

    for code <- MachineOutput.codes() do
      sentence = MachineOutput.sentence(code, details)

      assert is_binary(sentence) and sentence != "", "#{code} has no sentence"

      assert Jason.decode!(MachineOutput.error(code, details))["error"]["code"] ==
               Atom.to_string(code)
    end
  end

  # The sentences are read by a person in a terminal and in a desktop dialog.
  # Internal vocabulary in them is a support ticket nobody can answer.
  test "no sentence leaks an internal term" do
    details = [reason: "r", path: "/p", home: "/h", user: "u", output: "o"]
    internal = ~w(linux_package standalone macos_app systemd_environment BuildInfo GenServer)

    for code <- MachineOutput.codes(), term <- internal do
      refute MachineOutput.sentence(code, details) =~ term, "#{code} names #{term}"
    end
  end

  test "the service manager's own words reach the operator" do
    sentence = MachineOutput.sentence(:systemctl_failed, output: "Failed to enable unit.")

    assert sentence =~ "Failed to enable unit."
  end

  test "an absent output leaves no dangling clause" do
    assert MachineOutput.sentence(:systemctl_failed, []) ==
             "The service manager refused the change."
  end

  test "the linger refusal names the account's own enable-linger command" do
    sentence = MachineOutput.sentence(:linger_denied, user: "operator", output: "Access denied")

    assert sentence =~ "sudo loginctl enable-linger operator"
    assert sentence =~ "Access denied"
  end

  test "an invalid home speaks with the binding's own sentence" do
    assert MachineOutput.sentence(:invalid_home, reason: "The service home must be absolute.") ==
             "The service home must be absolute."
  end
end
