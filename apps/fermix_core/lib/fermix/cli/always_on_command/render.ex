defmodule Fermix.CLI.AlwaysOnCommand.Render do
  @moduledoc """
  The words `fermix always-on` prints, from what the engine answered
  (Always On setup §8.2). Pure: every function takes a summary, a record
  or an answer and returns lines; nothing here reads or writes.

  Every sentence, label, Details line and confirm is the engine's, printed
  as it came. What is the CLI's own is how it draws them: the step's
  command (`fermix always-on create-server`), the numbered menu, the list
  of sizes and places, and the frame around the own-server code. An
  action's id is printed in its kebab form, the one the command takes.
  """

  # The one-sentence fields of `detail` a screen prints under its sentence,
  # in this order, wherever the state carries them.
  @text_fields ~w(progress note billing data)
  @warnings ~w(warn block)

  @doc "An action id as the command takes it: `create_server` → `create-server`."
  @spec kebab(String.t()) :: String.t()
  def kebab(id) when is_binary(id), do: String.replace(id, "_", "-")

  @doc "Every action record the summary offers: its action, then the alternatives and actions."
  @spec records(map()) :: [map()]
  def records(%{} = summary) do
    detail = summary["detail"] || %{}
    List.wrap(summary["action"]) ++ (detail["alternatives"] || []) ++ (detail["actions"] || [])
  end

  @doc """
  The screen: the sentence, the step in hand and the other one-sentence
  fields, each warning or block of the review, then Details.
  """
  @spec screen(map()) :: [String.t()]
  def screen(%{"sentence" => sentence} = summary) do
    detail = summary["detail"] || %{}

    [sentence] ++
      Enum.flat_map(@text_fields, &List.wrap(detail[&1])) ++
      readiness(detail["readiness"] || []) ++ details(detail["lines"] || [])
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
    case records(summary) do
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

  @doc "A provider's token screen, as `detail.providers` gives it."
  @spec token_screen(map()) :: [String.t()]
  def token_screen(provider) do
    steps =
      (provider["steps"] || [])
      |> Enum.with_index(1)
      |> Enum.map(fn {step, i} -> "  #{i}. #{step}" end)

    console = if provider["console_url"], do: ["Console: #{provider["console_url"]}"], else: []
    docs = if provider["docs_url"], do: ["Docs: #{provider["docs_url"]}"], else: []
    List.wrap(provider["sentence"]) ++ steps ++ console ++ docs
  end

  @doc "The providers to pick from, numbered."
  @spec provider_menu([map()]) :: [String.t()]
  def provider_menu(providers) do
    providers |> Enum.with_index(1) |> Enum.map(fn {p, i} -> "  #{i}. #{p["name"]}" end)
  end

  @doc """
  The sizes and places `home.provision.options` answered, numbered with the
  recommendation first, and what each number chooses: `:recommended` (Fermix
  takes its own recommendation) or `{type, location}`.
  """
  @spec offers(map()) :: {[String.t()], [:recommended | {String.t(), String.t()}]}
  def offers(%{"offers" => offers, "recommended" => recommended} = options) do
    {first, rest} = Enum.split_with(offers, &same_offer?(&1, recommended))
    cities = Map.new(options["locations"] || [], &{&1["id"], &1["city"]})

    priced =
      Enum.map(first, &{&1, " (recommended)", :recommended}) ++
        Enum.map(rest, &{&1, "", choice(&1)})

    lines =
      priced
      |> Enum.with_index(1)
      |> Enum.map(fn {{offer, mark, _choice}, i} ->
        "  #{i}. #{offer_line(offer, cities, options["currency"])}#{mark}"
      end)

    {[options["sentence"] | lines], Enum.map(priced, &elem(&1, 2))}
  end

  defp same_offer?(offer, %{"type" => type, "location" => location}),
    do: offer["type"] == type and offer["location"] == location

  defp same_offer?(_offer, nil), do: false

  defp choice(offer), do: {offer["type"], offer["location"]}

  defp offer_line(offer, cities, currency) do
    city = Map.get(cities, offer["location"], offer["location"])
    dedicated = if offer["dedicated"], do: ", dedicated cores", else: ""

    "#{offer["description"]} in #{city}: #{offer["cores"]} cores, #{offer["memory_gb"]} GB " <>
      "memory, #{offer["disk_gb"]} GB disk#{dedicated}, #{offer["total_monthly"]} #{currency} a month"
  end

  @doc "What a step answered beyond its screen: the own-server code, shown this once."
  @spec result(map() | nil) :: [String.t()]
  def result(%{"code" => code, "expires_at" => until, "command" => command}) do
    [
      "On your server, run:",
      "  " <> command,
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
