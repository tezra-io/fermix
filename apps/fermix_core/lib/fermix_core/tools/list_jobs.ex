defmodule FermixCore.Tools.ListJobs do
  @moduledoc """
  List durable scheduled jobs. Each carries its heal that is not closed (M106
  §5.4), or nil: what failed, since when, how many runs, and whether the
  owner was told.
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

      with {:ok, jobs} <- Registry.list_jobs(opts),
           {:ok, heals} <- Repo.job_heals_call(:open_by_job, server: opts[:repo]) do
        Support.success_json(%{jobs: Enum.map(jobs, &listed_job(&1, heals, opts[:repo]))})
      else
        {:error, reason} -> Support.error(reason)
      end
    end)
  end

  defp listed_job(job, heals, repo) do
    job
    |> Support.job_payload(repo)
    |> Map.put(:heal, heals |> Map.get(job.id) |> Support.heal_payload())
  end
end
