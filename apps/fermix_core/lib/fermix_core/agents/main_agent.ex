defmodule FermixCore.Agents.MainAgent do
  @moduledoc """
  Persistent Main Agent GenServer.

  Receives channel messages, builds conversation context from history,
  runs the agent loop in a non-blocking Task, and sends responses
  back via the message's reply_fn callback.

  Same-conversation requests are single-flight. Each conversation keeps at most
  one active request task plus one pending replacement. If a newer message
  arrives while that conversation already has work in flight, the active task is
  canceled, the pending slot is replaced with the newest message, and only that
  newest message is started once the older task exits. Different conversations
  continue independently.

  Conversation identity is `{channel, chat_id, thread_scope}`. `thread_ts` is
  the canonical threaded-conversation identifier when present. `thread_scope` is
  accepted only as a fallback conversation-key segment for direct callers that
  do not provide `thread_ts`; channel adapters should put platform thread IDs in
  `thread_ts`.

  Started by Application supervisor with :permanent restart.
  """

  use GenServer, restart: :permanent

  require Logger

  alias FermixCore.AgentLoop
  alias FermixCore.Agents.AgentSupervisor
  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Memory.CompactionConfig
  alias FermixCore.Memory.Compactor
  alias FermixCore.Memory.Config
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.ExtractionDebouncer
  alias FermixCore.Memory.Scheduler
  alias FermixCore.Memory.Store
  alias FermixCore.Prompt.PromptComposer
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.RouteResolver

  @typing_interval_ms 4_000
  @typing_timeout_ms 300_000
  @auto_compaction_failure_backoff_ms 60_000
  @max_auto_compaction_failures 512

  @type thread_scope :: :root | String.t() | integer()

  @type channel_message :: %{
          :content => String.t(),
          :sender => String.t(),
          :channel => String.t(),
          :chat_id => String.t(),
          :reply_fn => (String.t() -> any()),
          optional(:typing_fn) => (-> any()),
          optional(:typing_interval_ms) => pos_integer(),
          optional(:typing_timeout_ms) => pos_integer(),
          optional(:thread_ts) => String.t() | integer() | nil,
          optional(:thread_scope) => thread_scope() | nil
        }

  @type conversation_key :: {
          channel :: String.t(),
          chat_id :: String.t(),
          thread_scope()
        }

  @type pending_request :: %{
          request_id: pos_integer(),
          message: channel_message()
        }

  @type active_request :: %{
          request_id: pos_integer(),
          pid: pid(),
          monitor_ref: reference()
        }

  @type conversation_runtime :: %{
          next_request_id: non_neg_integer(),
          active: active_request() | nil,
          pending: pending_request() | nil
        }

  @type status :: %{
          name: String.t(),
          health: :online,
          activity: :idle | :running,
          status: :idle | :running,
          pid: pid(),
          active_conversations: non_neg_integer(),
          pending_conversations: non_neg_integer(),
          active_requests: non_neg_integer(),
          pending_requests: non_neg_integer(),
          available_skills: [String.t()],
          provider: atom() | nil,
          model: String.t() | nil,
          memory: %{
            extraction_enabled: boolean(),
            agent_id: String.t(),
            owner_id: String.t()
          }
        }

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec handle_message(channel_message(), GenServer.server()) :: :ok
  def handle_message(
        %{
          content: content,
          sender: sender,
          channel: channel,
          chat_id: chat_id,
          reply_fn: reply_fn
        } =
          msg,
        server \\ __MODULE__
      )
      when is_binary(content) and is_binary(sender) and is_binary(channel) and
             is_binary(chat_id) and is_function(reply_fn, 1) do
    GenServer.cast(server, {:handle_message, msg})
  end

  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @spec reload_skills(GenServer.server()) :: {:ok, [String.t()]} | {:error, term()}
  def reload_skills(server \\ __MODULE__) do
    GenServer.call(server, :reload_skills)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    Logger.info("Main Agent started")

    skill_registry = Keyword.get(opts, :skill_registry, SkillRegistry)

    state = %{
      provider: Keyword.get(opts, :provider, FermixCore.Providers.OpenAI),
      capability_registry:
        Keyword.get(opts, :capability_registry, FermixCore.Capabilities.Registry),
      adapter_overrides: resolved_adapter_overrides(opts),
      adapter: Keyword.get(opts, :adapter),
      adapter_opts: Keyword.get(opts, :adapter_opts, []),
      agent_supervisor: Keyword.get(opts, :agent_supervisor, AgentSupervisor),
      skill_registry: skill_registry,
      available_skills: load_available_skills(skill_registry),
      conversation_store: Keyword.get(opts, :conversation_store, ConversationStore),
      task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
      journal_base_dir: Keyword.get(opts, :journal_base_dir),
      memory_store: Keyword.get(opts, :memory_store, Store),
      memory_repo: Keyword.get(opts, :memory_repo, Config.repo_server(opts)),
      memory_scheduler: Keyword.get(opts, :memory_scheduler, Scheduler),
      extraction_debouncer: Keyword.get(opts, :extraction_debouncer, ExtractionDebouncer),
      memory_agent_id: Config.agent_id(opts),
      memory_owner_id: Config.owner_id(opts),
      extraction_enabled: Config.extraction_enabled?(opts),
      extraction_timeout_ms: Config.extraction_timeout_ms(opts),
      extraction_context_messages: Config.extraction_context_messages(opts),
      extraction_min_confidence: Config.extraction_min_confidence(opts),
      extraction_debounce_ms: Config.extraction_debounce_ms(opts),
      extraction_model: Config.extraction_model(opts),
      conversations: %{},
      compaction_failures: %{},
      task_refs: %{}
    }

    {:ok, state}
  end

  # Bakes the configured provider/default_model/reasoning_effort into the
  # agent's adapter_overrides at boot so RouteResolver picks them up at
  # request time. Explicit opts win:
  #   * If the caller sets `:provider` in opts, opts win whole — the config
  #     block belongs to a different provider and its model/reasoning_effort
  #     would leak across providers (e.g. `:openai_codex`'s effort applied
  #     to an `:anthropic` route).
  #   * Otherwise, config provides provider+model+reasoning_effort and
  #     explicit opts override per-key.
  # The snapshot is taken once at init; live config edits require a daemon
  # restart (BootReport.restart_required? already enforces this for the
  # wizard).
  defp resolved_adapter_overrides(opts) do
    explicit = Keyword.get(opts, :adapter_overrides, [])

    if Keyword.has_key?(explicit, :provider) do
      explicit
    else
      Keyword.merge(adapter_overrides_from_config(), explicit)
    end
  end

  defp adapter_overrides_from_config do
    agent_config = Application.get_env(:fermix_core, :agent, [])
    providers = Application.get_env(:fermix_core, :providers, [])

    case Keyword.get(agent_config, :provider) do
      nil ->
        []

      provider when provider in [:openai, :openai_codex, :anthropic] ->
        provider_config = Keyword.get(providers, provider, [])

        [provider: provider]
        |> maybe_put_override(:model, Keyword.get(provider_config, :default_model))
        |> maybe_put_override(:reasoning_effort, Keyword.get(provider_config, :reasoning_effort))

      other ->
        Logger.warning(
          "MainAgent ignoring unknown provider #{inspect(other)} in :fermix_core, :agent, :provider"
        )

        []
    end
  end

  defp maybe_put_override(overrides, _key, nil), do: overrides
  defp maybe_put_override(overrides, key, value), do: Keyword.put(overrides, key, value)

  @impl true
  def handle_cast({:handle_message, msg}, state) do
    conversation_key = conversation_key(msg)
    state = enqueue_latest_message(conversation_key, msg, state)

    Logger.info("Main Agent received message from #{msg.channel}/#{msg.chat_id}")

    state =
      state
      |> maybe_cancel_active_request(conversation_key)
      |> maybe_start_next_request(conversation_key)

    {:noreply, state}
  end

  def handle_cast({:clear_auto_compaction_failure, conversation_key}, state) do
    {:noreply, update_in(state.compaction_failures, &Map.delete(&1, conversation_key))}
  end

  @impl true
  def handle_call(:reload_skills, _from, state) do
    case reload_available_skills(state.skill_registry) do
      {:ok, names, available_skills} ->
        {:reply, {:ok, names}, %{state | available_skills: available_skills}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status_from_state(state), state}
  end

  def handle_call({:record_auto_compaction_failure, conversation_key, failed_at_ms}, _from, state) do
    {:reply, :ok,
     update_in(state.compaction_failures, fn failures ->
       failures
       |> Map.put(conversation_key, failed_at_ms)
       |> prune_auto_compaction_failures()
     end)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.task_refs, ref) do
      {nil, _task_refs} ->
        {:noreply, state}

      {conversation_key, task_refs} ->
        state =
          state
          |> Map.put(:task_refs, task_refs)
          |> clear_active_request(conversation_key, ref, reason)
          |> maybe_start_next_request(conversation_key)

        {:noreply, state}
    end
  end

  # --- Internals ---

  defp conversation_key(%{channel: channel, chat_id: chat_id} = msg) do
    {channel, chat_id, thread_scope(msg)}
  end

  defp thread_scope(%{thread_ts: thread_ts}) when not is_nil(thread_ts), do: thread_ts

  defp thread_scope(%{thread_scope: thread_scope})
       when thread_scope == :root or is_binary(thread_scope) or is_integer(thread_scope),
       do: thread_scope

  defp thread_scope(_msg), do: :root

  defp empty_conversation_runtime do
    %{next_request_id: 0, active: nil, pending: nil}
  end

  defp enqueue_latest_message(conversation_key, msg, state) do
    conversation =
      state.conversations
      |> Map.get(conversation_key, empty_conversation_runtime())
      |> Map.update!(:next_request_id, &(&1 + 1))

    pending = %{request_id: conversation.next_request_id, message: msg}

    put_conversation_runtime(state, conversation_key, %{conversation | pending: pending})
  end

  defp maybe_cancel_active_request(state, conversation_key) do
    case get_in(state, [:conversations, conversation_key, :active]) do
      nil ->
        state

      %{pid: pid, request_id: request_id} ->
        Logger.info(
          "Canceling in-flight Main Agent request #{request_id} for #{format_conversation_key(conversation_key)}"
        )

        case Task.Supervisor.terminate_child(state.task_supervisor, pid) do
          :ok ->
            state

          {:error, :not_found} ->
            state
        end
    end
  end

  defp maybe_start_next_request(state, conversation_key) do
    case Map.get(state.conversations, conversation_key, empty_conversation_runtime()) do
      %{active: nil, pending: pending_request} = conversation when not is_nil(pending_request) ->
        start_pending_request(state, conversation_key, conversation, pending_request)

      _conversation ->
        state
    end
  end

  defp start_pending_request(
         state,
         conversation_key,
         conversation,
         %{request_id: request_id, message: msg}
       ) do
    task_state = task_runtime_state(state)

    case Task.Supervisor.start_child(state.task_supervisor, fn ->
           process_message(msg, task_state)
         end) do
      {:ok, pid} ->
        mark_request_started(state, conversation_key, conversation, request_id, pid)

      {:error, reason} ->
        handle_request_start_error(
          state,
          conversation_key,
          conversation,
          request_id,
          msg,
          reason
        )
    end
  end

  defp mark_request_started(state, conversation_key, conversation, request_id, pid) do
    monitor_ref = Process.monitor(pid)

    Logger.info(
      "Starting Main Agent request #{request_id} for #{format_conversation_key(conversation_key)}"
    )

    conversation = %{
      conversation
      | active: %{request_id: request_id, pid: pid, monitor_ref: monitor_ref},
        pending: nil
    }

    state
    |> put_conversation_runtime(conversation_key, conversation)
    |> update_in([:task_refs], &Map.put(&1, monitor_ref, conversation_key))
  end

  defp handle_request_start_error(
         state,
         conversation_key,
         conversation,
         request_id,
         msg,
         reason
       ) do
    Logger.error(
      "Failed to start Main Agent request #{request_id} for #{format_conversation_key(conversation_key)}: #{inspect(reason)}"
    )

    send_reply_async(msg, "Sorry, I encountered an error processing your message.")

    state
    |> put_conversation_runtime(conversation_key, %{conversation | pending: nil})
  end

  defp send_reply_async(msg, response) do
    spawn(fn -> deliver_reply(msg, response) end)
    :ok
  end

  defp clear_active_request(state, conversation_key, monitor_ref, reason) do
    case Map.get(state.conversations, conversation_key) do
      %{active: %{monitor_ref: ^monitor_ref, request_id: request_id}} = conversation ->
        Logger.info(
          "Main Agent request #{request_id} exited for #{format_conversation_key(conversation_key)} with reason #{inspect(reason)}"
        )

        put_conversation_runtime(state, conversation_key, %{conversation | active: nil})

      _conversation ->
        state
    end
  end

  defp put_conversation_runtime(state, conversation_key, %{active: nil, pending: nil}) do
    update_in(state.conversations, &Map.delete(&1, conversation_key))
  end

  defp put_conversation_runtime(state, conversation_key, conversation_runtime) do
    update_in(state.conversations, &Map.put(&1, conversation_key, conversation_runtime))
  end

  # Remote channels are mapped to `:third_party` — the registry default for
  # that trust is `:read_only` only. Local channels (cli, daemon socket,
  # realtime, scheduled jobs) stay `nil` (unfiltered main-agent surface).
  # Audit F-02: prevent prompt-injected remote messages from reaching write,
  # exec, network, or external-api tools.
  @remote_channels ~w(telegram whatsapp slack discord signal)

  defp source_trust_for_channel(channel) when is_binary(channel) do
    if channel in @remote_channels, do: :third_party, else: nil
  end

  defp source_trust_for_channel(_channel), do: nil

  defp build_loop_runtime(state, messages, context, opts) do
    base =
      [
        messages: messages,
        context: context,
        capability_registry: state.capability_registry
      ]
      |> maybe_put_trust(Keyword.get(opts, :source_trust))

    case resolve_loop_adapter(state) do
      {:adapter, mod, opts} ->
        loop_opts =
          base
          |> Keyword.put(:adapter, mod)
          |> Keyword.put(:adapter_opts, opts)

        {loop_opts, {mod, direct_adapter_route_key(state, opts), opts}}

      {:route, key, opts} ->
        loop_opts =
          base
          |> Keyword.put(:route_key, key)
          |> Keyword.put(:adapter_opts, opts)

        {loop_opts, {nil, key, opts}}
    end
  end

  defp maybe_put_trust(opts, nil), do: opts
  defp maybe_put_trust(opts, trust) when is_atom(trust), do: Keyword.put(opts, :trust, trust)

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

  defp task_runtime_state(state) do
    %{
      provider: state.provider,
      capability_registry: state.capability_registry,
      adapter_overrides: state.adapter_overrides,
      adapter: state.adapter,
      adapter_opts: state.adapter_opts,
      skill_registry: state.skill_registry,
      agent_supervisor: state.agent_supervisor,
      available_skills: state.available_skills,
      conversation_store: state.conversation_store,
      task_supervisor: state.task_supervisor,
      journal_base_dir: state.journal_base_dir,
      memory_store: state.memory_store,
      memory_repo: state.memory_repo,
      memory_scheduler: state.memory_scheduler,
      extraction_debouncer: state.extraction_debouncer,
      memory_agent_id: state.memory_agent_id,
      memory_owner_id: state.memory_owner_id,
      extraction_enabled: state.extraction_enabled,
      extraction_timeout_ms: state.extraction_timeout_ms,
      extraction_context_messages: state.extraction_context_messages,
      extraction_min_confidence: state.extraction_min_confidence,
      extraction_debounce_ms: state.extraction_debounce_ms,
      extraction_model: state.extraction_model,
      main_agent_server: self(),
      compaction_failures: state.compaction_failures
    }
  end

  defp format_conversation_key({channel, chat_id, :root}), do: "#{channel}/#{chat_id}"

  defp format_conversation_key({channel, chat_id, thread_scope}) do
    "#{channel}/#{chat_id}/#{inspect(thread_scope)}"
  end

  defp process_message(msg, state) do
    with_typing_indicator(msg, fn ->
      run_message_loop(msg, state)
    end)
  end

  defp run_message_loop(msg, state) do
    start = System.monotonic_time(:millisecond)
    conversation_key = conversation_key(msg)
    prompt_context = load_prompt_context!(state.memory_agent_id, state.available_skills)

    history = ConversationStore.get_history(conversation_key, server: state.conversation_store)
    user_message = %{role: "user", content: msg.content}
    messages = prompt_context.messages ++ history ++ [user_message]

    source_trust = source_trust_for_channel(msg.channel)

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
      prompt_accounting: prompt_context.accounting,
      source_channel: msg.channel,
      source_trust: source_trust
    }

    {loop_opts, compaction_target} =
      build_loop_runtime(state, messages, context, source_trust: source_trust)

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

        deliver_reply(msg, result.response)
        maybe_start_extraction(msg, history, result.response, state)
        maybe_auto_compact(conversation_key, state, compaction_target)

      {:error, reason} ->
        Logger.error("Agent loop failed: #{inspect(reason)}")

        :telemetry.execute(
          [:fermix, :agent, :message_error],
          %{count: 1},
          %{channel: msg.channel, chat_id: msg.chat_id, reason: reason}
        )

        deliver_reply(msg, "Sorry, I encountered an error processing your message.")
    end
  end

  defp with_typing_indicator(%{typing_fn: typing_fn} = msg, fun)
       when is_function(typing_fn, 0) and is_function(fun, 0) do
    pid =
      spawn_link(fn ->
        typing_loop(
          typing_fn,
          positive_integer(Map.get(msg, :typing_interval_ms), @typing_interval_ms),
          monotonic_ms() + positive_integer(Map.get(msg, :typing_timeout_ms), @typing_timeout_ms)
        )
      end)

    try do
      fun.()
    after
      stop_typing_loop(pid)
    end
  end

  defp with_typing_indicator(_msg, fun) when is_function(fun, 0), do: fun.()

  defp typing_loop(typing_fn, interval_ms, deadline_ms) do
    case emit_typing(typing_fn) do
      :ok ->
        wait_for_next_typing_tick(typing_fn, interval_ms, deadline_ms)

      {:error, _reason} ->
        :ok
    end
  end

  defp wait_for_next_typing_tick(typing_fn, interval_ms, deadline_ms) do
    now = monotonic_ms()

    if now >= deadline_ms do
      :ok
    else
      receive do
        :stop -> :ok
      after
        min(interval_ms, deadline_ms - now) ->
          typing_loop(typing_fn, interval_ms, deadline_ms)
      end
    end
  end

  defp emit_typing(typing_fn) do
    case typing_fn.() do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning("Typing indicator failed: #{inspect(reason)}")
        error

      other ->
        Logger.warning("Typing indicator returned unexpected result: #{inspect(other)}")
        {:error, other}
    end
  rescue
    error in [Req.TransportError] ->
      Logger.warning("Typing indicator transport failed: #{Exception.message(error)}")
      {:error, error}
  catch
    :exit, {:noproc, _details} = reason ->
      Logger.warning("Typing indicator adapter unavailable: #{inspect(reason)}")
      {:error, reason}

    :exit, :noproc ->
      Logger.warning("Typing indicator adapter unavailable: :noproc")
      {:error, :noproc}
  end

  defp stop_typing_loop(pid) when is_pid(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        :ok
    after
      100 ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          100 -> :ok
        end
    end
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

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

    case Compactor.compact(history,
           enabled: true,
           token_budget: budget,
           route: {route_key, adapter_opts},
           adapter: adapter,
           context: compaction_context(conversation_key, state)
         ) do
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
          %{before_tokens: before_tokens, after_tokens: after_tokens},
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

  defp prune_auto_compaction_failures(failures)
       when map_size(failures) <= @max_auto_compaction_failures do
    failures
  end

  defp prune_auto_compaction_failures(failures) do
    failures
    |> Enum.sort_by(fn {_conversation_key, failed_at} -> failed_at end, :desc)
    |> Enum.take(@max_auto_compaction_failures)
    |> Map.new()
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

  defp deliver_reply(msg, response) do
    case msg.reply_fn.(response) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.error("Main Agent reply delivery failed: #{inspect(reason)}")

        :telemetry.execute(
          [:fermix, :agent, :reply_error],
          %{count: 1},
          %{channel: msg.channel, chat_id: msg.chat_id, reason: reason}
        )

        error

      _other ->
        :ok
    end
  end

  defp load_prompt_context!(agent_id, available_skills)
       when is_binary(agent_id) and is_list(available_skills) do
    case PromptComposer.compose_with_metadata(
           agent_id: agent_id,
           available_skills: available_skills
         ) do
      {:ok, prompt_context} -> prompt_context
      {:error, reason} -> raise "prompt composition failed: #{inspect(reason)}"
    end
  end

  defp maybe_start_extraction(_msg, _history, _assistant_response, %{extraction_enabled: false}),
    do: :ok

  defp maybe_start_extraction(msg, history, assistant_response, state) do
    opts =
      [
        provider: state.provider,
        messages: extraction_messages(history, msg.content, assistant_response),
        agent_id: state.memory_agent_id,
        owner_id: state.memory_owner_id,
        conversation_key: conversation_key(msg),
        chat_mode: chat_mode(msg),
        memory_store: state.memory_store,
        scheduler: state.memory_scheduler,
        repo: state.memory_repo,
        extraction_timeout_ms: state.extraction_timeout_ms,
        extraction_context_messages: state.extraction_context_messages,
        extraction_min_confidence: state.extraction_min_confidence,
        extraction_debounce_ms: state.extraction_debounce_ms,
        extraction_model: state.extraction_model
      ]
      |> add_extraction_route(state)

    ExtractionDebouncer.request(opts, server: state.extraction_debouncer)
  end

  defp add_extraction_route(opts, %{adapter: adapter, adapter_opts: adapter_opts})
       when not is_nil(adapter) do
    opts
    |> Keyword.put(:adapter, adapter)
    |> Keyword.put(:adapter_opts, adapter_opts)
  end

  defp add_extraction_route(opts, state) do
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

  defp extraction_messages(history, user_content, assistant_content) do
    history
    |> Enum.map(fn message ->
      %{role: message.role, content: message.content}
    end)
    |> Kernel.++([
      %{role: "user", content: user_content},
      %{role: "assistant", content: assistant_content}
    ])
  end

  defp chat_mode(%{chat_mode: mode}) do
    normalize_chat_mode(mode)
  end

  defp chat_mode(%{metadata: metadata}) when is_map(metadata) do
    metadata_chat_mode(metadata)
  end

  defp chat_mode(_msg), do: :direct

  defp normalize_chat_mode(:direct), do: :direct
  defp normalize_chat_mode(:shared), do: :shared
  defp normalize_chat_mode("direct"), do: :direct
  defp normalize_chat_mode("shared"), do: :shared
  defp normalize_chat_mode(_mode), do: :direct

  defp metadata_chat_mode(metadata) do
    explicit_metadata_chat_mode(metadata) || inferred_metadata_chat_mode(metadata) || :direct
  end

  defp explicit_metadata_chat_mode(metadata) do
    case metadata_value(metadata, :chat_mode) do
      value when value in [:direct, "direct"] -> :direct
      value when value in [:shared, "shared"] -> :shared
      _other -> nil
    end
  end

  defp inferred_metadata_chat_mode(metadata) do
    cond do
      metadata_value(metadata, :chat_type) == "private" -> :direct
      metadata_value(metadata, :chat_type) in ["group", "supergroup", "channel"] -> :shared
      metadata_value(metadata, :channel_type) == "im" -> :direct
      metadata_value(metadata, :channel_type) in ["channel", "group", "mpim"] -> :shared
      not is_nil(metadata_value(metadata, :guild_id)) -> :shared
      not is_nil(metadata_value(metadata, :group_id)) -> :shared
      true -> nil
    end
  end

  defp metadata_value(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp load_available_skills(skill_registry) do
    case safe_skill_registry_call(fn -> SkillRegistry.list_detailed(skill_registry) end) do
      {:ok, skills} -> skills
      {:error, _reason} -> []
    end
  end

  defp reload_available_skills(skill_registry) do
    with {:ok, {:ok, names}} <-
           safe_skill_registry_call(fn -> SkillRegistry.reload(skill_registry) end),
         {:ok, skills} <-
           safe_skill_registry_call(fn -> SkillRegistry.list_detailed(skill_registry) end) do
      {:ok, names, skills}
    else
      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:skill_registry_unavailable, reason}}
    end
  end

  defp status_from_state(state) do
    counts = conversation_counts(state.conversations)
    activity = request_activity(counts)

    %{
      name: "main",
      health: :online,
      activity: activity,
      status: activity,
      pid: self(),
      active_conversations: counts.active_conversations,
      pending_conversations: counts.pending_conversations,
      active_requests: counts.active_requests,
      pending_requests: counts.pending_requests,
      available_skills: skill_names(state.available_skills),
      provider: Keyword.get(state.adapter_overrides, :provider) || provider_name(state.provider),
      model: Keyword.get(state.adapter_overrides, :model),
      memory: %{
        extraction_enabled: state.extraction_enabled,
        agent_id: state.memory_agent_id,
        owner_id: state.memory_owner_id
      }
    }
  end

  defp request_activity(%{active_requests: active_requests}) when active_requests > 0,
    do: :running

  defp request_activity(%{active_requests: active_requests}) when active_requests == 0, do: :idle

  defp conversation_counts(conversations) when is_map(conversations) do
    Enum.reduce(
      conversations,
      %{
        active_conversations: 0,
        pending_conversations: 0,
        active_requests: 0,
        pending_requests: 0
      },
      fn {_key, runtime}, counts ->
        active? = Map.get(runtime, :active) != nil
        pending? = Map.get(runtime, :pending) != nil

        counts
        |> increment_if(:active_conversations, active?)
        |> increment_if(:pending_conversations, pending?)
        |> increment_if(:active_requests, active?)
        |> increment_if(:pending_requests, pending?)
      end
    )
  end

  defp increment_if(counts, key, true), do: Map.update!(counts, key, &(&1 + 1))
  defp increment_if(counts, _key, false), do: counts

  defp skill_names(skills) when is_list(skills) do
    skills
    |> Enum.map(&Map.get(&1, :name))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp provider_name(FermixCore.Providers.OpenAI), do: :openai
  defp provider_name(FermixCore.Providers.OpenAI.Responses), do: :openai
  defp provider_name(FermixCore.Providers.OpenAI.ChatCompletions), do: :openai
  defp provider_name(FermixCore.Providers.OpenAI.Codex), do: :openai_codex
  defp provider_name(FermixCore.Providers.Anthropic.Messages), do: :anthropic

  defp provider_name(provider) when is_atom(provider) do
    case Atom.to_string(provider) do
      "Elixir." <> _module_name -> nil
      _provider_atom -> provider
    end
  end

  defp provider_name(_provider), do: nil

  defp safe_skill_registry_call(fun) do
    {:ok, fun.()}
  catch
    :exit, reason -> {:error, reason}
  end
end
