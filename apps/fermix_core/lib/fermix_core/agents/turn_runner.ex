defmodule FermixCore.Agents.TurnRunner do
  @moduledoc """
  Executes a single agent turn for the Main Agent.

  Given a normalized channel message and a `turn_state` snapshot (provider,
  registries, memory config, and the prebuilt runtime context), `run/3` reads
  conversation history, builds the prompt, runs the agent loop, persists the
  USER message, and RETURNS the response — it does not deliver it or persist the
  assistant message. The gateway owns delivery, typing, and the commit.

  History split: `run/3` persists the user message when the turn is accepted;
  the gateway commits the assistant message via `commit/4` only after it
  delivers the reply.

  `deliver` (the third argument) is the gateway delivery closure. It is exposed
  to mid-turn channel tools (`send_attachment`) via the agent-loop context, so
  every channel send — mid-turn and final — flows through the same gateway
  delivery path. `commit/4` also runs memory review + auto-compaction (after
  delivery, so synchronous compaction stays off the reply path).

  Turn execution is pure of scheduling: the caller owns FIFO ordering and task
  supervision. `MainAgent` owns the runtime-context cache and hands a built
  snapshot in via `turn_state`; compaction-failure backoff state lives in
  `MainAgent` and is read/written through `turn_state.main_agent_server`.
  """

  require Logger

  alias FermixCore.AgentLoop
  alias FermixCore.Agents.ConversationKey
  alias FermixCore.Agents.IterationLimits
  alias FermixCore.Agents.MainAgent
  alias FermixCore.Agents.RuntimeContext
  alias FermixCore.Memory.CompactionConfig
  alias FermixCore.Memory.Compactor
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Prompt.CurrentDate
  alias FermixCore.Providers.Error, as: ProviderError
  alias FermixCore.Providers.Failover
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.RouteResolver
  alias FermixCore.Reply
  alias FermixCore.Telemetry

  @auto_compaction_failure_backoff_ms 60_000
  @doc """
  Run one agent turn and return its response. Persists the USER message (the
  turn was accepted) but NOT the assistant message — the gateway commits that
  via `commit/4` only after delivery. The caller (gateway) owns delivery,
  typing, FIFO ordering, and the commit. `deliver` is the gateway delivery
  closure, exposed to mid-turn channel tools via the agent-loop context.

  `stream_callback` (optional 4th argument) is the channel-streaming seam
  (docs/design/CHANNEL_STREAMING.md §5.2): an opaque 1-arity closure built by
  the gateway that receives `AgentLoop.stream_event()`s. `nil` (the 3-arity
  call) threads nothing — non-streaming surfaces (background runs, CLI sync,
  cron) keep calling `run/3` and are byte-identical to before.
  """
  @spec run(map(), map(), Reply.reply_fn(), AgentLoop.stream_callback() | nil) ::
          {:ok, String.t(), non_neg_integer()} | {:error, term()}
  def run(msg, turn_state, deliver, stream_callback \\ nil) when is_function(deliver, 1) do
    run_message_loop(msg, turn_state, deliver, stream_callback)
  end

  @doc """
  The computer-use origin for a turn, derived from its channel and consumed by the
  attended-origin gate (`ComputerUse.Safety.host_start_allowed?/1`).

  A detached `/background` run (`BackgroundRun.run/1`, channel `"background"`) has
  no live owner surface to observe or abort a host action, so it is `:unattended`
  and fails closed. Every other turn reaching `run/3` is a foreground interaction —
  a human in a chat or `fermix ask` — and is `:interactive`. Voice tags `:voice` on
  its own path; scheduled jobs bypass `run/3` and default to `:unattended`.
  """
  @spec computer_use_origin(map()) :: :interactive | :unattended
  def computer_use_origin(%{channel: "background"}), do: :unattended
  def computer_use_origin(_msg), do: :interactive

  @doc """
  Commit a delivered turn: persist the assistant message, dispatch a background
  memory review, and run auto-compaction. The gateway calls this only after the
  reply was delivered. Auto-compaction is synchronous; running it here keeps it
  off the reply path.

  `context_tokens` is the peak provider-reported prompt-token count from `run/3`.
  Auto-compaction triggers on that real measure against the model's context
  window, so the threshold behaves identically across providers and models.
  """
  @spec commit(map(), map(), String.t(), non_neg_integer()) :: :ok | :compacted
  def commit(msg, turn_state, response, context_tokens) do
    conversation_key = ConversationKey.from(msg)

    ConversationStore.add_message(
      conversation_key,
      "assistant",
      response,
      server: turn_state.conversation_store,
      sender: "main",
      agent_id: turn_state.memory_agent_id,
      owner_id: turn_state.memory_owner_id
    )

    maybe_start_memory_review(msg, turn_state)

    result =
      maybe_auto_compact(
        conversation_key,
        turn_state,
        compaction_target(turn_state),
        context_tokens
      )

    # Carry this turn's real peak so the NEXT turn's preflight gate reads it
    # (same real measure as this post-delivery gate). Best-effort, off the
    # reply path — mirrors clear_auto_compaction_failure.
    record_context_tokens_peak(turn_state, conversation_key, context_tokens)
    result
  end

  @doc "Map an agent-loop error reason to the user-facing reply text."
  @spec error_reply(term()) :: String.t()
  def error_reply({:all_routes_failed, [{_provider, _reason} | _rest] = attempted}) do
    providers = Enum.map_join(attempted, ", ", fn {provider, _reason} -> to_string(provider) end)
    {_last_provider, last_reason} = List.last(attempted)

    "All configured providers failed (tried: #{providers}). Last error: " <>
      error_reply(last_reason)
  end

  def error_reply({:image_unsupported, provider, model}) do
    "That message includes an image, but the current model (#{provider}/#{model}) can't accept " <>
      "images. Switch to a vision-capable model, or send text only."
  end

  def error_reply(reason) do
    cond do
      context_length_error?(reason) ->
        "This conversation has grown larger than the model's context window, so I couldn't " <>
          "process that turn. Send /new to start a fresh session (your long-term memory is kept), " <>
          "or /compact to summarize this one, then resend."

      auth_error?(reason) ->
        auth_reply(reason)

      max_iterations_error?(reason) ->
        "I hit the investigation step limit before finishing that request. " <>
          "Try narrowing the ask, or rerun it as a deeper investigation after increasing limits."

      reply = provider_error_reply(reason) ->
        reply

      true ->
        "Sorry, I encountered an error processing your message."
    end
  end

  # The adapters return :context_length_exceeded for OpenAI-family overflow; the
  # binary fallback catches other providers that only surface a message string.
  defp context_length_error?(:context_length_exceeded), do: true

  defp context_length_error?(reason) when is_binary(reason) do
    downcased = String.downcase(reason)

    String.contains?(downcased, "context_length_exceeded") or
      String.contains?(downcased, "maximum context length") or
      String.contains?(downcased, "context window")
  end

  defp context_length_error?(_reason), do: false

  defp max_iterations_error?(reason) when is_binary(reason) do
    String.contains?(reason, "Maximum iterations")
  end

  defp max_iterations_error?(_reason), do: false

  # Build the user turn. Text-only stays a bare `%{role, content}` map —
  # byte-identical to the pre-multimodal shape (no `:image_parts` key), so
  # accounting, compaction, persistence, and the provider prompt cache are
  # untouched. Inbound images the gateway materialized (M14) ride a transient
  # `:image_parts` list the provider encoder reads; they are never persisted.
  defp build_user_message(msg) do
    base = %{role: "user", content: msg.content}

    case Map.get(msg, :media_parts) || [] do
      [] -> base
      parts -> Map.put(base, :image_parts, parts)
    end
  end

  defp run_message_loop(msg, state, deliver, stream_callback) do
    start = System.monotonic_time(:millisecond)
    conversation_key = ConversationKey.from(msg)
    %RuntimeContext{} = ctx = state.runtime_context
    cache_status = Map.get(msg, :__runtime_context_cache_status, :hit)
    source_trust = Map.get(msg, :source_trust)
    profile = profile_for_trust(ctx, source_trust, state.capability_registry)

    emit_runtime_context_cache_telemetry(state, cache_status, profile)

    {history, history_duration_us} =
      Telemetry.timed_us(fn ->
        ConversationStore.get_history(conversation_key, server: state.conversation_store)
      end)

    user_message = build_user_message(msg)

    {history, preflight_compaction} =
      maybe_preflight_auto_compact(conversation_key, state, history)

    maybe_notify_preflight_compacted(preflight_compaction, deliver)
    emit_history_telemetry(msg, conversation_key, history, history_duration_us)

    messages = RuntimeContext.messages_for(ctx, profile, history, user_message)
    accounting = RuntimeContext.accounting_for(ctx, profile)
    emit_prompt_context_telemetry(state.memory_agent_id, messages, accounting, cache_status)

    context = %{
      agent_name: "main",
      conversation_key: conversation_key,
      session_id: "main-#{System.unique_integer([:positive, :monotonic])}",
      capability_registry: state.capability_registry,
      provider: state.provider,
      # Turn-start route-chain snapshot for subagents (§7): static for the
      # turn — a subagent spawned after a mid-turn failover still starts at
      # the primary and runs its own bounded failover.
      ordered_routes: Map.get(state, :ordered_routes),
      skill_registry: state.skill_registry,
      agent_supervisor: state.agent_supervisor,
      task_supervisor: state.task_supervisor,
      journal_base_dir: state.journal_base_dir,
      memory_store: state.memory_store,
      memory_repo: state.memory_repo,
      memory_agent_id: state.memory_agent_id,
      memory_owner_id: state.memory_owner_id,
      prompt_accounting: accounting,
      source_channel: msg.channel,
      source_trust: source_trust,
      # Attended-origin gate (COMPUTER_USE.md §7.6): only a turn with a live owner
      # surface who can abort may start a host session. Derived from the channel via
      # computer_use_origin/1 so a detached `/background` run fails closed instead of
      # being mislabelled attended. Scheduled jobs bypass TurnRunner (SessionManager's
      # `:unattended` default); voice tags `:voice` on its own path.
      computer_use_origin: computer_use_origin(msg),
      reply_fn: deliver,
      channel: msg.channel,
      # This-turn inbound channel images (M14), so `generate_image` edit can
      # reference `inbound:last`. Transient like `:image_parts`, never persisted.
      inbound_images: Map.get(msg, :media_parts) || []
    }

    # The composed prompt + runtime section are cached per profile, so the
    # current date can't live there (it would freeze until the cache is
    # invalidated). Inject it fresh every turn instead.
    messages = inject_current_date(messages)

    # `/ultra` is now a run-mode of the normal turn (not a separate
    # orchestrator): the tag unlocks the wider `subagents` caps via
    # `subagent_mode: :ultra` in context (which the loop reads when refreshing
    # the tool schema and the tool reads at execution) and prepends an
    # exhaustive-mode addendum to the system prompt. Everything then flows
    # through the ordinary loop — so its workers nest under the parent trace
    # exactly like regular `subagents` (the orphan-trace bug is dissolved).
    {messages, context} = apply_run_profile(run_profile(msg), messages, context)

    {loop_opts, loop_runtime_duration_us} =
      Telemetry.timed_us(fn ->
        build_loop_runtime(state, messages, context,
          source_trust: source_trust,
          capabilities: profile.capabilities,
          dispatchable_capabilities: Map.get(profile, :dispatchable, profile.capabilities),
          stream_callback: stream_callback
        )
      end)

    emit_loop_runtime_telemetry(msg, conversation_key, source_trust, loop_runtime_duration_us)
    persist_user_message(conversation_key, msg, state)

    run_normal(loop_opts, context, msg, start)
  end

  defp run_profile(msg) do
    (Map.get(msg, :metadata) || %{}) |> Map.get(:run_profile)
  end

  defp apply_run_profile(:ultra, messages, context) do
    {inject_ultra_addendum(messages), Map.put(context, :subagent_mode, :ultra)}
  end

  defp apply_run_profile(_normal, messages, context), do: {messages, context}

  # Kept in the leading system run (the Anthropic adapter requires system
  # messages to lead) so the date sits with the rest of the system prompt.
  defp inject_current_date(messages) do
    {system_run, rest} = Enum.split_while(messages, &(&1.role == "system"))
    system_run ++ [%{role: "system", content: CurrentDate.note()}] ++ rest
  end

  # Insert the ultra-mode addendum as the last leading system message — after
  # the composed system prompt, before history. Keeps system messages leading
  # (the Anthropic adapter requires it) and places the mode instruction where
  # the model reads it last.
  defp inject_ultra_addendum(messages) do
    {system_run, rest} = Enum.split_while(messages, &(&1.role == "system"))
    system_run ++ [%{role: "system", content: ultra_addendum()}] ++ rest
  end

  # Folds the old decompose/verify/synthesize stage prompts into one freeform
  # instruction (§6). No parser — the model drives fan-out through `subagents`.
  defp ultra_addendum do
    """
    ## Exhaustive mode (/ultra)
    This request was sent with /ultra — a deep, high-effort task where breadth and rigor
    matter more than speed.
    - Decompose it broadly and fan out WIDE with the `subagents` tool: many narrow, parallel
      probes, each gathering one specific piece of evidence. Prefer more probes over fewer —
      one probe = one question / one source / one angle.
    - For the hardest or highest-stakes sub-problems, also fan out for DEPTH: run two or three
      independent `subagents` on the SAME sub-problem (different framings or approaches),
      compare their results, and keep the best-supported answer — discard the rest.
    - Don't answer from a single pass when the question has many facets; gather first.
    - Before relying on a finding, check it is well-supported; drop weak or unsupported ones.
    - Then synthesize everything into one thorough, well-organized answer, and note any gaps
      the probes could not cover.
    """
    |> String.trim()
  end

  defp run_normal(loop_opts, context, msg, start) do
    case AgentLoop.run(loop_opts) do
      {:ok, result} ->
        duration_ms = System.monotonic_time(:millisecond) - start

        :telemetry.execute(
          [:fermix, :agent, :message],
          %{
            iterations: result.iterations,
            total_tokens: result.total_tokens,
            duration_ms: duration_ms
          },
          turn_message_metadata(context, msg, result)
        )

        Logger.info(
          "Agent loop completed in #{result.iterations} iterations, #{result.total_tokens} tokens"
        )

        {:ok, result.response, Map.get(result, :context_tokens, 0)}

      {:error, reason} ->
        Logger.error("Agent loop failed: #{inspect(reason)}")

        :telemetry.execute(
          [:fermix, :agent, :message_error],
          %{count: 1},
          %{
            channel: msg.channel,
            chat_id: msg.chat_id,
            reason: reason,
            session_id: context.session_id,
            agent: context.agent_name
          }
        )

        {:error, reason}
    end
  end

  defp turn_message_metadata(context, msg, result) do
    %{
      channel: msg.channel,
      chat_id: msg.chat_id,
      sender: msg.sender,
      session_id: context.session_id,
      agent: context.agent_name
    }
    |> maybe_put_turn_content(msg, result)
  end

  defp maybe_put_turn_content(metadata, msg, result) do
    if Telemetry.capture_content?() do
      metadata
      |> Map.put(:input, Telemetry.preview(Map.get(msg, :content)))
      |> Map.put(:output, Telemetry.preview(Map.get(result, :response)))
    else
      metadata
    end
  end

  # See `error_reply/1` for the auth-vs-generic mapping these patterns drive.
  # (The Codex `{:auth_invalidated, _}`/`{:refresh_failed, _}` tuples are gone —
  # the adapter now returns structured `{:provider_error, %{kind: :auth}}`.)
  defp auth_error?(:no_auth_file), do: true
  defp auth_error?(:auth_invalidated), do: true
  defp auth_error?(:refresh_failed), do: true
  defp auth_error?(:invalid_grant), do: true
  defp auth_error?({:provider_error, status, _body}) when status in [401, 403], do: true
  defp auth_error?({:provider_error, %{kind: :auth}}), do: true
  defp auth_error?({:provider_error, %{status: status}}) when status in [401, 403], do: true
  defp auth_error?(%{status: status}) when status in [401, 403], do: true

  defp auth_error?(reason) when is_binary(reason) do
    String.match?(
      reason,
      ~r/\b(401|403|Unauthorized|refresh_token_reused|invalid_grant|invalid_token|no_auth_file|auth_invalidated)\b/i
    )
  end

  defp auth_error?(_other), do: false

  # The hint keys on how the route authenticates: subscription OAuth gets a
  # reconnect verb, API-key modes get key advice, and Codex-shaped reasons
  # (token errors, refresh failures, bare strings) keep `fermix auth login`.
  defp auth_reply({:provider_error, %{provider: :anthropic, auth_mode: :oauth}}) do
    "Claude subscription authentication failed — reconnect with " <>
      "`fermix auth login --provider anthropic` and retry."
  end

  # xAI 403 in OAuth mode is tier/entitlement denial, not a stale token —
  # re-login won't fix it (design doc §6.5).
  defp auth_reply({:provider_error, %{provider: :xai, auth_mode: :oauth, status: 403}}) do
    "xAI subscription access denied — the Grok plan may not include API access. " <>
      "Switch to an API key in `fermix setup`, or check the plan tier."
  end

  defp auth_reply({:provider_error, %{provider: :xai, auth_mode: :oauth}}) do
    "xAI subscription authentication failed — reconnect with " <>
      "`fermix auth login --provider xai` and retry."
  end

  # Codex is OAuth-only — "check the API key" advice would mislead.
  defp auth_reply({:provider_error, %{provider: :openai_codex}}) do
    "Authentication failed — run `fermix auth login` from the host and try again."
  end

  # Any other OAuth-tagged auth failure gets reconnect advice, never API-key
  # advice (provider design §13 note 11 — dispatch on auth_mode, not a
  # per-provider allowlist).
  defp auth_reply({:provider_error, %{provider: provider, auth_mode: :oauth}}) do
    "#{ProviderError.provider_label(provider)} authentication failed — reconnect with " <>
      "`fermix auth login --provider #{provider}` and retry."
  end

  defp auth_reply({:provider_error, %{provider: provider}}) when is_atom(provider) do
    label = ProviderError.provider_label(provider)
    "#{label} authentication failed — check the #{label} API key in `fermix setup` and retry."
  end

  defp auth_reply(_reason) do
    "Authentication failed — run `fermix auth login` from the host and try again."
  end

  defp provider_error_reply({:provider_error, %{kind: :rate_limit} = error}) do
    usage_limit_reply(error) ||
      "#{provider_label(error)} rate-limited this request. Wait briefly and retry."
  end

  defp provider_error_reply({:provider_error, %{kind: :quota} = error}) do
    usage_limit_reply(error) ||
      "#{provider_label(error)} quota or credits are exhausted. Check the provider account, " <>
        "billing, or model access, then retry."
  end

  defp provider_error_reply({:provider_error, %{kind: :provider_unavailable} = error}) do
    "#{provider_label(error)} is unavailable or overloaded right now. Retry later, or switch providers."
  end

  defp provider_error_reply({:provider_error, %{kind: :timeout} = error}) do
    "#{provider_label(error)} timed out before returning a response. Retry, or lower the request size."
  end

  defp provider_error_reply({:provider_error, %{kind: :not_implemented} = error}) do
    "#{provider_label(error)} provider calls are not implemented yet. Switch providers in setup."
  end

  defp provider_error_reply({:provider_error, %{status: status} = error}) do
    "#{provider_label(error)} returned HTTP #{status}. #{provider_message(error)}"
  end

  defp provider_error_reply({:provider_transport_error, %{kind: :timeout} = error}) do
    "#{provider_label(error)} provider request hit a network timeout. Retry, or check network/provider status."
  end

  defp provider_error_reply({:provider_transport_error, %{kind: :transport_closed} = error}) do
    "#{provider_label(error)} provider closed the connection before returning a response. Retry, " <>
      "or reduce request size/effort if it persists."
  end

  defp provider_error_reply({:provider_transport_error, error}) when is_map(error) do
    "#{provider_label(error)} provider transport failed: #{inspect(Map.get(error, :reason))}."
  end

  defp provider_error_reply(_reason), do: nil

  # Friendly usage-limit message when the provider's 429 body carried a reset
  # time (OpenAI/Codex). Best-effort and provider-agnostic — nil when no reset
  # is available, so the caller falls back to its generic text.
  defp usage_limit_reply(%{resets_at: resets_at} = error) when is_number(resets_at) do
    mins = max(0, round((resets_at * 1000 - System.system_time(:millisecond)) / 60_000))

    "You've hit your #{provider_label(error)} usage limit#{plan_suffix(error)}. " <>
      "Try again in ~#{mins} min."
  end

  defp usage_limit_reply(_error), do: nil

  defp plan_suffix(%{plan_type: plan}) when is_binary(plan) and plan != "",
    do: " (#{String.downcase(plan)} plan)"

  defp plan_suffix(_error), do: ""

  defp provider_label(error) when is_map(error) do
    error
    |> Map.get(:provider, :provider)
    |> ProviderError.provider_label()
  end

  defp provider_message(%{message: message}) when is_binary(message) and message != "" do
    message
  end

  defp provider_message(_error), do: "Check provider logs and retry."

  defp persist_user_message(conversation_key, msg, state) do
    ConversationStore.add_message(
      conversation_key,
      "user",
      msg.content,
      server: state.conversation_store,
      sender: msg.sender,
      agent_id: state.memory_agent_id,
      owner_id: state.memory_owner_id,
      metadata: Map.get(msg, :metadata)
    )
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp build_loop_runtime(state, messages, context, opts) do
    base =
      [
        messages: messages,
        context: context,
        capability_registry: state.capability_registry,
        max_iterations: IterationLimits.interactive()
      ]
      |> maybe_put_trust(Keyword.get(opts, :source_trust))
      |> maybe_put_capabilities(Keyword.get(opts, :capabilities))
      |> maybe_put_dispatchable(Keyword.get(opts, :dispatchable_capabilities))
      |> maybe_put_stream_callback(Keyword.get(opts, :stream_callback))

    case resolve_loop_adapter(state) do
      {:adapter, mod, opts} ->
        base
        |> Keyword.put(:adapter, mod)
        |> Keyword.put(:adapter_opts, opts)

      {:routes, routes} ->
        Keyword.put(base, :routes, routes)
    end
  end

  # The compaction route chain mirrors the loop's resolution; commit/3
  # recomputes it (cheap) so run/3 needn't thread it through its return value.
  # Returns {adapter_or_nil, routes} — one shape downstream.
  defp compaction_target(state) do
    case resolve_loop_adapter(state) do
      {:adapter, mod, opts} -> {mod, [{direct_adapter_route_key(state, opts), opts}]}
      {:routes, routes} -> {nil, routes}
    end
  end

  defp maybe_put_trust(opts, nil), do: opts
  defp maybe_put_trust(opts, trust) when is_atom(trust), do: Keyword.put(opts, :trust, trust)

  defp maybe_put_capabilities(opts, nil), do: opts

  defp maybe_put_capabilities(opts, capabilities) when is_list(capabilities),
    do: Keyword.put(opts, :capabilities, capabilities)

  defp maybe_put_dispatchable(opts, nil), do: opts

  defp maybe_put_dispatchable(opts, capabilities) when is_list(capabilities),
    do: Keyword.put(opts, :dispatchable_capabilities, capabilities)

  defp maybe_put_stream_callback(opts, nil), do: opts

  defp maybe_put_stream_callback(opts, callback) when is_function(callback, 1),
    do: Keyword.put(opts, :stream_callback, callback)

  defp resolve_loop_adapter(state) do
    cond do
      state.adapter ->
        {:adapter, state.adapter, state.adapter_opts}

      adapter_capable?(state.provider) ->
        # Test wiring: a provider that also implements the Adapter
        # behaviour can stand in as the adapter without separate plumbing.
        {:adapter, state.provider, Keyword.put(state.adapter_opts, :model, "mock-model")}

      true ->
        {:routes, state_routes(state)}
    end
  end

  # MainAgent snapshots Selection.ordered_routes at boot. When the snapshot
  # is unavailable (boot logged a config error, e.g. multiple primaries),
  # resolve per turn so the clear error raises loudly on the turn path.
  defp state_routes(state) do
    case Map.get(state, :ordered_routes) do
      [_ | _] = routes ->
        routes

      _missing ->
        {route_key, adapter_opts} = RouteResolver.resolve!(state.adapter_overrides)
        [{route_key, adapter_opts}]
    end
  end

  defp adapter_capable?(nil), do: false

  defp adapter_capable?(mod) when is_atom(mod) do
    Code.ensure_loaded?(mod) and function_exported?(mod, :chat, 3)
  end

  defp maybe_preflight_auto_compact(conversation_key, state, history) do
    config = Application.get_env(:fermix_core, :compaction, [])

    cond do
      not CompactionConfig.enabled?(config) ->
        {history, :ok}

      auto_compaction_in_backoff?(conversation_key, state) ->
        emit_auto_compaction_skipped(conversation_key, :failure_backoff)
        {history, :ok}

      true ->
        preflight_auto_compact_now(conversation_key, state, history, config)
    end
  end

  # Gate the preflight compaction on the REAL provider-reported context_tokens
  # carried from the prior turn (turn_state.last_context_tokens, set at
  # checkout), so preflight behaves identically to the post-delivery gate. A 0
  # means no prior measurement exists (cold/first turn, or first turn after a
  # daemon restart): skip cleanly — there is NO byte-estimate fallback on the
  # trigger path. Post-delivery still catches an over-budget turn this turn.
  defp preflight_auto_compact_now(conversation_key, state, history, config) do
    context_tokens = Map.get(state, :last_context_tokens, 0)

    if context_tokens <= 0 do
      emit_auto_compaction_skipped(conversation_key, :no_prior_measurement)
      {history, :ok}
    else
      preflight_compact_if_over_threshold(
        conversation_key,
        state,
        history,
        config,
        context_tokens
      )
    end
  end

  defp preflight_compact_if_over_threshold(
         conversation_key,
         state,
         history,
         config,
         context_tokens
       ) do
    {_adapter, [{lead_key, _lead_opts} | _rest]} = target = compaction_target(state)
    context_window = ModelCatalog.context_window_for(lead_key.provider, lead_key.model)
    threshold = CompactionConfig.threshold(config)

    if context_tokens / context_window >= threshold do
      compact_preflight_history(conversation_key, history, state, target, config)
    else
      emit_auto_compaction_skipped(conversation_key, :under_threshold)
      {history, :ok}
    end
  end

  defp compact_preflight_history(conversation_key, history, state, target, config) do
    result = run_auto_compaction(conversation_key, history, target, config, state)

    case result do
      :compacted -> reload_compacted_history(conversation_key, state, history)
      _other -> {history, :ok}
    end
  end

  defp reload_compacted_history(conversation_key, state, fallback_history) do
    case conversation_history(conversation_key, state) do
      {:ok, history} ->
        {history, :compacted}

      {:error, reason} ->
        emit_auto_compaction_skipped(conversation_key, reason)
        {fallback_history, :ok}
    end
  end

  defp maybe_notify_preflight_compacted(:compacted, deliver) when is_function(deliver, 1) do
    case deliver.(
           {:text, "Trimmed older conversation history to stay within the context window."}
         ) do
      {:error, reason} ->
        Logger.error("preflight compaction notice delivery failed: #{inspect(reason)}")

      _delivered ->
        :ok
    end
  end

  defp maybe_notify_preflight_compacted(_status, _deliver), do: :ok

  defp maybe_auto_compact(conversation_key, state, compaction_target, context_tokens) do
    config = Application.get_env(:fermix_core, :compaction, [])

    cond do
      not CompactionConfig.enabled?(config) ->
        :ok

      auto_compaction_in_backoff?(conversation_key, state) ->
        emit_auto_compaction_skipped(conversation_key, :failure_backoff)

      true ->
        maybe_auto_compact_now(conversation_key, state, compaction_target, config, context_tokens)
    end
  end

  # Trigger on the REAL prompt-token count the provider reported for this turn
  # (peak across loop iterations) — it already includes the system prompt, tool
  # schemas, memory, and full history, so it is the true "context usage" and is
  # provider/model-agnostic. A 0 here means the turn made no provider call
  # (e.g. an all-cached/error path); treat that as "nothing to measure".
  defp maybe_auto_compact_now(_key, _state, _target, _config, context_tokens)
       when context_tokens <= 0 do
    :ok
  end

  defp maybe_auto_compact_now(conversation_key, state, compaction_target, config, context_tokens) do
    {_adapter, [{lead_key, _lead_opts} | _rest]} = compaction_target
    context_window = ModelCatalog.context_window_for(lead_key.provider, lead_key.model)
    threshold = CompactionConfig.threshold(config)

    if context_tokens / context_window >= threshold do
      compact_when_over_threshold(conversation_key, state, compaction_target, config)
    else
      emit_auto_compaction_skipped(conversation_key, :under_threshold)
    end
  end

  defp compact_when_over_threshold(conversation_key, state, target, config) do
    with {:ok, history} <- conversation_history(conversation_key, state) do
      run_auto_compaction(conversation_key, history, target, config, state)
    else
      {:error, reason} -> emit_auto_compaction_skipped(conversation_key, reason)
    end
  end

  # Summaries don't need the agent's full reasoning effort. Override the
  # compaction route's effort with the configured compaction effort (default
  # :medium) so a high-effort agent (e.g. xhigh) doesn't pay xhigh prices for a
  # mechanical summary. The agent's own turns are unaffected.
  defp compaction_adapter_opts(adapter_opts, config) do
    Keyword.put(adapter_opts, :reasoning_effort, CompactionConfig.reasoning_effort(config))
  end

  defp conversation_history(conversation_key, state) do
    {:ok, ConversationStore.get_history(conversation_key, server: state.conversation_store)}
  catch
    :exit, reason -> {:error, {:conversation_history_unavailable, reason}}
  end

  defp direct_adapter_route_key(state, adapter_opts) do
    %{
      provider: :mock,
      model: Keyword.get(adapter_opts, :model, Keyword.get(state.adapter_opts, :model, "mock")),
      auth_mode: :api_key,
      base_url: "mock://"
    }
  end

  # Compaction failover runs through the same shared executor as the agent
  # loop's initial chat — no second retry loop. Compactor itself stays
  # single-route; the chain lives here.
  defp run_auto_compaction(conversation_key, history, {adapter, routes}, config, state) do
    before_tokens = Compactor.estimate_tokens(history)
    attempt = compaction_attempt(history, adapter, config, conversation_key, state)

    {compaction_result, duration_us} =
      Telemetry.timed_us(fn ->
        routes
        |> compaction_routes(before_tokens)
        |> Failover.run_chain(attempt, telemetry: %{agent: "main", surface: :compaction})
      end)

    case compaction_result do
      {:ok, {%{messages: compacted, compacted?: true}, route_key}} ->
        commit_compacted_history(
          conversation_key,
          state,
          compacted,
          route_key,
          {before_tokens, duration_us}
        )

      {:ok, {%{compacted?: false}, _route_key}} ->
        emit_auto_compaction_skipped(conversation_key, :nothing_to_compact)

      {:error, reason} ->
        Logger.error("auto-compaction failed: #{inspect(reason)}")
        emit_auto_compaction_skipped(conversation_key, reason)
        record_auto_compaction_failure(state, conversation_key)
    end
  end

  defp compaction_attempt(history, adapter, config, conversation_key, state) do
    fn {route_key, adapter_opts} ->
      # Route opts may carry a pre-bound :adapter (the same seam as
      # AgentLoop.bind_route); it is never re-resolved via for_route.
      {route_adapter, adapter_opts} = Keyword.pop(adapter_opts, :adapter)

      result =
        Compactor.compact(history,
          enabled: true,
          token_budget:
            trunc(0.5 * ModelCatalog.context_window_for(route_key.provider, route_key.model)),
          route: {route_key, compaction_adapter_opts(adapter_opts, config)},
          adapter: adapter || route_adapter,
          context: compaction_context(conversation_key, state)
        )

      # Unwrap Compactor's tag so the shared executor classifies (and
      # emits failover telemetry for) the real provider reason.
      case result do
        {:ok, compacted} -> {:ok, {compacted, route_key}}
        {:error, {:compaction_failed, reason}} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Skip-not-clamp (§7): the lead route triggered compaction and always
  # stays; a fallback whose context window cannot fit the summarization
  # prompt is excluded rather than shrinking the lead budget.
  defp compaction_routes([lead | rest], prompt_tokens) do
    [
      lead
      | Enum.filter(rest, fn {route_key, _opts} ->
          ModelCatalog.context_window_for(route_key.provider, route_key.model) >= prompt_tokens
        end)
    ]
  end

  defp commit_compacted_history(conversation_key, state, compacted, route_key, timing) do
    {before_tokens, duration_us} = timing
    after_tokens = Compactor.estimate_tokens(compacted)

    :ok =
      ConversationStore.replace_history(conversation_key, compacted,
        server: state.conversation_store,
        agent_id: state.memory_agent_id,
        owner_id: state.memory_owner_id
      )

    :telemetry.execute(
      [:fermix, :compaction, :auto],
      %{before_tokens: before_tokens, after_tokens: after_tokens, duration_us: duration_us},
      %{
        conversation_key: conversation_key,
        provider: route_key.provider,
        model: route_key.model
      }
    )

    # Compaction is a context-refresh point: drop the cached runtime context
    # so the next turn rebuilds it (bootstrap + USER.md/MEMORY.md + tools),
    # picking up any memory the reviewer wrote during this conversation.
    invalidate_runtime_context(state)
    clear_auto_compaction_failure(state, conversation_key)
    :compacted
  end

  defp compaction_context(conversation_key, state) do
    %{
      conversation_key: conversation_key,
      memory_repo: state.memory_repo,
      memory_agent_id: state.memory_agent_id,
      memory_owner_id: state.memory_owner_id
    }
  end

  defp auto_compaction_in_backoff?(conversation_key, state) do
    case state |> Map.get(:compaction_failures, %{}) |> Map.get(conversation_key) do
      failed_at when is_integer(failed_at) ->
        monotonic_ms() - failed_at < @auto_compaction_failure_backoff_ms

      _no_failure ->
        false
    end
  end

  defp record_auto_compaction_failure(%{main_agent_server: nil}, _conversation_key), do: :ok

  defp record_auto_compaction_failure(state, _conversation_key)
       when not is_map_key(state, :main_agent_server), do: :ok

  defp record_auto_compaction_failure(state, conversation_key) do
    GenServer.call(
      state.main_agent_server,
      {:record_auto_compaction_failure, conversation_key, monotonic_ms()}
    )

    :ok
  end

  defp clear_auto_compaction_failure(%{main_agent_server: nil}, _conversation_key), do: :ok

  defp clear_auto_compaction_failure(state, _conversation_key)
       when not is_map_key(state, :main_agent_server), do: :ok

  defp clear_auto_compaction_failure(state, conversation_key) do
    GenServer.cast(state.main_agent_server, {:clear_auto_compaction_failure, conversation_key})
    :ok
  end

  # Best-effort: a missing/restarting MainAgent must not crash the commit (which
  # runs after the reply is delivered). A 0 means no provider call this turn —
  # skip, so a no-op turn never overwrites a real peak.
  defp record_context_tokens_peak(%{main_agent_server: nil}, _conversation_key, _tokens), do: :ok

  defp record_context_tokens_peak(state, _conversation_key, _tokens)
       when not is_map_key(state, :main_agent_server),
       do: :ok

  defp record_context_tokens_peak(_state, _conversation_key, tokens) when tokens <= 0, do: :ok

  defp record_context_tokens_peak(state, conversation_key, tokens) do
    MainAgent.record_context_tokens(state.main_agent_server, conversation_key, tokens)
    :ok
  end

  # Best-effort: a missing/restarting MainAgent must not crash the commit (which
  # runs after the reply is already delivered). The next checkout rebuilds the
  # context regardless, so a failed invalidation only costs a stale-cache turn.
  defp invalidate_runtime_context(%{main_agent_server: server}) when not is_nil(server) do
    MainAgent.invalidate_runtime_context(server, :compaction)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp invalidate_runtime_context(_state), do: :ok

  defp emit_auto_compaction_skipped(conversation_key, reason) do
    :telemetry.execute(
      [:fermix, :compaction, :auto_skipped],
      %{count: 1},
      %{conversation_key: conversation_key, reason: reason}
    )

    :ok
  end

  defp profile_for_trust(ctx, :operator, registry),
    do: RuntimeContext.profile_for(ctx, :operator, registry, [])

  defp profile_for_trust(ctx, :guest, registry),
    do: RuntimeContext.profile_for(ctx, :guest, registry, [])

  # nil trust = least privilege (matches CapabilityRegistry.resolve_policy/2).
  defp profile_for_trust(ctx, _trust, registry),
    do: RuntimeContext.profile_for(ctx, :guest, registry, [])

  defp emit_prompt_context_telemetry(agent_id, messages, accounting, cache_status) do
    :telemetry.execute(
      [:fermix, :agent, :prompt_context],
      %{
        duration_us: 0,
        message_count: length(messages),
        message_bytes: messages_bytes(messages),
        part_count: length(accounting)
      },
      %{agent: agent_id, cache: cache_status}
    )
  end

  defp emit_runtime_context_cache_telemetry(state, cache_status, profile) do
    :telemetry.execute(
      [:fermix, :runtime_context, :cache],
      %{count: 1},
      %{
        agent: state.memory_agent_id,
        result: cache_status,
        trust: profile.trust
      }
    )
  end

  defp emit_history_telemetry(msg, conversation_key, history, duration_us) do
    :telemetry.execute(
      [:fermix, :agent, :history],
      %{
        duration_us: duration_us,
        message_count: length(history),
        message_bytes: messages_bytes(history)
      },
      %{
        agent: "main",
        channel: msg.channel,
        chat_id: msg.chat_id,
        conversation_key: inspect(conversation_key)
      }
    )
  end

  defp emit_loop_runtime_telemetry(msg, conversation_key, source_trust, duration_us) do
    :telemetry.execute(
      [:fermix, :agent, :loop_runtime],
      %{duration_us: duration_us},
      %{
        agent: "main",
        channel: msg.channel,
        chat_id: msg.chat_id,
        conversation_key: inspect(conversation_key),
        trust: source_trust
      }
    )
  end

  defp messages_bytes(messages) do
    Enum.reduce(messages, 0, fn message, total ->
      total +
        byte_size(to_string(Map.get(message, :content) || Map.get(message, "content") || ""))
    end)
  end

  defp maybe_start_memory_review(msg, state) do
    opts =
      [
        provider: state.provider,
        agent_id: state.memory_agent_id,
        owner_id: state.memory_owner_id,
        conversation_key: ConversationKey.from(msg),
        source_trust: Map.get(msg, :source_trust),
        repo: state.memory_repo,
        task_supervisor: state.task_supervisor,
        main_agent_server: state.main_agent_server,
        review_interval_hours: state.review_interval_hours,
        review_max_messages: state.review_max_messages,
        review_input_token_budget: state.review_input_token_budget,
        review_failure_backoff_ms: state.review_failure_backoff_ms
      ]
      |> add_reviewer_route(state)

    {result, duration_us} =
      Telemetry.timed_us(fn ->
        state.memory_reviewer.start_background(opts)
      end)

    emit_review_dispatch_telemetry(msg, result, duration_us)
    result
  end

  defp emit_review_dispatch_telemetry(msg, result, duration_us) do
    :telemetry.execute(
      [:fermix, :memory, :review_dispatch],
      %{duration_us: duration_us},
      %{
        agent: "main",
        channel: msg.channel,
        chat_id: msg.chat_id,
        status: dispatch_status(result)
      }
    )
  end

  defp dispatch_status(:ok), do: :ok
  defp dispatch_status({:error, _reason}), do: :error
  defp dispatch_status(_other), do: :ok

  defp add_reviewer_route(opts, %{adapter: adapter, adapter_opts: adapter_opts})
       when not is_nil(adapter) do
    opts
    |> Keyword.put(:adapter, adapter)
    |> Keyword.put(:adapter_opts, adapter_opts)
  end

  defp add_reviewer_route(opts, state) do
    case resolve_loop_adapter(state) do
      {:routes, routes} ->
        Keyword.put(opts, :routes, routes)

      {:adapter, mod, adapter_opts} ->
        opts
        |> Keyword.put(:adapter, mod)
        |> Keyword.put(:adapter_opts, adapter_opts)
    end
  end
end
