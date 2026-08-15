defmodule FermixChannels.Mobile.RequestCoordinator do
  @moduledoc """
  Serializes durable mobile-request ownership for one daemon boot.

  The random boot epoch is persisted by `FermixCore.Mobile.Store` when work is
  started. On restart, accepted work and work owned by an older epoch is
  recovered from its stored authenticated request envelope. Requests already
  running in this epoch are never started twice.

  A started attempt is also fenced on the liveness of whichever process owns its
  settlement: the acquiring socket process until `Gateway.ingest` returns, then
  the queue that owns the turn (`handoff/5`). If that owner dies without
  settling, the attempt is abandoned so a resend — or the next boot's recovery
  scan — runs a new attempt, instead of a `running` row nobody will ever settle
  answering every resend as an already-running duplicate.
  """

  use GenServer

  require Logger

  alias FermixChannels.Mobile.EventRouter
  alias FermixCore.Mobile.Store

  @default_recovery_limit 200
  @default_max_recovery_batches 100

  # Past the durable claim's own 24h TTL a fence can no longer protect anything:
  # the request row has expired, so a resend re-claims from scratch. Collecting
  # those fences is what keeps the table bounded for a long-lived queue owner.
  @default_fence_ttl_ms 24 * 60 * 60 * 1_000
  @fence_sweep_ms 15 * 60 * 1_000

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

  @doc """
  Move an in-flight attempt's liveness fence to the process that owns settlement
  once ingest has returned. A handoff for an attempt the fence no longer tracks
  is a no-op: that claim has already been superseded or released.
  """
  @spec handoff(GenServer.server(), String.t(), String.t(), pos_integer(), pid()) :: :ok
  def handoff(server, profile_id, client_msg_id, attempt, owner)
      when is_binary(profile_id) and profile_id != "" and is_binary(client_msg_id) and
             client_msg_id != "" and is_integer(attempt) and attempt > 0 and is_pid(owner) do
    GenServer.call(server, {:handoff, profile_id, client_msg_id, attempt, owner})
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
      fence_ttl_ms: fence_ttl_ms(opts),
      fences: %{},
      fence_refs: %{},
      server: self()
    }

    schedule_sweep()

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

  def handle_call({:acquire, profile_id, client_msg_id, opts}, {caller, _tag}, state) do
    store_opts = Keyword.merge(state.store_opts, opts)

    result =
      state.store.start_client_request(profile_id, client_msg_id, state.epoch, store_opts)

    {:reply, result, fence_started(state, {profile_id, client_msg_id}, caller, result)}
  end

  def handle_call({:handoff, profile_id, client_msg_id, attempt, owner}, _from, state) do
    key = {profile_id, client_msg_id}

    case Map.get(state.fences, key) do
      %{attempt: ^attempt} ->
        {:reply, :ok, state |> drop_fence(key) |> put_fence(key, owner, attempt)}

      _superseded ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.fence_refs, ref) do
      {nil, _refs} ->
        {:noreply, state}

      {key, fence_refs} ->
        {fence, fences} = Map.pop(state.fences, key)
        abandon_fenced_attempt(key, fence, reason, state)
        {:noreply, %{state | fences: fences, fence_refs: fence_refs}}
    end
  end

  def handle_info(:sweep, state) do
    schedule_sweep()
    {:noreply, sweep_fences(state, System.monotonic_time(:millisecond))}
  end

  def handle_info(message, state) do
    Logger.debug("mobile request coordinator ignored message: #{inspect(message)}")
    {:noreply, state}
  end

  defp fence_started(state, key, owner, {:ok, {:started, %{attempt: attempt}}}) do
    state |> drop_fence(key) |> put_fence(key, owner, attempt)
  end

  defp fence_started(state, _key, _owner, _other_result), do: state

  defp put_fence(state, key, owner, attempt) do
    ref = Process.monitor(owner)

    fence = %{
      ref: ref,
      attempt: attempt,
      deadline_ms: System.monotonic_time(:millisecond) + state.fence_ttl_ms
    }

    %{
      state
      | fences: Map.put(state.fences, key, fence),
        fence_refs: Map.put(state.fence_refs, ref, key)
    }
  end

  defp drop_fence(state, key) do
    case Map.pop(state.fences, key) do
      {nil, _fences} ->
        state

      {%{ref: ref}, fences} ->
        Process.demonitor(ref, [:flush])
        %{state | fences: fences, fence_refs: Map.delete(state.fence_refs, ref)}
    end
  end

  defp sweep_fences(state, now_ms) do
    state.fences
    |> Enum.filter(fn {_key, fence} -> fence.deadline_ms <= now_ms end)
    |> Enum.reduce(state, fn {key, _fence}, acc -> drop_fence(acc, key) end)
  end

  defp abandon_fenced_attempt({profile_id, client_msg_id}, %{attempt: attempt}, reason, state) do
    case state.store.abandon_client_request(
           profile_id,
           client_msg_id,
           attempt,
           state.store_opts
         ) do
      {:ok, _request} ->
        Logger.warning(
          "mobile request runner for #{inspect({profile_id, client_msg_id})} died " <>
            "(#{inspect(reason)}); attempt #{attempt} released for a new attempt"
        )

      # The owner settled the attempt before it exited, which is the ordinary
      # end of a turn: there is nothing left to fence.
      {:error, :stale_attempt} ->
        Logger.debug(
          "mobile request #{inspect({profile_id, client_msg_id})} attempt #{attempt} " <>
            "was already settled when its runner exited"
        )

      {:error, abandon_reason} ->
        Logger.error(
          "mobile request attempt could not be released for " <>
            "#{inspect({profile_id, client_msg_id})}: #{inspect(abandon_reason)}"
        )
    end
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @fence_sweep_ms)

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

      {:error, reason} ->
        Logger.error("mobile request recovery scan failed: #{inspect(reason)}")
    end
  end

  defp recover_batches(state, _batch) do
    Logger.error("mobile request recovery exceeded #{state.max_recovery_batches} bounded batches")
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

  defp fence_ttl_ms(opts) do
    case Keyword.get(opts, :fence_ttl_ms, @default_fence_ttl_ms) do
      ttl when is_integer(ttl) and ttl >= 0 -> ttl
      invalid -> raise ArgumentError, "fence_ttl_ms must be non-negative, got #{inspect(invalid)}"
    end
  end

  defp max_recovery_batches(opts) do
    case Keyword.get(opts, :max_recovery_batches, @default_max_recovery_batches) do
      batches when is_integer(batches) and batches > 0 ->
        batches

      invalid ->
        raise ArgumentError, "max_recovery_batches must be positive, got #{inspect(invalid)}"
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
