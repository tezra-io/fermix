defmodule FermixChannels.Mobile.Push.PigeonDispatcherTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias FermixChannels.Mobile.Push.Config
  alias FermixChannels.Mobile.Push.PigeonDispatcher
  alias Pigeon.APNS.Notification

  test "connects on the first batch, owns one dispatcher, serializes batches, closes it" do
    test_pid = self()
    tracker = start_supervised!({Agent, fn -> %{active: 0, max_active: 0, calls: 0} end})
    config = config()
    server = unique_name()
    dispatcher = make_ref()

    start_dispatcher = fn ^config ->
      send(test_pid, {:dispatcher_started, self()})
      {:ok, dispatcher}
    end

    # Each batch parks inside the push until the test releases it, so the
    # second batch can be seen waiting behind the first.
    push = fn ^dispatcher, notifications, 500 ->
      Agent.update(tracker, fn state ->
        active = state.active + 1
        %{state | active: active, max_active: max(state.max_active, active)}
      end)

      send(test_pid, {:push_entered, self()})
      receive do: (:release -> :ok)
      Agent.update(tracker, &%{&1 | active: &1.active - 1, calls: &1.calls + 1})
      {:ok, Enum.map(notifications, &%{&1 | response: :success})}
    end

    stop_dispatcher = fn ^dispatcher ->
      send(test_pid, :dispatcher_stopped)
      :ok
    end

    start_supervised!(
      {PigeonDispatcher,
       name: server,
       config: config,
       start_dispatcher: start_dispatcher,
       push: push,
       stop_dispatcher: stop_dispatcher}
    )

    # Nothing connects at boot: an offline host must not keep the subtree down.
    assert PigeonDispatcher.status(server) == :ready
    refute_received {:dispatcher_started, _connection}

    notification = %Notification{device_token: "token", topic: "io.tezra.fermix"}
    first = Task.async(fn -> PigeonDispatcher.dispatch(server, [notification], config) end)
    assert_receive {:dispatcher_started, connection}
    assert_receive {:push_entered, ^connection}

    # The second batch is seen arriving while the first is still inside its
    # push, and it does not start until the first is done.
    :erlang.trace(connection, true, [:receive])
    second = Task.async(fn -> PigeonDispatcher.dispatch(server, [notification], config) end)
    assert_receive {:trace, ^connection, :receive, {:push, _from, [_notification]}}
    refute_received {:push_entered, _connection}

    send(connection, :release)
    assert_receive {:push_entered, ^connection}
    send(connection, :release)

    for task <- [first, second] do
      assert {:ok, [%Notification{device_token: "token", response: :success}]} =
               Task.await(task)
    end

    assert Agent.get(tracker, & &1) == %{active: 0, max_active: 1, calls: 2}
    refute_received {:dispatcher_started, _connection}
    assert PigeonDispatcher.status(server) == :ready

    assert :ok = GenServer.stop(server, :normal, 1_000)
    assert_receive :dispatcher_stopped
  end

  test "rejects a runtime config that differs from the owned dispatcher" do
    config = config()
    server = unique_name()

    start_supervised!(
      {PigeonDispatcher,
       name: server,
       config: config,
       start_dispatcher: fn _ -> {:ok, make_ref()} end,
       push: fn _, _, _ -> flunk("mismatched config reached the dispatcher") end,
       stop_dispatcher: fn _ -> :ok end}
    )

    changed = %{config | topic: "io.tezra.other"}

    assert {:error, :push_dispatcher_config_mismatch} =
             PigeonDispatcher.dispatch(server, [], changed)
  end

  test "a raising push dependency is reported with its exception type and stacktrace" do
    config = config()
    server = unique_name()

    start_supervised!(
      {PigeonDispatcher,
       name: server,
       config: config,
       start_dispatcher: fn _ -> {:ok, make_ref()} end,
       push: fn _dispatcher, _notifications, _timeout -> raise ArgumentError, "pigeon defect" end,
       stop_dispatcher: fn _ -> :ok end}
    )

    notification = %Notification{device_token: "token", topic: "io.tezra.fermix"}

    {result, log} =
      with_log(fn -> PigeonDispatcher.dispatch(server, [notification], config) end)

    assert {:error, {:push_dependency_exception, :push, ArgumentError, "pigeon defect"}} = result
    assert log =~ "mobile push dependency :push raised"
    assert log =~ "ArgumentError"
    assert log =~ "push_pigeon_dispatcher_test.exs"
  end

  # STB-5: Pigeon's APNs adapter connects inside its own init and stops when it
  # cannot. Connecting at boot made an offline host fail the mobile subtree,
  # then the channels supervisor, then the node.
  test "an unreachable APNs at boot starts the dispatcher and degrades push" do
    test_pid = self()
    config = config()
    server = unique_name()

    start_supervised!(
      {PigeonDispatcher,
       name: server,
       config: config,
       start_dispatcher: fn ^config ->
         send(test_pid, :connect_attempted)
         {:error, :timeout}
       end,
       push: fn _, _, _ -> flunk("nothing to push through") end,
       stop_dispatcher: fn _ -> :ok end}
    )

    assert PigeonDispatcher.status(server) == :ready
    notification = %Notification{device_token: "token", topic: "io.tezra.fermix"}

    {result, log} =
      with_log(fn -> PigeonDispatcher.dispatch(server, [notification], config) end)

    assert {:error, {:push_unavailable, :connect_failed}} = result
    assert_receive :connect_attempted
    assert_receive :connect_attempted
    refute_received :connect_attempted
    assert log =~ "APNs connection failed"
    assert PigeonDispatcher.status(server) == {:degraded, :connect_failed}
  end

  # R1-9: Pigeon's APNs worker connects with no timeout, inside the call, so a
  # network that drops SYNs held this server for minutes; the status read
  # timed out and doctor said no push dispatcher was running.
  test "status answers while a connect hangs, and says push is connecting" do
    test_pid = self()
    config = config()
    server = unique_name()

    start_supervised!(
      {PigeonDispatcher,
       name: server,
       config: config,
       start_dispatcher: fn ^config ->
         send(test_pid, {:connecting, self()})
         receive do: (:answer -> {:error, :timeout})
       end,
       push: fn _, _, _ -> flunk("nothing connected to push through") end,
       stop_dispatcher: fn _ -> :ok end}
    )

    notification = %Notification{device_token: "token", topic: "io.tezra.fermix"}

    {result, log} =
      with_log(fn ->
        batch = Task.async(fn -> PigeonDispatcher.dispatch(server, [notification], config) end)

        for _attempt <- 1..2 do
          assert_receive {:connecting, connection}
          assert PigeonDispatcher.status(server) == {:degraded, :connecting}
          send(connection, :answer)
        end

        Task.await(batch)
      end)

    assert {:error, {:push_unavailable, :connect_failed}} = result
    assert log =~ "APNs connection failed"
    assert PigeonDispatcher.status(server) == {:degraded, :connect_failed}
  end

  test "batches that arrive while a connect runs wait for it, a bounded number of them" do
    test_pid = self()
    config = config()
    server = unique_name()
    bound = PigeonDispatcher.max_waiting_batches()
    assert bound == 32

    start_supervised!(
      {PigeonDispatcher,
       name: server,
       config: config,
       start_dispatcher: fn ^config ->
         send(test_pid, {:connecting, self()})
         receive do: (:answer -> {:ok, make_ref()})
       end,
       push: fn _dispatcher, notifications, _timeout -> {:ok, notifications} end,
       stop_dispatcher: fn _ -> :ok end}
    )

    server_pid = GenServer.whereis(server)
    :erlang.trace(server_pid, true, [:receive])
    notification = %Notification{device_token: "token", topic: "io.tezra.fermix"}

    batches =
      for _batch <- 1..(bound + 1) do
        Task.async(fn -> PigeonDispatcher.dispatch(server, [notification], config) end)
      end

    # Every batch reached the server before the connect is let finish.
    for _batch <- batches do
      assert_receive {:trace, ^server_pid, :receive, {:"$gen_call", _from, {:dispatch, _, _}}}
    end

    :erlang.trace(server_pid, false, [:receive])
    assert_receive {:connecting, connection}
    send(connection, :answer)
    results = Enum.map(batches, &Task.await/1)

    assert Enum.count(results, &match?({:ok, [_sent]}, &1)) == bound
    assert Enum.count(results, &(&1 == {:error, {:push_unavailable, :connecting}})) == 1
    refute_received {:connecting, _another}
  end

  # R3-3: Pigeon's worker connects through Kadabra's application-wide
  # supervisor, which runs the connect inside a start with no timeout. Killing
  # a Pigeon start at the deadline left that connect running and queued the
  # next one behind it, two more per batch, each opening an APNs connection
  # nobody owned once the network came back. The deadline now answers the
  # batches waiting on a connect, and the connect runs on to its own end.
  test "a connect past its deadline answers its batches, and none starts until it ends" do
    test_pid = self()
    config = config()
    server = unique_name()

    start_supervised!(
      {PigeonDispatcher,
       name: server,
       config: config,
       start_dispatcher: fn ^config ->
         send(test_pid, {:connecting, self()})
         receive do: ({:answer, result} -> result)
       end,
       push: fn _dispatcher, notifications, _timeout -> {:ok, notifications} end,
       stop_dispatcher: fn _ -> :ok end,
       schedule_deadline: fn message, timeout_ms ->
         send(test_pid, {:deadline_armed, message, timeout_ms})
         make_ref()
       end}
    )

    server_pid = GenServer.whereis(server)
    notification = %Notification{device_token: "token", topic: "io.tezra.fermix"}
    waiting = Task.async(fn -> PigeonDispatcher.dispatch(server, [notification], config) end)
    assert_receive {:connecting, connection}
    assert_receive {:deadline_armed, deadline, 10_000}

    # The answer to the waiting batch comes after the deadline's log line.
    {result, log} =
      with_log(fn ->
        send(server_pid, deadline)
        Task.await(waiting)
      end)

    assert result == {:error, {:push_unavailable, :connecting}}
    assert log =~ "APNs connect has not finished"
    assert PigeonDispatcher.status(server) == {:degraded, :connecting}

    # A batch while that connect is still out is refused at once, and starts
    # no second connect behind it.
    assert PigeonDispatcher.dispatch(server, [notification], config) ==
             {:error, {:push_unavailable, :connecting}}

    assert %{connecting: %{pid: ^connection}} = :sys.get_state(server_pid)

    # Its end, however late, is a result like any other; nobody waits on it,
    # so it is not tried again.
    :erlang.trace(server_pid, true, [:receive])

    {health, log} =
      with_log(fn ->
        send(connection, {:answer, {:error, :timeout}})
        assert_receive {:trace, ^server_pid, :receive, {:apns_connected, ^connection, _result}}
        PigeonDispatcher.status(server)
      end)

    :erlang.trace(server_pid, false, [:receive])
    assert health == {:degraded, :connect_failed}
    assert log =~ "APNs connection failed"
    assert %{connecting: nil} = :sys.get_state(server_pid)

    # The next batch connects afresh.
    next = Task.async(fn -> PigeonDispatcher.dispatch(server, [notification], config) end)
    assert_receive {:connecting, second}
    refute second == connection
    send(second, {:answer, {:ok, make_ref()}})
    assert {:ok, [_sent]} = Task.await(next)
    assert PigeonDispatcher.status(server) == :ready
  end

  test "a connect that ends after its deadline still serves the batches that follow" do
    test_pid = self()
    config = config()
    server = unique_name()
    dispatcher = make_ref()

    start_supervised!(
      {PigeonDispatcher,
       name: server,
       config: config,
       start_dispatcher: fn ^config ->
         send(test_pid, {:connecting, self()})
         receive do: (:answer -> {:ok, dispatcher})
       end,
       push: fn ^dispatcher, notifications, _timeout -> {:ok, notifications} end,
       stop_dispatcher: fn _ -> :ok end,
       schedule_deadline: fn message, _timeout_ms ->
         send(test_pid, {:deadline_armed, message})
         make_ref()
       end}
    )

    server_pid = GenServer.whereis(server)
    notification = %Notification{device_token: "token", topic: "io.tezra.fermix"}
    waiting = Task.async(fn -> PigeonDispatcher.dispatch(server, [notification], config) end)
    assert_receive {:connecting, connection}
    assert_receive {:deadline_armed, deadline}

    {result, _log} =
      with_log(fn ->
        send(server_pid, deadline)
        Task.await(waiting)
      end)

    assert result == {:error, {:push_unavailable, :connecting}}

    :erlang.trace(server_pid, true, [:receive])
    send(connection, :answer)
    assert_receive {:trace, ^server_pid, :receive, {:apns_connected, ^connection, _result}}
    :erlang.trace(server_pid, false, [:receive])

    assert PigeonDispatcher.status(server) == :ready
    assert {:ok, [_sent]} = PigeonDispatcher.dispatch(server, [notification], config)
    refute_received {:connecting, _another}
  end

  test "a connection lost at runtime degrades push and the next batch reconnects" do
    test_pid = self()
    config = config()
    server = unique_name()

    start_dispatcher = fn ^config ->
      pid = spawn_link(fn -> receive do: (:never -> :ok) end)
      send(test_pid, {:dispatcher_started, pid, self()})
      {:ok, pid}
    end

    start_supervised!(
      {PigeonDispatcher,
       name: server,
       config: config,
       start_dispatcher: start_dispatcher,
       push: fn _dispatcher, notifications, _timeout -> {:ok, notifications} end,
       stop_dispatcher: fn _ -> :ok end}
    )

    notification = %Notification{device_token: "token", topic: "io.tezra.fermix"}
    assert {:ok, [_sent]} = PigeonDispatcher.dispatch(server, [notification], config)
    assert_receive {:dispatcher_started, first, connection}
    server_pid = GenServer.whereis(server)

    # The server is seen receiving the connection's exit, so the status read
    # after it is answered with the loss already handled.
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        :erlang.trace(server_pid, true, [:receive])
        Process.exit(first, :kill)
        assert_receive {:trace, ^server_pid, :receive, {:EXIT, ^connection, _reason}}
        :erlang.trace(server_pid, false, [:receive])
        assert PigeonDispatcher.status(server) == {:degraded, :connection_lost}
      end)

    assert log =~ "APNs connection lost"
    assert Process.alive?(server_pid)

    assert {:ok, [_sent]} = PigeonDispatcher.dispatch(server, [notification], config)
    assert_receive {:dispatcher_started, second, _connection}
    refute second == first
    assert PigeonDispatcher.status(server) == :ready
  end

  defp config do
    {:ok, config} =
      Config.new(
        enabled: true,
        team_id: "ABCDE12345",
        key_id: "XYZ987",
        key: X509.PrivateKey.new_ec(:secp256r1) |> X509.PrivateKey.to_pem(),
        topic: "io.tezra.fermix",
        environment: "development",
        timeout_ms: 500
      )

    config
  end

  defp unique_name,
    do: String.to_atom("mobile-push-dispatcher-#{System.unique_integer([:positive])}")
end
