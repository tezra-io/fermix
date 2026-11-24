defmodule FermixCore.Memory.Repo.JobRetriesSql do
  @moduledoc """
  The store's half of a scheduled job's retry (M106 §5.3): one `job_retries`
  row per job whose runs have failed and been retried in a row, holding that
  count and the time of the pending retry, if any. Reached only from
  `FermixCore.Memory.Repo`, on its connection and inside the transaction of
  the write that changes it: a run's settle, a claim, or one of the owner's
  actions. Read by column name, never `SELECT *`.

  A table of its own and not columns on `scheduled_jobs`: every engine at the
  current home format reads `scheduled_jobs` with `SELECT *` into a fixed
  number of fields. A row goes with its job by cascade.

  The decision itself is `Jobs.Retry`'s; times are stored fixed-width
  (`CuesSql.stamp/1`), so a stored time and a scan's `now` compare as text.
  """

  alias FermixCore.Jobs.Retry
  alias FermixCore.Memory.Repo.CuesSql

  @schema_sql """
  CREATE TABLE IF NOT EXISTS job_retries (
    job_id TEXT PRIMARY KEY REFERENCES scheduled_jobs(id) ON DELETE CASCADE,
    attempts INTEGER NOT NULL DEFAULT 0,
    retry_at TEXT
  );
  """

  @type conn :: CuesSql.conn()
  @type retry :: %{job_id: String.t(), attempts: pos_integer(), retry_at: DateTime.t() | nil}

  @doc "The table, for its migration."
  @spec schema_sql() :: String.t()
  def schema_sql, do: @schema_sql

  @doc """
  Decides the retry of `run`, which `job`'s settle just wrote and released,
  and stores it: a `:retry` writes the count and the time, anything else
  removes the row, resetting the count.
  """
  @spec settle(conn(), map(), map(), Retry.settle_by()) ::
          {:ok, Retry.settlement()} | {:error, term()}
  def settle(conn, %{id: job_id} = job, %{completed_at: %DateTime{} = failed_at} = run, settle_by)
      when is_binary(job_id) do
    with {:ok, prior} <- attempts(conn, job_id) do
      settlement =
        Retry.decide(%{
          settle_by: settle_by,
          tools_started?: not is_nil(run.tools_started_at),
          prior_attempts: prior,
          failed_at: failed_at,
          job: job
        })

      with :ok <- store(conn, job_id, settlement), do: {:ok, settlement}
    end
  end

  @doc "The job's retry, or nil when it has none."
  @spec fetch(conn(), String.t()) :: {:ok, retry() | nil} | {:error, term()}
  def fetch(conn, job_id) when is_binary(job_id) do
    sql = "SELECT job_id, attempts, retry_at FROM job_retries WHERE job_id = ?"

    case CuesSql.query_all(conn, sql, [job_id]) do
      {:ok, [[id, attempts, retry_at]]} ->
        {:ok, %{job_id: id, attempts: attempts, retry_at: CuesSql.parse_stamp(retry_at)}}

      {:ok, []} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Ends the pending retry of a job a claim just took, keeping its count."
  @spec clear_retry_at(conn(), String.t()) :: :ok | {:error, term()}
  def clear_retry_at(conn, job_id) when is_binary(job_id),
    do: CuesSql.execute(conn, "UPDATE job_retries SET retry_at = NULL WHERE job_id = ?", [job_id])

  @doc """
  Drops a retry due at or before `cutoff` (the Scheduler's freshness window),
  keeping its count; a later retry is left as it is.
  """
  @spec drop_stale(conn(), String.t(), DateTime.t()) :: :ok | {:error, term()}
  def drop_stale(conn, job_id, %DateTime{} = cutoff) when is_binary(job_id) do
    sql = "UPDATE job_retries SET retry_at = NULL WHERE job_id = ? AND retry_at <= ?"
    CuesSql.execute(conn, sql, [job_id, CuesSql.stamp(cutoff)])
  end

  @doc "Removes the job's retry and its count: the owner acted on the job."
  @spec delete(conn(), String.t()) :: :ok | {:error, term()}
  def delete(conn, job_id) when is_binary(job_id),
    do: CuesSql.execute(conn, "DELETE FROM job_retries WHERE job_id = ?", [job_id])

  defp attempts(conn, job_id) do
    case fetch(conn, job_id) do
      {:ok, %{attempts: attempts}} -> {:ok, attempts}
      {:ok, nil} -> {:ok, 0}
      {:error, reason} -> {:error, reason}
    end
  end

  defp store(conn, job_id, %{disposition: :retry, attempts: attempts, retry_at: retry_at}) do
    sql = """
    INSERT INTO job_retries (job_id, attempts, retry_at) VALUES (?, ?, ?)
    ON CONFLICT(job_id) DO UPDATE SET attempts = excluded.attempts, retry_at = excluded.retry_at
    """

    CuesSql.execute(conn, sql, [job_id, attempts, stamp(retry_at)])
  end

  defp store(conn, job_id, _none_or_exhausted), do: delete(conn, job_id)

  defp stamp(nil), do: nil
  defp stamp(%DateTime{} = at), do: CuesSql.stamp(at)
end
