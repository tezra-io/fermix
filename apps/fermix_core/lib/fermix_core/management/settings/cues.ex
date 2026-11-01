defmodule FermixCore.Management.Settings.Cues do
  @moduledoc """
  The `cues` section (M60 app surface §3.2): the cue switches, the door's
  port, how items are screened and by which decision model, and the default
  filter model. Its rows are the scalars; the sources,
  watchers and mandates are the `cues.*` methods (`Management.Cues`), as the
  phone channel has `channels.mobile` beside `mobile.*`.

  Every write goes through
  `Cues.Settings`, the setup page's own functions: the filter pair through
  `save_filter_model/2` in one call (both, or "None" to clear both), the
  screen through `save_screen/1`, its decision model through
  `save_decision_provider/1`, the switches through `save_switches/1`, each
  checked before any is written. The setup page's
  Cues tab saves through `save/1` too. `restart` is derived from
  `Setup.RestartState`, which treats `routing.filter_*` and the mandates
  switch as live and the cue tree's switch and port as boot-bound.

  The filter rows come from `Cues.FilterChoices`, the setup page's own reader:
  the empty value is the default, labelled with the main model it resolves to,
  then only the providers that are set up, and the chosen provider's catalog
  models as suggestions. A provider whose list is the account's own publishes
  none, and the client asks `providers.models.list`. Each row keeps its
  explanation in `info`, with no footer.

  `cues_screen` is how items are checked before the filter model reads them:
  `keyword` or `decision_model` (`FilterChoices.screen_choices/1`). The
  decision model option names the one in use, or is disabled with its hint
  while none is set up; a saved `decision_model` keeps its value, and its
  watchers are held until one is set up or keyword match is picked.

  `cues_decision_provider` is which decision model that is, published
  whatever the screen is, so a client shows it beside the screen's choice
  without a read: `""` for Automatic, labelled with what it resolves to, then
  each provider that serves one (`FilterChoices.decision_provider_choices/1`).
  One not set up is disabled with its hint, a saved one included, so the
  value is always an option; its watchers are held until it is set up or
  another is picked.
  """

  alias FermixCore.Cues.Config, as: CuesConfig
  alias FermixCore.Cues.FilterChoices
  alias FermixCore.Cues.Settings, as: CueSettings
  alias FermixCore.Management.Settings.Row
  alias FermixCore.Management.Settings.Source
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.ModelCatalog

  @section %{id: "cues", pane: "cues", title: "Cues"}
  @switch_answers [:enabled, :mandates_enabled, :door_port]
  @filter_answers [:filter_provider, :filter_model]
  # The row a refusal names: the pair's provider row for the pair, the
  # screen's row, its decision model's, and the door's port for the switches,
  # the one switch a value can be refused for.
  @pair_row "filter_provider"
  @screen_row "cues_screen"
  @decision_provider_row "cues_decision_provider"
  @door_row "cues_door_port"
  @row_prefix "cues_"
  @pair_sentence "Pick a provider and a model, or clear both."
  @not_set_up "Set up this provider first."
  @enabled_info "Starts the sources, the door, the filters and the tasks watchers wake. " <>
                  "Applies after a restart."
  @mandates_info "Off stops every watcher action at once: the next call of every mandate and " <>
                   "every follow-up, even in a run already going. No restart needed."
  @filter_info "Judges each item on its own, so a smaller, faster model works well and costs " <>
                 "much less than your main model."
  @door_info "The door listens on this computer only. Applies after a restart."

  @doc "The one section this module owns."
  @spec sections() :: [%{id: String.t(), pane: String.t(), title: String.t()}]
  def sections, do: [@section]

  @doc "Whether this module owns the named section."
  @spec owns?(String.t()) :: boolean()
  def owns?(section) when is_binary(section), do: section == @section.id

  @doc "The rows of the owned section."
  @spec rows(String.t(), Source.snapshot()) :: [Row.t()]
  def rows("cues", snapshot) when is_map(snapshot) do
    cues = CuesConfig.normalize(Source.core(snapshot, :cues))
    routing = Source.core(snapshot, :routing)
    provider = Source.string(routing, :filter_provider)

    [
      Row.new("cues_enabled", :toggle, "Run cues",
        info: @enabled_info,
        value: CuesConfig.enabled?(cues),
        restart: Row.restart?([:cues, :enabled])
      ),
      Row.new("cues_mandates_enabled", :toggle, "Let watchers act",
        info: @mandates_info,
        value: CuesConfig.mandates_enabled?(cues),
        restart: Row.restart?([:cues, :mandates_enabled])
      ),
      Row.new("cues_screen", :choice, "Screen",
        info: FilterChoices.screen_info(),
        value: CuesConfig.screen(cues),
        options: Enum.map(FilterChoices.screen_choices(snapshot), &screen_option/1),
        restart: Row.restart?([:cues, :screen])
      ),
      Row.new(@decision_provider_row, :choice, "Decision model",
        info: FilterChoices.decision_provider_info(),
        value: decision_provider_value(CuesConfig.decision_provider(cues)),
        options: Enum.map(FilterChoices.decision_provider_choices(snapshot), &screen_option/1),
        restart: Row.restart?([:cues, :decision_provider])
      ),
      Row.new("filter_provider", :choice, "Filter model",
        info: @filter_info,
        value: provider,
        options: provider_options(snapshot, provider),
        restart: Row.restart?([:routing, :filter_provider])
      ),
      Row.new("filter_model", :choice, "Model",
        value: Source.string(routing, :filter_model),
        options: Enum.map(FilterChoices.models(provider), &Row.option(&1.id, &1.label)),
        suggestions: true,
        restart: Row.restart?([:routing, :filter_model])
      ),
      Row.new("cues_door_port", :number, "Door port",
        info: @door_info,
        value: CuesConfig.door_port(cues),
        min: 1_024,
        max: 65_535,
        step: 1,
        format: :integer,
        restart: Row.restart?([:cues, :door_port]),
        advanced: true
      )
    ]
  end

  @doc """
  Writes one `settings.apply` of the section, and the setup page's Cues tab's
  Save. Every step is checked first, with the check its save makes, so a
  refused value writes nothing; then the filter pair is written through
  `Cues.Settings.save_filter_model/2`, the screen through `save_screen/1`, its
  decision model through `save_decision_provider/1` and the switches through
  `save_switches/1`, each its own save, so the screen and its decision model
  are picked in one apply. Either filter key alone is refused. A refusal
  answers `{:invalid_value, row, sentence}`, `row` the key of the row it is
  about, which the settings write names as the field.
  """
  @spec save(keyword()) ::
          {:ok, map()} | {:error, {:invalid_value, String.t(), String.t()} | term()}
  def save(answers) when is_list(answers) do
    filter = Keyword.take(answers, @filter_answers)
    screen = Keyword.take(answers, [:screen])
    decision_provider = Keyword.take(answers, [:decision_provider])
    switches = Keyword.take(answers, @switch_answers)

    with :ok <- whole_pair(filter),
         :ok <- check_filter(filter),
         :ok <- check_screen(screen),
         :ok <- check_decision_provider(decision_provider),
         :ok <- check_switches(switches),
         {:ok, _filter} <- save_filter(filter),
         {:ok, _screen} <- save_screen(screen),
         {:ok, _provider} <- save_decision_provider(decision_provider),
         {:ok, _switches} <- save_switches(switches) do
      {:ok, %{}}
    end
  end

  defp whole_pair([]), do: :ok
  defp whole_pair([_provider, _model]), do: :ok
  defp whole_pair([{key, _value}]), do: {:error, {:invalid_value, row(key), @pair_sentence}}

  defp check_filter([]), do: :ok

  defp check_filter(filter),
    do:
      CueSettings.check_filter_model(filter[:filter_provider], filter[:filter_model])
      |> refused(@pair_row)

  defp save_filter([]), do: {:ok, :untouched}

  defp save_filter(filter),
    do:
      CueSettings.save_filter_model(filter[:filter_provider], filter[:filter_model])
      |> refused(@pair_row)

  defp check_screen([]), do: :ok

  defp check_screen(screen: screen),
    do: screen |> CueSettings.check_screen() |> refused(@screen_row)

  defp save_screen([]), do: {:ok, :untouched}

  defp save_screen(screen: screen),
    do: screen |> CueSettings.save_screen() |> refused(@screen_row)

  defp check_decision_provider([]), do: :ok

  defp check_decision_provider(decision_provider: provider),
    do: provider |> CueSettings.check_decision_provider() |> refused(@decision_provider_row)

  defp save_decision_provider([]), do: {:ok, :untouched}

  defp save_decision_provider(decision_provider: provider),
    do: provider |> CueSettings.save_decision_provider() |> refused(@decision_provider_row)

  defp check_switches([]), do: :ok

  defp check_switches(switches),
    do: switches |> CueSettings.check_switches() |> refused(switches_row(switches))

  defp save_switches([]), do: {:ok, :untouched}

  defp save_switches(switches),
    do: switches |> CueSettings.save_switches() |> refused(switches_row(switches))

  defp switches_row(switches) do
    if Keyword.has_key?(switches, :door_port),
      do: @door_row,
      else: switches |> Keyword.keys() |> hd() |> row()
  end

  # A row's key: the filter pair's are their own, every other is `cues_` and
  # the answer's name (`Settings.AnswerMap`'s rule, read backwards).
  defp row(key) when key in @filter_answers, do: Atom.to_string(key)
  defp row(key), do: @row_prefix <> Atom.to_string(key)

  defp refused({:error, {:invalid, sentence}}, row), do: {:error, {:invalid_value, row, sentence}}
  defp refused(result, _row), do: result

  # The main model first, then only the providers that are set up. A saved
  # provider that is no longer set up stays, disabled with its hint, so the
  # row's value is always one of its options.
  defp provider_options(snapshot, saved) do
    set_up = Enum.map(FilterChoices.providers(snapshot), &Row.option(&1.id, &1.label))
    [Row.option("", FilterChoices.main_model_label(snapshot)) | set_up] ++ stale(saved, set_up)
  end

  defp screen_option(choice),
    do: Row.option(choice.id, choice.label, hint: choice.hint, disabled: choice.disabled?)

  # Automatic is saved as no key and published as the empty value.
  defp decision_provider_value(nil), do: ""
  defp decision_provider_value(provider), do: Atom.to_string(provider)

  defp stale(saved, set_up) do
    provider = Enum.find(ModelCatalog.providers(), &(Atom.to_string(&1) == saved))

    if provider && not Enum.any?(set_up, &(&1["value"] == saved)),
      do: [
        Row.option(saved, Descriptor.fetch!(provider).label, disabled: true, hint: @not_set_up)
      ],
      else: []
  end
end
