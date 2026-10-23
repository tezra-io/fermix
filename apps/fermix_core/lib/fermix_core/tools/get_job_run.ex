defmodule FermixCore.Tools.GetJobRun do
  @moduledoc """
  Fetch the full record of a single scheduled-job run.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Jobs.CueRun
  alias FermixCore.Memory.Repo
  alias FermixCore.Tools.JobRegistrySupport, as: Support

  @impl true
  def name, do: "get_job_run"

  @impl true
  def description do
    "Fetch one scheduled-job run in full: status, trigger, timing, the prompt " <>
      "snapshot it executed, token usage, output reference, final response, and " <>
      "any error. Use this to inspect a specific run found via list_job_runs."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["run_id"],
      properties: %{
        run_id: %{type: "string", description: "Job run id to fetch."}
      }
    }
  end

  @impl true
  def when_to_use do
    "Read a single scheduled-job run in detail after locating it with list_job_runs."
  end

  @impl true
  def examples do
    [%{args: %{"run_id" => "run_abc123"}, note: "inspect one run's prompt and outcome"}]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "missing_run_id", description: "run_id is absent or blank"},
      %{tag: "not_found", description: "run id does not exist"}
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
    with {:ok, run_id} <- Support.required_string(args, "run_id") do
      case Repo.get_job_run(run_id, server: Support.repo(context)) do
        {:ok, run} -> present(run, context)
        {:error, reason} -> Support.error(reason)
      end
    else
      {:error, reason} -> {:ok, Tool.error(reason)}
    end
  end

  # A cue run's reply, error and prompt are held back off an attended owner
  # turn and framed on one (M60 §9.3).
  defp present(run, context) do
    pairs = [{Support.job_run_payload(run), run}]

    case CueRun.present_runs(pairs, context, repo: Support.repo(context)) do
      {:ok, [payload]} -> Support.success_json(payload)
      {:error, reason} -> Support.error(reason)
    end
  end
end
