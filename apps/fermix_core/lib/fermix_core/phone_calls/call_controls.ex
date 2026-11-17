defmodule FermixCore.PhoneCalls.CallControls do
  @moduledoc """
  The in-call controls a phone call's backend turn uses (M94 §07, §08), the
  one surface other modules call to reach a live call's worker
  (`PhoneCalls.Call`): press keys, and end the call.

  Each control names the call by its id and presents the running turn's
  `handle` (minted by the worker for that turn, `PhoneCalls.Delegate`). The
  worker is found in its subtree's call registry (`registry_name/0` in
  production, `opts[:registry]` for a test's own subtree), answers with a
  deferred reply, and is the authority on whether the handle is current.
  Arguments are checked here before the worker is asked, so a malformed
  request never reaches it.
  """

  alias FermixCore.PhoneCalls.Limits
  alias FermixCore.PhoneCalls.OpenAILive.Controls

  @registry FermixCore.PhoneCalls.CallRegistry
  @finish_reasons [:done, :needs_owner, :cannot_proceed, :voicemail]

  @type finish_reason :: :done | :needs_owner | :cannot_proceed | :voicemail
  @type keypad_result :: %{
          confirmed: String.t(),
          unconfirmed: String.t(),
          stopped: nil | atom() | {:cap_reached, :dtmf_keys}
        }

  @doc "The production call registry each worker registers its call id in."
  @spec registry_name() :: atom()
  def registry_name, do: @registry

  @doc """
  Presses `keys` on the call, for its running backend turn (`handle`). One
  key per event, each consuming one of the call's `Limits.max_dtmf_keys/0`
  first, each waiting for its acknowledgement
  (`Limits.dtmf_ack_timeout_ms/0`) before the next. A key whose
  acknowledgement does not come is never sent again: it and the rest come
  back unconfirmed, with why the presses stopped (`:ack_timeout`, `:refused`,
  `:not_sent`, `:send_unknown`, `:invalid_key`, `{:cap_reached, :dtmf_keys}`,
  `:turn_ended`, `:call_ending`).

  Refused before any key: `:invalid_key`, `:too_many_keys`, `:unknown_call`,
  `:bad_handle`, `:stale_handle`, `:not_active` (not answered, or ending),
  `:keypad_busy`, `{:cap_reached, :dtmf_keys}`; `:call_ended` and `:timeout`
  when the worker went or did not answer.
  """
  @spec press_keys(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, keypad_result()} | {:error, term()}
  def press_keys(call_id, handle, keys, opts \\ [])
      when is_binary(call_id) and is_binary(handle) and is_binary(keys) and is_list(opts) do
    with :ok <- valid_keys(keys),
         {:ok, pid} <- whereis(call_id, opts) do
      control(pid, {:press_keys, handle, keys}, keys_timeout_ms(keys))
    end
  end

  @doc """
  Ends the call, for its running backend turn (`handle`): `:done`,
  `:needs_owner` (it ends as `needs_owner` with the options heard),
  `:cannot_proceed` or `:voicemail` (voicemail or a machine answered). `:ok`
  once taken. The call ends when that turn's answer has been given to the
  voice, or its time is up; on `:voicemail` at once, with nothing said and no
  message left. `note` is kept with the outcome as given: the caller
  (`Tools.PhoneCallEnd`) refuses one longer than
  `Limits.max_finish_note_bytes/0`, and this control refuses it too, never
  cutting it.

  Refused: `:invalid_reason`, `:invalid_note`, `:unknown_call`,
  `:bad_handle`, `:stale_handle`, `:not_active`, `:already_finishing`;
  `:call_ended` and `:timeout` as for `press_keys/3`.
  """
  @spec finish(String.t(), String.t(), finish_reason(), String.t() | nil, keyword()) ::
          :ok | {:error, term()}
  def finish(call_id, handle, reason, note, opts \\ [])
      when is_binary(call_id) and is_binary(handle) and is_list(opts) do
    with :ok <- valid_reason(reason),
         {:ok, note} <- valid_note(note),
         {:ok, pid} <- whereis(call_id, opts) do
      control(pid, {:finish, handle, reason, note}, Limits.control_reply_margin_ms() * 2)
    end
  end

  defp valid_keys(keys) do
    cond do
      not Controls.dtmf_keys?(keys) -> {:error, :invalid_key}
      String.length(keys) > Limits.max_dtmf_keys() -> {:error, :too_many_keys}
      true -> :ok
    end
  end

  defp valid_reason(reason) when reason in @finish_reasons, do: :ok
  defp valid_reason(_reason), do: {:error, :invalid_reason}

  defp valid_note(nil), do: {:ok, nil}

  defp valid_note(note) when is_binary(note) do
    if String.valid?(note) and byte_size(note) <= Limits.max_finish_note_bytes(),
      do: {:ok, blank_nil(note)},
      else: {:error, :invalid_note}
  end

  defp valid_note(_note), do: {:error, :invalid_note}

  defp blank_nil(""), do: nil
  defp blank_nil(text), do: text

  # The worker answers within the keys' own acknowledgement bounds; the
  # margin lets its timers answer first.
  defp keys_timeout_ms(keys) do
    margin = Limits.control_reply_margin_ms()
    String.length(keys) * (Limits.dtmf_ack_timeout_ms() + margin) + margin
  end

  defp whereis(call_id, opts) do
    registry = Keyword.get(opts, :registry, @registry)

    with pid when is_pid(pid) <- Process.whereis(registry),
         [{worker, _value}] <- Registry.lookup(registry, call_id) do
      {:ok, worker}
    else
      _none -> {:error, :unknown_call}
    end
  end

  defp control(pid, message, timeout_ms) do
    GenServer.call(pid, message, timeout_ms)
  catch
    :exit, {:noproc, _call} -> {:error, :unknown_call}
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, {_reason, _call} -> {:error, :call_ended}
  end
end
