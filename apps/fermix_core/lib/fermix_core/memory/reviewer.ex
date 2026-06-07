defmodule FermixCore.Memory.Reviewer do
  @moduledoc """
  Time-gated background reviewer that consolidates durable memory rows.
  """

  require Logger

  alias FermixCore.Agents.MainAgent
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Memory.Admission
  alias FermixCore.Memory.Config
  alias FermixCore.Memory.PromptFiles
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.ReviewTools
  alias FermixCore.Providers.Adapter
  alias FermixCore.Providers.Failover
  alias FermixCore.Providers.Selection

  @nothing_to_save "Nothing to save."

  @spec start_background(keyword()) :: :ok | {:error, term()}
  def start_background(opts) when is_list(opts) do
    ctx = review_context(opts)

    case eligible?(ctx, false) do
      {:ok, selector, state, preview} -> start_task(ctx, selector, state, preview)
      {:skip, reason} -> emit_skip(ctx, reason)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec review_now(keyword()) :: {:ok, map()} | {:skip, atom()} | {:error, term()}
  def review_now(opts) when is_list(opts) do
    ctx = review_context(opts)

    case eligible?(ctx, true) do
      {:ok, selector, state, preview} -> run_claimed_review(ctx, selector, state, preview)
      {:skip, reason} -> {:skip, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec review_all_now(keyword()) :: {:ok, map()} | {:error, term()}
  def review_all_now(opts) when is_list(opts) do
    ctx = review_context(opts)

    case Repo.list_review_conversations(review_conversation_filter(ctx), server: ctx.repo) do
      {:ok, selectors} -> run_all(selectors, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp review_context(opts) do
    %{
      provider: Keyword.get(opts, :provider),
      adapter: Keyword.get(opts, :adapter),
      adapter_opts: Keyword.get(opts, :adapter_opts, []),
      route_key: Keyword.get(opts, :route_key),
      routes: Keyword.get(opts, :routes),
      repo: Keyword.get(opts, :repo, Config.repo_server(opts)),
      task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
      prompt_files: Keyword.get(opts, :prompt_files, PromptFiles),
      review_tools: Keyword.get(opts, :review_tools, ReviewTools),
      main_agent_server: Keyword.get(opts, :main_agent_server),
      agent_id: Keyword.get(opts, :agent_id, Config.agent_id(opts)),
      owner_id: Keyword.get(opts, :owner_id, Config.owner_id(opts)),
      conversation_key: Keyword.get(opts, :conversation_key),
      source_trust: Keyword.get(opts, :source_trust),
      memory_enabled?: Config.enabled?(opts),
      interval_hours: Config.review_interval_hours(opts),
      max_messages: Config.review_max_messages(opts),
      input_token_budget: Config.review_input_token_budget(opts),
      failure_backoff_ms: Config.review_failure_backoff_ms(opts),
      user_char_cap: Config.prompt_user_token_cap(opts) * 4,
      memory_char_cap: Config.prompt_memory_token_cap(opts) * 4,
      timeout_ms: Config.extraction_timeout_ms(opts)
    }
  end

  defp eligible?(%{conversation_key: nil}, _force?), do: {:error, :missing_conversation_key}

  defp eligible?(%{memory_enabled?: false}, _force?), do: {:skip, :disabled}

  defp eligible?(%{interval_hours: 0}, false), do: {:skip, :disabled}

  defp eligible?(ctx, force?) do
    selector = review_selector(ctx)
    now = DateTime.utc_now()

    with {:ok, state} <- review_state(ctx.repo, selector),
         :ok <- interval_gate(state, ctx, now, force?),
         :ok <- failure_gate(state, ctx, now, force?),
         {:ok, [preview | _]} <- new_messages(ctx.repo, selector, state, 1),
         {:ok, _claimed} <-
           Repo.claim_memory_review(selector, now, max(ctx.failure_backoff_ms, ctx.timeout_ms),
             server: ctx.repo
           ) do
      {:ok, selector, state, preview}
    else
      {:ok, []} -> {:skip, :no_new_messages}
      {:error, :concurrent_run} -> {:skip, :concurrent_run}
      {:skip, reason} -> {:skip, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp review_state(repo, selector) do
    case Repo.get_memory_review_state(selector, server: repo) do
      {:ok, state} -> {:ok, state}
      {:error, :not_found} -> {:ok, default_state()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_state do
    %{
      last_reviewed_message_id: nil,
      last_reviewed_at: nil,
      last_review_failed_at: nil
    }
  end

  defp interval_gate(_state, _ctx, _now, true), do: :ok
  defp interval_gate(%{last_reviewed_at: nil}, _ctx, _now, false), do: :ok

  defp interval_gate(state, ctx, now, false) do
    elapsed_hours = DateTime.diff(now, state.last_reviewed_at, :hour)

    if elapsed_hours >= ctx.interval_hours do
      :ok
    else
      {:skip, :under_interval}
    end
  end

  defp failure_gate(_state, _ctx, _now, true), do: :ok
  defp failure_gate(%{last_review_failed_at: nil}, _ctx, _now, false), do: :ok

  defp failure_gate(state, ctx, now, false) do
    elapsed_ms = DateTime.diff(now, state.last_review_failed_at, :millisecond)

    if elapsed_ms >= ctx.failure_backoff_ms do
      :ok
    else
      {:skip, :in_failure_backoff}
    end
  end

  defp start_task(ctx, selector, state, preview) do
    parent = self()

    case Task.Supervisor.start_child(ctx.task_supervisor, fn ->
           result = run_claimed_review(ctx, selector, state, preview)
           send(parent, {:memory_review_result, selector, result})
         end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_claimed_review(ctx, selector, state, preview) do
    started = System.monotonic_time(:microsecond)

    result =
      with {:ok, input} <- build_input(ctx, selector, state, preview),
           {:ok, operations} <- call_reviewer(ctx, input),
           {:ok, stats} <- apply_operations(ctx, operations),
           {:ok, status} <- finish_review(ctx, selector, input, stats) do
        {:ok, review_result(status, stats, input)}
      end

    emit_review(ctx, selector, result, started)
    record_review_completion(ctx, selector, result)
  end

  defp build_input(ctx, selector, state, _preview) do
    with {:ok, messages} when messages != [] <-
           new_messages(ctx.repo, selector, state, ctx.max_messages),
         packed <- pack_messages(messages, ctx.input_token_budget),
         {:ok, entries} <- current_entries(ctx) do
      {:ok,
       %{
         messages: packed.messages,
         input_tokens: packed.input_tokens,
         max_message_id: packed.max_message_id,
         entries: entries,
         prompt: reviewer_prompt(ctx, entries, packed.messages)
       }}
    else
      {:ok, []} -> {:error, :no_new_messages}
      {:error, reason} -> {:error, reason}
    end
  end

  defp new_messages(repo, selector, state, limit) do
    Repo.get_user_messages_after(selector, state.last_reviewed_message_id || 0, limit,
      server: repo
    )
  end

  defp pack_messages(messages, token_budget) do
    budget_bytes = token_budget * 4

    messages
    |> Enum.uniq_by(& &1.id)
    |> Enum.reduce_while(%{messages: [], bytes: 0, max_message_id: nil}, fn message, acc ->
      line = "message_id=#{message.id}: #{message.content}"
      line_bytes = byte_size(line)

      cond do
        acc.bytes + line_bytes <= budget_bytes ->
          {:cont, append_packed(acc, message, line, line_bytes)}

        acc.messages == [] ->
          truncated = truncate_to_valid_utf8(line, budget_bytes)
          {:halt, append_packed(acc, message, truncated, byte_size(truncated))}

        true ->
          {:halt, acc}
      end
    end)
    |> Map.update!(:messages, &Enum.reverse/1)
    |> Map.put_new(:input_tokens, 0)
    |> then(&Map.put(&1, :input_tokens, div(&1.bytes + 3, 4)))
  end

  # Byte-budget truncation must not split a multi-byte UTF-8 codepoint, or
  # the resulting binary fails JSON encoding in the provider request. Trim
  # trailing partial bytes back to a valid boundary (≤3 bytes for UTF-8).
  defp truncate_to_valid_utf8(binary, max_bytes) when byte_size(binary) <= max_bytes, do: binary

  defp truncate_to_valid_utf8(binary, max_bytes) do
    binary
    |> binary_part(0, max_bytes)
    |> drop_trailing_partial()
  end

  defp drop_trailing_partial(binary) do
    if String.valid?(binary) do
      binary
    else
      drop_trailing_partial(binary_part(binary, 0, byte_size(binary) - 1))
    end
  end

  defp append_packed(acc, message, line, line_bytes) do
    %{
      acc
      | messages: [%{id: message.id, content: line} | acc.messages],
        bytes: acc.bytes + line_bytes,
        max_message_id: message.id
    }
  end

  defp current_entries(ctx) do
    case Repo.get_memories(
           %{agent_id: ctx.agent_id, owner_id: ctx.owner_id, archived?: false},
           server: ctx.repo
         ) do
      {:ok, rows} -> {:ok, build_entry_summary(rows, ctx)}
      {:error, :disabled} -> {:ok, empty_entry_summary(ctx)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prompt_entry?(row), do: Admission.prompt_target(row) in ["user_md", "memory_md"]

  defp empty_entry_summary(ctx) do
    %{
      user: %{lines: [], used: 0, cap: ctx.user_char_cap},
      memory: %{lines: [], used: 0, cap: ctx.memory_char_cap}
    }
  end

  defp build_entry_summary(rows, ctx) do
    entries =
      rows
      |> Enum.filter(&prompt_entry?/1)
      |> Enum.map(&entry_data/1)

    %{
      user: bucket_summary(entries, "user", ctx.user_char_cap),
      memory: bucket_summary(entries, "memory", ctx.memory_char_cap)
    }
  end

  defp bucket_summary(entries, bucket, cap) do
    bucket_entries = Enum.filter(entries, &(&1.bucket == bucket))

    %{
      lines: Enum.map(bucket_entries, & &1.line),
      used: Enum.reduce(bucket_entries, 0, &(&1.chars + &2)),
      cap: cap
    }
  end

  defp entry_data(row) do
    bucket = if Admission.prompt_target(row) == "user_md", do: "user", else: "memory"

    %{
      bucket: bucket,
      chars: byte_size(row.value),
      line:
        "(id=#{row.id}, #{bucket}, scope=#{row.scope_type}:#{row.scope_id}, #{row.category}) " <>
          "#{row.key}: #{inspect(row.value)}"
    }
  end

  defp reviewer_prompt(ctx, entries, messages) do
    [
      %{role: "system", content: system_prompt(ctx)},
      %{
        role: "user",
        content: """
        Current memory:
        <user_md used="#{entries.user.used}/#{entries.user.cap} chars">
        #{Enum.join(entries.user.lines, "\n")}
        </user_md>
        <memory_md used="#{entries.memory.used}/#{entries.memory.cap} chars">
        #{Enum.join(entries.memory.lines, "\n")}
        </memory_md>

        New conversation excerpts since the last review:
        #{Enum.map_join(messages, "\n", & &1.content)}
        """
      }
    ]
  end

  defp system_prompt(ctx) do
    """
    You maintain #{ctx.agent_id}'s long-term memory from recent conversation excerpts.
    Use only durable, reusable facts. Do not save secrets or transient task details.
    Evolve memory instead of accumulating duplicates.

    Return either "#{@nothing_to_save}" or strict JSON:
    {"operations":[{"action":"add","target":"user|memory","category":"...","value":"..."},
    {"action":"replace","id":123,"value":"..."},{"action":"archive","id":123,"reason":"..."}]}

    add target=user categories: identity, preference, goal.
    add target=memory categories: project, environment, instruction.
    replace/archive must use ids from Current memory.
    """
  end

  defp call_reviewer(ctx, input) do
    with {:ok, turn} <- provider_turn(ctx, input.prompt) do
      parse_operations(turn)
    end
  end

  defp provider_turn(%{adapter: adapter} = ctx, messages) when not is_nil(adapter) do
    case adapter.chat(messages, review_capabilities(), adapter_opts(ctx)) do
      {:ok, turn} -> {:ok, turn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp provider_turn(%{route_key: route_key} = ctx, messages) when not is_nil(route_key) do
    provider_turn(%{ctx | adapter: Adapter.for_route(route_key)}, messages)
  end

  # The turn runner threads the turn's ordered route chain; review is a
  # single call with no provider state, so failover can cover it whole (§7).
  # Matched BEFORE the legacy provider clause: the turn runner passes both
  # (`provider:` is its always-present module default), and the chain wins.
  defp provider_turn(%{routes: [_ | _] = routes} = ctx, messages) do
    run_route_chain(routes, ctx, messages)
  end

  defp provider_turn(%{provider: provider} = ctx, messages) when not is_nil(provider) do
    case provider.chat(messages, provider_opts(ctx)) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  # Voice and CLI entry points pass neither an adapter nor an explicit
  # provider; resolve the configured primary/fallback chain here (lazily, so
  # a misconfiguration surfaces as a handled review failure rather than
  # crashing the caller) instead of hardcoding a provider.
  defp provider_turn(ctx, messages) do
    case Selection.ordered_routes() do
      {:ok, routes} -> run_route_chain(routes, ctx, messages)
      {:error, reason} -> {:error, {:route_resolution_failed, reason}}
    end
  end

  defp run_route_chain(routes, ctx, messages) do
    attempt = fn {route_key, route_opts} ->
      # Route opts may carry a pre-bound :adapter (the same seam as
      # AgentLoop.bind_route); it is never re-resolved via for_route.
      {adapter, route_opts} = Keyword.pop(route_opts, :adapter)

      attempt_ctx = %{
        ctx
        | adapter: adapter || Adapter.for_route(route_key),
          adapter_opts: Keyword.merge(route_opts, ctx.adapter_opts)
      }

      provider_turn(attempt_ctx, messages)
    end

    Failover.run_chain(routes, attempt,
      telemetry: %{agent: "memory_reviewer", surface: :memory_review}
    )
  end

  defp provider_opts(ctx) do
    [
      temperature: 0.1,
      tools: chat_tools(),
      req_options: [receive_timeout: ctx.timeout_ms]
    ]
  end

  defp adapter_opts(ctx) do
    ctx.adapter_opts
    |> Keyword.put_new(:temperature, 0.1)
    |> Keyword.put(:req_options, req_options(ctx))
  end

  defp req_options(ctx) do
    ctx.adapter_opts
    |> Keyword.get(:req_options, [])
    |> Keyword.put(:receive_timeout, ctx.timeout_ms)
  end

  defp parse_operations(%{tool_calls: calls}) when is_list(calls) and calls != [] do
    calls
    |> Enum.map(&tool_operation/1)
    |> normalize_operations()
  end

  defp parse_operations(%{content: content}) when is_binary(content) do
    content
    |> String.trim()
    |> parse_content_operations()
  end

  defp parse_content_operations(@nothing_to_save), do: {:ok, []}

  defp parse_content_operations(content) do
    case Jason.decode(content) do
      {:ok, %{"operations" => operations}} -> normalize_operations(operations)
      {:ok, operations} when is_list(operations) -> normalize_operations(operations)
      {:error, reason} -> {:error, {:invalid_review_json, reason}}
      {:ok, _other} -> {:error, :invalid_review_payload}
    end
  end

  defp normalize_operations(operations) when is_list(operations), do: {:ok, operations}
  defp normalize_operations(_operations), do: {:error, :invalid_review_payload}

  defp tool_operation(%{name: name, arguments: args}), do: tool_operation(name, args)

  defp tool_operation(%{"function" => %{"name" => name, "arguments" => args}}),
    do: tool_operation(name, args)

  # A tool_call in an unexpected shape becomes a skippable op rather than
  # crashing the background review with no failure state recorded.
  defp tool_operation(other), do: %{"action" => "__unparseable__", "raw" => inspect(other)}

  defp tool_operation(name, args) do
    args
    |> decode_tool_args()
    |> Map.put("action", tool_action(name))
  end

  defp decode_tool_args(args) when is_map(args), do: args

  defp decode_tool_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _invalid -> %{}
    end
  end

  defp tool_action("memory_review_add"), do: "add"
  defp tool_action("memory_review_replace"), do: "replace"
  defp tool_action("memory_review_archive"), do: "archive"
  defp tool_action(name), do: name

  defp apply_operations(_ctx, []),
    do: {:ok, %{added: 0, replaced: 0, archived: 0, skipped: 0, memory_ids: []}}

  defp apply_operations(ctx, operations) do
    ctx.review_tools.apply_operations(operations, %{
      agent_id: ctx.agent_id,
      owner_id: ctx.owner_id,
      repo: ctx.repo,
      source_trust: ctx.source_trust
    })
  end

  defp finish_review(ctx, selector, input, stats) do
    if changed?(stats) do
      with {:ok, _rendered} <- rebuild_prompt_files(ctx, stats),
           :ok <- invalidate_runtime_context(ctx),
           {:ok, _state} <-
             Repo.complete_memory_review(selector, :ok, input.max_message_id, DateTime.utc_now(),
               server: ctx.repo
             ) do
        {:ok, :ok}
      end
    else
      with {:ok, _state} <-
             Repo.complete_memory_review(
               selector,
               :nothing_to_save,
               input.max_message_id,
               DateTime.utc_now(),
               server: ctx.repo
             ) do
        {:ok, :nothing_to_save}
      end
    end
  end

  defp changed?(stats), do: stats.added + stats.replaced + stats.archived > 0

  defp rebuild_prompt_files(ctx, stats) do
    ctx.prompt_files.rebuild(ctx.agent_id, ctx.owner_id, :event,
      provenance: %{
        trigger: "memory_review",
        memory_ids: Enum.reverse(stats.memory_ids),
        description: "Prompt file rebuild triggered by memory review"
      }
    )
  end

  defp invalidate_runtime_context(%{main_agent_server: nil}), do: :ok

  defp invalidate_runtime_context(ctx) do
    case MainAgent.invalidate_runtime_context(ctx.main_agent_server, :memory_review) do
      :ok ->
        :telemetry.execute(
          [:fermix, :memory, :runtime_context_invalidated],
          %{count: 1},
          %{agent: ctx.agent_id, owner: ctx.owner_id, trigger: :memory_review}
        )

      result ->
        result
    end
  end

  defp record_review_completion(_ctx, _selector, {:ok, result}), do: {:ok, result}

  defp record_review_completion(ctx, selector, {:error, reason}) do
    Logger.warning("memory review failed: #{inspect(reason)}")

    case Repo.fail_memory_review(selector, DateTime.utc_now(), server: ctx.repo) do
      {:ok, _state} ->
        :ok

      {:error, persist_error} ->
        Logger.error("could not persist memory review failure state: #{inspect(persist_error)}")
    end

    {:error, reason}
  end

  defp review_result(status, stats, input) do
    %{
      status: status,
      ops_added: stats.added,
      ops_replaced: stats.replaced,
      ops_archived: stats.archived,
      ops_skipped: stats.skipped,
      input_messages: length(input.messages),
      input_tokens: input.input_tokens
    }
  end

  defp emit_review(ctx, selector, result, started) do
    duration_us = System.monotonic_time(:microsecond) - started
    metadata = review_metadata(ctx, selector, result)
    measurements = review_measurements(result, duration_us)

    :telemetry.execute([:fermix, :memory, :review], measurements, metadata)
  end

  defp review_metadata(ctx, selector, {:ok, result}) do
    %{
      agent: ctx.agent_id,
      owner: ctx.owner_id,
      conversation_key: conversation_key_string(selector),
      interval_hours: ctx.interval_hours,
      fired: true,
      status: result.status
    }
  end

  defp review_metadata(ctx, selector, {:error, reason}) do
    %{
      agent: ctx.agent_id,
      owner: ctx.owner_id,
      conversation_key: conversation_key_string(selector),
      interval_hours: ctx.interval_hours,
      fired: true,
      status: :failed,
      reason: reason
    }
  end

  defp review_measurements({:ok, result}, duration_us) do
    %{
      duration_us: duration_us,
      ops_added: result.ops_added,
      ops_replaced: result.ops_replaced,
      ops_archived: result.ops_archived,
      ops_skipped: result.ops_skipped,
      input_messages: result.input_messages,
      input_tokens: result.input_tokens
    }
  end

  defp review_measurements({:error, _reason}, duration_us) do
    %{
      duration_us: duration_us,
      ops_added: 0,
      ops_replaced: 0,
      ops_archived: 0,
      ops_skipped: 0,
      input_messages: 0,
      input_tokens: 0
    }
  end

  defp emit_skip(ctx, reason) do
    :telemetry.execute(
      [:fermix, :memory, :review_skipped],
      %{count: 1},
      %{reason: reason, agent: ctx.agent_id, owner: ctx.owner_id}
    )

    :ok
  end

  defp review_selector(ctx) do
    {channel, chat_id, thread_scope} = normalize_conversation_key(ctx.conversation_key)

    %{
      agent_id: ctx.agent_id,
      owner_id: ctx.owner_id,
      channel: channel,
      chat_id: chat_id,
      thread_scope: thread_scope
    }
  end

  defp normalize_conversation_key({channel, chat_id})
       when is_binary(channel) and is_binary(chat_id) do
    {channel, chat_id, :root}
  end

  defp normalize_conversation_key({channel, chat_id, thread_scope})
       when is_binary(channel) and is_binary(chat_id) do
    {channel, chat_id, thread_scope}
  end

  defp review_conversation_filter(ctx) do
    %{}
    |> maybe_put(:agent_id, ctx.agent_id)
    |> maybe_put(:owner_id, ctx.owner_id)
    |> maybe_merge_conversation(ctx.conversation_key)
  end

  defp maybe_merge_conversation(filter, nil), do: filter

  defp maybe_merge_conversation(filter, conversation_key) do
    {channel, chat_id, thread_scope} = normalize_conversation_key(conversation_key)

    filter
    |> Map.put(:channel, channel)
    |> Map.put(:chat_id, chat_id)
    |> Map.put(:thread_scope, thread_scope)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp conversation_key_string(selector) do
    "#{selector.channel}:#{selector.chat_id}:#{selector.thread_scope}"
  end

  defp run_all(selectors, opts) do
    results =
      Enum.map(selectors, fn selector ->
        opts
        |> Keyword.put(
          :conversation_key,
          {selector.channel, selector.chat_id, selector.thread_scope}
        )
        |> Keyword.put(:agent_id, selector.agent_id)
        |> Keyword.put(:owner_id, selector.owner_id)
        |> review_now()
      end)

    {:ok, %{total: length(results), results: results}}
  end

  defp review_capabilities do
    [
      review_capability("memory_review_add", add_parameters()),
      review_capability("memory_review_replace", replace_parameters()),
      review_capability("memory_review_archive", archive_parameters())
    ]
  end

  defp review_capability(name, parameters) do
    Capability.new(%{
      name: name,
      description: "Internal memory review operation.",
      parameters: parameters,
      kind: :builtin,
      executor: {__MODULE__, :noop, []},
      policy_class: :read_write,
      metadata: %{category: :memory, hidden_from_agent?: true}
    })
  end

  defp add_parameters do
    %{
      type: "object",
      required: ["target", "category", "value"],
      properties: %{
        target: %{type: "string", enum: ["user", "memory"]},
        category: %{type: "string"},
        value: %{type: "string"}
      }
    }
  end

  defp replace_parameters do
    %{
      type: "object",
      required: ["id", "value"],
      properties: %{id: %{type: "integer"}, value: %{type: "string"}}
    }
  end

  defp archive_parameters do
    %{
      type: "object",
      required: ["id", "reason"],
      properties: %{id: %{type: "integer"}, reason: %{type: "string"}}
    }
  end

  defp chat_tools do
    Enum.map(review_capabilities(), fn capability ->
      %{
        type: "function",
        function: %{
          name: capability.name,
          description: capability.description,
          parameters: capability.parameters
        }
      }
    end)
  end

  def noop(_args, _ctx), do: {:error, :internal_only}
end
