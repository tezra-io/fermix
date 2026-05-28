defmodule FermixCore.Realtime.ConversationRecorder do
  @moduledoc """
  Persists final Realtime voice transcripts and triggers memory review.
  """

  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Reviewer
  alias FermixCore.Realtime.Config

  @kind "voice_turn"
  @source_type "realtime"

  @spec conversation_key(String.t(), atom() | String.t() | integer()) ::
          {String.t(), String.t(), atom() | String.t() | integer()}
  def conversation_key(device_id, session_scope \\ :root) when is_binary(device_id) do
    {@source_type, source_id(device_id), session_scope}
  end

  @spec record_turn(Config.t(), String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def record_turn(%Config{} = config, device_id, role, content, opts \\ [])
      when is_binary(device_id) and is_binary(role) and is_binary(content) do
    record_messages(config, device_id, [%{role: role, content: content}], opts)
  end

  @spec record_exchange(Config.t(), String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def record_exchange(%Config{} = config, device_id, user_text, assistant_text, opts \\ [])
      when is_binary(device_id) and is_binary(user_text) and is_binary(assistant_text) do
    messages =
      [
        %{role: "user", content: user_text},
        %{role: "assistant", content: assistant_text}
      ]
      |> Enum.reject(&(String.trim(&1.content) == ""))

    record_messages(config, device_id, messages, opts)
  end

  defp record_messages(%Config{persist_transcripts?: false}, _device_id, _messages, _opts),
    do: :ok

  defp record_messages(%Config{}, _device_id, [], _opts), do: :ok

  defp record_messages(%Config{} = config, device_id, messages, opts) do
    with :ok <- insert_messages(config, device_id, messages, opts) do
      maybe_request_review(device_id, opts)
    end
  end

  defp insert_messages(config, device_id, messages, opts) do
    Enum.reduce_while(messages, :ok, fn message, :ok ->
      case insert_message(config, device_id, message.role, message.content, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp insert_message(config, device_id, role, content, opts) do
    repo_module = Keyword.get(opts, :repo_module, Repo)
    repo = Keyword.get(opts, :repo, MemoryConfig.repo_server(opts))

    attrs = message_attrs(config, device_id, role, content, opts)
    repo_opts = repo_opts(repo, opts)

    case repo_module.insert_message(attrs, repo_opts) do
      {:ok, _row} -> :ok
      {:error, :disabled} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp message_attrs(config, device_id, role, content, opts) do
    scope = Keyword.get(opts, :session_scope, :root)
    source = source_id(device_id)

    %{
      agent_id: Keyword.get(opts, :agent_id, MemoryConfig.agent_id(opts)),
      owner_id: Keyword.get(opts, :owner_id, MemoryConfig.owner_id(opts)),
      channel: @source_type,
      chat_id: source,
      thread_scope: scope,
      sender: Keyword.get(opts, :sender, role),
      role: role,
      kind: @kind,
      content: content,
      metadata:
        metadata(config, device_id, source, opts)
        |> Map.merge(Keyword.get(opts, :metadata, %{}))
    }
  end

  defp metadata(config, device_id, source, opts) do
    %{
      device_id: device_id,
      mode: "full_duplex_voice_call",
      model: config.model,
      source_type: @source_type,
      source_id: source,
      transcript_kind: @kind,
      usage: Keyword.get(opts, :usage),
      cost: Keyword.get(opts, :cost),
      tool_calls: Keyword.get(opts, :tool_calls, [])
    }
  end

  defp maybe_request_review(device_id, opts) do
    if Keyword.get(opts, :request_review?, true) do
      request_review(device_id, opts)
    else
      :ok
    end
  end

  defp request_review(device_id, opts) do
    source = source_id(device_id)
    reviewer = Keyword.get(opts, :memory_reviewer, Reviewer)

    review_opts =
      [
        agent_id: Keyword.get(opts, :agent_id, MemoryConfig.agent_id(opts)),
        owner_id: Keyword.get(opts, :owner_id, MemoryConfig.owner_id(opts)),
        conversation_key: conversation_key(device_id, Keyword.get(opts, :session_scope, :root)),
        repo: Keyword.get(opts, :repo, MemoryConfig.repo_server(opts)),
        task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
        extraction_timeout_ms: MemoryConfig.extraction_timeout_ms(opts),
        source_type: @source_type,
        source_id: source,
        source_name: "Realtime voice",
        source_description: "Local Realtime voice companion transcript"
      ]
      |> maybe_put_test_pid(opts)

    reviewer.start_background(review_opts)
  end

  defp maybe_put_test_pid(review_opts, opts) do
    case Keyword.get(opts, :test_pid) do
      nil -> review_opts
      test_pid -> Keyword.put(review_opts, :test_pid, test_pid)
    end
  end

  defp repo_opts(repo, opts) do
    opts
    |> Keyword.take([:test_pid])
    |> Keyword.put(:server, repo)
  end

  defp source_id(device_id), do: "local:" <> device_id
end
