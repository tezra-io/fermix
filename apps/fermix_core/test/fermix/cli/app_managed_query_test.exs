defmodule Fermix.CLI.AppManagedQueryTest do
  # Mutates `:fermix_core, :log` so the standalone log path is a fixture rather
  # than the operator's real `~/.fermix/logs/fermix.log`.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.Doctor
  alias Fermix.CLI.LogsCommand

  defmodule AppBuildInfo do
    def app_engine?, do: true
  end

  defmodule StandaloneBuildInfo do
    def app_engine?, do: false
  end

  setup do
    previous_log = Application.get_env(:fermix_core, :log)
    log_dir = mkdir!()
    Application.put_env(:fermix_core, :log, file: Path.join(log_dir, "fermix.log"))

    on_exit(fn ->
      restore_env(:log, previous_log)
      FermixTestSupport.SafeRm.rm_rf!(log_dir)
    end)

    %{log_dir: log_dir}
  end

  describe "fermix doctor on an app-managed engine" do
    test "runs the local session over the socket and never runs a local check" do
      client = scripted_client([{:ok, completed_view("doctor:one", "local")}])

      output =
        capture_io(fn ->
          assert Doctor.run([], app_deps(client)) == 1
        end)

      assert_receive {:called, "doctor.start", %{"scope" => "local"}}
      refute_received {:called, "doctor.get", _params}

      assert output =~ "readiness"
      assert output =~ "passed"
      assert output =~ "daemon_socket"
      assert output =~ "failed"
      assert output =~ "doctor:one"
    end

    test "polls doctor.get until the session reaches a terminal status" do
      client =
        scripted_client([
          {:ok, running_view("doctor:two", "local")},
          {:ok, running_view("doctor:two", "local")},
          {:ok, completed_view("doctor:two", "local")}
        ])

      capture_io(fn -> assert Doctor.run([], app_deps(client)) == 1 end)

      assert_receive {:called, "doctor.start", %{"scope" => "local"}}
      assert_receive {:called, "doctor.get", %{"session_id" => "doctor:two"}}
      assert_receive {:called, "doctor.get", %{"session_id" => "doctor:two"}}
    end

    # `--full` is local PLUS network, and the management scopes are disjoint
    # catalogs with their own budgets, so it must run both sessions.
    test "--full runs the local session and then the network session" do
      client =
        scripted_client([
          {:ok, passing_view("doctor:local", "local")},
          {:ok, passing_view("doctor:network", "network")}
        ])

      output =
        capture_io(fn ->
          assert Doctor.run(["--full"], app_deps(client)) == 0
        end)

      assert_receive {:called, "doctor.start", %{"scope" => "local"}}
      assert_receive {:called, "doctor.start", %{"scope" => "network"}}
      assert output =~ "doctor:local"
      assert output =~ "doctor:network"
    end

    test "a session that timed out exits non-zero even with no failed check" do
      client = scripted_client([{:ok, timed_out_view("doctor:slow", "local")}])

      output = capture_io(fn -> assert Doctor.run([], app_deps(client)) == 1 end)

      assert output =~ "timed_out"
    end

    test "an unreachable daemon is reported and no local check runs" do
      client = scripted_client([{:error, :not_running}])

      stderr =
        capture_io(:stderr, fn ->
          assert Doctor.run([], app_deps(client)) == 1
        end)

      assert stderr =~ "fermix doctor:"
      assert stderr =~ "not running"
      assert stderr =~ "Fermix.app"
    end

    # The poll is bounded, and its exhaustion is an operator sentence rather
    # than an inspected atom nobody can act on.
    test "a session that never leaves running is bounded and explained" do
      running = {:ok, running_view("doctor:stuck", "local")}
      client = scripted_client(List.duplicate(running, 200))

      stderr =
        capture_io(:stderr, fn ->
          assert Doctor.run([], app_deps(client)) == 1
        end)

      assert stderr =~ "did not finish the check run within its own budget"
      refute stderr =~ "doctor_session_unfinished"
    end

    test "a management error is reported in the daemon's own words" do
      client =
        scripted_client([
          {:error, {:management_error, "busy", "Another management operation is running.", %{}}}
        ])

      stderr =
        capture_io(:stderr, fn ->
          assert Doctor.run([], app_deps(client)) == 1
        end)

      assert stderr =~ "Another management operation is running."
      assert stderr =~ "busy"
    end
  end

  describe "fermix doctor on a standalone engine" do
    test "runs local checks and never opens the management socket" do
      collected = fn full? -> [%{name: "local", status: :ok, detail: "full? #{full?}"}] end

      deps = [
        build_info: StandaloneBuildInfo,
        client: raising_client(),
        collect_results: collected
      ]

      output = capture_io(fn -> assert Doctor.run([], deps) == 0 end)

      assert output =~ "full? false"
      refute_received {:called, _method, _params}
    end
  end

  describe "fermix logs on an app-managed engine" do
    test "renders one bounded page from logs.query and never spawns tail" do
      page = %{
        "entries" => [
          %{
            "time" => "2026-08-19T09:00:00.000Z",
            "level" => "info",
            "subsystem" => "daemon",
            "message" => "Daemon control socket listening"
          }
        ],
        "count" => 1,
        "truncated" => false,
        "direction" => "backward",
        "cursor" => nil
      }

      client = scripted_client([{:ok, page}])

      output = capture_io(fn -> assert LogsCommand.run([], app_deps(client)) == 0 end)

      assert_receive {:called, "logs.query", %{"limit" => 100, "direction" => "backward"}}
      assert output =~ "2026-08-19T09:00:00.000Z"
      assert output =~ "info"
      assert output =~ "Daemon control socket listening"
    end

    test "-n above the published ceiling refuses with the exact ceiling" do
      stderr =
        capture_io(:stderr, fn ->
          assert LogsCommand.run(["-n", "501"], app_deps(raising_client())) == 1
        end)

      assert stderr =~ "fermix logs:"
      assert stderr =~ "500"
    end

    test "--follow refuses and names the surface that follows" do
      stderr =
        capture_io(:stderr, fn ->
          assert LogsCommand.run(["-f"], app_deps(raising_client())) == 1
        end)

      assert stderr =~ "fermix logs:"
      assert stderr =~ "Fermix.app"
      assert stderr =~ "Logs"
    end

    test "a truncated page says so rather than presenting a complete tail" do
      page = %{
        "entries" => [],
        "count" => 0,
        "truncated" => true,
        "direction" => "backward",
        "cursor" => nil
      }

      output =
        capture_io(fn ->
          assert LogsCommand.run([], app_deps(scripted_client([{:ok, page}]))) == 0
        end)

      assert output =~ "truncated"
    end
  end

  describe "fermix logs on a standalone engine" do
    test "reads the log file and never opens the management socket", %{log_dir: log_dir} do
      deps = [build_info: StandaloneBuildInfo, client: raising_client()]

      stderr =
        capture_io(:stderr, fn ->
          assert LogsCommand.run([], deps) == 1
        end)

      assert stderr =~ "no log file at #{Path.join(log_dir, "fermix.log")}"
      refute_received {:called, _method, _params}
    end
  end

  defp app_deps(client),
    do: [build_info: AppBuildInfo, client: client, poll_sleep: fn _ms -> :ok end]

  defp scripted_client(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)
    test_pid = self()

    fn method, params, _opts ->
      send(test_pid, {:called, method, params})

      Agent.get_and_update(agent, fn
        [reply | rest] -> {reply, rest}
        [] -> {{:error, :no_scripted_reply}, []}
      end)
    end
  end

  defp raising_client do
    fn method, _params, _opts -> raise "the management socket must not be used: #{method}" end
  end

  defp running_view(session_id, scope) do
    session_id
    |> completed_view(scope)
    |> Map.merge(%{"status" => "running", "finished_at" => nil, "completed_count" => 0})
  end

  defp timed_out_view(session_id, scope) do
    session_id
    |> passing_view(scope)
    |> Map.merge(%{
      "status" => "timed_out",
      "summary" => tally(%{"passed" => 1, "timed_out" => 1}),
      "checks" =>
        passing_view(session_id, scope)["checks"] ++
          [check("plugins", "timed_out", "The run budget elapsed before this check ran.")]
    })
  end

  defp passing_view(session_id, scope) do
    session_id
    |> completed_view(scope)
    |> Map.merge(%{
      "summary" => tally(%{"passed" => 1}),
      "total" => 1,
      "completed_count" => 1,
      "checks" => [check("readiness", "passed", "Ready.")]
    })
  end

  defp completed_view(session_id, scope) do
    %{
      "session_id" => session_id,
      "scope" => scope,
      "status" => "completed",
      "budget_ms" => 10_000,
      "duration_ms" => 120,
      "started_at" => "2026-08-19T09:00:00Z",
      "finished_at" => "2026-08-19T09:00:00Z",
      "total" => 2,
      "completed_count" => 2,
      "summary" => tally(%{"passed" => 1, "failed" => 1}),
      "checks" => [
        check("readiness", "passed", "Ready."),
        check("daemon_socket", "failed", "Not running.")
      ]
    }
  end

  defp check(id, status, summary) do
    %{
      "id" => id,
      "category" => "runtime",
      "severity" => "critical",
      "applicability" => "always",
      "origin" => "engine",
      "status" => status,
      "summary" => summary,
      "evidence" => %{},
      "remediation_code" => if(status == "passed", do: nil, else: "#{id}.#{status}"),
      "duration_ms" => 1,
      "finished_at" => "2026-08-19T09:00:00Z"
    }
  end

  defp tally(counts) do
    ~w(passed warning failed unavailable skipped cancelled timed_out)
    |> Map.new(fn status -> {status, Map.get(counts, status, 0)} end)
  end

  defp mkdir! do
    path =
      Path.join(
        System.tmp_dir!(),
        "fermix-app-managed-query-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    path
  end

  defp restore_env(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore_env(key, value), do: Application.put_env(:fermix_core, key, value)
end
