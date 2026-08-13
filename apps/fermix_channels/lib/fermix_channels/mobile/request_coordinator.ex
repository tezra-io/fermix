defmodule FermixChannels.Mobile.RequestCoordinator do
  @moduledoc """
  Serializes durable mobile-request ownership for one daemon boot.

  The random boot epoch is persisted by `FermixCore.Mobile.Store` when work is
  started. On restart, accepted work and work owned by an older epoch is
  recovered from its stored authenticated request envelope. Requests already
  running in this epoch are never started twice.
  """

  use GenServer

  require Logger

  alias FermixChannels.Mobile.EventRouter
  alias FermixCore.Mobile.Store

  @default_recovery_limit 200
  @default_max_recovery_batches 100

  @type acquire_state :: :started | :active | :completed | :failed

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec epoch(GenServer.server()) :: String.t()
  def epoch(server \\ __MODULE__), do: GenServer.call(server, :epoch)

  @spec acquire(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, {acquire_state(), map()}} | {:error, term()}
  def acquire(server, profile_id, client_msg_id, opts \\ [])

  def acquire(server, profile_id, client_msg_id, opts)
      when is_binary(profile_id) and profile_id != "" and is_binary(client_msg_id) and
             client_msg_id != "" and is_list(opts) do
    GenServer.call(server, {:acquire, profile_id, client_msg_id, opts})
  end

  @impl true
  def init(opts) do
    state = %{
      epoch: boot_epoch(opts),
      store: Keyword.get(opts, :store, Store),
      store_opts: Keyword.get(opts, :store_opts, []),
      recovery_limit: recovery_limit(opts),
      max_recovery_batches: max_recovery_batches(opts),
      recovery_launcher: Keyword.get(opts, :recovery_launcher, &launch_recovery/1),
      recover_request: Keyword.get(opts, :recover_request, &EventRouter.recover_request/3),
      recover?: Keyword.get(opts, :recover?, true),
      server: self()
    }

    {:ok, state, {:continue, :recover}}
  end

  @impl true
  def handle_continue(:recover, %{recover?: false} = state), do: {:noreply, state}

  def handle_continue(:recover, state) do
    task = fn -> recover(state) end

    case state.recovery_launcher.(task) do
      :ok ->
        :ok

      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.error("mobile request recovery launch failed: #{inspect(reason)}")

      other ->
        Logger.error("mobile request recovery launcher returned: #{inspect(other)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:epoch, _from, state), do: {:reply, state.epoch, state}

  def handle_call({:acquire, profile_id, client_msg_id, opts}, _from, state) do
    store_opts = Keyword.merge(state.store_opts, opts)

    result =
      state.store.start_client_request(profile_id, client_msg_id, state.epoch, store_opts)

    {:reply, result, state}
  end

  defp recover(state) do
    recover_batches(state, 1)
  end

  defp recover_batches(state, batch) when batch <= state.max_recovery_batches do
    opts = Keyword.put(state.store_opts, :limit, state.recovery_limit)

    case state.store.recoverable_client_requests(state.epoch, opts) do
      {:ok, []} ->
        :ok

      {:ok, rows} ->
        Enum.each(rows, &recover_row(&1, state))

        if length(rows) == state.recovery_limit,
          do: recover_batches(state, batch + 1),
          else: :ok

      {:error, reason} -> Logger.error("mobile request recovery scan failed: #{inspect(reason)}")
    end
  end

  defp recover_batches(state, _batch) do
    Logger.error(
      "mobile request recovery exceeded #{state.max_recovery_batches} bounded batches"
    )
  end

  defp recover_row(row, state) do
    with {:ok, context} <- recovery_context(row),
         :ok <-
           state.recover_request.(row, context,
             request_coordinator: state.server,
             store: state.store,
             store_opts: state.store_opts
           ) do
      :ok
    else
      {:error, reason} ->
        terminalize_unrecoverable(row, reason, state)

        Logger.error(
          "mobile request recovery failed for #{request_label(row)}: #{inspect(reason)}"
        )
    end
  end

  defp recovery_context(%{authenticated_device_id: device_id})
       when is_binary(device_id) and device_id != "" do
    {:ok, %{transport: :mobile, authenticated_device_id: device_id}}
  end

  defp recovery_context(_row), do: {:error, :missing_authenticated_device}

  defp terminalize_unrecoverable(row, reason, state) do
    profile = Map.get(row, :profile_id)
    client_id = Map.get(row, :client_msg_id)

    case state.store.start_client_request(profile, client_id, state.epoch, state.store_opts) do
      {:ok, {:started, %{attempt: attempt}}} ->
        state.store.fail_client_request(
          profile,
          client_id,
          attempt,
          %{error: %{type: "recovery", reason: inspect(reason)}},
          state.store_opts
        )

      {:ok, {_terminal_or_active, _row}} ->
        :ok

      {:error, start_reason} ->
        Logger.error("mobile unrecoverable request could not be fenced: #{inspect(start_reason)}")
    end
  end

  defp request_label(row) do
    {Map.get(row, :profile_id), Map.get(row, :client_msg_id)} |> inspect()
  end

  defp recovery_limit(opts) do
    case Keyword.get(opts, :recovery_limit, @default_recovery_limit) do
      limit when is_integer(limit) and limit in 1..200 ->
        limit

      invalid ->
        raise ArgumentError, "recovery_limit must be between 1 and 200, got #{inspect(invalid)}"
    end
  end

  defp max_recovery_batches(opts) do
    case Keyword.get(opts, :max_recovery_batches, @default_max_recovery_batches) do
      batches when is_integer(batches) and batches > 0 -> batches
      invalid -> raise ArgumentError, "max_recovery_batches must be positive, got #{inspect(invalid)}"
    end
  end

  defp boot_epoch(opts) do
    case Keyword.fetch(opts, :boot_epoch) do
      :error ->
        random_boot_epoch()

      {:ok, epoch} when is_binary(epoch) and epoch != "" ->
        epoch

      {:ok, invalid} ->
        raise ArgumentError, "boot_epoch must be a non-empty string, got #{inspect(invalid)}"
    end
  end

  defp random_boot_epoch do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp launch_recovery(task) do
    Task.Supervisor.start_child(FermixCore.TaskSupervisor, task)
  end
end
