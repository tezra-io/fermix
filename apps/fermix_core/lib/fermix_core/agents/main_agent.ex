defmodule FermixCore.Agents.MainAgent do
  @moduledoc """
  Persistent Main Agent runtime holder.

  Owns the per-agent runtime-context cache (system prompt + capability surface),
  its invalidation, and conversation auto-compaction failure backoff. Channel
  messages no longer arrive here directly — the gateway (`FermixChannels.Gateway.Queue`)
  owns FIFO scheduling and calls `checkout_turn_state/2` to obtain a built
  turn-state snapshot, then runs the turn via `FermixCore.Agents.TurnRunner`.

  Keeping the cache here (rather than in the gateway) preserves the one-way
  dependency: core builds runtime context from skills, capabilities, and memory;
  the gateway never reconstructs core state. Invalidation is driven by core
  lifecycle events — skill reload (`reload_skills/1`) and memory-review writes
  (`invalidate_runtime_context/2`, called by the reviewer).

  Started by Application supervisor with :permanent restart.
  """

  use GenServer, restart: :permanent

  require Logger

  alias FermixCore.Agents.AgentSupervisor
  alias FermixCore.Agents.RuntimeContext
  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Memory.Config
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Reviewer
  alias FermixCore.Memory.Store
  alias FermixCore.Realtime.SessionSupervisor
  alias FermixCore.Reply
  alias FermixCore.Telemetry

  @max_auto_compaction_failures 512

  # GenServer.call timeout for checkout: a runtime-context cache miss builds the
  # context inline (skills + capabilities + memory). Bounded generously so a
  # cold first turn never times out, while still failing rather than hanging.
  @checkout_timeout_ms 30_000

  @type thread_scope :: :root | String.t() | integer()

  @type channel_message :: %{
          :content => String.t(),
          :sender => String.t(),
          :channel => String.t(),
          :chat_id => String.t(),
          :reply_fn => Reply.reply_fn(),
          optional(:typing_fn) => (-> any()),
          optional(:typing_interval_ms) => pos_integer(),
          optional(:typing_timeout_ms) => pos_integer(),
          optional(:thread_ts) => String.t() | integer() | nil,
          optional(:thread_scope) => thread_scope() | nil
        }

  @type status :: %{
          name: String.t(),
          health: :online,
          pid: pid(),
          available_skills: [String.t()],
          provider: atom() | nil,
          model: String.t() | nil,
          memory: %{
            review_interval_hours: non_neg_integer(),
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

  @doc """
  Ensure the runtime context is built (caching on miss) and return a turn-state
  snapshot for `FermixCore.Agents.TurnRunner.run/2` plus the cache status.
  """
  @spec checkout_turn_state(GenServer.server(), channel_message()) ::
          {:ok, map(), :hit | :miss} | {:error, term()}
  def checkout_turn_state(server \\ __MODULE__, msg) do
    GenServer.call(server, {:checkout_turn_state, msg}, @checkout_timeout_ms)
  end

  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @spec reload_skills(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def reload_skills(server \\ __MODULE__) do
    GenServer.call(server, :reload_skills)
  end

  @spec invalidate_runtime_context(GenServer.server(), atom()) :: :ok
  def invalidate_runtime_context(server \\ __MODULE__, reason \\ :external)
      when is_atom(reason) do
    GenServer.call(server, {:invalidate_runtime_context, reason})
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
      memory_reviewer: Keyword.get(opts, :memory_reviewer, Reviewer),
      memory_agent_id: Config.agent_id(opts),
      memory_owner_id: Config.owner_id(opts),
      extraction_timeout_ms: Config.extraction_timeout_ms(opts),
      review_interval_hours: Config.review_interval_hours(opts),
      review_max_messages: Config.review_max_messages(opts),
      review_input_token_budget: Config.review_input_token_budget(opts),
      review_failure_backoff_ms: Config.review_failure_backoff_ms(opts),
      runtime_context: nil,
      compaction_failures: %{}
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
  def handle_call({:checkout_turn_state, _msg}, _from, state) do
    case ensure_runtime_context(state) do
      {:ok, state, cache_status} ->
        {:reply, {:ok, turn_state(state), cache_status}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, status_from_state(state), state}
  end

  def handle_call(:reload_skills, _from, state) do
    case SkillRegistry.reload(state.skill_registry) do
      {:ok, summary} ->
        active_voice_session_count()
        |> log_stale_voice_sessions()

        next_state = %{
          state
          | available_skills: Map.get(summary, :skills, []),
            runtime_context: nil
        }

        {:reply, {:ok, summary}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:invalidate_runtime_context, _reason}, _from, state) do
    {:reply, :ok, %{state | runtime_context: nil}}
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
  def handle_cast({:clear_auto_compaction_failure, conversation_key}, state) do
    {:noreply, update_in(state.compaction_failures, &Map.delete(&1, conversation_key))}
  end

  # --- Internals ---

  # Snapshot of everything `TurnRunner.run/2` needs to execute a turn. Built
  # under the GenServer (so the runtime context is the freshly-cached one) and
  # handed to the gateway, which runs the turn in a supervised task.
  defp turn_state(state) do
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
      memory_reviewer: state.memory_reviewer,
      memory_agent_id: state.memory_agent_id,
      memory_owner_id: state.memory_owner_id,
      extraction_timeout_ms: state.extraction_timeout_ms,
      review_interval_hours: state.review_interval_hours,
      review_max_messages: state.review_max_messages,
      review_input_token_budget: state.review_input_token_budget,
      review_failure_backoff_ms: state.review_failure_backoff_ms,
      runtime_context: state.runtime_context,
      main_agent_server: self(),
      compaction_failures: state.compaction_failures
    }
  end

  defp ensure_runtime_context(state) do
    case state.runtime_context do
      %RuntimeContext{} = ctx ->
        {:ok, %{state | runtime_context: ctx}, :hit}

      nil ->
        case build_runtime_context(state) do
          {:ok, ctx} ->
            {:ok, %{state | runtime_context: ctx}, :miss}

          {:error, reason} ->
            Logger.error("runtime context build failed: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  defp build_runtime_context(state) do
    {result, duration_us} =
      Telemetry.timed_us(fn ->
        RuntimeContext.build(
          agent_id: state.memory_agent_id,
          available_skills: state.available_skills,
          capability_registry: state.capability_registry
        )
      end)

    case result do
      {:ok, ctx} ->
        emit_runtime_context_build(state, ctx, duration_us, :ok, nil)
        {:ok, ctx}

      {:error, reason} ->
        emit_runtime_context_build(state, nil, duration_us, :error, reason)
        {:error, reason}
    end
  end

  defp emit_runtime_context_build(state, ctx, duration_us, status, reason) do
    metadata = %{
      agent: state.memory_agent_id,
      status: status
    }

    metadata = if reason, do: Map.put(metadata, :reason, reason), else: metadata

    measurements = %{
      duration_us: duration_us,
      base_message_bytes: runtime_context_base_bytes(ctx)
    }

    :telemetry.execute([:fermix, :runtime_context, :build], measurements, metadata)
  end

  defp runtime_context_base_bytes(%RuntimeContext{base_messages: messages}),
    do: messages_bytes(messages)

  defp runtime_context_base_bytes(_other), do: 0

  defp messages_bytes(messages) do
    Enum.reduce(messages, 0, fn message, total ->
      total +
        byte_size(to_string(Map.get(message, :content) || Map.get(message, "content") || ""))
    end)
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

  defp load_available_skills(skill_registry) do
    case safe_skill_registry_call(fn -> SkillRegistry.list_detailed(skill_registry) end) do
      {:ok, skills} -> skills
      {:error, _reason} -> []
    end
  end

  defp active_voice_session_count do
    SessionSupervisor.active_sessions()
  catch
    :exit, reason ->
      Logger.debug(
        "Realtime session supervisor unavailable during skill reload: #{inspect(reason)}"
      )

      0
  end

  defp log_stale_voice_sessions(0), do: :ok

  defp log_stale_voice_sessions(count) when is_integer(count) and count > 0 do
    Logger.info(
      "skills reloaded; #{count} active realtime voice session(s) keep their existing skill snapshot until restarted"
    )
  end

  defp status_from_state(state) do
    %{
      name: "main",
      health: :online,
      pid: self(),
      available_skills: skill_names(state.available_skills),
      provider: Keyword.get(state.adapter_overrides, :provider) || provider_name(state.provider),
      model: Keyword.get(state.adapter_overrides, :model),
      memory: %{
        review_interval_hours: state.review_interval_hours,
        agent_id: state.memory_agent_id,
        owner_id: state.memory_owner_id
      }
    }
  end

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
