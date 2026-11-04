defmodule FermixCore.Management.AlwaysOnTest do
  # Always On setup §3.4, §4: every step a surface asks for is one `act/2`,
  # run by the engine under one serializer, against a home of the test's own:
  # the sequence and the summary after it, every refusal, and on a linked
  # desktop the server's steps sent over a scripted link. A job's end is read
  # from its own completion event, never waited for by the clock.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Candidates
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.EnrollmentCode
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Move
  alias FermixCore.Home.Moved
  alias FermixCore.Home.Return
  alias FermixCore.Home.Snapshot
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Home.Snapshot.Scheduler
  alias FermixCore.Home.Snapshot.Status
  alias FermixCore.Management.AlwaysOn
  alias FermixCore.Management.AlwaysOn.Input
  alias FermixCore.Management.Copy
  alias FermixCore.Management.Home
  alias FermixCore.Management.HomeSummary
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Router
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TelemetryCapture

  @at ~U[2031-05-04 12:00:00Z]
  @primary %{role: :primary, primary: nil}
  @device %{role: :device, primary: "fermix-general-a3f9"}
  @passphrase "invented-lighthouse-meridian"
  @manual_code "fxenroll1.eyJ2IjoxLCJuYW1lIjoib3duLXNlcnZlciJ9"
  @back_cand "cand-7a3e1c9b5d2f4086"

  setup ctx do
    home = SafeRm.make_tmp_dir!("always_on")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    :ok = Epoch.write(home, 4)
    test = self()

    link =
      start_supervised!(
        {Agent, fn -> %{primary: nil, desktops: [], enrollment: nil} end},
        id: :link
      )

    serializer = :"always_on_#{:erlang.phash2(ctx.test)}"
    start_supervised!({AlwaysOn, name: serializer})

    opts = [
      home: home,
      engine_role: @primary,
      profile: "general",
      now: @at,
      host_os: :linux,
      config: [],
      scheduler: nil,
      disk_usage: fn _home -> {:ok, %{used: 0.42, nearly_full: false}} end,
      link_status: fn -> Agent.get(link, & &1) end,
      jobs: jobs!(ctx),
      open_enrollment: fn _desktop ->
        send(test, :enrollment_opened)
        {:ok, %{code: @manual_code, expires_at: ~U[2031-05-04 12:30:00Z]}}
      end,
      withdraw_enrollment: fn ->
        send(test, :enrollment_withdrawn)
        Agent.update(link, &%{&1 | enrollment: nil})
        :ok
      end,
      free_bytes: fn _dir -> {:ok, 1_099_511_627_776} end,
      version: "9.9.9",
      host: "linux-x86_64",
      restarts_itself: true,
      restart: fn ->
        send(test, :restarted)
        :ok
      end,
      save_recipient: fn recipient ->
        send(test, {:saved, recipient})
        {:ok, %{}}
      end,
      serializer: serializer
    ]

    %{home: home, link: link, opts: opts}
  end

  describe "the input" do
    test "is text or absent, field by field, and anything else is refused without its value" do
      assert {:ok, %Input{recovery_passphrase: @passphrase}} =
               Input.decode(%{"recovery_passphrase" => @passphrase})

      assert Input.decode(nil) == {:ok, %Input{}}

      assert {:error, {:invalid_params, "recovery_passphrase", sentence}} =
               Input.decode(%{"recovery_passphrase" => 42})

      refute sentence =~ "42"

      assert {:error, {:invalid_params, "input", _sentence}} =
               Input.decode(%{"colour" => "invented-secret-value"})

      assert {:error, {:invalid_params, "input", _sentence}} =
               Input.decode(%{"token" => "invented-token"})

      assert {:error, {:invalid_params, "input", _sentence}} =
               Input.decode(["recovery_passphrase"])
    end

    test "never shows the recovery passphrase" do
      {:ok, input} = Input.decode(%{"recovery_passphrase" => @passphrase})

      shown = inspect(input)
      refute shown =~ @passphrase
      assert shown =~ "withheld"
    end
  end

  describe "the request" do
    test "names an action the summary offers and its key; one a surface opens is refused" do
      assert {:ok, %{action: "move_now", key: "k", input: %Input{}}} =
               AlwaysOn.decode(%{"action" => "move_now", "key" => "k"})

      for opened <- ~w(learn_more update) do
        assert {:error, {:invalid_params, "action", sentence}} =
                 AlwaysOn.decode(%{"action" => opened, "key" => "k"})

        assert is_binary(sentence)
      end

      assert {:error, {:invalid_params, "action", _sentence}} =
               AlwaysOn.decode(%{"action" => "set_up", "key" => "k"})

      assert {:error, {:invalid_params, "key", _sentence}} =
               AlwaysOn.decode(%{"action" => "cancel", "key" => String.duplicate("k", 65)})

      assert {:error, {:invalid_params, "key", _sentence}} =
               AlwaysOn.decode(%{"action" => "cancel"})

      assert AlwaysOn.acts() -- HomeSummary.actions() == []
      assert HomeSummary.actions() -- AlwaysOn.acts() == ~w(learn_more update)
    end
  end

  describe "the key rule" do
    test "an action not offered under its key is answered changed in a sentence, and " <>
           "nothing is done",
         ctx do
      request = %{action: "own_server", key: "an-older-key", input: %Input{}}

      assert {:error, :changed, %{"sentence" => sentence} = details} =
               AlwaysOn.act(request, ctx.opts)

      assert Map.keys(details) == ["sentence"]
      assert sentence =~ "changed"
      assert summary(ctx.opts)["state"] == "off"
      refute_received :enrollment_opened
    end

    test "with no serializer running, an act is refused in words", ctx do
      opts = Keyword.put(ctx.opts, :serializer, :"no_such_#{System.unique_integer()}")

      assert {:error, :unavailable, %{"capability" => "home", "sentence" => sentence}} =
               AlwaysOn.act(%{action: "cancel", key: "k", input: %Input{}}, opts)

      assert is_binary(sentence)
    end
  end

  describe "a server of the owner's own" do
    test "opens a manual code, answered once with the command, which carries no code and " <>
           "names the release this computer runs",
         ctx do
      assert {:ok, %{"result" => result, "summary" => summary}} = press(ctx, "own_server")
      assert_received :enrollment_opened

      assert result == %{
               "code" => @manual_code,
               "expires_at" => "2031-05-04T12:30:00Z",
               "command" =>
                 "curl -fsSL https://fermix.ai/always-on | sudo sh -s -- --version " <>
                   FermixCore.BuildInfo.product_version()
             }

      refute summary |> Jason.encode!() |> String.contains?(@manual_code)
    end

    test "Cancel the code releases the manual window", ctx do
      Agent.update(ctx.link, &%{&1 | enrollment: window(:open, nil)})
      assert %{"state" => "connect"} = summary(ctx.opts)

      assert {:ok, %{"summary" => %{"state" => "off"}}} = press(ctx, "cancel")
      assert_received :enrollment_withdrawn
    end
  end

  describe "the move, on the computer that sets up" do
    setup ctx do
      {:ok, held} = Candidates.add(ctx.home, candidate_attrs(), @at)
      Agent.update(ctx.link, &%{&1 | enrollment: window(:used, held.candidate_id)})
      Map.put(ctx, :candidate_id, held.candidate_id)
    end

    test "reviews at the press, sets the recovery key, starts the move and restarts", ctx do
      assert %{"state" => "ready", "action" => move_now} = summary(ctx.opts)
      assert move_now["needs"] == ["new_recovery_passphrase"]

      assert {:ok, %{"result" => %{"move_id" => move_id}}} =
               press(ctx, "move_now", %Input{recovery_passphrase: @passphrase})

      assert is_binary(move_id)
      assert_received {:saved, recipient}
      assert_received :restarted
      assert {:ok, %{"phase" => "requested"}} = Move.read_phase(ctx.home)
      assert {:ok, %{"candidate" => %{candidate_id: candidate_id}}} = Move.read_request(ctx.home)
      assert candidate_id == ctx.candidate_id

      {:ok, again} = Recipient.derive(@passphrase, recipient.salt)
      assert Recipient.matches?(again, recipient)
    end

    # A move back that ended keeps its record (`device/return.json`, with
    # `moved_at`) on the primary it came back to. A move away from that home
    # starts a new tenure: the record describes nothing any more, so the
    # start removes it, and none of the three screens below reads it.
    test "a move away from a home that once moved back draws no move back's progress", ctx do
      :ok = Return.write(ctx.home, ended_return())
      assert {:ok, _answer} = press(ctx, "move_now", %Input{recovery_passphrase: @passphrase})

      moving = summary(Keyword.put(ctx.opts, :engine_role, @device))

      assert moving["state"] == "moving"
      assert get_in(moving, ["detail", "progress"]) == nil
    end

    test "a later move back stopped between its two writes draws the stopped screen, not the " <>
           "ended move back's server",
         ctx do
      :ok = Return.write(ctx.home, ended_return())
      assert {:ok, _answer} = press(ctx, "move_now", %Input{recovery_passphrase: @passphrase})

      # The move done, as the device's boot records it, and this computer a
      # desktop of the new server; then Move back stops after its candidate
      # and before its record.
      :ok = Move.put_phase(ctx.home, "done", %{}, @at)
      :ok = Move.remove_request(ctx.home)
      :ok = DesktopLink.write(ctx.home, desktop_link())
      :ok = Moved.write(ctx.home, %{epoch: 4, moved_at: @at, to: "fermix-general-a3f9"})

      {:ok, state} =
        Candidate.prepare_return(ctx.home, {:return, return_code("fermix-general-a3f9")},
          now: @at,
          role: :device,
          restarts_itself?: true
        )

      enrolled =
        Map.merge(state, %{
          "phase" => "enrolled",
          "candidate_id" => @back_cand,
          "listen_until" => "2031-05-05T12:00:00Z"
        })

      :ok = Candidate.put_state(ctx.home, enrolled, @at)

      stopped = summary(Keyword.put(ctx.opts, :engine_role, @device))

      assert stopped["state"] == "problem"
      assert stopped["detail"]["kind"] == "return_failed"
      assert stopped["action"]["id"] == "cancel"
    end

    test "a later move undone tells nothing of the ended move back", ctx do
      :ok = Return.write(ctx.home, ended_return())
      assert {:ok, _answer} = press(ctx, "move_now", %Input{recovery_passphrase: @passphrase})

      # The move undone: the engine comes back as the primary.
      :ok = Move.put_phase(ctx.home, "aborted", %{}, @at)
      :ok = Move.remove_request(ctx.home)

      assert summary(ctx.opts)["notice"] == nil
    end

    test "with a key set, another passphrase is refused and nothing moves", ctx do
      {:ok, kept} = Recipient.from_passphrase("invented-orchard-meridian-77")
      opts = Keyword.put(ctx.opts, :config, recipient: Recipient.encode(kept))
      ctx = %{ctx | opts: opts}

      assert %{"action" => %{"needs" => ["recovery_passphrase"]}} = summary(opts)

      assert press(ctx, "move_now", %Input{recovery_passphrase: @passphrase}) ==
               {:error, :invalid_params,
                %{
                  "field" => "recovery_passphrase",
                  "sentence" => "That is not the recovery passphrase you set."
                }}

      refute_received :restarted
      refute_received {:saved, _recipient}
      assert Move.read_phase(ctx.home) == :absent
    end

    test "a review that blocks refuses with its sentence, and nothing moves", ctx do
      opts = Keyword.put(ctx.opts, :free_bytes, fn _dir -> {:ok, 1} end)

      assert {:error, :unavailable, %{"capability" => "home", "sentence" => sentence}} =
               press(%{ctx | opts: opts}, "move_now", %Input{recovery_passphrase: @passphrase})

      assert sentence =~ "The move cannot start yet."
      assert sentence =~ "make room first"
      refute_received :restarted
      assert Move.read_phase(ctx.home) == :absent
    end

    test "a warning the screen did not name answers changed, the screen then names it, and " <>
           "nothing moves",
         ctx do
      lockfile = Path.join(ctx.home, "plugins/installed.json")
      File.mkdir_p!(Path.dirname(lockfile))
      File.write!(lockfile, ~s({"invented-plugin": {"version": "0.0.1"}}))
      opts = Keyword.put(ctx.opts, :host, "macos-aarch64")
      before = summary(opts)["action"]

      assert {:error, :changed, %{"sentence" => _sentence}} =
               press(%{ctx | opts: opts}, "move_now", %Input{recovery_passphrase: @passphrase})

      now = summary(opts)["action"]
      assert now["confirm"] =~ "invented-plugin"
      assert now["key"] != before["key"]
      refute_received :restarted
      assert Move.read_phase(ctx.home) == :absent
    end

    test "Try again after an undone move starts it again with the key set", ctx do
      {:ok, kept} = Recipient.from_passphrase(@passphrase)
      opts = Keyword.put(ctx.opts, :config, recipient: Recipient.encode(kept))
      File.mkdir_p!(Move.dir(ctx.home))
      :ok = Move.put_phase(ctx.home, "aborted", %{"candidate" => "fermix-general-a3f9"}, @at)

      assert %{"state" => "undone", "action" => %{"id" => "try_again", "needs" => needs}} =
               summary(opts)

      assert needs == ["recovery_passphrase"]

      assert {:ok, %{"result" => %{"move_id" => _move_id}}} =
               press(%{ctx | opts: opts}, "try_again", %Input{recovery_passphrase: @passphrase})

      assert_received :restarted
      refute_received {:saved, _recipient}
      assert {:ok, %{"phase" => "requested"}} = Move.read_phase(ctx.home)
    end

    test "Check again runs the review again and keeps it", ctx do
      blocked = %{ready: false, items: [%{id: "disk", status: :block, sentence: "Too full."}]}
      :ok = Move.put_review(ctx.home, ctx.candidate_id, blocked, @at)
      assert %{"detail" => %{"kind" => "not_ready"}} = summary(ctx.opts)

      assert {:ok, %{"summary" => %{"state" => "ready"}, "result" => nil}} =
               press(ctx, "check_again")

      assert {:ok, %{ready: true}} = Move.last_review(ctx.home)
    end
  end

  describe "a backup now, on the server" do
    test "runs one through the scheduler", ctx do
      recipient = Recipient.encode(Recipient.generate())
      config = [recipient: recipient, s3_bucket: "invented-bucket"]
      old = DateTime.add(@at, -4 * 86_400, :second)
      :ok = Status.write(ctx.home, Status.record(Status.empty(), "s3", attempt(old)))
      Agent.update(ctx.link, &%{&1 | desktops: [desktop_row()]})
      test = self()

      run = fn _home, _config, _targets, _opts ->
        send(test, :backing_up)
        :not_configured
      end

      scheduler = scheduler!(ctx.home, config, run: run)
      opts = ctx.opts |> Keyword.put(:config, config) |> Keyword.put(:scheduler, scheduler)
      assert %{"detail" => %{"kind" => "backup_old"}} = summary(opts)

      assert {:ok, %{"result" => nil}} = press(%{ctx | opts: opts}, "back_up_now")
      assert_receive :backing_up, 10_000
    end
  end

  describe "on a linked desktop" do
    setup ctx do
      :ok = DesktopLink.write(ctx.home, desktop_link())
      :ok = Moved.write(ctx.home, %{epoch: 4, moved_at: @at, to: "fermix-general-a3f9"})
      script = start_supervised!({Agent, fn -> server_part(:on) end}, id: :script)
      test = self()

      forward = fn %{method: method, params: params}, _opts ->
        send(test, {:forwarded, method, params})
        Agent.get(script, & &1).(method, params)
      end

      Agent.update(ctx.link, &%{&1 | primary: primary(nil)})

      opts =
        ctx.opts
        |> Keyword.put(:engine_role, @device)
        |> Keyword.put(:primary_forward, forward)

      %{ctx | opts: opts} |> Map.put(:script, script)
    end

    test "Back up now is sent to the server", ctx do
      assert %{"state" => "on"} = summary(ctx.opts)

      assert {:ok, %{"result" => nil}} = press(ctx, "back_up_now")
      assert_received {:forwarded, "home.snapshots.run", %{}}
    end
  end

  describe "moving back, on a linked desktop" do
    setup ctx do
      :ok = DesktopLink.write(ctx.home, desktop_link())
      :ok = Moved.write(ctx.home, %{epoch: 4, moved_at: @at, to: "fermix-general-a3f9"})
      script = start_supervised!({Agent, fn -> server_part(:on) end}, id: :script)
      test = self()

      forward = fn %{method: method, params: params}, _opts ->
        send(test, {:forwarded, method, params})
        Agent.get(script, & &1).(method, params)
      end

      Agent.update(ctx.link, &%{&1 | primary: primary(nil)})

      opts =
        ctx.opts
        |> Keyword.merge(
          engine_role: @device,
          primary_forward: forward,
          role: :device,
          restarts_itself?: true,
          start_return: fn home ->
            send(test, {:return_started, home})
            :ok
          end,
          stop_return: fn ->
            send(test, :return_stopped)
            :ok
          end,
          local_return: fn home, copy ->
            send(test, {:restored, home, copy})
            {:ok, %{"restored" => true, "epoch" => 6}}
          end
        )

      %{ctx | opts: opts} |> Map.put(:script, script)
    end

    test "Move back asks the server for a code, writes the candidate and the record, and " <>
           "starts receiving beside the link",
         ctx do
      assert {:ok, %{"summary" => summary, "result" => nil}} = press(ctx, "move_back")

      assert_received {:forwarded, "home.enroll.open", %{}}
      assert_received {:return_started, home} when home == ctx.home

      assert {:ok, %{"kind" => "return", "phase" => "enrolling"} = state} =
               Candidate.read_state(ctx.home)

      assert state["primary"]["name"] == "invented"

      assert Return.read(ctx.home) ==
               {:ok, %{from: "invented", primary_epoch: 5, started_at: @at}}

      assert summary["state"] == "creating"
      assert summary["sentence"] == "Connecting this computer to your server…"
    end

    test "Move back is refused while the server reports a move of its own, and while " <>
           "Fermix would not start again by itself",
         ctx do
      Agent.update(ctx.script, fn script ->
        fn
          "home.status", params ->
            {:ok, part} = script.("home.status", params)

            {:ok,
             Map.put(part, "move", %{
               "phase" => "streaming",
               "candidate" => "x",
               "sentence" => "."
             })}

          method, params ->
            script.(method, params)
        end
      end)

      assert {:error, :unavailable, %{"sentence" => sentence}} = press(ctx, "move_back")
      assert sentence == "Your server is moving Fermix right now, so move back once that is done."
      refute_received {:forwarded, "home.enroll.open", _params}

      Agent.update(ctx.script, fn _script -> server_part(:on) end)
      terminal = Keyword.put(ctx.opts, :restarts_itself?, false)

      assert {:error, :unavailable, %{"sentence" => sentence}} =
               press(%{ctx | opts: terminal}, "move_back")

      assert sentence =~ "Install it as a service first."
      refute Candidate.present?(ctx.home)
      assert Return.read(ctx.home) == :absent
      refute_received {:return_started, _home}
    end

    test "two presses of Move back at once: the first runs, the second sees what it changed",
         ctx do
      key = offered!(summary(ctx.opts), "move_back")["key"]
      request = %{action: "move_back", key: key, input: %Input{}}

      answers =
        [request, request]
        |> Enum.map(fn request -> Task.async(fn -> AlwaysOn.act(request, ctx.opts) end) end)
        |> Enum.map(&Task.await(&1, 15_000))

      assert [{:error, :changed, %{"sentence" => _}}, {:ok, %{"summary" => after_first}}] =
               Enum.sort_by(answers, &elem(&1, 0))

      assert after_first["state"] == "creating"
      assert_received {:forwarded, "home.enroll.open", %{}}
      refute_received {:forwarded, "home.enroll.open", %{}}
    end

    test "Move now sends the move to the server and records it in the return", ctx do
      enrolled!(ctx)
      assert %{"state" => "ready", "action" => %{"id" => "move_now"}} = summary(ctx.opts)
      script = ctx.script

      # The server takes the move: its own part says so from then on.
      Agent.update(script, fn on ->
        fn
          "home.move.start", _params ->
            Agent.update(script, fn _on -> server_moving(on) end)
            {:ok, %{"move_id" => "mv-0002"}}

          method, params ->
            on.(method, params)
        end
      end)

      assert {:ok, %{"result" => %{"move_id" => "mv-0002"}, "summary" => after_move}} =
               press(ctx, "move_now", %Input{recovery_passphrase: @passphrase})

      assert_received {:forwarded, "home.move.start", params}

      assert params == %{
               "candidate_id" => @back_cand,
               "recovery_passphrase" => @passphrase,
               "keep_as_desktop" => false
             }

      assert {:ok, %{move_started_at: @at, candidate_id: @back_cand, move_id: "mv-0002"}} =
               Return.read(ctx.home)

      assert after_move["state"] == "moving"
      refute "cancel" in Enum.map(HomeSummary.offered(after_move), & &1["id"])
    end

    # HR-1 (the move back's TLA spec): the server restarts into the move as
    # it answers, so the start is recorded before the request leaves; a
    # stop at any point after that never leaves Cancel offered while the
    # server moves.
    test "Move now records the start before it sends the move", ctx do
      enrolled!(ctx)
      home = ctx.home
      test = self()

      Agent.update(ctx.script, fn script ->
        fn
          "home.move.start", _params ->
            send(test, {:recorded_when_sent, Return.read(home)})
            {:ok, %{"move_id" => "mv-0003"}}

          method, params ->
            script.(method, params)
        end
      end)

      assert {:ok, _answer} = press(ctx, "move_now", %Input{recovery_passphrase: @passphrase})

      assert_received {:recorded_when_sent,
                       {:ok, %{move_started_at: @at, candidate_id: @back_cand} = sent}}

      refute Map.has_key?(sent, :move_id)
    end

    test "a move the server refused, or that never left, forgets its start; one unconfirmed " <>
           "keeps it",
         ctx do
      enrolled!(ctx)

      refusal = %{
        "capability" => "home",
        "sentence" => "That is not the recovery passphrase you set."
      }

      down = %{"sentence" => "The server is unreachable."}

      for {answer, kept?} <- [
            {{:error, :invalid_params, refusal}, false},
            {{:error, :primary_unreachable, down}, false},
            {{:error, :unconfirmed, %{"method" => "home.move.start", "sentence" => "."}}, true}
          ] do
        Agent.update(ctx.script, fn _script ->
          fn
            "home.move.start", _params -> answer
            method, params -> server_part(:on).(method, params)
          end
        end)

        assert {:error, _code, _details} =
                 press(ctx, "move_now", %Input{recovery_passphrase: @passphrase})

        {:ok, record} = Return.read(ctx.home)
        assert Map.has_key?(record, :move_started_at) == kept?, inspect(answer)
        refute Map.has_key?(record, :move_id)
        if kept?, do: :ok, else: refute(Map.has_key?(record, :candidate_id))
      end
    end

    test "Cancel stops receiving, closes the code on the server and forgets the move back",
         ctx do
      enrolled!(ctx)

      assert {:ok, %{"summary" => after_cancel}} = press(ctx, "cancel")

      assert_received :return_stopped
      assert_received {:forwarded, "home.enroll.withdraw", %{}}
      refute Candidate.present?(ctx.home)
      assert Return.read(ctx.home) == :absent
      assert after_cancel["state"] == "on"
    end

    # HR-2a (the move back's TLA spec): Cancel forgets the record before the
    # candidate, so a stop between the two leaves a candidate alone, which
    # the screen offers to Cancel; never a started record alone.
    test "Cancel forgets the record before the candidate", ctx do
      enrolled!(ctx)
      key = offered!(summary(ctx.opts), "cancel")["key"]
      # The candidate cannot be removed: the home's own folder is read-only.
      File.chmod!(ctx.home, 0o500)
      on_exit(fn -> File.chmod(ctx.home, 0o700) end)

      assert {:error, :unavailable, _details} =
               AlwaysOn.act(%{action: "cancel", key: key, input: %Input{}}, ctx.opts)

      File.chmod!(ctx.home, 0o700)
      assert Return.read(ctx.home) == :absent
      assert Candidate.present?(ctx.home)
      assert "cancel" in Enum.map(HomeSummary.offered(summary(ctx.opts)), & &1["id"])
    end

    test "a started record left alone, the server the primary with no move, is cancelled",
         ctx do
      :ok =
        Return.write(ctx.home, %{
          from: "fermix-general-a3f9",
          started_at: @at,
          move_started_at: @at,
          candidate_id: @back_cand
        })

      assert %{"state" => "problem", "detail" => %{"kind" => "return_failed"}} = summary(ctx.opts)
      assert {:ok, %{"summary" => after_cancel}} = press(ctx, "cancel")
      assert Return.read(ctx.home) == :absent
      assert after_cancel["state"] == "on"
    end

    test "Cancel goes on when the server cannot be reached: its code lapses by itself", ctx do
      enrolled!(ctx)

      Agent.update(ctx.script, fn script ->
        fn
          "home.enroll.withdraw", _params -> {:error, :primary_unreachable, %{"sentence" => "."}}
          method, params -> script.(method, params)
        end
      end)

      assert {:ok, _answer} = press(ctx, "cancel")
      refute Candidate.present?(ctx.home)
    end

    # The owner deleted or stopped the server, as the confirm asks: Fermix
    # deletes nothing and restores the copy in a job of its own, which the
    # screen says runs from the press on.
    test "Restore here restores the newest copy the passphrase opens in a job of its own, " <>
           "and deletes nothing",
         ctx do
      copy = copy!(ctx)
      server = "fermix-general-a3f9"
      Agent.update(ctx.link, &%{&1 | primary: primary(11 * 60_000)})
      assert %{"detail" => %{"kind" => "cannot_reach"}} = summary(ctx.opts)
      test = self()

      held =
        Keyword.put(ctx.opts, :local_return, fn home, chosen ->
          send(test, {:restoring, self(), home, chosen})
          receive do: (:go -> {:ok, %{"restored" => true, "epoch" => 6}})
        end)

      assert {:ok, %{"summary" => running, "result" => nil}} =
               press(%{ctx | opts: held}, "restore_here", %Input{recovery_passphrase: @passphrase})

      assert running["state"] == "moving"

      assert running["sentence"] ==
               "Restoring Fermix on this computer from its backup. Messages wait until it is done."

      assert_receive {:restoring, run, home, chosen}, 10_000
      assert home == ctx.home
      assert %{name: name, from: ^server, pair: %{secret_key: _key}} = chosen
      assert name == Path.basename(copy)
      assert [%{"kind" => "home_restore", "status" => "running"}] = jobs(ctx)
      assert {:ok, %{restore_requested: ^name}} = Return.read(ctx.home)

      send(run, :go)
      settle!(ctx)

      assert [%{"kind" => "home_restore", "status" => "completed"}] = jobs(ctx)
      assert Return.read(ctx.home) == {:ok, %{from: server, started_at: @at}}
    end

    # A move back that ended keeps its record (`moved_at`) after the home moves
    # away again. Restore here starts a record of its own: merged into that
    # one, the restored primary's boot would keep the old `moved_at` and raise
    # the old move back's notice again.
    test "Restore here over a move back that already ended keeps a record of its own", ctx do
      copy = copy!(ctx)
      server = "fermix-general-a3f9"

      :ok =
        Return.write(ctx.home, %{
          from: "fermix-orchard-old",
          primary_epoch: 2,
          started_at: ~U[2031-04-01 09:00:00Z],
          move_started_at: ~U[2031-04-01 09:05:00Z],
          moved_at: ~U[2031-04-01 09:20:00Z],
          epoch: 3
        })

      Agent.update(ctx.link, &%{&1 | primary: primary(11 * 60_000)})
      test = self()

      held =
        Keyword.put(ctx.opts, :local_return, fn _home, _chosen ->
          send(test, {:restoring, self()})
          receive do: (:go -> {:ok, %{"restored" => true, "epoch" => 6}})
        end)

      assert {:ok, _answer} =
               press(%{ctx | opts: held}, "restore_here", %Input{recovery_passphrase: @passphrase})

      assert_receive {:restoring, run}, 10_000
      name = Path.basename(copy)

      assert Return.read(ctx.home) ==
               {:ok, %{from: server, started_at: @at, restore_requested: name}}

      send(run, :go)
      settle!(ctx)
    end

    # A restore job stopped from outside (past its budget, or cancelled) runs
    # no code of its own after the stop; its ending settles what it left as
    # the next start would: a copy not yet being put in place goes, and one
    # being put in place is finished by a restart.
    test "a restore job stopped before its copy was being put in place leaves nothing behind " <>
           "and offers Restore here again",
         ctx do
      copy!(ctx)
      Agent.update(ctx.link, &%{&1 | primary: primary(11 * 60_000)})
      test = self()

      left =
        ctx.opts
        |> Keyword.put(:local_return, fn home, chosen ->
          {:ok, _state} =
            Candidate.prepare_return(home, {:local, chosen.from},
              now: @at,
              role: :device,
              restarts_itself?: true
            )

          send(test, {:restoring, self()})
          receive do: (:never -> :ok)
        end)
        |> Keyword.put(:restart, fn ->
          send(test, :restarted)
          :ok
        end)

      assert {:ok, _answer} =
               press(%{ctx | opts: left}, "restore_here", %Input{recovery_passphrase: @passphrase})

      assert_receive {:restoring, _run}, 10_000
      assert summary(ctx.opts)["state"] == "moving"

      [%{"job_id" => id}] = jobs(ctx)
      assert {:ok, %{"status" => "cancelled"}} = Jobs.cancel(id, ctx.opts[:jobs])

      refute Candidate.present?(ctx.home)
      refute_received :restarted
      assert "restore_here" in Enum.map(HomeSummary.offered(summary(ctx.opts)), & &1["id"])
    end

    test "a restore job stopped while its copy was being put in place restarts the engine, " <>
           "whose start finishes it",
         ctx do
      copy!(ctx)
      Agent.update(ctx.link, &%{&1 | primary: primary(11 * 60_000)})
      test = self()

      left =
        ctx.opts
        |> Keyword.put(:local_return, fn home, chosen ->
          {:ok, state} =
            Candidate.prepare_return(home, {:local, chosen.from},
              now: @at,
              role: :device,
              restarts_itself?: true
            )

          :ok = Candidate.put_state(home, Map.put(state, "phase", "activating"), @at)
          send(test, {:restoring, self()})
          receive do: (:never -> :ok)
        end)
        |> Keyword.put(:restart, fn ->
          send(test, :restarted)
          :ok
        end)

      assert {:ok, _answer} =
               press(%{ctx | opts: left}, "restore_here", %Input{recovery_passphrase: @passphrase})

      assert_receive {:restoring, _run}, 10_000
      [%{"job_id" => id}] = jobs(ctx)
      assert {:ok, %{"status" => "cancelled"}} = Jobs.cancel(id, ctx.opts[:jobs])

      assert_received :restarted
      assert {:ok, %{"kind" => "local", "phase" => "activating"}} = Candidate.read_state(ctx.home)
    end

    # The job family refuses a start busy for two reasons: a restore already
    # runs, or the family runs as many jobs as it takes, of other kinds. The
    # sentence says which.
    test "a restore refused busy says a restore runs only when one does", ctx do
      copy!(ctx)
      Agent.update(ctx.link, &%{&1 | primary: primary(11 * 60_000)})
      test = self()

      blocking = fn _id, _report ->
        send(test, {:blocking, self()})
        receive do: (:go -> {:ok, %{}})
      end

      {:ok, _view} =
        Jobs.start(:home_restore, ctx.opts[:jobs] ++ [name: "restore_here", run: blocking])

      assert_receive {:blocking, restore}, 10_000

      assert press(ctx, "restore_here", %Input{recovery_passphrase: @passphrase}) ==
               {:error, :unavailable,
                %{
                  "capability" => "home",
                  "sentence" =>
                    "Fermix is already restoring its backup here, and it finishes by itself."
                }}

      send(restore, :go)
      settle!(ctx)

      runs =
        for index <- 1..Jobs.max_concurrent() do
          {:ok, _view} =
            Jobs.start(:plugin_check, ctx.opts[:jobs] ++ [name: "check-#{index}", run: blocking])

          assert_receive {:blocking, run}, 10_000
          run
        end

      assert {:error, :unavailable, %{"sentence" => sentence}} =
               press(ctx, "restore_here", %Input{recovery_passphrase: @passphrase})

      assert sentence == "Fermix is busy with other work right now, so try again in a minute."
      assert Copy.violations(sentence, :prose) == []
      refute match?({:ok, %{restore_requested: _copy}}, Return.read(ctx.home))

      for run <- runs, do: send(run, :go)
      settle!(ctx)
    end

    test "a restore that stopped before its copy was in place offers Restore here again", ctx do
      copy!(ctx)
      Agent.update(ctx.link, &%{&1 | primary: primary(11 * 60_000)})
      sentence = "The backup on this computer could not be restored here; Fermix's log says why."

      refused =
        Keyword.put(ctx.opts, :local_return, fn _home, _copy -> {:error, {:refused, sentence}} end)

      assert {:ok, _answer} =
               press(%{ctx | opts: refused}, "restore_here", %Input{
                 recovery_passphrase: @passphrase
               })

      settle!(ctx)

      assert [%{"kind" => "home_restore", "status" => "failed"}] = jobs(ctx)
      assert "restore_here" in Enum.map(HomeSummary.offered(summary(ctx.opts)), & &1["id"])
    end

    test "Restore here with a passphrase that opens no copy deletes nothing", ctx do
      copy!(ctx)
      Agent.update(ctx.link, &%{&1 | primary: primary(11 * 60_000)})

      assert {:error, :invalid_params, %{"field" => "recovery_passphrase", "sentence" => said}} =
               press(ctx, "restore_here", %Input{recovery_passphrase: "a-wrong-passphrase-here"})

      assert said == "That is not the recovery passphrase you set."
      assert jobs(ctx) == []
      assert Return.read(ctx.home) == :absent
    end
  end

  # `changed` says only that the screen moved on (Always On setup §3.4, the
  # lead's call on the error details' bound): the surface reads home.status
  # again, as it does after any act, so no refusal carries a summary.
  describe "the changed refusal" do
    test "holds only its sentence, on the wire too", ctx do
      params = %{"action" => "own_server", "key" => "an-older-key"}

      assert {:error, :changed, details} = route("home.act", params, ctx)

      assert details == %{
               "sentence" => "Always On changed since this was shown, so look at it again."
             }

      assert {:ok, %{"error" => %{"details" => ^details}}} =
               Protocol.respond("req-1", {:error, :changed, details})
    end
  end

  # The wire (§3.4, §3.5): `home.act` decodes its params at the router, and
  # the server's steps answer only a desktop's forward.
  describe "through the router" do
    test "home.act runs the step and answers the summary after it", ctx do
      key = offered!(summary(ctx.opts), "own_server")["key"]
      params = %{"action" => "own_server", "key" => key}

      assert {:ok, %{"summary" => %{"state" => "off"}, "result" => %{"code" => @manual_code}}} =
               route("home.act", params, ctx)
    end

    test "home.act's params are its own, and what a surface opens is refused", ctx do
      assert {:error, :invalid_params, %{"field" => "colour"}} =
               route("home.act", %{"action" => "cancel", "key" => "k", "colour" => 1}, ctx)

      assert {:error, :invalid_params, %{"field" => "action", "sentence" => _sentence}} =
               route("home.act", %{"action" => "learn_more", "key" => "k"}, ctx)

      assert {:error, :invalid_params, %{"field" => "input", "sentence" => _sentence}} =
               route(
                 "home.act",
                 %{"action" => "cancel", "key" => "k", "input" => %{"x" => "y"}},
                 ctx
               )
    end

    test "a candidate refuses home.act by name", ctx do
      candidate = %{role: :candidate, primary: nil}

      assert {:error, :unavailable, %{"capability" => "candidate", "sentence" => sentence}} =
               route("home.act", %{"action" => "cancel", "key" => "k"}, ctx,
                 engine_role: candidate
               )

      assert sentence =~ "candidate primary"
    end

    test "a server step answers only a desktop's forward", ctx do
      withdraw = fn ->
        send(self(), :withdrawn)
        :ok
      end

      opts = [operation_opts: [home: [home: ctx.home, withdraw_enrollment: withdraw]]]

      assert {:error, :unavailable, %{"method" => "home.enroll.withdraw", "sentence" => _}} =
               route("home.enroll.withdraw", %{}, ctx, opts)

      refute_received :withdrawn

      assert {:ok, %{"withdrawn" => true}} =
               route("home.enroll.withdraw", %{}, ctx, [actor: {:desktop, "desk-1"}] ++ opts)

      assert_received :withdrawn
    end
  end

  defp route(method, params, ctx, extra \\ []) do
    request = %{request_id: "req-1", protocol_version: 2, method: method, params: params}
    opts = Keyword.merge([engine_role: @primary, operation_opts: [always_on: ctx.opts]], extra)
    Router.route(request, opts)
  end

  # -- pressing ----------------------------------------------------------------

  # What a surface does: read the summary, find the action it drew, and send
  # its id and key with what it collected.
  defp press(ctx, id, input \\ %Input{}) do
    key = offered!(summary(ctx.opts), id)["key"]
    AlwaysOn.act(%{action: id, key: key, input: input}, ctx.opts)
  end

  defp summary(opts), do: opts |> Home.summary_facts() |> HomeSummary.summary()

  defp offered!(summary, id) do
    offered = HomeSummary.offered(summary)

    Enum.find(offered, &(&1["id"] == id)) ||
      flunk("#{summary["state"]} offers no #{id}: #{inspect(Enum.map(offered, & &1["id"]))}")
  end

  # -- the world ---------------------------------------------------------------

  defp window(state, candidate_id) do
    %{state: state, expires_at: ~U[2031-05-05 12:00:00Z], candidate_id: candidate_id}
  end

  # The server's own `home.status`, and its answers to the steps sent to it.
  defp server_part(which) do
    part = server_status(which)

    fn
      "home.status", _params ->
        {:ok, part}

      "home.snapshots.run", _params ->
        {:ok, %{"started" => true, "snapshots" => %{}}}

      "home.enroll.open", %{} ->
        {:ok, %{"code" => return_code(), "expires_at" => "2031-05-04T12:30:00Z"}}

      "home.enroll.withdraw", _params ->
        {:ok, %{"withdrawn" => true}}
    end
  end

  # The server's part once it took a move: its move requested.
  defp server_moving(script) do
    fn
      "home.status", params ->
        {:ok, part} = script.("home.status", params)

        {:ok,
         Map.put(part, "move", %{"phase" => "requested", "candidate" => "x", "sentence" => "."})}

      method, params ->
        script.(method, params)
    end
  end

  # The copied code the server opens for a desktop moving back.
  defp return_code(name \\ "invented") do
    {:ok, code} =
      EnrollmentCode.encode(%{
        secret: :binary.copy(<<9>>, 32),
        gateway_pk: :binary.copy(<<3>>, 32),
        node_id: String.duplicate("c4", 32),
        relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
        relays_rev: String.duplicate("a1", 8),
        name: name,
        expires_at: ~U[2031-05-04 12:30:00Z]
      })

    code
  end

  defp server_status(:on) do
    %{
      "role" => "primary",
      "version" => "9.9.9",
      "disk" => %{"used" => 0.4, "nearly_full" => false},
      "snapshots" => %{
        "targets" => [
          %{"label" => "S3", "last_verified" => %{"at" => "2031-05-04T10:00:00Z"}}
        ]
      },
      "enrollment" => nil,
      "candidates" => []
    }
  end

  defp primary(down_ms) do
    %{
      name: "fermix-general-a3f9",
      connected: down_ms == nil,
      status: if(down_ms, do: :unreachable, else: :connected),
      since: if(down_ms, do: nil, else: @at),
      epoch: 5,
      sentence: "The link's own words.",
      down_ms: down_ms,
      down_at: if(down_ms, do: DateTime.add(@at, -down_ms, :millisecond))
    }
  end

  # The record a move back that ended leaves on the primary it came back to.
  defp ended_return do
    %{
      from: "fermix-orchard-old",
      primary_epoch: 2,
      started_at: ~U[2031-04-01 09:00:00Z],
      move_started_at: ~U[2031-04-01 09:05:00Z],
      moved_at: ~U[2031-04-01 09:20:00Z],
      epoch: 3
    }
  end

  defp desktop_link do
    %{
      device_id: "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e",
      primary: %{
        name: "fermix-general-a3f9",
        gateway_pk: :binary.copy(<<3>>, 32),
        node_id: String.duplicate("c4", 32),
        relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
        relays_rev: String.duplicate("a1", 8)
      },
      epoch: 5
    }
  end

  defp desktop_row,
    do: %{
      device_id: "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e",
      name: "invented-mac",
      connected: true
    }

  defp candidate_attrs do
    %{
      name: "fermix-general-a3f9",
      os: "linux",
      arch: "x86_64",
      version: "9.9.9",
      node_id: String.duplicate("b7", 32),
      relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
      noise_pk: :binary.copy(<<1>>, 32),
      recipient: :binary.copy(<<2>>, 32),
      snapshots: nil
    }
  end

  defp attempt(at) do
    %{
      at: at,
      result: :verified,
      name: "20310430T120000Z-e4.fxsnap",
      epoch: 4,
      size: 48_211,
      sha256: String.duplicate("c", 64),
      location: "s3://invented-bucket/fermix/general/20310430T120000Z-e4.fxsnap",
      error: nil
    }
  end

  defp scheduler!(home, config, extra) do
    name = :"always_on_scheduler_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Scheduler,
       [
         name: name,
         home: home,
         config: fn -> config end,
         now: fn -> @at end,
         timer: fn _message, _delay -> make_ref() end
       ] ++ extra}
    )

    name
  end

  # -- moving back -------------------------------------------------------------

  # This desktop's candidate for a move back, held by the server, and the
  # record of the return, as Move back and the candidate's enrolment leave
  # them.
  defp enrolled!(ctx) do
    {:ok, state} =
      Candidate.prepare_return(ctx.home, {:return, return_code("fermix-general-a3f9")},
        now: @at,
        role: :device,
        restarts_itself?: true
      )

    enrolled =
      Map.merge(state, %{
        "phase" => "enrolled",
        "candidate_id" => @back_cand,
        "listen_until" => "2031-05-05T12:00:00Z"
      })

    :ok = Candidate.put_state(ctx.home, enrolled, @at)

    :ok =
      Return.write(ctx.home, %{
        from: "fermix-general-a3f9",
        started_at: @at,
        primary_epoch: 5
      })
  end

  # A copy of the server's snapshots this desktop keeps, written for the
  # owner's recovery passphrase.
  defp copy!(ctx) do
    server = Path.join(ctx.home, "invented-server")
    File.mkdir_p!(server)
    File.write!(Path.join(server, "config.toml"), "[fermix_core.engine]\nrole = \"primary\"\n")
    :ok = Epoch.write(server, 5)
    {:ok, pair} = Recipient.from_passphrase(@passphrase)
    File.mkdir_p!(Path.join(ctx.home, "snapshots"))
    path = Path.join([ctx.home, "snapshots", "20310504T093000Z-e5.fxsnap"])

    {:ok, _written} =
      Snapshot.write(server, Recipient.public(pair), path,
        host: "linux-x86_64",
        now: fn -> ~U[2031-05-04 09:30:00Z] end
      )

    SafeRm.rm_rf!(server)
    path
  end

  # -- jobs --------------------------------------------------------------------

  defp jobs!(ctx) do
    tasks = :"always_on_tasks_#{:erlang.phash2(ctx.test)}"
    start_supervised!({Task.Supervisor, name: tasks}, id: tasks)
    name = :"always_on_jobs_#{:erlang.phash2(ctx.test)}"
    start_supervised!({Jobs, name: name, task_supervisor: tasks})
    [server: name]
  end

  defp jobs(ctx) do
    {:ok, views} = Jobs.list(ctx.opts[:jobs])
    views
  end

  # Every job of the family has ended, each read from its completion event:
  # a step's job, and the one a cancel starts after it, at most.
  defp settle!(ctx, rounds \\ 3)

  defp settle!(_ctx, 0), do: flunk("a job of the family still runs after three rounds")

  defp settle!(ctx, rounds) do
    for %{"status" => "running"} = job <- jobs(ctx), do: finished(job, ctx.opts[:jobs])
    if Enum.any?(jobs(ctx), &(&1["status"] == "running")), do: settle!(ctx, rounds - 1)
    :ok
  end

  defp finished(%{"job_id" => id}, jobs) do
    TelemetryCapture.attach([[:fermix, :management_job, :complete]], session_id: id)

    case Jobs.get(id, jobs) do
      {:ok, %{"status" => "running"}} ->
        assert_receive {:telemetry, _event, _measurements, %{session_id: ^id}}, 10_000

      {:ok, _view} ->
        :ok
    end
  end
end
