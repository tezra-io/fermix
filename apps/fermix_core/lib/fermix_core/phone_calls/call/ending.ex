defmodule FermixCore.PhoneCalls.Call.Ending do
  @moduledoc """
  How a phone call ends (M94 §08, §09): what ends it, the end reason each
  cause gives the outcome reading (`Outcome.extract/4`'s `end_reason`, what
  the transport proved), the failure word each writes on the row (`nil` for
  an ordinary end), and the stages the end goes through. Pure: the worker
  (`PhoneCalls.Call`) runs the stages' side effects.

  | Cause | End reason | Failure word |
  |---|---|---|
  | `:no_answer` (ringing deadline) | `:no_answer` | `no_answer` |
  | `:deadline` (call deadline) | `:deadline` | `call_deadline_reached` |
  | `:recipient_silence` | `:deadline` | `recipient_silence_timeout` |
  | `:transcript_limit` (no reading runs) | `:deadline` | `transcript_limit_reached` |
  | `{:cancelled, :owner}` | `:cancelled` | `cancelled_by_owner` |
  | `{:cancelled, :disabled}` | `:cancelled` | `phone_calls_disabled` |
  | `{:cancelled, :shutdown}` | `:cancelled` | `engine_stopped` |
  | `{:finish, :done}`, `{:finish, :needs_owner}` | `:hangup` | none |
  | `{:finish, :cannot_proceed}` | `:hangup` | `cannot_proceed` |
  | `{:finish, :voicemail}` | `:voicemail` | none |
  | `:core_turn_limit` | `:hangup` | `core_turn_limit_reached` |
  | `:call_failed` | `:failed` | `call_failed` |
  | `{:remote_closed, "remote_hangup" or "close_requested"}` | `:hangup` | none |
  | `{:remote_closed, "expired"}` | `:deadline` | `provider_session_expired` |
  | `{:remote_closed, "connection_lost"}` | `:connection_lost` | `provider_connection_lost` |
  | `{:remote_closed, "content"}` | `:failed` | `provider_closed_for_content` |
  | `{:remote_closed, _other}` | `:hangup` | `provider_closed` |
  | `:sideband_lost`, `:attach_failed`, `:attach_timeout`, `:session_not_recorded` | `:connection_lost` | the cause's own name |

  The stages, in order and each skippable: `:speech` (a reply still being
  spoken gets `Limits.max_speech_checks/0` quiet windows, none on voicemail
  or once the engine is stopping), `:hangup` (one request, sent again only
  when it provably never left) and `:draining` (`session.closed` awaited).
  """

  alias FermixCore.PhoneCalls.Limits

  @connection_causes [:sideband_lost, :attach_failed, :attach_timeout, :session_not_recorded]

  @enforce_keys [:cause]
  defstruct [:cause, stage: nil, speech_checks: 0]

  @type cause ::
          :no_answer
          | :deadline
          | :recipient_silence
          | :transcript_limit
          | {:cancelled, :owner | :disabled | :shutdown}
          | {:finish, :done | :needs_owner | :cannot_proceed | :voicemail}
          | :core_turn_limit
          | :call_failed
          | {:remote_closed, String.t() | nil}
          | :sideband_lost
          | :attach_failed
          | :attach_timeout
          | :session_not_recorded

  @type end_reason ::
          :no_answer | :deadline | :cancelled | :hangup | :voicemail | :failed | :connection_lost
  @type stage :: nil | :speech | :hangup | :draining
  @type t :: %__MODULE__{cause: cause(), stage: stage(), speech_checks: non_neg_integer()}

  @doc "An end for `cause`, before any stage."
  @spec new(cause()) :: t()
  def new(cause) do
    {_end_reason, _word} = words(cause)
    %__MODULE__{cause: cause}
  end

  @doc "The end at `stage`."
  @spec put_stage(t(), stage()) :: t()
  def put_stage(%__MODULE__{} = ending, stage) when stage in [nil, :speech, :hangup, :draining],
    do: %{ending | stage: stage}

  @doc "What the transport proved of this end, for the outcome reading."
  @spec end_reason(t()) :: end_reason()
  def end_reason(%__MODULE__{cause: cause}), do: cause |> words() |> elem(0)

  @doc "Whether this end waits for a reply still being spoken at all."
  @spec waits_for_speech?(t(), boolean()) :: boolean()
  def waits_for_speech?(%__MODULE__{cause: {:finish, :voicemail}}, _engine_stopping?), do: false
  def waits_for_speech?(%__MODULE__{}, engine_stopping?), do: not engine_stopping?

  @doc """
  One quiet window has passed: `{:wait, ending}` for another while the voice
  is still speaking and the bound allows, `:done` when the hangup goes out.
  """
  @spec speech_checked(t(), boolean(), boolean()) :: {:wait, t()} | :done
  def speech_checked(%__MODULE__{} = ending, speaking?, engine_stopping?) do
    checks = ending.speech_checks + 1

    if speaking? and waits_for_speech?(ending, engine_stopping?) and
         checks < Limits.max_speech_checks(),
       do: {:wait, %{ending | speech_checks: checks}},
       else: :done
  end

  @doc """
  The failure words the row keeps: the cause's own word, `engine_stopped`
  beside it when the engine's stop cut the end short, and the hangup's
  failure when the end was never confirmed.
  """
  @spec failure_reason(t(), %{
          engine_stopping?: boolean(),
          closed?: boolean(),
          hangup_error: String.t() | nil
        }) :: String.t() | nil
  def failure_reason(%__MODULE__{cause: cause}, facts) do
    word = cause |> words() |> elem(1) |> stopped(cause, facts.engine_stopping?)

    case {facts.closed?, facts.hangup_error} do
      {false, error} when is_binary(error) -> join(word, "hangup " <> error)
      _closed_or_no_error -> word
    end
  end

  defp stopped(word, cause, true) when cause != {:cancelled, :shutdown},
    do: join(word, "engine_stopped")

  defp stopped(word, _cause, _engine_stopping?), do: word

  defp join(nil, more), do: more
  defp join(word, more), do: word <> "; " <> more

  defp words(:no_answer), do: {:no_answer, "no_answer"}
  defp words(:deadline), do: {:deadline, "call_deadline_reached"}
  defp words(:recipient_silence), do: {:deadline, "recipient_silence_timeout"}
  defp words(:transcript_limit), do: {:deadline, "transcript_limit_reached"}
  defp words({:cancelled, :owner}), do: {:cancelled, "cancelled_by_owner"}
  defp words({:cancelled, :disabled}), do: {:cancelled, "phone_calls_disabled"}
  defp words({:cancelled, :shutdown}), do: {:cancelled, "engine_stopped"}
  defp words({:finish, :voicemail}), do: {:voicemail, nil}
  defp words({:finish, :cannot_proceed}), do: {:hangup, "cannot_proceed"}
  defp words({:finish, reason}) when reason in [:done, :needs_owner], do: {:hangup, nil}
  defp words(:core_turn_limit), do: {:hangup, "core_turn_limit_reached"}
  defp words(:call_failed), do: {:failed, "call_failed"}
  defp words({:remote_closed, reason}), do: remote_closed(reason)

  defp words(cause) when cause in @connection_causes,
    do: {:connection_lost, Atom.to_string(cause)}

  defp remote_closed(reason) when reason in ["remote_hangup", "close_requested"],
    do: {:hangup, nil}

  defp remote_closed("expired"), do: {:deadline, "provider_session_expired"}
  defp remote_closed("connection_lost"), do: {:connection_lost, "provider_connection_lost"}
  defp remote_closed("content"), do: {:failed, "provider_closed_for_content"}
  defp remote_closed(_other), do: {:hangup, "provider_closed"}
end
