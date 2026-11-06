defmodule Fermix.CLI.AlwaysOnCommand.Render do
  @moduledoc """
  The words `fermix always-on` prints, from what the engine answered
  (Always On setup §8.2). Pure: every function takes a summary, a record
  or an answer and returns lines; nothing here reads or writes.

  Every sentence, label, Details line and confirm is the engine's, printed
  as it came. What is the CLI's own is how it draws them: the step's command
  (`fermix always-on move-now`), the numbers of the menu, and the frame
  around the own-server code. An
  action's id is printed in its kebab form, the one the command takes.
  """

  alias FermixCore.Management.HomeSummary

  # The one-sentence fields of `detail` a screen prints under its sentence,
  # in this order, wherever the state carries them.
  @text_fields ~w(progress note data)
  @warnings ~w(warn block)

  @doc "An action id as the command takes it: `move_now` → `move-now`."
  @spec kebab(String.t()) :: String.t()
  def kebab(id) when is_binary(id), do: String.replace(id, "_", "-")

  @doc """
  The screen: the sentence, the step in hand and the other one-sentence
  fields, each warning or block of the review, Details, then the Tailscale
  Funnel mounts the server needs, each command on a line of its own under
  its label, with its note under it.
  """
  @spec screen(map()) :: [String.t()]
  def screen(%{"sentence" => sentence} = summary) do
    detail = summary["detail"] || %{}

    [sentence] ++
      Enum.flat_map(@text_fields, &List.wrap(detail[&1])) ++
      readiness(detail["readiness"] || []) ++
      details(detail["lines"] || []) ++ webhooks(detail["webhooks"])
  end

  defp webhooks(nil), do: []

  defp webhooks(%{"sentence" => sentence, "mounts" => mounts, "notes" => notes}) do
    commands =
      Enum.flat_map(mounts, &["  #{&1["label"]}:", "    #{&1["command"]}", "  #{&1["note"]}"])

    [sentence] ++ commands ++ notes
  end

  defp readiness(items) do
    for %{"status" => status, "sentence" => sentence} <- items,
        status in @warnings,
        do: "- " <> sentence
  end

  defp details([]), do: []

  defp details(lines),
    do: ["Details:" | Enum.map(lines, fn %{"label" => l, "value" => v} -> "  #{l}: #{v}" end)]

  @doc "Each step the screen offers, with what takes it: its command, or the page it opens."
  @spec steps(map()) :: [String.t()]
  def steps(summary) do
    case HomeSummary.offered(summary) do
      [] -> []
      records -> ["Steps:" | Enum.map(records, &"  #{&1["label"]}: #{taken_by(&1)}")]
    end
  end

  defp taken_by(%{"id" => "update"}), do: "fermix upgrade"
  defp taken_by(%{"url" => url}) when is_binary(url), do: url
  defp taken_by(%{"id" => id}), do: "fermix always-on " <> kebab(id)

  @doc "What a step the surface opens itself prints: its page, or this computer's updater."
  @spec opened(map()) :: String.t()
  def opened(%{"id" => "update"}),
    do: "Update Fermix on this computer with fermix upgrade, then run fermix always-on again."

  def opened(%{"url" => url}) when is_binary(url), do: url

  @doc "The steps numbered, the summary's own action first."
  @spec menu([map()]) :: [String.t()]
  def menu(records) do
    records |> Enum.with_index(1) |> Enum.map(fn {r, i} -> "  #{i}. #{r["label"]}" end)
  end

  @doc "The prompt under the menu: Enter takes the summary's action, when it has one."
  @spec menu_prompt(map()) :: String.t()
  def menu_prompt(%{"action" => %{"label" => label}}), do: "Step (Enter: #{label}, q: quit): "
  def menu_prompt(_summary), do: "Step (q: quit): "

  @doc """
  What a step answered beyond its screen: the own-server code, shown this
  once, under the command and the optional Tailscale step's.
  """
  @spec result(map() | nil) :: [String.t()]
  def result(%{"code" => code, "expires_at" => until, "command" => command} = result) do
    %{"sentence" => tailscale, "command" => joins} = result["tailscale"]

    [
      "On your server, run:",
      "  " <> command,
      tailscale,
      "  " <> joins,
      "When it asks for the enrollment code, paste this one. It works once, until #{until}:",
      "  " <> code
    ]
  end

  def result(_result), do: []

  @doc "The one line a wait prints when the screen moves: its sentence and the step in hand."
  @spec progress(map()) :: String.t()
  def progress(%{"sentence" => sentence} = summary) do
    case (summary["detail"] || %{})["progress"] do
      progress when is_binary(progress) -> sentence <> " " <> progress
      _none -> sentence
    end
  end
end
