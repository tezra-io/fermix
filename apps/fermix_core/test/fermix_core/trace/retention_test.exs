defmodule FermixCore.Trace.RetentionTest do
  @moduledoc """
  The trace store stays bounded (M75 L14): day folders past the age bound go,
  then the oldest days until the rest fit the size bound, at most a pass's
  worth at a time, and never today's folder, a future one, or anything that is
  not a day folder. Every tree is built under a test-marked temporary directory
  and every pass is given its own date, so no test reads the clock.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Trace
  alias FermixCore.Trace.Retention
  alias FermixTestSupport.SafeRm

  @today ~D[2026-10-30]
  @limits %{max_age_days: 14, max_bytes: 1_073_741_824, max_removals: 32}
  @bodies_limits Map.put(@limits, :body_max_age_days, 1)

  setup do
    base = SafeRm.make_tmp_dir!("trace-retention")
    on_exit(fn -> SafeRm.rm_rf!(base) end)
    %{base: base}
  end

  defp day!(base, date, bytes \\ 10) do
    dir = Path.join(base, Date.to_iso8601(date))
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "llm_call.jsonl"), :binary.copy("x", bytes))
    dir
  end

  # What an Always On server writes (M75 L20): each day's records, and the
  # bodies of those that carry one in `<type>.bodies.jsonl` beside them.
  defp server_day!(base, date) do
    dir = day!(base, date)
    File.write!(Path.join(dir, "agent_event.jsonl"), ~s({"event":"turn_complete"}\n))
    File.write!(Path.join(dir, "llm_call.bodies.jsonl"), ~s({"output":"Three days."}\n))
    File.write!(Path.join(dir, "agent_event.bodies.jsonl"), ~s({"input":"Plan it"}\n))
    dir
  end

  defp names(dir), do: dir |> File.ls!() |> Enum.sort()

  defp days(base) do
    base
    |> File.ls!()
    |> Enum.filter(&match?({:ok, _date}, Date.from_iso8601(&1)))
    |> Enum.sort()
  end

  describe "the age bound" do
    test "removes the days older than it, and keeps the day exactly at it", %{base: base} do
      for date <- [~D[2026-09-01], ~D[2026-10-15], ~D[2026-10-16], ~D[2026-10-29], @today],
          do: day!(base, date)

      assert Retention.prune(base, @today, @limits) == %{
               removed: [~D[2026-09-01], ~D[2026-10-15]],
               refused: []
             }

      assert days(base) == ["2026-10-16", "2026-10-29", "2026-10-30"]
    end

    test "never removes today's folder, even with an age bound of zero", %{base: base} do
      day!(base, ~D[2026-10-29])
      day!(base, @today)

      assert %{removed: [~D[2026-10-29]], refused: []} =
               Retention.prune(base, @today, %{@limits | max_age_days: 0})

      assert days(base) == ["2026-10-30"]
    end
  end

  describe "the size bound" do
    test "removes the oldest days until the rest fit", %{base: base} do
      for date <- Date.range(~D[2026-10-26], ~D[2026-10-29]), do: day!(base, date, 100)
      day!(base, @today, 300)

      assert %{removed: [~D[2026-10-26], ~D[2026-10-27], ~D[2026-10-28]], refused: []} =
               Retention.prune(base, @today, %{@limits | max_bytes: 450})

      assert days(base) == ["2026-10-29", "2026-10-30"]
    end

    test "when today alone is over it, every older day goes and today stays", %{base: base} do
      day!(base, ~D[2026-10-28], 10)
      day!(base, ~D[2026-10-29], 10)
      day!(base, @today, 1_000)

      assert %{removed: [~D[2026-10-28], ~D[2026-10-29]], refused: []} =
               Retention.prune(base, @today, %{@limits | max_bytes: 100})

      assert days(base) == ["2026-10-30"]
      assert File.read!(Path.join([base, "2026-10-30", "llm_call.jsonl"])) =~ "x"
    end

    test "a future day counts toward it but is never removed", %{base: base} do
      day!(base, ~D[2026-10-29], 100)
      day!(base, @today, 100)
      day!(base, ~D[2026-11-30], 500)

      assert %{removed: [~D[2026-10-29]], refused: []} =
               Retention.prune(base, @today, %{@limits | max_bytes: 300})

      assert days(base) == ["2026-10-30", "2026-11-30"]
    end
  end

  test "a pass removes at most its bound, oldest first, and the next carries on", %{base: base} do
    expired = Enum.to_list(Date.range(~D[2026-09-01], ~D[2026-09-05]))
    for date <- expired, do: day!(base, date)
    day!(base, @today)
    limits = %{@limits | max_removals: 2}

    assert %{removed: [~D[2026-09-01], ~D[2026-09-02]]} = Retention.prune(base, @today, limits)
    assert %{removed: [~D[2026-09-03], ~D[2026-09-04]]} = Retention.prune(base, @today, limits)
    assert %{removed: [~D[2026-09-05]]} = Retention.prune(base, @today, limits)
    assert %{removed: [], refused: []} = Retention.prune(base, @today, limits)
    assert days(base) == ["2026-10-30"]
  end

  test "a dated folder holding anything but traces is not one, and does not count", %{base: base} do
    photos = day!(base, ~D[2026-09-01])
    File.write!(Path.join(photos, "beach.jpg"), "not a trace")
    finder = day!(base, ~D[2026-09-02])
    File.write!(Path.join(finder, ".DS_Store"), "")
    day!(base, @today, 100)

    assert Retention.prune(base, @today, %{@limits | max_bytes: 100}) ==
             %{removed: [~D[2026-09-02]], refused: []}

    assert days(base) == ["2026-09-01", "2026-10-30"]
    assert File.read!(Path.join(photos, "beach.jpg")) == "not a trace"
  end

  test "leaves alone everything that is not a past day's folder", %{base: base} do
    outside = SafeRm.make_tmp_dir!("trace-retention-outside")
    on_exit(fn -> SafeRm.rm_rf!(outside) end)
    sentinel = Path.join(outside, "sentinel")
    File.write!(sentinel, "kept")

    for name <- ["scratch", "2026-8-1", "2026-09-01.bak", "2026-09-01junk"],
        do: File.mkdir_p!(Path.join(base, name))

    File.write!(Path.join(base, "2026-09-02"), "a file, not a day folder")
    File.ln_s!(outside, Path.join(base, "2026-09-03"))
    before = File.ls!(base) |> Enum.sort()

    assert Retention.prune(base, @today, %{@limits | max_age_days: 0, max_bytes: 0}) ==
             %{removed: [], refused: []}

    assert File.ls!(base) |> Enum.sort() == before
    assert File.read!(sentinel) == "kept"
  end

  test "a trace directory not made yet is an empty pass", %{base: base} do
    assert Retention.prune(Path.join(base, "traces"), @today, @limits) ==
             %{removed: [], refused: []}
  end

  test "the filesystem root is refused as a trace directory, before it is listed" do
    # A day before 1970 cannot exist, so even a broken guard deletes nothing here.
    assert Retention.prune("/", ~D[1970-01-01], @limits) ==
             %{removed: [], refused: [{"/", :unsafe_trace_dir}]}
  end

  test "a day it cannot remove is refused, and the pass goes on", %{base: base} do
    stuck = day!(base, ~D[2026-09-01])
    day!(base, ~D[2026-09-02])
    File.chmod!(stuck, 0o500)
    on_exit(fn -> File.chmod!(stuck, 0o700) end)

    # The reason is the one the system gives (`:eexist` on macOS for the
    # folder left non-empty); the path is the folder or a file in it.
    assert %{removed: [~D[2026-09-02]], refused: [{path, reason}]} =
             Retention.prune(base, @today, @limits)

    assert String.starts_with?(path, stuck)
    assert is_atom(reason)
    assert days(base) == ["2026-09-01"]
  end

  test "a day it cannot list is refused and left out; the pass goes on", %{base: base} do
    day!(base, ~D[2026-09-01])
    day!(base, ~D[2026-10-28], 100)
    unreadable = day!(base, ~D[2026-10-29], 100)
    day!(base, @today, 100)
    File.chmod!(unreadable, 0o000)
    on_exit(fn -> File.chmod!(unreadable, 0o700) end)

    assert Retention.prune(base, @today, %{@limits | max_bytes: 150}) ==
             %{removed: [~D[2026-09-01], ~D[2026-10-28]], refused: [{unreadable, :eacces}]}

    assert days(base) == ["2026-10-29", "2026-10-30"]
  end

  test "a day it cannot size is refused, and nothing is removed for size", %{base: base} do
    day!(base, ~D[2026-09-01])
    day!(base, ~D[2026-10-28], 100)
    unsizable = day!(base, ~D[2026-10-29], 100)
    day!(base, @today, 100)
    # Listed (read) but not searched (no execute): its files cannot be stat'ed.
    File.chmod!(unsizable, 0o600)
    on_exit(fn -> File.chmod!(unsizable, 0o700) end)

    assert Retention.prune(base, @today, %{@limits | max_bytes: 10}) ==
             %{removed: [~D[2026-09-01]], refused: [{unsizable, :eacces}]}

    assert days(base) == ["2026-10-28", "2026-10-29", "2026-10-30"]
  end

  describe "the bodies bound" do
    test "removes the bodies files of each day before yesterday and keeps every record",
         %{base: base} do
      old = server_day!(base, ~D[2026-10-20])
      two_ago = server_day!(base, ~D[2026-10-28])
      yesterday = server_day!(base, ~D[2026-10-29])
      today = server_day!(base, @today)

      assert Retention.prune_bodies(base, @today, @bodies_limits) ==
               %{removed: [~D[2026-10-20], ~D[2026-10-28]], refused: []}

      for dir <- [old, two_ago], do: assert(names(dir) == ["agent_event.jsonl", "llm_call.jsonl"])

      for dir <- [yesterday, today] do
        assert names(dir) == [
                 "agent_event.bodies.jsonl",
                 "agent_event.jsonl",
                 "llm_call.bodies.jsonl",
                 "llm_call.jsonl"
               ]
      end
    end

    test "a day with no bodies, as everywhere but a server, is left whole", %{base: base} do
      dir = day!(base, ~D[2026-10-20])
      File.write!(Path.join(dir, "agent_event.jsonl"), ~s({"input":"Plan it"}\n))

      assert Retention.prune_bodies(base, @today, @bodies_limits) == %{removed: [], refused: []}
      assert names(dir) == ["agent_event.jsonl", "llm_call.jsonl"]
    end

    test "a day past the age bound is left to the age bound", %{base: base} do
      expired = server_day!(base, ~D[2026-09-01])

      assert Retention.prune_bodies(base, @today, @bodies_limits) == %{removed: [], refused: []}
      assert "llm_call.bodies.jsonl" in names(expired)
    end

    test "a pass removes the bodies of at most its bound of days, oldest first", %{base: base} do
      for date <- Date.range(~D[2026-10-20], ~D[2026-10-23]), do: server_day!(base, date)
      limits = %{@bodies_limits | max_removals: 3}

      assert %{removed: [~D[2026-10-20], ~D[2026-10-21], ~D[2026-10-22]]} =
               Retention.prune_bodies(base, @today, limits)

      assert %{removed: [~D[2026-10-23]]} = Retention.prune_bodies(base, @today, limits)
    end

    test "never touches a dated folder that is not a day of traces", %{base: base} do
      photos = server_day!(base, ~D[2026-10-20])
      File.write!(Path.join(photos, "beach.jpg"), "not a trace")
      before = names(photos)

      assert Retention.prune_bodies(base, @today, @bodies_limits) == %{removed: [], refused: []}
      assert names(photos) == before
    end

    test "a bodies file it cannot remove is refused, and the pass goes on", %{base: base} do
      stuck = server_day!(base, ~D[2026-10-20])
      server_day!(base, ~D[2026-10-21])
      File.chmod!(stuck, 0o500)
      on_exit(fn -> File.chmod!(stuck, 0o700) end)

      assert %{removed: [~D[2026-10-21]], refused: [{path, :eacces}, {path2, :eacces}]} =
               Retention.prune_bodies(base, @today, @bodies_limits)

      assert Enum.sort([path, path2]) == [
               Path.join(stuck, "agent_event.bodies.jsonl"),
               Path.join(stuck, "llm_call.bodies.jsonl")
             ]
    end

    test "a day it cannot list is named once, by the pass over the days", %{base: base} do
      server_day!(base, ~D[2026-10-20])
      unreadable = server_day!(base, ~D[2026-10-21])
      File.chmod!(unreadable, 0o000)
      on_exit(fn -> File.chmod!(unreadable, 0o700) end)

      assert Retention.prune_bodies(base, @today, @bodies_limits) ==
               %{removed: [~D[2026-10-20]], refused: []}

      assert %{refused: [{^unreadable, :eacces}]} = Retention.prune(base, @today, @limits)
    end

    test "the bodies bound is one day" do
      assert Retention.limits().body_max_age_days == 1
    end
  end

  describe "from the Trace process" do
    setup %{base: base} do
      clock = start_supervised!({Agent, fn -> ~D[2026-10-01] end})
      name = :"trace_retention_#{System.unique_integer([:positive])}"
      opts = [base_dir: base, name: name, today: fn -> Agent.get(clock, & &1) end]
      %{clock: clock, name: name, opts: opts}
    end

    test "a pass runs when Trace starts", %{base: base, name: name, opts: opts} do
      day!(base, ~D[2026-09-01])
      day!(base, ~D[2026-09-30])
      start_supervised!({Trace, Keyword.put(opts, :timer_enabled, true)})
      :sys.get_state(name)

      assert days(base) == ["2026-09-30"]
    end

    test "a pass closes the files of earlier days before it removes them, and today's is written",
         %{base: base, clock: clock, name: name, opts: opts} do
      start_supervised!({Trace, Keyword.put(opts, :timer_enabled, false)})
      Trace.record(:llm_call, "main", %{n: 1}, server: name)
      [{{~D[2026-10-01], :llm_call}, handle}] = Map.to_list(:sys.get_state(name).handles)
      ref = Process.monitor(handle)

      Agent.update(clock, fn _ -> @today end)
      send(Process.whereis(name), :retention)

      assert_receive {:DOWN, ^ref, :process, ^handle, _reason}
      assert :sys.get_state(name).handles == %{}
      assert days(base) == []

      Trace.record(:llm_call, "main", %{n: 2}, server: name)
      :sys.get_state(name)
      assert File.read!(Path.join([base, "2026-10-30", "llm_call.jsonl"])) =~ ~s("n":2)
    end
  end
end
