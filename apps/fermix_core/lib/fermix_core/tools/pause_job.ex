defmodule FermixCore.Tools.PauseJob do
  @moduledoc """
  Pause a scheduled job.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Jobs.Registry
  alias FermixCore.Tools.JobRegistrySupport, as: Support

  @impl true
  def name, do: "pause_job"

  @impl true
  def description, do: "Pause a scheduled job so future scheduler ticks ignore it."

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["job_id"],
      properties: %{job_id: %{type: "string", description: "Scheduled job id."}}
    }
  end

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), context, fn -> do_execute(args, context) end)
  end

  defp do_execute(args, context) do
    with {:ok, job_id} <- Support.required_string(args, "job_id") do
      case Registry.pause_job(job_id, repo: Support.repo(context)) do
        {:ok, job} -> Support.success_json(Support.job_payload(job))
        {:error, reason} -> Support.error(reason)
      end
    else
      {:error, reason} -> {:ok, Tool.error(reason)}
    end
  end
end
