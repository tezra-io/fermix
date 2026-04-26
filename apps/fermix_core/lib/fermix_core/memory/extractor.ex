defmodule FermixCore.Memory.Extractor do
  @moduledoc """
  Background durable-memory extraction pipeline for completed turns.
  """

  alias FermixCore.Memory.Admission
  alias FermixCore.Memory.Config
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Scheduler
  alias FermixCore.Memory.Store

  @type conversation_message :: %{
          required(:role) => String.t(),
          required(:content) => String.t()
        }

  @type candidate :: Admission.candidate()

  @spec extract(keyword()) :: {:ok, map()} | {:error, term()}
  def extract(opts) when is_list(opts) do
    start = System.monotonic_time(:millisecond)

    ctx = extraction_context(opts)

    result =
      with {:ok, response} <- call_provider(ctx),
           {:ok, candidates} <- parse_candidates(response.content),
           admission <-
             Admission.apply(candidates,
               agent_id: ctx.agent_id,
               owner_id: ctx.owner_id,
               conversation_key: ctx.conversation_key,
               chat_mode: ctx.chat_mode,
               repo: ctx.repo,
               min_confidence: ctx.min_confidence
             ),
           {:ok, persisted} <- persist_admitted(admission.admitted, ctx.memory_store, ctx.repo) do
        maybe_request_rebuild(admission, ctx, persisted)
        {:ok, extraction_result(candidates, admission)}
      end

    emit_telemetry(result, ctx, System.monotonic_time(:millisecond) - start)
    result
  end

  @spec parse_candidates(String.t()) :: {:ok, [candidate()]} | {:error, term()}
  def parse_candidates(payload) when is_binary(payload) do
    case payload |> normalize_payload() |> Jason.decode() do
      {:ok, decoded} ->
        with {:ok, candidates} <- candidate_items(decoded) do
          reduce_candidates(candidates)
        else
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:invalid_json, reason}}
    end
  end

  defp extraction_context(opts) do
    %{
      provider: Keyword.fetch!(opts, :provider),
      messages:
        recent_messages(
          Keyword.fetch!(opts, :messages),
          Config.extraction_context_messages(opts)
        ),
      agent_id: Keyword.fetch!(opts, :agent_id),
      owner_id: Keyword.fetch!(opts, :owner_id),
      conversation_key: Keyword.fetch!(opts, :conversation_key),
      chat_mode: Keyword.get(opts, :chat_mode, :direct),
      memory_store: Keyword.get(opts, :memory_store, Store),
      scheduler: Keyword.get(opts, :scheduler, Scheduler),
      repo: Keyword.get(opts, :repo, Config.repo_server(opts)),
      min_confidence: Config.extraction_min_confidence(opts),
      timeout_ms: Config.extraction_timeout_ms(opts),
      model: Config.extraction_model(opts)
    }
  end

  defp extraction_result(candidates, admission) do
    %{
      candidate_count: length(candidates),
      admitted_count: length(admission.admitted),
      rebuild?: admission.rebuild?,
      corrective?: admission.corrective?
    }
  end

  defp normalize_payload(payload) do
    payload
    |> String.trim()
    |> strip_markdown_code_fence()
  end

  defp strip_markdown_code_fence(payload) do
    case Regex.named_captures(
           ~r/\A```(?:[\w+-]+)?[ \t]*\R(?<body>.*?)(?:\R)?```[ \t]*\z/s,
           payload
         ) do
      %{"body" => body} -> String.trim(body)
      nil -> payload
    end
  end

  defp candidate_items(items) when is_list(items), do: {:ok, items}
  defp candidate_items(%{"candidates" => items}) when is_list(items), do: {:ok, items}
  defp candidate_items(_decoded), do: {:error, :invalid_payload}

  defp reduce_candidates(decoded) do
    Enum.reduce_while(decoded, {:ok, []}, fn item, {:ok, acc} ->
      case normalize_candidate(item) do
        {:ok, candidate} -> {:cont, {:ok, acc ++ [candidate]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp recent_messages(messages, limit) when is_list(messages) do
    messages
    |> Enum.take(-limit)
    |> Enum.map(&normalize_message!/1)
  end

  defp normalize_message!(%{role: role, content: content})
       when is_binary(role) and is_binary(content) do
    %{role: role, content: content}
  end

  defp call_provider(ctx) do
    prompt_messages = extraction_prompt(ctx.messages, ctx.chat_mode)

    ctx.provider.chat(
      prompt_messages,
      provider_opts(ctx)
    )
  end

  defp extraction_prompt(messages, chat_mode) do
    [
      %{
        role: "system",
        content: """
        Extract only durable memory candidates from the conversation.
        Output strict JSON only. Do not emit prose, markdown, or code fences.
        Return either a top-level JSON array of candidate objects or an object with a
        "candidates" array. Return [] when there are no durable memory candidates.

        Allowed categories: identity, preference, goal, project, environment, instruction, correction, episode.
        Allowed scope_type values: owner, conversation, agent.
        Allowed promote_target values: none, user_md, memory_md.

        Current chat mode: #{chat_mode}.
        Prefer explicit facts over guesses. Ignore transient chatter and one-off steps.
        Latest correction wins over older beliefs.
        Write memory values as declarative facts, not instructions to yourself.
        Good: "User prefers dark mode"
        Bad: "Remember to always use dark mode"
        Good: "Project uses Elixir with Phoenix for the backend"
        Bad: "Always use Elixir and Phoenix when writing backend code"
        """
      },
      %{
        role: "user",
        content: "Conversation:\n" <> render_messages(messages)
      }
    ]
  end

  defp provider_opts(ctx) do
    [temperature: 0.1, tools: [], req_options: [receive_timeout: ctx.timeout_ms]]
    |> maybe_put_model(ctx.model)
  end

  defp maybe_put_model(opts, nil), do: opts
  defp maybe_put_model(opts, model), do: Keyword.put(opts, :model, model)

  defp render_messages(messages) do
    Enum.map_join(messages, "\n", fn %{role: role, content: content} ->
      "[#{role}] #{content}"
    end)
  end

  defp normalize_candidate(%{} = item) do
    with {:ok, category} <- fetch_string(item, "category"),
         {:ok, key} <- fetch_string(item, "key"),
         {:ok, value} <- fetch_string(item, "value"),
         {:ok, scope_type} <- fetch_string(item, "scope_type"),
         {:ok, confidence} <- fetch_confidence(item),
         {:ok, promote_target} <- fetch_string(item, "promote_target") do
      {:ok,
       %{
         category: category,
         key: key,
         value: value,
         scope_type: scope_type,
         confidence: confidence,
         promote_target: promote_target
       }}
    end
  end

  defp normalize_candidate(_item), do: {:error, :invalid_candidate}

  defp fetch_string(item, key) do
    case Map.get(item, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:blank_field, key}}
          trimmed -> {:ok, trimmed}
        end

      _other ->
        {:error, {:invalid_field, key}}
    end
  end

  defp fetch_confidence(%{"confidence" => value})
       when is_float(value) and value >= 0.0 and value <= 1.0,
       do: {:ok, value}

  defp fetch_confidence(%{"confidence" => value})
       when is_integer(value) and value >= 0 and value <= 1,
       do: {:ok, value * 1.0}

  defp fetch_confidence(_item), do: {:error, {:invalid_field, "confidence"}}

  defp persist_admitted([], _memory_store, _repo), do: {:ok, []}

  defp persist_admitted(admitted, memory_store, repo) do
    Enum.reduce_while(admitted, {:ok, []}, fn memory, {:ok, acc} ->
      case Store.remember(memory, server: memory_store) do
        :ok -> {:cont, {:ok, acc ++ [persisted_memory(memory, repo)]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_request_rebuild(%{rebuild?: false}, _ctx, _persisted), do: :ok

  defp maybe_request_rebuild(%{rebuild?: true}, ctx, persisted) do
    Scheduler.request_rebuild(ctx.agent_id, ctx.owner_id, :event,
      server: ctx.scheduler,
      provenance: extraction_provenance(persisted)
    )
  end

  defp persisted_memory(memory, repo) do
    case Repo.get_memory(memory_selector(memory), server: repo) do
      {:ok, persisted} -> persisted
      {:error, :disabled} -> memory
      {:error, :not_found} -> memory
      {:error, _reason} -> memory
    end
  end

  defp memory_selector(memory) do
    %{
      agent_id: memory.agent_id,
      owner_id: memory.owner_id,
      scope_type: memory.scope_type,
      scope_id: memory.scope_id,
      key: memory.key
    }
  end

  defp extraction_provenance(memories) do
    %{
      trigger: "extraction_rebuild",
      memory_ids: memories |> Enum.map(&Map.get(&1, :id)) |> Enum.reject(&is_nil/1),
      categories: memories |> Enum.map(& &1.category) |> Enum.uniq(),
      description: "Prompt file rebuild triggered by memory extraction"
    }
  end

  defp emit_telemetry(result, ctx, duration_ms) do
    {status, counts} =
      case result do
        {:ok, data} ->
          {:ok, %{candidate_count: data.candidate_count, admitted_count: data.admitted_count}}

        {:error, _reason} ->
          {:error, %{candidate_count: 0, admitted_count: 0}}
      end

    :telemetry.execute(
      [:fermix, :memory, :extraction],
      Map.put(counts, :duration_ms, duration_ms),
      %{agent_id: ctx.agent_id, owner_id: ctx.owner_id, chat_mode: ctx.chat_mode, status: status}
    )
  end
end
