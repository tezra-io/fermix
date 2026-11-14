defmodule Fermix.CLI.AlwaysOnCommand.Render do
  @moduledoc """
  The words `fermix always-on` prints, from what the engine answered
  (Always On setup §8.2, the Always On pane's R1 to R12). Pure: every
  function takes a summary, a record or an answer and returns lines; nothing
  here reads or writes.

  Every sentence, label, Details line, confirm and page is the engine's,
  printed as it came. What is the CLI's own is how it draws them: the step's
  command (`fermix always-on move-now`), the numbers of the menu, and the
  frame words (`Details:`, `Steps:`, `Code:`, `Learn more:`). An action's id
  is printed in its kebab form, the one the command takes.
  """

  alias FermixCore.Management.HomeSummary

  @doc "An action id as the command takes it: `move_now` → `move-now`."
  @spec kebab(String.t()) :: String.t()
  def kebab(id) when is_binary(id), do: String.replace(id, "_", "-")

  @doc """
  The screen: the sentence, the one secondary sentence (`detail.note`), the
  step in hand with the engine's count beside it while bytes move, each block
  of the review, Details (its lines, then whether the recovery passphrase is
  set where the backup settings show), the Tailscale Funnel mounts the server
  needs (each command on a line of its own under its label, with its note
  under it, then the tailnet's one step and the page that holds the rest),
  and the screen's help page last.
  """
  @spec screen(map()) :: [String.t()]
  def screen(%{"sentence" => sentence} = summary) do
    detail = summary["detail"] || %{}

    [sentence] ++
      List.wrap(detail["note"]) ++
      List.wrap(step_in_hand(detail)) ++
      blocks(detail["readiness"] || []) ++
      details(detail["lines"] || [], detail["backup"]) ++
      webhooks(detail["webhooks"]) ++ help(summary["help"])
  end

  # The step in hand, with the bytes the engine counted beside it.
  defp step_in_hand(%{"progress" => progress, "transfer" => %{"label" => label}})
       when is_binary(progress) and is_binary(label),
       do: progress <> " " <> label

  defp step_in_hand(%{"progress" => progress}) when is_binary(progress), do: progress
  defp step_in_hand(_detail), do: nil

  defp webhooks(nil), do: []

  defp webhooks(%{"sentence" => sentence, "mounts" => mounts, "notes" => notes, "url" => url}) do
    commands =
      Enum.flat_map(mounts, &["  #{&1["label"]}:", "    #{&1["command"]}", "  #{&1["note"]}"])

    [sentence] ++ commands ++ notes ++ help(url)
  end

  defp blocks(items) do
    for %{"status" => "block", "sentence" => sentence} <- items, do: "- " <> sentence
  end

  defp details(lines, backup) do
    printed =
      Enum.map(lines, fn %{"label" => l, "value" => v} -> "  #{l}: #{v}" end) ++
        passphrase(backup)

    if printed == [], do: [], else: ["Details:" | printed]
  end

  defp passphrase(%{"passphrase" => %{"label" => label, "value" => value}}),
    do: ["  #{label}: #{value}"]

  defp passphrase(nil), do: []

  defp help(url) when is_binary(url), do: ["Learn more: " <> url]
  defp help(nil), do: []

  @doc "Each step the screen offers, with what takes it: its command, or this computer's updater."
  @spec steps(map()) :: [String.t()]
  def steps(summary) do
    case HomeSummary.offered(summary) do
      [] -> []
      records -> ["Steps:" | Enum.map(records, &"  #{&1["label"]}: #{taken_by(&1)}")]
    end
  end

  defp taken_by(%{"id" => "update"}), do: "fermix upgrade"
  defp taken_by(%{"id" => id}), do: "fermix always-on " <> kebab(id)

  @doc "What a step the surface opens itself prints: this computer's updater."
  @spec opened(map()) :: String.t()
  def opened(%{"id" => "update"}),
    do: "Update Fermix on this computer with fermix upgrade, then run fermix always-on again."

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
  once, under the engine's sentence for it and the command, then the
  optional Tailscale step under its label; the server's sentence for Restart
  <server>; nothing for a step that answers
  none (null, or a move's `{move_id}`). `own_server`'s is matched whole, the
  code's five fields and then its Tailscale step's four on their own, and any
  other shape raises: the code is answered once, so it is never dropped in
  silence. A refusal names the fields, never the code.
  """
  @spec result(map() | nil) :: [String.t()]
  def result(nil), do: []

  def result(%{"move_id" => id} = result) when is_binary(id) and map_size(result) == 1, do: []

  def result(
        %{
          "code" => code,
          "expires_at" => until,
          "command" => command,
          "sentence" => sentence,
          "tailscale" => step
        } = result
      )
      when is_binary(code) and is_binary(until) and is_binary(command) and is_binary(sentence) and
             map_size(result) == 5 do
    [sentence, "  " <> command, "Code:", "  " <> code] ++ tailscale_lines(step)
  end

  # Add a computer (M97 §3.1): the code a new computer joins with.
  def result(%{"code" => code, "expires_at" => until} = result)
      when is_binary(code) and is_binary(until) and map_size(result) == 2 do
    [
      "On the new computer, connect to a Fermix that already runs and paste this code. It " <>
        "works once, until #{until}:",
      "  " <> code
    ]
  end

  # The computer added (M97 §7.5).
  def result(%{"device_id" => id, "name" => name} = result)
      when is_binary(id) and is_binary(name) and map_size(result) == 2,
      do: ["#{name} is now a computer of your Fermix."]

  # The server's answer to Restart <server> (M97 D28c): now, or once its
  # computers' work ends, in its own sentence.
  def result(%{"when" => moment, "wait_s" => wait_s, "sentence" => sentence} = result)
      when moment in ["now", "after_work"] and is_integer(wait_s) and is_binary(sentence) and
             map_size(result) == 3,
      do: [sentence]

  def result(result), do: raise(ArgumentError, "home.act answered #{shape(result)}")

  defp tailscale_lines(
         %{"label" => label, "sentence" => sentence, "command" => command, "url" => url} = step
       )
       when is_binary(label) and is_binary(sentence) and is_binary(command) and is_binary(url) and
              map_size(step) == 4,
       do: [label <> ":", "  " <> sentence, "    " <> command, "  Learn more: " <> url]

  defp tailscale_lines(step),
    do: raise(ArgumentError, "home.act answered own_server's Tailscale step as #{shape(step)}")

  defp shape(%{} = map),
    do: "a result with the fields #{map |> Map.keys() |> Enum.sort() |> inspect()}"

  defp shape(_other), do: "a result that is no object"

  @doc """
  The one line a wait prints when the screen moves: its sentence and the step
  in hand, with the engine's count beside it while bytes move.
  """
  @spec progress(map()) :: String.t()
  def progress(%{"sentence" => sentence} = summary) do
    case step_in_hand(summary["detail"] || %{}) do
      nil -> sentence
      step -> sentence <> " " <> step
    end
  end
end
