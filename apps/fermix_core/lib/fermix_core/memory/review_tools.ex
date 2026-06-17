defmodule FermixCore.Memory.ReviewTools do
  @moduledoc """
  Internal operations used by the background memory reviewer.

  Operations apply **best-effort**: a model-level rejection — an unknown or
  out-of-scope row id, a trust-refused category, a malformed field — is
  recorded as a skip and the batch continues, so one bad operation never
  discards the good ones or fails the whole review. Only a genuine
  system/storage error halts the batch and fails the review (the pointer is
  left untouched and the window is retried under backoff).
  """

  require Logger

  alias FermixCore.Memory.Admission
  alias FermixCore.Memory.Repo

  @archive_actor "memory_reviewer"

  @type context :: %{
          required(:agent_id) => String.t(),
          required(:owner_id) => String.t(),
          required(:repo) => GenServer.server(),
          optional(:source_trust) => atom(),
          optional(:telemetry) => map()
        }

  @type stats :: %{
          added: non_neg_integer(),
          replaced: non_neg_integer(),
          archived: non_neg_integer(),
          skipped: non_neg_integer(),
          memory_ids: [pos_integer()]
        }

  @spec apply_operations([map()], context()) :: {:ok, stats()} | {:error, term()}
  def apply_operations(operations, ctx) when is_list(operations) and is_map(ctx) do
    initial = %{added: 0, replaced: 0, archived: 0, skipped: 0, memory_ids: []}

    Enum.reduce_while(operations, {:ok, initial}, fn operation, {:ok, stats} ->
      case apply_operation(operation, ctx) do
        {:ok, kind, memory} ->
          emit_write(ctx, kind, memory)
          {:cont, {:ok, record_success(stats, kind, memory.id)}}

        {:skip, reason} ->
          {:cont, {:ok, record_skip(stats, reason)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  # A durable reviewer write becomes an observable `[:fermix, :memory, :write]`
  # span ONLY when the caller threads telemetry attribution (session_id + the
  # conversation channel/chat_id, optional parent_session). Without it (legacy /
  # test callers) the write stays silent — backward compatible. `tool:
  # "memory_write"` makes it a tool-shaped span so it surfaces alongside tool
  # spans and lands in the JSONL tool-exec stream. This is the reviewer's
  # write-visibility seam; the `memory_store` tool already spans on its own path.
  defp emit_write(%{telemetry: %{} = tel}, kind, memory) do
    :telemetry.execute(
      [:fermix, :memory, :write],
      %{count: 1},
      %{
        tool: "memory_write",
        action: kind,
        category: memory.category,
        key: memory.key,
        scope_type: memory.scope_type,
        memory_id: memory.id,
        agent: Map.get(tel, :agent),
        owner: Map.get(tel, :owner),
        session_id: Map.get(tel, :session_id),
        parent_session: Map.get(tel, :parent_session),
        channel: Map.get(tel, :channel),
        chat_id: Map.get(tel, :chat_id)
      }
    )
  end

  defp emit_write(_ctx, _kind, _memory), do: :ok

  defp apply_operation(%{"action" => "add"} = op, ctx), do: add_memory(op, ctx)
  defp apply_operation(%{action: "add"} = op, ctx), do: add_memory(op, ctx)
  defp apply_operation(%{"action" => "replace"} = op, ctx), do: replace_memory(op, ctx)
  defp apply_operation(%{action: "replace"} = op, ctx), do: replace_memory(op, ctx)
  defp apply_operation(%{"action" => "archive"} = op, ctx), do: archive_memory(op, ctx)
  defp apply_operation(%{action: "archive"} = op, ctx), do: archive_memory(op, ctx)
  defp apply_operation(operation, _ctx), do: {:skip, {:invalid_review_operation, operation}}

  defp add_memory(op, ctx) do
    with {:ok, target} <- fetch_string(op, :target),
         {:ok, category} <- fetch_string(op, :category),
         {:ok, value} <- fetch_string(op, :value),
         :ok <- ensure_category_allowed(category, ctx),
         {:ok, attrs} <- add_attrs(target, category, value, ctx) do
      insert_added_memory(attrs, ctx)
    end
  end

  defp insert_added_memory(attrs, ctx) do
    case Repo.upsert_memory(attrs, server: ctx.repo) do
      {:ok, memory} -> {:ok, :added, memory}
      {:error, reason} -> {:error, reason}
    end
  end

  defp replace_memory(op, ctx) do
    with {:ok, id} <- fetch_id(op),
         {:ok, value} <- fetch_string(op, :value),
         {:ok, existing} <- get_owned_memory(id, ctx),
         :ok <- ensure_category_allowed(existing.category, ctx) do
      update_replaced_memory(id, value, ctx)
    end
  end

  defp update_replaced_memory(id, value, ctx) do
    case Repo.update_memory_value(
           %{id: id, agent_id: ctx.agent_id, owner_id: ctx.owner_id},
           value,
           server: ctx.repo
         ) do
      {:ok, memory} -> {:ok, :replaced, memory}
      {:error, :not_found} -> {:skip, {:memory_not_found, id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp archive_memory(op, ctx) do
    with {:ok, id} <- fetch_id(op),
         {:ok, reason} <- fetch_string(op, :reason),
         {:ok, existing} <- get_owned_memory(id, ctx),
         :ok <- ensure_category_allowed(existing.category, ctx) do
      archive_existing_memory(id, reason, ctx)
    end
  end

  defp archive_existing_memory(id, reason, ctx) do
    case Repo.archive_memory(
           %{id: id, agent_id: ctx.agent_id, owner_id: ctx.owner_id, archived?: false},
           @archive_actor,
           reason,
           DateTime.utc_now(),
           server: ctx.repo
         ) do
      {:ok, memory} -> {:ok, :archived, memory}
      {:error, :not_found} -> {:skip, {:memory_not_found, id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_category_allowed(category, ctx) do
    if Admission.category_allowed?(category, Map.get(ctx, :source_trust)) do
      :ok
    else
      {:skip, {:unauthorized_review_category, category}}
    end
  end

  defp add_attrs("user", category, value, ctx) do
    promoted_attrs(:user, "owner", ctx.owner_id, category, value, ctx)
  end

  defp add_attrs("memory", category, value, ctx) do
    promoted_attrs(:memory, "agent", ctx.agent_id, category, value, ctx)
  end

  defp add_attrs(target, category, _value, _ctx) do
    {:skip, {:invalid_add_target_category, target, category}}
  end

  defp promoted_attrs(bucket, scope_type, scope_id, category, value, ctx) do
    if Admission.promotable_category?(bucket, category) do
      {:ok,
       %{
         agent_id: ctx.agent_id,
         owner_id: ctx.owner_id,
         scope_type: scope_type,
         scope_id: scope_id,
         category: category,
         key: fresh_key(category, value),
         value: value,
         confidence: 1.0,
         promote_target: Admission.prompt_target(%{category: category, scope_type: scope_type})
       }}
    else
      {:skip, {:invalid_add_target_category, Atom.to_string(bucket), category}}
    end
  end

  defp get_owned_memory(id, ctx) do
    case Repo.get_memory(
           %{id: id, agent_id: ctx.agent_id, owner_id: ctx.owner_id, archived?: false},
           server: ctx.repo
         ) do
      {:ok, memory} -> {:ok, memory}
      {:error, :not_found} -> {:skip, {:memory_not_found, id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_string(op, key) do
    value = Map.get(op, key, Map.get(op, Atom.to_string(key)))

    case value do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:skip, {:blank_review_field, key}}
          trimmed -> {:ok, trimmed}
        end

      _other ->
        {:skip, {:invalid_review_field, key}}
    end
  end

  defp fetch_id(op) do
    case Map.get(op, :id, Map.get(op, "id")) do
      id when is_integer(id) and id > 0 -> {:ok, id}
      id when is_binary(id) -> parse_id(id)
      _other -> {:skip, {:invalid_review_field, :id}}
    end
  end

  defp parse_id(id) do
    case Integer.parse(id) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _invalid -> {:skip, {:invalid_review_field, :id}}
    end
  end

  defp fresh_key(category, value) do
    hash =
      :crypto.hash(:sha256, value)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    suffix = System.unique_integer([:positive, :monotonic])
    "review_#{category}_#{hash}_#{suffix}"
  end

  defp record_success(stats, kind, id) do
    Logger.info("memory review #{kind} memory_id=#{id}")

    stats
    |> Map.update!(kind, &(&1 + 1))
    |> Map.update!(:memory_ids, &[id | &1])
  end

  defp record_skip(stats, reason) do
    Logger.info("memory review skipped operation: #{inspect(reason)}")
    Map.update!(stats, :skipped, &(&1 + 1))
  end
end
