# The seeded-run timing rule (bin/seed_run_times.exs), checked at fixed instants. Needs
# the engine compiled (its schedule parser and zone database), so it runs beside the
# seed rather than in the Python harness tests:
#
#   FERMIX_HOME=$(mktemp -d) mix run --no-start --no-compile benchmark/bin/seed_run_times_test.exs
#
# Exits non-zero when a test fails. Every value is invented.

Code.require_file("seed_run_times.exs", __DIR__)
ExUnit.start(autorun: false)

defmodule SeedRunTimesTest do
  use ExUnit.Case, async: true

  @zone "America/New_York"
  # Tuesday 2026-11-24, 20:30 in New York (UTC-5).
  @evening ~U[2026-11-25 01:30:00Z]

  defp job(schedule, runs), do: %{"key" => "tides", "schedule" => schedule, "runs" => runs}
  defp run(when_), do: Map.merge(%{"duration_seconds" => 40, "status" => "ok"}, when_)

  defp local(%DateTime{} = at),
    do: at |> DateTime.shift_zone!(@zone) |> Calendar.strftime("%a %d %H:%M")

  test "scheduled runs sit at the job's own past fire times, oldest first" do
    runs = for n <- [3, 2, 1], do: run(%{"fires_ago" => n})
    starts = SeedRunTimes.starts!(job("40 5 * * *", runs), @zone, @evening)
    assert Enum.map(starts, &local/1) == ["Sun 22 05:40", "Mon 23 05:40", "Tue 24 05:40"]
    assert :ok = SeedRunTimes.check_order!("tides", runs, starts, @evening)
  end

  test "a fire whose run or conclusion would not be over by now is not counted" do
    # 05:40:30 local: this morning's fire is 30 s old, and its run lasts 40 s.
    just_after = ~U[2026-11-24 10:40:30Z]

    starts =
      SeedRunTimes.starts!(job("40 5 * * *", [run(%{"fires_ago" => 1})]), @zone, just_after)

    assert Enum.map(starts, &local/1) == ["Mon 23 05:40"]

    # Two hours after the fire, a conclusion three hours after the run is not over yet.
    later = ~U[2026-11-24 12:40:00Z]
    concluded = run(%{"fires_ago" => 1, "heal" => %{"delivered_minutes_after" => 180}})
    [start] = SeedRunTimes.starts!(job("40 5 * * *", [concluded]), @zone, later)
    assert local(start) == "Mon 23 05:40"
    assert DateTime.compare(SeedRunTimes.concluded(concluded, start), later) == :lt

    # A conclusion whose send is left to the daemon is timed the same way.
    left = run(%{"fires_ago" => 1, "heal" => %{"decided_minutes_after" => 180}})
    [start] = SeedRunTimes.starts!(job("40 5 * * *", [left]), @zone, later)
    assert local(start) == "Mon 23 05:40"
    assert DateTime.diff(SeedRunTimes.concluded(left, start), start) == 40 + 180 * 60
  end

  test "a weekly schedule counts back in weeks" do
    starts =
      SeedRunTimes.starts!(
        job("40 5 * * 1", [run(%{"fires_ago" => 2}), run(%{"fires_ago" => 1})]),
        @zone,
        @evening
      )

    assert Enum.map(starts, &local/1) == ["Mon 16 05:40", "Mon 23 05:40"]
  end

  test "fire times keep their wall clock across a daylight-saving change" do
    # New York left daylight time on 2026-11-01: the same 06:15 is a different UTC hour.
    now = ~U[2026-11-02 20:00:00Z]
    runs = for n <- [3, 2, 1], do: run(%{"fires_ago" => n})
    starts = SeedRunTimes.starts!(job("15 6 * * *", runs), @zone, now)
    assert Enum.map(starts, &local/1) == ["Sat 31 06:15", "Sun 01 06:15", "Mon 02 06:15"]
    assert Enum.map(starts, & &1.hour) == [10, 11, 11]
  end

  test "an off-schedule manual run is hours before now" do
    manual = run(%{"trigger" => "manual", "hours_ago" => 3})
    [start] = SeedRunTimes.starts!(job("40 5 * * *", [manual]), @zone, @evening)
    assert start == DateTime.add(@evening, -3 * 3_600, :second)
  end

  test "a scheduled run between fires and a manual run after it keep their order" do
    runs = [run(%{"fires_ago" => 1}), run(%{"trigger" => "manual", "hours_ago" => 2})]
    starts = SeedRunTimes.starts!(job("40 5 * * *", runs), @zone, @evening)
    assert :ok = SeedRunTimes.check_order!("tides", runs, starts, @evening)
  end

  for {label, bad} <- [
        {"a scheduled run stated in hours", %{"hours_ago" => 3}},
        {"a scheduled run stated both ways", %{"fires_ago" => 1, "hours_ago" => 3}},
        {"no fire", %{"fires_ago" => 0}},
        {"a fire that is not whole", %{"fires_ago" => 1.5}},
        {"a manual run at a fire time", %{"trigger" => "manual", "fires_ago" => 1}},
        {"a duration that is not whole", %{"fires_ago" => 1, "duration_seconds" => 40.5}},
        {"a conclusion with no time", %{"fires_ago" => 1, "heal" => %{"decision" => "tell"}}},
        {"a conclusion both sent and left to send",
         %{
           "fires_ago" => 1,
           "heal" => %{"delivered_minutes_after" => 5, "decided_minutes_after" => 5}
         }},
        {"a send left with a time that is not whole",
         %{"fires_ago" => 1, "heal" => %{"decided_minutes_after" => 2.5}}},
        {"a retry trigger", %{"trigger" => "retry", "hours_ago" => 1}}
      ] do
    test "refused: #{label}" do
      assert_raise RuntimeError, fn ->
        SeedRunTimes.starts!(
          job("40 5 * * *", [run(unquote(Macro.escape(bad)))]),
          @zone,
          @evening
        )
      end
    end
  end

  test "refused: a fire count on a schedule that is not cron" do
    assert_raise RuntimeError, ~r/needs a cron schedule/, fn ->
      SeedRunTimes.starts!(job("every 2 hours", [run(%{"fires_ago" => 1})]), @zone, @evening)
    end
  end

  test "refused: runs listed out of order, or a conclusion after the next run began" do
    swapped = [run(%{"fires_ago" => 1}), run(%{"fires_ago" => 2})]
    starts = SeedRunTimes.starts!(job("40 5 * * *", swapped), @zone, @evening)

    assert_raise RuntimeError, ~r/oldest first/, fn ->
      SeedRunTimes.check_order!("tides", swapped, starts, @evening)
    end

    late = [
      run(%{"fires_ago" => 2, "heal" => %{"delivered_minutes_after" => 1_500}}),
      run(%{"fires_ago" => 1})
    ]

    starts = SeedRunTimes.starts!(job("40 5 * * *", late), @zone, @evening)

    assert_raise RuntimeError, ~r/before the next starts/, fn ->
      SeedRunTimes.check_order!("tides", late, starts, @evening)
    end
  end

  test "every fixture that seeds runs gets a start for each, in order, at any hour of a day" do
    root = Path.expand("../suites", __DIR__)
    specs = Path.wildcard(Path.join(root, "**/fixtures/state/*.json"))

    for spec <- specs,
        job <- Map.get(Jason.decode!(File.read!(spec)), "jobs", []),
        runs = Map.get(job, "runs", []),
        runs != [],
        hour <- 0..23,
        minute <- [0, 41] do
      now = DateTime.add(~U[2026-11-24 05:00:00Z], hour * 3_600 + minute * 60, :second)
      zone = Map.get(job, "timezone", @zone)
      starts = SeedRunTimes.starts!(job, zone, now)
      assert length(starts) == length(runs), spec
      assert :ok = SeedRunTimes.check_order!(job["key"], runs, starts, now)
    end
  end
end

case ExUnit.run() do
  %{failures: 0} -> :ok
  _failed -> System.halt(1)
end
