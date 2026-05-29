defmodule FermixCore.Agents.TurnRunner do
  @moduledoc """
  Executes a single agent turn for the Main Agent.

  Given a normalized channel message and a `turn_state` snapshot (provider,
  registries, memory config, and the prebuilt runtime context), `run/3` reads
  conversation history, builds the prompt, runs the agent loop, persists the
  exchange, and RETURNS the response — it does not deliver it. The gateway owns
  delivery, typing, and post-turn finalization.

  `deliver` (the third argument) is the gateway delivery closure. It is exposed
  to mid-turn channel tools (`send_attachment`) via the agent-loop context, so
  every channel send — mid-turn and final — flows through the same gateway
  delivery path. `finalize/2` runs memory review + auto-compaction; the gateway
  calls it after delivering the reply, because compaction is synchronous and
  must not delay the reply.

  Turn execution is pure of scheduling: the caller owns single-flight,
  cancellation, and task supervision. `MainAgent` owns the runtime-context
  cache and hands a built snapshot in via `turn_state`; compaction-failure
  backoff state lives in `MainAgent` and is read/written through
  `turn_state.main_agent_server`.
  """

  require Logger

  alias FermixCore.AgentLoop
  alias FermixCore.Agents.ConversationKey
  alias FermixCore.Agents.RuntimeContext
  alias FermixCore.Memory.CompactionConfig
  alias FermixCore.Memory.Compactor
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.RouteResolver
  alias FermixCore.Reply
  alias FermixCore.Telemetry

  @auto_compaction_failure_backoff_ms 60_000

  @doc """
  Run one agent turn and return its response. The caller (gateway) owns
  delivery, typing, and post-turn finalization (`finalize/2`). `deliver` is the
  gateway delivery closure, exposed to mid-turn channel tools via the
  agent-loop context.
  """
  @spec run(map(), map(), Reply.reply_fn()) :: {:ok, String.t()} | {:error, term()}
  def run(msg, turn_state, deliver) when is_function(deliver, 1) do
    run_message_loop(msg, turn_state, deliver)
  end

  @doc """
  Post-turn finalization (success path only): dispatch background memory review
  and run auto-compaction. Separated from `run/3` so the gateway can deliver the
  reply first — compaction is synchronous and must not delay it.
  """
  @spec finalize(map(), map()) :: :ok
  def finalize(msg, turn_state) do
    maybe_start_memory_review(msg, turn_state)
    maybe_auto_compact(ConversationKey.from(msg), turn_state, compaction_target(turn_state))
    :ok
  end

  @doc "Map an agent-loop error reason to the user-facing reply text."
  @spec error_reply(term()) :: String.t()
  def error_reply(reason) do
    if auth_error?(reason) do
      "Authentication failed — run `fermix auth login` from the host and try again."
    else
      "Sorry, I encountered an error processing your message."
    end
  end

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

    emit_history_telemetry(msg, conversation_key, history, history_duration_us)

    user_message = %{role: "user", content: msg.content}
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

    {loop_opts, loop_runtime_duration_us} =
      Telemetry.timed_us(fn ->
        build_loop_runtime(state, messages, context,
          source_trust: source_trust,
          capabilities: profile.capabilities
        )
      end)

    emit_loop_runtime_telemetry(msg, conversation_key, source_trust, loop_runtime_duration_us)

    case AgentLoop.run(loop_opts) do
      {:ok, result} ->
        duration_ms = System.monotonic_time(:millisecond) - start

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

        ConversationStore.add_message(
          conversation_key,
          "assistant",
          result.response,
          server: state.conversation_store,
          sender: "main",
          agent_id: state.memory_agent_id,
          owner_id: state.memory_owner_id
        )

        :telemetry.execute(
          [:fermix, :agent, :message],
          %{
            iterations: result.iterations,
            total_tokens: result.total_tokens,
            duration_ms: duration_ms
          },
          %{channel: msg.channel, chat_id: msg.chat_id, sender: msg.sender}
        )

        Logger.info(
          "Agent loop completed in #{result.iterations} iterations, #{result.total_tokens} tokens"
        )

        {:ok, result.response}

      {:error, reason} ->
        Logger.error("Agent loop failed: #{inspect(reason)}")

        :telemetry.execute(
          [:fermix, :agent, :message_error],
          %{count: 1},
          %{channel: msg.channel, chat_id: msg.chat_id, reason: reason}
        )

        {:error, reason}
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
  defp auth_error?(%{status: status}) when status in [401, 403], do: true

  defp auth_error?(reason) when is_binary(reason) do
    String.match?(
      reason,
      ~r/\b(401|403|Unauthorized|refresh_token_reused|invalid_grant|invalid_token|no_auth_file|auth_invalidated)\b/i
    )
  end

  defp auth_error?(_other), do: false

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp build_loop_runtime(state, messages, context, opts) do
    base =
      [
        messages: messages,
        context: context,
        capability_registry: state.capability_registry
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

  # The compaction route mirrors the loop's adapter/route resolution; finalize/2
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

  defp maybe_auto_compact(conversation_key, state, compaction_target) do
    config = Application.get_env(:fermix_core, :compaction, [])

    cond do
      not CompactionConfig.enabled?(config) ->
        :ok

      auto_compaction_in_backoff?(conversation_key, state) ->
        emit_auto_compaction_skipped(conversation_key, :failure_backoff)

      true ->
        maybe_auto_compact_now(conversation_key, state, compaction_target, config)
    end
  end

  defp maybe_auto_compact_now(conversation_key, state, compaction_target, config) do
    with {:ok, history} <- conversation_history(conversation_key, state) do
      {adapter, route_key, adapter_opts} = compaction_target
      before_tokens = Compactor.estimate_tokens(history)
      context_window = ModelCatalog.context_window_for(route_key.provider, route_key.model)
      threshold = CompactionConfig.threshold(config)

      if before_tokens / context_window >= threshold do
        run_auto_compaction(
          conversation_key,
          history,
          before_tokens,
          adapter,
          route_key,
          adapter_opts,
          context_window,
          state
        )
      else
        emit_auto_compaction_skipped(conversation_key, :under_threshold)
      end
    else
      {:error, reason} -> emit_auto_compaction_skipped(conversation_key, reason)
    end
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

        clear_auto_compaction_failure(state, conversation_key)

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
    case Map.get(state.compaction_failures, conversation_key) do
      failed_at when is_integer(failed_at) ->
        monotonic_ms() - failed_at < @auto_compaction_failure_backoff_ms

      _no_failure ->
        false
    end
  end

  defp record_auto_compaction_failure(state, conversation_key) do
    GenServer.call(
      state.main_agent_server,
      {:record_auto_compaction_failure, conversation_key, monotonic_ms()}
    )

    :ok
  end

  defp clear_auto_compaction_failure(state, conversation_key) do
    GenServer.cast(state.main_agent_server, {:clear_auto_compaction_failure, conversation_key})
    :ok
  end

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
