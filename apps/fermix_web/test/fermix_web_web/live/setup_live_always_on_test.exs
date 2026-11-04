defmodule FermixWebWeb.SetupLiveAlwaysOnTest do
  # The setup page's Always On tab (Always On setup §8.1): it draws the
  # engine's summary, collects what the pressed action needs, shows its
  # confirm and sends one `home.act` through `Management.AlwaysOn.act/2`, in
  # the page's own process, then draws the answer. Every fact comes from a
  # temp FERMIX_HOME the core modules write, the rail's facts come from a
  # scripted `link_status`, and a linked desktop's server answers a scripted
  # forward.
  # Every read and act runs in `start_async`, so each step waits for the
  # page's own tasks (`render_async`), never for the clock.
  use FermixWebWeb.ConnCase

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

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
  alias FermixCore.Home.StatusWatch
  alias FermixCore.Management.AlwaysOn
  alias FermixCore.Management.Copy
  alias FermixCore.Management.Home
  alias FermixCore.Management.HomeSummary
  alias FermixCore.Management.Jobs
  alias FermixCore.Setup.RestartState
  alias FermixTestSupport.SecretWriterStub
  alias FermixTestSupport.TelemetryCapture

  @at ~U[2031-05-04 12:00:00Z]
  @primary %{role: :primary, primary: nil}
  @device %{role: :device, primary: "invented-vm"}
  @desktop_id "6d2b3c1e-1f7a-4c55-9a3e-2b8f6e0c4d71"
  @passphrase "invented-lighthouse-meridian"
  @manual_code "fxenroll1.eyJ2IjoxLCJuYW1lIjoib3duLXNlcnZlciJ9"
  @back_cand "cand-7a3e1c9b5d2f4086"

  setup %{conn: conn} = ctx do
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
    Application.put_env(:fermix_web, :cues_pane_opts, now: fn -> @at end)
    put_role(@primary)

    on_exit(fn ->
      Enum.each(saved.core, fn {key, value} -> restore_env(:fermix_core, key, value) end)
      Enum.each(saved.web, fn {key, value} -> restore_env(:fermix_web, key, value) end)
      Enum.each(saved.channels, fn {key, value} -> restore_env(:fermix_channels, key, value) end)

      case saved.home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      FermixTestSupport.SafeRm.rm_rf!(tmp_home)
      :ok = RestartState.record_persisted_baseline()
    end)

    link = start_supervised!({Agent, fn -> %{primary: nil, desktops: [], enrollment: nil} end})
    jobs = jobs!(ctx)
    serializer = :"setup_always_on_#{:erlang.phash2(ctx.test)}"
    start_supervised!({AlwaysOn, name: serializer})

    seams = %{
      home: tmp_home,
      link: link,
      jobs: jobs,
      serializer: serializer,
      test: self()
    }

    put_seams(seams)
    %{conn: authorize_setup(conn), home: tmp_home, link: link, seams: seams}
  end

  describe "the tab" do
    test "sits after Cues and before Doctor", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/setup")

      assert tab_ids(html) |> Enum.filter(&(&1 in ~w(cues always_on doctor))) ==
               ~w(cues always_on doctor)
    end

    # The Mac app embeds this page beside its own Always On pane, the one
    # surface there.
    test "embedded in the Mac app, the page neither lists nor opens Always On", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/setup?embed=1")
      refute "always_on" in tab_ids(html)

      {:ok, _view, html} = live(conn, "/setup?embed=1&tab=always_on")
      refute html =~ ~s(id="always-on-pane")

      put_role(@device)
      {:ok, _view, html} = live(conn, "/setup?embed=1")
      refute html =~ ~s(id="always-on-pane")
      refute "always_on" in tab_ids(html)
    end

    # The server's summary offers nothing to press, and the tab names none of
    # the engine's own words for the move.
    test "on the server: the summary's one sentence, and nothing to press", %{
      conn: conn,
      home: home,
      link: link
    } do
      :ok = Epoch.write(home, 3)
      File.mkdir_p!(Move.dir(home))
      :ok = Move.put_phase(home, "aborted", %{"candidate" => "invented-new-vm"}, @at)

      desktop = %{device_id: @desktop_id, name: "Studio Mac", connected: true, since: @at}
      Agent.update(link, &%{&1 | desktops: [desktop]})

      html = open!(conn)

      assert text(html, "#always-on-sentence") == "Fermix runs here."
      assert actions(html, "#always-on-pane") == []

      for word <- ["Epoch", "primary", "invented-new-vm", "Studio Mac", "passphrase", "code"] do
        refute text(html, "#always-on-pane") =~ word, "the tab shows #{word}"
      end

      refute html =~ ~s(id="device-role-notice")
    end

    test "with nothing set up: the first screen, Use my own Linux server", %{conn: conn} do
      html = open!(conn)

      assert text(html, "#always-on-sentence") =~
               ~r/\AKeep Fermix running when this computer sleeps\./

      assert text(html, "#always-on-action") == "Use my own Linux server"
      refute html =~ ~s(id="always-on-alternatives")
      refute html =~ "In the Fermix app"
      assert actions(html, "#always-on-pane") |> Enum.uniq() == ["always_on_press"]
    end

    test "an event the tab does not draw changes nothing and logs only its name", %{
      conn: conn,
      home: home
    } do
      {view, before} = open_view!(conn)

      log =
        capture_log(fn ->
          html =
            render_click(view, "always_on_passphrase", %{
              "always_on_passphrase" => %{"password" => @passphrase}
            })

          send(self(), {:html, html})
        end)

      assert_received {:html, html}
      assert text(html, "#always-on-pane") == text(before, "#always-on-pane")
      assert log =~ "setup always on: ignored a malformed always_on_passphrase event"
      refute log =~ "invented-lighthouse"
      refute File.exists?(Path.join(home, "config.toml"))
    end
  end

  # Always On is not in a release build yet: there the page lists no Always
  # On tab, opens none, and takes no Always On event.
  describe "in a build without Always On" do
    test "the page has no Always On tab, opens another, and an Always On event does nothing",
         %{conn: conn, link: link, seams: seams} do
      put_seams(seams, available: false)
      {:ok, view, html} = live(conn, ~p"/setup?tab=always_on")

      refute html =~ ~s(phx-value-tab="always_on")
      refute html =~ ~s(id="always-on-pane")

      render_click(view, "always_on_press", %{"id" => "own_server", "key" => "k"})
      refute render(view) =~ ~s(id="always-on-step")
      assert Agent.get(link, & &1.enrollment) == nil
    end

    test "in a build with it, the tab is listed", %{conn: conn, seams: seams} do
      put_seams(seams, available: true)
      {:ok, _view, html} = live(conn, ~p"/setup")
      assert html =~ ~s(phx-value-tab="always_on")
    end
  end

  describe "a server of the owner's own" do
    test "the code shows once, with the command and until when, and no print spells it", %{
      conn: conn
    } do
      {view, _html} = open_view!(conn)
      press(view, "own_server")
      html = render_async(view)

      assert text(html, "#always-on-code") =~ "curl -fsSL https://fermix.ai/always-on | sudo sh"
      assert text(html, "#always-on-code-text") == @manual_code
      assert html =~ ~s(data-copy-from="always-on-code-text")
      assert text(html, "#always-on-code") =~ "Sunday, May 4, 2031 at 12:30 PM UTC"
      refute view.pid |> :sys.get_state() |> inspect(limit: :infinity) =~ @manual_code

      # Cancel the code takes no confirm: it acts at once, and the card goes.
      press(view, "cancel")
      html = settle!(view)
      refute html =~ @manual_code
      refute html =~ ~s(id="always-on-code")
      assert_received :enrollment_withdrawn
    end
  end

  describe "the move, on the computer that sets up" do
    setup ctx do
      :ok = Epoch.write(ctx.home, 4)
      {:ok, held} = Candidates.add(ctx.home, candidate_attrs(), @at)
      Agent.update(ctx.link, &%{&1 | enrollment: window(:used, held.candidate_id)})
      ctx
    end

    # Where no recovery key is set, the passphrase is typed twice and
    # compared here; it reaches the move and nothing else.
    test "Move now asks the passphrase twice, puts the restart overlay up first, and the " <>
           "passphrase reaches no log, page or assign",
         %{conn: conn, seams: seams} do
      {view, _html} = open_view!(conn)
      move_now = action!(summary!(seams), "move_now")
      assert move_now["needs"] == ["new_recovery_passphrase"]

      html = press(view, "move_now")
      assert text(html, "#always-on-step") =~ move_now["confirm"]
      assert length(field_values(html, ~s(input[type="password"]))) == 2

      log =
        capture_log(fn ->
          html =
            render_submit(view, "always_on_submit", %{
              "always_on_step" => %{
                "passphrase" => @passphrase,
                "passphrase_again" => @passphrase <> "x"
              }
            })

          send(self(), {:mismatch, html})
          # Two passphrases that differ are the page's own refusal: no step ran.
          refute_received :restarted
          refute_received {:saved, _recipient}

          html =
            render_submit(view, "always_on_submit", %{
              "always_on_step" => %{
                "passphrase" => @passphrase,
                "passphrase_again" => @passphrase
              }
            })

          send(self(), {:overlay, html})
          send(self(), {:after, settle!(view)})
        end)

      assert_received {:mismatch, mismatch}
      assert text(mismatch, "#always-on-error") =~ "do not match"
      assert [_, _] = field_values(mismatch, ~s(input[type="password"]))
      assert Enum.all?(field_values(mismatch, ~s(input[type="password"])), &(&1 == ""))

      assert_received {:overlay, overlay}
      assert overlay =~ "Restarting Fermix"
      # The overlay is the one thing on top: the step it came from has closed.
      refute overlay =~ ~s(id="always-on-step")
      assert_received {:after, after_move}
      assert_received {:saved, _recipient}
      assert_received :restarted
      assert after_move =~ "Restarting Fermix"

      for shown <- [log, mismatch, overlay, after_move] do
        refute shown =~ @passphrase
      end

      refute view.pid |> :sys.get_state() |> inspect(limit: :infinity) =~ @passphrase
    end

    test "a review that blocks takes the overlay down and says why; nothing moves", %{
      conn: conn,
      seams: seams
    } do
      put_seams(seams, free_bytes: fn _dir -> {:ok, 1} end)
      {view, _html} = open_view!(conn)
      press(view, "move_now")

      html =
        render_submit(view, "always_on_submit", %{
          "always_on_step" => %{"passphrase" => @passphrase, "passphrase_again" => @passphrase}
        })

      assert html =~ "Restarting Fermix"

      html = settle!(view)
      refute html =~ "Restarting Fermix"
      assert text(html, "#always-on-error") =~ "The move cannot start yet."
      refute_received :restarted
    end

    test "a passphrase that is not text is the page's error line, never a crash", %{conn: conn} do
      {view, _html} = open_view!(conn)
      press(view, "move_now")

      html =
        render_submit(view, "always_on_submit", %{
          "always_on_step" => %{"passphrase" => ["x"], "passphrase_again" => ["x"]}
        })

      assert text(html, "#always-on-error") == "Type the recovery passphrase as text."
      assert Process.alive?(view.pid)
      refute_received :restarted
    end
  end

  # The engine's screen moves on while the page still draws the older one:
  # here the last review of the server came to block the move.
  describe "a screen that changed" do
    setup ctx do
      :ok = Epoch.write(ctx.home, 4)
      {:ok, held} = Candidates.add(ctx.home, candidate_attrs(), @at)
      Agent.update(ctx.link, &%{&1 | enrollment: window(:used, held.candidate_id)})
      Map.put(ctx, :candidate_id, held.candidate_id)
    end

    test "a press from an older screen does nothing, says so, and the tab reads again", ctx do
      {view, _html} = open_view!(ctx.conn)
      press(view, "move_now")
      block!(ctx)

      html =
        submit!(view, %{"passphrase" => @passphrase, "passphrase_again" => @passphrase})

      assert text(html, "#always-on-error") ==
               "Always On changed since this was shown, so look at it again."

      assert text(html, "#always-on-sentence") == "The move cannot start yet. Too full."
      refute_received :restarted
    end

    test "a press the screen no longer offers runs nothing and reads the screen again", ctx do
      {view, _html} = open_view!(ctx.conn)
      block!(ctx)

      render_click(view, "always_on_press", %{"id" => "move_now", "key" => "an-older-key"})

      assert text(settle!(view), "#always-on-sentence") == "The move cannot start yet. Too full."
      refute settle!(view) =~ ~s(id="always-on-step")
    end
  end

  describe "live updates" do
    test "the page listens to the watch, reads on its word, and listens again once the " <>
           "watch is back",
         %{conn: conn, home: home, seams: seams} do
      read = fn -> %{key: :invented, off: false, next_change_ms: nil} end
      watch = :"setup_always_on_watch_#{System.unique_integer([:positive])}"
      start_supervised!({StatusWatch, name: watch, read: read, clock_monitor: false}, id: :w1)
      put_seams(seams, status_watch: watch)

      {view, html} = open_view!(conn)
      assert text(html, "#always-on-sentence") =~ ~r/\AKeep Fermix running/
      assert Map.has_key?(:sys.get_state(watch).subscribers, view.pid)

      held!(home, seams.link)
      :ok = stop_supervised!(:w1)
      start_supervised!({StatusWatch, name: watch, read: read, clock_monitor: false}, id: :w2)

      # The retry's timer is delivered by hand rather than waited out; the
      # new watch tells its first subscriber at once.
      send(view.pid, {:always_on_watch, :retry})
      render(view)
      assert Map.has_key?(:sys.get_state(watch).subscribers, view.pid)

      assert text(settle!(view), "#always-on-sentence") =~
               ~r/\AYour server is ready for the move\./
    end

    test "a watch that does not come back is looked for a bounded number of times", %{
      conn: conn
    } do
      {view, _html} = open_view!(conn)

      # Each retry's timer is delivered by hand: the mount's look counts once.
      log =
        capture_log(fn ->
          for _retry <- 1..30, do: send(view.pid, {:always_on_watch, :retry})
          render(view)
        end)

      assert %{watch: nil, watch_tries: 30} = always_on_state(view)
      assert log =~ "the Always On watch is not running"
    end
  end

  describe "on a device" do
    setup do
      put_role(@device)
    end

    test "the page opens on Always On and says where Fermix-wide settings live", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/setup")

      assert html =~ ~s(id="always-on-pane")

      assert text(html, "#device-role-notice") ==
               "Fermix-wide settings live on your server, invented-vm. This page sets up " <>
                 "this computer and Always On."

      refute text(html, "#device-role-notice") =~ "Fermix app"
      refute text(html, "#device-role-notice") =~ "primary"
    end

    test "the server's tabs say so instead of offering their forms; this computer's stay", %{
      conn: conn
    } do
      for tab <- ~w(provider channels realtime plugins cues memory) do
        {:ok, view, html} = live(conn, "/setup?tab=#{tab}")

        assert html =~ ~s(id="primary-only-pane"), "#{tab} offers the primary's settings"

        assert text(html, "#primary-only-pane p") ==
                 "These settings are Fermix-wide, so they live on your server, invented-vm."

        refute html =~ "Fermix app"
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

    test "linked: the server's summary, and Back up now is sent to the server", %{
      conn: conn,
      seams: seams
    } do
      linked!(seams)

      {view, html} = open_view!(conn, "/setup")
      assert text(html, "#always-on-sentence") =~ ~r/\AFermix runs on your server\./
      refute html =~ "bg-error"

      press(view, "back_up_now")
      settle!(view)
      assert_received {:forwarded, "home.snapshots.run", %{}}
    end

    # A move back moves the server's home here, and this computer restarts
    # only once it is in place, so the page raises no restart overlay.
    test "linked, moving back: Move now is sent to the server, the passphrase asked once, " <>
           "and this page does not restart",
         ctx do
      moving_back_ready!(ctx)
      {view, html} = open_view!(ctx.conn, "/setup")
      assert text(html, "#always-on-action") == "Move now"

      html = press(view, "move_now")
      assert [""] = field_values(html, ~s(input[type="password"]))

      html =
        render_submit(view, "always_on_submit", %{
          "always_on_step" => %{"passphrase" => @passphrase}
        })

      refute html =~ "Restarting Fermix"
      html = settle!(view)
      refute html =~ "Restarting Fermix"

      assert_received {:forwarded, "home.move.start", params}

      assert params == %{
               "candidate_id" => @back_cand,
               "recovery_passphrase" => @passphrase,
               "keep_as_desktop" => false
             }

      refute_received :restarted
      assert text(html, "#always-on-sentence") =~ "Moving Fermix back"
    end

    # Restore here once the server went silent: its confirm asks the owner's
    # word that the server is deleted or stopped, Back takes nothing, and the
    # restore runs in a job of its own, which the page draws from the press.
    test "linked and silent with a backup: Restore here asks first, Back takes nothing, " <>
           "and the page draws the restore running",
         %{conn: conn, link: link, seams: seams} = ctx do
      test = self()
      copy!(ctx)

      linked!(seams,
        role: :device,
        restarts_itself?: true,
        local_return: fn _home, _copy ->
          send(test, {:restoring, self()})
          receive do: (:go -> {:ok, %{"restored" => true, "epoch" => 6}})
        end
      )

      Agent.update(link, &%{&1 | primary: primary(11 * 60_000)})
      {view, _html} = open_view!(conn, "/setup")

      html = press(view, "restore_here")

      assert text(html, "#always-on-step") =~
               Copy.summary_sentence(:confirm_restore_here, %{machine: "computer"})

      html = view |> element(~s|#always-on-step [phx-click="always_on_back"]|) |> render_click()
      refute html =~ ~s(id="always-on-step")
      refute_received {:restoring, _run}

      press(view, "restore_here")
      html = submit!(view, %{"passphrase" => @passphrase})

      assert text(html, "#always-on-sentence") ==
               "Restoring Fermix on this computer from its backup. Messages wait until it is done."

      refute html =~ "Restarting Fermix"
      assert_receive {:restoring, run}, 10_000
      send(run, :go)
      settle_jobs!(seams)
    end

    # Always On's move back is drawn as any step is: pressed from Details'
    # actions, sent to the server over the link, and this page does not
    # restart (the restart comes at the activation, and the page reconnects).
    test "linked: Move back is sent to the server, and the page draws the connecting " <>
           "screen with no restart",
         %{conn: conn, seams: seams, home: home} do
      test = self()
      :ok = Moved.write(home, %{epoch: 4, moved_at: @at, to: "invented-vm"})

      linked!(seams,
        role: :device,
        restarts_itself?: true,
        start_return: fn _home ->
          send(test, :return_started)
          :ok
        end
      )

      {view, _html} = open_view!(conn, "/setup")
      press(view, "move_back")
      html = settle!(view)

      refute html =~ "Restarting Fermix"
      assert_received {:forwarded, "home.enroll.open", %{}}
      assert_received :return_started
      assert text(html, "#always-on-sentence") == "Connecting this computer to your server…"
      assert text(html, "#always-on-action") == "Cancel"
    end

    test "linked and silent for ten minutes: the page reads again on the watch's word", %{
      conn: conn,
      link: link,
      seams: seams
    } do
      linked!(seams)
      {view, _html} = open_view!(conn, "/setup")

      Agent.update(link, &%{&1 | primary: primary(11 * 60_000)})
      send(view.pid, :home_status_changed)

      assert text(settle!(view), "#always-on-sentence") ==
               "Fermix cannot reach your server. Your messages wait until it is back."
    end

    test "unlinked after a move: Fermix moved, and Learn more opens the docs", %{
      conn: conn,
      home: home
    } do
      :ok = Moved.write(home, %{epoch: 4, moved_at: ~U[2031-05-03 09:00:00Z], to: "invented-vm"})
      html = open!(conn, "/setup")

      assert text(html, "#always-on-sentence") ==
               "Fermix moved to your server, and this computer is no longer connected to it."

      assert [url] = attribute_values(html, "#always-on-action", "href")
      assert url =~ "https://fermix.ai/docs/always-on/"
    end
  end

  # -- the page ------------------------------------------------------------------

  defp open!(conn, path \\ "/setup?tab=always_on") do
    {_view, html} = open_view!(conn, path)
    html
  end

  defp open_view!(conn, path \\ "/setup?tab=always_on") do
    {:ok, view, _html} = live(conn, path)
    {view, settle!(view)}
  end

  defp press(view, id) do
    view
    |> element(~s|#always-on-pane [phx-click="always_on_press"][phx-value-id="#{id}"]|)
    |> render_click()
  end

  defp submit!(view, fields) do
    render_submit(view, "always_on_submit", %{"always_on_step" => fields})
    settle!(view)
  end

  # Every read and act the page started has answered: an act's answer may
  # start one read more (after `changed`), so a few rounds, each waiting only
  # for the page's own tasks.
  defp settle!(view), do: Enum.reduce(1..3, nil, fn _round, _html -> render_async(view) end)

  defp summary!(seams) do
    opts = Keyword.put(home_seams(seams), :engine_role, @primary)
    opts |> Home.summary_facts() |> HomeSummary.summary()
  end

  defp action!(summary, id) do
    Enum.find(HomeSummary.offered(summary), &(&1["id"] == id)) ||
      flunk("#{summary["state"]} offers no #{id}")
  end

  # -- the world -----------------------------------------------------------------

  # The owner's server enrolled with its code and held for the move.
  defp held!(home, link) do
    {:ok, held} = Candidates.add(home, candidate_attrs(), @at)
    Agent.update(link, &%{&1 | enrollment: window(:used, held.candidate_id)})
    :ok
  end

  # The last review of the held server blocks the move.
  defp block!(ctx) do
    blocked = %{ready: false, items: [%{id: "disk", status: :block, sentence: "Too full."}]}
    :ok = Move.put_review(ctx.home, ctx.candidate_id, blocked, @at)
  end

  defp window(state, candidate_id) do
    %{state: state, expires_at: ~U[2031-05-05 12:00:00Z], candidate_id: candidate_id}
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

  # A desktop linked to its server after a move, whose server answers its own
  # `home.status` and the steps sent to it.
  defp linked!(seams, overrides \\ []) do
    :ok = DesktopLink.write(seams.home, desktop_link())
    Agent.update(seams.link, &%{&1 | primary: primary(nil)})
    test = seams.test

    forward = fn %{method: method, params: params}, _opts ->
      send(test, {:forwarded, method, params})
      server_part(method)
    end

    put_seams(seams, overrides, fn -> [primary_forward: forward] end)
  end

  defp server_part("home.status") do
    {:ok,
     %{
       "role" => "primary",
       "version" => "9.9.9",
       "disk" => %{"used" => 0.4, "nearly_full" => false},
       "snapshots" => %{
         "targets" => [%{"label" => "S3", "last_verified" => %{"at" => "2031-05-04T10:00:00Z"}}]
       },
       "enrollment" => nil,
       "candidates" => []
     }}
  end

  defp server_part("home.snapshots.run"), do: {:ok, %{"started" => true, "snapshots" => %{}}}

  # The copied code the server opens for this desktop to move back with.
  defp server_part("home.enroll.open"),
    do: {:ok, %{"code" => return_code(), "expires_at" => "2031-05-04T12:30:00Z"}}

  defp return_code do
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

    code
  end

  # This desktop moving back: its candidate for the home, held by the server,
  # and the return's record; the server answers as the primary, and once it
  # took the move, with the move under way.
  defp moving_back_ready!(ctx) do
    :ok = Moved.write(ctx.home, %{epoch: 4, moved_at: @at, to: "invented-vm"})
    :ok = DesktopLink.write(ctx.home, desktop_link())

    {:ok, state} =
      Candidate.prepare_return(ctx.home, {:return, return_code()},
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
    :ok = Return.write(ctx.home, %{from: "invented-vm", started_at: @at, primary_epoch: 5})
    Agent.update(ctx.link, &%{&1 | primary: primary(nil)})
    moved = start_supervised!({Agent, fn -> false end}, id: :server_moved)
    test = self()

    forward = fn %{method: method, params: params}, _opts ->
      send(test, {:forwarded, method, params})
      moving_back_part(method, moved)
    end

    put_seams(ctx.seams, [role: :device, restarts_itself?: true], fn ->
      [primary_forward: forward]
    end)
  end

  defp moving_back_part("home.status", moved) do
    {:ok, on} = server_part("home.status")

    if Agent.get(moved, & &1),
      do:
        {:ok,
         Map.put(on, "move", %{"phase" => "requested", "candidate" => "x", "sentence" => "."})},
      else: {:ok, on}
  end

  defp moving_back_part("home.move.start", moved) do
    Agent.update(moved, fn _moved -> true end)
    {:ok, %{"move_id" => "mv-0001"}}
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

    FermixTestSupport.SafeRm.rm_rf!(server)
    path
  end

  defp primary(down_ms) do
    %{
      name: "invented-vm",
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
        name: "invented-vm",
        gateway_pk: :binary.copy(<<3>>, 32),
        node_id: String.duplicate("c4", 32),
        relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
        relays_rev: String.duplicate("a1", 8)
      },
      epoch: 5
    }
  end

  # -- jobs ----------------------------------------------------------------------

  defp jobs!(ctx) do
    tasks = :"setup_always_on_tasks_#{:erlang.phash2(ctx.test)}"
    start_supervised!({Task.Supervisor, name: tasks}, id: tasks)
    name = :"setup_always_on_jobs_#{:erlang.phash2(ctx.test)}"
    start_supervised!({Jobs, name: name, task_supervisor: tasks})
    [server: name]
  end

  # Every job of the family has ended, each read from its completion event.
  defp settle_jobs!(seams, rounds \\ 3)
  defp settle_jobs!(_seams, 0), do: flunk("a job of the family still runs after three rounds")

  defp settle_jobs!(seams, rounds) do
    for %{"status" => "running"} = job <- jobs(seams), do: finished(job, seams.jobs)
    if Enum.any?(jobs(seams), &(&1["status"] == "running")), do: settle_jobs!(seams, rounds - 1)
    :ok
  end

  defp jobs(seams) do
    {:ok, views} = Jobs.list(seams.jobs)
    views
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

  # -- seams ---------------------------------------------------------------------

  defp put_role(record) do
    Application.put_env(:fermix_web, :engine_role, fn -> record end)
    :ok
  end

  # The page's seams: the options every read and act take, the watch, how
  # this engine reaches its server, and how long Move now's overlay leads.
  defp put_seams(seams, overrides \\ [], forwarding \\ fn -> [] end) do
    {watch, overrides} = Keyword.pop(overrides, :status_watch, :setup_always_on_no_watch)
    {available, overrides} = Keyword.pop(overrides, :available, true)

    Application.put_env(:fermix_web, :always_on,
      home: Keyword.merge(home_seams(seams), overrides),
      status_watch: watch,
      forwarding: forwarding,
      overlay_ms: 0,
      available: available
    )
  end

  defp home_seams(seams) do
    test = seams.test
    link = seams.link

    [
      home: seams.home,
      now: @at,
      profile: "general",
      host_os: :linux,
      config: [],
      scheduler: nil,
      disk_usage: fn _home -> {:ok, %{used: 0.42, nearly_full: false}} end,
      link_status: fn -> Agent.get(link, & &1) end,
      jobs: seams.jobs,
      open_enrollment: fn nil ->
        Agent.update(link, &%{&1 | enrollment: window(:open, nil)})
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
      serializer: seams.serializer
    ]
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

  defp tab_ids(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[phx-value-tab]")
    |> Enum.flat_map(&LazyHTML.attribute(&1, "phx-value-tab"))
    |> Enum.uniq()
  end

  defp field_values(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(fn field -> field |> LazyHTML.attribute("value") |> List.first() end)
  end

  defp attribute_values(html, selector, attribute) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.flat_map(&LazyHTML.attribute(&1, attribute))
  end

  # Every event a control inside `selector` sends.
  defp actions(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{selector} [phx-click], #{selector} [phx-submit]")
    |> Enum.flat_map(
      &(LazyHTML.attribute(&1, "phx-click") ++ LazyHTML.attribute(&1, "phx-submit"))
    )
  end

  # The tab's state as the page holds it, read from the page's own process.
  defp always_on_state(view), do: :sys.get_state(view.pid).socket.assigns.always_on

  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
end
