defmodule FermixCore.Management.InstallsTest do
  @moduledoc """
  The three job-backed device operations: `capabilities.install.start`,
  `computer_use.grant.start` and `meetings.signin.start`, plus the one read
  beside them, `computer_use.permissions.get`.

  Every installer, prompt and sign-in is injected, so nothing here downloads a
  binary, raises an OS dialog or launches a browser.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Management.Capabilities
  alias FermixCore.Management.ComputerUse
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.Meetings

  setup context do
    tasks = :"install_tasks_#{:erlang.phash2(context.test)}"
    start_supervised!({Task.Supervisor, name: tasks}, id: tasks)

    server =
      start_supervised!(
        {Jobs, name: :"install_jobs_#{:erlang.phash2(context.test)}", task_supervisor: tasks}
      )

    %{jobs: [server: server]}
  end

  describe "capabilities.install.start" do
    test "the computer use helper install names its download phase", %{jobs: jobs} do
      owner = self()

      install = fn ->
        send(owner, {:installing, self()})

        receive do
          :finish -> {:ok, "/tmp/compux"}
        end
      end

      assert {:ok, started} =
               Capabilities.install_start("computer_use_sidecar", jobs: jobs, install: install)

      assert started["kind"] == "capability_install"
      assert started["budget_ms"] == Jobs.budget_ms(:capability_install)

      assert_receive {:installing, pid}
      assert {:ok, running} = Jobs.get(started["job_id"], jobs)
      assert running["phase"] == "sidecar_downloading"

      send(pid, :finish)
      assert {:ok, done} = terminal(jobs, started["job_id"])

      assert done["status"] == "completed"
      assert done["result"] == %{"target" => "computer_use_sidecar", "installed" => true}
    end

    # A meeting join needs the sidecar AND the browser it launches, so an
    # install that stops after the first would report a capability that cannot
    # run.
    test "the notetaker install runs both halves before reporting installed", %{jobs: jobs} do
      owner = self()

      install = fn ->
        send(owner, :sidecar)
        {:ok, "/tmp/fermix-meetbot"}
      end

      install_browser = fn ->
        send(owner, :browser)
        {:ok, :installed}
      end

      assert {:ok, started} =
               Capabilities.install_start("meetbot",
                 jobs: jobs,
                 install: install,
                 install_browser: install_browser
               )

      assert {:ok, done} = terminal(jobs, started["job_id"])

      assert_receive :sidecar
      assert_receive :browser
      assert done["status"] == "completed"
      assert done["result"] == %{"target" => "meetbot", "installed" => true}
    end

    test "an unpinned notetaker release refuses in the installer's own words", %{jobs: jobs} do
      install = fn -> {:error, :no_pinned_release} end

      assert {:ok, started} = Capabilities.install_start("meetbot", jobs: jobs, install: install)
      assert {:ok, done} = terminal(jobs, started["job_id"])

      assert done["status"] == "failed"
      assert done["failure"]["sentence"] =~ "No meetbot sidecar release is pinned"
    end

    test "the on-device speech install reports its two stages as phases", %{jobs: jobs} do
      owner = self()

      install = fn opts ->
        progress = Keyword.fetch!(opts, :progress)
        progress.({:sidecar, :downloading})
        send(owner, {:staged, self()})

        receive do
          :finish ->
            progress.({:sidecar, :done})
            send(owner, :model)

            receive do
              :done -> :ok
            end
        end
      end

      assert {:ok, started} =
               Capabilities.install_start("local_stt", jobs: jobs, install: install)

      assert_receive {:staged, pid}
      assert {:ok, first} = Jobs.get(started["job_id"], jobs)
      assert first["phase"] == "sidecar_downloading"

      send(pid, :finish)
      assert_receive :model
      assert {:ok, second} = Jobs.get(started["job_id"], jobs)
      assert second["phase"] == "downloading"

      send(pid, :done)
      assert {:ok, done} = terminal(jobs, started["job_id"])
      assert done["status"] == "completed"
    end

    # A reason with no sentence of its own carries the operator's own paths, so
    # the published sentence is fixed and the term goes to the daemon log.
    test "an unnamed install failure publishes a fixed sentence", %{jobs: jobs} do
      install = fn -> {:error, {:cache_write_failed, "/Users/example/.fermix/plugins/compux"}} end

      assert {:ok, started} =
               Capabilities.install_start("computer_use_sidecar", jobs: jobs, install: install)

      assert {:ok, done} = terminal(jobs, started["job_id"])

      assert done["status"] == "failed"
      assert done["failure"]["sentence"] == "The install did not finish. See the daemon log."
    end

    test "a download that did not match its checksum says so", %{jobs: jobs} do
      install = fn -> {:error, {:checksum_mismatch, "abc", "def"}} end

      assert {:ok, started} =
               Capabilities.install_start("computer_use_sidecar", jobs: jobs, install: install)

      assert {:ok, done} = terminal(jobs, started["job_id"])

      assert done["failure"]["sentence"] ==
               "The download did not match the checksum it was published with."
    end

    test "an unknown target is refused by field and mints no job", %{jobs: jobs} do
      assert {:error, {:invalid_params, "target", _sentence}} =
               Capabilities.install_start("something_else", jobs: jobs)

      assert {:ok, []} = Jobs.list(jobs)
    end

    test "a second install of the same target is refused as busy", %{jobs: jobs} do
      owner = self()

      install = fn ->
        send(owner, :installing)

        receive do
          :finish -> {:ok, "/tmp/compux"}
        end
      end

      assert {:ok, _first} =
               Capabilities.install_start("computer_use_sidecar", jobs: jobs, install: install)

      assert_receive :installing

      assert {:error, {:busy, "capability_install"}} =
               Capabilities.install_start("computer_use_sidecar", jobs: jobs, install: install)
    end

    test "the published target catalog is closed" do
      assert Capabilities.targets() == ~w(computer_use_sidecar meetbot local_stt)
    end
  end

  describe "computer_use.permissions.get" do
    test "a probed helper reports its grants and when they were read" do
      probe = fn ->
        {:ok, %{state: :probed, screen_capture: true, input_control: false, platform: "macos"}}
      end

      assert {:ok, view} = ComputerUse.permissions(probe: probe)

      assert view["installed"] == true
      assert view["screen_capture"] == true
      assert view["input_control"] == false
      assert {:ok, _at, 0} = DateTime.from_iso8601(view["probed_at"])
    end

    test "an absent helper reports nothing granted and nothing probed" do
      probe = fn -> {:ok, %{state: :not_installed}} end

      assert {:ok, view} = ComputerUse.permissions(probe: probe)

      assert view == %{
               "installed" => false,
               "screen_capture" => false,
               "input_control" => false,
               "probed_at" => nil
             }
    end

    # Switched off is not the same as absent: the pane needs to know which of
    # "install it" and "turn it on" to offer.
    test "a switched-off feature still reports whether the helper is on disk" do
      probe = fn -> {:ok, %{state: :disabled}} end

      assert {:ok, view} = ComputerUse.permissions(probe: probe, installed?: fn -> true end)
      assert view["installed"] == true
      assert view["probed_at"] == nil

      assert {:ok, absent} = ComputerUse.permissions(probe: probe, installed?: fn -> false end)
      assert absent["installed"] == false
    end

    test "a helper that cannot be asked answers unavailable, not a wrong grant state" do
      probe = fn -> {:error, :port_closed} end

      assert {:error, {:unavailable, "computer_use_permissions"}} =
               ComputerUse.permissions(probe: probe)
    end
  end

  describe "computer_use.grant.start" do
    test "the grant is a job whose result is what the OS actually granted", %{jobs: jobs} do
      grant = fn -> {:ok, %{screen_capture: true, input_control: false}} end

      assert {:ok, started} = ComputerUse.grant_start(jobs: jobs, grant: grant)
      assert started["kind"] == "computer_use_grant"
      assert started["budget_ms"] == Jobs.budget_ms(:computer_use_grant)

      assert {:ok, done} = terminal(jobs, started["job_id"])
      assert done["status"] == "completed"
      assert done["result"] == %{"screen_capture" => true, "input_control" => false}
    end

    test "a grant that cannot be raised fails with the daemon's sentence", %{jobs: jobs} do
      grant = fn -> {:error, :not_installed} end

      assert {:ok, started} = ComputerUse.grant_start(jobs: jobs, grant: grant)
      assert {:ok, done} = terminal(jobs, started["job_id"])

      assert done["status"] == "failed"
      assert done["failure"]["sentence"] == "Fermix Computer Use is not installed yet."
    end

    test "a grant refused for an unnamed reason publishes a fixed sentence", %{jobs: jobs} do
      grant = fn -> {:error, {:driver_crashed, "/Applications/Fermix.app"}} end

      assert {:ok, started} = ComputerUse.grant_start(jobs: jobs, grant: grant)
      assert {:ok, done} = terminal(jobs, started["job_id"])

      assert done["failure"]["sentence"] ==
               "The permission prompts could not be raised. See the daemon log."
    end
  end

  describe "meetings.signin.start" do
    test "the sign-in is a job that waits on a person", %{jobs: jobs} do
      owner = self()

      signin = fn ->
        send(owner, {:signing_in, self()})

        receive do
          :finish -> {:ok, :signed_in}
        end
      end

      assert {:ok, started} = Meetings.signin_start(signin_opts(jobs, signin))
      assert started["kind"] == "meetings_signin"
      assert started["budget_ms"] == Jobs.budget_ms(:meetings_signin)

      assert_receive {:signing_in, pid}
      assert {:ok, running} = Jobs.get(started["job_id"], jobs)
      assert running["phase"] == "awaiting_signin"

      send(pid, :finish)
      assert {:ok, done} = terminal(jobs, started["job_id"])
      assert done["result"] == %{"signed_in" => true}
    end

    # The refusal is the whole of the answer, so it reaches the operator as the
    # job's own sentence rather than as a bare capability name.
    test "a missing notetaker refuses inside the job, with the reason", %{jobs: jobs} do
      opts =
        jobs
        |> signin_opts(fn -> flunk("the sign-in must not launch without the notetaker") end)
        |> Keyword.put(:installed?, fn -> false end)

      assert {:ok, started} = Meetings.signin_start(opts)
      assert {:ok, done} = terminal(jobs, started["job_id"])

      assert done["status"] == "failed"

      assert done["failure"]["sentence"] ==
               "Install the meeting notetaker first; the sign-in needs it."
    end

    test "a missing notetaker browser refuses with its own reason", %{jobs: jobs} do
      opts =
        jobs
        |> signin_opts(fn -> flunk("the sign-in must not launch without the browser") end)
        |> Keyword.put(:browser_installed?, fn -> false end)

      assert {:ok, started} = Meetings.signin_start(opts)
      assert {:ok, done} = terminal(jobs, started["job_id"])

      assert done["failure"]["sentence"] =~ "browser is not installed yet"
    end

    test "a cancelled sign-in says so rather than reporting a bare exit", %{jobs: jobs} do
      assert {:ok, started} =
               Meetings.signin_start(signin_opts(jobs, fn -> {:error, :cancelled} end))

      assert {:ok, done} = terminal(jobs, started["job_id"])

      assert done["failure"]["sentence"] == "The sign-in window was closed before it finished."
    end

    test "a sign-in window that would not open says so", %{jobs: jobs} do
      failed = fn -> {:error, {:spawn_failed, "/Users/example/.fermix/plugins/meetbot/bin"}} end

      assert {:ok, started} = Meetings.signin_start(signin_opts(jobs, failed))
      assert {:ok, done} = terminal(jobs, started["job_id"])

      assert done["failure"]["sentence"] == "The sign-in window could not be opened."
    end

    # A reason with no sentence of its own names files on the operator's disk,
    # so it goes to the daemon log and the published sentence stays fixed.
    test "a sign-in refused for an unnamed reason publishes a fixed sentence", %{jobs: jobs} do
      failed = fn -> {:error, {:profile_locked, "/Users/example/.fermix/plugins/meetbot"}} end

      assert {:ok, started} = Meetings.signin_start(signin_opts(jobs, failed))
      assert {:ok, done} = terminal(jobs, started["job_id"])

      assert done["failure"]["sentence"] == "The sign-in did not finish. See the daemon log."
    end

    test "a second sign-in is refused as busy", %{jobs: jobs} do
      owner = self()

      signin = fn ->
        send(owner, :signing_in)

        receive do
          :finish -> {:ok, :signed_in}
        end
      end

      assert {:ok, _first} = Meetings.signin_start(signin_opts(jobs, signin))
      assert_receive :signing_in

      assert {:error, {:busy, "meetings_signin"}} =
               Meetings.signin_start(signin_opts(jobs, signin))
    end
  end

  defp signin_opts(jobs, signin) do
    [
      jobs: jobs,
      signin: signin,
      installed?: fn -> true end,
      browser_installed?: fn -> true end
    ]
  end

  defp terminal(jobs, job_id, attempts \\ 200)
  defp terminal(_jobs, job_id, 0), do: {:error, {:never_terminal, job_id}}

  defp terminal(jobs, job_id, attempts) do
    {:ok, view} = Jobs.get(job_id, jobs)

    if view["status"] == "running" do
      Process.sleep(10)
      terminal(jobs, job_id, attempts - 1)
    else
      {:ok, view}
    end
  end
end
