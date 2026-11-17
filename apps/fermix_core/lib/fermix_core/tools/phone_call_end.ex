defmodule FermixCore.Tools.PhoneCallEnd do
  @moduledoc """
  `phone_call_end` (M94 §07, §09): hang up the phone call whose backend turn
  this is, saying why it ended and in a short note what is left.

  The reasons are the call's (`PhoneCalls.CallControls.finish/4`): `done`
  (the task is finished, whatever its outcome), `needs_owner` (a fact or
  decision the brief lacks: the owner follows up, and nothing waits on the
  line), `cannot_proceed` (the person declined, or the task cannot go on),
  and `voicemail` (voicemail or an answering machine answered: the worker
  ends the call without leaving a message).

  Built and offered only by a phone call's backend turn
  (`Agents.PhoneCallTurn`), which makes its capability from this module: no
  capability registry holds it, so no other turn can be offered or run it,
  and `execute/2` still refuses outside such a turn
  (`Agents.PhoneCallTurn.in_call/1`). The call is the turn's own, named by
  the context: its id and the handle the call's worker minted for this turn,
  never a model argument. The worker checks the handle again and owns the
  hang-up and everything after it.

  One `[:fermix, :tool, :exec]` event per model call under this name,
  refusals included. Its metadata carries the reason, never the note.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Agents.PhoneCallTurn
  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.PhoneCalls.Limits
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @name "phone_call_end"
  @reasons %{
    "done" => :done,
    "needs_owner" => :needs_owner,
    "cannot_proceed" => :cannot_proceed,
    "voicemail" => :voicemail
  }

  @impl true
  @spec name() :: String.t()
  def name, do: @name

  @impl true
  @spec description() :: String.t()
  def description do
    "Hang up this phone call once the conversation is over, voicemail or an answering " <>
      "machine answered, or the person asked to end it. Say why: done, needs_owner (the " <>
      "owner must follow up on something the brief does not settle), cannot_proceed, or " <>
      "voicemail; and add a short note of what is left."
  end

  @impl true
  @spec parameters() :: map()
  def parameters do
    %{
      type: "object",
      required: ["reason", "note"],
      properties: %{
        reason: %{
          type: "string",
          enum: Map.keys(@reasons),
          description: "Why the call ends: done, needs_owner, cannot_proceed or voicemail."
        },
        note: %{
          type: "string",
          description:
            "A short note of what is left, at most #{Limits.max_finish_note_bytes()} bytes."
        }
      }
    }
  end

  @impl true
  @spec when_to_use() :: String.t()
  def when_to_use,
    do:
      "When this phone call's conversation is over, voicemail answered, or the person asked to end it."

  @impl true
  @spec failure_modes() :: [map()]
  def failure_modes do
    [
      %{tag: "not_in_call", description: "not a phone call's backend turn"},
      %{tag: "invalid_reason", description: "a reason other than the four"},
      %{tag: "invalid_note", description: "a note that is missing or too long"},
      %{tag: "refused", description: "the call's worker did not end the call"}
    ]
  end

  @impl true
  @spec requires_setup() :: nil
  def requires_setup, do: nil

  @impl true
  @spec category() :: atom()
  def category, do: :phone_call

  @doc "The reasons a call may end with, as the model names them."
  @spec reasons() :: [String.t(), ...]
  def reasons, do: Map.keys(@reasons)

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    started = System.monotonic_time(:millisecond)
    result = run(args, context)
    duration = System.monotonic_time(:millisecond) - started

    ToolTelemetry.exec(@name, context, match?({:ok, %{success: true}}, result), duration,
      metadata: metadata(args, result),
      result: result
    )

    result
  end

  defp run(args, context) do
    with {:ok, call} <- in_call(context),
         {:ok, reason} <- fetch_reason(args),
         {:ok, note} <- fetch_note(args),
         :ok <- call.controls.finish(call.call_id, call.handle, reason, note) do
      {:ok, Tool.success(Jason.encode!(%{status: "ending", reason: Atom.to_string(reason)}))}
    else
      {:error, why} -> {:ok, Tool.error(sentence(why))}
    end
  end

  defp in_call(context) do
    case PhoneCallTurn.in_call(context) do
      {:ok, call} -> {:ok, call}
      :none -> {:error, :not_in_call}
    end
  end

  defp fetch_reason(%{"reason" => reason}) when is_map_key(@reasons, reason),
    do: {:ok, Map.fetch!(@reasons, reason)}

  defp fetch_reason(_args), do: {:error, :invalid_reason}

  defp fetch_note(%{"note" => note}) when is_binary(note) do
    note = String.trim(note)

    if String.valid?(note) and byte_size(note) <= Limits.max_finish_note_bytes(),
      do: {:ok, note},
      else: {:error, :invalid_note}
  end

  defp fetch_note(_args), do: {:error, :invalid_note}

  defp metadata(args, {:ok, %{success: false, error: error}}),
    do: %{reason: reason_word(args), error: error}

  defp metadata(args, _result), do: %{reason: reason_word(args)}

  defp reason_word(%{"reason" => reason}) when is_map_key(@reasons, reason), do: reason
  defp reason_word(_args), do: "invalid"

  defp sentence(:not_in_call), do: "#{@name} works only on a phone call's backend turn."

  defp sentence(:invalid_reason),
    do: "reason must be one of: #{Enum.join(Map.keys(@reasons), ", ")}."

  defp sentence(:invalid_note),
    do: "note must be text of at most #{Limits.max_finish_note_bytes()} bytes."

  defp sentence(reason), do: "The call was not ended: #{inspect(reason)}"
end
