defmodule FermixChannels.Desktop.InvocationsTest do
  @moduledoc """
  M75 §11: the primary's executor family against a real desktop session
  (Noise `IK`, the codec and the desktop's peer): an invocation and its
  correlated result, the deadline, a result lost in a reconnect reconciled from
  the desktop's receipt, an invocation the desktop holds no receipt for
  reported uncertain and never sent again, and a file through the attachment
  pipeline.

  `async: false`: the family reaches `Desktop.InvocationRegistry` by its
  registered name, so this module runs one registry under it, with its own
  peers registry and a schedule that hands each timer to the test, which
  delivers a deadline by hand.
  """

  use ExUnit.Case, async: false

  alias FermixChannels.Desktop.InvocationRegistry
  alias FermixChannels.Desktop.Invocations
  alias FermixChannels.Desktop.Peer
  alias FermixChannels.Desktop.Supervisor, as: DesktopSupervisor
  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.Noise
  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Test.SessionDriver, as: Driver

  @desktop_id "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e"
  @other_id "7a2b3c4d-5e6f-4a1b-8c2d-3e4f5a6b7c8d"
  @seen ~U[2026-10-27 08:00:00Z]
  @families %{executor: Invocations}

  setup do
    suffix = System.unique_integer([:positive])
    peers = Module.concat(__MODULE__, "Peers#{suffix}")
    peer_supervisor = Module.concat(__MODULE__, "PeerSupervisor#{suffix}")
    test_pid = self()

    start_supervised!(
      {DesktopSupervisor, name: nil, registry: peers, peer_supervisor: peer_supervisor}
    )

    registry =
      start_supervised!(
        {InvocationRegistry,
         peers: peers,
         schedule: fn message, delay_ms ->
           send(test_pid, {:scheduled, message, delay_ms})
           make_ref()
         end}
      )

    device_registry =
      start_supervised!(
        {DeviceRegistry,
         name: Module.concat(__MODULE__, "Registry#{suffix}"),
         authorize_device: fn _store, id -> {:ok, row(id)} end,
         delete_device: fn _store, _id -> :ok end,
         revoke_requests: fn _id -> :ok end}
      )

    %{
      gateway: Noise.generate_keypair(),
      desktop: Noise.generate_keypair(),
      other: Noise.generate_keypair(),
      peers: peers,
      peer_supervisor: peer_supervisor,
      registry: registry,
      device_registry: device_registry
    }
  end

  test "an invocation reaches the desktop with the turn's correlation id, and its result comes back",
       ctx do
    {driver, client} = ready!(ctx, ctx.desktop)
    task = invoke_async("notify", %{"title" => "Tea", "body" => "Kettle"})

    {[{invoke, args}], client} = Driver.client_receive(driver, client)
    assert %{"t" => "invoke", "action" => "notify", "deadline_s" => 30} = invoke
    assert %{"index" => 0, "last" => true} = invoke
    id = invoke["invocation_id"]

    assert Jason.decode!(args) == %{
             "title" => "Tea",
             "body" => "Kettle",
             "correlation_id" => "sess-7"
           }

    result = %{"correlation_id" => "sess-7"}
    _client = send_result(driver, client, id, "ok", result, 2)

    assert {:ok,
            %{kind: :result, status: :ok, result: ^result, attachment: nil, invocation_id: ^id}} =
             Task.await(task)
  end

  test "a desktop that is not connected is sent nothing" do
    assert Invocations.invoke(@desktop_id, "notify", %{}, deadline_s: 30, correlation_id: "s") ==
             {:error, :not_connected}

    refute_received {:scheduled, _message, _delay}
  end

  test "past the deadline a connected desktop is asked once more, and no receipt is uncertain",
       ctx do
    {driver, client} = ready!(ctx, ctx.desktop)
    task = invoke_async("list_directory", %{"path" => "~"})
    {[{%{"invocation_id" => id}, _args}], client} = Driver.client_receive(driver, client)

    assert_receive {:scheduled, {:deadline, ^id, _token} = deadline, 65_000}
    send(ctx.registry, deadline)

    {[{status, <<>>}], client} = Driver.client_receive(driver, client)
    assert %{"t" => "invoke_status", "status_id" => asked, "invocation_ids" => [^id]} = status
    assert_receive {:scheduled, {:reconcile_timeout, ^id, _later}, 10_000}

    _client = receipts(driver, client, asked, [], 2)

    assert {:ok, %{kind: :uncertain, reason: :no_receipt, invocation_id: ^id}} =
             Task.await(task)
  end

  test "a result lost in a reconnect is reconciled from the desktop's receipt", ctx do
    {driver, client} = ready!(ctx, ctx.desktop)
    task = invoke_async("open_url", %{"url" => "https://fermix.test/"})
    {[{%{"invocation_id" => id}, _args}], _client} = Driver.client_receive(driver, client)

    # The desktop ran it, and the connection dropped before its result arrived.
    drop!(ctx, driver)
    {driver, client} = ready!(ctx, ctx.desktop)

    {[{status, <<>>}], client} = Driver.client_receive(driver, client)
    assert %{"t" => "invoke_status", "status_id" => asked, "invocation_ids" => [^id]} = status

    receipt = %{"invocation_id" => id, "status" => "ok", "finished_at" => "2026-10-27T08:01:00Z"}
    client = receipts(driver, client, asked, [receipt], 2)

    assert {:ok,
            %{
              kind: :reconciled,
              status: :ok,
              finished_at: "2026-10-27T08:01:00Z",
              invocation_id: ^id
            }} =
             Task.await(task)

    assert_nothing_more_sent(driver, client, 3)
  end

  test "an invocation the desktop holds no receipt for is reported uncertain and never re-sent",
       ctx do
    {driver, client} = ready!(ctx, ctx.desktop)
    task = invoke_async("run_command", %{"command" => "make backup"})
    {[{%{"invocation_id" => id}, _args}], _client} = Driver.client_receive(driver, client)
    assert_receive {:scheduled, {:deadline, ^id, _token} = deadline, _delay}

    drop!(ctx, driver)
    {driver, client} = ready!(ctx, ctx.desktop)

    # After the reconnect: asked, and the desktop holds no receipt. It may still
    # be running, so the deadline decides.
    {[{%{"t" => "invoke_status", "status_id" => first, "invocation_ids" => [^id]}, <<>>}], client} =
      Driver.client_receive(driver, client)

    client = receipts(driver, client, first, [], 2)
    refute Task.yield(task, 0)

    send(ctx.registry, deadline)

    {[{%{"t" => "invoke_status", "status_id" => second, "invocation_ids" => [^id]}, <<>>}],
     client} = Driver.client_receive(driver, client)

    refute second == first
    client = receipts(driver, client, second, [], 3)

    assert {:ok, %{kind: :uncertain, reason: :no_receipt, invocation_id: ^id}} =
             Task.await(task)

    # Nothing was sent again: the next frame is the pong.
    assert_nothing_more_sent(driver, client, 4)
  end

  # Link F8: an answer to a question an earlier session asked, sent late on
  # the new one, settles nothing and costs the new question nothing.
  test "a late invoke_receipts naming another status_id is refused, and the asked one counts",
       ctx do
    {driver, client} = ready!(ctx, ctx.desktop)
    task = invoke_async("open_url", %{"url" => "https://fermix.test/"})
    {[{%{"invocation_id" => id}, _args}], _client} = Driver.client_receive(driver, client)

    drop!(ctx, driver)
    {driver, client} = ready!(ctx, ctx.desktop)

    {[{%{"t" => "invoke_status", "status_id" => asked}, <<>>}], client} =
      Driver.client_receive(driver, client)

    client = receipts(driver, client, "st-from-the-last-session", [], 2)

    assert {[{%{"t" => "error", "code" => "receipts_not_asked"}, <<>>}], client} =
             Driver.client_receive(driver, client)

    refute Task.yield(task, 0)

    receipt = %{"invocation_id" => id, "status" => "ok", "finished_at" => "2026-10-27T08:01:00Z"}
    _client = receipts(driver, client, asked, [receipt], 3)

    assert {:ok, %{kind: :reconciled, status: :ok, invocation_id: ^id}} = Task.await(task)
  end

  test "a desktop that dropped and did not come back by the deadline is uncertain at once",
       ctx do
    {driver, client} = ready!(ctx, ctx.desktop)
    task = invoke_async("notify", %{"title" => "a", "body" => "b"})
    {[{%{"invocation_id" => id}, _args}], _client} = Driver.client_receive(driver, client)
    assert_receive {:scheduled, {:deadline, ^id, _token} = deadline, _delay}

    drop!(ctx, driver)
    send(ctx.registry, deadline)

    assert {:ok, %{kind: :uncertain, reason: :disconnected, invocation_id: ^id}} =
             Task.await(task)
  end

  test "a read_file's bytes come back through the attachment pipeline", ctx do
    {driver, client} = ready!(ctx, ctx.desktop)
    task = invoke_async("read_file", %{"path" => "~/Downloads/lease.pdf"})
    {[{%{"invocation_id" => id}, _args}], client} = Driver.client_receive(driver, client)

    pdf = "%PDF-1.7\n1 0 obj << /Type /Catalog >> endobj\n%%EOF\n"
    blob = %{"invocation_id" => id, "index" => 0, "last" => true}
    client = Driver.client_send(driver, client, "invoke_blob", blob, 2, pdf)

    result = %{
      "name" => "lease.pdf",
      "size_bytes" => byte_size(pdf),
      "correlation_id" => "sess-7"
    }

    _client = send_result(driver, client, id, "ok", result, 3)

    assert {:ok, %{kind: :result, status: :ok, attachment: attachment}} = Task.await(task)

    assert %FermixCore.Attachments{
             kind: :document,
             mime_type: "application/pdf",
             name: "lease.pdf",
             status: :ready,
             bytes: ^pdf
           } = attachment

    assert FermixCore.Attachments.parts([attachment]) == [
             %{type: :document, mime_type: "application/pdf", data: pdf, name: "lease.pdf"}
           ]
  end

  test "a desktop cannot answer another desktop's invocation", ctx do
    {driver, client} = ready!(ctx, ctx.desktop)
    {other, other_client} = ready!(ctx, ctx.other, @other_id)
    task = invoke_async("notify", %{"title" => "a", "body" => "b"})
    {[{%{"invocation_id" => id}, _args}], _client} = Driver.client_receive(driver, client)

    other_client = send_result(other, other_client, id, "ok", %{}, 2)
    {[{error, <<>>}], _other_client} = Driver.client_receive(other, other_client)
    assert %{"t" => "error", "code" => _code} = error
    refute Task.yield(task, 0)
  end

  test "at most eight invocations are in flight to one desktop", ctx do
    {driver, client} = ready!(ctx, ctx.desktop)

    tasks = for n <- 1..8, do: invoke_async("notify", %{"title" => "#{n}", "body" => "b"})

    {_received, _client} =
      Enum.flat_map_reduce(1..8, client, fn _n, c -> Driver.client_receive(driver, c) end)

    assert Invocations.invoke(@desktop_id, "notify", %{}, deadline_s: 30, correlation_id: "s") ==
             {:error, {:busy, 8}}

    Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
  end

  # --- helpers ---------------------------------------------------------------

  defp invoke_async(action, args) do
    Task.async(fn ->
      Invocations.invoke(@desktop_id, action, args,
        deadline_s: deadline(action),
        correlation_id: "sess-7"
      )
    end)
  end

  defp deadline("notify"), do: 30
  defp deadline("open_url"), do: 30
  defp deadline("list_directory"), do: 60
  defp deadline(_action), do: 120

  defp send_result(driver, client, id, status, result, seq) do
    fields = %{"invocation_id" => id, "status" => status, "index" => 0, "last" => true}
    Driver.client_send(driver, client, "invoke_result", fields, seq, Jason.encode!(result))
  end

  # The desktop's connection drops: its session process ends, and its peer
  # with it.
  defp receipts(driver, client, status_id, receipts, seq) do
    Driver.client_send(
      driver,
      client,
      "invoke_receipts",
      %{"status_id" => status_id, "receipts" => receipts},
      seq
    )
  end

  defp drop!(ctx, driver) do
    {:ok, peer, _value} = Peer.lookup(ctx.peers, @desktop_id)
    ref = Process.monitor(peer)
    Process.unlink(driver)
    Process.exit(driver, :kill)
    assert_receive {:DOWN, ^ref, :process, ^peer, _reason}
  end

  defp assert_nothing_more_sent(driver, client, seq) do
    client = Driver.client_send(driver, client, "ping", %{}, seq)

    assert {[{%{"t" => "pong", "seq" => ^seq}, <<>>}], _client} =
             Driver.client_receive(driver, client)
  end

  # A desktop's session through IK and hello, its hello_ack read, its peer
  # started with the executor family alone.
  defp ready!(ctx, keypair, device_id \\ @desktop_id) do
    keys = %{ctx.desktop.public => @desktop_id, ctx.other.public => @other_id}
    supervisor = ctx.peer_supervisor

    driver =
      Driver.start!(
        peer: {127, 0, 0, 1},
        gateway_keypair: ctx.gateway,
        primary_epoch: 4,
        device_store: :store,
        device_registry: ctx.device_registry,
        desktop_peers: ctx.peers,
        desktop_peer_supervisor: ctx.peer_supervisor,
        find_device: fn :store, key -> {:ok, row(Map.fetch!(keys, key))} end,
        update_device: fn :store, id, %{last_seen: _seen} -> {:ok, row(id)} end,
        wall_clock: fn -> @seen end,
        hello_ack_builder: fn _state -> {:ok, hello_ack()} end,
        pending_approvals: fn "main" -> [] end,
        pairing_pending: fn -> :none end,
        start_desktop_peer: fn opts ->
          Peer.start(supervisor, Keyword.put(opts, :families, @families))
        end
      )

    assert {:ok, client} =
             Noise.initialize(:initiator, :ik,
               static_keypair: keypair,
               remote_static: ctx.gateway.public
             )

    client = Driver.handshake!(driver, client)

    hello = %{
      "device_id" => device_id,
      "app_version" => "0.17.0",
      "last_server_seq" => 0,
      "protocol_v" => Protocol.protocol_version()
    }

    client = Driver.client_send(driver, client, "hello", hello, 1)

    assert {[{%{"t" => "hello_ack", "seq" => 1}, <<>>}], client} =
             Driver.client_receive(driver, client)

    {driver, client}
  end

  defp row(id), do: %{device_id: id, name: "Studio Mac", kind: :desktop, executor: true}

  defp hello_ack do
    {min_version, max_version} = Protocol.supported_version_range()

    %{
      "session_id" => "desktop-session",
      "min_version" => min_version,
      "max_version" => max_version,
      "profiles" => [%{"id" => "main", "name" => "Fermix"}],
      "candidates" => [],
      "history_head_seq" => 0,
      "read_up_to_seq" => 0,
      "caps" => %{"commands" => [], "max_media_bytes" => 20_971_520},
      "primary_epoch" => 4
    }
  end
end
