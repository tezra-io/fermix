defmodule FermixCore.PhoneCalls.Limits do
  @moduledoc """
  Every bound on a phone call (M94 §10) and how long its record is kept
  (§11), in one place.

  Each is a constant, not a setting (decision D5): none is an owner's choice
  yet, and a constant becomes a setting only once owners need different
  values. Nothing here reads application environment or the process
  environment. Each bound's comment names what happens when it is reached.

  Durations are milliseconds, for an injected monotonic clock and for the
  absolute deadlines a call persists; retention is in days. The local timers
  bound a call only while Fermix runs. Once Fermix is gone, the provider's
  documented limits are the only bound on a call (decision D2), so they are
  stated here too, for the slot an unresolved call holds.
  """

  @minute 60 * 1000
  @hour 60 * @minute

  # -- external calls and attempts ---------------------------------------------

  # Reached: a new start is refused before dispatch, an uncertain dispatch included.
  @spec max_outstanding_calls() :: pos_integer()
  def max_outstanding_calls, do: 1

  # Reached: the mandate is spent; a timeout or a lost response never creates again.
  @spec max_create_requests_per_mandate() :: pos_integer()
  def max_create_requests_per_mandate, do: 1

  # Reached: a new start is refused before dispatch until the window frees an attempt.
  @spec max_attempts_per_day() :: pos_integer()
  def max_attempts_per_day, do: 5

  # The window `max_attempts_per_day/0` counts in: the 24 hours before a start.
  @spec attempt_window_ms() :: pos_integer()
  def attempt_window_ms, do: 24 * @hour

  # -- call, ringing and inactivity --------------------------------------------

  # Reached: the call's timer requests hangup.
  @spec call_deadline_ms() :: pos_integer()
  def call_deadline_ms, do: 10 * @minute

  # Reached: the call's timer requests hangup, and the outcome is no answer.
  @spec ringing_timeout_ms() :: pos_integer()
  def ringing_timeout_ms, do: 60 * 1000

  # Reached with no recipient transcript: the call's timer requests hangup.
  @spec recipient_silence_timeout_ms() :: pos_integer()
  def recipient_silence_timeout_ms, do: 120 * 1000

  # -- delegation ----------------------------------------------------------------

  # Reached: a further delegation waits as the pending one.
  @spec max_active_delegations() :: pos_integer()
  def max_active_delegations, do: 1

  # Reached: a further delegation is answered with an honest limitation, not queued.
  @spec max_pending_delegations() :: pos_integer()
  def max_pending_delegations, do: 1

  # Reached: no more Core turns; the call ends if the task cannot proceed without one.
  @spec max_core_turns_per_call() :: pos_integer()
  def max_core_turns_per_call, do: 8

  # Reached: the Core turn is stopped and its answer is an honest limitation.
  @spec core_turn_timeout_ms() :: pos_integer()
  def core_turn_timeout_ms, do: 30 * 1000

  # Reached: the Core turn stops stepping and answers with what it has.
  @spec max_agent_steps_per_core_turn() :: pos_integer()
  def max_agent_steps_per_core_turn, do: 12

  # -- transcript and keypad -----------------------------------------------------

  # Reached when required evidence would be lost: the call ends with incomplete evidence.
  @spec max_transcript_bytes() :: pos_integer()
  def max_transcript_bytes, do: 64 * 1024

  # Reached: a further key is refused.
  @spec max_dtmf_keys() :: pos_integer()
  def max_dtmf_keys, do: 32

  # Reached: the next key waits for the outstanding acknowledgement.
  @spec max_outstanding_dtmf_acks() :: pos_integer()
  def max_outstanding_dtmf_acks, do: 1

  # Reached: the key is ambiguous and is never sent again.
  @spec dtmf_ack_timeout_ms() :: pos_integer()
  def dtmf_ack_timeout_ms, do: 3 * 1000

  # -- cleanup and report --------------------------------------------------------

  # Reached: no second immediate termination request for the session.
  @spec max_immediate_termination_requests() :: pos_integer()
  def max_immediate_termination_requests, do: 1

  # Reached: closure stays unconfirmed. Used only once safe repeat semantics are proved.
  @spec max_cleanup_retries() :: non_neg_integer()
  def max_cleanup_retries, do: 2

  # Reached: no further cleanup request for the session; closure stays unconfirmed.
  @spec cleanup_window_ms() :: pos_integer()
  def cleanup_window_ms, do: 30 * 1000

  # Reached: the receiver closes and missing finalization is recorded.
  @spec terminal_drain_ms() :: pos_integer()
  def terminal_drain_ms, do: 5 * 1000

  # Reached: no second extraction; a failed one leaves the outcome unknown.
  @spec max_result_extractions() :: pos_integer()
  def max_result_extractions, do: 1

  # Reached: the extraction is stopped and the outcome is unknown.
  @spec result_extraction_timeout_ms() :: pos_integer()
  def result_extraction_timeout_ms, do: 30 * 1000

  # Reached: delivery stays visibly pending or uncertain; the call is never retried for it.
  @spec max_report_delivery_attempts() :: pos_integer()
  def max_report_delivery_attempts, do: 3

  # -- the provider's documented remote bounds -----------------------------------

  # OpenAI ends a call still ringing at this age, whether or not Fermix runs.
  @spec provider_ringing_limit_ms() :: pos_integer()
  def provider_ringing_limit_ms, do: 3 * @minute

  # OpenAI ends a connected call at this age, whether or not Fermix runs.
  @spec provider_connected_limit_ms() :: pos_integer()
  def provider_connected_limit_ms, do: 2 * @hour

  # Reached after dispatch: an unresolved call's slot may be released, its outcome unknown.
  @spec provider_lifetime_bound_ms() :: pos_integer()
  def provider_lifetime_bound_ms, do: provider_ringing_limit_ms() + provider_connected_limit_ms()

  # -- retention -----------------------------------------------------------------

  # Reached: a call's outcome and mandate audit are deleted, unless the owner deleted them earlier.
  @spec outcome_retention_days() :: pos_integer()
  def outcome_retention_days, do: 90

  # Reached: a call's confirmation excerpts are deleted, unless the owner deleted them earlier.
  @spec excerpt_retention_days() :: pos_integer()
  def excerpt_retention_days, do: 7
end
