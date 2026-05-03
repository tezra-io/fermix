defmodule FermixCore.Tools.RemoveJob do
  @moduledoc """
  Remove a scheduled job and tombstone its memory source.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Jobs.Registry
  alias FermixCore.Tools.JobRegistrySupport, as: Support

  @impl true
  def name, do: "remove_job"

  @impl true
  def description, do: "Remove a scheduled job and mark its memory source removed."

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
      case Registry.remove_job(job_id, repo: Support.repo(context)) do
        :ok -> Support.success_json(%{removed: true, job_id: job_id})
        {:error, reason} -> Support.error(reason)
      end
    else
      {:error, reason} -> {:ok, Tool.error(reason)}
    end
  end
end
