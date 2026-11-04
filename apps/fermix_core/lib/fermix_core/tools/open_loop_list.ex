defmodule FermixCore.Tools.OpenLoopList do
  @moduledoc """
  List the owner's open loops (MILESTONE_78 §07, §08, §18): what Fermix is
  keeping an eye on, with each loop's date stated absolutely, where and when
  the owner said it, its state, how many times it has been raised and its next
  check. Never a delivery destination. A loop noted after outside content has
  its words framed (`Registry.result_view/2`).

  Each loop also carries its `follow_ups` (MILESTONE_83 §07), newest first:
  when and how Fermix raised it, Fermix's own raise text (a check-in message's
  closing sentences, or those of the reply that raised it in conversation),
  and the owner's reply with its delay, or that none came, each text quoted as
  data (`OpenLoops.Reactions.follow_up/2`) and a raise made after outside
  content framed as such, so nothing the record holds is hidden from the
  owner, save what Fermix said on a turn that could see the owner's computer
  activity, which is listed only on a turn that may carry it
  (`ComputerHistory.RecentActivity.permitted?/1`). A dropped loop has none: a
  drop deletes them.

  A list that shows anything framed brings the turn or check-in run that
  called it an outside source (`UntrustedContent.outside_source/3`), as a due
  note that frames a loop does: what it shows may steer what the run does
  next. A list of clean loops and raises brings none.

  Read-only. Offered and run only while `[fermix_core.open_loops] enabled`, on
  the owner's attended turn in a private chat or inside a check-in run
  (`OpenLoops.Access.read?/1`); both halves of the gate ask the same question.

  Context seams: `:memory_repo` (the Repo) and `:now_fn` (the clock the
  follow-up record is read on).
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.ComputerHistory.RecentActivity
  alias FermixCore.Memory.Repo
  alias FermixCore.OpenLoops.Access
  alias FermixCore.OpenLoops.Config
  alias FermixCore.OpenLoops.Reactions
  alias FermixCore.OpenLoops.Registry
  alias FermixCore.Telemetry
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
        description:
          "the turn is neither the owner's attended top-level turn in a private chat nor a " <>
            "check-in run"
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
    {result, error} = gated(args, context)
    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    ToolTelemetry.exec(name(), context, success, duration,
      input: args,
      result: result,
      metadata: error
    )

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
      {:error, reason} -> refused(reason, Access.refusal(name(), reason))
    end
  end

  # A refusal is traced as the error it is (Opik's `error_info`): its tag, and
  # the sentence the model receives, which carries no owner words.
  defp refused(reason, sentence) do
    error = %{error_code: Registry.error_tag(reason), error_summary: Telemetry.preview(sentence)}
    {{:ok, Tool.error(sentence)}, error}
  end

  defp list(args, context) do
    repo = Map.get(context, :memory_repo, Repo)

    with {:ok, loops} <- Registry.list(Map.take(args, ["state"]), context, repo: repo),
         {:ok, follow_ups} <- follow_ups(context, repo) do
      {{:ok, Tool.success(Jason.encode!(%{"open_loops" => view(loops, follow_ups)}))}, %{}}
    else
      {:error, reason} -> refused(reason, Registry.describe_error(reason))
    end
  end

  defp follow_ups(context, repo) do
    owner_id = Map.get(context, :memory_owner_id, "default")
    activity_allowed = RecentActivity.permitted?(context)

    opts =
      [repo: repo, session_id: Map.get(context, :session_id), activity_allowed: activity_allowed] ++
        clock(context)

    Reactions.by_loop(owner_id, opts)
  end

  defp clock(%{now_fn: now_fn}) when is_function(now_fn, 0), do: [now: now_fn.()]
  defp clock(_context), do: []

  # A stamped loop's words are framed, as its due note frames them, and so is a
  # raise made after outside content; either makes the call bring its run an
  # outside source (`UntrustedContent.outside_source/3`).
  defp view(loops, follow_ups) do
    Enum.map(loops, fn loop ->
      reactions = Map.get(follow_ups, loop.id, [])

      loop
      |> Registry.result_view()
      |> Map.put("follow_ups", Enum.map(reactions, &Reactions.follow_up/1))
    end)
  end
end
