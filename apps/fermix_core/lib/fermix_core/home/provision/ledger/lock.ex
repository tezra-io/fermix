defmodule FermixCore.Home.Provision.Ledger.Lock do
  @moduledoc """
  The one owner of the provisioner's ledger locks (M75 lean v1 §4.3), one per
  file: `Ledger.update/3` holds a file's lock across its read, change, write
  and rename, so two writers never lose each other's change.

  Writers are served in the order they asked, each the moment the one before
  it released the file or exited (the holder is monitored): no retry and no
  backoff, so nobody waits while the file is free. The owner never runs a
  writer's code. A writer whose turn has not come within its bound (30 s, a
  holder stuck on the disk) is refused `{:locked, file}` and leaves the
  queue, so it is never handed the file afterwards.

  It runs in the primary's and a desktop's tree (`FermixCore.Application`),
  the two roles that write the ledger.
  """

  use GenServer

  @wait_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts),
    do: GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Waits for `file`'s lock and holds it for the calling process: `:ok`, or
  `{:error, {:locked, file}}` after `:wait_ms`. `opts`: `:server`, `:wait_ms`.
  """
  @spec acquire(Path.t(), keyword()) :: :ok | {:error, {:locked, Path.t()}}
  def acquire(file, opts \\ []) when is_binary(file) and is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:acquire, file}, Keyword.get(opts, :wait_ms, @wait_ms))
  catch
    :exit, {:timeout, _call} ->
      GenServer.cast(Keyword.get(opts, :server, __MODULE__), {:abandon, file, self()})
      {:error, {:locked, file}}
  end

  @doc "Lets `file` go: only its holder may, anyone else is `{:error, :not_held}`."
  @spec release(Path.t(), keyword()) :: :ok | {:error, :not_held}
  def release(file, opts \\ []) when is_binary(file) and is_list(opts),
    do: GenServer.call(Keyword.get(opts, :server, __MODULE__), {:release, file})

  @impl true
  def init(:ok), do: {:ok, %{held: %{}, waiting: %{}}}

  @impl true
  def handle_call({:acquire, file}, {pid, _tag} = from, state) do
    if Map.has_key?(state.held, file),
      do: {:noreply, enqueue(state, file, {pid, from})},
      else: {:reply, :ok, hold(state, file, pid)}
  end

  def handle_call({:release, file}, {pid, _tag}, state) do
    case state.held do
      %{^file => {^pid, _ref}} -> {:reply, :ok, let_go(state, file)}
      _other -> {:reply, {:error, :not_held}, state}
    end
  end

  # A writer that stopped waiting: out of the queue, or, when its turn came
  # just as it gave up, the file goes to the next.
  @impl true
  def handle_cast({:abandon, file, pid}, state) do
    case state.held do
      %{^file => {^pid, _ref}} -> {:noreply, let_go(state, file)}
      _other -> {:noreply, %{state | waiting: drop_waiter(state.waiting, file, pid)}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.held, fn {_file, {_pid, held_ref}} -> held_ref == ref end) do
      {file, _holder} -> {:noreply, hand_on(state, file)}
      nil -> {:noreply, state}
    end
  end

  defp hold(state, file, pid),
    do: %{state | held: Map.put(state.held, file, {pid, Process.monitor(pid)})}

  defp let_go(state, file) do
    {_pid, ref} = Map.fetch!(state.held, file)
    true = Process.demonitor(ref, [:flush])
    hand_on(state, file)
  end

  # The next writer that asked, in order; a writer that has exited since is
  # handed the file all the same, and its monitor hands it on at once.
  defp hand_on(state, file) do
    case :queue.out(Map.get(state.waiting, file, :queue.new())) do
      {{:value, {pid, from}}, rest} ->
        GenServer.reply(from, :ok)
        hold(%{state | waiting: Map.put(state.waiting, file, rest)}, file, pid)

      {:empty, _queue} ->
        %{state | held: Map.delete(state.held, file), waiting: Map.delete(state.waiting, file)}
    end
  end

  defp enqueue(state, file, waiter) do
    queue = Map.get(state.waiting, file, :queue.new())
    %{state | waiting: Map.put(state.waiting, file, :queue.in(waiter, queue))}
  end

  defp drop_waiter(waiting, file, pid) do
    case Map.fetch(waiting, file) do
      {:ok, queue} -> Map.put(waiting, file, :queue.filter(&(elem(&1, 0) != pid), queue))
      :error -> waiting
    end
  end
end
