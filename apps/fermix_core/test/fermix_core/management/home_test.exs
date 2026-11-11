defmodule FermixCore.Management.HomeTest do
  use ExUnit.Case, async: true

  alias FermixCore.Computers.Computer
  alias FermixCore.Cues.Config, as: CuesConfig
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Candidates
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.EnrollmentCode
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Move
  alias FermixCore.Home.Moved
  alias FermixCore.Home.Releases
  alias FermixCore.Home.Return
  alias FermixCore.Home.Snapshot.Capture
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Home.Snapshot.Scheduler
  alias FermixCore.Home.Snapshot.Status
  alias FermixCore.Home.StatusWatch
  alias FermixCore.Management.Home
  alias FermixCore.Management.HomeSummary
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.Router
  alias FermixCore.Setup.MachineFile
  alias FermixTestSupport.SafeRm

  @primary %{role: :primary, primary: nil}
  @device %{role: :device, primary: "invented host"}
  @desktop {:desktop, "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e"}
  @passphrase "invented-lighthouse-meridian"
  @at ~U[2031-05-04 12:00:00Z]
  @mac_id "5b2e7c1a-9d43-4f08-b6a1-3c7e9f2d8a54"
  @linux_id "8e4a1f6c-2b7d-4c95-a3e0-6d1b9c8f7e23"

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

    # Step 7: whether the link runs direct or through Fermix's relay, as the
    # helper reports it; absent while no session is up.
    test "a desktop's primary names the link's path while it is connected", %{home: home} do
      link = fn path, connected ->
        fn ->
          %{
            primary: %{
              name: "invented-vm",
              connected: connected,
              status: if(connected, do: :connected, else: :unreachable),
              since: nil,
              epoch: 5,
              sentence: "Fermix is connected to the server invented-vm.",
              path: path
            },
            desktops: [],
            enrollment: nil
          }
        end
      end

      for {path, connected, word} <- [
            {:direct, true, "direct"},
            {:relay, true, "relay"}
          ] do
        assert {:ok, status} =
                 route(
                   "home.status",
                   %{},
                   opts(home, engine_role: @device, link_status: link.(path, connected))
                 )

        assert status["primary"]["path"] == word
      end

      for {path, connected} <- [{nil, true}, {nil, false}] do
        assert {:ok, status} =
                 route(
                   "home.status",
                   %{},
                   opts(home, engine_role: @device, link_status: link.(path, connected))
                 )

        refute Map.has_key?(status["primary"], "path")
      end
    end

    test "a home that never booted as the primary has no epoch yet", %{home: home} do
      SafeRm.rm!(Epoch.path(home))

      assert {:ok, %{"epoch" => nil}} = route("home.status", %{}, opts(home))
    end

    # Always On's move back, §3.1 M7: the primary's boot records that this
    # computer took Fermix back (`Home.Return.done/2`); one it could not record
    # is tried again at each read, as an ending of a move is.
    test "a move back the primary's boot could not record is recorded by the next read",
         %{home: home} do
      :ok = Return.write(home, %{from: "north-box", started_at: ~U[2031-05-04 11:00:00Z]})

      # Nothing is written by an engine whose boot recorded it, or by a device.
      assert {:ok, _status} = route("home.status", %{}, opts(home, return_boot: :recorded))

      assert {:ok, _status} =
               route(
                 "home.status",
                 %{},
                 opts(home, return_boot: :unrecorded, engine_role: @device)
               )

      assert {:ok, record} = Return.read(home)
      refute Map.has_key?(record, :moved_at)

      assert {:ok, _status} = route("home.status", %{}, opts(home, return_boot: :unrecorded))
      assert {:ok, %{moved_at: @at, epoch: 4}} = Return.read(home)
    end

    # M97 §3.4, the server leads: an Always On server's update installs the
    # newest release whose app is published for each system of the computers
    # that keep its backups, read from the release table it keeps;
    # `update_ceiling` is that release, the field every update script reads.
    test "a server's update is the newest release its backup holders' apps carry",
         %{home: home} do
      table = release_table(["app 9.9.10 macos 3.1.0", "app 9.10.0 linux 1.4.0"])
      at = ~U[2031-05-04 11:55:00Z]
      server = [always_on_server: true, release_table: fn -> {:ok, table, at, nil} end]

      mac = computer("studio-mac", :macos, true)
      linux = computer("loft-linux", :linux, false)

      assert {:ok, %{"update" => update, "update_ceiling" => "9.9.10"}} =
               route("home.status", %{}, opts(home, server ++ [computers: [mac, linux]]))

      assert update == %{
               "running" => "9.9.9",
               "eligible" => "9.9.10",
               "held" => %{
                 "version" => "9.10.0",
                 "waits_for" => ["macos"],
                 "sentence" =>
                   "A newer Fermix is released. Your server takes it once the Mac app that " <>
                     "carries it is published."
               },
               "ahead_of_apps" => false,
               "table" => %{"read_at" => "2031-05-04T11:55:00Z", "sentence" => nil}
             }

      # A computer that keeps no backups holds nothing back.
      assert {:ok, %{"update_ceiling" => "9.10.0"}} =
               route("home.status", %{}, opts(home, server ++ [computers: [linux]]))

      # Not a server: no update, and no ceiling.
      assert {:ok, %{"update" => nil, "update_ceiling" => nil}} =
               route("home.status", %{}, opts(home, computers: [mac]))

      assert {:ok, %{"update" => nil, "update_ceiling" => nil}} =
               route("home.status", %{}, opts(home, engine_role: @device))
    end

    # The table fails closed: none read yet is no eligible release, with the
    # sentence that says why, so the update installs nothing.
    test "a server with no table read installs nothing, and says why", %{home: home} do
      failed = fn -> {:error, "An invented failure to read the table."} end
      server = [always_on_server: true, release_table: failed, computers: []]

      assert {:ok, %{"update" => update, "update_ceiling" => nil}} =
               route("home.status", %{}, opts(home, server))

      assert %{
               "eligible" => nil,
               "held" => nil,
               "ahead_of_apps" => false,
               "table" => %{
                 "read_at" => nil,
                 "sentence" => "An invented failure to read the table."
               }
             } = update
    end

    # §3.4: a restart waits for a move, and for work in progress on a
    # computer at most ten minutes.
    test "the restart hold names a move, then a computer's work", %{home: home} do
      assert {:ok, %{"restart_hold" => nil}} = route("home.status", %{}, opts(home))

      work = fn -> [%{started_at: DateTime.add(@at, -240, :second)}] end

      assert {:ok, %{"restart_hold" => %{"reason" => "computer_work", "count" => 1} = hold}} =
               route("home.status", %{}, opts(home, computer_work: work))

      assert hold["wait_s"] == 360
    end

    # M97 §3.2: each offer carries the words it goes by, from its offer
    # module (the core ones and those beside the link alike), so an app that
    # keeps no list of offers can name it; one a newer computer offers that
    # this engine has no module for has none. A linked computer reading its
    # server's list over the rail finds its own row marked, and only there.
    test "each offer has its words, and the row of the computer that asks is marked",
         %{home: home} do
      offers = [
        %{id: "shell", state: :on, sentence: nil, detail: "strict"},
        %{id: "voice", state: :off, sentence: "Switched off on this Mac.", detail: nil},
        %{id: "lantern", state: :on, sentence: nil, detail: nil}
      ]

      mac = %{computer("studio-mac", :macos, true) | offers: offers}
      linux = computer("loft-linux", :linux, false)
      listed = opts(home, computers: [mac, linux])

      assert {:ok, %{"computers" => [studio, loft]}} =
               route("home.status", %{}, Keyword.put(listed, :actor, {:desktop, @mac_id}))

      assert Enum.map(studio["offers"], &{&1["id"], &1["label"]}) == [
               {"shell", "commands"},
               {"voice", "voice calls"},
               {"lantern", nil}
             ]

      assert {studio["this_computer"], loft["this_computer"]} == {true, false}

      # The server's own app and its setup page are no computer of the home.
      for asked <- [listed, Keyword.put(listed, :actor, :setup_page)] do
        assert {:ok, %{"computers" => rows}} = route("home.status", %{}, asked)
        assert Enum.map(rows, & &1["this_computer"]) == [false, false]
      end
    end

    # Always On's inbound webhooks (design, "Inbound webhooks without a public
    # IP"): the primary names what it serves on loopback that the internet
    # must reach, from its own settings: WhatsApp when its channel is on, on
    # the web listener's port, and each enabled webhook source with a URL, on
    # the door's port. Whether a source has a URL is its sentinel in the
    # settings, never a read of the secret store.
    test "the primary names the webhooks it serves, from its own settings", %{home: home} do
      settings = webhook_settings(whatsapp: [enabled: true], web_port: 4130)

      assert {:ok, status} =
               route("home.status", %{}, opts(home, webhook_settings: fn -> settings end))

      assert status["webhooks"] == [
               %{"kind" => "whatsapp", "ref" => nil, "port" => 4130},
               %{"kind" => "cue", "ref" => "github", "port" => 4532},
               %{"kind" => "cue", "ref" => "stripe", "port" => 4532}
             ]

      quiet = webhook_settings(whatsapp: [enabled: false], sources: %{})

      assert {:ok, %{"webhooks" => []}} =
               route("home.status", %{}, opts(home, webhook_settings: fn -> quiet end))
    end

    # `fermix home status` with Fermix stopped reads the record with no engine
    # tree (`supervised: false`): a stopped Fermix serves nothing, and the web
    # listener's port, which only the running daemon bound, is never resolved.
    test "a stopped primary serves no webhook, and nothing is read for it", %{home: home} do
      unread = fn -> flunk("the webhook settings were read with no engine tree") end

      assert {:ok, %{"webhooks" => []}} =
               route("home.status", %{}, opts(home, supervised: false, webhook_settings: unread))
    end

    # The values are the server's: a desktop serves none of its own, and its
    # screen prints the server's, as the server's own `home.status` names them.
    test "a desktop names none of its own and prints its server's", %{home: home} do
      :ok = DesktopLink.write(home, desktop_link())
      :ok = Moved.write(home, %{epoch: 4, moved_at: @at, to: "invented-vm"})
      mac = webhook_settings(whatsapp: [enabled: true], web_port: 4030)

      server_part = %{
        "role" => "primary",
        "version" => "9.9.8",
        "snapshots" => %{"targets" => []},
        "webhooks" => [%{"kind" => "whatsapp", "ref" => nil, "port" => 4130}]
      }

      forward = fn _request, _opts -> {:ok, server_part} end

      assert {:ok, status} =
               route(
                 "home.status",
                 %{},
                 opts(home,
                   engine_role: @device,
                   link_status: link(primary: primary(nil)),
                   webhook_settings: fn -> mac end
                 )
                 |> Keyword.put(:primary_forward, forward)
               )

      assert status["webhooks"] == []
      assert %{"state" => "on", "detail" => %{"webhooks" => webhooks}} = status["summary"]

      assert [
               %{
                 "label" => "WhatsApp",
                 "command" =>
                   "sudo tailscale funnel --bg --set-path=/webhook/whatsapp " <>
                     "http://127.0.0.1:4130/webhook/whatsapp",
                 "note" => "Tailscale prints the address this gives." <> _rest
               }
             ] = webhooks["mounts"]
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
  # its sources a real file in a temp home or an injected seam: the
  # candidates, the window and link as the rail says them, the review, the
  # disk, the server's own part, this desktop's copies and its restore job.
  describe "home.status's summary" do
    test "a primary with nothing says off, and publishes its disk and version", %{home: home} do
      assert {:ok, status} =
               route("home.status", %{}, opts(home, disk_usage: disk(0.42), version: "9.9.9"))

      assert status["summary"]["state"] == "off"
      assert status["summary"]["action"]["id"] == "own_server"
      assert status["summary"]["key"] == HomeSummary.key(status["summary"])
      assert status["disk"] == %{"used" => 0.42, "nearly_full" => false}
      assert status["version"] == "9.9.9"
    end

    test "off names what this home uses that stops after the move, read from its settings",
         %{home: home} do
      File.write!(Path.join(home, "config.toml"), """
      [fermix_core.realtime]
      enabled = false

      [fermix_core.meetings]
      enabled = true
      """)

      # This Mac carries Messages for the server after a move (M97 §6.4), so
      # iMessage on is not among what stops.
      File.write!(MachineFile.path(home), "[fermix_core.computer]\nimessage = true\n")

      File.write!(
        Path.join(home, "config.toml"),
        File.read!(Path.join(home, "config.toml")) <>
          "\n[fermix_channels.imessage]\nenabled = true\n"
      )

      assert {:ok, %{"summary" => summary}} =
               route("home.status", %{}, opts(home, host_os: :macos))

      assert summary["sentence"] ==
               "Keep Fermix running when this Mac sleeps. It moves to a server you own. " <>
                 "Meetings stop after the move."

      File.write!(Path.join(home, "config.toml"), "")
      File.write!(MachineFile.path(home), "")

      assert {:ok, %{"summary" => %{"sentence" => sentence}}} =
               route("home.status", %{}, opts(home, host_os: :macos))

      assert sentence == "Keep Fermix running when this Mac sleeps. It moves to a server you own."
    end

    test "a server held with its code makes ready, with the last review's warnings",
         %{home: home} do
      {:ok, held} = Candidates.add(home, candidate_attrs(), @at)
      report = %{ready: true, items: [%{id: "whatsapp", status: :warn, sentence: "Warned."}]}
      :ok = Move.put_review(home, held.candidate_id, report, @at)

      window = manual(:used, held.candidate_id)

      assert {:ok, %{"summary" => summary}} =
               route("home.status", %{}, opts(home, link_status: link(enrollment: window)))

      assert summary["state"] == "ready"
      assert summary["action"]["id"] == "move_now"

      assert summary["detail"]["readiness"] == [
               %{"id" => "whatsapp", "status" => "warn", "sentence" => "Warned."}
             ]

      assert summary["detail"]["server"]["name"] == "fermix-general-a3f9"
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

    # Always On's move back (design §9, §14): a desktop's screen reads its own
    # candidate for the home and the return's record, and the copies it keeps.
    test "a desktop moving back reads its candidate and the return's record", %{home: home} do
      :ok = DesktopLink.write(home, desktop_link())
      :ok = Moved.write(home, %{epoch: 4, moved_at: @at, to: "invented-vm"})
      enrolled!(home)
      :ok = Return.write(home, %{from: "invented-vm", started_at: @at, primary_epoch: 5})

      assert {:ok, %{"summary" => summary}} = desktop_status(home, link(primary: primary(nil)))

      assert summary["state"] == "ready"
      assert summary["sentence"] == "This computer is ready to take Fermix back."
      assert summary["action"]["id"] == "move_now"
    end

    test "a server it cannot reach offers Restore here with the newest copy it keeps",
         %{home: home} do
      :ok = DesktopLink.write(home, desktop_link())
      :ok = Moved.write(home, %{epoch: 4, moved_at: @at, to: "invented-vm"})
      File.mkdir_p!(Capture.dir(home))

      for name <- ~w(20310503T100000Z-e5.fxsnap 20310504T100000Z-e5.fxsnap notes.fxsnap) do
        File.write!(Path.join(Capture.dir(home), name), "a copy")
      end

      assert {:ok, %{"summary" => summary}} =
               desktop_status(home, link(primary: primary(11 * 60_000)))

      assert "restore_here" in Enum.map(HomeSummary.offered(summary), & &1["id"])

      assert %{
               "label" => "Backup on this computer",
               "value" => "Sunday, May 4, 2031 at 10:00 AM UTC"
             } in summary[
               "detail"
             ]["lines"]
    end

    # A second desktop's move back the home went past (design §14): the link
    # reached a newer epoch than the one it was asked at, so its candidate is
    # stopped and removed with the record, saying nothing.
    test "a move back the home went past is discarded at the next read", %{home: home} do
      test = self()
      :ok = DesktopLink.write(home, desktop_link())
      :ok = Moved.write(home, %{epoch: 4, moved_at: @at, to: "invented-vm"})
      enrolled!(home)
      :ok = Return.write(home, %{from: "invented-vm", started_at: @at, primary_epoch: 5})

      stop = fn ->
        send(test, :return_stopped)
        :ok
      end

      ahead = link(primary: %{primary(nil) | epoch: 7})

      assert {:ok, %{"summary" => summary}} = desktop_status(home, ahead, stop_return: stop)

      assert_received :return_stopped
      refute File.exists?(Path.join(home, "candidate"))
      assert Return.read(home) == :absent
      assert summary["state"] == "on"

      # The record of this computer's own move back is never one.
      :ok =
        Return.write(home, %{
          from: "invented-vm",
          started_at: @at,
          primary_epoch: 5,
          moved_at: @at,
          epoch: 6
        })

      assert {:ok, _status} = desktop_status(home, ahead, stop_return: stop)
      refute_received :return_stopped
      assert {:ok, %{moved_at: @at}} = Return.read(home)
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

    # M97 §3.4: a desktop stands against its server's version by
    # major.minor: past the window it keeps settings alone and is asked to
    # update; a newer server inside it takes Move back's place with Update.
    test "a desktop reads where it stands against its server's version", %{home: home} do
      :ok = DesktopLink.write(home, desktop_link())
      :ok = Moved.write(home, %{epoch: 4, moved_at: @at, to: "invented-vm"})

      status_with = fn server_version ->
        part = %{"role" => "primary", "version" => server_version, "snapshots" => %{}}

        {:ok, status} =
          route(
            "home.status",
            %{},
            opts(home,
              engine_role: @device,
              link_status: link(primary: primary(nil)),
              restarts_itself: true
            )
            |> Keyword.put(:primary_forward, fn _request, _opts -> {:ok, part} end)
          )

        status["summary"]
      end

      assert %{"state" => "problem", "detail" => %{"kind" => "update"}} = status_with.("9.12.0")

      inside = status_with.("9.10.1")
      assert inside["state"] == "on"
      assert "update" in Enum.map(inside["detail"]["actions"], & &1["id"])
      refute "move_back" in Enum.map(inside["detail"]["actions"], & &1["id"])

      assert "move_back" in Enum.map(status_with.("9.9.0")["detail"]["actions"], & &1["id"])
    end

    # Review M4: a desktop that updated first meets a server on an older
    # protocol until its update takes this version, which the screen
    # says.
    test "a server older than this desktop says when it takes this version", %{home: home} do
      :ok = DesktopLink.write(home, desktop_link())
      older = fn _request, _opts -> {:error, :daemon_too_old, %{"maximum_version" => 2}} end

      assert {:ok, status} =
               route(
                 "home.status",
                 %{},
                 opts(home, engine_role: @device, link_status: link(primary: primary(nil)))
                 |> Keyword.put(:primary_forward, older)
               )

      assert status["summary"]["state"] == "problem"
      assert status["summary"]["detail"]["kind"] == "server_older"
      assert status["summary"]["action"]["id"] == "learn_more"
      assert status["primary_home"] == nil
      assert is_binary(status["primary_missing"])
    end

    # Review M2: a held server whose 24 hours ran out, which the window
    # names and the list still holds, is told as lapsed; one forgotten, or
    # one this home moved to and back from since it enrolled, is not.
    test "a held server whose day ran out is told as lapsed until it is forgotten",
         %{home: home} do
      {:ok, held} = Candidates.add(home, candidate_attrs(), ~U[2031-05-03 11:00:00Z])
      status = opts(home, link_status: link(enrollment: manual(:used, held.candidate_id)))

      assert {:ok, %{"summary" => summary}} = route("home.status", %{}, status)
      assert summary["state"] == "off"
      assert summary["notice"]["id"] == "server_lapsed:" <> held.candidate_id

      :ok = Return.write(home, %{from: "studio-mac", started_at: @at, moved_at: @at, epoch: 6})
      assert {:ok, %{"summary" => %{"notice" => nil}}} = route("home.status", %{}, status)

      # A move back that came home before this server enrolled is no reason
      # to keep quiet: the owner set this one up after it.
      earlier = ~U[2031-05-02 08:00:00Z]

      :ok =
        Return.write(home, %{from: "studio-mac", started_at: earlier, moved_at: earlier, epoch: 6})

      assert {:ok, %{"summary" => %{"notice" => %{"id" => "server_lapsed:" <> _id}}}} =
               route("home.status", %{}, status)

      :ok = Return.remove(home)
      :ok = Candidates.remove(home, held.candidate_id, @at)
      assert {:ok, %{"summary" => %{"notice" => nil}}} = route("home.status", %{}, status)
    end

    # Re-check note 5: a desktop's candidate for a move back (`returning`)
    # is never a server to set up again, so its day running out is not told.
    test "a move back's candidate whose day ran out is not told as lapsed", %{home: home} do
      attrs = Map.put(candidate_attrs(), :returning, "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e")
      {:ok, back} = Candidates.add(home, attrs, ~U[2031-05-03 11:00:00Z])
      status = opts(home, link_status: link(enrollment: manual(:used, back.candidate_id)))

      assert {:ok, %{"summary" => summary}} = route("home.status", %{}, status)
      assert summary["state"] == "off"
      assert summary["notice"] == nil
    end

    # Re-check note 6: a move's record that cannot be read is said in the
    # log, never taken as "not moved back" without a word.
    test "a retired copy whose move's record cannot be read says why in the log",
         %{home: home} do
      :ok = Moved.write(home, %{epoch: 5, moved_at: @at, to: "studio-mac"})
      File.mkdir_p!(Move.dir(home))
      File.write!(Path.join(Move.dir(home), "phase.json"), "{")
      device = %{role: :device, primary: "studio-mac"}
      seams = opts(home, engine_role: device, host_os: :linux, unreadable_files: nil)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{"summary" => %{"state" => "retired"}}} =
                   route("home.status", %{}, seams)
        end)

      assert log =~ "phase.json could not be read"
    end

    # Review m4: the server's own copy after a move back names where Fermix
    # went, from its move's own record.
    test "a server's copy retired by a move back says where Fermix moved back to",
         %{home: home} do
      :ok = Moved.write(home, %{epoch: 5, moved_at: @at, to: "studio-mac"})
      File.mkdir_p!(Move.dir(home))

      :ok =
        Move.put_phase(
          home,
          "done",
          %{"candidate" => "studio-mac", "keep_as_desktop" => false},
          @at
        )

      device = %{role: :device, primary: "studio-mac"}

      assert {:ok, %{"summary" => summary}} =
               route("home.status", %{}, opts(home, engine_role: device, host_os: :linux))

      assert summary["state"] == "retired"
      assert summary["sentence"] == "This copy is retired: Fermix moved back to studio-mac."
    end

    # Review m3: Restore here finished is told once on the primary it made,
    # naming the backup's day.
    test "a restore finished here is told by its epoch and its backup's day", %{home: home} do
      :ok =
        Return.write(home, %{
          from: "invented-vm",
          started_at: @at,
          restored: "20310503T093000Z-e5.fxsnap",
          moved_at: @at,
          epoch: 6
        })

      assert {:ok, %{"summary" => %{"notice" => notice}}} =
               route("home.status", %{}, opts(home, host_os: :macos))

      assert notice == %{
               "id" => "restored:6",
               "sentence" =>
                 "Fermix runs on this Mac again, from its backup of Saturday, May 3, 2031."
             }
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

    # D18: a primary that is no Always On server has no target, so its bucket
    # is never written and a run is refused in the status's own words.
    test "a primary that is no Always On server keeps none", %{home: home, recipient: recipient} do
      config = [recipient: recipient, s3_bucket: "invented-bucket"]
      scheduler = scheduler!(home, config, targets: [])
      opts = forwarded(opts(home, config: config, scheduler: scheduler, snapshot_targets: []))
      sentence = "Snapshots are kept only by an Always On server, and this computer is not one."

      assert route("home.snapshots.run", %{}, opts) ==
               {:error, :unavailable, %{"capability" => "snapshots", "sentence" => sentence}}

      assert {:ok, %{"configured" => false, "targets" => [], "sentence" => ^sentence}} =
               route("home.snapshots.status", %{}, opts)
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

  # Restore here's job (`home_restore`) runs on this desktop: a read draws it
  # running beside the return's request for it, from the job family's own
  # record, and draws nothing of it once the job is gone.
  describe "home.status reads Restore here's job" do
    test "a restore asked for and running is moving; one beside no job is not", ctx do
      %{home: home} = ctx
      :ok = DesktopLink.write(home, desktop_link())
      :ok = Moved.write(home, %{epoch: 4, moved_at: @at, to: "invented-vm"})

      :ok =
        Return.write(home, %{
          from: "invented-vm",
          started_at: @at,
          restore_requested: "20310504T100000Z-e5.fxsnap"
        })

      jobs = jobs!(ctx)
      silent = link(primary: primary(11 * 60_000))

      assert {:ok, %{"summary" => %{"state" => "problem"}}} =
               desktop_status(home, silent, jobs: jobs)

      test = self()

      {:ok, _view} =
        Jobs.start(:home_restore,
          name: "restore_here",
          server: jobs[:server],
          run: fn _id, _report ->
            send(test, {:restoring, self()})
            receive do: (:go -> {:ok, %{}})
          end
        )

      assert_receive {:restoring, run}, 10_000

      assert {:ok, %{"summary" => %{"state" => "moving", "sentence" => sentence}}} =
               desktop_status(home, silent, jobs: jobs)

      assert sentence =~ "Restoring Fermix on this computer from its backup."
      send(run, :go)
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

      {:ok, _held} = Candidates.add(ctx.home, candidate_attrs(), @at)
      :ok = StatusWatch.changed(ctx.watch, :enrollment)

      assert {:ok, %{"summary" => %{"state" => "ready", "key" => moved}}} =
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

  # What `home.status` reads the webhooks a primary serves from: the WhatsApp
  # channel's settings, the cues section (two webhook sources with a URL, one
  # without yet, one switched off, and a feed) and the web listener's port.
  defp webhook_settings(overrides) do
    hooks = %{"preset" => "github", "secret" => "@file", "path_secret" => "@file"}

    sources =
      Keyword.get(overrides, :sources, %{
        "github" => hooks,
        "stripe" => hooks,
        "fresh-hooks" => Map.delete(hooks, "path_secret"),
        "off-hooks" => Map.put(hooks, "enabled", false),
        "eng-blogs" => %{"preset" => "rss", "url" => "https://example.org/releases.atom"}
      })

    %{
      whatsapp: Keyword.fetch!(overrides, :whatsapp),
      cues: CuesConfig.normalize(%{"door_port" => 4532, "sources" => sources}),
      web_port: Keyword.get(overrides, :web_port, 4030)
    }
  end

  defp manual(state, candidate_id) do
    %{
      state: state,
      expires_at: ~U[2031-05-04 12:30:00Z],
      candidate_id: candidate_id
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
      key: :keyring,
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

  defp desktop_status(home, link, extra \\ []) do
    forward = fn _request, _opts -> {:ok, %{"role" => "primary", "version" => "9.9.9"}} end

    route(
      "home.status",
      %{},
      opts(home, [engine_role: @device, link_status: link, host_os: :linux] ++ extra)
      |> Keyword.put(:primary_forward, forward)
    )
  end

  # This desktop's candidate for a move back, enrolled with its server.
  defp enrolled!(home) do
    {:ok, code} =
      EnrollmentCode.encode(%{
        secret: :binary.copy(<<9>>, 32),
        gateway_pk: :binary.copy(<<3>>, 32),
        node_id: String.duplicate("c4", 32),
        relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
        relays_rev: String.duplicate("a1", 8),
        name: "invented-vm",
        expires_at: ~U[2031-05-04 12:30:00Z]
      })

    {:ok, state} =
      Candidate.prepare_return(home, {:return, code},
        now: @at,
        role: :device,
        restarts_itself?: true
      )

    enrolled =
      Map.merge(state, %{
        "phase" => "enrolled",
        "candidate_id" => "cand-7a3e1c9b5d2f4086",
        "listen_until" => "2031-05-05T12:00:00Z"
      })

    :ok = Candidate.put_state(home, enrolled, @at)
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
          disk_usage: disk(0.42),
          # An Always On server's primary, unless a test says otherwise (D18).
          snapshot_targets: Scheduler.targets(:server),
          # The live channel and cue settings are global: a home here serves none.
          webhook_settings: fn -> %{whatsapp: [], cues: [], web_port: 4030} end,
          # This engine's version, which a desktop's server stands against
          # (M97 §3.4): the servers here run 9.9.8 and 9.9.9.
          version: "9.9.9"
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
       Keyword.merge(
         [
           name: name,
           home: home,
           config: fn -> config end,
           targets: Scheduler.targets(:server),
           now: fn -> ~U[2026-10-27 09:00:00Z] end,
           timer: fn _message, _delay -> make_ref() end
         ],
         extra
       )}
    )

    name
  end

  # A release table pinning 9.9.9, 9.9.10 and 9.10.0, with `rows` after.
  defp release_table(rows) do
    digests =
      for version <- ["9.9.9", "9.9.10", "9.10.0"],
          do: "#{version} #{String.duplicate("d", 64)} fermix_always_on.sh"

    text = Enum.join(["format 1", "latest 9.10.0"] ++ digests ++ rows, "\n") <> "\n"
    {:ok, table} = Releases.parse(text)
    table
  end

  defp computer(name, platform, backups),
    do: %Computer{
      device_id: if(platform == :macos, do: @mac_id, else: @linux_id),
      name: name,
      platform: platform,
      backups: backups
    }
end
