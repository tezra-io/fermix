defmodule FermixCore.Home.Join do
  @moduledoc """
  A computer joining a home that already runs (M97 §3.1, §7.5): the one
  writer of `<home>/device/join.json`, mode `0600` under the device-local
  `device/` (`0700`), written whole to a temporary file and renamed.

      {"v": 1, "phase": "dialing", "key": "@keyring", "public": "<32 bytes>",
       "server": {"name": "studio-mac", "gateway_pk": "<32 bytes>",
                  "node_id": "<64 hex>", "relays": [...], "relays_rev": "<16 hex>"},
       "secret": "<32 bytes>", "expires_at": "2031-05-04T10:30:00Z",
       "sas": null, "sentence": null}

  `start/3` (`computer.join.start`, `fermix computer join <code>`) refuses a
  computer that has a home of its own (`own_home/2`), then decodes the code,
  which must be a computer's (`EnrollmentCode`, version 2) and not expired,
  then makes this computer's key in the secret store (`ComputerKey.create/2`),
  then writes the file with the code's route and secret, then makes this
  engine a device (`[fermix_core.engine] role`), and then restarts it, which
  a CLI with no engine running leaves to the next start. A step that fails
  takes back what the ones before it wrote.

  The device tree dials the server while the file is here
  (`FermixChannels.Desktop.Join`), and records what it learns (`record/3`):
  `dialing`, `awaiting_approval` with the six digits both ends show, or
  `denied` with the sentence that says why; the code's secret leaves the
  file once denied. `finish/3` takes the server's approval: this
  computer's switches, every offer off and reviewed (M97 §7.3: a computer
  that joins starts with every offer off), then its link
  (`FermixCore.Home.DesktopLink`, naming the key's store), then the file
  goes, and the engine restarts as a linked computer. `cancel/2` ends a join
  wherever it stands: the key and the file go, the engine is the primary of
  its own home again, and it restarts.

  **A home of its own** (M97 §17): a home that holds any message, memory or
  scheduled job, a paired phone or computer, the moved marker, or a link to
  a server. The files a first start writes and nothing uses are left as
  they are: nothing is deleted to make a home empty.

  `opts`: `:now` (a `DateTime`), `:restart` (0-arity, in place of
  `Management.Lifecycle.restart_self/0`; a CLI passes one that does
  nothing), and `:key_opts` (handed to `ComputerKey`: `supervised: false`
  for a caller with no engine tree, and the secret writer's test seams).
  """

  alias Exqlite.Sqlite3
  alias FermixCore.Computers.Switches
  alias FermixCore.Home.ComputerKey
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.EnrollmentCode
  alias FermixCore.Home.Moved
  alias FermixCore.Management.Lifecycle
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.SecretWriter

  @dir "device"
  @file_name "join.json"
  @version 1
  @file_mode 0o600
  @dir_mode 0o700
  @phases ~w(dialing awaiting_approval denied)
  # What a home holds in memory.db that makes it a home of its own.
  @own_tables [messages: "messages", memories: "memories", scheduled_jobs: "scheduled jobs"]

  @type phase :: String.t()
  @type state :: %{required(String.t()) => term()}
  @type error ::
          :computer_join_running
          | :not_joining
          | {:home_of_its_own, String.t()}
          | {:invalid_code, String.t()}
          | {:code_purpose, EnrollmentCode.purpose()}
          | :code_expired
          | {:computer_key, ComputerKey.error()}
          | {:link, DesktopLink.error()}
          | {:file, Path.t(), term()}
          | {:invalid_join, Path.t()}
          | {:config, term()}

  @doc "Where the join is kept under `home`."
  @spec path(Path.t()) :: Path.t()
  def path(home) when is_binary(home) and home != "", do: Path.join([home, @dir, @file_name])

  @doc "Whether `home` is joining a home (its file is here)."
  @spec present?(Path.t()) :: boolean()
  def present?(home) when is_binary(home) and home != "", do: File.regular?(path(home))

  @doc "Every phase the file may hold."
  @spec phases() :: [phase()]
  def phases, do: @phases

  @doc "Joins the home a computer's `code` names (see the moduledoc)."
  @spec start(Path.t(), String.t(), keyword()) :: :ok | {:error, error()}
  def start(home, code, opts \\ [])
      when is_binary(home) and home != "" and is_binary(code) and is_list(opts) do
    with :ok <- not_joining(home),
         :ok <- own_home(home),
         {:ok, facts} <- computer_code(code, now(opts)),
         {:ok, keypair, store} <- new_key(home, opts),
         :ok <- undo_key_unless(write_state(home, initial(facts, keypair, store)), home, opts),
         :ok <- undo_all_unless(device_role(home), home, opts) do
      restart(opts)
    end
  end

  @doc """
  Whether `home` has a home of its own (see the moduledoc): `:ok`, or
  `{:error, {:home_of_its_own, what}}` naming the first thing found.
  """
  @spec own_home(Path.t()) :: :ok | {:error, error()}
  def own_home(home) when is_binary(home) and home != "" do
    with :ok <- not_moved(home),
         :ok <- not_linked(home),
         :ok <- no_devices(home) do
      no_memory(Path.join(home, "memory.db"))
    end
  end

  @doc "The join under `home`: its state, `:absent`, or why it cannot be read."
  @spec read(Path.t()) :: {:ok, state()} | :absent | {:error, error()}
  def read(home) when is_binary(home) and home != "" do
    file = path(home)

    with {:ok, text} <- read_file(file),
         {:ok, %{"v" => @version, "phase" => phase} = state} when phase in @phases <-
           Jason.decode(text) do
      {:ok, state}
    else
      :absent -> :absent
      {:error, {:file, _file, _reason}} = error -> error
      _not_a_join -> {:error, {:invalid_join, file}}
    end
  end

  @doc """
  Records `phase` with `fields` (string keys: `sas`, `sentence`) over what the
  file holds; a denial takes the code's secret off the disk.
  """
  @spec record(Path.t(), phase(), map()) :: :ok | {:error, error()}
  def record(home, phase, fields) when phase in @phases and is_map(fields) do
    with {:ok, state} <- read_present(home) do
      state = state |> Map.merge(fields) |> Map.put("phase", phase)
      write_state(home, if(phase == "denied", do: Map.put(state, "secret", nil), else: state))
    end
  end

  @doc "Ends the join wherever it stands (see the moduledoc)."
  @spec cancel(Path.t(), keyword()) :: :ok | {:error, error()}
  def cancel(home, opts \\ []) when is_binary(home) and home != "" and is_list(opts) do
    with {:ok, state} <- read_present(home),
         :ok <- forget_key(home, state, opts),
         :ok <- remove_file(path(home)),
         :ok <- config(ConfigStore.put_engine_role(home, :primary)) do
      restart(opts)
    end
  end

  @doc """
  Takes the server's approval (`join_approved`'s fields): this computer's
  switches, every offer off, then its link, then the file goes and the
  engine restarts as a linked computer.
  """
  @spec finish(Path.t(), map(), keyword()) :: :ok | {:error, error()}
  def finish(home, %{"device_id" => _id, "primary" => _primary} = approved, opts \\ [])
      when is_binary(home) and home != "" and is_list(opts) do
    with {:ok, state} <- read_present(home),
         {:ok, store} <- recorded_store(state),
         :ok <- config(Switches.write(home, Switches.only([]))),
         :ok <- link(DesktopLink.write(home, link_of(approved, state, store))),
         :ok <- remove_file(path(home)) do
      restart(opts)
    end
  end

  @doc """
  The join as `home.status` shows it on the computer that joins: its phase,
  the server's name, the six digits once both ends show them, and the
  sentence; nil when no join is under way.
  """
  @spec view(Path.t()) :: map() | nil
  def view(home) when is_binary(home) and home != "" do
    case read(home) do
      {:ok, state} -> view_of(state)
      _absent_or_unreadable -> nil
    end
  end

  defp view_of(state) do
    %{
      "phase" => state["phase"],
      "server" => get_in(state, ["server", "name"]),
      "sas" => state["sas"],
      "sentence" => state["sentence"] || phase_sentence(state)
    }
  end

  defp phase_sentence(%{"phase" => "dialing", "server" => %{"name" => name}}),
    do: "Connecting to your Fermix on #{name}."

  defp phase_sentence(%{"phase" => "awaiting_approval", "server" => %{"name" => name}}),
    do: "Waiting for you to add this computer on #{name}."

  defp phase_sentence(_state), do: "This computer was not added to your Fermix."

  @doc "The sentence a person is shown for an error of this module."
  @spec error_sentence(error()) :: String.t()
  def error_sentence(:computer_join_running),
    do: "This computer is already joining a Fermix. Cancel that first."

  def error_sentence(:not_joining), do: "This computer is not joining a Fermix."

  def error_sentence({:home_of_its_own, what}),
    do:
      "This computer already has a Fermix of its own (it holds #{what}), so it cannot join " <>
        "another. Two homes cannot be merged."

  def error_sentence({:invalid_code, _what}),
    do: "That is not a code Fermix opened. Copy the code again from Add a computer."

  def error_sentence({:code_purpose, :candidate}),
    do:
      "That code sets up a server of your own, so a computer cannot join with it. Use Add a " <>
        "computer in Always On."

  def error_sentence(:code_expired),
    do: "That code expired. Open a new one with Add a computer."

  def error_sentence({:computer_key, reason}), do: ComputerKey.error_sentence(reason)
  def error_sentence({:link, reason}), do: DesktopLink.error_sentence(reason)

  def error_sentence({:invalid_join, _path}),
    do: "This computer's join is not one Fermix wrote. Cancel it and join again."

  def error_sentence({:file, _path, reason}) when is_atom(reason),
    do: "Fermix could not use this computer's join (#{:file.format_error(reason)})."

  def error_sentence(_reason), do: "Fermix could not keep this computer's join."

  @doc """
  Every sentence this module shows a person, for the copy rules, with
  `server` as the server's name.
  """
  @spec sentences(String.t()) :: [String.t()]
  def sentences(server) when is_binary(server) do
    own = for {_table, words} <- @own_tables, do: {:home_of_its_own, words}

    reasons =
      own ++
        [
          :computer_join_running,
          :not_joining,
          {:home_of_its_own, "a home that moved to a server"},
          {:home_of_its_own, "a link to a server"},
          {:home_of_its_own, "a paired phone or computer"},
          {:invalid_code, "v"},
          {:code_purpose, :candidate},
          :code_expired,
          {:invalid_join, "join.json"},
          {:file, "join.json", :eacces},
          {:config, :eacces}
        ]

    phases =
      for phase <- @phases,
          do: phase_sentence(%{"phase" => phase, "server" => %{"name" => server}})

    Enum.map(reasons, &error_sentence/1) ++ phases
  end

  # -- start ---------------------------------------------------------------------

  defp not_joining(home) do
    if present?(home), do: {:error, :computer_join_running}, else: :ok
  end

  defp computer_code(text, now) do
    case EnrollmentCode.decode(text) do
      {:ok, %{purpose: :computer} = facts} -> unexpired(facts, now)
      {:ok, %{purpose: purpose}} -> {:error, {:code_purpose, purpose}}
      {:error, {:invalid_code, _what}} = error -> error
    end
  end

  defp unexpired(%{expires_at: at} = facts, now) do
    if DateTime.compare(now, at) == :lt, do: {:ok, facts}, else: {:error, :code_expired}
  end

  defp new_key(home, opts) do
    case ComputerKey.create(home, Keyword.get(opts, :key_opts, [])) do
      {:ok, keypair, store} -> {:ok, keypair, store}
      {:error, reason} -> {:error, {:computer_key, reason}}
    end
  end

  defp initial(facts, keypair, store) do
    %{
      "v" => @version,
      "phase" => "dialing",
      "key" => SecretWriter.sentinel_for(store),
      "public" => Base.encode64(keypair.public),
      "server" => %{
        "name" => facts.name,
        "gateway_pk" => Base.encode64(facts.gateway_pk),
        "node_id" => facts.node_id,
        "relays" => facts.relays,
        "relays_rev" => facts.relays_rev
      },
      "secret" => Base.encode64(facts.secret),
      "expires_at" => DateTime.to_iso8601(facts.expires_at),
      "sas" => nil,
      "sentence" => nil
    }
  end

  defp device_role(home), do: config(ConfigStore.put_engine_role(home, :device))

  # A step that fails takes back what the ones before it wrote.
  defp undo_key_unless(:ok, _home, _opts), do: :ok

  defp undo_key_unless({:error, _reason} = error, home, opts) do
    _ = ComputerKey.delete(home, nil, Keyword.get(opts, :key_opts, []))
    error
  end

  defp undo_all_unless(:ok, _home, _opts), do: :ok

  defp undo_all_unless({:error, _reason} = error, home, opts) do
    with {:ok, state} <- read_present(home), do: forget_key(home, state, opts)
    _ = remove_file(path(home))
    error
  end

  # -- a home of its own ------------------------------------------------------------

  defp not_moved(home) do
    case Moved.read(home) do
      :absent -> :ok
      _marker_or_unreadable -> {:error, {:home_of_its_own, "a home that moved to a server"}}
    end
  end

  defp not_linked(home) do
    if File.exists?(DesktopLink.path(home)),
      do: {:error, {:home_of_its_own, "a link to a server"}},
      else: :ok
  end

  defp no_devices(home) do
    file = Path.join([home, "mobile", "devices.toml"])

    case File.read(file) do
      {:error, :enoent} -> :ok
      {:ok, text} -> paired(TomlElixir.decode(text), file)
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  defp paired({:ok, %{"devices" => [_ | _]}}, _file),
    do: {:error, {:home_of_its_own, "a paired phone or computer"}}

  defp paired({:ok, _none}, _file), do: :ok
  defp paired({:error, _reason}, file), do: {:error, {:file, file, :invalid_devices}}

  # Read-only: an engine running in this home keeps its own connection, and
  # a reader sees what it committed (the WAL included).
  defp no_memory(db) do
    if File.regular?(db) do
      case Sqlite3.open(db, mode: :readonly) do
        {:ok, conn} -> close_after(conn, first_rows(conn))
        {:error, reason} -> {:error, {:file, db, reason}}
      end
    else
      :ok
    end
  end

  defp close_after(conn, result) do
    :ok = Sqlite3.close(conn)
    result
  end

  defp first_rows(conn) do
    Enum.reduce_while(@own_tables, :ok, fn {table, words}, :ok ->
      case rows?(conn, table) do
        {:ok, false} -> {:cont, :ok}
        {:ok, true} -> {:halt, {:error, {:home_of_its_own, words}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # A table a first start has not created holds nothing.
  defp rows?(conn, table) do
    with {:ok, [[present]]} <-
           query(conn, "SELECT count(*) FROM sqlite_master WHERE name = ?1", [
             Atom.to_string(table)
           ]) do
      if present == 0, do: {:ok, false}, else: any_row(conn, table)
    end
  end

  defp any_row(conn, table) do
    with {:ok, [[found]]} <- query(conn, "SELECT EXISTS (SELECT 1 FROM #{table})", []),
         do: {:ok, found == 1}
  end

  defp query(conn, sql, args) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      result =
        with :ok <- Sqlite3.bind(statement, args), do: Sqlite3.fetch_all(conn, statement)

      :ok = Sqlite3.release(conn, statement)
      result
    end
  end

  # -- finish and cancel --------------------------------------------------------------

  defp link_of(approved, state, store) do
    primary = approved["primary"]
    {:ok, gateway_pk} = Base.decode64(state["server"]["gateway_pk"])

    %{
      device_id: approved["device_id"],
      key: store,
      primary: %{
        name: primary["name"],
        gateway_pk: gateway_pk,
        node_id: primary["node_id"],
        relays: primary["relays"],
        relays_rev: primary["relays_rev"],
        addrs: Map.get(primary, "addrs", [])
      },
      epoch: approved["primary_epoch"]
    }
  end

  defp recorded_store(%{"key" => sentinel}) do
    case SecretWriter.store_of_sentinel(sentinel) do
      {:ok, store} -> {:ok, store}
      _unknown -> {:error, {:computer_key, {:invalid, :keyring}}}
    end
  end

  # Only the key this join made: another home's under the same profile stays.
  defp forget_key(home, state, opts) do
    with {:ok, store} <- recorded_store(state),
         {:ok, public} <- public_of(state) do
      key_opts = [public: public] ++ Keyword.get(opts, :key_opts, [])

      case ComputerKey.delete(home, store, key_opts) do
        :ok -> :ok
        {:error, reason} -> {:error, {:computer_key, reason}}
      end
    end
  end

  defp public_of(%{"public" => encoded}) do
    case Base.decode64(encoded || "") do
      {:ok, <<_::256>> = public} -> {:ok, public}
      _invalid -> {:error, {:computer_key, {:invalid, :keyring}}}
    end
  end

  # -- the file --------------------------------------------------------------------

  defp read_present(home) do
    case read(home) do
      {:ok, state} -> {:ok, state}
      :absent -> {:error, :not_joining}
      {:error, _reason} = error -> error
    end
  end

  defp read_file(file) do
    case File.read(file) do
      {:ok, text} -> {:ok, text}
      {:error, :enoent} -> :absent
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  defp write_state(home, state) do
    file = path(home)
    tmp = file <> ".tmp"

    with :ok <- dir(Path.dirname(file)),
         :ok <- file_op(File.write(tmp, Jason.encode!(state)), tmp),
         :ok <- file_op(File.chmod(tmp, @file_mode), tmp),
         :ok <- file_op(File.rename(tmp, file), file) do
      :ok
    else
      {:error, _reason} = error ->
        _ = File.rm(tmp)
        error
    end
  end

  defp dir(dir) do
    with :ok <- file_op(File.mkdir_p(dir), dir), do: file_op(File.chmod(dir, @dir_mode), dir)
  end

  defp remove_file(file) do
    case File.rm(file) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:file, file, reason}}
    end
  end

  defp file_op(:ok, _path), do: :ok
  defp file_op({:error, reason}, path), do: {:error, {:file, path, reason}}

  defp config(:ok), do: :ok
  defp config({:error, reason}), do: {:error, {:config, reason}}

  defp link(:ok), do: :ok
  defp link({:error, reason}), do: {:error, {:link, reason}}

  defp restart(opts), do: Keyword.get(opts, :restart, &Lifecycle.restart_self/0).()
  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
end
