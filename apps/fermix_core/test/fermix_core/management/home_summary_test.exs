defmodule FermixCore.Management.HomeSummaryTest do
  # `home.status.summary` (M75 lean v1 §7): one table over every state and
  # every problem, from the facts the gatherer collects to the state, the
  # sentence and the one action every surface shows. The facts are invented
  # and written here, so each row names exactly what makes its state.
  use ExUnit.Case, async: true

  alias FermixCore.Computers.Consent
  alias FermixCore.Home.Snapshot.S3
  alias FermixCore.Home.Snapshot.Status
  alias FermixCore.Management.Copy
  alias FermixCore.Management.HomeSummary

  @now ~U[2031-05-04 12:00:00Z]
  # A failed backup's try, and how its sentence states it.
  @failed_at ~U[2031-05-04 10:00:00Z]
  @failed_said "Sunday, May 4, 2031 at 10:00 AM UTC"
  @recipient "fxsnap1.AAECAwQFBgcICQoLDA0ODw.B3l5ExMinEfPofapoLSG57ZGCBl_fiIqFbtB5nPDNqA"
  @minute 60_000
  @cand "cand-5e2a9c1f7b3d4086"
  @back_cand "cand-7a3e1c9b5d2f4086"
  @copy "20310504T093000Z-e5.fxsnap"
  @connect_sentence "Waiting for your server: run the command on it and paste the code when " <>
                      "it asks. It takes Debian 12, Debian 13 or Ubuntu 24.04 on arm64 or " <>
                      "x86_64 with Linux 6.2 or later, which Debian 12 has only with a newer " <>
                      "kernel than its own. The code works for 30 minutes, and installing " <>
                      "takes a few of them."

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
      # M87 §07: the Mac's own voice stays with the Mac; a phone's calls ride its
      # session to wherever the home runs.
      {"a home that uses all three", facts(stays_here: [:imessage, :voice, :meetings]), "off",
       "Keep Fermix running when this Mac sleeps. It moves to a server you own. iMessage and " <>
         "meetings stop after the move. This Mac's voice calls stop after the move; calls " <>
         "from your phone carry on at your server when Talk to Fermix is on there and its " <>
         "key is in your server's secret store.", "own_server"},
      {"a home that uses only iMessage", facts(stays_here: [:imessage]), "off",
       "Keep Fermix running when this Mac sleeps. It moves to a server you own. iMessage " <>
         "stops after the move.", "own_server"},
      {"a Linux home with nothing", facts(host_os: :linux), "off",
       "Keep Fermix running when this computer sleeps. It moves to a server you own.",
       "own_server"},
      {"a Linux home with voice calls on", facts(host_os: :linux, stays_here: [:voice]), "off",
       "Keep Fermix running when this computer sleeps. It moves to a server you own. This " <>
         "computer's voice calls stop after the move; calls from your phone carry on at your " <>
         "server when Talk to Fermix is on there and its key is in your server's secret " <>
         "store.", "own_server"},
      {"a code for the owner's server", facts(link: link(enrollment: manual(:open))), "connect",
       @connect_sentence, nil},
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
      {"a code a server used, past its half hour with no server recorded",
       facts(link: link(enrollment: manual(:expired))), "off",
       "Keep Fermix running when this Mac sleeps. It moves to a server you own.", "own_server"},
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
      {"a computer asking to join the home", desktop(primary_home: asking_home()), "on",
       "A computer named loft-linux (Linux) asks to join your Fermix. Add it only if it " <>
         "shows 482 913.", "approve_computer"},
      {"a server's copy retired by a move back",
       device(linked: false, moved: moved_to("studio-mac"), moved_back: true, host_os: :linux),
       "retired", "This copy is retired: Fermix moved back to studio-mac.", "learn_more"},
      {"a desktop with a fresh backup", desktop([]), "on",
       "Fermix runs on your server. Last backup 2 hours ago.", nil},
      # M97 §7.3: a computer that moved before its server could ask what it
      # may use here offers nothing until the owner reviews it.
      {"a desktop whose switches wait for the review",
       desktop(offers_review: Consent.view(Consent.block([:files, :shell], os: :macos))), "on",
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
      # M97 §3.4: the server leads, from the release channel, once the app
      # for each computer that keeps the backups carries the release.
      {"a server older than this Mac", desktop(primary_behind: true, primary_home: nil),
       "problem",
       "Your server runs an older Fermix than this Mac. It updates on its own once the app " <>
         "for each computer that keeps your backups carries the newer one.", "learn_more"},
      # M97 §3.4: past the server's window, settings only; and a server that
      # went ahead of the apps, which this Mac cannot read.
      {"a Mac past the server's window", desktop(standing: :settings_only), "problem",
       "Update Fermix on this Mac. Your server runs a newer Fermix, so until then this Mac " <>
         "can change settings only.", "update"},
      {"a server ahead of the apps",
       desktop(
         primary_home: Map.put(server_home([]), "update", %{"ahead_of_apps" => true}),
         readable: {:error, {:newer_engine, "0.9.0", "0.8.0"}}
       ), "problem",
       "Your server runs a newer Fermix than this Mac can restore. Update Fermix on this Mac.",
       "update"},
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
       "back_up_now"},
      {"a backup that failed",
       desktop(
         primary_home: status_home(tried(Status.empty(), @failed_at, "S3 refused the snapshot."))
       ), "problem", "Backing up to S3 failed on #{@failed_said}: S3 refused the snapshot.",
       "back_up_now"}
    ]
  end

  defp server_cases do
    [
      {"the server itself", server([]), "primary", "Fermix runs here.", nil},
      # M97 §4: a server that left out the settings it inherited says so.
      {"the server the day it took its own sandbox setting",
       server(server_sandbox: ~U[2031-05-03 12:00:00Z]), "primary", "Fermix runs here.", nil},
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
       "This server waited too long for its move. Open a new code in Always On and run the " <>
         "command here again.", "learn_more"},
      {"a server whose enrollment failed", candidate_role("failed"), "problem",
       "This server did not finish setting up. Open a new code in Always On and run the " <>
         "command here again.", "learn_more"},
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
  # none of the engine's own words for the move. The systems the server's
  # first boot takes are names the copy interpolates (`Copy.own_server_names/0`).
  test "every sentence, label and detail line obeys the copy rules and names nothing internal" do
    names = [@failed_said | Copy.own_server_names()]

    for {name, facts, _state, _sentence, _action} <- cases(),
        text <- printed(HomeSummary.summary(facts)) do
      assert Copy.violations(text, :prose, names) == [],
             "#{name}: #{inspect(text)} breaks #{inspect(Copy.violations(text, :prose, names))}"

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

  # M97 §7.3 and §4: what a computer keeps on for its server, and a server
  # that took its own sandbox setting.
  describe "a computer's offers" do
    test "a desktop whose switches wait offers the review, says it once, and shows its block" do
      block = Consent.view(Consent.block([:files, :shell], os: :macos))
      summary = HomeSummary.summary(desktop(offers_review: block))

      assert %{"id" => "computer_review", "sentence" => said} = summary["notice"]
      assert said =~ "until you review"
      assert summary["detail"]["review"] == block
      assert "review_offers" in Enum.map(HomeSummary.offered(summary), & &1["id"])

      reviewed = HomeSummary.summary(desktop([]))
      refute Map.has_key?(reviewed["detail"], "review")
      refute "review_offers" in Enum.map(HomeSummary.offered(reviewed), & &1["id"])
      refute match?(%{"id" => "computer_review"}, reviewed["notice"])
    end

    test "the move's ready screen shows what this computer keeps on" do
      block = Consent.view(Consent.block([:files, :shell, :browser], os: :macos))

      candidate = %{
        "candidate_id" => "cand-1",
        "name" => "garden-box",
        "expires_at" => "2031-05-05T12:00:00Z"
      }

      summary =
        HomeSummary.summary(facts(candidates: [candidate], keeps_on: block))

      assert summary["state"] == "ready"
      assert summary["detail"]["keeps_on"] == block
    end

    test "a server says for a week that it took its own sandbox setting" do
      at = ~U[2031-05-03 12:00:00Z]

      assert %{"id" => "server_sandbox:2031-05-03T12:00:00Z", "sentence" => said} =
               HomeSummary.summary(server(server_sandbox: at))["notice"]

      assert said =~ "its own sandbox setting: open"

      watched = HomeSummary.watch(server(server_sandbox: at))
      assert watched.next_change_ms <= 6 * 86_400_000

      later = server(server_sandbox: at, now: DateTime.add(at, 8 * 86_400, :second))
      refute match?(%{"id" => "server_sandbox:" <> _}, HomeSummary.summary(later)["notice"])
    end
  end

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

      assert [
               %{"id" => "own_server"} = renew,
               %{"id" => "cancel", "label" => "Cancel the code"} = cancel
             ] =
               summary["detail"]["alternatives"]

      assert cancel["confirm"] == nil

      # Review m2: a new code ends the one the server may be using already.
      assert renew["label"] == "Open a new code (the current one stops working)"
      assert renew["confirm"] == nil
    end

    # Review m1: a server that used its code and stalls leaves a way out.
    test "connecting offers Cancel, which closes the code the server used" do
      summary = HomeSummary.summary(facts(link: link(enrollment: manual(:used))))

      assert summary["action"] == nil

      assert [%{"id" => "cancel", "label" => "Cancel the code", "confirm" => nil}] =
               summary["detail"]["alternatives"]
    end

    # Review M2: a held server, ready or blocked by its review, can be
    # forgotten, after a confirm, and never while a move to it runs.
    test "a held server offers Forget this server, which asks first" do
      for facts <- [ready_facts([]), ready_facts(review: review([warn(), block()]))] do
        summary = HomeSummary.summary(facts)

        assert [%{"id" => "cancel", "label" => "Forget this server"} = forget] =
                 summary["detail"]["alternatives"]

        assert forget["needs"] == []

        assert forget["confirm"] ==
                 "Forget this server? Fermix stops holding it for the move. To move later, " <>
                   "set up a server with a new code."
      end

      moving = HomeSummary.summary(ready_facts(move: move("requested")))
      assert moving["state"] == "ready"
      assert moving["detail"]["alternatives"] in [nil, []]
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
      assert ids(detail["actions"]) == ["back_up_now", "add_computer", "move_back"]

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

    # Re-check finding 2: a move undone leaves its server held, so it can be
    # forgotten there too, with ready's confirm and its key (the held
    # server's), but not while the undoing still runs.
    test "a move undone offers Try again, and Forget this server beside it" do
      summary = HomeSummary.summary(ready_facts(move: move("aborted")))

      assert %{"state" => "undone", "action" => %{"id" => "try_again"}} = summary

      assert [%{"id" => "cancel", "label" => "Forget this server"} = forget] =
               summary["detail"]["alternatives"]

      assert [forget] == HomeSummary.summary(ready_facts([]))["detail"]["alternatives"]

      undoing = HomeSummary.summary(ready_facts(move: move("undoing")))
      assert undoing["state"] == "undone"
      assert undoing["detail"]["alternatives"] in [nil, []]
    end

    test "every state with nothing more to say holds an empty detail" do
      for facts <- [device(move: move("streaming")), candidate_role("enrolled")] do
        assert HomeSummary.summary(facts)["detail"] == %{}
      end

      # The server's own screen offers Add a computer (M97 §3.1), and nothing more.
      assert %{"actions" => [%{"id" => "add_computer"}]} =
               detail = HomeSummary.summary(server([]))["detail"]

      assert Map.keys(detail) == ["actions"]
    end
  end

  # Always On's inbound webhooks (design, "Inbound webhooks without a public
  # IP"): once the home is on a server, a desktop's screen prints the
  # Tailscale Funnel mount of each webhook the server serves, from the
  # server's own `home.status`, with the one-time policy step and the
  # caveats, and nothing when it serves none.
  describe "the webhooks a server needs" do
    # Review F6 (D12): the one-time tailnet steps Funnel needs first, after
    # what the server serves, and only that (EC2 test finding 7).
    @webhooks_steps "Tailscale Funnel. Once, in your tailnet policy, give tag:fermix-server " <>
                      "the funnel node attribute, and turn on MagicDNS and HTTPS " <>
                      "certificates. Then run each of these on the server; a new address can " <>
                      "take about ten minutes to resolve."
    @webhooks_sentence "WhatsApp and your webhook sources reach Fermix on your server through " <>
                         @webhooks_steps
    # Review F3 (D10): where Meta is pointed, and that nothing arrives until then.
    @whatsapp_note "Tailscale prints the address this gives. In Meta's app dashboard, set it " <>
                     "as the Callback URL with your verify token and press Verify and save; " <>
                     "until then WhatsApp messages do not arrive."
    # Review F4 (D11): the mount is the source's prefix, so no secret is on the
    # screen; the sender keeps its path and takes Tailscale's host.
    @cue_note "Tailscale prints the address this gives. In the sender (GitHub and the like), " <>
                "change the host of the source's webhook address to the one it prints, and " <>
                "keep the path."
    @port_note "Funnel publishes everything tailscale serve has on port 443, so put only " <>
                 "these paths there."
    # With Funnel, its ingress is the one way in; without Tailscale, the tunnel
    # the next note names is (EC2 test finding 8).
    @ingress_note "Funnel traffic comes in through Tailscale's ingress servers, which see " <>
                    "only encrypted bytes: with Funnel, they are the one way a webhook " <>
                    "reaches your server."

    test "a server with WhatsApp alone: its one mount, the policy step and the caveats" do
      %{"state" => "on", "detail" => detail} =
        HomeSummary.summary(desktop(primary_home: server_home(webhooks: [whatsapp(4130)])))

      assert detail["webhooks"] == %{
               "sentence" => "WhatsApp reaches Fermix on your server through " <> @webhooks_steps,
               "mounts" => [
                 %{
                   "label" => "WhatsApp",
                   # Review F2 (D9): the installer sets no Tailscale operator.
                   "command" =>
                     "sudo tailscale funnel --bg --set-path=/webhook/whatsapp " <>
                       "http://127.0.0.1:4130/webhook/whatsapp",
                   "note" => @whatsapp_note
                 }
               ],
               "notes" => [
                 @port_note,
                 @ingress_note,
                 "Without Tailscale, run Cloudflare Tunnel to the same loopback port " <>
                   "instead: 4130 for WhatsApp."
               ]
             }
    end

    test "webhook sources alone: one mount each of the source's prefix on the server's door" do
      served = [cue("github", 4532), cue("stripe", 4532)]

      %{"detail" => detail} =
        HomeSummary.summary(desktop(primary_home: server_home(webhooks: served)))

      assert detail["webhooks"]["mounts"] == [
               %{
                 "label" => "Webhook source github",
                 "command" =>
                   "sudo tailscale funnel --bg --set-path=/cues/hooks/github " <>
                     "http://127.0.0.1:4532/cues/hooks/github",
                 "note" => @cue_note
               },
               %{
                 "label" => "Webhook source stripe",
                 "command" =>
                   "sudo tailscale funnel --bg --set-path=/cues/hooks/stripe " <>
                     "http://127.0.0.1:4532/cues/hooks/stripe",
                 "note" => @cue_note
               }
             ]

      refute detail["webhooks"] |> Jason.encode!() |> String.contains?("<random>")

      assert detail["webhooks"]["sentence"] ==
               "Your webhook sources reach Fermix on your server through " <> @webhooks_steps

      assert detail["webhooks"]["notes"] == [
               @port_note,
               @ingress_note,
               "Without Tailscale, run Cloudflare Tunnel to the same loopback port instead: " <>
                 "4532 for webhook sources."
             ]
    end

    test "both: WhatsApp first, then each source, and the tunnel names both ports" do
      served = [whatsapp(4130), cue("github", 4532)]

      %{"detail" => detail} =
        HomeSummary.summary(desktop(primary_home: server_home(webhooks: served)))

      assert Enum.map(detail["webhooks"]["mounts"], & &1["label"]) ==
               ["WhatsApp", "Webhook source github"]

      assert detail["webhooks"]["sentence"] == @webhooks_sentence

      assert ("Without Tailscale, run Cloudflare Tunnel to the same loopback ports instead: " <>
                "4130 for WhatsApp and 4532 for webhook sources.") in detail["webhooks"]["notes"]
    end

    test "neither: no webhooks at all, and none from a server whose part did not arrive" do
      refute Map.has_key?(HomeSummary.summary(desktop([]))["detail"], "webhooks")
      refute Map.has_key?(HomeSummary.summary(desktop(primary_home: nil))["detail"], "webhooks")
    end

    # The server's summary rides inside each desktop's `home.status`
    # (`primary_home`), where the mounts would pass the protocol's nesting
    # bound, so only the desktop's own screen draws them.
    test "only a desktop's screen of a server it reaches shows them, never a problem's, a move's or the server's own" do
      served = server_home(webhooks: [whatsapp(4130)])

      for facts <- [
            desktop(primary_home: %{served | "disk" => %{"used" => 0.9, "nearly_full" => true}}),
            desktop(primary_home: served, link_primary: primary(:unreachable, 11 * @minute)),
            device(move: move("streaming"), primary_home: served),
            server([])
          ] do
        refute Map.has_key?(HomeSummary.summary(facts)["detail"], "webhooks")
      end
    end

    test "every word is plain, and the key moves with what the server serves" do
      served = [whatsapp(4130), cue("github", 4532)]

      %{"detail" => %{"webhooks" => webhooks}} =
        HomeSummary.summary(desktop(primary_home: server_home(webhooks: served)))

      for text <-
            [webhooks["sentence"] | webhooks["notes"]] ++
              Enum.flat_map(webhooks["mounts"], &[&1["label"], &1["note"]]) do
        assert Copy.summary_violations(text) == [], text
        assert Copy.violations(text, :prose, ["github"]) == [], text
      end

      keys =
        for served <- [
              [],
              [whatsapp(4130)],
              [whatsapp(4131)],
              [whatsapp(4130), cue("github", 4532)]
            ],
            do: HomeSummary.summary(desktop(primary_home: server_home(webhooks: served)))["key"]

      assert length(Enum.uniq(keys)) == length(keys)
    end
  end

  # -- the summary is the screen (Always On setup §3.1) -------------------------

  # Review simplification 3: one reading of what a screen offers.
  test "what a screen offers is its action, then the alternatives, then Details' actions" do
    assert ids(HomeSummary.offered(HomeSummary.summary(desktop([])))) ==
             ["back_up_now", "add_computer", "move_back"]

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

      %{"detail" => %{"actions" => [back_up, add, move_back]}} = HomeSummary.summary(desktop([]))
      assert {back_up["needs"], add["needs"], move_back["needs"]} == {[], [], []}
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
      [_back_up, _add, move_back] = summary["detail"]["actions"]

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

    # Step 7: whether the link runs direct or through Fermix's relay, in the
    # summary's own words, while its session is up.
    test "on: the link's path while it is connected, and none while it is not" do
      for {path, value} <- [direct: "Direct", relay: "Through Fermix's network"] do
        connected = Map.put(primary(:connected), :path, path)
        %{"detail" => %{"lines" => lines}} = HomeSummary.summary(desktop(link_primary: connected))

        assert List.last(lines) == %{"label" => "Connection", "value" => value}
        assert Copy.summary_violations(value) == []
      end

      %{"detail" => %{"lines" => lines}} =
        HomeSummary.summary(desktop(link_primary: Map.put(primary(:connected), :path, nil)))

      refute Enum.any?(lines, &(&1["label"] == "Connection"))

      direct =
        HomeSummary.summary(desktop(link_primary: Map.put(primary(:connected), :path, :direct)))

      relayed =
        HomeSummary.summary(desktop(link_primary: Map.put(primary(:connected), :path, :relay)))

      refute direct["key"] == relayed["key"]
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

    # Review M2: a held server whose 24 hours ran out is told once, by its id,
    # on the screen it leaves.
    test "a held server whose day ran out, until a new code" do
      lapsed = facts(link: link(enrollment: manual(:used, @cand)), lapsed: @cand)
      summary = HomeSummary.summary(lapsed)

      assert summary["state"] == "off"

      assert summary["notice"] == %{
               "id" => "server_lapsed:" <> @cand,
               "sentence" =>
                 "Your server waited 24 hours for the move and must be set up again. Open a " <>
                   "new code in Always On and run the command on it again."
             }

      assert %{off: false} = HomeSummary.watch(lapsed)
    end

    # Review m3: Restore here finished is told once, by the epoch it came
    # back at, naming the backup it restored.
    test "a restore finished here, naming its backup's day" do
      restored =
        Map.merge(return_record(), %{
          restored: "20310503T093000Z-e5.fxsnap",
          moved_at: ~U[2031-05-04 11:50:00Z],
          epoch: 6
        })

      summary = HomeSummary.summary(facts(return: restored, zone: "Europe/Berlin"))

      assert summary["state"] == "off"

      assert summary["notice"] == %{
               "id" => "restored:6",
               "sentence" =>
                 "Fermix runs on this Mac again, from its backup of Saturday, May 3, 2031."
             }

      assert Copy.violations(summary["notice"]["sentence"], :prose, ["Saturday, May 3, 2031"]) ==
               []

      # A restore merged into a move back's record that had started is still a
      # restore.
      both = Map.merge(started_record(), restored)
      assert %{"id" => "restored:6"} = HomeSummary.summary(facts(return: both))["notice"]
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

  # Back up now's backup runs on the server: the screen that offers it runs
  # until the backup ends, and its end says whether the backup was stored,
  # so a surface following the step (`--wait`) stops at the end and says so.
  describe "a backup now" do
    test "on runs while the server backs up, saying so, and is done once it ends" do
      home = server_home([])
      running = put_in(home, ["snapshots", "running"], true)

      summary = HomeSummary.summary(desktop(primary_home: running))
      assert {summary["state"], summary["outcome"]} == {"on", "running"}
      assert summary["detail"]["progress"] == "Backing up now…"

      ended = HomeSummary.summary(desktop(primary_home: home))
      assert {ended["outcome"], ended["detail"]["progress"]} == {"done", nil}
      refute ended["key"] == summary["key"]
    end

    test "a backup that ends failed leaves its screen on the failure, not done" do
      tried = tried(Status.empty(), ~U[2031-05-04 11:00:00Z], "S3 refused the snapshot.")
      running = put_in(status_home(tried), ["snapshots", "running"], true)

      assert %{"state" => "problem", "outcome" => "running"} =
               HomeSummary.summary(desktop(primary_home: running))

      assert %{"state" => "problem", "outcome" => "failed"} =
               HomeSummary.summary(desktop(primary_home: status_home(tried)))
    end
  end

  # The owner's rule: a backup that failed is a problem until one is stored
  # there (`Snapshot.Status` keeps the place's error until then), and a later
  # try that fails raises it again in that try's own words. Built through
  # `Snapshot.Status` itself, so the rule rests on what the scheduler writes.
  describe "a backup that failed" do
    test "is a problem in the try's own words, where it went and when, with Back up now" do
      tried = tried(Status.empty(), ~U[2031-05-04 10:00:00Z], "S3 refused the snapshot")
      summary = HomeSummary.summary(desktop(primary_home: status_home(tried)))

      assert %{"state" => "problem", "detail" => %{"kind" => "backup_failed"} = detail} = summary

      assert summary["sentence"] ==
               "Backing up to S3 failed on Sunday, May 4, 2031 at 10:00 AM UTC: S3 refused " <>
                 "the snapshot."

      assert {summary["action"]["id"], summary["outcome"]} == {"back_up_now", "failed"}
      assert detail["seen_at"] == "2031-05-04T10:00:00Z"
      assert Copy.summary_violations(summary["sentence"]) == []
    end

    test "a stored backup clears it, and the next try's failure raises it in that try's words" do
      first = tried(Status.empty(), ~U[2031-05-04 10:00:00Z], "S3 refused the snapshot.")
      cleared = stored(first, ~U[2031-05-04 11:00:00Z])
      again = tried(cleared, ~U[2031-05-04 11:30:00Z], "S3 did not answer in time.")

      [failed, on, raised] =
        for status <- [first, cleared, again],
            do: HomeSummary.summary(desktop(primary_home: status_home(status)))

      assert {failed["detail"]["kind"], on["state"]} == {"backup_failed", "on"}
      assert raised["detail"]["kind"] == "backup_failed"

      assert raised["sentence"] ==
               "Backing up to S3 failed on Sunday, May 4, 2031 at 11:30 AM UTC: S3 did not " <>
                 "answer in time."

      refute raised["key"] == failed["key"]

      # A try that fails again with no backup stored between moves the key too.
      twice = tried(first, ~U[2031-05-04 10:30:00Z], "S3 did not answer in time.")

      refute HomeSummary.summary(desktop(primary_home: status_home(twice)))["key"] ==
               failed["key"]
    end

    # A try that only waited (a desktop away) stored nothing: the failure
    # stands, in its own words and at its own time, until a backup is stored.
    test "a try that only waited leaves it standing, and a stored backup then clears it" do
      first = tried(Status.empty(), ~U[2031-05-04 10:00:00Z], "S3 refused the snapshot.")
      waited = Status.record(first, "s3", waited(~U[2031-05-04 11:00:00Z]))

      summary = HomeSummary.summary(desktop(primary_home: status_home(waited)))
      assert %{"state" => "problem", "detail" => %{"kind" => "backup_failed"}} = summary

      assert summary["sentence"] ==
               "Backing up to S3 failed on Sunday, May 4, 2031 at 10:00 AM UTC: S3 refused " <>
                 "the snapshot."

      cleared = stored(waited, ~U[2031-05-04 11:30:00Z])
      assert HomeSummary.summary(desktop(primary_home: status_home(cleared)))["state"] == "on"
    end

    test "a server with desktops says it on its own screen" do
      tried = tried(Status.empty(), ~U[2031-05-04 10:00:00Z], "S3 refused the snapshot.")
      own = server(snapshots: snapshots_view(tried))

      assert %{"state" => "problem", "detail" => %{"kind" => "backup_failed"}} =
               HomeSummary.summary(own)
    end

    test "a backup over 3 days old runs while its Back up now runs, and is a problem once it ends" do
      old = server_home(backups: [{"desktop", ~U[2031-04-30 10:00:00Z]}])
      running = put_in(old, ["snapshots", "running"], true)

      assert %{"state" => "problem", "outcome" => "running"} =
               HomeSummary.summary(desktop(primary_home: running))

      assert %{"state" => "problem", "outcome" => "failed"} =
               HomeSummary.summary(desktop(primary_home: old))

      # The server's own screen offers no Back up now: its runs move nothing.
      running_here = Map.put(snapshots([{"desktop", ~U[2031-05-04 10:00:00Z]}]), "running", true)

      assert %{"state" => "primary", "outcome" => "done"} =
               HomeSummary.summary(server(snapshots: running_here))
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

    # M97 §3.4: a computer that cannot read its server's home (the server
    # runs a newer Fermix) is offered Update in place of Move back, and in
    # place of Restore here, by the one rule (`Home.Readable`).
    test "a computer that cannot read the server's home is asked to update first" do
      newer = {:error, {:newer_engine, "0.9.0", "0.8.0"}}
      summary = HomeSummary.summary(desktop(readable: newer))

      assert summary["state"] == "on"
      assert ids(summary["detail"]["actions"]) == ["back_up_now", "add_computer", "update"]
      refute "move_back" in ids(HomeSummary.offered(summary))

      assert %{"label" => "Update Fermix on this Mac first", "needs" => [], "confirm" => nil} =
               Enum.find(summary["detail"]["actions"], &(&1["id"] == "update"))

      silent = primary(:unreachable, 10 * @minute)
      copy = %{name: "20310504T100000Z-e5.fxsnap", at: ~U[2031-05-04 10:00:00Z]}

      restorable =
        HomeSummary.summary(desktop(link_primary: silent, copies: [copy], readable: newer))

      refute "restore_here" in ids(HomeSummary.offered(restorable))
      assert "update" in ids(HomeSummary.offered(restorable))

      assert "move_back" in ids(HomeSummary.offered(HomeSummary.summary(desktop(readable: :ok))))
    end

    # §3.4: past the server's window this computer keeps its link for
    # settings alone; a server that went past the apps (an owner's override)
    # and that this computer cannot read says so until it updates.
    test "a computer past the window, and one behind a server ahead of the apps, update" do
      settings_only = HomeSummary.summary(desktop(standing: :settings_only))

      assert {settings_only["state"], settings_only["detail"]["kind"],
              settings_only["action"]["id"]} == {"problem", "update", "update"}

      assert settings_only["sentence"] ==
               "Update Fermix on this Mac. Your server runs a newer Fermix, so until then this " <>
                 "Mac can change settings only."

      ahead_home = Map.put(server_home([]), "update", %{"ahead_of_apps" => true})
      newer = {:error, {:newer_engine, "0.9.0", "0.8.0"}}
      ahead = HomeSummary.summary(desktop(primary_home: ahead_home, readable: newer))

      assert {ahead["state"], ahead["detail"]["kind"], ahead["action"]["id"]} ==
               {"problem", "server_ahead", "update"}

      assert ahead["sentence"] ==
               "Your server runs a newer Fermix than this Mac can restore. Update Fermix on " <>
                 "this Mac."

      # One this computer reads, or a server inside the apps, is no problem.
      for facts <- [
            desktop(primary_home: ahead_home, readable: :ok),
            desktop(primary_home: Map.put(server_home([]), "update", nil), readable: newer),
            desktop(standing: :behind)
          ] do
        refute HomeSummary.summary(facts)["detail"]["kind"] in ["update", "server_ahead"]
      end
    end

    # The move back's own check refuses an engine run from a terminal at the
    # press, so the screen says it where Move back would be, before any press.
    test "an engine run from a terminal is not offered Move back, and Details say why" do
      summary = HomeSummary.summary(desktop(restarts_itself: false))

      assert summary["state"] == "on"
      assert ids(summary["detail"]["actions"]) == ["back_up_now", "add_computer"]
      refute "move_back" in ids(HomeSummary.offered(summary))

      assert %{"label" => "Move back", "value" => said} =
               Enum.find(summary["detail"]["lines"], &(&1["label"] == "Move back"))

      assert said ==
               "Fermix runs from a terminal here, so it could not start again on its own " <>
                 "after the move back. Install it as a service first."

      assert Copy.summary_violations(said) == []
      refute summary["key"] == HomeSummary.summary(desktop([]))["key"]

      refute Enum.any?(
               HomeSummary.summary(desktop([]))["detail"]["lines"],
               &(&1["label"] == "Move back")
             )
    end

    test "ready names the server, what runs here again and until when it waits, and Move " <>
           "now asks the server's passphrase with a confirm built here, Cancel beside it" do
      summary = HomeSummary.summary(returning(back("enrolled")))

      assert %{"id" => "move_now", "needs" => ["recovery_passphrase"]} = summary["action"]

      assert summary["action"]["confirm"] ==
               "Move Fermix back to this Mac now? iMessage, voice calls and meetings run " <>
                 "here again. Your server stays until you delete it."

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
               "Move Fermix back to this Mac now? Your server stays until you delete it."

      # The costs are named only where the home's settings have them (EC2
      # test finding 15).
      costly =
        HomeSummary.summary(
          returning(back("enrolled"), stays_here: [], return_costs: [:coding_agents, :telegram])
        )

      assert costly["action"]["confirm"] ==
               "Move Fermix back to this Mac now? Coding agents ask for your approval again. " <>
                 "Messages sent to Telegram while it moves wait until it is done. Your server " <>
                 "stays until you delete it."

      telegram = HomeSummary.summary(returning(back("enrolled"), return_costs: [:telegram]))

      assert telegram["action"]["confirm"] ==
               "Move Fermix back to this Mac now? iMessage, voice calls and meetings run " <>
                 "here again. Messages sent to Telegram while it moves wait until it is done. " <>
                 "Your server stays until you delete it."

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
                 "gone."

      # Telegram's 24 hours are named only where this computer's settings have
      # it set up (the EC2 test's F7 rule).
      telegram = %{facts | return_costs: [:telegram]}

      assert Enum.find(
               HomeSummary.offered(HomeSummary.summary(telegram)),
               &(&1["id"] == "restore_here")
             )[
               "confirm"
             ] ==
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

    # A desktop's screen runs while its server backs up, and says a try that
    # failed, so the server's key moves with both too.
    test "a server's key moves with a backup running and a try that failed" do
      base = HomeSummary.watch(server([])).key
      running = Map.put(snapshots([{"desktop", ~U[2031-05-04 10:00:00Z]}]), "running", true)
      failed = backed_up(snapshots([{"desktop", ~U[2031-05-04 10:00:00Z]}]), "desktop", "x.")

      assert HomeSummary.watch(server(snapshots: running)).key != base
      assert HomeSummary.watch(server(snapshots: failed)).key != base
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

  # M97 §3.1, §7.5: a computer that asks to join, on the server's own screen
  # and on a linked computer's; the screen of the computer that joins; and a
  # computer that joined has no Move back or Restore here.
  describe "computers joining the home" do
    test "the server and a linked computer offer Add a computer" do
      assert "add_computer" in ids(HomeSummary.offered(HomeSummary.summary(server([]))))
      assert "add_computer" in ids(HomeSummary.offered(HomeSummary.summary(desktop([]))))
    end

    test "a computer that asks to join is added with the digits it shows, or not" do
      waiting = %{
        state: :awaiting_approval,
        expires_at: ~U[2031-05-04 12:30:00Z],
        candidate_id: nil,
        purpose: :computer,
        joiner: %{name: "loft-linux", platform: "linux", sas: "482913"},
        joined: nil
      }

      on_server =
        HomeSummary.summary(
          server(link: link(desktops: server([]).link.desktops, enrollment: waiting))
        )

      assert %{"id" => "approve_computer", "needs" => ["sas"], "label" => "Add it"} =
               on_server["action"]

      assert [%{"id" => "deny_computer", "needs" => []}] = on_server["detail"]["alternatives"]

      assert on_server["sentence"] ==
               "A computer named loft-linux (Linux) asks to join your Fermix. Add it only if " <>
                 "it shows 482 913."

      home =
        Map.put(server_home([]), "enrollment", %{
          "state" => "awaiting_approval",
          "purpose" => "computer",
          "joiner" => %{"name" => "loft-linux", "platform" => "linux", "sas" => "482913"}
        })

      linked = HomeSummary.summary(desktop(primary_home: home))
      assert {linked["state"], linked["action"]["id"]} == {"on", "approve_computer"}
      assert linked["action"]["key"] == on_server["action"]["key"]

      # Other digits are another approval: the key binds the digits shown.
      other = put_in(home, ["enrollment", "joiner", "sas"], "100200")

      refute HomeSummary.summary(desktop(primary_home: other))["action"]["key"] ==
               linked["action"]["key"]
    end

    test "a computer that joined is told once on the owner's other screens" do
      joined = %{
        state: :approved,
        expires_at: ~U[2031-05-04 12:30:00Z],
        candidate_id: nil,
        purpose: :computer,
        joiner: nil,
        joined: %{device_id: "7e1f0c2a-3b4d-4e5f-8a6b-7c8d9e0f1a2b", name: "loft-linux"}
      }

      notice =
        HomeSummary.summary(
          server(link: link(desktops: server([]).link.desktops, enrollment: joined))
        )["notice"]

      assert notice == %{
               "id" => "computer_joined:7e1f0c2a-3b4d-4e5f-8a6b-7c8d9e0f1a2b",
               "sentence" => "A computer named loft-linux joined your Fermix."
             }

      home =
        Map.put(server_home([]), "enrollment", %{
          "state" => "approved",
          "purpose" => "computer",
          "joined" => %{
            "device_id" => "7e1f0c2a-3b4d-4e5f-8a6b-7c8d9e0f1a2b",
            "name" => "loft-linux"
          }
        })

      assert HomeSummary.summary(desktop(primary_home: home))["notice"] == notice
    end

    test "the computer that joins shows where it stands, with Cancel" do
      join = %{"server" => "studio-mac", "sas" => nil, "sentence" => nil}

      dialing =
        HomeSummary.summary(
          device(linked: false, moved: nil, join: Map.put(join, "phase", "dialing"))
        )

      assert {dialing["state"], dialing["outcome"], dialing["action"]["id"]} ==
               {"creating", "running", "cancel"}

      assert dialing["sentence"] == "Connecting this Mac to your Fermix on studio-mac."

      waiting =
        HomeSummary.summary(
          device(
            linked: false,
            moved: nil,
            join: %{join | "sas" => "482913"} |> Map.put("phase", "awaiting_approval")
          )
        )

      assert {waiting["state"], waiting["outcome"]} == {"creating", "waiting"}
      assert waiting["sentence"] =~ "Both show 482 913"

      said = "studio-mac did not add this computer. Open a new code there to try again."

      denied =
        HomeSummary.summary(
          device(
            linked: false,
            moved: nil,
            join: %{join | "sentence" => said} |> Map.put("phase", "denied")
          )
        )

      assert {denied["state"], denied["outcome"], denied["sentence"]} ==
               {"creating", "failed", said}
    end

    test "a computer that joined has no Move back and no Restore here" do
      silent = primary(:unreachable, 10 * @minute)
      copy = %{name: "20310504T100000Z-e5.fxsnap", at: ~U[2031-05-04 10:00:00Z]}

      for facts <- [
            desktop(moved: nil),
            desktop(moved: nil, link_primary: silent, copies: [copy])
          ] do
        offered = ids(HomeSummary.offered(HomeSummary.summary(facts)))
        refute "move_back" in offered
        refute "restore_here" in offered
      end

      assert "move_back" in ids(HomeSummary.offered(HomeSummary.summary(desktop([]))))
    end
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
        return_costs: [],
        zone: "Etc/UTC",
        return: nil,
        returning: nil,
        restoring: false,
        copies: [],
        lapsed: nil,
        moved_back: false,
        primary_behind: false,
        restarts_itself: true
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

  defp moved_to(to), do: %{moved() | to: to}

  # The server's home while a computer asks to join it (M97 §7.5).
  defp asking_home do
    Map.put(server_home([]), "enrollment", %{
      "state" => "awaiting_approval",
      "purpose" => "computer",
      "joiner" => %{"name" => "loft-linux", "platform" => "linux", "sas" => "482913"}
    })
  end

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
      "disk" => %{"used" => used, "nearly_full" => used >= 0.85},
      "webhooks" => Keyword.get(overrides, :webhooks, [])
    }
  end

  # A webhook the server serves on loopback, as its `home.status` names it.
  defp whatsapp(port), do: %{"kind" => "whatsapp", "ref" => nil, "port" => port}
  defp cue(ref, port), do: %{"kind" => "cue", "ref" => ref, "port" => port}

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

  # The server's own `home.status` whose snapshots `Snapshot.Status` gives,
  # an S3 target its only place.
  defp status_home(status), do: Map.put(server_home([]), "snapshots", snapshots_view(status))

  defp snapshots_view(status) do
    Status.view(status, %{
      config: [recipient: @recipient, s3_bucket: "invented-fermix-snapshots"],
      targets: [S3],
      running: false,
      profile: "general"
    })
  end

  # A try at `at`, as the scheduler records it: failed in `said`, or stored.
  defp tried(status, at, said), do: Status.record(status, "s3", attempt(at, :failed, said))
  defp stored(status, at), do: Status.record(status, "s3", attempt(at, :verified, nil))

  defp waited(at),
    do: Map.put(attempt(at, :waiting, nil), :note, "The place waits for the next run.")

  defp attempt(at, result, error) do
    %{
      at: at,
      result: result,
      name: "20310504T100000Z-e4.fxsnap",
      epoch: 4,
      size: 48_211,
      sha256: String.duplicate("9c", 32),
      location: if(result == :verified, do: "s3://invented-fermix-snapshots/n.fxsnap"),
      error: error
    }
  end

  # The snapshots with the place `id`'s last try failed in `said`.
  defp backed_up(snapshots, id, said),
    do: Map.update!(snapshots, "targets", &Enum.map(&1, fn t -> failed(t, id, said) end))

  defp failed(%{"id" => id} = target, id, said),
    do: Map.merge(target, %{"last_error" => said, "last_attempt_at" => "2031-05-04T11:00:00Z"})

  defp failed(target, _id, _said), do: target

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
