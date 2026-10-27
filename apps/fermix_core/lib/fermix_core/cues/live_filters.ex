defmodule FermixCore.Cues.LiveFilters do
  @moduledoc """
  The live filter dispatcher for stream items (M60_CUE_INTAKE_AT_SCALE.md
  §3.2): a stream's item is judged before it is stored, and only a pass is
  written.

  `Cues.Source.Stream` hands it each `llm` watcher of its source with what a
  call needs (`watchers/3`: the watcher's row, its active instructions, its
  recent examples and the calls its `filter_budget` counts), at connect and on
  every 10 s flush, and offers it the items each watcher's words matched
  (`offer/3`). Each watcher has a live queue of at most 250 items in memory: a
  full queue turns the newest away (counted `overflow`), and a watcher at its
  filter budget takes none and has what waits in its queue counted too
  (`over_budget`). The budget counts the calls the ledger held at the last
  refresh, the calls ended since and the calls in flight.

  At most four calls run at once across every live watcher, never two for one
  watcher's subject, so the items of a subject are judged and stored in
  arrival order; an item with no subject has no order and may use all four.
  The longest-waiting watcher goes first, and a watcher backing off after a
  provider failure waits for its `filter_retry_at`. `Cues.Filters` keeps its
  own four for stored deliveries, so neither pool starves the other.

  It makes no synchronous Repo call: a slow store cannot stall the judging or
  this mailbox. Each call runs as one task under
  `FermixCore.Cues.LiveFilterSupervisor` (`Task.Supervisor.async_nolink/2`,
  monitored). The task opens the call's live run (`Cues.Filter.Telemetry`),
  asks `Cues.Filter.Llm.decide/2`, tells this process it has decided, writes
  the result itself, sends any notice, closes the run and reports back:

    * a pass: `CuesSql`'s `{:pass_live, …}` (the cue if its identity is new,
      this watcher's `passed` delivery, the call's ledger row; a stored item of
      other content is an identity conflict, its gap and no delivery), then
      the scheduler is woken, as for a `none` delivery. A watcher paused, or no
      longer listening to the source, when the pass is written gets only the
      ledger row (`withheld`), and nothing is woken;
    * a drop: the call's ledger row (`CuesFilterSql`'s `{:settle_live, …}`);
      here the item goes to the watcher's recent drops (`Cues.RecentDrops`);
    * a provider failure: the ledger row and the watcher's backoff, written as
      a stored call's settle writes them; here the item goes back to the head
      of its subject and the watcher waits. The third in a row holds it, with
      `:filter_held`, and a success after a hold sends `:filter_recovered`;
    * a content failure: the ledger row; here the item goes back to the head
      of its subject, up to three attempts, then is counted `filter_failed`.

  A write that does not answer in time keeps its decision: the task tries
  only the write again, three times with backoff, then gives up (a pass is
  counted `write_failed`; a provider failure whose backoff was not written
  holds the watcher here for a minute). A task that has not decided within
  60 s is killed and its call ends as a provider failure (a timeout); one
  that exits abnormally is a content failure; each is written by a task of
  its own, so the slot and the subject stay held until it is. When that task
  crashes too, the call ends there, unwritten: traced and counted
  `filter_failed`. One shut down with its supervisor is put back at the head
  unwritten.

  The counts per watcher (`Cues.Counts`) are flushed every 10 s by a task, and
  once at a clean stop, as absolute totals for the hour. This process creates
  the recent-drops table in `init`. Its queues, the recent drops and the
  counts since the last flush are lost with it.
  """

  use GenServer

  require Logger

  alias FermixCore.Cues
  alias FermixCore.Cues.Counts
  alias FermixCore.Cues.Filter.Llm
  alias FermixCore.Cues.Filter.Telemetry, as: FilterTelemetry
  alias FermixCore.Cues.Notices
  alias FermixCore.Cues.RecentDrops
  alias FermixCore.Cues.Telemetry
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesFilterSql
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixCore.Timeouts

  @max_in_flight 4
  @queue_cap 250
  @max_attempts 3
  @call_timeout_ms 60_000
  @flush_ms 10_000
  @write_retries 3
  @first_write_retry_ms 1_000
  # A provider failure whose backoff could not be written holds the watcher
  # this long here, so a store that does not answer is not met with a call
  # after every failure.
  @unwritten_hold_ms 60_000
  # The clean stop's count flush is bounded well under the supervisor's
  # shutdown (5 s by default), which would kill this process mid-call.
  @stop_flush_ms 2_000
  @task_supervisor FermixCore.Cues.LiveFilterSupervisor
  @shutdown_reasons [:shutdown]

  @typedoc """
  One `llm` watcher of a stream source, as `watchers/3` takes it: its row's
  fields and what `CuesFilterSql`'s `{:live_context, …}` read for it.
  """
  @type spec :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:purpose) => String.t() | nil,
          required(:filter_budget) => non_neg_integer(),
          required(:filter_failures) => non_neg_integer(),
          required(:filter_retry_at) => DateTime.t() | nil,
          required(:instructions) => [map()],
          required(:examples) => [map()],
          required(:used) => non_neg_integer()
        }

  @doc """
  Starts the dispatcher. Opts: `:name` (default `__MODULE__`), `:repo`
  (default `Memory.Repo`), `:repo_timeout_ms` (each write's bound, default
  `Timeouts.repo_call/0`), `:clock` (a zero-arity function returning the UTC
  now), `:timers?` (default true; false turns off the count flush, the due
  timer and the call deadline, for tests, which send `:flush` and `:due` by
  hand), `:task_supervisor` (default `FermixCore.Cues.LiveFilterSupervisor`),
  `:notices` (default `Cues.Notices`) and `:notice_opts` (appended to every
  notice call's opts), `:llm` (opts for `Cues.Filter.Llm.decide/2`'s seams),
  `:wake_scheduler` (default `Cues.wake_scheduler/0`) and `:sleep` (the write
  retry's wait, default `Process.sleep/1`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Hands over `source_ref`'s `llm` watchers, replacing what that source handed
  before. A watcher no source lists any more (removed, disabled, or no longer
  listening) is forgotten, with its queue and its recent drops. A cast: it
  never blocks.
  """
  @spec watchers(GenServer.server(), String.t(), [spec()]) :: :ok
  def watchers(server, source_ref, specs) when is_binary(source_ref) and is_list(specs) do
    true = Enum.all?(specs, &is_binary(Map.get(&1, :id)))
    GenServer.cast(server, {:watchers, source_ref, specs})
  end

  @doc """
  Offers `source_ref`'s items, each with the watchers whose words matched it,
  in arrival order. A cast: it never blocks.
  """
  @spec offer(GenServer.server(), String.t(), [{Cues.Item.t(), [String.t()]}]) :: :ok
  def offer(server, source_ref, offers) when is_binary(source_ref) and is_list(offers) do
    GenServer.cast(server, {:offer, source_ref, offers})
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    RecentDrops.new_table()
    timers? = Keyword.get(opts, :timers?, true)

    state = %{
      repo: Keyword.get(opts, :repo, Repo),
      repo_timeout_ms: Keyword.get(opts, :repo_timeout_ms, Timeouts.repo_call()),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      timers?: timers?,
      task_supervisor: Keyword.get(opts, :task_supervisor, @task_supervisor),
      notices: Keyword.get(opts, :notices, Notices),
      notice_opts: Keyword.get(opts, :notice_opts, []),
      llm_opts: Keyword.get(opts, :llm, []),
      wake_scheduler: Keyword.get(opts, :wake_scheduler, &Cues.wake_scheduler/0),
      sleep: Keyword.get(opts, :sleep, &Process.sleep/1),
      specs: %{},
      sources: %{},
      queues: %{},
      seq: 0,
      in_flight: %{},
      counts: Counts.new("watcher"),
      flushing: nil,
      due_timer: nil
    }

    if timers?, do: Process.send_after(self(), :flush, @flush_ms)
    {:ok, state}
  end

  @impl true
  def handle_cast({:watchers, source_ref, specs}, state) do
    state = state |> put_watchers(source_ref, specs) |> drain_over_budget(specs)
    {:noreply, dispatch(state)}
  end

  def handle_cast({:offer, source_ref, offers}, state),
    do: {:noreply, state |> take_offers(source_ref, offers) |> dispatch()}

  @impl true
  def handle_info(:flush, state) do
    if state.timers?, do: Process.send_after(self(), :flush, @flush_ms)
    {:noreply, flush(state)}
  end

  def handle_info(:due, state), do: {:noreply, dispatch(%{state | due_timer: nil})}

  def handle_info({:decided, pid}, state) when is_pid(pid), do: {:noreply, decided(pid, state)}

  def handle_info({:deadline, ref}, state) when is_reference(ref),
    do: {:noreply, ref |> expire(state) |> dispatch()}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state),
    do: {:noreply, ref |> down(reason, state) |> dispatch()}

  def handle_info({ref, reply}, state) when is_reference(ref),
    do: {:noreply, ref |> reported(reply, state) |> dispatch()}

  # A clean stop writes what was counted since the last flush. This is the one
  # synchronous Repo call, made as the process ends, bounded by `@stop_flush_ms`.
  @impl true
  def terminate(_reason, state) do
    rows = Counts.rows(state.counts)
    Counts.report(state.counts)

    if rows != [],
      do: write_counts(%{task_context(state) | repo_timeout_ms: @stop_flush_ms}, rows)

    :ok
  end

  # --- watchers and offers ------------------------------------------------------------

  defp put_watchers(state, source_ref, specs) do
    listed = Enum.map(specs, & &1.id)
    sources = Map.put(state.sources, source_ref, listed)
    gone = Map.get(state.sources, source_ref, []) -- listed
    still = sources |> Map.values() |> List.flatten() |> MapSet.new()
    forgotten = Enum.reject(gone, &MapSet.member?(still, &1))
    Enum.each(forgotten, &RecentDrops.forget/1)

    %{
      state
      | sources: sources,
        specs: state.specs |> Map.drop(forgotten) |> Map.merge(Map.new(specs, &{&1.id, &1})),
        queues: Map.drop(state.queues, forgotten)
    }
  end

  defp take_offers(state, source_ref, offers) do
    now = state.clock.()

    Enum.reduce(offers, state, fn {item, watcher_ids}, acc ->
      Enum.reduce(watcher_ids, acc, &enqueue(&2, &1, {source_ref, item}, now))
    end)
  end

  defp enqueue(state, watcher_id, {source_ref, item}, now) do
    state = count(state, watcher_id, "offered", now)
    queue = Map.get(state.queues, watcher_id, :queue.new())

    cond do
      over_budget?(state, watcher_id) ->
        state |> drain(watcher_id, now) |> count(watcher_id, "over_budget", now)

      :queue.len(queue) >= @queue_cap ->
        count(state, watcher_id, "overflow", now)

      true ->
        push(state, watcher_id, queue, entry(state, source_ref, item, now))
    end
  end

  defp entry(state, source_ref, item, now) do
    %{
      seq: state.seq,
      source_ref: source_ref,
      item: item,
      subject: item.subject,
      received_at: now,
      attempts: 0
    }
  end

  defp push(state, watcher_id, queue, entry) do
    queues = Map.put(state.queues, watcher_id, :queue.in(entry, queue))
    %{state | queues: queues, seq: state.seq + 1}
  end

  # Back at the head: the item comes before every later item of its subject. A
  # watcher forgotten while the item's call ran takes nothing back.
  defp requeue(state, watcher_id, entry) do
    if Map.has_key?(state.specs, watcher_id) do
      queue = Map.get(state.queues, watcher_id, :queue.new())
      %{state | queues: Map.put(state.queues, watcher_id, :queue.in_r(entry, queue))}
    else
      state
    end
  end

  # `used` is the ledger's count at the last refresh plus the calls ended
  # since; a call in flight has no row yet, so it is counted apart.
  defp over_budget?(state, watcher_id) do
    case Map.fetch(state.specs, watcher_id) do
      {:ok, %{filter_budget: budget, used: used}} ->
        budget > 0 and used + in_flight_of(state, watcher_id) >= budget

      :error ->
        false
    end
  end

  defp in_flight_of(state, watcher_id),
    do: Enum.count(state.in_flight, fn {_ref, flight} -> flight.watcher_id == watcher_id end)

  # A watcher at its filter budget judges nothing more until its calls leave
  # the 24-hour window, so what waits in its queue is counted, not kept.
  defp drain_over_budget(state, specs) do
    now = state.clock.()
    over = for %{id: id} <- specs, over_budget?(state, id), do: id
    Enum.reduce(over, state, &drain(&2, &1, now))
  end

  defp drain(state, watcher_id, now) do
    {queue, queues} = Map.pop(state.queues, watcher_id, :queue.new())
    count(%{state | queues: queues}, watcher_id, "over_budget", now, :queue.len(queue))
  end

  # --- dispatch ------------------------------------------------------------------------

  defp dispatch(state) do
    free = @max_in_flight - map_size(state.in_flight)
    state |> start_calls(free, state.clock.()) |> arm_due()
  end

  defp start_calls(state, free, _now) when free <= 0, do: state

  defp start_calls(state, free, now) do
    case next_ready(state, now) do
      nil ->
        state

      {watcher_id, entry, rest} ->
        state = %{state | queues: Map.put(state.queues, watcher_id, rest)}
        state |> start_call(watcher_id, entry, now) |> start_calls(free - 1, now)
    end
  end

  # The longest-waiting item any ready watcher may take now: the first of its
  # queue whose subject has no call in flight.
  defp next_ready(state, now) do
    busy = busy_subjects(state)

    state.queues
    |> Enum.filter(fn {watcher_id, _queue} -> ready?(state, watcher_id, now) end)
    |> Enum.flat_map(fn {watcher_id, queue} -> take_ready(watcher_id, queue, busy) end)
    |> Enum.min_by(fn {_watcher_id, entry, _rest} -> entry.seq end, fn -> nil end)
  end

  defp ready?(state, watcher_id, now) do
    case Map.fetch(state.specs, watcher_id) do
      {:ok, spec} -> not backing_off?(spec, now) and not over_budget?(state, watcher_id)
      :error -> false
    end
  end

  defp backing_off?(%{filter_retry_at: nil}, _now), do: false
  defp backing_off?(%{filter_retry_at: at}, now), do: DateTime.compare(at, now) == :gt

  defp take_ready(watcher_id, queue, busy) do
    entries = :queue.to_list(queue)

    case Enum.split_while(entries, &MapSet.member?(busy, {watcher_id, &1.subject})) do
      {_all_busy, []} -> []
      {before, [entry | rest]} -> [{watcher_id, entry, :queue.from_list(before ++ rest)}]
    end
  end

  defp busy_subjects(state) do
    for {_ref, %{watcher_id: id, entry: %{subject: subject}}} <- state.in_flight,
        subject != nil,
        into: MapSet.new(),
        do: {id, subject}
  end

  defp start_call(state, watcher_id, entry, now) do
    spec = Map.fetch!(state.specs, watcher_id)
    run = run_of(spec, entry, now)
    context = Map.put(task_context(state), :waiting, queued(state, watcher_id))
    claim = claim_of(spec, entry)
    item = entry.item

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        run_call(run, claim, item, context)
      end)

    flight = %{
      watcher_id: watcher_id,
      entry: entry,
      run: run,
      pid: task.pid,
      deadline: deadline(state, task.ref),
      started_ms: monotonic_ms(),
      ending?: false
    }

    %{state | in_flight: Map.put(state.in_flight, task.ref, flight)}
  end

  defp run_of(spec, entry, now) do
    %{
      live?: true,
      session_id: FilterTelemetry.session_id(spec.id, now),
      call_id: Cues.id("cfc"),
      watcher_id: spec.id,
      source_ref: entry.source_ref,
      attempt: entry.attempts,
      started_at: now
    }
    |> Map.merge(Llm.configured())
  end

  # What `Cues.Filter.Llm.decide/2` takes, shaped as a stored claim: the
  # watcher's purpose, instructions and examples, and the one item.
  defp claim_of(spec, %{item: item} = entry) do
    cue = %{
      source_ref: entry.source_ref,
      type: item.type,
      subject: item.subject,
      occurred_at: item.occurred_at,
      received_at: entry.received_at,
      payload: item.payload
    }

    %{
      watcher: Map.take(spec, [:id, :name, :purpose]),
      cue: cue,
      instructions: spec.instructions,
      examples: spec.examples
    }
  end

  defp deadline(%{timers?: false}, _ref), do: nil

  defp deadline(_state, ref), do: Process.send_after(self(), {:deadline, ref}, @call_timeout_ms)

  # The earliest time a backing-off watcher with items waiting may go again.
  defp arm_due(%{timers?: false} = state), do: state

  defp arm_due(state) do
    if state.due_timer, do: Process.cancel_timer(state.due_timer)
    now = state.clock.()

    next =
      for {id, queue} <- state.queues,
          not :queue.is_empty(queue),
          %{filter_retry_at: %DateTime{} = at} <- [Map.get(state.specs, id)],
          DateTime.compare(at, now) == :gt,
          do: at

    case next do
      [] ->
        %{state | due_timer: nil}

      times ->
        delay = DateTime.diff(Enum.min(times, DateTime), now, :millisecond)
        %{state | due_timer: Process.send_after(self(), :due, delay)}
    end
  end

  # --- one call, inside its task --------------------------------------------------------

  defp run_call(run, claim, item, context) do
    started = monotonic_ms()
    FilterTelemetry.run_start(run)
    result = Llm.decide(claim, Keyword.put(context.llm_opts, :session_id, run.session_id))
    send(context.owner, {:decided, self()})
    end_call(context, run, item, result, started)
  end

  # Writes the result, then traces it and sends its notices; the report says
  # what this process does next with the item.
  defp end_call(context, run, item, result, started) do
    written = write(context, run, item, result)
    finish(context, run, result, written, monotonic_ms() - started)
    {:live, result, written}
  end

  defp write(context, run, item, {:pass, reason, hint}) do
    request =
      {:pass_live, run.source_ref, item, run.watcher_id, reason, hint, call_of(run),
       context.clock.()}

    write_retried(context, CuesSql, request, @write_retries)
  end

  defp write(context, run, _item, result) do
    request = {:settle_live, run.watcher_id, call_of(run), result, context.clock.()}
    write_retried(context, CuesFilterSql, request, @write_retries)
  end

  # Only a write that did not answer in time is sent again: the request still
  # runs when the Repo reaches it, and both writes are safe to repeat.
  defp write_retried(context, module, request, retries_left) do
    case Repo.cues_call(module, request, repo_opts(context)) do
      {:error, :repo_timeout} when retries_left > 0 ->
        context.sleep.(@first_write_retry_ms * Integer.pow(2, @write_retries - retries_left))
        write_retried(context, module, request, retries_left - 1)

      written ->
        written
    end
  end

  defp call_of(run) do
    Map.take(run, [:session_id, :started_at, :provider, :model, :attempt, :source_ref])
    |> Map.put(:id, run.call_id)
  end

  defp finish(context, run, result, {:ok, outcome}, duration_ms) do
    emit_pass(run, result, outcome)
    send_notices(context, run, result, outcome)
    close(run_with_ids(run, outcome), result, duration_ms)
  end

  defp finish(_context, run, _result, {:error, reason}, duration_ms) do
    Logger.error(
      "Cue live filter call #{run.call_id} could not write its result: #{inspect(reason)}"
    )

    FilterTelemetry.run_error(run, :settle_failed, error_kind(reason), duration_ms)
  end

  defp run_with_ids(run, %{cue_id: cue_id, delivery_id: delivery_id}),
    do: Map.merge(run, %{cue_id: cue_id, delivery_id: delivery_id})

  defp run_with_ids(run, _outcome), do: run

  defp close(run, {:pass, _reason, _hint}, duration_ms),
    do: FilterTelemetry.run_complete(run, :pass, duration_ms)

  defp close(run, {:drop, _reason}, duration_ms),
    do: FilterTelemetry.run_complete(run, :drop, duration_ms)

  defp close(run, {status, %{kind: kind}}, duration_ms),
    do: FilterTelemetry.run_error(run, status, kind, duration_ms)

  # A pass keeps its per-item events; every other outcome of a live call is
  # counted and traced at the flush (`Cues.Counts`). A withheld pass stored
  # nothing, so it has none. A pass that met a stored item of other content is
  # traced as accept traces it: `conflict`, its gap.
  defp emit_pass(_run, _result, %{result: :withheld}), do: :ok

  defp emit_pass(run, {:pass, _reason, _hint}, %{conflict?: true} = outcome) do
    Telemetry.lifecycle(:conflict, %{}, %{
      source_ref: run.source_ref,
      cue_id: outcome.cue_id,
      watcher_id: run.watcher_id
    })

    Enum.each(outcome.gaps, &emit_gap/1)
  end

  defp emit_pass(run, {:pass, reason, _hint}, outcome) do
    Telemetry.lifecycle(:passed, %{}, %{
      session_id: run.session_id,
      filter_call_id: run.call_id,
      watcher_id: run.watcher_id,
      delivery_id: outcome.delivery_id,
      cue_id: outcome.cue_id,
      source_ref: run.source_ref,
      decision: :pass,
      content: reason
    })

    Enum.each(outcome.evicted, &emit_evicted(run.source_ref, &1))
    Enum.each(outcome.gaps, &emit_gap/1)
  end

  defp emit_pass(_run, _result, _outcome), do: :ok

  defp emit_evicted(source_ref, evicted) do
    Telemetry.lifecycle(:expired, %{}, %{
      source_ref: source_ref,
      delivery_id: evicted.delivery_id,
      watcher_id: evicted.watcher_id,
      reason: "inbox_full"
    })
  end

  defp emit_gap(gap) do
    Telemetry.lifecycle(:gap, %{count: gap.count}, %{
      source_ref: gap.source_ref,
      gap_id: gap.gap_id,
      watcher_id: gap.watcher_id,
      reason: gap.reason
    })
  end

  defp send_notices(context, run, result, outcome) do
    base = %{watcher_name: outcome.watcher_name, waiting: context.waiting}

    if outcome.held_now? do
      {_status, %{message: message}} = result
      notify(context, run.watcher_id, :filter_held, Map.put(base, :error, message))
    end

    if outcome.recovered?, do: notify(context, run.watcher_id, :filter_recovered, base)
    :ok
  end

  defp notify(context, watcher_id, kind, data) do
    bounds = [on_timeout: :error, timeout: context.repo_timeout_ms]
    opts = [repo: context.repo, now: context.clock.()] ++ bounds ++ context.notice_opts

    case context.notices.watcher(watcher_id, kind, data, opts) do
      {:error, reason} ->
        Logger.warning(
          "Cue live filter notice #{kind} for #{watcher_id} failed: #{inspect(reason)}"
        )

      _sent_or_already ->
        :ok
    end
  end

  # --- the end of a call, here -----------------------------------------------------------

  # Decided: the deadline is over; the write is bounded by its own retries.
  defp decided(pid, state) do
    case Enum.find(state.in_flight, fn {_ref, flight} -> flight.pid == pid end) do
      nil ->
        state

      {ref, flight} ->
        cancel(flight.deadline)
        %{state | in_flight: Map.put(state.in_flight, ref, %{flight | deadline: nil})}
    end
  end

  defp reported(ref, {:counts_written, rows, written}, %{flushing: ref} = state) do
    Process.demonitor(ref, [:flush])
    %{state | flushing: nil, counts: counts_after(state, rows, written)}
  end

  defp reported(ref, {:live, result, written}, state) do
    case Map.pop(state.in_flight, ref) do
      {nil, _in_flight} ->
        state

      {flight, in_flight} ->
        Process.demonitor(ref, [:flush])
        cancel(flight.deadline)

        %{state | in_flight: in_flight}
        |> spent(flight.watcher_id)
        |> settle(flight, result, written)
    end
  end

  defp reported(_ref, _reply, state), do: state

  defp down(ref, _reason, %{flushing: ref} = state), do: %{state | flushing: nil}

  defp down(ref, reason, state) do
    case Map.pop(state.in_flight, ref) do
      {nil, _in_flight} -> state
      {flight, in_flight} -> ended(%{state | in_flight: in_flight}, flight, reason)
    end
  end

  # Shut down with its supervisor: back at the head, unwritten. Any other exit
  # is the item's content failure, written by a task of its own; when that
  # task crashes too, the call ends here and is never handed on again.
  defp ended(state, flight, reason) when reason in @shutdown_reasons,
    do: aborted(state, flight)

  defp ended(state, flight, {:shutdown, _detail}), do: aborted(state, flight)

  defp ended(state, %{ending?: true} = flight, reason) do
    Logger.error(
      "Cue live filter call #{flight.run.call_id} could not write its end: #{inspect(reason)}"
    )

    duration_ms = monotonic_ms() - flight.started_ms
    FilterTelemetry.run_error(flight.run, :settle_failed, :crashed, duration_ms)
    state |> spent(flight.watcher_id) |> count(flight.watcher_id, "filter_failed")
  end

  defp ended(state, flight, reason) do
    cancel(flight.deadline)
    Logger.warning("Cue live filter call #{flight.run.call_id} crashed: #{inspect(reason)}")
    failure = %{kind: :crashed, message: "The filter call stopped unexpectedly."}
    end_in_task(state, flight, {:content_failure, failure})
  end

  defp aborted(state, flight) do
    cancel(flight.deadline)
    duration_ms = monotonic_ms() - flight.started_ms
    FilterTelemetry.run_error(flight.run, :aborted, :shutdown, duration_ms)
    requeue(state, flight.watcher_id, flight.entry)
  end

  defp expire(ref, state) do
    case Map.pop(state.in_flight, ref) do
      {nil, _in_flight} ->
        state

      {flight, in_flight} ->
        Process.exit(flight.pid, :kill)
        Process.demonitor(ref, [:flush])
        message = "The filter model gave no answer within #{div(@call_timeout_ms, 1000)} seconds."
        failure = {:provider_failure, %{kind: :timeout, message: message}}
        end_in_task(%{state | in_flight: in_flight}, flight, failure)
    end
  end

  # The call's end written by a task of its own, under the same flight marked
  # ending: the slot and the subject stay held until it reports or crashes.
  defp end_in_task(state, flight, result) do
    context = Map.put(task_context(state), :waiting, queued(state, flight.watcher_id))
    started = flight.started_ms
    run = flight.run
    item = flight.entry.item

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        end_call(context, run, item, result, started)
      end)

    flight = %{flight | pid: task.pid, deadline: nil, ending?: true}
    %{state | in_flight: Map.put(state.in_flight, task.ref, flight)}
  end

  # What a reported call means for its item, its watcher and the counts.
  # `passed` counts the passes whose delivery was stored: the watcher already
  # had this item's (a repeat) when the write stored none. A withheld pass (the
  # watcher paused, or no longer listening to the source, when it was written)
  # stored nothing: no task to wake and nothing passed, though the model did
  # answer.
  defp settle(state, flight, {:pass, _reason, _hint}, {:ok, %{result: :withheld}}),
    do: succeeded(state, flight.watcher_id)

  defp settle(state, flight, {:pass, _reason, _hint}, {:ok, outcome}) do
    state.wake_scheduler.()
    state = succeeded(state, flight.watcher_id)
    if outcome.delivery_id, do: count(state, flight.watcher_id, "passed"), else: state
  end

  defp settle(state, flight, {:pass, _reason, _hint}, {:error, _write_error}),
    do: count(state, flight.watcher_id, "write_failed")

  defp settle(state, flight, {:drop, reason}, written) do
    %{watcher_id: watcher_id, entry: entry} = flight
    RecentDrops.put(watcher_id, entry.item, entry.source_ref, reason, state.clock.())
    state = if match?({:ok, _outcome}, written), do: succeeded(state, watcher_id), else: state
    count(state, watcher_id, "dropped")
  end

  defp settle(state, flight, {:provider_failure, _failure}, written) do
    state
    |> backed_off(flight.watcher_id, written)
    |> requeue(flight.watcher_id, flight.entry)
  end

  defp settle(state, flight, {:content_failure, _failure}, _written) do
    entry = %{flight.entry | attempts: flight.entry.attempts + 1}

    if entry.attempts >= @max_attempts,
      do: count(state, flight.watcher_id, "filter_failed"),
      else: requeue(state, flight.watcher_id, entry)
  end

  defp succeeded(state, watcher_id),
    do: put_hold(state, watcher_id, %{filter_failures: 0, filter_retry_at: nil})

  defp backed_off(state, watcher_id, {:ok, outcome}) do
    hold = %{filter_failures: outcome.filter_failures, filter_retry_at: outcome.retry_at}
    put_hold(state, watcher_id, hold)
  end

  defp backed_off(state, watcher_id, {:error, _reason}) do
    retry_at = DateTime.add(state.clock.(), @unwritten_hold_ms, :millisecond)
    put_hold(state, watcher_id, %{filter_retry_at: retry_at})
  end

  # A call that ended wrote its ledger row, or tried to: the budget counts it
  # until the next refresh reads the ledger again.
  defp spent(state, watcher_id) do
    case Map.fetch(state.specs, watcher_id) do
      {:ok, spec} ->
        %{state | specs: Map.put(state.specs, watcher_id, %{spec | used: spec.used + 1})}

      :error ->
        state
    end
  end

  # A watcher forgotten while its call ran has no spec to change.
  defp put_hold(state, watcher_id, hold) do
    case Map.fetch(state.specs, watcher_id) do
      {:ok, spec} -> %{state | specs: Map.put(state.specs, watcher_id, Map.merge(spec, hold))}
      :error -> state
    end
  end

  # --- counts ----------------------------------------------------------------------------

  defp count(state, watcher_id, name), do: count(state, watcher_id, name, state.clock.())

  defp count(state, watcher_id, name, now), do: count(state, watcher_id, name, now, 1)

  defp count(state, watcher_id, name, now, n),
    do: %{state | counts: Counts.add(state.counts, watcher_id, name, n, now)}

  # One flush at a time, by a task: its rows are absolute totals, so one that
  # failed is simply sent again by the next.
  defp flush(%{flushing: flushing} = state) when flushing != nil, do: state

  defp flush(state) do
    rows = Counts.rows(state.counts)
    counts = Counts.report(state.counts)
    context = task_context(state)

    if rows == [] do
      %{state | counts: counts}
    else
      task =
        Task.Supervisor.async_nolink(state.task_supervisor, fn ->
          {:counts_written, rows, write_counts(context, rows)}
        end)

      %{state | counts: counts, flushing: task.ref}
    end
  end

  defp counts_after(state, rows, {:ok, _written}),
    do: Counts.written(state.counts, rows, state.clock.())

  defp counts_after(state, _rows, {:error, _reason}), do: state.counts

  defp write_counts(context, rows) do
    case Repo.cues_call(CuesSql, {:counts_put, rows, context.clock.()}, repo_opts(context)) do
      {:ok, _written} = written ->
        written

      {:error, reason} ->
        Telemetry.lifecycle(:sweep_error, %{}, %{reason: :live_counts, result: {:error, reason}})
        Logger.warning("Cue live filters: the counts could not be written: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # --- helpers ---------------------------------------------------------------------------

  defp queued(state, watcher_id) do
    case Map.fetch(state.queues, watcher_id) do
      {:ok, queue} -> :queue.len(queue)
      :error -> 0
    end
  end

  defp task_context(state) do
    state
    |> Map.take([:repo, :repo_timeout_ms, :clock, :notices, :notice_opts, :llm_opts, :sleep])
    |> Map.put(:owner, self())
  end

  defp repo_opts(context), do: Repo.periodic_opts(context.repo, context.repo_timeout_ms)

  defp error_kind(reason) when is_atom(reason), do: reason

  defp error_kind(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: elem(reason, 0)

  defp error_kind(_reason), do: :unclassified

  defp cancel(nil), do: :ok

  defp cancel(timer) do
    Process.cancel_timer(timer)
    :ok
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
