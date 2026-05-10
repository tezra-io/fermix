defmodule FermixCore.Memory.Compactor do
  @moduledoc """
  Token-aware prompt compaction with durable checkpoint summaries.

  Checkpoint resource revisions are audit history only. M4.6 runtime behavior does not
  read checkpoints from the resource registry or support checkpoint rollback.

  Over-budget compaction requires `route: {route_key, adapter_opts}`. There is no
  hardcoded provider fallback; orphaned callers without a route fail loudly.
  """

  require Logger

  alias FermixCore.Memory.Config
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Scope
  alias FermixCore.Providers.Adapter
  alias FermixCore.Resource.Registry

  @type message :: map()
  @type compact_result :: %{
          messages: [message()],
          compacted?: boolean(),
          cache: map() | nil
        }

  @spec compact([message()], keyword()) :: {:ok, compact_result()} | {:error, term()}
  def compact(messages, opts \\ []) when is_list(messages) and is_list(opts) do
    if Keyword.get(opts, :enabled, Config.compaction_enabled?(opts)) do
      do_compact(messages, opts)
    else
      {:ok, unchanged(messages)}
    end
  end

  @spec estimate_tokens(String.t() | [message()]) :: non_neg_integer()
  def estimate_tokens(text) when is_binary(text), do: count_tokens(text)

  def estimate_tokens(messages) when is_list(messages) do
    messages
    |> Enum.map_join("\n", &message_text/1)
    |> count_tokens()
  end

  defp do_compact(messages, opts) do
    budget = Keyword.get(opts, :token_budget, Config.compaction_token_budget(opts))

    if estimate_tokens(messages) <= budget do
      {:ok, unchanged(messages)}
    else
      compact_over_budget(messages, budget, opts)
    end
  end

  defp compact_over_budget(messages, budget, opts) do
    {protected, history} = split_protected(messages)
    protected = Enum.reject(protected, &checkpoint_summary_message?/1)
    history = Enum.reject(history, &checkpoint_summary_message?/1)
    {older, recent} = split_for_compaction(history, budget)

    if older == [] do
      {:ok, unchanged(messages)}
    else
      with {:ok, summary, cache} <- summary_for(older, budget, opts) do
        summary_message = checkpoint_message(summary)

        {:ok,
         %{
           messages: trim_recent_to_budget(protected, summary_message, recent, budget),
           compacted?: true,
           cache: cache
         }}
      end
    end
  end

  defp summary_for(older, budget, opts) do
    case Keyword.get(opts, :cache) do
      %{summary: summary} = cache when is_binary(summary) ->
        {:ok, summary, cache}

      _cache ->
        create_summary(older, budget, opts)
    end
  end

  defp create_summary(older, budget, opts) do
    prior = latest_checkpoint(opts)

    with {:ok, summary} <- call_summary_provider(older, prior, budget, opts) do
      # Persistence errors are logged and must not block the turn.
      _ = maybe_persist_checkpoint(summary, length(older), budget, opts)
      {:ok, summary, %{summary: summary}}
    end
  end

  defp call_summary_provider(older, prior, budget, opts) do
    {route_key, adapter_opts} = Keyword.fetch!(opts, :route)
    adapter = Keyword.get(opts, :adapter) || Adapter.for_route(route_key)

    case adapter.chat(summary_prompt(older, prior, budget), [], adapter_opts) do
      {:ok, %{content: content}} when is_binary(content) ->
        case String.trim(content) do
          "" -> {:error, {:compaction_failed, :empty_summary}}
          summary -> {:ok, summary}
        end

      {:error, reason} ->
        {:error, {:compaction_failed, reason}}

      other ->
        {:error, {:compaction_failed, other}}
    end
  end

  defp summary_prompt(older, nil, budget) do
    [
      summary_system_message(),
      %{role: "user", content: summary_user_content(older, nil, budget)}
    ]
  end

  defp summary_prompt(older, prior, budget) do
    [
      summary_system_message(),
      %{role: "user", content: summary_user_content(older, prior, budget)}
    ]
  end

  defp summary_system_message do
    %{
      role: "system",
      content:
        "Summarize older conversation context into one reusable checkpoint. " <>
          "Preserve decisions, unresolved questions, durable facts, and active context."
    }
  end

  defp summary_user_content(older, prior, budget) do
    [
      prior_checkpoint_block(prior),
      "Summary token budget: #{max(div(budget, 4), 64)}",
      "Older messages:",
      Enum.map_join(older, "\n\n", &render_message/1)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp prior_checkpoint_block(nil), do: nil
  defp prior_checkpoint_block(prior), do: "Prior checkpoint summary:\n#{prior}"

  defp split_protected(messages) do
    Enum.split_while(messages, fn message -> role(message) == "system" end)
  end

  defp split_for_compaction(history, budget) do
    target = max(div(budget, 2), 1)

    {recent, older, _tokens} =
      Enum.reduce(Enum.reverse(history), {[], [], 0}, fn message, {recent, older, tokens} ->
        message_tokens = estimate_tokens([message])

        cond do
          recent == [] ->
            {[message], older, tokens + message_tokens}

          tokens + message_tokens <= target ->
            {[message | recent], older, tokens + message_tokens}

          true ->
            {recent, [message | older], tokens}
        end
      end)

    {older, recent}
  end

  defp trim_recent_to_budget(protected, summary_message, recent, budget) do
    Enum.reduce_while(recent, recent, fn _message, current ->
      messages = protected ++ [summary_message] ++ current

      cond do
        estimate_tokens(messages) <= budget ->
          {:halt, current}

        length(current) <= 1 ->
          {:halt, current}

        true ->
          {:cont, tl(current)}
      end
    end)
    |> then(fn current -> protected ++ [summary_message] ++ current end)
  end

  defp checkpoint_message(summary) do
    %{role: "system", content: "Conversation checkpoint summary:\n#{summary}"}
  end

  defp checkpoint_summary_message?(message) do
    role(message) == "system" and
      String.starts_with?(content(message), "Conversation checkpoint summary:")
  end

  defp latest_checkpoint(opts) do
    with {:ok, repo} <- repo_server(Keyword.get(opts, :context, %{})),
         {:ok, selector} <- checkpoint_selector(opts),
         {:ok, [checkpoint]} <- Repo.get_messages(selector, server: repo, limit: 1) do
      checkpoint.content
    else
      _no_checkpoint -> nil
    end
  end

  defp maybe_persist_checkpoint(summary, message_count, budget, opts) do
    persist? =
      Keyword.get(opts, :persist_checkpoints, Config.checkpoint_persistence_enabled?(opts))

    if persist? do
      persist_checkpoint(summary, message_count, budget, opts)
    else
      :ok
    end
  end

  defp persist_checkpoint(summary, message_count, budget, opts) do
    context = Keyword.get(opts, :context, %{})

    with {:ok, repo} <- repo_server(context),
         {:ok, attrs} <- checkpoint_attrs(summary, context),
         {:ok, _row} <- Repo.insert_message(attrs, server: repo),
         {:ok, _revision} <-
           commit_checkpoint_revision(summary, message_count, budget, context, repo) do
      :ok
    else
      {:error, :missing_checkpoint_context} ->
        :ok

      {:error, :disabled} ->
        :ok

      {:error, reason} ->
        Logger.error("compaction checkpoint persistence failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp commit_checkpoint_revision(summary, message_count, budget, context, repo) do
    with {:ok, {agent_id, scope_id}} <- checkpoint_revision_selector(context) do
      Registry.commit(agent_id, "checkpoint", scope_id, summary,
        mutation_source: :compaction,
        provenance: checkpoint_provenance(message_count, budget),
        repo: repo
      )
    end
  end

  defp checkpoint_revision_selector(context) do
    case Map.get(context, :conversation_key) do
      {channel, chat_id, thread_scope} ->
        {:ok,
         {Map.get(context, :memory_agent_id, "main"),
          Scope.conversation_scope_id(channel, chat_id, thread_scope)}}

      _missing ->
        {:error, :missing_checkpoint_context}
    end
  end

  defp checkpoint_provenance(message_count, budget) do
    %{
      "trigger" => "compaction",
      "messages_summarized" => message_count,
      "token_budget" => budget,
      "description" => "Compacted #{message_count} messages into checkpoint summary"
    }
  end

  defp checkpoint_attrs(summary, context) do
    case Map.get(context, :conversation_key) do
      {channel, chat_id, thread_scope} ->
        {:ok,
         %{
           agent_id: Map.get(context, :memory_agent_id, "main"),
           owner_id: Map.get(context, :memory_owner_id, "default"),
           channel: channel,
           chat_id: chat_id,
           thread_scope: thread_scope,
           sender: "compactor",
           role: "system",
           kind: "checkpoint_summary",
           content: summary,
           metadata: %{source: "agent_loop_compaction"}
         }}

      _missing ->
        {:error, :missing_checkpoint_context}
    end
  end

  defp checkpoint_selector(opts) do
    context = Keyword.get(opts, :context, %{})

    case Map.get(context, :conversation_key) do
      {channel, chat_id, thread_scope} ->
        {:ok,
         %{
           agent_id: Map.get(context, :memory_agent_id, "main"),
           channel: channel,
           chat_id: chat_id,
           thread_scope: thread_scope,
           kind: "checkpoint_summary"
         }}

      _missing ->
        {:error, :missing_checkpoint_context}
    end
  end

  defp repo_server(%{memory_repo: repo}) when is_pid(repo) or is_atom(repo) do
    case Repo.enabled_server(repo) do
      nil -> {:error, :disabled}
      server -> {:ok, server}
    end
  end

  defp repo_server(_context), do: {:error, :missing_checkpoint_context}

  defp render_message(message) do
    "[#{role(message)}] #{content(message)}"
  end

  defp message_text(message) do
    "#{role(message)}: #{content(message)}"
  end

  defp role(message), do: Map.get(message, :role) || Map.get(message, "role") || "unknown"
  defp content(message), do: Map.get(message, :content) || Map.get(message, "content") || ""

  defp count_tokens(text) do
    nif_module = Module.concat([:FermixNif])

    cond do
      Code.ensure_loaded?(nif_module) && function_exported?(nif_module, :count_tokens, 1) ->
        normalize_token_count(apply(nif_module, :count_tokens, [text]), text)

      Code.ensure_loaded?(nif_module) && function_exported?(nif_module, :estimate_tokens, 1) ->
        normalize_token_count(apply(nif_module, :estimate_tokens, [text]), text)

      true ->
        fallback_token_count(text)
    end
  end

  defp normalize_token_count(count, _text) when is_integer(count) and count >= 0, do: count
  defp normalize_token_count({:ok, count}, _text) when is_integer(count) and count >= 0, do: count
  defp normalize_token_count(_bad_count, text), do: fallback_token_count(text)

  defp fallback_token_count(text), do: div(byte_size(text) + 3, 4)

  defp unchanged(messages), do: %{messages: messages, compacted?: false, cache: nil}
end
