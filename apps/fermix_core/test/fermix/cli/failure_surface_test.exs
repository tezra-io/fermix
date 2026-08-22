defmodule Fermix.CLI.FailureSurfaceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.AgentsCommand
  alias Fermix.CLI.CapabilitiesCommand
  alias Fermix.CLI.SkillsCommand
  alias Fermix.CLI.StatusCommand

  setup do
    previous_home = System.get_env("FERMIX_HOME")
    socket_dir = mkdir!()
    System.put_env("FERMIX_HOME", socket_dir)

    on_exit(fn ->
      restore_env("FERMIX_HOME", previous_home)
      FermixTestSupport.SafeRm.rm_rf!(socket_dir)
    end)

    %{socket_path: Path.join(socket_dir, "daemon.sock")}
  end

  # The v1 projection publishes that jobs are unavailable but not the raw
  # registry term behind it, so `--full` must still surface the state itself.
  test "status --full makes unavailable jobs visible", %{socket_path: socket_path} do
    task =
      serve_v1_once(socket_path, %{
        "daemon" => %{"status" => "running"},
        "readiness" => %{"status" => "ready"},
        "agents" => %{"main" => %{"status" => "idle"}, "skill_workers" => 0},
        "jobs" => %{
          "status" => "unavailable",
          "scheduled" => 0,
          "running" => 0,
          "paused" => 0,
          "failed_recent" => 0
        },
        "capabilities" => %{"builtin" => 0, "skill" => 0, "mcp" => 0}
      })

    test_self = self()

    output =
      capture_io(fn ->
        send(test_self, {:exit_status, StatusCommand.run(["--full"])})
      end)

    assert_receive {:exit_status, 0}
    Task.await(task, 1_000)
    assert output =~ "jobs: unavailable"
    assert output =~ "fermix doctor"
  end

  test "capabilities command reports structured daemon errors", %{socket_path: socket_path} do
    task =
      serve_once(socket_path, %{
        "status" => "error",
        "reason" => %{"registry" => "down"}
      })

    test_self = self()

    stderr =
      capture_io(:stderr, fn ->
        send(test_self, {:exit_status, CapabilitiesCommand.run(["--json"])})
      end)

    assert_receive {:exit_status, 1}
    Task.await(task, 1_000)
    assert stderr =~ ~s(fermix capabilities: %{"registry" => "down"})
  end

  test "agents command reports daemon errors without unexpected-reply noise", %{
    socket_path: socket_path
  } do
    task =
      serve_once(socket_path, %{
        "status" => "error",
        "reason" => "{:main_agent_unavailable, :noproc}"
      })

    test_self = self()

    stderr =
      capture_io(:stderr, fn ->
        send(test_self, {:exit_status, AgentsCommand.run(["--json"])})
      end)

    assert_receive {:exit_status, 1}
    Task.await(task, 1_000)
    assert stderr =~ ~s(fermix agents: "{:main_agent_unavailable, :noproc}")
    refute stderr =~ "unexpected reply"
  end

  # A v1 error carries the daemon's own sentence and a stable code; neither is
  # replaced by an inspected internal term.
  test "status overview reports daemon errors without unexpected-reply noise", %{
    socket_path: socket_path
  } do
    task =
      serve_v1_error_once(socket_path, %{
        "code" => "unavailable",
        "message" => "The requested management capability is unavailable.",
        "details" => %{"capability" => "overview"}
      })

    test_self = self()

    stderr =
      capture_io(:stderr, fn ->
        send(test_self, {:exit_status, StatusCommand.run(["--json"])})
      end)

    assert_receive {:exit_status, 1}
    Task.await(task, 1_000)
    assert stderr =~ "fermix status: The requested management capability is unavailable."
    assert stderr =~ "(unavailable)"
    refute stderr =~ "unexpected reply"
  end

  test "skills list pretty-prints rows and errors", %{socket_path: socket_path} do
    task =
      serve_once(socket_path, %{
        "status" => "ok",
        "skills" => %{
          "count" => 1,
          "skills" => [
            %{"name" => "alpha", "trust" => "operator", "description" => "Use alpha."}
          ],
          "errors" => ["{:invalid_skill, \"bad\", :missing_frontmatter}"]
        }
      })

    test_self = self()

    output =
      capture_io(fn ->
        send(test_self, {:exit_status, SkillsCommand.run(["list"])})
      end)

    assert_receive {:exit_status, 0}
    Task.await(task, 1_000)
    assert output =~ "skills: 1"
    assert output =~ "- alpha [operator] Use alpha."
    assert output =~ "errors: 1"
  end

  test "skills view pretty-prints the selected skill body", %{socket_path: socket_path} do
    task =
      serve_once(socket_path, %{
        "status" => "ok",
        "skill" => %{
          "name" => "alpha",
          "description" => "Use alpha.",
          "trust" => "operator",
          "source_path" => "/tmp/alpha/SKILL.md",
          "body" => "Alpha body."
        }
      })

    test_self = self()

    output =
      capture_io(fn ->
        send(test_self, {:exit_status, SkillsCommand.run(["view", "alpha"])})
      end)

    assert_receive {:exit_status, 0}
    Task.await(task, 1_000)
    assert output =~ "# alpha"
    assert output =~ "path: /tmp/alpha/SKILL.md"
    assert output =~ "Alpha body."
  end

  test "skills reload --json prints reload summary", %{socket_path: socket_path} do
    task =
      serve_once(socket_path, %{
        "status" => "ok",
        "reload" => %{
          "count" => 1,
          "names" => ["alpha"],
          "added" => ["alpha"],
          "removed" => [],
          "changed" => [],
          "errors" => []
        }
      })

    test_self = self()

    output =
      capture_io(fn ->
        send(test_self, {:exit_status, SkillsCommand.run(["reload", "--json"])})
      end)

    assert_receive {:exit_status, 0}
    Task.await(task, 1_000)

    decoded = Jason.decode!(output)
    assert decoded["added"] == ["alpha"]
    assert decoded["count"] == 1
  end

  test "skills command reports daemon unavailable with exit 3" do
    test_self = self()

    stderr =
      capture_io(:stderr, fn ->
        send(test_self, {:exit_status, SkillsCommand.run(["list", "--json"])})
      end)

    assert_receive {:exit_status, 3}
    assert stderr =~ "fermix: not running"
  end

  defp serve_once(socket_path, response) do
    serve(socket_path, fn _request -> response end)
  end

  # A v1 response must echo the request's own id, so the reply is built from the
  # frame the client actually sent rather than from a canned literal.
  defp serve_v1_once(socket_path, result) do
    serve(socket_path, fn request ->
      %{"request_id" => request["request_id"], "result" => result}
    end)
  end

  defp serve_v1_error_once(socket_path, error) do
    serve(socket_path, fn request ->
      %{"request_id" => request["request_id"], "error" => error}
    end)
  end

  defp serve(socket_path, respond) do
    parent = self()

    Task.async(fn ->
      File.mkdir_p!(Path.dirname(socket_path))

      {:ok, listen_socket} =
        :gen_tcp.listen(0, [
          :binary,
          {:active, false},
          {:ifaddr, {:local, socket_path}},
          {:packet, 4},
          {:reuseaddr, true}
        ])

      File.chmod!(socket_path, 0o600)
      send(parent, :fake_daemon_ready)
      {:ok, conn} = :gen_tcp.accept(listen_socket, 1_000)
      {:ok, request} = :gen_tcp.recv(conn, 0, 1_000)
      :ok = :gen_tcp.send(conn, Jason.encode!(respond.(Jason.decode!(request))))
      :gen_tcp.close(conn)
      :gen_tcp.close(listen_socket)
      FermixTestSupport.SafeRm.rm(socket_path)
    end)
    |> tap(fn _task -> assert_receive :fake_daemon_ready end)
  end

  defp mkdir! do
    base = "/tmp/fermix-test-sockets"

    path =
      base
      |> Path.join("fermix-fs-#{System.unique_integer([:positive, :monotonic])}")
      |> Path.expand()

    File.mkdir_p!(base)
    File.mkdir!(path)
    FermixTestSupport.SafeRm.mark!(path)
    path
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
