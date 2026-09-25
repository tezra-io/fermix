defmodule FermixCore.AgentLoop do
  @moduledoc """
  Core LLM conversation loop with capability execution.

  Calls the provider adapter, executes any returned tool calls via the
  capability registry, hands the results back through the adapter's
  continuation surface, and repeats until the adapter returns no more
  tool calls or the iteration cap is reached.

  Adapter dispatch is a deterministic function of `(provider, model,
  auth_mode, base_url)` — see `FermixCore.Providers.Adapter.for_route/1`.
  """

  require Logger

  alias FermixCore.Agents.ToolResultDigest
  alias FermixCore.Agents.ToolResultStore
  alias FermixCore.Capabilities.Advertisement
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Deferral
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.ComputerUse
  alias FermixCore.Memory.CompactionConfig
  alias FermixCore.Memory.Config
  alias FermixCore.Providers.Adapter
  alias FermixCore.Providers.Failover
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.Transient
  alias FermixCore.Telemetry
  alias FermixCore.Text
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @max_iterations 25

  # Bounded in-place recovery for a continuation call that failed without
  # emitting anything user-visible. Unlike the route-level retry (first call
  # only) or cron's whole-loop backoff (refuses once tools ran), this
  # re-issues ONLY the failed LLM call: no tool replay, no provider switch.
  # Two classes retry (`continuation_retryable?/1`): the measured zero-chunk
  # timeout (`Transient.pre_response_timeout?/1` — a connect/TLS stall, or a
  # response that never started within the receive window), and the
  # non-timeout transient kinds (transport cuts, provider-declared
  # unavailability/overload — the 2026-07-31 incident class, where one
  # transient Codex overload killed a 109-second turn one step short of its
  # push). Unmeasured timeouts stay excluded on purpose: a slow model burning
  # its receive window would be re-issued for nothing, a full window per
  # attempt. Two retries with 2s/4s backoff outlast the multi-second blips;
  # the first-byte-stall subclass costs a full receive window per attempt, so
  # exhaustion is bounded at roughly three windows — accepted, since the
  # alternative is failing a whole run (or turn) on one transient stall.
  @continuation_retry_attempts 2
  @continuation_retry_backoff_ms 2_000

  # In-loop context compaction (docs/design/IN_LOOP_CONTEXT_OVERFLOW.md). The
  # step being answered and the @raw_steps before it keep their raw tool
  # results. Before every continuation the estimated request is held under
  # the route's budget by digesting older results, oldest step first (§3.4);
  # a provider refusal runs the recovery ladder (§3.5): at most
  # @recovery_rounds re-issues of the provider call, each after a reduction
  # that had candidates, never a tool re-run. Every raw result stays in the
  # run's ToolResultStore for `tool_result_recall`.
  @raw_steps 2
  @recovery_rounds 3
  @bytes_per_token 4
  # Wire framing per result (ids, block scaffolding) on top of its text.
  @frame_overhead_bytes 200
  # The task excerpt each digest call carries; a long user message must not
  # ride whole in every summarizer prompt.
  @task_excerpt_bytes 4_000

  @typedoc """
  Channel-streaming events emitted through `stream_callback` (see
  docs/design/CHANNEL_STREAMING.md §5.1). The loop emits `:session_started`
  once and `:iteration_started` before every provider call; streaming
  adapters emit `:text_delta`/`:reasoning_delta` through the same callback
  (threaded via `adapter_opts[:stream_callback]`).
  """
  @type stream_event ::
          {:session_started, String.t() | nil}
          | {:iteration_started, pos_integer()}
          | {:text_delta, String.t()}
          | {:text_done, String.t()}
          | {:reasoning_delta, String.t()}
          | {:reasoning_done, String.t()}
  @type stream_callback :: (stream_event() -> any())

  @typedoc """
  Turn-activity events emitted through `activity_callback`. Consumers use them
  to observe turn progress: the cron watchdog treats any event as liveness and
  brackets a running tool, and the ACP session renders the tool pair as
  `tool_call` / `tool_call_update` frames
  (docs/design/MILESTONE_29_ACP_AGENT_SURFACE.md §8.4) — which is why
  `:tool_finish` carries the execution outcome.
  """
  @type activity_event ::
          :provider_start
          | :provider_response
          | {:tool_start, String.t()}
          | {:tool_finish, String.t(), %{status: :ok | :error}}
  @type activity_callback :: (activity_event() -> any())

  @typedoc """
  Route input is ONE shape: `routes` — an ordered `[{route_key, adapter_opts}]`
  list. A one-element list means no failover (the pre-failover behavior); the
  initial `chat/3` fails over across the list for eligible errors
  (docs/design/MULTI_PROVIDER_FAILOVER.md §5). `continue/3` always stays on
  the route that answered the initial call.

  A directly injected `adapter` (test mocks, adapter-capable providers) is
  sugar for a one-element routes list whose entry carries the pre-bound
  module — it never fails over and is never re-resolved via `for_route/1`.
  A route's `adapter_opts` may carry `:adapter` for the same purpose.
  """
  @type route :: {Adapter.route_key(), keyword()}

  @type loop_opts :: [
          messages: [map()],
          capabilities: [Capability.t()],
          allowed_tools: [String.t()] | nil,
          policy: CapabilityRegistry.policy_spec(),
          trust: CapabilityRegistry.trust(),
          excluded_categories: [atom()] | nil,
          routes: [route()],
          model: String.t(),
          temperature: float(),
          max_iterations: pos_integer(),
          context_window: pos_integer(),
          loop_detection_window: pos_integer(),
          loop_detection_warn_threshold: pos_integer(),
          loop_detection_kill_threshold: pos_integer(),
          activity_callback: activity_callback() | nil,
          stream_callback: stream_callback() | nil,
          context: map(),
          capability_registry: GenServer.server(),
          retry_delay_fn: (non_neg_integer() -> any())
        ]

  @typedoc """
  A finished loop. `tool_failures` counts the tool calls that came back as an
  error result (a tool that refused, exploded, was unknown, or received
  arguments it could not parse); the loop went on and the model answered, so
  the run's status alone would never show it.
  """
  @type loop_result :: %{
          response: String.t(),
          iterations: pos_integer(),
          total_tokens: non_neg_integer(),
          context_tokens: non_neg_integer(),
          tool_failures: non_neg_integer()
        }

  @spec run(loop_opts()) :: {:ok, loop_result()} | {:error, term()}
  def run(opts) do
    store = ToolResultStore.new()

    try do
      run_with_store(opts, store)
    after
      ToolResultStore.delete(store)
    end
  end

  defp run_with_store(opts, store) do
    state = build_state(opts, store)
    emit_stream(state, {:session_started, Map.get(state.context, :session_id)})

    case initial_chat(state) do
      {:ok, turn, state} -> continue_until_terminal(turn, state)
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_state(opts, store) do
    capability_registry = Keyword.get(opts, :capability_registry, CapabilityRegistry)
    allowed_tools = Keyword.get(opts, :allowed_tools)
    policy = Keyword.get(opts, :policy)
    trust = Keyword.get(opts, :trust)
    excluded_categories = Keyword.get(opts, :excluded_categories)
    routes = resolve_routes(opts)
    {first_route_key, _first_opts} = hd(routes)

    context =
      opts
      |> Keyword.get(:context, %{})
      |> stamp_effective_surface(trust, policy, allowed_tools)
      |> Map.put(:tool_result_store, store)

    {{capabilities, dispatchable}, capability_duration_us} =
      Telemetry.timed_us(fn ->
        {advertised, dispatchable} =
          resolve_capability_surfaces(opts, capability_registry,
            allowed_tools: allowed_tools,
            policy: policy,
            trust: trust,
            excluded_categories: excluded_categories
          )

        {Advertisement.prepare(advertised, context), dispatchable}
      end)

    emit_capability_selection_telemetry(
      capabilities,
      capability_duration_us,
      first_route_key,
      context,
      %{
        trust: trust,
        policy: policy,
        allowed_tools: allowed_tools,
        excluded_categories: excluded_categories
      }
    )

    %{
      messages: Keyword.fetch!(opts, :messages),
      capabilities: capabilities,
      capabilities_by_name: dispatch_index(dispatchable, capabilities),
      allowed_tools: allowed_tools,
      capability_registry: capability_registry,
      routes: routes,
      adapter: nil,
      route_key: first_route_key,
      adapter_opts: [],
      temperature: Keyword.get(opts, :temperature, 0.7),
      stream: stream_state(Keyword.get(opts, :stream_callback)),
      max_iter: Keyword.get(opts, :max_iterations, @max_iterations),
      context: context,
      iteration: 0,
      total_tokens: 0,
      context_tokens: 0,
      tool_failures: 0,
      store: store,
      substitutions: %{},
      not_compressible: MapSet.new(),
      context_window: Keyword.get(opts, :context_window),
      last_usage: %{prompt: 0, completion: 0},
      task: task_excerpt(Keyword.fetch!(opts, :messages)),
      loop_detector: loop_detector_state(opts),
      activity_callback: Keyword.get(opts, :activity_callback),
      stream_callback: Keyword.get(opts, :stream_callback),
      retry_delay_fn: Keyword.get(opts, :retry_delay_fn, &Process.sleep/1)
    }
  end

  # Single source of truth for the run's effective capability surface (§11.2):
  # the loop already resolves the surface from `(trust, policy, allowed_tools)`,
  # so it stamps the *resolved* class list and allowlist into the tool context.
  # `subagents` reads these to intersect a worker's baseline against the parent
  # run's ceiling — a confined run (a tool-narrowed job, a skill-confined run)
  # can never spawn workers that regain the tools it lost. Correct for every run
  # type, including workers themselves: a worker's own loop re-stamps its
  # (already-intersected) values. `effective_allowed_tools` is `nil` when the
  # run is unrestricted.
  defp stamp_effective_surface(context, trust, policy, allowed_tools) do
    context
    |> Map.put(:effective_policy, CapabilityRegistry.resolved_policy_classes(trust, policy))
    |> Map.put(:effective_allowed_tools, allowed_tools)
  end

  defp index_by_name(capabilities) do
    Map.new(capabilities, fn %Capability{name: name} = capability -> {name, capability} end)
  end

  # M10 §3.2: dispatchable ⊇ advertised. The dispatch index covers the full
  # surface (deferred tools stay callable by name), with the schema-refreshed
  # advertised entries winning so dynamic schemas dispatch consistently.
  defp dispatch_index(dispatchable, advertised) do
    Map.merge(index_by_name(dispatchable), index_by_name(advertised))
  end

  # Resolve the advertised (wire) and dispatchable (callable) capability
  # surfaces. Explicit capability lists come from the caller's profile
  # (TurnRunner passes both); the registry default path applies the deferral
  # partition itself — except for allowlist-curated loops, where the caller
  # already chose the exact surface and deferral would only obscure it.
  defp resolve_capability_surfaces(opts, registry, filter_opts) do
    case Keyword.get(opts, :capabilities) do
      nil ->
        capabilities = CapabilityRegistry.list_for(registry, filter_opts)

        if is_nil(filter_opts[:allowed_tools]) do
          %{advertised: advertised, deferred: deferred} = Deferral.partition(capabilities)
          {advertised, advertised ++ deferred}
        else
          {capabilities, capabilities}
        end

      capabilities when is_list(capabilities) ->
        {capabilities, Keyword.get(opts, :dispatchable_capabilities) || capabilities}
    end
  end

  # ONE route shape: `routes` (ordered list). A top-level injected `:adapter`
  # is sugar for a one-element list carrying the pre-bound module in its
  # route opts — the adapter-wins branch in `bind_route/2`, never re-resolved.
  defp resolve_routes(opts) do
    case Keyword.get(opts, :adapter) do
      nil ->
        case Keyword.fetch!(opts, :routes) do
          [_ | _] = routes -> routes
          [] -> raise ArgumentError, "AgentLoop requires at least one route"
        end

      adapter when is_atom(adapter) ->
        route_key =
          Keyword.get(opts, :route_key, %{
            provider: :mock,
            model: Keyword.get(opts, :model, "mock"),
            auth_mode: :api_key,
            base_url: "mock://"
          })

        [{route_key, Keyword.put(Keyword.get(opts, :adapter_opts, []), :adapter, adapter)}]
    end
  end

  # Binds one attempt: adapter module + per-route adapter opts. Cross-cutting
  # opts (correlation ids, the wrapped stream callback, temperature) are
  # merged onto every attempted route at this single point; the route's own
  # opts win, exactly like the pre-failover merge.
  defp bind_route(state, {route_key, route_opts}) do
    {adapter, route_opts} = Keyword.pop(route_opts, :adapter)

    adapter_opts =
      [
        model: route_key.model,
        base_url: route_key.base_url,
        temperature: state.temperature
      ]
      |> maybe_put_adapter_opt(:agent, context_agent(state.context))
      |> maybe_put_adapter_opt(:session_id, Map.get(state.context, :session_id))
      |> maybe_put_adapter_opt(:parent_session, Map.get(state.context, :parent_session))
      |> maybe_put_adapter_opt(:stream_callback, state.stream.callback)
      |> maybe_put_adapter_opt(:max_retained_screenshots, max_retained_screenshots())
      |> Keyword.merge(route_opts)

    %{
      state
      | adapter: adapter || Adapter.for_route(route_key),
        route_key: route_key,
        adapter_opts: adapter_opts,
        context_window: state.context_window || catalog_window(route_key)
    }
  end

  # An explicit `context_window` (tests, callers that know better) wins over
  # the catalog; the catalog answers a default for a model it does not know,
  # quietly: this runs on every route bind, and the unknown-model event
  # already fires where the model was chosen.
  defp catalog_window(%{provider: provider, model: model}),
    do: ModelCatalog.context_window_for(provider, model, unknown_model_telemetry: false)

  # The emitted? flag (§5 Streaming Boundary): the loop wraps the stream
  # callback so it KNOWS whether user-visible content was flushed — the
  # authoritative gate, since an adapter's `stage` derives from raw chunk
  # arrival, not from what the callback emitted.
  defp stream_state(nil), do: %{callback: nil, emitted: nil}

  defp stream_state(callback) when is_function(callback, 1) do
    emitted = :counters.new(1, [])

    wrapped = fn event ->
      record_stream_content(emitted, event)
      callback.(event)
    end

    %{callback: wrapped, emitted: emitted}
  end

  defp record_stream_content(counter, {:text_delta, _delta}), do: :counters.add(counter, 1, 1)

  defp record_stream_content(counter, {:reasoning_delta, _delta}),
    do: :counters.add(counter, 1, 1)

  defp record_stream_content(_counter, _event), do: :ok

  defp stream_content_emitted?(stream), do: stream_content_count(stream) > 0

  defp stream_content_count(%{emitted: nil}), do: 0
  defp stream_content_count(%{emitted: counter}), do: :counters.get(counter, 1)

  defp emit_capability_selection_telemetry(capabilities, duration_us, route_key, context, opts) do
    :telemetry.execute(
      [:fermix, :capabilities, :select],
      %{
        duration_us: duration_us,
        count: length(capabilities),
        description_bytes: capability_description_bytes(capabilities)
      },
      %{
        agent: context_agent(context) || "unknown",
        provider: route_key.provider,
        model: route_key.model,
        trust: opts.trust,
        policy: opts.policy,
        allowed_tools_filtered: not is_nil(opts.allowed_tools),
        excluded_categories: opts.excluded_categories || [],
        kind_counts: capability_counts(capabilities, & &1.kind),
        policy_counts: capability_counts(capabilities, & &1.policy_class)
      }
    )
  end

  defp capability_description_bytes(capabilities) do
    Enum.reduce(capabilities, 0, fn %Capability{description: description}, total ->
      total + byte_size(description || "")
    end)
  end

  defp capability_counts(capabilities, key_fun) do
    capabilities
    |> Enum.frequencies_by(key_fun)
    |> Map.reject(fn {_key, count} -> count == 0 end)
  end

  defp maybe_put_adapter_opt(opts, _key, nil), do: opts
  defp maybe_put_adapter_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp context_agent(%{agent_name: agent}) when is_binary(agent) or is_atom(agent), do: agent
  defp context_agent(_context), do: nil

  # How many tool-result screenshot images each adapter keeps live in the
  # replayed history (the rest are elided to a text marker). Tool-result images
  # come only from the browser/computer-use tools, so the cap lives in
  # `ComputerUse.Config`; adapters receive a plain integer and stay provider-pure.
  defp max_retained_screenshots, do: ComputerUse.Config.current().max_retained_screenshots

  # The initial chat is the only failover point: bounded by the route count
  # via the shared executor. Once a route answers, the whole tool loop
  # (`continue/3`) stays on it — provider_state is provider-specific.
  defp initial_chat(state) do
    start = System.monotonic_time(:millisecond)
    emit_stream(state, {:iteration_started, state.iteration + 1})
    emit_activity(state, :provider_start)

    case Failover.run_chain(state.routes, initial_attempt(state), failover_opts(state)) do
      {:ok, {turn, bound}} ->
        emit_activity(bound, :provider_response)
        duration_ms = System.monotonic_time(:millisecond) - start
        emit_telemetry(bound.iteration + 1, duration_ms, turn.tool_calls != [])

        {:ok, turn,
         %{
           bound
           | iteration: bound.iteration + 1,
             total_tokens: bound.total_tokens + turn.usage.total_tokens,
             context_tokens: peak_context_tokens(bound, turn),
             last_usage: last_usage(turn)
         }}

      {:error, reason} ->
        Logger.error("LLM call failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Rule #12 fail-loud: a turn carrying image content must not be sent to a model
  # that can't accept it — no silent drop, no degrade-to-text. Returns an error
  # tuple (not a raise) so it rides the normal failover/error flow: the chain can
  # try the next route for a vision-capable one, and the precise message reaches
  # the user instead of a generic crash. Checked per route, so a transient
  # failover onto a non-vision model is caught too.
  defp ensure_image_capable(bound) do
    if Adapter.has_image_content?(bound.messages) do
      %{provider: provider, model: model} = bound.route_key

      if ModelCatalog.vision?(provider, model),
        do: :ok,
        else: {:error, {:image_unsupported, provider, model}}
    else
      :ok
    end
  end

  defp initial_attempt(state) do
    fn route ->
      bound = bind_route(state, route)

      with :ok <- ensure_image_capable(bound),
           {:ok, turn} <-
             bound.adapter.chat(bound.messages, bound.capabilities, bound.adapter_opts) do
        {:ok, {turn, bound}}
      end
    end
  end

  # Streaming boundary (§5): once any delta reached the user, switching
  # providers would mix outputs — the loop's emitted? flag gates eligibility
  # on top of the error's own kind/stage.
  defp failover_opts(state) do
    opts = [
      eligible?: fn reason ->
        not stream_content_emitted?(state.stream) and Failover.eligible?(reason)
      end,
      retryable?: fn reason ->
        not stream_content_emitted?(state.stream) and Transient.retryable?(reason)
      end,
      telemetry: failover_telemetry_meta(state)
    ]

    opts = Keyword.put(opts, :retry_delay_fn, state.retry_delay_fn)

    # Cron opts out of the inner route-level retry (it owns its own
    # deadline-bounded outer backoff), so the two retry loops never stack.
    if Map.get(state.context, :route_transient_retry, true) do
      opts
    else
      Keyword.put(opts, :max_retries, 0)
    end
  end

  defp failover_telemetry_meta(state) do
    meta = %{agent: context_agent(state.context) || "unknown"}

    case Map.get(state.context, :session_id) do
      nil -> meta
      session_id -> Map.put(meta, :session_id, session_id)
    end
  end

  defp continue_until_terminal(%{tool_calls: []} = turn, state) do
    {:ok, terminal_result(turn.content, state)}
  end

  defp continue_until_terminal(_turn, %{iteration: i, max_iter: max}) when i >= max do
    {:error, "Maximum iterations (#{max}) reached"}
  end

  defp continue_until_terminal(turn, state) do
    # tool_call bridge unwrap (M10 §3.1) happens FIRST: loop detection,
    # channel-side-effect bounds, activity, telemetry, and dispatch all see
    # the underlying tool name, never the bridge.
    turn = %{turn | tool_calls: Enum.map(turn.tool_calls, &unwrap_bridge_call/1)}

    case detect_tool_loop(turn.tool_calls, state) do
      {:kill, reason} ->
        {:error, reason}

      {warning, state} ->
        run_continuation(turn, state, warning)
    end
  end

  # A well-formed tool_call rewrites to the underlying {name, arguments};
  # the provider's call_id is preserved so the result pairs with the original
  # function call. Malformed calls (missing/blank name, non-object arguments,
  # or bridge-on-bridge recursion) fall through unchanged and reach the
  # ToolCall stub executor, which answers with corrective guidance.
  defp unwrap_bridge_call(%{name: "tool_call"} = call) do
    with {:ok, args} <- parse_arguments(call.arguments),
         inner_name when is_binary(inner_name) and inner_name != "" <- Map.get(args, "name"),
         inner_args when is_map(inner_args) <- Map.get(args, "arguments", %{}),
         false <- inner_name == "tool_call" do
      %{call | name: inner_name, arguments: inner_args}
    else
      _malformed -> call
    end
  end

  defp unwrap_bridge_call(call), do: call

  defp run_continuation(turn, state, warning) do
    with {:ok, tool_results, sole_terminal?, failures} <-
           execute_tool_calls(turn.tool_calls, state),
         :ok <- ensure_tool_results_image_capable(tool_results, state) do
      state = %{state | tool_failures: state.tool_failures + failures}

      if sole_terminal? and blank?(turn.content) do
        # The terminal side-effect (react) delivered and IS the reply; the model
        # added no text and called no other tool. Skip the continuation LLM call —
        # nothing left to ask. The turn ends empty and the queue's §7 ledger
        # commits the marker + suppresses the retry, exactly as after a normal
        # empty continuation, but a full model round-trip cheaper.
        {:ok, terminal_result("", state)}
      else
        continue_turn(turn, tool_results, warning, state)
      end
    end
  end

  defp continue_turn(turn, tool_results, warning, state) do
    with {:ok, state} <- keep_within_budget(tool_results, state),
         {:ok, next_turn, state} <-
           continuation_call(turn.provider_state, tool_results, warning, state) do
      continue_until_terminal(next_turn, state)
    end
  end

  defp terminal_result(response, state) do
    %{
      response: response,
      iterations: state.iteration,
      total_tokens: state.total_tokens,
      context_tokens: state.context_tokens,
      tool_failures: state.tool_failures
    }
  end

  defp blank?(nil), do: true
  defp blank?(content) when is_binary(content), do: String.trim(content) == ""
  defp blank?(_content), do: false

  # Continuation parallel to `ensure_image_capable/1`: a tool RESULT carrying image
  # content (e.g. a screenshot) must not be sent back to a non-vision route — no
  # silent drop, no degrade-to-text (Rule #12). Same `{:image_unsupported, ...}`
  # shape so it rides the existing error flow and reaches the user verbatim. The
  # route is fixed for the tool loop, so this checks the bound provider/model.
  defp ensure_tool_results_image_capable(tool_results, state) do
    if Enum.any?(tool_results, &tool_result_has_images?/1) do
      %{provider: provider, model: model} = state.route_key

      if ModelCatalog.vision?(provider, model),
        do: :ok,
        else: {:error, {:image_unsupported, provider, model}}
    else
      :ok
    end
  end

  defp tool_result_has_images?(%{images: [_ | _]}), do: true
  defp tool_result_has_images?(_), do: false

  defp continuation_call(provider_state, tool_results, _warning, state) do
    start = System.monotonic_time(:millisecond)
    emit_stream(state, {:iteration_started, state.iteration + 1})

    case continue_or_recover(provider_state, tool_results, state) do
      {:ok, next_turn, state} ->
        emit_activity(state, :provider_response)
        duration_ms = System.monotonic_time(:millisecond) - start
        emit_telemetry(state.iteration + 1, duration_ms, next_turn.tool_calls != [])

        {:ok, next_turn,
         %{
           state
           | iteration: state.iteration + 1,
             total_tokens: state.total_tokens + next_turn.usage.total_tokens,
             context_tokens: peak_context_tokens(state, next_turn),
             last_usage: last_usage(next_turn)
         }}

      {:error, reason} ->
        Logger.error("LLM continuation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # See @continuation_retry_attempts. Runs through Failover.run_chain — the
  # shared bounded-recovery executor — pinned to the single route that answered
  # the initial call, with failover disabled: a continuation never switches
  # provider. The emitted-content guard is a PER-CALL snapshot, not the
  # turn-cumulative `stream_content_emitted?/1`: earlier iterations
  # legitimately streamed into the draft, so the guard compares against the
  # count taken just before this call — only an attempt that itself pushed a
  # delta is barred from re-issuing (a retry would duplicate what the user
  # already saw). `:provider_start` is emitted per attempt so a scheduled
  # run's inactivity watchdog sees each retry as progress rather than one
  # long silent window.
  defp continue_with_retry(provider_state, tool_results, state) do
    emitted_before = stream_content_count(state.stream)

    adapter_opts = continuation_opts(state)

    Failover.run_chain(
      [{state.route_key, adapter_opts}],
      fn _route ->
        emit_activity(state, :provider_start)
        state.adapter.continue(provider_state, tool_results, adapter_opts)
      end,
      eligible?: fn _reason -> false end,
      retryable?: fn reason ->
        stream_content_count(state.stream) == emitted_before and
          continuation_retryable?(reason)
      end,
      max_retries: @continuation_retry_attempts,
      retry_base_delay_ms: @continuation_retry_backoff_ms,
      retry_delay_fn: state.retry_delay_fn,
      telemetry: failover_telemetry_meta(state)
    )
  end

  # The continuation's transient classes (rationale at
  # @continuation_retry_attempts): measured zero-data timeouts, pool-checkout
  # failures, plus an explicit allowlist — transport cuts and provider-declared
  # unavailability. A positive list, not `Transient.retryable?/1` minus
  # exceptions: each kind's mid-loop policy is a deliberate decision, and
  # unmeasured timeouts stay out (a slow model re-issued for nothing).
  # `:connection_unavailable` is a Finch pool-checkout timeout, which fires
  # BEFORE the request function runs — zero bytes on the wire, so re-issuing
  # cannot duplicate work — and Finch picks among the host's `count: 2` pool
  # processes at random, so a bounded retry usually lands on a healthy one.
  # Interactive turns have no outer recovery (only cron runs reach the
  # scheduled-job runner's backoff), so excluding it here killed live turns.
  defp continuation_retryable?(reason) do
    Transient.pre_response_timeout?(reason) or Transient.connection_unavailable?(reason) or
      continuation_transient?(reason)
  end

  defp continuation_transient?({:provider_transport_error, %{kind: kind}}),
    do: kind in [:transport_closed, :network]

  defp continuation_transient?({:provider_error, %{kind: kind}}),
    do: kind in [:provider_unavailable]

  defp continuation_transient?(_reason), do: false

  # --- In-loop context compaction (docs/design/IN_LOOP_CONTEXT_OVERFLOW.md) ---

  # The substitution map rides only when it has entries, so a run that never
  # compacts sends byte-identical adapter opts.
  defp continuation_opts(%{substitutions: subs} = state) when map_size(subs) == 0,
    do: state.adapter_opts

  defp continuation_opts(state),
    do: Keyword.put(state.adapter_opts, :tool_result_substitutions, state.substitutions)

  defp last_usage(%{usage: usage}) do
    %{
      prompt: Map.get(usage, :prompt_tokens, 0),
      completion: Map.get(usage, :completion_tokens, 0)
    }
  end

  # §3.4: the next request is the last one the provider measured, plus the
  # reply it produced, plus the results about to be appended. Held under
  # `threshold × context_window` by digesting older results, oldest step
  # first. Images are not estimated; screenshot retention bounds them.
  defp keep_within_budget(tool_results, state) do
    estimate = context_estimate(tool_results, state)
    budget = context_budget(state)

    if estimate <= budget, do: {:ok, state}, else: reduce_to_budget(state, estimate, budget)
  end

  defp context_estimate(tool_results, state) do
    new_bytes =
      Enum.reduce(tool_results, 0, fn %{output: output}, acc ->
        acc + byte_size(to_string(output)) + @frame_overhead_bytes
      end)

    state.last_usage.prompt + state.last_usage.completion + div(new_bytes, @bytes_per_token)
  end

  defp context_budget(%{context_window: window}) when is_integer(window) and window > 0,
    do: trunc(CompactionConfig.threshold() * window)

  # One step per pass; a substituted or not-compressible result leaves the
  # candidate set, so the passes are bounded by the eligible steps.
  defp reduce_to_budget(state, estimate, budget) do
    case oldest_eligible_step(state) do
      [] -> {:ok, state}
      batch -> reduce_step_to_budget(batch, state, estimate, budget)
    end
  end

  defp reduce_step_to_budget(batch, state, estimate, budget) do
    with {:ok, state, saved_bytes} <- digest_entries(batch, :budget, state) do
      estimate = estimate - div(saved_bytes, @bytes_per_token)
      if estimate <= budget, do: {:ok, state}, else: reduce_to_budget(state, estimate, budget)
    end
  end

  defp oldest_eligible_step(state) do
    oldest_raw = oldest_raw_step(state)
    older = eligible_entries(state, fn entry -> entry.step < oldest_raw end)

    case Enum.min_by(older, & &1.step, fn -> nil end) do
      nil -> []
      %{step: step} -> Enum.filter(older, &(&1.step == step))
    end
  end

  # The step being answered carries `state.iteration`; it and the @raw_steps
  # before it stay raw.
  defp oldest_raw_step(state), do: state.iteration - @raw_steps

  # Metadata only; a body is fetched when its entry is chosen.
  defp eligible_entries(state, predicate) do
    state.store
    |> ToolResultStore.index()
    |> Enum.filter(fn meta ->
      meta.bytes > ToolResultDigest.target_bytes() and
        not Map.has_key?(state.substitutions, meta.call_id) and
        not MapSet.member?(state.not_compressible, meta.call_id) and
        predicate.(meta)
    end)
  end

  # §3.5: a refusal re-issues the provider call after the next reduction that
  # has candidates: older than the raw window, then the raw window, then the
  # step being answered (its raw text is in the store, and a digest is the
  # only way it can reach the model at all). Never a tool re-run. Only a call
  # that streamed nothing is re-issued, exactly like the transient retry.
  # Round 0 is the ordinary continuation; rounds 1..@recovery_rounds each
  # follow one reduction.
  defp continue_or_recover(provider_state, tool_results, state),
    do: attempt_continuation(provider_state, tool_results, state, 0)

  defp attempt_continuation(provider_state, tool_results, state, round) do
    emitted_before = stream_content_count(state.stream)

    case continue_with_retry(provider_state, tool_results, state) do
      {:ok, next_turn} ->
        note_round(state, round, :recovered)
        {:ok, next_turn, state}

      {:error, :context_length_exceeded} ->
        note_round(state, round, :refused_again)
        refused(provider_state, tool_results, state, emitted_before, round + 1)

      {:error, reason} ->
        note_round(state, round, :error)
        {:error, reason}
    end
  end

  defp note_round(_state, 0, _outcome), do: :ok
  defp note_round(state, round, outcome), do: emit_recovery(state, round, outcome)

  defp refused(_provider_state, _tool_results, _state, _emitted_before, round)
       when round > @recovery_rounds,
       do: {:error, :context_overflow_after_compaction}

  defp refused(provider_state, tool_results, state, emitted_before, round) do
    if stream_content_count(state.stream) == emitted_before,
      do: recovery_round(provider_state, tool_results, state, round),
      else: {:error, :context_length_exceeded}
  end

  defp recovery_round(provider_state, tool_results, state, round) do
    case next_reduction(tool_results, state) do
      :nothing_left ->
        emit_recovery(state, round, :nothing_left)
        {:error, :context_overflow_after_compaction}

      {:error, reason} ->
        emit_recovery(state, round, :digest_failed)
        {:error, reason}

      {:ok, state} ->
        attempt_continuation(
          provider_state,
          substitute_results(tool_results, state),
          state,
          round
        )
    end
  end

  defp next_reduction(tool_results, state) do
    current = MapSet.new(tool_results, & &1.call_id)
    oldest_raw = oldest_raw_step(state)

    candidates =
      Enum.find_value(
        [
          fn entry -> entry.step < oldest_raw end,
          fn entry -> entry.step >= oldest_raw and not MapSet.member?(current, entry.call_id) end,
          fn entry -> MapSet.member?(current, entry.call_id) end
        ],
        fn predicate -> non_empty(eligible_entries(state, predicate)) end
      )

    case candidates do
      nil ->
        :nothing_left

      batch ->
        with {:ok, state, _saved} <- digest_entries(batch, :recovery, state), do: {:ok, state}
    end
  end

  defp non_empty([]), do: nil
  defp non_empty(entries), do: entries

  # The step being answered is substituted by the loop itself: adapters only
  # substitute their replayed history.
  defp substitute_results(tool_results, %{substitutions: subs}) do
    Enum.map(tool_results, fn %{call_id: call_id} = result ->
      case Map.fetch(subs, call_id) do
        {:ok, text} -> %{result | output: text}
        :error -> result
      end
    end)
  end

  # One reduction: digest every entry of `batch`, stop at the first digest
  # failure. Returns the state with the substitutions and the bytes saved;
  # the event fires only when something was actually substituted.
  defp digest_entries(batch, trigger, state) do
    empty_tally = %{results: 0, before: 0, after: 0}

    case Enum.reduce_while(batch, {:ok, state, empty_tally}, &digest_into/2) do
      {:ok, state, %{results: 0}} ->
        {:ok, state, 0}

      {:ok, state, tally} ->
        emit_compaction(state, trigger, tally)
        {:ok, state, tally.before - tally.after}

      {:error, {:digest_failed, reason}} ->
        {:error, {:context_recovery_failed, reason}}
    end
  end

  defp digest_into(entry, {:ok, state, tally}) do
    case digest_entry(entry, state) do
      {:ok, state, delta} -> {:cont, {:ok, state, add_tally(tally, delta)}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp digest_entry(meta, state) do
    {:ok, entry} = ToolResultStore.fetch(state.store, meta.call_id)

    case ToolResultDigest.digest(entry.output, digest_opts(entry, state)) do
      {:ok, digest, tokens} ->
        substitute_if_shorter(entry, digest_text(entry, digest, state), tokens, state)

      {:not_compressible, tokens} ->
        {:ok, mark_not_compressible(entry, tokens, state), no_tally()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The rule is "never larger than what it replaces", judged on the text that
  # will actually ride in the transcript: digest plus its frames.
  defp substitute_if_shorter(entry, text, tokens, state) when byte_size(text) < entry.bytes do
    state = %{
      state
      | substitutions: Map.put(state.substitutions, entry.call_id, text),
        total_tokens: state.total_tokens + tokens
    }

    {:ok, state, %{results: 1, before: entry.bytes, after: byte_size(text)}}
  end

  defp substitute_if_shorter(entry, _text, tokens, state),
    do: {:ok, mark_not_compressible(entry, tokens, state), no_tally()}

  defp mark_not_compressible(entry, tokens, state) do
    %{
      state
      | not_compressible: MapSet.put(state.not_compressible, entry.call_id),
        total_tokens: state.total_tokens + tokens
    }
  end

  defp no_tally, do: %{results: 0, before: 0, after: 0}

  defp digest_opts(entry, state) do
    [
      task: state.task,
      tool_name: entry.tool_name,
      adapter: state.adapter,
      route: {state.route_key, state.adapter_opts},
      context_window: state.context_window,
      before_call: fn -> emit_activity(state, :provider_start) end,
      retry_delay_fn: state.retry_delay_fn
    ]
  end

  # The digest frame names the call id so the model can read the original
  # back, but only on a run that can actually call the recall tool (a
  # tool-narrowed job or a confined worker may not); the digest itself is
  # framed as untrusted when the result was.
  defp digest_text(entry, digest, state) do
    "[digest of a #{entry.bytes}-byte result from #{entry.tool_name} (call_id " <>
      "#{entry.call_id}), compressed to keep the context within budget. Facts, numbers, " <>
      "ids, URLs and error lines were kept; " <>
      recall_advice(entry, state) <> "]\n" <> ToolResultStore.frame(entry, digest)
  end

  defp recall_advice(entry, state) do
    if recall_available?(state),
      do: "for anything else, or for exact totals, use tool_result_recall on #{entry.call_id}.",
      else: "the rest of this result is not retrievable on this run."
  end

  defp recall_available?(state) do
    Map.has_key?(state.capabilities_by_name, "tool_result_recall") and
      capability_allowed?("tool_result_recall", state.allowed_tools)
  end

  defp add_tally(tally, delta) do
    %{
      results: tally.results + delta.results,
      before: tally.before + delta.before,
      after: tally.after + delta.after
    }
  end

  defp task_excerpt(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: "user", content: content} -> content_text(content)
      _message -> nil
    end)
    |> Text.truncate_utf8(@task_excerpt_bytes)
  end

  defp content_text(content) when is_binary(content), do: content

  defp content_text(parts) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: text} when is_binary(text) -> text
      %{"text" => text} when is_binary(text) -> text
      _part -> ""
    end)
  end

  defp content_text(_content), do: ""

  defp emit_compaction(state, trigger, tally) do
    :telemetry.execute(
      [:fermix, :agent_loop, :context_compaction],
      %{count: 1, results: tally.results, bytes_before: tally.before, bytes_after: tally.after},
      Map.merge(loop_event_meta(state), %{level: 1, trigger: trigger})
    )

    :ok
  end

  defp emit_recovery(state, round, outcome) do
    :telemetry.execute(
      [:fermix, :agent_loop, :context_recovery],
      %{count: 1},
      Map.merge(loop_event_meta(state), %{round: round, outcome: outcome})
    )
  end

  defp loop_event_meta(state) do
    state.context
    |> Telemetry.correlation()
    |> Map.merge(%{
      agent: to_string(context_agent(state.context) || "unknown"),
      iteration: state.iteration
    })
  end

  # At most ONE `:channel`-category call executes per iteration: the first one.
  # Every later one comes back as an error tool result the MODEL reads and can
  # act on, and non-channel calls in the same batch run normally, in order.
  # Refusing the whole iteration instead used to end the run with an error the
  # model never saw — a scheduled wardrobe run died that way after two paid
  # image generations (M46 §2.4).
  #
  # Returns the results for the provider, whether the turn's one call was a
  # terminal side-effect, and how many calls came back as an error result.
  defp execute_tool_calls(tool_calls, state) do
    {outcomes, _channel_used?} =
      Enum.map_reduce(tool_calls, false, &execute_or_refuse(&1, &2, state))

    {:ok, Enum.map(outcomes, &elem(&1, 0)), sole_terminal?(outcomes),
     Enum.count(outcomes, &(elem(&1, 2) == :error))}
  end

  defp execute_or_refuse(tool_call, channel_used?, state) do
    channel? = channel_side_effect_call?(tool_call, state)

    if channel? and channel_used? do
      {refused_channel_outcome(tool_call, state), true}
    else
      {executed_outcome(tool_call, state), channel_used? or channel?}
    end
  end

  defp executed_outcome(tool_call, state) do
    %{output: output, images: images, terminal: terminal, status: status, external?: external?} =
      run_tool_call(tool_call, state)

    output = sanitize_tool_output(output)
    record_tool_result(state, tool_call, output, external?)
    {build_tool_result(tool_call.call_id, output, images), terminal, status}
  end

  # Not executed, so no `:tool_start`/`:tool_finish` activity — but it IS one
  # model tool call, so it gets exactly one `[:fermix, :tool, :exec]` event under
  # the name the model used, like every other unexecuted call.
  defp refused_channel_outcome(%{call_id: call_id, name: name} = tool_call, state) do
    message =
      "Error: Only one channel side-effect tool call is executed per iteration; " <>
        "`#{name}` was not executed. Call it again in your next step."

    %{output: output} = trace_unexecuted(name, tool_call.arguments, message, state)
    output = sanitize_tool_output(output)
    record_tool_result(state, tool_call, output, false)
    {build_tool_result(call_id, output, []), false, :error}
  end

  # Every result the model receives is kept for the run (§3.1), under the
  # step whose tool calls produced it, before the provider sees it.
  defp record_tool_result(state, %{call_id: call_id, name: name}, output, external?) do
    ToolResultStore.put(state.store, %{
      call_id: call_id,
      step: state.iteration,
      tool_name: name,
      output: to_string(output),
      external?: external?
    })
  end

  # A turn ends without a continuation LLM call only when its ONE tool call was a
  # terminal side-effect that delivered (react). More than one call, or a
  # non-terminal call, always continues.
  defp sole_terminal?([{_result, true, _status}]), do: true
  defp sole_terminal?(_outcomes), do: false

  # Text-only results keep the exact pre-image shape (`%{call_id, output}`) so
  # every provider encoder and existing test stays byte-identical; image content
  # parts ride a dedicated key only when a tool actually produced them.
  defp build_tool_result(call_id, output, []), do: %{call_id: call_id, output: output}

  defp build_tool_result(call_id, output, [_ | _] = images),
    do: %{call_id: call_id, output: output, images: images}

  # Tool output can carry bytes that are not valid UTF-8 — a file read of a
  # source saved in Latin-1, raw command bytes, an HTTP body with a stray byte.
  # Jason rejects invalid UTF-8 and raises when a provider encodes the request
  # body, which crashes the whole run (and is invisible until that turn fires).
  # Replace invalid bytes with the Unicode replacement character at this single
  # seam so every tool result reaching every provider is encodable.
  defp sanitize_tool_output(output) when is_binary(output), do: String.replace_invalid(output)
  defp sanitize_tool_output(output), do: output

  defp channel_side_effect_call?(%{name: name}, state) when is_binary(name) do
    capability_allowed?(name, state.allowed_tools) and channel_capability?(name, state)
  end

  defp channel_side_effect_call?(_tool_call, _state), do: false

  defp channel_capability?(name, state) do
    case Map.fetch(state.capabilities_by_name, name) do
      {:ok, %Capability{metadata: metadata}} -> Map.get(metadata, :category) == :channel
      :error -> false
    end
  end

  # A tool that declares itself terminal (react) — its successful delivery ends
  # the turn without a continuation call. Discovered via `function_exported?`,
  # the same convention as `advertise?/1` / `dynamic_parameters/1`; tools without
  # the hook are never terminal.
  defp terminal_capability?(%Capability{executor: {mod, _fun, _args}}) when is_atom(mod) do
    function_exported?(mod, :terminal?, 0) and mod.terminal?()
  end

  defp terminal_capability?(_capability), do: false

  defp run_tool_call(%{name: name, arguments: arguments_raw}, state) do
    emit_activity(state, {:tool_start, name})

    result =
      case parse_arguments(arguments_raw) do
        {:ok, arguments} -> invoke_capability(name, arguments, state)
        {:error, reason} -> trace_unexecuted(name, arguments_raw, reason, state)
      end

    emit_activity(state, {:tool_finish, name, %{status: result.status}})
    result
  end

  # The dispatch chain returns a uniform `%{output, images}` so an image-producing
  # tool (e.g. a screenshot) can surface its image content parts to the provider;
  # every text-only path — errors, missing/disallowed tools — wraps its string
  # with no images via `text_result/2`. `status` is loop metadata (never sent to
  # the provider), carried so the `:tool_finish` activity event reports the real
  # outcome instead of a caller re-deriving it from the output text.
  defp text_result(output, status) when is_binary(output) and status in [:ok, :error],
    do: %{output: output, images: [], terminal: false, status: status, external?: false}

  defp invoke_capability(name, arguments, state) do
    if capability_allowed?(name, state.allowed_tools) do
      lookup_and_dispatch(name, arguments, state)
    else
      trace_unexecuted(name, arguments, "Error: Tool '#{name}' not available", state)
    end
  end

  defp lookup_and_dispatch(name, arguments, state) do
    case Map.fetch(state.capabilities_by_name, name) do
      {:ok, capability} -> dispatch_capability(capability, arguments, state.context)
      :error -> trace_unexecuted(name, arguments, "Error: Tool '#{name}' not found", state)
    end
  end

  # A tool call the model made that never reached a capability: an unregistered
  # or policy-filtered name, a name outside this run's `allowed_tools`, or
  # arguments that would not parse. Each returns its error to the model, and each
  # used to emit nothing — so the turn's telemetry showed an iteration whose tool
  # call left no tool row anywhere, in the JSONL trace or in Opik. The reader
  # could see that the model had called *something* and not what, which is how
  # two iterations spent calling a withdrawn harness by a guessed name went
  # unexplained. Routed through the shared emitter (never a hand-rolled
  # `:telemetry.execute`) so the invariant holds: one tool call by the model,
  # one `[:fermix, :tool, :exec]` event, recorded under the name the MODEL used —
  # the only name a reader has to search for. The three messages stay distinct so
  # the miss kinds do not collapse into one indistinguishable failure.
  defp trace_unexecuted(name, arguments, message, state) do
    ToolTelemetry.exec(name, state.context, false, 0,
      metadata: %{error: message},
      input: arguments
    )

    text_result(message, :error)
  end

  defp capability_allowed?(_name, nil), do: true
  defp capability_allowed?(name, allowed) when is_list(allowed), do: name in allowed

  # `external?` rides every outcome so the store can frame a digest or a
  # recalled slice of the result the way the original was framed.
  defp dispatch_capability(%Capability{} = capability, arguments, context) do
    capability
    |> dispatch_capability_result(arguments, context)
    |> Map.put(:external?, UntrustedContent.external?(capability))
  end

  defp dispatch_capability_result(%Capability{} = capability, arguments, context) do
    case Capability.execute(capability, arguments, context) do
      {:ok, %{success: true, output: output} = result} ->
        %{
          output: wrap_untrusted_content(output, capability),
          images: Map.get(result, :images, []),
          # `terminal` is loop metadata (never sent to the provider): true only
          # when the tool succeeded AND declares itself terminal (react). Every
          # other branch flows through `text_result/2` (terminal: false), so a
          # failed reaction is never terminal and the loop continues.
          terminal: terminal_capability?(capability),
          status: :ok
        }

      {:ok, %{success: false, error: error}} ->
        text_result("Error: #{wrap_untrusted_content(error, capability)}", :error)

      {:ok, other} when is_binary(other) ->
        text_result(wrap_untrusted_content(other, capability), :ok)

      {:ok, other} ->
        text_result(wrap_untrusted_content(inspect(other), capability), :ok)

      {:error, reason} ->
        text_result(
          "Error executing tool: #{wrap_untrusted_content(inspect(reason), capability)}",
          :error
        )
    end
  rescue
    e ->
      Logger.error(
        "Tool execution raised: #{Exception.message(e)}\n" <>
          Exception.format_stacktrace(__STACKTRACE__)
      )

      text_result(
        "Error: tool raised #{wrap_untrusted_content(Exception.message(e), capability)}",
        :error
      )
  end

  # Provenance as architecture (M10 P2): results from tools that return EXTERNAL
  # CONTENT (web, MCP servers, plugin APIs, computer-use screen text) are
  # delimited as data so the model never reads third-party text as instructions.
  # The classification + frame live in `Capabilities.UntrustedContent` — one
  # boundary shared with the realtime voice `ToolBridge`, so it can't drift
  # between the two model-facing paths.
  #
  # EVERY model-facing branch of `dispatch_capability/3` is wrapped, not just the
  # success one. A failure is not fermix-authored just because fermix wrote the
  # "Error:" prefix: `Mcp.Capability.format_reason/1` deliberately renders the
  # remote server's own sentence (so an agent can act on "out of credits" rather
  # than blind-retry), which means the error path carries attacker-controlled
  # prose too. Wrapping the vendor text and not the prefix keeps the frame
  # around exactly the untrusted region. Internal tools classify as non-external
  # and pass through unchanged on every branch, as before.
  defp wrap_untrusted_content(output, capability),
    do: UntrustedContent.wrap(output, capability)

  defp parse_arguments(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, args} -> {:ok, args}
      {:error, err} -> {:error, "Invalid JSON arguments: #{Exception.message(err)}"}
    end
  end

  defp parse_arguments(args) when is_map(args), do: {:ok, args}
  defp parse_arguments(_), do: {:ok, %{}}

  # Peak input size the model saw this turn, in real provider-reported prompt
  # tokens (max across all loop iterations). The gateway uses this to decide,
  # at commit time, whether the conversation has crossed the compaction
  # threshold — a real, provider-agnostic measure rather than a local estimate.
  defp peak_context_tokens(state, turn) do
    max(state.context_tokens, Map.get(turn.usage, :prompt_tokens, 0))
  end

  defp detect_tool_loop(tool_calls, state) do
    signatures = Enum.map(tool_calls, &tool_signature/1)
    detector = update_detector(state.loop_detector, signatures)

    cond do
      detector.kill_signature ->
        {:kill, loop_kill_message(detector.kill_signature, detector.kill_threshold)}

      detector.warning ->
        {loop_warning_message(detector.warning, detector.warn_threshold),
         %{state | loop_detector: detector}}

      true ->
        {nil, %{state | loop_detector: detector}}
    end
  end

  defp update_detector(detector, signatures) do
    detector = %{detector | warning: nil, kill_signature: nil}

    Enum.reduce(signatures, detector, fn signature, current ->
      recent = Enum.take([signature | current.recent], current.window)
      windowed = Enum.count(recent, &(&1 == signature))
      consecutive = recent |> Enum.take_while(&(&1 == signature)) |> length()
      warned = MapSet.member?(current.warned, signature)

      cond do
        # Kill only on an unbroken run: any different call in between means the
        # model is alternating work with re-observation, which the tool contract
        # itself mandates (fresh screenshot after every state-changing action;
        # NOT-delivered recovery re-sends identical coordinates). Interleaved
        # repetition gets the one-time warning below and stays bounded by the
        # iteration cap — a windowed kill ends healthy turns mid-work.
        consecutive >= current.kill_threshold ->
          %{current | recent: recent, kill_signature: signature}

        windowed >= current.warn_threshold and not warned ->
          %{
            current
            | recent: recent,
              warning: signature,
              warned: MapSet.put(current.warned, signature)
          }

        true ->
          %{current | recent: recent}
      end
    end)
  end

  defp tool_signature(%{name: name, arguments: arguments}) do
    {name, normalize_arguments(arguments)}
  end

  defp normalize_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} -> normalize_arguments(decoded)
      {:error, _reason} -> arguments
    end
  end

  defp normalize_arguments(arguments) do
    Jason.encode!(sort_json(arguments))
  end

  defp sort_json(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), sort_json(value)} end)
  end

  defp sort_json(list) when is_list(list), do: Enum.map(list, &sort_json/1)
  defp sort_json(value), do: value

  defp loop_warning_message({name, arguments}, threshold) do
    "Repeated tool call warning: #{name} with #{arguments} has repeated #{threshold} times. " <>
      "Do not call it again unless the arguments or plan meaningfully change."
  end

  defp loop_kill_message({name, arguments}, threshold) do
    "Repeated tool call loop detected: #{name} with #{arguments} reached #{threshold} repeats"
  end

  defp loop_detector_state(opts) do
    warn =
      Keyword.get(
        opts,
        :loop_detection_warn_threshold,
        Config.loop_detection_warn_threshold(opts)
      )

    kill =
      Keyword.get(
        opts,
        :loop_detection_kill_threshold,
        Config.loop_detection_kill_threshold(opts)
      )

    %{
      recent: [],
      warned: MapSet.new(),
      warning: nil,
      kill_signature: nil,
      window: Keyword.get(opts, :loop_detection_window, Config.loop_detection_window(opts)),
      warn_threshold: warn,
      kill_threshold: max(kill, warn)
    }
  end

  defp emit_telemetry(iteration, duration_ms, has_tool_calls) do
    :telemetry.execute(
      [:fermix, :agent, :iteration],
      %{duration_ms: duration_ms},
      %{iteration: iteration, has_tool_calls: has_tool_calls}
    )
  end

  defp emit_activity(%{activity_callback: callback}, event) when is_function(callback, 1) do
    callback.(event)
    :ok
  rescue
    error ->
      Logger.warning("AgentLoop activity callback raised: #{Exception.message(error)}")
      :ok
  end

  defp emit_activity(_state, _event), do: :ok

  # Loop-side stream events (session/iteration bookkeeping). Mirrors
  # emit_activity: a raising callback is logged, never crashes the turn —
  # streaming is a preview layer, the turn's reply path is authoritative.
  defp emit_stream(%{stream_callback: callback}, event) when is_function(callback, 1) do
    callback.(event)
    :ok
  rescue
    error ->
      Logger.warning("AgentLoop stream callback raised: #{Exception.message(error)}")
      :ok
  end

  defp emit_stream(_state, _event), do: :ok
end
