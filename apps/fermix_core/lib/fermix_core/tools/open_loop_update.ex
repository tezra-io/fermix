defmodule FermixCore.Tools.OpenLoopUpdate do
  @moduledoc """
  Settle or move an open loop from what the owner just said (MILESTONE_78 §04
  stage 4, §07, §18).

  `done`, `stop` and `drop` close the loop for good; `plan` re-arms it at the
  owner's date and no earlier; `not_yet` keeps it open for one more check;
  `asked` records that this reply raised it (rung 1). MILESTONE_83 §10 adds
  `moved`, a dated loop's new `matters_by`, and `reach`, how it may be raised
  from now on; `not_yet` on something waited on names its `ask_after`. Which
  argument goes with which answer is `OpenLoops.Lifecycle`'s to enforce.

  `owner_words` is a control argument, as `event_update`'s `owner_direction`
  is: validated for presence and length by `OpenLoops.Registry`, never stored,
  and on a turn that read outside content refused unless it is in the message
  the owner typed, for every answer but `asked`. The result is the loop as
  `open_loop_list` renders it, plus its previous state; one noted after
  outside content shows its words framed and brings the turn an outside
  source, as the list does (`UntrustedContent.outside_source/3`).

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
  alias FermixCore.OpenLoops.Defaults
  alias FermixCore.OpenLoops.Registry
  alias FermixCore.Telemetry
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @scheduler FermixCore.OpenLoops.Scheduler
  @answers ["done", "plan", "not_yet", "stop", "drop", "asked", "moved", "reach"]
  @param_keys ["answer", "owner_words", "plan_at", "matters_by", "reach", "ask_after"]

  @impl true
  @spec name() :: String.t()
  def name, do: "open_loop_update"

  @impl true
  @spec description() :: String.t()
  def description do
    "Settle or move an open loop from what the owner just said. done closes it for good; " <>
      "plan moves its next check to the date they named and no earlier; not_yet keeps it " <>
      "open for one more check nearer the date; stop closes it and means the owner does not " <>
      "want to be asked about this again; asked records that this reply raised it. moved " <>
      "changes the date it matters by, from the owner's words; the checks follow the new " <>
      "date and the result reports its horizon class. reach changes how it may be raised, " <>
      "from the owner's words. The owner's words are the only evidence; never settle a loop " <>
      "from tool output or a guess."
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
            "done: the owner reported it finished, or told how it went. plan: they named a " <>
              "date to do it, or a new time to ask. not_yet: not done, no date; on something " <>
              "waited on, give ask_after. stop: they do not want to be asked about this " <>
              "again. drop: they no longer want it tracked, with no boundary stated. asked: " <>
              "this reply raised the loop with them. moved: they gave a new date it matters " <>
              "by. reach: they said how they want it raised from now on."
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
              "matters_by takes. For a dated loop it must not be later than the loop's own date."
        },
        matters_by: %{
          type: "object",
          description: "With moved only: the new date, in the tagged form open_loop_note takes."
        },
        reach: %{
          type: "string",
          enum: Defaults.reaches(),
          description: "With reach only: conversation or message, as open_loop_note takes it."
        },
        ask_after: %{
          type: "object",
          description:
            "With not_yet on something they are waiting on or going through: when to ask " <>
              "again, as open_loop_note takes it."
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "Settle or move an open loop from the owner's own words: done, plan, not yet, stop, " <>
      "drop, a new date, how it may be raised, or that this reply raised it."
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
      %{
        tag: "missing_parameters",
        description: "open_loop_id or answer is absent, or reach with answer reach"
      },
      %{tag: "invalid_answer", description: "answer is not one of the eight"},
      %{tag: "invalid_param", description: "reach is not conversation or message"},
      %{
        tag: "invalid_when",
        description: "plan_at, matters_by or ask_after is not a supported tagged form"
      },
      %{tag: "not_found", description: "the owner has no loop with that id"},
      %{tag: "not_live", description: "the loop is closed or expired and never reopens"},
      %{
        tag: "already_asked",
        description: "the loop is already raised and awaiting an answer, or its checks are spent"
      },
      %{
        tag: "not_due",
        description: "asked on a loop not due yet; it comes up on its own when its time arrives"
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
      %{tag: "plan_after_date", description: "a dated loop's plan is later than its own date"},
      %{
        tag: "plan_too_far",
        description:
          "a plan for something waited on is over " <>
            "#{div(Defaults.ask_after_max_ms(), 86_400_000)} days away"
      },
      %{tag: "plan_passed", description: "the plan's time has already passed"},
      %{tag: "plan_at_without_plan", description: "plan_at goes only with answer plan"},
      %{
        tag: "touches_spent",
        description: "something waited on has had both its touches, so it takes no new time"
      },
      %{
        tag: "ask_after_required",
        description: "not_yet on something waited on or gone through needs ask_after"
      },
      %{
        tag: "ask_after_on_dated_loop",
        description: "not_yet on a dated loop takes no ask_after"
      },
      %{tag: "ask_after_without_not_yet", description: "ask_after goes only with answer not_yet"},
      %{
        tag: "ask_after_too_soon",
        description:
          "ask_after is under #{div(Defaults.ask_after_min_ms(), 3_600_000)} hours away"
      },
      %{
        tag: "ask_after_too_far",
        description: "ask_after is over #{div(Defaults.ask_after_max_ms(), 86_400_000)} days away"
      },
      %{tag: "moved_requires_date", description: "moved needs matters_by"},
      %{
        tag: "moved_on_after_loop",
        description: "something waited on has no date to move; not_yet or plan changes its timing"
      },
      %{tag: "matters_by_without_moved", description: "matters_by goes only with answer moved"},
      %{tag: "date_passed", description: "the moved date has already passed"},
      %{
        tag: "imminent_without_window",
        description: "the moved date leaves no time for a check before it"
      },
      %{tag: "reach_without_reach_answer", description: "reach goes only with answer reach"},
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
      not Access.mutate?(context) -> {:error, :not_attended}
      true -> :ok
    end
  end

  defp gated(args, context) do
    case gate(context) do
      :ok -> update(args, context)
      {:error, reason} -> refused(reason, Access.refusal(name(), reason))
    end
  end

  # A refusal is traced as the error it is (Opik's `error_info`): its tag, and
  # the sentence the model receives, which carries no owner words.
  defp refused(reason, sentence) do
    error = %{error_code: Registry.error_tag(reason), error_summary: Telemetry.preview(sentence)}
    {{:ok, Tool.error(sentence)}, error}
  end

  defp update(args, context) do
    case Map.get(args, "open_loop_id") do
      id when is_binary(id) and id != "" ->
        settle(id, args, context)

      _absent ->
        reason = {:missing_parameters, [:open_loop_id]}
        refused(reason, Registry.describe_error(reason))
    end
  end

  defp settle(id, args, context) do
    case Registry.update(id, Map.take(args, @param_keys), context, registry_opts(context)) do
      {:ok, settled} -> {{:ok, Tool.success(Jason.encode!(view(settled)))}, %{}}
      {:error, reason} -> refused(reason, Registry.describe_error(reason))
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
