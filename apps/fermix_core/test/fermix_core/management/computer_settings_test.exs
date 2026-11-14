defmodule FermixCore.Management.ComputerSettingsTest do
  # M97 §19 (D28, D28a): what a linked computer lists as its own, what it
  # takes from its server's list, and the prefix on its own answers.
  use ExUnit.Case, async: true

  alias FermixCore.Management.ComputerSettings

  @inventory [
    %{"id" => "providers.openai", "pane" => "providers", "title" => "OpenAI"},
    %{"id" => "accessories", "pane" => "voice", "title" => "StackChan"},
    %{"id" => "computer_use", "pane" => "computer", "title" => "Computer use"},
    %{"id" => "computer_history", "pane" => "computer", "title" => "Computer history"},
    %{"id" => "sandbox", "pane" => "sandbox", "title" => "Sandbox"},
    %{"id" => "browser", "pane" => "browser", "title" => "Browser"},
    %{"id" => "computer", "pane" => "always_on", "title" => "This computer"}
  ]

  test "a Mac lists its own sections in This Mac's order, under always_on, titled for itself" do
    assert ComputerSettings.own_sections(@inventory, macos?: true, computer?: true) == [
             %{"id" => "computer", "pane" => "always_on", "title" => "This computer"},
             %{
               "id" => "computer.sandbox",
               "pane" => "always_on",
               "title" => "Sandbox on this Mac"
             },
             %{
               "id" => "computer.browser",
               "pane" => "always_on",
               "title" => "Browser on this Mac"
             },
             %{
               "id" => "computer.computer_use",
               "pane" => "always_on",
               "title" => "Computer use on this Mac"
             },
             %{
               "id" => "computer.computer_history",
               "pane" => "always_on",
               "title" => "Computer history on this Mac"
             },
             %{
               "id" => "computer.accessories",
               "pane" => "always_on",
               "title" => "StackChan on this Mac"
             }
           ]
  end

  test "a Linux computer publishes no history of its own yet, and an engine with no area none" do
    ids =
      @inventory
      |> ComputerSettings.own_sections(macos?: false, computer?: true)
      |> Enum.map(& &1["id"])

    refute "computer.computer_history" in ids
    assert "computer.sandbox" in ids

    assert ComputerSettings.own_sections(@inventory, macos?: true, computer?: false) == []
  end

  test "the server's list loses every computer id it names, and its machine sections are named" do
    server = [
      %{"id" => "routing", "pane" => "providers", "title" => "Model behavior"},
      %{"id" => "harness_machine", "pane" => "coding", "title" => "This server"},
      %{"id" => "sandbox", "pane" => "sandbox", "title" => "Sandbox"},
      %{"id" => "browser", "pane" => "browser", "title" => "Browser"},
      %{"id" => "computer", "pane" => "always_on", "title" => "This computer"},
      %{"id" => "computer.sandbox", "pane" => "always_on", "title" => "Not believed"}
    ]

    assert ComputerSettings.server_sections(server, %{
             name: "garden server",
             machine_settings: true
           }) == [
             %{"id" => "routing", "pane" => "providers", "title" => "Model behavior"},
             %{"id" => "harness_machine", "pane" => "coding", "title" => "garden server"},
             %{"id" => "sandbox", "pane" => "sandbox", "title" => "Sandbox on garden server"},
             %{"id" => "browser", "pane" => "browser", "title" => "Browser on garden server"}
           ]

    # A server without the rule serves its browser as the home's, as before
    # the rule, and none of its other machine sections.
    assert ComputerSettings.server_sections(server, %{name: nil, machine_settings: false}) == [
             %{"id" => "routing", "pane" => "providers", "title" => "Model behavior"},
             %{"id" => "browser", "pane" => "browser", "title" => "Browser on your server"}
           ]

    assert ComputerSettings.server_title("browser", "Browser", nil) == "Browser on your server"
  end

  # A primary that is a Mac (one that took the home back, beside a second
  # linked computer) lists its screen, history and StackChan; they are its
  # own, so another computer lists none of them.
  test "a primary's own screen, history and accessories are never listed from it" do
    mac_primary = [
      %{"id" => "routing", "pane" => "providers", "title" => "Model behavior"},
      %{"id" => "computer_use", "pane" => "computer", "title" => "Computer use"},
      %{"id" => "computer_history", "pane" => "computer", "title" => "Computer history"},
      %{"id" => "accessories", "pane" => "voice", "title" => "StackChan"}
    ]

    for rule? <- [true, false] do
      assert ComputerSettings.server_sections(mac_primary, %{
               name: "studio Mac",
               machine_settings: rule?
             }) == [%{"id" => "routing", "pane" => "providers", "title" => "Model behavior"}]
    end
  end

  test "a computer id is answered under its plain id, and its answer carries the prefix" do
    opts = [macos?: true, computer?: true]

    assert ComputerSettings.plain("computer.sandbox", opts) == {:ok, "sandbox"}
    assert ComputerSettings.plain("computer", opts) == {:ok, "computer"}
    assert ComputerSettings.plain("routing", opts) == {:ok, "routing"}
    assert ComputerSettings.plain("computer.routing", opts) == :none
    assert ComputerSettings.plain("computer.harness_machine", opts) == :none
    assert ComputerSettings.plain("computer.sandbox", macos?: true, computer?: false) == :none

    # `computer` is published as itself, never as `computer.computer`.
    assert ComputerSettings.plain("computer.computer", opts) == :none
    assert ComputerSettings.plain("computer.computer.sandbox", opts) == :none

    assert ComputerSettings.plain_secret("computer.env:LEDGER_TOKEN", opts) ==
             {:ok, "env:LEDGER_TOKEN"}

    assert ComputerSettings.plain_secret("env:GARDEN_TOKEN", opts) == {:ok, "env:GARDEN_TOKEN"}
    assert ComputerSettings.plain_secret("computer.anthropic_api_key", opts) == :none

    view = %{
      "id" => "sandbox",
      "title" => "Sandbox",
      "rows" => [
        %{"key" => "sandbox_mode", "kind" => "choice"},
        %{"key" => "env:LEDGER_TOKEN", "kind" => "secret"}
      ]
    }

    assert ComputerSettings.own_view(view, "computer.sandbox", opts) == %{
             "id" => "computer.sandbox",
             "title" => "Sandbox on this Mac",
             "rows" => [
               %{"key" => "sandbox_mode", "kind" => "choice"},
               %{"key" => "computer.env:LEDGER_TOKEN", "kind" => "secret"}
             ]
           }

    assert ComputerSettings.own_view(view, "sandbox", opts) == view

    assert ComputerSettings.own_result(
             {:error, :external_change, %{"section" => "sandbox"}},
             "computer.sandbox"
           ) == {:error, :external_change, %{"section" => "computer.sandbox"}}

    assert ComputerSettings.own_result({:ok, %{"id" => "env:X"}}, "computer.env:X") ==
             {:ok, %{"id" => "computer.env:X"}}

    # A refusal of this computer's own write names this computer's section,
    # whatever the id written, so the reload it asks for is answered here.
    assert ComputerSettings.own_result(
             {:error, :external_change, %{"section" => "sandbox"}},
             "computer.env:LEDGER_TOKEN"
           ) == {:error, :external_change, %{"section" => "computer.sandbox"}}

    assert ComputerSettings.own_result(
             {:error, :external_change, %{"section" => "browser"}},
             "computer"
           ) == {:error, :external_change, %{"section" => "computer.browser"}}

    assert ComputerSettings.own_result(
             {:error, :external_change, %{"section" => "computer"}},
             "computer"
           ) == {:error, :external_change, %{"section" => "computer"}}

    assert ComputerSettings.own_result(
             {:error, :external_change, %{"section" => "sandbox"}},
             "env:GARDEN_TOKEN"
           ) == {:error, :external_change, %{"section" => "sandbox"}}

    assert ComputerSettings.own_result({:ok, %{"id" => "sandbox"}}, "sandbox") ==
             {:ok, %{"id" => "sandbox"}}
  end
end
