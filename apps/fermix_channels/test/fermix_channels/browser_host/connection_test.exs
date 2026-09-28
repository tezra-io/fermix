defmodule FermixChannels.BrowserHost.ConnectionTest do
  # End to end over a real 0600 Unix socket: the endpoint and a connection,
  # standing in for the Fermix app as the wire's client.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixChannels.BrowserHost.Endpoint
  alias FermixCore.Browser.HostAvailability
  alias FermixCore.BrowserHost.Link
  alias FermixTestSupport.ParentProcess

  setup do
    unique = System.unique_integer([:positive])
    socket_path = Path.join(System.tmp_dir!(), "fermix-browser-host-#{unique}.sock")
    connections = :"browser_host_conn_sup_#{unique}"
    host = start_supervised!({HostAvailability, name: nil}, id: :"browser_host_avail_#{unique}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm(socket_path) end)

    start_supervised!(
      Supervisor.child_spec({DynamicSupervisor, name: connections, strategy: :one_for_one},
        id: connections
      )
    )

    endpoint_opts = [
      name: :"browser_host_conn_endpoint_#{unique}",
      socket_path: socket_path,
      connection_supervisor: connections,
      host_availability: host,
      connection_opts: [host_availability: host]
    ]

    start_supervised!({Endpoint, endpoint_opts})

    %{
      endpoint_opts: endpoint_opts,
      socket_path: socket_path,
      host: host,
      connections: connections
    }
  end

  test "the socket is owner-only", %{socket_path: path} do
    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "the handshake is mandatory and one-shot", %{socket_path: path} do
    early = connect(path)
    send_line(early, %{"type" => "attached", "host_version" => "0.2.0", "profile_id" => "p"})
    assert %{"type" => "error", "reason" => "handshake_required"} = recv(early)
    assert closed?(early)

    {app, response} = connect_handshaken(path)
    assert response == %{"type" => "server_hello", "min_version" => 1, "max_version" => 1}

    send_line(app, %{"type" => "client_hello", "protocol_version" => 1})
    assert %{"type" => "error", "reason" => "unexpected_client_hello"} = recv(app)
    assert closed?(app)
  end

  test "a client outside the window learns which side must update", %{socket_path: path} do
    client = connect(path)
    send_line(client, %{"type" => "client_hello", "protocol_version" => 2})

    assert recv(client) == %{
             "type" => "error",
             "reason" => "unsupported_protocol_version",
             "direction" => "client_too_new",
             "client_version" => 2,
             "min_version" => 1,
             "max_version" => 1
           }

    assert closed?(client)
  end

  test "attach is mandatory before anything else, and one-shot", ctx do
    app = hello(ctx.socket_path)
    send_line(app, %{"type" => "availability", "available" => true})
    assert %{"type" => "error", "reason" => "attach_required"} = recv(app)
    assert closed?(app)

    attached = attach(ctx.socket_path)
    send_line(attached, %{"type" => "attached", "host_version" => "0.2.0", "profile_id" => "p"})
    assert %{"type" => "error", "reason" => "unexpected_attached"} = recv(attached)
    assert closed?(attached)
  end

  test "a second host while one is attached is refused and closed", ctx do
    _first = attach(ctx.socket_path)
    second = connect(ctx.socket_path)
    assert %{"type" => "error", "reason" => "host_already_attached"} = recv(second)
    assert closed?(second)
  end

  test "availability reaches HostAvailability, and host_stopping is final for the connection",
       ctx do
    app = attach(ctx.socket_path)

    send_line(app, %{"type" => "availability", "available" => true})
    assert eventually(fn -> HostAvailability.usable?(HostAvailability.current(ctx.host)) end)

    send_line(app, %{"type" => "host_stopping"})
    assert %{"id" => stop_id, "type" => "host.stop_ack"} = recv(app)
    send_line(app, %{"id" => stop_id, "ok" => true, "result" => %{}})

    # BROWSER-5: a report that lands behind `host_stopping` never reopens it.
    send_line(app, %{"type" => "availability", "available" => true})

    assert eventually(fn ->
             current = HostAvailability.current(ctx.host)
             current.stopping and not HostAvailability.usable?(current)
           end)
  end

  test "a task's release travels behind its own queued request, never overtaking it (BROWSER-1)",
       ctx do
    app = attach(ctx.socket_path)
    connection = connection_pid(ctx.connections)

    payload = %{
      "task_id" => "task-1",
      "url" => "about:blank",
      "observe" => false,
      "download_dir" => "/tmp",
      "task_tab_cap" => 1,
      "tab_cap" => 1
    }

    ref = Link.request(connection, "task-1", "tab.open", payload)
    :ok = Link.release(connection, "task-1")

    assert %{"id" => 1, "type" => "tab.open"} = recv(app)
    assert %{"id" => 2, "type" => "task.release", "task_id" => "task-1"} = recv(app)

    send_line(app, %{
      "id" => 1,
      "ok" => true,
      "result" => %{"tab_id" => "t1", "url" => "about:blank", "title" => ""}
    })

    assert_receive {:browser_host_answer, ^ref, {:ok, %{"tab_id" => "t1"}}}

    send_line(app, %{"id" => 2, "ok" => true, "result" => %{"released" => ["t1"]}})
  end

  test "a second release for the same task writes nothing on the wire (idempotent, BROWSER-2)",
       ctx do
    app = attach(ctx.socket_path)
    connection = connection_pid(ctx.connections)

    ref = Link.request(connection, "task-1", "tab.list", %{"task_id" => "task-1"})
    assert %{"id" => 1} = recv(app)
    send_line(app, %{"id" => 1, "ok" => true, "result" => %{"tabs" => []}})
    assert_receive {:browser_host_answer, ^ref, {:ok, %{"tabs" => []}}}

    :ok = Link.release(connection, "task-1")
    assert %{"id" => 2, "type" => "task.release"} = recv(app)
    send_line(app, %{"id" => 2, "ok" => true, "result" => %{"released" => []}})

    :ok = Link.release(connection, "task-1")
    assert {:error, :timeout} = :gen_tcp.recv(app, 0, 200)
  end

  test "host_stopping releases every task bound here before it answers", ctx do
    app = attach(ctx.socket_path)
    connection = connection_pid(ctx.connections)

    ref1 = Link.request(connection, "task-1", "tab.list", %{"task_id" => "task-1"})
    assert %{"id" => 1} = recv(app)
    send_line(app, %{"id" => 1, "ok" => true, "result" => %{"tabs" => []}})
    assert_receive {:browser_host_answer, ^ref1, _}

    ref2 = Link.request(connection, "task-2", "tab.list", %{"task_id" => "task-2"})
    assert %{"id" => 2} = recv(app)
    send_line(app, %{"id" => 2, "ok" => true, "result" => %{"tabs" => []}})
    assert_receive {:browser_host_answer, ^ref2, _}

    send_line(app, %{"type" => "host_stopping"})
    assert_receive {:browser_host_stopping, ^connection}
    assert_receive {:browser_host_stopping, ^connection}

    task_ids =
      for _ <- 1..2 do
        assert %{"id" => id, "type" => "task.release", "task_id" => task_id} = recv(app)
        send_line(app, %{"id" => id, "ok" => true, "result" => %{"released" => []}})
        task_id
      end

    assert Enum.sort(task_ids) == ["task-1", "task-2"]

    assert %{"id" => stop_id, "type" => "host.stop_ack"} = recv(app)
    send_line(app, %{"id" => stop_id, "ok" => true, "result" => %{}})
  end

  test "task.cancel tells the named task and releases its tabs, leaving other tasks alone", ctx do
    app = attach(ctx.socket_path)
    connection = connection_pid(ctx.connections)

    ref1 = Link.request(connection, "task-1", "tab.list", %{"task_id" => "task-1"})
    assert %{"id" => 1} = recv(app)
    send_line(app, %{"id" => 1, "ok" => true, "result" => %{"tabs" => []}})
    assert_receive {:browser_host_answer, ^ref1, _}

    ref2 = Link.request(connection, "task-2", "tab.list", %{"task_id" => "task-2"})
    assert %{"id" => 2} = recv(app)
    send_line(app, %{"id" => 2, "ok" => true, "result" => %{"tabs" => []}})
    assert_receive {:browser_host_answer, ^ref2, _}

    send_line(app, %{
      "type" => "task.cancel",
      "task_id" => "task-1",
      "reason" => "cancelled by the person"
    })

    assert_receive {:browser_host_cancelled, ^connection, "cancelled by the person"}

    assert %{"id" => 3, "type" => "task.release", "task_id" => "task-1"} = recv(app)
    send_line(app, %{"id" => 3, "ok" => true, "result" => %{"released" => []}})

    # task-2 was never named, so it is still bound: its own release still
    # travels, and only once.
    :ok = Link.release(connection, "task-2")
    assert %{"id" => 4, "type" => "task.release", "task_id" => "task-2"} = recv(app)
    send_line(app, %{"id" => 4, "ok" => true, "result" => %{"released" => []}})
  end

  test "task.cancel for a task this connection never bound to is silently ignored", ctx do
    app = attach(ctx.socket_path)
    connection = connection_pid(ctx.connections)

    send_line(app, %{
      "type" => "task.cancel",
      "task_id" => "task-x",
      "reason" => "cancelled by the person"
    })

    assert {:error, :timeout} = :gen_tcp.recv(app, 0, 200)

    ref = Link.request(connection, "task-1", "tab.list", %{"task_id" => "task-1"})
    assert %{"id" => 1} = recv(app)
    send_line(app, %{"id" => 1, "ok" => true, "result" => %{"tabs" => []}})
    assert_receive {:browser_host_answer, ^ref, _}
  end

  test "an app event about a tab reaches every task bound here", ctx do
    app = attach(ctx.socket_path)
    connection = connection_pid(ctx.connections)

    ref =
      Link.request(connection, "task-1", "tab.open", %{
        "task_id" => "task-1",
        "url" => "about:blank",
        "observe" => false,
        "download_dir" => "/tmp",
        "task_tab_cap" => 1,
        "tab_cap" => 1
      })

    assert %{"id" => 1} = recv(app)

    send_line(app, %{
      "id" => 1,
      "ok" => true,
      "result" => %{"tab_id" => "t1", "url" => "about:blank", "title" => ""}
    })

    assert_receive {:browser_host_answer, ^ref, _}

    send_line(app, %{"type" => "tab.closed", "tab_id" => "t1", "by" => "page"})

    assert_receive {:browser_host_event, ^connection, "tab.closed",
                    %{"tab_id" => "t1", "by" => "page"}}
  end

  test "protocol violations are answered once and close the connection", ctx do
    oversized = hello(ctx.socket_path)
    :ok = :gen_tcp.send(oversized, String.duplicate("x", 4_194_305))
    assert %{"type" => "error", "reason" => "line_too_large"} = recv(oversized)
    assert closed?(oversized)

    unknown = attach(ctx.socket_path)
    send_line(unknown, %{"type" => "ping"})
    assert %{"type" => "error", "reason" => "unknown_event", "event" => "ping"} = recv(unknown)
    assert closed?(unknown)
  end

  describe "who is on the other end" do
    test "a connection the daemon cannot place as independent is refused and closed", ctx do
      restart_endpoint(ctx, daemon_os_pid: ParentProcess.os_pid())

      {_result, log} =
        with_log(fn ->
          client = connect(ctx.socket_path)

          assert %{"type" => "error", "reason" => "untrusted_host", "message" => message} =
                   recv(client)

          assert message =~ "the browser host must be a process the daemon did not start"
          assert closed?(client)
        end)

      assert log =~ "browser host connection refusing a host the daemon did not trust"
    end

    test "a client that hung up before it was placed is not refused" do
      path =
        Path.join(
          System.tmp_dir!(),
          "fermix-browser-host-#{System.unique_integer([:positive])}.sock"
        )

      on_exit(fn -> FermixTestSupport.SafeRm.rm(path) end)
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, path}])
      {:ok, client} = :gen_tcp.connect({:local, to_charlist(path)}, 0, [:binary, active: false])
      {:ok, accepted} = :gen_tcp.accept(listener, 1_000)
      :ok = :gen_tcp.close(client)

      {_result, log} =
        with_log(fn ->
          {:ok, connection} =
            GenServer.start(FermixChannels.BrowserHost.Connection,
              socket: accepted,
              connection_id: 1
            )

          ref = Process.monitor(connection)
          :ok = :gen_tcp.controlling_process(accepted, connection)
          send(connection, :socket_handover)

          assert_receive {:DOWN, ^ref, :process, ^connection, :normal}, 5_000
        end)

      :gen_tcp.close(listener)
      refute log =~ "refusing"
    end
  end

  defp restart_endpoint(ctx, connection_opts) do
    stop_supervised!(Endpoint)

    ctx.endpoint_opts
    |> Keyword.update!(:connection_opts, &Keyword.merge(&1, connection_opts))
    |> then(&start_supervised!({Endpoint, &1}))
  end

  defp connection_pid(connections) do
    [{_id, pid, _type, _modules}] = DynamicSupervisor.which_children(connections)
    pid
  end

  defp hello(path) do
    {client, response} = connect_handshaken(path)
    assert %{"type" => "server_hello"} = response
    client
  end

  # Only one host connects at a time, and the endpoint frees the slot only
  # after it takes the exiting connection's `:DOWN` — a step after the socket
  # itself closes, from the caller's point of view. So connecting right behind
  # a connection this test just closed retries the transient refusal instead
  # of racing that teardown.
  defp connect_handshaken(path, attempts \\ 40) do
    client = connect(path)
    send_line(client, %{"type" => "client_hello", "protocol_version" => 1})

    case recv(client) do
      %{"type" => "error", "reason" => "host_already_attached"} when attempts > 0 ->
        Process.sleep(10)
        connect_handshaken(path, attempts - 1)

      response ->
        {client, response}
    end
  end

  defp attach(path) do
    client = hello(path)
    send_line(client, %{"type" => "attached", "host_version" => "0.2.0", "profile_id" => "p"})
    client
  end

  defp connect(path) do
    {:ok, socket} =
      :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [
        :binary,
        active: false,
        packet: :line
      ])

    socket
  end

  defp send_line(socket, map), do: :ok = :gen_tcp.send(socket, Jason.encode!(map) <> "\n")

  defp recv(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 2_000)
    Jason.decode!(line)
  end

  defp closed?(socket), do: :gen_tcp.recv(socket, 0, 2_000) == {:error, :closed}

  defp eventually(predicate, attempts \\ 40) do
    cond do
      predicate.() -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && eventually(predicate, attempts - 1)
    end
  end
end
