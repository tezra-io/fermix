defmodule FermixCore.Memory.Search do
  @moduledoc """
  Unified FTS5-backed lexical search over durable memories and message history.
  """

  alias FermixCore.Memory.Config
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Scope

  @type source :: :memories | :messages | :all
  @type scope :: :current_conversation | :owner | :all
  @type thread_scope :: :root | String.t() | integer()
  @type conversation_key :: {String.t(), String.t()} | {String.t(), String.t(), thread_scope()}

  @spec query(String.t(), keyword()) :: [map()]
  def query(search_term, opts \\ []) when is_binary(search_term) and is_list(opts) do
    search_term
    |> String.trim()
    |> do_query(opts)
  end

  defp do_query("", _opts), do: []

  defp do_query(search_term, opts) do
    ctx = %{
      repo: Keyword.get(opts, :repo, Repo),
      source: normalize_source!(Keyword.get(opts, :source, :all)),
      scope: normalize_scope!(Keyword.get(opts, :scope, :all)),
      limit: normalize_limit!(Keyword.get(opts, :limit, 10)),
      agent_id: Keyword.get(opts, :agent_id, Config.agent_id()),
      owner_id: Keyword.get(opts, :owner_id, Config.owner_id()),
      conversation_key: Keyword.get(opts, :conversation_key)
    }

    search_results(search_term, ctx)
    |> Enum.sort_by(&sort_key/1)
    |> Enum.take(ctx.limit)
  end

  defp search_results(search_term, %{source: :memories} = ctx),
    do: search_memory_results(search_term, ctx)

  defp search_results(search_term, %{source: :messages} = ctx),
    do: search_message_results(search_term, ctx)

  defp search_results(search_term, %{source: :all} = ctx) do
    search_memory_results(search_term, ctx) ++ search_message_results(search_term, ctx)
  end

  defp search_memory_results(search_term, ctx) do
    search_memories(
      search_term,
      ctx.scope,
      ctx.limit,
      ctx.repo,
      ctx.agent_id,
      ctx.owner_id,
      ctx.conversation_key
    )
    |> Enum.map(&Map.put(&1, :source, :memories))
  end

  defp search_message_results(search_term, ctx) do
    search_messages(
      search_term,
      ctx.scope,
      ctx.limit,
      ctx.repo,
      ctx.agent_id,
      ctx.owner_id,
      ctx.conversation_key
    )
    |> Enum.map(&Map.put(&1, :source, :messages))
  end

  defp search_memories(
         search_term,
         :current_conversation,
         limit,
         repo,
         agent_id,
         owner_id,
         {channel, chat_id}
       ) do
    legacy_selector = %{
      agent_id: agent_id,
      owner_id: owner_id,
      scope_type: "conversation",
      scope_id: "legacy:#{channel}:#{chat_id}"
    }

    case repo_search_memories(repo, search_term, legacy_selector, limit) do
      [] ->
        repo_search_memories(
          repo,
          search_term,
          %{
            agent_id: agent_id,
            owner_id: owner_id,
            scope_type: "conversation",
            scope_id: Scope.conversation_scope_id(channel, chat_id, :root)
          },
          limit
        )

      results ->
        results
    end
  end

  defp search_memories(
         search_term,
         :current_conversation,
         limit,
         repo,
         agent_id,
         owner_id,
         {channel, chat_id, thread_scope}
       ) do
    repo_search_memories(
      repo,
      search_term,
      %{
        agent_id: agent_id,
        owner_id: owner_id,
        scope_type: "conversation",
        scope_id: Scope.conversation_scope_id(channel, chat_id, thread_scope)
      },
      limit
    )
  end

  defp search_memories(
         _search_term,
         :current_conversation,
         _limit,
         _repo,
         _agent_id,
         _owner_id,
         nil
       ) do
    raise ArgumentError, "conversation_key is required for current_conversation search scope"
  end

  defp search_memories(search_term, :owner, limit, repo, agent_id, owner_id, _conversation_key) do
    repo_search_memories(
      repo,
      search_term,
      %{agent_id: agent_id, owner_id: owner_id, scope_type: "owner", scope_id: owner_id},
      limit
    )
  end

  defp search_memories(search_term, :all, limit, repo, agent_id, _owner_id, _conversation_key) do
    repo_search_memories(repo, search_term, %{agent_id: agent_id}, limit)
  end

  defp search_messages(
         search_term,
         :current_conversation,
         limit,
         repo,
         agent_id,
         owner_id,
         {channel, chat_id}
       ) do
    repo_search_messages(
      repo,
      search_term,
      %{
        agent_id: agent_id,
        owner_id: owner_id,
        channel: channel,
        chat_id: chat_id,
        thread_scope: "root"
      },
      limit
    )
  end

  defp search_messages(
         search_term,
         :current_conversation,
         limit,
         repo,
         agent_id,
         owner_id,
         {channel, chat_id, thread_scope}
       ) do
    repo_search_messages(
      repo,
      search_term,
      %{
        agent_id: agent_id,
        owner_id: owner_id,
        channel: channel,
        chat_id: chat_id,
        thread_scope: Scope.normalize_thread_scope(thread_scope)
      },
      limit
    )
  end

  defp search_messages(
         _search_term,
         :current_conversation,
         _limit,
         _repo,
         _agent_id,
         _owner_id,
         nil
       ) do
    raise ArgumentError, "conversation_key is required for current_conversation search scope"
  end

  defp search_messages(search_term, :owner, limit, repo, agent_id, owner_id, _conversation_key) do
    repo_search_messages(repo, search_term, %{agent_id: agent_id, owner_id: owner_id}, limit)
  end

  defp search_messages(search_term, :all, limit, repo, agent_id, _owner_id, _conversation_key) do
    repo_search_messages(repo, search_term, %{agent_id: agent_id}, limit)
  end

  defp repo_search_memories(repo, search_term, selector, limit) do
    case Repo.search_memories(search_term, selector: selector, limit: limit, server: repo) do
      {:ok, results} -> results
      {:error, :disabled} -> []
      {:error, reason} -> raise "memory search failed: #{inspect(reason)}"
    end
  end

  defp repo_search_messages(repo, search_term, selector, limit) do
    case Repo.search_messages(search_term, selector: selector, limit: limit, server: repo) do
      {:ok, results} -> results
      {:error, :disabled} -> []
      {:error, reason} -> raise "message search failed: #{inspect(reason)}"
    end
  end

  defp sort_key(%{rank: rank, updated_at: updated_at, id: id}),
    do: {rank, -updated_at_microseconds(updated_at), -id}

  defp sort_key(%{rank: rank, created_at: created_at, id: id}),
    do: {rank, -updated_at_microseconds(created_at), -id}

  defp updated_at_microseconds(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)

  defp normalize_source!(:memories), do: :memories
  defp normalize_source!(:messages), do: :messages
  defp normalize_source!(:history), do: :messages
  defp normalize_source!(:all), do: :all
  defp normalize_source!("memories"), do: :memories
  defp normalize_source!("messages"), do: :messages
  defp normalize_source!("history"), do: :messages
  defp normalize_source!("all"), do: :all

  defp normalize_source!(value) do
    raise ArgumentError, "invalid search source: #{inspect(value)}"
  end

  defp normalize_scope!(:current_conversation), do: :current_conversation
  defp normalize_scope!(:owner), do: :owner
  defp normalize_scope!(:all), do: :all
  defp normalize_scope!("current"), do: :current_conversation
  defp normalize_scope!("owner"), do: :owner
  defp normalize_scope!("all"), do: :all

  defp normalize_scope!(value) do
    raise ArgumentError, "invalid search scope: #{inspect(value)}"
  end

  defp normalize_limit!(value) when is_integer(value) and value > 0, do: value

  defp normalize_limit!(value) do
    raise ArgumentError, "expected search limit to be a positive integer, got: #{inspect(value)}"
  end
end
