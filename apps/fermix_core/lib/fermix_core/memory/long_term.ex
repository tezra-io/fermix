defmodule FermixCore.Memory.LongTerm do
  @moduledoc """
  The owner's long-term memory, edited on request: the writes behind the
  `memory_store` and `memory_forget` tools.

  `Memory.Reviewer` distils memory from conversation in the background, about
  once a day. This is the path for what is asked for now — remember this, that
  is wrong, forget that — under the same admission policy (`Memory.Admission`),
  on the same rows, addressed by the same ids. A write that changes what
  USER.md or MEMORY.md show republishes both files and invalidates the cached
  runtime context, so the next turn is built from it.

  Every function reports what happened rather than what was asked: the receipt
  carries the row as SQLite now holds it and whether the prompt files caught up.
  """

  alias FermixCore.Agents.MainAgent
  alias FermixCore.Memory.Admission
  alias FermixCore.Memory.PromptFiles
  alias FermixCore.Memory.Repo

  @archive_actor "main_agent"
  @note_category "fact"

  @type context :: %{
          required(:agent_id) => String.t(),
          required(:owner_id) => String.t(),
          required(:repo) => GenServer.server(),
          optional(:source_trust) => atom() | nil,
          optional(:main_agent_server) => GenServer.server() | nil
        }

  @typedoc """
  `published` is `:ok` once the prompt files were rebuilt from the row,
  `:not_shown` for a row no prompt file renders (a conversation note), and
  `{:error, reason}` when the row is saved but the rebuild failed.
  """
  @type receipt :: %{
          memory: Repo.memory_row(),
          published: :ok | :not_shown | {:error, term()}
        }

  @type refusal ::
          :disabled
          | :not_found
          | :blank_key
          | :blank_value
          | {:invalid_category, String.t()}
          | {:category_not_allowed, String.t()}
          | {:not_editable, String.t()}
          | {:value_too_long, pos_integer(), pos_integer()}

  @doc """
  Saves one fact under a durable category. A user category lands in the owner's
  scope (USER.md), a work category in the agent's (MEMORY.md) — the mapping the
  reviewer's `add` uses. Saving a key again replaces its value.
  """
  @spec save(String.t(), String.t(), String.t(), context()) ::
          {:ok, receipt()} | {:error, refusal() | term()}
  def save(category, key, value, ctx)
      when is_binary(category) and is_binary(key) and is_binary(value) and is_map(ctx) do
    with {:ok, scope_type, scope_id} <- scope_for(category, ctx),
         :ok <- allow_category(category, ctx),
         {:ok, key} <- present(key, :blank_key),
         {:ok, value} <- prompt_value(value),
         attrs = save_attrs(category, key, value, scope_type, scope_id, ctx),
         {:ok, memory} <- Repo.upsert_memory(attrs, server: ctx.repo) do
      {:ok, receipt(memory, ctx)}
    end
  end

  @doc """
  Replaces the value of an existing row by id, keeping its scope and category:
  the correction path for a fact already remembered, whoever wrote it.
  """
  @spec replace(pos_integer(), String.t(), context()) ::
          {:ok, receipt()} | {:error, refusal() | term()}
  def replace(id, value, ctx)
      when is_integer(id) and id > 0 and is_binary(value) and is_map(ctx) do
    with {:ok, existing} <- fetch_editable(id, ctx),
         {:ok, value} <- value_for(existing, value),
         {:ok, memory} <- Repo.update_memory_value(row_selector(id, ctx), value, server: ctx.repo) do
      {:ok, receipt(memory, ctx)}
    end
  end

  @doc """
  Archives a row by id: it leaves the prompt files and every recall, and stays
  in SQLite where `fermix memory restore ID` can bring it back.
  """
  @spec forget(pos_integer(), String.t(), context()) ::
          {:ok, receipt()} | {:error, refusal() | term()}
  def forget(id, reason, ctx)
      when is_integer(id) and id > 0 and is_binary(reason) and is_map(ctx) do
    selector = Map.put(row_selector(id, ctx), :archived?, false)

    with {:ok, _existing} <- fetch_editable(id, ctx),
         {:ok, memory} <-
           Repo.archive_memory(selector, @archive_actor, reason, DateTime.utc_now(),
             server: ctx.repo
           ) do
      {:ok, receipt(memory, ctx)}
    end
  end

  defp scope_for(category, ctx) do
    cond do
      Admission.promotable_category?(:user, category) -> {:ok, "owner", ctx.owner_id}
      Admission.promotable_category?(:memory, category) -> {:ok, "agent", ctx.agent_id}
      true -> {:error, {:invalid_category, category}}
    end
  end

  defp allow_category(category, ctx) do
    if Admission.category_allowed?(category, Map.get(ctx, :source_trust)) do
      :ok
    else
      {:error, {:category_not_allowed, category}}
    end
  end

  defp save_attrs(category, key, value, scope_type, scope_id, ctx) do
    %{
      agent_id: ctx.agent_id,
      owner_id: ctx.owner_id,
      scope_type: scope_type,
      scope_id: scope_id,
      category: category,
      key: key,
      value: value,
      promote_target: Admission.prompt_target(%{category: category, scope_type: scope_type})
    }
  end

  defp fetch_editable(id, ctx) do
    selector = Map.put(row_selector(id, ctx), :archived?, false)

    with {:ok, memory} <- Repo.get_memory(selector, server: ctx.repo),
         :ok <- editable(memory, ctx) do
      {:ok, memory}
    end
  end

  defp row_selector(id, ctx), do: %{id: id, agent_id: ctx.agent_id, owner_id: ctx.owner_id}

  # The rows these tools may change: a conversation note `memory_store` wrote,
  # and the durable categories the caller's trust admits. Anything else in the
  # table — a job's run summary, a coding run's write-back — belongs to the
  # run that wrote it.
  defp editable(%{category: @note_category, scope_type: "conversation"}, _ctx), do: :ok

  defp editable(%{category: category}, ctx) do
    if Admission.category_allowed?(category, Map.get(ctx, :source_trust)) do
      :ok
    else
      {:error, {:not_editable, category}}
    end
  end

  defp value_for(existing, value) do
    if Admission.prompt_target(existing) == "none" do
      present(value, :blank_value)
    else
      prompt_value(value)
    end
  end

  # A prompt file renders one short clause per row and clips anything longer.
  # What the owner asked to keep is refused at that length instead, so the
  # caller shortens it and nothing is shown with its qualifier cut off.
  defp prompt_value(value) do
    max = PromptFiles.max_value_chars()

    with {:ok, value} <- present(value, :blank_value) do
      case String.length(value) do
        length when length > max -> {:error, {:value_too_long, length, max}}
        _fits -> {:ok, value}
      end
    end
  end

  defp present(text, blank_reason) do
    case String.trim(text) do
      "" -> {:error, blank_reason}
      trimmed -> {:ok, trimmed}
    end
  end

  defp receipt(memory, ctx), do: %{memory: memory, published: publish(memory, ctx)}

  defp publish(memory, ctx) do
    if Admission.prompt_target(memory) == "none" do
      :not_shown
    else
      republish(memory, ctx)
    end
  end

  defp republish(memory, ctx) do
    provenance = %{
      trigger: "memory_tool",
      memory_ids: [memory.id],
      description: "Prompt file rebuild triggered by a memory tool"
    }

    case PromptFiles.rebuild(ctx.agent_id, ctx.owner_id, :event,
           provenance: provenance,
           repo: ctx.repo
         ) do
      {:ok, _rendered} -> invalidate_runtime_context(ctx)
      {:error, reason} -> {:error, reason}
    end
  end

  # Best-effort, like the turn runner's own invalidation: a main agent that is
  # missing or restarting builds its context fresh on the next checkout anyway.
  defp invalidate_runtime_context(%{main_agent_server: server} = ctx) when not is_nil(server) do
    :ok = MainAgent.invalidate_runtime_context(server, :memory_tool)

    :telemetry.execute(
      [:fermix, :memory, :runtime_context_invalidated],
      %{count: 1},
      %{agent: ctx.agent_id, owner: ctx.owner_id, trigger: :memory_tool}
    )
  catch
    :exit, _reason -> :ok
  end

  defp invalidate_runtime_context(_ctx), do: :ok
end
