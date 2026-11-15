defmodule FermixChannels.Desktop.Invoke.Admission do
  @moduledoc """
  Each invocation this computer's server asks of it, from its `invoke_open`
  to its `invoke_result` (M97 §6.2, §6.3), in `Desktop.Invoke`.

  **Admit**, in this order, each a refusal with the computer's sentence:
  the request's primary epoch is at least the link's (`stale_epoch`: an
  older copy of the home never acts here); the capability and its op are
  ones this computer has (`unavailable`); the master switch is on, the
  switches reviewed and the capability's offer on, read from this
  computer's switches at that moment (`off`); a deadline of 0 only for a
  long-lived op and a turn named for every turn's origin (`unavailable`);
  args the capability takes (`failed`, its sentence). The capability's own
  rules (`admit/3`: the origin, the sandbox's roots) may read the owner's
  folders, so they run first in the run's own process, never in this one:
  a folder that stops answering holds that run alone. The origin is the
  server's word: the check guards against a bug there, not against a
  server that was taken over.

  **Bound**: at most #{8} run at once and #{32} wait, first come first
  served; past that, `busy`. A request that announces an upload waits for
  its part (`invoke_part`, at most 20 MiB, #{64} MiB across every upload),
  counted among the waiting; a part with a gap, a size or a SHA-256 past
  what was announced fails the invocation ("The upload did not arrive
  whole."), and the session stays open.

  **Run**: a `started` record is synced to the journal
  (`FermixCore.Computers.Journal`) before the run, which is a task under
  the runs' supervisor; a journal that cannot be written runs nothing. A
  deadline counts from the request's arrival, its wait included: past it a
  run is stopped and answered `timed_out`. A run stopped (past its
  deadline, cancelled, or by a switch) is stopped beside this process, the
  capability's `cancel/2` first, then its process, and is answered once it
  ended, holding its slot until then: a `cancel/2` that hangs or fails is
  logged and never holds or ends this process. A run that ran and failed
  with a result of its own (a
  tool's error) is answered `failed` with its short message, and carries
  its result and part within the capability's bounds (its message alone
  past them), so its journal record is never `ok`.

  **Record, then answer**: the `finished` record is synced before the
  `invoke_result` goes, then its part (`invoke_part`). A request refused
  before it started has only a `finished` record; one its capability's own
  rules refuse started, and has both. A request its capability says is no
  thing Fermix did here (`Capability.recorded?/3`, read once as it arrives:
  the renewal of a screen hold) has neither. Answers are sent by a task of
  their own, so a slow link never holds this process.

  **Held**: each answer stays here #{10} minutes, at most #{32} answers and
  32 MiB, for `invoke_status` after a lost answer; past that, the journal's
  receipt alone answers (`{"receipt_only":true}`), and with no record the
  answer is `unknown` with no receipt. A request still running or waiting
  is answered when it ends. `invoke_cancel` is answered exactly once:
  `cancelled`, or the outcome reached first.

  **The master switch off** (`switches_changed/1`, told by
  `FermixCore.Computers.Switches`) refuses every later request and ends
  what runs or waits as `refused` `stopped_here`. **An
  offer's own switch off**, the master on, ends the work of each capability
  whose offer it is, running or waiting, by the rule a request is admitted
  by (the capability's `offer/0` against `Switches.on?/2`): `refused` `off`,
  the sentence a request of it arriving now gets; every other capability's
  work goes on. A run that ends while the switches no longer let its
  capability run was ended by them (a switch's own listener, such as the
  browser's held turns, can end it before this process hears) and is
  answered as they say, never `failed`. A request that waited for a slot or
  its upload has the switches read again the moment it would start, as at
  admission, so none starts while they are off though this process has not
  heard yet.

  Each invocation is a run of its own on this computer's trace
  (`FermixCore.Computers.Telemetry`), its bookend emitted before the answer.

  At start it closes what a crash left started (`unknown`, `interrupted`)
  and tells the server of each as soon as it has started, with the
  journal's receipt as a status ask is answered. What only waited, for a
  slot or its upload, never started and has no record: its facts (never its
  args or bytes) are kept while it waits in `:waiting_table`, which
  `Desktop.Invoke` owns, so the restart answers each too, `refused`
  `unavailable` ("restarted before it ran"), journaled as one refused
  before it ran. Then it tells the server it started (`invoke_restarted`),
  and each caller still waiting on this computer asks about its request
  (`invoke_status`), as after a new session: a request that was on its way
  while this process was down never reached it, and one that waited when
  `Desktop.Invoke` itself restarted went with its table, so either has no
  record and is answered `unknown`, which ends an effect and has a read,
  a long-lived one (`imessage.watch`, `screen.watch`) included, asked
  again. So a restart of this process or of `Desktop.Invoke` while the
  session stays up leaves no caller waiting; with no session nothing is
  sent, and the server asks once one comes back. It applies the journal's
  retention then, and every hour. Seams: `:timer` (2-arity,
  `Process.send_after/3` to this process), `:send` (3-arity, in place of
  `Relay.send_event/3`), `:link_epoch` (0-arity, in place of reading
  `device/desktop.json`), `:reminder_uplink` (the `Desktop.ReminderUplink`
  a snooze's answer goes to).
  """

  use GenServer

  require Logger

  alias FermixChannels.Desktop.HistoryUplink
  alias FermixChannels.Desktop.Relay
  alias FermixChannels.Desktop.ReminderUplink
  alias FermixChannels.Mobile.Chunks
  alias FermixCore.Computers.Capability
  alias FermixCore.Computers.Journal
  alias FermixCore.Computers.Offers
  alias FermixCore.Computers.Origin
  alias FermixCore.Computers.Outcome
  alias FermixCore.Computers.Switches
  alias FermixCore.Computers.Telemetry
  alias FermixCore.Home.DesktopLink

  @max_running 8
  @max_waiting 32
  @max_part_bytes 20 * 1_024 * 1_024
  @max_upload_bytes 64 * 1_024 * 1_024
  @held_ms 10 * 60_000
  @max_held 32
  @max_held_bytes 32 * 1_024 * 1_024
  @prune_every_ms 60 * 60_000
  @part_chunk_bytes 60 * 1_024
  # What answering a request that never started needs, and nothing more.
  @waiting_facts [:id, :capability, :op, :target, :origin, :epoch, :turn, :arrived_at, :recorded?]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @doc "One event of the family, as the relay put it together. Never waits."
  @spec handle(GenServer.server(), String.t(), map(), binary()) :: :ok
  def handle(server, type, fields, payload),
    do: GenServer.cast(server, {:event, type, fields, payload})

  @doc "The switches changed: the master switch is read again."
  @spec switches_changed(GenServer.server()) :: :ok
  def switches_changed(server), do: GenServer.cast(server, :switches_changed)

  @impl true
  def init(opts) do
    home = Keyword.fetch!(opts, :home)

    state = %{
      home: home,
      dir: Journal.dir(home),
      switches: Keyword.fetch!(opts, :switches),
      sandbox: Keyword.fetch!(opts, :sandbox),
      browser: Keyword.get(opts, :browser),
      capabilities: Keyword.fetch!(opts, :capabilities),
      clock: Keyword.fetch!(opts, :clock),
      relay: Keyword.fetch!(opts, :relay),
      runs: Keyword.fetch!(opts, :runs),
      waiting_table: Keyword.fetch!(opts, :waiting_table),
      notifications: Keyword.fetch!(opts, :notifications),
      reminder_uplink: Keyword.get(opts, :reminder_uplink, ReminderUplink),
      timer: Keyword.get(opts, :timer, &Process.send_after(self(), &1, &2)),
      send: Keyword.get(opts, :send, &Relay.send_event/3),
      link_epoch: Keyword.get(opts, :link_epoch, fn -> link_epoch(home) end),
      running: %{},
      tasks: %{},
      stopping: %{},
      waiting: :queue.new(),
      uploads: %{},
      held: %{}
    }

    closed = recover(state)
    waited = waited_before(closed, state)
    _timer = state.timer.(:prune, @prune_every_ms)
    {:ok, state, {:continue, {:interrupted, closed, waited}}}
  end

  # Each run a crash ended, and each request that only waited then, is
  # answered once this process stands again.
  @impl true
  def handle_continue({:interrupted, closed, waited}, state) do
    Enum.each(
      closed,
      &send_answer(receipt_answer(&1), Outcome.receipt_only_payload(), nil, state)
    )

    never_ran = Outcome.refused(:unavailable, sentence(:restarted))
    state = Enum.reduce(waited, state, &answer(&1, never_ran, &2))
    :ok = tell_started(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:event, "invoke_open", fields, payload}, state),
    do: {:noreply, open(fields, payload, state)}

  def handle_cast({:event, "invoke_part", fields, bytes}, state),
    do: {:noreply, part(fields, bytes, state)}

  def handle_cast({:event, "invoke_cancel", %{"id" => id}, _payload}, state),
    do: {:noreply, cancel(id, state)}

  def handle_cast({:event, "invoke_status", %{"id" => id}, _payload}, state),
    do: {:noreply, status(id, state)}

  # The home's answer to a request this computer sent it goes to the process
  # waiting on it, by its id's prefix: `history.submit` (M97 §8.1) and a
  # reminder's snooze (M99 §10.1).
  def handle_cast({:event, "invoke_result", %{"id" => id} = fields, payload}, state) do
    if uplink_answer(id, fields, payload, state) == :unknown,
      do:
        Logger.warning("invocation #{id}: an answer came for a request this computer never sent")

    {:noreply, state}
  end

  def handle_cast(:switches_changed, state) do
    switches = switches(state)

    if Switches.enabled?(switches),
      do: {:noreply, offer_switched_off(switches, state)},
      else: {:noreply, stopped(state)}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    cond do
      Map.has_key?(state.tasks, ref) ->
        {id, tasks} = Map.pop!(state.tasks, ref)
        Process.demonitor(ref, [:flush])
        {:noreply, ran(id, result, %{state | tasks: tasks})}

      Map.has_key?(state.stopping, ref) ->
        Process.demonitor(ref, [:flush])
        {:noreply, run_stopped(ref, state)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    cond do
      Map.has_key?(state.tasks, ref) ->
        {id, tasks} = Map.pop!(state.tasks, ref)
        {:noreply, crashed(id, reason, %{state | tasks: tasks})}

      Map.has_key?(state.stopping, ref) ->
        Logger.error("a run here was not stopped cleanly: #{inspect(reason)}")
        {:noreply, run_stopped(ref, state)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:deadline, id}, state), do: {:noreply, deadline(id, state)}

  def handle_info(:prune, state) do
    _timer = state.timer.(:prune, @prune_every_ms)
    :ok = prune(state)
    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.debug("the invocations ignored #{inspect(message)}")
    {:noreply, state}
  end

  defp uplink_answer("hist-" <> _rest = id, fields, payload, _state),
    do: HistoryUplink.answer(id, fields, payload)

  defp uplink_answer("snz-" <> _rest = id, fields, payload, state),
    do: ReminderUplink.answer(id, fields, payload, state.reminder_uplink)

  defp uplink_answer(_id, _fields, _payload, _state), do: :unknown

  # -- start ------------------------------------------------------------------------

  # What a crash left started is closed, then the retention runs; a journal
  # this computer cannot read or write is said, and the requests that need
  # it are refused as they come. Answers what it closed.
  defp recover(state) do
    closed =
      case Journal.interrupted(state.dir, state.clock.()) do
        {:ok, []} ->
          []

        {:ok, closed} ->
          Logger.warning(
            "#{length(closed)} invocation(s) were interrupted when Fermix stopped here"
          )

          closed

        {:error, reason} ->
          Logger.error("the invocation journal could not be read: #{inspect(reason)}")
          []
      end

    :ok = prune(state)
    closed
  end

  defp prune(state) do
    case Journal.prune(state.dir, state.clock.()) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("the invocation journal was not pruned: #{inspect(reason)}")
    end
  end

  # What waited when this process last stopped, oldest first: at most 32
  # (`@max_waiting`). One the crash caught as it started has a started record
  # and is among `closed`, answered from the journal; it is only let go here.
  defp waited_before(closed, state) do
    started = MapSet.new(closed, & &1.id)

    {ran, waited} =
      state.waiting_table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, facts} -> facts end)
      |> Enum.split_with(&MapSet.member?(started, &1.id))

    Enum.each(ran, &forget_waiting(&1.id, state))
    if waited != [], do: Logger.warning("#{length(waited)} request(s) waited when Fermix stopped")
    Enum.sort_by(waited, &DateTime.to_unix(&1.arrived_at, :microsecond))
  end

  # -- admitting ----------------------------------------------------------------------

  defp open(%{"id" => id} = fields, payload, state) do
    if known?(id, state),
      do: repeated(id, state),
      else: fields |> entry(payload, state) |> admitted(state)
  end

  defp known?(id, state) do
    Map.has_key?(state.running, id) or Map.has_key?(state.uploads, id) or
      Map.has_key?(state.held, id) or waiting?(id, state) or stopping?(id, state)
  end

  defp stopping?(id, state),
    do: Enum.any?(state.stopping, fn {_ref, {entry, _outcome}} -> entry.id == id end)

  defp waiting?(id, state), do: Enum.any?(:queue.to_list(state.waiting), &(&1.id == id))

  # The server never sends an id twice; one that came again is answered as
  # a status request is, never run again.
  defp repeated(id, state) do
    Logger.warning("invocation #{id} was asked again: it is not run twice")
    status(id, state)
  end

  defp entry(fields, payload, state) do
    capability = fields["capability"]
    module = Map.get(state.capabilities, capability)
    {:ok, origin} = Origin.from_wire(fields["origin"])
    args = args(payload)

    %{
      id: fields["id"],
      capability: capability,
      module: module,
      op: fields["op"],
      deadline_ms: fields["deadline_ms"],
      epoch: fields["epoch"],
      origin: origin,
      turn: turn(fields["turn"]),
      part: fields["part"],
      args: args,
      target: target(module, fields["op"], args, capability),
      recorded?: recorded?(module, fields["op"], args),
      arrived_at: state.clock.(),
      arrived_ms: System.monotonic_time(:millisecond)
    }
  end

  # Read once: what the capability says is no thing done here (the renewal
  # of a screen hold) gets no journal record, started or finished.
  defp recorded?(module, op, {:ok, args}) when is_atom(module) and not is_nil(module),
    do: Capability.recorded?(module, op, args)

  defp recorded?(_module, _op, _args), do: true

  defp args(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = args} -> {:ok, args}
      _other -> :error
    end
  end

  defp turn(%{"session_id" => session, "tool_call_id" => call}),
    do: %{session_id: session, tool_call_id: call}

  defp turn(nil), do: nil

  # What the request acts on, in the capability's words once its args are
  # ones it takes; its capability and op otherwise.
  defp target(module, op, {:ok, args}, capability) when is_atom(module) and not is_nil(module) do
    named =
      if op in module.ops() and module.validate(op, args) == :ok,
        do: Capability.bounded_target(module.target(op, args)),
        else: ""

    if named == "", do: Capability.bounded_target("#{capability}.#{op}"), else: named
  end

  defp target(_module, op, _args, capability),
    do: Capability.bounded_target("#{capability}.#{op}")

  defp admitted(entry, state) do
    meta = meta(entry)
    :ok = Telemetry.started(meta)

    case admit(entry, state) do
      :ok -> accept(entry, state)
      {:refused, refusal, sentence} -> answer(entry, Outcome.refused(refusal, sentence), state)
      {:failed, sentence} -> answer(entry, %Outcome{status: :failed, message: sentence}, state)
    end
  end

  # The capability's own rules (`admit/3`) are not here: they may read the
  # owner's folders, so they run first in the run's own process (`launch/3`).
  defp admit(entry, state) do
    with :ok <- current_epoch(entry, state),
         :ok <- known_op(entry),
         :ok <- switched_on(entry, switches(state)),
         :ok <- deadline_allowed(entry),
         :ok <- turn_named(entry),
         {:ok, _args} <- valid_args(entry) do
      :ok
    end
  end

  defp current_epoch(entry, state) do
    case state.link_epoch.() do
      {:ok, epoch} when entry.epoch >= epoch ->
        :ok

      {:ok, _newer} ->
        {:refused, :stale_epoch, sentence(:stale_epoch)}

      {:error, reason} ->
        Logger.error("an invocation was refused: the link could not be read: #{inspect(reason)}")
        {:refused, :unavailable, sentence(:link_unread)}
    end
  end

  defp known_op(%{module: nil}), do: {:refused, :unavailable, sentence(:unknown_op)}

  defp known_op(%{module: module, op: op}) do
    if op in module.ops(), do: :ok, else: {:refused, :unavailable, sentence(:unknown_op)}
  end

  defp switched_on(%{module: module}, switches) do
    machine = machine()

    cond do
      not Switches.reviewed?(switches) -> {:refused, :off, Offers.waiting_sentence(machine)}
      not Switches.enabled?(switches) -> {:refused, :off, Offers.master_off_sentence(machine)}
      offer_on?(module.offer(), switches) -> :ok
      true -> {:refused, :off, Offers.switched_off_sentence(machine)}
    end
  end

  defp offer_on?(nil, _switches), do: true
  defp offer_on?(offer, switches), do: Switches.on?(switches, offer)

  defp deadline_allowed(%{deadline_ms: 0, module: module, op: op}) do
    if module.long_lived?(op),
      do: :ok,
      else: {:refused, :unavailable, sentence(:no_deadline)}
  end

  defp deadline_allowed(_entry), do: :ok

  defp turn_named(%{origin: origin, turn: nil}) do
    if Origin.turn?(origin),
      do: {:refused, :unavailable, sentence(:no_turn)},
      else: :ok
  end

  defp turn_named(_entry), do: :ok

  defp valid_args(%{args: :error}),
    do: {:failed, sentence(:args_not_object)}

  defp valid_args(%{args: {:ok, args}, module: module, op: op}) do
    case module.validate(op, args) do
      :ok -> {:ok, args}
      {:error, sentence} -> {:failed, sentence}
    end
  end

  # -- bounding ---------------------------------------------------------------------

  defp accept(%{part: nil} = entry, state) do
    cond do
      slot_free?(state) ->
        entry |> armed(state) |> then(&start(entry, nil, &1))

      waiting_count(state) < @max_waiting ->
        entry |> armed(state) |> queue(entry)

      true ->
        busy(entry, state)
    end
  end

  defp accept(%{part: %{"size_bytes" => size}} = entry, state) do
    fits? =
      waiting_count(state) < @max_waiting and size <= @max_part_bytes and
        upload_bytes(state) + size <= @max_upload_bytes

    if fits?, do: entry |> armed(state) |> upload(entry), else: busy(entry, state)
  end

  defp busy(entry, state), do: answer(entry, Outcome.refused(:busy, sentence(:busy)), state)

  # A run being stopped still holds its slot until it ended.
  defp slot_free?(state), do: map_size(state.running) + map_size(state.stopping) < @max_running

  defp waiting_count(state), do: :queue.len(state.waiting) + map_size(state.uploads)

  defp upload_bytes(state),
    do: Enum.reduce(state.uploads, 0, fn {_id, upload}, sum -> sum + upload.size end)

  # The deadline counts from the request's arrival, its wait included.
  defp armed(%{deadline_ms: 0}, state), do: state

  defp armed(%{id: id, deadline_ms: deadline}, state) do
    _timer = state.timer.({:deadline, id}, deadline)
    state
  end

  defp queue(state, entry) do
    :ok = keep_waiting(entry, state)
    %{state | waiting: :queue.in(entry, state.waiting)}
  end

  defp upload(state, entry) do
    %{"size_bytes" => size, "sha256" => sha} = entry.part
    upload = %{entry: entry, size: size, sha256: sha, next: 0, received: 0, parts: []}
    :ok = keep_waiting(entry, state)
    %{state | uploads: Map.put(state.uploads, entry.id, upload)}
  end

  # What waits is kept outside this process until it starts or is answered,
  # so a restart answers it (the moduledoc).
  defp keep_waiting(entry, state) do
    true = :ets.insert(state.waiting_table, {entry.id, Map.take(entry, @waiting_facts)})
    :ok
  end

  defp forget_waiting(id, state) do
    true = :ets.delete(state.waiting_table, id)
    :ok
  end

  # The next request that waits, once one has ended.
  defp next(state) do
    with true <- slot_free?(state),
         {{:value, entry}, waiting} <- :queue.out(state.waiting) do
      next(waited(entry, Map.get(entry, :part_bytes), %{state | waiting: waiting}))
    else
      _full_or_empty -> state
    end
  end

  # A request that waited for a slot or its upload starts only if the
  # switches let it now: nothing starts while they are off, though this
  # process has not heard yet (`switches_changed/1`).
  defp waited(entry, part, state) do
    case switched_on(entry, switches(state)) do
      :ok -> start(entry, part, state)
      {:refused, refusal, sentence} -> answer(entry, Outcome.refused(refusal, sentence), state)
    end
  end

  # -- the upload ---------------------------------------------------------------------

  defp part(%{"id" => id} = fields, bytes, state) do
    case Map.fetch(state.uploads, id) do
      {:ok, upload} -> took_part(upload, fields, bytes, state)
      :error -> state
    end
  end

  defp took_part(upload, %{"index" => index, "last" => last, "size_bytes" => size}, bytes, state) do
    received = upload.received + byte_size(bytes)

    if index == upload.next and size == upload.size and received <= upload.size,
      do:
        part_taken(
          %{upload | next: index + 1, received: received, parts: [bytes | upload.parts]},
          last,
          state
        ),
      else: upload_failed(upload, state)
  end

  defp part_taken(upload, false, state),
    do: %{state | uploads: Map.put(state.uploads, upload.entry.id, upload)}

  defp part_taken(upload, true, state) do
    bytes = upload.parts |> Enum.reverse() |> IO.iodata_to_binary()
    state = %{state | uploads: Map.delete(state.uploads, upload.entry.id)}

    if byte_size(bytes) == upload.size and sha256(bytes) == upload.sha256,
      do: uploaded(Map.put(upload.entry, :part_bytes, bytes), bytes, state),
      else: answer(upload.entry, upload_outcome(), state)
  end

  defp uploaded(entry, bytes, state) do
    if slot_free?(state),
      do: waited(entry, bytes, state),
      else: queue(state, entry)
  end

  defp upload_failed(upload, state) do
    state = %{state | uploads: Map.delete(state.uploads, upload.entry.id)}
    answer(upload.entry, upload_outcome(), state)
  end

  defp upload_outcome, do: %Outcome{status: :failed, message: sentence(:upload_lost)}

  # -- running ----------------------------------------------------------------------

  # The started record is synced before the run; without it nothing runs.
  defp start(entry, part, state) do
    started_at = state.clock.()

    case record_started(entry, started_at, state) do
      :ok ->
        :ok = forget_waiting(entry.id, state)
        launch(Map.put(entry, :started_at, started_at), part, state)

      {:error, reason} ->
        Logger.error("invocation #{entry.id} did not run: its journal: #{inspect(reason)}")
        answer(entry, %Outcome{status: :failed, message: sentence(:not_recorded)}, state)
    end
  end

  # The run's own process first applies the capability's rules, which may
  # read the owner's folders, then runs it: neither ever holds this process.
  defp launch(entry, part, state) do
    {:ok, args} = entry.args
    context = context(entry, switches(state), state)
    module = entry.module
    op = entry.op

    task =
      Task.Supervisor.async_nolink(state.runs, fn ->
        with :ok <- module.admit(op, args, context), do: module.run(op, args, part, context)
      end)

    %{
      state
      | running: Map.put(state.running, entry.id, Map.put(entry, :task, task)),
        tasks: Map.put(state.tasks, task.ref, entry.id)
    }
  end

  defp ran(id, result, state) do
    {entry, state} = pop_running(id, state)
    answer(entry, outcome(result, entry), state) |> next()
  end

  defp crashed(id, reason, state) do
    {entry, state} = pop_running(id, state)
    outcome = crash_outcome(entry, switches(state))

    if outcome.status == :failed,
      do: Logger.error("invocation #{id} stopped: #{inspect(reason)}"),
      else: Logger.info("invocation #{id} ended with its switch off: #{inspect(reason)}")

    answer(entry, outcome, state) |> next()
  end

  # A run that ended while the switches no longer let its capability run was
  # ended by them, and is answered as they would have ended it: the master
  # off as stopped here, its offer off as a request of it now; else failed.
  defp crash_outcome(entry, switches) do
    with true <- Switches.enabled?(switches),
         :ok <- switched_on(entry, switches) do
      %Outcome{status: :failed, message: sentence(:crashed)}
    else
      false -> Outcome.refused(:stopped_here, sentence(:stopped_here))
      {:refused, refusal, sentence} -> Outcome.refused(refusal, sentence)
    end
  end

  defp pop_running(id, state) do
    {entry, running} = Map.pop!(state.running, id)
    {entry, %{state | running: running}}
  end

  defp outcome({:ok, result, part}, entry) when is_map(result) do
    if within_bounds?(result, part, entry),
      do: %Outcome{status: :ok, result: result, part_bytes: part},
      else: %Outcome{status: :failed, message: sentence(:answer_too_large)}
  end

  defp outcome({:failed, sentence}, _entry) when is_binary(sentence),
    do: %Outcome{status: :failed, message: sentence}

  # It ran and failed with a result of its own (a tool's error): failed, never
  # ok, its result and part carried within the same bounds, else its message
  # alone.
  defp outcome({:failed, sentence, result, part}, entry)
       when is_binary(sentence) and is_map(result) do
    if within_bounds?(result, part, entry),
      do: %Outcome{status: :failed, message: sentence, result: result, part_bytes: part},
      else: %Outcome{status: :failed, message: sentence}
  end

  defp outcome({:refused, refusal, sentence}, _entry) when is_binary(sentence),
    do: Outcome.refused(refusal, sentence)

  defp outcome(other, entry) do
    Logger.error("invocation #{entry.id}: #{entry.capability} answered #{inspect(other)}")
    %Outcome{status: :failed, message: sentence(:unsendable)}
  end

  defp within_bounds?(result, part, entry) do
    %{result_bytes: max_result, part_bytes: max_part} = entry.module.bounds(entry.op)
    payload_bytes = byte_size(Jason.encode!(result))
    part_size = if is_binary(part), do: byte_size(part), else: 0
    payload_bytes <= min(max_result, Outcome.max_result_bytes()) and part_size <= max_part
  end

  # Past its deadline: what runs is stopped, what waits never runs.
  defp deadline(id, state) do
    cond do
      Map.has_key?(state.running, id) ->
        stop_running(id, %Outcome{status: :timed_out}, state) |> next()

      Map.has_key?(state.uploads, id) ->
        drop_upload(id, %Outcome{status: :timed_out}, state)

      waiting?(id, state) ->
        drop_waiting(id, %Outcome{status: :timed_out}, state)

      true ->
        state
    end
  end

  # Past its deadline, cancelled, or ended by a switch: the run is stopped
  # beside this process and answered `outcome` once it ended, its slot held
  # until then.
  defp stop_running(id, outcome, state) do
    {entry, state} = pop_running(id, state)
    Process.demonitor(entry.task.ref, [:flush])
    stopper = stop_task(entry, state)

    %{
      state
      | tasks: Map.delete(state.tasks, entry.task.ref),
        stopping: Map.put(state.stopping, stopper.ref, {entry, outcome})
    }
  end

  defp run_stopped(ref, state) do
    {{entry, outcome}, stopping} = Map.pop!(state.stopping, ref)
    answer(entry, outcome, %{state | stopping: stopping}) |> next()
  end

  # The capability lets go of what the run holds, then the run is ended, in a
  # process of its own: a letting go that hangs or fails never holds or ends
  # this one.
  defp stop_task(%{task: task, module: module, op: op}, state) do
    runs = state.runs
    Task.Supervisor.async_nolink(runs, fn -> stop_run(module, op, task.pid, runs) end)
  end

  defp stop_run(module, op, pid, runs) do
    :ok = let_go(module, op, pid)

    case Task.Supervisor.terminate_child(runs, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp let_go(module, op, pid) do
    if function_exported?(module, :cancel, 2), do: module.cancel(op, pid), else: :ok
  catch
    :exit, reason ->
      Logger.warning("a run of #{op} did not let go of what it held: #{inspect(reason)}")
      :ok
  end

  defp drop_upload(id, outcome, state) do
    {upload, uploads} = Map.pop!(state.uploads, id)
    answer(upload.entry, outcome, %{state | uploads: uploads})
  end

  defp drop_waiting(id, outcome, state) do
    {[entry], rest} = Enum.split_with(:queue.to_list(state.waiting), &(&1.id == id))
    answer(entry, outcome, %{state | waiting: :queue.from_list(rest)})
  end

  # -- cancel, status and the master switch ------------------------------------------

  # Exactly one answer: cancelled, or what was reached first.
  defp cancel(id, state) do
    cond do
      Map.has_key?(state.running, id) ->
        stop_running(id, %Outcome{status: :cancelled}, state) |> next()

      Map.has_key?(state.uploads, id) ->
        drop_upload(id, %Outcome{status: :cancelled}, state)

      waiting?(id, state) ->
        drop_waiting(id, %Outcome{status: :cancelled}, state)

      # Being stopped already: answered once it ended.
      stopping?(id, state) ->
        state

      true ->
        status(id, state)
    end
  end

  defp status(id, state) do
    now = state.clock.()

    cond do
      Map.has_key?(state.running, id) or Map.has_key?(state.uploads, id) or waiting?(id, state) or
          stopping?(id, state) ->
        state

      held?(state, id, now) ->
        resend(Map.fetch!(state.held, id), state)

      true ->
        from_journal(id, state)
    end
  end

  defp from_journal(id, state) do
    case Journal.lookup(state.dir, id) do
      {:ok, entry} ->
        send_answer(receipt_answer(entry), Outcome.receipt_only_payload(), nil, state)

      :none ->
        send_answer(%{"id" => id, "status" => "unknown", "duration_ms" => 0}, "{}", nil, state)

      {:error, reason} ->
        Logger.error("invocation #{id}: the journal could not be read: #{inspect(reason)}")
        send_answer(%{"id" => id, "status" => "unknown", "duration_ms" => 0}, "{}", nil, state)
    end

    state
  end

  # What the journal recorded, with a sentence where the status needs one:
  # the journal holds no content.
  defp receipt_answer(entry) do
    status = entry.status || "unknown"

    %{
      "id" => entry.id,
      "status" => status,
      "duration_ms" => entry.duration_ms || 0,
      "receipt" => %{"at" => entry.at, "target" => entry.target}
    }
    |> put_some("refusal", if(status == "refused", do: entry.refusal))
    |> put_some("message", receipt_message(status))
  end

  defp receipt_message("failed"), do: sentence(:receipt_failed)
  defp receipt_message("refused"), do: sentence(:receipt_refused)
  defp receipt_message("unknown"), do: sentence(:receipt_unknown)
  defp receipt_message(_status), do: nil

  defp stopped(state) do
    outcome = Outcome.refused(:stopped_here, sentence(:stopped_here))
    state = Enum.reduce(Map.keys(state.running), state, &stop_running(&1, outcome, &2))
    state = Enum.reduce(Map.keys(state.uploads), state, &drop_upload(&1, outcome, &2))
    ids = for entry <- :queue.to_list(state.waiting), do: entry.id
    Enum.reduce(ids, state, &drop_waiting(&1, outcome, &2))
  end

  # An offer's own switch off, the master on: each capability's work, running
  # or waiting, is held to the rule it was admitted by (`switched_on/2`), and
  # what that rule now refuses ends with its refusal (`off`, the sentence a
  # request of it arriving now gets). What then has a slot starts.
  defp offer_switched_off(switches, state) do
    running = for {id, entry} <- state.running, do: {:running, id, entry}
    uploads = for {id, upload} <- state.uploads, do: {:upload, id, upload.entry}
    waiting = for entry <- :queue.to_list(state.waiting), do: {:waiting, entry.id, entry}

    refused =
      for {where, id, entry} <- running ++ uploads ++ waiting,
          {:refused, refusal, sentence} <- [switched_on(entry, switches)],
          do: {where, id, Outcome.refused(refusal, sentence)}

    refused
    |> Enum.reduce(state, fn {where, id, outcome}, acc -> end_work(where, id, outcome, acc) end)
    |> next()
  end

  defp end_work(:running, id, outcome, state), do: stop_running(id, outcome, state)
  defp end_work(:upload, id, outcome, state), do: drop_upload(id, outcome, state)
  defp end_work(:waiting, id, outcome, state), do: drop_waiting(id, outcome, state)

  # -- recording and answering ---------------------------------------------------------

  # The finished record is synced, the run's bookend emitted, the answer
  # held and then sent.
  defp answer(entry, %Outcome{} = outcome, state) do
    now = state.clock.()
    duration = max(DateTime.diff(now, entry.arrived_at, :millisecond), 0)
    receipt = %{at: Map.get(entry, :started_at, now), target: entry.target}
    {fields, payload} = to_wire(outcome, entry, duration, receipt)
    part = outcome.part_bytes
    bytes = byte_size(payload) + if(is_binary(part), do: byte_size(part), else: 0)

    :ok = record_finished(entry, outcome, now, duration, bytes, state)
    :ok = Telemetry.finished(meta(entry), %{outcome | duration_ms: duration}, bytes)
    held = %{fields: fields, payload: payload, part: part, at: now, bytes: bytes}
    send_answer(fields, payload, part, state)
    # Let go only once recorded and on its way: a restart in between answers
    # it again, never not at all.
    :ok = forget_waiting(entry.id, state)
    hold(entry.id, held, state)
  end

  defp to_wire(outcome, entry, duration, receipt) do
    announce = if is_binary(outcome.part_bytes), do: announce(outcome.part_bytes)

    Outcome.to_wire(%{
      outcome
      | invocation: entry.id,
        duration_ms: duration,
        receipt: receipt,
        part: announce
    })
  end

  defp announce(bytes),
    do: %{size_bytes: byte_size(bytes), sha256: sha256(bytes), mime: "application/octet-stream"}

  # A request its capability says is no thing done here has no record.
  defp record_started(%{recorded?: false}, _at, _state), do: :ok

  defp record_started(entry, at, state),
    do: Journal.append_started(state.dir, started_record(entry, at))

  defp record_finished(%{recorded?: false}, _outcome, _now, _duration, _bytes, _state), do: :ok

  defp record_finished(entry, outcome, now, duration, bytes, state) do
    record =
      %{
        id: entry.id,
        at: now,
        status: outcome.status,
        refusal: outcome.refusal,
        result_bytes: bytes,
        duration_ms: duration
      }
      |> Map.merge(never_started(entry))

    case Journal.append_finished(state.dir, record) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("invocation #{entry.id}: its end was not journaled: #{inspect(reason)}")
    end
  end

  # A request that never started names itself in its one record.
  defp never_started(%{started_at: _at}), do: %{}

  defp never_started(entry),
    do: %{capability: entry.capability, op: entry.op, target: entry.target, origin: entry.origin}

  defp started_record(entry, at) do
    %{
      id: entry.id,
      at: at,
      capability: entry.capability,
      op: entry.op,
      target: entry.target,
      origin: entry.origin,
      epoch: entry.epoch,
      turn_session: entry.turn && entry.turn.session_id
    }
  end

  defp resend(held, state) do
    send_answer(held.fields, held.payload, held.part, state)
    state
  end

  # Sent by a task of its own: a slow link never holds this process.
  defp send_answer(fields, payload, part, state) do
    send = state.send
    relay = state.relay
    event = Map.put(fields, "t", "invoke_result")

    {:ok, _pid} =
      Task.Supervisor.start_child(state.runs, fn -> deliver(send, relay, event, payload, part) end)

    :ok
  end

  # The server hears this process started (`invoke_restarted`), so each
  # caller still waiting on this computer asks about its request: one that
  # was on its way while this process was down, or that waited when
  # `Desktop.Invoke` itself restarted, has no record here and is answered so.
  # With no session it is not sent: the next session's start asks the same.
  defp tell_started(state) do
    send = state.send
    relay = state.relay

    {:ok, _pid} =
      Task.Supervisor.start_child(state.runs, fn ->
        case send.(relay, %{"t" => "invoke_restarted"}, <<>>) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.info("the server was not told of this start: #{inspect(reason)}")
        end
      end)

    :ok
  end

  # The answer, then its part a frame at a time; the first refusal ends it,
  # and the server asks again after its session comes back.
  defp deliver(send, relay, %{"id" => id} = event, payload, part) do
    with :ok <- send.(relay, event, payload),
         :ok <- deliver_part(send, relay, id, part) do
      :ok
    else
      {:error, reason} ->
        Logger.info("invocation #{id}: its answer was not sent: #{inspect(reason)}")
    end
  end

  defp deliver_part(_send, _relay, _id, nil), do: :ok

  defp deliver_part(send, relay, id, part) do
    size = byte_size(part)

    part
    |> Chunks.split(@part_chunk_bytes)
    |> Enum.reduce_while(:ok, fn {index, last, bytes}, :ok ->
      event = %{
        "t" => "invoke_part",
        "id" => id,
        "index" => index,
        "last" => last,
        "size_bytes" => size
      }

      case send.(relay, event, bytes) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # -- held answers --------------------------------------------------------------------

  defp hold(id, held, state) do
    now = held.at
    kept = state.held |> Map.reject(fn {_id, old} -> expired?(old, now) end) |> Map.put(id, held)
    %{state | held: within_bounds(kept)}
  end

  defp held?(state, id, now) do
    case Map.fetch(state.held, id) do
      {:ok, held} -> not expired?(held, now)
      :error -> false
    end
  end

  defp expired?(held, now), do: DateTime.diff(now, held.at, :millisecond) > @held_ms

  # The oldest go first, until the count and the bytes are within bounds.
  defp within_bounds(held) do
    total = Enum.reduce(held, 0, fn {_id, one}, sum -> sum + one.bytes end)

    if map_size(held) <= @max_held and total <= @max_held_bytes do
      held
    else
      {oldest, _one} =
        Enum.min_by(held, fn {_id, one} -> DateTime.to_unix(one.at, :microsecond) end)

      within_bounds(Map.delete(held, oldest))
    end
  end

  # -- the facts ---------------------------------------------------------------------

  defp switches(state), do: state.switches.()

  defp context(entry, switches, state) do
    %{
      id: entry.id,
      origin: entry.origin,
      epoch: entry.epoch,
      turn: entry.turn,
      home: state.home,
      switches: switches,
      sandbox: state.sandbox.(),
      browser: browser(state),
      notifications: state.notifications,
      clock: state.clock,
      deadline_ms: entry.deadline_ms
    }
  end

  # This computer's browser, read at each request (`Desktop.Invoke`'s
  # `:browser`); nil where it was given none.
  defp browser(%{browser: nil}), do: nil
  defp browser(%{browser: read}) when is_function(read, 0), do: read.()

  defp meta(entry) do
    %{
      id: entry.id,
      capability: entry.capability,
      op: entry.op,
      origin: entry.origin,
      epoch: entry.epoch,
      parent_session: entry.turn && entry.turn.session_id
    }
  end

  defp link_epoch(home) do
    with {:ok, link} <- DesktopLink.read(home), do: {:ok, link.epoch}
  end

  defp machine do
    case :os.type() do
      {:unix, :darwin} -> "Mac"
      _other -> "computer"
    end
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  # -- what the server's model reads ----------------------------------------------

  @said [
    :stale_epoch,
    :link_unread,
    :unknown_op,
    :no_deadline,
    :no_turn,
    :args_not_object,
    :busy,
    :upload_lost,
    :not_recorded,
    :crashed,
    :answer_too_large,
    :unsendable,
    :receipt_failed,
    :receipt_refused,
    :receipt_unknown,
    :stopped_here,
    :restarted
  ]

  @doc """
  Every sentence this module puts in an answer's `message`, which the
  server's model reads: one place, held to the copy rules. An offer's
  refusal is in that offer's words (`FermixCore.Computers.Offers`).
  """
  @spec sentences() :: [String.t(), ...]
  def sentences, do: Enum.map(@said, &sentence/1)

  defp sentence(:stale_epoch),
    do: "This computer has seen a newer copy of its home than the one that asked."

  defp sentence(:link_unread), do: "This computer cannot read its link to its server."
  defp sentence(:unknown_op), do: "Fermix on this computer does not know how to do that."
  defp sentence(:no_deadline), do: "This request names no deadline, and it needs one."
  defp sentence(:no_turn), do: "This request names no turn, and it needs one."
  defp sentence(:args_not_object), do: "The request's arguments are not a JSON object."
  defp sentence(:busy), do: "This computer is running as much as it allows right now."
  defp sentence(:upload_lost), do: "The upload did not arrive whole."

  defp sentence(:not_recorded),
    do: "This computer could not record the request, so it did not run it."

  defp sentence(:crashed), do: "It stopped before it finished. The computer's log says why."
  defp sentence(:answer_too_large), do: "The answer is larger than this computer sends."
  defp sentence(:unsendable), do: "It answered in a way this computer cannot send."

  defp sentence(:receipt_failed),
    do: "It failed, and this computer no longer holds what it said."

  defp sentence(:receipt_refused), do: "This computer refused it."
  defp sentence(:receipt_unknown), do: "Fermix on this computer stopped while it ran."
  defp sentence(:stopped_here), do: "The person at this computer stopped it."

  defp sentence(:restarted),
    do: "Fermix on this computer restarted before it ran this, so it did not run."
end
