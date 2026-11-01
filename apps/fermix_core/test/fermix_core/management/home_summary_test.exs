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
  @step_at ~U[2031-05-04 11:59:00Z]
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
       "Keep Fermix running when this Mac sleeps. It moves to a server you own.", "paste_token"},
      {"a home that uses iMessage and meetings", facts(stays_here: [:imessage, :meetings]), "off",
       "Keep Fermix running when this Mac sleeps. It moves to a server you own. iMessage and " <>
         "meetings stop after the move.", "paste_token"},
      {"a home that uses all three", facts(stays_here: [:imessage, :voice, :meetings]), "off",
       "Keep Fermix running when this Mac sleeps. It moves to a server you own. iMessage, " <>
         "voice calls and meetings stop after the move.", "paste_token"},
      {"a home that uses only iMessage", facts(stays_here: [:imessage]), "off",
       "Keep Fermix running when this Mac sleeps. It moves to a server you own. iMessage " <>
         "stops after the move.", "paste_token"},
      {"a Linux home with nothing", facts(host_os: :linux), "off",
       "Keep Fermix running when this computer sleeps. It moves to a server you own.",
       "paste_token"},
      {"a Linux home with voice calls on", facts(host_os: :linux, stays_here: [:voice]), "off",
       "Keep Fermix running when this computer sleeps. It moves to a server you own. Voice " <>
         "calls stop after the move.", "paste_token"},
      {"a code for a server of the owner's own", facts(link: link(enrollment: manual(:open))),
       "connect", "Paste a Hetzner API token to let Fermix create your server.", "paste_token"},
      {"a token Hetzner refused before anything was made",
       facts(provision: ledger(:failed, token: :refused, failure: failure("token_refused"))),
       "connect", "Paste a Hetzner API token to let Fermix create your server.", "paste_token"},
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
       "problem", "Falkenstein has no CPX22 right now.", "start_again"},
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
      {"a create's step, before its job wrote anything",
       facts(provision: ledger(:connected) |> stepping("create")), "creating",
       "Starting your server…", "cancel"},
      {"Start again's step, deleting what stood first",
       facts(provision: created_ledger(state: :deleting) |> stepping("create")), "creating",
       "Deleting your server…", nil},
      {"a delete's step", facts(provision: created_ledger() |> stepping("delete")), "creating",
       "Deleting your server…", nil},
      {"turning the server on",
       facts(provision: created_ledger(power: "off") |> stepping("power_on")), "creating",
       "Turning your server on…", nil},
      {"a power action that stopped",
       facts(provision: created_ledger(state: :failed) |> failed(step_failure("power_on"))),
       "problem",
       "Fermix could not reach Hetzner, so check this computer's connection and try again.",
       "turn_on"},
      {"a delete that stopped",
       facts(provision: created_ledger(state: :failed) |> failed(step_failure("delete"))),
       "problem",
       "Fermix could not reach Hetzner, so check this computer's connection and try again.",
       "delete_server"},
      {"a create a restart cut short",
       facts(provision: ledger(:failed, failure: step_failure("create", "interrupted"))),
       "problem", "Fermix stopped before your server was created, so start again.",
       "start_again"},
      {"nothing in stock for the recommendation",
       facts(provision: ledger(:failed, failure: failure("nothing_in_stock"))), "problem",
       "Hetzner has no server type with 4 GB in stock in Falkenstein, Nuremberg or Helsinki " <>
         "right now.", "start_again"},
      {"a move undone, the server still held",
       ready_facts(move: move("aborted"), link: link(enrollment: provisioned(:used, @cand))),
       "undone", "The move was undone. Fermix still runs on this Mac.", "try_again"},
      {"a move undone long ago, nothing held", facts(move: move("aborted")), "off",
       "Keep Fermix running when this Mac sleeps. It moves to a server you own.", "paste_token"}
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
      {"restarting the server",
       desktop(
         link_primary: primary(:unreachable, 11 * @minute),
         provision: created_ledger() |> stepping("power_reset")
       ), "creating", "Restarting your server…", nil},
      {"a restart that stopped",
       desktop(
         link_primary: primary(:unreachable, 11 * @minute),
         provision: created_ledger(state: :failed) |> failed(step_failure("power_reset"))
       ), "problem",
       "Fermix could not reach Hetzner, so check this computer's connection and try again.",
       "restart_server"},
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
      {"a replace's create step, before its job wrote anything",
       desktop(
         provision:
           replacing(:creating, server: nil, ledger_state: :connected) |> stepping("create")
       ), "creating", "Creating your new server…", "cancel"},
      {"turning a replace's new server on",
       desktop(
         provision: replacing(:waiting, server: new_server(power: "off")) |> stepping("power_on"),
         primary_home: server_home(enrollment: new_window("open"))
       ), "creating", "Turning your new server on…", nil},
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
      %{"detail" => %{"providers" => [screen]}} =
        HomeSummary.summary(facts(provider: FakeCloudProvider, providers: [FakeCloudProvider]))

      assert screen["sentence"] == "Paste a Nimbus access key to let Fermix create your server."
      assert screen["steps"] == FakeCloudProvider.display().steps

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

      assert %{
               "id" => "open_console",
               "label" => "Open Nimbus",
               "url" => "https://console.nimbus.invalid/"
             } = summary["action"]

      full = %{failure("unavailable", "lis1") | sentence: "Oslo has no Small 4 right now."}

      summary =
        HomeSummary.summary(
          facts(provider: FakeCloudProvider, provision: ledger(:failed, failure: full))
        )

      assert %{"id" => "create_in", "label" => "Create in Lisbon"} = summary["action"]
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
    test "the first screen is Set up: the token every provider's screen asks for" do
      summary = HomeSummary.summary(facts([]))

      assert %{"id" => "paste_token", "label" => "Set up", "needs" => ["token"]} =
               summary["action"]

      assert [screen] = summary["detail"]["providers"]

      assert %{
               "id" => "hetzner",
               "name" => "Hetzner",
               "token_label" => "Hetzner API token",
               "sentence" => "Paste a Hetzner API token to let Fermix create your server.",
               "console_url" => "https://console.hetzner.cloud/",
               "docs_url" => "https://fermix.ai/docs/always-on/#hetzner"
             } = screen

      assert_token_steps(screen["steps"])
      assert ids(summary["detail"]["alternatives"]) == ["own_server"]
      refute Map.has_key?(summary["detail"], "connect")
    end

    test "the token step names two-factor sign-in and a project for Fermix alone" do
      summary = HomeSummary.summary(facts(link: link(enrollment: manual(:open))))

      assert %{"id" => "paste_token", "label" => "Set up"} = summary["action"]
      assert_token_steps(hd(summary["detail"]["providers"])["steps"])
    end

    # Always On setup §4: Cancel closes an open code for a server of the
    # owner's own, which deletes nothing and so asks nothing.
    test "an open code for a server of the owner's own is closed by Cancel" do
      %{"detail" => detail} = HomeSummary.summary(facts(link: link(enrollment: manual(:open))))

      assert [%{"id" => "own_server"}, %{"id" => "cancel", "label" => "Cancel the code"} = cancel] =
               detail["alternatives"]

      assert cancel["confirm"] == nil

      # A token refused before anything was made asks for a new one, and no
      # code is open to close.
      summary =
        HomeSummary.summary(
          facts(provision: ledger(:failed, token: :refused, failure: failure("token_refused")))
        )

      assert %{"id" => "paste_token", "label" => "Paste a new token"} = summary["action"]
      assert ids(summary["detail"]["alternatives"]) == ["own_server"]
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

      assert Map.delete(detail, "lines") == %{
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

    # Review R3: a refusal the owner or the provider can lift is offered again.
    test "the account's limit offers to start again once lifted, and a server of the " <>
           "owner's own" do
      %{"detail" => detail} =
        HomeSummary.summary(facts(provision: ledger(:failed, failure: failure("account_limit"))))

      assert ids(detail["alternatives"]) == ["start_again", "own_server"]
      assert detail["seen_at"] == "2031-05-04T11:00:00Z"
    end

    test "no stock anywhere offers to start again, and Learn more beside it" do
      for reason <- ["unavailable", "nothing_in_stock"] do
        summary = HomeSummary.summary(facts(provision: ledger(:failed, failure: failure(reason))))

        assert %{"id" => "start_again", "confirm" => confirm} = summary["action"]
        assert confirm =~ "create your server again"
        assert ids(summary["detail"]["alternatives"]) == ["learn_more"]
      end
    end

    # Review R2: what Fermix created for a move that has not begun can be
    # deleted from every screen it waits on, and nothing else can.
    test "a server Fermix created, ready or blocked, offers to delete it" do
      for facts <- [ready_facts([]), ready_facts(review: review([warn(), block()]))] do
        summary = HomeSummary.summary(facts)

        assert [%{"id" => "delete_server", "label" => "Delete your server"} = delete] =
                 summary["detail"]["alternatives"]

        assert delete["confirm"] == "Delete your server? Everything on it is deleted."

        assert delete["key"] ==
                 HomeSummary.action_key(
                   "delete_server",
                   "Delete your server",
                   delete["confirm"],
                   [],
                   "61839204"
                 )
      end

      blocked = HomeSummary.summary(ready_facts(review: review([block()])))

      assert blocked["detail"]["note"] ==
               "Your server costs its monthly price until it is deleted."
    end

    test "no delete is offered for a server of the owner's own, nor while a move runs" do
      own = facts(candidates: [candidate()], link: link(enrollment: manual(:used, @cand)))
      assert HomeSummary.summary(own)["detail"]["alternatives"] in [nil, []]

      for phase <- ["requested", "streaming", "committing", "undoing"] do
        summary = HomeSummary.summary(ready_facts(move: move(phase)))
        refute "delete_server" in ids(summary["detail"]["alternatives"] || []), phase
      end
    end

    test "Create in names the next location and carries its id" do
      summary =
        HomeSummary.summary(
          facts(provision: ledger(:failed, failure: failure("unavailable", "nbg1")))
        )

      assert %{"id" => "create_in", "label" => "Create in Nuremberg"} = summary["action"]
      assert summary["detail"]["next_location"] == "nbg1"
    end

    test "a replace's ready holds the new server's facts and until when it waits" do
      %{"detail" => detail} = HomeSummary.summary(replace_ready([]))

      # Review R2: the new server, and only it, can be deleted before the move.
      assert [%{"id" => "delete_server", "label" => "Delete your new server"} = delete] =
               detail["alternatives"]

      assert delete["confirm"] == "Delete your new server? Everything on it is deleted."
      new_id = replace_ready([]).provision.server.id
      assert delete["key"] =~ ~r/\A[A-Za-z0-9_-]+\z/

      assert delete["key"] ==
               HomeSummary.action_key(
                 "delete_server",
                 "Delete your new server",
                 delete["confirm"],
                 [],
                 new_id
               )

      assert Map.drop(detail, ["lines", "alternatives"]) == %{
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

    # Review R4: the replace stopped before anything was made for it, so the
    # server the home lives on is untouched and only Replace is offered.
    test "a replace that stopped before its new server is a problem, offering Replace alone" do
      summary =
        HomeSummary.summary(desktop(provision: failed(created_ledger(), step_failure("create"))))

      assert %{"state" => "problem", "action" => %{"id" => "replace_server"} = replace} = summary
      assert replace["needs"] == ["choice"]
      assert summary["detail"]["kind"] == "create_failed"
      assert summary["detail"]["alternatives"] == []

      assert summary["detail"]["note"] ==
               "Your server still runs Fermix, so replacing it can be tried again."

      assert summary["sentence"] ==
               "Fermix could not reach Hetzner, so check this computer's connection and try again."
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

      assert [%{"id" => "delete_server", "label" => "Delete your new server"}] =
               summary["detail"]["alternatives"]
    end

    test "an old server left after a replace says it costs money, and Delete tries again" do
      summary =
        HomeSummary.summary(
          desktop(provision: replacing(:failed, current: :new, failure: old_server_failure()))
        )

      assert %{"id" => "delete_server", "label" => "Delete your old server"} = summary["action"]

      assert Map.delete(summary["detail"], "lines") == %{
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

  # -- the summary is the screen (Always On setup §3.1) -------------------------

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

    test "what spends, deletes, restarts a server or moves asks first; nothing else does" do
      asks =
        for {_name, facts, _state, _sentence, _action} <- cases(),
            action <- every_action(HomeSummary.summary(facts)),
            into: %{},
            do: {action["id"], action["confirm"] != nil}

      for id <- ~w(create_server create_in start_again replace_server restart_server
                   delete_server move_now try_again),
          do: assert(asks[id], id)

      for id <- ~w(learn_more turn_on open_console paste_token update back_up_now check_again
                   own_server),
          do: refute(asks[id], id)
    end

    test "what each one needs the surface to collect" do
      needs = fn facts -> HomeSummary.summary(facts)["action"]["needs"] end

      assert needs.(facts([])) == ["token"]
      assert needs.(facts(provision: ledger(:connected))) == ["choice"]

      # The recovery passphrase is typed twice where none is set yet, and once,
      # to be checked, where one is; a replace's move checks the server's own,
      # which every move to it set.
      assert needs.(ready_facts([])) == ["new_recovery_passphrase"]

      assert needs.(ready_facts(snapshots: Map.put(snapshots([]), "recipient_set", true))) ==
               ["recovery_passphrase"]

      assert needs.(replace_ready([])) == ["recovery_passphrase"]

      assert needs.(facts(provision: ledger(:failed, failure: failure("unavailable", "nbg1")))) ==
               []

      %{"detail" => %{"actions" => [back_up, replace]}} = HomeSummary.summary(desktop([]))
      assert {back_up["needs"], replace["needs"]} == {[], ["choice"]}
    end

    test "Learn more opens the docs at the provider's part, Open its console" do
      %{"detail" => %{"alternatives" => [learn]}} =
        HomeSummary.summary(facts(provision: ledger(:failed, failure: failure("unavailable"))))

      assert learn["url"] == "https://fermix.ai/docs/always-on/#hetzner"

      %{"action" => console} =
        HomeSummary.summary(facts(provision: ledger(:failed, failure: failure("account_limit"))))

      assert console["url"] == "https://console.hetzner.cloud/"
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

      %{"action" => turn_on} =
        HomeSummary.summary(
          facts(
            provision: created_ledger(power: "off"),
            link: link(enrollment: provisioned(:open))
          )
        )

      assert turn_on["key"] ==
               HomeSummary.action_key("turn_on", "Turn it on", nil, [], "61839204")

      %{"action" => paste} = HomeSummary.summary(facts([]))

      assert paste["key"] ==
               HomeSummary.action_key("paste_token", "Set up", nil, ["token"], "hetzner")

      %{"action" => create_in} =
        HomeSummary.summary(
          facts(provision: ledger(:failed, failure: failure("unavailable", "nbg1")))
        )

      assert create_in["key"] ==
               HomeSummary.action_key(
                 "create_in",
                 "Create in Nuremberg",
                 create_in["confirm"],
                 [],
                 "nbg1"
               )

      # Another server to move to is another key.
      other = %{candidate() | "candidate_id" => "cand-0a1b2c3d4e5f6071"}

      moved_key =
        HomeSummary.summary(
          ready_facts(
            candidates: [other],
            link: link(enrollment: provisioned(:used, "cand-0a1b2c3d4e5f6071"))
          )
        )["action"]["key"]

      refute moved_key == move["key"]
    end

    test "find_action/3 finds an action by its id and key wherever it sits, and nothing else" do
      summary = HomeSummary.summary(desktop([]))
      [_back_up, replace] = summary["detail"]["actions"]

      assert {:ok, ^replace} = HomeSummary.find_action(summary, "replace_server", replace["key"])
      assert :error = HomeSummary.find_action(summary, "replace_server", "another-key")
      assert :error = HomeSummary.find_action(summary, "move_now", replace["key"])
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

    test "during a replace it says what every such move does" do
      %{"action" => move} = HomeSummary.summary(replace_ready([]))

      assert move["confirm"] ==
               "Move Fermix to your new server now? Your old server serves nothing while the " <>
                 "move runs, and Fermix deletes it once the move is done."
    end
  end

  describe "a step whose job runs" do
    test "the step in hand follows what the job wrote" do
      progress = fn ledger ->
        HomeSummary.summary(facts(provision: ledger))["detail"]["progress"]
      end

      assert progress.(ledger(:connected) |> stepping("create")) ==
               "Checking that Hetzner has the server in stock."

      assert progress.(ledger(:creating) |> stepping("create")) ==
               "Creating the server's firewall."

      assert progress.(created_ledger(status: :requested, state: :creating) |> stepping("create")) ==
               "Creating the server."

      assert progress.(created_ledger(status: :creating, state: :creating) |> stepping("create")) ==
               "Waiting for the server to start."

      assert progress.(created_ledger(state: :deleting) |> stepping("delete")) ==
               "Deleting the server and what came with it."

      assert progress.(created_ledger(power: "off") |> stepping("power_on")) ==
               "Waiting for Hetzner to finish."

      assert progress.(created_ledger()) == nil
    end

    test "the step's progress moves the key, a minute of the clock does not" do
      first = HomeSummary.summary(facts(provision: ledger(:connected) |> stepping("create")))
      written = HomeSummary.summary(facts(provision: ledger(:creating) |> stepping("create")))

      assert first["state"] == written["state"] and first["sentence"] == written["sentence"]
      refute first["key"] == written["key"]

      assert HomeSummary.watch(
               later(facts(provision: ledger(:creating) |> stepping("create")), @minute)
             ).key ==
               HomeSummary.watch(facts(provision: ledger(:creating) |> stepping("create"))).key
    end

    test "the job's budget is a deadline: the summary reads it again then" do
      %{next_change_ms: next} =
        HomeSummary.watch(facts(provision: ledger(:connected) |> stepping("create")))

      assert next == 15 * @minute - @minute
    end
  end

  describe "Details' lines" do
    test "ready: the server, its size, place, address, system, version, until when, and cost" do
      priced =
        created_ledger(total_monthly: "8.33", currency: "EUR")
        |> Map.put(:checked_at, ~U[2031-05-04 11:58:00Z])

      %{"detail" => %{"lines" => lines}} =
        HomeSummary.summary(ready_facts(provision: priced, zone: "Europe/Berlin"))

      assert lines == [
               %{"label" => "Server", "value" => "fermix-general-a3f9"},
               %{"label" => "Size", "value" => "CPX22"},
               %{"label" => "Place", "value" => "Falkenstein"},
               %{"label" => "Address", "value" => "203.0.113.7"},
               %{"label" => "System", "value" => "linux x86_64"},
               %{"label" => "Version", "value" => "0.9.0"},
               %{"label" => "Waits until", "value" => "Monday, May 5, 2031 at 1:00 PM CEST"},
               %{"label" => "Last checked", "value" => "Sunday, May 4, 2031 at 1:58 PM CEST"},
               %{
                 "label" => "Costs",
                 "value" => "€8.33 a month, billed by the hour until deleted"
               }
             ]
    end

    test "on: the server, each backup, this Mac's copies and the server's disk" do
      %{"detail" => %{"lines" => lines}} =
        HomeSummary.summary(desktop(copies_bytes: 3_221_225_472))

      assert lines == [
               %{"label" => "Server", "value" => "fermix-general-a3f9"},
               %{"label" => "Place", "value" => "Falkenstein"},
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

    test "a check of the provider that found nothing new tells nobody" do
      checked = fn at ->
        facts(provision: created_ledger() |> Map.put(:checked_at, at)) |> later_seen(at)
      end

      a = HomeSummary.summary(checked.(~U[2031-05-04 11:00:00Z]))
      b = HomeSummary.summary(checked.(~U[2031-05-04 11:59:00Z]))

      refute a["detail"]["lines"] == b["detail"]["lines"]
      assert a["key"] == b["key"]
    end

    test "states that name no server have none" do
      for facts <- [
            facts([]),
            facts(provision: ledger(:connected)),
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

      assert %{"id" => "ready:" <> @new_cand} = HomeSummary.summary(replace_ready([]))["notice"]
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

    test "a server that must be set up again, by when it was created" do
      summary =
        HomeSummary.summary(
          facts(provision: created_ledger(), link: link(enrollment: provisioned(:expired)))
        )

      assert %{"id" => "not_set_up:2031-05-04T10:00:00Z"} = summary["notice"]
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

  describe "the server a move goes to" do
    test "the one the created server's code enrolled, else the newest held" do
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

    test "during a replace, the one the old server's code for the new one enrolled" do
      assert HomeSummary.target(replace_ready([]))["candidate_id"] == @new_cand
      assert HomeSummary.target(desktop([])) == nil
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
              facts(provision: ledger(:creating)),
              facts(provision: created_ledger(), link: link(enrollment: provisioned(:open))),
              facts(provision: created_ledger(), link: link(enrollment: provisioned(:used))),
              facts(provision: ledger(:failed, failure: failure("unavailable", "nbg1"))),
              facts(provision: ledger(:failed, failure: failure("unavailable"))),
              ready_facts([]),
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
    test "a server's key moves with the backups, the code and the servers its desktops draw" do
      base = HomeSummary.watch(server([])).key

      assert HomeSummary.watch(
               server(snapshots: snapshots([{"desktop", ~U[2031-05-04 11:30:00Z]}]))
             ).key != base

      assert HomeSummary.watch(server(link: server_link(enrollment: provisioned(:open)))).key !=
               base

      assert HomeSummary.watch(server(candidates: [candidate()])).key != base

      # The awake count of an open code is no change.
      assert HomeSummary.watch(
               server(link: server_link(enrollment: provisioned(:open, nil, 2 * @minute)))
             ).key ==
               HomeSummary.watch(server(link: server_link(enrollment: provisioned(:open)))).key
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
    created = created_ledger()

    [
      {"a created server, its code open a minute awake",
       facts(provision: created, link: link(enrollment: provisioned(:open))), 29 * @minute,
       "problem", "not_set_up"},
      {"a server held until its day is out", ready_facts([]), 23 * @hour, "problem",
       "waited_too_long"},
      {"a server silent for five minutes",
       desktop(link_primary: primary(:unreachable, 5 * @minute)), 5 * @minute, "problem",
       "cannot_reach"},
      {"a backup two hours old", desktop([]), 3 * @day - 2 * @hour + 1_000, "problem",
       "backup_old"},
      {"no backup since a move a day ago",
       desktop(primary_home: server_home(backups: []), moved: moved(~U[2031-05-03 12:00:00Z])),
       2 * @day + 1_000, "problem", "backup_old"},
      {"the server's backup two hours old", server([]), 3 * @day - 2 * @hour + 1_000, "problem",
       "backup_old"},
      {"a replace's new server, made twenty minutes ago",
       desktop(
         provision: replacing(:waiting, server: new_server(created_at: ~U[2031-05-04 11:40:00Z])),
         primary_home: server_home(enrollment: new_window("open"))
       ), 10 * @minute, "problem", "not_set_up"},
      {"a replace's new server held until its day is out", replace_ready([]),
       23 * @hour + 40 * @minute, "problem", "waited_too_long"}
    ]
  end

  # The same facts `ms` later: the clock, the awake counts of a code and of a
  # link that is down, and the servers held only while they have not expired
  # (`Home.Candidates` drops one at its expiry).
  defp later(facts, ms) do
    now = DateTime.add(facts.now, ms, :millisecond)
    link = facts.link

    link = %{
      link
      | enrollment: advance(link.enrollment, :awake_ms, ms),
        primary: advance(link.primary, :down_ms, ms)
    }

    %{
      facts
      | now: now,
        link: link,
        candidates: live(facts.candidates, now),
        primary_home: live_home(facts.primary_home, now)
    }
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

  defp live_home(nil, _now), do: nil

  defp live_home(home, now),
    do: Map.update(home, "candidates", [], &live(&1, now))

  defp server_link(overrides) do
    desktop_row = %{device_id: "6d2b3c1e", name: "Studio Mac", connected: true}
    link([desktops: [desktop_row]] ++ overrides)
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
        providers: [Hetzner],
        provision: ledger(:none),
        review: nil,
        move_items: [],
        snapshots: snapshots([]),
        disk: nil,
        primary_home: nil,
        primary_too_old: false,
        copies_bytes: nil,
        stays_here: [],
        zone: "Etc/UTC"
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
      %{
        state: state,
        token: token,
        server: nil,
        failure: nil,
        sentence: nil,
        replace: nil,
        action: nil,
        checked_at: nil
      },
      Map.new(overrides)
    )
  end

  # The ledger with a step's job running, started a minute ago.
  defp stepping(ledger, kind),
    do: %{ledger | action: %{kind: kind, started_at: @step_at, type: nil, location: nil}}

  defp failed(ledger, failure), do: %{ledger | failure: failure}

  # A step's failure as `Management.Provision` keeps it.
  defp step_failure(action, reason \\ "unreachable") do
    sentences = %{
      "unreachable" =>
        "Fermix could not reach Hetzner, so check this computer's connection and try again.",
      "interrupted" => "Fermix stopped before your server was created, so start again."
    }

    %{
      reason: reason,
      sentence: Map.fetch!(sentences, reason),
      next_location: nil,
      at: ~U[2031-05-04 11:00:00Z],
      action: action,
      type: "cpx22",
      location: "fsn1"
    }
  end

  defp created_ledger(overrides \\ []) do
    {state, overrides} = Keyword.pop(overrides, :state, :created)

    server =
      Map.merge(
        %{
          name: "fermix-general-a3f9",
          id: "61839204",
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
      action: nil,
      checked_at: nil,
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
          id: "61900117",
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
      replace: nil,
      action: nil,
      checked_at: nil,
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
          "checks again when it opens.",
      "nothing_in_stock" =>
        "Hetzner has no server type with 4 GB in stock in Falkenstein, Nuremberg or Helsinki " <>
          "right now."
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

  # The same facts, the provider having last seen the server at `at`.
  defp later_seen(facts, at),
    do: put_in(facts, [:provision, :server, :seen_at], at)

  # -- reading a summary --------------------------------------------------------

  defp action_id(%{"action" => nil}), do: nil
  defp action_id(%{"action" => %{"id" => id}}), do: id

  defp kind(%{"detail" => %{"kind" => kind}}), do: kind

  defp ids(actions), do: Enum.map(actions, & &1["id"])

  defp every_action(%{"action" => action, "detail" => detail}),
    do: List.wrap(action) ++ Map.get(detail, "alternatives", []) ++ Map.get(detail, "actions", [])

  # The main action and every one Details offers.
  defp all_actions(%{"action" => action, "detail" => detail}) do
    ids(List.wrap(action)) ++
      ids(Map.get(detail, "alternatives", [])) ++ ids(Map.get(detail, "actions", []))
  end

  # Every word a surface prints as prose: the sentence, each action's label
  # and confirm, the notes, the token screens, the step in hand, the labels
  # of Details' lines and the notice.
  defp printed(%{"sentence" => sentence, "action" => action, "detail" => detail} = summary) do
    actions =
      List.wrap(action) ++ (detail["alternatives"] || []) ++ (detail["actions"] || [])

    words = Enum.flat_map(actions, &[&1["label"] | List.wrap(&1["confirm"])])
    notes = for key <- ~w(note billing data progress), is_binary(detail[key]), do: detail[key]
    screens = Enum.flat_map(detail["providers"] || [], &[&1["sentence"] | &1["steps"]])
    lines = for %{"label" => label} <- detail["lines"] || [], do: label
    notice = for %{"sentence" => said} <- List.wrap(summary["notice"]), do: said

    [sentence | words] ++ notes ++ screens ++ lines ++ notice
  end

  defp assert_token_steps(steps) do
    assert [_, _, _, _] = steps
    assert Enum.any?(steps, &(&1 =~ "two-factor sign-in"))
    assert Enum.any?(steps, &(&1 =~ "project for Fermix alone"))
    assert Enum.any?(steps, &(&1 =~ "Read & Write"))
  end
end
