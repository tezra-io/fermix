defmodule FermixCore.Tools.JobHealRespond do
  @moduledoc """
  A heal run's only exit (M106 §5.5): one decision about the failed job and a
  short note for the owner.

  The heal run's loop context carries `job_heal: %{id, job_id, reply_to,
  ref}` (`Jobs.HealDiagnosis.loop_context/1`), and that key is the whole
  gate: this tool is offered and runs only where it is present, and no other
  run's context carries it.

  `execute/2` checks the decision's shape only, then sends

      {:job_heal_respond, ref, %{decision: :rerun | :raise_limit | :pause | :propose | :tell,
                                 note: String.t(),
                                 timeout_seconds: pos_integer() | nil,
                                 change: map() | nil}}

  to `reply_to` and tells the model the run ends here. It changes nothing
  itself: whether a decision is carried out, and how, is code's, in the heal
  run after its loop has ended (`Jobs.HealDecision`). A note is at most 500
  characters and a longer one is refused, never cut. A proposed
  `change` names only `update_job`'s own fields for what a job does, where
  it reports and how long it may run: never its tools, and never its removal.
  Every accepted call is sent: keeping the first decision and ignoring a
  later one is the heal run's, which owns the run.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Telemetry
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @decisions %{
    "rerun" => :rerun,
    "raise_limit" => :raise_limit,
    "pause" => :pause,
    "propose" => :propose,
    "tell" => :tell
  }
  @note_max 500
  @text_fields ~w(task schedule skill_name provider model delivery_mode)
  @change_fields @text_fields ++ ~w(timeout_seconds clear_route_pin delivery_target)

  @type decision :: %{
          decision: :rerun | :raise_limit | :pause | :propose | :tell,
          note: String.t(),
          timeout_seconds: pos_integer() | nil,
          change: map() | nil
        }

  @impl true
  @spec name() :: String.t()
  def name, do: "job_heal_respond"

  @impl true
  @spec description() :: String.t()
  def description do
    "Report this heal run's one decision about the failed job, with a short note for the " <>
      "owner. rerun runs the job once more; raise_limit, with timeout_seconds, gives each " <>
      "run more time; pause stops it until the owner resumes it; propose, with change, " <>
      "states the exact edit for the owner to consider and applies nothing; tell changes " <>
      "nothing. Fermix checks the decision and carries it out itself. Exactly one call ends " <>
      "the run."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["decision", "note"],
      properties: %{
        decision: %{type: "string", enum: Map.keys(@decisions)},
        note: %{
          type: "string",
          description:
            "For the owner, in plain sentences: what failed and what would have to change. " <>
              "At most #{@note_max} characters; a longer note is refused, not cut."
        },
        timeout_seconds: %{
          type: "integer",
          minimum: 1,
          description: "With raise_limit: the new time limit for each run, in seconds."
        },
        change: %{
          type: "object",
          description:
            "With propose: the exact edit, in update_job's field names. Only what is to change.",
          properties: %{
            task: %{type: "string"},
            schedule: %{type: "string"},
            skill_name: %{type: "string"},
            timeout_seconds: %{type: "integer", minimum: 1},
            provider: %{type: "string"},
            model: %{type: "string"},
            clear_route_pin: %{type: "boolean"},
            delivery_mode: %{type: "string", enum: ["none", "origin", "channel", "local"]},
            delivery_target: %{type: "object"}
          }
        }
      }
    }
  end

  @impl true
  def when_to_use, do: "End a job's heal run with its one decision."

  @impl true
  def examples do
    [%{args: %{"decision" => "tell", "note" => "..."}, note: "nothing Fermix can change"}]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "invalid_decision", description: "decision is not one of the five"},
      %{tag: "missing_note", description: "the note for the owner is absent or blank"},
      %{tag: "note_too_long", description: "the note is over #{@note_max} characters; never cut"},
      %{tag: "missing_limit", description: "raise_limit needs a positive timeout_seconds"},
      %{tag: "missing_change", description: "propose needs a change naming at least one field"},
      %{tag: "invalid_change", description: "a change names another field or a wrong value"},
      %{tag: "not_heal_run", description: "the turn is not a job's heal run"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :scheduling

  @doc "Whether `context` is a heal run's, the one place the tool is offered."
  @spec advertise?(map()) :: boolean()
  def advertise?(context) when is_map(context), do: Map.has_key?(context, :job_heal)

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

  defp gated(args, context) do
    if advertise?(context),
      do: respond(args, context),
      else: refused(:not_heal_run, not_heal_run())
  end

  defp not_heal_run do
    "#{name()} is available only inside a job's heal run, as its one way to report a " <>
      "decision; no other turn can use it."
  end

  # A refusal is traced as the error it is: its tag, and the sentence the
  # model receives.
  defp refused(reason, sentence) do
    error = %{error_code: tag(reason), error_summary: Telemetry.preview(sentence)}
    {{:ok, Tool.error(sentence)}, error}
  end

  defp respond(args, context) do
    case decision(args) do
      {:ok, decision} ->
        :ok = report(context, decision)
        {{:ok, Tool.success(ended(decision))}, %{}}

      {:error, reason} ->
        refused(reason, describe_error(reason))
    end
  end

  # The one side effect: the decision goes to the heal run that owns the run.
  # A heal context without a live reply address is a broken run, so it fails
  # loud here rather than reporting a decision nobody receives.
  defp report(%{job_heal: %{reply_to: reply_to, ref: ref}}, decision)
       when is_pid(reply_to) and is_reference(ref) do
    send(reply_to, {:job_heal_respond, ref, decision})
    :ok
  end

  defp decision(args) do
    with {:ok, choice} <- choice(Map.get(args, "decision")),
         {:ok, note} <- note(Map.get(args, "note")),
         {:ok, limit} <- limit(choice, Map.get(args, "timeout_seconds")),
         {:ok, change} <- change(choice, Map.get(args, "change")) do
      {:ok, %{decision: choice, note: note, timeout_seconds: limit, change: change}}
    end
  end

  defp choice(value) do
    case Map.fetch(@decisions, value) do
      {:ok, choice} -> {:ok, choice}
      :error -> {:error, {:invalid_decision, value}}
    end
  end

  defp note(text) when is_binary(text) do
    note = String.trim(text)

    cond do
      note == "" -> {:error, :missing_note}
      String.length(note) > @note_max -> {:error, {:note_too_long, String.length(note)}}
      true -> {:ok, note}
    end
  end

  defp note(_absent), do: {:error, :missing_note}

  defp limit(:raise_limit, seconds) when is_integer(seconds) and seconds > 0, do: {:ok, seconds}
  defp limit(:raise_limit, _absent_or_invalid), do: {:error, :missing_limit}
  defp limit(_choice, _ignored), do: {:ok, nil}

  defp change(:propose, change) when is_map(change) and map_size(change) > 0 do
    case Enum.reject(Map.keys(change), &(&1 in @change_fields)) do
      [] -> change_values(change)
      unknown -> {:error, {:invalid_change, Enum.sort(unknown)}}
    end
  end

  defp change(:propose, _absent_or_empty), do: {:error, :missing_change}
  defp change(_choice, _ignored), do: {:ok, nil}

  defp change_values(change) do
    case Enum.reject(change, &valid_field?/1) do
      [] -> {:ok, change}
      invalid -> {:error, {:invalid_change, invalid |> Enum.map(&elem(&1, 0)) |> Enum.sort()}}
    end
  end

  defp valid_field?({field, value}) when field in @text_fields,
    do: is_binary(value) and String.trim(value) != ""

  defp valid_field?({"timeout_seconds", value}), do: is_integer(value) and value > 0
  defp valid_field?({"clear_route_pin", value}), do: value == true
  defp valid_field?({"delivery_target", value}), do: is_map(value) and map_size(value) > 0

  defp ended(%{decision: decision}) do
    "Decision #{decision} recorded. This heal run ends here: make no further tool calls and " <>
      "write no reply."
  end

  defp tag(:not_heal_run), do: "not_heal_run"
  defp tag({:invalid_decision, _value}), do: "invalid_decision"
  defp tag(:missing_note), do: "missing_note"
  defp tag({:note_too_long, _length}), do: "note_too_long"
  defp tag(:missing_limit), do: "missing_limit"
  defp tag(:missing_change), do: "missing_change"
  defp tag({:invalid_change, _fields}), do: "invalid_change"

  defp describe_error({:invalid_decision, value}) do
    "#{inspect(value)} is not a decision; call again with decision rerun, raise_limit, " <>
      "pause, propose or tell."
  end

  defp describe_error(:missing_note),
    do: "The decision needs note, what failed and what would have to change; call again with it."

  defp describe_error({:note_too_long, length}) do
    "The note is #{length} characters and must be at most #{@note_max}; it is never cut, so " <>
      "call again with a shorter one."
  end

  defp describe_error(:missing_limit),
    do: "raise_limit needs timeout_seconds, a positive whole number; call again with it."

  defp describe_error(:missing_change) do
    "propose needs change, the exact edit in update_job's field names; call again with it, " <>
      "or decide tell."
  end

  defp describe_error({:invalid_change, fields}) do
    "A change names only #{Enum.join(@change_fields, ", ")}, each with a value of its type " <>
      "(clear_route_pin only as true); these are not: #{Enum.join(fields, ", ")}."
  end
end
