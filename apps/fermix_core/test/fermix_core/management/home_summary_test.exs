defmodule FermixCore.Management.HomeSummaryTest do
  # `home.status.summary` (M75 lean v1 §7): one table over every state and
  # every problem, from the facts the gatherer collects to the state, the
  # sentence and the one action every surface shows. The facts are invented
  # and written here, so each row names exactly what makes its state.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Provision.Hetzner
  alias FermixCore.Management.Copy
  alias FermixCore.Management.HomeSummary
  alias FermixTestSupport.FakeCloudProvider

  @now ~U[2031-05-04 12:00:00Z]
  @minute 60_000
  @cand "cand-5e2a9c1f7b3d4086"
  @new_cand "cand-9d41c7e2b05a3f68"

  # -- the table ----------------------------------------------------------------

  # {name, facts, state, sentence, action id or nil}
  defp cases do
    setup_cases() ++ device_cases() ++ replace_cases() ++ server_cases() ++ candidate_cases()
  end

  defp setup_cases do
    created = created_ledger()

    [
      {"a home with nothing", facts([]), "off",
       "Keep Fermix running when this Mac sleeps. It moves to a server you own.", "set_up"},
      {"a home that uses iMessage and meetings", facts(stays_here: [:imessage, :meetings]), "off",
       "Keep Fermix running when this Mac sleeps. It moves to a server you own. iMessage and " <>
         "meetings stop after the move.", "set_up"},
      {"a home that uses all three", facts(stays_here: [:imessage, :voice, :meetings]), "off",
       "Keep Fermix running when this Mac sleeps. It moves to a server you own. iMessage, " <>
         "voice calls and meetings stop after the move.", "set_up"},
      {"a home that uses only iMessage", facts(stays_here: [:imessage]), "off",
       "Keep Fermix running when this Mac sleeps. It moves to a server you own. iMessage " <>
         "stops after the move.", "set_up"},
      {"a Linux home with nothing", facts(host_os: :linux), "off",
       "Keep Fermix running when this computer sleeps. It moves to a server you own.", "set_up"},
      {"a Linux home with voice calls on", facts(host_os: :linux, stays_here: [:voice]), "off",
       "Keep Fermix running when this computer sleeps. It moves to a server you own. Voice " <>
         "calls stop after the move.", "set_up"},
      {"a code for a server of the owner's own", facts(link: link(enrollment: manual(:open))),
       "connect", "Paste a Hetzner API token to let Fermix create your server.", nil},
      {"a token Hetzner refused before anything was made",
       facts(provision: ledger(:failed, token: :refused, failure: failure("token_refused"))),
       "connect", "Paste a Hetzner API token to let Fermix create your server.", nil},
      {"a token Hetzner accepted", facts(provision: ledger(:connected)), "choose",
       "Your Hetzner token works, so choose the server Fermix creates.", "create_server"},
      {"the create under way", facts(provision: ledger(:creating)), "creating",
       "Starting your server…", "cancel"},
      {"a created server that is still starting",
       facts(
         provision: created_ledger(power: "starting"),
         link: link(enrollment: provisioned(:open))
       ), "creating", "Starting your server…", "cancel"},
      {"a running server installing Fermix",
       facts(provision: created, link: link(enrollment: provisioned(:open))), "creating",
       "Installing Fermix on your server…", "cancel"},
      {"a server that just used its code",
       facts(provision: created, link: link(enrollment: provisioned(:used))), "creating",
       "Connecting your server…", "cancel"},
      {"a server waiting for its move", ready_facts([]), "ready",
       "Your server is ready for the move. There is no way back to this Mac in this version.",
       "move_now"},
      {"a server waiting, the review warning", ready_facts(review: review([warn()])), "ready",
       "Your server is ready for the move. There is no way back to this Mac in this version.",
       "move_now"},
      {"a server waiting, the review blocking", ready_facts(review: review([warn(), block()])),
       "problem",
       "The move cannot start yet. This home is about 4 GiB; the move needs about 9 GiB free.",
       "check_again"},
      {"a server of the owner's own waiting",
       facts(candidates: [candidate()], link: link(enrollment: manual(:used, @cand))), "ready",
       "Your server is ready for the move. There is no way back to this Mac in this version.",
       "move_now"},
      {"a server of the owner's own presenting its code",
       facts(link: link(enrollment: manual(:used))), "creating", "Connecting your server…", nil},
      {"a server Hetzner turned off",
       facts(
         provision: created_ledger(power: "off"),
         link: link(enrollment: provisioned(:open))
       ), "problem", "Your server is turned off.", "turn_on"},
      {"a server silent for thirty minutes awake",
       facts(
         provision: created,
         link: link(enrollment: provisioned(:open, nil, 30 * @minute))
       ), "problem", "Your server did not finish setting up.", "start_again"},
      {"a server whose code expired unused",
       facts(provision: created, link: link(enrollment: provisioned(:expired))), "problem",
       "Your server did not finish setting up.", "start_again"},
      {"a server that waited past its day",
       facts(provision: created, link: link(enrollment: provisioned(:used, @cand))), "problem",
       "Your server waited too long and must be set up again.", "start_again"},
      {"a server deleted in Hetzner before the move",
       facts(provision: created_ledger(status: :gone, state: :gone)), "problem",
       "Your server was deleted in Hetzner.", "start_again"},
      {"no capacity, another location in stock",
       facts(provision: ledger(:failed, failure: failure("unavailable", "nbg1"))), "problem",
       "Falkenstein has no CPX22 right now.", "create_in"},
      {"no capacity anywhere", facts(provision: ledger(:failed, failure: failure("unavailable"))),
       "problem", "Falkenstein has no CPX22 right now.", "learn_more"},
      {"the account's limit",
       facts(provision: ledger(:failed, failure: failure("account_limit"))), "problem",
       "Hetzner limits new servers on this account.", "open_console"},
      {"a token that can only read",
       facts(provision: ledger(:failed, failure: failure("read_only_token"))), "problem",
       "This token can only read, so Fermix created nothing; paste a Read & Write API token " <>
         "from your Hetzner project.", "paste_token"},
      {"a create that stopped", facts(provision: ledger(:failed, failure: failure("other"))),
       "problem",
       "Hetzner had not finished starting your server after five minutes; Always On checks " <>
         "again when it opens.", "start_again"},
      {"a token that stopped working while the server stands",
       facts(provision: %{created | token: :refused}), "problem",
       "Hetzner no longer accepts Fermix's token.", "paste_token"},
      {"a Hetzner file Fermix cannot read", facts(provision: unreadable_ledger()), "problem",
       "Fermix could not read its Hetzner file, so it shows nothing it created there; " <>
         "Fermix's log says why.", "learn_more"},
      {"the server being deleted", facts(provision: created_ledger(state: :deleting)), "creating",
       "Deleting your server…", nil},
      {"a move undone, the server still held",
       ready_facts(move: move("aborted"), link: link(enrollment: provisioned(:used, @cand))),
       "undone", "The move was undone. Fermix still runs on this Mac.", "try_again"},
      {"a move undone long ago, nothing held", facts(move: move("aborted")), "off",
       "Keep Fermix running when this Mac sleeps. It moves to a server you own.", "set_up"}
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
      {"a server Hetzner runs, silent for ten minutes",
       desktop(link_primary: primary(:unreachable, 10 * @minute)), "problem",
       "Fermix cannot reach your server. Your messages wait until it is back.", "restart_server"},
      {"a server answering as an older copy for ten minutes",
       desktop(link_primary: primary(:stale, 11 * @minute)), "problem",
       "Fermix cannot reach your server. Your messages wait until it is back.", "restart_server"},
      {"a server of the owner's own, silent for ten minutes",
       desktop(link_primary: primary(:unreachable, 10 * @minute), provision: ledger(:none)),
       "problem", "Fermix cannot reach your server. Your messages wait until it is back.",
       "learn_more"},
      {"a server Hetzner turned off",
       desktop(
         link_primary: primary(:unreachable, @minute),
         provision: created_ledger(power: "off")
       ), "problem", "Your server is turned off.", "turn_on"},
      {"a server deleted in Hetzner after the move",
       desktop(
         link_primary: primary(:unreachable, @minute),
         provision: created_ledger(status: :gone, state: :gone)
       ), "problem", "Your server was deleted in Hetzner.", "learn_more"},
      {"a server this Mac is too old for", desktop(primary_too_old: true, primary_home: nil),
       "problem", "Update Fermix on this Mac to keep using Always On.", "update"},
      {"a token that stopped working after the move",
       desktop(provision: %{created_ledger() | token: :refused}), "problem",
       "Hetzner no longer accepts Fermix's token.", "paste_token"},
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

  # A replace of the server, on the computer the home left: the ledger's
  # `replace` (`Ledger.state/1`), and the old server's own part for the new
  # server's code and the candidate it enrolled as.
  defp replace_cases do
    [
      {"a replace creating the new server",
       desktop(provision: replacing(:creating, server: nil, ledger_state: :creating)), "creating",
       "Creating your new server…", "cancel"},
      {"a replace's new server still starting",
       desktop(
         provision: replacing(:waiting, server: new_server(power: "starting")),
         primary_home: server_home(enrollment: new_window("open"))
       ), "creating", "Starting your new server…", "cancel"},
      {"a replace's new server installing Fermix",
       desktop(
         provision: replacing(:waiting),
         primary_home: server_home(enrollment: new_window("open"))
       ), "creating", "Installing Fermix on your new server…", "cancel"},
      {"a replace's new server, the old one's part missing",
       desktop(provision: replacing(:waiting), primary_home: nil), "creating",
       "Installing Fermix on your new server…", "cancel"},
      {"a replace's new server that just used its code",
       desktop(
         provision: replacing(:waiting),
         primary_home: server_home(enrollment: new_window("used"))
       ), "creating", "Connecting your new server…", "cancel"},
      {"a replace's new server waiting for its move", replace_ready([]), "ready",
       "Your new server is ready for the move.", "move_now"},
      {"a replace's new server turned off",
       desktop(
         provision: replacing(:waiting, server: new_server(power: "off")),
         primary_home: server_home(enrollment: new_window("open"))
       ), "problem", "Your new server is turned off.", "turn_on"},
      {"a replace's new server silent for thirty minutes",
       desktop(
         provision: replacing(:waiting, server: new_server(created_at: ~U[2031-05-04 11:29:00Z])),
         primary_home: server_home(enrollment: new_window("open"))
       ), "problem", "Your new server did not finish setting up.", "start_again"},
      {"a replace's code expired unused",
       desktop(
         provision: replacing(:waiting),
         primary_home: server_home(enrollment: new_window("expired"))
       ), "problem", "Your new server did not finish setting up.", "start_again"},
      {"a replace's new server that waited past its day",
       desktop(
         provision: replacing(:waiting),
         primary_home: server_home(enrollment: new_window("used", @new_cand))
       ), "problem", "Your new server waited too long and must be set up again.", "start_again"},
      {"the move to the new server, the old one silent",
       desktop(
         link_primary: primary(:unreachable, 40 * @minute),
         provision: replacing(:moving),
         primary_home: nil
       ), "moving", "Moving to your new server. Messages wait until it is done.", nil},
      {"the old server being removed after the move", desktop(provision: replacing(:deleting)),
       "creating", "Removing your old server…", nil},
      {"the old server's delete stopped",
       desktop(provision: replacing(:failed, current: :new, failure: old_server_failure())),
       "problem",
       "Fermix could not delete your old server: Hetzner had not finished deleting your " <>
         "server after five minutes; Always On checks again when it opens.", "delete_server"},
      {"the new server being deleted before the move",
       desktop(provision: replacing(:cancelling, ledger_state: :deleting)), "creating",
       "Deleting your new server…", nil},
      {"the new server's create stopped",
       desktop(
         provision:
           replacing(:failed,
             server: nil,
             ledger_state: :failed,
             failure: failure("other")
           )
       ), "problem",
       "Hetzner had not finished starting your server after five minutes; Always On checks " <>
         "again when it opens.", "start_again"},
      {"no capacity for the new server",
       desktop(
         provision:
           replacing(:failed,
             server: nil,
             ledger_state: :failed,
             failure: failure("unavailable", "nbg1")
           )
       ), "problem", "Falkenstein has no CPX22 right now.", "create_in"},
      {"the new server deleted in Hetzner before the move",
       desktop(
         provision:
           replacing(:failed,
             server: new_server(status: :gone),
             ledger_state: :gone,
             failure: replacement_gone()
           )
       ), "problem", "Your new server was deleted in Hetzner, so replace the server again.",
       "start_again"},
      {"a replace that is done", desktop(provision: replacing(:done)), "on",
       "Fermix runs on your server. Last backup 2 hours ago.", nil},
      {"the old server silent for ten minutes during a replace",
       desktop(
         link_primary: primary(:unreachable, 10 * @minute),
         provision: replacing(:waiting),
         primary_home: nil
       ), "problem", "Fermix cannot reach your server. Your messages wait until it is back.",
       "learn_more"},
      {"the old server turned off during a replace",
       desktop(
         link_primary: primary(:unreachable, @minute),
         provision: replacing(:waiting, old: %{created_ledger().server | power: "off"}),
         primary_home: nil
       ), "problem", "Your server is turned off.", "learn_more"}
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

  # -- the table, read --------------------------------------------------------

  test "every row answers its state, sentence and action" do
    for {name, facts, state, sentence, action} <- cases() do
      summary = HomeSummary.summary(facts)

      assert summary["state"] == state, "#{name}: #{inspect(summary)}"
      assert summary["sentence"] == sentence, "#{name}: #{inspect(summary["sentence"])}"
      assert action_id(summary) == action, "#{name}: #{inspect(summary["action"])}"
    end
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
      assert Copy.violations(text, :prose, ["CPX22", "Read & Write"]) == [],
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

  # -- a provider that is not Hetzner -------------------------------------------

  # The summary names no provider of its own: its name, its token, its
  # cities, its type names and its steps are the provider's display data, so
  # an invented provider reads in its own words throughout.
  describe "on a provider that is not Hetzner" do
    test "the token step, the choice and the bill name the provider" do
      %{"detail" => %{"connect" => connect}} =
        HomeSummary.summary(facts(provider: FakeCloudProvider))

      assert connect["sentence"] == "Paste a Nimbus access key to let Fermix create your server."
      assert connect["steps"] == FakeCloudProvider.display().steps

      summary =
        HomeSummary.summary(facts(provider: FakeCloudProvider, provision: ledger(:connected)))

      assert summary["sentence"] ==
               "Your Nimbus token works, so choose the server Fermix creates."

      assert summary["detail"]["billing"] ==
               "Nimbus bills by the hour until the server is deleted."
    end

    test "a problem's action names the provider and its city" do
      limit = %{failure("account_limit") | sentence: "Nimbus limits new servers on this account."}

      summary =
        HomeSummary.summary(
          facts(provider: FakeCloudProvider, provision: ledger(:failed, failure: limit))
        )

      assert summary["action"] == %{"id" => "open_console", "label" => "Open Nimbus"}

      full = %{failure("unavailable", "lis1") | sentence: "Oslo has no Small 4 right now."}

      summary =
        HomeSummary.summary(
          facts(provider: FakeCloudProvider, provision: ledger(:failed, failure: full))
        )

      assert summary["action"] == %{"id" => "create_in", "label" => "Create in Lisbon"}
    end

    test "a server's facts are the provider's, and so is who can read its disk" do
      nimbus = created_ledger(type: "small-4", location: "osl1")

      %{"detail" => detail} =
        HomeSummary.summary(ready_facts(provider: FakeCloudProvider, provision: nimbus))

      assert %{"type" => "Small 4", "location" => "Oslo"} = detail["server"]

      %{"detail" => detail} =
        HomeSummary.summary(desktop(provider: FakeCloudProvider, provision: nimbus))

      assert detail["server"]["location"] == "Oslo"
      assert detail["data"] =~ "and Nimbus can technically read its disk"

      %{"sentence" => sentence} =
        HomeSummary.summary(
          facts(
            provider: FakeCloudProvider,
            provision:
              created_ledger(type: "small-4", location: "osl1", status: :gone, state: :gone)
          )
        )

      assert sentence == "Your server was deleted in Nimbus."
    end
  end

  # -- what Details holds -------------------------------------------------------

  describe "the detail" do
    test "the first screen carries the token step its Set up opens" do
      %{"detail" => %{"connect" => connect}} = HomeSummary.summary(facts([]))

      assert connect["sentence"] == "Paste a Hetzner API token to let Fermix create your server."
      assert_token_steps(connect["steps"])
      assert ids(connect["alternatives"]) == ["own_server"]
    end

    test "the token step names two-factor sign-in and a project for Fermix alone" do
      %{"detail" => detail} = HomeSummary.summary(facts(link: link(enrollment: manual(:open))))

      assert_token_steps(detail["steps"])
      assert ids(detail["alternatives"]) == ["own_server"]
    end

    test "choose says Hetzner bills by the hour until the server is deleted" do
      %{"detail" => detail} = HomeSummary.summary(facts(provision: ledger(:connected)))

      assert detail == %{"billing" => "Hetzner bills by the hour until the server is deleted."}
    end

    test "ready holds the server's facts, the readiness warnings and blocks, and until when" do
      %{"detail" => detail} =
        HomeSummary.summary(ready_facts(review: review([ok(), warn()])))

      assert detail["server"] == %{
               "name" => "fermix-general-a3f9",
               "type" => "CPX22",
               "location" => "Falkenstein",
               "ipv4" => "203.0.113.7",
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

    test "on holds the server, each backup, this Mac's copies, the disk and the two actions" do
      %{"detail" => detail} = HomeSummary.summary(desktop(copies_bytes: 3_221_225_472))

      assert detail["server"] == %{
               "name" => "fermix-general-a3f9",
               "location" => "Falkenstein",
               "version" => "0.9.0"
             }

      assert detail["backups"] == [
               %{"place" => "your desktop", "at" => "2031-05-04T10:00:00Z"},
               %{"place" => "S3", "at" => "2031-05-03T10:00:00Z"}
             ]

      assert detail["copies_bytes"] == 3_221_225_472
      assert detail["disk_used"] == 0.42
      assert ids(detail["actions"]) == ["back_up_now", "replace_server"]

      assert detail["data"] ==
               "Your conversations and memories, the secrets, the browser and traces live on " <>
                 "your server, and Hetzner can technically read its disk. Backups are " <>
                 "encrypted to your recovery passphrase."
    end

    test "on a server of the owner's own, the provider is whoever hosts it" do
      %{"detail" => detail} = HomeSummary.summary(desktop(provision: ledger(:none)))

      assert detail["server"] == %{
               "name" => "fermix-general-a3f9",
               "location" => nil,
               "version" => "0.9.0"
             }

      assert detail["data"] =~ "whoever hosts it can technically read its disk"
    end

    test "a problem says what Fermix last saw, and when" do
      %{"detail" => detail} =
        HomeSummary.summary(
          desktop(
            link_primary: primary(:unreachable, @minute),
            provision: created_ledger(power: "off")
          )
        )

      assert detail == %{
               "kind" => "turned_off",
               "note" => "A turned-off server still costs its monthly price.",
               "seen_at" => "2031-05-04T11:50:00Z",
               "alternatives" => []
             }
    end

    test "before the move, a problem with the server standing offers to delete it" do
      %{"detail" => detail} =
        HomeSummary.summary(
          facts(provision: created_ledger(), link: link(enrollment: provisioned(:expired)))
        )

      assert detail["kind"] == "not_set_up"
      assert detail["note"] == "Your server costs its monthly price until it is deleted."
      assert ids(detail["alternatives"]) == ["own_server", "open_console", "delete_server"]
    end

    test "the account's limit offers a server of the owner's own beside it" do
      %{"detail" => detail} =
        HomeSummary.summary(facts(provision: ledger(:failed, failure: failure("account_limit"))))

      assert ids(detail["alternatives"]) == ["own_server"]
      assert detail["seen_at"] == "2031-05-04T11:00:00Z"
    end

    test "Create in names the next location and carries its id" do
      summary =
        HomeSummary.summary(
          facts(provision: ledger(:failed, failure: failure("unavailable", "nbg1")))
        )

      assert summary["action"] == %{"id" => "create_in", "label" => "Create in Nuremberg"}
      assert summary["detail"]["next_location"] == "nbg1"
    end

    test "a replace's ready holds the new server's facts and until when it waits" do
      %{"detail" => detail} = HomeSummary.summary(replace_ready([]))

      assert detail == %{
               "server" => %{
                 "name" => "fermix-general-5d2e",
                 "type" => "CPX32",
                 "location" => "Helsinki",
                 "ipv4" => "203.0.113.9",
                 "system" => "linux x86_64",
                 "version" => "0.9.0"
               },
               "readiness" => [],
               "waits_until" => "2031-05-05T11:40:00Z"
             }
    end

    test "a replace's problem before the move offers to delete the new server" do
      summary =
        HomeSummary.summary(
          desktop(
            provision: replacing(:waiting),
            primary_home: server_home(enrollment: new_window("expired"))
          )
        )

      assert summary["detail"]["note"] ==
               "Your new server costs its monthly price until it is deleted."

      assert summary["detail"]["alternatives"] == [
               %{"id" => "delete_server", "label" => "Delete your new server"}
             ]
    end

    test "an old server left after a replace says it costs money, and Delete tries again" do
      summary =
        HomeSummary.summary(
          desktop(provision: replacing(:failed, current: :new, failure: old_server_failure()))
        )

      assert summary["action"] == %{"id" => "delete_server", "label" => "Delete your old server"}

      assert summary["detail"] == %{
               "kind" => "delete_failed",
               "note" => "Your old server costs its monthly price until it is deleted.",
               "seen_at" => "2031-05-04T11:00:00Z",
               "alternatives" => []
             }
    end

    test "every state with nothing more to say holds an empty detail" do
      for facts <- [
            device(move: move("streaming")),
            server([]),
            candidate_role("enrolled"),
            desktop(provision: replacing(:moving))
          ] do
        assert HomeSummary.summary(facts)["detail"] == %{}
      end
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
        provider: Hetzner,
        provision: ledger(:none),
        review: nil,
        snapshots: snapshots([]),
        disk: nil,
        primary_home: nil,
        primary_too_old: false,
        copies_bytes: nil,
        stays_here: []
      },
      Map.new(overrides)
    )
  end

  defp ready_facts(overrides) do
    facts(
      [
        provision: created_ledger(),
        candidates: [candidate()],
        link: link(enrollment: provisioned(:used, @cand))
      ] ++ overrides
    )
  end

  defp device(overrides),
    do: facts([role: :device, linked: true, moved: moved()] ++ overrides)

  defp desktop(overrides) do
    {primary, overrides} = Keyword.pop(overrides, :link_primary, primary(:connected))

    device(
      [link: link(primary: primary), provision: created_ledger(), primary_home: server_home([])] ++
        overrides
    )
  end

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

  defp provisioned(state, candidate_id \\ nil, awake_ms \\ @minute),
    do: window(:provisioned, state, candidate_id, awake_ms)

  defp manual(state, candidate_id \\ nil), do: window(:manual, state, candidate_id, @minute)

  defp window(kind, state, candidate_id, awake_ms) do
    %{
      state: state,
      expires_at: ~U[2031-05-05 10:00:00Z],
      kind: kind,
      candidate_id: candidate_id,
      awake_ms: awake_ms
    }
  end

  defp ledger(state, overrides \\ []) do
    token = if state == :none, do: :none, else: :accepted

    Map.merge(
      %{state: state, token: token, server: nil, failure: nil, sentence: nil},
      Map.new(overrides)
    )
  end

  defp created_ledger(overrides \\ []) do
    {state, overrides} = Keyword.pop(overrides, :state, :created)

    server =
      Map.merge(
        %{
          name: "fermix-general-a3f9",
          id: 61_839_204,
          status: :created,
          type: "cpx22",
          location: "fsn1",
          ipv4: "203.0.113.7",
          power: "running",
          created_at: ~U[2031-05-04 10:00:00Z],
          seen_at: ~U[2031-05-04 11:50:00Z]
        },
        Map.new(overrides)
      )

    ledger(state, server: server)
  end

  # A replace of the server as `Ledger.state/1` answers it: the ledger's own
  # places hold the new server, `replace.old` the one the home lives on.
  defp replacing(state, overrides \\ []) do
    current = if state in [:deleting, :done], do: :new, else: :old
    old = if state == :done, do: nil, else: created_ledger().server

    %{
      state: Keyword.get(overrides, :ledger_state, :created),
      token: :accepted,
      server: Keyword.get(overrides, :server, new_server()),
      failure: nil,
      sentence: nil,
      replace: %{
        state: state,
        current: Keyword.get(overrides, :current, current),
        old: Keyword.get(overrides, :old, old),
        failure: Keyword.get(overrides, :failure)
      }
    }
  end

  defp new_server(overrides \\ []) do
    Map.merge(
      %{
        created_ledger().server
        | name: "fermix-general-5d2e",
          id: 61_900_117,
          type: "cpx32",
          location: "hel1",
          ipv4: "203.0.113.9",
          created_at: ~U[2031-05-04 11:40:00Z]
      },
      Map.new(overrides)
    )
  end

  # The new server waiting for its move: the old server's code used by the
  # candidate it holds.
  defp replace_ready(overrides) do
    desktop(
      [
        provision: replacing(:waiting),
        primary_home:
          server_home(
            enrollment: new_window("used", @new_cand),
            candidates: [new_candidate()]
          )
      ] ++ overrides
    )
  end

  # The old server's window for the new one, as its `home.status` draws it.
  defp new_window(state, candidate_id \\ nil) do
    %{
      "state" => state,
      "expires_at" => "2031-05-05T11:40:00Z",
      "kind" => "provisioned",
      "candidate_id" => candidate_id
    }
  end

  defp new_candidate do
    %{
      candidate()
      | "candidate_id" => @new_cand,
        "name" => "fermix-general-5d2e",
        "enrolled_at" => "2031-05-04T11:45:00Z",
        "expires_at" => "2031-05-05T11:40:00Z"
    }
  end

  defp old_server_failure do
    %{
      reason: "other",
      sentence:
        "Fermix could not delete your old server: Hetzner had not finished deleting your " <>
          "server after five minutes; Always On checks again when it opens.",
      next_location: nil,
      at: ~U[2031-05-04 11:00:00Z]
    }
  end

  defp replacement_gone do
    %{
      reason: "gone",
      sentence: "Your new server was deleted in Hetzner, so replace the server again.",
      next_location: nil,
      at: ~U[2031-05-04 11:50:00Z]
    }
  end

  defp unreadable_ledger do
    %{
      state: :unreadable,
      token: :none,
      server: nil,
      failure: nil,
      sentence:
        "Fermix could not read its Hetzner file, so it shows nothing it created there; " <>
          "Fermix's log says why."
    }
  end

  defp failure(reason, next \\ nil) do
    sentences = %{
      "token_refused" => "Hetzner no longer accepts Fermix's token.",
      "unavailable" => "Falkenstein has no CPX22 right now.",
      "account_limit" => "Hetzner limits new servers on this account.",
      "read_only_token" =>
        "This token can only read, so Fermix created nothing; paste a Read & Write API " <>
          "token from your Hetzner project.",
      "other" =>
        "Hetzner had not finished starting your server after five minutes; Always On " <>
          "checks again when it opens."
    }

    %{
      reason: reason,
      sentence: Map.fetch!(sentences, reason),
      next_location: next,
      at: ~U[2031-05-04 11:00:00Z]
    }
  end

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
      "disk" => %{"used" => used, "nearly_full" => used >= 0.85},
      "enrollment" => Keyword.get(overrides, :enrollment),
      "candidates" => Keyword.get(overrides, :candidates, [])
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

  # -- reading a summary --------------------------------------------------------

  defp action_id(%{"action" => nil}), do: nil
  defp action_id(%{"action" => %{"id" => id}}), do: id

  defp kind(%{"detail" => %{"kind" => kind}}), do: kind

  defp ids(actions), do: Enum.map(actions, & &1["id"])

  # The main action and every one Details offers.
  defp all_actions(%{"action" => action, "detail" => detail}) do
    connect = get_in(detail, ["connect", "alternatives"]) || []

    ids(List.wrap(action)) ++
      ids(Map.get(detail, "alternatives", [])) ++
      ids(Map.get(detail, "actions", [])) ++ ids(connect)
  end

  defp printed(%{"sentence" => sentence, "action" => action, "detail" => detail}) do
    labels = for %{"label" => label} <- List.wrap(action), do: label

    lines = for key <- ~w(note billing data), is_binary(detail[key]), do: detail[key]

    actions =
      for list <- [detail["alternatives"], detail["actions"]],
          action <- list || [],
          do: action["label"]

    connect =
      case detail["connect"] do
        %{"sentence" => s, "steps" => steps, "alternatives" => alts} ->
          [s | steps] ++ Enum.map(alts, & &1["label"])

        nil ->
          []
      end

    [sentence | labels] ++ lines ++ actions ++ connect ++ (detail["steps"] || [])
  end

  defp assert_token_steps(steps) do
    assert [_, _, _, _] = steps
    assert Enum.any?(steps, &(&1 =~ "two-factor sign-in"))
    assert Enum.any?(steps, &(&1 =~ "project for Fermix alone"))
    assert Enum.any?(steps, &(&1 =~ "Read & Write"))
  end
end
