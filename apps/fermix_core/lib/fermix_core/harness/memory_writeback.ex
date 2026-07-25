defmodule FermixCore.Harness.MemoryWriteback do
  @moduledoc """
  Untrusted-provenance run-summary write-back for completed harness runs
  (design §10.3).

  A harness run summarizes untrusted repo/issue/web content, so its summary is
  stored as a bounded DATA record — never an owner-authored fact. The row carries
  `source_type: "coding_harness"` (the untrusted marker read by
  `UntrustedContent.untrusted_source_type?/1`, so `memory_recall` frames it on
  recall), `category: "harness_run_summary"`, a below-owner-fact confidence, and
  `promote_target: "none"` (never promoted to bootstrap files, the job-scope
  precedent).

  Scope mirrors the origin: a scheduled launch writes under the parent job's
  memory scope (`job` / `memory_source_id`); a chat launch writes under the
  originating conversation scope. Write-back is best-effort — a disabled repo or
  a write error is logged and swallowed so it can never fail terminalization
  (jobs precedent).
  """

  require Logger

  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Scope

  @category "harness_run_summary"
  @source_type "coding_harness"
  @confidence 0.6
  # A scheduled harness run shares the parent job's `{job, memory_source_id}`
  # scope, and the upsert conflict target is `(agent, owner, scope_type, scope_id,
  # key)` — category is NOT part of it. A key of `"latest"` would collide with the
  # job's own `job_run_summary` "latest" row and one would silently overwrite the
  # other. A distinct key keeps both records under the shared scope (spec §D vs
  # C4's `key "latest"`).
  @key "harness_latest"
  @value_max 16_384

  @doc """
  Writes the run summary for a completed `row` (best-effort). A non-completed
  run, an empty summary, an unresolvable scope, a disabled repo, or a write error
  all return `:ok` — the run's terminalization must never depend on the write-back.
  """
  @spec write(map(), String.t() | nil, keyword()) :: :ok
  def write(row, result_text, opts \\ []) when is_map(row) and is_list(opts) do
    if completed?(row) do
      write_completed(row, result_text, opts)
    else
      :ok
    end
  end

  defp completed?(row), do: Map.get(row, :status) == "completed"

  defp write_completed(row, result_text, opts) do
    case bounded_value(result_text) do
      {:ok, value} -> write_value(row, value, opts)
      :skip -> :ok
    end
  end

  defp write_value(row, value, opts) do
    case resolve_scope(row, opts) do
      {:ok, scope} -> persist(row, value, scope, opts)
      {:error, reason} -> log_skip(row, reason)
    end
  end

  defp bounded_value(text) when is_binary(text) do
    case String.trim(text) do
      "" -> :skip
      _non_empty -> {:ok, bound(text)}
    end
  end

  defp bounded_value(_text), do: :skip

  defp bound(text) when byte_size(text) <= @value_max, do: text
  defp bound(text), do: binary_part(text, 0, @value_max)

  # --- Scope resolution ---------------------------------------------------

  defp resolve_scope(%{origin_kind: "scheduled", parent_job_id: job_id} = _row, opts)
       when is_binary(job_id) do
    resolve_job_scope(job_id, opts)
  end

  defp resolve_scope(row, _opts), do: resolve_chat_scope(row)

  defp resolve_job_scope(job_id, opts) do
    server = Keyword.get(opts, :repo, Repo)

    case JobsRegistry.get_job(job_id, server: server) do
      {:ok, %{memory_source_id: source_id} = job} when is_binary(source_id) ->
        {:ok,
         %{
           scope_type: "job",
           scope_id: source_id,
           agent_id: job.created_by_agent_id || MemoryConfig.agent_id(),
           owner_id: MemoryConfig.owner_id()
         }}

      {:ok, _job} ->
        {:error, :missing_job_memory_source}

      {:error, reason} ->
        {:error, {:parent_job_lookup_failed, reason}}
    end
  end

  defp resolve_chat_scope(row) do
    platform = Map.get(row, :platform)
    destination = Map.get(row, :destination)

    if is_binary(platform) and is_binary(destination) do
      scope_id = Scope.conversation_scope_id(platform, destination, thread_scope(row))

      {:ok,
       %{
         scope_type: "conversation",
         scope_id: scope_id,
         agent_id: MemoryConfig.agent_id(),
         owner_id: MemoryConfig.owner_id()
       }}
    else
      {:error, :missing_conversation_target}
    end
  end

  defp thread_scope(row) do
    case Map.get(row, :thread) do
      thread when is_binary(thread) and thread != "" -> thread
      _root -> :root
    end
  end

  # --- Persist ------------------------------------------------------------

  defp persist(row, value, scope, opts) do
    attrs = %{
      agent_id: scope.agent_id,
      owner_id: scope.owner_id,
      scope_type: scope.scope_type,
      scope_id: scope.scope_id,
      category: @category,
      key: @key,
      value: value,
      confidence: @confidence,
      promote_target: "none",
      source_id: Map.get(row, :id),
      source_type: @source_type,
      source_name: Map.get(row, :vendor),
      source_description: source_description(row),
      session_id: "harness_" <> Map.get(row, :id),
      run_id: Map.get(row, :id)
    }

    case Repo.upsert_memory(attrs, server: Keyword.get(opts, :repo, Repo)) do
      {:ok, _memory} -> :ok
      {:error, :disabled} -> :ok
      {:error, reason} -> log_skip(row, reason)
    end
  end

  defp source_description(row) do
    "run #{Map.get(row, :id)} in #{Map.get(row, :worktree_root)}"
  end

  defp log_skip(row, reason) do
    Logger.warning(
      "harness run #{Map.get(row, :id)} memory write-back skipped: #{inspect(reason)}"
    )

    :ok
  end
end
