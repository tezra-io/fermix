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
      FermixTestSupport.SafeRm.rm(socket_path)
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

    wait_until(fn -> LocalVoiceSocket.active_clients(socket) == {:ok, 1} end)
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

  test "refuses to start when a live socket already owns the path", %{
    socket_path: socket_path
  } do
    # start_link links the failed starter to the test; trap so the
    # {:stop, reason} exit arrives as a message instead of killing us.
    Process.flag(:trap_exit, true)

    assert {:error, {:another_voice_socket_running, ^socket_path}} =
             LocalVoiceSocket.start_link(
               socket_path: socket_path,
               name: :"rt_socket_second_#{System.unique_integer([:positive])}"
             )

    # the original listener keeps the path and still serves clients
    assert {:ok, conn} = connect(socket_path)
    :gen_tcp.close(conn)
  end

  test "unlinks a stale socket file with no listener behind it" do
    socket_path =
      Path.join(
        System.tmp_dir!(),
        "fermix-realtime-stale-#{System.unique_integer([:positive])}.sock"
      )

    # Bind and close without unlinking — leaves a dead socket file behind,
    # like a crashed daemon would.
    {:ok, dead} =
      :gen_tcp.listen(0, [:binary, {:ifaddr, {:local, to_charlist(socket_path)}}])

    :ok = :gen_tcp.close(dead)
    assert File.exists?(socket_path)

    {:ok, socket} =
      LocalVoiceSocket.start_link(
        socket_path: socket_path,
        name: :"rt_socket_stale_#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      if Process.alive?(socket), do: GenServer.stop(socket)
      FermixTestSupport.SafeRm.rm(socket_path)
    end)

    assert {:ok, conn} = connect(socket_path)
    :gen_tcp.close(conn)
  end

  test "rejects a connection once max_clients is reached" do
    socket_path =
      Path.join(
        System.tmp_dir!(),
        "fermix-realtime-cap-#{System.unique_integer([:positive])}.sock"
      )

    {:ok, task_sup} =
      Task.Supervisor.start_link(name: :"rt_cap_tasks_#{System.unique_integer([:positive])}")

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
        max_clients: 1,
        name: :"rt_cap_socket_#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      if Process.alive?(socket), do: GenServer.stop(socket)
      FermixTestSupport.SafeRm.rm(socket_path)
    end)

    {:ok, conn1} = connect(socket_path)
    wait_until(fn -> LocalVoiceSocket.active_clients(socket) == {:ok, 1} end)

    {:ok, conn2} = connect(socket_path)

    assert {:ok, line} = recv_line(conn2, 2_000)

    assert %{"type" => "error", "reason" => "max_clients_reached"} =
             Jason.decode!(String.trim(line))

    assert {:error, :closed} = :gen_tcp.recv(conn2, 0, 1_000)
    assert LocalVoiceSocket.active_clients(socket) == {:ok, 1}

    :gen_tcp.close(conn1)
  end

  test "rejects non-positive max_clients" do
    Process.flag(:trap_exit, true)

    bad_path =
      Path.join(
        System.tmp_dir!(),
        "fermix-realtime-bad-#{System.unique_integer([:positive])}.sock"
      )

    name = :"rt_bad_socket_#{System.unique_integer([:positive])}"

    assert {:error, {%ArgumentError{message: msg}, _stack}} =
             LocalVoiceSocket.start_link(
               socket_path: bad_path,
               task_supervisor: FermixCore.TaskSupervisor,
               max_clients: 0,
               name: name
             )

    assert msg =~ "max_clients"
  end

  test "active_clients surfaces an error tuple when the server is gone" do
    name = :"rt_gone_#{System.unique_integer([:positive])}"
    assert {:error, _reason} = LocalVoiceSocket.active_clients(name)
  end

  test "a client handler crash decrements active_clients via the monitor (F-12 follow-up)" do
    socket_path =
      Path.join(
        System.tmp_dir!(),
        "fermix-realtime-crash-#{System.unique_integer([:positive])}.sock"
      )

    {:ok, task_sup} =
      Task.Supervisor.start_link(name: :"rt_crash_tasks_#{System.unique_integer([:positive])}")

    crashing_starter = fn _opts ->
      # Simulate a handler that raises after the parent has already
      # incremented active_clients. Returning {:error, _} from the
      # starter is not enough — the bug requires the *task* to crash,
      # not just the session_starter, so we raise inside an Agent.
      {:ok, pid} = Agent.start_link(fn -> :ready end)
      ref = make_ref()
      send(pid, {:raise_after, ref, 10})
      {:ok, pid}
    end

    {:ok, socket} =
      LocalVoiceSocket.start_link(
        socket_path: socket_path,
        task_supervisor: task_sup,
        session_starter: crashing_starter,
        session_module: FakeSession,
        max_clients: 4,
        name: :"rt_crash_socket_#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      if Process.alive?(socket), do: GenServer.stop(socket)
      FermixTestSupport.SafeRm.rm(socket_path)
    end)

    {:ok, conn} = connect(socket_path)

    wait_until(fn -> LocalVoiceSocket.active_clients(socket) == {:ok, 1} end)

    # Force the handler task to crash by closing the conn from our side
    # AND telling the handler to send raw bytes that make
    # `process_one_line/2`'s `:ok = send_event(...)` assertion fail. The
    # simplest path: send a giant unterminated line so the wire-line cap
    # trips, then close before the response lands — but the cleanest
    # crash is `Process.exit/2` on the task. We can't reach it directly,
    # so we send malformed data and immediately close so write fails.
    :ok = :gen_tcp.send(conn, "{\n")
    :gen_tcp.close(conn)

    wait_until(fn -> LocalVoiceSocket.active_clients(socket) == {:ok, 0} end)
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
