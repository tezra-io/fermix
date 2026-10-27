defmodule FermixCore.Tools.OpenLoopList do
  @moduledoc """
  List the owner's open loops (MILESTONE_78 §07, §08, §18): what Fermix is
  keeping an eye on, with each loop's date stated absolutely, where and when
  the owner said it, its state, how many times it has been raised and its next
  check. Never a delivery destination, never a check-in's message text.

  Read-only. Offered and run only while `[fermix_core.open_loops] enabled`, on
  an attended owner turn or inside a check-in run (`OpenLoops.Access.read?/1`);
  both halves of the gate ask the same question.

  Context seam: `:memory_repo` (the Repo).
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Memory.Repo
  alias FermixCore.OpenLoops.Access
  alias FermixCore.OpenLoops.Config
  alias FermixCore.OpenLoops.Registry
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @impl true
  @spec name() :: String.t()
  def name, do: "open_loop_list"

  @impl true
  @spec description() :: String.t()
  def description do
    "List the open loops Fermix is keeping an eye on for the owner, with their dates and how " <>
      "many times each has been raised. Read-only: the owner drops one in their own words and " <>
      "you settle it with open_loop_update."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      properties: %{
        state: %{
          type: "string",
          enum: ["live", "closed", "any"],
          description:
            "Defaults to live: loops that are open, due, or asked and awaiting an answer. " <>
              "closed adds the last 25 settled or expired loops."
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "List the open loops Fermix is keeping an eye on for the owner."
  end

  @impl true
  def examples do
    [
      %{args: %{}, note: "the owner's live loops"},
      %{args: %{"state" => "closed"}, note: "the recently settled or expired loops"}
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "invalid_param", description: "state is not live, closed or any"},
      %{
        tag: "not_attended",
        description: "the turn is neither an attended top-level owner turn nor a check-in run"
      },
      %{tag: "disabled", description: "open loops are turned off on this install"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :scheduling

  @doc """
  Offered only while open loops are enabled, on an attended owner turn or
  inside a check-in run; the same gate re-runs inside `execute/2`.
  """
  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context), do: gate(context) == :ok

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    start = System.monotonic_time(:millisecond)
    result = gated(args, context)
    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    ToolTelemetry.exec(name(), context, success, duration, input: args, result: result)
    result
  end

  defp gate(context) do
    cond do
      not Config.enabled?() -> {:error, :disabled}
      not Access.read?(context) -> {:error, :not_readable}
      true -> :ok
    end
  end

  defp gated(args, context) do
    case gate(context) do
      :ok -> list(args, context)
      {:error, reason} -> {:ok, Tool.error(Access.refusal(name(), reason))}
    end
  end

  defp list(args, context) do
    opts = [repo: Map.get(context, :memory_repo, Repo)]

    case Registry.list(Map.take(args, ["state"]), context, opts) do
      {:ok, loops} -> {:ok, Tool.success(Jason.encode!(%{"open_loops" => view(loops)}))}
      {:error, reason} -> {:ok, Tool.error(Registry.describe_error(reason))}
    end
  end

  defp view(loops), do: Enum.map(loops, &Registry.view/1)
end
