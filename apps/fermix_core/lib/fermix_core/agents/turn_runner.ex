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
  alias FermixCore.Providers.Error, as: ProviderError
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
  """
  @spec run(map(), map(), Reply.reply_fn()) ::
          {:ok, String.t(), non_neg_integer()} | {:error, term()}
  def run(msg, turn_state, deliver) when is_function(deliver, 1) do
    run_message_loop(msg, turn_state, deliver)
  end

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

    maybe_auto_compact(
      conversation_key,
      turn_state,
      compaction_target(turn_state),
      context_tokens
    )
  end

  @doc "Map an agent-loop error reason to the user-facing reply text."
  @spec error_reply(term()) :: String.t()
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

      codex_transport_closed_error?(reason) ->
        "The Codex provider closed the response stream before returning an answer. " <>
          "This is not a confirmed context-window error. Send /compact or /new, then resend; " <>
          "if it persists, lower reasoning_effort or check ChatGPT account status."

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

  defp codex_transport_closed_error?(reason) when is_binary(reason) do
    reason
    |> String.downcase()
    |> String.contains?("codex stream closed by peer")
  end

  defp codex_transport_closed_error?(_reason), do: false

  defp run_message_loop(msg, state, deliver) do
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

    user_message = %{role: "user", content: msg.content}

    {history, preflight_compaction} =
      maybe_preflight_auto_compact(conversation_key, state, profile, history, user_message)

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
      reply_fn: deliver,
      channel: msg.channel
    }

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
          capabilities: profile.capabilities
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
  defp auth_error?(:no_auth_file), do: true
  defp auth_error?(:auth_invalidated), do: true
  defp auth_error?(:refresh_failed), do: true
  defp auth_error?(:invalid_grant), do: true
  defp auth_error?({:auth_invalidated, _body}), do: true
  defp auth_error?({:refresh_failed, _reason}), do: true
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

  defp auth_reply({:provider_error, %{provider: provider}})
       when provider in [:openai, :anthropic, :xai] do
    label = ProviderError.provider_label(provider)
    "#{label} authentication failed — check the #{label} API key in `fermix setup` and retry."
  end

  defp auth_reply(_reason) do
    "Authentication failed — run `fermix auth login` from the host and try again."
  end

  defp provider_error_reply({:provider_error, %{kind: :rate_limit} = error}) do
    "#{provider_label(error)} rate-limited this request. Wait briefly and retry."
  end

  defp provider_error_reply({:provider_error, %{kind: :quota} = error}) do
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

    case resolve_loop_adapter(state) do
      {:adapter, mod, opts} ->
        base
        |> Keyword.put(:adapter, mod)
        |> Keyword.put(:adapter_opts, opts)

      {:route, key, opts} ->
        base
        |> Keyword.put(:route_key, key)
        |> Keyword.put(:adapter_opts, opts)
    end
  end

  # The compaction route mirrors the loop's adapter/route resolution; commit/3
  # recomputes it (cheap) so run/3 needn't thread it through its return value.
  defp compaction_target(state) do
    case resolve_loop_adapter(state) do
      {:adapter, mod, opts} -> {mod, direct_adapter_route_key(state, opts), opts}
      {:route, key, opts} -> {nil, key, opts}
    end
  end

  defp maybe_put_trust(opts, nil), do: opts
  defp maybe_put_trust(opts, trust) when is_atom(trust), do: Keyword.put(opts, :trust, trust)

  defp maybe_put_capabilities(opts, nil), do: opts

  defp maybe_put_capabilities(opts, capabilities) when is_list(capabilities),
    do: Keyword.put(opts, :capabilities, capabilities)

  defp resolve_loop_adapter(state) do
    cond do
      state.adapter ->
        {:adapter, state.adapter, state.adapter_opts}

      adapter_capable?(state.provider) ->
        # Test wiring: a provider that also implements the Adapter
        # behaviour can stand in as the adapter without separate plumbing.
        {:adapter, state.provider, Keyword.put(state.adapter_opts, :model, "mock-model")}

      true ->
        {route_key, adapter_opts} = RouteResolver.resolve!(state.adapter_overrides)
        {:route, route_key, adapter_opts}
    end
  end

  defp adapter_capable?(nil), do: false

  defp adapter_capable?(mod) when is_atom(mod) do
    Code.ensure_loaded?(mod) and function_exported?(mod, :chat, 3)
  end

  defp maybe_preflight_auto_compact(conversation_key, state, profile, history, user_message) do
    config = Application.get_env(:fermix_core, :compaction, [])

    cond do
      not CompactionConfig.enabled?(config) ->
        {history, :ok}

      auto_compaction_in_backoff?(conversation_key, state) ->
        emit_auto_compaction_skipped(conversation_key, :failure_backoff)
        {history, :ok}

      true ->
        preflight_auto_compact_now(
          conversation_key,
          state,
          profile,
          history,
          user_message,
          config
        )
    end
  end

  defp preflight_auto_compact_now(conversation_key, state, profile, history, user_message, config) do
    {adapter, route_key, adapter_opts} = compaction_target(state)
    context_window = ModelCatalog.context_window_for(route_key.provider, route_key.model)
    threshold = CompactionConfig.threshold(config)
    prompt_tokens = preflight_prompt_tokens(state.runtime_context, profile, history, user_message)

    if prompt_tokens / context_window >= threshold do
      compact_preflight_history(
        conversation_key,
        history,
        state,
        {adapter, route_key, adapter_opts},
        context_window,
        config
      )
    else
      emit_auto_compaction_skipped(conversation_key, :under_threshold)
      {history, :ok}
    end
  end

  defp preflight_prompt_tokens(ctx, profile, history, user_message) do
    ctx
    |> RuntimeContext.messages_for(profile, history, user_message)
    |> Compactor.estimate_tokens()
  end

  defp compact_preflight_history(
         conversation_key,
         history,
         state,
         {adapter, route_key, adapter_opts},
         context_window,
         config
       ) do
    result =
      run_auto_compaction(
        conversation_key,
        history,
        Compactor.estimate_tokens(history),
        adapter,
        route_key,
        compaction_adapter_opts(adapter_opts, config),
        context_window,
        state
      )

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
    {adapter, route_key, adapter_opts} = compaction_target
    context_window = ModelCatalog.context_window_for(route_key.provider, route_key.model)
    threshold = CompactionConfig.threshold(config)

    if context_tokens / context_window >= threshold do
      compact_when_over_threshold(
        conversation_key,
        state,
        {adapter, route_key, adapter_opts},
        context_window,
        config
      )
    else
      emit_auto_compaction_skipped(conversation_key, :under_threshold)
    end
  end

  defp compact_when_over_threshold(
         conversation_key,
         state,
         {adapter, route_key, adapter_opts},
         context_window,
         config
       ) do
    with {:ok, history} <- conversation_history(conversation_key, state) do
      run_auto_compaction(
        conversation_key,
        history,
        Compactor.estimate_tokens(history),
        adapter,
        route_key,
        compaction_adapter_opts(adapter_opts, config),
        context_window,
        state
      )
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

  defp run_auto_compaction(
         conversation_key,
         history,
         before_tokens,
         adapter,
         route_key,
         adapter_opts,
         context_window,
         state
       ) do
    budget = trunc(0.5 * context_window)

    {compaction_result, duration_us} =
      Telemetry.timed_us(fn ->
        Compactor.compact(history,
          enabled: true,
          token_budget: budget,
          route: {route_key, adapter_opts},
          adapter: adapter,
          context: compaction_context(conversation_key, state)
        )
      end)

    case compaction_result do
      {:ok, %{messages: compacted, compacted?: true}} ->
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

      {:ok, %{compacted?: false}} ->
        emit_auto_compaction_skipped(conversation_key, :nothing_to_compact)

      {:error, reason} ->
        Logger.error("auto-compaction failed: #{inspect(reason)}")
        emit_auto_compaction_skipped(conversation_key, reason)
        record_auto_compaction_failure(state, conversation_key)
    end
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
        extraction_timeout_ms: state.extraction_timeout_ms,
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
      {:route, route_key, adapter_opts} ->
        opts
        |> Keyword.put(:route_key, route_key)
        |> Keyword.put(:adapter_opts, adapter_opts)

      {:adapter, mod, adapter_opts} ->
        opts
        |> Keyword.put(:adapter, mod)
        |> Keyword.put(:adapter_opts, adapter_opts)
    end
  end
end
