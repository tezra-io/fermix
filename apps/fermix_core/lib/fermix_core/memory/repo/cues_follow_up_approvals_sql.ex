defmodule FermixCore.Memory.Repo.CuesFollowUpApprovalsSql do
  @moduledoc """
  SQL for an automatic follow-up's approval (M60_WATCHER_CODING_RUNS.md §3.4,
  §5): the approval on the watcher's row, bound to a digest of what the
  follow-up runs and what sets it off, and the table `cue_follow_up_approvals`
  of the prompts that ask the owner for it.

  Pure SQL over the caller's `conn`, reached only through
  `FermixCore.Memory.Repo.cues_call/3`. One `handle/2` head per request tuple,
  every head contiguous and above the catch-all, which must stay last.
  Transactions go through `CuesSql.with_immediate_transaction/2`, timestamps
  through `CuesSql.stamp/1`.

  ## The approval

  `follow_up_approved_at` and `follow_up_approval_digest` on `cue_watchers`
  hold the owner's approval and the digest it approved
  (`Cues.Watchers.follow_up_digest/2`, computed here from the stored rows). A
  pass runs the follow-up on its own only while that digest is still the
  follow-up's (`effective_mode/2`). Every write that changes what the digest
  covers clears the approval in its own transaction (`clear_stale_approval/2`,
  which `CuesWatchersSql` and `Memory.Repo` call), so undoing the change does
  not bring the approval back, and the owner's "Keep asking" clears it too.

  ## The prompts

  A prompt holds the digest it showed, where it went, its expiry and the
  owner's answer (`waiting → approved | denied | expired`). One waits per
  watcher: a new prompt expires the one before it. An answer only records
  itself here, a no clearing the approval as it does; a yes is applied by
  `Cues.Watchers.approve_follow_up/3`, and only while the digest it showed is
  still the follow-up's.

  `effective_mode/2` and `clear_stale_approval/2` are not requests: each runs
  inside a transaction another module owns (`CuesFollowUpSql.on_pass/3`, a
  watcher's or a job's write).
  """

  alias FermixCore.Cues.Watchers
  alias FermixCore.Memory.Repo.CuesSql

  @schema_sql """
  CREATE TABLE IF NOT EXISTS cue_follow_up_approvals (
    id TEXT PRIMARY KEY,
    watcher_id TEXT NOT NULL,
    shown_digest TEXT NOT NULL,
    token_digest TEXT UNIQUE,
    chat_platform TEXT,
    chat_id TEXT,
    chat_user_id TEXT,
    expires_at TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('waiting','approved','denied','expired')),
    decided_from TEXT,
    decided_at TEXT,
    created_at TEXT NOT NULL,
    CHECK ((state IN ('approved','denied')) = (decided_at IS NOT NULL))
  );
  CREATE INDEX IF NOT EXISTS cue_follow_up_approvals_state ON cue_follow_up_approvals (state, expires_at);
  CREATE INDEX IF NOT EXISTS cue_follow_up_approvals_watcher ON cue_follow_up_approvals (watcher_id, state);
  """

  @approval_columns """
  a.id, a.watcher_id, w.name, a.shown_digest, a.state, a.token_digest IS NOT NULL,
  a.chat_platform, a.chat_id, a.chat_user_id, a.expires_at, a.decided_from, a.decided_at,
  a.created_at
  """

  # What an approval's prompt shows: what the follow-up runs and what sets it
  # off, as stored now.
  @approval_card_sql """
  SELECT #{@approval_columns}, w.daily_cap, w.filter, w.purpose, w.listen_for,
         (SELECT json_group_array(source_ref) FROM
            (SELECT source_ref FROM cue_watcher_sources s WHERE s.watcher_id = a.watcher_id
             ORDER BY source_ref)),
         j.id, j.name, j.task_prompt, j.allowed_tools_json, j.delivery_mode,
         j.delivery_target_json
  FROM cue_follow_up_approvals a
  LEFT JOIN cue_watchers w ON w.id = a.watcher_id
  LEFT JOIN scheduled_jobs j ON j.id = w.follow_up_job_id
  """

  @clear_approval "UPDATE cue_watchers SET follow_up_approved_at = NULL, " <>
                    "follow_up_approval_digest = NULL WHERE id = ?"

  @approval_states ~w(waiting approved denied expired)

  @type conn :: term()
  @typedoc "An automatic approval's prompt as this module reads it."
  @type approval :: %{
          id: String.t(),
          watcher_id: String.t(),
          watcher_name: String.t() | nil,
          shown_digest: String.t(),
          state: String.t(),
          offered?: boolean(),
          chat: %{platform: String.t(), chat_id: String.t(), user_id: String.t() | nil} | nil,
          expires_at: DateTime.t(),
          decided_from: String.t() | nil,
          decided_at: DateTime.t() | nil,
          created_at: DateTime.t()
        }

  @doc "The DDL of the prompt table and its indexes (migration 54)."
  @spec schema_sql() :: String.t()
  def schema_sql, do: @schema_sql

  # --- requests -------------------------------------------------------------------

  @doc """
  Serves one request on `conn`; an unknown request is an error, never a raise.

  - `{:follow_up_digest, watcher_id}` → `{:ok, digest}`: the digest of what
    the follow-up runs and what sets it off now (`Cues.Watchers.follow_up_digest/2`).
  - `{:approve, watcher_id, shown_digest, now}` → `{:ok, digest}`: records the
    automatic approval when `shown_digest` is still the follow-up's;
    `{:error, :changed}` when it is not, `{:error, :not_automatic}` for a
    follow-up that asks first.
  - `{:effective_mode, watcher_id}` → `{:ok, "auto" | "approve" | nil}`: how
    the watcher's follow-up runs now, as a pass decides it: `"auto"` only while
    its approval's digest is still that of what it runs and what sets it off;
    nil for a watcher with no follow-up.
  - `{:ask_approval, %{id, watcher_id, shown_digest, expires_at}, now}` →
    `{:ok, {approval, superseded}}`: a new prompt, `waiting`; the watcher's
    prompt still waiting before it is expired and comes back.
  - `{:record_approval_offer, id, binding}` → `{:ok, approval}`: where the
    prompt went, on a waiting prompt with no token yet.
  - `{:answer_approval, digest, origin, "approved" | "denied", now}`: the
    owner's answer by token, fenced on the digest, `waiting`, the chat it went
    to and the expiry; `{:decide_approval, id, to_state, decided_from, now}`
    by id, fenced on `waiting` and the expiry. A no clears the watcher's
    approval in the same transaction.
  - `{:approvals_waiting_in_chat, origin, now}` → `{:ok, [approval]}`.
  - `{:approval_card, id}` → `{:ok, approval_card_row | nil}`;
    `{:waiting_approval_cards, now, limit}` → `{:ok, [approval_card_row]}`.
  - `{:expire_approvals, now, limit}` → `{:ok, [approval]}`: waiting past the
    expiry → `expired`.
  """
  @spec handle(conn(), tuple()) :: term()
  def handle(conn, {:follow_up_digest, watcher_id}) when is_binary(watcher_id),
    do: current_digest(conn, watcher_id)

  def handle(conn, {:approve, watcher_id, shown, %DateTime{} = now})
      when is_binary(watcher_id) and is_binary(shown) do
    CuesSql.with_immediate_transaction(conn, fn -> approve(conn, watcher_id, shown, now) end)
  end

  def handle(conn, {:effective_mode, watcher_id}) when is_binary(watcher_id) do
    sql = "SELECT follow_up_mode, follow_up_approval_digest FROM cue_watchers WHERE id = ?"

    case CuesSql.query_all(conn, sql, [watcher_id]) do
      {:ok, [[nil, _approval]]} ->
        {:ok, nil}

      {:ok, [[mode, approval]]} ->
        effective_mode(conn, %{mode: mode, approval_digest: approval, watcher_id: watcher_id})

      {:ok, []} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle(conn, {:ask_approval, %{id: id, watcher_id: watcher_id} = row, %DateTime{} = now})
      when is_binary(id) and is_binary(watcher_id) do
    CuesSql.with_immediate_transaction(conn, fn -> ask_approval(conn, row, now) end)
  end

  def handle(conn, {:record_approval_offer, id, binding})
      when is_binary(id) and is_map(binding) do
    CuesSql.with_immediate_transaction(conn, fn -> record_approval_offer(conn, id, binding) end)
  end

  def handle(conn, {:answer_approval, digest, origin, to_state, %DateTime{} = now})
      when is_binary(digest) and to_state in ["approved", "denied"] do
    case CuesSql.checked_origin(origin) do
      {:ok, origin} ->
        CuesSql.with_immediate_transaction(conn, fn ->
          answer_approval(conn, digest, origin, to_state, now)
        end)

      :error ->
        {:error, :wrong_origin}
    end
  end

  def handle(conn, {:decide_approval, id, to_state, decided_from, %DateTime{} = now})
      when is_binary(id) and to_state in ["approved", "denied"] and is_binary(decided_from) do
    CuesSql.with_immediate_transaction(conn, fn ->
      decide_approval(conn, id, to_state, decided_from, now)
    end)
  end

  def handle(conn, {:approvals_waiting_in_chat, origin, %DateTime{} = now}) do
    where =
      "a.state = 'waiting' AND a.expires_at > ? AND a.chat_platform = ? AND a.chat_id = ? " <>
        "AND a.chat_user_id = ? ORDER BY a.created_at, a.rowid"

    case CuesSql.checked_origin(origin) do
      {:ok, chat} ->
        list_approvals(conn, where, [
          CuesSql.stamp(now),
          chat.platform,
          chat.chat_id,
          chat.user_id
        ])

      :error ->
        {:error, :wrong_origin}
    end
  end

  def handle(conn, {:approval_card, id}) when is_binary(id) do
    case CuesSql.query_all(conn, @approval_card_sql <> "WHERE a.id = ?", [id]) do
      {:ok, [row]} -> approval_card_row(row)
      {:ok, []} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle(conn, {:waiting_approval_cards, %DateTime{} = now, limit})
      when is_integer(limit) and limit > 0 do
    where =
      "WHERE a.state = 'waiting' AND a.expires_at > ? ORDER BY a.created_at, a.rowid LIMIT ?"

    with {:ok, rows} <-
           CuesSql.query_all(conn, @approval_card_sql <> where, [CuesSql.stamp(now), limit]) do
      collect_ok(rows, &approval_card_row/1)
    end
  end

  def handle(conn, {:expire_approvals, %DateTime{} = now, limit})
      when is_integer(limit) and limit > 0 do
    CuesSql.with_immediate_transaction(conn, fn -> expire_approvals(conn, now, limit) end)
  end

  def handle(_conn, request), do: {:error, {:unknown_request, request}}

  # --- the approval (§5) --------------------------------------------------------------

  @doc """
  How a pass runs the watcher's follow-up (`facts`: its `mode`, its
  `approval_digest` and its `watcher_id`): on its own (`"auto"`) only while
  its approval's digest is still that of what it runs and what sets it off,
  else asking first. Inside the pass's transaction (`CuesFollowUpSql.on_pass/3`).
  """
  @spec effective_mode(conn(), map()) :: {:ok, String.t()} | {:error, term()}
  def effective_mode(_conn, %{mode: "approve"}), do: {:ok, "approve"}
  def effective_mode(_conn, %{mode: "auto", approval_digest: nil}), do: {:ok, "approve"}

  def effective_mode(conn, %{mode: "auto", approval_digest: approved, watcher_id: watcher_id})
      when is_binary(approved) do
    with {:ok, current} <- current_digest(conn, watcher_id) do
      {:ok, if(current == approved, do: "auto", else: "approve")}
    end
  end

  @doc """
  Clears the automatic approval of the watcher `{:watcher, id}`, or of the one
  whose follow-up is job `{:follow_up_job, id}`, when what the follow-up runs
  or what sets it off no longer matches the digest it approved (§5). Called in
  the transaction of every write that can change one of them, after the
  write, so the approval is cleared rather than shadowed: undoing the change
  does not bring it back. Nothing for a watcher with no approval, or a job
  that is no watcher's follow-up.
  """
  @spec clear_stale_approval(conn(), {:watcher | :follow_up_job, String.t()}) ::
          :ok | {:error, term()}
  def clear_stale_approval(conn, {by, id})
      when by in [:watcher, :follow_up_job] and is_binary(id) do
    column = if by == :watcher, do: "id", else: "follow_up_job_id"
    sql = "SELECT id, follow_up_approval_digest FROM cue_watchers WHERE #{column} = ?"

    case CuesSql.query_all(conn, sql, [id]) do
      {:ok, [[watcher_id, approved]]} when is_binary(approved) ->
        clear_if_changed(conn, watcher_id, approved)

      {:ok, _no_approval} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp clear_if_changed(conn, watcher_id, approved) do
    case current_digest(conn, watcher_id) do
      {:ok, ^approved} -> :ok
      {:ok, _changed} -> CuesSql.execute(conn, @clear_approval, [watcher_id])
      {:error, reason} -> {:error, reason}
    end
  end

  defp approve(conn, watcher_id, shown, now) do
    with {:ok, mode} <- follow_up_mode(conn, watcher_id),
         :ok <- automatic(mode),
         {:ok, current} <- current_digest(conn, watcher_id),
         :ok <- unchanged(current, shown),
         :ok <-
           CuesSql.execute(
             conn,
             "UPDATE cue_watchers SET follow_up_approved_at = ?, follow_up_approval_digest = ? " <>
               "WHERE id = ?",
             [CuesSql.stamp(now), current, watcher_id]
           ) do
      {:ok, current}
    end
  end

  defp follow_up_mode(conn, watcher_id) do
    case CuesSql.query_all(conn, "SELECT follow_up_mode FROM cue_watchers WHERE id = ?", [
           watcher_id
         ]) do
      {:ok, [[mode]]} -> {:ok, mode}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp automatic("auto"), do: :ok
  defp automatic(nil), do: {:error, :no_follow_up}
  defp automatic(_mode), do: {:error, :not_automatic}

  defp unchanged(same, same), do: :ok
  defp unchanged(_current, _shown), do: {:error, :changed}

  # What decides when the follow-up runs and what it runs, read as stored and
  # handed to the one digest function, so the approval and every pass compute it
  # from the same reads.
  defp current_digest(conn, watcher_id) do
    with {:ok, watcher} <- digest_watcher(conn, watcher_id),
         {:ok, job} <- digest_job(conn, watcher.follow_up_job_id) do
      {:ok, Watchers.follow_up_digest(job, watcher)}
    end
  end

  defp digest_watcher(conn, watcher_id) do
    sql = "SELECT follow_up_job_id, filter, purpose, listen_for FROM cue_watchers WHERE id = ?"

    with {:ok, rows} <- CuesSql.query_all(conn, sql, [watcher_id]),
         {:ok, [job_id, filter, purpose, words]} <- one(rows, :not_found),
         :ok <- has_follow_up(job_id),
         {:ok, sources} <- digest_sources(conn, watcher_id),
         {:ok, instructions} <- digest_instructions(conn, watcher_id),
         {:ok, listen_for} <- decode(words, :listen_for) do
      {:ok,
       %{
         follow_up_job_id: job_id,
         filter: filter,
         purpose: purpose,
         listen_for: listen_for,
         sources: sources,
         instructions: instructions
       }}
    end
  end

  defp has_follow_up(nil), do: {:error, :no_follow_up}
  defp has_follow_up(_job_id), do: :ok

  defp digest_sources(conn, watcher_id) do
    sql = "SELECT source_ref FROM cue_watcher_sources WHERE watcher_id = ? ORDER BY source_ref"
    with {:ok, rows} <- CuesSql.query_all(conn, sql, [watcher_id]), do: {:ok, List.flatten(rows)}
  end

  defp digest_instructions(conn, watcher_id) do
    sql =
      "SELECT text FROM cue_watcher_instructions WHERE watcher_id = ? AND removed_at IS NULL " <>
        "ORDER BY number"

    with {:ok, rows} <- CuesSql.query_all(conn, sql, [watcher_id]) do
      {:ok, Enum.map(rows, fn [text] -> %{text: text} end)}
    end
  end

  defp digest_job(conn, job_id) do
    sql = """
    SELECT task_prompt, allowed_tools_json, skill_name, model, provider, delivery_mode,
           delivery_target_json
    FROM scheduled_jobs WHERE id = ?
    """

    with {:ok, rows} <- CuesSql.query_all(conn, sql, [job_id]),
         {:ok, [prompt, tools, skill, model, provider, mode, target]} <- one(rows, :job_not_found),
         {:ok, tools} <- decode(tools, :allowed_tools),
         {:ok, target} <- decode(target, :delivery_target) do
      {:ok,
       %{
         task_prompt: prompt,
         allowed_tools: tools || [],
         skill_name: skill,
         model: model,
         provider: provider,
         delivery_mode: mode,
         delivery_target: target
       }}
    end
  end

  defp decode(nil, _column), do: {:ok, nil}

  defp decode(text, column) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:error, {:corrupt, column}}
    end
  end

  # --- the prompts ----------------------------------------------------------------------

  # One prompt waits per watcher: the one before a new prompt expires with the
  # new one's insert, and is answered with it, so an app can drop its card.
  defp ask_approval(conn, row, now) do
    where = "a.watcher_id = ? AND a.state = 'waiting'"
    supersede = "UPDATE cue_follow_up_approvals SET state = 'expired' WHERE id = ?"

    insert = """
    INSERT INTO cue_follow_up_approvals (id, watcher_id, shown_digest, expires_at, state,
      created_at)
    VALUES (?, ?, ?, ?, 'waiting', ?)
    """

    params = [row.id, row.watcher_id, row.shown_digest, CuesSql.stamp(row.expires_at)]

    with {:ok, waiting} <- list_approvals(conn, where, [row.watcher_id]),
         {:ok, superseded} <- update_each(conn, supersede, waiting, "expired"),
         :ok <- CuesSql.execute(conn, insert, params ++ [CuesSql.stamp(now)]),
         {:ok, approval} <- fetch_approval(conn, row.id) do
      {:ok, {approval, superseded}}
    end
  end

  defp record_approval_offer(conn, id, binding) do
    sql = """
    UPDATE cue_follow_up_approvals
    SET token_digest = ?, chat_platform = ?, chat_id = ?, chat_user_id = ?
    WHERE id = ? AND state = 'waiting' AND token_digest IS NULL
    """

    params = [
      Map.get(binding, :token_digest),
      Map.get(binding, :platform),
      Map.get(binding, :chat_id),
      Map.get(binding, :user_id),
      id
    ]

    with :ok <- CuesSql.execute(conn, sql, params),
         {:ok, changed} <- CuesSql.changes(conn) do
      if changed == 1, do: fetch_approval(conn, id), else: {:error, :not_waiting}
    end
  end

  defp answer_approval(conn, digest, origin, to_state, now) do
    stamp = CuesSql.stamp(now)

    sql = """
    UPDATE cue_follow_up_approvals SET state = ?, decided_at = ?, decided_from = ?
    WHERE token_digest = ? AND state = 'waiting' AND chat_platform = ? AND chat_id = ?
      AND chat_user_id = ? AND expires_at > ?
    """

    params = [to_state, stamp, CuesSql.origin_text(origin), digest]
    params = params ++ [origin.platform, origin.chat_id, origin.user_id, stamp]

    with :ok <- CuesSql.execute(conn, sql, params),
         {:ok, changed} <- CuesSql.changes(conn) do
      answered_or_why(conn, "a.token_digest = ?", [digest], changed, now)
    end
  end

  defp decide_approval(conn, id, to_state, decided_from, now) do
    stamp = CuesSql.stamp(now)

    sql =
      "UPDATE cue_follow_up_approvals SET state = ?, decided_at = ?, decided_from = ? " <>
        "WHERE id = ? AND state = 'waiting' AND expires_at > ?"

    with :ok <- CuesSql.execute(conn, sql, [to_state, stamp, decided_from, id, stamp]),
         {:ok, changed} <- CuesSql.changes(conn) do
      answered_or_why(conn, "a.id = ?", [id], changed, now)
    end
  end

  defp answered_or_why(conn, where, params, 1, _now) do
    with {:ok, approval} <- fetch_one_approval(conn, where, params),
         :ok <- kept_asking(conn, approval),
         do: {:ok, approval}
  end

  defp answered_or_why(conn, where, params, 0, now) do
    case list_approvals(conn, where, params) do
      {:ok, []} -> {:error, :unknown}
      {:ok, [%{state: "waiting"} = approval]} -> {:error, CuesSql.waiting_why(approval, now)}
      {:ok, [%{state: state}]} -> {:error, {:not_waiting, state}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The owner's "Keep asking" leaves no approval standing: the follow-up asks
  # first until the owner approves it again.
  defp kept_asking(conn, %{state: "denied", watcher_id: watcher_id}),
    do: CuesSql.execute(conn, @clear_approval, [watcher_id])

  defp kept_asking(_conn, _approved), do: :ok

  defp expire_approvals(conn, now, limit) do
    where = "a.state = 'waiting' AND a.expires_at <= ? ORDER BY a.expires_at, a.rowid LIMIT ?"
    sql = "UPDATE cue_follow_up_approvals SET state = 'expired' WHERE id = ?"

    with {:ok, approvals} <- list_approvals(conn, where, [CuesSql.stamp(now), limit]),
         do: update_each(conn, sql, approvals, "expired")
  end

  # Runs `sql` with each row's id, answering the rows in their new state.
  defp update_each(conn, sql, rows, state) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, done} ->
      case CuesSql.execute(conn, sql, [row.id]) do
        :ok -> {:cont, {:ok, [%{row | state: state} | done]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, done} -> {:ok, Enum.reverse(done)}
      {:error, reason} -> {:error, reason}
    end)
  end

  # --- reads ------------------------------------------------------------------------

  defp list_approvals(conn, where, params) do
    sql =
      "SELECT #{@approval_columns} FROM cue_follow_up_approvals a " <>
        "LEFT JOIN cue_watchers w ON w.id = a.watcher_id WHERE " <> where

    with {:ok, rows} <- CuesSql.query_all(conn, sql, params),
         do: {:ok, Enum.map(rows, &approval_row/1)}
  end

  defp fetch_approval(conn, id), do: fetch_one_approval(conn, "a.id = ?", [id])

  defp fetch_one_approval(conn, where, params) do
    with {:ok, rows} <- list_approvals(conn, where, params), do: one(rows, :not_found)
  end

  defp one([row], _none), do: {:ok, row}
  defp one([], none), do: {:error, none}

  defp approval_row([
         id,
         watcher_id,
         watcher_name,
         shown_digest,
         state,
         offered,
         platform,
         chat_id,
         user_id,
         expires_at,
         decided_from,
         decided_at,
         created_at
       ])
       when state in @approval_states do
    %{
      id: id,
      watcher_id: watcher_id,
      watcher_name: watcher_name,
      shown_digest: shown_digest,
      state: state,
      offered?: offered == 1,
      chat: CuesSql.answer_chat(platform, chat_id, user_id),
      expires_at: CuesSql.parse_stamp(expires_at),
      decided_from: decided_from,
      decided_at: CuesSql.parse_stamp(decided_at),
      created_at: CuesSql.parse_stamp(created_at)
    }
  end

  defp approval_card_row(row) do
    {approval, [cap, filter, purpose, words, sources, job_id, job_name, prompt | rest]} =
      Enum.split(row, 13)

    [tools, delivery_mode, target] = rest

    with {:ok, words} <- decode(words, :listen_for),
         {:ok, sources} <- decode(sources, :sources),
         {:ok, tools} <- decode(tools, :allowed_tools),
         {:ok, target} <- decode(target, :delivery_target) do
      {:ok,
       Map.merge(approval_row(approval), %{
         daily_cap: cap,
         filter: filter,
         purpose: purpose,
         listen_for: words || [],
         sources: sources || [],
         job_id: job_id,
         job_name: job_name,
         task_prompt: prompt,
         allowed_tools: tools || [],
         delivery_mode: delivery_mode,
         delivery_target: target
       })}
    end
  end

  defp collect_ok(rows, fun) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, done} ->
      case fun.(row) do
        {:ok, value} -> {:cont, {:ok, [value | done]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, done} -> {:ok, Enum.reverse(done)}
      {:error, reason} -> {:error, reason}
    end)
  end
end
