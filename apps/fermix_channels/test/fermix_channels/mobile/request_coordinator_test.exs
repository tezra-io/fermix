defmodule FermixChannels.Mobile.RequestCoordinatorTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.RequestCoordinator

  defmodule StoreStub do
    def recoverable_client_requests(epoch, opts) do
      send(opts[:test_pid], {:recoverable, epoch, opts[:limit]})
      {:ok, opts[:recoverable] || []}
    end

    def start_client_request(profile, client_id, epoch, opts) do
      send(opts[:test_pid], {:started, profile, client_id, epoch})

      case client_id do
        "active" -> {:ok, {:active, %{attempt: 4}}}
        "done" -> {:ok, {:completed, %{attempt: 2, result_server_seq: 9}}}
        _other -> {:ok, {:started, %{attempt: opts[:attempt] || 1, runner_epoch: epoch}}}
      end
    end

    def fail_client_request(profile, client_id, attempt, fields, opts) do
      send(opts[:test_pid], {:recovery_failed, profile, client_id, attempt, fields})
      {:ok, %{status: "failed", attempt: attempt}}
    end
  end

  test "serializes acquisition under one random boot epoch" do
    server =
      start_supervised!(
        {RequestCoordinator, store: StoreStub, recover?: false, boot_epoch: random_epoch()}
      )

    epoch = RequestCoordinator.epoch(server)

    assert is_binary(epoch)
    assert String.starts_with?(epoch, "test-")

    opts = [test_pid: self(), attempt: 3]

    assert {:ok, {:started, %{attempt: 3}}} =
             RequestCoordinator.acquire(server, "main", "one", opts)

    assert {:ok, {:active, %{attempt: 4}}} =
             RequestCoordinator.acquire(server, "main", "active", opts)

    assert_received {:started, "main", "one", ^epoch}
    assert_received {:started, "main", "active", ^epoch}
  end

  test "startup recovery is bounded and reconstructs authenticated requests" do
    test_pid = self()

    recoverable = [
      %{
        profile_id: "main",
        client_msg_id: "offline",
        request_type: "msg",
        payload: %{"client_msg_id" => "offline", "profile_id" => "main", "text" => "queued"},
        authenticated_device_id: "device-a"
      }
    ]

    recover = fn row, context, opts ->
      send(test_pid, {:recovered, row.client_msg_id, context, opts[:request_coordinator]})
      :ok
    end

    server =
      start_supervised!(
        {RequestCoordinator,
         store: StoreStub,
         boot_epoch: random_epoch(),
         store_opts: [test_pid: self(), recoverable: recoverable],
         recovery_limit: 2,
         recovery_launcher: fn task -> task.() end,
         recover_request: recover}
      )

    epoch = RequestCoordinator.epoch(server)
    assert_received {:recoverable, ^epoch, 2}

    assert_received {:recovered, "offline",
                     %{transport: :mobile, authenticated_device_id: "device-a"}, ^server}
  end

  test "invalid legacy recovery rows are observable and never dispatched" do
    test_pid = self()

    row = %{
      profile_id: "main",
      client_msg_id: "legacy",
      request_type: "msg",
      payload: %{"client_msg_id" => "legacy"},
      authenticated_device_id: nil
    }

    recover = fn _row, _context, _opts ->
      send(test_pid, :unexpected_recovery)
      :ok
    end

    server =
      start_supervised!(
        {RequestCoordinator,
         store: StoreStub,
         boot_epoch: random_epoch(),
         store_opts: [test_pid: self(), recoverable: [row]],
         recovery_limit: 2,
         recovery_launcher: fn task -> task.() end,
         recover_request: recover}
      )

    assert is_binary(RequestCoordinator.epoch(server))
    refute_received :unexpected_recovery
    assert_received {:recovery_failed, "main", "legacy", 1, _fields}
  end

  test "standalone startup generates a fresh cryptographic boot epoch" do
    server = start_supervised!({RequestCoordinator, store: StoreStub, recover?: false})
    first = RequestCoordinator.epoch(server)

    assert {:ok, first_bytes} = Base.url_decode64(first, padding: false)
    assert byte_size(first_bytes) == 32

    assert {:ok, second_server} =
             RequestCoordinator.start_link(store: StoreStub, recover?: false, name: nil)

    on_exit(fn -> if Process.alive?(second_server), do: GenServer.stop(second_server) end)
    second = RequestCoordinator.epoch(second_server)
    refute first == second
    assert {:ok, <<_::256>>} = Base.url_decode64(second, padding: false)
  end

  defp random_epoch do
    "test-#{System.unique_integer([:positive, :monotonic])}"
  end
end
