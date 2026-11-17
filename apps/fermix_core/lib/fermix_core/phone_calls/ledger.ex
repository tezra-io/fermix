defmodule FermixCore.PhoneCalls.Ledger do
  @moduledoc """
  Public face over the `phone_calls` table (M94 §09), the `Harness.Ledger`
  shape: it owns call-id generation, reads `PhoneCalls.Limits`, validates and
  encodes what it writes in its caller's process, decodes what it reads, and
  hands every persistence step to `FermixCore.Memory.Repo`, the single
  serialized SQLite writer (`Memory.Repo.PhoneCallsSql`).

  A call id is `"pc_"` followed by 12 lowercase hex characters.

  ## The state vocabulary

      Call:    admitted → dispatching → connecting → ringing → active → closing → ended
                           ↘ dispatch_unknown      ↘ failed          ↘ closure_unconfirmed
      Outcome: pending | confirmed | unavailable | options | needs_owner | unknown
      Usage:   provisional | voice_duration_confirmed | incomplete
      Report:  pending | written | delivery_unconfirmed

  `ended`, `failed`, `dispatch_unknown` and `closure_unconfirmed` are terminal;
  the last two are uncertain (the remote call is not proven gone).

  ## Admission (`admit/3`)

  One `BEGIN IMMEDIATE`, in order: the same originating request (`request_id`,
  the requesting turn's session id) answers the call it already made, as
  `{:existing, row}`; the one-call slot; the day's attempts; the insert. A
  refusal writes nothing and so consumes nothing.

    * **The slot** is held by every non-terminal row, and by an uncertain row
      until it is released on verified termination (`release_slot/3`) or the
      provider's own bound on one call (`Limits.provider_lifetime_bound_ms/0`:
      its ringing limit plus its connected limit) has passed since the dispatch
      claim (`slot_expires_at`). Its outcome stays `unknown` either way.
    * **The day** is the rolling window `Limits.attempt_window_ms/0` ending at
      the admission's `now`, never a calendar day: no zone to choose, and never
      more than `Limits.max_attempts_per_day/0` attempts in any such window.
      Every row admitted in the window counts except one proven never to have
      dialed: terminal (`ended` or `failed`) with no dispatch claim.

  ## Transitions

  The per-call worker writes its own non-terminal steps, each a guarded
  forward-only reducer: `claim_dispatch/3` (only from `admitted`, and durable
  before any network I/O), `record_session/4`, `record_carrier_call/3`,
  `advance/4` (ringing is optional; a delayed event never regresses a row),
  `consume/3`, `record_usage/4`. `PhoneCalls.Manager` is the single terminal
  writer: `terminalize/4` (once only, `:already_terminal` after) and
  `fail_undispatched/4` (only from `admitted`). `ended` never implies
  `confirmed`: an outcome defaults to `unknown`, and `confirmed` needs evidence.
  """

  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.PhoneCallsSql
  alias FermixCore.Memory.Repo.TemporalSql
  alias FermixCore.PhoneCalls.Limits

  @id_prefix "pc_"
  @id_bytes 6
  @text_max 500
  @excerpt_max 400
  @max_excerpts 8
  @facts_json_max 4_096
  @recent_max 20

  @timestamp_columns ~w(created_at dispatch_claimed_at connecting_at ringing_at answered_at
                        closing_at ended_at call_deadline_at ringing_deadline_at slot_expires_at
                        cancel_requested_at evidence_pruned_at slot_released_at next_delivery_at
                        delivered_at)a
  @json_columns %{
    origin_conversation: :origin_conversation,
    send_opts_json: :send_opts,
    mandate_json: :mandate,
    outcome_facts_json: :outcome_facts,
    evidence_json: :evidence,
    usage_json: :usage,
    backend_usage_json: :backend_usage
  }

  @type row :: map()
  @type server_opts :: keyword()
  @type admission :: {:admitted, row()} | {:existing, row()}

  @doc "A fresh call id: `\"pc_\"` + 12 lowercase hex characters."
  @spec generate_id() :: String.t()
  def generate_id do
    @id_prefix <> Base.encode16(:crypto.strong_rand_bytes(@id_bytes), case: :lower)
  end

  @doc "Whether `id` has the shape of a call id."
  @spec call_id?(term()) :: boolean()
  def call_id?(id) when is_binary(id), do: Regex.match?(~r/^pc_[0-9a-f]{12}$/, id)
  def call_id?(_id), do: false

  # --- admission ---------------------------------------------------------------

  @doc """
  Admits a call `admitted` in one transaction (see the moduledoc), assigning a
  fresh id when `attrs` has none. `attrs` carries the evidence and snapshot
  columns: `request_id`, `owner_id`, `authorization` (`direct` | `confirmed`),
  `access_intent`, `origin_kind`, `origin_conversation`, `delivery_mode`,
  `platform`, `destination`, `thread`, `send_opts`, `mandate` (a JSON-safe map)
  and its `mandate_hash`, and `model`, `voice`, `prompt_version`,
  `carrier_profile`.
  """
  @spec admit(map(), DateTime.t(), server_opts()) ::
          {:ok, admission()}
          | {:error,
             {:slot_held, String.t()}
             | {:daily_attempts_exhausted, non_neg_integer()}
             | {:invalid, atom(), term()}
             | term()}
  def admit(attrs, %DateTime{} = now, opts \\ []) when is_map(attrs) and is_list(opts) do
    with {:ok, row} <- admission_row(Map.put_new_lazy(attrs, :id, &generate_id/0), now) do
      window_start = DateTime.add(now, -Limits.attempt_window_ms(), :millisecond)

      bounds = %{
        now: stamp(now),
        window_start: stamp(window_start),
        max_attempts: Limits.max_attempts_per_day()
      }

      {:admit, row, bounds} |> call(opts) |> decode_admission()
    end
  end

  # --- the worker's non-terminal steps ---------------------------------------

  @doc """
  The dispatch claim: `admitted` → `dispatching`, with the call's absolute
  deadlines and the slot's expiry, written before any network I/O. A row no
  longer `admitted` (cancelled, disabled, already claimed) answers
  `{:error, {:not_admitted, status}}` and must not be dialed.
  """
  @spec claim_dispatch(String.t(), DateTime.t(), server_opts()) ::
          {:ok, row()} | {:error, {:not_admitted, String.t()} | :not_found | term()}
  def claim_dispatch(id, %DateTime{} = now, opts \\ []) when is_binary(id) and is_list(opts) do
    fields = %{
      dispatch_claimed_at: stamp(now),
      call_deadline_at: stamp(DateTime.add(now, Limits.call_deadline_ms(), :millisecond)),
      ringing_deadline_at: stamp(DateTime.add(now, Limits.ringing_timeout_ms(), :millisecond)),
      slot_expires_at: stamp(DateTime.add(now, Limits.provider_lifetime_bound_ms(), :millisecond))
    }

    {:claim_dispatch, id, fields} |> call(opts) |> decode_one()
  end

  @doc """
  Records the provider's session id exactly as the provider returned it, once:
  a dispatching row becomes `connecting`; the same id again answers the row
  unchanged; another id is `{:error, :session_mismatch}`, and a row never
  dispatched is `{:error, :not_dispatched}`.
  """
  @spec record_session(String.t(), String.t(), DateTime.t(), server_opts()) ::
          {:ok, row()} | {:error, :session_mismatch | :not_dispatched | :not_found | term()}
  def record_session(id, session_id, %DateTime{} = now, opts \\ [])
      when is_binary(id) and is_binary(session_id) and session_id != "" and is_list(opts) do
    {:record_session, id, session_id, stamp(now)} |> call(opts) |> decode_one()
  end

  @doc """
  Records the carrier's own call id once, only when the carrier reported one;
  never derived from the provider session id.
  """
  @spec record_carrier_call(String.t(), String.t(), server_opts()) ::
          {:ok, row()} | {:error, :carrier_call_mismatch | :not_found | term()}
  def record_carrier_call(id, carrier_call_id, opts \\ [])
      when is_binary(id) and is_binary(carrier_call_id) and carrier_call_id != "" and
             is_list(opts) do
    {:record_carrier_call, id, carrier_call_id} |> call(opts) |> decode_one()
  end

  @doc """
  Takes one forward step (`"ringing"`, `"active"` or `"closing"`) from any
  lower step after the session is known. A step at or below the row's answers
  the row unchanged, so a late event never regresses it.
  """
  @spec advance(String.t(), String.t(), DateTime.t(), server_opts()) ::
          {:ok, row()} | {:error, :not_found | term()}
  def advance(id, step, %DateTime{} = now, opts \\ [])
      when is_binary(id) and is_binary(step) and is_list(opts) do
    if step in PhoneCallsSql.steps(),
      do: {:advance, id, step, stamp(now)} |> call(opts) |> decode_one(),
      else: {:error, {:invalid, :step, step}}
  end

  @doc """
  Consumes one unit of a bounded counter before the side effect it pays for:
  `:core_turns`, `:dtmf_keys` or `:cleanup_attempts`, each capped by
  `PhoneCalls.Limits`. At the cap it is `{:error, {:cap_reached, counter}}`
  and the side effect must not happen.
  """
  @spec consume(String.t(), :core_turns | :dtmf_keys | :cleanup_attempts, server_opts()) ::
          {:ok, row()} | {:error, {:cap_reached, atom()} | :not_found | term()}
  def consume(id, counter, opts \\ []) when is_binary(id) and is_list(opts) do
    case cap(counter) do
      {:ok, cap} -> {:consume, id, counter, cap} |> call(opts) |> decode_one()
      :error -> {:error, {:invalid, :counter, counter}}
    end
  end

  @doc """
  Replaces the row's cumulative usage snapshot while the call runs; never sums.
  A snapshot reporting less voice time than the row holds is older and leaves
  the row unchanged.
  """
  @spec record_usage(String.t(), map(), non_neg_integer() | nil, server_opts()) ::
          {:ok, row()} | {:error, term()}
  def record_usage(id, usage, voice_seconds, opts \\ [])
      when is_binary(id) and is_map(usage) and
             (is_nil(voice_seconds) or (is_integer(voice_seconds) and voice_seconds >= 0)) and
             is_list(opts) do
    with {:ok, json} <- encode(:usage, usage) do
      {:record_usage, id, json, voice_seconds} |> call(opts) |> decode_one()
    end
  end

  @doc "Marks that the owner, or the off switch, asked a live call to stop."
  @spec mark_cancel_requested(String.t(), DateTime.t(), server_opts()) ::
          {:ok, row()} | {:error, term()}
  def mark_cancel_requested(id, %DateTime{} = now, opts \\ []) when is_binary(id) do
    {:mark_cancel_requested, id, stamp(now)} |> call(opts) |> decode_one()
  end

  # --- the Manager's terminal writes ------------------------------------------

  @doc """
  Ends a row that never dispatched as `failed`, nothing dialed, only while it
  is still `admitted`: a row the worker claimed meanwhile answers
  `{:error, {:dispatched, status}}`, and one already terminal
  `{:error, :already_terminal}`. `reason` names why; `fields` may carry the
  hand-off lease (`next_delivery_at`).
  """
  @spec fail_undispatched(String.t(), String.t(), DateTime.t(), keyword()) ::
          {:ok, row()} | {:error, :already_terminal | {:dispatched, String.t()} | term()}
  def fail_undispatched(id, reason, %DateTime{} = now, opts \\ [])
      when is_binary(id) and is_binary(reason) and reason != "" and is_list(opts) do
    fields = %{
      outcome: "unknown",
      usage_state: "voice_duration_confirmed",
      voice_seconds: 0,
      failure_reason: bound(reason),
      ended_at: stamp(now)
    }

    fields = put_lease(fields, Keyword.get(opts, :next_delivery_at))
    {:fail_undispatched, id, fields} |> call(opts) |> decode_one()
  end

  @doc """
  The once-only terminal write. `status` is `ended`, `failed`,
  `dispatch_unknown` or `closure_unconfirmed`; `fields` may carry `outcome`
  (default `unknown`), `outcome_facts`, `evidence` (excerpts), `usage`,
  `voice_seconds`, `usage_state`, `backend_usage`, `failure_reason`,
  `vendor_message` and `next_delivery_at` (the hand-off lease). The provider's
  and the carrier's ids are never set here: each is written once, by its own
  guarded step. `confirmed` needs at least one
  evidence excerpt and an `ended` or `closure_unconfirmed` call;
  `dispatch_unknown` is always `unknown`.
  """
  @spec terminalize(String.t(), String.t(), map(), server_opts()) ::
          {:ok, row()}
          | {:error, :already_terminal | :not_found | {:invalid, atom(), term()} | term()}
  def terminalize(id, status, fields, opts \\ [])
      when is_binary(id) and is_binary(status) and is_map(fields) and is_list(opts) do
    with :ok <- check_terminal_status(status),
         {:ok, encoded} <- terminal_fields(status, fields) do
      {:terminalize, id, status, encoded} |> call(opts) |> decode_one()
    end
  end

  @doc "Records the vendor's words when a cleanup request (hangup) failed."
  @spec record_cleanup_error(String.t(), String.t(), server_opts()) ::
          {:ok, row()} | {:error, term()}
  def record_cleanup_error(id, text, opts \\ []) when is_binary(id) and is_binary(text) do
    {:record_cleanup_error, id, bound(text)} |> call(opts) |> decode_one()
  end

  @doc """
  Releases the slot of an uncertain row on verified termination. Its outcome
  is untouched. Only the evidence-backed reason exists: a model-supplied flag,
  an absent search result or a local process exit is no reason.
  """
  @spec release_slot(String.t(), :verified_termination, DateTime.t(), server_opts()) ::
          {:ok, row()} | {:error, {:not_releasable, String.t()} | term()}
  def release_slot(id, :verified_termination, %DateTime{} = now, opts \\ [])
      when is_binary(id) do
    {:release_slot, id, "verified_termination", stamp(now)} |> call(opts) |> decode_one()
  end

  @doc """
  Updates a terminal row's report state: `report_status`, `delivery_attempts`,
  `next_delivery_at`, `last_delivery_error`, `delivered_at`.
  """
  @spec mark_report(String.t(), map(), server_opts()) :: {:ok, row()} | {:error, term()}
  def mark_report(id, fields, opts \\ [])
      when is_binary(id) and is_map(fields) and map_size(fields) > 0 do
    with {:ok, encoded} <- report_fields(fields) do
      {:mark_report, id, encoded} |> call(opts) |> decode_one()
    end
  end

  # --- reads -------------------------------------------------------------------

  @spec get(String.t(), server_opts()) :: {:ok, row()} | {:error, :not_found | term()}
  def get(id, opts \\ []) when is_binary(id), do: {:get, id} |> call(opts) |> decode_one()

  @doc "One call, only if it is `owner_id`'s: another owner's id is `:not_found`."
  @spec get_for_owner(String.t(), String.t(), server_opts()) ::
          {:ok, row()} | {:error, :not_found | term()}
  def get_for_owner(id, owner_id, opts \\ []) when is_binary(id) and is_binary(owner_id),
    do: {:get_for_owner, id, owner_id} |> call(opts) |> decode_one()

  @doc "The owner's most recent calls, newest first (`opts[:limit]`, at most #{@recent_max})."
  @spec list_recent(String.t(), keyword()) :: {:ok, [row()]} | {:error, term()}
  def list_recent(owner_id, opts \\ []) when is_binary(owner_id) and is_list(opts) do
    limit = opts |> Keyword.get(:limit, @recent_max) |> min(@recent_max) |> max(1)
    {:list_recent, owner_id, limit} |> call(opts) |> decode_many()
  end

  @doc "The rows holding the one-call slot at `now` (normally zero or one)."
  @spec outstanding(DateTime.t(), server_opts()) :: {:ok, [row()]} | {:error, term()}
  def outstanding(%DateTime{} = now, opts \\ []),
    do: {:outstanding, stamp(now)} |> call(opts) |> decode_many()

  @doc "Every non-terminal row: what boot reconciliation settles."
  @spec unsettled(server_opts()) :: {:ok, [row()]} | {:error, term()}
  def unsettled(opts \\ []), do: {:unsettled} |> call(opts) |> decode_many()

  @doc "The uncertain rows still holding the slot at `now`: the recovery view's rows."
  @spec unresolved(DateTime.t(), server_opts()) :: {:ok, [row()]} | {:error, term()}
  def unresolved(%DateTime{} = now, opts \\ []),
    do: {:unresolved, stamp(now)} |> call(opts) |> decode_many()

  @doc "Terminal rows whose report is pending and due at `now`, oldest first."
  @spec pending_reports(DateTime.t(), pos_integer(), server_opts()) ::
          {:ok, [row()]} | {:error, term()}
  def pending_reports(%DateTime{} = now, limit, opts \\ [])
      when is_integer(limit) and limit > 0,
      do: {:pending_reports, stamp(now), limit} |> call(opts) |> decode_many()

  @doc """
  Retention (M94 §11): deletes terminal rows older than
  `Limits.outcome_retention_days/0` that no longer hold the slot, and clears
  the excerpts of rows that ended longer ago than
  `Limits.excerpt_retention_days/0`.
  """
  @spec prune(DateTime.t(), server_opts()) ::
          {:ok, %{deleted: non_neg_integer(), excerpts_cleared: non_neg_integer()}}
          | {:error, term()}
  def prune(%DateTime{} = now, opts \\ []) do
    audit = DateTime.add(now, -Limits.outcome_retention_days() * 86_400, :second)
    excerpts = DateTime.add(now, -Limits.excerpt_retention_days() * 86_400, :second)
    call({:prune, stamp(now), stamp(audit), stamp(excerpts)}, opts)
  end

  @doc "Whether `row` holds the one-call slot at `now` (the SQL rule, for a row in hand)."
  @spec holds_slot?(row(), DateTime.t()) :: boolean()
  def holds_slot?(%{status: status} = row, %DateTime{} = now) do
    cond do
      status in PhoneCallsSql.non_terminal_statuses() -> true
      status not in PhoneCallsSql.uncertain_statuses() -> false
      not is_nil(Map.get(row, :slot_released_at)) -> false
      true -> unexpired?(Map.get(row, :slot_expires_at), now)
    end
  end

  @doc "Whether `status` is terminal."
  @spec terminal?(String.t()) :: boolean()
  def terminal?(status) when is_binary(status), do: status in PhoneCallsSql.terminal_statuses()

  # --- admission row -----------------------------------------------------------

  defp admission_row(attrs, now) do
    with {:ok, id} <- fetch_id(attrs),
         {:ok, required} <- required_text(attrs),
         :ok <- check_enum(:authorization, attrs[:authorization], ~w(direct confirmed)),
         :ok <- check_enum(:origin_kind, attrs[:origin_kind], ~w(chat voice)),
         :ok <- check_enum(:delivery_mode, attrs[:delivery_mode], ~w(origin channel)),
         :ok <- check_hash(attrs[:mandate_hash]),
         {:ok, mandate} <- encode(:mandate, Map.get(attrs, :mandate)),
         {:ok, conversation} <- encode_optional(:origin_conversation, attrs[:origin_conversation]),
         {:ok, send_opts} <- encode_optional(:send_opts, attrs[:send_opts]) do
      {:ok,
       Map.merge(required, %{
         id: id,
         operation: "phone_call.start",
         authorization: attrs.authorization,
         access_intent: optional_text(attrs[:access_intent]),
         origin_kind: attrs.origin_kind,
         origin_conversation: conversation,
         delivery_mode: attrs.delivery_mode,
         thread: optional_text(attrs[:thread]),
         send_opts_json: send_opts,
         mandate_json: mandate,
         mandate_hash: attrs.mandate_hash,
         status: "admitted",
         created_at: stamp(now)
       })}
    end
  end

  @required_text ~w(request_id owner_id platform destination model voice prompt_version
                    carrier_profile)a

  defp required_text(attrs) do
    Enum.reduce_while(@required_text, {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.get(attrs, key) do
        value when is_binary(value) and value != "" -> {:cont, {:ok, Map.put(acc, key, value)}}
        other -> {:halt, {:error, {:invalid, key, other}}}
      end
    end)
  end

  defp fetch_id(%{id: id}) do
    if call_id?(id), do: {:ok, id}, else: {:error, {:invalid, :id, id}}
  end

  defp check_enum(key, value, allowed) do
    if value in allowed, do: :ok, else: {:error, {:invalid, key, value}}
  end

  defp check_hash(hash) when is_binary(hash) do
    if Regex.match?(~r/^[0-9a-f]{64}$/, hash),
      do: :ok,
      else: {:error, {:invalid, :mandate_hash, hash}}
  end

  defp check_hash(hash), do: {:error, {:invalid, :mandate_hash, hash}}

  # --- terminal fields ---------------------------------------------------------

  defp check_terminal_status(status) do
    if terminal?(status), do: :ok, else: {:error, {:invalid, :status, status}}
  end

  defp terminal_fields(status, fields) do
    outcome = Map.get(fields, :outcome) || "unknown"
    evidence = fields |> Map.get(:evidence, []) |> List.wrap() |> bound_excerpts()

    with {:ok, ended_at} <- fetch_ended_at(fields),
         :ok <- check_outcome(status, outcome, evidence),
         :ok <-
           check_enum(:usage_state, usage_state(status, fields), PhoneCallsSql.usage_states()),
         {:ok, encoded} <- encode_terminal_json(fields, evidence) do
      {:ok,
       fields
       |> Map.take([:voice_seconds])
       |> Map.merge(encoded)
       |> Map.merge(%{
         outcome: outcome,
         usage_state: usage_state(status, fields),
         failure_reason: optional_bound(Map.get(fields, :failure_reason)),
         vendor_message: optional_bound(Map.get(fields, :vendor_message)),
         ended_at: stamp(ended_at)
       })
       |> put_lease(Map.get(fields, :next_delivery_at))
       |> reject_nil()}
    end
  end

  defp fetch_ended_at(%{ended_at: %DateTime{} = at}), do: {:ok, at}
  defp fetch_ended_at(fields), do: {:error, {:invalid, :ended_at, Map.get(fields, :ended_at)}}

  defp check_outcome(status, outcome, evidence) do
    cond do
      outcome not in PhoneCallsSql.terminal_outcomes() ->
        {:error, {:invalid, :outcome, outcome}}

      status == "dispatch_unknown" and outcome != "unknown" ->
        {:error, {:invalid, :outcome, outcome}}

      outcome == "confirmed" and evidence == [] ->
        {:error, {:invalid, :outcome, :no_evidence}}

      outcome == "confirmed" and status not in ~w(ended closure_unconfirmed) ->
        {:error, {:invalid, :outcome, {:confirmed_on, status}}}

      true ->
        :ok
    end
  end

  # An uncertain end never had its final usage confirmed.
  defp usage_state(status, _fields) when status in ["dispatch_unknown", "closure_unconfirmed"],
    do: "incomplete"

  defp usage_state(_status, fields), do: Map.get(fields, :usage_state) || "incomplete"

  defp encode_terminal_json(fields, evidence) do
    with {:ok, facts} <- encode_facts(Map.get(fields, :outcome_facts)),
         {:ok, evidence} <- encode_optional(:evidence, nil_if_empty(evidence)),
         {:ok, usage} <- encode_optional(:usage, Map.get(fields, :usage)),
         {:ok, backend} <- encode_optional(:backend_usage, Map.get(fields, :backend_usage)) do
      {:ok,
       %{
         outcome_facts_json: facts,
         evidence_json: evidence,
         usage_json: usage,
         backend_usage_json: backend
       }}
    end
  end

  defp encode_facts(nil), do: {:ok, nil}

  defp encode_facts(facts) when is_map(facts) do
    with {:ok, json} <- encode(:outcome_facts, facts) do
      if byte_size(json) <= @facts_json_max,
        do: {:ok, json},
        else: {:error, {:invalid, :outcome_facts, :too_large}}
    end
  end

  defp encode_facts(other), do: {:error, {:invalid, :outcome_facts, other}}

  # Bounded evidence: at most `@max_excerpts` excerpts, each a speaker label and
  # at most `@excerpt_max` bytes of what was said, stored under string keys
  # whichever keys it came with. An excerpt with no text is no evidence.
  defp bound_excerpts(excerpts) do
    excerpts
    |> Enum.flat_map(&excerpt/1)
    |> Enum.take(@max_excerpts)
  end

  defp excerpt(%{} = excerpt) do
    text = Map.get(excerpt, :text) || Map.get(excerpt, "text")
    speaker = Map.get(excerpt, :speaker) || Map.get(excerpt, "speaker")

    if is_binary(text) and String.trim(text) != "",
      do: [%{"speaker" => to_string(speaker || "unknown"), "text" => bound(text, @excerpt_max)}],
      else: []
  end

  defp excerpt(_other), do: []

  defp nil_if_empty([]), do: nil
  defp nil_if_empty(list), do: list

  # --- report fields -------------------------------------------------------------

  defp report_fields(fields) do
    with :ok <- check_report_status(Map.get(fields, :report_status)) do
      {:ok,
       fields
       |> Map.take([
         :report_status,
         :delivery_attempts,
         :next_delivery_at,
         :last_delivery_error,
         :delivered_at
       ])
       |> Map.new(fn
         {key, %DateTime{} = at} -> {key, stamp(at)}
         {:last_delivery_error, text} when is_binary(text) -> {:last_delivery_error, bound(text)}
         pair -> pair
       end)}
    end
  end

  defp check_report_status(nil), do: :ok

  defp check_report_status(status),
    do: check_enum(:report_status, status, PhoneCallsSql.report_statuses())

  # --- counters ------------------------------------------------------------------

  defp cap(:core_turns), do: {:ok, Limits.max_core_turns_per_call()}
  defp cap(:dtmf_keys), do: {:ok, Limits.max_dtmf_keys()}

  defp cap(:cleanup_attempts),
    do: {:ok, Limits.max_immediate_termination_requests() + Limits.max_cleanup_retries()}

  defp cap(_counter), do: :error

  # --- decoding ------------------------------------------------------------------

  defp decode_admission({:ok, {kind, raw}}) when kind in [:admitted, :existing],
    do: {:ok, {kind, decode_row(raw)}}

  defp decode_admission({:error, reason}), do: {:error, reason}

  defp decode_one({:ok, raw}) when is_map(raw), do: {:ok, decode_row(raw)}
  defp decode_one({:error, reason}), do: {:error, reason}

  defp decode_many({:ok, rows}) when is_list(rows), do: {:ok, Enum.map(rows, &decode_row/1)}
  defp decode_many({:error, reason}), do: {:error, reason}

  # The table's CHECKs admit only valid JSON and fixed-width stamps, so a value
  # that fails to decode here is a corrupted store: it raises in the caller's
  # process, never in the Repo's.
  defp decode_row(raw) do
    raw
    |> Map.new(fn {key, value} -> decode_column(key, value) end)
  end

  defp decode_column(key, value) when key in @timestamp_columns, do: {key, parse_stamp(value)}

  defp decode_column(key, value) when is_map_key(@json_columns, key),
    do: {Map.fetch!(@json_columns, key), value && Jason.decode!(value)}

  defp decode_column(key, value), do: {key, value}

  defp parse_stamp(nil), do: nil

  defp parse_stamp(value) when is_binary(value) do
    {:ok, at, 0} = DateTime.from_iso8601(value)
    at
  end

  # --- helpers ---------------------------------------------------------------------

  defp encode(key, value) when is_map(value) or is_list(value) do
    case Jason.encode(value) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:invalid, key, {:not_json, Exception.message(reason)}}}
    end
  end

  defp encode(key, value), do: {:error, {:invalid, key, value}}

  defp encode_optional(_key, nil), do: {:ok, nil}
  defp encode_optional(key, value), do: encode(key, value)

  defp optional_text(value) when is_binary(value) and value != "", do: value
  defp optional_text(_value), do: nil

  defp optional_bound(value) when is_binary(value) and value != "", do: bound(value)
  defp optional_bound(_value), do: nil

  defp bound(text), do: bound(text, @text_max)

  defp bound(text, max) when is_binary(text) and byte_size(text) <= max, do: text
  defp bound(text, max) when is_binary(text), do: utf8_prefix(text, max, 3)
  defp bound(_text, _max), do: ""

  # A byte cut can land inside a codepoint; at most three bytes are shaved.
  defp utf8_prefix(text, size, shaves) when shaves >= 0 do
    prefix = binary_part(text, 0, size)
    if String.valid?(prefix), do: prefix, else: utf8_prefix(text, size - 1, shaves - 1)
  end

  defp utf8_prefix(_text, _size, _shaves), do: ""

  defp put_lease(fields, %DateTime{} = at), do: Map.put(fields, :next_delivery_at, stamp(at))
  defp put_lease(fields, nil), do: fields

  defp unexpired?(%DateTime{} = expires_at, now), do: DateTime.compare(expires_at, now) == :gt
  defp unexpired?(_absent, _now), do: false

  defp reject_nil(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()

  defp stamp(%DateTime{} = at) do
    {:ok, value} = TemporalSql.timestamp(at)
    value
  end

  defp call(request, opts),
    do: Repo.phone_calls_call(request, Keyword.take(opts, [:server, :timeout, :on_timeout]))
end
