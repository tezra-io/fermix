defmodule FermixCore.Tools.ListJobs do
  @moduledoc """
  List durable scheduled jobs. Each carries its heal that is not closed (M106
  §5.4), or nil: what failed, since when, how many runs, and whether the
  owner was told, and once diagnosed (§5.5) what Fermix decided, whether the
  diagnosis left a note (its text is read with the run, through
  `get_job_run`, as outside content: a model wrote it after reading the
  failure's words), and a proposal's fields with the whole values they would
  take. A job's latest proposal that is no longer its open heal (answered,
  superseded, expired or closed by a clean run) shows as `last_proposal` for
  the seven days its failure is quiet, whatever heal is open beside it
  (§5.7, D5).

  Context seams: `:memory_repo` and `:now_fn` (the clock that window is
  counted on).
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Jobs.Registry
  alias FermixCore.Memory.Repo
  alias FermixCore.Tools.JobRegistrySupport, as: Support

  @impl true
  def name, do: "list_jobs"

  @impl true
  def description, do: "List scheduled jobs and their current registry status."

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        state: %{
          type: "string",
          description: "Optional state filter such as scheduled or paused."
        }
      }
    }
  end

  @impl true
  def when_to_use, do: "List Fermix scheduled jobs and inspect their current states."

  @impl true
  def examples, do: [%{args: %{"state" => "scheduled"}, note: "list active scheduled jobs"}]

  @impl true
  def failure_modes do
    [
      %{tag: "registry_failed", description: "job registry query failed"},
      %{tag: "invalid_state", description: "state filter is not a string"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :scheduling

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), context, fn ->
      opts = [repo: Support.repo(context)]

      opts =
        case Support.optional_string(args, "state") do
          nil -> opts
          state -> Keyword.put(opts, :state, state)
        end

      now = now(context)

      with {:ok, jobs} <- Registry.list_jobs(opts),
           {:ok, heals} <- Repo.job_heals_call({:listed_by_job, now}, server: opts[:repo]) do
        Support.success_json(%{jobs: Enum.map(jobs, &listed_job(&1, heals, opts[:repo]))})
      else
        {:error, reason} -> Support.error(reason)
      end
    end)
  end

  # A turn's context carries the seam as nil when no clock was injected
  # (`Agents.TurnRunner`), so the key being there says nothing.
  defp now(%{now_fn: now_fn}) when is_function(now_fn, 0), do: now_fn.()
  defp now(_context), do: DateTime.utc_now()

  defp listed_job(job, %{open: open, proposals: proposals}, repo) do
    heal = Map.get(open, job.id)

    job
    |> Support.job_payload(repo)
    |> Map.put(:heal, Support.heal_payload(heal))
    |> put_last_proposal(heal, Map.get(proposals, job.id))
  end

  defp put_last_proposal(payload, _heal, nil), do: payload
  defp put_last_proposal(payload, %{id: id}, %{id: id}), do: payload

  defp put_last_proposal(payload, _heal, proposal),
    do: Map.put(payload, :last_proposal, Support.heal_payload(proposal))
end
