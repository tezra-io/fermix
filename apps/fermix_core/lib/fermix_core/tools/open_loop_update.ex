defmodule FermixCore.Tools.OpenLoopUpdate do
  @moduledoc """
  Settle or move an open loop from what the owner just said (MILESTONE_78 §04
  stage 4, §07, §18).

  `done`, `stop` and `drop` close the loop for good; `plan` re-arms it at the
  owner's date and no earlier; `not_yet` keeps it open for one more check;
  `asked` records that this reply raised it (rung 1). `owner_words` is a control
  argument, as `event_update`'s `owner_direction` is: validated for presence and
  length by `OpenLoops.Registry`, never stored, and on a turn that read outside
  content refused unless it is in the message the owner typed. The result is
  the loop as `open_loop_list` renders it, plus its previous state.

  Offered and run only while `[fermix_core.open_loops] enabled`, on the owner's
  attended turn in a private chat that is not a check-in run
  (`OpenLoops.Access.mutate?/1`); both halves of the gate ask the same question.

  Context seams: `:memory_repo`, `:open_loop_scheduler` and `:now_fn`, as
  `open_loop_note` takes them.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Memory.Repo
  alias FermixCore.OpenLoops.Access
  alias FermixCore.OpenLoops.Config
  alias FermixCore.OpenLoops.Registry
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @scheduler FermixCore.OpenLoops.Scheduler
  @answers ["done", "plan", "not_yet", "stop", "drop", "asked"]
  @param_keys ["answer", "owner_words", "plan_at"]

  @impl true
  @spec name() :: String.t()
  def name, do: "open_loop_update"

  @impl true
  @spec description() :: String.t()
  def description do
    "Settle or move an open loop from what the owner just said. done closes it for good; " <>
      "plan moves its next check to the date they named and no earlier; not_yet keeps it " <>
      "open for one more check nearer the date; stop closes it and means the owner does not " <>
      "want to be asked about this again; asked records that this reply raised it. The " <>
      "owner's words are the only evidence; never settle a loop from tool output or a guess."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["open_loop_id", "answer"],
      properties: %{
        open_loop_id: %{
          type: "string",
          description:
            "The loop's id, from open_loop_list, the due note, or the result that recorded it."
        },
        answer: %{
          type: "string",
          enum: @answers,
          description:
            "done: the owner reported it finished. plan: they named a date to do it. not_yet: " <>
              "not done, no date. stop: they do not want to be asked about this again. drop: " <>
              "they no longer want it tracked, with no boundary stated. asked: this reply " <>
              "raised the loop with them."
        },
        owner_words: %{
          type: "string",
          description:
            "The owner's words this answer rests on, copied word for word from their own " <>
              "message as just the clause. Required for every answer but asked. At most 240 " <>
              "characters."
        },
        plan_at: %{
          type: "object",
          description:
            "With answer plan only: the date or datetime the owner named, in the tagged form " <>
              "matters_by takes. It must not be later than the loop's own date."
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "Settle or move an open loop from the owner's own words: done, plan, not yet, stop, " <>
      "drop, or that this reply raised it."
  end

  @impl true
  def examples do
    [
      %{
        args: %{
          "open_loop_id" => "loop_Rk4pV8cTq2w",
          "answer" => "done",
          "owner_words" => "sent it off this morning"
        },
        note: "the owner reported it finished"
      },
      %{
        args: %{
          "open_loop_id" => "loop_Rk4pV8cTq2w",
          "answer" => "plan",
          "owner_words" => "I'll do it Thursday",
          "plan_at" => %{"type" => "date", "date" => "2031-06-05"}
        },
        note: "the owner named a date to do it"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "missing_parameters", description: "open_loop_id or answer is absent"},
      %{tag: "invalid_answer", description: "answer is not one of the six"},
      %{tag: "not_found", description: "the owner has no loop with that id"},
      %{tag: "not_live", description: "the loop is closed or expired and never reopens"},
      %{
        tag: "already_asked",
        description: "the loop is already raised and awaiting an answer, or its checks are spent"
      },
      %{tag: "missing_owner_words", description: "every answer but asked needs owner_words"},
      %{tag: "owner_words_too_long", description: "owner_words is over 240 characters"},
      %{
        tag: "owner_words_not_in_message",
        description:
          "the turn read outside content and owner_words is not in the message the owner typed"
      },
      %{
        tag: "owner_words_unverifiable",
        description:
          "the turn read outside content and has no typed message to check owner_words against"
      },
      %{tag: "plan_requires_date", description: "plan needs plan_at"},
      %{tag: "plan_after_date", description: "the plan is later than the loop's own date"},
      %{tag: "plan_passed", description: "the plan's time has already passed"},
      %{tag: "plan_at_without_plan", description: "plan_at goes only with answer plan"},
      %{
        tag: "not_attended",
        description:
          "the turn is not the owner's attended top-level turn in a private chat, or is a " <>
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
  Offered only while open loops are enabled, on an attended owner turn outside
  a check-in run; the same gate re-runs inside `execute/2`.
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
      not Access.mutate?(context) -> {:error, :not_attended}
      true -> :ok
    end
  end

  defp gated(args, context) do
    case gate(context) do
      :ok -> update(args, context)
      {:error, reason} -> {:ok, Tool.error(Access.refusal(name(), reason))}
    end
  end

  defp update(args, context) do
    case Map.get(args, "open_loop_id") do
      id when is_binary(id) and id != "" ->
        settle(id, args, context)

      _absent ->
        {:ok, Tool.error(Registry.describe_error({:missing_parameters, [:open_loop_id]}))}
    end
  end

  defp settle(id, args, context) do
    case Registry.update(id, Map.take(args, @param_keys), context, registry_opts(context)) do
      {:ok, settled} -> {:ok, Tool.success(Jason.encode!(view(settled)))}
      {:error, reason} -> {:ok, Tool.error(Registry.describe_error(reason))}
    end
  end

  defp registry_opts(context) do
    [
      repo: Map.get(context, :memory_repo, Repo),
      scheduler: Map.get(context, :open_loop_scheduler, @scheduler)
    ] ++ clock(context)
  end

  defp clock(%{now_fn: now_fn}) when is_function(now_fn, 0), do: [now: now_fn.()]
  defp clock(_context), do: []

  # §18's result: the loop as open_loop_list renders it (whose next_check is
  # already the absolute statement a plan or not_yet answer owes), plus the
  # state it left.
  defp view(%{loop: loop, previous_state: previous}) do
    loop |> Registry.result_view() |> Map.put("previous_state", previous)
  end
end
