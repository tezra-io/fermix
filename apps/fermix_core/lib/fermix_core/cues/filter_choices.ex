defmodule FermixCore.Cues.FilterChoices do
  @moduledoc """
  What a surface offers for the Cues filter model (M60 §8.2): the default, the
  main model, which every filter runs on while none is set, named by what it
  resolves to (M60_CUE_INTAKE_AT_SCALE.md §3.7), and the providers that are set
  up, with their catalog models as suggestions. A provider that is not set up
  is not offered: a filter on it would fail at its first call.

  It also offers how items are screened before the filter model reads them
  (`screen_options/1`): by the words to listen for, or by the decision model of
  a provider that is set up, with the sentence both surfaces show beside it
  (`screen_info/0`).

  The one reader behind the setup page's Cues tab and the management `cues`
  section, so both offer the same choices under the same labels. Reads the
  setup snapshot (`ConfigStore.current_snapshot/0`), never application env.
  """

  alias FermixCore.Management.Settings.Source
  alias FermixCore.Providers.DecisionModel
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.PrimaryConfig
  alias FermixCore.Providers.Selection

  @type choice :: %{id: String.t(), label: String.t()}

  @screen_info "How items are screened before the filter model reads them. Words: only an " <>
                 "item containing one of the watcher's words gets through. A decision model " <>
                 "checks each item by its meaning instead, with the watcher's purpose, " <>
                 "instructions and words as hints, in about a third of a second, roughly ten " <>
                 "times faster than a chat model."

  @doc """
  The label of the empty choice, the main model, read from the owner's own
  settings: "Default: your main model (Anthropic · claude-sonnet-5-5)", or the
  provider alone while it has no model chosen.
  """
  @spec main_model_label(Source.snapshot()) :: String.t()
  def main_model_label(snapshot) when is_map(snapshot) do
    providers = Source.core(snapshot, :providers)

    case PrimaryConfig.primary_in(providers, Source.core(snapshot, :agent)) do
      {:ok, provider} ->
        "Default: your main model (#{route_label(provider, Source.provider(snapshot, provider))})"

      {:error, :multiple_primary} ->
        "Default: your main model"
    end
  end

  @doc "The providers that are set up, in catalog order, each labelled by its descriptor."
  @spec providers(Source.snapshot()) :: [choice()]
  def providers(snapshot) when is_map(snapshot) do
    ModelCatalog.providers()
    |> Enum.filter(&Selection.configured?(&1, Source.provider(snapshot, &1)))
    |> Enum.map(&%{id: Atom.to_string(&1), label: Descriptor.fetch!(&1).label})
  end

  @doc """
  The catalog's models for `provider` as suggestions; none for an unknown name
  or a provider whose list is the account's own.
  """
  @spec models(String.t()) :: [choice()]
  def models(provider) when is_binary(provider) do
    case Enum.find(ModelCatalog.providers(), &(Atom.to_string(&1) == provider)) do
      nil -> []
      id -> Enum.map(ModelCatalog.models_for(id), &%{id: &1.id, label: &1.label})
    end
  end

  @doc "The sentence a surface shows beside the screen choice."
  @spec screen_info() :: String.t()
  def screen_info, do: @screen_info

  @doc """
  The decision models a screen can use: one for each provider that serves one
  (`Providers.DecisionModel.providers/0`) and is set up, primary or not, in
  catalog order, labelled "OpenAI · gpt-6-luna". The words are the empty
  choice, which a surface offers first.
  """
  @spec screen_options(Source.snapshot()) :: [choice()]
  def screen_options(snapshot) when is_map(snapshot) do
    DecisionModel.providers()
    |> Enum.filter(&Selection.configured?(&1, Source.provider(snapshot, &1)))
    |> Enum.map(&%{id: Atom.to_string(&1), label: DecisionModel.label(&1)})
  end

  defp route_label(provider, block) do
    label = Descriptor.fetch!(provider).label

    case ModelCatalog.effective_model(provider, block) do
      "" -> label
      model -> "#{label} · #{model}"
    end
  end
end
