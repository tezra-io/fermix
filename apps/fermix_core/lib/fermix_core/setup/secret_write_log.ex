defmodule FermixCore.Setup.SecretWriteLog do
  @moduledoc """
  The one path every setup secret write takes, and the record of what it wrote
  (M34 native setup §7.5, the fourth restart input).

  A boot-bound credential that was replaced since the daemon started needs a
  restart, and no snapshot comparison can see that: a rotation writes the same
  `@keyring` sentinel over the same sentinel, so the persisted document and
  application environment are byte-identical before and after. The rotation is
  only visible at the moment it happens, which is why it is recorded here rather
  than derived later.

  There is no second writing path. `SecretWriter.put/3` has three call sites in
  the tree (`SecretStore`, `SecretMigration`, `Wizard`) and `secret.set` is the
  fourth; all four route through `put/3` so a rotation cannot land unrecorded.

  The log is boot-bound state and is deliberately not persisted: what it answers
  is "since this VM started", and a restart is exactly what clears it.

  Reads and records answer truthfully with no server running — a tree-less verb
  has written nothing through this process, so it has nothing to report. That is
  two declared configurations of one read, not a fallback: the write itself
  always happens, and only the record is skipped.
  """

  use GenServer

  alias FermixCore.Setup.SecretWriter

  @max_recorded 200

  @type record :: %{key: atom(), at_ms: integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Writes one secret through `SecretWriter` and records the write on success.

  The write's own result is returned untouched: a failed write records nothing,
  because nothing was replaced.
  """
  @spec put(atom(), String.t(), keyword()) :: :ok | {:error, term()}
  def put(key, value, opts \\ []) when is_atom(key) and is_binary(value) and is_list(opts) do
    case SecretWriter.put(key, value, opts) do
      :ok -> record(key, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Every secret key written through this process at or after `since_ms`, a
  `System.monotonic_time(:millisecond)` reading.

  Answers `[]` with no server running.
  """
  @spec keys_since(integer(), keyword()) :: [atom()]
  def keys_since(since_ms, opts \\ []) when is_integer(since_ms) and is_list(opts) do
    call(opts, {:keys_since, since_ms}, [])
  end

  @doc "Every write this process holds, newest first. Bounded; for tests and diagnostics."
  @spec recorded(keyword()) :: [record()]
  def recorded(opts \\ []) when is_list(opts), do: call(opts, :recorded, [])

  @impl true
  def init(opts) do
    {:ok, %{writes: [], max_recorded: Keyword.get(opts, :max_recorded, @max_recorded)}}
  end

  @impl true
  def handle_call({:record, key}, _from, state) do
    write = %{key: key, at_ms: System.monotonic_time(:millisecond)}
    {:reply, :ok, %{state | writes: Enum.take([write | state.writes], state.max_recorded)}}
  end

  def handle_call({:keys_since, since_ms}, _from, state) do
    keys =
      state.writes
      |> Enum.filter(&(&1.at_ms >= since_ms))
      |> Enum.map(& &1.key)
      |> Enum.uniq()

    {:reply, keys, state}
  end

  def handle_call(:recorded, _from, state), do: {:reply, state.writes, state}

  defp record(key, opts) do
    call(opts, {:record, key}, :ok)
  end

  defp call(opts, message, absent_answer) do
    case Process.whereis(Keyword.get(opts, :write_log, __MODULE__)) do
      nil -> absent_answer
      pid -> GenServer.call(pid, message)
    end
  catch
    # Only an absent process reads as the absent answer. A timeout or a crashed
    # server is a wedged daemon, and mapping it to the default would draw a
    # healthy surface over it.
    :exit, {:noproc, _call} -> absent_answer
  end
end
