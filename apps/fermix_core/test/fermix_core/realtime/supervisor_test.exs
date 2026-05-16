defmodule FermixCore.Realtime.SupervisorTest do
  use ExUnit.Case, async: false

  alias FermixCore.Realtime
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.LocalVoiceSocket
  alias FermixCore.Realtime.SessionSupervisor

  test "starts session supervisor and local voice socket" do
    socket_path =
      Path.join(
        System.tmp_dir!(),
        "fermix-realtime-supervisor-#{System.unique_integer([:positive])}.sock"
      )

    name = :"rt_supervisor_#{System.unique_integer([:positive])}"
    socket_name = :"rt_socket_#{System.unique_integer([:positive])}"
    session_name = :"rt_sessions_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Realtime.Supervisor.start_link(
        name: name,
        socket_path: socket_path,
        socket_name: socket_name,
        session_supervisor_name: session_name
      )

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :shutdown)
      File.rm(socket_path)
    end)

    assert Process.whereis(socket_name)
    assert Process.whereis(session_name)
    assert LocalVoiceSocket.active_clients(socket_name) == 0
    assert SessionSupervisor.active_sessions(session_name) == 0
  end

  test "session children are not restarted after normal shutdown" do
    session_name = :"rt_sessions_#{System.unique_integer([:positive])}"

    {:ok, supervisor} = SessionSupervisor.start_link(name: session_name)

    on_exit(fn ->
      if Process.alive?(supervisor), do: Process.exit(supervisor, :shutdown)
    end)

    {:ok, session} =
      SessionSupervisor.start_session(session_name,
        companion: self(),
        config: Config.normalize(enabled: true),
        capabilities: [],
        prompt_loader: fn _opts -> {:ok, %{messages: [], parts: [], accounting: []}} end
      )

    assert SessionSupervisor.active_sessions(session_name) == 1

    GenServer.stop(session, :normal, 1_000)

    wait_until(fn -> SessionSupervisor.active_sessions(session_name) == 0 end)
  end

  defp wait_until(fun, attempts \\ 20)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition did not become true")
end
