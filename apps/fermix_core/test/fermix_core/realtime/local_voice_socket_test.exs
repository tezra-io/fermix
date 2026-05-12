defmodule FermixCore.Realtime.LocalVoiceSocketTest do
  use ExUnit.Case, async: false

  alias FermixCore.Realtime.LocalVoiceSocket

  defmodule FakeSession do
    def call_start(pid), do: Agent.update(pid, &Map.put(&1, :call_started?, true))
    def audio_chunk(pid, audio), do: Agent.update(pid, &Map.put(&1, :audio, audio))

    def interrupt(pid, audio_end_ms),
      do: Agent.update(pid, &Map.merge(&1, %{interrupted?: true, audio_end_ms: audio_end_ms}))

    def mute(pid, enabled?), do: Agent.update(pid, &Map.put(&1, :muted?, enabled?))
    def call_stop(pid), do: Agent.update(pid, &Map.put(&1, :stopped?, true))
  end

  setup do
    socket_path =
      Path.join(System.tmp_dir!(), "fermix-realtime-#{System.unique_integer([:positive])}.sock")

    {:ok, task_sup} =
      Task.Supervisor.start_link(name: :"rt_socket_tasks_#{System.unique_integer([:positive])}")

    test_pid = self()

    session_starter = fn opts ->
      {:ok, pid} = Agent.start_link(fn -> %{opts: opts} end)
      send(test_pid, {:session_started, pid, opts})
      {:ok, pid}
    end

    {:ok, socket} =
      LocalVoiceSocket.start_link(
        socket_path: socket_path,
        task_supervisor: task_sup,
        session_starter: session_starter,
        session_module: FakeSession,
        name: :"rt_socket_#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      if Process.alive?(socket), do: GenServer.stop(socket)
      File.rm(socket_path)
    end)

    %{socket: socket, socket_path: socket_path}
  end

  test "binds the Unix socket with 0600 permissions", %{socket_path: socket_path} do
    stat = File.stat!(socket_path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600
  end

  test "client_hello returns idle state and tracks active clients", %{
    socket: socket,
    socket_path: socket_path
  } do
    {:ok, conn} = connect(socket_path)

    wait_until(fn -> LocalVoiceSocket.active_clients(socket) == 1 end)
    :ok = :gen_tcp.send(conn, ~s({"type":"client_hello"}\n))

    assert {:ok, line} = recv_line(conn)
    assert Jason.decode!(String.trim(line)) == %{"type" => "state", "state" => "idle"}

    :gen_tcp.close(conn)
  end

  test "malformed event returns error and closes that client", %{socket_path: socket_path} do
    {:ok, conn} = connect(socket_path)
    :ok = :gen_tcp.send(conn, "{\n")

    assert {:ok, line} = recv_line(conn)
    assert %{"type" => "error", "reason" => "invalid_json"} = Jason.decode!(String.trim(line))
    assert {:error, :closed} = :gen_tcp.recv(conn, 0, 1_000)
  end

  test "call and audio events dispatch to a session", %{socket_path: socket_path} do
    {:ok, conn} = connect(socket_path)
    :ok = :gen_tcp.send(conn, ~s({"type":"call_start"}\n))

    assert_receive {:session_started, session, _opts}, 1_000
    assert {:ok, line} = recv_line(conn)
    assert %{"type" => "state", "state" => "listening"} = Jason.decode!(String.trim(line))

    audio = Base.encode64("1234")
    :ok = :gen_tcp.send(conn, ~s({"type":"audio_chunk","audio":"#{audio}"}\n))
    wait_until(fn -> Agent.get(session, &Map.get(&1, :audio)) == "1234" end)

    :ok = :gen_tcp.send(conn, ~s({"type":"interrupt"}\n))
    wait_until(fn -> Agent.get(session, &Map.get(&1, :interrupted?)) == true end)
    assert Agent.get(session, &Map.get(&1, :audio_end_ms)) == nil

    :gen_tcp.close(conn)
  end

  test "interrupt with audio_end_ms forwards the value to the session module", %{
    socket_path: socket_path
  } do
    {:ok, conn} = connect(socket_path)
    :ok = :gen_tcp.send(conn, ~s({"type":"call_start"}\n))

    assert_receive {:session_started, session, _opts}, 1_000
    assert {:ok, _line} = recv_line(conn)

    :ok = :gen_tcp.send(conn, ~s({"type":"interrupt","audio_end_ms":1750}\n))
    wait_until(fn -> Agent.get(session, &Map.get(&1, :interrupted?)) == true end)
    assert Agent.get(session, &Map.get(&1, :audio_end_ms)) == 1_750

    :gen_tcp.close(conn)
  end

  test "interrupt with non-integer audio_end_ms returns an error and closes", %{
    socket_path: socket_path
  } do
    {:ok, conn} = connect(socket_path)
    :ok = :gen_tcp.send(conn, ~s({"type":"interrupt","audio_end_ms":"oops"}\n))

    assert {:ok, line} = recv_line(conn)

    assert %{"type" => "error", "reason" => "invalid_audio_end_ms"} =
             Jason.decode!(String.trim(line))

    assert {:error, :closed} = :gen_tcp.recv(conn, 0, 1_000)
  end

  test "accepts a pet-sized audio chunk over the socket", %{socket_path: socket_path} do
    {:ok, conn} = connect(socket_path)
    :ok = :gen_tcp.send(conn, ~s({"type":"call_start"}\n))

    assert_receive {:session_started, session, _opts}, 1_000
    assert {:ok, _line} = recv_line(conn)

    audio = :binary.copy(<<1>>, 12_000)
    encoded = Base.encode64(audio)

    :ok = :gen_tcp.send(conn, ~s({"type":"audio_chunk","audio":"#{encoded}"}\n))

    case :gen_tcp.recv(conn, 0, 100) do
      {:ok, line} -> flunk("unexpected server response: #{inspect(line)}")
      {:error, :timeout} -> :ok
      {:error, reason} -> flunk("socket closed while sending pet-sized chunk: #{inspect(reason)}")
    end

    wait_until(fn -> Agent.get(session, &Map.get(&1, :audio)) == audio end)

    :gen_tcp.close(conn)
  end

  test "audio chunks require an active call", %{socket_path: socket_path} do
    {:ok, conn} = connect(socket_path)

    audio = Base.encode64("before-start")
    :ok = :gen_tcp.send(conn, ~s({"type":"audio_chunk","audio":"#{audio}"}\n))

    assert {:ok, line} = recv_line(conn)
    assert %{"type" => "error", "reason" => "not_connected"} = Jason.decode!(String.trim(line))
    assert {:error, :closed} = :gen_tcp.recv(conn, 0, 1_000)
  end

  test "call_stop closes the active session", %{
    socket_path: socket_path
  } do
    {:ok, conn} = connect(socket_path)
    :ok = :gen_tcp.send(conn, ~s({"type":"call_start"}\n))

    assert_receive {:session_started, session, _opts}, 1_000
    assert {:ok, _line} = recv_line(conn)

    :ok = :gen_tcp.send(conn, ~s({"type":"call_stop"}\n))
    wait_until(fn -> Agent.get(session, &Map.get(&1, :stopped?)) == true end)
    assert {:ok, line} = recv_line(conn)
    assert %{"type" => "state", "state" => "idle"} = Jason.decode!(String.trim(line))

    :gen_tcp.close(conn)
  end

  test "client disconnect closes the active realtime session", %{socket_path: socket_path} do
    {:ok, conn} = connect(socket_path)
    :ok = :gen_tcp.send(conn, ~s({"type":"call_start"}\n))

    assert_receive {:session_started, session, _opts}, 1_000
    assert {:ok, _line} = recv_line(conn)

    :gen_tcp.close(conn)
    wait_until(fn -> Agent.get(session, &Map.get(&1, :stopped?)) == true end)
  end

  defp connect(socket_path) do
    :gen_tcp.connect(
      {:local, String.to_charlist(socket_path)},
      0,
      [:binary, {:active, false}],
      1_000
    )
  end

  defp recv_line(conn, timeout \\ 1_000, acc \\ "") do
    case :binary.match(acc, "\n") do
      {newline, 1} ->
        <<line::binary-size(newline), _newline::binary-size(1), _rest::binary>> = acc
        {:ok, line}

      :nomatch ->
        case :gen_tcp.recv(conn, 0, timeout) do
          {:ok, bytes} -> recv_line(conn, timeout, acc <> bytes)
          {:error, reason} -> {:error, reason}
        end
    end
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
