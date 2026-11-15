defmodule FermixCore.Home.MoveProgress do
  @moduledoc """
  What the move in hand on this computer counted so far, in memory only
  (Always On pane §3.13, P2 and P4): the step it is in and, while bytes move,
  how many moved of how many. The Always On summary reads it
  (`Management.HomeSummary`); nothing else does, and nothing is written to
  disk.

  **One record per engine**, since one move runs at a time:
  `%{move_id, step, bytes, size}`. `step` is the source's `:capture`,
  `:send`, `:staging` or `:commit` (`FermixChannels.Home.MoveWorker`) or the
  receiver's `:receive` (`FermixChannels.Home.MoveResponder`, on the desktop
  taking the home back). `bytes` and `size` are the bytes handed to the link
  (`:send`) or written (`:receive`) against the capture's size; a step that
  moves no bytes has `bytes` 0 and `size` nil. A record that breaks that
  shape is refused (`FunctionClauseError`).

  **Never written per chunk.** A writer puts at each step and at each whole
  5% of the transfer it crosses (`crossed?/3`, the one rule both writers put
  by), so a transfer of any size puts at most 21 times, its 0% included.
  Each change tells the Always On watch (`Home.StatusWatch.changed(:move)`)
  once the record is in place, so the apps' key moves at most that often.

  **A record lives no longer than its writer.** `clear/2` forgets it only
  when it names that move, so a writer's ending never forgets another's; and
  the process that put it is monitored, so a writer that exits without
  clearing (one killed, or crashed) takes its record with it.

  Reads are lock-free (a protected ETS table named after the server); a put
  and a clear go through the process. Where the store does not run (a test
  VM, a CLI verb with no engine, a candidate's tree) `read/1` answers nil and
  `put/2` and `clear/2` do nothing, as `StatusWatch.changed/2` does for a
  watch that does not run.

  Seams: `:name` (the server and its table) and `:status_changed` (a 0-arity
  call in place of telling the watch, made inside the store with the change
  in place).
  """

  use GenServer

  alias FermixCore.Home.StatusWatch

  @steps [:capture, :send, :staging, :commit, :receive]
  @counted [:send, :receive]
  @uncounted @steps -- @counted
  @key :move

  # A record's shape: its four keys and a move id; a count of bytes against
  # a size for a step that moves them, none for one that does not.
  defguardp moving(record, id) when map_size(record) == 4 and is_binary(id) and id != ""

  defguardp counted(step, bytes, size)
            when step in @counted and is_integer(size) and is_integer(bytes) and bytes >= 0 and
                   bytes <= size

  defguardp uncounted(step, bytes, size) when step in @uncounted and bytes === 0 and is_nil(size)

  @type step :: :capture | :send | :staging | :commit | :receive
  @type t :: %{
          move_id: String.t(),
          step: step(),
          bytes: non_neg_integer(),
          size: non_neg_integer() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    name = opts |> Keyword.get(:name, __MODULE__) |> named!()
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  # The table is named after the server, so the server has a name.
  defp named!(name) when is_atom(name) and not is_nil(name), do: name

  @doc "The record of the move in hand, or nil where nothing is counted or no store runs."
  @spec read(atom()) :: t() | nil
  def read(server \\ __MODULE__) when is_atom(server) do
    case :ets.whereis(server) do
      :undefined -> nil
      table -> table |> :ets.lookup(@key) |> record()
    end
  end

  @doc "Replaces the one record with `record` and tells the watch; nothing where no store runs."
  @spec put(atom(), t()) :: :ok
  def put(server \\ __MODULE__, record)

  def put(server, %{move_id: id, step: step, bytes: bytes, size: size} = record)
      when is_atom(server) and moving(record, id) and
             (counted(step, bytes, size) or uncounted(step, bytes, size)),
      do: call(server, {:put, record})

  @doc "Forgets the record when it names `move_id`, and tells the watch if it did."
  @spec clear(atom(), String.t()) :: :ok
  def clear(server \\ __MODULE__, move_id)
      when is_atom(server) and is_binary(move_id) and move_id != "",
      do: call(server, {:clear, move_id})

  @doc """
  Whether a count that moved from `before` to `now` bytes of `size` crossed a
  whole 5% (a twentieth) it had not reached: the writers put only then. The
  last byte always crosses into the whole; a size of 0 never crosses.
  """
  @spec crossed?(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: boolean()
  def crossed?(before, now, size)
      when is_integer(before) and is_integer(now) and is_integer(size) and before >= 0 and
             now >= before and size >= now,
      do: twentieth(now, size) > twentieth(before, size)

  defp twentieth(_bytes, 0), do: 20
  defp twentieth(bytes, size), do: div(bytes * 20, size)

  defp record([{@key, record}]), do: record
  defp record([]), do: nil

  defp call(server, message) do
    GenServer.call(server, message)
  catch
    :exit, {:noproc, _call} -> :ok
  end

  # -- the store ---------------------------------------------------------------

  @impl true
  def init(opts) do
    table =
      :ets.new(Keyword.fetch!(opts, :name), [
        :named_table,
        :protected,
        :set,
        read_concurrency: true
      ])

    {:ok,
     %{
       table: table,
       status_changed: Keyword.get(opts, :status_changed, fn -> StatusWatch.changed(:move) end),
       writer: nil
     }}
  end

  @impl true
  def handle_call({:put, record}, {pid, _tag}, state) do
    true = :ets.insert(state.table, {@key, record})
    state = follow(state, pid)
    :ok = state.status_changed.()
    {:reply, :ok, state}
  end

  def handle_call({:clear, move_id}, _from, state) do
    case :ets.lookup(state.table, @key) do
      [{@key, %{move_id: ^move_id}}] -> {:reply, :ok, forget(state)}
      _another_or_none -> {:reply, :ok, state}
    end
  end

  # The writer exited without clearing: its record goes with it.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{writer: {_writer, ref}} = state),
    do: {:noreply, forget(state)}

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # The process that put the record is the one watched; a record put by
  # another replaces its writer.
  defp follow(%{writer: {pid, _ref}} = state, pid), do: state
  defp follow(state, pid), do: %{unfollow(state) | writer: {pid, Process.monitor(pid)}}

  defp unfollow(%{writer: nil} = state), do: state

  defp unfollow(%{writer: {_pid, ref}} = state) do
    true = Process.demonitor(ref, [:flush])
    %{state | writer: nil}
  end

  defp forget(state) do
    true = :ets.delete(state.table, @key)
    state = unfollow(state)
    :ok = state.status_changed.()
    state
  end
end
