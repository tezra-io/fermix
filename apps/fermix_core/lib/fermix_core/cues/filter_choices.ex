defmodule FermixCore.Cues.FilterChoices do
  @moduledoc """
  What a surface offers for the Cues filter model (M60 §8.2): the default, the
  main model, which every filter runs on while none is set, named by what it
  resolves to (M60_CUE_INTAKE_AT_SCALE.md §3.7), and the providers that are set
  up, with their catalog models as suggestions. A provider that is not set up
  is not offered: a filter on it would fail at its first call.

  It also offers how items are checked before the filter model reads them
  (`screen_choices/1`): keyword match, or a decision model, with the sentence
  both surfaces show beside them (`screen_info/0`); and which decision model
  that is (`decision_provider_choices/1`, `decision_provider_info/0`):
  Automatic, the one Fermix picks (`decision_model/1`), or a provider the
  owner chooses. A decision model counts as set up only with a key that
  loaded (`decision_model_set_up?/2`), so no surface offers one whose call
  would carry a secret's sentinel.

  The one reader behind the setup page's Cues tab and the management `cues`
  section, so both offer the same choices under the same labels. Reads the
  setup snapshot (`ConfigStore.current_snapshot/0`), never application env.
  """

  alias FermixCore.Cues.Config, as: CuesConfig
  alias FermixCore.Management.Settings.Source
  alias FermixCore.Providers.DecisionModel
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.PrimaryConfig
  alias FermixCore.Providers.Selection

  @type choice :: %{id: String.t(), label: String.t()}
  @type screen_choice :: %{
          id: String.t(),
          label: String.t(),
          hint: String.t() | nil,
          disabled?: boolean()
        }

  @screen_info "How items are checked before the filter model reads them. Keyword match: an " <>
                 "item must contain one of the watcher's keywords. Decision model: each item " <>
                 "is checked by its meaning, with the watcher's purpose, instructions and " <>
                 "keywords as hints, in about a third of a second, roughly ten times faster " <>
                 "than a chat model."
  @decision_provider_info "Which decision model checks items while the screen uses one, on " <>
                            "that provider's own key. Automatic: your main provider's when it " <>
                            "serves one, otherwise the first set up of OpenAI, OpenRouter and " <>
                            "Venice."
  @no_decision_model "Set up OpenAI, OpenRouter or Venice first."
  @provider_not_set_up "Set up this provider first."

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
  The two screens, keyword match first. The decision model's hint names the
  one the screen uses, the owner's choice or else the one Fermix picks ("Uses
  OpenAI · gpt-6-luna"), or, while the owner's choice is not set up, what to
  set up (`decision_model_not_set_up/1`); while none is set up it is disabled,
  with the hint that says what to set up.
  """
  @spec screen_choices(Source.snapshot()) :: [screen_choice()]
  def screen_choices(snapshot) when is_map(snapshot) do
    chosen =
      case CuesConfig.decision_provider(CuesConfig.normalize(Source.core(snapshot, :cues))) do
        nil -> nil
        provider -> {provider, decision_model_set_up?(snapshot, provider)}
      end

    [
      %{id: "keyword", label: "Keyword match", hint: nil, disabled?: false},
      decision_model_choice(decision_model(snapshot), chosen)
    ]
  end

  defp decision_model_choice(nil, _chosen),
    do: %{
      id: "decision_model",
      label: "Decision model",
      hint: @no_decision_model,
      disabled?: true
    }

  defp decision_model_choice(%{label: label}, nil), do: decision_model_hint("Uses #{label}")

  defp decision_model_choice(_automatic, {chosen, true}),
    do: decision_model_hint("Uses #{DecisionModel.label(chosen)}")

  defp decision_model_choice(_automatic, {chosen, false}),
    do: decision_model_hint(decision_model_not_set_up(chosen))

  defp decision_model_hint(hint),
    do: %{id: "decision_model", label: "Decision model", hint: hint, disabled?: false}

  @doc """
  What to set up before the owner's chosen decision model can run: the
  screen's hint while it is not set up, and the save's refusal.
  """
  @spec decision_model_not_set_up(DecisionModel.provider()) :: String.t()
  def decision_model_not_set_up(provider) when is_atom(provider) do
    "Set up #{Descriptor.fetch!(provider).label} first: the screen's decision model runs on " <>
      "its key."
  end

  @doc """
  The decision model Automatic runs on, picked from the snapshot as
  `Providers.DecisionModel.pick/2` picks it at the call, with its label
  ("OpenAI · gpt-6-luna"), or nil while no provider that serves one is set up.
  """
  @spec decision_model(Source.snapshot()) ::
          %{provider: DecisionModel.provider(), label: String.t()} | nil
  def decision_model(snapshot) when is_map(snapshot) do
    primary =
      PrimaryConfig.primary_in(Source.core(snapshot, :providers), Source.core(snapshot, :agent))

    case DecisionModel.pick(primary, &decision_model_set_up?(snapshot, &1)) do
      {:ok, provider} -> %{provider: provider, label: DecisionModel.label(provider)}
      {:error, :not_set_up} -> nil
    end
  end

  @doc """
  Whether `provider`'s decision model can run, read from the snapshot: set up,
  with a key that loaded (`Providers.DecisionModel.ready?/2`).
  """
  @spec decision_model_set_up?(Source.snapshot(), DecisionModel.provider()) :: boolean()
  def decision_model_set_up?(snapshot, provider) when is_map(snapshot) and is_atom(provider),
    do: DecisionModel.ready?(provider, Source.provider(snapshot, provider))

  @doc "The sentence a surface shows beside the screen's decision model."
  @spec decision_provider_info() :: String.t()
  def decision_provider_info, do: @decision_provider_info

  @doc """
  Which decision model the screen uses: Automatic first (`""`), labelled with
  what it resolves to ("Automatic (Uses OpenAI · gpt-6-luna)"), or disabled
  with what to set up while none is set up; then every provider that serves
  one ("OpenRouter · Jev"), one not set up disabled with its hint, so a saved
  choice is always among them.
  """
  @spec decision_provider_choices(Source.snapshot()) :: [screen_choice()]
  def decision_provider_choices(snapshot) when is_map(snapshot) do
    providers =
      Enum.map(
        DecisionModel.providers(),
        &provider_choice(&1, decision_model_set_up?(snapshot, &1))
      )

    [automatic_choice(decision_model(snapshot)) | providers]
  end

  defp automatic_choice(nil),
    do: %{id: "", label: "Automatic", hint: @no_decision_model, disabled?: true}

  defp automatic_choice(%{label: label}),
    do: %{id: "", label: "Automatic (Uses #{label})", hint: nil, disabled?: false}

  defp provider_choice(provider, set_up?),
    do: %{
      id: Atom.to_string(provider),
      label: DecisionModel.label(provider),
      hint: if(set_up?, do: nil, else: @provider_not_set_up),
      disabled?: not set_up?
    }

  defp route_label(provider, block) do
    label = Descriptor.fetch!(provider).label

    case ModelCatalog.effective_model(provider, block) do
      "" -> label
      model -> "#{label} · #{model}"
    end
  end
end
