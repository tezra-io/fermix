defmodule FermixCore.Tools.ListCodingRuns do
  @moduledoc """
  List coding-harness runs and their delivery state. Dead-letter runs (a terminal
  message that could never be delivered) are surfaced in their own group so the
  model raises them to the owner.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Harness.Authorization
  alias FermixCore.Harness.Config
  alias FermixCore.Harness.Ledger
  alias FermixCore.Tools.HarnessSupport, as: Support

  @impl true
  @spec name() :: String.t()
  def name, do: "list_coding_runs"

  @impl true
  @spec description() :: String.t()
  def description, do: "List coding-harness runs, their status, and delivery state."

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      properties: %{
        status: %{
          type: "string",
          description: "Optional status filter (e.g. running, completed, failed)."
        }
      }
    }
  end

  @impl true
  def when_to_use, do: "To check on active or recent Codex / Claude Code runs and their delivery."

  @impl true
  def examples, do: [%{args: %{}, note: "list all coding runs"}]

  @impl true
  def failure_modes do
    [
      %{tag: "not_authorized", description: "not an attended operator or allowlisted job"},
      %{tag: "ledger_failed", description: "the run ledger query failed"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :harness

  @doc """
  Advertise only when the harness is usable — `enabled` + `approved`, the same
  gate the run tools carry (design §23.4), so an unusable harness advertises
  nothing at all. Still dispatchable by name for reading history recorded before
  consent was withdrawn.
  """
  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context) do
    Config.enabled?() and Config.approved?() and
      Authorization.authorize(name(), context) == :ok
  end

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    Support.run(name(), context, fn -> do_execute(args, context) end)
  end

  defp do_execute(args, context) do
    case Authorization.authorize(name(), context) do
      :ok -> list_runs(args, context)
      {:error, reason} -> Support.error(reason)
    end
  end

  defp list_runs(args, context) do
    case Ledger.list(filters(args), server: Support.repo(context)) do
      {:ok, rows} -> Support.success_json(group(rows))
      {:error, reason} -> Support.error(reason)
    end
  end

  # `status` is a free-form ledger filter, so pass a present string straight
  # through and ignore anything else.
  defp filters(%{"status" => status}) when is_binary(status) and status != "",
    do: %{status: status}

  defp filters(_args), do: %{}

  defp group(rows) do
    {dead, live} = Enum.split_with(rows, &(Map.get(&1, :delivery_status) == "dead_letter"))

    %{
      runs: Enum.map(live, &Support.run_summary/1),
      dead_letter: Enum.map(dead, &Support.run_summary/1)
    }
  end
end
