defmodule FermixCore.Tools.ListJobs do
  @moduledoc """
  List durable scheduled jobs.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Jobs.Registry
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

      case Registry.list_jobs(opts) do
        {:ok, jobs} -> Support.success_json(%{jobs: Enum.map(jobs, &Support.job_payload/1)})
        {:error, reason} -> Support.error(reason)
      end
    end)
  end
end
