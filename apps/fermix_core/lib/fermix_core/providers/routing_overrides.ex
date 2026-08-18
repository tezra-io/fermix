defmodule FermixCore.Providers.RoutingOverrides do
  @moduledoc """
  Single reader, validator, and applier for the model-selection overrides in
  `[fermix_core.routing]`:

    * `subagent_provider` / `subagent_model` / `subagent_reasoning_effort` —
      the model delegated `subagents` workers run on.
    * `cron_provider` / `cron_model` / `cron_reasoning_effort` — the model
      unpinned scheduled jobs run on.
    * `meeting_provider` / `meeting_model` / `meeting_reasoning_effort` — the
      model the meeting summarizer runs on.

  Plus the per-call override the main agent may pass as `subagents` tool args
  (`parse_tool_args/1`), which `merge/2`s field-level over the config default.

  Resolution layers (highest first): per-call tool arg > `[fermix_core.routing]`
  config > inherit. All three are stamped onto an `AgentDefinition`
  (`model`/`provider`/`reasoning_effort`) and resolved by `RouteResolver`.

  Validation is the boundary (Code Rule #6): an unknown provider or effort
  raises `ArgumentError` naming the offending key + value. `apply_effort/2`
  overlays a chosen thinking level onto already-resolved routes (clamped per
  provider) so lowering the effort never changes the model or drops failover.

  See `docs/design/SUBAGENT_MODEL_SELECTION.md`.
  """

  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.PrimaryConfig
  alias FermixCore.Providers.ReasoningEffort

  @type override :: %{
          provider: ModelCatalog.provider() | nil,
          model: String.t() | nil,
          reasoning_effort: ReasoningEffort.level() | nil
        }

  @doc "The configured subagent override (`[fermix_core.routing] subagent_*`)."
  @spec subagent() :: override()
  def subagent, do: parse(routing_config(), :subagent)

  @doc "The configured cron override (`[fermix_core.routing] cron_*`)."
  @spec cron() :: override()
  def cron, do: parse(routing_config(), :cron)

  @doc "The configured meeting-summary override (`[fermix_core.routing] meeting_*`)."
  @spec meeting() :: override()
  def meeting, do: parse(routing_config(), :meeting)

  defp routing_config, do: Application.get_env(:fermix_core, :routing, [])

  @doc """
  Reads + validates the `<prefix>_provider/model/reasoning_effort` keys from a
  routing keyword list. Raises `ArgumentError` on an unknown provider or effort.
  """
  @spec parse(keyword(), :subagent | :cron | :meeting) :: override()
  def parse(routing, prefix) when is_list(routing) and prefix in [:subagent, :cron, :meeting] do
    provider = validate_provider(get(routing, prefix, :provider), label(prefix, :provider))
    model = normalize_model(get(routing, prefix, :model))
    validate_pairing(provider, model, label(prefix, :model))

    %{
      provider: provider,
      model: model,
      reasoning_effort:
        validate_effort(get(routing, prefix, :reasoning_effort), label(prefix, :reasoning_effort))
    }
  end

  @doc """
  Parses a per-call override from `subagents` tool args (an LLM string map).
  Same validators; `model` is a free slug. Raises `ArgumentError` (surfaced as a
  clean tool error) on an unknown provider or effort. Provider is NOT inferred
  here — `infer_provider/1` fills it from the slug after `merge/2`.
  """
  @spec parse_tool_args(map()) :: override()
  def parse_tool_args(args) when is_map(args) do
    provider = validate_provider(Map.get(args, "provider"), ~s(subagents argument "provider"))
    model = normalize_model(Map.get(args, "model"))
    validate_pairing(provider, model, ~s(subagents argument "model"))

    %{
      provider: provider,
      model: model,
      reasoning_effort:
        validate_effort(
          Map.get(args, "reasoning_effort"),
          ~s(subagents argument "reasoning_effort")
        )
    }
  end

  @doc "Field-level precedence: each set field of `call` wins over `config`."
  @spec merge(override(), override()) :: override()
  def merge(call, config) do
    %{
      provider: call.provider || config.provider,
      model: call.model || config.model,
      reasoning_effort: call.reasoning_effort || config.reasoning_effort
    }
  end

  @doc """
  Fills `:provider` from the active primary when a model is set but no provider
  was given — a bare model pin runs on the **primary** provider (the sub-agent /
  cron picker is scoped to it; a cross-provider worker needs an EXPLICIT
  `*_provider`). Only when no primary is configured does it fall back to the
  model's catalog owner. Leaves the override untouched if a provider is already
  set or no model is present.
  """
  @spec infer_provider(override()) :: override()
  def infer_provider(%{provider: nil, model: model} = override) when is_binary(model) do
    %{override | provider: provider_for(model)}
  end

  def infer_provider(override), do: override

  # A provider-less pin runs on the primary. Only fall back to the model's catalog
  # owner when no primary is configured (nothing better to default to). This is
  # what keeps a bare sub-agent model on the primary instead of silently
  # re-routing to whichever provider's catalog happens to own the slug.
  defp provider_for(model) do
    case current_primary() do
      nil -> ModelCatalog.provider_for_model(model)
      primary -> primary
    end
  end

  defp current_primary do
    case PrimaryConfig.primary() do
      {:ok, provider} -> provider
      _other -> nil
    end
  end

  @doc """
  Overlays `level` onto each `{route_key, adapter_opts}` route, clamped to that
  route's provider's supported range. `nil` leaves routes unchanged. Only the
  effort field is touched — model and failover chain are preserved.

  Routes whose provider has no `ReasoningEffort` levels entry (effort-less
  providers, e.g. ChatCompletions-only ones) are left untouched — stamping
  an effort their adapter must ignore would make the telemetry/wire
  contract accidental instead of explicit (M12 §5.2).
  """
  @spec apply_effort([{map(), keyword()}], ReasoningEffort.level() | nil) :: [{map(), keyword()}]
  def apply_effort(routes, nil), do: routes

  def apply_effort(routes, level) when is_list(routes) and is_atom(level) do
    Enum.map(routes, fn {%{provider: provider, model: model} = route_key, adapter_opts} ->
      case ReasoningEffort.levels_for(provider) do
        [] ->
          {route_key, adapter_opts}

        _supported ->
          {route_key,
           Keyword.put(
             adapter_opts,
             :reasoning_effort,
             ModelCatalog.clamp_effort(provider, model, level)
           )}
      end
    end)
  end

  defp get(routing, prefix, field), do: Keyword.get(routing, :"#{prefix}_#{field}")
  defp label(prefix, field), do: "[fermix_core.routing] #{prefix}_#{field}"

  defp validate_provider(nil, _label), do: nil
  defp validate_provider("", _label), do: nil

  defp validate_provider(value, label) when is_binary(value) do
    trimmed = String.trim(value)

    case Enum.find(ModelCatalog.providers(), &(Atom.to_string(&1) == trimmed)) do
      nil ->
        raise ArgumentError,
              "#{label} = #{inspect(value)} is not a known provider (#{providers_hint()})"

      provider ->
        provider
    end
  end

  defp validate_provider(value, label) when is_atom(value) do
    if value in ModelCatalog.providers() do
      value
    else
      raise ArgumentError,
            "#{label} = #{inspect(value)} is not a known provider (#{providers_hint()})"
    end
  end

  defp normalize_model(nil), do: nil

  defp normalize_model(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # A model slug stays free-form (an unknown id is the provider API's call, so a
  # brand-new OpenRouter model still passes), but a slug the catalog KNOWS under a
  # *different* provider than the one explicitly paired with it is a definite
  # mis-pairing — e.g. `subagent_provider = "openrouter"` + `subagent_model =
  # "qwen3:32b"` (an Ollama model), which otherwise only 400s at spawn. Reject it
  # at the parse boundary so no automated writer can persist it (and a manual
  # config edit fails loud here at the next subagent/cron spawn).
  defp validate_pairing(provider, model, label)
       when is_atom(provider) and not is_nil(provider) and is_binary(model) do
    cond do
      ModelCatalog.known_model?(provider, model) ->
        :ok

      is_nil(ModelCatalog.provider_for_model(model)) ->
        :ok

      true ->
        owner = ModelCatalog.provider_for_model(model)

        raise ArgumentError,
              "#{label} = #{inspect(model)} belongs to provider #{owner}, not #{provider} " <>
                "(invalid provider/model pairing). Use a #{provider} model slug, change the " <>
                "provider, or clear the override."
    end
  end

  defp validate_pairing(_provider, _model, _label), do: :ok

  defp validate_effort(nil, _label), do: nil
  defp validate_effort("", _label), do: nil

  defp validate_effort(value, label) do
    case ReasoningEffort.parse(value) do
      {:ok, level} ->
        level

      :error ->
        raise ArgumentError,
              "#{label} = #{inspect(value)} is not a valid reasoning effort (#{efforts_hint()})"
    end
  end

  defp providers_hint, do: Enum.map_join(ModelCatalog.providers(), ", ", &Atom.to_string/1)
  defp efforts_hint, do: Enum.map_join(ReasoningEffort.levels(), ", ", &Atom.to_string/1)
end
