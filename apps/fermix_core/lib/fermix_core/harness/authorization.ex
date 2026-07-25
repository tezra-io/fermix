defmodule FermixCore.Harness.Authorization do
  @moduledoc """
  The execute-time authorization gate shared by every coding-harness tool and by
  their `advertise?/1` visibility hook (design §7.1, spec §6/C1).

  `advertise?/1` only filters the model-visible schema list — a remembered tool
  name stays dispatchable inside the run's policy/allowlist ceiling, and an
  operator-created cron job runs with the full operator policy (including
  `:exec`). So visibility is never the barrier: this gate is called first thing
  inside every harness tool's `execute/2`, before any ledger insert, and refuses
  independently of what was advertised.

  Two ways in, enforced in order:

    * **Live attended operator turn** — `source_trust == :operator`,
      `subagent_depth == 0`, and a channel `reply_fn` present (the owner is on
      the other end and can see the outcome).
    * **Scheduled context** — the run is a non-delegated cron loop
      (`subagent_depth == 0`) whose `conversation_key` is `{:scheduled_job, _, _}`
      and whose *raw job row* names the exact tool in its persisted
      `allowed_tools`. The runner narrows `[]` → `nil` before the loop context is
      built, so the allowlist is read straight from the job row via
      `Jobs.Registry.get_job/2` — a generic `:exec` policy is deliberately
      insufficient, and an empty/absent job allowlist is not an authorization.
      The depth guard is load-bearing: a subagent worker fanned out inside a cron
      job inherits the scheduled `conversation_key`/`job_id` (subagents strip
      `:source_trust`, never those keys), so without it an allowlisted job would
      authorize its own workers — the worker-exclusion invariant (§7.1) forbids
      that.

  Anything else is refused with a class-distinct reason: `:worker_context`
  (a delegated subagent — `source_trust` is stripped), `:guest_context`,
  `:unattended` (an operator context with no live reply surface, e.g. a
  `/background` run), or `:cron_not_allowlisted`.
  """

  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Memory.Repo

  @type reason ::
          :worker_context
          | :guest_context
          | :unattended
          | :cron_not_allowlisted
          | :missing_job_id
          | {:job_lookup_failed, term()}

  @doc """
  Authorizes dispatch of `tool_name` in `context`. Returns `:ok` for a live
  attended operator turn or an allowlisted scheduled context; a class-distinct
  `{:error, reason}` otherwise.
  """
  @spec authorize(String.t(), map()) :: :ok | {:error, reason()}
  def authorize(tool_name, context) when is_binary(tool_name) and is_map(context) do
    cond do
      scheduled?(context) -> authorize_scheduled(tool_name, context)
      attended_operator?(context) -> :ok
      true -> {:error, refusal_reason(context)}
    end
  end

  # --- Attended operator --------------------------------------------------

  defp attended_operator?(context) do
    Map.get(context, :source_trust) == :operator and
      Map.get(context, :subagent_depth, 0) == 0 and
      is_function(Map.get(context, :reply_fn), 1)
  end

  # --- Scheduled (raw job-row allowlist) ----------------------------------

  # A delegated worker inherits the scheduled `conversation_key`/`job_id` but runs
  # at `subagent_depth >= 1`; the real cron loop context carries no depth (→ 0).
  # Gating the scheduled path on depth 0 keeps a worker out of the job allowlist.
  defp scheduled?(context) do
    Map.get(context, :subagent_depth, 0) == 0 and
      match?({:scheduled_job, _job_id, _run_id}, Map.get(context, :conversation_key))
  end

  defp authorize_scheduled(tool_name, context) do
    case fetch_job(context) do
      {:ok, job} -> check_allowlist(tool_name, job)
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_job(context) do
    case Map.get(context, :job_id) do
      job_id when is_binary(job_id) and job_id != "" ->
        lookup_job(job_id, context)

      _missing ->
        {:error, :missing_job_id}
    end
  end

  defp lookup_job(job_id, context) do
    registry = Map.get(context, :jobs_registry, JobsRegistry)
    server = Map.get(context, :memory_repo, Repo)

    case registry.get_job(job_id, server: server) do
      {:ok, job} -> {:ok, job}
      {:error, reason} -> {:error, {:job_lookup_failed, reason}}
    end
  end

  defp check_allowlist(tool_name, job) do
    allowed = Map.get(job, :allowed_tools) || []

    if tool_name in allowed do
      :ok
    else
      {:error, :cron_not_allowlisted}
    end
  end

  # --- Refusal classification ---------------------------------------------

  defp refusal_reason(context) do
    case Map.get(context, :source_trust) do
      :guest -> :guest_context
      :operator -> :unattended
      nil -> :worker_context
      _other -> :worker_context
    end
  end
end
