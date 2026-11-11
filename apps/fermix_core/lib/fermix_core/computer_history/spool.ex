defmodule FermixCore.ComputerHistory.Spool do
  @moduledoc """
  This machine's own store of raw computer history (M97 §8.1, D9):
  `device/history.db` under its home, on every engine that records, a primary
  included, so one pipeline serves a Mac that is its own home and a computer
  whose home is a server. It holds the tables the raw spool had in `memory.db`:
  the events (kept 48 hours), the purge fence, the state row (the cursor of what
  was sent, the pause, the open sitting, the cycle's claim), and what this
  machine last heard from its home (`computer_history_link`). The home's notes
  never live here, and raw events never live anywhere else: a device-role
  engine opens no `memory.db`, and this store is what lets it record at all.

  `device/` is device-local (`Home.DeviceLocal`): no archive, snapshot or move
  carries it, and the sandbox keeps agent commands out of it. The file is mode
  0600 in a 0700 folder. A home that kept its spool in `memory.db` has it moved
  here by memory.db's migration 59 (`Memory.Repo`), which attaches this file.

  One GenServer holds the store's connection, the `Memory.Repo` shape; every
  request runs `Memory.Repo.ComputerHistorySql` on it, so the raw reads and
  writes have one implementation. It is not the only writer: a computer applies
  what its home tells it (`apply_at/3`, from `ComputerHistory.MachineService`)
  on a connection of its own, opened and closed for that one apply. Every write
  of either is one `BEGIN IMMEDIATE` transaction, which SQLite serializes, so
  neither interleaves with the other; a write that waits past the 5 s
  `busy_timeout` fails with an error. Options: `:path` (the file), `:name`
  (nil for none, a test's seam). A caller passes `server:` and may pass
  `timeout:` and `on_timeout: :error` (answered `{:error, :spool_timeout}`).
  """

  use GenServer

  require Logger

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo.ComputerHistorySql, as: Sql
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Timeouts

  @file_name "history.db"
  @schema_version 1

  @doc "The machine store under `home`."
  @spec path(Path.t()) :: Path.t()
  def path(home) when is_binary(home) and home != "",
    do: Path.join([home, "device", @file_name])

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  # -- the raw spool -------------------------------------------------------------

  @doc "Insert raw events (Ingest's one write); see `ComputerHistorySql.insert_events/2`."
  @spec insert_events([map()], keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def insert_events(events, opts \\ []) when is_list(events),
    do: call({:sql, :insert_events, [events]}, opts)

  @doc """
  The 48-hour sweep: delete events stamped before `cutoff_ts`, count those never
  sent to the home, and prune fence intervals that no longer matter.
  """
  @spec sweep_expired(integer(), keyword()) ::
          {:ok, %{deleted: non_neg_integer(), unsent: non_neg_integer()}} | {:error, term()}
  def sweep_expired(cutoff_ts, opts \\ []) when is_integer(cutoff_ts),
    do: call({:sql, :sweep_spool, [cutoff_ts]}, opts)

  @doc "The byte-ceiling backstop; see `ComputerHistorySql.sweep_spool_over_bytes/2`."
  @spec sweep_over_bytes(pos_integer(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def sweep_over_bytes(ceiling, opts \\ []) when is_integer(ceiling) and ceiling > 0,
    do: call({:sql, :sweep_spool_over_bytes, [ceiling]}, opts)

  @doc "How many raw events this machine holds."
  @spec count_events(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count_events(opts \\ []), do: call({:sql, :count_events, []}, opts)

  @doc "The oldest raw event's stamp, or nil."
  @spec oldest_event_ts(keyword()) :: {:ok, integer() | nil} | {:error, term()}
  def oldest_event_ts(opts \\ []), do: call({:sql, :oldest_event_ts, []}, opts)

  @doc "Up to `limit` events past the id `after_id`, oldest first (the cursor's read)."
  @spec events_after(non_neg_integer(), pos_integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def events_after(after_id, limit, opts \\ [])
      when is_integer(after_id) and after_id >= 0 and is_integer(limit) and limit > 0,
      do: call({:sql, :events_after_id, [after_id, limit]}, opts)

  @doc "How many events are not yet sent, and the oldest one's stamp."
  @spec unsent_stats(keyword()) ::
          {:ok, {non_neg_integer(), integer() | nil}} | {:error, term()}
  def unsent_stats(opts \\ []), do: call({:sql, :unsummarized_stats, []}, opts)

  @doc "Per-app coverage gaps since `since_ts`; see `ComputerHistorySql.coverage_gaps/2`."
  @spec coverage_gaps(integer(), keyword()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def coverage_gaps(since_ts, opts \\ []) when is_integer(since_ts),
    do: call({:sql, :coverage_gaps, [since_ts]}, opts)

  @doc "The text of the newest `limit` events that carry any (a local summary's guard)."
  @spec recent_texts(pos_integer(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def recent_texts(limit, opts \\ []) when is_integer(limit) and limit > 0,
    do: call({:sql, :recent_event_texts, [limit]}, opts)

  @doc "Delete the events stamped in `[from_ts, to_ts]` and fence later ones."
  @spec fence(integer(), integer(), integer(), keyword()) ::
          {:ok, %{events: non_neg_integer()}} | {:error, term()}
  def fence(from_ts, to_ts, issued_at, opts \\ [])
      when is_integer(from_ts) and is_integer(to_ts) and from_ts <= to_ts and
             is_integer(issued_at),
      do: call({:sql, :fence_window, [from_ts, to_ts, issued_at]}, opts)

  # -- the state row ---------------------------------------------------------------

  @doc "The state row (cursor, pause, open sitting, claim), made when absent."
  @spec state(keyword()) :: {:ok, map()} | {:error, term()}
  def state(opts \\ []), do: call({:sql, :ensure_state, []}, opts)

  @doc "Set or clear (nil) the capture pause, an ISO 8601 horizon."
  @spec set_pause_until(String.t() | nil, keyword()) :: :ok | {:error, term()}
  def set_pause_until(until, opts \\ []) when is_binary(until) or is_nil(until),
    do: call({:sql, :set_pause_until, [until]}, opts)

  @doc "Record why sending or summarizing is held, or clear it (nil)."
  @spec set_paused_reason(String.t() | nil, keyword()) :: :ok | {:error, term()}
  def set_paused_reason(reason, opts \\ []) when is_binary(reason) or is_nil(reason),
    do: call({:sql, :set_paused_reason, [reason]}, opts)

  @doc "Record the first stamp of the sitting still open, or clear it (nil)."
  @spec set_open_since(integer() | nil, keyword()) :: :ok | {:error, term()}
  def set_open_since(ts, opts \\ []) when is_integer(ts) or is_nil(ts),
    do: call({:sql, :set_session_open_since, [ts]}, opts)

  @doc "Claim a cycle (`idle -> running`); a claim older than `stale_ms` is taken over."
  @spec claim(DateTime.t(), non_neg_integer(), keyword()) ::
          {:ok, map()} | {:error, :concurrent_run | term()}
  def claim(%DateTime{} = now, stale_ms, opts \\ []) when is_integer(stale_ms),
    do: call({:sql, :claim_cycle, [now, stale_ms]}, opts)

  @doc "Release a claimed cycle."
  @spec release(DateTime.t(), keyword()) :: :ok | {:error, term()}
  def release(%DateTime{} = now, opts \\ []), do: call({:sql, :release_claim, [now]}, opts)

  @doc "Advance the cursor past `last_id`, recording `status` (nil keeps the last one)."
  @spec advance(non_neg_integer(), DateTime.t(), String.t() | nil, keyword()) ::
          :ok | {:error, term()}
  def advance(last_id, %DateTime{} = now, status, opts \\ [])
      when is_integer(last_id) and last_id >= 0,
      do: call({:sql, :advance_cursor, [last_id, now, status]}, opts)

  # -- what the home said -------------------------------------------------------------

  @doc "What this machine last heard from its home; see `ComputerHistorySql.link/1`."
  @spec link(keyword()) :: {:ok, map()} | {:error, term()}
  def link(opts \\ []), do: call({:sql, :link, []}, opts)

  @doc "Record the home's answer to the latest sitting."
  @spec record_answer(String.t(), String.t() | nil, integer(), keyword()) ::
          :ok | {:error, term()}
  def record_answer(answer, reason, at_ts, opts \\ []) when is_binary(answer),
    do: call({:sql, :record_answer, [answer, reason, at_ts]}, opts)

  @doc """
  Apply the home's purge and pause intervals (M97 §8.5), oldest first: each
  deletes the raw events stamped inside it and fences later ones, a pause that
  has not ended also pauses capture here until it does, and the mark of the
  highest one applied is recorded last, so an interrupted apply is done again
  whole. `now` is the wall clock.
  """
  @spec apply_intervals([map()], DateTime.t(), keyword()) :: :ok | {:error, term()}
  def apply_intervals(intervals, %DateTime{} = now, opts \\ []) when is_list(intervals) do
    Enum.reduce_while(intervals, :ok, fn interval, :ok ->
      case apply_interval(interval, now, opts) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> mark_applied(intervals, opts)
  end

  defp apply_interval(%{from_ts: from_ts, to_ts: to_ts, kind: kind} = interval, now, opts) do
    with {:ok, _counts} <- fence(from_ts, to_ts, Map.get(interval, :issued_at, from_ts), opts) do
      pause_from(kind, to_ts, now, opts)
    end
  end

  # A pause already set here that ends later is kept: one write that only ever
  # raises the horizon, so a pause applied from a refusal or a delivery that
  # races one from chat can never lower it.
  defp pause_from("pause", until_ts, now, opts) do
    if until_ts > DateTime.to_unix(now, :millisecond) do
      until = until_ts |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
      call({:sql, :raise_pause_until, [until]}, opts)
    else
      :ok
    end
  end

  defp pause_from("purge", _to_ts, _now, _opts), do: :ok

  defp mark_applied(:ok, [], _opts), do: :ok

  defp mark_applied(:ok, intervals, opts),
    do: call({:sql, :set_home_mark, [intervals |> Enum.map(& &1.id) |> Enum.max()]}, opts)

  defp mark_applied({:error, _reason} = error, _intervals, _opts), do: error

  @doc """
  Apply the home's intervals (`apply_intervals/3`) to the store at `file`, on a
  connection of its own, opened and closed here: how a computer applies what
  its home sends it (`ComputerHistory.MachineService`), from the invocation's
  home alone. Answers the store's mark once they are applied: the highest
  interval this machine has applied, every one below it included. A machine
  with no store has no raw event to fence and applied nothing: nothing is
  created and the mark is 0, so a store it opens later starts from the first
  interval.
  """
  @spec apply_at(Path.t(), [map()], DateTime.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def apply_at(file, intervals, %DateTime{} = now) when is_binary(file) and is_list(intervals) do
    if File.exists?(file), do: apply_open(file, intervals, now), else: {:ok, 0}
  end

  defp apply_open(file, intervals, now) do
    with {:ok, conn} <- open(file) do
      result =
        with :ok <- apply_intervals(intervals, now, conn: conn),
             {:ok, %{home_mark: mark}} <- link(conn: conn),
             do: {:ok, mark}

      case Sqlite3.close(conn) do
        :ok -> result
        {:error, reason} -> {:error, {:spool_close, reason}}
      end
    end
  end

  # -- the process -----------------------------------------------------------------

  # `conn:` runs the request on a connection the caller opened (`apply_at/3`).
  defp call({:sql, function, args}, conn: conn), do: apply(Sql, function, [conn | args])

  defp call(request, opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    timeout = Keyword.get(opts, :timeout, Timeouts.repo_call())

    case Keyword.get(opts, :on_timeout, :exit) do
      :exit -> GenServer.call(server, request, timeout)
      :error -> call_or_error(server, request, timeout)
    end
  end

  defp call_or_error(server, request, timeout) do
    GenServer.call(server, request, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :spool_timeout}
  end

  @impl true
  def init(opts) do
    file = Keyword.get_lazy(opts, :path, fn -> path(ConfigStore.fermix_home()) end)

    case open(file) do
      {:ok, conn} ->
        {:ok, %{conn: conn, path: file}}

      {:error, reason} ->
        Logger.error(
          "computer history: the machine store #{file} did not open: #{inspect(reason)}"
        )

        {:stop, {:spool, reason}}
    end
  end

  @impl true
  def handle_call({:sql, function, args}, _from, state),
    do: {:reply, apply(Sql, function, [state.conn | args]), state}

  @impl true
  def terminate(_reason, %{conn: conn}) do
    _ = Sqlite3.close(conn)
    :ok
  end

  @doc """
  Opens (creating) the store at `file` with its schema, mode 0600 in a 0700
  folder. Public for the migration's tests, which open a store the way a boot does.
  """
  @spec open(Path.t()) :: {:ok, term()} | {:error, term()}
  def open(file) when is_binary(file) do
    dir = Path.dirname(file)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         {:ok, conn} <- Sqlite3.open(file, mode: :readwrite) do
      close_unless_ready(conn, ready(conn, file))
    end
  end

  defp ready(conn, file) do
    with :ok <- Sqlite3.execute(conn, "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;"),
         :ok <- migrate(conn) do
      File.chmod(file, 0o600)
    end
  end

  defp close_unless_ready(conn, :ok), do: {:ok, conn}

  defp close_unless_ready(conn, {:error, reason}) do
    _ = Sqlite3.close(conn)
    {:error, reason}
  end

  # One version so far, its statements each safe to run again, recorded in the
  # same transaction.
  defp migrate(conn) do
    Sqlite3.execute(
      conn,
      """
      CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY);
      BEGIN;
      #{Sql.spool_schema_sql()}
      INSERT OR IGNORE INTO schema_migrations(version) VALUES (#{@schema_version});
      COMMIT;
      """
    )
  end
end
