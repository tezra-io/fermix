defmodule FermixCore.Home.Snapshot.SchedulerTest do
  # The cadence with an injected clock and timer: nothing waits on time. A tick
  # is delivered by hand with the token the scheduler planned, and a run goes
  # through the real capture into a stand-in target.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Home.Snapshot.Run
  alias FermixCore.Home.Snapshot.Scheduler
  alias FermixCore.Home.Snapshot.Status
  alias FermixTestSupport.SafeRm

  @boot ~U[2026-10-27 09:00:00Z]
  @wait 10_000

  defmodule FakeTarget do
    @moduledoc false
    @behaviour FermixCore.Home.Snapshot.Target

    @impl true
    def id, do: "fake"
    @impl true
    def label, do: "the stand-in"

    @impl true
    def configured(config) do
      case Keyword.get(config, :s3_bucket) do
        nil -> :not_configured
        bucket -> {:ok, %{bucket: bucket}}
      end
    end

    @impl true
    def destination(settings, _opts), do: "fake://#{settings.bucket}/"

    # The test process named in the run options is told what arrived; a
    # bucket named "refuse" refuses.
    @impl true
    def store(snapshot, %{bucket: bucket}, opts) do
      send(Keyword.fetch!(opts, :test), {:stored, snapshot, File.read!(snapshot.path)})

      case bucket do
        "refuse" -> {:error, {:refused, 403, "AccessDenied", "Access Denied"}}
        "asleep" -> {:waiting, :asleep}
        _kept -> {:ok, %{location: "fake://#{bucket}/#{snapshot.name}"}}
      end
    end

    @impl true
    def sentence({:refused, status, code, message}),
      do: "The stand-in refused it (#{status} #{code}): #{message}."

    def sentence(:asleep), do: "The stand-in is asleep; the snapshot waits for the next run."
  end

  setup_all do
    %{pair: Recipient.generate()}
  end

  setup %{pair: pair} do
    tmp = SafeRm.make_tmp_dir!("snapshot_scheduler")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)

    home = Path.join(tmp, "home")
    File.mkdir_p!(home)
    File.write!(Path.join(home, "config.toml"), "[fermix_core]\n")
    :ok = Epoch.write(home, 2)

    {:ok, clock} = Agent.start_link(fn -> @boot end)
    {:ok, config} = Agent.start_link(fn -> configured(pair, "kept") end)

    %{home: home, clock: clock, config: config}
  end

  test "a home that never ran plans its first run five minutes after boot, and runs it",
       %{home: home} = context do
    scheduler = start!(context)

    assert_receive {:planned, {:tick, token}, 300_000}
    assert %{next_run_at: ~U[2026-10-27 09:05:00Z], running: false} = Scheduler.info(scheduler)
    assert {:ok, %{next_run_at: ~U[2026-10-27 09:05:00Z]}} = Status.read(home)

    advance(context, 300)
    send(scheduler, {:tick, token})

    assert_receive {:stored, snapshot, bytes}, @wait
    assert snapshot.epoch == 2
    assert snapshot.name == "20261027T090500Z-e2.fxsnap"
    assert byte_size(bytes) == snapshot.size

    # The next run is one interval after this one started.
    assert_receive {:planned, {:tick, _next}, delay}, @wait
    assert delay == 6 * 3_600_000

    assert {:ok, status} = Status.read(home)
    assert status.next_run_at == ~U[2026-10-27 15:05:00Z]

    assert %{
             last_attempt: %{result: :verified, location: "fake://kept/" <> _name},
             last_verified: %{epoch: 2, sha256: sha256},
             last_error: nil
           } = status.targets["fake"]

    assert sha256 == snapshot.sha256
    # The encrypted file went once the target had it.
    assert hidden(home) == []
  end

  test "a failure is recorded with its sentence and retried at the next interval",
       %{config: config, pair: pair, home: home} = context do
    Agent.update(config, fn _ -> configured(pair, "refuse") end)
    scheduler = start!(context)
    assert_receive {:planned, {:tick, token}, _delay}

    advance(context, 300)
    send(scheduler, {:tick, token})
    assert_receive {:stored, _snapshot, _bytes}, @wait
    assert_receive {:planned, {:tick, _next}, delay}, @wait
    assert delay == 6 * 3_600_000

    assert {:ok, %{targets: %{"fake" => entry}}} = Status.read(home)
    assert entry.last_verified == nil
    assert entry.last_attempt.result == :failed
    assert entry.last_error == "The stand-in refused it (403 AccessDenied): Access Denied."
  end

  test "a target that cannot take it now is waiting, not failed, and keeps the verified point",
       %{config: config, pair: pair, home: home} = context do
    verified = %{
      at: ~U[2026-10-27 03:00:00Z],
      result: :verified,
      name: "n",
      epoch: 2,
      size: 1,
      sha256: String.duplicate("a", 64),
      location: "fake://asleep/n",
      error: nil
    }

    :ok = Status.write(home, Status.record(Status.empty(), "fake", verified))
    Agent.update(config, fn _ -> configured(pair, "asleep") end)
    scheduler = start!(context)
    assert_receive {:planned, {:tick, _first}, _delay}

    assert Scheduler.run_now(scheduler) == {:ok, :started}
    assert_receive {:stored, _snapshot, _bytes}, @wait
    assert_receive {:planned, {:tick, _next}, _delay}, @wait

    assert {:ok, %{targets: %{"fake" => entry}}} = Status.read(home)
    assert entry.last_attempt.result == :waiting

    assert entry.last_attempt.note ==
             "The stand-in is asleep; the snapshot waits for the next run."

    assert entry.last_error == nil
    assert entry.last_verified.at == ~U[2026-10-27 03:00:00Z]
  end

  test "each attempt records the recovery key it was written for",
       %{pair: pair, home: home} = context do
    scheduler = start!(context)
    assert_receive {:planned, {:tick, _first}, _delay}
    assert Scheduler.run_now(scheduler) == {:ok, :started}
    assert_receive {:stored, _snapshot, _bytes}, @wait
    assert_receive {:planned, {:tick, _next}, _delay}, @wait

    key_id = Base.encode16(Recipient.key_id(pair.public_key), case: :lower)
    assert {:ok, %{targets: %{"fake" => entry}}} = Status.read(home)
    assert entry.last_attempt.key_id == key_id
    assert entry.last_verified.key_id == key_id
  end

  test "the first boot after a move runs its first snapshot at once, then the boot delay holds",
       %{home: home} = context do
    :ok = Status.write(home, %{Status.empty() | run_at_boot: true})
    scheduler = start!(context)

    assert_receive {:planned, {:tick, token}, 0}
    send(scheduler, {:tick, token})
    assert_receive {:stored, _snapshot, _bytes}, @wait
    assert_receive {:planned, {:tick, _next}, _delay}, @wait

    # Asked once: a restart after it plans as any other boot does.
    assert {:ok, %{run_at_boot: false}} = Status.read(home)
  end

  test "a restart plans from the last attempt, never sooner than the boot delay",
       %{home: home} = context do
    last = %{
      at: ~U[2026-10-27 07:00:00Z],
      result: :verified,
      name: "n",
      epoch: 2,
      size: 1,
      sha256: String.duplicate("a", 64),
      location: "fake://kept/n",
      error: nil
    }

    :ok = Status.write(home, Status.record(Status.empty(), "fake", last))
    _scheduler = start!(context)

    # 07:00 plus six hours is 13:00, four hours after this boot.
    assert_receive {:planned, {:tick, _token}, delay}
    assert delay == 4 * 3_600_000
  end

  test "one run at a time, run now, and nothing to do without a recipient",
       %{config: config} = context do
    gate = self()

    run = fn _home, _config, _targets, _opts ->
      send(gate, {:running, self()})

      receive do
        :finish -> :not_configured
      end
    end

    scheduler = start!(context, run: run)

    assert Scheduler.run_now(scheduler) == {:ok, :started}
    assert_receive {:running, task}, @wait
    assert Scheduler.run_now(scheduler) == {:error, :busy}
    assert %{running: true} = Scheduler.info(scheduler)

    # The section is cleared while the run is going; once the run ends there
    # is nothing to plan and nothing to run.
    Agent.update(config, fn _ -> [] end)
    monitor = Process.monitor(task)
    send(task, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^task, _reason}, @wait

    assert Scheduler.run_now(scheduler) == {:error, :not_configured}
    assert %{running: false, next_run_at: nil} = Scheduler.info(scheduler)
  end

  test "a stale tick does nothing", context do
    scheduler = start!(context)
    assert_receive {:planned, {:tick, _token}, _delay}

    send(scheduler, {:tick, make_ref()})
    assert %{running: false} = Scheduler.info(scheduler)
    refute_received {:stored, _snapshot, _bytes}
  end

  test "a run with no target on and no recipient is not configured", %{home: home, pair: pair} do
    assert Run.run(home, [], [FakeTarget], []) == :not_configured
    assert Run.run(home, [s3_bucket: "kept"], [FakeTarget], []) == :not_configured

    assert Run.run(home, [recipient: Recipient.encode(pair)], [FakeTarget], []) ==
             :not_configured
  end

  test "a capture that fails is every target's failure, in the capture's words",
       %{home: home, pair: pair} do
    SafeRm.rm!(Epoch.path(home))

    assert {:ok, %{written: nil, outcomes: [{FakeTarget, {:error, sentence}}]}} =
             Run.run(home, configured(pair, "kept"), [FakeTarget], test: self())

    assert sentence == "The home has no primary epoch yet, so there is nothing to snapshot."
  end

  defp start!(context, extra \\ []) do
    test = self()
    %{home: home, clock: clock, config: config} = context

    opts =
      [
        name: nil,
        home: home,
        config: fn -> Agent.get(config, & &1) end,
        targets: [FakeTarget],
        now: fn -> Agent.get(clock, & &1) end,
        timer: fn message, delay ->
          send(test, {:planned, message, delay})
          make_ref()
        end,
        run_opts: [test: test, host: "macos-aarch64"]
      ] ++ extra

    start_supervised!({Scheduler, opts})
  end

  defp configured(pair, bucket),
    do: [recipient: Recipient.encode(pair), s3_bucket: bucket, interval_hours: 6]

  defp advance(%{clock: clock}, seconds),
    do: Agent.update(clock, &DateTime.add(&1, seconds, :second))

  defp hidden(home) do
    case File.ls(Path.join(home, "snapshots")) do
      {:ok, names} -> Enum.filter(names, &String.starts_with?(&1, "."))
      {:error, :enoent} -> []
    end
  end
end
