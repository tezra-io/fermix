defmodule FermixCore.Trips.DayTurn do
  @moduledoc """
  The trips index again at a day's turn (M89 D14). The picker order
  (`Trips.Picker`) moves with the date alone when a trip starts or ends at a
  local midnight, in its zone or the home's, and this process sends the index
  again to every connection that pulled it, by the path any change takes
  (`Kept.Notify.index_moved/3`), within minutes of that midnight, when the
  order or a trip's `past` moved. Primary-only, in `FermixCore.Supervisor`'s
  tree after the trip placer: it reads memory.db.

  It reads the index the owner's devices draw (`Trips.Registry.names/2` for
  the device's owner, `Kept.Access.device_context/0`) at the wall clock's
  now, and keeps what it last sent or kept as the trips' ids in order with
  their `past`, and the next instant any trip's status changes
  (`Trips.Picker.next_change/3`, the turn). It reads:

    * **when its one timer fires**, and sends when the read differs from the
      one kept. The timer is armed one second past the turn, never less than
      1 s and never more than 10 min ahead: it runs on the BEAM's monotonic
      clock, which stops while a Mac sleeps, so a timer armed for a turn
      hours away would fire hours late after a night's sleep. However long
      it slept, a wake comes within 10 min of waking and compares the index
      the wall clock gives;
    * **on every committed change to a trip** (`trips_changed/1`, which the
      Registry casts after it tells the devices), and keeps what it read
      without sending, the change's own push carrying the new order; but
      when the turn has passed by the time it reads, it compares and sends
      as the timer does, since the devices' window may have read before the
      turn;
    * **at boot**, and sends: it cannot know what a connection was last sent,
      and a restart (a crash of any child before it under `:rest_for_one`)
      must not swallow a turn that passed while it was down. So a restart
      costs one push of an unchanged index to the connections that pulled
      it; at the daemon's own boot no connection has pulled yet. After a
      boot whose read failed, the first read that succeeds sends.

  A read that fails is logged when the failures start and when a read
  succeeds again, never one by one; what it kept stays, and the timer is
  armed 10 min on.

  It serves no call, so a slow store holds up only its own reads, and it
  raises on nothing it is sent: an exit from the store is a read that failed,
  and an unexpected message is logged once each ("Cascade roots": a crash
  of it would restart every child after it).

  Seams: `:name`, `:repo`, `:clock` (0-arity, the wall clock),
  `:personalization` (the home's zone, as `FermixCore.Clock` reads it),
  `:notifier` (`Kept.Notify`'s) and `:timer` (2-arity, given the message and
  the delay, answering a reference, in place of `Process.send_after/3` to
  this process).
  """

  use GenServer

  require Logger

  alias FermixCore.Clock
  alias FermixCore.Kept.Access, as: KeptAccess
  alias FermixCore.Kept.Notify, as: KeptNotify
  alias FermixCore.Memory.Repo
  alias FermixCore.Timeouts
  alias FermixCore.Trips.Picker
  alias FermixCore.Trips.Registry

  @margin_ms 1_000
  @min_wake_ms 1_000
  @max_wake_ms 10 * 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  A trip changed and its devices were told: read the index again and arm
  for its next turn. One that does not run (a device, a test tree) hears
  nothing.
  """
  @spec trips_changed(GenServer.server()) :: :ok
  def trips_changed(server \\ __MODULE__), do: GenServer.cast(server, :changed)

  @impl true
  def init(opts) do
    state = %{
      registry_opts:
        [repo: Keyword.get(opts, :repo, Repo), on_timeout: :error, timeout: Timeouts.repo_call()] ++
          Keyword.take(opts, [:personalization]),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      notify_opts: Keyword.take(opts, [:notifier]),
      timer: Keyword.get(opts, :timer, &send_after/2),
      shown: nil,
      turn_at: nil,
      failing?: false,
      wake: nil
    }

    true = is_function(state.clock, 0) and is_function(state.timer, 2)
    {:ok, state, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state), do: {:noreply, look(state, :boot)}

  @impl true
  def handle_cast(:changed, state), do: {:noreply, look(state, :change)}

  @impl true
  def handle_info({:wake, token}, %{wake: %{token: token}} = state),
    do: {:noreply, look(%{state | wake: nil}, :wake)}

  # A wake replaced by a later look: nothing to do.
  def handle_info({:wake, _token}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Logger.warning(
      "trips: the day-turn of the owner's trips was sent #{inspect(message, limit: 5)}, " <>
        "which it ignores"
    )

    {:noreply, state}
  end

  # -- one look ------------------------------------------------------------------

  # Reads the index at the clock's now, sends it when the read compares and
  # it moved (moduledoc), and arms the next wake.
  defp look(state, trigger) do
    now = state.clock.()

    case read(state, now) do
      {:ok, trips} ->
        shown = Enum.map(trips, &{&1.id, &1.past})
        :ok = maybe_send(state, compares?(trigger, state.turn_at, now), shown)
        turn_at = Picker.next_change(trips, now, home_zone(state))
        arm(%{recovered(state) | shown: shown, turn_at: turn_at}, delay_until(turn_at, now))

      {:error, reason} ->
        arm(failed(state, reason), @max_wake_ms)
    end
  end

  # A boot's read and a wake's compare; a change's keeps, unless the turn it
  # kept has passed.
  defp compares?(:change, nil, _now), do: false
  defp compares?(:change, turn_at, now), do: DateTime.compare(now, turn_at) != :lt
  defp compares?(trigger, _turn_at, _now) when trigger in [:boot, :wake], do: true

  defp read(state, now) do
    opts = Keyword.put(state.registry_opts, :now, now)

    case Registry.names(KeptAccess.device_context(), opts) do
      {:ok, trips} -> {:ok, trips}
      {:error, :disabled} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # A read that compares sends what differs from what was kept, and nothing
  # kept (a boot) differs from every read. A notifier that answers anything
  # but :ok is logged, never raised on.
  defp maybe_send(%{shown: shown} = state, true, now_shown) when shown != now_shown do
    owner = KeptAccess.device_context().memory_owner_id

    case KeptNotify.index_moved(:trips, owner, state.notify_opts) do
      :ok ->
        :ok

      other ->
        Logger.error(
          "trips: the devices could not be told the trips index moved: " <>
            inspect(other, limit: 5)
        )
    end
  end

  defp maybe_send(_state, _compares?, _shown), do: :ok

  defp home_zone(state),
    do: Clock.shown_zone(Keyword.take(state.registry_opts, [:personalization]))

  # One second past the turn, so the clock already reads the new day; within
  # [1 s, 10 min], the cap when nothing will change.
  defp delay_until(nil, _now), do: @max_wake_ms

  defp delay_until(at, now) do
    (DateTime.diff(at, now, :millisecond) + @margin_ms)
    |> max(@min_wake_ms)
    |> min(@max_wake_ms)
  end

  defp failed(%{failing?: true} = state, _reason), do: state

  defp failed(state, reason) do
    Logger.error(
      "trips: the trips index could not be read for a day's turn (#{inspect(reason, limit: 5)}); " <>
        "it is read again in #{div(@max_wake_ms, 60_000)} min and at the next change"
    )

    %{state | failing?: true}
  end

  defp recovered(%{failing?: false} = state), do: state

  defp recovered(state) do
    Logger.warning("trips: the trips index is read again for a day's turn")
    %{state | failing?: false}
  end

  # -- the one timer -------------------------------------------------------------

  defp arm(state, delay_ms) do
    state = cancel_wake(state)
    token = make_ref()

    %{
      state
      | wake: %{token: token, ref: state.timer.({:wake, token}, delay_ms), delay_ms: delay_ms}
    }
  end

  defp cancel_wake(%{wake: nil} = state), do: state

  defp cancel_wake(%{wake: %{ref: ref}} = state) do
    _cancelled = Process.cancel_timer(ref)
    %{state | wake: nil}
  end

  defp send_after(message, delay), do: Process.send_after(self(), message, delay)
end
