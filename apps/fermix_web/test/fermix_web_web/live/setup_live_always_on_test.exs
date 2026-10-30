defmodule FermixWebWeb.SetupLiveAlwaysOnTest do
  # The setup page's Always On tab (M75 §14, B14) and the device role's word on
  # the rest of the page. Every fact comes from `Management.Home.status/1` over
  # a temp FERMIX_HOME: candidates, the move's phase, the moved marker and the
  # snapshot status are real files the core modules write; the rail's facts
  # (the primary, the desktops, the enrollment window) come from a scripted
  # `link_status`, and every later read is handed to the case instead of a
  # clock. Every secret goes through the stub.
  use FermixWebWeb.ConnCase

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias FermixCore.Home.Candidates
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Move
  alias FermixCore.Home.Moved
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Home.Snapshot.S3
  alias FermixCore.Home.Snapshot.Scheduler
  alias FermixCore.Home.Snapshot.Settings, as: SnapshotSettings
  alias FermixCore.Home.Snapshot.Status
  alias FermixCore.Setup.RestartState
  alias FermixTestSupport.SecretWriterStub

  @now ~U[2026-10-27 12:00:00Z]
  @code "fxenroll1.eyJ2IjoxLCJpbnZlbnRlZCI6IjQ0MTAifQ"
  @code_expires ~U[2026-10-27 12:10:00Z]
  @primary %{role: :primary, primary: nil}
  @device %{role: :device, primary: "invented-vm"}
  @desktop_id "6d2b3c1e-1f7a-4c55-9a3e-2b8f6e0c4d71"
  @server_candidate_id "cand-7a1c2e3f4b5d6e70"

  setup %{conn: conn} do
    saved = %{
      core:
        Map.new(
          ~w(providers agent secret_writer tools transcription realtime meetings harness routing
             plugins plugins_dist_opts oauth cues personalization engine snapshots)a,
          &{&1, Application.fetch_env(:fermix_core, &1)}
        ),
      web:
        Map.new(
          ~w(harness_detector imessage_macos? local_transcription_opts cues_pane_opts always_on
             engine_role)a,
          &{&1, Application.fetch_env(:fermix_web, &1)}
        ),
      channels:
        Map.new(~w(telegram imessage)a, &{&1, Application.fetch_env(:fermix_channels, &1)}),
      home: System.get_env("FERMIX_HOME")
    }

    tmp_home = FermixTestSupport.SafeRm.make_tmp_dir!("setup-live-always-on")
    System.put_env("FERMIX_HOME", tmp_home)
    SecretWriterStub.reset()
    :ok = RestartState.record_persisted_baseline()

    Application.put_env(:fermix_core, :providers, [])
    Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai)
    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    Application.put_env(:fermix_core, :tools, [])

    Application.put_env(:fermix_core, :transcription,
      backend: "openai",
      model: "gpt-4o-mini-transcribe",
      max_file_mb: 20
    )

    Application.put_env(:fermix_core, :realtime, [])
    Application.put_env(:fermix_core, :meetings, enabled: false)
    Application.put_env(:fermix_core, :harness, [])
    Application.put_env(:fermix_core, :routing, [])
    Application.put_env(:fermix_core, :plugins, [])
    Application.put_env(:fermix_core, :plugins_dist_opts, [])
    Application.put_env(:fermix_core, :oauth, %{})
    Application.put_env(:fermix_core, :cues, [])
    Application.put_env(:fermix_core, :personalization, [])
    Application.put_env(:fermix_core, :engine, [])
    Application.put_env(:fermix_core, :snapshots, [])
    Application.delete_env(:fermix_channels, :telegram)
    Application.put_env(:fermix_channels, :imessage, enabled: false)
    Application.put_env(:fermix_web, :imessage_macos?, false)

    Application.put_env(:fermix_web, :local_transcription_opts,
      releases: FermixTestSupport.SttPins.for_this_host()
    )

    Application.put_env(:fermix_web, :harness_detector, fn -> %{} end)
    Application.put_env(:fermix_web, :cues_pane_opts, now: fn -> @now end)
    put_role(@primary)

    on_exit(fn ->
      Enum.each(saved.core, fn {key, value} -> restore_env(:fermix_core, key, value) end)
      Enum.each(saved.web, fn {key, value} -> restore_env(:fermix_web, key, value) end)
      Enum.each(saved.channels, fn {key, value} -> restore_env(:fermix_channels, key, value) end)
      SecretWriterStub.delete(:snapshot_s3_access_key_id)
      SecretWriterStub.delete(:snapshot_s3_secret_access_key)

      case saved.home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      FermixTestSupport.SafeRm.rm_rf!(tmp_home)
      :ok = RestartState.record_persisted_baseline()
    end)

    link = start_supervised!({Agent, fn -> %{primary: nil, desktops: [], enrollment: nil} end})
    put_seams(link)

    %{conn: authorize_setup(conn), home: tmp_home, link: link}
  end

  describe "the tab" do
    test "sits after Cues and before Doctor", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/setup")

      order =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[phx-value-tab]")
        |> Enum.flat_map(&LazyHTML.attribute(&1, "phx-value-tab"))
        |> Enum.uniq()
        |> Enum.filter(&(&1 in ~w(cues always_on doctor)))

      assert order == ~w(cues always_on doctor)
    end

    test "on an unmoved primary: the role and epoch, recovery, a code to get, no server yet",
         %{conn: conn, home: home} do
      :ok = Epoch.write(home, 3)
      {:ok, _view, html} = live(conn, "/setup?tab=always_on")

      assert html =~ ~s(id="always-on-pane")
      assert text(html, "#always-on-role") == "primary"
      assert text(html, "#always-on-epoch") == "Epoch 3"
      assert text(html, "#always-on-passphrase-state") == "No recovery passphrase is set."

      assert text(html, "#always-on-snapshots-sentence") ==
               "Snapshots are off: set a recovery passphrase to turn them on."

      assert text(html, "#always-on-enrollment-state") =~ "No code is open."
      assert html =~ "None yet. Get a code above"
      refute html =~ ~s(id="always-on-primary")
      refute html =~ ~s(id="always-on-desktops")
      refute html =~ ~s(id="always-on-move")
      refute html =~ ~s(id="device-role-notice")
    end

    test "the route to a server: the command for a Linux server you have", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/setup?tab=always_on")

      assert html =~ ~s(href="https://fermix.ai/docs/always-on")
      assert text(html, "#always-on-enrollment") =~ "On a Linux server you have"
      refute text(html, "#always-on-enrollment") =~ "AWS"

      assert text(html, "#always-on-existing-host") ==
               "curl -fsSL https://fermix.ai/always-on | sudo sh"
    end
  end

  describe "the enrollment code" do
    test "is shown once, with Copy and its expiry, and is gone after Done", %{
      conn: conn,
      link: link
    } do
      {:ok, view, html} = live(conn, "/setup?tab=always_on")
      refute html =~ @code

      html = view |> element("#always-on-enroll") |> render_click()
      assert_received :enrollment_opened

      assert text(html, "#always-on-code-value") == @code
      assert html =~ ~s(data-copy-from="always-on-code-value")
      assert html =~ "It works once, until 2026-10-27 12:10 UTC."

      assert text(html, "#always-on-enrollment-state") =~
               "A code is open until 2026-10-27 12:10 UTC"

      # The open window moves by itself, so it is read again on a schedule.
      assert_received {:scheduled, {:always_on_poll, _gen}, 5_000}
      assert Agent.get(link, & &1.enrollment).state == :open

      html = render_click(view, "always_on_code_done", %{})
      refute html =~ @code
      refute render(view) =~ @code
    end

    test "is dropped when the tab is left", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup?tab=always_on")
      view |> element("#always-on-enroll") |> render_click()

      view |> element(~s|button[phx-value-tab="doctor"]|) |> render_click()
      html = view |> element(~s|button[phx-value-tab="always_on"]|) |> render_click()

      refute html =~ @code
    end

    test "a refused window shows the daemon's sentence", %{conn: conn, link: link} do
      put_seams(link,
        open_enrollment: fn -> {:error, {:unavailable, "The rail is not running yet."}} end
      )

      {:ok, view, _html} = live(conn, "/setup?tab=always_on")
      html = view |> element("#always-on-enroll") |> render_click()

      assert text(html, "#always-on-notice-enrollment") == "The rail is not running yet."
      refute html =~ ~s(id="always-on-code")
    end
  end

  describe "candidates" do
    test "show the host and the instance facts marked unverified, and the move command only " <>
           "once the review has nothing that blocks",
         %{conn: conn, home: home} do
      {:ok, candidate} = add_candidate(home)
      {:ok, view, html} = live(conn, "/setup?tab=always_on")

      card = "#always-on-candidate-#{candidate.candidate_id}"
      assert text(html, card) =~ "fermix-server-0f3b"
      assert text(html, card) =~ "linux · arm64 · Fermix"
      assert text(html, card) =~ "61839204"
      assert text(html, card) =~ "Unverified"
      refute text(html, card) =~ "Account"

      assert text(html, card) =~ "Fermix cannot check these."
      refute text(html, card) =~ ~r/compare/i

      refute html =~ ~s(id="always-on-move-#{candidate.candidate_id}")

      html = view |> element("#always-on-review-#{candidate.candidate_id}") |> render_click()
      readiness = "#always-on-readiness-#{candidate.candidate_id}"

      assert text(html, "#{readiness}-cutover_gap") =~
               "Messages sent to Telegram while the move runs are lost"

      assert text(html, "#{readiness}-serves_nothing") =~ "This computer serves nothing"
      refute html =~ ~s(id="always-on-readiness-#{candidate.candidate_id}-blocked")

      assert text(html, "#always-on-move-#{candidate.candidate_id}") ==
               "fermix home move --to #{candidate.candidate_id} --recovery-passphrase-file FILE"

      assert text(html, card) =~ "this page goes away while it restarts"

      # A server that is itself the primary, being replaced, keeps no desktop.
      assert text(html, "#always-on-move-retire-#{candidate.candidate_id}") ==
               "If this computer is a server you are replacing, add --retire to the command: " <>
                 "Fermix here hands the home over and then serves nothing, instead of staying " <>
                 "a desktop of the new server. Leave it out on a computer you keep using."

      refute html =~ ~s(phx-click="always_on_move)
      refute html =~ ~s(phx-submit="always_on_replace")
    end

    test "a review that blocks shows each block as one, and no move command", %{
      conn: conn,
      home: home,
      link: link
    } do
      put_seams(link, free_bytes: fn _dir -> {:ok, 1_024} end)
      {:ok, candidate} = add_candidate(home)
      {:ok, view, _html} = live(conn, "/setup?tab=always_on")

      html = view |> element("#always-on-review-#{candidate.candidate_id}") |> render_click()
      readiness = "#always-on-readiness-#{candidate.candidate_id}"

      assert text(html, "#{readiness}-blocked") ==
               "The move cannot start while anything below blocks it."

      assert text(html, "#{readiness}-disk") =~ "Blocks"
      assert text(html, "#{readiness}-disk") =~ "free"
      refute html =~ ~s(id="always-on-move-#{candidate.candidate_id}")

      html = render_click(view, "always_on_review_done", %{})
      refute html =~ ~s(id="always-on-readiness-#{candidate.candidate_id}")
    end

    test "a review of a server the primary no longer holds is refused by name", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup?tab=always_on")
      html = render_click(view, "always_on_review", %{"candidate" => "cand-0000000000000000"})

      assert text(html, "#always-on-notice-candidates") ==
               "That server is no longer waiting for the move. Read the list again."
    end

    test "a candidate that enrolls while a code is open appears at the next read", %{
      conn: conn,
      home: home
    } do
      {:ok, view, _html} = live(conn, "/setup?tab=always_on")
      view |> element("#always-on-enroll") |> render_click()
      assert_received {:scheduled, {:always_on_poll, _gen} = read, 5_000}

      {:ok, candidate} = add_candidate(home)
      send(view.pid, read)

      assert render(view) =~ "always-on-candidate-#{candidate.candidate_id}"
    end
  end

  describe "the move" do
    test "shows each phase with its sentence, and follows only a move still under way", %{
      conn: conn,
      home: home
    } do
      File.mkdir_p!(Move.dir(home))

      for phase <- Move.phases() do
        :ok = Move.put_phase(home, phase, %{"candidate" => "invented-vm"}, @now)
        {:ok, view, html} = live(conn, "/setup?tab=always_on")

        assert text(html, "#always-on-move-phase") == phase
        assert text(html, "#always-on-move-sentence") == Move.sentence(phase, "invented-vm")

        # The two endings recorded just before a restart are followed too: the
        # engine that comes back publishes how the move ended.
        if phase in ~w(requested streaming committing aborting committed undoing) do
          assert_received {:scheduled, {:always_on_poll, _gen}, 5_000}
        else
          refute_received {:scheduled, {:always_on_poll, _gen}, _ms}
        end

        GenServer.stop(view.pid)
      end
    end
  end

  describe "on a device" do
    setup do
      put_role(@device)
    end

    test "the page opens on Always On and leads with where Fermix-wide settings live", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, "/setup")

      assert html =~ ~s(id="always-on-pane")

      assert text(html, "#device-role-notice") ==
               "This computer runs Fermix as a desktop of the primary, invented-vm. " <>
                 "Fermix-wide settings live on the primary: change them in the Fermix app " <>
                 "on this computer. This page sets up this computer."
    end

    test "the primary's tabs say so instead of offering their forms; this computer's stay", %{
      conn: conn
    } do
      for tab <- ~w(provider channels realtime plugins cues memory) do
        {:ok, view, html} = live(conn, "/setup?tab=#{tab}")

        assert html =~ ~s(id="primary-only-pane"), "#{tab} offers the primary's settings"

        assert html =~
                 "These settings are Fermix-wide, so they live on the primary, invented-vm. " <>
                   "Change them in the Fermix app on this computer."

        refute html =~ "setup page"

        refute html =~ ~s(phx-submit="save_provider")
        refute html =~ ~s(phx-submit="save_channels")
        GenServer.stop(view.pid)
      end

      for tab <- ~w(sandbox doctor always_on) do
        {:ok, view, html} = live(conn, "/setup?tab=#{tab}")
        refute html =~ ~s(id="primary-only-pane"), "#{tab} is this computer's"
        GenServer.stop(view.pid)
      end
    end

    test "linked: the primary, connected, with its sentence", %{conn: conn, link: link} do
      primary = %{
        name: "invented-vm",
        connected: true,
        status: :connected,
        since: ~U[2026-10-27 11:30:00Z],
        epoch: 5,
        sentence: "Connected to invented-vm."
      }

      Agent.update(link, &%{&1 | primary: primary})
      {:ok, _view, html} = live(conn, "/setup")

      assert text(html, "#always-on-role") == "device"
      assert text(html, "#always-on-primary") =~ "invented-vm"
      assert text(html, "#always-on-primary") =~ "Connected since 2026-10-27 11:30 UTC"
      assert text(html, "#always-on-primary") =~ "Connected to invented-vm."
      refute html =~ ~s(id="always-on-recovery")
      refute html =~ ~s(id="always-on-enrollment")
      refute html =~ ~s(id="always-on-candidates")
    end

    test "linked but not connected: the primary is named as not connected", %{
      conn: conn,
      link: link
    } do
      sentence =
        "The server invented-vm is unreachable. Fermix keeps your message until it is back."

      primary = %{
        name: "invented-vm",
        connected: false,
        status: :unreachable,
        since: nil,
        epoch: 5,
        sentence: sentence
      }

      Agent.update(link, &%{&1 | primary: primary})

      {:ok, _view, html} = live(conn, "/setup")

      assert text(html, "#always-on-primary") =~ "Not connected"
      assert text(html, "#always-on-primary") =~ sentence
    end

    # A quiet renewal is not an outage, so it is not drawn as one.
    test "linked and renewing: the primary is reconnecting, not drawn as an outage", %{
      conn: conn,
      link: link
    } do
      primary = %{
        name: "invented-vm",
        connected: false,
        status: :renewing,
        since: nil,
        epoch: 5,
        sentence: "Fermix is reconnecting to the server invented-vm."
      }

      Agent.update(link, &%{&1 | primary: primary})

      {:ok, _view, html} = live(conn, "/setup")

      assert text(html, "#always-on-primary") =~ "Reconnecting"
      refute text(html, "#always-on-primary") =~ "Not connected"
      refute html =~ ~s(bg-error)
    end

    test "unlinked after a move: the marker says where the home went", %{conn: conn, home: home} do
      :ok = Moved.write(home, %{epoch: 4, moved_at: ~U[2026-10-26 09:00:00Z], to: "invented-vm"})
      {:ok, _view, html} = live(conn, "/setup")

      assert text(html, "#always-on-primary") =~
               "This home moved to invented-vm on 2026-10-26 09:00 UTC at epoch 4."
    end

    test "unlinked with no marker: no primary to name", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/setup")

      assert text(html, "#always-on-primary") =~
               "This computer runs in the device role with no link to a primary."
    end
  end

  describe "a primary with desktops" do
    setup %{link: link} do
      desktop = %{
        device_id: @desktop_id,
        name: "Studio Mac",
        connected: true,
        since: ~U[2026-10-27 11:45:00Z]
      }

      Agent.update(link, &%{&1 | desktops: [desktop]})
      :ok
    end

    test "lists each desktop, connected or not", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/setup?tab=always_on")

      row = "#always-on-desktop-#{@desktop_id}"
      assert text(html, row) =~ "Studio Mac"
      assert text(html, row) =~ "Connected since 2026-10-27 11:45 UTC"
    end
  end

  describe "recovery" do
    test "two passphrases that differ save nothing and are never shown", %{conn: conn, home: home} do
      {:ok, view, _html} = live(conn, "/setup?tab=always_on")

      html =
        view
        |> form("#always-on-passphrase-0",
          always_on_passphrase: %{
            password: "invented-lighthouse-meridian",
            password_again: "invented-lighthouse-meridiam"
          }
        )
        |> render_submit()

      assert text(html, "#always-on-notice-passphrase") ==
               "The two passphrases differ, so nothing was saved."

      refute html =~ "invented-lighthouse"
      assert html =~ ~s(id="always-on-passphrase-1")
      refute File.exists?(Path.join(home, "config.toml"))
    end

    test "a passphrase typed twice sets the recovery key; the passphrase is never shown or logged",
         %{conn: conn, home: home} do
      {:ok, view, _html} = live(conn, "/setup?tab=always_on")

      log =
        capture_log(fn ->
          html =
            view
            |> form("#always-on-passphrase-0",
              always_on_passphrase: %{
                password: "invented-lighthouse-meridian",
                password_again: "invented-lighthouse-meridian"
              }
            )
            |> render_submit()

          send(self(), {:html, html})
        end)

      assert_received {:html, html}
      assert text(html, "#always-on-passphrase-state") == "A recovery passphrase is set."
      assert text(html, "#always-on-notice-passphrase") =~ "The recovery passphrase is set."
      refute html =~ "invented-lighthouse"
      refute log =~ "invented-lighthouse"

      contents = File.read!(Path.join(home, "config.toml"))
      assert contents =~ ~r/recipient = "fxsnap1\./
      refute contents =~ "invented-lighthouse"
    end

    test "a passphrase too short is refused in the daemon's words", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup?tab=always_on")

      html =
        view
        |> form("#always-on-passphrase-0",
          always_on_passphrase: %{password: "short", password_again: "short"}
        )
        |> render_submit()

      assert text(html, "#always-on-notice-passphrase") ==
               "The recovery passphrase must be at least 12 bytes long."
    end

    test "Back up now is offered only once snapshots have somewhere to go", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/setup?tab=always_on")
      refute html =~ ~s(id="always-on-backup")

      config = [recipient: Recipient.encode(Recipient.generate())]
      Application.put_env(:fermix_core, :snapshots, config)
      {:ok, _view, html} = live(conn, "/setup?tab=always_on")

      assert text(html, "#always-on-snapshots-sentence") ==
               "Snapshots are off: name an S3 bucket to keep them in."

      refute html =~ ~s(id="always-on-backup")
    end

    test "Back up now without a running scheduler says so", %{conn: conn} do
      config = [recipient: Recipient.encode(Recipient.generate()), s3_bucket: "invented-bucket"]
      Application.put_env(:fermix_core, :snapshots, config)
      {:ok, view, _html} = live(conn, "/setup?tab=always_on")
      html = view |> element("#always-on-backup") |> render_click()

      assert text(html, "#always-on-notice-recovery") ==
               "Snapshots are not running in this engine."
    end

    test "Back up now starts a run and follows it", %{conn: conn, home: home, link: link} do
      test_pid = self()
      config = [recipient: Recipient.encode(Recipient.generate()), s3_bucket: "invented-bucket"]
      Application.put_env(:fermix_core, :snapshots, config)
      tasks = start_supervised!(Task.Supervisor)
      name = :"always_on_test_scheduler_#{System.unique_integer([:positive])}"

      start_supervised!({Scheduler,
       name: name,
       home: home,
       config: fn -> config end,
       targets: [S3],
       timer_enabled: false,
       task_supervisor: tasks,
       run: fn _home, _config, _targets, _opts ->
         send(test_pid, :snapshot_run)

         # The run stays open, so the scheduler reports one running, until
         # the case's supervisor stops it.
         receive do
           :never -> {:error, :stopped}
         end
       end})

      put_seams(link, scheduler: name)
      {:ok, view, _html} = live(conn, "/setup?tab=always_on")

      html = view |> element("#always-on-backup") |> render_click()

      assert_receive :snapshot_run
      assert text(html, "#always-on-notice-recovery") == "A snapshot is being written now."
      assert_received {:scheduled, {:always_on_poll, _gen}, 5_000}
    end

    test "a target's last verified point and its error are shown", %{conn: conn, home: home} do
      config = [recipient: Recipient.encode(Recipient.generate()), s3_bucket: "invented-bucket"]
      Application.put_env(:fermix_core, :snapshots, config)
      write_status(home)

      {:ok, _view, html} = live(conn, "/setup?tab=always_on")

      assert text(html, "#always-on-target-s3") =~
               "Last verified 2026-10-27 09:30 UTC: 20261027T093000Z-e4.fxsnap"

      assert text(html, "#always-on-target-s3") =~ "The bucket refused the snapshot."
      assert text(html, "#always-on-target-s3") =~ "(recovery key 0011223344556677)"
    end

    test "a desktop that could not take a copy now is waiting, not failed", %{
      conn: conn,
      home: home
    } do
      note = "Your Studio Mac is not connected; the snapshot waits for the next run."

      waiting = %{
        at: ~U[2026-10-27 11:30:00Z],
        result: :waiting,
        name: "20261027T113000Z-e4.fxsnap",
        epoch: 4,
        size: 1_024,
        sha256: String.duplicate("0", 64),
        location: nil,
        error: nil,
        note: note
      }

      :ok = Status.write(home, Status.record(Status.empty(), "desktop", waiting))
      {:ok, _view, html} = live(conn, "/setup?tab=always_on")

      assert text(html, "#always-on-target-desktop") =~ "Waiting"
      assert text(html, "#always-on-target-desktop") =~ note
    end

    test "changing the passphrase says which snapshots open with which", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/setup?tab=always_on")
      fields = fn word -> %{password: word, password_again: word} end

      html =
        view
        |> form("#always-on-passphrase-0",
          always_on_passphrase: fields.("invented-first-meridian")
        )
        |> render_submit()

      refute text(html, "#always-on-notice-passphrase") =~ "earlier passphrase"

      assert text(html, "#always-on-passphrase-change") =~
               "Snapshots written before a change keep opening only with the passphrase"

      html =
        view
        |> form("#always-on-passphrase-1",
          always_on_passphrase: fields.("invented-second-meridian")
        )
        |> render_submit()

      assert text(html, "#always-on-notice-passphrase") =~
               "those written before now open only with the earlier passphrase."

      refute html =~ "invented-second"
    end
  end

  describe "before the move" do
    test "says the gap, that this computer serves nothing, the disk, where secrets live, " <>
           "the 30 minutes and that there is no way back",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/setup?tab=always_on")
      facts = text(html, "#always-on-before-moving")

      assert facts =~
               "The move needs about twice this home's size free on this computer, and as " <>
                 "much again on the server."

      assert facts =~ "While it runs this computer serves nothing"

      assert facts =~
               "Telegram messages sent during the move are lost, and a recurring job more " <>
                 "than an hour late is skipped."

      assert facts =~
               "The server keeps your secrets in files, behind its disk encryption and " <>
                 "Fermix's sandbox: encrypt its disk if its host does not."

      assert facts =~
               "Moving back to a desktop is not in this version: to bring Fermix back to a " <>
                 "computer, restore the newest snapshot into a fresh home there."

      assert text(html, "#always-on-moving-back") =~ "restore the newest snapshot"

      assert text(html, "#always-on-enrollment-state") ==
               "No code is open. A code works once, for 30 minutes."
    end

    test "while a code is open, the button says a new one stops it working", %{conn: conn} do
      {:ok, view, html} = live(conn, "/setup?tab=always_on")
      assert text(html, "#always-on-enroll") == "Get a code"

      html = view |> element("#always-on-enroll") |> render_click()

      assert text(html, "#always-on-enroll") == "Get a new code (the open one stops working)"
    end
  end

  describe "times" do
    test "are drawn in the viewer's own zone, named", %{conn: conn} do
      conn = put_connect_params(conn, %{"timezone" => "Europe/Berlin"})
      {:ok, view, _html} = live(conn, "/setup?tab=always_on")

      html = view |> element("#always-on-enroll") |> render_click()

      assert html =~ "It works once, until 2026-10-27 13:10 CET."

      assert text(html, "#always-on-enrollment-state") =~
               "A code is open until 2026-10-27 13:10 CET"
    end

    test "a zone the zone database does not know reads in UTC, and says so", %{conn: conn} do
      conn = put_connect_params(conn, %{"timezone" => "Invented/Nowhere"})
      {:ok, view, _html} = live(conn, "/setup?tab=always_on")

      html = view |> element("#always-on-enroll") |> render_click()

      assert html =~ "It works once, until 2026-10-27 12:10 UTC."
    end
  end

  describe "secrets a move left behind" do
    test "the primary names each one to enter again, by its id", %{conn: conn, link: link} do
      settings = %{
        fermix_core: [providers: [anthropic: [api_key: "@keyring"]]],
        fermix_channels: [telegram: [bot_token: "@keyring"]]
      }

      put_seams(link, settings_snapshot: fn -> settings end)
      {:ok, _view, html} = live(conn, "/setup?tab=always_on")
      card = text(html, "#always-on-secrets-missing")

      assert card =~
               "Fermix cannot read these secrets on this host, so whatever uses them fails " <>
                 "until you enter each again in its tab on this page."

      assert card =~ "anthropic_api_key"
      assert card =~ "telegram_bot_token"
    end

    test "none missing, no card", %{conn: conn, link: link} do
      put_seams(link, settings_snapshot: fn -> %{fermix_core: [], fermix_channels: []} end)
      {:ok, _view, html} = live(conn, "/setup?tab=always_on")

      refute html =~ ~s(id="always-on-secrets-missing")
    end
  end

  describe "a desktop linked to its server" do
    setup %{link: link} do
      put_role(@device)

      server =
        start_supervised!(
          Supervisor.child_spec({Agent, fn -> %{"home.status" => {:ok, server_home()}} end},
            id: :server
          )
        )

      put_linked(link, server)
      %{server: server}
    end

    test "shows the server's recovery, the key each point opens with, and no way back here", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, "/setup")
      assert_received {:forwarded, "home.status", %{}}

      recovery = text(html, "#always-on-server-recovery")
      assert recovery =~ "The server's recovery"
      assert recovery =~ "The last snapshot was stored at 2026-10-27 09:30 UTC."
      assert recovery =~ "(recovery key 0011223344556677)"

      assert text(html, "#always-on-moving-back") ==
               "Moving Fermix back to this computer is not in this version: to bring it " <>
                 "back, restore the newest snapshot into a fresh home here."

      assert html =~ ~s(id="always-on-backup")
      refute html =~ ~s(id="always-on-passphrase-0")
      refute html =~ ~s(id="always-on-storage")
      assert text(html, "#always-on-enrollment") =~ "Replace the server"

      assert text(html, "#always-on-before-moving") =~
               "The server you replace serves nothing once the move is done, and is no " <>
                 "desktop of the new one"
    end

    test "while the server cannot be reached, says why in its words", %{
      conn: conn,
      server: server
    } do
      sentence =
        "The server invented-vm is unreachable. Fermix keeps your message until it is back."

      answer = {:error, :primary_unreachable, %{"sentence" => sentence}}
      Agent.update(server, &Map.put(&1, "home.status", answer))

      {:ok, _view, html} = live(conn, "/setup")

      assert text(html, "#always-on-server-missing") =~ sentence
      refute html =~ ~s(id="always-on-server-recovery")
    end

    test "the server's secrets to enter again point at the app", %{conn: conn, server: server} do
      home = server_home(%{"secrets_missing" => ["anthropic_api_key"]})
      Agent.update(server, &Map.put(&1, "home.status", {:ok, home}))

      {:ok, _view, html} = live(conn, "/setup")

      assert text(html, "#always-on-server-secrets-missing") =~
               "until you enter each again in the Fermix app."

      assert text(html, "#always-on-server-secrets-missing") =~ "anthropic_api_key"
    end

    test "a move under way on the server is shown and followed", %{conn: conn, server: server} do
      move = %{
        "phase" => "streaming",
        "candidate" => "fermix-aws-new",
        "sentence" => "This home is being sent to fermix-aws-new."
      }

      Agent.update(server, &Map.put(&1, "home.status", {:ok, server_home(%{"move" => move})}))
      {:ok, _view, html} = live(conn, "/setup")

      assert text(html, "#always-on-server-move-sentence") ==
               "This home is being sent to fermix-aws-new."

      assert_received {:scheduled, {:always_on_poll, _gen}, 5_000}
    end

    test "Back up now and a code are asked of the server", %{conn: conn, server: server} do
      Agent.update(server, fn answers ->
        answers
        |> Map.put("home.snapshots.run", {:ok, %{"started" => true}})
        |> Map.put(
          "home.enroll.open",
          {:ok, %{"code" => @code, "expires_at" => "2026-10-27T12:10:00Z"}}
        )
      end)

      {:ok, view, _html} = live(conn, "/setup")

      html = view |> element("#always-on-backup") |> render_click()
      assert_received {:forwarded, "home.snapshots.run", %{}}
      assert text(html, "#always-on-notice-recovery") == "A snapshot is being written now."

      html = view |> element("#always-on-enroll") |> render_click()
      assert_received {:forwarded, "home.enroll.open", %{}}
      assert text(html, "#always-on-code-value") == @code
    end

    test "replacing it: the review on the server, then the move there, kept as no desktop", %{
      conn: conn,
      server: server
    } do
      Agent.update(server, fn answers ->
        answers
        |> Map.put("home.move.readiness", {:ok, ready_review()})
        |> Map.put("home.move.start", {:ok, %{"candidate" => server_candidate()}})
      end)

      {:ok, view, html} = live(conn, "/setup")
      refute html =~ ~s(phx-submit="always_on_replace")

      html = view |> element("#always-on-review-#{@server_candidate_id}") |> render_click()

      assert_received {:forwarded, "home.move.readiness",
                       %{"candidate_id" => @server_candidate_id}}

      assert text(html, "#always-on-readiness-#{@server_candidate_id}-cutover_gap") =~ "Note"
      refute html =~ "fermix home move"

      log =
        capture_log(fn ->
          html =
            view
            |> form("#always-on-replace-0",
              always_on_replace: %{
                password: "invented-harbour-lantern",
                password_again: "invented-harbour-lantern"
              }
            )
            |> render_submit()

          send(self(), {:html, html})
        end)

      assert_received {:html, html}

      assert_received {:forwarded, "home.move.start",
                       %{
                         "candidate_id" => @server_candidate_id,
                         "recovery_passphrase" => "invented-harbour-lantern",
                         "keep_as_desktop" => false
                       }}

      assert text(html, "#always-on-notice-replace") =~
               "The server is moving this home to fermix-aws-new"

      refute html =~ "invented-harbour"
      refute log =~ "invented-harbour"
    end

    test "the move is not asked before a review with nothing that blocks, nor with two " <>
           "passphrases that differ",
         %{conn: conn, server: server} do
      Agent.update(server, &Map.put(&1, "home.move.readiness", {:ok, ready_review()}))
      {:ok, view, _html} = live(conn, "/setup")

      fields = %{
        "candidate" => @server_candidate_id,
        "password" => "invented-harbour-lantern",
        "password_again" => "invented-harbour-lantern"
      }

      html = render_submit(view, "always_on_replace", %{"always_on_replace" => fields})

      assert text(html, "#always-on-notice-replace") ==
               "Review the move to that server first; it starts once nothing blocks it."

      view |> element("#always-on-review-#{@server_candidate_id}") |> render_click()

      html =
        render_submit(view, "always_on_replace", %{
          "always_on_replace" => %{fields | "password_again" => "invented-harbour-lanterm"}
        })

      assert text(html, "#always-on-notice-replace") ==
               "The two passphrases differ, so nothing was saved."

      refute_received {:forwarded, "home.move.start", _params}
    end

    test "a review the server refuses shows its sentence", %{conn: conn, server: server} do
      sentence = "The server invented-vm did not answer in time."
      answer = {:error, :primary_unreachable, %{"sentence" => sentence}}
      Agent.update(server, &Map.put(&1, "home.move.readiness", answer))

      {:ok, view, _html} = live(conn, "/setup")
      html = view |> element("#always-on-review-#{@server_candidate_id}") |> render_click()

      assert text(html, "#always-on-notice-candidates") == sentence
    end
  end

  describe "where snapshots are kept" do
    test "the section's fields save to the settings file", %{conn: conn, home: home} do
      {:ok, view, html} = live(conn, "/setup?tab=always_on")

      for key <- ~w(snapshots_s3_bucket snapshots_s3_region snapshots_s3_endpoint
                    snapshots_interval_hours) do
        assert html =~ ~s(name="always_on_storage[#{key}]"), "#{key} is not offered"
      end

      refute html =~ "snapshots_s3_credentials"

      html =
        view
        |> form("#always-on-storage",
          always_on_storage: %{
            snapshots_s3_bucket: "invented-fermix-snapshots",
            snapshots_s3_region: "eu-west-1",
            snapshots_interval_hours: "12"
          }
        )
        |> render_submit()

      assert text(html, "#always-on-notice-storage") == "Saved."
      contents = File.read!(Path.join(home, "config.toml"))
      assert contents =~ ~s(s3_bucket = "invented-fermix-snapshots")
      assert contents =~ ~s(s3_region = "eu-west-1")
      assert contents =~ "interval_hours = 12"
    end

    test "a value the section refuses is shown in its words and nothing is saved", %{
      conn: conn,
      home: home
    } do
      {:ok, view, _html} = live(conn, "/setup?tab=always_on")

      html =
        view
        |> form("#always-on-storage", always_on_storage: %{snapshots_s3_bucket: "Not A Bucket"})
        |> render_submit()

      assert text(html, "#always-on-notice-storage") =~ "s3_bucket takes a bucket name"
      refute File.exists?(Path.join(home, "config.toml"))
    end

    test "the access keys are secret fields: stored, and never rendered", %{conn: conn} do
      {:ok, view, html} = live(conn, "/setup?tab=always_on")

      for key <- ~w(snapshot_s3_access_key_id snapshot_s3_secret_access_key) do
        assert input_type(html, ~s|input[name="secret[#{key}]"]|) == "password"
        assert input_value(html, ~s|input[name="secret[#{key}]"]|) in [nil, ""]
      end

      html =
        view
        |> form("#always-on-keys-0",
          secret: %{
            snapshot_s3_access_key_id: "AKIAINVENTED7781",
            snapshot_s3_secret_access_key: "invented-secret-access-4410"
          }
        )
        |> render_submit()

      assert text(html, "#always-on-notice-keys") == "The keys are stored."
      assert SecretWriterStub.get(:snapshot_s3_access_key_id) == {:ok, "AKIAINVENTED7781"}

      assert SecretWriterStub.get(:snapshot_s3_secret_access_key) ==
               {:ok, "invented-secret-access-4410"}

      {:ok, _view, fresh} = live(conn, "/setup?tab=always_on")

      for page <- [html, fresh] do
        refute page =~ "AKIAINVENTED7781"
        refute page =~ "invented-secret-access-4410"
        assert placeholder(page, ~s|input[name="secret[snapshot_s3_access_key_id]"]|) == "Stored"
      end
    end
  end

  # -- seams ---------------------------------------------------------------------

  defp put_role(record) do
    Application.put_env(:fermix_web, :engine_role, fn -> record end)
    :ok
  end

  defp put_seams(link, home_overrides \\ []) do
    test_pid = self()

    home =
      Keyword.merge(
        [
          now: @now,
          scheduler: nil,
          # The review's facts about this computer, fixed: room to spare, and
          # the same Fermix as the server the cases enroll.
          free_bytes: fn _dir -> {:ok, 1_099_511_627_776} end,
          version: "0.18.0",
          link_status: fn -> Agent.get(link, & &1) end,
          save_recipient: &SnapshotSettings.put_recipient(&1, scheduler: :always_on_no_scheduler),
          open_enrollment: fn ->
            send(test_pid, :enrollment_opened)
            window = %{state: :open, expires_at: @code_expires}
            Agent.update(link, &%{&1 | enrollment: window})
            {:ok, %{code: @code, expires_at: @code_expires}}
          end
        ],
        home_overrides
      )

    Application.put_env(:fermix_web, :always_on,
      home: home,
      schedule: fn message, wait_ms -> send(test_pid, {:scheduled, message, wait_ms}) end
    )
  end

  # A desktop linked to its server: what the tab asks the server goes to
  # `server`, an agent holding each method's answer, and each request is
  # reported to the case.
  defp put_linked(link, server) do
    put_seams(link)
    test_pid = self()

    forward = fn %{method: method, params: params}, _opts ->
      send(test_pid, {:forwarded, method, params})
      Agent.get(server, &Map.fetch!(&1, method))
    end

    seams = Application.fetch_env!(:fermix_web, :always_on)
    Application.put_env(:fermix_web, :always_on, seams ++ [linked?: true, forward: forward])
  end

  # The server's own `home.status`, as it answers a desktop: one verified S3
  # snapshot written by a real status view, and one server waiting.
  defp server_home(overrides \\ %{}) do
    verified = %{
      at: ~U[2026-10-27 09:30:00Z],
      result: :verified,
      name: "20261027T093000Z-e5.fxsnap",
      epoch: 5,
      size: 1_024,
      sha256: String.duplicate("0", 64),
      location: "s3://invented-bucket/fermix/general/20261027T093000Z-e5.fxsnap",
      key_id: "0011223344556677",
      error: nil
    }

    snapshots =
      Status.view(Status.record(Status.empty(), "s3", verified), %{
        config: [recipient: Recipient.encode(Recipient.generate()), s3_bucket: "invented-bucket"],
        targets: [S3],
        running: false,
        profile: "general"
      })

    Map.merge(
      %{
        "role" => "primary",
        "epoch" => 5,
        "moved" => nil,
        "primary" => nil,
        "desktops" => [],
        "snapshots" => snapshots,
        "enrollment" => nil,
        "candidates" => [server_candidate()],
        "move" => nil,
        "primary_home" => nil,
        "primary_missing" => nil,
        "secrets_missing" => []
      },
      overrides
    )
  end

  defp server_candidate do
    %{
      "candidate_id" => @server_candidate_id,
      "name" => "fermix-aws-new",
      "os" => "linux",
      "arch" => "arm64",
      "version" => "0.18.0",
      "node_id" => String.duplicate("cd", 32),
      "instance" => nil,
      "snapshots" => nil,
      "enrolled_at" => "2026-10-27T11:00:00Z",
      "expires_at" => "2026-10-28T11:00:00Z"
    }
  end

  defp ready_review do
    %{
      "ready" => true,
      "items" => [
        %{
          "id" => "keychain_secrets",
          "status" => "ok",
          "sentence" => "No secret is kept in a keychain."
        },
        %{
          "id" => "cutover_gap",
          "status" => "warn",
          "sentence" =>
            "Messages sent to Telegram while the move runs are lost, and a recurring job " <>
              "more than an hour late is skipped."
        }
      ]
    }
  end

  defp add_candidate(home) do
    Candidates.add(
      home,
      %{
        name: "fermix-server-0f3b",
        os: "linux",
        arch: "arm64",
        version: "0.18.0",
        node_id: String.duplicate("ab", 32),
        relays: [%{"url" => "https://relay.example.net", "quic_port" => 7842}],
        noise_pk: :crypto.strong_rand_bytes(32),
        recipient: :crypto.strong_rand_bytes(32),
        instance: %{"provider" => "hetzner", "instance_id" => "61839204", "region" => "fsn1"},
        snapshots: nil
      },
      @now
    )
  end

  # The status file as the scheduler writes it: one verified run, then a
  # failure in the bucket's words.
  defp write_status(home) do
    verified = %{
      at: ~U[2026-10-27 09:30:00Z],
      result: :verified,
      name: "20261027T093000Z-e4.fxsnap",
      epoch: 4,
      size: 1_024,
      sha256: String.duplicate("0", 64),
      location: "s3://invented-bucket/fermix/general/20261027T093000Z-e4.fxsnap",
      key_id: "0011223344556677",
      error: nil
    }

    failed = %{
      verified
      | at: ~U[2026-10-27 11:30:00Z],
        result: :failed,
        location: nil,
        error: "The bucket refused the snapshot."
    }

    status = Status.empty() |> Status.record("s3", verified) |> Status.record("s3", failed)
    :ok = Status.write(home, status)
  end

  # -- reading the page ----------------------------------------------------------

  defp text(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  defp attribute(html, selector, name) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
    |> List.first()
  end

  defp input_type(html, selector), do: attribute(html, selector, "type")
  defp input_value(html, selector), do: attribute(html, selector, "value")
  defp placeholder(html, selector), do: attribute(html, selector, "placeholder")

  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
end
