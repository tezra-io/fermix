defmodule FermixCore.OpenLoops.Lifecycle do
  @moduledoc """
  The open-loop state machine and touch ledger (MILESTONE_78 §05, §18), pure.

  Every function takes `now` and the owner's active hours as arguments; nothing
  here reads a clock, the database or configuration. The functions return the
  column changes a write applies, and `Memory.Repo` applies them under its
  `WHERE state IN ('open', 'due', 'asked')` guard, so a closed or expired row is
  unreachable from here as from everywhere.

  A live loop is in one of three phases, read off its own columns:

    * **before** — `next_touch_at` is before the instant the date has passed: a
      before-the-date slot, or a plan standing in for one, is pending;
    * **hand-back** — `next_touch_at` is at or after that instant and no touch
      has happened since: the class's last slot is pending;
    * **spent** — every touch the class allows is used, or the hand-back has
      been delivered: `next_touch_at` is the end of the owner's day to answer,
      and the loop expires when it arrives.

  Touches only advance through `after_touch/4`: a recorded rung 1 raise or a
  confirmed rung 2 send.
  """

  alias FermixCore.OpenLoops.ActiveHours
  alias FermixCore.OpenLoops.Defaults

  @live ~w(open due asked)
  @max_touches Defaults.max_touches()
  @closing_answers %{"done" => "done", "stop" => "stop", "drop" => "dropped"}
  @quiet_outcomes ~w(silent empty)
  @failed_outcomes ~w(delivery_failed timeout error)

  @type loop :: map()
  @type hours :: ActiveHours.hours()
  @type changes :: %{optional(atom()) => term()}
  @type due_decision :: :not_yet | :due | {:skip_to_handback, DateTime.t()} | :expire

  # --- slots ---------------------------------------------------------------

  @doc """
  The time of slot `index` of the loop's class, `:past` when that time is not
  after `now` (or, for an imminent loop, when it would not come before its
  date), `:none` when the class has no such slot.
  """
  @spec slot_time(loop(), non_neg_integer(), hours(), DateTime.t()) ::
          {:ok, DateTime.t()} | :past | :none
  def slot_time(loop, index, hours, %DateTime{} = now)
      when is_map(loop) and is_integer(index) and index >= 0 do
    case Enum.at(Defaults.slots(loop.horizon_class), index) do
      nil -> :none
      slot -> slot_at(slot, loop, hours, now)
    end
  end

  defp slot_at({:after_hours, hours_after}, loop, _hours, now) do
    at = DateTime.add(now, hours_after * 3_600, :second)
    if before_date?(at, loop), do: {:ok, at}, else: :past
  end

  defp slot_at({:before_hours_min, hours_before}, loop, hours, now) do
    at = ActiveHours.next_start(hours, now, loop.timezone)
    latest = DateTime.add(loop.matters_by_at, -hours_before * 3_600, :second)
    if DateTime.compare(at, latest) == :gt, do: :past, else: {:ok, at}
  end

  defp slot_at({:days_before, days}, loop, hours, now),
    do:
      future(
        ActiveHours.start_on(hours, Date.add(loop.matters_by_date, -days), loop.timezone),
        now
      )

  defp slot_at({:days_after, days}, loop, hours, now),
    do:
      future(
        ActiveHours.start_on(hours, Date.add(loop.matters_by_date, days), loop.timezone),
        now
      )

  defp future(at, now), do: if(DateTime.compare(at, now) == :gt, do: {:ok, at}, else: :past)

  @doc """
  The first `next_touch_at` of a new loop: its class's first slot (three hours
  on for an imminent one). An imminent loop whose date passes before then has
  no window.
  """
  @spec first_touch_at(loop(), hours(), DateTime.t()) ::
          {:ok, DateTime.t()} | {:error, :imminent_without_window}
  def first_touch_at(loop, hours, %DateTime{} = now) when is_map(loop) do
    case slot_time(loop, 0, hours, now) do
      {:ok, at} -> {:ok, at}
      _past_or_none -> {:error, :imminent_without_window}
    end
  end

  # --- the due scan ----------------------------------------------------------

  @doc """
  What the due scan does with one live row at `now` (§18 due scan).

  An open or asked row whose touch has arrived becomes `:due`, unless its
  pending slot is a before-the-date slot whose date has passed: then a row
  asked at least once skips to the hand-back (`{:skip_to_handback, at}`) and
  one never asked, or of class imminent, expires. A spent row expires when its
  answer day ends, and a hand-back not delivered within a day of its slot
  expires. A claimed row is left to its check-in.

  The skip's time is the hand-back date at the default active-hours start: the
  scan runs inside the single writer, which cannot resolve the owner's derived
  hours, and a rung 2 claim still waits for the owner's own window.
  """
  @spec due_decision(loop(), DateTime.t()) :: due_decision()
  def due_decision(%{state: state} = loop, %DateTime{} = now) when state in @live do
    cond do
      not is_nil(loop.claimed_at) -> :not_yet
      DateTime.compare(loop.next_touch_at, now) == :gt -> :not_yet
      true -> arrived(loop, phase(loop), now)
    end
  end

  defp arrived(_loop, :spent, _now), do: :expire

  defp arrived(loop, :before, now) do
    cond do
      before_date?(now, loop) -> become_due(loop)
      loop.horizon_class == "imminent" or loop.touches == 0 -> :expire
      true -> {:skip_to_handback, default_handback_at(loop)}
    end
  end

  defp arrived(loop, :handback, now) do
    cond do
      loop.horizon_class == "imminent" -> :expire
      grace_spent?(loop, now) -> :expire
      true -> become_due(loop)
    end
  end

  defp become_due(%{state: "due"}), do: :not_yet
  defp become_due(_loop), do: :due

  defp default_handback_at(loop) do
    {start, finish} = Defaults.active_hours_default()
    hours = %{start: start, finish: finish}
    {:days_after, days} = loop.horizon_class |> Defaults.slots() |> List.last()
    ActiveHours.start_on(hours, Date.add(loop.matters_by_date, days), loop.timezone)
  end

  defp grace_spent?(loop, now) do
    DateTime.compare(now, later(loop.next_touch_at, Defaults.expiry_grace_ms())) !=
      :lt
  end

  # --- rung 2 ----------------------------------------------------------------

  @doc """
  Whether a due loop may have its unprompted check-in now (§18 rung 2 claim),
  given whether the owner's day's budget is already spent. Claimability and the
  supervisor's capacity are the caller's.
  """
  @spec rung2_eligible?(loop(), DateTime.t(), hours(), boolean()) ::
          true | {:skip, :window_open | :imminent | :active_hours | :budget}
  def rung2_eligible?(%{state: "due"} = loop, %DateTime{} = now, hours, budget_spent?)
      when is_boolean(budget_spent?) do
    cond do
      loop.horizon_class == "imminent" -> {:skip, :imminent}
      DateTime.compare(now, window_close(loop)) == :lt -> {:skip, :window_open}
      not ActiveHours.inside?(hours, now, loop.timezone) -> {:skip, :active_hours}
      budget_spent? -> {:skip, :budget}
      true -> true
    end
  end

  defp window_close(loop),
    do: later(loop.next_touch_at, Defaults.rung1_window_ms())

  # --- the touch ledger --------------------------------------------------------

  @doc """
  A recorded rung 1 raise or a confirmed rung 2 send: one more touch, the loop
  asked, and the following slot armed. A touch after the date is the hand-back,
  and arms the end of the owner's day to answer.
  """
  @spec after_touch(loop(), 1 | 2, DateTime.t(), hours()) :: changes()
  def after_touch(%{state: state, touches: touches} = loop, rung, %DateTime{} = now, hours)
      when state in @live and rung in [1, 2] and touches < @max_touches do
    count = touches + 1

    %{
      touches: count,
      state: "asked",
      next_touch_at: following_touch(loop, count, now, hours),
      last_touch_at: now,
      last_touch_rung: rung
    }
  end

  defp following_touch(loop, count, now, hours) do
    if before_date?(now, loop),
      do: next_future_slot(loop, count, hours, now, &answer_day_end/1),
      else: answer_day_end(now)
  end

  defp answer_day_end(now), do: later(now, Defaults.expiry_grace_ms())

  # The first slot from `index` on whose time is still ahead. Slot times rise
  # with the index, so a slot already behind `now` was consumed or skipped.
  defp next_future_slot(loop, index, hours, now, otherwise) do
    case slot_time(loop, index, hours, now) do
      {:ok, at} -> at
      :past -> next_future_slot(loop, index + 1, hours, now, otherwise)
      :none -> otherwise.(now)
    end
  end

  # --- the owner's answer ------------------------------------------------------

  @doc """
  The changes an owner's answer makes (§18 answers). `done`, `stop` and `drop`
  close the loop; `plan` re-arms it at `plan_at` and no earlier, never later
  than the loop's own date; `not_yet` keeps it open for one more touch nearer
  the date; `asked` records a rung 1 raise and is refused on an asked row or
  once the touches are spent. Every answer is accepted on every live state.
  """
  @spec after_answer(loop(), String.t(), DateTime.t() | nil, DateTime.t(), hours()) ::
          {:ok, changes()} | {:error, atom()}
  def after_answer(%{state: state} = loop, answer, plan_at, %DateTime{} = now, hours)
      when state in @live and is_binary(answer) do
    cond do
      answer != "plan" and not is_nil(plan_at) -> {:error, :plan_at_without_plan}
      Map.has_key?(@closing_answers, answer) -> {:ok, close(answer, now)}
      answer == "plan" -> plan(loop, plan_at, now)
      answer == "not_yet" -> {:ok, not_yet(loop, now, hours)}
      answer == "asked" -> asked(loop, now, hours)
      true -> {:error, {:invalid_answer, answer}}
    end
  end

  defp close(answer, now) do
    %{
      state: "closed",
      close_reason: Map.fetch!(@closing_answers, answer),
      closed_at: now,
      next_touch_at: nil,
      last_answer: answer
    }
  end

  defp plan(_loop, nil, _now), do: {:error, :plan_requires_date}

  defp plan(loop, %DateTime{} = plan_at, now) do
    cond do
      DateTime.compare(plan_at, loop.matters_by_at) == :gt ->
        {:error, :plan_after_date}

      DateTime.compare(plan_at, now) != :gt ->
        {:error, :plan_passed}

      true ->
        {:ok, %{state: "open", last_answer: "plan", plan_at: plan_at, next_touch_at: plan_at}}
    end
  end

  defp not_yet(loop, now, hours) do
    next =
      case phase(loop) do
        :spent -> loop.next_touch_at
        _pending -> next_future_slot(loop, loop.touches, hours, now, &answer_day_end/1)
      end

    %{state: "open", last_answer: "not_yet", next_touch_at: next}
  end

  defp asked(%{state: "asked"}, _now, _hours), do: {:error, :already_asked}

  defp asked(loop, now, hours) do
    if phase(loop) == :spent or loop.touches >= @max_touches,
      do: {:error, :already_asked},
      else: {:ok, after_touch(loop, 1, now, hours)}
  end

  # --- a check-in that did not speak ---------------------------------------------

  @doc """
  The changes a check-in's outcome makes when it sent nothing (§18 touch
  ledger). `silent` and `empty` advance to the following slot; `delivery_failed`,
  `timeout` and `error` retry at the next active-hours start, never sooner than
  the five-second floor (before the date that retry repeats daily until the
  date passes; the hand-back retries once); `closed` settles the loop as
  reported elsewhere. A loop that runs out of slots this way expires: a
  hand-back that does not speak, or a before-the-date slot of a loop never asked
  whose next slot would be the hand-back. None of them touches the ledger; a
  spoken message is `after_touch/4`.
  """
  @spec after_outcome(loop(), String.t(), DateTime.t(), hours()) :: changes()
  def after_outcome(%{state: state} = loop, outcome, %DateTime{} = now, hours)
      when state in @live and outcome in @quiet_outcomes do
    loop |> advance(now, hours) |> Map.merge(outcome_fields(outcome, now))
  end

  def after_outcome(%{state: state} = loop, outcome, %DateTime{} = now, hours)
      when state in @live and outcome in @failed_outcomes do
    loop |> retry(now, hours) |> Map.merge(outcome_fields(outcome, now))
  end

  def after_outcome(%{state: state}, "closed", %DateTime{} = now, _hours) when state in @live do
    %{
      state: "closed",
      close_reason: "reported_elsewhere",
      closed_at: now,
      next_touch_at: nil
    }
    |> Map.merge(outcome_fields("closed", now))
  end

  defp outcome_fields(outcome, now), do: %{last_outcome: outcome, last_outcome_at: now}

  defp advance(loop, now, hours) do
    case phase(loop) do
      :before -> arm_or_expire(loop, slot_after(loop, loop.touches + 1, hours, now), hours, now)
      _handback_or_spent -> expired(now)
    end
  end

  defp slot_after(loop, index, hours, now),
    do: next_future_slot(loop, index, hours, now, fn _now -> nil end)

  defp retry(loop, now, hours) do
    case phase(loop) do
      :before -> arm_or_expire(loop, retry_at(loop, now, hours), hours, now)
      :handback -> retry_handback(loop, now, hours)
      :spent -> expired(now)
    end
  end

  defp retry_handback(loop, now, hours) do
    if handback_failed_before?(loop),
      do: expired(now),
      else: %{state: "open", next_touch_at: retry_at(loop, now, hours)}
  end

  # Every hand-back attempt runs after the date and every earlier attempt before
  # it, so a failure recorded after the date is this hand-back's first.
  defp handback_failed_before?(
         %{last_outcome: outcome, last_outcome_at: %DateTime{} = at} = loop
       ),
       do: outcome in @failed_outcomes and not before_date?(at, loop)

  defp handback_failed_before?(_loop), do: false

  defp retry_at(loop, now, hours) do
    floor = later(now, Defaults.fault_floor_ms())
    start = ActiveHours.next_start(hours, now, loop.timezone)
    if DateTime.compare(start, floor) == :lt, do: floor, else: start
  end

  # Before the date the next time is armed, unless it would land on or after
  # the date: then a loop asked at least once goes to its hand-back, no earlier
  # than the hand-back slot, and one never asked expires, as the due scan
  # treats a passed slot.
  defp arm_or_expire(_loop, nil, _hours, now), do: expired(now)

  defp arm_or_expire(loop, at, hours, now) do
    cond do
      before_date?(at, loop) -> %{state: "open", next_touch_at: at}
      loop.touches == 0 or loop.horizon_class == "imminent" -> expired(now)
      true -> %{state: "open", next_touch_at: not_before_handback(loop, at, hours, now)}
    end
  end

  defp not_before_handback(loop, at, hours, now) do
    last = length(Defaults.slots(loop.horizon_class)) - 1

    case slot_time(loop, last, hours, now) do
      {:ok, slot} -> if DateTime.compare(slot, at) == :gt, do: slot, else: at
      :past -> at
    end
  end

  defp expired(now) do
    %{state: "expired", close_reason: "expired", closed_at: now, next_touch_at: nil}
  end

  # --- the scheduler's timer -------------------------------------------------------

  @doc """
  The earliest moment after `now` at which the due scan or a rung 2 claim could
  change this loop, or nil. An open or asked loop wakes at `next_touch_at`. A
  due loop wakes when its rung 1 window closes, and again when its pending slot
  lapses: the date passing for a before-the-date slot, the day of grace ending
  for a hand-back. Waiting for active hours or the next day's budget is the
  caller's, which holds the owner's hours. A claimed or terminal loop has none.
  """
  @spec next_wake(loop(), DateTime.t()) :: DateTime.t() | nil
  def next_wake(%{state: state, next_touch_at: %DateTime{} = at}, _now)
      when state in ["open", "asked"],
      do: at

  def next_wake(%{state: "due", claimed_at: nil} = loop, %DateTime{} = now) do
    [due_window_close(loop), lapse(loop, phase(loop))]
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&(DateTime.compare(&1, now) == :gt))
    |> Enum.min(DateTime, fn -> nil end)
  end

  def next_wake(_loop, _now), do: nil

  defp due_window_close(%{horizon_class: "imminent"}), do: nil
  defp due_window_close(loop), do: window_close(loop)

  defp lapse(loop, :before), do: loop.matters_by_at
  defp lapse(%{horizon_class: "imminent"} = loop, _phase), do: loop.matters_by_at

  defp lapse(loop, :handback),
    do: later(loop.next_touch_at, Defaults.expiry_grace_ms())

  defp lapse(loop, :spent), do: loop.next_touch_at

  @doc """
  Whether the touch now pending is the loop's last: the hand-back, or the last
  touch its class allows. The check-in says plainly that it won't raise the
  loop again.
  """
  @spec final_touch?(loop()) :: boolean()
  def final_touch?(loop) when is_map(loop) do
    phase(loop) != :before or loop.touches + 1 >= length(Defaults.slots(loop.horizon_class))
  end

  # --- phases ------------------------------------------------------------------------

  defp phase(loop) do
    cond do
      loop.touches >= length(Defaults.slots(loop.horizon_class)) -> :spent
      before_date?(loop.next_touch_at, loop) -> :before
      touched_after_date?(loop) -> :spent
      true -> :handback
    end
  end

  defp touched_after_date?(%{last_touch_at: %DateTime{} = at} = loop),
    do: not before_date?(at, loop)

  defp touched_after_date?(_loop), do: false

  defp before_date?(%DateTime{} = at, loop), do: DateTime.compare(at, loop.matters_by_at) == :lt

  # Every duration in `Defaults` is whole seconds; adding seconds keeps the
  # instant's own precision, which a millisecond add would change.
  defp later(%DateTime{} = at, ms) when rem(ms, 1_000) == 0,
    do: DateTime.add(at, div(ms, 1_000), :second)
end
