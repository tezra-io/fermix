defmodule Fermix.CLI.RestartPhoneCallTest do
  @moduledoc """
  `fermix restart` while a phone call is in progress (M94 §12), on each of its
  three paths: the owner's restart asks the daemon for the window a call
  holds, and a refusal prints the daemon's own sentence and changes nothing.
  Every fact comes from an injected client and service, so nothing here
  reaches a socket or a service manager.
  """

  # async: false: these tests capture `:stderr`, one global device.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.RestartCommand

  @held "A phone call is in progress, and restarting Fermix now would hang it up without " <>
          "its outcome. Ask Fermix to stop the call, or let it end, then restart."
  @minimums %{"lifecycle.prepare" => 1, "lifecycle.prepare_restart" => 2}
  @older %{"lifecycle.prepare" => 1}

  defmodule AppBuildInfo do
    @moduledoc false
    def app_engine?, do: true
    def linux_package?, do: false
    def distribution_identity, do: "macos_app"
  end

  defmodule StandaloneBuildInfo do
    @moduledoc false
    def app_engine?, do: false
    def linux_package?, do: false
    def distribution_identity, do: "standalone"
  end

  defmodule PackagedBuildInfo do
    @moduledoc false
    def app_engine?, do: false
    def linux_package?, do: true
    def distribution_identity, do: "linux_package"
  end

  # The installed user-scope unit; its restart reports to the test.
  defmodule StandaloneService do
    @moduledoc false
    def installed?(scope), do: scope == :user

    def restart(scope) do
      send(Process.get(:restart_test), {:service_restart, scope})
      :ok
    end
  end

  defmodule PackagedService do
    @moduledoc false
    def restart(:user, opts) do
      send(Process.get(:restart_test), {:service_restart, opts})
      {:ok, %{"previous_pid" => "100", "pid" => "412", "alignment" => "aligned"}}
    end
  end

  setup do
    Process.put(:restart_test, self())
    :ok
  end

  # A daemon whose `hello` answers `pids` in turn (`:down` when it is not
  # running) and publishes `minimums`, and whose drain window answers `prepare`.
  defp client(pids, minimums, prepare) do
    test = self()
    counter = :counters.new(1, [])

    fn method, params, _opts ->
      send(test, {:called, method, params})

      case method do
        "hello" -> hello(pids, counter, minimums)
        "lifecycle.prepare" <> _which -> prepare
        "lifecycle.commit" -> {:ok, %{"lease_id" => "lease-1", "status" => "committed"}}
        "lifecycle.cancel" -> {:ok, %{"lease_id" => "lease-1", "status" => "cancelled"}}
      end
    end
  end

  defp hello(pids, counter, minimums) do
    :counters.add(counter, 1, 1)

    case Enum.at(pids, min(:counters.get(counter, 1) - 1, length(pids) - 1)) do
      :down ->
        {:error, :not_running}

      pid ->
        {:ok,
         %{
           "engine" => %{"pid" => pid},
           "capabilities" => %{"minimum_versions" => minimums}
         }}
    end
  end

  defp held do
    {:error,
     {:management_error, "unavailable", "That is not available here.",
      %{"capability" => "phone_calls", "sentence" => @held}}}
  end

  defp lease, do: {:ok, %{"lease_id" => "lease-1", "ttl_ms" => 30_000}}

  defp deps(build_info, client, extra \\ []) do
    [build_info: build_info, client: client, sleep: fn _ms -> :ok end, verify_polls: 4] ++ extra
  end

  describe "an app-managed engine" do
    test "a call in progress refuses the restart in the daemon's words, and nothing stops" do
      deps = deps(AppBuildInfo, client(["100"], @minimums, held()))

      stderr = capture_io(:stderr, fn -> assert RestartCommand.run([], deps) == 1 end)

      assert stderr == "fermix restart: #{@held}\n"
      assert_received {:called, "lifecycle.prepare_restart", %{}}
      refute_received {:called, "lifecycle.prepare", _params}
      refute_received {:called, "lifecycle.commit", _params}
    end

    test "with no call it restarts through the same window" do
      deps = deps(AppBuildInfo, client(["100", "100", "412"], @minimums, lease()))

      stdout = capture_io(fn -> assert RestartCommand.run([], deps) == 0 end)

      assert stdout =~ "daemon restarted (pid 412)"
      assert_received {:called, "lifecycle.prepare_restart", %{}}
      assert_received {:called, "lifecycle.commit", %{"lease_id" => "lease-1"}}
    end

    test "a daemon one release behind, which runs no phone calls, is asked as before" do
      deps = deps(AppBuildInfo, client(["100", "412"], @older, lease()))

      capture_io(fn -> assert RestartCommand.run([], deps) == 0 end)

      assert_received {:called, "lifecycle.prepare", %{}}
      refute_received {:called, "lifecycle.prepare_restart", _params}
    end
  end

  describe "a standalone engine" do
    test "a call in progress refuses before the service manager is asked" do
      deps =
        deps(StandaloneBuildInfo, client(["100"], @minimums, held()), service: StandaloneService)

      stderr = capture_io(:stderr, fn -> assert RestartCommand.run([], deps) == 1 end)

      assert stderr == "fermix restart: #{@held}\n"
      refute_received {:service_restart, _scope}
    end

    test "with no call the window is taken, released, and the unit restarted" do
      deps =
        deps(StandaloneBuildInfo, client(["100"], @minimums, lease()), service: StandaloneService)

      capture_io(fn -> assert RestartCommand.run([], deps) == 0 end)

      assert_received {:called, "lifecycle.prepare_restart", %{}}
      assert_received {:called, "lifecycle.cancel", %{"lease_id" => "lease-1"}}
      assert_received {:service_restart, :user}
      refute_received {:called, "lifecycle.commit", _params}
    end

    test "a daemon that is not answering is restarted as before" do
      deps =
        deps(StandaloneBuildInfo, client([:down], @minimums, held()), service: StandaloneService)

      capture_io(fn -> assert RestartCommand.run([], deps) == 0 end)

      assert_received {:service_restart, :user}
      refute_received {:called, "lifecycle.prepare_restart", _params}
    end
  end

  test "a packaged engine's restart is marked the owner's, so its window is the one a call holds" do
    deps = deps(PackagedBuildInfo, client(["100"], @minimums, lease()), service: PackagedService)

    capture_io(fn -> assert RestartCommand.run([], deps) == 0 end)

    assert_received {:service_restart, opts}
    assert Keyword.get(opts, :owner_restart) == true
  end
end
