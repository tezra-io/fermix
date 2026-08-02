defmodule FermixCore.Tools.StopTrackingCodingRun do
  @moduledoc """
  Stop tracking an active Codex **cloud** run.

  The cloud surface has no cancel, so this abandons Fermix's tracking: it cancels
  the poll timer and finalizes the run `blocked/:tracking_stopped`, delivering the
  task URL. It never claims the vendor task itself stopped — the task keeps
  running on ChatGPT. Only applies to cloud runs; a local run is refused (use
  `cancel_coding_run`).
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Harness.Authorization
  alias FermixCore.Harness.Config
  alias FermixCore.Harness.Manager
  alias FermixCore.Tools.HarnessSupport, as: Support

  @impl true
  @spec name() :: String.t()
  def name, do: "stop_tracking_coding_run"

  @impl true
  @spec description() :: String.t()
  def description do
    "Stop tracking an active Codex cloud run (the vendor task keeps running on " <>
      "ChatGPT; there is no cancel on the cloud surface)."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["run_id"],
      properties: %{
        run_id: %{type: "string", description: "The cloud coding run id (hr_…) to stop tracking."}
      }
    }
  end

  @impl true
  def when_to_use do
    "To stop polling a Codex cloud run you no longer want tracked — it does NOT " <>
      "stop the vendor task, only Fermix's tracking of it."
  end

  @impl true
  def examples, do: [%{args: %{"run_id" => "hr_0123456789ab"}, note: "stop tracking a cloud run"}]

  @impl true
  def failure_modes do
    [
      %{tag: "not_authorized", description: "not an attended operator or allowlisted job"},
      %{tag: "not_found", description: "no run exists for that id"},
      %{tag: "not_cloud", description: "the run is a local run, not a cloud run"},
      %{tag: "already_terminal", description: "the cloud run has already finished"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :harness

  @doc """
  Advertise only when the harness is usable — `enabled` + `approved`, matching
  `codex_cloud_run`, whose runs this tool stops tracking (design §23.4), and only on
  a turn whose run could report back (`HarnessSupport.harness_deliverable?/1`). Still
  dispatchable by name, so a cloud task left tracking when consent was withdrawn
  can be released on request.
  """
  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context) do
    Config.enabled?() and Config.approved?() and
      Support.harness_deliverable?(context) and
      Authorization.authorize(name(), context) == :ok
  end

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), context, fn -> do_execute(args, context) end)
  end

  defp do_execute(args, context) do
    with :ok <- Authorization.authorize(name(), context),
         {:ok, run_id} <- Support.required_string(args, "run_id"),
         {:ok, task_url} <- Manager.stop_tracking(run_id, manager(context)) do
      Support.success_json(stopped_map(run_id, task_url))
    else
      {:error, reason} -> Support.error(reason)
    end
  end

  defp stopped_map(run_id, task_url) do
    %{
      run_id: run_id,
      status: "tracking_stopped",
      task_url: task_url,
      detail:
        "Stopped tracking this cloud run. The vendor task itself keeps running on " <>
          "ChatGPT — check it there."
    }
  end

  defp manager(context), do: Map.get(context, :harness_manager, Manager)
end
