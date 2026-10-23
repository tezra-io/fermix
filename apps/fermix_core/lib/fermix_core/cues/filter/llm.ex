defmodule FermixCore.Cues.Filter.Llm do
  @moduledoc """
  One filter call for one cue (M60 §8.2), made the way `Meetings.Summarizer`
  makes its own: a resolved route, `adapter.chat/3` with no tools through
  `Providers.Failover.run_chain/3`, and the call's `agent` and `session_id`
  riding the adapter opts so the adapter's own `Providers.Telemetry.emit_call/3`
  lands in the filter call's trace. The chain's failover telemetry carries the
  same `session_id`, so a failover event nests there too.

  ## The model

  The watcher's `filter_model` (with its `filter_provider`, or the primary's
  when none is named) when set, else `[fermix_core.routing] filter_*` through
  `RoutingOverrides.filter/0`, else `:no_filter_model`. Never
  `Selection.ordered_routes/0` and never the primary route: that is usually the
  main agent's model, an expensive one for a yes-or-no question. A route needs a
  model; a provider alone names none. The effort is `filter_reasoning_effort`
  when set, else `:low`, clamped by `RoutingOverrides.apply_effort/2`. Not
  `:none`: on OpenAI that omits the field and leaves the model at its own
  default effort. Every call also asks for no thinking (`thinking: :off`, read
  by the Anthropic adapter), since adaptive thinking counts against the cap.

  The output is capped at 150 tokens where the adapter takes a cap (the
  Anthropic adapter's `max_tokens`; the OpenAI adapters read no cap today). A
  JSON object is asked for only from the adapters that take a format: OpenAI
  Responses and the ChatGPT plan route (`text_format`), and Chat Completions on
  OpenAI itself (`response_format`). The 60 s deadline is the dispatcher's
  (`Cues.Filters`), which owns the task this runs in.

  ## The outcome

  `decide/2` returns what `CuesFilterSql`'s settle takes: a decision, or a
  failure classified by the provider error taxonomy (`Providers.Error` kinds,
  never strings):

  - **provider failure**, the watcher's: no route at call time, every transport
    kind, and the API kinds in `@provider_api_kinds` (rate limit, quota, 5xx,
    timeout, auth, plan or route refusals), plus an unclassified API error whose
    status is not one of `@input_refused_statuses`;
  - **content failure**, the cue's: an invalid answer, an empty reply, a model
    refusal (`stop_reason: "refusal"`), the provider refusing the request body
    (an unclassified API error with status 400, 413 or 422), an oversized input
    (`:context_length_exceeded`), and any error of no known shape.
  """

  require Logger

  alias FermixCore.Cues.Filter.Answer
  alias FermixCore.Cues.Filter.Prompt
  alias FermixCore.Cues.Filter.Telemetry, as: FilterTelemetry
  alias FermixCore.Providers.Adapter
  alias FermixCore.Providers.Failover
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.OpenAI.ChatCompletions
  alias FermixCore.Providers.OpenAI.ChatGPTPlan
  alias FermixCore.Providers.OpenAI.Responses
  alias FermixCore.Providers.RouteResolver
  alias FermixCore.Providers.RoutingOverrides

  @max_output_tokens 150
  @default_effort :low
  @max_message_chars 500
  @json_object %{type: "json_object"}

  @provider_api_kinds [
    :timeout,
    :rate_limit,
    :quota,
    :provider_unavailable,
    :auth,
    :plan_not_eligible,
    :invalid_request,
    :not_implemented
  ]
  @input_refused_statuses [400, 413, 422]

  @no_filter_model "Pick a model for this watcher's filter, or set a default filter model in settings."

  @type failure :: %{kind: atom(), message: String.t()}
  @type result ::
          {:pass, String.t(), String.t() | nil}
          | {:drop, String.t()}
          | {:provider_failure, failure()}
          | {:content_failure, failure()}

  @doc "The sentence for a watcher with no filter model and no default filter model."
  @spec no_filter_model_sentence() :: String.t()
  def no_filter_model_sentence, do: @no_filter_model

  @doc """
  Decides one claim. Opts: `:session_id` (required, the call's own), and the
  seams `:adapter` (a module used in place of `Adapter.for_route/1` for the
  resolved route), `:adapter_opts` (merged into the call opts),
  `:retry_delay_fn` (the same-provider retry's sleep) and `:routes` (a route
  chain run in place of `route/1`'s one route, for a test of the failover
  path).
  """
  @spec decide(map(), keyword()) :: result()
  def decide(%{watcher: watcher} = claim, opts) when is_map(watcher) and is_list(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    with {:ok, routes} <- routes(watcher, opts),
         {:ok, turn} <- call(routes, Prompt.messages(claim), session_id, opts) do
      classify_turn(turn)
    else
      {:error, reason} -> classify_error(reason)
    end
  end

  @doc """
  The route chain one call of `watcher` runs on, effort applied, or why there
  is none. A bad override in config is a route that cannot resolve, never a
  crash of the call.
  """
  @spec route(map()) ::
          {:ok, [{Adapter.route_key(), keyword()}]}
          | {:error, :no_filter_model}
          | {:error, {:no_route, String.t()}}
  def route(watcher) when is_map(watcher) do
    default = RoutingOverrides.filter()

    with {:ok, pick} <- pick(watcher, default),
         {:ok, provider} <- route_provider(pick) do
      resolved = RouteResolver.resolve!(provider: provider, model: pick.model)

      {:ok,
       RoutingOverrides.apply_effort([resolved], default.reasoning_effort || @default_effort)}
    end
  rescue
    error in ArgumentError -> {:error, {:no_route, Exception.message(error)}}
  end

  defp routes(watcher, opts) do
    case Keyword.fetch(opts, :routes) do
      {:ok, [_ | _] = routes} -> {:ok, routes}
      :error -> route(watcher)
    end
  end

  defp pick(%{filter_model: model} = watcher, _default) when is_binary(model) and model != "" do
    {:ok, %{provider: Map.get(watcher, :filter_provider), model: model}}
  end

  defp pick(_watcher, %{model: model} = default) when is_binary(model) do
    {:ok, %{provider: default.provider, model: model}}
  end

  defp pick(_watcher, _default), do: {:error, :no_filter_model}

  defp route_provider(%{provider: provider}) when is_atom(provider) and not is_nil(provider),
    do: {:ok, provider}

  defp route_provider(%{provider: name, model: model}) when is_binary(name) and name != "" do
    case Enum.find(ModelCatalog.providers(), &(Atom.to_string(&1) == name)) do
      nil -> {:error, {:no_route, "#{inspect(name)} is not a known provider (model #{model})."}}
      provider -> {:ok, provider}
    end
  end

  defp route_provider(%{model: model}) do
    %{provider: provider} =
      RoutingOverrides.infer_provider(%{provider: nil, model: model, reasoning_effort: nil})

    {:ok, provider}
  end

  # --- the call -------------------------------------------------------------------

  defp call(routes, messages, session_id, opts) do
    attempt = fn {route_key, route_opts} ->
      adapter = Keyword.get(opts, :adapter) || Adapter.for_route(route_key)
      adapter.chat(messages, [], call_opts(route_key, route_opts, session_id, opts))
    end

    Failover.run_chain(routes, attempt,
      telemetry: %{agent: FilterTelemetry.agent(), surface: :cue_filter, session_id: session_id},
      retry_delay_fn: Keyword.get(opts, :retry_delay_fn, &Process.sleep/1)
    )
  end

  defp call_opts(route_key, route_opts, session_id, opts) do
    route_opts
    |> Keyword.merge(Keyword.get(opts, :adapter_opts, []))
    |> Keyword.merge(format_opts(Adapter.for_route(route_key), route_key.provider))
    |> Keyword.merge(
      agent: FilterTelemetry.agent(),
      session_id: session_id,
      max_tokens: @max_output_tokens,
      thinking: :off
    )
  end

  defp format_opts(adapter, _provider) when adapter in [Responses, ChatGPTPlan],
    do: [text_format: @json_object]

  defp format_opts(ChatCompletions, :openai), do: [response_format: @json_object]
  defp format_opts(_adapter, _provider), do: []

  # --- the outcome ----------------------------------------------------------------

  defp classify_turn(%{provider_state: %{stop_reason: "refusal"}}),
    do: content_failure(:refused, "The model refused to judge this item.")

  defp classify_turn(%{content: content}) when is_binary(content) do
    if String.trim(content) == "" do
      content_failure(:empty_reply, "The model gave an empty reply.")
    else
      answer(Answer.parse(content))
    end
  end

  defp classify_turn(_turn), do: content_failure(:empty_reply, "The model gave no text.")

  defp answer({:error, :invalid_answer, detail}), do: content_failure(:invalid_answer, detail)
  defp answer(decision), do: decision

  defp classify_error(:no_filter_model), do: provider_failure(:no_filter_model, @no_filter_model)
  defp classify_error({:no_route, message}), do: provider_failure(:no_route, message)
  defp classify_error(:no_routes), do: provider_failure(:no_route, "No route resolved.")

  defp classify_error({:all_routes_failed, tried}) when is_list(tried) and tried != [] do
    {_provider, last} = List.last(tried)
    classify_error(last)
  end

  defp classify_error({:provider_transport_error, %{kind: kind, message: message}}),
    do: provider_failure(kind, message)

  defp classify_error({:provider_error, %{kind: kind, message: message}})
       when kind in @provider_api_kinds,
       do: provider_failure(kind, message)

  defp classify_error({:provider_error, %{kind: :provider, status: status, message: message}})
       when status in @input_refused_statuses,
       do: content_failure(:input_refused, message)

  defp classify_error({:provider_error, %{kind: kind, message: message}}),
    do: provider_failure(kind, message)

  defp classify_error(:context_length_exceeded),
    do: content_failure(:context_length, "The item is too long for the filter model.")

  defp classify_error(other) do
    Logger.warning("Cue filter call failed with an unclassified error: #{inspect(other)}")
    content_failure(:unclassified, other |> inspect() |> String.slice(0, @max_message_chars))
  end

  defp provider_failure(kind, message), do: {:provider_failure, failure(kind, message)}
  defp content_failure(kind, message), do: {:content_failure, failure(kind, message)}

  defp failure(kind, message) when is_atom(kind) and is_binary(message),
    do: %{kind: kind, message: String.slice(message, 0, @max_message_chars)}
end
