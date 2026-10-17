defmodule FermixCore.Memory.Repo.ConnectSql do
  @moduledoc false
  # Private SQL for `FermixCore.Memory.Repo`'s X channel assignments
  # (MILESTONE_63_SHARED_X_HANDLE, `priv/connect/PROTOCOL.md` §6): one row per
  # assignment Fermix Connect handed this installation, from the receipt to
  # Connect's answer to its result. The `VoiceCallsSql` split: every statement
  # takes the caller's `conn` and runs only from a Repo `handle_call`, so the
  # single writer is unchanged.
  #
  # Every transition is a compare-and-set on `status` (and on `attempt` where a
  # later attempt must not settle an earlier one's row): a statement that finds
  # the row in another state changes nothing and answers `:not_found`, so the
  # first writer of an ending wins and every later one learns it lost.
  #
  # `normalize_*` and `decode/1` run in the *caller* process, before and after
  # the GenServer call: a bad value fails at the boundary with a clear error,
  # and a stored row that does not decode is the caller's error, never a crash
  # of the single writer.

  alias Exqlite.Sqlite3

  @statuses %{
    "accepted" => :accepted,
    "running" => :running,
    "completed" => :completed,
    "failed" => :failed,
    "cancelled" => :cancelled,
    "expired" => :expired
  }

  @decisions %{
    "public_reply" => :public_reply,
    "private_only" => :private_only,
    "no_reply" => :no_reply,
    "failed" => :failed
  }

  # The statuses a failure may move a row out of: an assignment Connect would
  # not start, a turn that ended without a result, and a result Connect
  # refused.
  @failable ~w(accepted running completed)

  @id_max 256
  @epoch_max 128
  @reason_max 512
  # The whole JWS is at most `max_assignment_bytes` (32 KiB today); past twice
  # that it is a runaway, refused rather than stored.
  @jws_max 65_536
  # A staged reply far past anything a result frame can carry is a runaway.
  @reply_max 1_048_576
  @result_json_max 65_536
  @recoverable_limit 100

  @columns [
    :assignment_id,
    :interaction_id,
    :tenant_id,
    :instance_id,
    :requester_x_user_id,
    :conversation_id,
    :request_sha256,
    :jws,
    :status,
    :attempt,
    :runner_epoch,
    :deadline_at,
    :expires_at,
    :receipt_sent_at,
    :reply_text,
    :decision,
    :result_sha256,
    :result_json,
    :result_acked_at,
    :failure_reason,
    :claimed_at,
    :updated_at
  ]

  @select Enum.map_join(@columns, ", ", &Atom.to_string/1)
  @stamp_columns [
    :deadline_at,
    :expires_at,
    :receipt_sent_at,
    :result_acked_at,
    :claimed_at,
    :updated_at
  ]

  @schema_sql """
  CREATE TABLE IF NOT EXISTS x_assignments (
    assignment_id TEXT PRIMARY KEY,
    interaction_id TEXT NOT NULL,
    tenant_id TEXT NOT NULL,
    instance_id TEXT NOT NULL,
    requester_x_user_id TEXT NOT NULL,
    conversation_id TEXT NOT NULL,
    request_sha256 TEXT NOT NULL,
    jws TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN
      ('accepted','running','completed','failed','cancelled','expired')),
    attempt INTEGER CHECK (attempt IS NULL OR attempt > 0),
    runner_epoch TEXT,
    deadline_at TEXT,
    expires_at TEXT NOT NULL,
    receipt_sent_at TEXT,
    reply_text TEXT,
    decision TEXT CHECK (decision IS NULL OR decision IN
      ('public_reply','private_only','no_reply','failed')),
    result_sha256 TEXT,
    result_json TEXT,
    result_acked_at TEXT,
    failure_reason TEXT,
    claimed_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );

  CREATE INDEX IF NOT EXISTS idx_x_assignments_status ON x_assignments(status, claimed_at);
  """

  @type status :: :accepted | :running | :completed | :failed | :cancelled | :expired
  @type decision :: :public_reply | :private_only | :no_reply | :failed

  @spec schema_sql() :: String.t()
  def schema_sql, do: @schema_sql

  @spec recoverable_limit() :: pos_integer()
  def recoverable_limit, do: @recoverable_limit

  # --- normalization (caller process) --------------------------------------

  @doc "Validates a verified assignment's claim, in the order the INSERT binds it."
  @spec normalize_claim(map()) :: {:ok, list()} | {:error, term()}
  def normalize_claim(attrs) when is_map(attrs) do
    with {:ok, ids} <- normalize_ids(attrs),
         {:ok, sha} <- normalize_sha(:request_sha256, Map.get(attrs, :request_sha256)),
         {:ok, jws} <- normalize_text(:jws, Map.get(attrs, :jws), @jws_max),
         {:ok, expires_at} <- normalize_stamp(:expires_at, Map.get(attrs, :expires_at)),
         {:ok, claimed_at} <- normalize_stamp(:claimed_at, Map.get(attrs, :claimed_at)) do
      {:ok, ids ++ [sha, jws, expires_at, claimed_at, claimed_at]}
    end
  end

  @doc "Validates an execution-start grant, in the order the UPDATE binds it."
  @spec normalize_start(map()) :: {:ok, list()} | {:error, term()}
  def normalize_start(grant) when is_map(grant) do
    with {:ok, attempt} <- normalize_attempt(Map.get(grant, :attempt)),
         {:ok, epoch} <- normalize_text(:runner_epoch, Map.get(grant, :runner_epoch), @epoch_max),
         {:ok, deadline_at} <- normalize_stamp(:deadline_at, Map.get(grant, :deadline_at)),
         {:ok, now} <- normalize_stamp(:now, Map.get(grant, :now)) do
      {:ok, [attempt, epoch, deadline_at, now]}
    end
  end

  @doc "Validates a staged reply text."
  @spec normalize_reply(term()) :: {:ok, String.t()} | {:error, term()}
  def normalize_reply(text) when is_binary(text) do
    if byte_size(text) > @reply_max,
      do: {:error, {:invalid, :reply_text, :too_long}},
      else: {:ok, text}
  end

  def normalize_reply(_text), do: {:error, {:invalid, :reply_text, :not_a_string}}

  @doc """
  Validates an attempt's result: `%{decision, result_sha256, result_json}`, the
  JSON being the frame as it is sent and resent. `nil` is no result at all (an
  assignment that never ran).
  """
  @spec normalize_result(map() | nil) :: {:ok, list()} | {:error, term()}
  def normalize_result(nil), do: {:ok, [nil, nil, nil]}

  def normalize_result(result) when is_map(result) do
    with {:ok, decision} <- normalize_decision(Map.get(result, :decision)),
         {:ok, sha} <- normalize_sha(:result_sha256, Map.get(result, :result_sha256)),
         {:ok, json} <-
           normalize_text(:result_json, Map.get(result, :result_json), @result_json_max) do
      {:ok, [decision, sha, json]}
    end
  end

  def normalize_result(_result), do: {:error, {:invalid, :result, :not_a_map}}

  @doc "Validates the status a failure moves a row out of."
  @spec normalize_failable(term()) :: {:ok, String.t()} | {:error, term()}
  def normalize_failable(status) when is_atom(status) do
    text = Atom.to_string(status)
    if text in @failable, do: {:ok, text}, else: {:error, {:invalid, :from_status, status}}
  end

  def normalize_failable(status), do: {:error, {:invalid, :from_status, status}}

  @doc "Validates a failure reason, stored as text."
  @spec normalize_reason(term()) :: {:ok, String.t()} | {:error, term()}
  def normalize_reason(reason) when is_atom(reason) and not is_nil(reason),
    do: normalize_reason(Atom.to_string(reason))

  def normalize_reason(reason), do: normalize_text(:failure_reason, reason, @reason_max)

  @doc "Validates an assignment id."
  @spec normalize_id(term()) :: {:ok, String.t()} | {:error, term()}
  def normalize_id(id), do: normalize_text(:assignment_id, id, @id_max)

  @doc "Validates an attempt number."
  @spec normalize_attempt(term()) :: {:ok, pos_integer()} | {:error, term()}
  def normalize_attempt(attempt) when is_integer(attempt) and attempt > 0, do: {:ok, attempt}
  def normalize_attempt(_attempt), do: {:error, {:invalid, :attempt, :not_positive}}

  @doc "The fixed-width UTC form of an instant, so stamps compare as text."
  @spec normalize_stamp(atom(), term()) :: {:ok, String.t()} | {:error, term()}
  def normalize_stamp(_key, %DateTime{} = value) do
    {:ok,
     value
     |> DateTime.shift_zone!("Etc/UTC")
     |> pad_microseconds()
     |> DateTime.to_iso8601()}
  end

  def normalize_stamp(key, _value), do: {:error, {:invalid, key, :not_a_datetime}}

  @doc """
  A stored row as callers read it: `status` and `decision` as atoms and every
  stamp a `DateTime`.
  """
  @spec decode(map()) :: {:ok, map()} | {:error, term()}
  def decode(%{assignment_id: id, status: status, decision: decision} = row) do
    with {:ok, status} <- known(@statuses, status, id, :status),
         {:ok, decision} <- optional_known(@decisions, decision, id),
         {:ok, row} <- decode_stamps(row, id) do
      {:ok, %{row | status: status, decision: decision}}
    end
  end

  # --- statements (single-writer process) ----------------------------------

  @doc """
  Claims an assignment as `accepted`. A second claim of the same id changes
  nothing and answers the row as it stands.
  """
  @spec claim(term(), list()) :: {:ok, {:claimed | :duplicate, map()}} | {:error, term()}
  def claim(conn, [assignment_id | _rest] = params) do
    inserted =
      returning(
        conn,
        """
        INSERT INTO x_assignments (assignment_id, interaction_id, tenant_id, instance_id,
          requester_x_user_id, conversation_id, request_sha256, jws, status, expires_at,
          claimed_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'accepted', ?, ?, ?)
        ON CONFLICT(assignment_id) DO NOTHING
        RETURNING #{@select}
        """,
        params
      )

    case inserted do
      {:ok, row} -> {:ok, {:claimed, row}}
      {:error, :not_found} -> existing(conn, assignment_id)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec fetch(term(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch(conn, assignment_id) when is_binary(assignment_id) do
    returning(
      conn,
      "SELECT #{@select} FROM x_assignments WHERE assignment_id = ? LIMIT 1",
      [assignment_id]
    )
  end

  @doc "Records when the receipt for a stored assignment first went out."
  @spec mark_receipt_sent(term(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def mark_receipt_sent(conn, assignment_id, now) do
    returning(
      conn,
      """
      UPDATE x_assignments SET receipt_sent_at = COALESCE(receipt_sent_at, ?), updated_at = ?
      WHERE assignment_id = ?
      RETURNING #{@select}
      """,
      [now, now, assignment_id]
    )
  end

  @doc "`accepted` → `running` under a start grant, its attempt and this boot's epoch."
  @spec start(term(), String.t(), list()) :: {:ok, map()} | {:error, term()}
  def start(conn, assignment_id, [attempt, epoch, deadline_at, now]) do
    returning(
      conn,
      """
      UPDATE x_assignments
      SET status = 'running', attempt = ?, runner_epoch = ?, deadline_at = ?, updated_at = ?
      WHERE assignment_id = ? AND status = 'accepted'
      RETURNING #{@select}
      """,
      [attempt, epoch, deadline_at, now, assignment_id]
    )
  end

  @doc "Stages the running turn's reply text; the last text staged wins."
  @spec stage_reply(term(), String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def stage_reply(conn, assignment_id, text, now) do
    returning(
      conn,
      """
      UPDATE x_assignments SET reply_text = ?, updated_at = ?
      WHERE assignment_id = ? AND status = 'running'
      RETURNING #{@select}
      """,
      [text, now, assignment_id]
    )
  end

  @doc "`running` → `completed` with the attempt's result, for that attempt only."
  @spec complete(term(), String.t(), pos_integer(), list(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def complete(conn, assignment_id, attempt, [decision, sha, json], now) do
    returning(
      conn,
      """
      UPDATE x_assignments
      SET status = 'completed', decision = ?, result_sha256 = ?, result_json = ?, updated_at = ?
      WHERE assignment_id = ? AND status = 'running' AND attempt = ?
      RETURNING #{@select}
      """,
      [decision, sha, json, now, assignment_id, attempt]
    )
  end

  @doc """
  `from` → `failed`, with the reason and, for an attempt that ran, the
  `failed` result it owes Connect.
  """
  @spec fail(term(), String.t(), String.t(), String.t(), list(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def fail(conn, assignment_id, from, reason, [decision, sha, json], now) do
    returning(
      conn,
      """
      UPDATE x_assignments
      SET status = 'failed', failure_reason = ?,
          decision = COALESCE(?, decision), result_sha256 = COALESCE(?, result_sha256),
          result_json = COALESCE(?, result_json), updated_at = ?
      WHERE assignment_id = ? AND status = ?
      RETURNING #{@select}
      """,
      [reason, decision, sha, json, now, assignment_id, from]
    )
  end

  @doc "An assignment not yet settled → `cancelled`."
  @spec cancel(term(), String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def cancel(conn, assignment_id, reason, now) do
    returning(
      conn,
      """
      UPDATE x_assignments SET status = 'cancelled', failure_reason = ?, updated_at = ?
      WHERE assignment_id = ? AND status IN ('accepted', 'running')
      RETURNING #{@select}
      """,
      [reason, now, assignment_id]
    )
  end

  @doc "Every `accepted` row whose `expires_at` has passed → `expired`; answers their ids."
  @spec expire(term(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def expire(conn, now) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             UPDATE x_assignments SET status = 'expired', updated_at = ?
             WHERE status = 'accepted' AND expires_at <= ?
             RETURNING assignment_id
             """,
             [now, now]
           ) do
      {:ok, Enum.map(rows, fn [id] -> id end)}
    end
  end

  @doc "Connect acknowledged the attempt's result: it is Connect's responsibility now."
  @spec ack_result(term(), String.t(), pos_integer(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def ack_result(conn, assignment_id, attempt, now) do
    returning(
      conn,
      """
      UPDATE x_assignments SET result_acked_at = ?, updated_at = ?
      WHERE assignment_id = ? AND attempt = ? AND result_json IS NOT NULL
        AND result_acked_at IS NULL
      RETURNING #{@select}
      """,
      [now, now, assignment_id, attempt]
    )
  end

  @doc """
  Connect refused the attempt's result, which ends its resending. A `conflict`
  (Connect holds a different result for the attempt) leaves the row's own
  record as it is; any other refusal fails the attempt.
  """
  @spec reject_result(term(), String.t(), pos_integer(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def reject_result(conn, assignment_id, attempt, reason, now) do
    returning(
      conn,
      """
      UPDATE x_assignments
      SET result_acked_at = ?, failure_reason = ?, updated_at = ?,
          status = CASE WHEN ? = 'result_rejected:conflict' THEN status ELSE 'failed' END
      WHERE assignment_id = ? AND attempt = ? AND result_json IS NOT NULL
        AND result_acked_at IS NULL
      RETURNING #{@select}
      """,
      [now, reason, now, reason, assignment_id, attempt]
    )
  end

  @doc """
  The rows a boot or a reconnection picks up, oldest claim first, at most
  #{@recoverable_limit}: assignments waiting for a start, attempts that were
  running, and results Connect has not answered.
  """
  @spec recoverable(term()) :: {:ok, [map()]} | {:error, term()}
  def recoverable(conn) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT #{@select} FROM x_assignments
             WHERE status IN ('accepted', 'running')
                OR (result_json IS NOT NULL AND result_acked_at IS NULL)
             ORDER BY claimed_at ASC, assignment_id ASC
             LIMIT ?
             """,
             [@recoverable_limit]
           ) do
      {:ok, Enum.map(rows, &row/1)}
    end
  end

  # --- normalization helpers -----------------------------------------------

  defp normalize_ids(attrs) do
    keys = [
      :assignment_id,
      :interaction_id,
      :tenant_id,
      :instance_id,
      :requester_x_user_id,
      :conversation_id
    ]

    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      case normalize_text(key, Map.get(attrs, key), @id_max) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_text(key, text, max) when is_binary(text) do
    cond do
      String.trim(text) == "" -> {:error, {:invalid, key, :blank}}
      byte_size(text) > max -> {:error, {:invalid, key, :too_long}}
      true -> {:ok, text}
    end
  end

  defp normalize_text(key, _text, _max), do: {:error, {:invalid, key, :not_a_string}}

  defp normalize_sha(key, sha) when is_binary(sha) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, sha),
      do: {:ok, sha},
      else: {:error, {:invalid, key, :not_a_sha256}}
  end

  defp normalize_sha(key, _sha), do: {:error, {:invalid, key, :not_a_sha256}}

  defp normalize_decision(decision) when is_atom(decision) do
    text = Atom.to_string(decision)

    if Map.has_key?(@decisions, text),
      do: {:ok, text},
      else: {:error, {:invalid, :decision, decision}}
  end

  defp normalize_decision(decision), do: {:error, {:invalid, :decision, decision}}

  defp pad_microseconds(%DateTime{microsecond: {value, _precision}} = at) do
    %{at | microsecond: {value, 6}}
  end

  # --- decoding helpers ----------------------------------------------------

  defp known(vocabulary, value, id, key) do
    case Map.fetch(vocabulary, value) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:invalid_x_assignment, id, key, value}}
    end
  end

  defp optional_known(_vocabulary, nil, _id), do: {:ok, nil}
  defp optional_known(vocabulary, value, id), do: known(vocabulary, value, id, :decision)

  defp decode_stamps(row, id) do
    Enum.reduce_while(@stamp_columns, {:ok, row}, fn key, {:ok, acc} ->
      case decode_stamp(Map.fetch!(acc, key)) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        :error -> {:halt, {:error, {:invalid_x_assignment, id, key, Map.fetch!(acc, key)}}}
      end
    end)
  end

  defp decode_stamp(nil), do: {:ok, nil}

  defp decode_stamp(stamp) when is_binary(stamp) do
    case DateTime.from_iso8601(stamp) do
      {:ok, at, 0} -> {:ok, at}
      _invalid -> :error
    end
  end

  defp decode_stamp(_stamp), do: :error

  # --- rows + sqlite plumbing ----------------------------------------------

  defp existing(conn, assignment_id) do
    case fetch(conn, assignment_id) do
      {:ok, row} -> {:ok, {:duplicate, row}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp returning(conn, sql, params) do
    case query_all(conn, sql, params) do
      {:ok, [values | _rest]} -> {:ok, row(values)}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp row(values), do: @columns |> Enum.zip(values) |> Map.new()

  defp query_all(conn, sql, params) do
    case Sqlite3.prepare(conn, sql) do
      {:ok, stmt} -> release_statement(conn, stmt, bind_and_fetch(conn, stmt, params))
      {:error, reason} -> {:error, reason}
    end
  end

  defp bind_and_fetch(conn, stmt, params) do
    with :ok <- Sqlite3.bind(stmt, params), do: Sqlite3.fetch_all(conn, stmt)
  end

  defp release_statement(conn, stmt, result) do
    case Sqlite3.release(conn, stmt) do
      :ok -> result
      {:error, reason} -> {:error, reason}
    end
  end
end
