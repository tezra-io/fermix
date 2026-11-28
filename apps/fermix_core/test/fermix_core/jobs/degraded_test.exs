defmodule FermixCore.Jobs.DegradedTest do
  # M106 §6: the trigger for a run that ended ok without working, decided by
  # code from the tool tallies of the run and the job's two runs before it.
  # It reads no words, only whether a tool ever succeeded. Pure, so the whole
  # rule is a table.
  use ExUnit.Case, async: true

  alias FermixCore.Jobs.Degraded

  # A tally entry as the runner stores it, for a tool none of whose calls in
  # one run succeeded.
  defp refused(name, error \\ 1, extra \\ []) do
    Map.merge(%{"name" => name, "ok" => 0, "error" => error, "unfinished" => 0}, Map.new(extra))
  end

  test "three runs is the rule's count" do
    assert Degraded.runs() == 3
  end

  describe "decide/1, newest run first" do
    test "a tool that never succeeded in three runs in a row trips it" do
      tallies = [
        [refused("tide_lookup", 2, [{"last_error", "station offline"}])],
        [refused("tide_lookup", 1, [{"last_error", "station asleep"}])],
        [refused("tide_lookup", 3)]
      ]

      assert Degraded.decide(tallies) ==
               {:tool,
                %{
                  name: "tide_lookup",
                  plugin: nil,
                  failed_calls: [2, 1, 3],
                  last_error: "station offline"
                }}
    end

    # A tally entry as the runner stores it, built at compile time for the table.
    @refused %{"name" => "tide_lookup", "ok" => 0, "error" => 1, "unfinished" => 0}
    @worked_once %{@refused | "ok" => 1, "error" => 9}
    @fetch %{"name" => "web_fetch", "ok" => 2, "error" => 0, "unfinished" => 0}
    @read_miss %{"name" => "read_file", "ok" => 3, "error" => 1, "unfinished" => 0}

    # name, the three tallies, what the rule answers
    @table [
      {"two runs are not enough", [[@refused], [@refused]], :none},
      {"one success in the newest run clears it", [[@worked_once], [@refused], [@refused]],
       :none},
      {"one success in the oldest run clears it", [[@refused], [@refused], [@worked_once]],
       :none},
      {"a run that did not call the tool breaks the streak", [[@refused], [@fetch], [@refused]],
       :none},
      {"a run with no tally breaks the streak", [[@refused], nil, [@refused]], :none},
      {"a run that called no tool breaks the streak", [[@refused], [], [@refused]], :none},
      {"an unfinished call is no success, and one failed call still counts",
       [[%{@refused | "unfinished" => 2}], [@refused], [@refused]], {:tool, "tide_lookup"}},
      {"a run whose only calls were unfinished has no failed call, so it does not count",
       [[%{@refused | "error" => 0, "unfinished" => 1}], [@refused], [@refused]], :none},
      {"an ordinary miss beside successes of the same tool is passed over",
       [[@read_miss], [@read_miss], [%{@read_miss | "ok" => 5, "error" => 2}]], :none},
      {"other tools in the runs change nothing",
       [[@fetch, @refused], [@refused, @fetch], [@refused]], {:tool, "tide_lookup"}}
    ]

    for {name, tallies, expected} <- @table do
      @tallies tallies
      @expected expected
      test name do
        assert @tallies |> Degraded.decide() |> named() == @expected
      end
    end

    test "a plugin's tool is chosen first, then the most failed calls, then the name" do
      plugin_tool = refused("whoami", 1, [{"plugin", "harbour_id"}])
      busy = refused("tide_lookup", 5)
      also_busy = refused("swell_lookup", 5)
      quiet = refused("anchor_watch", 1)

      runs = [plugin_tool, busy, also_busy, quiet]
      tallies = [runs, Enum.reverse(runs), runs]

      assert {:tool, %{name: "whoami", plugin: "harbour_id", failed_calls: [1, 1, 1]}} =
               Degraded.decide(tallies)

      without_plugin = for tally <- tallies, do: List.delete(tally, plugin_tool)
      assert {:tool, %{name: "swell_lookup"}} = Degraded.decide(without_plugin)

      fewer = for tally <- without_plugin, do: List.delete(tally, also_busy)
      assert {:tool, %{name: "tide_lookup", failed_calls: [5, 5, 5]}} = Degraded.decide(fewer)
    end

    test "the plugin and the last error are the newest run's" do
      tallies = [
        [refused("whoami", 1, [{"plugin", "harbour_id"}])],
        [refused("whoami", 1, [{"plugin", "old_id"}, {"last_error", "older words"}])],
        [refused("whoami", 1)]
      ]

      assert {:tool, %{plugin: "harbour_id", last_error: nil}} = Degraded.decide(tallies)
    end

    test "a tally that is not one is refused, loudly" do
      assert_raise FunctionClauseError, fn ->
        Degraded.decide([[%{"name" => "tide_lookup"}], [refused("x")], [refused("x")]])
      end

      assert_raise FunctionClauseError, fn -> Degraded.decide(:none) end
    end
  end

  # What the store reads back: a tally this engine cannot read proves nothing
  # and reads as none, which breaks the streak; it never raises.
  describe "readable_tally/1" do
    @entry ~s({"name": "tide_lookup", "ok": 0, "error": 2, "unfinished": 0})

    test "a list of well-formed entries reads as it is, keys another engine added read past" do
      assert {:ok, [%{"name" => "tide_lookup", "error" => 2}]} =
               Degraded.readable_tally("[#{@entry}]")

      assert {:ok, [_]} =
               Degraded.readable_tally(
                 ~s([{"name": "whoami", "ok": 1, "error": 0, "plugin": "harbour_id", ) <>
                   ~s("last_error": "x", "kind": "auth"}])
               )

      assert Degraded.readable_tally(nil) == {:ok, nil}
      assert Degraded.readable_tally("[]") == {:ok, []}
      assert Degraded.readable_tally([refused("tide_lookup")]) == {:ok, [refused("tide_lookup")]}
    end

    for {label, stored} <- [
          {"text that is not JSON", "[{"},
          {"not a list", @entry},
          {"an entry that is not an object", "[3]"},
          {"a missing count", ~s([{"name": "tide_lookup", "error": 2}])},
          {"a count of the wrong type", ~s([{"name": "tide_lookup", "ok": "0", "error": 2}])},
          {"a negative count", ~s([{"name": "tide_lookup", "ok": -1, "error": 2}])},
          {"a name that is not text", ~s([{"name": 7, "ok": 0, "error": 2}])},
          {"a plugin that is not text", ~s([{"name": "x", "ok": 0, "error": 2, "plugin": 3}])}
        ] do
      @stored stored
      test "#{label} is unreadable" do
        assert Degraded.readable_tally(@stored) == :unreadable
      end
    end
  end

  # Only the heal's own tool working proves it (§6).
  test "worked?/2: a tool worked in a run when one of its calls succeeded" do
    tally = [%{"name" => "whoami", "ok" => 1, "error" => 4}, refused("whereami")]
    assert Degraded.worked?(tally, "whoami")
    refute Degraded.worked?(tally, "whereami")
    refute Degraded.worked?(tally, "tide_lookup")
    refute Degraded.worked?(nil, "whoami")
  end

  defp named(:none), do: :none
  defp named({:tool, %{name: name}}), do: {:tool, name}
end
