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

  `reason/1` is the one rule for printing any phone-call process's reason
  where it outlives that process: the Manager's and the delivery worker's
  crash reports, every log line that names a reason which can carry a call's
  words, and the failure words a row keeps of a task that crashed.
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

  @doc """
  A message the worker handles, without the call's words. A call's request
  is the bare request, as OTP hands it to `format_status/1`.
  """
  @spec message(term()) :: term()
  def message({:phone_sideband, pid, {:event, event}}),
    do: {:phone_sideband, pid, {:event, event(event)}}

  def message({:phone_call_delegation, call_id, id, {:ok, %{reply: _} = answer}}),
    do: {:phone_call_delegation, call_id, id, {:ok, %{answer | reply: :redacted}}}

  def message({:press_keys, _handle, keys}) when is_binary(keys),
    do: {:press_keys, :redacted, {:keys, String.length(keys)}}

  def message({:finish, _handle, reason, note}), do: {:finish, :redacted, reason, redacted(note)}

  def message({ref, _task_result}) when is_reference(ref), do: {ref, :redacted}

  def message({:DOWN, ref, :process, pid, reason}),
    do: {:DOWN, ref, :process, pid, reason(reason)}

  def message({:EXIT, pid, reason}), do: {:EXIT, pid, reason(reason)}
  def message(message), do: message

  # Deep enough for an exit of a call wrapping a stopped task's crash.
  @reason_depth 6

  @doc """
  A reason by its codes alone: an atom or an integer (an HTTP status, a close
  code) as itself, an exception as its module, a stack frame by arity and
  place, a tuple element by element, and every other value (text, a map, a
  list that is no stack, a pid) as `:redacted`. Nested at most
  #{@reason_depth} deep; past that, `:redacted`.
  """
  @spec reason(term()) :: term()
  def reason(reason), do: code(reason, @reason_depth)

  defp event({:transcript, %{text: text} = fragment}),
    do: {:transcript, %{fragment | text: {:bytes, byte_size(text)}}}

  defp event({kind, type, _raw}) when kind in [:unknown, :malformed], do: {kind, type, :redacted}

  defp event({kind, %{message: _} = map}) when kind in [:call_failed, :vendor_error],
    do: {kind, %{map | message: :redacted}}

  defp event(event), do: event

  defp code(_value, 0), do: :redacted
  defp code(value, _depth) when is_atom(value) or is_integer(value), do: value
  defp code(%{__exception__: true, __struct__: module}, _depth), do: module

  defp code(value, depth) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&code(&1, depth - 1)) |> List.to_tuple()

  defp code([_ | _] = list, _depth) do
    if Enum.all?(list, &frame?/1), do: Enum.map(list, &frame/1), else: :redacted
  end

  defp code(_value, _depth), do: :redacted

  defp frame?({module, function, args, location})
       when is_atom(module) and is_atom(function) and (is_list(args) or is_integer(args)) and
              is_list(location),
       do: true

  defp frame?(_other), do: false

  # The place is the file and line alone: a frame's `error_info` can carry a
  # value of the call that failed.
  defp frame({module, function, args, location}),
    do: {module, function, arity(args), place(location)}

  defp place(location), do: for({key, _value} = pair <- location, key in [:file, :line], do: pair)

  defp arity(args) when is_list(args), do: length(args)
  defp arity(arity), do: arity

  defp finish(nil), do: nil
  defp finish(finish), do: %{finish | note: redacted(finish.note)}

  defp redacted(nil), do: nil
  defp redacted(_value), do: :redacted
end
