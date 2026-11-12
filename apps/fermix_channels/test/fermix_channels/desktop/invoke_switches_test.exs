defmodule FermixChannels.Desktop.InvokeSwitchesTest do
  # M97 §7.2: what Fermix on the server may use on this computer widens only
  # at this computer, by its owner. The server's work runs here as processes
  # this engine started, and `daemon.sock` refuses the `computer` section to
  # every one of them: a run of an invocation that asks to switch an offer on
  # is refused, and nothing is written. The daemon is told this test VM's
  # parent is its own OS process, so every client in the VM, the run's
  # among them, is a process the daemon started (`FermixTestSupport.ParentProcess`).
  use ExUnit.Case, async: true

  alias Fermix.CLI.Daemon
  alias Fermix.CLI.Daemon.Client
  alias FermixChannels.Desktop.Invoke
  alias FermixChannels.Test.DesktopRail
  alias FermixCore.Computers.Switches
  alias FermixCore.Sandbox.Config
  alias FermixTestSupport.ParentProcess

  @reply_ms 10_000

  # A run that asks this computer's daemon to switch files and commands on
  # for the server, and answers what the daemon said.
  defmodule Widen do
    @moduledoc false
    @behaviour FermixCore.Computers.Capability

    @impl true
    def id, do: :widen
    @impl true
    def offer, do: nil
    @impl true
    def ops, do: ["widen"]
    @impl true
    def effect?(_op), do: true
    @impl true
    def long_lived?(_op), do: false
    @impl true
    def validate(_op, _args), do: :ok
    @impl true
    def bounds(_op), do: %{result_bytes: 4_096, part_bytes: 0}
    @impl true
    def admit(_op, _args, _context), do: :ok

    @impl true
    def run("widen", _args, nil, context) do
      socket = :persistent_term.get({__MODULE__, context.home})
      params = %{"section" => "computer", "values" => %{"computer_files_and_shell" => true}}

      case Client.request_v1("settings.apply", params, socket_path: socket, timeout: 10_000) do
        {:error, {:management_error, code, _message, details}} ->
          {:ok, %{"refused" => code, "details" => details}, nil}

        other ->
          {:ok, %{"answered" => inspect(other)}, nil}
      end
    end

    @impl true
    def target("widen", _args), do: "switch files and commands on"
  end

  setup do
    root = DesktopRail.root!("fx-sw")
    File.mkdir_p!(root)
    socket = Path.join(root, "d.sock")
    test = self()
    tasks = start_supervised!({Task.Supervisor, []}, id: :daemon_tasks)

    start_supervised!(
      {Daemon,
       name: :"invoke_switches_daemon_#{System.unique_integer([:positive])}",
       socket_path: socket,
       task_supervisor: tasks,
       forwarding: [],
       daemon_os_pid: ParentProcess.os_pid(),
       management_opts: [
         settings_writer: fn section, _values, _opts ->
           send(test, {:written, section})
           {:ok, %{"section" => section}}
         end,
         identity_provider: fn -> {:ok, identity()} end,
         endpoint_opts: [port: 4041]
       ]}
    )

    :persistent_term.put({Widen, root}, socket)
    on_exit(fn -> :persistent_term.erase({Widen, root}) end)
    name = :"invoke_switches_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Invoke,
       name: name,
       home: root,
       switches: fn -> Switches.only([:browser]) end,
       sandbox: fn -> Config.normalize(mode: :strict, home: root, os_home: root) end,
       capabilities: %{"widen" => Widen},
       clock: &DateTime.utc_now/0,
       relay: :no_relay,
       send: fn _relay, event, payload ->
         send(test, {:sent, event, payload})
         :ok
       end,
       link_epoch: fn -> {:ok, 3} end}
    )

    %{admission: Invoke.admission(name)}
  end

  test "a run of the server's work cannot switch on what it may use here", ctx do
    header = %{
      "id" => "inv-widen",
      "capability" => "widen",
      "op" => "widen",
      "deadline_ms" => 30_000,
      "epoch" => 3,
      "origin" => "chat",
      "turn" => %{"session_id" => "main-4", "tool_call_id" => "call-9"}
    }

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Invoke.handle(ctx.admission, "invoke_open", header, "{}")

        assert_receive {:sent, %{"t" => "invoke_result", "id" => "inv-widen"}, payload},
                       @reply_ms

        assert %{"refused" => "unavailable"} = Jason.decode!(payload)
      end)

    assert log =~ "only the owner may"
    refute_received {:written, _section}
  end

  defp identity do
    %{
      "engine_id" => "fermix-engine-test",
      "product_version" => "1.2.3",
      "build_id" => nil,
      "source_commit" => nil,
      "distribution_identity" => "standalone",
      "artifact_target" => nil,
      "architecture" => "arm64",
      "pid" => "4321"
    }
  end
end
