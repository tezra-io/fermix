defmodule FermixCore.Tools.CancelCodingRun do
  @moduledoc """
  Cancel an active coding-harness run (owner intent → `cancelled`). An unknown id
  or an already-finished run is reported honestly. A Codex **cloud** run has no
  vendor cancel surface — cancelling one is refused with `vendor_cancel_unsupported`
  (carrying a `stop_tracking_coding_run` pointer and the task URL) and its polling
  continues; only `stop_tracking_coding_run` abandons a cloud run.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Harness.Authorization
  alias FermixCore.Harness.Config
  alias FermixCore.Harness.Manager
  alias FermixCore.Tools.HarnessSupport, as: Support

  @impl true
  @spec name() :: String.t()
  def name, do: "cancel_coding_run"

  @impl true
  @spec description() :: String.t()
  def description, do: "Cancel an active coding-harness run by its id."

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["run_id"],
      properties: %{
        run_id: %{type: "string", description: "The coding run id (hr_…) to cancel."}
      }
    }
  end

  @impl true
  def when_to_use, do: "To stop a Codex / Claude Code run that is still active."

  @impl true
  def examples, do: [%{args: %{"run_id" => "hr_0123456789ab"}, note: "cancel a run"}]

  @impl true
  def failure_modes do
    [
      %{tag: "not_authorized", description: "not an attended operator or allowlisted job"},
      %{tag: "not_found", description: "no run exists for that id"},
      %{tag: "already_terminal", description: "the run has already finished"},
      %{
        tag: "vendor_cancel_unsupported",
        description:
          "the run is a Codex cloud run (no vendor cancel exists) — polling continues; " <>
            "use stop_tracking_coding_run to abandon tracking"
      }
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :harness

  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context) do
    Config.enabled?() and Authorization.authorize(name(), context) == :ok
  end

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), context, fn -> do_execute(args, context) end)
  end

  defp do_execute(args, context) do
    with :ok <- Authorization.authorize(name(), context),
         {:ok, run_id} <- Support.required_string(args, "run_id"),
         :ok <- Manager.cancel(run_id, :owner, manager(context)) do
      Support.success_json(%{run_id: run_id, status: "cancelling"})
    else
      {:error, reason} -> Support.error(reason)
    end
  end

  defp manager(context), do: Map.get(context, :harness_manager, Manager)
end
