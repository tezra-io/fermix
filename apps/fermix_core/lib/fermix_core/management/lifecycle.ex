defmodule FermixCore.Management.Lifecycle do
  @moduledoc """
  The leased drain transaction behind `lifecycle.prepare|commit|cancel` (M34 §2,
  §4).

  Disable, restart, migration, and update all need the same thing: a short,
  single-flight window in which the app may unregister the background agent
  knowing the daemon will still be there if the step fails. `prepare/1` opens
  exactly one such window and hands back `{lease_id, expires_at_ms}`;
  `commit/2` runs the daemon's existing shutdown path; `cancel/2` releases the
  window with the daemon untouched.

  **A prepared daemon auto-resumes.** The lease is finite and monotonic: if the
  app crashes, is force-quit, or the machine reboots between prepare and commit,
  the timer fires, the lease is dropped, and the daemon simply keeps serving.
  Nothing is drained by `prepare/1` itself — a prepared daemon that never
  commits is indistinguishable from one that was never prepared.

  **The lease publishes a relative `ttl_ms`, never a wall-clock deadline.** The
  expiry timer runs on Erlang monotonic time, which is frozen across sleep on
  Darwin and never stepped by NTP. A wall-clock `expires_at_ms` computed
  alongside it disagrees with the timer the moment the machine sleeps or the
  clock steps: the client abandons a transaction the server still holds, and
  every later `prepare` answers `:busy` until the residual monotonic TTL
  elapses. The client measures the published TTL against its own clock.

  A lease id is answered honestly for as long as this server remembers it:
  an id whose window elapsed is `:lease_expired` (the app can tell the operator
  the transaction timed out), while an id this server never issued — or already
  consumed — is `:unknown_lease`. The expired memory is bounded; beyond it an
  ancient id degrades to `:unknown_lease`.
  """

  use GenServer

  require Logger

  @default_lease_ttl_ms 30_000
  @max_remembered_leases 8
  @lease_id_bytes 12
  # Mirrors the daemon's own v0 shutdown finalizer: answer first, then stop, so
  # the caller sees the commit acknowledged rather than a closed socket.
  @shutdown_delay_ms 150

  @type lease :: %{lease_id: String.t(), ttl_ms: pos_integer()}
  @type lease_error :: :lease_expired | :unknown_lease

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The number of elapsed lease ids this server distinguishes from unknown ones."
  @spec max_remembered_leases() :: pos_integer()
  def max_remembered_leases, do: @max_remembered_leases

  @doc "Opens the single drain window. `{:error, :busy}` when one is already open."
  @spec prepare(keyword()) :: {:ok, lease()} | {:error, :busy}
  def prepare(opts \\ []) when is_list(opts) do
    GenServer.call(server(opts), :prepare)
  end

  @doc "Commits the prepared drain by running the daemon shutdown path."
  @spec commit(String.t(), keyword()) ::
          {:ok, %{lease_id: String.t(), status: :committed}} | {:error, lease_error()}
  def commit(lease_id, opts \\ []) when is_binary(lease_id) and is_list(opts) do
    GenServer.call(server(opts), {:release, lease_id, :committed})
  end

  @doc "Releases the prepared drain with the daemon untouched."
  @spec cancel(String.t(), keyword()) ::
          {:ok, %{lease_id: String.t(), status: :cancelled}} | {:error, lease_error()}
  def cancel(lease_id, opts \\ []) when is_binary(lease_id) and is_list(opts) do
    GenServer.call(server(opts), {:release, lease_id, :cancelled})
  end

  @doc "Whether a drain window is currently open."
  @spec prepared?(keyword()) :: boolean()
  def prepared?(opts \\ []) when is_list(opts) do
    GenServer.call(server(opts), :prepared?)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       lease: nil,
       elapsed: [],
       lease_ttl_ms: Keyword.get(opts, :lease_ttl_ms, @default_lease_ttl_ms),
       shutdown: Keyword.get(opts, :shutdown, default_stopper())
     }}
  end

  @impl true
  def handle_call(:prepared?, _from, state), do: {:reply, state.lease != nil, state}

  def handle_call(:prepare, _from, %{lease: nil} = state) do
    lease_id = mint_lease_id()
    timer = Process.send_after(self(), {:lease_expired, lease_id}, state.lease_ttl_ms)

    Logger.info(
      "Management lifecycle drain prepared: lease=#{lease_id} ttl_ms=#{state.lease_ttl_ms}"
    )

    lease = %{lease_id: lease_id, ttl_ms: state.lease_ttl_ms, timer: timer}
    {:reply, {:ok, public_lease(lease)}, %{state | lease: lease}}
  end

  def handle_call(:prepare, _from, state), do: {:reply, {:error, :busy}, state}

  def handle_call({:release, lease_id, outcome}, _from, state) do
    case state.lease do
      %{lease_id: ^lease_id} = lease -> release(state, lease, outcome)
      _other -> {:reply, {:error, unheld_reason(state, lease_id)}, state}
    end
  end

  @impl true
  def handle_info({:lease_expired, lease_id}, %{lease: %{lease_id: lease_id}} = state) do
    Logger.info("Management lifecycle drain lease expired, daemon resumed: lease=#{lease_id}")
    {:noreply, %{state | lease: nil, elapsed: remember(state.elapsed, lease_id)}}
  end

  def handle_info({:lease_expired, _stale_lease_id}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  The daemon's one stop path: answer the pending request, then stop the VM.

  Both routes that can stop this daemon default to it — a committed lifecycle
  lease and the v0 `shutdown` control method — so `fermix stop` and the app's
  drain transaction are the same code, not two implementations that can drift
  apart on how (or whether) the VM actually exits.
  """
  @spec stop_daemon() :: :ok
  def stop_daemon do
    spawn(fn ->
      Process.sleep(@shutdown_delay_ms)
      :init.stop()
    end)

    :ok
  end

  @doc "The shared default stopper, so every stop call site can name one function."
  @spec default_stopper() :: (-> :ok)
  def default_stopper, do: &__MODULE__.stop_daemon/0

  defp release(state, lease, outcome) do
    Process.cancel_timer(lease.timer)
    :ok = run_outcome(state, lease, outcome)
    reply = {:ok, %{lease_id: lease.lease_id, status: outcome}}
    {:reply, reply, %{state | lease: nil}}
  end

  # A committed lease shuts the daemon down; a cancelled one leaves it serving.
  # Neither is remembered: the id is consumed, so replaying it is `unknown_lease`
  # and never a second shutdown.
  defp run_outcome(state, lease, :committed) do
    Logger.info("Management lifecycle drain committed: lease=#{lease.lease_id}")
    state.shutdown.()
    :ok
  end

  defp run_outcome(_state, lease, :cancelled) do
    Logger.info("Management lifecycle drain cancelled: lease=#{lease.lease_id}")
    :ok
  end

  defp unheld_reason(state, lease_id) do
    if lease_id in state.elapsed, do: :lease_expired, else: :unknown_lease
  end

  defp remember(elapsed, lease_id) do
    Enum.take([lease_id | elapsed], @max_remembered_leases)
  end

  defp public_lease(lease), do: Map.take(lease, [:lease_id, :ttl_ms])

  defp mint_lease_id do
    "lease_" <> Base.url_encode64(:crypto.strong_rand_bytes(@lease_id_bytes), padding: false)
  end

  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)
end
