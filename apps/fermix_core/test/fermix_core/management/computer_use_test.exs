defmodule FermixCore.Management.ComputerUseTest do
  @moduledoc """
  The `computer_use.grant.start` refusal sentences (M34 native setup §7.3), and
  what `computer_use.permissions.get` answers for each platform.

  The grant and the probe are injected, so nothing here spawns the sidecar or
  raises a macOS dialog: what is under test is the sentence a person reads when
  the grant is refused, the daemon log line that keeps the diagnosis, and the
  permissions answer each probed state projects to.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Fermix.CLI.Doctor.Checks
  alias FermixCore.Management.ComputerUse
  alias FermixCore.Management.Jobs

  @reset "gdbus call --session --dest org.freedesktop.impl.portal.PermissionStore " <>
           "--object-path /org/freedesktop/impl/portal/PermissionStore --method " <>
           "org.freedesktop.impl.portal.PermissionStore.DeletePermission screenshot " <>
           "screenshot io.tezra.fermix.ComputerUse"

  setup context do
    tasks = :"computer_use_tasks_#{:erlang.phash2(context.test)}"
    start_supervised!({Task.Supervisor, name: tasks}, id: tasks)

    server =
      start_supervised!(
        {Jobs, name: :"computer_use_jobs_#{:erlang.phash2(context.test)}", task_supervisor: tasks}
      )

    %{jobs: [server: server]}
  end

  describe "computer_use.grant.start" do
    # A helper the engine cannot speak to is not a broken prompt: the two halves
    # ship together, so the person is told they are from different releases and
    # that an update is the cure. The two versions stay in the daemon log, where
    # they are a diagnosis rather than copy.
    test "a helper from another release is named, with an update as the cure", %{jobs: jobs} do
      grant = fn -> {:error, {:protocol_mismatch, %{library: 6, sidecar: 5}}} end

      log =
        capture_log(fn ->
          assert {:ok, view} = ComputerUse.grant_start(jobs: jobs, grant: grant)
          done = await(view, jobs)

          assert done["status"] == "failed"
          assert done["failure"]["code"] == "unavailable"

          assert done["failure"]["sentence"] ==
                   "Fermix Computer Use on this Mac is from a different Fermix release. " <>
                     "Update Fermix to raise the prompts."
        end)

      assert log =~ "protocol_mismatch"
      assert log =~ "library: 6"
      assert log =~ "sidecar: 5"
    end

    # The residue is still the residue: a reason with no sentence of its own
    # carries the sidecar's words and the path it was spawned from, so the
    # published sentence stays fixed and the term goes to the log.
    test "an unnamed refusal keeps the fixed sentence and logs the term", %{jobs: jobs} do
      grant = fn -> {:error, {:driver_failed, "/Users/example/.fermix/computer_use/compux"}} end

      log =
        capture_log(fn ->
          assert {:ok, view} = ComputerUse.grant_start(jobs: jobs, grant: grant)

          assert await(view, jobs)["failure"]["sentence"] ==
                   "The permission prompts could not be raised. See the daemon log."
        end)

      assert log =~ "driver_failed"
      assert log =~ "/Users/example/.fermix/computer_use/compux"
    end
  end

  # On Linux nothing is granted: the two booleans say what this session's pixel
  # route serves, so the answer carries the platform, the display server the app
  # picks the route by, and the doctor's own Linux rows, from the producer
  # `fermix doctor` prints them with. Every probe here is the map
  # `Setup.Doctor.computer_use_permissions/0` answers, so nothing is spawned.
  describe "computer_use.permissions.get" do
    test "an X11 session answers its pixel route by X11, with the doctor's rows in order" do
      probe = linux()
      view = permissions(probe)

      assert view["installed"] == true
      assert view["screen_capture"] == true
      assert view["input_control"] == true
      assert {:ok, _at, 0} = DateTime.from_iso8601(view["probed_at"])
      assert view["platform"] == "linux"
      assert view["display_server"] == "x11"

      assert Enum.map(view["rows"], & &1["name"]) == [
               "display server",
               "accessibility bus",
               "atk bridge",
               "toolkit qt",
               "toolkit chromium",
               "x11 pixels",
               "desktop portal",
               "portal screenshot"
             ]

      assert view["rows"] == doctor_rows(probe)
      assert Enum.all?(view["rows"], &(Map.keys(&1) == ~w(detail name status)))

      assert row(view, "x11 pixels") ==
               %{"status" => "ok", "detail" => "XTEST present, keyboard map present"}
    end

    test "the computer use summary row, with its grant wording, is never one of the rows" do
      for probe <- [linux(), linux(display_server: "wayland", portal: portal(registry: true))] do
        names = Enum.map(permissions(probe)["rows"], & &1["name"])
        refute "computer use" in names
      end
    end

    test "GNOME Wayland answers its route by the desktop portal" do
      probe =
        linux(
          display_server: "wayland",
          portal: portal(version: "1.18.4-1ubuntu2", registry: true)
        )

      view = permissions(probe)

      assert view["display_server"] == "wayland"
      assert view["screen_capture"] == true
      assert view["input_control"] == true
      assert view["rows"] == doctor_rows(probe)

      assert row(view, "desktop portal") == %{
               "status" => "ok",
               "detail" => "xdg-desktop-portal 1.18.4-1ubuntu2; running; has the host registry"
             }
    end

    # KDE and other Wayland desktops: no pixel route, so both booleans are false,
    # while the accessibility bus answers and controls work.
    test "a controls-only Wayland session answers no pixels and a bus that answers" do
      probe =
        linux(
          display_server: "wayland",
          screen_capture: false,
          input_control: false,
          portal: portal(registry: true)
        )

      view = permissions(probe)

      assert view["screen_capture"] == false
      assert view["input_control"] == false
      assert view["display_server"] == "wayland"
      assert view["rows"] == doctor_rows(probe)

      assert row(view, "accessibility bus") ==
               %{"status" => "ok", "detail" => "answering, with 7 applications"}
    end

    test "an accessibility bus that is unavailable warns with the helper's reason" do
      bus = %{
        state: "unavailable",
        applications: nil,
        cause: "not_installed",
        detail: "org.a11y.Bus is not provided"
      }

      view = permissions(linux(accessibility_bus: bus, toolkit_notes: []))

      assert row(view, "accessibility bus") == %{
               "status" => "warn",
               "detail" => "unavailable (`not_installed`): org.a11y.Bus is not provided"
             }

      refute Enum.any?(view["rows"], &String.starts_with?(&1["name"], "toolkit"))
    end

    # The reset is a literal the person types, so it rides in backticks: the
    # Linux app shows it as selectable inline code.
    test "a stored Screenshot no carries the reset command in backticks" do
      probe = linux(display_server: "wayland", portal: portal(screenshot_permission: "no"))
      %{"status" => status, "detail" => detail} = row(permissions(probe), "portal screenshot")

      assert status == "warn"
      assert detail =~ "a stored no refuses every screenshot on Wayland until it is reset: `"
      assert String.ends_with?(detail, "`#{@reset}`")
    end

    test "a macOS answer gains only its platform" do
      mac = %{
        state: :probed,
        platform: "macos",
        display_server: "quartz",
        screen_capture: true,
        input_control: false
      }

      view = permissions(mac)

      assert Map.keys(view) == ~w(input_control installed platform probed_at screen_capture)
      assert view["platform"] == "macos"
      assert view["screen_capture"] == true
      assert view["input_control"] == false
    end

    test "a state that probed nothing answers exactly as before, with no platform" do
      assert {:ok, absent} =
               ComputerUse.permissions(probe: fn -> {:ok, %{state: :not_installed}} end)

      assert absent == %{
               "installed" => false,
               "screen_capture" => false,
               "input_control" => false,
               "probed_at" => nil
             }

      off = fn -> {:ok, %{state: :disabled}} end
      assert {:ok, disabled} = ComputerUse.permissions(probe: off, installed?: fn -> true end)

      assert disabled == %{
               "installed" => true,
               "screen_capture" => false,
               "input_control" => false,
               "probed_at" => nil
             }
    end
  end

  defp permissions(probe) do
    assert {:ok, view} = ComputerUse.permissions(probe: fn -> {:ok, probe} end)
    view
  end

  defp row(view, name) do
    case Enum.find(view["rows"], &(&1["name"] == name)) do
      nil -> flunk("no #{name} row in #{inspect(Enum.map(view["rows"], & &1["name"]))}")
      row -> Map.delete(row, "name")
    end
  end

  # What `fermix doctor` prints after its `computer use` row, as the wire carries it.
  defp doctor_rows(probe) do
    for %{name: name, status: status, detail: detail} <- tl(Checks.computer_use({:ok, probe})),
        do: %{"name" => name, "status" => Atom.to_string(status), "detail" => detail}
  end

  # A 22.04 X11 desktop as the helper reports it: a portal too old for the host
  # registry, both the Qt and the Chromium notes.
  defp linux(overrides \\ []) do
    %{
      state: :probed,
      platform: "linux",
      display_server: "x11",
      screen_capture: true,
      input_control: true,
      display_adopted: false,
      x11_pixels: %{xtest: true, keymap: true},
      portal: %{
        running: true,
        version: "1.14.4-1ubuntu2~22.04.2",
        registry: false,
        screenshot_permission: "unset"
      },
      accessibility_bus: %{state: "answering", applications: 7, cause: nil, detail: nil},
      accessibility_packages: %{source: "dpkg", at_spi2_core: "2.44.0-3", atk_bridge: "2.38.0-3"},
      toolkit_notes: [
        %{toolkit: "qt", note: "a Qt application publishes no tree: start it with QT_X=1"},
        %{toolkit: "chromium", note: "start it with --force-renderer-accessibility"}
      ]
    }
    |> Map.merge(Map.new(overrides))
  end

  defp portal(overrides), do: Map.merge(linux().portal, Map.new(overrides))

  defp await(view, jobs), do: await(view["job_id"], jobs, 50)

  defp await(job_id, jobs, 0) do
    {:ok, view} = Jobs.get(job_id, jobs)
    flunk("job #{job_id} never finished: #{inspect(view)}")
  end

  defp await(job_id, jobs, attempts) do
    {:ok, view} = Jobs.get(job_id, jobs)

    if view["status"] == "running" do
      Process.sleep(10)
      await(job_id, jobs, attempts - 1)
    else
      view
    end
  end
end
