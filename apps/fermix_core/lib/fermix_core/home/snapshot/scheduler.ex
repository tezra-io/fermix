defmodule FermixCore.Home.Snapshot.Scheduler do
  @moduledoc """
  Writes the primary's snapshots on its cadence (M75 §8): every
  `interval_hours` of `[fermix_core.snapshots]`, one run at a time, to every
  target that is on (`Snapshot.Target`: the S3 target, then the connected
  desktops, `targets/0`).

  **Primary only.** A device-role boot leaves it out (`Home.Role`): a device's
  home is a retired copy. In the device role `home.snapshots.run` answers that
  snapshots are the primary's.

  **When.** The next run is the last attempt plus the interval, read back from
  the status file at boot, and never sooner than #{div(300, 60)} minutes after
  the scheduler starts, so a restart loop is not a snapshot loop; a home that
  never ran one starts its first that long after boot. The one exception is
  the status file's `run_at_boot`, which a move's activation writes: the new
  primary's first boot runs at once, so it holds a verified snapshot as soon as
  it can, and the request is cleared when that run starts, so it is asked only
  once. A run that fails is
  recorded with its sentence and the next one comes one interval after it
  started, as a verified one does. Nothing runs while the section names no
  recipient or no target; `config_changed/1` (called by the writers of the
  section) plans again at once. `run_now/1` starts one at once unless one is
  running (`{:error, :busy}`).

  **A backup a week old.** After each run, once the newest verified point of
  any target is seven days old, the phones are told, once per occurrence (M75
  lean v1 §7): the summary's sentence (`Management.Copy`) goes through the
  phones' own push path, a message in the owner's phone chat that every
  paired phone away from it is pushed (`FermixChannels.Channels.Mobile`,
  reached through `[:fermix_core, :jobs, :delivery_channels]`). The point told
  is kept in the status (`stale_notice`), so a later point that grows as old
  is told again; a push the phones did not get is logged and tried again at
  the next run. The message carries the point as its proactive key, so a
  retry after a push whose record was lost writes no second one.

  **One writer.** The run is a task under `FermixCore.TaskSupervisor`; this
  process alone writes the status file (`Snapshot.Status`), from the answer the
  task returns, or from its exit when it crashed. The clock and the timer are
  injected (`:now`, `:timer`), so tests deliver a tick by hand, and so is the
  push (`:notify`).

  **The Always On watch.** A finished run moved the newest backup the Always
  On summary reads, so once the status file holds it the scheduler tells
  `Home.StatusWatch` (`:status_changed`, its 0-arity stand-in).
  """

  use GenServer

  alias FermixCore.Delivery.ChannelSend
  alias FermixCore.Home.Snapshot.Config
  alias FermixCore.Home.Snapshot.Run
  alias FermixCore.Home.Snapshot.S3
  alias FermixCore.Home.Snapshot.Status
  alias FermixCore.Home.StatusWatch
  alias FermixCore.Management.Copy
  alias FermixCore.Setup.ConfigStore

  require Logger

  @boot_delay_s 300
  @crashed "The snapshot run stopped unexpectedly; Fermix's log says why."
  @hour_s 3_600
  @day_s 86_400
  @stale_notice_s 7 * @day_s
  @push_timeout_ms 10_000

  @type state :: %{
          home: Path.t(),
          config: (-> keyword()),
          targets: [module()],
          now: (-> DateTime.t()),
          timer: (term(), non_neg_integer() -> reference()) | nil,
          run: (Path.t(), keyword(), [module()], keyword() ->
                  {:ok, Run.result()} | :not_configured),
          run_opts: keyword(),
          task_supervisor: GenServer.server(),
          notify: (String.t(), String.t() -> :ok | {:error, term()}),
          status_changed: (-> :ok),
          started_at: DateTime.t(),
          task: reference() | nil,
          token: reference() | nil,
          next_run_at: DateTime.t() | nil
        }

  @doc """
  The targets the engine writes to, in order: S3, then those configured at
  `:snapshot_targets` (the desktops over the rail, which `fermix_core` does
  not compile against: `FermixChannels.Desktop.SnapshotTarget`).
  """
  @spec targets() :: [module()]
  def targets, do: [S3 | Application.fetch_env!(:fermix_core, :snapshot_targets)]

  @doc """
  Starts the scheduler. `opts`: `:name`, `:home`, `:config` (a 0-arity reader
  of the section), `:targets`, `:now` (a 0-arity clock), `:timer_enabled`
  (false keeps it from planning timers: a test tree), `:timer` (a 2-arity
  `send_after` in its place, given the message and the delay in ms), `:run`
  (`Run.run/4` in its place), `:run_opts` (passed to every run: `:profile`,
  `:host`, a target's seams), `:task_supervisor`, `:notify` (a 2-arity
  push of a sentence and its proactive key to the phones, in place of their
  push path) and `:status_changed` (a 0-arity call in place of telling the
  Always On watch).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Starts a run now: `{:error, :busy}` while one runs, `:not_configured` with nothing to do."
  @spec run_now(GenServer.server()) :: {:ok, :started} | {:error, :busy | :not_configured}
  def run_now(server \\ __MODULE__), do: GenServer.call(server, :run_now)

  @doc "Whether a run is going and when the next one is planned."
  @spec info(GenServer.server()) :: %{running: boolean(), next_run_at: DateTime.t() | nil}
  def info(server \\ __MODULE__), do: GenServer.call(server, :info)

  @doc "Plans the next run again after the section changed. A no-op when no scheduler runs."
  @spec config_changed(GenServer.server()) :: :ok
  def config_changed(server \\ __MODULE__) do
    if GenServer.whereis(server), do: GenServer.cast(server, :config_changed)
    :ok
  end

  @impl true
  def init(opts) do
    now = Keyword.get(opts, :now, &DateTime.utc_now/0)

    state = %{
      home: Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0),
      config:
        Keyword.get(opts, :config, fn -> Application.get_env(:fermix_core, :snapshots, []) end),
      targets: Keyword.get(opts, :targets, targets()),
      now: now,
      timer: timer(opts),
      run: Keyword.get(opts, :run, &Run.run/4),
      run_opts: Keyword.get(opts, :run_opts, []),
      task_supervisor: Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor),
      notify: Keyword.get(opts, :notify, &push_to_phones/2),
      status_changed:
        Keyword.get(opts, :status_changed, fn -> StatusWatch.changed(:snapshots) end),
      started_at: now.(),
      task: nil,
      token: nil,
      next_run_at: nil
    }

    {:ok, first_plan(state)}
  end

  @impl true
  def handle_call(:run_now, _from, %{task: task} = state) when task != nil,
    do: {:reply, {:error, :busy}, state}

  def handle_call(:run_now, _from, state) do
    case configured?(state) do
      true -> {:reply, {:ok, :started}, start_run(state)}
      false -> {:reply, {:error, :not_configured}, state}
    end
  end

  def handle_call(:info, _from, state),
    do: {:reply, %{running: state.task != nil, next_run_at: state.next_run_at}, state}

  @impl true
  def handle_cast(:config_changed, %{task: nil} = state),
    do: {:noreply, plan(state, last_attempt_at(state))}

  def handle_cast(:config_changed, state), do: {:noreply, state}

  @impl true
  def handle_info({:tick, token}, %{token: token, task: nil} = state) do
    if configured?(state),
      do: {:noreply, start_run(%{state | token: nil})},
      else: {:noreply, plan(%{state | token: nil}, nil)}
  end

  def handle_info({:tick, _stale_or_busy}, state), do: {:noreply, state}

  def handle_info({ref, answer}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finished(state, answer)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: ref} = state) do
    Logger.error("home snapshot: the run stopped: #{inspect(reason)}")
    {:noreply, finished(state, {:crashed, reason})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_run(state) do
    %{home: home, run: run, targets: targets, run_opts: run_opts} = state
    record(state, &%{&1 | run_at_boot: false})
    config = state.config.()
    opts = Keyword.put(run_opts, :now, state.now)

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        run.(home, config, targets, opts)
      end)

    %{state | task: task.ref, next_run_at: nil}
  end

  defp finished(state, {:ok, %{started_at: started_at, outcomes: outcomes} = result}) do
    facts = %{at: started_at, written: result.written, key_id: result.key_id}

    record(state, fn status ->
      Enum.reduce(outcomes, status, &record_outcome(&1, &2, facts))
    end)

    :ok = notice_stale(state)
    :ok = state.status_changed.()
    plan(%{state | task: nil}, started_at)
  end

  defp finished(state, :not_configured), do: plan(%{state | task: nil}, nil)

  defp finished(state, {:crashed, _reason}) do
    at = DateTime.truncate(state.now.(), :second)
    config = state.config.()
    on = Enum.filter(state.targets, &match?({:ok, _settings}, &1.configured(config)))

    record(state, fn status ->
      Enum.reduce(
        on,
        status,
        &Status.record(&2, &1.id(), attempt(:failed, at, nil, nil, @crashed))
      )
    end)

    plan(%{state | task: nil}, at)
  end

  # The phones hear once when the newest verified point passes seven days,
  # and again only for a later point grown as old.
  defp notice_stale(state) do
    case Status.read(state.home) do
      {:ok, status} ->
        notice_stale(state, status, Status.newest_verified(status))

      {:error, reason} ->
        Logger.error("home snapshot: the status could not be read: #{inspect(reason)}")
        :ok
    end
  end

  defp notice_stale(_state, _status, nil), do: :ok

  defp notice_stale(state, status, at) do
    age = DateTime.diff(state.now.(), at, :second)
    told? = status.stale_notice != nil and DateTime.compare(status.stale_notice, at) == :eq

    if age >= @stale_notice_s and not told?,
      do: tell_phones(state, at, div(age, @day_s)),
      else: :ok
  end

  defp tell_phones(state, at, days) do
    key = "backup_stale:" <> DateTime.to_iso8601(at)

    case state.notify.(Copy.summary_sentence(:backup_push, %{days: days}), key) do
      :ok ->
        record(state, &%{&1 | stale_notice: at})

      {:error, reason} ->
        Logger.warning(
          "home snapshot: the phones were not told the last backup is #{days} days old " <>
            "(#{inspect(reason)}); the next run tries again"
        )
    end

    :ok
  end

  # The phones' own push path: a message in the owner's phone chat, pushed to
  # every paired phone that is away from it, while the phones' channel runs.
  defp push_to_phones(sentence, key) do
    channels =
      :fermix_core |> Application.get_env(:jobs, []) |> Keyword.get(:delivery_channels, %{})

    with {:ok, adapter} <- ChannelSend.resolve_adapter("mobile", channels: channels),
         {:ok, profile} <- phone_chat(adapter) do
      ChannelSend.with_timeout(@push_timeout_ms, fn ->
        ChannelSend.send("mobile", profile, sentence, [proactive_key: key], channels: channels)
      end)
    end
  end

  defp phone_chat(adapter) do
    case adapter.owner_inbox() do
      {:ok, profile} -> {:ok, profile}
      :unavailable -> {:error, :phones_off}
    end
  end

  defp record_outcome({target, {:ok, stored}}, status, facts) do
    attempt = attempt(:verified, facts.at, facts.written, facts.key_id, nil)
    Status.record(status, target.id(), %{attempt | location: stored.location})
  end

  defp record_outcome({target, {:waiting, sentence}}, status, facts) do
    attempt = attempt(:waiting, facts.at, facts.written, facts.key_id, nil)
    Status.record(status, target.id(), Map.put(attempt, :note, sentence))
  end

  defp record_outcome({target, {:error, sentence}}, status, facts),
    do:
      Status.record(
        status,
        target.id(),
        attempt(:failed, facts.at, facts.written, facts.key_id, sentence)
      )

  defp attempt(result, at, written, key_id, error) do
    %{
      at: at,
      result: result,
      name: written && written.name,
      epoch: written && written.epoch,
      size: written && written.size,
      sha256: written && written.sha256,
      location: nil,
      key_id: key_id,
      error: error,
      note: nil
    }
  end

  # The next run, from the last attempt (nil: never, or not known), planned
  # only while the section turns snapshots on, and recorded in the status
  # file so a surface reading it without the engine still shows it. A
  # scheduler with no timer (a test tree) plans nothing and writes nothing.
  defp plan(%{timer: nil} = state, _last_at), do: %{state | next_run_at: nil, token: nil}

  defp plan(state, last_at) do
    next = if configured?(state), do: next_run_at(state, last_at)
    record(state, &%{&1 | next_run_at: next})
    schedule(%{state | next_run_at: next})
  end

  # The first plan of this start: at once when a move's activation asked for
  # it (`run_at_boot`), otherwise from the last attempt.
  defp first_plan(state) do
    case Status.read(state.home) do
      {:ok, %{run_at_boot: true}} -> plan_now(state)
      _other -> plan(state, last_attempt_at(state))
    end
  end

  defp plan_now(%{timer: nil} = state), do: plan(state, nil)

  defp plan_now(state) do
    if configured?(state) do
      next = DateTime.truncate(state.now.(), :second)
      record(state, &%{&1 | next_run_at: next})
      schedule(%{state | next_run_at: next})
    else
      plan(state, last_attempt_at(state))
    end
  end

  defp next_run_at(state, last_at) do
    now = state.now.()
    earliest = DateTime.add(state.started_at, @boot_delay_s, :second)
    due = if last_at, do: DateTime.add(last_at, interval_s(state), :second), else: earliest

    [due, earliest, now]
    |> Enum.max(DateTime)
    |> DateTime.truncate(:second)
  end

  defp schedule(%{next_run_at: nil} = state), do: %{state | token: nil}

  defp schedule(state) do
    token = make_ref()
    delay = max(DateTime.diff(state.next_run_at, state.now.(), :millisecond), 0)
    state.timer.({:tick, token}, delay)
    %{state | token: token}
  end

  defp record(state, fun) do
    with {:ok, status} <- Status.read(state.home),
         :ok <- Status.write(state.home, fun.(status)) do
      :ok
    else
      {:error, reason} ->
        Logger.error("home snapshot: the status was not written: #{inspect(reason)}")
    end
  end

  defp last_attempt_at(state) do
    case Status.read(state.home) do
      {:ok, %{targets: targets}} ->
        targets
        |> Map.values()
        |> Enum.flat_map(fn entry -> List.wrap(entry.last_attempt && entry.last_attempt.at) end)
        |> Enum.max(DateTime, fn -> nil end)

      {:error, reason} ->
        Logger.error("home snapshot: the status could not be read: #{inspect(reason)}")
        nil
    end
  end

  defp configured?(state) do
    config = state.config.()

    Keyword.has_key?(config, :recipient) and
      Enum.any?(state.targets, &match?({:ok, _settings}, &1.configured(config)))
  end

  defp interval_s(state), do: Config.interval_hours(state.config.()) * @hour_s

  defp timer(opts) do
    cond do
      Keyword.get(opts, :timer_enabled, true) == false -> nil
      timer = Keyword.get(opts, :timer) -> timer
      true -> &send_after/2
    end
  end

  defp send_after(message, delay), do: Process.send_after(self(), message, delay)
end
