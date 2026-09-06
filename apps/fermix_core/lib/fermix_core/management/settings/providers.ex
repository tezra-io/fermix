defmodule FermixCore.Management.Settings.Providers do
  @moduledoc """
  The `providers.<id>` sections and the `routing` section (M34 native setup §5.1).

  One section per descriptor id, built from the descriptor itself, so a provider
  added to `Providers.Descriptor` gets its pane the same day with no second list
  to update. The section title is the descriptor's own label rather than a
  marketing name, because `setup.state.get` publishes that label on the provider
  row and two names for one provider is a disagreement a client cannot resolve.
  """

  alias FermixCore.Management.Settings.Row
  alias FermixCore.Management.Settings.Source
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.PrimaryConfig
  alias FermixCore.Providers.ReasoningEffort

  @prefix "providers."
  @pane "providers"
  @routing_id "routing"

  # Auth-mode words. The daemon owns them; no front-end composes its own.
  @auth_mode_labels %{
    api_key: "An API key",
    oauth: "A subscription",
    none: "No sign-in needed"
  }

  # Effort words, low to high, in the daemon's own vocabulary.
  @effort_labels %{
    none: "None",
    minimal: "Minimal",
    low: "Low",
    medium: "Medium",
    high: "High",
    xhigh: "Extra high",
    max: "Maximum"
  }

  # The one non-secret provider setup field, whose CLI prompt text ("Ollama base
  # URL (blank = ...)") is a terminal instruction rather than a wire label.
  @plain_field_copy %{
    ollama_base_url: {"Address", "Where Ollama is listening on this Mac."}
  }

  @doc "Every provider section, plus routing, in descriptor order."
  @spec sections() :: [%{id: String.t(), pane: String.t(), title: String.t()}]
  def sections do
    provider_sections =
      Enum.map(Descriptor.all(), &%{id: section_id(&1.id), pane: @pane, title: &1.label})

    provider_sections ++ [%{id: @routing_id, pane: @pane, title: "Model behavior"}]
  end

  @doc "The section id for one provider."
  @spec section_id(atom()) :: String.t()
  def section_id(id) when is_atom(id), do: @prefix <> Atom.to_string(id)

  @doc "Whether this module owns the named section."
  @spec owns?(String.t()) :: boolean()
  def owns?(@routing_id), do: true

  def owns?(@prefix <> id), do: Enum.any?(Descriptor.ids(), &(Atom.to_string(&1) == id))

  def owns?(_section), do: false

  @doc "The rows of one owned section."
  @spec rows(String.t(), Source.snapshot()) :: [Row.t()]
  def rows(@routing_id, snapshot), do: routing_rows(snapshot)

  def rows(@prefix <> id, snapshot) do
    descriptor = Descriptor.fetch!(String.to_existing_atom(id))
    provider_rows(descriptor, Source.provider(snapshot, descriptor.id), snapshot)
  end

  defp provider_rows(descriptor, block, snapshot) do
    restart = Row.restart?(:providers)

    auth_mode_row(descriptor, block, restart) ++
      Enum.map(descriptor.setup_fields, &field_row(descriptor, &1, block, snapshot, restart)) ++
      [model_row(descriptor, block, restart)] ++
      effort_row(descriptor, block, restart) ++ fast_row(descriptor, block, restart)
  end

  defp auth_mode_row(descriptor, block, restart) do
    if Descriptor.multi_auth_mode?(descriptor) do
      options = Enum.map(descriptor.auth_modes, &Row.option(Atom.to_string(&1), auth_label(&1)))

      value =
        Source.string(block, :auth_mode, Atom.to_string(Descriptor.default_auth_mode(descriptor)))

      [
        Row.new("auth_mode", :choice, "Sign in with",
          value: value,
          options: options,
          restart: restart
        )
      ]
    else
      []
    end
  end

  defp field_row(descriptor, %{secret?: true} = field, _block, snapshot, restart) do
    Row.new(Atom.to_string(field.key), :secret, "#{descriptor.label} key",
      present: Source.secret_present?(snapshot, field.key),
      restart: restart
    )
  end

  defp field_row(_descriptor, field, block, _snapshot, restart) do
    {label, footer} = Map.get(@plain_field_copy, field.key, {field.label, nil})

    Row.new(Atom.to_string(field.key), :text, label,
      footer: footer,
      value: Source.string(block, field.config_key, field.default || ""),
      restart: restart
    )
  end

  defp model_row(descriptor, block, restart) do
    Row.new("default_model", :choice, "Model",
      value: Source.string(block, :default_model),
      options: model_options(descriptor.id),
      suggestions: true,
      restart: restart
    )
  end

  defp effort_row(%{effort?: false}, _block, _restart), do: []

  defp effort_row(descriptor, block, restart) do
    [
      Row.new("reasoning_effort", :choice, "Reasoning effort",
        value: Source.string(block, :reasoning_effort),
        options: effort_options(descriptor.id),
        restart: restart
      )
    ]
  end

  defp fast_row(descriptor, block, restart) do
    if :fast in descriptor.config_keys do
      [
        Row.new("fast", :toggle, "Fast mode",
          footer: "Answers sooner and reasons less.",
          value: Source.boolean(block, :fast, false),
          restart: restart
        )
      ]
    else
      []
    end
  end

  # An empty option list is the truthful answer for a provider whose models are
  # discovered rather than shipped (Ollama, OpenRouter). The client asks
  # `providers.models.list` for those; it never invents a catalog.
  defp model_options(id) do
    Enum.map(ModelCatalog.models_for(id), &Row.option(&1.id, &1.label))
  end

  defp effort_options(id) do
    Enum.map(ReasoningEffort.levels_for(id), fn level ->
      Row.option(Atom.to_string(level), Map.fetch!(@effort_labels, level))
    end)
  end

  defp auth_label(mode), do: Map.fetch!(@auth_mode_labels, mode)

  # The sub-agent model is a routing key, not a provider key: it names a model
  # of whichever provider is primary, and the blank entry means "the same model
  # the main agent uses".
  defp routing_rows(snapshot) do
    block = Source.core(snapshot, :routing)
    options = [Row.option("", "Same as main model") | primary_model_options()]

    [
      Row.new("subagent_model", :choice, "Sub-agent model",
        footer: "What a sub-agent uses when the main model would be more than the job needs.",
        value: Source.string(block, :subagent_model),
        options: options,
        suggestions: true,
        restart: Row.restart?(:routing)
      )
    ]
  end

  defp primary_model_options do
    case PrimaryConfig.primary() do
      {:ok, nil} -> []
      {:ok, provider} -> model_options(provider)
      {:error, :multiple_primary} -> []
    end
  end
end
