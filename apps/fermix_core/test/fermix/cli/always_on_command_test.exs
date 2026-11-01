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
  alias FermixTestSupport.HomeSummaryGoldens
  alias FermixTestSupport.PipedTerminal
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TtyTerminal

  @token "invented-hetzner-token-0123456789abcdef"
  @passphrase "invented-lantern-orchard"
  @create_confirm "Create your server? Hetzner bills it by the hour until it is deleted."
  @changed "Always On changed since this was shown, so look at it again."
  @command "curl -fsSL https://fermix.ai/always-on | sudo sh"
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
    test "an unknown step, half a choice or a step flag with no step is a usage error", ctx do
      for argv <- [
            ["make-it-so"],
            ["create_server"],
            ["create-server", "--type", "cpx22"],
            ["--yes"],
            ["create-server", "extra"]
          ] do
        {status, out, err} = run(argv, ctx, script([]))
        assert {status, out} == {2, ""}, inspect(argv)
        assert err =~ "fermix always-on ACTION", inspect(argv)
      end

      refute_received {:called, _method, _params, _opts}
    end

    # §6: the token never enters argv, and the refusal never echoes it.
    test "a token or passphrase typed as an argument is refused and never echoed", ctx do
      for argv <- [
            ["paste-token", "--token", @token],
            ["paste-token", "--token=" <> @token],
            ["move-now", "--recovery-passphrase", @passphrase]
          ] do
        {status, out, err} = run(argv, ctx, script([]))
        assert {status, out} == {2, ""}
        assert err =~ "never taken as an argument"
        refute err =~ @token
        refute err =~ @passphrase
      end

      refute_received {:called, _method, _params, _opts}
    end
  end

  describe "before anything is read" do
    # §8.2, verify_standalone: no daemon, nothing written, the code and a
    # sentence on stderr.
    test "with Fermix stopped a step refuses engine_stopped and writes nothing", ctx do
      client = script([{"hello", {:error, :not_running}}])

      {status, out, err} = run(["create-server", "--json"], ctx, client)

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

  describe "the screen" do
    test "with no terminal it prints the summary and each step as a command", ctx do
      client = script([hello(), {"home.status", {:ok, status(off())}}])

      {0, out, ""} = run([], ctx, client)

      assert [
               "Keep Fermix running when this Mac sleeps. It moves to a server you own.",
               "Steps:",
               "  Set up: fermix always-on paste-token",
               "  Use my own Linux server: fermix always-on own-server"
             ] == lines(out)
    end

    test "Details are the summary's lines, and --json prints the summary itself", ctx do
      ready = golden_summary("home_status_ready")
      client = script([hello(), {"home.status", {:ok, status(ready)}}])

      {0, out, ""} = run([], ctx, client)
      assert out =~ "Details:\n  Server: fermix-general-a3f9\n  Size: CPX22\n"
      assert out =~ "  Move now: fermix always-on move-now"

      client = script([hello(), {"home.status", {:ok, status(ready)}}])
      {0, out, ""} = run(["--json"], ctx, client)
      assert Jason.decode!(out) == %{"schema_version" => 1, "ok" => true, "result" => ready}
    end
  end

  describe "one step without a terminal" do
    test "a token comes only from --stdin, and the one provider is left to Fermix", ctx do
      client = script([hello(), {"home.status", {:ok, status(off())}}])
      {status, out, err} = run(["paste-token"], ctx, client)
      assert {status, out} == {2, ""}
      assert err =~ "pass --stdin and pipe the token in"
      refute_act()

      act = fn params ->
        assert params == %{
                 "action" => "paste_token",
                 "key" => "a-paste",
                 "input" => %{"token" => @token}
               }

        {:ok, %{"summary" => choose(), "result" => nil}}
      end

      client = script([hello(), {"home.status", {:ok, status(off())}}, {"home.act", act}])

      {0, out, err} =
        run(["paste-token", "--stdin", "--json"], ctx, client, stdin: @token <> "\n")

      assert %{"result" => %{"summary" => %{"state" => "choose"}, "result" => nil}} =
               Jason.decode!(out)

      assert err == "fermix always-on: paste_token\n"
      refute out =~ @token
      assert_received {:called, "home.act", _params, opts}
      assert Keyword.fetch!(opts, :timeout) == 90_000
      assert Keyword.fetch!(opts, :socket_path) == Path.join(ctx.home, "daemon.sock")
    end

    test "a confirm needs --yes, and refuses with its own sentence otherwise", ctx do
      client = script([hello(), {"home.status", {:ok, status(choose())}}])

      {1, out, err} = run(["create-server", "--json"], ctx, client)

      assert %{"error" => %{"code" => "confirm_required", "sentence" => sentence}} =
               Jason.decode!(out)

      assert sentence == @create_confirm <> " Pass --yes to accept it."
      assert err == "fermix always-on: " <> sentence <> "\n"
      refute_act()
    end

    test "a choice is the recommendation unless both --type and --location are given", ctx do
      for {flags, input} <- [
            {[], nil},
            {["--type", "cpx32", "--location", "hel1"],
             %{"type" => "cpx32", "location" => "hel1"}}
          ] do
        act = fn params ->
          assert Map.get(params, "input") == input

          assert Map.take(params, ["action", "key"]) == %{
                   "action" => "create_server",
                   "key" => "a-create"
                 }

          {:ok, %{"summary" => creating(), "result" => nil}}
        end

        client = script([hello(), {"home.status", {:ok, status(choose())}}, {"home.act", act}])

        {0, out, _err} = run(["create-server", "--yes"] ++ flags, ctx, client)
        assert hd(lines(out)) == "Starting your server…"
      end
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

    test "a step the screen does not offer is refused before anything is sent", ctx do
      client = script([hello(), {"home.status", {:ok, status(off())}}])

      {1, out, err} = run(["turn-on", "--json"], ctx, client)

      assert %{"error" => %{"code" => "action_refused", "sentence" => sentence}} =
               Jason.decode!(out)

      assert sentence =~ "Always On does not offer turn-on now"
      assert err =~ sentence
      refute_act()
    end

    test "the engine's refusal is said in its own words", ctx do
      refusal =
        {:error,
         {:management_error, "invalid_params", "Invalid params.",
          %{"field" => "token", "sentence" => "Hetzner does not accept this token."}}}

      client = script([hello(), {"home.status", {:ok, status(off())}}, {"home.act", refusal}])

      {1, out, err} = run(["paste-token", "--stdin"], ctx, client, stdin: @token)

      assert out == ""
      assert err =~ "fermix always-on: Fermix did not take that step. It said: Hetzner does not"
    end

    # §3.4: `changed` carries its sentence alone; the CLI reads the screen
    # again, and under --json hands it over with the refusal.
    test "changed exits 1 with its sentence and, under --json, the screen read again", ctx do
      changed = {:error, {:management_error, "changed", "Changed.", %{"sentence" => @changed}}}

      client =
        script([
          hello(),
          {"home.status", {:ok, status(choose())}},
          {"home.act", changed},
          {"home.status", {:ok, status(creating())}}
        ])

      {1, out, err} = run(["create-server", "--yes", "--json"], ctx, client)

      assert %{
               "ok" => false,
               "error" => %{"code" => "changed", "sentence" => @changed, "summary" => summary}
             } = Jason.decode!(out)

      assert summary == creating()
      assert err == "fermix always-on: create_server\nfermix always-on: #{@changed}\n"
    end

    test "Use my own Linux server prints the command and the code once", ctx do
      result = %{
        "code" => "fxenroll1.invented",
        "expires_at" => "2031-05-04T12:30:00Z",
        "command" => @command
      }

      act = {:ok, %{"summary" => connect_with_code(), "result" => result}}
      client = script([hello(), {"home.status", {:ok, status(off())}}, {"home.act", act}])

      {0, out, _err} = run(["own-server"], ctx, client)

      assert out =~ "On your server, run:\n  #{@command}\n"
      assert out =~ "until 2031-05-04T12:30:00Z:\n  fxenroll1.invented\n"
      assert length(String.split(out, "fxenroll1.invented")) == 2

      client = script([hello(), {"home.status", {:ok, status(off())}}, {"home.act", act}])
      {0, json, _err} = run(["own-server", "--json"], ctx, client)
      assert %{"result" => %{"result" => ^result}} = Jason.decode!(json)
    end

    test "Learn more prints its page and sends nothing", ctx do
      client = script([hello(), {"home.status", {:ok, status(retired())}}])

      {0, out, ""} = run(["learn-more"], ctx, client)

      assert out == "https://fermix.ai/docs/always-on/#hetzner\n"
      refute_act()
    end
  end

  describe "waiting" do
    test "--wait follows the screen until the step settles, a line per new sentence", ctx do
      ready = golden_summary("home_status_ready")

      installing = %{
        creating()
        | "sentence" => "Installing Fermix on your server…",
          "detail" => %{}
      }

      client =
        script([
          hello(),
          {"home.status", {:ok, status(choose())}},
          {"home.act", {:ok, %{"summary" => creating(), "result" => nil}}},
          {"home.status", wait_for("k-creating", {:ok, status(installing)}, ctx)},
          {"home.status", wait_for("k-creating", {:ok, status(installing)}, ctx)},
          {"home.status", wait_for("k-creating", {:ok, status(ready)}, ctx)}
        ])

      {0, out, err} = run(["create-server", "--yes", "--wait", "--json"], ctx, client)

      assert %{"result" => %{"summary" => ^ready}} = Jason.decode!(out)
      assert err =~ "Ctrl-C stops waiting"
      assert err =~ "\n  Installing Fermix on your server…\n"
      assert length(String.split(err, "Installing Fermix")) == 2
      assert err =~ "\n  Your server is ready for the move."

      assert_received {:called, "home.status", %{}, _opts}

      assert_received {:called, "home.status", %{"after" => "k-creating", "wait_ms" => 25_000},
                       opts}

      assert Keyword.fetch!(opts, :timeout) == 30_000
    end

    # §8.2: a connection closed mid-wait is the move's restart; the CLI
    # reconnects to the engine that comes back in the device role.
    test "after Move now the closed connection is the restart, followed to the end", ctx do
      ready = golden_summary("home_status_ready")
      on = golden_summary("home_status_on")

      moving = %{
        "key" => "k-moving",
        "state" => "moving",
        "sentence" => "Moving.",
        "action" => nil,
        "detail" => %{},
        "notice" => nil
      }

      file = passphrase_file(ctx)

      client =
        script([
          hello(),
          {"home.status", {:ok, status(ready)}},
          {"home.act", {:ok, %{"summary" => ready, "result" => %{"move_id" => "mv-1"}}}},
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
            {"home.act", {:ok, %{"summary" => ready, "result" => %{"move_id" => "mv-1"}}}},
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

      result = %{
        "code" => "fxenroll1.invented",
        "expires_at" => "2031-05-04T12:30:00Z",
        "command" => @command
      }

      client =
        script([
          hello(),
          {"home.status", {:ok, status(off())}},
          {"home.act", {:ok, %{"summary" => connect_with_code(), "result" => result}}},
          {"home.status", wait_for("k-connect", {:ok, status(ready)}, ctx)}
        ])

      {0, out, _err} = run(["own-server", "--wait"], ctx, client)

      assert out =~ "fxenroll1.invented"
      assert out =~ "Your server is ready for the move."
    end

    test "the wait ends after 45 minutes with the screen as it stands", ctx do
      waits =
        List.duplicate(
          {"home.status", wait_for("k-creating", {:ok, status(creating())}, ctx)},
          108
        )

      client =
        script(
          [
            hello(),
            {"home.status", {:ok, status(choose())}},
            {"home.act", {:ok, %{"summary" => creating(), "result" => nil}}}
          ] ++ waits
        )

      {0, out, err} = run(["create-server", "--yes", "--wait", "--json"], ctx, client)

      assert %{"result" => %{"summary" => %{"state" => "creating"}}} = Jason.decode!(out)
      assert err =~ "still at it after 45 minutes"
      assert Agent.get(ctx.clock, & &1) >= 45 * 60_000
    end
  end

  describe "on a terminal" do
    test "it walks the owner from Set up to a created server, then quits", ctx do
      ready = golden_summary("home_status_ready")

      paste = fn params ->
        assert params["input"] == %{"token" => @token}
        {:ok, %{"summary" => choose(), "result" => nil}}
      end

      create = fn params ->
        refute Map.has_key?(params, "input")
        {:ok, %{"summary" => creating(), "result" => nil}}
      end

      client =
        script([
          hello(),
          {"home.status", {:ok, status(off())}},
          {"home.act", paste},
          {"home.provision.options", {:ok, options()}},
          {"home.act", create},
          {"home.status", wait_for("k-creating", {:ok, status(ready)}, ctx)}
        ])

      stdin = Enum.join(["", @token, "", "", "y", "q"], "\n") <> "\n"

      {{0, out, err}, prompts} = run_tty([], ctx, client, stdin)

      assert out =~ "  1. Set up\n  2. Use my own Linux server\n"
      assert out =~ "Make a new project for Fermix alone"

      assert out =~
               "Recommended: CPX22 in Falkenstein, €20 a month.\nFalkenstein\n" <>
                 "  1. CPX22: 2 cores, 4 GB memory, 80 GB disk\n" <>
                 "     €20.09 a month, billed by the hour until deleted\n" <>
                 "  2. CPX32: 4 cores, 8 GB memory, 160 GB disk\n"

      assert out =~ "  1. Move now\n"
      assert prompts =~ "Hetzner API token: "
      assert prompts =~ "(39 characters)"
      assert err =~ @create_confirm <> " [y/N] "
      assert err =~ "fermix always-on: paste_token\n"
      assert err =~ "fermix always-on: create_server\n"
      refute out =~ @token
      refute err =~ @token
      assert_received {:called, "home.provision.options", %{}, opts}
      assert Keyword.fetch!(opts, :timeout) == 90_000
      assert_received {:secret_input_echo, false}
    end

    # A code waits on its server only right after the step that opened it:
    # coming back to it later, the owner gets Cancel the code, not a wait.
    test "an open code read afresh is offered, not waited on", ctx do
      client = script([hello(), {"home.status", {:ok, status(connect_with_code())}}])

      {{0, out, _err}, _prompts} = run_tty([], ctx, client, "q\n")

      assert out =~ "  1. Set up\n  2. Use my own Linux server\n  3. Cancel the code\n"
      refute_received {:called, "home.status", %{"after" => _key}, _opts}
    end

    # The menu is the engine's answer as sent: the recommendation first, the
    # rest grouped by city, each offer its label and its price, and a number
    # chooses that offer's size and place.
    test "the size-and-place menu groups the engine's offers by city, and a pick sends it",
         ctx do
      act = fn params ->
        assert params == %{
                 "action" => "create_server",
                 "key" => "a-create",
                 "input" => %{"type" => "cpx32", "location" => "hel1"}
               }

        {:ok, %{"summary" => creating(), "result" => nil}}
      end

      ready = golden_summary("home_status_ready")

      client =
        script([
          hello(),
          {"home.status", {:ok, status(choose())}},
          {"home.provision.options", {:ok, options()}},
          {"home.act", act},
          {"home.status", wait_for("k-creating", {:ok, status(ready)}, ctx)}
        ])

      {{0, out, err}, _prompts} = run_tty(["create-server"], ctx, client, "7\ny\n")

      menu = out |> lines() |> Enum.drop_while(&(not String.starts_with?(&1, "Recommended:")))

      assert Enum.take(menu, 20) == [
               "Recommended: CPX22 in Falkenstein, €20 a month.",
               "Falkenstein",
               "  1. CPX22: 2 cores, 4 GB memory, 80 GB disk",
               "     €20.09 a month, billed by the hour until deleted",
               "  2. CPX32: 4 cores, 8 GB memory, 160 GB disk",
               "     €36.09 a month, billed by the hour until deleted",
               "  3. CCX13: 2 dedicated cores, 8 GB memory, 80 GB disk",
               "     €42.24 a month, billed by the hour until deleted",
               "Nuremberg",
               "  4. CPX22: 2 cores, 4 GB memory, 80 GB disk",
               "     €20.09 a month, billed by the hour until deleted",
               "  5. CCX13: 2 dedicated cores, 8 GB memory, 80 GB disk",
               "     €42.24 a month, billed by the hour until deleted",
               "Helsinki",
               "  6. CPX22: 2 cores, 4 GB memory, 80 GB disk",
               "     €20.09 a month, billed by the hour until deleted",
               "  7. CPX32: 4 cores, 8 GB memory, 160 GB disk",
               "     €36.09 a month, billed by the hour until deleted",
               "  8. CCX13: 2 dedicated cores, 8 GB memory, 80 GB disk",
               "     €42.24 a month, billed by the hour until deleted"
             ]

      assert err =~ "Size and place (Enter: 1): "
      assert err =~ @create_confirm <> " [y/N] "
      assert out =~ "Your server is ready for the move."
    end

    test "No at the confirm sends nothing", ctx do
      client =
        script([
          hello(),
          {"home.status", {:ok, status(choose())}},
          {"home.provision.options", {:ok, options()}}
        ])

      {{1, _out, err}, _prompts} = run_tty(["create-server"], ctx, client, "\n\n")

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
          {"home.status", {:ok, status(retired_with_turn_on())}},
          {"home.act", changed},
          {"home.status", {:ok, status(retired())}}
        ])

      {{0, out, err}, _prompts} = run_tty([], ctx, client, "\nq\n")

      assert err =~ "fermix always-on: #{@changed}\n"
      assert out =~ "Fermix moved to your server, and this Mac is no longer connected to it."
      assert out =~ "  1. Learn more\n"
    end
  end

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp record(id, label, needs, confirm, key, url \\ nil),
    do: %{
      "id" => id,
      "label" => label,
      "needs" => needs,
      "confirm" => confirm,
      "key" => key,
      "url" => url
    }

  defp hetzner do
    %{
      "id" => "hetzner",
      "name" => "Hetzner",
      "token_label" => "Hetzner API token",
      "sentence" => "Paste a Hetzner API token to let Fermix create your server.",
      "steps" => [
        "Sign in to Hetzner's console and turn on two-factor sign-in for your account.",
        "Make a new project for Fermix alone, so the token reaches nothing else."
      ],
      "console_url" => "https://console.hetzner.cloud/",
      "docs_url" => "https://fermix.ai/docs/always-on/#hetzner"
    }
  end

  defp off do
    %{
      "key" => "k-off",
      "state" => "off",
      "sentence" => "Keep Fermix running when this Mac sleeps. It moves to a server you own.",
      "action" => record("paste_token", "Set up", ["token"], nil, "a-paste"),
      "detail" => %{
        "alternatives" => [record("own_server", "Use my own Linux server", [], nil, "a-own")],
        "providers" => [hetzner()]
      },
      "notice" => nil
    }
  end

  defp choose do
    %{
      "key" => "k-choose",
      "state" => "choose",
      "sentence" => "Your Hetzner token works, so choose the server Fermix creates.",
      "action" =>
        record("create_server", "Create server", ["choice"], @create_confirm, "a-create"),
      "detail" => %{"billing" => "Hetzner bills by the hour until the server is deleted."},
      "notice" => nil
    }
  end

  defp creating do
    %{
      "key" => "k-creating",
      "state" => "creating",
      "sentence" => "Starting your server…",
      "action" =>
        record(
          "cancel",
          "Cancel",
          [],
          "Cancel and delete your server? Everything Fermix created for it is deleted.",
          "a-cancel"
        ),
      "detail" => %{"progress" => "Checking that Hetzner has the server in stock."},
      "notice" => nil
    }
  end

  defp connect_with_code do
    %{
      off()
      | "key" => "k-connect",
        "state" => "connect",
        "sentence" => "Paste a Hetzner API token to let Fermix create your server."
    }
    |> put_in(["detail", "alternatives"], [
      record("own_server", "Use my own Linux server", [], nil, "a-own"),
      record("cancel", "Cancel the code", [], nil, "a-cancel-code")
    ])
  end

  defp moving do
    %{
      "key" => "k-moving",
      "state" => "moving",
      "sentence" => "Moving.",
      "action" => nil,
      "detail" => %{},
      "notice" => nil
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

  defp retired do
    %{
      "key" => "k-retired",
      "state" => "retired",
      "sentence" => "Fermix moved to your server, and this Mac is no longer connected to it.",
      "action" =>
        record(
          "learn_more",
          "Learn more",
          [],
          nil,
          "a-learn",
          "https://fermix.ai/docs/always-on/#hetzner"
        ),
      "detail" => %{},
      "notice" => nil
    }
  end

  defp retired_with_turn_on,
    do: %{
      retired()
      | "key" => "k-old",
        "action" => record("turn_on", "Turn it on", [], nil, "a-on")
    }

  # The engine's own answer, the management golden: the CLI draws it as sent.
  defp options do
    Application.app_dir(:fermix_core, "priv/management/fixtures/success.jsonl")
    |> File.stream!()
    |> Enum.map(&Jason.decode!/1)
    |> Enum.find(&(&1["name"] == "home_provision_options"))
    |> get_in(["response", "result"])
  end

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
