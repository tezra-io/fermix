defmodule Fermix.CLI.MemoryCommand do
  @moduledoc """
  `fermix memory` — review and restore durable memory rows.
  """

  alias FermixCore.Memory.Config
  alias FermixCore.Memory.PromptFiles
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Reviewer

  @review_switches [
    now: :boolean,
    conversation: :string,
    agent: :string,
    owner: :string,
    json: :boolean
  ]
  @json_switches [json: :boolean]

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) when is_list(argv) do
    case argv do
      ["review" | rest] -> review(rest)
      ["restore", id | rest] -> restore(id, rest)
      _other -> usage()
    end
  end

  defp review(argv) do
    with {:ok, opts} <- parse_opts(argv, @review_switches),
         true <- Keyword.get(opts, :now, false),
         {:ok, review_opts} <- review_opts(opts),
         {:ok, result} <- Reviewer.review_all_now(review_opts) do
      print(result, Keyword.get(opts, :json, false), fn _ ->
        IO.puts("memory review completed: #{result.total} conversation(s) checked")
      end)
    else
      false -> invalid_options("review requires --now")
      :error -> invalid_options("review")
      {:error, :invalid_conversation} -> invalid_options("review")
      {:error, reason} -> error(reason)
    end
  end

  defp restore(id, argv) do
    with {:ok, opts} <- parse_opts(argv, @json_switches),
         {:ok, parsed_id} <- parse_id(id),
         {:ok, memory} <- Repo.restore_memory(parsed_id, server: Config.repo_server()),
         {:ok, _rendered} <- PromptFiles.rebuild(memory.agent_id, memory.owner_id, :event, []) do
      print(%{restored: memory.id}, Keyword.get(opts, :json, false), fn _ ->
        IO.puts("restored memory #{memory.id}")
      end)
    else
      :error -> invalid_options("restore")
      {:error, reason} -> error(reason)
    end
  end

  defp review_opts(opts) do
    with {:ok, conversation_key} <- parse_conversation(Keyword.get(opts, :conversation)) do
      review_opts =
        []
        |> maybe_put(:agent_id, Keyword.get(opts, :agent, Config.agent_id()))
        |> maybe_put(:owner_id, Keyword.get(opts, :owner, Config.owner_id()))
        |> maybe_put(:conversation_key, conversation_key)

      {:ok, review_opts}
    end
  end

  defp parse_conversation(nil), do: {:ok, nil}

  defp parse_conversation(value) do
    case String.split(value, ":", parts: 3) do
      [channel, chat_id] when channel != "" and chat_id != "" ->
        {:ok, {channel, chat_id, :root}}

      [channel, chat_id, thread_scope]
      when channel != "" and chat_id != "" and thread_scope != "" ->
        {:ok, {channel, chat_id, thread_scope}}

      _invalid ->
        {:error, :invalid_conversation}
    end
  end

  defp parse_id(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _invalid -> {:error, :invalid_memory_id}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_opts(argv, switches) do
    case OptionParser.parse(argv, strict: switches) do
      {opts, [], []} -> {:ok, opts}
      {_opts, _args, _invalid} -> :error
    end
  end

  defp print(data, true, _pretty) do
    IO.puts(Jason.encode!(data))
    0
  end

  defp print(data, false, pretty) do
    pretty.(data)
    0
  end

  defp invalid_options(context) do
    IO.puts(:stderr, "invalid memory #{context} options")
    usage()
  end

  defp error(reason) do
    IO.puts(:stderr, "memory command failed: #{inspect(reason)}")
    1
  end

  defp usage do
    IO.puts(:stderr, """
    Usage:
      fermix memory review --now [--conversation channel:chat_id[:thread]] [--agent ID] [--owner ID] [--json]
      fermix memory restore ID [--json]
    """)

    2
  end
end
