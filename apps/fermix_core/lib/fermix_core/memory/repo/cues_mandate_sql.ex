defmodule FermixCore.Memory.Repo.CuesMandateSql do
  @moduledoc """
  SQL for mandate calls, proposals and mandate approvals (PLAN §4.6). Lane F owns it.

  Pure SQL over the caller's `conn`, reached only through
  `FermixCore.Memory.Repo.cues_call/3`. One `handle/2` head per request tuple,
  added above the catch-all, which must stay last; helpers live below it.
  Transactions go through `CuesSql.with_immediate_transaction/2`.

  A mandate call is written in three Repo calls (design §10.3): `{:open_call,
  …}` before any check, one `{:decide_*, …}` before the executor runs or the
  proposal is sent (the run's first `allow` or `propose` also sets
  `job_runs.tools_started_at` in that transaction, and a `propose` inserts its
  `cue_proposals` row there), and `{:finish_call, …}` (or the proposal's own
  settle) once the result is known. Every state change of a row is a
  compare-and-set on its current state; zero rows changed is `{:error, :stale}`.

  A confirm or a denial is one `UPDATE … WHERE state = 'waiting' AND
  token_digest = ? AND sent_platform = ? AND sent_chat_id = ? AND sent_user_id
  = ? AND expires_at > ?` (Fable review issue 2), so a wrong chat never spends
  the token and a second tap finds nothing waiting. An answer from one of the
  owner's devices (M60 app surface §3.7, D28) is the same `UPDATE` fenced on
  the proposal's id instead of its token and chat (`{:decide_proposal, …}`):
  the transport authenticated the device, so the first answer from any surface
  wins and every later one finds nothing waiting.
  """

  alias FermixCore.Memory.Repo.CuesSql

  @proposal_columns """
  p.id, p.mandate_call_id, p.run_id, p.job_id, p.mandate, p.watcher_id, p.delivery_id, p.tool,
  p.args_json, p.idempotency_key, p.state, p.sent_platform, p.sent_chat_id, p.sent_user_id,
  p.created_at, p.expires_at, p.decided_at, p.refusal_reason, p.result_status, p.result_summary,
  p.finished_at, p.reported_at, r.session_id
  """

  # What an app surface shows of a proposal (Cues.Proposals' record and card):
  # Fermix's own columns, the names of its task and watcher, and, for the card,
  # the recorded arguments and the cue's snapshot (outside text).
  @card_select """
  SELECT p.id, p.state, p.mandate, p.tool, p.job_id, j.name, w.name, d.source_ref, p.created_at,
         p.expires_at, p.decided_at, p.decided_from, p.result_status, p.args_json, d.received_at,
         c.occurred_at, c.snapshot
  FROM cue_proposals p
  LEFT JOIN scheduled_jobs j ON j.id = p.job_id
  LEFT JOIN cue_watchers w ON w.id = p.watcher_id
  LEFT JOIN cue_deliveries d ON d.id = p.delivery_id
  LEFT JOIN cues c ON c.id = d.cue_id
  """

  @doc "Serves one request on `conn`; an unknown request is an error, never a raise."
  @spec handle(term(), tuple()) :: term()
  # `{:list_run_calls, run_id}` (lane C2) → `{:ok, [call]}`: the run's mandate
  # calls, oldest first, for Fermix's report on the run's message.
  def handle(conn, {:list_run_calls, run_id}) when is_binary(run_id) do
    sql = """
    SELECT id, mandate, tool, args_json, decision, reason, validator, proposal_id, result_status,
           result_summary, created_at, decided_at, finished_at
    FROM cue_mandate_calls WHERE run_id = ? ORDER BY created_at, id
    """

    with {:ok, rows} <- CuesSql.query_all(conn, sql, [run_id]) do
      {:ok,
       Enum.map(rows, fn [
                           id,
                           mandate,
                           tool,
                           args,
                           decision,
                           reason,
                           validator,
                           proposal_id,
                           status,
                           summary,
                           created_at,
                           decided_at,
                           finished_at
                         ] ->
         %{
           id: id,
           mandate: mandate,
           tool: tool,
           args_json: args,
           decision: decision,
           reason: reason,
           validator: validator,
           proposal_id: proposal_id,
           result_status: status,
           result_summary: summary,
           created_at: CuesSql.parse_stamp(created_at),
           decided_at: CuesSql.parse_stamp(decided_at),
           finished_at: CuesSql.parse_stamp(finished_at)
         }
       end)}
    end
  end

  # Repo call (1): the row, before any check. Also reads, in the same
  # transaction, what the checks need: the run's earlier allowed or proposed
  # calls (`calls_this_run`), the task's allowed or proposed calls since
  # `hour_ago` (the loop breaker) and the cue's snapshot (for a proposal).
  def handle(conn, {:open_call, %{id: id} = attrs}) when is_binary(id) do
    CuesSql.with_immediate_transaction(conn, fn -> open_call(conn, attrs) end)
  end

  # Repo call (2) for a refusal: the decision, its reason and the end of the
  # row in one write (a refused call never runs, so nothing follows it).
  def handle(conn, {:decide_refuse, call_id, reason, validator, %DateTime{} = now})
      when is_binary(call_id) and is_binary(reason) and validator in [nil, "program", "none"] do
    sql = """
    UPDATE cue_mandate_calls SET decision = 'refuse', reason = ?, validator = ?, decided_at = ?,
      finished_at = ?
    WHERE id = ? AND decision IS NULL
    """

    stamp = CuesSql.stamp(now)
    one_row(conn, sql, [reason, validator, stamp, stamp, call_id])
  end

  # Repo call (2) for an allowed call in `auto` mode: the decision and, for the
  # run's first allowed or proposed call, `job_runs.tools_started_at`.
  def handle(conn, {:decide_allow, call_id, run_id, validator, %DateTime{} = now})
      when is_binary(call_id) and is_binary(run_id) and validator in ["program", "none"] do
    CuesSql.with_immediate_transaction(conn, fn ->
      sql = """
      UPDATE cue_mandate_calls SET decision = 'allow', validator = ?, decided_at = ?
      WHERE id = ? AND decision IS NULL
      """

      stamp = CuesSql.stamp(now)

      with {:ok, :ok} <- one_row(conn, sql, [validator, stamp, call_id]),
           :ok <- mark_tools_started(conn, run_id, stamp) do
        {:ok, :ok}
      end
    end)
  end

  # Repo call (2) for an allowed call in `approve` mode: the decision, the
  # marker and the proposal, in one transaction. A proposal with the same
  # idempotency key is not stored again: the call row points at it and the
  # caller tells the model its state.
  def handle(conn, {:decide_propose, call_id, %{id: proposal_id} = proposal, %DateTime{} = now})
      when is_binary(call_id) and is_binary(proposal_id) do
    CuesSql.with_immediate_transaction(conn, fn ->
      decide_propose(conn, call_id, proposal, now)
    end)
  end

  # Repo call (3) for a call the executor ran.
  def handle(conn, {:finish_call, call_id, status, summary, %DateTime{} = now})
      when is_binary(call_id) and is_binary(status) do
    sql = """
    UPDATE cue_mandate_calls SET result_status = ?, result_summary = ?, finished_at = ?
    WHERE id = ? AND finished_at IS NULL
    """

    one_row(conn, sql, [status, summary, CuesSql.stamp(now), call_id])
  end

  # A proposal that will not run: its send failed (`waiting`), or the checks at
  # confirmation refused it (`confirmed`). Its call row ends with it.
  def handle(conn, {:refuse_proposal, proposal_id, from_state, reason, %DateTime{} = now})
      when is_binary(proposal_id) and from_state in ["waiting", "confirmed"] and
             is_binary(reason) do
    CuesSql.with_immediate_transaction(conn, fn ->
      settle_proposal(conn, proposal_id, from_state, "refused", reason, now)
    end)
  end

  # The owner's confirm: `waiting → confirmed`, fenced on the token, the chat it
  # was sent to and the expiry. `{:error, why}` names why nothing changed.
  def handle(conn, {:confirm_proposal, digest, origin, %DateTime{} = now})
      when is_binary(digest) and is_map(origin) do
    CuesSql.with_immediate_transaction(conn, fn ->
      decide_waiting(conn, digest, origin, "confirmed", now)
    end)
  end

  # The owner's denial: `waiting → denied`, with the confirm's fence. The call
  # row ends with it.
  def handle(conn, {:deny_proposal, digest, origin, %DateTime{} = now})
      when is_binary(digest) and is_map(origin) do
    CuesSql.with_immediate_transaction(conn, fn ->
      with {:ok, proposal} <- decide_waiting(conn, digest, origin, "denied", now),
           :ok <- end_call(conn, proposal.mandate_call_id, "denied", "You denied it.", now) do
        {:ok, proposal}
      end
    end)
  end

  # An answer from one of the owner's devices: `waiting → confirmed | denied`,
  # fenced on the id, the state and the expiry, recording where it came from.
  # A denial ends the call row with it. `{:error, why}` names why nothing changed.
  def handle(conn, {:decide_proposal, proposal_id, to_state, decided_from, %DateTime{} = now})
      when is_binary(proposal_id) and to_state in ["confirmed", "denied"] and
             is_binary(decided_from) do
    CuesSql.with_immediate_transaction(conn, fn ->
      decide_by_id(conn, proposal_id, to_state, decided_from, now)
    end)
  end

  # What an app surface lists: the proposals still waiting at `now`, oldest
  # first, or every proposal made since `since`, newest first; at most `limit`.
  def handle(conn, {:proposal_cards, :waiting, %DateTime{} = now, limit})
      when is_integer(limit) and limit > 0 do
    where = "WHERE p.state = 'waiting' AND p.expires_at > ? ORDER BY p.created_at, p.id LIMIT ?"
    list_cards(conn, where, [CuesSql.stamp(now), limit])
  end

  def handle(conn, {:proposal_cards, {:since, %DateTime{} = since}, limit})
      when is_integer(limit) and limit > 0 do
    where = "WHERE p.created_at >= ? ORDER BY p.created_at DESC, p.id DESC LIMIT ?"
    list_cards(conn, where, [CuesSql.stamp(since), limit])
  end

  # One proposal as an app surface shows it, or nil.
  def handle(conn, {:proposal_card, proposal_id}) when is_binary(proposal_id) do
    case list_cards(conn, "WHERE p.id = ?", [proposal_id]) do
      {:ok, []} -> {:ok, nil}
      {:ok, [card]} -> {:ok, card}
      {:ok, cards} -> {:error, {:unexpected_rows, length(cards)}}
      {:error, reason} -> {:error, reason}
    end
  end

  # A confirmed proposal's result, written to the proposal and its call row.
  def handle(conn, {:finish_proposal, proposal_id, status, summary, %DateTime{} = now})
      when is_binary(proposal_id) and is_binary(status) do
    CuesSql.with_immediate_transaction(conn, fn ->
      finish_proposal(conn, proposal_id, status, summary, now)
    end)
  end

  # The sweep: waiting proposals past `expires_at` become `expired`, oldest
  # first, at most `limit`; their call rows end with them.
  def handle(conn, {:expire_proposals, %DateTime{} = now, limit})
      when is_integer(limit) and limit > 0 do
    CuesSql.with_immediate_transaction(conn, fn -> expire_proposals(conn, now, limit) end)
  end

  # The unknown-outcome report: confirmed proposals with no result whose confirm
  # is older than `cutoff`, not yet reported. Each is claimed (`reported_at`)
  # here; `{:release_report, id}` undoes a claim whose send failed.
  def handle(conn, {:claim_unknown_outcomes, %DateTime{} = now, %DateTime{} = cutoff, limit})
      when is_integer(limit) and limit > 0 do
    CuesSql.with_immediate_transaction(conn, fn ->
      claim_unknown_outcomes(conn, now, cutoff, limit)
    end)
  end

  def handle(conn, {:release_report, proposal_id}) when is_binary(proposal_id) do
    sql = "UPDATE cue_proposals SET reported_at = NULL WHERE id = ? AND finished_at IS NULL"
    one_row(conn, sql, [proposal_id])
  end

  # An allowed call whose result never came (a crash or a stop between the
  # decision and the result), once its run has ended or is gone: finished
  # `unknown` with `summary`, oldest first, at most `limit`. Returns the ids.
  def handle(conn, {:finish_unreported_allows, summary, %DateTime{} = now, limit})
      when is_binary(summary) and is_integer(limit) and limit > 0 do
    CuesSql.with_immediate_transaction(conn, fn ->
      finish_unreported_allows(conn, summary, now, limit)
    end)
  end

  # One proposal by its token digest or by id, or nil.
  def handle(conn, {:get_proposal, {:digest, digest}}) when is_binary(digest),
    do: fetch_proposal(conn, "p.token_digest = ?", [digest])

  def handle(conn, {:get_proposal, {:id, id}}) when is_binary(id),
    do: fetch_proposal(conn, "p.id = ?", [id])

  # What the validator's request needs at a confirm: the proposing run's other
  # allowed or proposed calls, and the cue the run held (design §10.2).
  def handle(conn, {:proposal_context, proposal_id}) when is_binary(proposal_id) do
    with {:ok, proposal} <- conn |> fetch_proposal("p.id = ?", [proposal_id]) |> require_row(),
         {:ok, calls} <-
           count_actions(conn, "run_id = ? AND id != ?", [
             proposal.run_id,
             proposal.mandate_call_id
           ]),
         {:ok, cue} <- delivery_cue(conn, proposal.delivery_id) do
      {:ok, %{calls_this_run: calls, cue: cue}}
    end
  end

  # A mandate's approval row, or nil.
  def handle(conn, {:get_approval, mandate}) when is_binary(mandate) do
    sql = """
    SELECT mandate, digest, approved_at, approved_from, disabled_at, disabled_reason
    FROM cue_mandate_approvals WHERE mandate = ?
    """

    case CuesSql.query_all(conn, sql, [mandate]) do
      {:ok, []} -> {:ok, nil}
      {:ok, [row]} -> {:ok, approval_row(row)}
      {:error, reason} -> {:error, reason}
    end
  end

  # The owner's approval: the digest as it is now, and the mandate on again.
  def handle(conn, {:approve, mandate, digest, approved_from, %DateTime{} = now})
      when is_binary(mandate) and is_binary(digest) do
    sql = """
    INSERT INTO cue_mandate_approvals (mandate, digest, approved_at, approved_from)
    VALUES (?, ?, ?, ?)
    ON CONFLICT (mandate) DO UPDATE SET digest = excluded.digest,
      approved_at = excluded.approved_at, approved_from = excluded.approved_from,
      disabled_at = NULL, disabled_reason = NULL
    """

    with :ok <- CuesSql.execute(conn, sql, [mandate, digest, CuesSql.stamp(now), approved_from]) do
      handle(conn, {:get_approval, mandate})
    end
  end

  # Disables an approved mandate until it is approved again. `:disabled` only
  # for the write that disabled it, so its caller tells the owner once.
  def handle(conn, {:disable, mandate, reason, %DateTime{} = now})
      when is_binary(mandate) and is_binary(reason) do
    sql = """
    UPDATE cue_mandate_approvals SET disabled_at = ?, disabled_reason = ?
    WHERE mandate = ? AND disabled_at IS NULL
    """

    with :ok <- CuesSql.execute(conn, sql, [CuesSql.stamp(now), reason, mandate]),
         {:ok, changed} <- CuesSql.changes(conn) do
      disable_result(conn, mandate, changed)
    end
  end

  def handle(_conn, request), do: {:error, {:unknown_request, request}}

  # --- calls ---------------------------------------------------------------------------

  defp open_call(conn, attrs) do
    insert = """
    INSERT INTO cue_mandate_calls (id, run_id, job_id, mandate, tool, args_json, idempotency_key,
      delivery_id, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    """

    params = [
      attrs.id,
      attrs.run_id,
      attrs.job_id,
      attrs.mandate,
      attrs.tool,
      attrs.args_json,
      attrs.idempotency_key,
      attrs.delivery_id,
      CuesSql.stamp(attrs.created_at)
    ]

    with :ok <- CuesSql.execute(conn, insert, params),
         {:ok, calls_this_run} <- count_actions(conn, "run_id = ?", [attrs.run_id]),
         {:ok, hourly} <- hourly_actions(conn, attrs.job_id, attrs.hour_ago),
         {:ok, snapshot} <- cue_snapshot(conn, attrs.cue_id) do
      {:ok, %{calls_this_run: calls_this_run, hourly_actions: hourly, snapshot: snapshot}}
    end
  end

  defp count_actions(conn, where, params) do
    sql =
      "SELECT count(*) FROM cue_mandate_calls WHERE #{where} AND decision IN ('allow','propose')"

    case CuesSql.query_all(conn, sql, params) do
      {:ok, [[count]]} -> {:ok, count}
      {:ok, other} -> {:error, {:unexpected_rows, length(other)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp hourly_actions(conn, job_id, %DateTime{} = hour_ago),
    do: count_actions(conn, "job_id = ? AND decided_at > ?", [job_id, CuesSql.stamp(hour_ago)])

  defp cue_snapshot(_conn, nil), do: {:ok, nil}

  defp cue_snapshot(conn, cue_id) when is_integer(cue_id) do
    case CuesSql.query_all(conn, "SELECT snapshot FROM cues WHERE id = ?", [cue_id]) do
      {:ok, [[snapshot]]} -> {:ok, snapshot}
      {:ok, []} -> {:ok, nil}
      {:ok, other} -> {:error, {:unexpected_rows, length(other)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delivery_cue(_conn, nil), do: {:ok, nil}

  defp delivery_cue(conn, delivery_id) when is_integer(delivery_id) do
    sql = """
    SELECT c.source_ref, c.item_id, c.subject, c.occurred_at, c.received_at
    FROM cue_deliveries d JOIN cues c ON c.id = d.cue_id WHERE d.id = ?
    """

    case CuesSql.query_all(conn, sql, [delivery_id]) do
      {:ok, [[source_ref, item_id, subject, occurred_at, received_at]]} ->
        {:ok,
         %{
           "source" => source_ref,
           "item_id" => item_id,
           "subject" => subject,
           "occurred_at" => occurred_at,
           "received_at" => received_at
         }}

      {:ok, []} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mark_tools_started(conn, run_id, stamp) do
    sql = "UPDATE job_runs SET tools_started_at = ? WHERE id = ? AND tools_started_at IS NULL"
    CuesSql.execute(conn, sql, [stamp, run_id])
  end

  defp decide_propose(conn, call_id, proposal, now) do
    stamp = CuesSql.stamp(now)

    case fetch_proposal(conn, "p.idempotency_key = ?", [proposal.idempotency_key]) do
      {:ok, nil} -> store_proposal(conn, call_id, proposal, stamp)
      {:ok, existing} -> point_at_existing(conn, call_id, proposal, existing, stamp)
      {:error, reason} -> {:error, reason}
    end
  end

  defp store_proposal(conn, call_id, proposal, stamp) do
    insert = """
    INSERT INTO cue_proposals (id, mandate_call_id, run_id, job_id, mandate, watcher_id,
      delivery_id, tool, args_json, idempotency_key, token_digest, state, sent_platform,
      sent_chat_id, sent_user_id, created_at, expires_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'waiting', ?, ?, ?, ?, ?)
    """

    params = [
      proposal.id,
      call_id,
      proposal.run_id,
      proposal.job_id,
      proposal.mandate,
      proposal.watcher_id,
      proposal.delivery_id,
      proposal.tool,
      proposal.args_json,
      proposal.idempotency_key,
      proposal.token_digest,
      proposal.sent_platform,
      proposal.sent_chat_id,
      proposal.sent_user_id,
      stamp,
      CuesSql.stamp(proposal.expires_at)
    ]

    decide = """
    UPDATE cue_mandate_calls SET decision = 'propose', validator = ?, decided_at = ?,
      proposal_id = ?
    WHERE id = ? AND decision IS NULL
    """

    with :ok <- CuesSql.execute(conn, insert, params),
         {:ok, :ok} <- one_row(conn, decide, [proposal.validator, stamp, proposal.id, call_id]),
         :ok <- mark_tools_started(conn, proposal.run_id, stamp) do
      {:ok, {:new, proposal.id}}
    end
  end

  defp point_at_existing(conn, call_id, proposal, existing, stamp) do
    decide = """
    UPDATE cue_mandate_calls SET decision = 'propose', reason = 'already proposed',
      validator = ?, decided_at = ?, proposal_id = ?, result_status = ?, finished_at = ?
    WHERE id = ? AND decision IS NULL
    """

    params = [proposal.validator, stamp, existing.id, existing.state, stamp, call_id]

    with {:ok, :ok} <- one_row(conn, decide, params),
         :ok <- mark_tools_started(conn, proposal.run_id, stamp) do
      {:ok, {:existing, existing}}
    end
  end

  defp finish_unreported_allows(conn, summary, now, limit) do
    select = """
    SELECT c.id FROM cue_mandate_calls c LEFT JOIN job_runs r ON r.id = c.run_id
    WHERE c.decision = 'allow' AND c.finished_at IS NULL
      AND (r.id IS NULL OR r.status NOT IN ('queued', 'running'))
    ORDER BY c.decided_at, c.id LIMIT ?
    """

    with {:ok, rows} <- CuesSql.query_all(conn, select, [limit]) do
      ids = Enum.map(rows, fn [id] -> id end)
      each_ok(ids, &finish_unreported(conn, &1, summary, now))
    end
  end

  defp finish_unreported(conn, id, summary, now) do
    case end_call(conn, id, "unknown", summary, now) do
      :ok -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp end_call(conn, call_id, status, summary, now) do
    sql = """
    UPDATE cue_mandate_calls SET result_status = ?, result_summary = ?, finished_at = ?
    WHERE id = ? AND finished_at IS NULL
    """

    CuesSql.execute(conn, sql, [status, summary, CuesSql.stamp(now), call_id])
  end

  # --- proposals -----------------------------------------------------------------------

  defp decide_waiting(conn, digest, origin, to_state, now) do
    stamp = CuesSql.stamp(now)
    finished = if to_state == "denied", do: stamp, else: nil

    sql = """
    UPDATE cue_proposals SET state = ?, decided_at = ?, decided_from = ?, finished_at = ?
    WHERE token_digest = ? AND state = 'waiting' AND sent_platform = ? AND sent_chat_id = ?
      AND sent_user_id = ? AND expires_at > ?
    """

    params = [
      to_state,
      stamp,
      origin_text(origin),
      finished,
      digest,
      origin.platform,
      origin.chat_id,
      origin.user_id,
      stamp
    ]

    with :ok <- CuesSql.execute(conn, sql, params),
         {:ok, changed} <- CuesSql.changes(conn) do
      decided_or_why(conn, digest, origin, now, changed)
    end
  end

  defp decided_or_why(conn, digest, _origin, _now, 1),
    do: conn |> fetch_proposal("p.token_digest = ?", [digest]) |> require_row()

  defp decided_or_why(conn, digest, origin, now, 0) do
    case fetch_proposal(conn, "p.token_digest = ?", [digest]) do
      {:ok, nil} -> {:error, :unknown}
      {:ok, proposal} -> {:error, why_not(proposal, origin, now)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp why_not(%{state: state}, _origin, _now) when state != "waiting", do: {:not_waiting, state}

  defp why_not(proposal, origin, now) do
    if same_origin?(proposal, origin),
      do: expired_or_stale(proposal, now),
      else: :wrong_origin
  end

  defp expired_or_stale(%{expires_at: expires_at}, now) do
    if DateTime.compare(expires_at, now) == :gt, do: :stale, else: :expired
  end

  defp same_origin?(proposal, origin) do
    proposal.sent_platform == origin.platform and proposal.sent_chat_id == origin.chat_id and
      proposal.sent_user_id == origin.user_id
  end

  defp origin_text(%{platform: platform, chat_id: chat_id, user_id: user_id}),
    do: "#{platform}:#{chat_id}:#{user_id}"

  defp decide_by_id(conn, proposal_id, to_state, decided_from, now) do
    stamp = CuesSql.stamp(now)
    finished = if to_state == "denied", do: stamp, else: nil

    sql = """
    UPDATE cue_proposals SET state = ?, decided_at = ?, decided_from = ?, finished_at = ?
    WHERE id = ? AND state = 'waiting' AND expires_at > ?
    """

    params = [to_state, stamp, decided_from, finished, proposal_id, stamp]

    with :ok <- CuesSql.execute(conn, sql, params),
         {:ok, changed} <- CuesSql.changes(conn) do
      decided_by_id(conn, proposal_id, to_state, now, changed)
    end
  end

  defp decided_by_id(conn, proposal_id, to_state, now, 1) do
    with {:ok, proposal} <- conn |> fetch_proposal("p.id = ?", [proposal_id]) |> require_row(),
         :ok <- end_denied(conn, proposal, to_state, now) do
      {:ok, proposal}
    end
  end

  defp decided_by_id(conn, proposal_id, _to_state, now, 0) do
    case fetch_proposal(conn, "p.id = ?", [proposal_id]) do
      {:ok, nil} -> {:error, :unknown_id}
      {:ok, %{state: state}} when state != "waiting" -> {:error, {:not_waiting, state}}
      {:ok, proposal} -> {:error, expired_or_stale(proposal, now)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp end_denied(conn, proposal, "denied", now),
    do: end_call(conn, proposal.mandate_call_id, "denied", "You denied it.", now)

  defp end_denied(_conn, _proposal, "confirmed", _now), do: :ok

  defp list_cards(conn, where, params) do
    with {:ok, rows} <- CuesSql.query_all(conn, @card_select <> where, params) do
      {:ok, Enum.map(rows, &card_row/1)}
    end
  end

  defp card_row([
         id,
         state,
         mandate,
         tool,
         job_id,
         job_name,
         watcher,
         source_ref,
         created_at,
         expires_at,
         decided_at,
         decided_from,
         result_status,
         args_json,
         received_at,
         occurred_at,
         snapshot
       ]) do
    %{
      id: id,
      state: state,
      mandate: mandate,
      tool: tool,
      job_id: job_id,
      job_name: job_name,
      watcher: watcher,
      source_ref: source_ref,
      created_at: CuesSql.parse_stamp(created_at),
      expires_at: CuesSql.parse_stamp(expires_at),
      decided_at: CuesSql.parse_stamp(decided_at),
      decided_from: decided_from,
      result_status: result_status,
      args_json: args_json,
      received_at: CuesSql.parse_stamp(received_at),
      occurred_at: CuesSql.parse_stamp(occurred_at),
      snapshot: snapshot
    }
  end

  defp settle_proposal(conn, proposal_id, from_state, to_state, reason, now) do
    stamp = CuesSql.stamp(now)

    sql = """
    UPDATE cue_proposals SET state = ?, refusal_reason = ?, decided_at = coalesce(decided_at, ?),
      finished_at = ?
    WHERE id = ? AND state = ? AND finished_at IS NULL
    """

    params = [to_state, reason, stamp, stamp, proposal_id, from_state]

    with {:ok, :ok} <- one_row(conn, sql, params),
         {:ok, proposal} <- conn |> fetch_proposal("p.id = ?", [proposal_id]) |> require_row(),
         :ok <- end_call(conn, proposal.mandate_call_id, to_state, reason, now) do
      {:ok, proposal}
    end
  end

  defp finish_proposal(conn, proposal_id, status, summary, now) do
    sql = """
    UPDATE cue_proposals SET result_status = ?, result_summary = ?, finished_at = ?
    WHERE id = ? AND state = 'confirmed' AND finished_at IS NULL
    """

    params = [status, summary, CuesSql.stamp(now), proposal_id]

    with {:ok, :ok} <- one_row(conn, sql, params),
         {:ok, proposal} <- conn |> fetch_proposal("p.id = ?", [proposal_id]) |> require_row(),
         :ok <- end_call(conn, proposal.mandate_call_id, status, summary, now) do
      {:ok, proposal}
    end
  end

  defp expire_proposals(conn, now, limit) do
    select = """
    SELECT #{@proposal_columns}
    FROM cue_proposals p LEFT JOIN job_runs r ON r.id = p.run_id
    WHERE p.state = 'waiting' AND p.expires_at <= ?
    ORDER BY p.expires_at, p.id LIMIT ?
    """

    with {:ok, rows} <- CuesSql.query_all(conn, select, [CuesSql.stamp(now), limit]) do
      rows
      |> Enum.map(&proposal_row/1)
      |> each_ok(&settle_proposal(conn, &1.id, "waiting", "expired", "no answer in time", now))
    end
  end

  defp claim_unknown_outcomes(conn, now, cutoff, limit) do
    select = """
    SELECT #{@proposal_columns}
    FROM cue_proposals p LEFT JOIN job_runs r ON r.id = p.run_id
    WHERE p.state = 'confirmed' AND p.finished_at IS NULL AND p.reported_at IS NULL
      AND p.decided_at <= ?
    ORDER BY p.decided_at, p.id LIMIT ?
    """

    with {:ok, rows} <- CuesSql.query_all(conn, select, [CuesSql.stamp(cutoff), limit]) do
      rows
      |> Enum.map(&proposal_row/1)
      |> each_ok(&claim_report(conn, &1, now))
    end
  end

  defp claim_report(conn, proposal, now) do
    claim = "UPDATE cue_proposals SET reported_at = ? WHERE id = ? AND reported_at IS NULL"

    case one_row(conn, claim, [CuesSql.stamp(now), proposal.id]) do
      {:ok, :ok} -> {:ok, proposal}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_proposal(conn, where, params) do
    sql = """
    SELECT #{@proposal_columns}
    FROM cue_proposals p LEFT JOIN job_runs r ON r.id = p.run_id
    WHERE #{where}
    """

    case CuesSql.query_all(conn, sql, params) do
      {:ok, []} -> {:ok, nil}
      {:ok, [row]} -> {:ok, proposal_row(row)}
      {:ok, rows} -> {:error, {:unexpected_rows, length(rows)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_row({:ok, nil}), do: {:error, :stale}
  defp require_row(other), do: other

  defp proposal_row([
         id,
         call_id,
         run_id,
         job_id,
         mandate,
         watcher_id,
         delivery_id,
         tool,
         args_json,
         key,
         state,
         platform,
         chat_id,
         user_id,
         created_at,
         expires_at,
         decided_at,
         refusal_reason,
         result_status,
         result_summary,
         finished_at,
         reported_at,
         session_id
       ]) do
    %{
      id: id,
      mandate_call_id: call_id,
      run_id: run_id,
      job_id: job_id,
      mandate: mandate,
      watcher_id: watcher_id,
      delivery_id: delivery_id,
      tool: tool,
      args_json: args_json,
      idempotency_key: key,
      state: state,
      sent_platform: platform,
      sent_chat_id: chat_id,
      sent_user_id: user_id,
      created_at: CuesSql.parse_stamp(created_at),
      expires_at: CuesSql.parse_stamp(expires_at),
      decided_at: CuesSql.parse_stamp(decided_at),
      refusal_reason: refusal_reason,
      result_status: result_status,
      result_summary: result_summary,
      finished_at: CuesSql.parse_stamp(finished_at),
      reported_at: CuesSql.parse_stamp(reported_at),
      session_id: session_id
    }
  end

  # --- approvals -----------------------------------------------------------------------

  defp approval_row([mandate, digest, approved_at, approved_from, disabled_at, disabled_reason]) do
    %{
      mandate: mandate,
      digest: digest,
      approved_at: CuesSql.parse_stamp(approved_at),
      approved_from: approved_from,
      disabled_at: CuesSql.parse_stamp(disabled_at),
      disabled_reason: disabled_reason
    }
  end

  defp disable_result(_conn, _mandate, 1), do: {:ok, :disabled}

  defp disable_result(conn, mandate, 0) do
    case handle(conn, {:get_approval, mandate}) do
      {:ok, nil} -> {:ok, :unapproved}
      {:ok, _row} -> {:ok, :already_disabled}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- helpers -------------------------------------------------------------------------

  defp one_row(conn, sql, params) do
    with :ok <- CuesSql.execute(conn, sql, params),
         {:ok, changed} <- CuesSql.changes(conn) do
      if changed == 1, do: {:ok, :ok}, else: {:error, :stale}
    end
  end

  # `fun` over `items` in order, stopping at the first error; the results in order.
  defp each_ok(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, done} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | done]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, done} -> {:ok, Enum.reverse(done)}
      error -> error
    end
  end
end
