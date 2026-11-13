defmodule Fermix.CLI.AlwaysOnCommandTest do
  @moduledoc """
  `fermix always-on` (Always On setup §8.2): the CLI draws the engine's
  summary, collects what the pressed action needs, asks its confirm, sends
  one `home.act`, and follows the step with `home.status {after, wait_ms}`.

  Every case injects the management client (a script of the calls the verb
  makes, in order), the terminal, the three IO devices, the clock and the
  sleep, so nothing reaches a socket, a keychain or a real clock.
  """

  # Sync: a masked prompt goes to `:standard_error`, one globally registered
  # device that concurrent captures would share.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.AlwaysOnCommand
  alias Fermix.CLI.AlwaysOnCommand.Render
  alias FermixTestSupport.HomeSummaryGoldens
  alias FermixTestSupport.PipedTerminal
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TtyTerminal

  @passphrase "invented-lantern-orchard"
  @changed "Always On changed since this was shown, so look at it again."
  @help "https://fermix.ai/docs/always-on/"
  @command "curl -fsSL https://fermix.ai/install | sudo sh -s -- --always-on --version 1.2.3"
  @code_sentence "Run this on your Debian 12 or 13, or Ubuntu 24.04 server, then paste the code " <>
                   "when it asks. The code works once, until Sunday, May 4, 2031 at 2:30 PM CEST."
  @tailscale_label "Also join your tailnet (optional)"
  @tailscale_sentence "For WhatsApp and webhook sources: run this instead. It also asks for a " <>
                        "one-off, pre-approved Tailscale auth key tagged tag:fermix-server."
  @tailscale_command "curl -fsSL https://fermix.ai/install | sudo sh -s -- --always-on --version 1.2.3 --tailscale"
  @unconfirmed "The server fermix-general-a3f9 did not confirm in time whether the move " <>
                 "started. Its state shows once the server answers again, and starting it " <>
                 "again never starts a second move."

  setup do
    tmp = SafeRm.make_tmp_dir!("always_on_command")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)
    clock = start_supervised!({Agent, fn -> 0 end}, id: :clock)
    %{home: Path.join(tmp, "home"), tmp: tmp, clock: clock}
  end

  describe "arguments" do
    test "an unknown step, an unknown flag or a step flag with no step is a usage error", ctx do
      for argv <- [
            ["make-it-so"],
            ["move_now"],
            ["move-now", "--type", "cpx22"],
            ["--yes"],
            ["move-now", "extra"]
          ] do
        {status, out, err} = run(argv, ctx, script([]))
        assert {status, out} == {2, ""}, inspect(argv)
        assert err =~ "fermix always-on ACTION", inspect(argv)
      end

      refute_received {:called, _method, _params, _opts}
    end

    # §6: the passphrase never enters argv, and the refusal never echoes it.
    test "a passphrase typed as an argument is refused and never echoed", ctx do
      for argv <- [
            ["move-now", "--recovery-passphrase", @passphrase],
            ["restore-here", "--recovery-passphrase=" <> @passphrase]
          ] do
        {status, out, err} = run(argv, ctx, script([]))
        assert {status, out} == {2, ""}
        assert err =~ "never taken as an argument"
        refute err =~ @passphrase
      end

      refute_received {:called, _method, _params, _opts}
    end
  end

  # Always On is not in a release build yet: the verb refuses in one
  # sentence there, before anything is read or sent.
  describe "in a build without Always On" do
    test "every use of the verb refuses in one sentence, exit 1, reaching nothing", ctx do
      for argv <- [[], ["--json"], ["move-now", "--yes", "--json"]] do
        {status, out, err} = run(argv, ctx, script([]), always_on: false)

        assert status == 1, inspect(argv)
        assert err == "fermix always-on: Always On is not in this release of Fermix yet.\n"

        if "--json" in argv,
          do: assert(%{"error" => %{"code" => "always_on_unavailable"}} = Jason.decode!(out)),
          else: assert(out == "")
      end

      refute_received {:called, _method, _params, _opts}
    end

    # With no seam the verb asks the resolver of this home's own settings
    # file, the one the engine's boot reads (`Home.AlwaysOnRelease`), before
    # it reaches the engine: a switch it cannot read is named with its file.
    test "it reads Always On's switch from this home's own settings file", ctx do
      File.mkdir_p!(ctx.home)
      file = Path.join(ctx.home, "config.toml")
      File.write!(file, "[fermix_core.always_on]\nenabled = \"yes\"\n")

      {status, out, err} = run(["--json"], ctx, script([]))

      assert status == 1
      assert %{"error" => %{"code" => "home_status_unavailable"}} = Jason.decode!(out)
      assert err =~ "fermix always-on: Fermix could not read this home's status."
      assert err =~ file
      assert err =~ "[fermix_core.always_on] enabled takes true or false"
      refute_received {:called, _method, _params, _opts}
    end

    test "in a build with it, the verb reads the screen as ever", ctx do
      client = script([hello(), {"home.status", {:ok, status(off())}}])
      assert {0, _out, ""} = run([], ctx, client, always_on: true)
    end
  end

  describe "before anything is read" do
    # §8.2, verify_standalone: no daemon, nothing written, the code and a
    # sentence on stderr.
    test "with Fermix stopped a step refuses engine_stopped and writes nothing", ctx do
      client = script([{"hello", {:error, :not_running}}])

      {status, out, err} = run(["own-server", "--json"], ctx, client)

      assert status == 1
      assert %{"ok" => false, "error" => %{"code" => "engine_stopped"}} = Jason.decode!(out)
      assert err =~ "fermix always-on: Fermix is not running from this home"
      refute File.exists?(ctx.home)
    end

    test "on a home the Fermix app manages it names the app's Always On pane", ctx do
      hello = {:ok, %{"engine" => %{"distribution_identity" => "macos_app"}}}
      client = script([{"hello", hello}])
      parent = self()

      app_managed? = fn opts ->
        send(parent, {:asked_with, Keyword.fetch!(opts, :hello).()})
        true
      end

      {status, out, err} = run(["--json"], ctx, client, app_managed?: app_managed?)

      assert status == 1
      assert_received {:asked_with, ^hello}
      assert %{"error" => %{"code" => "app_managed", "sentence" => sentence}} = Jason.decode!(out)
      assert sentence =~ "the app's Always On pane"
      assert err =~ sentence
    end
  end

  # Review R6: a step that waits reports how it ended.
  describe "waiting for a step" do
    test "a restore that failed while waited on exits 1, not ok", ctx do
      problem = golden_summary("home_status_problem")

      failed = %{
        "key" => "failed",
        "state" => "problem",
        "sentence" => "Fermix could not restore its backup on this Mac.",
        "action" => nil,
        "detail" => %{"kind" => "return_failed"},
        "notice" => nil,
        "outcome" => "failed"
      }

      client =
        script([
          hello(),
          {"home.status", {:ok, status(problem)}},
          {"home.act", {:ok, %{"summary" => restoring(), "result" => nil}}},
          {"home.status", {:ok, status(failed)}}
        ])

      argv = ["restore-here", "--recovery-passphrase-file", passphrase_file(ctx)]
      argv = argv ++ ["--yes", "--wait", "--json"]

      {exit_status, out, _err} = run(argv, ctx, client)
      assert exit_status == 1, "a failed step exited #{exit_status}: #{out}"

      assert %{
               "ok" => false,
               "error" => %{"code" => "step_failed", "sentence" => sentence, "summary" => ^failed}
             } = Jason.decode!(out)

      assert sentence =~ "Fermix could not restore its backup on this Mac."
    end

    # The owner's rule for Back up now: its screen runs until the backup
    # ends, on the failed backup's problem (exit 1) or back on `on` (exit 0).
    test "back-up-now --wait exits 1 when the backup it waited for failed, 0 once stored",
         ctx do
      on = golden_summary("home_status_on")
      failed = golden_summary("home_status_backup_failed")

      for {ending, expected} <- [{failed, 1}, {on, 0}] do
        client =
          script([
            hello(),
            {"home.status", {:ok, status(on)}},
            {"home.act", {:ok, %{"summary" => backing_up(on), "result" => nil}}},
            {"home.status", wait_for("k-backing-up", {:ok, status(ending)}, ctx)}
          ])

        {exit_status, out, _err} = run(["back-up-now", "--wait", "--json"], ctx, client)
        assert exit_status == expected, "#{ending["state"]} exited #{exit_status}: #{out}"

        if expected == 1 do
          assert %{
                   "error" => %{"code" => "step_failed", "sentence" => sentence, "summary" => at}
                 } = Jason.decode!(out)

          assert sentence =~ "Backing up to S3 failed."
          # The try's own words are the screen's note, which the screen prints.
          assert at["detail"]["note"] =~ "S3 could not be reached: the connection timed out."
        else
          assert %{"ok" => true, "result" => %{"summary" => ^on}} = Jason.decode!(out)
        end
      end
    end

    test "reading a problem screen with no step is a success", ctx do
      problem = golden_summary("home_status_problem")
      client = script([hello(), {"home.status", {:ok, status(problem)}}])

      {0, out, ""} = run(["--json"], ctx, client)
      assert %{"ok" => true, "result" => ^problem} = Jason.decode!(out)
    end
  end

  describe "the screen" do
    # The Always On pane's R7: one help page per screen, the screen's last
    # line, ahead of the steps.
    test "with no terminal it prints the summary, its help page and each step as a command",
         ctx do
      client = script([hello(), {"home.status", {:ok, status(off())}}])

      {0, out, ""} = run([], ctx, client)

      assert [
               "Keep Fermix running when this Mac sleeps. It moves to a server you own.",
               "Learn more: https://fermix.ai/docs/always-on/#what-you-need",
               "Steps:",
               "  Use my own Linux server: fermix always-on own-server"
             ] == lines(out)
    end

    # R4 and R8: the one secondary sentence right under the sentence, and
    # Details facts only.
    test "the note is under the sentence, Details are the summary's lines, and --json prints " <>
           "the summary itself",
         ctx do
      ready = golden_summary("home_status_ready")
      client = script([hello(), {"home.status", {:ok, status(ready)}}])

      {0, out, ""} = run([], ctx, client)

      assert lines(out) ==
               [ready["sentence"], ready["detail"]["note"], "Details:"] ++
                 for(
                   %{"label" => l, "value" => v} <- ready["detail"]["lines"],
                   do: "  #{l}: #{v}"
                 ) ++
                 [
                   "Learn more: " <> ready["help"],
                   "Steps:",
                   "  Move now: fermix always-on move-now",
                   "  Forget this server: fermix always-on cancel"
                 ]

      client = script([hello(), {"home.status", {:ok, status(ready)}}])
      {0, out, ""} = run(["--json"], ctx, client)
      assert Jason.decode!(out) == %{"schema_version" => 1, "ok" => true, "result" => ready}
    end

    # R5: a block's reason and what to check are never hidden; a problem that
    # no step of the owner's fixes offers only what it has.
    test "a problem's note and a review's blocks print under the sentence", ctx do
      problem = golden_summary("home_status_problem")
      client = script([hello(), {"home.status", {:ok, status(problem)}}])

      {0, out, ""} = run([], ctx, client)

      assert lines(out) == [
               problem["sentence"],
               problem["detail"]["note"],
               "Learn more: " <> problem["help"],
               "Steps:",
               "  Restore on this Mac: fermix always-on restore-here"
             ]

      client = script([hello(), {"home.status", {:ok, status(not_ready())}}])
      {0, out, ""} = run([], ctx, client)

      assert lines(out) == [
               "The move cannot start yet.",
               "- fermix-larch-52e0 is too full.",
               "Learn more: https://fermix.ai/docs/always-on/#the-move",
               "Steps:",
               "  Check again: fermix always-on check-again"
             ]
    end

    # R12: the count is the engine's, said beside the step in hand, on the
    # screen and on the wait's line.
    test "while the home moves, the engine's count is beside the step in hand" do
      assert Render.screen(sending()) == [
               "Moving. This Mac restarts and reconnects to your server.",
               "Sending your home to fermix-larch-52e0… 502 MiB of 1.4 GiB sent",
               "Learn more: https://fermix.ai/docs/always-on/#the-move"
             ]

      assert Render.progress(sending()) ==
               "Moving. This Mac restarts and reconnects to your server. Sending your home to " <>
                 "fermix-larch-52e0… 502 MiB of 1.4 GiB sent"

      no_count = update_in(sending(), ["detail"], &Map.delete(&1, "transfer"))
      assert Render.progress(no_count) =~ ~r/fermix-larch-52e0…\z/
    end

    # Always On's inbound webhooks: the Funnel mounts the server needs, each
    # command on a line of its own to copy, as the engine words them, then
    # the one tailnet step and the page that holds the rest.
    test "the Funnel mounts print under their sentence, each command on its own line", ctx do
      on = golden_summary("home_status_on")

      %{"sentence" => said, "mounts" => mounts, "notes" => [note], "url" => url} =
        on["detail"]["webhooks"]

      client = script([hello(), {"home.status", {:ok, status(on)}}])

      {0, out, ""} = run([], ctx, client)

      printed =
        [said] ++
          Enum.flat_map(
            mounts,
            &["  #{&1["label"]}:", "    #{&1["command"]}", "  #{&1["note"]}"]
          ) ++ [note, "Learn more: " <> url]

      assert out =~ Enum.join(printed, "\n") <> "\n"

      assert out =~
               "  WhatsApp:\n    sudo tailscale funnel --bg --set-path=/webhook/whatsapp " <>
                 "http://127.0.0.1:4030/webhook/whatsapp\n"
    end

    # The backup settings (the pane's §3.12): whether the recovery passphrase
    # is set is a Details line, and Change is a step like any other.
    test "a linked desktop's screen says the recovery passphrase is set and offers Change", ctx do
      on = golden_summary("home_status_on")
      client = script([hello(), {"home.status", {:ok, status(on)}}])

      {0, out, ""} = run([], ctx, client)

      %{"passphrase" => %{"label" => label, "value" => value}} = on["detail"]["backup"]
      assert out =~ "  Connection: Direct\n  #{label}: #{value}\n"
      assert out =~ "  Change: fermix always-on change-passphrase\n"
      assert List.last(lines(out)) == "  Change: fermix always-on change-passphrase"
      assert out =~ "\nLearn more: " <> on["help"] <> "\nSteps:\n"
    end
  end

  # Review F9 (D17): the code is shown once, so a result of any other shape
  # than own_server's fails loud rather than print nothing.
  describe "a step's result" do
    # The Always On pane's D10: the code's sentence and the Tailscale step's
    # label are the engine's, printed as they came.
    test "own_server's is matched whole, the code's fields and its Tailscale step apart" do
      code = own_code()

      assert Render.result(code) == [
               @code_sentence,
               "  " <> @command,
               "Code:",
               "  fxenroll1.invented",
               @tailscale_label <> ":",
               "  " <> @tailscale_sentence,
               "    " <> @tailscale_command,
               "  Learn more: https://fermix.ai/docs/always-on/#tailscale"
             ]

      assert Render.result(nil) == []
      assert Render.result(%{"move_id" => "mv-0001"}) == []

      for bad <- [
            Map.delete(code, "tailscale"),
            Map.delete(code, "command"),
            Map.delete(code, "sentence"),
            Map.put(code, "code", nil),
            Map.put(code, "tailscale", %{"sentence" => @tailscale_sentence}),
            Map.update!(code, "tailscale", &Map.delete(&1, "label")),
            Map.update!(code, "tailscale", &Map.delete(&1, "url")),
            Map.put(code, "tailscale", nil),
            %{"move_id" => "mv-0001", "code" => "fxenroll1.invented"}
          ] do
        error = assert_raise ArgumentError, fn -> Render.result(bad) end
        refute error.message =~ "fxenroll1.invented"
      end
    end
  end

  # M97 §3.1, §7.5: Add a computer's code and the computer added.
  describe "adding a computer" do
    test "the code and the computer added are printed, each matched whole" do
      code = %{"code" => "fxenroll1.invented", "expires_at" => "2031-05-04T10:30:00Z"}

      assert [intro, "  fxenroll1.invented"] = Render.result(code)
      assert intro =~ "works once, until 2031-05-04T10:30:00Z"

      added = %{"device_id" => "7e1f0c2a-3b4d-4e5f-8a6b-7c8d9e0f1a2b", "name" => "loft-linux"}
      assert Render.result(added) == ["loft-linux is now a computer of your Fermix."]

      for bad <- [Map.put(code, "name", "loft-linux"), Map.put(added, "code", "fxenroll1.x")] do
        error = assert_raise ArgumentError, fn -> Render.result(bad) end
        refute error.message =~ "fxenroll1"
      end
    end

    test "add-computer prints the code the server opened, once", ctx do
      server = golden_summary("home_status_server")
      add = Enum.find(server["detail"]["alternatives"], &(&1["id"] == "add_computer"))
      result = %{"code" => "fxenroll1.invented", "expires_at" => "2031-05-04T10:30:00Z"}

      act = fn params ->
        assert params == %{"action" => "add_computer", "key" => add["key"]}
        {:ok, %{"summary" => server, "result" => result}}
      end

      client = script([hello(), {"home.status", {:ok, status(server)}}, {"home.act", act}])
      assert {0, out, _err} = run(["add-computer"], ctx, client)
      assert out =~ "  fxenroll1.invented\n"
    end

    test "approve-computer takes the digits from --sas, never a prompt", ctx do
      asking = golden_summary("home_status_server_asking")
      joined = golden_summary("home_status_server_joined")
      %{"id" => "approve_computer", "key" => key, "needs" => ["sas"]} = asking["action"]
      client = script([hello(), {"home.status", {:ok, status(asking)}}])

      {2, "", err} = run(["approve-computer"], ctx, client)
      assert err =~ "pass --sas DIGITS"
      refute_act()

      act = fn params ->
        assert params == %{
                 "action" => "approve_computer",
                 "key" => key,
                 "input" => %{"sas" => "482 913"}
               }

        added = %{"device_id" => "7e1f0c2a-3b4d-4e5f-8a6b-7c8d9e0f1a2b", "name" => "loft-linux"}
        {:ok, %{"summary" => joined, "result" => added}}
      end

      client = script([hello(), {"home.status", {:ok, status(asking)}}, {"home.act", act}])
      assert {0, out, _err} = run(["approve-computer", "--sas", "482 913"], ctx, client)
      assert out =~ "loft-linux is now a computer of your Fermix."
    end

    test "deny-computer sends the step beside it, asking nothing", ctx do
      asking = golden_summary("home_status_server_asking")
      [deny | _more] = asking["detail"]["alternatives"]

      act = fn params ->
        assert params == %{"action" => "deny_computer", "key" => deny["key"]}
        {:ok, %{"summary" => golden_summary("home_status_server"), "result" => nil}}
      end

      client = script([hello(), {"home.status", {:ok, status(asking)}}, {"home.act", act}])
      assert {0, _out, _err} = run(["deny-computer"], ctx, client)
    end

    test "on a terminal the digits are asked for, as the new computer shows them", ctx do
      asking = golden_summary("home_status_server_asking")
      joined = golden_summary("home_status_server_joined")

      act = fn params ->
        assert params["input"] == %{"sas" => "482913"}
        added = %{"device_id" => "7e1f0c2a-3b4d-4e5f-8a6b-7c8d9e0f1a2b", "name" => "loft-linux"}
        {:ok, %{"summary" => joined, "result" => added}}
      end

      client = script([hello(), {"home.status", {:ok, status(asking)}}, {"home.act", act}])
      {{0, out, err}, _prompts} = run_tty(["approve-computer"], ctx, client, "482913\n")

      assert err =~ "The six digits the new computer shows: "
      assert out =~ "loft-linux is now a computer of your Fermix."
    end
  end

  describe "one step without a terminal" do
    test "a confirm needs --yes, and refuses with its own sentence otherwise", ctx do
      ready = golden_summary("home_status_ready")
      client = script([hello(), {"home.status", {:ok, status(ready)}}])
      argv = ["move-now", "--recovery-passphrase-file", passphrase_file(ctx), "--json"]

      {1, out, err} = run(argv, ctx, client)

      assert %{"error" => %{"code" => "confirm_required", "sentence" => sentence}} =
               Jason.decode!(out)

      assert sentence == ready["action"]["confirm"] <> " Pass --yes to accept it."
      assert err == "fermix always-on: " <> sentence <> "\n"
      refute_act()
    end

    test "Move now takes the recovery passphrase from its file, never a prompt", ctx do
      ready = golden_summary("home_status_ready_first_move")
      %{"key" => move_key} = ready["action"]
      client = script([hello(), {"home.status", {:ok, status(ready)}}])

      {2, "", err} = run(["move-now", "--yes"], ctx, client)
      assert err =~ "pass --recovery-passphrase-file PATH"
      refute_act()

      file = Path.join(ctx.tmp, "recovery")
      File.write!(file, @passphrase <> "\n")

      act = fn params ->
        assert params == %{
                 "action" => "move_now",
                 "key" => move_key,
                 "input" => %{"recovery_passphrase" => @passphrase}
               }

        {:ok, %{"summary" => ready, "result" => %{"move_id" => "mv-0f1e2d3c"}}}
      end

      client = script([hello(), {"home.status", {:ok, status(ready)}}, {"home.act", act}])
      argv = ["move-now", "--yes", "--recovery-passphrase-file", file]

      {0, out, err} = run(argv, ctx, client)
      refute out =~ @passphrase
      refute err =~ @passphrase
    end

    # Always On's move back: its two actions are verbs the day the engine
    # offers them, by the one rule that names an action's step.
    test "move-back sends the step the on screen offers, asking nothing", ctx do
      on = golden_summary("home_status_on")
      move_back = Enum.find(on["detail"]["alternatives"], &(&1["id"] == "move_back"))
      assert "move-back" in AlwaysOnCommand.steps()

      act = fn params ->
        assert params == %{"action" => "move_back", "key" => move_back["key"]}
        {:ok, %{"summary" => on, "result" => nil}}
      end

      client = script([hello(), {"home.status", {:ok, status(on)}}, {"home.act", act}])
      assert {0, out, _err} = run(["move-back", "--json"], ctx, client)
      assert %{"result" => %{"result" => nil}} = Jason.decode!(out)
    end

    test "restore-here takes the recovery passphrase from its file and needs --yes", ctx do
      problem = golden_summary("home_status_problem")
      restore = Enum.find(problem["detail"]["alternatives"], &(&1["id"] == "restore_here"))
      assert restore["needs"] == ["recovery_passphrase"]
      file = passphrase_file(ctx)

      client = script([hello(), {"home.status", {:ok, status(problem)}}])
      argv = ["restore-here", "--recovery-passphrase-file", file, "--json"]
      {1, out, _err} = run(argv, ctx, client)
      assert %{"error" => %{"code" => "confirm_required"}} = Jason.decode!(out)
      refute_act()

      act = fn params ->
        assert params == %{
                 "action" => "restore_here",
                 "key" => restore["key"],
                 "input" => %{"recovery_passphrase" => @passphrase}
               }

        {:ok, %{"summary" => problem, "result" => nil}}
      end

      client = script([hello(), {"home.status", {:ok, status(problem)}}, {"home.act", act}])
      {0, out, err} = run(["restore-here", "--yes" | tl(argv)], ctx, client)
      refute out =~ @passphrase
      refute err =~ @passphrase
    end

    test "a step the screen does not offer is refused before anything is sent", ctx do
      client = script([hello(), {"home.status", {:ok, status(off())}}])

      {1, out, err} = run(["move-back", "--json"], ctx, client)

      assert %{"error" => %{"code" => "action_refused", "sentence" => sentence}} =
               Jason.decode!(out)

      assert sentence =~ "Always On does not offer move-back now"
      assert err =~ sentence
      refute_act()
    end

    test "the engine's refusal is said in its own words", ctx do
      refusal =
        {:error,
         {:management_error, "unavailable", "Unavailable.",
          %{"capability" => "home", "sentence" => "Remote reach is off on this computer."}}}

      client = script([hello(), {"home.status", {:ok, status(off())}}, {"home.act", refusal}])

      {1, out, err} = run(["own-server"], ctx, client)

      assert out == ""

      assert err =~
               "fermix always-on: Fermix did not take that step. It said: Remote reach is off"
    end

    # §3.4: `changed` carries its sentence alone; the CLI reads the screen
    # again, and under --json hands it over with the refusal.
    test "changed exits 1 with its sentence and, under --json, the screen read again", ctx do
      changed = {:error, {:management_error, "changed", "Changed.", %{"sentence" => @changed}}}

      client =
        script([
          hello(),
          {"home.status", {:ok, status(off())}},
          {"home.act", changed},
          {"home.status", {:ok, status(connect_with_code())}}
        ])

      {1, out, err} = run(["own-server", "--json"], ctx, client)

      assert %{
               "ok" => false,
               "error" => %{"code" => "changed", "sentence" => @changed, "summary" => summary}
             } = Jason.decode!(out)

      assert summary == connect_with_code()
      assert err == "fermix always-on: own_server\nfermix always-on: #{@changed}\n"
    end

    test "Use my own Linux server prints the command and the code once", ctx do
      result = own_code()

      act = {:ok, %{"summary" => connect_with_code(), "result" => result}}
      client = script([hello(), {"home.status", {:ok, status(off())}}, {"home.act", act}])

      {0, out, _err} = run(["own-server"], ctx, client)

      # The engine's sentence for the code, the command and the code, then
      # the optional Tailscale step under its label.
      assert out =~
               "#{@code_sentence}\n  #{@command}\nCode:\n  fxenroll1.invented\n" <>
                 "#{@tailscale_label}:\n  #{@tailscale_sentence}\n    #{@tailscale_command}\n"

      assert length(String.split(out, "fxenroll1.invented")) == 2
      refute out =~ "2031-05-04T12:30:00Z"

      client = script([hello(), {"home.status", {:ok, status(off())}}, {"home.act", act}])
      {0, json, _err} = run(["own-server", "--json"], ctx, client)
      assert %{"result" => %{"result" => ^result}} = Jason.decode!(json)
    end

    # R7: Learn more is no step; the screen's help page is its last line.
    test "learn-more is no step any more, and the help page is printed with the screen", ctx do
      {status, out, err} = run(["learn-more"], ctx, script([]))
      assert {status, out} == {2, ""}
      refute err =~ "learn-more"
      refute_received {:called, _method, _params, _opts}

      client = script([hello(), {"home.status", {:ok, status(retired())}}])
      {0, out, ""} = run([], ctx, client)

      assert lines(out) == [
               "Fermix moved to your server, and this Mac is no longer connected to it.",
               "Learn more: https://fermix.ai/docs/always-on/#when-the-server-is-gone"
             ]
    end

    # The backup settings' Change (the pane's §3.12, S2): the new recovery
    # passphrase is collected as the first Move now's is, and the confirm
    # asked first.
    test "change-passphrase takes the new passphrase from its file and needs --yes", ctx do
      on = golden_summary("home_status_on")
      %{"key" => key, "needs" => ["new_recovery_passphrase"]} = on["detail"]["backup"]["change"]
      assert "change-passphrase" in AlwaysOnCommand.steps()

      {2, _out, usage} = run(["--yes"], ctx, script([]))
      assert usage =~ "change-passphrase"

      client = script([hello(), {"home.status", {:ok, status(on)}}])
      {2, "", err} = run(["change-passphrase", "--yes"], ctx, client)
      assert err =~ "pass --recovery-passphrase-file PATH"
      refute_act()

      argv = ["change-passphrase", "--recovery-passphrase-file", passphrase_file(ctx), "--json"]
      client = script([hello(), {"home.status", {:ok, status(on)}}])
      {1, out, _err} = run(argv, ctx, client)

      assert %{"error" => %{"code" => "confirm_required", "sentence" => sentence}} =
               Jason.decode!(out)

      assert sentence =~ "Change the recovery passphrase?\n"
      refute_act()

      act = fn params ->
        assert params == %{
                 "action" => "change_passphrase",
                 "key" => key,
                 "input" => %{"recovery_passphrase" => @passphrase}
               }

        {:ok, %{"summary" => on, "result" => nil}}
      end

      client = script([hello(), {"home.status", {:ok, status(on)}}, {"home.act", act}])
      {0, out, err} = run(["change-passphrase", "--yes" | tl(argv)], ctx, client)
      assert %{"result" => %{"result" => nil}} = Jason.decode!(out)
      refute out =~ @passphrase
      refute err =~ @passphrase
    end
  end

  describe "waiting" do
    test "--wait follows the screen until the step settles, a line per new sentence", ctx do
      ready = golden_summary("home_status_ready")

      client =
        script([
          hello(),
          {"home.status", {:ok, status(off())}},
          {"home.act", {:ok, %{"summary" => connect_with_code(), "result" => own_code()}}},
          {"home.status", wait_for("k-connect", {:ok, status(creating())}, ctx)},
          {"home.status", wait_for("k-creating", {:ok, status(creating())}, ctx)},
          {"home.status", wait_for("k-creating", {:ok, status(ready)}, ctx)}
        ])

      {0, out, err} = run(["own-server", "--wait", "--json"], ctx, client)

      assert %{"result" => %{"summary" => ^ready}} = Jason.decode!(out)
      assert err =~ "Ctrl-C stops waiting"
      assert err =~ "\n  Connecting your server…\n"
      assert length(String.split(err, "Connecting your server")) == 2
      assert err =~ "\n  " <> ready["sentence"] <> "\n"

      assert_received {:called, "home.status", %{}, _opts}

      assert_received {:called, "home.status", %{"after" => "k-connect", "wait_ms" => 25_000},
                       opts}

      assert Keyword.fetch!(opts, :timeout) == 30_000
    end

    # §8.2: a connection closed mid-wait is the move's restart; the CLI
    # reconnects to the engine that comes back in the device role.
    test "after Move now the closed connection is the restart, followed to the end", ctx do
      ready = golden_summary("home_status_ready")
      on = golden_summary("home_status_on")

      moving = moving()

      file = passphrase_file(ctx)

      client =
        script([
          hello(),
          {"home.status", {:ok, status(ready)}},
          {"home.act",
           {:ok, %{"summary" => moved_here(ready), "result" => %{"move_id" => "mv-1"}}}},
          {"home.status", {:error, :closed}},
          {"home.status", {:error, :not_running}},
          {"home.status", {:ok, status(moving)}},
          {"home.status", wait_for("k-moving", {:ok, status(on)}, ctx)}
        ])

      argv = ["move-now", "--yes", "--wait", "--recovery-passphrase-file", file, "--json"]
      {0, out, err} = run(argv, ctx, client)

      assert %{"result" => %{"summary" => ^on, "result" => %{"move_id" => "mv-1"}}} =
               Jason.decode!(out)

      assert err =~ "  Moving.\n"
      assert Agent.get(ctx.clock, & &1) < 90_000
    end

    test "a move whose engine never comes back says to start Fermix again", ctx do
      ready = golden_summary("home_status_ready")
      file = passphrase_file(ctx)
      gone = List.duplicate({"home.status", {:error, :not_running}}, 90)

      client =
        script(
          [
            hello(),
            {"home.status", {:ok, status(ready)}},
            {"home.act",
             {:ok, %{"summary" => moved_here(ready), "result" => %{"move_id" => "mv-1"}}}},
            {"home.status", {:error, :closed}}
          ] ++ gone
        )

      argv = ["move-now", "--yes", "--wait", "--recovery-passphrase-file", file, "--json"]
      {1, out, err} = run(argv, ctx, client)

      assert %{"error" => %{"code" => "engine_stopped", "sentence" => sentence}} =
               Jason.decode!(out)

      assert sentence =~ "Start Fermix again to finish the move."
      assert err =~ sentence
      assert Agent.get(ctx.clock, & &1) >= 90_000
    end

    # §3.4: `unconfirmed` from a desktop's forwarded Move now means the move
    # may have started, so it is followed exactly as a started move is.
    test "an unconfirmed Move now is said and followed to the moved screen", ctx do
      ready = golden_summary("home_status_ready")
      on = golden_summary("home_status_on")
      file = passphrase_file(ctx)

      client =
        script([
          hello(),
          {"home.status", {:ok, status(ready)}},
          {"home.act", unconfirmed()},
          {"home.status", {:ok, status(moving())}},
          {"home.status", wait_for("k-moving", {:ok, status(on)}, ctx)}
        ])

      argv = ["move-now", "--yes", "--wait", "--recovery-passphrase-file", file, "--json"]
      {0, out, err} = run(argv, ctx, client)

      assert Jason.decode!(out) == %{
               "schema_version" => 1,
               "ok" => true,
               "result" => %{"summary" => on, "result" => nil}
             }

      assert err =~ "fermix always-on: #{@unconfirmed}\n"
      refute err =~ "did not take that step"
    end

    test "an unconfirmed Move now with no wait shows the screen read again", ctx do
      ready = golden_summary("home_status_ready")
      file = passphrase_file(ctx)

      client =
        script([
          hello(),
          {"home.status", {:ok, status(ready)}},
          {"home.act", unconfirmed()},
          {"home.status", {:ok, status(moving())}}
        ])

      argv = ["move-now", "--yes", "--recovery-passphrase-file", file]
      {0, out, err} = run(argv, ctx, client)

      assert lines(out) == ["Moving."]
      assert err == "fermix always-on: move_now\nfermix always-on: #{@unconfirmed}\n"
    end

    test "a code for a server of your own is waited on until the server comes", ctx do
      ready = golden_summary("home_status_ready")

      client =
        script([
          hello(),
          {"home.status", {:ok, status(off())}},
          {"home.act", {:ok, %{"summary" => connect_with_code(), "result" => own_code()}}},
          {"home.status", wait_for("k-connect", {:ok, status(ready)}, ctx)}
        ])

      {0, out, _err} = run(["own-server", "--wait"], ctx, client)

      assert out =~ "fxenroll1.invented"
      assert out =~ ready["sentence"]
    end

    test "the wait ends after 45 minutes, exit 1, with the screen as it stands", ctx do
      waits =
        List.duplicate(
          {"home.status", wait_for("k-connect", {:ok, status(connect_with_code())}, ctx)},
          108
        )

      client =
        script(
          [
            hello(),
            {"home.status", {:ok, status(off())}},
            {"home.act", {:ok, %{"summary" => connect_with_code(), "result" => own_code()}}}
          ] ++ waits
        )

      {1, out, err} = run(["own-server", "--wait", "--json"], ctx, client)

      # Review R6: a step still at it is not a step done.
      assert %{
               "ok" => false,
               "error" => %{
                 "code" => "step_unfinished",
                 "summary" => %{"state" => "connect", "outcome" => "waiting"}
               }
             } = Jason.decode!(out)

      assert err =~ "still at it after 45 minutes"
      assert Agent.get(ctx.clock, & &1) >= 45 * 60_000
    end
  end

  describe "on a terminal" do
    test "it walks the owner from their own server's code to a held server, then quits", ctx do
      ready = golden_summary("home_status_ready")

      own = fn params ->
        assert params == %{"action" => "own_server", "key" => "a-own"}
        {:ok, %{"summary" => connect_with_code(), "result" => own_code()}}
      end

      client =
        script([
          hello(),
          {"home.status", {:ok, status(off())}},
          {"home.act", own},
          {"home.status", wait_for("k-connect", {:ok, status(ready)}, ctx)}
        ])

      {{0, out, err}, _prompts} = run_tty([], ctx, client, "\nq\n")

      assert out =~ "  1. Use my own Linux server\n"
      assert out =~ "#{@code_sentence}\n  #{@command}\n"
      assert out =~ "  fxenroll1.invented\n"
      assert out =~ ready["sentence"]
      assert out =~ "  1. Move now\n"
      assert err =~ "fermix always-on: own_server\n"
      assert_received {:called, "home.act", _params, opts}
      assert Keyword.fetch!(opts, :timeout) == 90_000
    end

    # A code waits on its server only right after the step that opened it:
    # coming back to it later, the owner gets Cancel the code, not a wait.
    test "an open code read afresh is offered, not waited on", ctx do
      client = script([hello(), {"home.status", {:ok, status(connect_with_code())}}])

      {{0, out, _err}, _prompts} = run_tty([], ctx, client, "q\n")

      assert out =~ "  1. Replace the code\n  2. Cancel the code\n"
      refute_received {:called, "home.status", %{"after" => _key}, _opts}
    end

    test "No at the confirm sends nothing", ctx do
      problem = golden_summary("home_status_problem")
      client = script([hello(), {"home.status", {:ok, status(problem)}}])

      {{1, _out, err}, prompts} =
        run_tty(["restore-here"], ctx, client, @passphrase <> "\n\n")

      assert prompts =~ "Recovery passphrase: "
      assert err =~ problem["detail"]["alternatives"] |> hd() |> Map.fetch!("confirm")

      assert err =~ "fermix always-on: nothing was done.\n"
      refute_act()
    end

    test "a new recovery passphrase is typed twice and must match", ctx do
      ready = golden_summary("home_status_ready_first_move")
      client = script([hello(), {"home.status", {:ok, status(ready)}}])

      stdin = @passphrase <> "\n" <> "another-invented-passphrase\n"
      {{1, _out, err}, prompts} = run_tty(["move-now"], ctx, client, stdin)

      assert prompts =~ "New recovery passphrase: "
      assert prompts =~ "Repeat it: "
      assert err =~ "The two passphrases differ"
      refute_act()
    end

    test "an unconfirmed Move now is followed on a terminal, then the next step offered", ctx do
      ready = golden_summary("home_status_ready")
      on = golden_summary("home_status_on")

      client =
        script([
          hello(),
          {"home.status", {:ok, status(ready)}},
          {"home.act", unconfirmed()},
          {"home.status", {:ok, status(moving())}},
          {"home.status", wait_for("k-moving", {:ok, status(on)}, ctx)}
        ])

      stdin = Enum.join(["", @passphrase, "y", "q"], "\n") <> "\n"
      {{0, out, err}, _prompts} = run_tty([], ctx, client, stdin)

      assert err =~ "fermix always-on: #{@unconfirmed}\n"
      assert out =~ "Fermix runs on your server."
      assert out =~ "  1. Back up now\n"
      refute err =~ "did not take that step"
    end

    test "after changed the screen is read again and offered anew", ctx do
      changed = {:error, {:management_error, "changed", "Changed.", %{"sentence" => @changed}}}

      client =
        script([
          hello(),
          {"home.status", {:ok, status(off())}},
          {"home.act", changed},
          {"home.status", {:ok, status(retired())}}
        ])

      {{0, out, err}, _prompts} = run_tty([], ctx, client, "\nq\n")

      assert err =~ "fermix always-on: #{@changed}\n"
      # A screen that offers no step ends on its help page: nothing to number.
      assert String.ends_with?(
               out,
               "Fermix moved to your server, and this Mac is no longer connected to it.\n" <>
                 "Learn more: https://fermix.ai/docs/always-on/#when-the-server-is-gone\n"
             )
    end

    test "a new recovery passphrase for the backups is typed twice, then confirmed", ctx do
      on = golden_summary("home_status_on")
      client = script([hello(), {"home.status", {:ok, status(on)}}])

      stdin = @passphrase <> "\n" <> @passphrase <> "\n\n"
      {{1, _out, err}, prompts} = run_tty(["change-passphrase"], ctx, client, stdin)

      assert prompts =~ "New recovery passphrase: "
      assert prompts =~ "Repeat it: "
      assert err =~ on["detail"]["backup"]["change"]["confirm"] <> " [y/N] "
      assert err =~ "fermix always-on: nothing was done.\n"
      refute_act()
    end
  end

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp record(id, label, needs, confirm, key),
    do: %{"id" => id, "label" => label, "needs" => needs, "confirm" => confirm, "key" => key}

  defp off do
    %{
      "key" => "k-off",
      "state" => "off",
      "sentence" => "Keep Fermix running when this Mac sleeps. It moves to a server you own.",
      "action" => record("own_server", "Use my own Linux server", [], nil, "a-own"),
      "detail" => %{},
      "notice" => nil,
      "outcome" => "done",
      "help" => @help <> "#what-you-need"
    }
  end

  # The owner's server used its code and connects.
  defp creating do
    %{
      "key" => "k-creating",
      "state" => "creating",
      "sentence" => "Connecting your server…",
      "action" => nil,
      "detail" => %{},
      "notice" => nil,
      "outcome" => "running"
    }
  end

  defp connect_with_code do
    %{
      "key" => "k-connect",
      "state" => "connect",
      "sentence" => "Waiting for your server to use its code.",
      "action" => nil,
      "detail" => %{
        "alternatives" => [
          record("own_server", "Replace the code", [], nil, "a-own"),
          record("cancel", "Cancel the code", [], nil, "a-cancel-code")
        ]
      },
      "notice" => nil,
      "outcome" => "waiting",
      "help" => @help <> "#set-up-your-server"
    }
  end

  # What Use my own Linux server answers once: the code, the command, the
  # engine's sentence for them and the optional Tailscale step.
  defp own_code do
    %{
      "code" => "fxenroll1.invented",
      "expires_at" => "2031-05-04T12:30:00Z",
      "command" => @command,
      "sentence" => @code_sentence,
      "tailscale" => %{
        "label" => @tailscale_label,
        "sentence" => @tailscale_sentence,
        "command" => @tailscale_command,
        "url" => @help <> "#tailscale"
      }
    }
  end

  # Restore here's job running, as the act answers it.
  defp restoring do
    %{
      "key" => "k-restoring",
      "state" => "moving",
      "sentence" =>
        "Restoring Fermix on this Mac from its backup. Messages wait until it is done.",
      "action" => nil,
      "detail" => %{"progress" => "Restoring Fermix from the backup on this Mac…"},
      "notice" => nil,
      "outcome" => "running"
    }
  end

  defp moving do
    %{
      "key" => "k-moving",
      "state" => "moving",
      "sentence" => "Moving.",
      "action" => nil,
      "detail" => %{},
      "notice" => nil,
      "outcome" => "running"
    }
  end

  defp unconfirmed do
    details = %{
      "method" => "home.move.start",
      "primary" => "fermix-general-a3f9",
      "sentence" => @unconfirmed
    }

    {:error,
     {:management_error, "unconfirmed",
      "The request was sent, but its answer did not arrive, so its outcome is not known yet.",
      details}}
  end

  # Nothing to press: the help line is the way on.
  defp retired do
    %{
      "key" => "k-retired",
      "state" => "retired",
      "sentence" => "Fermix moved to your server, and this Mac is no longer connected to it.",
      "action" => nil,
      "detail" => %{},
      "notice" => nil,
      "outcome" => "done",
      "help" => @help <> "#when-the-server-is-gone"
    }
  end

  # The move from this computer while it sends the home, as the engine counts
  # it.
  defp sending do
    %{
      "key" => "k-sending",
      "state" => "moving",
      "sentence" => "Moving. This Mac restarts and reconnects to your server.",
      "action" => nil,
      "detail" => %{
        "progress" => "Sending your home to fermix-larch-52e0…",
        "transfer" => %{"fraction" => 0.35, "label" => "502 MiB of 1.4 GiB sent"},
        "route" => %{"from" => "This Mac", "to" => "fermix-larch-52e0", "direction" => "forward"}
      },
      "notice" => nil,
      "outcome" => "running",
      "help" => @help <> "#the-move"
    }
  end

  # A review that blocks the move: its blocks, and nothing else of the
  # review.
  defp not_ready do
    %{
      "key" => "k-not-ready",
      "state" => "problem",
      "sentence" => "The move cannot start yet.",
      "action" => record("check_again", "Check again", [], nil, "a-check"),
      "detail" => %{
        "kind" => "not_ready",
        "note" => nil,
        "seen_at" => nil,
        "readiness" => [
          %{"id" => "disk", "status" => "block", "sentence" => "fermix-larch-52e0 is too full."}
        ],
        "alternatives" => []
      },
      "notice" => nil,
      "outcome" => "failed",
      "help" => @help <> "#the-move"
    }
  end

  # The screen Back up now answers: `on`, its backup running on the server.
  defp backing_up(on) do
    %{on | "key" => "k-backing-up", "outcome" => "running"}
    |> put_in(["detail", "progress"], "Backing up now…")
  end

  # The screen Move now answers here: `ready` until the restart shows, the
  # move it asked for running.
  defp moved_here(ready), do: %{ready | "outcome" => "running"}

  defp golden_summary(name) do
    {^name, record} = List.keyfind(HomeSummaryGoldens.rows(), name, 0)
    record["summary"]
  end

  defp status(summary), do: %{"role" => "primary", "summary" => summary}

  defp hello, do: {"hello", {:ok, %{"engine" => %{"distribution_identity" => "standalone"}}}}

  defp passphrase_file(ctx) do
    file = Path.join(ctx.tmp, "recovery")
    File.write!(file, @passphrase <> "\n")
    file
  end

  # A held `home.status` that answers once 25 s of the injected clock passed.
  defp wait_for(key, reply, ctx) do
    fn params ->
      assert params == %{"after" => key, "wait_ms" => 25_000}
      Agent.update(ctx.clock, &(&1 + 25_000))
      reply
    end
  end

  # ── harness ───────────────────────────────────────────────────────────────

  # The calls the verb makes, in order: each `{method, reply}` answers the next
  # call, a 1-arity reply is given the params. Every call is reported to the
  # test, and a call out of script fails it.
  defp script(steps) do
    agent = start_supervised!({Agent, fn -> steps end}, id: make_ref())
    parent = self()

    fn method, params, opts ->
      send(parent, {:called, method, params, opts})

      case Agent.get_and_update(agent, &pop/1) do
        {^method, reply} when is_function(reply, 1) -> reply.(params)
        {^method, reply} -> reply
        next -> flunk("#{method} was not expected; the script's next call was #{inspect(next)}")
      end
    end
  end

  defp pop([next | rest]), do: {next, rest}
  defp pop([]), do: {:end_of_script, []}

  defp refute_act, do: refute_received({:called, "home.act", _params, _opts})

  defp deps(ctx, client, extra) do
    clock = ctx.clock

    [
      home: ctx.home,
      client: client,
      terminal: PipedTerminal,
      app_managed?: fn _opts -> false end,
      now_ms: fn -> Agent.get(clock, & &1) end,
      sleep: fn ms -> Agent.update(clock, &(&1 + ms)) end
    ]
    |> Keyword.merge(extra)
  end

  defp run(argv, ctx, client, extra \\ []) do
    {stdin_text, extra} = Keyword.pop(extra, :stdin, "")
    {:ok, stdin} = StringIO.open(stdin_text)
    {:ok, stdout} = StringIO.open("")
    {:ok, stderr} = StringIO.open("")

    all = deps(ctx, client, extra) ++ [stdin: stdin, stdout: stdout, stderr: stderr]
    status = AlwaysOnCommand.run(argv, all)

    {status, contents(stdout), contents(stderr)}
  end

  # On a terminal: masked prompts go to `:standard_error`, captured here.
  defp run_tty(argv, ctx, client, stdin) do
    parent = self()

    prompts =
      capture_io(:stderr, fn ->
        send(parent, {:ran, run(argv, ctx, client, terminal: TtyTerminal, stdin: stdin)})
      end)

    assert_received {:ran, ran}
    {ran, prompts}
  end

  defp contents(device) do
    {:ok, {_in, out}} = StringIO.close(device)
    out
  end

  defp lines(text), do: String.split(text, "\n", trim: true)
end
