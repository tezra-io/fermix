defmodule FermixCore.Tools.OpenLoopNote do
  @moduledoc """
  Record an open loop (MILESTONE_78 §04 stage 1, §07, §18): an intention the
  owner stated, with the date by which it matters, that they have not reported
  closing. MILESTONE_83 §10 widens it to anything in the owner's own life worth
  following up: something waited on or gone through takes `ask_after` in place
  of `matters_by`, every loop takes the `reach` it may be raised by, and a
  confirmed looked-up date is marked `matters_by_source: "lookup"`.

  The model supplies the owner's words, one timing in the tagged date form, the
  reach and what makes it matter; `OpenLoops.Registry` owns the clock, the zone,
  the dedupe identity and the delivery snapshot. The result is what was stored,
  its anchor stated absolutely under the timing's own name, its reach, its first
  check and the delivery platform, never a destination. A restated loop comes
  back as stored, its words framed when it was noted after outside content,
  which brings the turn an outside source, as the list does
  (`UntrustedContent.outside_source/3`). Capture is silent, so the
  description tells the model to say nothing about it.

  Offered and run only while `[fermix_core.open_loops] enabled`, on the owner's
  attended turn in a private chat that is not a check-in run
  (`OpenLoops.Access.mutate?/1`); both halves of the gate ask the same question.
  What that turn had read is stamped on the loop (`OpenLoops.Registry`).

  Context seams: `:memory_repo` (the Repo), `:open_loop_scheduler` (the
  scheduler a new loop signals; nil signals none) and `:now_fn` (the clock),
  each defaulting to the production value.
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
  @param_keys [
    "intention",
    "why_it_matters",
    "matters_by",
    "ask_after",
    "reach",
    "matters_by_source",
    "timezone"
  ]

  @impl true
  @spec name() :: String.t()
  def name, do: "open_loop_note"

  @impl true
  @spec description() :: String.t()
  def description do
    "Record an open loop: something in the owner's own life, in their words, that they " <>
      "would want Fermix to follow up on. Give matters_by for what they mean to do or decide " <>
      "by a date, which Fermix raises before then; give ask_after for what they are waiting " <>
      "on or going through, which Fermix asks about once, afterwards. reach says whether it " <>
      "may come up only in a conversation the owner starts, or Fermix may also message them " <>
      "about it. Never record one from a guest or a group chat, never one Fermix itself " <>
      "owns, and never a date from tool output or fetched content the owner has not " <>
      "confirmed; mark a confirmed looked-up date as a lookup. Unless the owner asked to be " <>
      "reminded, the loop is the only record: store no reminder beside it, except when the " <>
      "result reports the loop imminent, since an imminent loop is never raised by message. " <>
      "One loop per thing; the same thing told again returns the existing loop. Say nothing " <>
      "about the loop unless asked."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["intention", "reach"],
      properties: %{
        intention: %{
          type: "string",
          description:
            "What the owner said, in their own words: what they mean to do or decide, or what " <>
              "they are waiting on or going through. At most 500 characters."
        },
        why_it_matters: %{
          type: "string",
          description:
            "One clause on the stakes as the owner stated them. Leave it out when they stated " <>
              "none. At most 300 characters."
        },
        matters_by: %{
          type: "object",
          description:
            ~s(One tagged time form, as event_store takes it: {"type":"date","date":"YYYY-MM-DD"}, ) <>
              ~s({"type":"datetime","date":"YYYY-MM-DD","time":"HH:MM:SS"} with an optional ) <>
              ~s("utc_offset", or {"type":"relative","amount":2,"unit":"days"|"weeks"}. A loop ) <>
              "is dated, so minutes, hours and yearly forms are refused. Give exactly one of " <>
              "matters_by and ask_after."
        },
        ask_after: %{
          type: "object",
          description:
            "For what they are waiting on or going through: when asking would first feel " <>
              "natural, in the tagged form matters_by takes, from a few hours to a year out; " <>
              "a date alone means after that day ends. Give exactly one of matters_by and " <>
              "ask_after."
        },
        reach: %{
          type: "string",
          enum: Defaults.reaches(),
          description:
            "conversation: raise it only inside a conversation the owner starts. message: " <>
              "Fermix may also send them one message about it."
        },
        matters_by_source: %{
          type: "string",
          enum: ["owner", "lookup"],
          description:
            "lookup when the date came from a lookup the owner asked for and then confirmed; " <>
              "otherwise owner, the default."
        },
        timezone: %{
          type: "string",
          description:
            "IANA zone, only when the owner named one. Otherwise the tool reads the configured " <>
              "personalization timezone itself."
        }
      }
    }
  end

  @impl true
  def when_to_use do
    "Record, silently, something in the owner's own life to follow up: what they mean to do " <>
      "by a date, or what they are waiting on or going through."
  end

  @impl true
  def examples do
    [
      %{
        args: %{
          "intention" => "send the Larkspur grant report",
          "matters_by" => %{"type" => "date", "date" => "2031-06-10"},
          "reach" => "message"
        },
        note: "a date-only intention Fermix may message about"
      },
      %{
        args: %{
          "intention" => "decide on the Halvorsen offer",
          "why_it_matters" => "the offer lapses after that",
          "matters_by" => %{"type" => "relative", "amount" => 2, "unit" => "weeks"},
          "reach" => "conversation"
        },
        note: "a relative date with the stakes the owner stated, raised only in conversation"
      },
      %{
        args: %{
          "intention" => "hear back from the Tamsworth clinic about the scan",
          "ask_after" => %{"type" => "date", "date" => "2031-06-12"},
          "reach" => "message"
        },
        note: "something the owner is waiting on, asked about once after that day ends"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "missing_parameters", description: "intention or reach is absent"},
      %{tag: "missing_when", description: "neither matters_by nor ask_after is given"},
      %{tag: "both_whens", description: "both matters_by and ask_after are given"},
      %{tag: "too_long", description: "intention or why_it_matters is over its bound"},
      %{
        tag: "invalid_param",
        description: "reach or matters_by_source is not one of its values"
      },
      %{
        tag: "invalid_when",
        description: "matters_by or ask_after is not a supported tagged form"
      },
      %{tag: "not_dated", description: "a timer or yearly form; a loop needs a calendar date"},
      %{tag: "date_passed", description: "the date has already passed"},
      %{
        tag: "ask_after_too_soon",
        description:
          "ask_after is under #{div(Defaults.ask_after_min_ms(), 3_600_000)} hours away"
      },
      %{
        tag: "ask_after_too_far",
        description: "ask_after is over #{div(Defaults.ask_after_max_ms(), 86_400_000)} days away"
      },
      %{
        tag: "source_without_matters_by",
        description: "matters_by_source is given with ask_after"
      },
      %{
        tag: "kind_conflict",
        description:
          "a live loop already holds the same thing in the other timing; nothing is recorded"
      },
      %{tag: "timezone_not_configured", description: "no zone is configured and none named"},
      %{
        tag: "no_target",
        description:
          "the owner has no chat inbox; a notification-only target counts as none, and " <>
            "nothing is stored"
      },
      %{tag: "too_many_loops", description: "the owner already has 20 live loops"},
      %{tag: "no_conversation", description: "the turn has no conversation to record against"},
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
      :ok -> note(args, context)
      {:error, reason} -> refused(reason, Access.refusal(name(), reason))
    end
  end

  # A refusal is traced as the error it is (Opik's `error_info`): its tag, and
  # the sentence the model receives, which carries no owner words.
  defp refused(reason, sentence) do
    error = %{error_code: Registry.error_tag(reason), error_summary: Telemetry.preview(sentence)}
    {{:ok, Tool.error(sentence)}, error}
  end

  defp note(args, context) do
    case Registry.note(Map.take(args, @param_keys), context, registry_opts(context)) do
      {:ok, noted} -> {{:ok, Tool.success(Jason.encode!(view(noted)))}, %{}}
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

  # §18's result: what was stored, stated absolutely, and the platform the
  # check-in will use, never the destination it was snapshotted to. The anchor
  # goes under the timing the loop has, as `open_loop_list` shows it.
  defp view(%{loop: loop} = noted) do
    %{
      "open_loop_id" => loop.id,
      "status" => Atom.to_string(noted.status),
      "intention" => intention(noted.status, loop),
      "horizon_class" => loop.horizon_class,
      "reach" => loop.reach,
      "first_check" => noted.first_check,
      "delivery" => noted.delivery,
      "live_loops" => noted.live_loops
    }
    |> Map.merge(anchor_view(loop, noted.stated_as))
  end

  # A created loop's words are the ones this call just gave. A restated one comes
  # back as stored, framed when it was noted after outside content, as the list
  # shows it.
  defp intention(:created, loop), do: loop.intention
  defp intention(:existing, loop), do: Registry.result_view(loop)["intention"]

  defp anchor_view(%{anchor_kind: "ask_after"}, stated_as), do: %{"ask_after" => stated_as}

  defp anchor_view(loop, stated_as),
    do: %{"matters_by" => stated_as, "matters_by_source" => loop.matters_by_source}
end
