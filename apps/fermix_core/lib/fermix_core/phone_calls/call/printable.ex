defmodule FermixCore.PhoneCalls.Call.Printable do
  @moduledoc """
  What a phone call's worker prints of itself (`PhoneCalls.Call`'s
  `format_status/1`, which crash reports and `:sys.get_status/1` use): its
  state and the message in hand with none of the call's words, and a crash
  reason's stack frames by arity, never their arguments. Pure.

  Taken out: what was said (each fragment becomes its size), the mandate (the
  brief, and the row's copy of it), the opening line, reply text, finish
  notes, keypad keys, vendor words and every turn's handle. The credentials
  are never in the state at all.
  """

  alias FermixCore.PhoneCalls.Brief
  alias FermixCore.PhoneCalls.Call.Delegations
  alias FermixCore.PhoneCalls.Call.Keypad

  @doc "The worker's state without the call's words."
  @spec state(map()) :: map()
  def state(%{brief: %Brief{}} = state) do
    %{
      state
      | row: Map.take(state.row, [:id, :status]),
        brief: :redacted,
        opening: redacted(state.opening),
        transcript: {:entries, length(state.transcript), state.transcript_bytes},
        delegations: Delegations.printable(state.delegations),
        keypad: Keypad.printable(state.keypad),
        finish: finish(state.finish),
        call_failed: redacted(state.call_failed),
        vendor_error: redacted(state.vendor_error),
        hangup_error: redacted(state.hangup_error)
    }
  end

  def state(state), do: state

  @doc "A message the worker handles, without the call's words."
  @spec message(term()) :: term()
  def message({:phone_sideband, pid, {:event, event}}),
    do: {:phone_sideband, pid, {:event, event(event)}}

  def message({:phone_call_delegation, call_id, id, revision, {:ok, %{reply: _} = answer}}),
    do: {:phone_call_delegation, call_id, id, revision, {:ok, %{answer | reply: :redacted}}}

  def message({:"$gen_call", from, {:press_keys, _handle, keys}}),
    do: {:"$gen_call", from, {:press_keys, :redacted, {:keys, String.length(keys)}}}

  def message({:"$gen_call", from, {:finish, _handle, reason, note}}),
    do: {:"$gen_call", from, {:finish, :redacted, reason, redacted(note)}}

  def message({ref, _task_result}) when is_reference(ref), do: {ref, :redacted}
  def message(message), do: message

  @doc "A crash reason: an exception as its module, every stack frame by arity."
  @spec reason(term()) :: term()
  def reason({cause, stack}) when is_list(stack), do: {cause(cause), Enum.map(stack, &frame/1)}
  def reason(reason), do: cause(reason)

  defp event({:transcript, %{text: text} = fragment}),
    do: {:transcript, %{fragment | text: {:bytes, byte_size(text)}}}

  defp event({kind, type, _raw}) when kind in [:unknown, :malformed], do: {kind, type, :redacted}

  defp event({kind, %{message: _} = map}) when kind in [:call_failed, :vendor_error],
    do: {kind, %{map | message: :redacted}}

  defp event(event), do: event

  defp cause(%{__exception__: true, __struct__: module}), do: module
  defp cause(reason) when is_atom(reason), do: reason

  defp cause(reason) when is_tuple(reason) and tuple_size(reason) > 0,
    do: {elem(reason, 0), :redacted}

  defp cause(_reason), do: :redacted

  defp frame({module, function, args, location}) when is_list(args),
    do: {module, function, length(args), location}

  defp frame(frame), do: frame

  defp finish(nil), do: nil
  defp finish(finish), do: %{finish | note: redacted(finish.note)}

  defp redacted(nil), do: nil
  defp redacted(_value), do: :redacted
end
