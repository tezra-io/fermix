defmodule FermixCore.OpenLoops.Lifecycle do
  @moduledoc """
  The open-loop state machine and touch ledger (MILESTONE_78 §05, §18;
  MILESTONE_83 §05, §11), pure.

  Every function takes `now` and the owner's active hours as arguments; nothing
  here reads a clock, the database or configuration. The functions return the
  column changes a write applies, and `Memory.Repo` applies them under its
  `WHERE state IN ('open', 'due', 'asked')` guard, so a closed or expired row is
  unreachable from here as from everywhere.

  `matters_by_at` is the loop's anchor: for something to do (a dated class,
  `long` to `imminent`) the instant its date has passed, for something waited
  on or gone through (class `after`) the instant asking first feels natural.
  The slot table follows the class and the reach (`Defaults.slots/2`): a loop
  kept for conversation is never raised by message, so it has no hand-back
  and never a rung 2 check-in.

  A live dated loop is in one of three phases, read off its own columns:

    * **before** — `next_touch_at` is before the instant the date has passed: a
      before-the-date slot, or a plan standing in for one, is pending;
    * **hand-back** — `next_touch_at` is at or after that instant and no touch
      has happened since: the class's last slot is pending. A loop with no
      hand-back is resting here instead, and expires when it arrives;
    * **spent** — every touch the class allows is used, or the hand-back has
      been delivered: `next_touch_at` is the end of the owner's day to answer,
      and the loop expires when it arrives.

  A live `after` loop is **armed** while a touch is pending (its anchor's, or a
  second one a plan or a not-yet with a new `ask_after` armed) and **spent**
  while it waits for the owner's answer to a touch, or once both touches are
  used. It has no hand-back.

  When the scan marks a loop due it writes `rung1_until`, the close of its
  rung 1 window (`due_decision/2`). A conversation loop's window that closes
  unraised takes the quiet path: the next window of the same touch, or expiry.

  Touches only advance through `after_touch/4`: a recorded rung 1 raise or a
  confirmed rung 2 send.
  """

  alias FermixCore.OpenLoops.ActiveHours
  alias FermixCore.OpenLoops.Defaults

  @live ~w(open due asked)
  @max_touches Defaults.max_touches()
  @after_max_touches Defaults.after_max_touches()
  @reaches Defaults.reaches()
  @closing_answers %{"done" => "done", "stop" => "stop", "drop" => "dropped"}
  @quiet_outcomes ~w(silent empty)
  @failed_outcomes ~w(delivery_failed timeout error)
  # A check-in that judged now the wrong moment waits as a failed run does, and
  # it counts as that touch's one retry.
  @retry_outcomes ["later" | @failed_outcomes]
  # Each answer argument and the one answer it goes with.
  @argument_answers %{plan_at: "plan", ask_after: "not_yet", anchor: "moved", reach: "reach"}

  @type loop :: map()
  @type hours :: ActiveHours.hours()
  @type changes :: %{optional(atom()) => term()}
  @type due_decision ::
          :not_yet
          | {:due, DateTime.t()}
          | {:lapse, DateTime.t(), DateTime.t()}
          | {:skip_to_handback, DateTime.t()}
          | :expire

  @typedoc """
  An answer's argument, resolved by the caller: `plan_at` with `plan`,
  `ask_after` with `not_yet` on an `after` loop, `anchor` (the new date's
  `matters_by_kind`, `matters_by_date`, `matters_by_time`, `matters_by_at` and
  `matters_by_source`) with `moved`, `reach` with `reach`.
  """
  @type answer_args :: %{
          optional(:plan_at) => DateTime.t() | nil,
          optional(:ask_after) => DateTime.t() | nil,
          optional(:anchor) => map() | nil,
          optional(:reach) => String.t() | nil
        }

  # --- slots ---------------------------------------------------------------

  @doc """
  The time of slot `index` of the loop's table, `:past` when that time is not
  after `now` (or, for an imminent loop, when it would not come before its
  date), `:none` when the table has no such slot.
  """
  @spec slot_time(loop(), non_neg_integer(), hours(), DateTime.t()) ::
          {:ok, DateTime.t()} | :past | :none
  def slot_time(loop, index, hours, %DateTime{} = now)
      when is_map(loop) and is_integer(index) and index >= 0 do
    case Enum.at(slots(loop), index) do
      nil -> :none
      slot -> slot_at(slot, loop, hours, now)
    end
  end

  defp slot_at({:at_anchor}, loop, _hours, now), do: future(loop.matters_by_at, now)

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

  defp slots(loop), do: Defaults.slots(loop.horizon_class, loop.reach)
  defp handback?(loop), do: Defaults.handback?(loop.horizon_class, loop.reach)

  @doc """
  The first `next_touch_at` of a new loop: its table's first slot (three hours
  on for an imminent one, the anchor itself for an `after` one). An imminent
  loop whose date passes before then has no window.
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

  An open or asked row whose touch has arrived becomes due, `{:due,
  rung1_until}`, unless its pending slot is a before-the-date slot whose date
  has passed: then a row asked at least once skips to the hand-back
  (`{:skip_to_handback, at}`) and one never asked, one of class imminent, or
  one with no hand-back (kept for conversation) expires. A spent row expires
  when its answer day ends, a hand-back not delivered within a day of its slot
  expires, a resting conversation loop expires when its rest ends, and an
  `after` touch not raised within `Defaults.conversation_window_ms/0` of its
  time expires. A claimed row is left to its check-in.

  A due conversation loop whose window has closed unraised takes the quiet
  path: `{:lapse, next_touch_at, rung1_until}` opens the next window of the
  same touch where the last one closed, and with none left it expires.

  `rung1_until` is three hours on for a loop raised by message (rung 2 follows
  it), the date for an imminent loop, and for a loop kept for conversation the
  next slot's time, the date for the last slot before it, or the touch's time
  plus `Defaults.conversation_window_ms/0` for an `after` loop.

  The skip's time and a conversation window's slot times are read at the
  default active-hours start: the scan runs inside the single writer, which
  cannot resolve the owner's derived hours, and a rung 2 claim still waits
  for the owner's own window.
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

  defp arrived(loop, :armed, now) do
    if touch_lapsed?(loop, now), do: :expire, else: become_due(loop, now)
  end

  defp arrived(loop, :before, now) do
    cond do
      before_date?(now, loop) -> become_due(loop, now)
      loop.horizon_class == "imminent" or loop.touches == 0 or not handback?(loop) -> :expire
      true -> {:skip_to_handback, default_handback_at(loop)}
    end
  end

  defp arrived(loop, :handback, now) do
    cond do
      loop.horizon_class == "imminent" or not handback?(loop) -> :expire
      grace_spent?(loop, now) -> :expire
      true -> become_due(loop, now)
    end
  end

  defp become_due(%{state: "due"} = loop, now) do
    if window_lapsed?(loop, now), do: next_window(loop), else: :not_yet
  end

  defp become_due(loop, now), do: {:due, rung1_until(loop, now)}

  defp touch_lapsed?(loop, now),
    do: DateTime.compare(now, later(loop.next_touch_at, Defaults.conversation_window_ms())) != :lt

  defp window_lapsed?(%{reach: "conversation", rung1_until: %DateTime{} = until}, now),
    do: DateTime.compare(now, until) != :lt

  defp window_lapsed?(_loop, _now), do: false

  # An `after` touch has one window; a dated conversation loop's next window
  # opens where the closed one closed, at a slot before the date.
  defp next_window(%{horizon_class: "after"}), do: :expire

  defp next_window(loop) do
    opened = %{loop | next_touch_at: loop.rung1_until}
    {:lapse, loop.rung1_until, conversation_close(opened)}
  end

  defp rung1_until(%{horizon_class: "imminent"} = loop, _now), do: loop.matters_by_at
  defp rung1_until(%{reach: "message"}, now), do: later(now, Defaults.rung1_window_ms())

  defp rung1_until(%{horizon_class: "after"} = loop, _now),
    do: later(loop.next_touch_at, Defaults.conversation_window_ms())

  defp rung1_until(loop, _now), do: conversation_close(loop)

  # The first slot before the date on a later local day than the pending
  # touch, at the default active-hours start; with none, the date.
  defp conversation_close(loop) do
    pending_day = local_date(loop.next_touch_at, loop.timezone)

    loop
    |> slots()
    |> Enum.flat_map(&slot_day(&1, loop))
    |> Enum.find(&(Date.compare(&1, pending_day) == :gt))
    |> close_on(loop)
  end

  defp slot_day({:days_before, days}, loop), do: [Date.add(loop.matters_by_date, -days)]
  defp slot_day(_slot, _loop), do: []

  defp close_on(nil, loop), do: loop.matters_by_at

  defp close_on(day, loop) do
    at = ActiveHours.start_on(default_hours(), day, loop.timezone)
    if before_date?(at, loop), do: at, else: loop.matters_by_at
  end

  defp default_handback_at(loop) do
    {:days_after, days} = loop |> slots() |> List.last()
    ActiveHours.start_on(default_hours(), Date.add(loop.matters_by_date, days), loop.timezone)
  end

  defp default_hours do
    {start, finish} = Defaults.active_hours_default()
    %{start: start, finish: finish}
  end

  defp grace_spent?(loop, now) do
    DateTime.compare(now, later(loop.next_touch_at, Defaults.expiry_grace_ms())) !=
      :lt
  end

  # --- rung 2 ----------------------------------------------------------------

  @doc """
  Whether a due loop may have its unprompted check-in now (§18 rung 2 claim),
  given whether the owner's day's budget is already spent. An imminent loop
  and a loop kept for conversation never have one. Claimability and the
  supervisor's capacity are the caller's.
  """
  @spec rung2_eligible?(loop(), DateTime.t(), hours(), boolean()) ::
          true
          | {:skip, :window_open | :imminent | :conversation | :active_hours | :budget}
  def rung2_eligible?(%{state: "due"} = loop, %DateTime{} = now, hours, budget_spent?)
      when is_boolean(budget_spent?) do
    cond do
      loop.horizon_class == "imminent" -> {:skip, :imminent}
      loop.reach == "conversation" -> {:skip, :conversation}
      DateTime.compare(now, loop.rung1_until) == :lt -> {:skip, :window_open}
      not ActiveHours.inside?(hours, now, loop.timezone) -> {:skip, :active_hours}
      budget_spent? -> {:skip, :budget}
      true -> true
    end
  end

  # --- the touch ledger --------------------------------------------------------

  @doc """
  A recorded rung 1 raise or a confirmed rung 2 send: one more touch, the loop
  asked, and the following slot armed, always on a later local day than the
  touch, so a loop is never raised twice in a day. A touch after the date is the hand-back,
  and arms the end of the owner's day to answer; so does every touch of an
  `after` loop, whose next touch only an answer arms. A loop with no hand-back
  and no slot left before its date rests until the date has passed and the
  day to answer has ended.
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

  defp following_touch(%{horizon_class: "after"}, _count, now, _hours), do: answer_day_end(now)

  defp following_touch(loop, count, now, hours) do
    if before_date?(now, loop),
      do: next_later_day_slot(loop, count, hours, now, no_slot_left(loop)),
      else: answer_day_end(now)
  end

  # The first slot from `index` on a later local day than the touch at `now`.
  # A conversation loop's window runs to its next slot's day, and a lapse opens
  # the next window at the default start while the slot itself falls at the
  # owner's own, so a touch can land on a slot's day before its time; arming that
  # slot would raise the loop again the same day (OL-3). Slot days rise with
  # the index, so the walk ends at the table's end.
  defp next_later_day_slot(loop, index, hours, now, otherwise) do
    case slot_time(loop, index, hours, now) do
      {:ok, at} ->
        if later_day?(at, now, loop.timezone),
          do: at,
          else: next_later_day_slot(loop, index + 1, hours, now, otherwise)

      :past ->
        next_later_day_slot(loop, index + 1, hours, now, otherwise)

      :none ->
        otherwise.(now)
    end
  end

  defp answer_day_end(now), do: later(now, Defaults.expiry_grace_ms())

  # With no slot left, a loop arms the end of the owner's day to answer. A
  # dated loop whose hand-back its conversation reach dropped can run out of
  # slots before its date with touches still unspent, so it rests until the
  # date has passed as well, and its next arrival is never mistaken for a slot.
  defp no_slot_left(loop) do
    if Defaults.handback?(loop.horizon_class, "message") and not handback?(loop),
      do: &latest(answer_day_end(&1), loop.matters_by_at),
      else: &answer_day_end/1
  end

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
  The changes an owner's answer makes (§18 answers; M83 §10, §11). `done`,
  `stop` and `drop` close the loop; `plan` re-arms it at `plan_at` and no
  earlier, never later than a dated loop's own date and never more than
  `Defaults.ask_after_max_ms/0` out for an `after` loop; `not_yet` keeps a
  dated loop open for one more touch nearer the date, and on an `after` loop
  requires `ask_after` and arms the next touch there; `moved` gives a dated
  loop a new date, re-derives its class, keeps its touches and arms the next
  slot of the new table still ahead, or with none left rests until the new
  date's hand-back, or the date, and expires there; `reach` changes how the loop may be
  raised; `asked` records a rung 1 raise, only on a due row, and is refused on
  an asked row or once the touches are spent. A plan or a not yet on an `after`
  loop whose two touches are used is refused. Every answer is accepted on every live state,
  and an argument given with an answer it does not go with is refused.

  A reach change moves no slot. A due loop's window is recomputed as the scan
  would compute it now, and the new table decides what follows: under
  conversation a pending or resting hand-back expires when it arrives, and no
  rung 2 runs; under message the hand-back is armed again.
  """
  @spec after_answer(loop(), String.t(), answer_args(), DateTime.t(), hours()) ::
          {:ok, changes()} | {:error, term()}
  def after_answer(%{state: state} = loop, answer, args, %DateTime{} = now, hours)
      when state in @live and is_binary(answer) and is_map(args) do
    with :ok <- arguments_fit(answer, args) do
      answer_changes(loop, answer, args, now, hours)
    end
  end

  defp arguments_fit(answer, args) do
    case Enum.find(args, fn {key, value} -> not is_nil(value) and misplaced?(key, answer) end) do
      nil -> :ok
      {key, _value} -> {:error, misplaced(key)}
    end
  end

  defp misplaced?(key, answer), do: Map.fetch!(@argument_answers, key) != answer

  defp misplaced(:plan_at), do: :plan_at_without_plan
  defp misplaced(:ask_after), do: :ask_after_without_not_yet
  defp misplaced(:anchor), do: :matters_by_without_moved
  defp misplaced(:reach), do: :reach_without_reach_answer

  defp answer_changes(_loop, answer, _args, now, _hours)
       when is_map_key(@closing_answers, answer),
       do: {:ok, close(answer, now)}

  defp answer_changes(loop, "plan", args, now, _hours), do: plan(loop, args[:plan_at], now)

  defp answer_changes(loop, "not_yet", args, now, hours),
    do: not_yet(loop, args[:ask_after], now, hours)

  defp answer_changes(loop, "asked", _args, now, hours), do: asked(loop, now, hours)
  defp answer_changes(loop, "moved", args, now, hours), do: moved(loop, args[:anchor], now, hours)
  defp answer_changes(loop, "reach", args, now, _hours), do: reach(loop, args[:reach], now)
  defp answer_changes(_loop, answer, _args, _now, _hours), do: {:error, {:invalid_answer, answer}}

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
    with :ok <- touch_left(loop),
         :ok <- plan_bound(loop, plan_at, now) do
      if DateTime.compare(plan_at, now) == :gt,
        do:
          {:ok,
           rearmed(loop, %{
             state: "open",
             last_answer: "plan",
             plan_at: plan_at,
             next_touch_at: plan_at
           })},
        else: {:error, :plan_passed}
    end
  end

  # An `after` loop whose two touches are used has no touch left to arm: a plan
  # or a new ask_after is refused rather than armed to expire on arrival.
  defp touch_left(%{horizon_class: "after", touches: touches}) when touches >= @after_max_touches,
    do: {:error, :touches_spent}

  defp touch_left(_loop), do: :ok

  # An `after` touch retries once, as a hand-back does: a failure or a later
  # counts against the pending touch when it came after the loop's last touch,
  # or at any time when there is none (`failed_this_touch?/1`). An answer that
  # arms the touch again clears one recorded before it, so the re-armed touch
  # gets its own retry.
  defp rearmed(%{horizon_class: "after", last_outcome: outcome}, changes)
       when outcome in @retry_outcomes,
       do: Map.merge(changes, %{last_outcome: nil, last_outcome_at: nil})

  defp rearmed(_loop, changes), do: changes

  # A dated loop's plan is bounded by its date; an `after` loop has none, so its
  # plan is bounded as an `ask_after` is.
  defp plan_bound(%{horizon_class: "after"}, plan_at, now) do
    if DateTime.compare(plan_at, later(now, Defaults.ask_after_max_ms())) == :gt,
      do: {:error, :plan_too_far},
      else: :ok
  end

  defp plan_bound(loop, plan_at, _now) do
    if DateTime.compare(plan_at, loop.matters_by_at) == :gt,
      do: {:error, :plan_after_date},
      else: :ok
  end

  defp not_yet(%{horizon_class: "after"}, nil, _now, _hours), do: {:error, :ask_after_required}

  defp not_yet(%{horizon_class: "after"} = loop, %DateTime{} = ask_after, _now, _hours) do
    with :ok <- touch_left(loop) do
      {:ok, rearmed(loop, %{state: "open", last_answer: "not_yet", next_touch_at: ask_after})}
    end
  end

  defp not_yet(_dated, %DateTime{}, _now, _hours), do: {:error, :ask_after_on_dated_loop}

  defp not_yet(loop, nil, now, hours) do
    next =
      case phase(loop) do
        :spent -> loop.next_touch_at
        _pending -> next_future_slot(loop, loop.touches, hours, now, no_slot_left(loop))
      end

    {:ok, %{state: "open", last_answer: "not_yet", next_touch_at: next}}
  end

  # A raise is recorded only on a due loop: before its touch arrives the due
  # note never named it, so recording one is the model's error, and the loop
  # comes up on its own.
  defp asked(%{state: "asked"}, _now, _hours), do: {:error, :already_asked}

  defp asked(%{state: "due"} = loop, now, hours) do
    if phase(loop) == :spent or loop.touches >= @max_touches,
      do: {:error, :already_asked},
      else: {:ok, after_touch(loop, 1, now, hours)}
  end

  defp asked(_not_due, _now, _hours), do: {:error, :not_due}

  defp moved(%{horizon_class: "after"}, _anchor, _now, _hours),
    do: {:error, :moved_on_after_loop}

  defp moved(_loop, nil, _now, _hours), do: {:error, :moved_requires_date}

  defp moved(loop, %{matters_by_at: %DateTime{} = at} = anchor, now, hours) do
    with :ok <- movable(at, now) do
      fields = Map.put(anchor, :horizon_class, Defaults.horizon_class(now, at, loop.timezone))
      moved = Map.merge(loop, fields)
      next = next_future_slot(moved, loop.touches, hours, now, moved_rest(moved, hours))
      {:ok, Map.merge(fields, %{state: "open", last_answer: "moved", next_touch_at: next})}
    end
  end

  # A moved loop whose touches leave no slot of its new table rests until the
  # new date's hand-back, or the date itself when its class and reach have
  # none, and the scan expires it there: never before the date the owner just
  # gave. The hand-back follows a date `movable/2` put ahead, so it is ahead too.
  defp moved_rest(loop, hours) do
    if handback?(loop) do
      last = length(slots(loop)) - 1

      fn now ->
        {:ok, at} = slot_time(loop, last, hours, now)
        at
      end
    else
      fn _now -> loop.matters_by_at end
    end
  end

  # A new date must leave room for a touch before it, as capture requires.
  defp movable(at, now) do
    cond do
      DateTime.compare(at, now) != :gt ->
        {:error, :date_passed}

      DateTime.compare(at, later(now, Defaults.ask_after_min_ms())) != :gt ->
        {:error, :imminent_without_window}

      true ->
        :ok
    end
  end

  defp reach(_loop, nil, _now), do: {:error, {:missing_parameters, [:reach]}}

  defp reach(%{state: "due"} = loop, reach, now) when reach in @reaches,
    do: {:ok, %{reach: reach, rung1_until: rung1_until(%{loop | reach: reach}, now)}}

  defp reach(_loop, reach, _now) when reach in @reaches, do: {:ok, %{reach: reach}}
  defp reach(_loop, _reach, _now), do: {:error, {:invalid_param, :reach}}

  # --- a check-in that did not speak ---------------------------------------------

  @doc """
  The changes a check-in's outcome makes when it sent nothing (§18 touch
  ledger). `silent` and `empty` advance to the following slot; `later`,
  `delivery_failed`, `timeout` and `error` retry at the next active-hours
  start, never sooner than the five-second floor (before the date that retry
  repeats daily until the date passes; the hand-back and an `after` touch
  retry once); `closed`
  settles the loop as reported elsewhere. A loop that runs out of slots this
  way expires: a hand-back or an `after` touch that does not speak, or a
  before-the-date slot of a loop never asked whose next slot would be the
  hand-back. None of them touches the ledger; a spoken message is
  `after_touch/4`.
  """
  @spec after_outcome(loop(), String.t(), DateTime.t(), hours()) :: changes()
  def after_outcome(%{state: state} = loop, outcome, %DateTime{} = now, hours)
      when state in @live and outcome in @quiet_outcomes do
    loop |> advance(now, hours) |> Map.merge(outcome_fields(outcome, now))
  end

  def after_outcome(%{state: state} = loop, outcome, %DateTime{} = now, hours)
      when state in @live and outcome in @retry_outcomes do
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

  defp advance(%{horizon_class: "after"}, now, _hours), do: expired(now)

  defp advance(loop, now, hours) do
    case phase(loop) do
      :before -> arm_or_expire(loop, slot_after(loop, loop.touches + 1, hours, now), hours, now)
      _handback_or_spent -> expired(now)
    end
  end

  defp slot_after(loop, index, hours, now),
    do: next_future_slot(loop, index, hours, now, fn _now -> nil end)

  defp retry(%{horizon_class: "after"} = loop, now, hours) do
    if failed_this_touch?(loop),
      do: expired(now),
      else: %{state: "open", next_touch_at: retry_at(loop, now, hours)}
  end

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
       do: outcome in @retry_outcomes and not before_date?(at, loop)

  defp handback_failed_before?(_loop), do: false

  # The rule `rearmed/2` states: a failure since the last touch, or any while
  # there is none, is the pending touch's first, since an answer that re-armed
  # the touch cleared the one before it. The anchor is no bound: a plan or a
  # not yet may arm the touch before it.
  defp failed_this_touch?(%{last_outcome: outcome, last_outcome_at: %DateTime{} = at} = loop) do
    outcome in @retry_outcomes and
      (is_nil(loop.last_touch_at) or DateTime.compare(at, loop.last_touch_at) != :lt)
  end

  defp failed_this_touch?(_loop), do: false

  defp retry_at(loop, now, hours) do
    floor = later(now, Defaults.fault_floor_ms())
    start = ActiveHours.next_start(hours, now, loop.timezone)
    if DateTime.compare(start, floor) == :lt, do: floor, else: start
  end

  # Before the date the next time is armed, unless it would land on or after
  # the date: then a loop asked at least once goes to its hand-back, no earlier
  # than the hand-back slot, and one never asked, or one with no hand-back,
  # expires, as the due scan treats a passed slot.
  defp arm_or_expire(_loop, nil, _hours, now), do: expired(now)

  defp arm_or_expire(loop, at, hours, now) do
    cond do
      before_date?(at, loop) -> %{state: "open", next_touch_at: at}
      loop.touches == 0 or not handback?(loop) -> expired(now)
      true -> %{state: "open", next_touch_at: not_before_handback(loop, at, hours, now)}
    end
  end

  defp not_before_handback(loop, at, hours, now) do
    last = length(slots(loop)) - 1

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
  due loop wakes when its rung 1 window closes (`rung1_until`), and again when
  its pending touch lapses: the date passing for a before-the-date slot, the
  day of grace ending for a hand-back, an `after` touch's longest wait ending.
  Waiting for active hours or the next day's budget is the caller's, which
  holds the owner's hours. A claimed or terminal loop has none.
  """
  @spec next_wake(loop(), DateTime.t()) :: DateTime.t() | nil
  def next_wake(%{state: state, next_touch_at: %DateTime{} = at}, _now)
      when state in ["open", "asked"],
      do: at

  def next_wake(%{state: "due", claimed_at: nil} = loop, %DateTime{} = now) do
    [loop.rung1_until, lapse(loop, phase(loop))]
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&(DateTime.compare(&1, now) == :gt))
    |> Enum.min(DateTime, fn -> nil end)
  end

  def next_wake(_loop, _now), do: nil

  defp lapse(%{horizon_class: "after"} = loop, _phase),
    do: later(loop.next_touch_at, Defaults.conversation_window_ms())

  defp lapse(loop, :before), do: loop.matters_by_at
  defp lapse(%{horizon_class: "imminent"} = loop, _phase), do: loop.matters_by_at

  defp lapse(loop, :handback) do
    if handback?(loop),
      do: later(loop.next_touch_at, Defaults.expiry_grace_ms()),
      else: loop.next_touch_at
  end

  defp lapse(loop, :spent), do: loop.next_touch_at

  @doc """
  Whether the touch now pending is the loop's last: the hand-back, the last
  touch its table allows, or an `after` loop's second. The check-in says
  plainly that it won't raise the loop again.
  """
  @spec final_touch?(loop()) :: boolean()
  def final_touch?(%{horizon_class: "after"} = loop),
    do: loop.touches + 1 >= @after_max_touches

  def final_touch?(loop) when is_map(loop) do
    phase(loop) != :before or loop.touches + 1 >= length(slots(loop))
  end

  # --- phases ------------------------------------------------------------------------

  defp phase(%{horizon_class: "after"} = loop) do
    if loop.touches >= @after_max_touches or loop.state == "asked", do: :spent, else: :armed
  end

  defp phase(loop) do
    cond do
      loop.touches >= length(slots(loop)) -> :spent
      before_date?(loop.next_touch_at, loop) -> :before
      touched_after_date?(loop) -> :spent
      true -> :handback
    end
  end

  defp touched_after_date?(%{last_touch_at: %DateTime{} = at} = loop),
    do: not before_date?(at, loop)

  defp touched_after_date?(_loop), do: false

  defp before_date?(%DateTime{} = at, loop), do: DateTime.compare(at, loop.matters_by_at) == :lt

  defp local_date(at, zone), do: at |> DateTime.shift_zone!(zone) |> DateTime.to_date()

  defp later_day?(at, now, zone),
    do: Date.compare(local_date(at, zone), local_date(now, zone)) == :gt

  defp latest(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  # Every duration in `Defaults` is whole seconds; adding seconds keeps the
  # instant's own precision, which a millisecond add would change.
  defp later(%DateTime{} = at, ms) when rem(ms, 1_000) == 0,
    do: DateTime.add(at, div(ms, 1_000), :second)
end
