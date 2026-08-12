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

  alias FermixCore.Capabilities.Advertisement
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Deferral
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.ComputerUse
  alias FermixCore.Memory.Config
  alias FermixCore.Providers.Adapter
  alias FermixCore.Providers.Failover
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.Transient
  alias FermixCore.Telemetry
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
          loop_detection_window: pos_integer(),
          loop_detection_warn_threshold: pos_integer(),
          loop_detection_kill_threshold: pos_integer(),
          activity_callback: activity_callback() | nil,
          stream_callback: stream_callback() | nil,
          context: map(),
          capability_registry: GenServer.server(),
          retry_delay_fn: (non_neg_integer() -> any())
        ]

  @type loop_result :: %{
          response: String.t(),
          iterations: pos_integer(),
          total_tokens: non_neg_integer(),
          context_tokens: non_neg_integer()
        }

  @spec run(loop_opts()) :: {:ok, loop_result()} | {:error, term()}
  def run(opts) do
    state = build_state(opts)
    emit_stream(state, {:session_started, Map.get(state.context, :session_id)})

    case initial_chat(state) do
      {:ok, turn, state} -> continue_until_terminal(turn, state)
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_state(opts) do
    capability_registry = Keyword.get(opts, :capability_registry, CapabilityRegistry)
    allowed_tools = Keyword.get(opts, :allowed_tools)
    policy = Keyword.get(opts, :policy)
    trust = Keyword.get(opts, :trust)
    excluded_categories = Keyword.get(opts, :excluded_categories)
    routes = resolve_routes(opts)
    {first_route_key, _first_opts} = hd(routes)

    context =
      stamp_effective_surface(Keyword.get(opts, :context, %{}), trust, policy, allowed_tools)

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
        adapter_opts: adapter_opts
    }
  end

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
             context_tokens: peak_context_tokens(bound, turn)
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
    with {:ok, tool_results, sole_terminal?} <- execute_tool_calls(turn.tool_calls, state),
         :ok <- ensure_tool_results_image_capable(tool_results, state) do
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
    with {:ok, next_turn, state} <-
           continuation_call(turn.provider_state, tool_results, warning, state) do
      continue_until_terminal(next_turn, state)
    end
  end

  defp terminal_result(response, state) do
    %{
      response: response,
      iterations: state.iteration,
      total_tokens: state.total_tokens,
      context_tokens: state.context_tokens
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

    case continue_with_retry(provider_state, tool_results, state) do
      {:ok, next_turn} ->
        emit_activity(state, :provider_response)
        duration_ms = System.monotonic_time(:millisecond) - start
        emit_telemetry(state.iteration + 1, duration_ms, next_turn.tool_calls != [])

        {:ok, next_turn,
         %{
           state
           | iteration: state.iteration + 1,
             total_tokens: state.total_tokens + next_turn.usage.total_tokens,
             context_tokens: peak_context_tokens(state, next_turn)
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

    Failover.run_chain(
      [{state.route_key, state.adapter_opts}],
      fn _route ->
        emit_activity(state, :provider_start)
        state.adapter.continue(provider_state, tool_results, state.adapter_opts)
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

  defp execute_tool_calls(tool_calls, state) do
    with :ok <- enforce_channel_side_effect_bound(tool_calls, state) do
      outcomes =
        Enum.map(tool_calls, fn tool_call ->
          %{output: output, images: images, terminal: terminal} = run_tool_call(tool_call, state)
          {build_tool_result(tool_call.call_id, sanitize_tool_output(output), images), terminal}
        end)

      {:ok, Enum.map(outcomes, &elem(&1, 0)), sole_terminal?(outcomes)}
    end
  end

  # A turn ends without a continuation LLM call only when its ONE tool call was a
  # terminal side-effect that delivered (react). More than one call, or a
  # non-terminal call, always continues.
  defp sole_terminal?([{_result, true}]), do: true
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

  defp enforce_channel_side_effect_bound(tool_calls, state) do
    count = Enum.count(tool_calls, &channel_side_effect_call?(&1, state))

    if count > 1 do
      {:error,
       "Multiple channel side-effect tool calls in one iteration are not allowed; " <>
         "retry with one channel send per iteration."}
    else
      :ok
    end
  end

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
    do: %{output: output, images: [], terminal: false, status: status}

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

  defp dispatch_capability(%Capability{} = capability, arguments, context) do
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
