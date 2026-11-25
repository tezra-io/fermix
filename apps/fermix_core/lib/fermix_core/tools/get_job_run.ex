defmodule FermixCore.Tools.GetJobRun do
  @moduledoc """
  Fetch the full record of a single scheduled-job run.

  A run a heal took carries the heal's note as `heal_note`, inside the
  outside-content frame (source `job_heal_note`, M106 §9): a model wrote it
  after reading the failure's words, so it reaches the main agent only here,
  a tool whose every call counts as an outside source for its turn
  (`Capabilities.UntrustedContent.outside_source/1`). `list_jobs` says only
  that a note exists.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Capabilities.UntrustedContent
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
        {:ok, run} -> present_own(run, context)
        {:error, reason} -> Support.error(reason)
      end
    else
      {:error, reason} -> {:ok, Tool.error(reason)}
    end
  end

  # Inside a heal run, only a run of the heal's own job (M106 §5.5).
  defp present_own(run, context) do
    case Support.check_heal_job(run.job_id, context) do
      :ok -> present(run, context)
      {:error, sentence} -> {:ok, Tool.error(sentence)}
    end
  end

  # A cue run's reply, error and prompt are held back off an attended owner
  # turn and framed on one (M60 §9.3).
  defp present(run, context) do
    pairs = [{Support.job_run_payload(run), run}]

    with {:ok, [payload]} <- CueRun.present_runs(pairs, context, repo: Support.repo(context)),
         {:ok, note} <-
           Repo.job_heals_call({:note_for_run, run.id}, server: Support.repo(context)) do
      payload |> put_heal_note(note) |> Support.success_json()
    else
      {:error, reason} -> Support.error(reason)
    end
  end

  defp put_heal_note(payload, nil), do: payload

  defp put_heal_note(payload, note),
    do: Map.put(payload, :heal_note, UntrustedContent.frame("job_heal_note", note))
end
