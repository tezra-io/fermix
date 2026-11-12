defmodule FermixCore.Harness.MachineStore do
  @moduledoc """
  This machine's own coding store (M98 D3): `device/coding.db` under its home,
  made only where a coding agent can run (the harness on and a vendor CLI
  found when the engine started). Today it holds one table, the sign-in marks
  (`Harness.SignIn`): an agent whose last run here failed to sign in.

  `device/` is device-local (`Home.DeviceLocal`): no archive, snapshot or move
  carries it, and the sandbox keeps file tools and commands out of it. The
  file is mode 0600 in a 0700 folder, in WAL mode with a 5 s `busy_timeout`,
  and each schema version is recorded in the transaction that applies it.

  Reserved, nothing built: v2 `coding_runs`, the machine half of the run
  ledger now in `memory.db` (`harness_runs`); later `coding_sessions`, the
  machine half of coding sessions, `PRIMARY KEY (vendor, vendor_session_id)`
  with `cwd`, `worktree_root`, `lock_roots_json` and `status`, whose active
  rows join the per-repository lock scan in the same admission transaction,
  because they live in this file.

  One GenServer holds the store's connection, first under
  `Harness.Supervisor` (the Manager reads it at boot), the
  `ComputerHistory.Spool` shape. It never raises on its input or its I/O
  (AGENTS.md "Cascade roots"): a store that does not open stays up, logs why
  once and answers every request `{:error, {:store_unavailable, reason}}`.
  Where no agent can run there is no file (`status/1` is `:absent`): a read
  finds no mark, a delete has nothing to delete, and a mark answers
  `{:error, :no_coding_agent}`.

  It is not the only connection: `marks_at/1` reads on a read-only connection
  of its own (doctor, a page, an engine whose store process is not running),
  and `delete_marks_at/2` clears on a read-write one of its own, opened and
  closed for that one write; SQLite serializes it with the process's writes.
  Options: `:path` (the file), `:name` (nil for none, a test's seam),
  `:open?` (whether an agent can run here). A caller passes `server:` and may
  pass `timeout:`.
  """

  use GenServer

  require Logger

  alias Exqlite.Sqlite3
  alias FermixCore.Harness.Config, as: HarnessConfig
  alias FermixCore.Harness.MachineStore.Sql
  alias FermixCore.Harness.Vendors
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Timeouts

  @file_name "coding.db"
  @vendors ~w(codex claude)

  @type mark :: %{
          vendor: String.t(),
          marked_at: String.t(),
          run_id: String.t(),
          sign_in_file: String.t() | nil,
          file_stat: map() | nil
        }
  @type status :: :absent | :open | {:unavailable, Path.t(), term()}

  @doc "The coding store under `home`."
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

  @doc """
  Whether this machine's store is in use: `:open`, `:absent` (no agent can
  run here, so there is no file), or `{:unavailable, file, reason}` when it
  did not open.
  """
  @spec status(keyword()) :: status()
  def status(opts \\ []) when is_list(opts), do: call(:status, opts)

  @doc "Every sign-in mark, keyed by agent (`codex`, `claude`)."
  @spec marks(keyword()) :: {:ok, %{String.t() => mark()}} | {:error, term()}
  def marks(opts \\ []) when is_list(opts), do: call({:sql, :marks, []}, opts)

  @doc """
  Marks `vendor` signed out: `mark` carries `marked_at`, the `run_id` that
  failed, and the agent's `sign_in_file` with its `file_stat` (`size`,
  `mtime`, `inode`), each nil where the agent keeps no file.
  """
  @spec put_mark(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def put_mark(vendor, %{marked_at: %DateTime{}, run_id: run_id} = mark, opts \\ [])
      when vendor in @vendors and is_binary(run_id) and is_list(opts) do
    file = Map.get(mark, :sign_in_file)
    stat = Map.get(mark, :file_stat)
    true = (is_binary(file) or is_nil(file)) and stat_shape?(stat)
    call({:sql, :put_mark, [vendor, mark]}, opts)
  end

  @doc "Deletes `vendor`'s mark."
  @spec delete_mark(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_mark(vendor, opts \\ []) when vendor in @vendors and is_list(opts),
    do: call({:sql, :delete_marks, [[vendor]]}, opts)

  @doc """
  The marks in the store at `file`, read on a read-only connection of its
  own, opened and closed here, for a reader with no store process (doctor, a
  page, an engine whose rail does not run). No file is no mark.
  """
  @spec marks_at(Path.t()) :: {:ok, %{String.t() => mark()}} | {:error, term()}
  def marks_at(file) when is_binary(file) do
    case File.stat(file) do
      {:ok, _stat} -> on_own_connection(file, :readonly, &Sql.marks/1)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes the marks of `vendors` in the store at `file`, on a connection of
  its own, opened and closed here: the owner's word that they signed in again
  (`coding_agents.check`), on any machine, its rail running or not. No file
  is nothing to clear, and none is made.
  """
  @spec delete_marks_at(Path.t(), [String.t()]) :: :ok | {:error, term()}
  def delete_marks_at(file, vendors) when is_binary(file) and is_list(vendors) do
    true = Enum.all?(vendors, &(&1 in @vendors))

    case File.stat(file) do
      {:ok, _stat} -> on_own_connection(file, :readwrite, &Sql.delete_marks(&1, vendors))
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # --- the process ----------------------------------------------------------------

  @impl true
  def init(opts) do
    file = Keyword.get_lazy(opts, :path, fn -> path(ConfigStore.fermix_home()) end)

    if Keyword.get_lazy(opts, :open?, &agent_can_run?/0),
      do: {:ok, opened(file)},
      else: {:ok, %{conn: nil, path: file, status: :absent}}
  end

  # A store that does not open (a full disk, a damaged file, a folder that
  # cannot be made) never stops the engine or the children after this one:
  # the process stays up holding the reason, logged once here.
  defp opened(file) do
    case open(file) do
      {:ok, conn} ->
        %{conn: conn, path: file, status: :open}

      {:error, reason} ->
        Logger.error(
          "coding agents: this machine's store #{file} did not open: #{inspect(reason)}; " <>
            "sign-in marks are not kept until Fermix starts again"
        )

        %{conn: nil, path: file, status: {:unavailable, file, reason}}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call({:sql, :marks, []}, _from, %{status: :absent} = state),
    do: {:reply, {:ok, %{}}, state}

  def handle_call({:sql, :delete_marks, _vendors}, _from, %{status: :absent} = state),
    do: {:reply, :ok, state}

  def handle_call({:sql, _function, _args}, _from, %{status: :absent} = state),
    do: {:reply, {:error, :no_coding_agent}, state}

  def handle_call(
        {:sql, _function, _args},
        _from,
        %{status: {:unavailable, _file, reason}} = state
      ),
      do: {:reply, {:error, {:store_unavailable, reason}}, state}

  def handle_call({:sql, function, args}, _from, state),
    do: {:reply, apply(Sql, function, [state.conn | args]), state}

  @impl true
  def terminate(_reason, %{conn: nil}), do: :ok

  def terminate(_reason, %{conn: conn, path: file}) do
    case Sqlite3.close(conn) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("coding agents: closing #{file}: #{inspect(reason)}")
    end
  end

  # --- opening --------------------------------------------------------------------

  @doc """
  Opens (creating) the store at `file` with its schema, mode 0600 in a 0700
  folder. Public for tests that build a home with a store in it.
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
    _closed = Sqlite3.close(conn)
    {:error, reason}
  end

  # Each statement is safe to run again, and the version is recorded in the
  # transaction that applies it.
  defp migrate(conn) do
    with :ok <-
           Sqlite3.execute(
             conn,
             "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY); BEGIN;"
           ) do
      conn |> upgrade() |> settle_migration(conn)
    end
  end

  defp upgrade(conn) do
    with :ok <- Sql.create_schema(conn), do: Sql.record_version(conn)
  end

  defp settle_migration(:ok, conn), do: Sqlite3.execute(conn, "COMMIT;")

  defp settle_migration({:error, reason}, conn) do
    _rolled_back = Sqlite3.execute(conn, "ROLLBACK;")
    {:error, reason}
  end

  defp on_own_connection(file, mode, run) do
    with {:ok, conn} <- Sqlite3.open(file, mode: mode) do
      result = with :ok <- busy_timeout(conn), do: run.(conn)

      case Sqlite3.close(conn) do
        :ok -> result
        {:error, reason} -> {:error, {:store_close, reason}}
      end
    end
  end

  defp busy_timeout(conn), do: Sqlite3.execute(conn, "PRAGMA busy_timeout=5000;")

  # --- helpers --------------------------------------------------------------------

  # The harness on and a vendor CLI found when this engine started: the same
  # detection the run tools' advertisement reads (`Vendors.detected?/1`).
  defp agent_can_run? do
    HarnessConfig.enabled?() and Enum.any?(Vendors.vendors(), &Vendors.detected?/1)
  end

  defp stat_shape?(nil), do: true

  defp stat_shape?(%{} = stat),
    do: Enum.all?(stat, fn {key, value} -> is_binary(key) and is_integer(value) end)

  defp stat_shape?(_other), do: false

  defp call(request, opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, request, Keyword.get(opts, :timeout, Timeouts.repo_call()))
  end
end
