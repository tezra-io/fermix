defmodule FermixCore.Memory.Repo.CuesWatchersSql do
  @moduledoc """
  SQL for watchers, their sources, instructions and examples, and the
  once-only claims behind watcher, source and gap notices (M60 §8, §9.5).
  Lane D owns it.

  Pure SQL over the caller's `conn`, reached only through
  `FermixCore.Memory.Repo.cues_call/3`, so each request runs whole before the
  single writer serves the next one. One `handle/2` head per request tuple,
  above the catch-all, which stays last. Delivery moves go through
  `CuesSql.transition/6`, transactions through
  `CuesSql.with_immediate_transaction/2`, timestamps through `CuesSql.stamp/1`.

  ## Requests

  - `{:insert_watcher, attrs, sources, instructions, now}`: the watcher, its
    source rows and its first instructions (numbered from 1) in one transaction.
  - `{:get_watcher, {:name, name} | {:id, id}}`: the watcher with its sources,
    active and removed instructions and its 20 most recent examples.
  - `{:list_watchers}`.
  - `{:update_watcher, id, expected_updated_at, patch, sources | nil, now}` →
    `{:ok, %{watcher: watcher, passed: [passed], expired: [expired]}}`: fenced
    on `updated_at`, so two changes read from the same state cannot both land;
    a relinked task is checked in the same transaction. New `sources` expire
    the watcher's `pending` and `filtering` deliveries from every source it no
    longer has (`watcher_removed`, no gap; a call on a `filtering` one then
    settles stale); `expired` lists them. A patch that switches the filter to
    `none` then passes the watcher's remaining `pending` and `filtering`
    deliveries in that transaction, so nothing waits for a filter that no
    longer runs; `passed` lists them. Each entry is a `delivery_id`, `cue_id`
    and `source_ref`, in id order.
  - `{:remove_watcher, id, now}`: refused (`:busy`) while a delivery of it is
    `filtering` or `claimed` (`:busy`) or its follow-up's job holds a run
    (`:follow_up_running`); otherwise its
    `pending` and `passed` deliveries expire (`watcher_removed`), one gap per
    source they came from, its follow-up's waiting and starting triggers are
    refused, and the watcher row goes (its sources, instructions and examples
    cascade). Its follow-up's job is the caller's to remove.
  - `{:remove_follow_up, id, expected_updated_at, now}`: the watcher's
    follow-up stopped, fenced as an update is, refused (`:follow_up_running`)
    while its run holds the job; its open triggers are refused and its
    columns cleared.
  - `{:change_instructions, id, %{add: texts, remove: numbers}, from, now, cap}`,
    `{:restore_instruction, id, number, from, now, cap}`,
    `{:merge_instructions, id, numbers, text, from, now}`: one transaction each,
    returning what was added and removed for Fermix's echo. A number is never
    reused: the next is one past the highest the watcher ever had.
  - `{:add_example, id, cue_id, label, note, now}` (the cue must have been
    delivered to this watcher; its snapshot is copied),
    `{:add_drop_example, id, cue_id, label, note, now}` (a stream watcher's
    recent drop, kept by `CuesSql`'s `{:store_item, …}` with no delivery; the
    cue's snapshot is copied) and `{:remove_example, id, example_id, now}`.
  - `{:watcher_for_job, job_id}`: the watcher whose task or follow-up is
    `job_id`, or nil.
  - Notice claims: `{:claim_watcher_notice, id, kind, rule, now}` (a claimed
    target names `notice_job_id`, the job whose delivery a watcher notice
    takes: its task's, else its follow-up's),
    `{:release_watcher_notice, id, kind, rule, previous}`,
    `{:claim_source_notice, ref, kind, rule, now}`,
    `{:release_source_notice, ref, kind, previous}`,
    `{:due_gap_notices, now, limit}`, `{:claim_gap_notice, gap_id, now}`,
    `{:release_gap_notice, gap_id, stamp}`.
  """

  alias FermixCore.Cues
  alias FermixCore.Memory.Repo.CuesFollowUpAllowSql
  alias FermixCore.Memory.Repo.CuesFollowUpSql
  alias FermixCore.Memory.Repo.CuesSql

  @recent_examples 20
  @gap_notice_after_s 3_600
  @watcher_removed "Not started: the watcher was removed."

  @watcher_select """
  SELECT id, name, purpose, filter, listen_for, task_job_id, task_notes,
    daily_cap, filter_budget, filter_failures, filter_retry_at, held_notified_at, notices,
    enabled, created_from, created_at, updated_at, follow_up_job_id, follow_up_approved_at
  FROM cue_watchers
  """

  @patch_fields [
    :purpose,
    :filter,
    :listen_for,
    :task_job_id,
    :task_notes,
    :daily_cap,
    :filter_budget,
    :enabled,
    :follow_up_job_id,
    :follow_up_approved_at,
    :follow_up_approval_digest
  ]

  @type conn :: term()

  @doc "Serves one request on `conn`; an unknown request is an error, never a raise."
  @spec handle(conn(), tuple()) :: term()
  def handle(conn, {:insert_watcher, attrs, sources, instructions, %DateTime{} = now})
      when is_map(attrs) and is_list(sources) and is_list(instructions) do
    CuesSql.with_immediate_transaction(conn, fn ->
      insert_watcher(conn, attrs, sources, instructions, now)
    end)
  end

  def handle(conn, {:get_watcher, {:name, name}}) when is_binary(name),
    do: get_watcher(conn, "name", name)

  def handle(conn, {:get_watcher, {:id, id}}) when is_binary(id),
    do: get_watcher(conn, "id", id)

  def handle(conn, {:list_watchers}), do: list_watchers(conn)

  def handle(conn, {:source_watchers, ref}) when is_binary(ref), do: source_watchers(conn, ref)

  def handle(
        conn,
        {:update_watcher, id, %DateTime{} = expected, patch, sources, %DateTime{} = now}
      )
      when is_binary(id) and is_map(patch) and (is_list(sources) or is_nil(sources)) do
    CuesSql.with_immediate_transaction(conn, fn ->
      update_watcher(conn, id, expected, patch, sources, now)
    end)
  end

  def handle(conn, {:remove_watcher, id, %DateTime{} = now}) when is_binary(id) do
    CuesSql.with_immediate_transaction(conn, fn -> remove_watcher(conn, id, now) end)
  end

  def handle(conn, {:remove_follow_up, id, %DateTime{} = expected, %DateTime{} = now})
      when is_binary(id) do
    CuesSql.with_immediate_transaction(conn, fn -> remove_follow_up(conn, id, expected, now) end)
  end

  def handle(conn, {:change_instructions, id, %{add: adds, remove: removes}, from, now, cap})
      when is_binary(id) and is_list(adds) and is_list(removes) and is_integer(cap) do
    CuesSql.with_immediate_transaction(conn, fn ->
      change_instructions(conn, id, {adds, removes}, from, now, cap)
    end)
  end

  def handle(conn, {:restore_instruction, id, number, from, %DateTime{} = now, cap})
      when is_binary(id) and is_integer(number) and is_integer(cap) do
    CuesSql.with_immediate_transaction(conn, fn ->
      restore_instruction(conn, id, number, from, now, cap)
    end)
  end

  def handle(conn, {:merge_instructions, id, numbers, text, from, %DateTime{} = now})
      when is_binary(id) and is_list(numbers) and is_binary(text) do
    CuesSql.with_immediate_transaction(conn, fn ->
      merge_instructions(conn, id, numbers, text, from, now)
    end)
  end

  def handle(conn, {:add_example, id, cue_id, label, note, %DateTime{} = now})
      when is_binary(id) and is_integer(cue_id) and label in ["pass", "drop"] do
    CuesSql.with_immediate_transaction(conn, fn ->
      add_example(conn, id, cue_id, label, note, now)
    end)
  end

  def handle(conn, {:add_drop_example, id, cue_id, label, note, %DateTime{} = now})
      when is_binary(id) and is_integer(cue_id) and label in ["pass", "drop"] do
    CuesSql.with_immediate_transaction(conn, fn ->
      add_drop_example(conn, id, cue_id, label, note, now)
    end)
  end

  def handle(conn, {:remove_example, id, example_id, %DateTime{} = now})
      when is_binary(id) and is_binary(example_id) do
    CuesSql.with_immediate_transaction(conn, fn -> remove_example(conn, id, example_id, now) end)
  end

  def handle(conn, {:watcher_for_job, job_id}) when is_binary(job_id) do
    sql = @watcher_select <> " WHERE task_job_id = ? OR follow_up_job_id = ?"

    case CuesSql.query_all(conn, sql, [job_id, job_id]) do
      {:ok, [row]} -> {:ok, watcher_row(row)}
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle(conn, {:claim_watcher_notice, id, kind, rule, %DateTime{} = now})
      when is_binary(id) and is_binary(kind) do
    CuesSql.with_immediate_transaction(conn, fn ->
      claim_watcher_notice(conn, id, kind, rule, now)
    end)
  end

  def handle(conn, {:release_watcher_notice, id, kind, rule, previous})
      when is_binary(id) and is_binary(kind) do
    CuesSql.with_immediate_transaction(conn, fn ->
      release_watcher_notice(conn, id, kind, rule, previous)
    end)
  end

  def handle(conn, {:claim_source_notice, ref, kind, rule, %DateTime{} = now})
      when is_binary(ref) and is_binary(kind) do
    CuesSql.with_immediate_transaction(conn, fn ->
      claim_source_notice(conn, ref, kind, rule, now)
    end)
  end

  def handle(conn, {:release_source_notice, ref, kind, previous})
      when is_binary(ref) and is_binary(kind) do
    CuesSql.with_immediate_transaction(conn, fn ->
      release_source_notice(conn, ref, kind, previous)
    end)
  end

  def handle(conn, {:due_gap_notices, %DateTime{} = now, limit})
      when is_integer(limit) and limit > 0,
      do: due_gap_notices(conn, now, limit)

  def handle(conn, {:claim_gap_notice, gap_id, %DateTime{} = now}) when is_binary(gap_id) do
    with :ok <-
           CuesSql.execute(
             conn,
             "UPDATE cue_gaps SET reported_at = ? WHERE id = ? AND reported_at IS NULL",
             [CuesSql.stamp(now), gap_id]
           ),
         {:ok, changed} <- CuesSql.changes(conn) do
      {:ok, if(changed == 1, do: :claimed, else: :already_sent)}
    end
  end

  def handle(conn, {:release_gap_notice, gap_id, stamp})
      when is_binary(gap_id) and is_binary(stamp) do
    CuesSql.execute(
      conn,
      "UPDATE cue_gaps SET reported_at = NULL WHERE id = ? AND reported_at = ?",
      [gap_id, stamp]
    )
  end

  def handle(_conn, request), do: {:error, {:unknown_request, request}}

  # --- insert --------------------------------------------------------------------

  defp insert_watcher(conn, attrs, sources, instructions, now) do
    stamp = CuesSql.stamp(now)
    from = Map.get(attrs, :created_from)

    with :ok <- check_name_free(conn, attrs.name),
         :ok <- check_task(conn, Map.get(attrs, :task_job_id), nil),
         :ok <- check_follow_up(conn, Map.get(attrs, :follow_up_job_id), nil),
         :ok <- insert_watcher_row(conn, attrs, stamp),
         :ok <- insert_sources(conn, attrs.id, sources),
         {:ok, _added} <- insert_instructions(conn, attrs.id, 1, instructions, from, stamp) do
      get_watcher(conn, "id", attrs.id)
    end
  end

  defp check_name_free(conn, name) do
    case CuesSql.query_all(conn, "SELECT 1 FROM cue_watchers WHERE name = ?", [name]) do
      {:ok, []} -> :ok
      {:ok, _rows} -> {:error, :name_taken}
      {:error, reason} -> {:error, reason}
    end
  end

  # A task is a job that runs on cues and wakes no other watcher. A watcher
  # with only a follow-up has none.
  defp check_task(_conn, nil, _watcher_id), do: :ok

  defp check_task(conn, job_id, watcher_id) do
    with {:ok, kind} <- job_kind(conn, job_id),
         :ok <- cue_kind(kind),
         {:ok, rows} <- watchers_of_job(conn, job_id) do
      case rows do
        [] -> :ok
        [[^watcher_id, _name]] -> :ok
        [[_other, name]] -> {:error, {:task_taken, name}}
      end
    end
  end

  # A follow-up is a job of its own kind, never shared between watchers
  # (M60_WATCHER_CODING_RUNS.md §5).
  defp check_follow_up(_conn, nil, _watcher_id), do: :ok

  defp check_follow_up(conn, job_id, watcher_id) do
    with {:ok, kind} <- job_kind(conn, job_id),
         :ok <- follow_up_kind(kind),
         {:ok, rows} <- watchers_of_job(conn, job_id) do
      case rows do
        [] -> :ok
        [[^watcher_id, _name]] -> :ok
        [[_other, name]] -> {:error, {:follow_up_taken, name}}
      end
    end
  end

  # Either role counts: a job is one watcher's task or follow-up, never both.
  defp watchers_of_job(conn, job_id) do
    CuesSql.query_all(
      conn,
      "SELECT id, name FROM cue_watchers WHERE task_job_id = ? OR follow_up_job_id = ?",
      [job_id, job_id]
    )
  end

  defp job_kind(conn, job_id) do
    case CuesSql.query_all(conn, "SELECT schedule_kind FROM scheduled_jobs WHERE id = ?", [job_id]) do
      {:ok, [[kind]]} -> {:ok, kind}
      {:ok, []} -> {:error, :job_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cue_kind("cue"), do: :ok
  defp cue_kind(_kind), do: {:error, :not_cue_job}

  defp follow_up_kind("watcher"), do: :ok
  defp follow_up_kind(_kind), do: {:error, :not_follow_up_job}

  defp insert_watcher_row(conn, attrs, stamp) do
    CuesSql.execute(
      conn,
      """
      INSERT INTO cue_watchers (id, name, purpose, filter, listen_for, task_job_id, task_notes,
        daily_cap, filter_budget, enabled, created_from, created_at, updated_at,
        follow_up_job_id)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?)
      """,
      [
        attrs.id,
        attrs.name,
        Map.get(attrs, :purpose),
        attrs.filter,
        Jason.encode!(Map.get(attrs, :listen_for, [])),
        Map.get(attrs, :task_job_id),
        flag(Map.get(attrs, :task_notes, false)),
        Map.get(attrs, :daily_cap, 0),
        Map.get(attrs, :filter_budget, 0),
        Map.get(attrs, :created_from),
        stamp,
        stamp,
        Map.get(attrs, :follow_up_job_id)
      ]
    )
  end

  # The watchers of one source, with their words, for a stream that judges its
  # items before they are stored (`Cues.LiveFilters`): an enabled watcher only,
  # oldest first.
  defp source_watchers(conn, ref) do
    sql =
      @watcher_select <>
        " WHERE enabled = 1 AND id IN" <>
        " (SELECT watcher_id FROM cue_watcher_sources WHERE source_ref = ?) ORDER BY created_at, id"

    with {:ok, rows} <- CuesSql.query_all(conn, sql, [ref]) do
      {:ok, Enum.map(rows, &watcher_row/1)}
    end
  end

  defp insert_sources(conn, id, sources) do
    Enum.reduce_while(Enum.uniq(sources), :ok, fn ref, :ok ->
      case CuesSql.execute(
             conn,
             "INSERT INTO cue_watcher_sources (watcher_id, source_ref) VALUES (?, ?)",
             [id, ref]
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp insert_instructions(conn, id, first_number, texts, from, stamp) do
    texts
    |> Enum.with_index(first_number)
    |> Enum.reduce_while({:ok, []}, fn {text, number}, {:ok, added} ->
      row_id = Cues.id("cwi")

      case CuesSql.execute(
             conn,
             "INSERT INTO cue_watcher_instructions (id, watcher_id, number, text, added_at, " <>
               "added_from) VALUES (?, ?, ?, ?, ?, ?)",
             [row_id, id, number, text, stamp, from]
           ) do
        :ok -> {:cont, {:ok, added ++ [%{id: row_id, number: number, text: text}]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # --- reads ---------------------------------------------------------------------

  defp get_watcher(conn, column, value) when column in ["id", "name"] do
    with {:ok, rows} <-
           CuesSql.query_all(conn, @watcher_select <> " WHERE #{column} = ?", [value]),
         {:ok, watcher} <- one_watcher(rows),
         {:ok, sources} <- sources_of(conn, watcher.id),
         {:ok, instructions} <- instructions_of(conn, watcher.id),
         {:ok, examples} <- recent_examples(conn, watcher.id) do
      {active, removed} = Enum.split_with(instructions, &is_nil(&1.removed_at))

      {:ok,
       Map.merge(watcher, %{
         sources: sources,
         instructions: active,
         removed_instructions: removed,
         examples: examples
       })}
    end
  end

  defp one_watcher([row]), do: {:ok, watcher_row(row)}
  defp one_watcher([]), do: {:error, :not_found}

  defp sources_of(conn, id) do
    with {:ok, rows} <-
           CuesSql.query_all(
             conn,
             "SELECT source_ref FROM cue_watcher_sources WHERE watcher_id = ? ORDER BY source_ref",
             [id]
           ) do
      {:ok, Enum.map(rows, &hd/1)}
    end
  end

  defp instructions_of(conn, id) do
    with {:ok, rows} <-
           CuesSql.query_all(
             conn,
             "SELECT id, number, text, added_at, added_from, removed_at, removed_from, replaced_by " <>
               "FROM cue_watcher_instructions WHERE watcher_id = ? ORDER BY number",
             [id]
           ) do
      {:ok, Enum.map(rows, &instruction_row/1)}
    end
  end

  defp recent_examples(conn, id) do
    with {:ok, rows} <-
           CuesSql.query_all(
             conn,
             "SELECT id, cue_id, label, note, snapshot, created_at FROM cue_watcher_examples " <>
               "WHERE watcher_id = ? ORDER BY created_at DESC, id DESC LIMIT ?",
             [id, @recent_examples]
           ) do
      {:ok, Enum.map(rows, &example_row/1)}
    end
  end

  defp list_watchers(conn) do
    with {:ok, rows} <- CuesSql.query_all(conn, @watcher_select <> " ORDER BY name", []),
         {:ok, source_rows} <-
           CuesSql.query_all(
             conn,
             "SELECT watcher_id, source_ref FROM cue_watcher_sources ORDER BY source_ref",
             []
           ),
         {:ok, count_rows} <-
           CuesSql.query_all(
             conn,
             "SELECT watcher_id, count(*) FROM cue_watcher_instructions " <>
               "WHERE removed_at IS NULL GROUP BY watcher_id",
             []
           ) do
      sources = Enum.group_by(source_rows, &hd/1, &List.last/1)
      counts = Map.new(count_rows, fn [id, n] -> {id, n} end)

      {:ok,
       Enum.map(rows, fn row ->
         watcher = watcher_row(row)

         Map.merge(watcher, %{
           sources: Map.get(sources, watcher.id, []),
           active_instructions: Map.get(counts, watcher.id, 0)
         })
       end)}
    end
  end

  defp watcher_row([
         id,
         name,
         purpose,
         filter,
         listen_for,
         task_job_id,
         task_notes,
         daily_cap,
         filter_budget,
         filter_failures,
         filter_retry_at,
         held_notified_at,
         _notices,
         enabled,
         created_from,
         created_at,
         updated_at,
         follow_up_job_id,
         follow_up_approved_at
       ]) do
    %{
      id: id,
      name: name,
      purpose: purpose,
      filter: filter,
      listen_for: Jason.decode!(listen_for),
      task_job_id: task_job_id,
      task_notes?: task_notes == 1,
      daily_cap: daily_cap,
      filter_budget: filter_budget,
      filter_failures: filter_failures,
      filter_retry_at: CuesSql.parse_stamp(filter_retry_at),
      held_notified_at: CuesSql.parse_stamp(held_notified_at),
      enabled?: enabled == 1,
      created_from: created_from,
      created_at: CuesSql.parse_stamp(created_at),
      updated_at: CuesSql.parse_stamp(updated_at),
      follow_up_job_id: follow_up_job_id,
      follow_up_approved_at: CuesSql.parse_stamp(follow_up_approved_at)
    }
  end

  defp instruction_row([id, number, text, added_at, added_from, removed_at, removed_from, by]) do
    %{
      id: id,
      number: number,
      text: text,
      added_at: CuesSql.parse_stamp(added_at),
      added_from: added_from,
      removed_at: CuesSql.parse_stamp(removed_at),
      removed_from: removed_from,
      replaced_by: by
    }
  end

  defp example_row([id, cue_id, label, note, snapshot, created_at]) do
    %{
      id: id,
      cue_id: cue_id,
      label: label,
      note: note,
      snapshot: snapshot,
      created_at: CuesSql.parse_stamp(created_at)
    }
  end

  # --- update --------------------------------------------------------------------

  # A change to its sources or filter clears a follow-up's Always allow it no
  # longer matches, in the same write (M60_WATCHER_CODING_RUNS.md §5), as does a
  # change to its instructions below.
  defp update_watcher(conn, id, expected, patch, sources, now) do
    with :ok <- check_patch(patch),
         :ok <- check_relink(conn, id, patch),
         :ok <- write_patch(conn, id, expected, patch, now),
         {:ok, expired} <- replace_sources(conn, id, sources, now),
         {:ok, passed} <- pass_pending(conn, id, patch, now),
         :ok <- CuesFollowUpAllowSql.clear_stale_approval(conn, {:watcher, id}),
         {:ok, watcher} <- get_watcher(conn, "id", id) do
      {:ok, %{watcher: watcher, passed: passed, expired: expired}}
    end
  end

  # Switching to no filter means everything passes (design §8.1): what waited
  # for the filter is passed here, in the switch's transaction, rather than
  # left for its lifetime to end. That includes a `filtering` row: its call's
  # settle then finds the fence gone and is refused, closing the call. Left
  # filtering, a failed or aborted call would put it back to `pending`, where
  # no `llm` claim takes it again and it holds its subject's later items. The
  # inbox cap bounds the rows per source. Each passed row's ids come back for
  # its `passed` lifecycle event, with its follow-up's trigger, written in the
  # same transaction (`CuesFollowUpSql.on_pass/3`), or nil.
  defp pass_pending(conn, id, %{filter: "none"}, now) do
    patch = %{decision_reason: "no filter", ready_at: now, filter_call_id: nil}

    sql =
      "SELECT id, cue_id, source_ref, state FROM cue_deliveries " <>
        "WHERE watcher_id = ? AND state IN ('pending', 'filtering') ORDER BY id"

    with {:ok, rows} <- CuesSql.query_all(conn, sql, [id]) do
      Enum.reduce_while(rows, {:ok, []}, &pass_one(conn, &1, {patch, now}, &2))
    end
  end

  defp pass_pending(_conn, _id, _patch, _now), do: {:ok, []}

  defp pass_one(conn, [delivery_id, cue_id, source_ref, from], {patch, now}, {:ok, passed}) do
    with :ok <- CuesSql.transition(conn, delivery_id, from, :none, "passed", patch),
         {:ok, follow_up} <- CuesFollowUpSql.on_pass(conn, delivery_id, now) do
      entry = %{delivery_id: delivery_id, cue_id: cue_id, source_ref: source_ref}
      {:cont, {:ok, passed ++ [Map.put(entry, :follow_up, follow_up)]}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp check_patch(patch) do
    case Enum.reject(Map.keys(patch), &(&1 in @patch_fields)) do
      [] -> :ok
      unknown -> {:error, {:invalid_patch, unknown}}
    end
  end

  defp check_relink(conn, id, patch) do
    with :ok <- relink_task(conn, id, patch), do: relink_follow_up(conn, id, patch)
  end

  defp relink_task(conn, id, %{task_job_id: job_id}) when is_binary(job_id),
    do: check_task(conn, job_id, id)

  defp relink_task(_conn, _id, _patch), do: :ok

  defp relink_follow_up(conn, id, %{follow_up_job_id: job_id}) when is_binary(job_id),
    do: check_follow_up(conn, job_id, id)

  defp relink_follow_up(_conn, _id, _patch), do: :ok

  defp write_patch(conn, id, expected, patch, now) do
    columns = patch |> Map.keys() |> Enum.sort()
    set_sql = Enum.map_join(columns, "", &", #{&1} = ?")
    values = Enum.map(columns, &column_value(Map.fetch!(patch, &1)))
    expected_stamp = CuesSql.stamp(expected)

    sql = "UPDATE cue_watchers SET updated_at = ?#{set_sql} WHERE id = ? AND updated_at = ?"

    with :ok <-
           CuesSql.execute(
             conn,
             sql,
             [next_stamp(now, expected)] ++ values ++ [id, expected_stamp]
           ),
         {:ok, changed} <- CuesSql.changes(conn) do
      if changed == 1, do: :ok, else: stale_or_missing(conn, id)
    end
  end

  defp stale_or_missing(conn, id) do
    case CuesSql.query_all(conn, "SELECT 1 FROM cue_watchers WHERE id = ?", [id]) do
      {:ok, []} -> {:error, :not_found}
      {:ok, _rows} -> {:error, :stale}
      {:error, reason} -> {:error, reason}
    end
  end

  defp replace_sources(_conn, _id, nil, _now), do: {:ok, []}

  defp replace_sources(conn, id, sources, now) do
    with :ok <-
           CuesSql.execute(conn, "DELETE FROM cue_watcher_sources WHERE watcher_id = ?", [id]),
         :ok <- insert_sources(conn, id, sources) do
      expire_unlistened(conn, id, now)
    end
  end

  # M60 §8.8 does not cover taking a source off a watcher, so it is treated as
  # removing the watcher for that source: what waits from a source it no
  # longer has expires here, in the change's transaction, ahead of a switch to
  # no filter in the same change, so it is never claimed again, never holds a
  # later item of its subject at the run claim, and is never passed. A row
  # under a filter call expires too: that call's settle then finds its fence
  # gone and is refused as stale, its call closed `aborted`, as for a switch
  # to no filter. No gap, because the owner chose it, as with a pause;
  # `passed` deliveries stay and still go to the task, as after a pause.
  # Adding the source back brings none of them back.
  defp expire_unlistened(conn, id, now) do
    sql = """
    SELECT d.id, d.cue_id, d.source_ref, d.state FROM cue_deliveries d
    WHERE d.watcher_id = ? AND d.state IN ('pending', 'filtering')
      AND NOT EXISTS (SELECT 1 FROM cue_watcher_sources s
                      WHERE s.watcher_id = d.watcher_id AND s.source_ref = d.source_ref)
    ORDER BY d.id
    """

    patch = %{outcome: "watcher_removed", settled_at: now}

    with {:ok, rows} <- CuesSql.query_all(conn, sql, [id]) do
      Enum.reduce_while(rows, {:ok, []}, &expire_one(conn, &1, patch, &2))
    end
  end

  defp expire_one(conn, [delivery_id, cue_id, source_ref, from], patch, {:ok, expired}) do
    case CuesSql.transition(conn, delivery_id, from, :none, "expired", patch) do
      :ok ->
        {:cont,
         {:ok, expired ++ [%{delivery_id: delivery_id, cue_id: cue_id, source_ref: source_ref}]}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  # `updated_at` only ever grows, so a fence read before a change never matches
  # the row after it, even when two changes share one clock reading.
  defp next_stamp(now, previous) do
    if DateTime.compare(now, previous) == :gt,
      do: CuesSql.stamp(now),
      else: previous |> DateTime.add(1, :microsecond) |> CuesSql.stamp()
  end

  defp touch(conn, id, now) do
    with {:ok, rows} <-
           CuesSql.query_all(conn, "SELECT updated_at FROM cue_watchers WHERE id = ?", [id]) do
      case rows do
        [[updated_at]] ->
          CuesSql.execute(
            conn,
            "UPDATE cue_watchers SET updated_at = ? WHERE id = ?",
            [next_stamp(now, CuesSql.parse_stamp(updated_at)), id]
          )

        [] ->
          {:error, :not_found}
      end
    end
  end

  # --- remove --------------------------------------------------------------------

  defp remove_watcher(conn, id, now) do
    with :ok <- touch(conn, id, now),
         :ok <- check_not_held(conn, id),
         :ok <- check_follow_up_idle(conn, id),
         {:ok, refused} <- refuse_open_triggers(conn, id),
         {:ok, rows} <-
           CuesSql.query_all(
             conn,
             "SELECT id, cue_id, source_ref FROM cue_deliveries " <>
               "WHERE watcher_id = ? AND state IN ('pending', 'passed') ORDER BY id",
             [id]
           ),
         :ok <- expire_all(conn, rows, now),
         {:ok, gaps} <- removal_gaps(conn, id, rows, now),
         :ok <- CuesSql.execute(conn, "DELETE FROM cue_watchers WHERE id = ?", [id]) do
      expired =
        Enum.map(rows, fn [delivery_id, cue_id, ref] ->
          %{delivery_id: delivery_id, cue_id: cue_id, source_ref: ref}
        end)

      {:ok, %{expired: expired, gaps: gaps, refused_triggers: refused}}
    end
  end

  # Stopping a follow-up (M60_WATCHER_CODING_RUNS.md §3.5): fenced on the
  # watcher as read, refused while its run holds the job, its open triggers
  # refused, and its columns cleared; the watcher keeps its task (the table's
  # CHECK holds that). The job is the caller's to remove.
  defp remove_follow_up(conn, id, expected, now) do
    patch = %{follow_up_job_id: nil, follow_up_approved_at: nil, follow_up_approval_digest: nil}

    with :ok <- check_follow_up_idle(conn, id),
         {:ok, refused} <- refuse_open_triggers(conn, id),
         :ok <- write_patch(conn, id, expected, patch, now) do
      {:ok, %{refused_triggers: refused}}
    end
  end

  # A follow-up that is running is let finish before its watcher and its job go.
  defp check_follow_up_idle(conn, id) do
    sql = """
    SELECT count(*) FROM job_runs r JOIN cue_watchers w ON w.follow_up_job_id = r.job_id
    WHERE w.id = ? AND r.status IN ('queued', 'running')
    """

    case CuesSql.query_all(conn, sql, [id]) do
      {:ok, [[0]]} -> :ok
      {:ok, [[_running]]} -> {:error, :follow_up_running}
      {:error, reason} -> {:error, reason}
    end
  end

  # A card left waiting or a trigger left to start would act for a watcher
  # that is gone: both end refused with the removal, and come back for their
  # lifecycle events.
  defp refuse_open_triggers(conn, id) do
    select =
      "SELECT id, delivery_id, cue_id, job_id, mode FROM cue_follow_up_triggers " <>
        "WHERE watcher_id = ? AND state IN ('waiting', 'starting') ORDER BY created_at, rowid"

    update =
      "UPDATE cue_follow_up_triggers SET state = 'refused', reason = ? " <>
        "WHERE watcher_id = ? AND state IN ('waiting', 'starting')"

    with {:ok, rows} <- CuesSql.query_all(conn, select, [id]),
         :ok <- CuesSql.execute(conn, update, [@watcher_removed, id]) do
      {:ok, Enum.map(rows, &refused_trigger(id, &1))}
    end
  end

  defp refused_trigger(watcher_id, [id, delivery_id, cue_id, job_id, mode]) do
    %{
      id: id,
      watcher_id: watcher_id,
      delivery_id: delivery_id,
      cue_id: cue_id,
      job_id: job_id,
      mode: mode,
      state: "refused"
    }
  end

  defp check_not_held(conn, id) do
    case CuesSql.query_all(
           conn,
           "SELECT count(*) FROM cue_deliveries WHERE watcher_id = ? " <>
             "AND state IN ('filtering', 'claimed')",
           [id]
         ) do
      {:ok, [[0]]} -> :ok
      {:ok, [[_held]]} -> {:error, :busy}
      {:error, reason} -> {:error, reason}
    end
  end

  defp expire_all(conn, rows, now) do
    patch = %{outcome: "watcher_removed", settled_at: now}

    Enum.reduce_while(rows, :ok, fn [delivery_id, _cue_id, _ref], :ok ->
      case CuesSql.transition(conn, delivery_id, ["pending", "passed"], :none, "expired", patch) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # One `watcher_removed` gap per source whose items the removal left
  # undelivered; a source with nothing waiting lost nothing.
  defp removal_gaps(conn, id, rows, now) do
    rows
    |> Enum.frequencies_by(&List.last/1)
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {ref, count}, {:ok, gaps} ->
      case CuesSql.extend_gap(conn, ref, id, "watcher_removed", count, {nil, nil}, now) do
        {:ok, gap_id} ->
          {:cont, {:ok, gaps ++ [%{gap_id: gap_id, source_ref: ref, count: count}]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  # --- instructions ----------------------------------------------------------------

  defp change_instructions(conn, id, {adds, removes}, from, now, cap) do
    stamp = CuesSql.stamp(now)

    with :ok <- touch(conn, id, now),
         {:ok, active} <- active_instructions(conn, id),
         {:ok, removed} <- pick_active(active, removes),
         :ok <- within_cap(length(active) - length(removed) + length(adds), cap),
         :ok <- mark_removed(conn, removed, from, stamp, nil),
         {:ok, next} <- next_number(conn, id),
         {:ok, added} <- insert_instructions(conn, id, next, adds, from, stamp),
         :ok <- CuesFollowUpAllowSql.clear_stale_approval(conn, {:watcher, id}) do
      {:ok, %{added: added, removed: removed}}
    end
  end

  defp restore_instruction(conn, id, number, _from, now, cap) do
    with :ok <- touch(conn, id, now),
         {:ok, active} <- active_instructions(conn, id),
         :ok <- within_cap(length(active) + 1, cap),
         {:ok, row} <- removed_instruction(conn, id, number),
         :ok <-
           CuesSql.execute(
             conn,
             "UPDATE cue_watcher_instructions SET removed_at = NULL, removed_from = NULL, " <>
               "replaced_by = NULL WHERE id = ?",
             [row.id]
           ),
         :ok <- CuesFollowUpAllowSql.clear_stale_approval(conn, {:watcher, id}) do
      {:ok, %{restored: row}}
    end
  end

  defp merge_instructions(conn, id, numbers, text, from, now) do
    stamp = CuesSql.stamp(now)

    with :ok <- touch(conn, id, now),
         {:ok, active} <- active_instructions(conn, id),
         {:ok, removed} <- pick_active(active, numbers),
         {:ok, next} <- next_number(conn, id),
         {:ok, [added]} <- insert_instructions(conn, id, next, [text], from, stamp),
         :ok <- mark_removed(conn, removed, from, stamp, added.id),
         :ok <- CuesFollowUpAllowSql.clear_stale_approval(conn, {:watcher, id}) do
      {:ok, %{added: [added], removed: removed}}
    end
  end

  defp active_instructions(conn, id) do
    with {:ok, rows} <- instructions_of(conn, id) do
      {:ok, Enum.filter(rows, &is_nil(&1.removed_at))}
    end
  end

  defp pick_active(active, numbers) do
    by_number = Map.new(active, &{&1.number, &1})

    case Enum.reject(Enum.uniq(numbers), &Map.has_key?(by_number, &1)) do
      [] -> {:ok, Enum.map(Enum.uniq(numbers), &Map.fetch!(by_number, &1))}
      missing -> {:error, {:not_active, missing}}
    end
  end

  defp within_cap(count, cap) when count <= cap, do: :ok
  defp within_cap(_count, _cap), do: {:error, :instruction_cap}

  defp mark_removed(conn, rows, from, stamp, replaced_by) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case CuesSql.execute(
             conn,
             "UPDATE cue_watcher_instructions SET removed_at = ?, removed_from = ?, " <>
               "replaced_by = ? WHERE id = ? AND removed_at IS NULL",
             [stamp, from, replaced_by, row.id]
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp next_number(conn, id) do
    case CuesSql.query_all(
           conn,
           "SELECT coalesce(max(number), 0) + 1 FROM cue_watcher_instructions WHERE watcher_id = ?",
           [id]
         ) do
      {:ok, [[next]]} -> {:ok, next}
      {:error, reason} -> {:error, reason}
    end
  end

  defp removed_instruction(conn, id, number) do
    with {:ok, rows} <- instructions_of(conn, id) do
      case Enum.find(rows, &(&1.number == number)) do
        nil -> {:error, {:no_instruction, number}}
        %{removed_at: nil} -> {:error, {:already_active, number}}
        row -> {:ok, row}
      end
    end
  end

  # --- examples --------------------------------------------------------------------

  defp add_example(conn, id, cue_id, label, note, now) do
    with :ok <- touch(conn, id, now),
         {:ok, snapshot} <- delivered_snapshot(conn, id, cue_id) do
      insert_example(conn, id, {cue_id, snapshot}, label, note, now)
    end
  end

  # A stream watcher's drop has no delivery: the drop's ring entry is what
  # showed the watcher had it, so the kept cue's own snapshot is copied.
  defp add_drop_example(conn, id, cue_id, label, note, now) do
    with :ok <- touch(conn, id, now),
         {:ok, snapshot} <- kept_snapshot(conn, cue_id) do
      insert_example(conn, id, {cue_id, snapshot}, label, note, now)
    end
  end

  defp insert_example(conn, id, {cue_id, snapshot}, label, note, now) do
    example_id = Cues.id("cwe")

    with :ok <-
           CuesSql.execute(
             conn,
             "INSERT INTO cue_watcher_examples (id, watcher_id, cue_id, label, note, snapshot, " <>
               "created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
             [example_id, id, cue_id, label, note, snapshot, CuesSql.stamp(now)]
           ) do
      {:ok, %{id: example_id, cue_id: cue_id, label: label, note: note, snapshot: snapshot}}
    end
  end

  defp kept_snapshot(conn, cue_id) do
    case CuesSql.query_all(conn, "SELECT snapshot FROM cues WHERE id = ?", [cue_id]) do
      {:ok, [[snapshot]]} when is_binary(snapshot) -> {:ok, snapshot}
      {:ok, [[nil]]} -> {:error, :snapshot_gone}
      {:ok, []} -> {:error, :cue_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp delivered_snapshot(conn, id, cue_id) do
    case CuesSql.query_all(
           conn,
           "SELECT c.snapshot FROM cue_deliveries d JOIN cues c ON c.id = d.cue_id " <>
             "WHERE d.watcher_id = ? AND d.cue_id = ?",
           [id, cue_id]
         ) do
      {:ok, [[snapshot]]} when is_binary(snapshot) -> {:ok, snapshot}
      {:ok, [[nil]]} -> {:error, :snapshot_gone}
      {:ok, []} -> {:error, :not_delivered}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_example(conn, id, example_id, now) do
    with :ok <- touch(conn, id, now),
         {:ok, rows} <-
           CuesSql.query_all(
             conn,
             "SELECT id, cue_id, label, note, snapshot, created_at FROM cue_watcher_examples " <>
               "WHERE id = ? AND watcher_id = ?",
             [example_id, id]
           ),
         {:ok, example} <- one_example(rows),
         :ok <-
           CuesSql.execute(conn, "DELETE FROM cue_watcher_examples WHERE id = ?", [example_id]) do
      {:ok, example}
    end
  end

  defp one_example([row]), do: {:ok, example_row(row)}
  defp one_example([]), do: {:error, :example_not_found}

  # --- notice claims -----------------------------------------------------------------
  #
  # The single writer serves each request whole, so a claim reads, decides and
  # stamps before any other caller can: two callers never both win one episode.

  defp claim_watcher_notice(conn, id, kind, rule, now) do
    with {:ok, rows} <-
           CuesSql.query_all(
             conn,
             "SELECT name, coalesce(task_job_id, follow_up_job_id), held_notified_at, notices " <>
               "FROM cue_watchers WHERE id = ?",
             [id]
           ),
         {:ok, [name, job_id, held, raw]} <- one_row(rows),
         {:ok, notices} <- decode_notices(raw) do
      target = %{name: name, notice_job_id: job_id}

      case watcher_claim(rule, kind, held, notices, now) do
        {:held, previous, value} -> stamp_held(conn, id, value, target, previous)
        {:notices, previous, updated} -> stamp_notices(conn, id, updated, target, previous)
        :already_sent -> {:ok, :already_sent}
      end
    end
  end

  defp watcher_claim(:held, _kind, nil, _notices, now), do: {:held, nil, CuesSql.stamp(now)}
  defp watcher_claim(:held, _kind, _held, _notices, _now), do: :already_sent
  defp watcher_claim(:recovered, _kind, nil, _notices, _now), do: :already_sent
  defp watcher_claim(:recovered, _kind, held, _notices, _now), do: {:held, held, nil}

  # An episode kept in the notices map under its own kind: claimed while the
  # kind is absent, and closed by the notice that names it.
  defp watcher_claim(:opens, kind, _held, notices, now) do
    if Map.has_key?(notices, kind),
      do: :already_sent,
      else: {:notices, nil, Map.put(notices, kind, CuesSql.stamp(now))}
  end

  defp watcher_claim({:closes, opened}, _kind, _held, notices, _now) do
    case Map.fetch(notices, opened) do
      {:ok, previous} -> {:notices, previous, Map.delete(notices, opened)}
      :error -> :already_sent
    end
  end

  defp watcher_claim(rule, kind, _held, notices, now) do
    previous = Map.get(notices, kind)

    if due?(rule, previous, now),
      do: {:notices, previous, Map.put(notices, kind, CuesSql.stamp(now))},
      else: :already_sent
  end

  defp stamp_held(conn, id, value, target, previous) do
    with :ok <-
           CuesSql.execute(conn, "UPDATE cue_watchers SET held_notified_at = ? WHERE id = ?", [
             value,
             id
           ]) do
      {:ok, {:claimed, Map.put(target, :previous, previous)}}
    end
  end

  defp stamp_notices(conn, id, notices, target, previous) do
    with :ok <-
           CuesSql.execute(conn, "UPDATE cue_watchers SET notices = ? WHERE id = ?", [
             Jason.encode!(notices),
             id
           ]) do
      {:ok, {:claimed, Map.put(target, :previous, previous)}}
    end
  end

  defp release_watcher_notice(conn, id, _kind, rule, previous) when rule in [:held, :recovered] do
    with :ok <-
           CuesSql.execute(conn, "UPDATE cue_watchers SET held_notified_at = ? WHERE id = ?", [
             previous,
             id
           ]) do
      {:ok, :released}
    end
  end

  defp release_watcher_notice(conn, id, kind, rule, previous) do
    key = released_key(kind, rule)

    with {:ok, rows} <-
           CuesSql.query_all(conn, "SELECT notices FROM cue_watchers WHERE id = ?", [id]),
         {:ok, [raw]} <- one_row(rows),
         {:ok, notices} <- decode_notices(raw) do
      restored = put_or_drop(notices, key, previous)

      with :ok <-
             CuesSql.execute(conn, "UPDATE cue_watchers SET notices = ? WHERE id = ?", [
               Jason.encode!(restored),
               id
             ]) do
        {:ok, :released}
      end
    end
  end

  # A closing notice that failed puts back the episode it closed.
  defp released_key(_kind, {:closes, opened}), do: opened
  defp released_key(kind, _rule), do: kind

  defp claim_source_notice(conn, ref, kind, rule, now) do
    stamp = CuesSql.stamp(now)

    with :ok <-
           CuesSql.execute(
             conn,
             "INSERT INTO cue_sources (source_ref, updated_at) VALUES (?, ?) " <>
               "ON CONFLICT (source_ref) DO NOTHING",
             [ref, stamp]
           ),
         {:ok, rows} <-
           CuesSql.query_all(
             conn,
             "SELECT last_good_at, notices FROM cue_sources WHERE source_ref = ?",
             [ref]
           ),
         {:ok, [last_good, raw]} <- one_row(rows),
         {:ok, notices} <- decode_notices(raw) do
      previous = Map.get(notices, kind)

      if source_due?(rule, previous, last_good, now),
        do: write_source_notices(conn, ref, Map.put(notices, kind, stamp), previous),
        else: {:ok, :already_sent}
    end
  end

  defp write_source_notices(conn, ref, notices, previous) do
    with :ok <-
           CuesSql.execute(conn, "UPDATE cue_sources SET notices = ? WHERE source_ref = ?", [
             Jason.encode!(notices),
             ref
           ]) do
      {:ok, {:claimed, %{previous: previous}}}
    end
  end

  defp release_source_notice(conn, ref, kind, previous) do
    with {:ok, rows} <-
           CuesSql.query_all(conn, "SELECT notices FROM cue_sources WHERE source_ref = ?", [ref]),
         {:ok, [raw]} <- one_row(rows),
         {:ok, notices} <- decode_notices(raw) do
      restored = put_or_drop(notices, kind, previous)

      with :ok <-
             CuesSql.execute(conn, "UPDATE cue_sources SET notices = ? WHERE source_ref = ?", [
               Jason.encode!(restored),
               ref
             ]) do
        {:ok, :released}
      end
    end
  end

  # A source episode ends when the source has a good moment after the notice.
  defp source_due?(:since_last_good, nil, _last_good, _now), do: true
  defp source_due?(:since_last_good, _previous, nil, _now), do: false
  defp source_due?(:since_last_good, previous, last_good, _now), do: last_good > previous
  defp source_due?(rule, previous, _last_good, now), do: due?(rule, previous, now)

  defp due?(_rule, nil, _now), do: true

  defp due?(:once, _previous, _now), do: false

  defp due?(:utc_day, previous, now),
    do: String.slice(previous, 0, 10) != Date.to_iso8601(DateTime.to_date(now))

  defp due?({:window, seconds}, previous, now) when is_integer(seconds) and seconds > 0,
    do: previous <= CuesSql.stamp(DateTime.add(now, -seconds, :second))

  defp due_gap_notices(conn, now, limit) do
    cutoff = now |> DateTime.add(-@gap_notice_after_s, :second) |> CuesSql.stamp()

    with {:ok, rows} <-
           CuesSql.query_all(
             conn,
             """
             SELECT g.id, g.source_ref, g.watcher_id, g.reason, g.count, g.first_at, w.name,
               coalesce(w.task_job_id, w.follow_up_job_id)
             FROM cue_gaps g JOIN cue_watchers w ON w.id = g.watcher_id
             WHERE g.reported_at IS NULL AND g.closed_at IS NULL AND g.first_at <= ?
             ORDER BY g.first_at, g.id LIMIT ?
             """,
             [cutoff, limit]
           ) do
      {:ok, Enum.map(rows, &gap_notice_row/1)}
    end
  end

  defp gap_notice_row([id, ref, watcher_id, reason, count, first_at, name, job_id]) do
    %{
      gap_id: id,
      source_ref: ref,
      watcher_id: watcher_id,
      reason: reason,
      count: count,
      first_at: CuesSql.parse_stamp(first_at),
      name: name,
      notice_job_id: job_id
    }
  end

  # --- helpers -----------------------------------------------------------------------

  defp one_row([row]), do: {:ok, row}
  defp one_row([]), do: {:error, :not_found}

  # The column defaults to `{}` and only this module writes it; anything else is
  # a damaged row, reported rather than read as "never sent".
  defp decode_notices(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _malformed -> {:error, :malformed_notices}
    end
  end

  defp decode_notices(_other), do: {:error, :malformed_notices}

  defp put_or_drop(map, key, nil), do: Map.delete(map, key)
  defp put_or_drop(map, key, value), do: Map.put(map, key, value)

  defp flag(true), do: 1
  defp flag(false), do: 0

  defp column_value(value) when is_boolean(value), do: flag(value)
  defp column_value(value) when is_list(value), do: Jason.encode!(value)
  defp column_value(value), do: value
end
