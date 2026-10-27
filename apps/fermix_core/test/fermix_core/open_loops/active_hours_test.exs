defmodule FermixCore.OpenLoops.ActiveHoursTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Repo
  alias FermixCore.OpenLoops.ActiveHours

  @tz "America/New_York"
  # Every date in this file is invented; June 2031 is EDT (UTC-4) throughout.
  @now ~U[2031-06-02 14:00:00Z]
  @default %{start: ~T[09:00:00], finish: ~T[21:00:00], source: :default}

  defp local(date, time), do: date |> DateTime.new!(time, @tz) |> DateTime.shift_zone!("Etc/UTC")

  # `count` instants on consecutive days before June 2, each at `hour` local.
  defp at_hour(hour, count) do
    for day <- 1..count, do: local(Date.add(~D[2031-06-01], -rem(day, 20)), Time.new!(hour, 7, 0))
  end

  describe "derive/2" do
    test "under 40 messages the window is 09:00 to 21:00" do
      assert %{start: ~T[09:00:00], finish: ~T[21:00:00], source: :default, sample: 39} =
               ActiveHours.derive(at_hour(12, 39), @tz)
    end

    test "40 messages give the 15th to 85th percentile hours" do
      instants =
        at_hour(8, 6) ++
          Enum.flat_map(10..16, &at_hour(&1, 4)) ++ at_hour(22, 6)

      assert %{start: ~T[08:00:00], finish: ~T[16:00:00], source: :derived, sample: 40} =
               ActiveHours.derive(instants, @tz)
    end

    test "a window narrower than six hours is widened around its middle" do
      assert %{start: ~T[09:00:00], finish: ~T[15:00:00], source: :derived} =
               ActiveHours.derive(at_hour(12, 40), @tz)
    end

    test "widening never crosses midnight at either end" do
      assert %{start: ~T[00:00:00], finish: ~T[06:00:00]} =
               ActiveHours.derive(at_hour(1, 40), @tz)

      assert %{start: ~T[17:00:00], finish: ~T[23:00:00]} =
               ActiveHours.derive(at_hour(22, 40), @tz)
    end

    test "hours are read in the zone given, not in UTC" do
      # 12:07 EDT is 16:07 UTC: a UTC reading would centre the window on 16:00.
      assert %{start: ~T[09:00:00]} = ActiveHours.derive(at_hour(12, 40), @tz)
      assert %{start: ~T[13:00:00]} = ActiveHours.derive(at_hour(12, 40), "Etc/UTC")
    end
  end

  describe "resolve/5 over the owner's stored messages" do
    setup do
      unique = System.unique_integer([:positive])
      db_path = Path.join(System.tmp_dir!(), "fermix-open-loop-hours-#{unique}.db")
      repo = :"open_loop_hours_repo_#{unique}"

      start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

      on_exit(fn ->
        Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
      end)

      %{repo: repo}
    end

    defp seed(repo, instants, overrides) do
      for at <- instants do
        attrs =
          Map.merge(
            %{
              agent_id: "main",
              owner_id: "default",
              channel: "telegram",
              chat_id: "40001",
              thread_scope: "root",
              sender: "owner",
              role: "user",
              kind: "chat_message",
              content: "an invented message",
              metadata: nil,
              created_at: at
            },
            overrides
          )

        {:ok, _row} = Repo.insert_message(attrs, server: repo)
      end

      :ok
    end

    test "the owner's own chat messages over 28 days decide the window", %{repo: repo} do
      seed(repo, at_hour(12, 40), %{})

      assert {:ok, %{start: ~T[09:00:00], finish: ~T[15:00:00], source: :derived, sample: 40}} =
               ActiveHours.resolve([server: repo], "main", "default", @tz, @now)
    end

    test "guest, assistant, non-chat, other-owner and older rows are not the owner's rhythm",
         %{repo: repo} do
      seed(repo, at_hour(12, 40), %{})
      seed(repo, at_hour(3, 30), %{metadata: %{guest: true}})
      seed(repo, at_hour(3, 30), %{role: "assistant", sender: "fermix"})
      seed(repo, at_hour(3, 30), %{kind: "tool_result"})
      seed(repo, at_hour(3, 30), %{owner_id: "someone_else"})
      seed(repo, [local(~D[2031-05-04], ~T[03:07:00])], %{})

      assert {:ok, %{start: ~T[09:00:00], finish: ~T[15:00:00], sample: 40}} =
               ActiveHours.resolve([server: repo], "main", "default", @tz, @now)
    end

    test "guest messages never lift the owner over the 40-message floor", %{repo: repo} do
      seed(repo, at_hour(12, 39), %{})
      seed(repo, at_hour(12, 5), %{metadata: %{guest: true}})

      assert {:ok, %{start: ~T[09:00:00], finish: ~T[21:00:00], source: :default, sample: 39}} =
               ActiveHours.resolve([server: repo], "main", "default", @tz, @now)
    end

    test "with no messages at all the default window applies", %{repo: repo} do
      assert {:ok, hours} = ActiveHours.resolve([server: repo], "main", "default", @tz, @now)
      assert Map.take(hours, [:start, :finish, :source]) == @default
      assert hours.sample == 0
    end
  end

  describe "inside?/3, next_start/3, start_on/3, day_start/2 and label/1" do
    test "the window includes its start and excludes its finish" do
      hours = Map.put(@default, :sample, 0)

      refute ActiveHours.inside?(hours, local(~D[2031-06-02], ~T[08:59:59]), @tz)
      assert ActiveHours.inside?(hours, local(~D[2031-06-02], ~T[09:00:00]), @tz)
      assert ActiveHours.inside?(hours, local(~D[2031-06-02], ~T[20:59:59]), @tz)
      refute ActiveHours.inside?(hours, local(~D[2031-06-02], ~T[21:00:00]), @tz)
    end

    test "the next start is strictly after the instant given" do
      hours = Map.put(@default, :sample, 0)

      assert ActiveHours.next_start(hours, local(~D[2031-06-02], ~T[08:00:00]), @tz) ==
               ~U[2031-06-02 13:00:00Z]

      assert ActiveHours.next_start(hours, local(~D[2031-06-02], ~T[09:00:00]), @tz) ==
               ~U[2031-06-03 13:00:00Z]

      assert ActiveHours.next_start(hours, local(~D[2031-06-02], ~T[23:30:00]), @tz) ==
               ~U[2031-06-03 13:00:00Z]
    end

    test "a date's start is that local date at the window's start, in UTC" do
      hours = Map.put(@default, :sample, 0)
      assert ActiveHours.start_on(hours, ~D[2031-06-10], @tz) == ~U[2031-06-10 13:00:00Z]
    end

    test "the day start is the local midnight at or before the instant, in UTC" do
      # 03:30Z is 23:30 EDT the evening before: that day's midnight, not the next.
      assert ActiveHours.day_start(~U[2031-06-07 03:30:00Z], @tz) == ~U[2031-06-06 04:00:00Z]
      assert ActiveHours.day_start(~U[2031-06-07 04:00:00Z], @tz) == ~U[2031-06-07 04:00:00Z]
      assert ActiveHours.day_start(~U[2031-06-07 23:59:59Z], @tz) == ~U[2031-06-07 04:00:00Z]
    end

    test "the label is HH:MM-HH:MM" do
      assert ActiveHours.label(Map.put(@default, :sample, 0)) == "09:00-21:00"

      assert ActiveHours.label(%{start: ~T[06:00:00], finish: ~T[13:00:00]}) == "06:00-13:00"
    end
  end
end
