defmodule FermixCore.Management.Settings.Cues do
  @moduledoc """
  The `cues` section (M60 app surface §3.2): the cue switches, the door's
  port and the default filter model. Its rows are the scalars; the sources,
  watchers and mandates are the `cues.*` methods (`Management.Cues`), as the
  phone channel has `channels.mobile` beside `mobile.*`.

  Published only where the build admits cues (`Cues.available?/0`, design
  B1), the precedent of iMessage off a Mac. Every write goes through
  `Cues.Settings`, the setup page's own functions: the filter pair through
  `save_filter_model/2` in one call (both, or "None" to clear both), the
  switches through `save_switches/1`. `restart` is derived from
  `Setup.RestartState`, which treats `routing.filter_*` and the mandates
  switch as live and the cue tree's switch and port as boot-bound.

  The filter rows are catalog data: the providers `ModelCatalog` publishes,
  each labelled by its descriptor, and the chosen provider's models as
  suggestions. A provider whose list is the account's own publishes none,
  and the client asks `providers.models.list`.
  """

  require Logger

  alias FermixCore.Cues
  alias FermixCore.Cues.Config, as: CuesConfig
  alias FermixCore.Cues.Settings, as: CueSettings
  alias FermixCore.Management.Settings.Row
  alias FermixCore.Management.Settings.Source
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesWatchersSql
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.Selection

  @section %{id: "cues", pane: "cues", title: "Cues"}
  @switch_answers [:enabled, :mandates_enabled, :door_port]
  @filter_answers [:filter_provider, :filter_model]
  @pair_sentence "Pick a provider and a model, or clear both."
  @not_set_up "Set up this provider first."

  @doc "The one section this module owns, where the build admits cues."
  @spec sections(keyword()) :: [%{id: String.t(), pane: String.t(), title: String.t()}]
  def sections(opts \\ []) when is_list(opts),
    do: if(available?(opts), do: [@section], else: [])

  @doc "Whether this module owns the named section on this build."
  @spec owns?(String.t(), keyword()) :: boolean()
  def owns?(section, opts \\ []) when is_binary(section) and is_list(opts),
    do: section == @section.id and available?(opts)

  @doc "The rows of the owned section."
  @spec rows(String.t(), Source.snapshot()) :: [Row.t()]
  def rows("cues", snapshot) when is_map(snapshot) do
    cues = CuesConfig.normalize(Source.core(snapshot, :cues))
    routing = Source.core(snapshot, :routing)
    provider = Source.string(routing, :filter_provider)

    [
      Row.new("cues_enabled", :toggle, "Run cues",
        footer: "Starts the sources, the door, the filters and the tasks watchers wake.",
        value: CuesConfig.enabled?(cues),
        restart: Row.restart?([:cues, :enabled])
      ),
      Row.new("cues_mandates_enabled", :toggle, "Let mandates act",
        footer: "Off stops the next call of every mandate, even in a run already going.",
        value: CuesConfig.mandates_enabled?(cues),
        restart: Row.restart?([:cues, :mandates_enabled])
      ),
      Row.new("filter_provider", :choice, "Filter provider",
        footer: "Decides which items reach a watcher's task. Fermix never uses your main model.",
        value: provider,
        options: [Row.option("", "None") | provider_options(snapshot)],
        restart: Row.restart?([:routing, :filter_provider])
      ),
      Row.new("filter_model", :choice, "Filter model",
        footer: "A watcher with a model of its own uses that one.",
        value: Source.string(routing, :filter_model),
        options: model_options(provider),
        suggestions: true,
        restart: Row.restart?([:routing, :filter_model])
      ),
      Row.new("cues_door_port", :number, "Door port",
        footer: "The door listens on this Mac only.",
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
  Writes one `settings.apply` of the section: the filter pair first, through
  `Cues.Settings.save_filter_model/2`, then the switches through
  `save_switches/1`. Either filter key alone is refused before anything is
  written. A refusal answers `{:invalid_value, sentence}`, which the settings
  write names under the field that was sent.
  """
  @spec save(keyword()) :: {:ok, map()} | {:error, {:invalid_value, String.t()} | term()}
  def save(answers) when is_list(answers) do
    filter = Keyword.take(answers, @filter_answers)
    switches = Keyword.take(answers, @switch_answers)

    with :ok <- whole_pair(filter),
         {:ok, _filter} <- save_filter(filter),
         {:ok, _switches} <- save_switches(switches) do
      {:ok, %{}}
    end
  end

  @doc """
  What clearing the default filter model did that the owner did not type:
  the `llm` watchers that name no model of their own now wait for one.
  `before` and `current` are the snapshots around the write.
  """
  @spec side_effects(map(), map(), keyword()) :: [String.t()]
  def side_effects(before, current, opts \\ []) when is_map(before) and is_map(current) do
    if filter_model(before) != "" and filter_model(current) == "" do
      waiting_sentence(waiting_watchers(opts))
    else
      []
    end
  end

  defp waiting_sentence({:ok, 0}), do: []
  defp waiting_sentence({:ok, 1}), do: ["One watcher now waits for a filter model."]
  defp waiting_sentence({:ok, count}), do: ["#{count} watchers now wait for a filter model."]

  defp waiting_sentence(:unknown),
    do: ["Watchers with no filter model of their own now wait for one."]

  # Watchers live in `memory.db`: with memory off, or no Repo running, there
  # are none to wait. A Repo that answers an error leaves the count unknown,
  # which is said and logged, never counted as none.
  defp waiting_watchers(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    case GenServer.whereis(repo) do
      nil -> {:ok, 0}
      _pid -> count_waiting(Repo.cues_call(CuesWatchersSql, {:list_watchers}, server: repo))
    end
  end

  defp count_waiting({:ok, watchers}),
    do: {:ok, Enum.count(watchers, &(&1.filter == "llm" and blank?(&1.filter_model)))}

  defp count_waiting({:error, :disabled}), do: {:ok, 0}

  defp count_waiting({:error, reason}) do
    Logger.warning(
      "cues section: the watchers waiting for a filter model are unknown: #{inspect(reason)}"
    )

    :unknown
  end

  defp blank?(value), do: value in [nil, ""]

  defp filter_model(snapshot),
    do: snapshot |> Source.core(:routing) |> Source.string(:filter_model)

  defp whole_pair([]), do: :ok
  defp whole_pair([_provider, _model]), do: :ok
  defp whole_pair([_one]), do: {:error, {:invalid_value, @pair_sentence}}

  defp save_filter([]), do: {:ok, :untouched}

  defp save_filter(filter),
    do: refused(CueSettings.save_filter_model(filter[:filter_provider], filter[:filter_model]))

  defp save_switches([]), do: {:ok, :untouched}
  defp save_switches(switches), do: switches |> CueSettings.save_switches() |> refused()

  defp refused({:error, {:invalid, sentence}}), do: {:error, {:invalid_value, sentence}}
  defp refused(result), do: result

  # Every provider the engine publishes. One that is not set up is offered
  # disabled with the reason: a filter on it would fail at its first call.
  defp provider_options(snapshot) do
    Enum.map(ModelCatalog.providers(), fn id ->
      label = Descriptor.fetch!(id).label

      if Selection.configured?(id, Source.provider(snapshot, id)),
        do: Row.option(Atom.to_string(id), label),
        else: Row.option(Atom.to_string(id), label, disabled: true, hint: @not_set_up)
    end)
  end

  defp model_options(provider) do
    case Enum.find(ModelCatalog.providers(), &(Atom.to_string(&1) == provider)) do
      nil -> []
      id -> Enum.map(ModelCatalog.models_for(id), &Row.option(&1.id, &1.label))
    end
  end

  defp available?(opts), do: Keyword.get_lazy(opts, :cues_available?, &Cues.available?/0)
end
