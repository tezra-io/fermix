defmodule FermixCore.Memory.Repo.CuesDeliveriesSql do
  @moduledoc """
  SQL for the read side of the cue inbox (M60 §9.10, §15): what `list_cues`
  and `cue_history` show, through `FermixCore.Cues.Deliveries`. Lane D2 owns it.

  Pure SQL over the caller's `conn`, reached only through
  `FermixCore.Memory.Repo.cues_call/3`. One `handle/2` head per request tuple,
  every head contiguous and above the catch-all, which must stay last (private
  helpers go below it). A request's filters are checked here, so a bad value is
  an error tuple, never a raise inside the Repo process.

  The run's side (admission, the claim and settle parts, a cue run's own reads)
  is `FermixCore.Memory.Repo.CuesRunsSql`.
  """

  alias FermixCore.Memory.Repo.CuesSql

  @type conn :: term()

  @delivery_page_max 50
  @delivery_filters [
    :limit,
    :watcher_id,
    :source_ref,
    :state,
    :subject,
    :since,
    :until,
    :before_id,
    :exclude_id
  ]
  @summary_filters [:since, :watcher_id, :source_ref]
  @proposal_filters [:limit, :watcher_id, :source_ref, :state, :since]

  @doc """
  `{:list_deliveries, filters}` → `{:ok, [delivery]}`: deliveries newest
  first, each with its cue's type and snapshot, the run that held it last
  (its status and the first 280 characters of its reply), and the mandate
  calls and proposals made for it (at most 10 of each, the rest counted). Filters: `limit`
  (required), `watcher_id`, `source_ref`, `state`, `subject`, `since` and
  `until` (on `received_at`), `before_id`, `exclude_id`.
  `{:cue_summary, filters}` → `{:ok, %{sources: [...], watchers: [...]}}`:
  per source, the cues received since `since` (receipts included) and the
  watchers listening to it; per watcher, its deliveries since then by state,
  outcome and source. Filters: `since` (required), `watcher_id`, `source_ref`.
  `{:list_proposals, filters}` → `{:ok, [proposal]}`, newest first. Filters:
  `limit` (required), `watcher_id`, `source_ref`, `state`, `since`.
  `{:watcher_ref, name}` → `{:ok, ref} | {:error, :not_found}`: a watcher's
  id and switches, and its task's job and memory source (where its notes are).
  `{:mandate_summary, since}` → `{:ok, [%{mandate, decision, count}]}`: how
  many mandate calls each mandate decided since `since`, by decision (`allow`,
  `propose`, `refuse`), for the counts a mandate row carries (M60 app surface
  §3.4). No text.
  Free text (snapshots, reasons, arguments, results) comes back raw: the
  caller (`Cues.Deliveries`) frames it.
  """
  @spec handle(conn(), tuple()) :: term()
  def handle(conn, {:list_deliveries, %{limit: limit} = filters})
      when is_integer(limit) and limit in 1..@delivery_page_max do
    with :ok <- known_filters(filters, @delivery_filters), do: list_deliveries(conn, filters)
  end

  def handle(conn, {:cue_summary, %{since: %DateTime{}} = filters}) do
    with :ok <- known_filters(filters, @summary_filters), do: cue_summary(conn, filters)
  end

  def handle(conn, {:list_proposals, %{limit: limit} = filters})
      when is_integer(limit) and limit in 1..@delivery_page_max do
    with :ok <- known_filters(filters, @proposal_filters), do: list_proposals(conn, filters)
  end

  def handle(conn, {:watcher_ref, name}) when is_binary(name), do: watcher_ref(conn, name)

  def handle(conn, {:mandate_summary, %DateTime{} = since}), do: mandate_summary(conn, since)

  def handle(_conn, request), do: {:error, {:unknown_request, request}}

  @doc """
  The text of the snapshot Fermix wrote at ingest (JSON `{type, subject,
  text}`); nil once retention dropped it. A snapshot that does not decode is
  `{:error, {:invalid_snapshot, delivery_id}}`.
  """
  @spec snapshot_text(String.t() | nil, term()) :: {:ok, String.t() | nil} | {:error, term()}
  def snapshot_text(nil, _delivery_id), do: {:ok, nil}

  def snapshot_text(snapshot, delivery_id) when is_binary(snapshot) do
    case Jason.decode(snapshot) do
      {:ok, %{"text" => text}} when is_binary(text) or is_nil(text) -> {:ok, text}
      _invalid -> {:error, {:invalid_snapshot, delivery_id}}
    end
  end

  # --- helpers ---------------------------------------------------------------------

  # The head of a run's reply a delivery shows (design §9.10), and how much of a
  # recorded free-text field (a reason, a hint, arguments, a result) is read.
  @reply_excerpt_chars 280
  @recorded_text_chars 1_000
  # Mandate calls and proposals listed per delivery; the rest are counted.
  @delivery_children_max 10
  # Rows a summary reads: sources, and watcher × state × outcome × source groups.
  @summary_sources_max 100
  @summary_groups_max 500
  # Mandate × decision groups a mandate summary reads: three decisions for each
  # of the most mandates a settings file is given.
  @mandate_groups_max 3 * 64

  # Its three `?` are the reason, hint and reply lengths read.
  @delivery_page_sql """
  SELECT d.id, d.cue_id, d.watcher_id, w.name, d.source_ref, d.received_at, d.state, d.outcome,
         substr(d.decision_reason, 1, ?), substr(d.hint, 1, ?), d.filter_attempts,
         d.task_attempts, d.settled_at, c.type, d.subject, c.occurred_at, c.snapshot,
         r.id, r.status, substr(r.final_response, 1, ?)
  FROM cue_deliveries d
  JOIN cues c ON c.id = d.cue_id
  LEFT JOIN cue_watchers w ON w.id = d.watcher_id
  LEFT JOIN job_runs r ON r.id = d.claimed_run_id
  """

  # Per delivery, its first calls (or proposals) and how many it has. The three
  # leading `?` are text lengths, then the delivery ids, then the per-delivery cap.
  @delivery_calls_sql """
  SELECT id, delivery_id, mandate, tool, substr(args_json, 1, ?), decision, substr(reason, 1, ?),
         validator, proposal_id, result_status, substr(result_summary, 1, ?), created_at,
         decided_at, finished_at, total
  FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY delivery_id ORDER BY created_at, id) AS n,
           COUNT(*) OVER (PARTITION BY delivery_id) AS total
    FROM cue_mandate_calls WHERE delivery_id IN (__IDS__)
  )
  WHERE n <= ?
  ORDER BY delivery_id, n
  """

  @delivery_proposals_sql """
  SELECT id, delivery_id, mandate_call_id, mandate, tool, substr(args_json, 1, ?), state,
         created_at, expires_at, decided_at, substr(refusal_reason, 1, ?), result_status,
         substr(result_summary, 1, ?), finished_at, total
  FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY delivery_id ORDER BY created_at, id) AS n,
           COUNT(*) OVER (PARTITION BY delivery_id) AS total
    FROM cue_proposals WHERE delivery_id IN (__IDS__)
  )
  WHERE n <= ?
  ORDER BY delivery_id, n
  """

  @proposals_sql """
  SELECT p.id, p.delivery_id, p.mandate_call_id, p.mandate, p.tool, substr(p.args_json, 1, ?),
         p.state, p.created_at, p.expires_at, p.decided_at, substr(p.refusal_reason, 1, ?),
         p.result_status, substr(p.result_summary, 1, ?), p.finished_at,
         p.watcher_id, w.name, d.source_ref
  FROM cue_proposals p
  LEFT JOIN cue_watchers w ON w.id = p.watcher_id
  LEFT JOIN cue_deliveries d ON d.id = p.delivery_id
  """

  # Every source that sent a cue since `since`, has a state row or is listened
  # to. Its `?` is `since`. A receipt (a cue no watcher took) is kept about
  # eight days, so a window longer than that undercounts what nobody took. The
  # window is counted in one pass through `cues_received_at`: a source keeps its
  # rows for weeks, and counting by source would walk all of them for the
  # day's few, on every Cues read.
  @summary_sources_sql """
  WITH recent AS MATERIALIZED (
    SELECT source_ref, COUNT(*) AS received, SUM(routed_count > 0) AS routed,
      SUM(self_caused = 1) AS self_caused
    FROM cues INDEXED BY cues_received_at
    WHERE received_at >= ?
    GROUP BY source_ref
  ),
  refs AS (
    SELECT source_ref FROM recent
    UNION SELECT source_ref FROM cue_sources
    UNION SELECT source_ref FROM cue_watcher_sources
  )
  SELECT r.source_ref, coalesce(c.received, 0), coalesce(c.routed, 0),
    coalesce(c.self_caused, 0),
    (SELECT group_concat(w.name, char(10)) FROM cue_watcher_sources s
     JOIN cue_watchers w ON w.id = s.watcher_id
     WHERE s.source_ref = r.source_ref AND w.enabled = 1),
    (SELECT group_concat(w.name, char(10)) FROM cue_watcher_sources s
     JOIN cue_watchers w ON w.id = s.watcher_id
     WHERE s.source_ref = r.source_ref AND w.enabled = 0),
    (SELECT COUNT(*) FROM cue_gaps g WHERE g.source_ref = r.source_ref AND g.closed_at IS NULL),
    s.status, s.last_good_at, s.last_accepted_at
  FROM refs r
  LEFT JOIN recent c ON c.source_ref = r.source_ref
  LEFT JOIN cue_sources s ON s.source_ref = r.source_ref
  """

  @doc false
  # The source summary's SQL, for the test that holds its query plan.
  @spec summary_sources_sql() :: String.t()
  def summary_sources_sql, do: @summary_sources_sql <> " ORDER BY r.source_ref"

  # Its `?` is `since`; a source filter adds itself to the join condition.
  @summary_groups_sql """
  SELECT w.id, w.name, w.enabled, d.state, d.outcome, d.source_ref, COUNT(d.id)
  FROM cue_watchers w
  LEFT JOIN cue_deliveries d ON d.watcher_id = w.id AND d.received_at >= ?
  """

  @watcher_ref_sql """
  SELECT w.id, w.name, w.enabled, w.task_notes, j.id, j.name, j.memory_source_id,
         j.created_by_agent_id
  FROM cue_watchers w
  JOIN scheduled_jobs j ON j.id = w.task_job_id
  WHERE w.name = ?
  """

  # A request's filters must be the ones it takes, each of its type: a bad value
  # is an error tuple here, never a raise inside the Repo process.
  defp known_filters(filters, allowed) do
    case Enum.reject(filters, fn {key, value} -> key in allowed and filter_value?(key, value) end) do
      [] -> :ok
      bad -> {:error, {:invalid_filters, Enum.map(bad, &elem(&1, 0))}}
    end
  end

  defp filter_value?(_key, nil), do: true
  defp filter_value?(key, %DateTime{}) when key in [:since, :until], do: true

  defp filter_value?(key, value) when key in [:limit, :before_id, :exclude_id],
    do: is_integer(value) and value > 0

  defp filter_value?(key, value) when key in [:watcher_id, :source_ref, :state, :subject],
    do: is_binary(value)

  defp filter_value?(_key, _value), do: false

  defp list_deliveries(conn, filters) do
    {where, params} = where_clause(delivery_conditions(filters))
    lengths = [@recorded_text_chars + 1, @recorded_text_chars + 1, @reply_excerpt_chars + 1]
    sql = @delivery_page_sql <> where <> " ORDER BY d.id DESC LIMIT ?"

    with {:ok, rows} <- CuesSql.query_all(conn, sql, lengths ++ params ++ [filters.limit]),
         {:ok, deliveries} <- decode_deliveries(rows),
         ids = Enum.map(deliveries, & &1.id),
         {:ok, calls} <- delivery_children(conn, @delivery_calls_sql, ids, &call_row/1),
         {:ok, proposals} <-
           delivery_children(conn, @delivery_proposals_sql, ids, &proposal_row/1) do
      {:ok, Enum.map(deliveries, &with_children(&1, calls, proposals))}
    end
  end

  defp delivery_conditions(filters) do
    [
      equal(filters, :watcher_id, "d.watcher_id = ?"),
      equal(filters, :source_ref, "d.source_ref = ?"),
      equal(filters, :state, "d.state = ?"),
      equal(filters, :subject, "d.subject = ?"),
      at_or_after(filters, :since, "d.received_at >= ?"),
      at_or_after(filters, :until, "d.received_at < ?"),
      equal(filters, :before_id, "d.id < ?"),
      equal(filters, :exclude_id, "d.id <> ?")
    ]
  end

  defp equal(filters, key, sql) do
    case Map.get(filters, key) do
      nil -> nil
      value -> {sql, [value]}
    end
  end

  defp at_or_after(filters, key, sql) do
    case Map.get(filters, key) do
      nil -> nil
      %DateTime{} = at -> {sql, [CuesSql.stamp(at)]}
    end
  end

  defp where_clause(conditions) do
    case Enum.reject(conditions, &is_nil/1) do
      [] -> {"", []}
      present -> {" WHERE " <> joined(present), Enum.flat_map(present, &elem(&1, 1))}
    end
  end

  defp and_clause(conditions) do
    case Enum.reject(conditions, &is_nil/1) do
      [] -> {"", []}
      present -> {" AND " <> joined(present), Enum.flat_map(present, &elem(&1, 1))}
    end
  end

  defp joined(conditions), do: Enum.map_join(conditions, " AND ", &elem(&1, 0))

  defp decode_deliveries(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case delivery_row(row) do
        {:ok, delivery} -> {:cont, {:ok, [delivery | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, deliveries} -> {:ok, Enum.reverse(deliveries)}
      {:error, reason} -> {:error, reason}
    end)
  end

  defp delivery_row([
         id,
         cue_id,
         watcher_id,
         watcher_name,
         source_ref,
         received_at,
         state,
         outcome,
         reason,
         hint,
         filter_attempts,
         task_attempts,
         settled_at,
         type,
         subject,
         occurred_at,
         snapshot,
         run_id,
         run_status,
         reply
       ]) do
    with {:ok, text} <- snapshot_text(snapshot, id) do
      {:ok,
       %{
         id: id,
         cue_id: cue_id,
         watcher_id: watcher_id,
         watcher_name: watcher_name,
         source_ref: source_ref,
         received_at: CuesSql.parse_stamp(received_at),
         state: state,
         outcome: outcome,
         decision_reason: clip(reason, @recorded_text_chars),
         hint: clip(hint, @recorded_text_chars),
         filter_attempts: filter_attempts,
         task_attempts: task_attempts,
         settled_at: CuesSql.parse_stamp(settled_at),
         type: type,
         subject: subject,
         occurred_at: CuesSql.parse_stamp(occurred_at),
         snapshot_text: text,
         run: run(run_id, run_status, reply)
       }}
    end
  end

  defp run(nil, _status, _reply), do: nil

  defp run(id, status, reply),
    do: %{id: id, status: status, reply_excerpt: clip(reply, @reply_excerpt_chars)}

  # `%{delivery_id => {[child], total}}` for the page's deliveries.
  defp delivery_children(_conn, _sql, [], _decode), do: {:ok, %{}}

  defp delivery_children(conn, sql, ids, decode) do
    lengths = List.duplicate(@recorded_text_chars + 1, 3)
    sql = String.replace(sql, "__IDS__", Enum.map_join(ids, ", ", fn _id -> "?" end))

    with {:ok, rows} <-
           CuesSql.query_all(conn, sql, lengths ++ ids ++ [@delivery_children_max]) do
      {:ok,
       rows
       |> Enum.group_by(fn [_id, delivery_id | _rest] -> delivery_id end)
       |> Map.new(fn {delivery_id, [first | _] = group} ->
         {delivery_id, {Enum.map(group, &decode.(Enum.drop(&1, -1))), List.last(first)}}
       end)}
    end
  end

  defp with_children(delivery, calls, proposals) do
    {call_list, call_total} = Map.get(calls, delivery.id, {[], 0})
    {proposal_list, proposal_total} = Map.get(proposals, delivery.id, {[], 0})

    Map.merge(delivery, %{
      calls: call_list,
      more_calls: call_total - length(call_list),
      proposals: proposal_list,
      more_proposals: proposal_total - length(proposal_list)
    })
  end

  defp call_row([
         id,
         delivery_id,
         mandate,
         tool,
         args,
         decision,
         reason,
         validator,
         proposal_id,
         result_status,
         result_summary,
         created_at,
         decided_at,
         finished_at
       ]) do
    %{
      id: id,
      delivery_id: delivery_id,
      mandate: mandate,
      tool: tool,
      args_json: clip(args, @recorded_text_chars),
      decision: decision,
      reason: clip(reason, @recorded_text_chars),
      validator: validator,
      proposal_id: proposal_id,
      result_status: result_status,
      result_summary: clip(result_summary, @recorded_text_chars),
      created_at: CuesSql.parse_stamp(created_at),
      decided_at: CuesSql.parse_stamp(decided_at),
      finished_at: CuesSql.parse_stamp(finished_at)
    }
  end

  defp proposal_row([
         id,
         delivery_id,
         mandate_call_id,
         mandate,
         tool,
         args,
         state,
         created_at,
         expires_at,
         decided_at,
         refusal_reason,
         result_status,
         result_summary,
         finished_at
       ]) do
    %{
      id: id,
      delivery_id: delivery_id,
      mandate_call_id: mandate_call_id,
      mandate: mandate,
      tool: tool,
      args_json: clip(args, @recorded_text_chars),
      state: state,
      created_at: CuesSql.parse_stamp(created_at),
      expires_at: CuesSql.parse_stamp(expires_at),
      decided_at: CuesSql.parse_stamp(decided_at),
      refusal_reason: clip(refusal_reason, @recorded_text_chars),
      result_status: result_status,
      result_summary: clip(result_summary, @recorded_text_chars),
      finished_at: CuesSql.parse_stamp(finished_at)
    }
  end

  # At most `max` code points (SQLite's `substr` counts them too), marked when cut.
  defp clip(nil, _max), do: nil

  defp clip(text, max) when is_binary(text) do
    points = String.codepoints(text)

    if length(points) > max,
      do: (points |> Enum.take(max) |> Enum.join()) <> "…",
      else: text
  end

  defp list_proposals(conn, filters) do
    {where, params} =
      where_clause([
        equal(filters, :watcher_id, "p.watcher_id = ?"),
        equal(filters, :source_ref, "d.source_ref = ?"),
        equal(filters, :state, "p.state = ?"),
        at_or_after(filters, :since, "p.created_at >= ?")
      ])

    lengths = List.duplicate(@recorded_text_chars + 1, 3)
    sql = @proposals_sql <> where <> " ORDER BY p.created_at DESC, p.id DESC LIMIT ?"

    with {:ok, rows} <- CuesSql.query_all(conn, sql, lengths ++ params ++ [filters.limit]) do
      {:ok, Enum.map(rows, &listed_proposal/1)}
    end
  end

  defp listed_proposal(row) do
    {own, [watcher_id, watcher_name, source_ref]} = Enum.split(row, 14)

    Map.merge(proposal_row(own), %{
      watcher_id: watcher_id,
      watcher_name: watcher_name,
      source_ref: source_ref
    })
  end

  defp cue_summary(conn, filters) do
    since = CuesSql.stamp(filters.since)

    with {:ok, source_rows} <- summary_sources(conn, since, filters),
         {:ok, group_rows} <- summary_groups(conn, since, filters) do
      {:ok,
       %{
         sources: Enum.map(source_rows, &summary_source/1),
         watchers: group_rows |> Enum.chunk_by(&hd/1) |> Enum.map(&summary_watcher/1)
       }}
    end
  end

  defp summary_sources(conn, since, filters) do
    {where, params} =
      where_clause([
        equal(filters, :source_ref, "r.source_ref = ?"),
        equal(
          filters,
          :watcher_id,
          "r.source_ref IN (SELECT source_ref FROM cue_watcher_sources WHERE watcher_id = ?)"
        )
      ])

    sql = @summary_sources_sql <> where <> " ORDER BY r.source_ref LIMIT ?"
    CuesSql.query_all(conn, sql, [since | params] ++ [@summary_sources_max])
  end

  defp summary_groups(conn, since, filters) do
    {on, on_params} = and_clause([equal(filters, :source_ref, "d.source_ref = ?")])

    {where, params} =
      where_clause([
        equal(filters, :watcher_id, "w.id = ?"),
        equal(
          filters,
          :source_ref,
          "w.id IN (SELECT watcher_id FROM cue_watcher_sources WHERE source_ref = ?)"
        )
      ])

    sql =
      @summary_groups_sql <>
        on <>
        where <>
        " GROUP BY w.id, d.state, d.outcome, d.source_ref ORDER BY w.name, w.id LIMIT ?"

    CuesSql.query_all(conn, sql, [since | on_params] ++ params ++ [@summary_groups_max])
  end

  defp summary_source([
         ref,
         cues,
         routed,
         self_caused,
         listening,
         paused,
         open_gaps,
         status,
         last_good_at,
         last_accepted_at
       ]) do
    %{
      source_ref: ref,
      cues: cues,
      routed: routed,
      self_caused: self_caused,
      not_routed: cues - routed - self_caused,
      listening: names(listening),
      paused: names(paused),
      open_gaps: open_gaps,
      status: status,
      last_good_at: CuesSql.parse_stamp(last_good_at),
      last_accepted_at: CuesSql.parse_stamp(last_accepted_at)
    }
  end

  defp names(nil), do: []
  defp names(text), do: text |> String.split("\n") |> Enum.sort()

  # One watcher's groups (contiguous by the query's order). A watcher with no
  # delivery in the window has one group whose state is null.
  defp summary_watcher([[id, name, enabled | _rest] | _more] = groups) do
    counted = Enum.reject(groups, fn [_id, _name, _enabled, state | _rest] -> is_nil(state) end)

    %{
      watcher_id: id,
      name: name,
      enabled?: enabled == 1,
      deliveries: counted |> Enum.map(&List.last/1) |> Enum.sum(),
      by_state: tally(counted, 3),
      by_outcome: counted |> Enum.reject(&is_nil(Enum.at(&1, 4))) |> tally(4),
      by_source: tally(counted, 5)
    }
  end

  defp tally(groups, index) do
    Enum.reduce(groups, %{}, fn group, acc ->
      Map.update(acc, Enum.at(group, index), List.last(group), &(&1 + List.last(group)))
    end)
  end

  defp mandate_summary(conn, since) do
    sql = """
    SELECT mandate, decision, COUNT(*) FROM cue_mandate_calls
    WHERE created_at >= ? AND decision IS NOT NULL
    GROUP BY mandate, decision ORDER BY mandate, decision LIMIT ?
    """

    with {:ok, rows} <- CuesSql.query_all(conn, sql, [CuesSql.stamp(since), @mandate_groups_max]) do
      {:ok,
       Enum.map(rows, fn [mandate, decision, count] ->
         %{mandate: mandate, decision: decision, count: count}
       end)}
    end
  end

  defp watcher_ref(conn, name) do
    case CuesSql.query_all(conn, @watcher_ref_sql, [name]) do
      {:ok, [[id, name, enabled, notes, job_id, job_name, source_id, agent_id]]} ->
        {:ok,
         %{
           id: id,
           name: name,
           enabled?: enabled == 1,
           task_notes?: notes == 1,
           job_id: job_id,
           job_name: job_name,
           memory_source_id: source_id,
           created_by_agent_id: agent_id
         }}

      {:ok, []} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
