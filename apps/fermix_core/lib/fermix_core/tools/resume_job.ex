defmodule FermixCore.Tools.ResumeJob do
  @moduledoc """
  Resume a paused scheduled job.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Jobs.Registry
  alias FermixCore.Tools.JobRegistrySupport, as: Support

  @impl true
  def name, do: "resume_job"

  @impl true
  def description, do: "Resume a paused scheduled job."

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["job_id"],
      properties: %{job_id: %{type: "string", description: "Scheduled job id."}}
    }
  end

  @impl true
  def when_to_use, do: "Resume a paused Fermix scheduled job."

  @impl true
  def examples, do: [%{args: %{"job_id" => "job_123"}, note: "resume one paused job"}]

  @impl true
  def failure_modes do
    [
      %{tag: "missing_job_id", description: "job_id is absent or blank"},
      %{tag: "not_found", description: "job id does not exist"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :scheduling

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), context, fn -> do_execute(args, context) end)
  end

  defp do_execute(args, context) do
    with {:ok, job_id} <- Support.required_string(args, "job_id") do
      case Registry.resume_job(job_id, repo: Support.repo(context)) do
        {:ok, job} -> Support.success_json(Support.job_payload(job))
        {:error, reason} -> Support.error(reason)
      end
    else
      {:error, reason} -> {:ok, Tool.error(reason)}
    end
  end
end
