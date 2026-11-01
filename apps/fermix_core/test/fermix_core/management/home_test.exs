defmodule FermixCore.Management.HomeTest do
  use ExUnit.Case, async: true

  alias FermixCore.Home.Candidates
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Move
  alias FermixCore.Home.Moved
  alias FermixCore.Home.Provision.Driver
  alias FermixCore.Home.Provision.Ledger
  alias FermixCore.Home.Snapshot.Capture
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Home.Snapshot.Scheduler
  alias FermixCore.Home.Snapshot.Status
  alias FermixCore.Home.StatusWatch
  alias FermixCore.Management.Home
  alias FermixCore.Management.HomeSummary
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.Router
  alias FermixTestSupport.FakeCloudProvider
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TelemetryCapture

  @primary %{role: :primary, primary: nil}
  @device %{role: :device, primary: "invented host"}
  @desktop {:desktop, "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e"}
  @passphrase "invented-lighthouse-meridian"
  @at ~U[2031-05-04 12:00:00Z]

  setup do
    tmp = SafeRm.make_tmp_dir!("management_home")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)
    :ok = Epoch.write(tmp, 4)
    %{home: tmp, recipient: Recipient.encode(Recipient.generate())}
  end

  describe "home.status" do
    test "the primary's picture, with the places later slices fill left empty",
         %{home: home, recipient: recipient} do
      config = [recipient: recipient, s3_bucket: "invented-bucket"]

      assert {:ok, status} = route("home.status", %{}, opts(home, config: config))

      assert status["role"] == "primary"
      assert status["epoch"] == 4
      assert status["moved"] == nil
      assert status["primary"] == nil
      assert status["desktops"] == []
      assert status["enrollment"] == nil
      assert status["candidates"] == []
      assert status["move"] == nil
      assert status["secrets_missing"] == []
      assert status["snapshots"]["configured"]
      assert status["snapshots"]["sentence"] == "Snapshots are on; the first runs soon."
    end

    test "the primary names each secret reference this host could not resolve",
         %{home: home} do
      live = %{
        fermix_core: [providers: [anthropic: [api_key: "@keyring"], openai: [api_key: "sk-x"]]],
        fermix_channels: [telegram: [bot_token: "@keyring"]]
      }

      settings = fn -> live end

      assert {:ok, %{"secrets_missing" => ["anthropic_api_key", "telegram_bot_token"]}} =
               route("home.status", %{}, opts(home, settings_snapshot: settings))

      # A desktop's own settings name no secret the server needs.
      assert {:ok, %{"secrets_missing" => []}} =
               route(
                 "home.status",
                 %{},
                 opts(home, settings_snapshot: settings, engine_role: @device)
               )
    end

    test "a device names its marker and leaves snapshots to the primary",
         %{home: home, recipient: recipient} do
      :ok =
        Moved.write(home, %{epoch: 4, moved_at: ~U[2026-10-27 09:30:00Z], to: "invented host"})

      config = [recipient: recipient, s3_bucket: "invented-bucket"]

      assert {:ok, status} =
               route("home.status", %{}, opts(home, config: config, engine_role: @device))

      assert status["role"] == "device"

      assert status["moved"] == %{
               "to" => "invented host",
               "moved_at" => "2026-10-27T09:30:00Z",
               "epoch" => 4
             }

      assert status["snapshots"]["configured"] == false
      assert status["snapshots"]["next_run_at"] == nil

      assert status["snapshots"]["sentence"] ==
               "Snapshots are the primary's to write; this engine runs in the device role."
    end

    # A quiet renewal and an outage are both "not connected"; the word tells
    # them apart, so an app draws the renewal quietly.
    test "a desktop's primary carries the link's status word, from the closed set", %{
      home: home
    } do
      for word <- ~w(connected renewing unreachable revoked stale)a do
        link = fn ->
          %{
            primary: %{
              name: "invented-vm",
              connected: word == :connected,
              status: word,
              since: nil,
              epoch: 5,
              sentence: "Fermix is reconnecting to the server invented-vm."
            },
            desktops: [],
            enrollment: nil
          }
        end

        assert {:ok, status} =
                 route("home.status", %{}, opts(home, engine_role: @device, link_status: link))

        assert status["primary"]["status"] == Atom.to_string(word)
      end

      unknown = fn ->
        %{
          primary: %{name: "invented-vm", connected: false, status: :asleep, sentence: "Asleep."},
          desktops: [],
          enrollment: nil
        }
      end

      assert_raise FunctionClauseError, fn ->
        route("home.status", %{}, opts(home, engine_role: @device, link_status: unknown))
      end
    end

    test "a home that never booted as the primary has no epoch yet", %{home: home} do
      SafeRm.rm!(Epoch.path(home))

      assert {:ok, %{"epoch" => nil}} = route("home.status", %{}, opts(home))
    end

    test "the next run and a run in progress come from a running scheduler",
         %{home: home, recipient: recipient} do
      config = [recipient: recipient, s3_bucket: "invented-bucket"]
      scheduler = scheduler!(home, config)

      assert {:ok, %{"next_run_at" => "2026-10-27T09:05:00Z", "running" => false}} =
               route(
                 "home.snapshots.status",
                 %{},
                 opts(home, config: config, scheduler: scheduler)
               )
    end
  end

  # The gatherer behind `home.status.summary` (M75 lean v1 §7), with each of
  # its sources a real file in a temp home or an injected seam: the ledger,
  # the candidates, the window and link as the rail says them, the review,
  # the disk, the server's own part and this desktop's copies.
  describe "home.status's summary" do
    test "a primary with nothing says off, and publishes its disk and version", %{home: home} do
      assert {:ok, status} =
               route("home.status", %{}, opts(home, disk_usage: disk(0.42), version: "9.9.9"))

      assert status["summary"]["state"] == "off"
      assert status["summary"]["action"]["id"] == "paste_token"
      assert status["summary"]["key"] == HomeSummary.key(status["summary"])
      assert status["disk"] == %{"used" => 0.42, "nearly_full" => false}
      assert status["version"] == "9.9.9"
    end

    test "off names what this home uses that stops after the move, read from its settings",
         %{home: home} do
      File.write!(Path.join(home, "config.toml"), """
      [fermix_channels.imessage]
      enabled = true

      [fermix_core.realtime]
      enabled = false

      [fermix_core.meetings]
      enabled = true
      """)

      assert {:ok, %{"summary" => summary}} =
               route("home.status", %{}, opts(home, host_os: :macos))

      assert summary["sentence"] ==
               "Keep Fermix running when this Mac sleeps. It moves to a server you own. " <>
                 "iMessage and meetings stop after the move."

      File.write!(Path.join(home, "config.toml"), "")

      assert {:ok, %{"summary" => %{"sentence" => sentence}}} =
               route("home.status", %{}, opts(home, host_os: :macos))

      assert sentence == "Keep Fermix running when this Mac sleeps. It moves to a server you own."
    end

    test "the ledger's token makes choose, and its created server waiting makes ready, " <>
           "with the last review's warnings",
         %{home: home} do
      {:ok, _ledger} =
        Ledger.update(home, "hetzner", &{:ok, Ledger.connect(&1, "invented-token-0001", @at)})

      assert {:ok, %{"summary" => %{"state" => "choose"}}} = route("home.status", %{}, opts(home))

      {:ok, held} = Candidates.add(home, candidate_attrs(), @at)
      {:ok, _ledger} = Ledger.update(home, "hetzner", &{:ok, Ledger.put_server(&1, server())})
      report = %{ready: true, items: [%{id: "whatsapp", status: :warn, sentence: "Warned."}]}
      :ok = Move.put_review(home, held.candidate_id, report, @at)

      window = provisioned(:used, held.candidate_id)

      assert {:ok, %{"summary" => summary}} =
               route("home.status", %{}, opts(home, link_status: link(enrollment: window)))

      assert summary["state"] == "ready"
      assert summary["action"]["id"] == "move_now"

      assert summary["detail"]["readiness"] == [
               %{"id" => "whatsapp", "status" => "warn", "sentence" => "Warned."}
             ]

      assert summary["detail"]["server"]["location"] == "Falkenstein"
    end

    test "a created server whose code has been open thirty minutes awake did not set up",
         %{home: home} do
      {:ok, _ledger} =
        Ledger.update(home, "hetzner", fn ledger ->
          {:ok,
           ledger |> Ledger.connect("invented-token-0001", @at) |> Ledger.put_server(server())}
        end)

      window = %{provisioned(:open, nil) | awake_ms: 31 * 60_000}

      assert {:ok, %{"summary" => summary}} =
               route("home.status", %{}, opts(home, link_status: link(enrollment: window)))

      assert summary["state"] == "problem"
      assert summary["detail"]["kind"] == "not_set_up"
    end

    test "a linked desktop reads the server's part, its own copies and the link's silence",
         %{home: home} do
      :ok = DesktopLink.write(home, desktop_link())
      :ok = Moved.write(home, %{epoch: 4, moved_at: @at, to: "invented-vm"})
      File.mkdir_p!(Capture.dir(home))
      File.write!(Path.join(Capture.dir(home), "20310504T100000Z-e5.fxsnap"), "12345")

      server_part = %{
        "role" => "primary",
        "version" => "9.9.8",
        "disk" => %{"used" => 0.4, "nearly_full" => false},
        "snapshots" => %{
          "targets" => [
            %{"label" => "your desktop", "last_verified" => %{"at" => "2031-05-04T11:00:00Z"}}
          ]
        }
      }

      forward = fn _request, _opts -> {:ok, server_part} end

      assert {:ok, status} =
               route(
                 "home.status",
                 %{},
                 opts(home, engine_role: @device, link_status: link(primary: primary(nil)))
                 |> Keyword.put(:primary_forward, forward)
               )

      assert status["summary"]["sentence"] ==
               "Fermix runs on your server. Last backup 1 hour ago."

      assert status["summary"]["detail"]["copies_bytes"] == 5
      assert status["summary"]["detail"]["server"]["version"] == "9.9.8"
      assert status["disk"] == nil

      silent = link(primary: primary(11 * 60_000))

      assert {:ok, %{"summary" => summary}} =
               route(
                 "home.status",
                 %{},
                 opts(home, engine_role: @device, link_status: silent)
                 |> Keyword.put(:primary_forward, forward)
               )

      assert summary["detail"]["kind"] == "cannot_reach"
      assert summary["action"]["id"] == "learn_more"
    end

    test "a linked desktop replacing its server reads the replace from its ledger and the " <>
           "new server's code from the old one",
         %{home: home} do
      :ok = DesktopLink.write(home, desktop_link())
      new_server = %{server() | name: "fermix-general-5d2e", id: "61900117"}

      {:ok, _ledger} =
        Ledger.update(home, "hetzner", fn ledger ->
          {:ok, replacing} =
            ledger
            |> Ledger.connect("invented-token-0001", @at)
            |> Ledger.put_server(server())
            |> Ledger.begin_replace(5, @at)

          {:ok, Ledger.put_server(replacing, new_server)}
        end)

      candidate = %{
        "candidate_id" => "cand-9d41c7e2b05a3f68",
        "name" => "fermix-general-5d2e",
        "os" => "linux",
        "arch" => "x86_64",
        "version" => "9.9.9",
        "enrolled_at" => "2031-05-04T10:05:00Z",
        "expires_at" => "2031-05-05T10:05:00Z"
      }

      server_part = %{
        "role" => "primary",
        "version" => "9.9.9",
        "disk" => %{"used" => 0.4, "nearly_full" => false},
        "snapshots" => %{"targets" => []},
        "enrollment" => %{
          "state" => "used",
          "expires_at" => "2031-05-05T10:00:00Z",
          "kind" => "provisioned",
          "candidate_id" => "cand-9d41c7e2b05a3f68"
        },
        "candidates" => [candidate]
      }

      forward = fn _request, _opts -> {:ok, server_part} end

      assert {:ok, %{"summary" => summary}} =
               route(
                 "home.status",
                 %{},
                 opts(home, engine_role: @device, link_status: link(primary: primary(nil)))
                 |> Keyword.put(:primary_forward, forward)
               )

      assert summary["sentence"] == "Your new server is ready for the move."
      assert summary["action"]["id"] == "move_now"
      assert summary["detail"]["server"]["name"] == "fermix-general-5d2e"
    end

    test "a server this desktop is too old for asks to update it", %{home: home} do
      :ok = DesktopLink.write(home, desktop_link())
      too_old = fn _request, _opts -> {:error, :client_too_old, %{"minimum_version" => 3}} end

      assert {:ok, status} =
               route(
                 "home.status",
                 %{},
                 opts(home, engine_role: @device, link_status: link(primary: primary(nil)))
                 |> Keyword.put(:primary_forward, too_old)
               )

      assert status["summary"]["detail"]["kind"] == "update"
      assert status["primary_home"] == nil
      assert status["primary_missing"] =~ "newer Fermix"
    end

    test "a disk that cannot be read publishes none and says why in the log", %{home: home} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{"disk" => nil}} =
                   route(
                     "home.status",
                     %{},
                     opts(home, disk_usage: fn _home -> {:error, :df_unavailable} end)
                   )
        end)

      assert log =~ "df_unavailable"
    end
  end

  describe "home.snapshots.run" do
    test "starts one, and a second while it runs is busy", %{home: home, recipient: recipient} do
      config = [recipient: recipient, s3_bucket: "invented-bucket"]
      test = self()

      run = fn _home, _config, _targets, _opts ->
        send(test, {:running, self()})

        receive do
          :finish -> :not_configured
        end
      end

      scheduler = scheduler!(home, config, run: run)

      # On `daemon.sock` the run is refused by name and starts none, so the
      # forward's run below is the first.
      assert {:error, :unavailable,
              %{
                "capability" => "home",
                "method" => "home.snapshots.run",
                "sentence" => <<_, _::binary>>
              }} =
               route("home.snapshots.run", %{}, opts(home, config: config, scheduler: scheduler))

      opts = forwarded(opts(home, config: config, scheduler: scheduler))

      assert {:ok, %{"started" => true, "snapshots" => snapshots}} =
               route("home.snapshots.run", %{}, opts)

      assert snapshots["running"]
      assert snapshots["sentence"] == "A snapshot is being written now."
      assert_receive {:running, task}, 10_000

      assert route("home.snapshots.run", %{}, opts) ==
               {:error, :busy, %{"operation" => "home.snapshots.run"}}

      send(task, :finish)
    end

    test "with nothing to write, says what is missing", %{home: home} do
      scheduler = scheduler!(home, [])

      assert route("home.snapshots.run", %{}, forwarded(opts(home, scheduler: scheduler))) ==
               {:error, :unavailable,
                %{
                  "capability" => "snapshots",
                  "sentence" => "Snapshots are off: set a recovery passphrase to turn them on."
                }}
    end

    test "a device, and an engine with no scheduler, refuse by name", %{home: home} do
      assert {:error, :unavailable, %{"sentence" => device}} =
               route("home.snapshots.run", %{}, forwarded(opts(home, engine_role: @device)))

      assert device =~ "device role"

      assert route("home.snapshots.run", %{}, forwarded(opts(home, scheduler: nil))) ==
               {:error, :unavailable,
                %{
                  "capability" => "snapshots",
                  "sentence" => "Snapshots are not running in this engine."
                }}
    end
  end

  describe "home.snapshots.passphrase" do
    test "keeps the derived public key, answers it, and never the passphrase", %{home: home} do
      test = self()
      save = fn recipient -> send(test, {:saved, recipient}) && {:ok, %{}} end
      params = %{"recovery_passphrase" => @passphrase}

      assert {:ok, result} =
               route("home.snapshots.passphrase", params, opts(home, save_recipient: save))

      assert_receive {:saved, saved}
      refute Map.has_key?(saved, :secret_key)
      assert result["recipient"] == Recipient.encode(saved)
      assert result["key_id"] == Base.encode16(Recipient.key_id(saved.public_key), case: :lower)
      assert result["snapshots"]["recipient_set"]
      assert result["sentence"] =~ "written before now open only with the earlier passphrase"
      refute inspect(result) =~ @passphrase

      # The key re-derives from the passphrase and the salt the recipient carries.
      {:ok, again} = Recipient.derive(@passphrase, saved.salt)
      assert again.public_key == saved.public_key
    end

    test "a short passphrase, a wrong key and a device are refused by name", %{home: home} do
      assert route(
               "home.snapshots.passphrase",
               %{"recovery_passphrase" => "too short"},
               opts(home)
             ) ==
               {:error, :invalid_params,
                %{
                  "field" => "recovery_passphrase",
                  "sentence" => "The recovery passphrase must be at least 12 bytes long."
                }}

      assert route("home.snapshots.passphrase", %{"passphrase" => @passphrase}, opts(home)) ==
               {:error, :invalid_params, %{"field" => "passphrase"}}

      assert {:error, :unavailable, %{"capability" => "snapshots"}} =
               route(
                 "home.snapshots.passphrase",
                 %{"recovery_passphrase" => @passphrase},
                 opts(home, engine_role: @device)
               )
    end
  end

  test "the reads take no params" do
    for method <- ~w(home.snapshots.status home.snapshots.run) do
      assert route(method, %{"x" => 1}, []) == {:error, :invalid_params, %{"method" => method}}
    end
  end

  # Always On setup §5: freshness is the engine's. A read that draws a state
  # resting on the provider, while a server Fermix created stands and was
  # last checked over a minute ago, starts one reconcile, as a job of the
  # provider's family: one at a time, and never beside a step.
  describe "home.status keeps the provider's word fresh" do
    setup %{home: home} = ctx do
      world = FakeCloudProvider.start!()
      jobs = jobs!(ctx)
      seams = nimbus_seams(world)

      {:ok, _ledger} =
        Ledger.update(home, "nimbus", &{:ok, Ledger.connect(&1, FakeCloudProvider.token(), @at)})

      request = %{type: "small-4", location: "osl1", profile: "general"}
      {:ok, _server} = Driver.create(FakeCloudProvider, home, request, seams[:provider_opts])
      %{world: world, jobs: jobs, seams: seams}
    end

    test "a read in a problem with an unchecked server starts one reconcile", ctx do
      opts = opts(ctx.home, [jobs: ctx.jobs] ++ ctx.seams)

      assert {:ok, %{"summary" => %{"state" => "problem"}}} = route("home.status", %{}, opts)
      assert [%{"kind" => "home_provision"} = job] = jobs(ctx.jobs)
      assert %{"status" => "completed"} = finished(job, ctx.jobs)
      assert %{checked_at: @at} = Ledger.state(ctx.home, FakeCloudProvider)

      # Checked just now: the next read starts nothing.
      {:ok, _status} = route("home.status", %{}, opts)
      assert length(jobs(ctx.jobs)) == 1

      # Over a minute later it reads the provider again.
      later = DateTime.add(@at, 61, :second)

      {:ok, _status} =
        route("home.status", %{}, opts(ctx.home, [jobs: ctx.jobs, now: later] ++ ctx.seams))

      assert length(jobs(ctx.jobs)) == 2
    end

    test "a read while a step runs starts nothing beside it", ctx do
      gate = self()

      {:ok, _view} =
        Jobs.start(:home_provision,
          name: "nimbus",
          server: ctx.jobs[:server],
          run: fn _id, _report ->
            send(gate, :holding)

            receive do
              :go -> {:ok, %{}}
            end
          end
        )

      opts = opts(ctx.home, [jobs: ctx.jobs] ++ ctx.seams)
      assert {:ok, %{"summary" => %{"state" => "problem"}}} = route("home.status", %{}, opts)
      assert [%{"status" => "running"}] = jobs(ctx.jobs)
      assert %{checked_at: nil} = Ledger.state(ctx.home, FakeCloudProvider)
    end

    test "a state that rests on nothing the provider says starts nothing", ctx do
      {:ok, _ledger} = Ledger.update(ctx.home, "nimbus", &{:ok, Ledger.clear(&1)})
      opts = opts(ctx.home, [jobs: ctx.jobs] ++ ctx.seams)

      assert {:ok, %{"summary" => %{"state" => "choose"}}} = route("home.status", %{}, opts)
      assert jobs(ctx.jobs) == []
    end
  end

  # Always On setup §3.3: `home.status {after, wait_ms}` waits for the
  # summary to change, held in the caller by the Always On watch, so the CLI
  # follows a step without an interval.
  describe "home.status waits for a change" do
    setup %{home: home} = ctx do
      watch = :"home_status_watch_#{:erlang.phash2(ctx.test)}"
      home_opts = [home: home, engine_role: @primary, scheduler: nil, now: @at]

      start_supervised!(
        {StatusWatch,
         name: watch,
         read: fn -> HomeSummary.watch(Home.summary_facts(home_opts)) end,
         timer: fn _message, _delay -> make_ref() end,
         clock_monitor: false}
      )

      test = self()

      wait_timer = fn message, delay ->
        send(test, {:wait_timer, self(), message, delay})
        make_ref()
      end

      %{watch: watch, waits: [status_watch: watch, wait_timer: wait_timer]}
    end

    test "a key that is not the summary's is answered at once", ctx do
      opts = opts(ctx.home, ctx.waits)

      assert {:ok, %{"summary" => %{"state" => "off"}}} =
               route("home.status", %{"after" => "not-the-key", "wait_ms" => 25_000}, opts)

      refute_received {:wait_timer, _pid, _message, _delay}
    end

    test "the summary's key is held until the watch tells it moved", ctx do
      opts = opts(ctx.home, ctx.waits)
      {:ok, %{"summary" => %{"key" => key}}} = route("home.status", %{}, opts)

      waiting =
        Task.async(fn -> route("home.status", %{"after" => key, "wait_ms" => 25_000}, opts) end)

      assert_receive {:wait_timer, _pid, {:home_status_wait, _token}, 25_000}

      {:ok, _ledger} =
        Ledger.update(ctx.home, "hetzner", &{:ok, Ledger.connect(&1, "invented-token-0001", @at)})

      :ok = StatusWatch.changed(ctx.watch, :ledger)

      assert {:ok, %{"summary" => %{"state" => "choose", "key" => moved}}} =
               Task.await(waiting, 10_000)

      refute moved == key
    end

    test "off is quiet, so the wait runs out with the summary as it is", ctx do
      opts = opts(ctx.home, ctx.waits)
      {:ok, %{"summary" => %{"key" => key}}} = route("home.status", %{}, opts)

      waiting =
        Task.async(fn -> route("home.status", %{"after" => key, "wait_ms" => 5_000}, opts) end)

      assert_receive {:wait_timer, pid, {:home_status_wait, _token} = expiry, 5_000}
      send(pid, expiry)

      assert {:ok, %{"summary" => %{"state" => "off", "key" => ^key}}} =
               Task.await(waiting, 10_000)
    end

    test "the wait is asked for whole, and for at most 25 seconds", ctx do
      opts = opts(ctx.home, ctx.waits)

      assert {:error, :invalid_params, %{"field" => "wait_ms"}} =
               route("home.status", %{"after" => "k"}, opts)

      assert {:error, :invalid_params, %{"field" => "after"}} =
               route("home.status", %{"wait_ms" => 1_000}, opts)

      assert {:error, :invalid_params, %{"field" => "wait_ms"}} =
               route("home.status", %{"after" => "k", "wait_ms" => 25_001}, opts)

      assert {:error, :invalid_params, %{"field" => "x"}} =
               route("home.status", %{"x" => 1}, opts)
    end
  end

  defp jobs!(ctx) do
    tasks = :"home_tasks_#{:erlang.phash2(ctx.test)}"
    start_supervised!({Task.Supervisor, name: tasks}, id: tasks)
    name = :"home_jobs_#{:erlang.phash2(ctx.test)}"
    start_supervised!({Jobs, name: name, task_supervisor: tasks})
    [server: name]
  end

  defp jobs(jobs) do
    {:ok, views} = Jobs.list(jobs)
    views
  end

  defp nimbus_seams(world) do
    [
      providers: [FakeCloudProvider],
      provider_opts: [
        world: world,
        now: fn -> @at end,
        sleep: fn _ms -> :ok end,
        open_code: fn -> {:ok, "fxenroll1.eyJ2IjoxLCJuYW1lIjoiaW52ZW50ZWQifQ"} end,
        withdraw_code: fn -> :ok end
      ],
      open_code: fn -> {:ok, "fxenroll1.eyJ2IjoxLCJuYW1lIjoiaW52ZW50ZWQifQ"} end,
      withdraw_code: fn -> :ok end
    ]
  end

  # The job's end is its completion event; one that ended before the handler
  # was attached is read as it stands.
  defp finished(%{"job_id" => id}, jobs) do
    TelemetryCapture.attach([[:fermix, :management_job, :complete]], session_id: id)

    case Jobs.get(id, jobs) do
      {:ok, %{"status" => "running"}} ->
        assert_receive {:telemetry, _event, _measurements, %{session_id: ^id}}, 10_000
        {:ok, view} = Jobs.get(id, jobs)
        view

      {:ok, view} ->
        view
    end
  end

  test "a status file the scheduler wrote is what the view reads", %{
    home: home,
    recipient: recipient
  } do
    attempt = %{
      at: ~U[2026-10-27 09:30:00Z],
      result: :verified,
      name: "20261027T093000Z-e4.fxsnap",
      epoch: 4,
      size: 48_211,
      sha256: String.duplicate("c", 64),
      location: "s3://invented-bucket/fermix/general/20261027T093000Z-e4.fxsnap",
      error: nil
    }

    :ok = Status.write(home, Status.record(Status.empty(), "s3", attempt))
    config = [recipient: recipient, s3_bucket: "invented-bucket"]

    assert {:ok, view} = route("home.snapshots.status", %{}, opts(home, config: config))
    assert view["sentence"] == "The last snapshot was stored at 2026-10-27 09:30 UTC."

    assert [
             %{"id" => "s3", "last_verified" => %{"name" => "20261027T093000Z-e4.fxsnap"}},
             %{"id" => "desktop", "configured" => false}
           ] = view["targets"]
  end

  defp disk(used), do: fn _home -> {:ok, %{used: used, nearly_full: used >= 0.85}} end

  # The rail's facts, as the `link_status` seam answers them.
  defp link(overrides) do
    status = Map.merge(%{primary: nil, desktops: [], enrollment: nil}, Map.new(overrides))
    fn -> status end
  end

  defp provisioned(state, candidate_id) do
    %{
      state: state,
      expires_at: ~U[2031-05-05 10:00:00Z],
      kind: :provisioned,
      candidate_id: candidate_id,
      awake_ms: 60_000
    }
  end

  defp primary(down_ms) do
    %{
      name: "invented-vm",
      connected: down_ms == nil,
      status: if(down_ms, do: :unreachable, else: :connected),
      since: if(down_ms, do: nil, else: @at),
      epoch: 5,
      sentence: "The link's own words.",
      down_ms: down_ms
    }
  end

  defp server do
    %{
      name: "fermix-general-a3f9",
      id: "61839204",
      status: :created,
      type: "cpx22",
      location: "fsn1",
      ipv4: "203.0.113.7",
      power: "running",
      created_at: @at,
      seen_at: @at
    }
  end

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

  defp desktop_link do
    %{
      device_id: "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e",
      primary: %{
        name: "invented-vm",
        gateway_pk: :binary.copy(<<3>>, 32),
        node_id: String.duplicate("c4", 32),
        relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
        relays_rev: String.duplicate("a1", 8)
      },
      epoch: 5
    }
  end

  defp route(method, params, opts) do
    Router.route(
      %{request_id: "req-1", protocol_version: 2, method: method, params: params},
      opts
    )
  end

  defp opts(home, extra \\ []) do
    home_opts =
      Keyword.merge(
        [
          home: home,
          engine_role: @primary,
          config: [],
          scheduler: nil,
          profile: "general",
          now: @at,
          disk_usage: disk(0.42)
        ],
        extra
      )

    [operation_opts: [home: home_opts]]
  end

  # The server answering a desktop's forward over the rail, the one caller
  # `home.snapshots.run` is served to.
  defp forwarded(opts), do: Keyword.put(opts, :actor, @desktop)

  defp scheduler!(home, config, extra \\ []) do
    name = :"snapshot_scheduler_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Scheduler,
       [
         name: name,
         home: home,
         config: fn -> config end,
         now: fn -> ~U[2026-10-27 09:00:00Z] end,
         timer: fn _message, _delay -> make_ref() end
       ] ++ extra}
    )

    name
  end
end
