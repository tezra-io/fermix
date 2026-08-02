defmodule FermixCore.Tools.GetCodingRun do
  @moduledoc """
  Fetch one coding-harness run in full: status, diagnostics tail, usage, artifact
  paths, and delivery state.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Harness.Authorization
  alias FermixCore.Harness.Config
  alias FermixCore.Harness.Ledger
  alias FermixCore.Tools.HarnessSupport, as: Support

  @impl true
  @spec name() :: String.t()
  def name, do: "get_coding_run"

  @impl true
  @spec description() :: String.t()
  def description, do: "Get a coding-harness run's full status, diagnostics, usage, and delivery."

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["run_id"],
      properties: %{
        run_id: %{type: "string", description: "The coding run id (hr_…)."}
      }
    }
  end

  @impl true
  def when_to_use, do: "To inspect a specific Codex / Claude Code run by its id."

  @impl true
  def examples, do: [%{args: %{"run_id" => "hr_0123456789ab"}, note: "inspect one run"}]

  @impl true
  def failure_modes do
    [
      %{tag: "not_authorized", description: "not an attended operator or allowlisted job"},
      %{tag: "not_found", description: "no run exists for that id"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :harness

  @doc """
  Advertise only when the harness is usable — `enabled` + `approved`, the same
  gate the run tools carry (design §23.4). An unusable harness advertises
  *nothing*: offering a run-inspection tool while the prompt drops the whole
  harness category leaves the model tools it has no framing for, and a run
  history it has no way to add to. The same holds for a turn whose run could not
  report back (`HarnessSupport.harness_deliverable?/1`). Still dispatchable by name,
  so a run recorded before consent was withdrawn stays readable on request.
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
         {:ok, row} <- Ledger.get(run_id, server: Support.repo(context)) do
      Support.success_json(Support.run_payload(row, Support.read_run_text(row)))
    else
      {:error, reason} -> Support.error(reason)
    end
  end
end
