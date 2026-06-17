defmodule FermixCore.Tools.RunJobNow do
  @moduledoc """
  Trigger an immediate, out-of-band run of a scheduled job.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Jobs.Scheduler
  alias FermixCore.Tools.JobRegistrySupport, as: Support

  @impl true
  def name, do: "run_job_now"

  @impl true
  def description do
    "Run a scheduled job immediately, out of band, without waiting for its next " <>
      "scheduled time. The run executes through the normal scheduled-job runner " <>
      "(same isolation, delivery, and confinement) and the job's timed cadence is " <>
      "left unchanged. Use this to test a job or fulfil an on-demand request."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["job_id"],
      properties: %{
        job_id: %{type: "string", description: "Scheduled job id to run now."}
      }
    }
  end

  @impl true
  def when_to_use do
    "Run a scheduled job right now (to test it or satisfy an immediate request) without disturbing its schedule."
  end

  @impl true
  def examples do
    [%{args: %{"job_id" => "weather_abc"}, note: "run a job once, immediately"}]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "missing_job_id", description: "job_id is absent or blank"},
      %{tag: "not_found", description: "job id does not exist"},
      %{tag: "not_runnable", description: "job is paused, disabled, or already completed"},
      %{tag: "expired", description: "job has passed its expiry"},
      %{tag: "already_running", description: "the job already has an active run"}
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
      scheduler = Map.get(context, :scheduler, Scheduler)

      case Scheduler.run_now(scheduler, job_id) do
        {:ok, run} -> Support.success_json(Support.job_run_summary(run))
        {:error, reason} -> Support.error(reason)
      end
    else
      {:error, reason} -> {:ok, Tool.error(reason)}
    end
  catch
    :exit, reason -> {:ok, Tool.error("scheduler_unavailable: #{inspect(reason)}")}
  end
end
