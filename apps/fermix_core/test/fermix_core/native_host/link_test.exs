defmodule FermixCore.NativeHost.LinkTest do
  # End to end over a real 0600 Unix socket in the test's temp directory: the
  # native host subtree (its record, the link supervisor and the server), with
  # this test standing in for the Fermix app as the wire's client.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Native.HostAvailability
  alias FermixCore.NativeHost.Link
  alias FermixCore.NativeHost.Supervisor, as: NativeHostSupervisor
  alias FermixTestSupport.ParentProcess

  @post %{
    "reminder_id" => "rem_1",
    "title" => "Tea",
    "body" => "Tea, today at 16:05.",
    "sound" => true,
    "actions" => [%{"id" => "snooze_10m", "title" => "Snooze 10 minutes"}]
  }

  setup do
    unique = System.unique_integer([:positive])
    socket_path = Path.join(System.tmp_dir!(), "fermix-native-host-#{unique}.sock")
    on_exit(fn -> FermixTestSupport.SafeRm.rm(socket_path) end)

    opts = [
      name: :"native_host_sup_#{unique}",
      server_name: :"native_host_server_#{unique}",
      host_availability: :"native_host_avail_#{unique}",
      connection_supervisor: :"native_host_links_#{unique}",
      socket_path: socket_path
    ]

    start_supervised!({NativeHostSupervisor, opts}, id: opts[:name])
    %{opts: opts, socket_path: socket_path, host: opts[:host_availability]}
  end

  test "the socket is owner-only, and the record says it is served", ctx do
    assert {:ok, %File.Stat{mode: mode}} = File.stat(ctx.socket_path)
    assert Bitwise.band(mode, 0o777) == 0o600
    assert HostAvailability.current(ctx.host).listening
  end

  test "the handshake is mandatory and one-shot", %{socket_path: path} do
    early = connect(path)
    send_line(early, %{"type" => "attached", "host_version" => "0.6.0"})
    assert %{"type" => "error", "reason" => "handshake_required"} = recv(early)
    assert closed?(early)

    {app, response} = connect_handshaken(path)
    assert response == %{"type" => "server_hello", "min_version" => 1, "max_version" => 1}

    send_line(app, %{"type" => "client_hello", "protocol_version" => 1})
    assert %{"type" => "error", "reason" => "unexpected_client_hello"} = recv(app)
    assert closed?(app)
  end

  test "an app outside the window learns which side must update", %{socket_path: path} do
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
    send_line(app, %{"type" => "capabilities", "notifications" => "granted"})
    assert %{"type" => "error", "reason" => "attach_required"} = recv(app)
    assert closed?(app)

    attached = attach(ctx.socket_path)
    send_line(attached, %{"type" => "attached", "host_version" => "0.6.0"})
    assert %{"type" => "error", "reason" => "unexpected_attached"} = recv(attached)
    assert closed?(attached)
  end

  test "a second app while one is attached is refused and closed", ctx do
    _first = attach(ctx.socket_path)
    second = connect(ctx.socket_path)
    assert %{"type" => "error", "reason" => "host_already_attached"} = recv(second)
    assert closed?(second)
  end

  test "the attach and every grant report reach the record", ctx do
    app = attach(ctx.socket_path)
    attached = await_current(ctx.host, & &1.attached)
    assert %{host_version: "0.6.0", connection_id: 1, notifications: nil} = attached

    send_line(app, %{"type" => "capabilities", "notifications" => "not_asked"})
    assert await_current(ctx.host, &(&1.notifications == "not_asked"))

    send_line(app, %{"type" => "capabilities", "notifications" => "granted"})
    assert await_current(ctx.host, &(&1.notifications == "granted"))
  end

  test "a request goes out with the next id, and its answer, matched by id, is the caller's",
       ctx do
    app = attach(ctx.socket_path)
    link = attached_link(ctx.host)

    status = Task.async(fn -> Link.request(link, "host.status", %{}, 10_000) end)
    assert %{"id" => 1, "type" => "host.status"} = recv(app)
    post = Task.async(fn -> Link.request(link, "notifications.post", @post, 10_000) end)
    assert %{"id" => 2, "type" => "notifications.post"} = sent = recv(app)
    assert Map.drop(sent, ["id", "type"]) == @post

    send_line(app, %{"id" => 2, "ok" => true, "result" => %{"notification_id" => "n-1"}})

    send_line(app, %{
      "id" => 1,
      "ok" => true,
      "result" => %{"host_version" => "0.6.0", "notifications" => "granted"}
    })

    assert Task.await(post, 10_000) == {:ok, %{"notification_id" => "n-1"}}

    assert Task.await(status, 10_000) ==
             {:ok, %{"host_version" => "0.6.0", "notifications" => "granted"}}
  end

  test "the app's refusal and an answer off the protocol each reach the caller as an error",
       ctx do
    app = attach(ctx.socket_path)
    link = attached_link(ctx.host)

    refused = Task.async(fn -> Link.request(link, "notifications.post", @post, 10_000) end)
    assert %{"id" => 1} = recv(app)
    error = %{"reason" => "not_authorized", "message" => "Notifications are turned off"}
    send_line(app, %{"id" => 1, "ok" => false, "error" => error})
    assert Task.await(refused, 10_000) == {:error, error}

    {_result, log} =
      with_log(fn ->
        off = Task.async(fn -> Link.request(link, "notifications.authorize", %{}, 10_000) end)
        assert %{"id" => 2} = recv(app)
        send_line(app, %{"id" => 2, "ok" => true, "result" => %{"state" => "maybe"}})
        assert {:error, %{"reason" => "invalid_result"}} = Task.await(off, 10_000)
      end)

    assert log =~ "native host answered notifications.authorize off the protocol"
  end

  test "a request the codec refuses never reaches the wire", ctx do
    app = attach(ctx.socket_path)
    link = attached_link(ctx.host)

    {answer, _log} =
      with_log(fn -> Link.request(link, "notifications.post", %{"title" => "Tea"}, 10_000) end)

    assert {:error, %{"reason" => "invalid_request"}} = answer
    assert {:ok, _status} = round_trip(app, link)
  end

  test "a caller whose bound runs out is answered timeout, and the late answer is dropped",
       ctx do
    app = attach(ctx.socket_path)
    link = attached_link(ctx.host)

    # The app never answers inside the bound, so the bound alone ends the wait.
    assert Link.request(link, "notifications.authorize", %{}, 50) == {:error, :timeout}
    assert %{"id" => 1, "type" => "notifications.authorize"} = recv(app)
    send_line(app, %{"id" => 1, "ok" => true, "result" => %{"state" => "granted"}})

    assert {:ok, _status} = round_trip(app, link)
  end

  test "host_stopping is final: it is answered host.stop_ack, and later requests are refused",
       ctx do
    app = attach(ctx.socket_path)
    link = attached_link(ctx.host)

    send_line(app, %{"type" => "capabilities", "notifications" => "granted"})
    send_line(app, %{"type" => "host_stopping"})
    assert %{"id" => stop_id, "type" => "host.stop_ack"} = stop_ack = recv(app)
    assert map_size(stop_ack) == 2
    send_line(app, %{"id" => stop_id, "ok" => true, "result" => %{}})

    send_line(app, %{"type" => "capabilities", "notifications" => "not_granted"})
    stopped = await_current(ctx.host, & &1.stopping)
    assert stopped.notifications == "granted"

    assert Link.request(link, "host.status", %{}, 10_000) ==
             {:error, %{"reason" => "host_unavailable", "message" => "the app is quitting"}}
  end

  test "a caller waiting when the app goes away is answered closed", ctx do
    app = attach(ctx.socket_path)
    link = attached_link(ctx.host)

    waiting = Task.async(fn -> Link.request(link, "notifications.post", @post, 10_000) end)
    assert %{"id" => 1} = recv(app)
    :ok = :gen_tcp.close(app)

    assert Task.await(waiting, 10_000) == {:error, :closed}
    assert await_current(ctx.host, &(not &1.attached))
  end

  test "a press on an action is read, logged and dropped", ctx do
    app = attach(ctx.socket_path)
    link = attached_link(ctx.host)

    {_result, log} =
      with_log(fn ->
        send_line(app, %{
          "type" => "notification.action",
          "reminder_id" => "rem_1",
          "action" => "snooze_10m"
        })

        assert {:ok, _status} = round_trip(app, link)
      end)

    assert log =~ "native host dropped notification.action for reminder rem_1"
  end

  test "protocol violations are answered once and close the connection", ctx do
    bad = attach(ctx.socket_path)
    send_line(bad, %{"type" => "notification.action", "reminder_id" => "rem_1", "action" => "x"})
    assert %{"type" => "error", "reason" => "invalid_field", "field" => "action"} = recv(bad)
    assert closed?(bad)

    unknown = attach(ctx.socket_path)
    send_line(unknown, %{"type" => "tab.closed"})

    assert %{"type" => "error", "reason" => "unknown_event", "event" => "tab.closed"} =
             recv(unknown)

    assert closed?(unknown)
  end

  test "an app the daemon cannot place as independent is refused and closed", ctx do
    stop_supervised!(ctx.opts[:name])
    opts = Keyword.put(ctx.opts, :link_opts, daemon_os_pid: ParentProcess.os_pid())
    start_supervised!({NativeHostSupervisor, opts}, id: opts[:name])

    {_result, log} =
      with_log(fn ->
        client = connect(ctx.socket_path)

        assert %{"type" => "error", "reason" => "untrusted_host", "message" => message} =
                 recv(client)

        assert message =~ "the native host must be a process the daemon did not start"
        assert closed?(client)
      end)

    assert log =~ "native host connection refusing a host the daemon did not trust"
  end

  defp attached_link(host), do: await_current(host, & &1.attached).connection

  # One more request answered, so everything the app wrote before it has been
  # read: the link reads the app's lines in order.
  defp round_trip(app, link) do
    status = Task.async(fn -> Link.request(link, "host.status", %{}, 10_000) end)
    assert %{"id" => id, "type" => "host.status"} = recv(app)

    send_line(app, %{
      "id" => id,
      "ok" => true,
      "result" => %{"host_version" => "0.6.0", "notifications" => "granted"}
    })

    Task.await(status, 10_000)
  end

  defp hello(path) do
    {client, response} = connect_handshaken(path)
    assert %{"type" => "server_hello"} = response
    client
  end

  # Only one app connects at a time, and the server frees the slot only after
  # it takes the exiting link's `:DOWN`, a step after the socket itself closes
  # from the caller's point of view. So a connect right behind a link this test
  # just closed retries the transient refusal instead of racing that teardown;
  # the browser host's connection test explains each refusal shape.
  defp connect_handshaken(path, deadline_ms \\ 10_000) do
    until = System.monotonic_time(:millisecond) + deadline_ms
    handshake_until(path, until)
  end

  defp handshake_until(path, until) do
    client = connect(path)
    hello = Jason.encode!(%{"type" => "client_hello", "protocol_version" => 1}) <> "\n"

    case {:gen_tcp.send(client, hello), System.monotonic_time(:millisecond) < until} do
      {:ok, retry?} ->
        case recv(client) do
          %{"type" => "error", "reason" => "host_already_attached"} when retry? ->
            retry_handshake(path, until)

          response ->
            {client, response}
        end

      {{:error, :closed}, true} ->
        retry_handshake(path, until)
    end
  end

  defp retry_handshake(path, until) do
    # sleep: one retry's interval, bounded by the deadline above
    Process.sleep(10)
    handshake_until(path, until)
  end

  defp attach(path) do
    client = hello(path)
    send_line(client, %{"type" => "attached", "host_version" => "0.6.0"})
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
    {:ok, line} = :gen_tcp.recv(socket, 0, 10_000)
    Jason.decode!(line)
  end

  defp closed?(socket), do: :gen_tcp.recv(socket, 0, 10_000) == {:error, :closed}

  # A record written by the link's own process has no reply to wait on, so the
  # read is repeated until it holds, bounded by a wall-clock deadline.
  defp await_current(host, predicate, deadline_ms \\ 10_000) do
    until = System.monotonic_time(:millisecond) + deadline_ms
    await_until(host, predicate, until)
  end

  defp await_until(host, predicate, until) do
    current = HostAvailability.current(host)

    cond do
      predicate.(current) ->
        current

      System.monotonic_time(:millisecond) >= until ->
        flunk("the record never held: #{inspect(current)}")

      true ->
        # sleep: one poll's interval, bounded by the deadline above
        Process.sleep(10)
        await_until(host, predicate, until)
    end
  end
end
