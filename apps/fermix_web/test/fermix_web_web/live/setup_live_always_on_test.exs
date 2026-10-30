defmodule FermixWebWeb.SetupLiveAlwaysOnTest do
  # The setup page's Always On tab (M75 §14, B14): one read-only sentence for
  # where Fermix runs, and the device role's word on the rest of the page.
  # Every fact comes from `Management.Home.status/1` over a temp FERMIX_HOME:
  # the epoch, the move's phase and the moved marker are real files the core
  # modules write; the rail's facts (the primary, the desktops, the enrollment
  # window) come from a scripted `link_status`. Every secret goes through the
  # stub.
  use FermixWebWeb.ConnCase

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Move
  alias FermixCore.Home.Moved
  alias FermixCore.Setup.RestartState
  alias FermixTestSupport.SecretWriterStub

  @now ~U[2026-10-27 12:00:00Z]
  @primary %{role: :primary, primary: nil}
  @device %{role: :device, primary: "invented-vm"}
  @desktop_id "6d2b3c1e-1f7a-4c55-9a3e-2b8f6e0c4d71"

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

    # The apps hold the rest of Always On; this page names none of it, and
    # offers nothing to do but read the sentence again.
    test "on a primary: one sentence for where Fermix runs, and nothing to set up", %{
      conn: conn,
      home: home,
      link: link
    } do
      :ok = Epoch.write(home, 3)
      File.mkdir_p!(Move.dir(home))
      :ok = Move.put_phase(home, "aborted", %{"candidate" => "invented-new-vm"}, @now)

      desktop = %{device_id: @desktop_id, name: "Studio Mac", connected: true, since: @now}
      Agent.update(link, &%{&1 | desktops: [desktop]})

      {:ok, _view, html} = live(conn, "/setup?tab=always_on")

      assert html =~ ~s(id="always-on-pane")
      assert text(html, "#always-on-status") == "Fermix runs on this computer."
      assert html =~ ~s(href="https://fermix.ai/docs/always-on")
      assert actions(html, "#always-on-pane") == ["always_on_refresh"]

      for word <- ["Epoch", "primary", "invented-new-vm", "Studio Mac", "passphrase", "code"] do
        refute text(html, "#always-on-pane") =~ word, "the tab shows #{word}"
      end

      refute html =~ ~s(id="device-role-notice")
    end

    test "an event the tab no longer draws changes nothing and logs only its name", %{
      conn: conn,
      home: home
    } do
      {:ok, view, before} = live(conn, "/setup?tab=always_on")

      log =
        capture_log(fn ->
          html =
            render_click(view, "always_on_passphrase", %{
              "always_on_passphrase" => %{
                "password" => "invented-lighthouse-meridian",
                "password_again" => "invented-lighthouse-meridian"
              }
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

    # The link's own sentence, whatever its state: never a role word, a
    # connection dot or a time.
    test "linked: the link's own sentence", %{conn: conn, link: link} do
      for {status, connected, sentence} <- [
            {:connected, true, "Fermix is connected to the server invented-vm."},
            {:renewing, false, "Fermix is reconnecting to the server invented-vm."},
            {:unreachable, false,
             "The server invented-vm is unreachable: it did not answer. " <>
               "Fermix tries again in 30 s."}
          ] do
        primary = %{
          name: "invented-vm",
          connected: connected,
          status: status,
          since: if(connected, do: ~U[2026-10-27 11:30:00Z]),
          epoch: 5,
          sentence: sentence
        }

        Agent.update(link, &%{&1 | primary: primary})
        {:ok, view, html} = live(conn, "/setup")

        assert text(html, "#always-on-status") == sentence
        refute html =~ "bg-error"
        GenServer.stop(view.pid)
      end
    end

    test "Refresh reads the link again", %{conn: conn, link: link} do
      primary = %{
        name: "invented-vm",
        connected: true,
        status: :connected,
        since: ~U[2026-10-27 11:30:00Z],
        epoch: 5,
        sentence: "Fermix is connected to the server invented-vm."
      }

      Agent.update(link, &%{&1 | primary: primary})
      {:ok, view, _html} = live(conn, "/setup")

      unreachable = "The server invented-vm is unreachable: it did not answer."

      lost = %{
        primary
        | connected: false,
          status: :unreachable,
          since: nil,
          sentence: unreachable
      }

      Agent.update(link, &%{&1 | primary: lost})

      html = view |> element(~s|button[phx-click="always_on_refresh"]|) |> render_click()

      assert text(html, "#always-on-status") == unreachable
    end

    test "unlinked after a move: where the home went, and that this computer no longer " <>
           "reaches it",
         %{conn: conn, home: home} do
      :ok = Moved.write(home, %{epoch: 4, moved_at: ~U[2026-10-26 09:00:00Z], to: "invented-vm"})
      {:ok, _view, html} = live(conn, "/setup")

      assert text(html, "#always-on-status") ==
               "Fermix moved to invented-vm, and this computer is no longer connected to it."
    end

    test "unlinked with no marker: not connected to a server", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/setup")

      assert text(html, "#always-on-status") == "This computer is not connected to a server."
    end
  end

  # -- seams ---------------------------------------------------------------------

  defp put_role(record) do
    Application.put_env(:fermix_web, :engine_role, fn -> record end)
    :ok
  end

  defp put_seams(link) do
    Application.put_env(:fermix_web, :always_on,
      home: [now: @now, scheduler: nil, link_status: fn -> Agent.get(link, & &1) end]
    )
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

  # Every event a control inside `selector` sends.
  defp actions(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{selector} [phx-click], #{selector} [phx-submit]")
    |> Enum.flat_map(
      &(LazyHTML.attribute(&1, "phx-click") ++ LazyHTML.attribute(&1, "phx-submit"))
    )
  end

  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
end
