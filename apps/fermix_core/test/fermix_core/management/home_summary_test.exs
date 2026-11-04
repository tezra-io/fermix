defmodule FermixCore.Management.HomeSummaryTest do
  # `home.status.summary` (M75 lean v1 §7): one table over every state and
  # every problem, from the facts the gatherer collects to the state, the
  # sentence and the one action every surface shows. The facts are invented
  # and written here, so each row names exactly what makes its state.
  use ExUnit.Case, async: true

  alias FermixCore.Management.Copy
  alias FermixCore.Management.HomeSummary

  @now ~U[2031-05-04 12:00:00Z]
  @minute 60_000
  @cand "cand-5e2a9c1f7b3d4086"
  @back_cand "cand-7a3e1c9b5d2f4086"
  @copy "20310504T093000Z-e5.fxsnap"

  # -- the table ----------------------------------------------------------------

  # {name, facts, state, sentence, action id or nil}
  defp cases do
    setup_cases() ++ device_cases() ++ server_cases() ++ candidate_cases() ++ return_cases()
  end

  defp setup_cases do
    [
      {"a home with nothing", facts([]), "off",
       "Keep Fermix running when this Mac sleeps. It moves to a server you own.", "own_server"},
      {"a home that uses iMessage and meetings", facts(stays_here: [:imessage, :meetings]), "off",
       "Keep Fermix running when this Mac sleeps. It moves to a server you own. iMessage and " <>
         "meetings stop after the move.", "own_server"},
      {"a home that uses all three", facts(stays_here: [:imessage, :voice, :meetings]), "off",
       "Keep Fermix running when this Mac sleeps. It moves to a server you own. iMessage, " <>
         "voice calls and meetings stop after the move.", "own_server"},
      {"a home that uses only iMessage", facts(stays_here: [:imessage]), "off",
       "Keep Fermix running when this Mac sleeps. It moves to a server you own. iMessage " <>
         "stops after the move.", "own_server"},
      {"a Linux home with nothing", facts(host_os: :linux), "off",
       "Keep Fermix running when this computer sleeps. It moves to a server you own.",
       "own_server"},
      {"a Linux home with voice calls on", facts(host_os: :linux, stays_here: [:voice]), "off",
       "Keep Fermix running when this computer sleeps. It moves to a server you own. Voice " <>
         "calls stop after the move.", "own_server"},
      {"a code for the owner's server", facts(link: link(enrollment: manual(:open))), "connect",
       "Waiting for your server: run the command on it and paste the code when it asks.", nil},
      {"a server waiting for its move", ready_facts([]), "ready",
       "Your server is ready for the move. You can move Fermix back to this Mac from Always " <>
         "On whenever you want.", "move_now"},
      {"a server waiting, the review warning", ready_facts(review: review([warn()])), "ready",
       "Your server is ready for the move. You can move Fermix back to this Mac from Always " <>
         "On whenever you want.", "move_now"},
      {"a server waiting, the review blocking", ready_facts(review: review([warn(), block()])),
       "problem",
       "The move cannot start yet. This home is about 4 GiB; the move needs about 9 GiB free.",
       "check_again"},
      {"a server presenting its code", facts(link: link(enrollment: manual(:used))), "creating",
       "Connecting your server…", nil},
      {"a move undone, the server still held", ready_facts(move: move("aborted")), "undone",
       "The move was undone. Fermix still runs on this Mac.", "try_again"},
      {"a move undone long ago, nothing held", facts(move: move("aborted")), "off",
       "Keep Fermix running when this Mac sleeps. It moves to a server you own.", "own_server"}
    ]
  end

  defp device_cases do
    [
      {"the move streaming", device(move: move("streaming")), "moving",
       "Moving. This Mac restarts and reconnects to your server. Messages wait until it is " <>
         "done.", nil},
      {"the move restarting into the desktop", device(move: move("committed")), "moving",
       "Moving. This Mac restarts and reconnects to your server. Messages wait until it is " <>
         "done.", nil},
      {"the move waiting on the server's word", device(move: move("committing")), "moving",
       "Waiting for your server to confirm the move. Fermix keeps trying.", nil},
      {"the move being undone", device(move: move("undoing")), "undone",
       "The move was undone. Fermix still runs on this Mac.", nil},
      {"a computer the move left with no link", device(linked: false, moved: moved()), "retired",
       "Fermix moved to your server, and this Mac is no longer connected to it.", "learn_more"},
      {"a desktop the server forgot", desktop(link_primary: primary(:revoked)), "retired",
       "Fermix moved to your server, and this Mac is no longer connected to it.", "learn_more"},
      {"a desktop with a fresh backup", desktop([]), "on",
       "Fermix runs on your server. Last backup 2 hours ago.", nil},
      {"a desktop whose server's part did not arrive", desktop(primary_home: nil), "on",
       "Fermix runs on your server.", nil},
      {"a desktop while Fermix is stopped", desktop(link_primary: nil, primary_home: nil), "on",
       "Fermix runs on your server.", nil},
      {"a desktop the day after the move, no backup yet",
       desktop(primary_home: server_home(backups: []), moved: moved(~U[2031-05-03 12:00:00Z])),
       "on", "Fermix runs on your server. No backup has finished yet.", nil},
      {"a server silent for five minutes",
       desktop(link_primary: primary(:unreachable, 5 * @minute)), "on",
       "Fermix runs on your server. Last backup 2 hours ago.", nil},
      {"a server silent for ten minutes",
       desktop(link_primary: primary(:unreachable, 10 * @minute)), "problem",
       "Fermix cannot reach your server. Your messages wait until it is back.", "learn_more"},
      {"a server answering as an older copy for ten minutes",
       desktop(link_primary: primary(:stale, 11 * @minute)), "problem",
       "Fermix cannot reach your server. Your messages wait until it is back.", "learn_more"},
      {"a server this Mac is too old for", desktop(primary_too_old: true, primary_home: nil),
       "problem", "Update Fermix on this Mac to keep using Always On.", "update"},
      {"a server disk nearly full", desktop(primary_home: server_home(disk: 0.9)), "problem",
       "Your server's disk is 90% full.", "learn_more"},
      {"a last backup five days old",
       desktop(primary_home: server_home(backups: [{"desktop", ~U[2031-04-29 11:00:00Z]}])),
       "problem", "Your last backup is 5 days old. It runs when this Mac is online.",
       "back_up_now"},
      {"no backup since a move four days ago",
       desktop(primary_home: server_home(backups: []), moved: moved(~U[2031-04-30 10:00:00Z])),
       "problem",
       "No backup has finished since the move 4 days ago. It runs when this Mac is online.",
       "back_up_now"}
    ]
  end

  defp server_cases do
    [
      {"the server itself", server([]), "primary", "Fermix runs here.", nil},
      {"the server's disk nearly full", server(disk: %{"used" => 0.87, "nearly_full" => true}),
       "problem", "This server's disk is 87% full.", "learn_more"},
      {"the server's last backup five days old",
       server(snapshots: snapshots([{"desktop", ~U[2031-04-29 10:00:00Z]}])), "problem",
       "The last backup is 5 days old. It runs when your Mac is online.", "back_up_now"}
    ]
  end

  defp candidate_cases do
    [
      {"a server waiting", candidate_role("enrolled"), "candidate",
       "This server is waiting for its move.", nil},
      {"a server enrolling", candidate_role("enrolling"), "candidate",
       "This server is waiting for its move.", nil},
      {"a server receiving its home", candidate_role("receiving"), "candidate",
       "Your home is moving to this server.", nil},
      {"a server waited past its day", candidate_role("expired"), "problem",
       "This server waited too long for its move and must be set up again.", "learn_more"},
      {"a server whose enrollment failed", candidate_role("failed"), "problem",
       "This server did not finish setting up.", "learn_more"},
      {"a candidate whose state is unreadable", facts(role: :candidate), "candidate",
       "This server is waiting for its move.", nil}
    ]
  end

  # Always On's move back (design §9): the desktop takes the home back from
  # its server over the link, or restores its own backup when the server is
  # gone.
  defp return_cases do
    unreachable = primary(:unreachable, 11 * @minute)

    [
      {"a desktop asking its server for the code to move back", returning(back("enrolling")),
       "creating", "Connecting this Mac to your server…", "cancel"},
      {"a desktop ready to take Fermix back", returning(back("enrolled")), "ready",
       "This Mac is ready to take Fermix back.", "move_now"},
      {"a Linux desktop ready to take Fermix back", returning(back("enrolled"), host_os: :linux),
       "ready", "This computer is ready to take Fermix back.", "move_now"},
      {"the move back asked of the server",
       returning(back("enrolled"), started: true, server_move: "requested"), "moving",
       "Moving Fermix back to this Mac. Messages wait until it is done.", nil},
      {"the move back arriving",
       returning(back("receiving"), started: true, server_move: "streaming"), "moving",
       "Moving Fermix back to this Mac. Messages wait until it is done.", nil},
      {"the move back arriving while the server serves nothing",
       returning(back("receiving"), started: true, link_primary: unreachable, primary_home: nil),
       "moving", "Moving Fermix back to this Mac. Messages wait until it is done.", nil},
      {"the move back staged",
       returning(back("staged"), started: true, server_move: "committing"), "moving",
       "Moving Fermix back to this Mac. Messages wait until it is done.", nil},
      {"the move back put in place, the link gone",
       returning(back("activating"), started: true, linked: false), "moving",
       "Moving Fermix back to this Mac. Messages wait until it is done.", nil},
      {"the move back done here, the restart to come",
       returning(nil, started: true, linked: false, primary_home: nil), "moving",
       "Moving Fermix back to this Mac. Messages wait until it is done.", nil},
      {"the server undid the move back",
       returning(back("enrolled"), started: true, server_move: "aborted"), "undone",
       "The move back was undone. Fermix still runs on your server.", "try_again"},
      {"the server undoing the move back",
       returning(back("enrolled"), started: true, server_move: "undoing"), "moving",
       "Moving Fermix back to this Mac. Messages wait until it is done.", nil},
      {"a start recorded that the server, still the primary, never took",
       returning(back("enrolled"), started: true), "ready",
       "This Mac is ready to take Fermix back.", "move_now"},
      {"a move back arriving with no record of it",
       returning(back("receiving"), record: false, server_move: "streaming"), "moving",
       "Moving Fermix back to this Mac. Messages wait until it is done.", nil},
      {"a move back arriving, the server serving again",
       returning(back("receiving"), started: true, server_move: "aborted"), "undone",
       "The move back was undone. Fermix still runs on your server.", "try_again"},
      {"a move back staged, the server the primary with no move",
       returning(back("staged"), started: true), "undone",
       "The move back was undone. Fermix still runs on your server.", "try_again"},
      {"a move back arriving with no record, the server serving again",
       returning(back("receiving"), record: false), "problem",
       "Moving back stopped part-way, so cancel it and move back again.", "cancel"},
      {"a move back put in place, the server answering as the primary",
       returning(back("activating"), started: true), "moving",
       "Moving Fermix back to this Mac. Messages wait until it is done.", nil},
      {"a started record left alone, the server the primary with no move",
       returning(nil, started: true), "problem",
       "Moving back stopped part-way, so cancel it and move back again.", "cancel"},
      {"the move back that failed", returning(back("failed")), "problem",
       "This Mac could not get ready to take Fermix back. Move back to try again.", "move_back"},
      {"the move back that waited past its day", returning(back("expired")), "problem",
       "This Mac could not get ready to take Fermix back. Move back to try again.", "move_back"},
      {"a move back stopped part-way with no record of it",
       returning(back("enrolled"), record: false), "problem",
       "Moving back stopped part-way, so cancel it and move back again.", "cancel"},
      {"a move back whose state cannot be read", returning(:unreadable), "problem",
       "Moving back stopped part-way, so cancel it and move back again.", "cancel"},
      {"a restore from this Mac's backup", returning(restore("receiving")), "moving",
       "Restoring Fermix on this Mac from its backup. Messages wait until it is done.", nil},
      {"a restore from this Mac's backup that failed",
       returning(restore("failed"),
         copies: [copy()],
         link_primary: unreachable,
         primary_home: nil
       ), "problem", "Fermix could not restore its backup on this Mac.", "restore_here"},
      {"restoring here, before the restore wrote anything",
       desktop(
         link_primary: unreachable,
         primary_home: nil,
         restoring: true,
         return: restore_record(),
         copies: [copy()]
       ), "moving",
       "Restoring Fermix on this Mac from its backup. Messages wait until it is done.", nil},
      {"back on this Mac after a move back", facts(return: back_record([])), "off",
       "Keep Fermix running when this Mac sleeps. It moves to a server you own.", "own_server"}
    ]
  end

  # -- the table, read --------------------------------------------------------

  test "every row answers its state, sentence and action" do
    for {name, facts, state, sentence, action} <- cases() do
      summary = HomeSummary.summary(facts)

      assert summary["state"] == state, "#{name}: #{inspect(summary)}"
      assert summary["sentence"] == sentence, "#{name}: #{inspect(summary["sentence"])}"
      assert action_id(summary) == action, "#{name}: #{inspect(summary["action"])}"
    end
  end

  # Review R6: the outcome a surface following a step reads is the engine's,
  # so no surface keeps a table of states.
  test "every row's outcome is the engine's word for whether it moves on by itself" do
    for {name, facts, state, _sentence, _action} <- cases() do
      outcome = HomeSummary.summary(facts)["outcome"]
      assert outcome in HomeSummary.outcomes(), name

      expected =
        case state do
          "problem" -> "failed"
          state when state in ["creating", "moving"] -> "running"
          _settled -> outcome
        end

      assert outcome == expected, "#{name}: #{outcome}"
    end

    outcome = &HomeSummary.summary(&1)["outcome"]
    assert outcome.(ready_facts([])) == "done"
    assert outcome.(ready_facts(move: move("requested"))) == "running"
    assert outcome.(facts(link: link(enrollment: manual(:open)))) == "waiting"
    assert outcome.(facts([])) == "done"
    assert outcome.(candidate_role("receiving")) == "running"
    assert outcome.(candidate_role("enrolled")) == "done"
    assert outcome.(device(move: move("undoing"))) == "running"
    assert outcome.(desktop([])) == "done"
  end

  test "the table reaches every state, every problem and every action of the vocabulary" do
    summaries = Enum.map(cases(), fn {_name, facts, _s, _t, _a} -> HomeSummary.summary(facts) end)

    states = summaries |> Enum.map(& &1["state"]) |> MapSet.new()
    kinds = for %{"state" => "problem"} = s <- summaries, into: MapSet.new(), do: kind(s)
    actions = summaries |> Enum.flat_map(&all_actions/1) |> MapSet.new()

    assert MapSet.equal?(states, MapSet.new(HomeSummary.states()))
    assert MapSet.equal?(kinds, MapSet.new(HomeSummary.problems()))
    assert MapSet.equal?(actions, MapSet.new(HomeSummary.actions()))
  end

  # Every word a surface prints: no dash, no command, no backticked code, and
  # none of the engine's own words for the move.
  test "every sentence, label and detail line obeys the copy rules and names nothing internal" do
    for {name, facts, _state, _sentence, _action} <- cases(),
        text <- printed(HomeSummary.summary(facts)) do
      assert Copy.violations(text, :prose) == [],
             "#{name}: #{inspect(text)} breaks #{inspect(Copy.violations(text, :prose))}"

      assert Copy.summary_violations(text) == [],
             "#{name}: #{inspect(text)} breaks #{inspect(Copy.summary_violations(text))}"
    end
  end

  test "every row's state, problem kind and action are in the published vocabulary" do
    for {name, facts, _state, _sentence, _action} <- cases() do
      summary = HomeSummary.summary(facts)

      assert summary["state"] in HomeSummary.states(), name
      assert Enum.all?(all_actions(summary), &(&1 in HomeSummary.actions())), name
      assert is_map(summary["detail"]), name

      if summary["state"] == "problem",
        do: assert(kind(summary) in HomeSummary.problems(), name),
        else: refute(Map.has_key?(summary["detail"], "kind"), name)
    end
  end

  # -- what Details holds -------------------------------------------------------

  describe "the detail" do
    test "the first screen is Use my own Linux server, which asks nothing" do
      summary = HomeSummary.summary(facts([]))

      assert %{
               "id" => "own_server",
               "label" => "Use my own Linux server",
               "needs" => [],
               "confirm" => nil
             } = summary["action"]

      assert summary["detail"] == %{}
    end

    # Always On setup §4: Cancel closes an open code for the owner's server,
    # which deletes nothing and so asks nothing; a new code replaces it.
    test "an open code for the owner's server is closed by Cancel" do
      summary = HomeSummary.summary(facts(link: link(enrollment: manual(:open))))

      assert summary["action"] == nil

      assert [%{"id" => "own_server"}, %{"id" => "cancel", "label" => "Cancel the code"} = cancel] =
               summary["detail"]["alternatives"]

      assert cancel["confirm"] == nil
    end

    test "ready holds the server's facts, the readiness warnings and blocks, and until when" do
      %{"detail" => detail} =
        HomeSummary.summary(ready_facts(review: review([ok(), warn()])))

      assert detail["server"] == %{
               "name" => "fermix-general-a3f9",
               "system" => "linux x86_64",
               "version" => "0.9.0"
             }

      assert detail["readiness"] == [warn()]
      assert detail["waits_until"] == "2031-05-05T11:00:00Z"
    end

    test "a blocked move lists every warning and block" do
      %{"detail" => detail} = HomeSummary.summary(ready_facts(review: review([warn(), block()])))

      assert detail["kind"] == "not_ready"
      assert detail["readiness"] == [warn(), block()]
    end

    test "on holds the server, each backup, this Mac's copies, the disk and its actions" do
      %{"detail" => detail} = HomeSummary.summary(desktop(copies_bytes: 3_221_225_472))

      assert detail["server"] == %{"name" => "fermix-general-a3f9", "version" => "0.9.0"}

      assert detail["backups"] == [
               %{"place" => "your desktop", "at" => "2031-05-04T10:00:00Z"},
               %{"place" => "S3", "at" => "2031-05-03T10:00:00Z"}
             ]

      assert detail["copies_bytes"] == 3_221_225_472
      assert detail["disk_used"] == 0.42
      assert ids(detail["actions"]) == ["back_up_now", "move_back"]

      assert detail["data"] ==
               "Your conversations and memories, the secrets, the browser and traces live on " <>
                 "your server, and whoever hosts it can technically read its disk. Backups " <>
                 "are encrypted to your recovery passphrase."
    end

    test "a problem says what Fermix last saw, and when" do
      %{"detail" => detail} =
        HomeSummary.summary(
          desktop(primary_home: server_home(backups: [{"desktop", ~U[2031-04-29 11:00:00Z]}]))
        )

      assert Map.delete(detail, "lines") == %{
               "kind" => "backup_old",
               "note" => nil,
               "seen_at" => "2031-04-29T11:00:00Z",
               "alternatives" => []
             }
    end

    test "a move undone offers Try again and nothing else" do
      summary = HomeSummary.summary(ready_facts(move: move("aborted")))

      assert %{"state" => "undone", "action" => %{"id" => "try_again"}} = summary
      assert summary["detail"]["alternatives"] in [nil, []]
    end

    test "every state with nothing more to say holds an empty detail" do
      for facts <- [device(move: move("streaming")), server([]), candidate_role("enrolled")] do
        assert HomeSummary.summary(facts)["detail"] == %{}
      end
    end
  end

  # -- the summary is the screen (Always On setup §3.1) -------------------------

  # Review simplification 3: one reading of what a screen offers.
  test "what a screen offers is its action, then the alternatives, then Details' actions" do
    assert ids(HomeSummary.offered(HomeSummary.summary(desktop([])))) ==
             ["back_up_now", "move_back"]

    code = facts(link: link(enrollment: manual(:open)))
    assert ids(HomeSummary.offered(HomeSummary.summary(code))) == ["own_server", "cancel"]

    summary = HomeSummary.summary(ready_facts([]))

    for %{"id" => id, "key" => key} = record <- HomeSummary.offered(summary),
        do: assert(HomeSummary.find_action(summary, id, key) == {:ok, record})
  end

  describe "every action is one record" do
    test "each action anywhere has its needs, confirm, url and key" do
      for {name, facts, _state, _sentence, _action} <- cases(),
          summary = HomeSummary.summary(facts),
          action <- every_action(summary) do
        assert Map.keys(action) |> Enum.sort() == ~w(confirm id key label needs url), name
        assert Enum.all?(action["needs"], &(&1 in HomeSummary.needs())), name
        assert is_binary(action["key"]), name

        assert {:ok, ^action} = HomeSummary.find_action(summary, action["id"], action["key"]),
               name

        # A confirm is stable: no time and no price in it.
        if action["confirm"] do
          refute action["confirm"] =~ ~r/[€$£]|\d:\d\d|\b\d{4}\b|\ba month\b/,
                 "#{name}: #{action["confirm"]}"
        end
      end
    end

    test "what moves or restores asks first; nothing else does" do
      asks =
        for {_name, facts, _state, _sentence, _action} <- cases(),
            action <- every_action(HomeSummary.summary(facts)),
            into: %{},
            do: {action["id"], action["confirm"] != nil}

      for id <- ~w(move_now try_again restore_here), do: assert(asks[id], id)

      for id <- ~w(learn_more update back_up_now check_again own_server move_back cancel),
          do: refute(asks[id], id)
    end

    test "what each one needs the surface to collect" do
      needs = fn facts -> HomeSummary.summary(facts)["action"]["needs"] end

      assert needs.(facts([])) == []

      # The recovery passphrase is typed twice where none is set yet, and once,
      # to be checked, where one is; a move back checks the server's own,
      # which every move to it set.
      assert needs.(ready_facts([])) == ["new_recovery_passphrase"]

      assert needs.(ready_facts(snapshots: Map.put(snapshots([]), "recipient_set", true))) ==
               ["recovery_passphrase"]

      assert needs.(returning(back("enrolled"))) == ["recovery_passphrase"]

      %{"detail" => %{"actions" => [back_up, move_back]}} = HomeSummary.summary(desktop([]))
      assert {back_up["needs"], move_back["needs"]} == {[], []}
    end

    test "Learn more opens the docs" do
      %{"action" => learn} = HomeSummary.summary(device(linked: false, moved: moved()))

      assert learn["url"] == "https://fermix.ai/docs/always-on/"
      assert HomeSummary.summary(facts([]))["action"]["url"] == nil
    end

    test "an action's key is its id, label, confirm, needs and what it acts on" do
      %{"action" => move} = HomeSummary.summary(ready_facts([]))

      assert move["key"] ==
               HomeSummary.action_key(
                 "move_now",
                 "Move now",
                 move["confirm"],
                 move["needs"],
                 @cand
               )

      %{"action" => own} = HomeSummary.summary(facts([]))

      assert own["key"] ==
               HomeSummary.action_key("own_server", "Use my own Linux server", nil, [], nil)

      # Another server to move to is another key.
      other = %{candidate() | "candidate_id" => "cand-0a1b2c3d4e5f6071"}

      moved_key =
        HomeSummary.summary(
          ready_facts(
            candidates: [other],
            link: link(enrollment: manual(:used, "cand-0a1b2c3d4e5f6071"))
          )
        )["action"]["key"]

      refute moved_key == move["key"]
    end

    test "find_action/3 finds an action by its id and key wherever it sits, and nothing else" do
      summary = HomeSummary.summary(desktop([]))
      [_back_up, move_back] = summary["detail"]["actions"]

      assert {:ok, ^move_back} = HomeSummary.find_action(summary, "move_back", move_back["key"])
      assert :error = HomeSummary.find_action(summary, "move_back", "another-key")
      assert :error = HomeSummary.find_action(summary, "move_now", move_back["key"])
    end
  end

  # B2: Move now asks once, at `ready`, naming what this home's settings
  # say stops or waits; the full review at the press changes it, and its
  # key, only when it found a warning the screen did not name.
  describe "Move now's confirm" do
    test "names each warning this home's settings give, in the review's words" do
      summary = HomeSummary.summary(ready_facts(move_items: move_items()))

      assert summary["action"]["confirm"] ==
               "Move Fermix to your server now? " <>
                 "WhatsApp stops after the move: it needs an address on the internet that " <>
                 "WhatsApp can send messages to, and fermix-general-a3f9 has none. " <>
                 "This computer serves nothing while the move runs."
    end

    test "a warning the last review of the same server gave beside them moves it, and the key" do
      plain = HomeSummary.summary(ready_facts(move_items: move_items()))

      # The review said the same warnings: Move now's confirm and key are the same.
      same = review([warn()])
      reviewed_same = HomeSummary.summary(ready_facts(move_items: move_items(), review: same))
      assert reviewed_same["action"]["key"] == plain["action"]["key"]

      s3 = %{
        "id" => "s3_size",
        "status" => "warn",
        "sentence" => "This home is about 6 GiB, more than one S3 upload carries (5 GiB)."
      }

      reviewed = HomeSummary.summary(ready_facts(move_items: move_items(), review: review([s3])))

      assert reviewed["action"]["confirm"] =~
               "Move Fermix to your server now? This home is about 6 GiB"

      refute reviewed["action"]["key"] == plain["action"]["key"]
      refute reviewed["key"] == plain["key"]
    end
  end

  describe "Details' lines" do
    test "ready: the server, its system, version and until when" do
      %{"detail" => %{"lines" => lines}} =
        HomeSummary.summary(ready_facts(zone: "Europe/Berlin"))

      assert lines == [
               %{"label" => "Server", "value" => "fermix-general-a3f9"},
               %{"label" => "System", "value" => "linux x86_64"},
               %{"label" => "Version", "value" => "0.9.0"},
               %{"label" => "Waits until", "value" => "Monday, May 5, 2031 at 1:00 PM CEST"}
             ]
    end

    test "on: the server, each backup, this Mac's copies and the server's disk" do
      %{"detail" => %{"lines" => lines}} =
        HomeSummary.summary(desktop(copies_bytes: 3_221_225_472))

      assert lines == [
               %{"label" => "Server", "value" => "fermix-general-a3f9"},
               %{"label" => "Version", "value" => "0.9.0"},
               %{
                 "label" => "Last backup to your desktop",
                 "value" => "Sunday, May 4, 2031 at 10:00 AM UTC"
               },
               %{
                 "label" => "Last backup to S3",
                 "value" => "Saturday, May 3, 2031 at 10:00 AM UTC"
               },
               %{"label" => "Backups on this Mac", "value" => "3 GiB"},
               %{"label" => "Server disk", "value" => "42% used"}
             ]
    end

    test "states that name no server have none" do
      for facts <- [
            facts([]),
            facts(link: link(enrollment: manual(:open))),
            device(move: move("streaming"))
          ],
          do: refute(Map.has_key?(HomeSummary.summary(facts)["detail"], "lines"))
    end
  end

  # The notice an app raises (Always On setup §3.1): one id per occurrence,
  # stable while it stands, so an app that keeps the last id posts it once.
  describe "the notice" do
    test "ready, until another server is held" do
      assert %{"id" => "ready:" <> @cand, "sentence" => "Your server is ready for the move."} =
               HomeSummary.summary(ready_facts([]))["notice"]

      assert HomeSummary.summary(facts([]))["notice"] == nil
    end

    test "the move done, until the first backup after it" do
      no_backup =
        desktop(primary_home: server_home(backups: []), moved: moved(~U[2031-05-04 09:00:00Z]))

      assert %{"id" => "moved:5", "sentence" => "Fermix moved to your server."} =
               HomeSummary.summary(no_backup)["notice"]

      assert HomeSummary.summary(desktop([]))["notice"] == nil
    end

    test "the server out of reach, since the link went down" do
      down = Map.put(primary(:unreachable, 11 * @minute), :down_at, ~U[2031-05-04 11:49:00Z])
      summary = HomeSummary.summary(desktop(link_primary: down))

      assert %{"id" => "cannot_reach:2031-05-04T11:49:00Z"} = summary["notice"]
      assert summary["notice"]["sentence"] == summary["sentence"]

      # The same outage later is the same notice.
      assert HomeSummary.summary(later(desktop(link_primary: down), 30 * @minute))["notice"] ==
               summary["notice"]
    end

    test "the newest backup a week old, once for that backup" do
      week = desktop(primary_home: server_home(backups: [{"desktop", ~U[2031-04-27 11:00:00Z]}]))

      assert %{"id" => "backup_week:2031-04-27T11:00:00Z", "sentence" => said} =
               HomeSummary.summary(week)["notice"]

      assert said == "Your last backup is a week old. It runs when this Mac is online."

      assert HomeSummary.summary(later(week, 2 * 86_400_000))["notice"] ==
               HomeSummary.summary(week)["notice"]
    end
  end

  describe "moving back" do
    test "on offers Move back beside Back up now, asking nothing" do
      %{"detail" => %{"actions" => actions}} = HomeSummary.summary(desktop([]))
      move_back = Enum.find(actions, &(&1["id"] == "move_back"))

      assert %{"label" => "Move back to this Mac", "needs" => [], "confirm" => nil} = move_back

      linux = HomeSummary.summary(desktop(host_os: :linux))["detail"]["actions"]
      assert Enum.find(linux, &(&1["id"] == "move_back"))["label"] == "Move back to this computer"
    end

    test "ready names the server, what runs here again and until when it waits, and Move " <>
           "now asks the server's passphrase with a confirm built here, Cancel beside it" do
      summary = HomeSummary.summary(returning(back("enrolled")))

      assert %{"id" => "move_now", "needs" => ["recovery_passphrase"]} = summary["action"]

      assert summary["action"]["confirm"] ==
               "Move Fermix back to this Mac now? iMessage, voice calls and meetings run " <>
                 "here again. Coding agents ask for your approval again. Messages sent to " <>
                 "Telegram while it moves wait until it is done. Your server stays until you " <>
                 "delete it."

      assert [%{"id" => "cancel", "confirm" => nil, "label" => "Cancel"}] =
               summary["detail"]["alternatives"]

      assert %{"label" => "Server", "value" => "fermix-general-a3f9"} in summary["detail"][
               "lines"
             ]

      assert %{"label" => "Runs here again", "value" => "iMessage, voice calls and meetings"} in summary[
               "detail"
             ]["lines"]

      assert Enum.any?(summary["detail"]["lines"], &(&1["label"] == "Waits until"))

      quiet = HomeSummary.summary(returning(back("enrolled"), stays_here: []))

      assert quiet["action"]["confirm"] ==
               "Move Fermix back to this Mac now? Coding agents ask for your approval again. " <>
                 "Messages sent to Telegram while it moves wait until it is done. Your server " <>
                 "stays until you delete it."

      assert summary["notice"] == %{
               "id" => "ready:" <> @back_cand,
               "sentence" => "This Mac is ready to take Fermix back."
             }
    end

    # HR-1: Cancel only where no move of the server's is under way: before
    # the start, once the server undid it, and where the server answers as
    # the primary with no move although the start was recorded; never while
    # the server moves, once it retired, or once this computer took the home.
    test "Cancel is offered only where the server has no move under way" do
      offers = &all_actions(HomeSummary.summary(&1))

      assert "cancel" in offers.(returning(back("enrolling")))
      assert "cancel" in offers.(returning(back("enrolled")))

      assert "cancel" in offers.(
               returning(back("enrolled"), started: true, server_move: "aborted")
             )

      assert "cancel" in offers.(returning(back("enrolled"), started: true))
      assert "cancel" in offers.(returning(back("enrolled"), record: false))

      silent = primary(:unreachable, 11 * @minute)

      for facts <- [
            returning(back("enrolled"), started: true, server_move: "streaming"),
            returning(back("enrolled"), started: true, server_move: "undoing"),
            returning(back("enrolled"), started: true, primary_home: nil, link_primary: silent),
            returning(back("receiving"), started: true, server_move: "streaming"),
            returning(back("activating"), started: true, linked: false),
            returning(back("activating"), record: false),
            returning(nil, started: true, linked: false, primary_home: nil),
            returning(:unreadable, started: true)
          ] do
        refute "cancel" in offers.(facts), inspect(facts.returning)
        refute "restore_here" in offers.(Map.put(facts, :copies, [copy()]))
      end
    end

    test "the move back's progress follows what this Mac's receiver wrote" do
      progress =
        &HomeSummary.summary(returning(back(&1), started: true, server_move: "streaming"))[
          "detail"
        ]["progress"]

      assert progress.("receiving") == "Receiving your Fermix from the server…"
      assert progress.("staged") == "Waiting for your server to hand over…"
      assert progress.("activating") == "Putting Fermix in place on this Mac…"
    end

    test "a second desktop's move back the home went past is not drawn" do
      ahead = %{primary(:connected) | epoch: 7}

      summary =
        HomeSummary.summary(returning(back("enrolled"), link_primary: ahead))

      assert summary["state"] == "on"
    end

    test "back after a move back is told once, by the epoch it came back at; back from a " <>
           "restore here is not" do
      summary = HomeSummary.summary(facts(return: back_record([])))

      assert summary["notice"] == %{
               "id" => "back:6",
               "sentence" =>
                 "Fermix is back on this Mac. Your own server still runs its retired copy: " <>
                   "turn it off or delete it."
             }

      restored = Map.merge(return_record(), %{moved_at: ~U[2031-05-04 11:50:00Z], epoch: 6})
      assert HomeSummary.summary(facts(return: restored))["notice"] == nil
    end

    test "an off that carries a notice is told: the engine that took the home back says so" do
      back = facts(return: back_record([]))

      assert HomeSummary.summary(back)["state"] == "off"
      assert %{off: false} = HomeSummary.watch(back)
      assert %{off: true} = HomeSummary.watch(facts([]))
    end

    # Only where nothing answers: no link, a link forgotten, or no session for
    # ten minutes. A server that answers that it forgot this Mac (revoked), or
    # a retired copy that answers (stale: the home lives somewhere else), is
    # not silent: a restore beside it would make a second primary.
    test "Restore here is offered wherever the server went silent and this Mac holds a copy" do
      unreachable = primary(:unreachable, 11 * @minute)
      silent = [link_primary: unreachable, primary_home: nil, copies: [copy()]]

      screens = [
        desktop(silent),
        desktop(linked: false, link_primary: nil, copies: [copy()])
      ]

      for facts <- screens do
        assert "restore_here" in all_actions(HomeSummary.summary(facts)), inspect(facts.link)
      end

      for facts <- [
            desktop(copies: [copy()]),
            desktop(link_primary: primary(:unreachable, 5 * @minute), copies: [copy()]),
            desktop(link_primary: unreachable, primary_home: nil, copies: []),
            desktop(link_primary: primary(:revoked), copies: [copy()]),
            desktop(
              link_primary: primary(:stale, 11 * @minute),
              primary_home: nil,
              copies: [copy()]
            )
          ] do
        refute "restore_here" in all_actions(HomeSummary.summary(facts)), inspect(facts.link)
      end
    end

    # The move back's TLA spec, `GoneServerCanBeRestored`: a restore that
    # stopped before its copy was in place leaves no candidate, and its
    # request either taken back by the job's end or beside no running job
    # after a restart, so Restore here is offered again; while its job runs
    # beside the request it is not.
    test "Restore here is offered again once a restore stopped before its copy was in place" do
      silent = [link_primary: primary(:unreachable, 11 * @minute), primary_home: nil]
      stopped = [return: restore_record(), copies: [copy()]] ++ silent

      assert "restore_here" in all_actions(HomeSummary.summary(desktop(stopped)))

      taken_back = Keyword.put(stopped, :return, return_record())

      assert "restore_here" in all_actions(
               HomeSummary.summary(desktop([restoring: true] ++ taken_back))
             )

      running = HomeSummary.summary(desktop([restoring: true] ++ stopped))
      assert running["state"] == "moving"
      refute "restore_here" in all_actions(running)
      assert running["detail"]["progress"] == "Restoring Fermix from the backup on this Mac…"
    end

    test "Restore here is offered only once the server was silent long enough" do
      quiet = [primary_home: nil, copies: [copy()]]

      refute "restore_here" in all_actions(
               HomeSummary.summary(
                 desktop([link_primary: primary(:unreachable, @minute)] ++ quiet)
               )
             )

      assert "restore_here" in all_actions(
               HomeSummary.summary(
                 desktop([link_primary: primary(:unreachable, 11 * @minute)] ++ quiet)
               )
             )
    end

    test "Restore here asks the passphrase and the owner's word that the server is deleted " <>
           "or stopped, says what two running copies and the restore cost, and names the " <>
           "backup's date; a newer copy moves its key" do
      facts = desktop(link_primary: primary(:unreachable, 11 * @minute), copies: [copy()])
      summary = HomeSummary.summary(facts)
      restore = Enum.find(HomeSummary.offered(summary), &(&1["id"] == "restore_here"))

      assert %{"label" => "Restore on this Mac", "needs" => ["recovery_passphrase"]} = restore

      assert restore["confirm"] ==
               "Restore Fermix on this Mac from its backup? Confirm only once you deleted " <>
                 "your server, or stopped it for good: if it runs again, two copies of Fermix " <>
                 "answer the same channels. Messages, memory and jobs since that backup are " <>
                 "gone, and Telegram keeps nothing older than 24 hours."

      assert summary["detail"]["lines"] == [
               %{"label" => "Backup on this Mac", "value" => "Sunday, May 4, 2031 at 9:30 AM UTC"}
             ]

      newer = %{facts | copies: [copy("20310504T120000Z-e5.fxsnap"), copy()]}

      moved =
        Enum.find(HomeSummary.offered(HomeSummary.summary(newer)), &(&1["id"] == "restore_here"))

      refute moved["key"] == restore["key"]
    end
  end

  describe "the server a move goes to" do
    test "the one its code enrolled, else the newest held" do
      older = %{
        candidate()
        | "candidate_id" => "cand-old",
          "enrolled_at" => "2031-05-04T09:00:00Z"
      }

      assert HomeSummary.target(ready_facts(candidates: [older, candidate()]))["candidate_id"] ==
               @cand

      assert HomeSummary.target(facts(candidates: [older, candidate()]))["candidate_id"] == @cand
      assert HomeSummary.target(facts([])) == nil
    end

    test "none from a desktop that is not moving back" do
      assert HomeSummary.target(desktop([])) == nil
    end

    # Design §9: a desktop moving back moves to its own candidate.
    test "during a move back, this desktop's own candidate, once it enrolled" do
      assert HomeSummary.target(returning(back("enrolled")))["candidate_id"] == @back_cand
      assert HomeSummary.target(returning(back("enrolling"))) == nil
      assert HomeSummary.target(returning(restore("receiving"))) == nil
    end
  end

  describe "the stale-backup push" do
    test "names the days and where the fix is, in words a phone shows" do
      sentence = Copy.summary_sentence(:backup_push, %{days: 8})

      assert sentence ==
               "Your last backup is 8 days old. It runs when your Mac is online: open Fermix " <>
                 "on your Mac to back up now."

      assert Copy.violations(sentence, :prose) == []
      assert Copy.internal_words(sentence) == []
    end
  end

  describe "the internal words" do
    test "each one is caught, and a sentence free of them passes" do
      for word <- ~w(epoch primary candidate relay rail phase ledger daemon) do
        assert Copy.internal_words("The #{word} is fine.") == [word]
      end

      assert Copy.internal_words("Shown with key id 0011.") == ["key id"]
      # An S3 credential's name, as AWS and the snapshot settings call it.
      assert Copy.internal_words("Set your Access key ID in Recovery snapshots.") == []
      assert Copy.internal_words("Fermix runs on your server.") == []
    end
  end

  # -- watching for a change ----------------------------------------------------

  # What `Home.StatusWatch` reads (companion protocol 6): the key a change is
  # told by, whether Always On is off, and when the summary next changes by
  # time alone.
  describe "watching for a change" do
    @hour 60 * @minute
    @day 24 * @hour

    test "the key does not move with the clock between deadlines" do
      for {name, facts, _state, _sentence, _action} <- cases() do
        %{key: key, next_change_ms: next} = HomeSummary.watch(facts)
        shift = min((next || 6 * @hour) - 1_000, 6 * @hour)

        if shift > 0 do
          assert HomeSummary.watch(later(facts, shift)).key == key,
                 "#{name}: the key moved #{shift} ms later"
        end
      end
    end

    test "each deadline is when the summary changes, and not a second before" do
      for {name, facts, wait, state, kind} <- deadline_cases() do
        assert HomeSummary.watch(facts).next_change_ms == wait, name

        before = HomeSummary.summary(later(facts, wait - 1_000))
        refute {before["state"], before["detail"]["kind"]} == {state, kind}, name

        at = HomeSummary.summary(later(facts, wait))
        assert {at["state"], at["detail"]["kind"]} == {state, kind}, "#{name}: #{inspect(at)}"
      end
    end

    test "off watches nothing: no deadline, and the key says off" do
      for facts <- [facts([]), facts(stays_here: [:imessage]), facts(host_os: :linux)] do
        assert %{off: true, next_change_ms: nil} = HomeSummary.watch(facts)
      end

      # The line naming what stops after the move is read when the pane
      # opens, never told: an app forgets Always On while it is off.
      assert HomeSummary.watch(facts(stays_here: [:imessage, :voice])).key ==
               HomeSummary.watch(facts([])).key

      refute HomeSummary.watch(ready_facts([])).off
      refute HomeSummary.watch(desktop([])).off
    end

    test "the key moves with the state, the action, the problem kind and a step's sentence" do
      keys =
        for facts <- [
              facts([]),
              facts(link: link(enrollment: manual(:open))),
              facts(link: link(enrollment: manual(:used))),
              ready_facts([]),
              ready_facts(review: review([warn(), block()])),
              device(move: move("streaming")),
              device(move: move("committing")),
              desktop([]),
              desktop(primary_home: server_home(disk: 0.9))
            ],
            do: HomeSummary.watch(facts).key

      assert length(Enum.uniq(keys)) == length(keys)
    end

    test "on and problem keys leave out the sentence, whose figures move with the clock" do
      an_hour_ago = server_home(backups: [{"desktop", ~U[2031-05-04 11:00:00Z]}])

      assert HomeSummary.summary(desktop(primary_home: an_hour_ago))["sentence"] ==
               "Fermix runs on your server. Last backup 1 hour ago."

      assert HomeSummary.summary(later(desktop(primary_home: an_hour_ago), 60 * @minute))[
               "sentence"
             ] == "Fermix runs on your server. Last backup 2 hours ago."

      assert HomeSummary.watch(desktop(primary_home: an_hour_ago)).key ==
               HomeSummary.watch(later(desktop(primary_home: an_hour_ago), 60 * @minute)).key

      assert HomeSummary.watch(desktop(primary_home: server_home(disk: 0.9))).key ==
               HomeSummary.watch(desktop(primary_home: server_home(disk: 0.96))).key
    end

    # A desktop draws its own summary from what its server's `home.status`
    # holds, so the server's key moves with that too.
    test "a server's key moves with the backups its desktops draw" do
      base = HomeSummary.watch(server([])).key

      assert HomeSummary.watch(
               server(snapshots: snapshots([{"desktop", ~U[2031-05-04 11:30:00Z]}]))
             ).key != base
    end

    # The apps raise their notification once the newest backup is a week old
    # (M75 lean v1 §7), a mark the summary's words do not show: it is a
    # deadline, and the key moves once as it passes, then holds.
    test "a backup's week is a deadline, and the key moves once as it passes" do
      four_days_ago = ~U[2031-04-30 12:00:00Z]

      for {name, facts} <- [
            {"a desktop whose server's backup is four days old",
             desktop(primary_home: server_home(backups: [{"desktop", four_days_ago}]))},
            {"a desktop with no backup since a move four days ago",
             desktop(primary_home: server_home(backups: []), moved: moved(four_days_ago))},
            {"a server whose backup is four days old",
             server(snapshots: snapshots([{"desktop", four_days_ago}]))}
          ] do
        %{key: key, next_change_ms: wait} = HomeSummary.watch(facts)
        assert HomeSummary.summary(facts)["detail"]["kind"] == "backup_old", name
        assert wait == 3 * @day, name

        assert HomeSummary.watch(later(facts, wait - 1_000)).key == key, name

        week = HomeSummary.watch(later(facts, wait))
        refute week.key == key, "#{name}: the week passed untold"
        assert week.next_change_ms == nil, name
        assert HomeSummary.summary(later(facts, wait))["detail"]["kind"] == "backup_old", name
        assert HomeSummary.watch(later(facts, wait + 2 * @day)).key == week.key, name
      end
    end

    test "the computer that sets Always On up does not watch its own backups" do
      assert HomeSummary.watch(facts(snapshots: snapshots([{"s3", ~U[2031-05-01 10:00:00Z]}]))) ==
               HomeSummary.watch(facts([]))
    end
  end

  # {name, facts, ms until the change, the state and problem kind it changes to}
  defp deadline_cases do
    [
      {"a server held until its day is out", ready_facts([]), 23 * @hour, "off", nil},
      {"a server silent for five minutes",
       desktop(link_primary: primary(:unreachable, 5 * @minute)), 5 * @minute, "problem",
       "cannot_reach"},
      {"a backup two hours old", desktop([]), 3 * @day - 2 * @hour + 1_000, "problem",
       "backup_old"},
      {"no backup since a move a day ago",
       desktop(primary_home: server_home(backups: []), moved: moved(~U[2031-05-03 12:00:00Z])),
       2 * @day + 1_000, "problem", "backup_old"},
      {"the server's backup two hours old", server([]), 3 * @day - 2 * @hour + 1_000, "problem",
       "backup_old"}
    ]
  end

  # The same facts `ms` later: the clock, the awake count of a link that is
  # down, and the servers held only while they have not expired
  # (`Home.Candidates` drops one at its expiry).
  defp later(facts, ms) do
    now = DateTime.add(facts.now, ms, :millisecond)
    link = %{facts.link | primary: advance(facts.link.primary, :down_ms, ms)}

    %{facts | now: now, link: link, candidates: live(facts.candidates, now)}
  end

  defp advance(nil, _key, _ms), do: nil

  defp advance(map, key, ms) do
    case Map.get(map, key) do
      count when is_integer(count) -> Map.put(map, key, count + ms)
      _none -> map
    end
  end

  defp live(candidates, now) do
    Enum.filter(candidates, fn %{"expires_at" => at} ->
      {:ok, at, 0} = DateTime.from_iso8601(at)
      DateTime.compare(at, now) == :gt
    end)
  end

  # -- facts --------------------------------------------------------------------

  defp facts(overrides) do
    Map.merge(
      %{
        role: :primary,
        host_os: :macos,
        now: @now,
        linked: false,
        moved: nil,
        move: nil,
        link: link([]),
        candidates: [],
        review: nil,
        move_items: [],
        snapshots: snapshots([]),
        disk: nil,
        primary_home: nil,
        primary_too_old: false,
        copies_bytes: nil,
        stays_here: [],
        zone: "Etc/UTC",
        return: nil,
        returning: nil,
        restoring: false,
        copies: []
      },
      Map.new(overrides)
    )
  end

  defp ready_facts(overrides) do
    facts([candidates: [candidate()], link: link(enrollment: manual(:used, @cand))] ++ overrides)
  end

  defp device(overrides),
    do: facts([role: :device, linked: true, moved: moved()] ++ overrides)

  defp desktop(overrides) do
    {primary, overrides} = Keyword.pop(overrides, :link_primary, primary(:connected))
    device([link: link(primary: primary), primary_home: server_home([])] ++ overrides)
  end

  # A desktop moving back: its candidate's state (`state`, nil for none) and
  # the return's record (`record: false` for none; `started:` once the
  # server started the move), the server's own part saying its move's phase
  # (`server_move:`).
  defp returning(state, overrides \\ []) do
    {record?, overrides} = Keyword.pop(overrides, :record, true)
    {started?, overrides} = Keyword.pop(overrides, :started, false)
    {server_move, overrides} = Keyword.pop(overrides, :server_move)

    record = if started?, do: started_record(), else: return_record()
    home = server_home([]) |> Map.put("move", server_move && move(server_move))

    desktop(
      [
        returning: state,
        return: if(record?, do: record),
        primary_home: home,
        stays_here: [:imessage, :voice, :meetings]
      ] ++ overrides
    )
  end

  defp back(phase) do
    enrolled = phase not in ["enrolling"]

    %{
      "v" => 1,
      "phase" => phase,
      "kind" => "return",
      "primary" => %{"name" => "fermix-general-a3f9"},
      "candidate_id" => if(enrolled, do: @back_cand),
      "listen_until" => if(enrolled, do: "2031-05-05T11:00:00Z")
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp restore(phase) do
    %{
      "v" => 1,
      "phase" => phase,
      "kind" => "local",
      "primary" => %{"name" => "fermix-general-a3f9"}
    }
  end

  defp return_record do
    %{
      from: "fermix-general-a3f9",
      primary_epoch: 5,
      started_at: ~U[2031-05-04 11:30:00Z]
    }
  end

  defp started_record,
    do:
      Map.merge(return_record(), %{
        move_started_at: ~U[2031-05-04 11:40:00Z],
        candidate_id: @back_cand,
        move_id: "mv-0001"
      })

  defp back_record(overrides) do
    started_record()
    |> Map.merge(%{moved_at: ~U[2031-05-04 11:50:00Z], epoch: 6})
    |> Map.merge(Map.new(overrides))
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp restore_record, do: Map.put(return_record(), :restore_requested, @copy)

  defp copy(name \\ @copy, at \\ ~U[2031-05-04 09:30:00Z]), do: %{name: name, at: at}

  defp server(overrides) do
    desktop_row = %{device_id: "6d2b3c1e", name: "Studio Mac", connected: true}

    facts(
      [
        link: link(desktops: [desktop_row]),
        snapshots: snapshots([{"desktop", ~U[2031-05-04 10:00:00Z]}]),
        disk: %{"used" => 0.42, "nearly_full" => false}
      ] ++ overrides
    )
  end

  defp candidate_role(phase),
    do: facts(role: :candidate, move: %{"phase" => phase, "candidate" => nil, "sentence" => "."})

  defp link(overrides),
    do: Map.merge(%{primary: nil, desktops: [], enrollment: nil}, Map.new(overrides))

  defp primary(status, down_ms \\ nil) do
    %{
      name: "fermix-general-a3f9",
      connected: status == :connected,
      status: status,
      since: if(status == :connected, do: ~U[2031-05-04 09:00:00Z]),
      epoch: 5,
      sentence: "The link's own words.",
      down_ms: down_ms
    }
  end

  defp manual(state, candidate_id \\ nil),
    do: %{state: state, expires_at: ~U[2031-05-05 10:00:00Z], candidate_id: candidate_id}

  defp candidate do
    %{
      "candidate_id" => @cand,
      "name" => "fermix-general-a3f9",
      "os" => "linux",
      "arch" => "x86_64",
      "version" => "0.9.0",
      "node_id" => String.duplicate("b7", 32),
      "snapshots" => nil,
      "enrolled_at" => "2031-05-04T11:00:00Z",
      "expires_at" => "2031-05-05T11:00:00Z"
    }
  end

  defp review(items) do
    %{
      candidate_id: @cand,
      reviewed_at: ~U[2031-05-04 11:30:00Z],
      ready: not Enum.any?(items, &(&1["status"] == "block")),
      items: items
    }
  end

  defp ok, do: %{"id" => "disk", "status" => "ok", "sentence" => "The disk has room."}

  defp warn,
    do: %{
      "id" => "whatsapp",
      "status" => "warn",
      "sentence" =>
        "WhatsApp stops after the move: it needs an address on the internet that WhatsApp " <>
          "can send messages to, and fermix-general-a3f9 has none."
    }

  defp block,
    do: %{
      "id" => "disk",
      "status" => "block",
      "sentence" => "This home is about 4 GiB; the move needs about 9 GiB free."
    }

  defp move(phase),
    do: %{"phase" => phase, "candidate" => "fermix-general-a3f9", "sentence" => "."}

  defp moved(at \\ ~U[2031-04-20 09:00:00Z]),
    do: %{to: "fermix-general-a3f9", moved_at: at, epoch: 5}

  defp server_home(overrides) do
    backups =
      Keyword.get(overrides, :backups, [
        {"desktop", ~U[2031-05-04 10:00:00Z]},
        {"s3", ~U[2031-05-03 10:00:00Z]}
      ])

    used = Keyword.get(overrides, :disk, 0.42)

    %{
      "role" => "primary",
      "version" => "0.9.0",
      "snapshots" => snapshots(backups),
      "disk" => %{"used" => used, "nearly_full" => used >= 0.85}
    }
  end

  defp snapshots(backups) do
    targets =
      for {id, at} <- backups do
        %{
          "id" => id,
          "label" => if(id == "s3", do: "S3", else: "your desktop"),
          "configured" => true,
          "last_verified" => %{"at" => DateTime.to_iso8601(at)}
        }
      end

    %{"configured" => targets != [], "targets" => targets}
  end

  # The review's items this home's settings give, as `MoveReadiness` words
  # them (the summary carries no copy of its own for them).
  defp move_items do
    [
      %{id: "stays_here", status: :ok, sentence: "Voice calls and meetings are not turned on."},
      %{id: "whatsapp", status: :warn, sentence: warn()["sentence"]},
      %{
        id: "serves_nothing",
        status: :warn,
        sentence: "This computer serves nothing while the move runs."
      }
    ]
  end

  # -- reading a summary --------------------------------------------------------

  defp action_id(%{"action" => nil}), do: nil
  defp action_id(%{"action" => %{"id" => id}}), do: id

  defp kind(%{"detail" => %{"kind" => kind}}), do: kind

  defp ids(actions), do: Enum.map(actions, & &1["id"])

  defp every_action(summary), do: HomeSummary.offered(summary)

  # The main action and every one Details offers.
  defp all_actions(summary), do: ids(HomeSummary.offered(summary))

  # Every word a surface prints as prose: the sentence, each action's label
  # and confirm, the notes, the step in hand, the labels of Details' lines
  # and the notice.
  defp printed(%{"sentence" => sentence, "detail" => detail} = summary) do
    words = Enum.flat_map(HomeSummary.offered(summary), &[&1["label"] | List.wrap(&1["confirm"])])
    notes = for key <- ~w(note data progress), is_binary(detail[key]), do: detail[key]
    lines = for %{"label" => label} <- detail["lines"] || [], do: label
    notice = for %{"sentence" => said} <- List.wrap(summary["notice"]), do: said

    [sentence | words] ++ notes ++ lines ++ notice
  end
end
