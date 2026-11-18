defmodule FermixCore.PhoneCalls.Limits do
  @moduledoc """
  Every bound on a phone call (M94 §10) and how long its record is kept
  (§11), in one place.

  Each is a constant, not a setting (decision D5): none is an owner's choice
  yet, and a constant becomes a setting only once owners need different
  values. Nothing here reads application environment or the process
  environment. Each bound's comment names what happens when it is reached.
  A bound the code's shape makes true has no number here and is said where
  it holds: one outcome extraction per call (`PhoneCalls.Call`'s
  `finalize/1`, the extraction's only caller, which runs once).

  Durations are milliseconds, for an injected monotonic clock and for the
  absolute deadlines a call persists; retention is in days. The local timers
  bound a call only while Fermix runs. Once Fermix is gone, the provider's
  documented limits are the only bound on a call (decision D2), so they are
  stated here too, for the slot an unresolved call holds.

  ## What lives here

  A number the feature chooses about how a call behaves (a wait, a deadline,
  a count, a retry or its backoff, a size of what is kept, sent or shown, a
  retention) lives here, and the code that enforces it reads it here: a
  bound nothing reads is deleted, and a bound that only documents is a
  comment. One class stays beside its code, named and documented there: a
  property of a vendor's interface, or a size derived from one, because it
  moves when the vendor's documentation does, not when the feature changes
  its mind. They are the field shapes and sizes OpenAI's create reference
  documents (`OpenAILive`), the event names and the keypad's keys
  (`OpenAILive.Controls`), how far back the sideband replays
  (`OpenAILive.Sideband`), the instructions and input a call's prompt may
  send (`Prompt`, from the create reference's token caps) and the reply a
  call speaks (`Disclosure`, under the vendor's 500-token append limit). The
  provider's limits on a call's life are here, because the slot an uncertain
  call holds is built on them. A parameter of an algorithm is no bound at
  all and stays beside its code: it shapes how a result is computed, never
  how long a call waits, how often it tries or how much it keeps, sends or
  shows. `Outcome.Record`'s fitting rounds (8) and smallest value (16 bytes)
  are how a report is fitted to the record's bounds, which are here, and
  `Outcome.Confirmed`'s two words allowed after a clock time are how a time
  is matched in what was said. Where a table CHECK holds a size as well (the
  record's text, a closure's reason), the CHECK is the store's and changes
  only by a migration.
  """

  @minute 60 * 1000
  @hour 60 * @minute

  # -- external calls and attempts ---------------------------------------------

  # Reached: a new start is refused before dispatch, an uncertain dispatch
  # included. A mandate is dialed at most once: its row leaves `admitted` by
  # the one dispatch claim (`Ledger.claim_dispatch/3`), so a timeout or a lost
  # response never creates again.
  @spec max_outstanding_calls() :: pos_integer()
  def max_outstanding_calls, do: 1

  # Reached: a new start is refused before dispatch until the window frees an attempt.
  @spec max_attempts_per_day() :: pos_integer()
  def max_attempts_per_day, do: 20

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

  # How long, once the call is answered, the voice waits for the recipient to
  # speak first. Reached with no recipient speech: the opening line is sent,
  # once; speech before it means the opening is never sent.
  @spec opening_wait_ms() :: pos_integer()
  def opening_wait_ms, do: 2 * 1000

  # -- delegation ----------------------------------------------------------------

  # Reached: a further delegation waits as the pending one.
  @spec max_active_delegations() :: pos_integer()
  def max_active_delegations, do: 1

  # Reached: a further delegation is answered with an honest limitation, not queued.
  @spec max_pending_delegations() :: pos_integer()
  def max_pending_delegations, do: 1

  # How often a call's end asks a delegation's lane to stop: once for each
  # turn it can hold (the one running and the one waiting), and once more.
  # Reached: a stop that still finds a turn is logged, never repeated.
  @spec max_delegation_stops() :: pos_integer()
  def max_delegation_stops, do: max_active_delegations() + max_pending_delegations() + 1

  # The transcript a backend turn reads of the call so far. Reached: the
  # oldest lines are left out.
  @spec max_backend_window_bytes() :: pos_integer()
  def max_backend_window_bytes, do: 8_192

  # Reached: no more Core turns; the call ends if the task cannot proceed without one.
  @spec max_core_turns_per_call() :: pos_integer()
  def max_core_turns_per_call, do: 8

  # Reached: the Core turn is stopped and its answer is an honest limitation.
  @spec core_turn_timeout_ms() :: pos_integer()
  def core_turn_timeout_ms, do: 30 * 1000

  # Reached: the Core turn stops stepping and answers with what it has.
  @spec max_agent_steps_per_core_turn() :: pos_integer()
  def max_agent_steps_per_core_turn, do: 12

  # The delegation ids and the finished turns' handles a call remembers, each.
  # Reached: the oldest is forgotten, so a repeat of that id would run as new
  # and that handle would read as a bad one rather than a stale one.
  @spec max_remembered_delegations() :: pos_integer()
  def max_remembered_delegations, do: 64

  # -- transcript and keypad -----------------------------------------------------

  # Reached when required evidence would be lost: the call ends with incomplete evidence.
  @spec max_transcript_bytes() :: pos_integer()
  def max_transcript_bytes, do: 64 * 1024

  # Reached: a further key is refused.
  @spec max_dtmf_keys() :: pos_integer()
  def max_dtmf_keys, do: 32

  # Each key waits for its acknowledgement before the next is sent. Reached:
  # the key is ambiguous and is never sent again.
  @spec dtmf_ack_timeout_ms() :: pos_integer()
  def dtmf_ack_timeout_ms, do: 3 * 1000

  # How long a delegation waits for late transcript words before its window is
  # cut. Reached: the backend turn starts with the words that have arrived.
  @spec transcript_settle_ms() :: pos_integer()
  def transcript_settle_ms, do: 1_000

  # Reached: a finish note is cut to whole characters.
  @spec max_finish_note_bytes() :: pos_integer()
  def max_finish_note_bytes, do: 500

  # Added to an in-call control's own bound (a key's acknowledgement wait),
  # so the worker's timers answer first. Reached: the turn hears `:timeout`.
  @spec control_reply_margin_ms() :: pos_integer()
  def control_reply_margin_ms, do: 2_000

  # -- cleanup and report --------------------------------------------------------

  # A reply counts as still being spoken while the voice carried words within
  # this window. Reached with no words: the hangup goes out.
  @spec speech_quiet_ms() :: pos_integer()
  def speech_quiet_ms, do: 1_500

  # Reached: the hangup goes out whether or not the reply has finished.
  @spec max_speech_checks() :: pos_integer()
  def max_speech_checks, do: 6

  # A hangup's own receive bound is 15 s (`OpenAILive`). Reached: the request
  # is stopped and its result unknown; it is never sent again.
  @spec hangup_wait_ms() :: pos_integer()
  def hangup_wait_ms, do: 30 * 1000

  # The wait before a hangup that provably never left is sent again. Reached:
  # it is sent, while `cleanup_window_ms/0` and the cleanup cap allow.
  @spec hangup_resend_spacing_ms() :: pos_integer()
  def hangup_resend_spacing_ms, do: 2_000

  # One hangup request that may reach the provider, per session: the worker's
  # own, or, only when the row counts none, the Manager's cleanup after the
  # worker was lost. Reached: no second such request; closure stays
  # unconfirmed. The vendor documents nothing about repeating a hangup.
  @spec max_immediate_termination_requests() :: pos_integer()
  def max_immediate_termination_requests, do: 1

  # Further hangup requests for a session, only when the one before provably
  # never left (`{:not_sent, _}`): a request that may have reached the
  # provider is never repeated, by anyone. The worker sends them inside
  # `cleanup_window_ms/0`; the Manager, for a session no worker owns, after
  # `cleanup_retry_ms/0` doubling (2 s, then 4 s, inside the same window).
  # Every one is counted on the row first, capped at one plus this, so neither
  # can send more. Reached: closure stays unconfirmed.
  @spec max_cleanup_retries() :: non_neg_integer()
  def max_cleanup_retries, do: 2

  # The Manager's wait before resending a cleanup hangup that provably never
  # left, doubling before each one after.
  @spec cleanup_retry_ms() :: pos_integer()
  def cleanup_retry_ms, do: 2 * 1000

  # Reached: no further cleanup request for the session; closure stays unconfirmed.
  @spec cleanup_window_ms() :: pos_integer()
  def cleanup_window_ms, do: 30 * 1000

  # Reached: the receiver closes and missing finalization is recorded.
  @spec terminal_drain_ms() :: pos_integer()
  def terminal_drain_ms, do: 5 * 1000

  # A ceiling to be reached rarely, the bound `Realtime.CallGist` gives the same
  # kind of call. Reached: the extraction is stopped and the outcome is unknown.
  @spec result_extraction_timeout_ms() :: pos_integer()
  def result_extraction_timeout_ms, do: 60 * 1000

  # The extraction bounds itself; past its timeout and this, the worker stops
  # the task. Reached: the outcome is unknown.
  @spec result_extraction_grace_ms() :: pos_integer()
  def result_extraction_grace_ms, do: 5_000

  # Reached: delivery stays visibly pending or uncertain; the call is never retried for it.
  @spec max_report_delivery_attempts() :: pos_integer()
  def max_report_delivery_attempts, do: 3

  # A terminal write the store refused (an error, a timeout) is tried this many
  # times in all, the end report kept meanwhile. Reached: the row is left to
  # the next boot's proof rules.
  @spec max_terminal_write_attempts() :: pos_integer()
  def max_terminal_write_attempts, do: 5

  # The wait before the second terminal write, doubling before each one after.
  @spec terminal_write_retry_ms() :: pos_integer()
  def terminal_write_retry_ms, do: 1_000

  # Every stop bound below fits the smallest window the engine gets to stop
  # before SIGKILL, 20 s: launchd's default `ExitTimeOut`, which applies under
  # the Mac app, because its launch agent sets none (fermix-macos
  # `scripts/render_launch_agent_plist.sh` writes KeepAlive, Label,
  # ProcessType and RunAtLoad only). The CLI's own service units ask 30 s
  # (`Fermix.CLI.Service.Templates`). Fermix enforces no such window, so it
  # is stated here, and `limits_test.exs` holds the bounds to it.

  # On the engine's orderly stop, how long a call's one hangup request is
  # waited for (its ordinary wait is the request's own 15 s bound). Reached:
  # the request is stopped and its result unknown, never sent again; the call
  # goes on to the terminal drain and reports its closure unconfirmed.
  @spec shutdown_hangup_wait_ms() :: pos_integer()
  def shutdown_hangup_wait_ms, do: 3 * 1000

  # An orderly stop of the engine waits this long for the call in progress to
  # end: the hangup wait above, the terminal drain and a second for the end
  # report. It leaves the rest of the tree 10 s of the smallest stop window
  # (the 20 s above). Reached: nothing is forced; the stop goes on,
  # and the call's row is settled by what it proves at the next boot.
  @spec shutdown_drain_ms() :: pos_integer()
  def shutdown_drain_ms, do: 10 * 1000

  # -- the Manager -----------------------------------------------------------------

  # How long a caller waits for the Manager's answer to a start, a stop, the
  # off switch or the owner's release: at most two ledger calls, each bounded
  # by the Repo's own 5 s, and a margin. Reached: the caller exits, as any
  # `GenServer.call/3` past its bound.
  @spec manager_reply_wait_ms() :: pos_integer()
  def manager_reply_wait_ms, do: 15 * 1000

  # The terminal write leases the report to the hand-off before the delivery
  # worker may select it: at most a continuation dispatch
  # (`continuation_dispatch_wait_ms/0`), one inline send
  # (`report_send_wait_ms/0`) and two ledger writes (5 s each), 85 s, and a
  # margin. Reached:
  # the delivery worker may send it too, the designed at-least-once duplicate.
  @spec handoff_lease_ms() :: pos_integer()
  def handoff_lease_ms, do: 120 * 1000

  # How much past `shutdown_drain_ms/0` the engine's stop waits for the
  # Manager's own answer. Reached: the stop goes on without it.
  @spec drain_reply_margin_ms() :: pos_integer()
  def drain_reply_margin_ms, do: 2 * 1000

  # How often the Manager prunes the ledger to its retention.
  @spec prune_interval_ms() :: pos_integer()
  def prune_interval_ms, do: 24 * @hour

  # -- the report's delivery -------------------------------------------------------

  # How often the delivery worker looks for a report due to send.
  @spec delivery_tick_ms() :: pos_integer()
  def delivery_tick_ms, do: 30 * 1000

  # The soonest the delivery worker looks again after a tick it cut short.
  @spec delivery_min_rearm_ms() :: pos_integer()
  def delivery_min_rearm_ms, do: 5 * 1000

  # Reached: the tick stops; the rest wait for the next one.
  @spec max_reports_per_tick() :: pos_integer()
  def max_reports_per_tick, do: 10

  # One send of the report to its frozen destination (`Delivery.FrozenSend`).
  # Reached: whether it arrived is unknown; the report stays pending.
  @spec report_send_wait_ms() :: pos_integer()
  def report_send_wait_ms, do: 60 * 1000

  # One hand-off of the result to the continuation dispatcher. Reached: the
  # report goes as text instead.
  @spec continuation_dispatch_wait_ms() :: pos_integer()
  def continuation_dispatch_wait_ms, do: 15 * 1000

  # The wait after a failed send, doubling with each attempt, never past the cap.
  @spec delivery_backoff_ms() :: pos_integer()
  def delivery_backoff_ms, do: 30 * 1000

  @spec delivery_backoff_cap_ms() :: pos_integer()
  def delivery_backoff_cap_ms, do: 30 * @minute

  # -- what a call's record keeps ---------------------------------------------------

  # The result extraction's whole reply. Reached: the reply is refused and the
  # outcome is unknown.
  @spec max_extraction_reply_bytes() :: pos_integer()
  def max_extraction_reply_bytes, do: 16_384

  # The corrections one extraction may list. Reached: the reply is refused and
  # the outcome is unknown.
  @spec max_claim_corrections() :: pos_integer()
  def max_claim_corrections, do: 12

  # The provider's closing words kept with a recorded closure. Reached: cut.
  # The table's CHECK on `closure_reason` holds the same 120.
  @spec max_closure_reason_bytes() :: pos_integer()
  def max_closure_reason_bytes, do: 120

  # How many of the owner's calls a recent list shows. Reached: older ones
  # are left out of it.
  @spec max_recent_calls() :: pos_integer()
  def max_recent_calls, do: 20

  # Reached: the outcome's facts are fitted to it (`Outcome.Record`), else refused.
  @spec max_facts_json_bytes() :: pos_integer()
  def max_facts_json_bytes, do: 4_096

  # Reached: further evidence excerpts are left out.
  @spec max_evidence_excerpts() :: pos_integer()
  def max_evidence_excerpts, do: 8

  # Reached: an excerpt is cut, on a character, never mid-character.
  @spec max_excerpt_bytes() :: pos_integer()
  def max_excerpt_bytes, do: 400

  # The uncertainty note, the failure words, the vendor's words and a delivery
  # error, as kept and as shown. Reached: the text is cut. The table's CHECK on
  # `outcome_uncertainty` holds the same 500.
  @spec max_record_text_bytes() :: pos_integer()
  def max_record_text_bytes, do: 500

  # One fact's value as the owner's report shows it. Reached: the value is cut.
  @spec max_report_fact_bytes() :: pos_integer()
  def max_report_fact_bytes, do: 200

  # The vendor's own words as the owner's report shows them. Reached: cut.
  @spec max_report_vendor_bytes() :: pos_integer()
  def max_report_vendor_bytes, do: 300

  # -- the transport -----------------------------------------------------------------

  # The create request's wait for its response: the session initializes, and
  # answers, before anyone picks up; the vendor's own initialization timeout
  # (its 504) is undocumented in length. Reached: the dispatch is unknown, the
  # call may exist, and it is never sent again.
  @spec create_response_wait_ms() :: pos_integer()
  def create_response_wait_ms, do: 60 * 1000

  # The hangup request's wait for its response. Reached: whether it ended the
  # call is unknown, and it is never sent again.
  @spec hangup_response_wait_ms() :: pos_integer()
  def hangup_response_wait_ms, do: 15 * 1000

  # The sideband's TCP and TLS connect. Reached: the attach failed.
  @spec sideband_connect_ms() :: pos_integer()
  def sideband_connect_ms, do: 5 * 1000

  # Each read of the sideband's upgrade response. Reached: the attach failed.
  @spec sideband_handshake_read_ms() :: pos_integer()
  def sideband_handshake_read_ms, do: 5 * 1000

  # One frame written to the sideband. Reached: whether it was written is
  # unknown, and it is never sent again.
  @spec sideband_send_ms() :: pos_integer()
  def sideband_send_ms, do: 5 * 1000

  # How many server event ids the sideband remembers, to deliver a replayed
  # event once. Reached: the oldest id is forgotten.
  @spec max_seen_event_ids() :: pos_integer()
  def max_seen_event_ids, do: 1_024

  # -- the provider's documented remote bounds -----------------------------------

  # The longest a create request can go unanswered before the worker stops
  # waiting for it (`PhoneCalls.Call`'s create watchdog): the latest a provider
  # session can start after the dispatch claim. Reached: the dispatch is
  # unknown, never sent again.
  @spec max_create_wait_ms() :: pos_integer()
  def max_create_wait_ms, do: 90 * 1000

  # OpenAI ends a call still ringing at this age, whether or not Fermix runs.
  @spec provider_ringing_limit_ms() :: pos_integer()
  def provider_ringing_limit_ms, do: 3 * @minute

  # OpenAI ends a connected call at this age, whether or not Fermix runs.
  @spec provider_connected_limit_ms() :: pos_integer()
  def provider_connected_limit_ms, do: 2 * @hour

  # Reached after the latest a session could have started (the dispatch claim
  # plus `max_create_wait_ms/0`): an unresolved call's slot may be released,
  # its outcome unknown.
  @spec provider_lifetime_bound_ms() :: pos_integer()
  def provider_lifetime_bound_ms, do: provider_ringing_limit_ms() + provider_connected_limit_ms()

  # How long an uncertain call holds the slot after its dispatch claim: the
  # latest its session could start, then the provider's own bound on it, so
  # the slot never frees while the provider could still hold the call.
  @spec slot_hold_ms() :: pos_integer()
  def slot_hold_ms, do: max_create_wait_ms() + provider_lifetime_bound_ms()

  # -- retention -----------------------------------------------------------------

  # Reached: a call's outcome and mandate audit are deleted, unless the owner deleted them earlier.
  @spec outcome_retention_days() :: pos_integer()
  def outcome_retention_days, do: 90

  # Reached: a call's confirmation excerpts are deleted, unless the owner deleted them earlier.
  @spec excerpt_retention_days() :: pos_integer()
  def excerpt_retention_days, do: 7
end
