defmodule FermixCore.Memory.Repo.CuesFollowUpAllowSql do
  @moduledoc """
  SQL for a follow-up's Always allow (M60_WATCHER_CODING_RUNS.md §5, revision
  of 2026-10-31): the owner's approval on the watcher's row, bound to a digest
  of what the follow-up runs and what sets it off.

  Pure SQL over the caller's `conn`, reached through
  `FermixCore.Memory.Repo.cues_call/3` for its requests. One `handle/2` head per
  request tuple, above the catch-all, which stays last. Transactions go through
  `CuesSql.with_immediate_transaction/2`, timestamps through `CuesSql.stamp/1`.

  ## The approval

  `follow_up_approved_at` and `follow_up_approval_digest` on `cue_watchers`
  hold the owner's Always allow and the digest it allowed
  (`Cues.Watchers.follow_up_digest/2`, computed here from the stored rows).
  Only the owner's Always allow on one of the follow-up's cards writes them
  (`allow_shown/5`, inside that answer's transaction in `CuesFollowUpSql`), and
  only for the digest the card showed (`card_digest/3`, read with the card).
  A pass runs the follow-up with no card only while that digest is still the
  follow-up's (`allowed?/2`). Every write that changes what the digest covers
  clears the approval in its own transaction (`clear_stale_approval/2`, which
  `CuesWatchersSql` and `Memory.Repo` call), so undoing the change does not
  bring it back. The owner takes it back with `{:revoke, watcher_id}`, from
  chat or an app; nothing else writes it.

  `allowed?/2`, `allow_shown/5`, `card_digest/3`, `current_digest/2` and
  `clear_stale_approval/2` are not requests: each runs inside a read or a
  transaction another module owns.
  """

  alias FermixCore.Cues.Watchers
  alias FermixCore.Memory.Repo.CuesSql

  @clear_approval "UPDATE cue_watchers SET follow_up_approved_at = NULL, " <>
                    "follow_up_approval_digest = NULL WHERE id = ?"

  @type conn :: term()
  @typedoc "What the owner's Always allow came to: allowed, or a card that no longer matches."
  @type outcome :: String.t()

  # --- requests -------------------------------------------------------------------

  @doc """
  Serves one request on `conn`; an unknown request is an error, never a raise.

  - `{:allowed, watcher_id}` → `{:ok, boolean}`: whether the watcher's
    follow-up is always allowed for what it runs and what sets it off now;
    `{:error, :not_found}` for no such watcher.
  - `{:revoke, watcher_id}` → `{:ok, boolean}`: the approval cleared, and
    whether there was one to clear.
  """
  @spec handle(conn(), tuple()) :: term()
  def handle(conn, {:allowed, watcher_id}) when is_binary(watcher_id) do
    sql = "SELECT follow_up_approval_digest FROM cue_watchers WHERE id = ?"

    case CuesSql.query_all(conn, sql, [watcher_id]) do
      {:ok, [[approved]]} -> allowed?(conn, %{approval_digest: approved, watcher_id: watcher_id})
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle(conn, {:revoke, watcher_id}) when is_binary(watcher_id) do
    CuesSql.with_immediate_transaction(conn, fn -> revoke(conn, watcher_id) end)
  end

  def handle(_conn, request), do: {:error, {:unknown_request, request}}

  # --- the approval ------------------------------------------------------------------

  @doc """
  Whether a pass runs the watcher's follow-up with no card (`facts`: its
  `approval_digest` and its `watcher_id`): only while the digest the owner
  allowed is still that of what it runs and what sets it off. Inside the
  pass's transaction (`CuesFollowUpSql.on_pass/3`).
  """
  @spec allowed?(conn(), map()) :: {:ok, boolean()} | {:error, term()}
  def allowed?(_conn, %{approval_digest: nil}), do: {:ok, false}

  def allowed?(conn, %{approval_digest: approved, watcher_id: watcher_id})
      when is_binary(approved) and is_binary(watcher_id) do
    with {:ok, current} <- current_digest(conn, watcher_id), do: {:ok, current == approved}
  end

  @doc """
  Records the owner's Always allow from a card of job `job_id`, inside the
  answer's transaction: the approval is written only while `shown` (the digest
  the card showed) is still the follow-up's and `job_id` still the watcher's
  follow-up, else nothing is. Answers `"allowed"` or `"changed"`.
  """
  @spec allow_shown(conn(), String.t(), String.t(), String.t() | nil, DateTime.t()) ::
          {:ok, outcome()} | {:error, term()}
  def allow_shown(conn, watcher_id, job_id, shown, %DateTime{} = now)
      when is_binary(watcher_id) and is_binary(job_id) do
    with {:ok, current} <- card_digest(conn, watcher_id, job_id) do
      if is_binary(shown) and current == shown,
        do: write_approval(conn, watcher_id, shown, now),
        else: {:ok, "changed"}
    end
  end

  defp write_approval(conn, watcher_id, digest, now) do
    sql =
      "UPDATE cue_watchers SET follow_up_approved_at = ?, follow_up_approval_digest = ? " <>
        "WHERE id = ?"

    with :ok <- CuesSql.execute(conn, sql, [CuesSql.stamp(now), digest, watcher_id]),
         do: {:ok, "allowed"}
  end

  defp revoke(conn, watcher_id) do
    sql = @clear_approval <> " AND follow_up_approval_digest IS NOT NULL"

    with {:ok, _exists} <- watcher_exists(conn, watcher_id),
         :ok <- CuesSql.execute(conn, sql, [watcher_id]),
         {:ok, changed} <- CuesSql.changes(conn),
         do: {:ok, changed == 1}
  end

  defp watcher_exists(conn, watcher_id) do
    case CuesSql.query_all(conn, "SELECT 1 FROM cue_watchers WHERE id = ?", [watcher_id]) do
      {:ok, [_row]} -> {:ok, true}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Clears the approval of the watcher `{:watcher, id}`, or of the one whose
  follow-up is job `{:follow_up_job, id}`, when what the follow-up runs or what
  sets it off no longer matches the digest it allowed. Called in the
  transaction of every write that can change one of them, after the write, so
  the approval is cleared rather than shadowed: undoing the change does not
  bring it back. Nothing for a watcher with no approval, or a job that is no
  watcher's follow-up.
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

  # --- the digest ---------------------------------------------------------------------

  @doc """
  The digest a card of job `job_id` shows, read in the same Repo call as the
  card: the watcher's `current_digest/2` while `job_id` is still its
  follow-up, else nil (the watcher or its follow-up is gone or replaced).
  """
  @spec card_digest(conn(), String.t(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def card_digest(conn, watcher_id, job_id) when is_binary(watcher_id) and is_binary(job_id) do
    sql = "SELECT follow_up_job_id FROM cue_watchers WHERE id = ?"

    case CuesSql.query_all(conn, sql, [watcher_id]) do
      {:ok, [[^job_id]]} -> current_digest(conn, watcher_id)
      {:ok, _gone_or_replaced} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The digest of what the watcher's follow-up runs and what sets it off, as
  stored now, read and handed to the one digest function
  (`Cues.Watchers.follow_up_digest/2`), so a card, an approval and every pass
  compute it from the same reads. `{:error, :no_follow_up}` for a watcher with
  none.
  """
  @spec current_digest(conn(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def current_digest(conn, watcher_id) when is_binary(watcher_id) do
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

  defp one([row], _none), do: {:ok, row}
  defp one([], none), do: {:error, none}
end
