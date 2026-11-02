defmodule FermixCore.Management.AlwaysOnTest do
  # Always On setup §3.4, §4: every step a surface asks for is one `act/2`,
  # run by the engine under one serializer, against the invented provider
  # (`FermixTestSupport.FakeCloudProvider`) and a home of the test's own: the
  # sequence, the ledger and the summary after it, every refusal, and on a
  # linked desktop the server's steps sent over a scripted link. A job's end
  # is read from its own completion event, never waited for by the clock.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Candidates
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Move
  alias FermixCore.Home.Moved
  alias FermixCore.Home.Provision.Driver
  alias FermixCore.Home.Provision.Ledger
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Home.Snapshot.Scheduler
  alias FermixCore.Home.Snapshot.Status
  alias FermixCore.Management.AlwaysOn
  alias FermixCore.Management.AlwaysOn.Input
  alias FermixCore.Management.Home
  alias FermixCore.Management.HomeSummary
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Provision
  alias FermixCore.Management.Router
  alias FermixTestSupport.FakeCloudProvider
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TelemetryCapture

  @at ~U[2031-05-04 12:00:00Z]
  @primary %{role: :primary, primary: nil}
  @device %{role: :device, primary: "fermix-general-a3f9"}
  @passphrase "invented-lighthouse-meridian"
  @code "fxenroll1.eyJ2IjoxLCJuYW1lIjoiaW52ZW50ZWQifQ"
  @manual_code "fxenroll1.eyJ2IjoxLCJuYW1lIjoib3duLXNlcnZlciJ9"
  @server_code "fxenroll1.eyJ2IjoxLCJuYW1lIjoib2xkLXNlcnZlciJ9"
  @recommended %{type: "small-4", location: "osl1", profile: "general"}
  # The offer the owner was shown and chose: a create always names one.
  @choice %Input{type: "small-4", location: "osl1"}

  setup ctx do
    home = SafeRm.make_tmp_dir!("always_on")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    :ok = Epoch.write(home, 4)
    world = FakeCloudProvider.start!()
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
      providers: [FakeCloudProvider],
      provider_opts: provider_opts(world),
      jobs: jobs!(ctx),
      open_code: fn ->
        send(test, :code_opened)
        {:ok, @code}
      end,
      withdraw_code: fn ->
        send(test, :code_withdrawn)
        :ok
      end,
      open_enrollment: fn kind ->
        send(test, {:enrollment_opened, kind})
        {:ok, %{code: @manual_code, expires_at: ~U[2031-05-04 12:30:00Z]}}
      end,
      withdraw_enrollment: fn kind ->
        send(test, {:enrollment_withdrawn, kind})
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

    %{home: home, world: world, link: link, opts: opts}
  end

  describe "the input" do
    test "is text or absent, field by field, and anything else is refused without its value" do
      assert {:ok, %Input{token: "invented-token", provider: nil}} =
               Input.decode(%{"token" => "invented-token"})

      assert Input.decode(nil) == {:ok, %Input{}}

      assert {:error, {:invalid_params, "recovery_passphrase", sentence}} =
               Input.decode(%{"recovery_passphrase" => 42})

      refute sentence =~ "42"

      assert {:error, {:invalid_params, "input", _sentence}} =
               Input.decode(%{"colour" => "invented-secret-value"})

      assert {:error, {:invalid_params, "input", _sentence}} = Input.decode(["token"])
    end

    test "never shows the token or the recovery passphrase" do
      {:ok, input} =
        Input.decode(%{
          "token" => "invented-token-5f2c8e1a",
          "recovery_passphrase" => @passphrase,
          "provider" => "nimbus"
        })

      shown = inspect(input)
      refute shown =~ "invented-token-5f2c8e1a"
      refute shown =~ @passphrase
      assert shown =~ "nimbus"
      assert shown =~ "withheld"
    end
  end

  describe "the request" do
    test "names an action the summary offers and its key; one a surface opens is refused" do
      assert {:ok, %{action: "create_server", key: "k", input: %Input{}}} =
               AlwaysOn.decode(%{"action" => "create_server", "key" => "k"})

      for opened <- ~w(learn_more open_console update) do
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
      assert HomeSummary.actions() -- AlwaysOn.acts() == ~w(learn_more open_console update)
    end
  end

  describe "the key rule" do
    test "an action not offered under its key is answered changed in a sentence, and " <>
           "nothing is done",
         ctx do
      request = %{action: "paste_token", key: "an-older-key", input: token_input()}

      assert {:error, :changed, %{"sentence" => sentence} = details} =
               AlwaysOn.act(request, ctx.opts)

      assert Map.keys(details) == ["sentence"]
      assert sentence =~ "changed"
      assert summary(ctx.opts)["state"] == "off"
      refute File.exists?(Ledger.path(ctx.home, "nimbus"))
    end

    test "two presses of one key at once: the first runs, the second sees what it changed",
         ctx do
      connect!(ctx)
      key = offered!(summary(ctx.opts), "create_server")["key"]
      request = %{action: "create_server", key: key, input: @choice}

      answers =
        [request, request]
        |> Enum.map(fn request -> Task.async(fn -> AlwaysOn.act(request, ctx.opts) end) end)
        |> Enum.map(&Task.await(&1, 15_000))

      assert [{:error, :changed, %{"sentence" => _}}, {:ok, %{"summary" => after_first}}] =
               Enum.sort_by(answers, &elem(&1, 0))

      assert after_first["state"] == "creating"

      settle!(ctx)
      assert length(jobs(ctx)) == 1
    end

    test "with no serializer running, an act is refused in words", ctx do
      opts = Keyword.put(ctx.opts, :serializer, :"no_such_#{System.unique_integer()}")

      assert {:error, :unavailable, %{"capability" => "home", "sentence" => sentence}} =
               AlwaysOn.act(%{action: "cancel", key: "k", input: %Input{}}, opts)

      assert is_binary(sentence)
    end
  end

  describe "the token" do
    test "is checked and kept, and the screen after it is the choice", ctx do
      assert {:ok, %{"summary" => summary, "result" => nil}} =
               press(ctx, "paste_token", token_input())

      assert summary["state"] == "choose"
      assert {:ok, %{token: token}} = Ledger.read(ctx.home, "nimbus")
      assert token == FakeCloudProvider.token()
    end

    test "one the provider refuses is refused on the token, and kept nowhere", ctx do
      input = %Input{token: "invented-wrong-token-00000"}

      assert {:error, :invalid_params, %{"field" => "token", "sentence" => sentence}} =
               press(ctx, "paste_token", input)

      assert sentence =~ "Nimbus"
      refute File.exists?(Ledger.path(ctx.home, "nimbus"))
    end
  end

  describe "creating the server" do
    setup ctx, do: connect!(ctx)

    test "names the step before the job, so the answer already says it runs, and the " <>
           "job's end clears it",
         ctx do
      assert {:ok, %{"summary" => summary, "result" => nil}} =
               press(ctx, "create_server", @choice)

      assert summary["state"] == "creating"
      assert summary["sentence"] == "Starting your server…"
      assert offered!(summary, "cancel")

      settle!(ctx)
      assert {:ok, %{server: server, action: nil}} = Ledger.read(ctx.home, "nimbus")
      assert %{status: :created, type: "small-4", location: "osl1"} = server
      assert server.total_monthly == "12.00"
    end

    test "takes the size and place chosen", ctx do
      input = %Input{type: "large-8", location: "osl1"}
      assert {:ok, _answer} = press(ctx, "create_server", input)

      settle!(ctx)

      assert {:ok, %{server: %{type: "large-8", location: "osl1"}}} =
               Ledger.read(ctx.home, "nimbus")
    end

    test "with no size and place chosen it is refused on the type, and leaves no step behind",
         ctx do
      assert {:error, :invalid_params, %{"field" => "type", "sentence" => _sentence}} =
               press(ctx, "create_server")

      assert {:ok, %{action: nil, server: nil}} = Ledger.read(ctx.home, "nimbus")
      assert jobs(ctx) == []
    end

    test "keeps the size and place chosen on the step from the press on", ctx do
      test = self()

      # The job holds before its first read of the provider.
      spy = fn
        :catalog ->
          send(test, {:holding, self()})

          receive do
            :go -> :ok
          end

        _other ->
          :ok
      end

      held = %{ctx | opts: put_provider_opt(ctx.opts, :spy, spy)}

      assert {:ok, _answer} =
               press(held, "create_server", %Input{type: "large-8", location: "osl1"})

      assert_receive {:holding, run}, 10_000

      assert {:ok, %{action: %{kind: "create", type: "large-8", location: "osl1"}}} =
               Ledger.read(ctx.home, "nimbus")

      send(run, :go)
      settle!(held)
    end

    test "a size with no place is refused on the place, and leaves no step behind", ctx do
      assert {:error, :invalid_params, %{"field" => "location", "sentence" => _sentence}} =
               press(ctx, "create_server", %Input{type: "large-8"})

      assert {:ok, %{action: nil, server: nil}} = Ledger.read(ctx.home, "nimbus")
      assert jobs(ctx) == []
      assert summary(ctx.opts)["state"] == "choose"
    end

    test "meeting a read of the provider that runs is refused busy in words, and leaves no " <>
           "step behind",
         ctx do
      hold_reconcile!(ctx)

      assert {:error, :unavailable, %{"capability" => "home", "sentence" => sentence}} =
               press(ctx, "create_server", @choice)

      assert sentence =~ "server"
      assert {:ok, %{action: nil}} = Ledger.read(ctx.home, "nimbus")
    end

    test "in the next place, after the first had none, with the size the failure kept", ctx do
      failure = %{
        reason: "unavailable",
        sentence: "Oslo has no Small 4 right now.",
        next_location: "lis1",
        at: @at,
        action: "create",
        type: "small-4",
        location: "osl1"
      }

      {:ok, _ledger} = Ledger.update(ctx.home, "nimbus", &{:ok, Ledger.put_failure(&1, failure)})
      assert %{"detail" => %{"kind" => "no_capacity"}} = summary(ctx.opts)

      assert {:ok, %{"summary" => %{"state" => "creating"}}} = press(ctx, "create_in")

      settle!(ctx)

      assert {:ok, %{server: %{type: "small-4", location: "lis1"}, failure: nil}} =
               Ledger.read(ctx.home, "nimbus")
    end
  end

  describe "start again" do
    setup ctx, do: connect!(ctx)

    test "is one job: what stands is deleted, then a server of its size and place is created",
         ctx do
      created!(ctx, %{@recommended | type: "large-8"})
      provisioned_window(ctx, :open, 31 * 60_000)
      assert %{"detail" => %{"kind" => "not_set_up"}} = summary(ctx.opts)

      assert {:ok, %{"summary" => summary}} = press(ctx, "start_again")
      assert summary["state"] == "creating"

      settle!(ctx)
      assert [_one_job] = jobs(ctx)

      assert {:ok, %{server: new, action: nil}} = Ledger.read(ctx.home, "nimbus")
      assert %{status: :created, type: "large-8", location: "osl1"} = new

      calls = Enum.map(FakeCloudProvider.calls(ctx.world), &elem(&1, 0))
      deleted = Enum.find_index(calls, &(&1 == :delete))
      created = Enum.find_index(Enum.drop(calls, deleted), &(&1 == :create_server))
      assert is_integer(deleted) and is_integer(created)
    end

    test "after a step the engine's restart left, creates again with what it kept", ctx do
      :ok = Provision.put_action("create", ctx.opts)
      choice = %{type: "large-8", location: "osl1"}
      {:ok, _ledger} = Ledger.update(ctx.home, "nimbus", &{:ok, Ledger.choose(&1, choice)})
      :ok = Provision.interrupt_left_actions(ctx.opts)

      assert %{"detail" => %{"kind" => "create_failed"}} = summary(ctx.opts)
      assert offered!(summary(ctx.opts), "start_again")["needs"] == []
      assert {:ok, _answer} = press(ctx, "start_again")

      settle!(ctx)

      assert {:ok, %{server: %{status: :created, type: "large-8"}, failure: nil, action: nil}} =
               Ledger.read(ctx.home, "nimbus")
    end

    test "with no size and place kept, asks for them and creates the one chosen", ctx do
      failure = %{
        reason: "interrupted",
        sentence: "Fermix stopped before your server was created, so start again.",
        next_location: nil,
        at: @at
      }

      {:ok, _ledger} = Ledger.update(ctx.home, "nimbus", &{:ok, Ledger.put_failure(&1, failure)})
      assert offered!(summary(ctx.opts), "start_again")["needs"] == ["choice"]

      assert {:error, :invalid_params, %{"field" => "type"}} = press(ctx, "start_again")
      assert {:ok, _answer} = press(ctx, "start_again", %Input{type: "large-8", location: "osl1"})
      settle!(ctx)

      assert {:ok, %{server: %{status: :created, type: "large-8"}, failure: nil}} =
               Ledger.read(ctx.home, "nimbus")
    end
  end

  describe "power" do
    setup ctx do
      connect!(ctx)
      created!(ctx, @recommended)
      provisioned_window(ctx, :open, 60_000)
      ctx
    end

    test "turn it on is the power job, and its end is kept", ctx do
      turned_off!(ctx)
      assert %{"detail" => %{"kind" => "turned_off"}} = summary(ctx.opts)

      assert {:ok, %{"summary" => %{"sentence" => "Turning your server on…"}}} =
               press(ctx, "turn_on")

      settle!(ctx)
      assert {:ok, %{server: %{power: "running"}, action: nil}} = Ledger.read(ctx.home, "nimbus")
      assert {:power, {server_id(ctx), :on}} in FakeCloudProvider.calls(ctx.world)
    end

    test "a power action that stops is a problem the summary keeps", ctx do
      turned_off!(ctx)
      FakeCloudProvider.fault(ctx.world, :power, {:unreachable, "invented timeout"})

      assert {:ok, _answer} = press(ctx, "turn_on")
      settle!(ctx)

      assert %{"state" => "problem", "detail" => %{"kind" => "power_failed"}} =
               summary(ctx.opts)
    end
  end

  describe "deleting" do
    setup ctx do
      connect!(ctx)
      created!(ctx, @recommended)
      ctx
    end

    test "Delete your server is the delete job", ctx do
      provisioned_window(ctx, :open, 31 * 60_000)

      assert {:ok, %{"summary" => %{"sentence" => "Deleting your server…"}}} =
               press(ctx, "delete_server")

      settle!(ctx)
      assert {:ok, %{server: nil, firewall: nil, action: nil}} = Ledger.read(ctx.home, "nimbus")
      assert summary(ctx.opts)["state"] == "choose"
    end

    test "Cancel with the server standing is the delete job", ctx do
      provisioned_window(ctx, :open, 60_000)
      assert %{"state" => "creating", "action" => %{"id" => "cancel"}} = summary(ctx.opts)

      assert {:ok, _answer} = press(ctx, "cancel")
      settle!(ctx)

      assert {:ok, %{server: nil, action: nil}} = Ledger.read(ctx.home, "nimbus")
    end
  end

  describe "cancel during a create" do
    test "stops the create, waits for its run to end, then deletes what it made", ctx do
      connect!(ctx)
      test = self()
      tracker = start_supervised!({Agent, fn -> nil end}, id: :tracker)

      # The create holds inside its server's call; the delete reports whether
      # the create's run still lived when it reached the provider.
      spy = fn
        :create_server ->
          run = self()
          Agent.update(tracker, fn _nil -> run end)
          send(test, :create_holding)

          receive do
            :never -> :ok
          end

        :delete ->
          send(test, {:delete_beside_create, Process.alive?(Agent.get(tracker, & &1))})

        _other ->
          :ok
      end

      opts = put_provider_opt(ctx.opts, :spy, spy)
      ctx = %{ctx | opts: opts}

      assert {:ok, _answer} = press(ctx, "create_server", @choice)
      assert_receive :create_holding, 10_000
      assert %{"state" => "creating", "action" => %{"id" => "cancel"}} = summary(opts)

      assert {:ok, %{"summary" => summary}} = press(ctx, "cancel")
      refute Process.alive?(Agent.get(tracker, & &1))
      assert summary["state"] == "creating"

      assert_receive {:delete_beside_create, false}, 10_000
      settle!(ctx)

      assert {:ok, %{server: nil, firewall: nil, action: nil}} = Ledger.read(ctx.home, "nimbus")
      assert summary(opts)["state"] == "choose"
    end
  end

  describe "a server of the owner's own" do
    test "opens a manual code, answered once with the command, which carries no code and " <>
           "names the release this computer runs",
         ctx do
      assert {:ok, %{"result" => result, "summary" => summary}} = press(ctx, "own_server")
      assert_received {:enrollment_opened, :manual}

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
      Agent.update(ctx.link, &%{&1 | enrollment: window(:manual, :open, nil, 60_000)})
      assert %{"state" => "connect"} = summary(ctx.opts)

      assert {:ok, %{"summary" => %{"state" => "off"}}} = press(ctx, "cancel")
      assert_received {:enrollment_withdrawn, :manual}
      refute_received :code_withdrawn
    end
  end

  describe "the move, on the computer that sets up" do
    setup ctx do
      {:ok, held} = Candidates.add(ctx.home, candidate_attrs(), @at)
      Agent.update(ctx.link, &%{&1 | enrollment: window(:manual, :used, held.candidate_id, 0)})
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
      connect!(ctx)
      created!(ctx, @recommended)
      script = start_supervised!({Agent, fn -> server_part(:on) end}, id: :script)
      test = self()

      forward = fn %{method: method, params: params}, _opts ->
        send(test, {:forwarded, method, params})
        Agent.get(script, & &1).(method, params)
      end

      Agent.update(ctx.link, &%{&1 | primary: primary(nil)})

      # The server's code comes over the link, as the daemon's forward brings it.
      opts =
        ctx.opts
        |> Keyword.drop([:open_code, :withdraw_code])
        |> Keyword.put(:engine_role, @device)
        |> Keyword.put(:primary_forward, forward)

      %{ctx | opts: opts} |> Map.put(:script, script)
    end

    # Review R4: a replace that failed before the provider allocated anything
    # is the desktop's own problem, offered another Replace; never on.
    test "a replace that failed before the new server is a problem of its own", ctx do
      FakeCloudProvider.fault(ctx.world, :catalog, {:unreachable, :timeout})
      assert {:ok, _answer} = press(ctx, "replace_server", @choice)
      settle!(ctx)

      assert {:ok, %{failure: %{action: "create"}, replace: nil}} =
               Ledger.read(ctx.home, "nimbus")

      assert summary(ctx.opts)["state"] == "problem"
      screen = summary(ctx.opts)
      assert %{"action" => %{"id" => "replace_server"}} = screen
      offered = Enum.map(screen["detail"]["alternatives"], & &1["id"])
      refute Enum.any?(offered, &(&1 in ["start_again", "delete_server"]))

      assert {:ok, _answer} = press(ctx, "replace_server", @choice)
      settle!(ctx)

      assert {:ok, %{replace: %{old: %{server: %{}}}, server: %{status: :created}, failure: nil}} =
               Ledger.read(ctx.home, "nimbus")
    end

    # Review R2: a ready replacement can still be cancelled.
    test "a new server ready for the move can be deleted", ctx do
      live = server_id(ctx)
      replacing_ready!(ctx)
      screen = summary(ctx.opts)
      assert screen["state"] == "ready"

      actions = HomeSummary.offered(screen)

      assert Enum.any?(actions, &(&1["id"] in ["cancel", "delete_server"]))

      assert {:ok, _answer} = press(ctx, "delete_server")
      settle!(ctx)

      # The new server is gone; the one the home lives on is the ledger's again.
      assert {:ok, %{replace: nil, server: %{id: ^live}}} = Ledger.read(ctx.home, "nimbus")

      assert summary(ctx.opts)["state"] == "on"
    end

    test "Back up now is sent to the server", ctx do
      assert %{"state" => "on"} = summary(ctx.opts)

      assert {:ok, %{"result" => nil}} = press(ctx, "back_up_now")
      assert_received {:forwarded, "home.snapshots.run", %{}}
    end

    test "Replace the server creates the new one here, with the server's own code", ctx do
      assert {:ok, %{"summary" => summary}} = press(ctx, "replace_server", @choice)
      assert summary["state"] == "creating"

      settle!(ctx)
      assert_received {:forwarded, "home.enroll.open", %{"kind" => "provisioned"}}

      assert {:ok, %{replace: %{old: %{server: %{}}}, server: %{status: :created}}} =
               Ledger.read(ctx.home, "nimbus")
    end

    test "Restart server is the power job, on the server this desktop cannot reach", ctx do
      Agent.update(ctx.link, &%{&1 | primary: primary(11 * 60_000)})
      assert %{"detail" => %{"kind" => "cannot_reach"}} = summary(ctx.opts)

      assert {:ok, %{"summary" => %{"sentence" => "Restarting your server…"}}} =
               press(ctx, "restart_server")

      settle!(ctx)
      assert {:power, {server_id(ctx), :reset}} in FakeCloudProvider.calls(ctx.world)
    end

    test "Move now sends the move to the server, which keeps no desktop of the old one, " <>
           "and records the replace once",
         ctx do
      candidate_id = replacing_ready!(ctx)
      assert %{"state" => "ready", "action" => move_now} = summary(ctx.opts)
      assert move_now["needs"] == ["recovery_passphrase"]

      Agent.update(ctx.script, fn script ->
        fn
          "home.move.start", _params -> {:ok, %{"move_id" => "mv-0001"}}
          method, params -> script.(method, params)
        end
      end)

      assert {:ok, %{"result" => %{"move_id" => "mv-0001"}, "summary" => summary}} =
               press(ctx, "move_now", %Input{recovery_passphrase: @passphrase})

      assert_received {:forwarded, "home.move.start", params}

      assert params == %{
               "candidate_id" => candidate_id,
               "recovery_passphrase" => @passphrase,
               "keep_as_desktop" => false
             }

      assert summary["state"] == "moving"
      assert {:ok, %{replace: %{move_started_at: @at}}} = Ledger.read(ctx.home, "nimbus")

      # The move started: the screen offers no second one.
      assert {:error, :changed, _details} =
               AlwaysOn.act(
                 %{action: "move_now", key: move_now["key"], input: %Input{}},
                 ctx.opts
               )
    end

    test "the server's own refusal of a replace's move is answered as it came, and " <>
           "records nothing",
         ctx do
      replacing_ready!(ctx)
      refusal = %{"capability" => "home", "sentence" => "The move cannot start yet. Too full."}

      Agent.update(ctx.script, fn script ->
        fn
          "home.move.start", _params -> {:error, :unavailable, refusal}
          method, params -> script.(method, params)
        end
      end)

      assert press(ctx, "move_now", %Input{recovery_passphrase: @passphrase}) ==
               {:error, :unavailable, refusal}

      assert {:ok, %{replace: %{move_started_at: nil}}} = Ledger.read(ctx.home, "nimbus")
    end
  end

  # `changed` says only that the screen moved on (Always On setup §3.4, the
  # lead's call on the error details' bound): the surface reads home.status
  # again, as it does after any act, so no refusal carries a summary.
  describe "the changed refusal" do
    test "holds only its sentence, on the wire too", ctx do
      params = %{"action" => "paste_token", "key" => "an-older-key"}

      assert {:error, :changed, details} = route("home.act", params, ctx)

      assert details == %{
               "sentence" => "Always On changed since this was shown, so look at it again."
             }

      assert {:ok, %{"error" => %{"details" => ^details}}} =
               Protocol.respond("req-1", {:error, :changed, details})
    end
  end

  # The wire (§3.4, §3.5): `home.act` decodes its params at the router, the
  # server's steps answer only a desktop's forward, and the provisioner's
  # writes are no method.
  describe "through the router" do
    test "home.act runs the step and answers the summary after it", ctx do
      key = offered!(summary(ctx.opts), "paste_token")["key"]

      params = %{
        "action" => "paste_token",
        "key" => key,
        "input" => %{"token" => FakeCloudProvider.token()}
      }

      assert {:ok, %{"summary" => %{"state" => "choose"}, "result" => nil}} =
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
      withdraw = fn kind ->
        send(self(), {:withdrawn, kind})
        :ok
      end

      opts = [operation_opts: [home: [home: ctx.home, withdraw_enrollment: withdraw]]]

      assert {:error, :unavailable, %{"method" => "home.enroll.withdraw", "sentence" => _}} =
               route("home.enroll.withdraw", %{}, ctx, opts)

      refute_received {:withdrawn, _kind}

      assert {:ok, %{"withdrawn" => true}} =
               route("home.enroll.withdraw", %{}, ctx, [actor: {:desktop, "desk-1"}] ++ opts)

      assert_received {:withdrawn, :provisioned}
    end

    test "the provisioner's writes are no method", ctx do
      for method <- ~w(home.provision.providers home.provision.connect home.provision.create
                       home.provision.power home.provision.resources home.provision.delete) do
        assert {:error, :method_not_found, %{"method" => ^method}} = route(method, %{}, ctx)
      end
    end
  end

  # Review R5, R1, R3: every ending of a step leaves a usable screen.
  describe "after a step stopped" do
    test "a create whose run raised keeps its failure on the screen", ctx do
      connect!(ctx)

      spy = fn
        :catalog -> raise "invented provider failure"
        _other -> :ok
      end

      raising = %{ctx | opts: put_provider_opt(ctx.opts, :spy, spy)}
      assert {:ok, _answer} = press(raising, "create_server", @choice)
      settle!(raising)
      assert Enum.any?(jobs(ctx), &(&1["status"] == "failed"))
      assert {:ok, %{action: nil, failure: failure}} = Ledger.read(ctx.home, "nimbus")
      assert is_map(failure), "the job failed but the ledger keeps #{inspect(failure)}"
      assert %{reason: "interrupted", action: "create"} = failure

      assert %{"state" => "problem", "detail" => %{"kind" => "create_failed"}} =
               summary(ctx.opts)

      assert {:ok, _answer} = press(ctx, "start_again")
      settle!(ctx)
      assert {:ok, %{server: %{status: :created}, failure: nil}} = Ledger.read(ctx.home, "nimbus")
    end

    test "a create whose run was killed keeps its failure on the screen", ctx do
      connect!(ctx)

      spy = fn
        :create_server -> Process.exit(self(), :kill)
        _other -> :ok
      end

      killed = %{ctx | opts: put_provider_opt(ctx.opts, :spy, spy)}
      assert {:ok, _answer} = press(killed, "create_server", @choice)
      settle!(killed)

      assert {:ok, %{action: nil, failure: %{reason: "interrupted", action: "create"}}} =
               Ledger.read(ctx.home, "nimbus")

      assert %{"detail" => %{"kind" => "create_failed"}} = summary(ctx.opts)
    end

    test "a read-only token replaced by one that writes offers the create again", ctx do
      assert {:ok, _answer} =
               press(ctx, "paste_token", %Input{token: FakeCloudProvider.read_only_token()})

      assert {:ok, _answer} = press(ctx, "create_server", @choice)
      settle!(ctx)
      assert summary(ctx.opts)["detail"]["kind"] == "read_only_token"
      assert {:ok, %{"summary" => screen}} = press(ctx, "paste_token", token_input())
      assert {:ok, %{token: token}} = Ledger.read(ctx.home, "nimbus")
      assert token == FakeCloudProvider.token()

      actions = HomeSummary.offered(screen)

      assert Enum.any?(actions, &(&1["id"] in ["create_server", "start_again"])), inspect(screen)
      assert screen["state"] == "choose"

      assert {:ok, _answer} = press(ctx, "create_server", @choice)
      settle!(ctx)
      assert {:ok, %{server: %{status: :created}, failure: nil}} = Ledger.read(ctx.home, "nimbus")
    end

    test "an account limit the owner lifted offers the create again", ctx do
      connect!(ctx)
      FakeCloudProvider.fault(ctx.world, :create_server, :account_limit)
      assert {:ok, _answer} = press(ctx, "create_server", @choice)
      settle!(ctx)
      screen = summary(ctx.opts)
      assert screen["detail"]["kind"] == "account_limit"
      # The fault was one-shot: the same provider now accepts the create.
      assert FakeCloudProvider.world(ctx.world).faults == []

      actions = HomeSummary.offered(screen)

      assert Enum.any?(actions, &(&1["id"] in ["create_server", "start_again", "check_again"])),
             inspect(screen)

      assert {:ok, _answer} = press(ctx, "start_again")
      settle!(ctx)

      assert {:ok,
              %{server: %{status: :created, type: "small-4", location: "osl1"}, failure: nil}} =
               Ledger.read(ctx.home, "nimbus")
    end

    test "a size out of stock everywhere offers the create again, with the size it kept", ctx do
      connect!(ctx)

      failure = %{
        reason: "unavailable",
        sentence: "No location Fermix offers has a Small 4 right now, Oslo included.",
        next_location: nil,
        at: @at,
        action: "create",
        type: "small-4",
        location: "osl1"
      }

      {:ok, _ledger} = Ledger.update(ctx.home, "nimbus", &{:ok, Ledger.put_failure(&1, failure)})

      assert %{"detail" => %{"kind" => "no_capacity"}, "action" => %{"id" => "start_again"}} =
               summary(ctx.opts)

      assert {:ok, _answer} = press(ctx, "start_again")
      settle!(ctx)

      assert {:ok,
              %{server: %{status: :created, type: "small-4", location: "osl1"}, failure: nil}} =
               Ledger.read(ctx.home, "nimbus")
    end

    # Review R2: a server Fermix created waits for the move with a way to
    # delete it, whether it is ready or its review blocks.
    test "a server ready for the first move can be deleted", ctx do
      first_move_ready!(ctx)
      assert %{"state" => "ready"} = summary(ctx.opts)

      assert {:ok, _answer} = press(ctx, "delete_server")
      settle!(ctx)
      assert {:ok, %{server: nil, firewall: nil}} = Ledger.read(ctx.home, "nimbus")
    end

    test "a server whose move was undone can be deleted", ctx do
      first_move_ready!(ctx)
      File.mkdir_p!(Move.dir(ctx.home))
      :ok = Move.put_phase(ctx.home, "aborted", %{"candidate" => "fermix-general-a3f9"}, @at)
      assert %{"state" => "undone"} = summary(ctx.opts)

      assert {:ok, _answer} = press(ctx, "delete_server")
      settle!(ctx)
      assert {:ok, %{server: nil, firewall: nil}} = Ledger.read(ctx.home, "nimbus")
    end

    test "a server whose review blocks the first move can be deleted", ctx do
      candidate_id = first_move_ready!(ctx)
      items = [%{id: "disk", status: :block, sentence: "Too full."}]
      :ok = Move.put_review(ctx.home, candidate_id, %{ready: false, items: items}, @at)
      assert %{"detail" => %{"kind" => "not_ready"}} = summary(ctx.opts)

      assert {:ok, _answer} = press(ctx, "delete_server")
      settle!(ctx)
      assert {:ok, %{server: nil, firewall: nil}} = Ledger.read(ctx.home, "nimbus")
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

  defp token_input, do: %Input{token: FakeCloudProvider.token()}

  # -- the world ---------------------------------------------------------------

  defp provider_opts(world), do: [world: world, now: fn -> @at end, sleep: fn _ms -> :ok end]

  defp put_provider_opt(opts, key, value),
    do: Keyword.update!(opts, :provider_opts, &Keyword.put(&1, key, value))

  defp connect!(ctx) do
    {:ok, _ledger} =
      Ledger.update(
        ctx.home,
        "nimbus",
        &{:ok, Ledger.connect(&1, FakeCloudProvider.token(), @at)}
      )

    ctx
  end

  # A server the driver created, as a step's job leaves it.
  defp created!(ctx, request) do
    opts =
      ctx.opts[:provider_opts] ++
        [open_code: fn -> {:ok, @code} end, withdraw_code: fn -> :ok end]

    {:ok, _server} = Driver.create(FakeCloudProvider, ctx.home, request, opts)
    :ok
  end

  defp server_id(ctx) do
    {:ok, %{server: %{id: id}}} = Ledger.read(ctx.home, "nimbus")
    id
  end

  defp turned_off!(ctx) do
    {:ok, %{server: %{id: id}}} = Ledger.read(ctx.home, "nimbus")
    Agent.update(ctx.world, &put_in(&1.servers[id].power, "off"))

    {:ok, _ledger} =
      Ledger.update(ctx.home, "nimbus", &{:ok, Ledger.put_server(&1, %{power: "off"})})
  end

  defp provisioned_window(ctx, state, awake_ms),
    do: Agent.update(ctx.link, &%{&1 | enrollment: window(:provisioned, state, nil, awake_ms)})

  defp window(kind, state, candidate_id, awake_ms) do
    %{
      state: state,
      expires_at: ~U[2031-05-05 12:00:00Z],
      kind: kind,
      candidate_id: candidate_id,
      awake_ms: awake_ms
    }
  end

  # A step of the family already runs: a read of the provider.
  defp hold_reconcile!(ctx) do
    test = self()

    {:ok, _view} =
      Jobs.start(:home_provision,
        name: "nimbus",
        server: ctx.opts[:jobs][:server],
        run: fn _id, _report ->
          send(test, :reconciling)

          receive do
            :never -> {:ok, %{}}
          end
        end
      )

    assert_receive :reconciling, 10_000
  end

  # A server Fermix created enrolled with its code and waits for the first
  # move; the candidate it enrolled as.
  defp first_move_ready!(ctx) do
    connect!(ctx)
    created!(ctx, @recommended)
    {:ok, held} = Candidates.add(ctx.home, candidate_attrs(), @at)
    window = window(:provisioned, :used, held.candidate_id, 60_000)
    Agent.update(ctx.link, &%{&1 | enrollment: window})
    held.candidate_id
  end

  # The server the home lives on is being replaced: its new server stands and
  # waits for the move, as the old server's own part says.
  defp replacing_ready!(ctx) do
    new_server = %{
      name: "fermix-general-5d2e",
      id: "nb-900",
      status: :created,
      type: "small-4",
      location: "osl1",
      ipv4: "198.51.100.9",
      power: "running",
      created_at: @at,
      seen_at: @at
    }

    {:ok, _ledger} =
      Ledger.update(ctx.home, "nimbus", fn ledger ->
        {:ok, replacing} = Ledger.begin_replace(ledger, 5, @at)
        {:ok, Ledger.put_server(replacing, new_server)}
      end)

    Agent.update(ctx.script, fn _script -> server_part(:replace_ready) end)
    "cand-9d41c7e2b05a3f68"
  end

  # The server's own `home.status`, and its answers to the steps sent to it.
  defp server_part(which) do
    part = server_status(which)

    fn
      "home.status", _params -> {:ok, part}
      "home.snapshots.run", _params -> {:ok, %{"started" => true, "snapshots" => %{}}}
      "home.enroll.open", %{"kind" => "provisioned"} -> {:ok, %{"code" => @server_code}}
      "home.enroll.withdraw", _params -> {:ok, %{"withdrawn" => true}}
    end
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

  defp server_status(:replace_ready) do
    Map.merge(server_status(:on), %{
      "enrollment" => %{
        "state" => "used",
        "expires_at" => "2031-05-05T12:00:00Z",
        "kind" => "provisioned",
        "candidate_id" => "cand-9d41c7e2b05a3f68"
      },
      "candidates" => [
        %{
          "candidate_id" => "cand-9d41c7e2b05a3f68",
          "name" => "fermix-general-5d2e",
          "os" => "linux",
          "arch" => "x86_64",
          "version" => "9.9.9",
          "enrolled_at" => "2031-05-04T11:05:00Z",
          "expires_at" => "2031-05-05T11:05:00Z"
        }
      ]
    })
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
