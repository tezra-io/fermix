defmodule FermixChannels.Mobile.Push.PigeonDispatcherTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias FermixChannels.Mobile.Push.Config
  alias FermixChannels.Mobile.Push.PigeonDispatcher
  alias Pigeon.APNS.Notification

  test "owns one dispatcher, serializes concurrent batches, and closes it on shutdown" do
    test_pid = self()
    tracker = start_supervised!({Agent, fn -> %{active: 0, max_active: 0, calls: 0} end})
    config = config()
    server = unique_name()
    dispatcher = make_ref()

    start_dispatcher = fn ^config ->
      send(test_pid, :dispatcher_started)
      {:ok, dispatcher}
    end

    push = fn ^dispatcher, notifications, 500 ->
      Agent.update(tracker, fn state ->
        active = state.active + 1

        %{
          state
          | active: active,
            max_active: max(state.max_active, active),
            calls: state.calls + 1
        }
      end)

      Process.sleep(20)
      Agent.update(tracker, &%{&1 | active: &1.active - 1})
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

    assert_receive :dispatcher_started

    notification = %Notification{device_token: "token", topic: "io.tezra.fermix"}

    results =
      1..2
      |> Task.async_stream(
        fn _ -> PigeonDispatcher.dispatch(server, [notification], config) end,
        ordered: false,
        max_concurrency: 2,
        timeout: 2_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, fn
             {:ok,
              {:ok,
               [
                 %Notification{
                   device_token: "token",
                   topic: "io.tezra.fermix",
                   response: :success
                 }
               ]}} ->
               true

             _other ->
               false
           end)

    assert Agent.get(tracker, & &1) == %{active: 0, max_active: 1, calls: 2}
    refute_receive :dispatcher_started

    assert :ok = GenServer.stop(server, :normal, 1_000)
    assert_receive :dispatcher_stopped, 1_000
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
