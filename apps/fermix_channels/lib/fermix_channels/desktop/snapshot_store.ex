defmodule FermixChannels.Desktop.SnapshotStore do
  @moduledoc """
  The desktop's copies of its primary's snapshots (M75 §8, D19), in the
  device role: the desktop target's other end.

  The primary streams each snapshot it writes, still encrypted
  (`snapshot_begin`, `snapshot_chunk`…, `snapshot_end`). This process writes
  it to `<home>/snapshots/<name>.partial` (`0600`), checking that the chunks
  come in order, and at the end that the size and the SHA-256 are the ones
  `snapshot_begin` named; then it renames the file into place, keeps the
  newest #{3} and deletes the older ones, and answers `snapshot_stored` with
  the SHA-256 it computed. The primary counts the copy verified when that is
  its own.

  **The floor.** A copy is refused before a byte is written when this disk
  would be left with less than 2 GiB free once it is stored: the owner's
  desktop is not the place to fill a disk for a backup. The primary is told
  why (`snapshot_refused`), and records it as the desktop target's error.
  Other refusals: `space_unknown` (the free space could not be read),
  `mismatch` (size or SHA-256), `out_of_order` (a chunk that is not the next
  one, or for another snapshot), `invalid_name`, `write_failed`. A refused or failed copy leaves no partial file.

  Only the copies are here: this machine never holds the recovery passphrase,
  so it cannot read them; `fermix home import` restores one with it.

  The relay hands it the primary's events (`handle/3`, one line each in
  `Desktop.Relay`'s `@inbound`), and waits for each chunk to be written, so a
  slow disk slows the stream instead of filling memory. The answer goes back
  in a task, never from inside the relay's call. Test seams: `:name`,
  `:home`, `:send`, `:free_bytes` (a 1-arity function of the directory),
  `:task_supervisor`.
  """

  use GenServer

  require Logger

  alias FermixChannels.Desktop.Relay
  alias FermixCore.CommandRunner
  alias FermixCore.Home.Snapshot.Capture
  alias FermixCore.Setup.ConfigStore

  @events ~w(snapshot_begin snapshot_chunk snapshot_end)
  @keep 3
  @floor_bytes 2 * 1_024 * 1_024 * 1_024
  @name ~r/\A[0-9]{8}T[0-9]{6}Z-e[0-9]{1,12}\.fxsnap\z/
  @call_timeout_ms 60_000
  @df_timeout_ms 5_000

  @doc "How many copies a desktop keeps."
  @spec keep() :: pos_integer()
  def keep, do: @keep

  @doc "The free space, in bytes, a stored copy must leave on the desktop's disk."
  @spec floor_bytes() :: pos_integer()
  def floor_bytes, do: @floor_bytes

  @doc "Serves one of the primary's snapshot events, from the relay."
  @spec handle(String.t(), map(), binary()) :: :ok | {:error, term()}
  def handle(type, fields, payload) when type in @events and is_map(fields),
    do: handle(__MODULE__, type, fields, payload)

  @doc false
  @spec handle(GenServer.server(), String.t(), map(), binary()) :: :ok | {:error, term()}
  def handle(server, type, fields, payload) when type in @events do
    GenServer.call(server, {type, fields, payload}, @call_timeout_ms)
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] -> {:error, :not_running}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    home = Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)

    {:ok,
     %{
       dir: Capture.dir(home),
       send: Keyword.get(opts, :send, &Relay.send_event(Relay, &1, &2)),
       free_bytes: Keyword.get(opts, :free_bytes, &df_free_bytes/1),
       task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
       copy: nil
     }}
  end

  @impl true
  def handle_call({"snapshot_begin", fields, _payload}, _from, state) do
    state = abandon(state)

    case begin(fields, state) do
      {:ok, copy} ->
        {:reply, :ok, %{state | copy: copy}}

      {:error, reason} ->
        refuse(fields["snapshot_id"], reason, state)
        {:reply, :ok, state}
    end
  end

  def handle_call(
        {"snapshot_chunk", %{"snapshot_id" => id, "index" => index}, bytes},
        _from,
        state
      ) do
    case state.copy do
      %{id: ^id, next: ^index} = copy -> {:reply, :ok, write(copy, bytes, state)}
      _other -> {:reply, :ok, refuse_copy(id, "out_of_order", state)}
    end
  end

  def handle_call({"snapshot_end", %{"snapshot_id" => id}, _payload}, _from, state) do
    case state.copy do
      %{id: ^id} = copy -> {:reply, :ok, finish(copy, state)}
      _other -> {:reply, :ok, refuse_copy(id, "out_of_order", state)}
    end
  end

  @impl true
  def terminate(_reason, state) do
    abandon(state)
    :ok
  end

  defp begin(%{"snapshot_id" => id, "name" => name, "size_bytes" => size, "sha256" => sha}, state) do
    with :ok <- valid_name(name),
         :ok <- mkdir(state.dir),
         :ok <- room(size, state),
         partial = Path.join(state.dir, name <> ".partial"),
         {:ok, io} <- open_partial(partial) do
      {:ok,
       %{
         id: id,
         name: name,
         size: size,
         sha256: String.downcase(sha),
         partial: partial,
         io: io,
         hash: :crypto.hash_init(:sha256),
         written: 0,
         next: 0
       }}
    end
  end

  defp valid_name(name) do
    if Regex.match?(@name, name), do: :ok, else: {:error, "invalid_name"}
  end

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> write_failed(dir, reason)
    end
  end

  defp room(size, state) do
    case state.free_bytes.(state.dir) do
      {:ok, free} when free - size >= @floor_bytes ->
        :ok

      {:ok, free} ->
        Logger.warning(
          "desktop snapshots: #{size} bytes would leave #{free - size} free; refused"
        )

        {:error, "disk_floor"}

      {:error, reason} ->
        Logger.error("desktop snapshots: the free space is unknown: #{inspect(reason)}")
        {:error, "space_unknown"}
    end
  end

  defp open_partial(partial) do
    with {:ok, io} <- File.open(partial, [:write, :binary, :raw]),
         :ok <- File.chmod(partial, 0o600) do
      {:ok, io}
    else
      {:error, reason} -> write_failed(partial, reason)
    end
  end

  defp write(copy, bytes, state) do
    case :file.write(copy.io, bytes) do
      :ok ->
        %{
          state
          | copy: %{
              copy
              | hash: :crypto.hash_update(copy.hash, bytes),
                written: copy.written + byte_size(bytes),
                next: copy.next + 1
            }
        }

      {:error, reason} ->
        Logger.error("desktop snapshots: #{copy.partial}: #{inspect(reason)}")
        refuse_copy(copy.id, "write_failed", state)
    end
  end

  defp finish(copy, state) do
    sha = copy.hash |> :crypto.hash_final() |> Base.encode16(case: :lower)
    :ok = File.close(copy.io)
    copy = %{copy | io: nil}

    if copy.written == copy.size and sha == copy.sha256,
      do: place(copy, sha, state),
      else: refuse_copy(copy.id, "mismatch", %{state | copy: copy})
  end

  defp place(copy, sha, state) do
    case File.rename(copy.partial, Path.join(state.dir, copy.name)) do
      :ok ->
        prune(state.dir)
        answer(state, %{"t" => "snapshot_stored", "snapshot_id" => copy.id, "sha256" => sha})
        %{state | copy: nil}

      {:error, reason} ->
        Logger.error("desktop snapshots: #{copy.name} not placed: #{inspect(reason)}")
        refuse_copy(copy.id, "write_failed", %{state | copy: copy})
    end
  end

  # The newest three copies stay: their names start with the UTC time they
  # were written, so they sort by age.
  defp prune(dir) do
    {:ok, entries} = File.ls(dir)

    entries
    |> Enum.filter(&Regex.match?(@name, &1))
    |> Enum.sort(:desc)
    |> Enum.drop(@keep)
    |> Enum.each(fn old ->
      case File.rm(Path.join(dir, old)) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("desktop snapshots: #{old} not removed: #{inspect(reason)}")
      end
    end)
  end

  defp refuse_copy(id, reason, state) do
    state = abandon(state)
    refuse(id, reason, state)
    state
  end

  defp refuse(id, reason, state) do
    Logger.warning("desktop snapshots: #{id} refused: #{reason}")
    answer(state, %{"t" => "snapshot_refused", "snapshot_id" => id, "reason" => reason})
  end

  # A copy in progress goes with its partial file.
  defp abandon(%{copy: nil} = state), do: state

  defp abandon(%{copy: copy} = state) do
    if copy.io, do: File.close(copy.io)

    case File.rm(copy.partial) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> Logger.error("desktop snapshots: #{copy.partial}: #{inspect(reason)}")
    end

    %{state | copy: nil}
  end

  # The relay is waiting on this process, so the answer goes from a task.
  defp answer(state, %{"t" => type} = event) do
    job = fn ->
      case state.send.(event, <<>>) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("desktop snapshots: #{type} not sent: #{inspect(reason)}")
      end
    end

    {:ok, _task} = Task.Supervisor.start_child(state.task_supervisor, job)
    :ok
  end

  defp write_failed(path, reason) do
    Logger.error("desktop snapshots: #{path}: #{inspect(reason)}")
    {:error, "write_failed"}
  end

  # POSIX `df -Pk`: the fourth column of the second line is the space left,
  # in 1024-byte blocks, on the filesystem that holds `dir`.
  defp df_free_bytes(dir) do
    with df when is_binary(df) <- System.find_executable("df"),
         {:ok, %{exit: 0, stdout: out}} <-
           CommandRunner.run(df, ["-Pk", dir], timeout_ms: @df_timeout_ms),
         [_header, line | _rest] <- String.split(out, "\n", trim: true),
         [_fs, _blocks, _used, available | _cols] <- String.split(line),
         {kb, ""} <- Integer.parse(available) do
      {:ok, kb * 1_024}
    else
      nil -> {:error, :df_unavailable}
      other -> {:error, {:df_failed, other}}
    end
  end
end
