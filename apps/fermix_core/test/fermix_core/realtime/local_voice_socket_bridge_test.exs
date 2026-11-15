defmodule FermixCore.Realtime.LocalVoiceSocketBridgeTest do
  @moduledoc """
  The app's `realtime.sock` in its bridged configuration (M97 §9.2): on a
  computer whose home moved, the same socket at the same path, its handshake
  its own, and every call after it carried by a `SocketBridge` with no
  session started here; and after a move back, the same path served by the
  primary's own sessions again, with nothing of the bridge left.
  """

  # The socket snapshots the realtime config per connection.
  use ExUnit.Case, async: false

  alias FermixCore.Realtime.LocalVoiceSocket
  alias FermixCore.Realtime.SessionGuard
  alias FermixTestSupport.SafeRm

  # A bridge that tells the test everything it is handed and answers what the
  # test told it to in its opts.
  defmodule TestBridge do
    @behaviour FermixCore.Realtime.SocketBridge

    @impl true
    def open(opts) do
      test = Keyword.fetch!(opts, :test)
      send(test, {:bridge_opened, self(), Keyword.take(opts, [:protocol_version])})
      %{test: test, write: Keyword.fetch!(opts, :write), emit: Keyword.fetch!(opts, :emit)}
    end

    @impl true
    def event(bridge, event) do
      send(bridge.test, {:bridge_event, event})
      {:cont, bridge}
    end

    @impl true
    def info(bridge, {:write, json}) do
      :ok = bridge.write.(json)
      {:cont, bridge}
    end

    def info(bridge, {:refuse, frame}) do
      _ = bridge.emit.(frame)
      {:stop, bridge}
    end

    @impl true
    def close(bridge) do
      send(bridge.test, :bridge_closed)
      :ok
    end
  end

  setup do
    previous = Application.get_env(:fermix_core, :realtime, [])
    Application.put_env(:fermix_core, :realtime, engine: "openai_realtime")
    on_exit(fn -> Application.put_env(:fermix_core, :realtime, previous) end)

    # Short, so the socket's address fits.
    path = Path.join(System.tmp_dir!(), "fx-rb-#{System.unique_integer([:positive])}.sock")
    on_exit(fn -> SafeRm.rm(path) end)
    tasks = start_supervised!({Task.Supervisor, name: nil}, id: :tasks)
    %{path: path, tasks: tasks}
  end

  test "a bridged socket answers the handshake and hands every call event to its bridge", ctx do
    start_bridged!(ctx)
    conn = connect!(ctx.path)

    send_line(conn, %{type: "client_hello", protocol_version: 3})
    assert %{"type" => "server_hello", "min_version" => 1, "max_version" => 5} = recv!(conn)
    assert_receive {:bridge_opened, handler, protocol_version: 3}

    send_line(conn, %{type: "call_start"})
    assert_receive {:bridge_event, %{type: "call_start"}}

    pcm = :binary.copy(<<1, 0>>, 2_400)
    send_line(conn, %{type: "audio_chunk", audio: Base.encode64(pcm)})
    assert_receive {:bridge_event, %{type: "audio_chunk", payload: %{"audio" => ^pcm}}}

    # The bridge's own mail reaches it in the connection's handler, and what
    # it writes reaches the app as the line it is.
    send(handler, {:write, ~s({"type":"state","state":"listening"})})
    assert recv!(conn) == %{"type" => "state", "state" => "listening"}

    # A repeated hello is still the socket's refusal, as on a primary.
    send_line(conn, %{type: "client_hello", protocol_version: 3})
    assert %{"type" => "error", "reason" => "unexpected_client_hello"} = recv!(conn)
    assert_receive :bridge_closed
    assert {:error, :closed} = :gen_tcp.recv(conn, 0, 1_000)
    refute_received {:session_started, _session}
  end

  test "a bridge that stops closes the connection after its frame, and is told it ended",
       ctx do
    start_bridged!(ctx)
    conn = connect!(ctx.path)
    send_line(conn, %{type: "client_hello", protocol_version: 3})
    assert %{"type" => "server_hello"} = recv!(conn)
    assert_receive {:bridge_opened, handler, _version}

    send(handler, {:refuse, %{type: "error", reason: "server_unreachable", sentence: "Gone."}})

    assert recv!(conn) == %{
             "type" => "error",
             "reason" => "server_unreachable",
             "sentence" => "Gone."
           }

    assert_receive :bridge_closed
    assert {:error, :closed} = :gen_tcp.recv(conn, 0, 1_000)
  end

  test "the app closing its connection tells the bridge", ctx do
    start_bridged!(ctx)
    conn = connect!(ctx.path)
    send_line(conn, %{type: "client_hello", protocol_version: 3})
    assert %{"type" => "server_hello"} = recv!(conn)
    assert_receive {:bridge_opened, _handler, _version}

    :ok = :gen_tcp.close(conn)
    assert_receive :bridge_closed
  end

  # The move back: the device tree stops, the computer starts as the primary,
  # and its realtime tree serves the same path with sessions. Whether the
  # bridge's listener stopped (its file gone) or was killed (its file left),
  # the primary's socket takes the path, and its calls are its sessions'.
  test "after a move back the same path is served by the primary's sessions", ctx do
    for ending <- [:stopped, :killed] do
      socket = start_bridged!(ctx)
      conn = connect!(ctx.path)
      send_line(conn, %{type: "client_hello", protocol_version: 3})
      assert %{"type" => "server_hello"} = recv!(conn)
      assert_receive {:bridge_opened, _handler, _version}

      :ok = end_socket(socket, ending)
      assert File.exists?(ctx.path) == (ending == :killed)

      primary = start_primary!(ctx)
      conn = connect!(ctx.path)
      send_line(conn, %{type: "client_hello", protocol_version: 3})
      assert %{"type" => "server_hello"} = recv!(conn)
      send_line(conn, %{type: "call_start"})

      assert_receive {:session_started, session, opts}
      assert Keyword.fetch!(opts, :endpoint) == :desktop
      assert recv!(conn) == %{"type" => "state", "state" => "listening"}
      refute_received {:bridge_opened, _handler, _version}
      refute_received {:bridge_event, _event}

      :ok = :gen_tcp.close(conn)
      Agent.stop(session)
      :ok = end_socket(primary, :stopped)
    end
  end

  # -- the sockets --------------------------------------------------------------------

  defp start_bridged!(ctx) do
    {:ok, socket} =
      LocalVoiceSocket.start_link(
        socket_path: ctx.path,
        task_supervisor: ctx.tasks,
        bridge: {TestBridge, test: self()},
        session_starter: fn _opts -> flunk("a bridged socket started a session") end,
        name: nil
      )

    Process.unlink(socket)
    socket
  end

  # The primary's own: a session double that says listening at call_start.
  defp start_primary!(ctx) do
    test = self()
    guard = :"rt_bridge_guard_#{System.unique_integer([:positive])}"
    start_supervised!({SessionGuard, name: guard, task_supervisor: ctx.tasks}, id: guard)

    {:ok, socket} =
      LocalVoiceSocket.start_link(
        socket_path: ctx.path,
        task_supervisor: ctx.tasks,
        session_guard: guard,
        session_module: __MODULE__.Listening,
        session_starter: fn opts ->
          {:ok, pid} = Agent.start(fn -> opts end)
          send(test, {:session_started, pid, opts})
          {:ok, pid}
        end,
        name: nil
      )

    Process.unlink(socket)
    socket
  end

  defmodule Listening do
    @moduledoc false
    def call_start(pid) do
      companion = Agent.get(pid, &Keyword.fetch!(&1, :companion))
      send(companion, {:realtime, %{type: "state", state: "listening"}})
      :ok
    end

    def call_stop(_pid), do: :ok
  end

  defp end_socket(socket, :stopped) do
    ref = Process.monitor(socket)
    GenServer.stop(socket)
    assert_receive {:DOWN, ^ref, :process, ^socket, _reason}
    :ok
  end

  defp end_socket(socket, :killed) do
    ref = Process.monitor(socket)
    Process.exit(socket, :kill)
    assert_receive {:DOWN, ^ref, :process, ^socket, :killed}
    :ok
  end

  # -- the app ---------------------------------------------------------------------------

  defp connect!(path) do
    {:ok, conn} =
      :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [
        :binary,
        {:active, false},
        {:packet, :line}
      ])

    conn
  end

  defp send_line(conn, frame), do: :ok = :gen_tcp.send(conn, [Jason.encode!(frame), "\n"])

  defp recv!(conn) do
    assert {:ok, line} = :gen_tcp.recv(conn, 0, 2_000)
    Jason.decode!(line)
  end
end
