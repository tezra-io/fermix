defmodule FermixCore.ComputerUse.InputOwner do
  @moduledoc """
  The one native input owner across conversations (M42 slice 2 §6).

  There is exactly one cursor, one keyboard and one focused window on the machine.
  Two conversations driving them at once is not concurrency: each moves the pointer
  the other just aimed, and each reads a screen the other is changing, so both
  conclude their clicks missed and repeat them. The per-conversation
  `ComputerUse.Session` serialises a conversation's own actions; this serialises
  the machine's.

  **Taken, not queued.** `acquire/2` answers `:ok` or `{:error, :input_busy}` and
  there is no waiting line. A click that lands minutes later, on a screen that has
  moved on, is worse than a refusal the model can act on — and a queue would make
  the seat's holder responsible for latency it cannot see.

  **Lapse, not a lease.** The holder keeps the seat across its own actions (a task
  is a sequence, not one click), but a conversation that went quiet cannot hold it
  against another forever, so ownership lapses once its holder has dispatched
  nothing for `#{60_000} ms`. That is long enough for the slowest link in an
  ongoing task — one model round trip carrying a screenshot, which is seconds to
  tens of seconds — and twice the 30 s budget of a single sidecar action, so a slow
  action plus the turn that follows it never loses the seat mid-task. It is short
  enough that a human who switched conversations waits at most a minute. Evaluated
  when the seat is contended rather than on a timer: an uncontended seat has
  nothing to lapse for, and a timer would be state that can disagree with the clock.

  Which actions need it is `Courtesy.disturbing?/1` — everything that moves the
  cursor or types, `mouse_move` included. Read-only actions never take the seat:
  two conversations may look at the same screen all they like.

  Not running (computer-use disabled, so no CU tree) means there is no second
  conversation to arbitrate against, so `acquire/2` grants — the same shape
  `CaptureHealth.status/0` uses for the same reason.
  """

  use GenServer

  require Logger

  # An owner-review item: see the moduledoc for the derivation.
  @idle_lapse_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Take (or keep) the native input seat for `owner`. `:ok` when `owner` now holds
  it, `{:error, :input_busy}` when another live conversation does and has not gone
  idle for long enough to lose it, and `{:error, :input_unavailable}` when who
  holds it cannot be established at all.
  """
  @spec acquire(pid(), GenServer.server()) ::
          :ok | {:error, :input_busy} | {:error, :input_unavailable}
  def acquire(owner, server \\ __MODULE__) when is_pid(owner) do
    GenServer.call(server, {:acquire, owner})
  catch
    # NOT RUNNING is a grant: no CU tree means there is no second conversation to
    # arbitrate against, the same backstop shape `CaptureHealth` uses when
    # computer-use is off. Anything else — a call that timed out, an arbiter that
    # died mid-call — leaves ownership UNKNOWN, and granting on an unknown is
    # precisely the failure this module exists to prevent. It fails closed.
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] ->
      :ok

    :exit, reason ->
      Logger.warning("computer_use: the input owner did not answer (#{inspect(reason)})")
      {:error, :input_unavailable}
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       owner: nil,
       monitor: nil,
       last_at: nil,
       idle_lapse_ms: Keyword.get(opts, :idle_lapse_ms, @idle_lapse_ms)
     }}
  end

  @impl true
  def handle_call({:acquire, owner}, _from, state) do
    if available?(state, owner),
      do: {:reply, :ok, grant(state, owner)},
      else: {:reply, {:error, :input_busy}, state}
  end

  # The holder died — a session is `:temporary` and dies on a poison reset, an
  # abort, or the end of its conversation. Without this the seat is held by a
  # corpse and no other conversation can ever act.
  @impl true
  def handle_info({:DOWN, monitor, :process, owner, _reason}, %{monitor: monitor} = state) do
    Logger.debug("computer_use: native input seat released by #{inspect(owner)}")
    {:noreply, %{state | owner: nil, monitor: nil, last_at: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp available?(%{owner: nil}, _owner), do: true
  defp available?(%{owner: owner}, owner), do: true

  defp available?(%{last_at: last_at, idle_lapse_ms: lapse}, _owner),
    do: now_ms() - last_at >= lapse

  defp grant(%{owner: owner} = state, owner), do: %{state | last_at: now_ms()}

  defp grant(state, owner) do
    if state.monitor, do: Process.demonitor(state.monitor, [:flush])
    %{state | owner: owner, monitor: Process.monitor(owner), last_at: now_ms()}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
