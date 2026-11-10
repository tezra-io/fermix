defmodule FermixChannels.Mobile.PhoneListChannelTest do
  @moduledoc """
  A phone's list channel end to end (M85 E4): the phone's real
  `Mobile.Session` through the Noise `IK` handshake and codec, its peer and
  the desktop's companion family with one channel, the pump, and an ordinary
  `Companion.Connection` in the lists scope on the primary, with the owner's
  lists in a throwaway repo. What is stood in for is the trust store's row
  and the router a phone's `msg` is handed to.
  """

  use ExUnit.Case, async: true

  alias FermixChannels.Companion.Approvals
  alias FermixChannels.Companion.ChecklistNotifier
  alias FermixChannels.Companion.Endpoint
  alias FermixChannels.Desktop.Companion
  alias FermixChannels.Desktop.Supervisor, as: DesktopSupervisor
  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.EventRouter
  alias FermixChannels.Mobile.Noise
  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Test.SessionDriver, as: Driver
  alias FermixCore.Checklists.Registry, as: ChecklistRegistry
  alias FermixCore.Memory.Repo

  @phone_id "2a9b8c7d-6e5f-4a3b-9c2d-1e0f9a8b7c6d"
  @seen ~U[2026-11-09 08:00:00Z]
  @one_channel "One list channel is open from this phone."

  @owner_turn %{
    agent_name: "main",
    conversation_key: {"companion", "main", :root},
    source_trust: :operator,
    computer_use_origin: :interactive,
    channel: "companion",
    outside_sources: MapSet.new()
  }

  setup do
    suffix = System.unique_integer([:positive])
    peers = Module.concat(__MODULE__, "Peers#{suffix}")
    peer_supervisor = Module.concat(__MODULE__, "PeerSupervisor#{suffix}")
    tunnels = Module.concat(__MODULE__, "Tunnels#{suffix}")

    start_supervised!(
      {DesktopSupervisor,
       name: nil, registry: peers, peer_supervisor: peer_supervisor, tunnel_supervisor: tunnels}
    )

    registry =
      start_supervised!(
        {DeviceRegistry,
         name: Module.concat(__MODULE__, "Registry#{suffix}"),
         authorize_device: fn _store, id -> {:ok, row(id)} end,
         delete_device: fn _store, _id -> :ok end,
         revoke_requests: fn _id -> :ok end}
      )

    companion = primary_companion!(suffix)

    %{
      gateway: Noise.generate_keypair(),
      phone: Noise.generate_keypair(),
      peers: peers,
      peer_supervisor: peer_supervisor,
      tunnels: tunnels,
      registry: registry,
      companion: companion
    }
  end

  test "the phone opens its channel, pulls the index and a list, and edits via the phone", ctx do
    list_id = groceries!(ctx)
    {driver, client} = ready_phone!(ctx)

    client = open!(driver, client, 1, 2)

    {[server_hello], client} =
      line!(driver, client, %{"type" => "client_hello", "protocol_version" => 7}, 3)

    assert %{"type" => "server_hello"} = server_hello

    {[index], client} =
      line!(driver, client, %{"type" => "checklists_pull", "profile_id" => "main"}, 4)

    assert %{"type" => "checklists", "lists" => [%{"list_id" => ^list_id}]} = index

    pull = %{"type" => "checklist_pull", "profile_id" => "main", "list_id" => list_id}
    {[list], client} = line!(driver, client, pull, 5)
    assert %{"type" => "checklist", "list" => %{"list_id" => ^list_id, "rev" => 1}} = list

    edit = %{
      "type" => "checklist_edit",
      "client_msg_id" => "phone-add-1",
      "profile_id" => "main",
      "list_id" => list_id,
      "op" => %{"op" => "add", "text" => "Eggs"}
    }

    {[accepted], _client} = line!(driver, client, edit, 6)

    assert %{"type" => "accepted", "client_msg_id" => "phone-add-1", "duplicate" => false} =
             accepted

    {:ok, %{rows: rows}} =
      ChecklistRegistry.device_list(list_id, false, :independent, ctx.companion.checklist_opts)

    assert %{made_via: "phone"} = Enum.find(rows, &(&1.text == "Eggs"))
  end

  test "a phone's turn says it draws lists once its channel pulled the index", ctx do
    {driver, client} = ready_phone!(ctx)
    client = send_msg(driver, client, "before-pull", 2)
    assert_receive {:routed, %{type: "msg"} = before}, 2_000
    refute Map.get(before, :draws_lists)

    client = open!(driver, client, 1, 3)

    {_hello, client} =
      line!(driver, client, %{"type" => "client_hello", "protocol_version" => 7}, 4)

    {_index, client} =
      line!(driver, client, %{"type" => "checklists_pull", "profile_id" => "main"}, 5)

    _client = send_msg(driver, client, "after-pull", 6)
    assert_receive {:routed, %{type: "msg", draws_lists: true}}, 2_000
  end

  test "a second channel from the phone is closed with its sentence, and the session stays open",
       ctx do
    {driver, client} = ready_phone!(ctx)
    client = open!(driver, client, 1, 2)

    client = Driver.client_send(driver, client, "companion_open", %{"channel" => 2}, 3)
    {[{close, <<>>}], client} = Driver.client_receive(driver, client)

    assert close == %{
             "v" => 2,
             "t" => "companion_close",
             "seq" => close["seq"],
             "channel" => 2,
             "reason" => @one_channel
           }

    {[hello], _client} =
      line!(driver, client, %{"type" => "client_hello", "protocol_version" => 7}, 4)

    assert %{"type" => "server_hello"} = hello
  end

  test "a phone's channel refuses a msg as unknown, closing the channel and not the session",
       ctx do
    {driver, client} = ready_phone!(ctx)
    client = open!(driver, client, 1, 2)

    {_hello, client} =
      line!(driver, client, %{"type" => "client_hello", "protocol_version" => 7}, 3)

    msg = %{
      "type" => "msg",
      "client_msg_id" => "m-1",
      "profile_id" => "main",
      "text" => "hi",
      "attach_ids" => []
    }

    client =
      Driver.client_send(
        driver,
        client,
        "companion_line",
        %{"channel" => 1, "index" => 0, "last" => true},
        4,
        Jason.encode!(msg)
      )

    {frames, client} = receive_until_close(driver, client)
    assert [%{"type" => "error", "reason" => "unknown_event", "event" => "msg"}] = lines(frames)
    assert %{"t" => "companion_close", "channel" => 1} = frames |> List.last() |> elem(0)

    client = Driver.client_send(driver, client, "ping", %{}, 5)
    assert {[{%{"t" => "pong"}, <<>>}], _client} = Driver.client_receive(driver, client)
  end

  test "a phone's hello_ack says it has lists", ctx do
    {_driver, _client, ack} = ready_phone_with_ack!(ctx, hello_ack_builder: nil)
    assert ack["caps"]["lists"] == true
  end

  # -- the phone's session ------------------------------------------------------------

  defp open!(driver, client, channel, seq) do
    Driver.client_send(driver, client, "companion_open", %{"channel" => channel}, seq)
  end

  # One line to the channel, and the lines it answers with.
  defp line!(driver, client, line, seq) do
    fields = %{"channel" => 1, "index" => 0, "last" => true}

    client =
      Driver.client_send(driver, client, "companion_line", fields, seq, Jason.encode!(line))

    {frames, client} = Driver.client_receive(driver, client)
    {lines(frames), client}
  end

  defp lines(frames) do
    for {%{"t" => "companion_line"}, bytes} <- frames, do: Jason.decode!(bytes)
  end

  defp receive_until_close(driver, client, seen \\ []) when length(seen) < 10 do
    {frames, client} = Driver.client_receive(driver, client)
    seen = seen ++ frames

    if Enum.any?(frames, fn {header, _bytes} -> header["t"] == "companion_close" end),
      do: {seen, client},
      else: receive_until_close(driver, client, seen)
  end

  defp send_msg(driver, client, id, seq) do
    msg = %{
      "client_msg_id" => id,
      "profile_id" => "main",
      "text" => "what's on my list?",
      "attach_ids" => []
    }

    Driver.client_send(driver, client, "msg", msg, seq)
  end

  defp ready_phone!(ctx) do
    {driver, client, _ack} = ready_phone_with_ack!(ctx, [])
    {driver, client}
  end

  defp ready_phone_with_ack!(ctx, opts) do
    test_pid = self()
    keys = %{ctx.phone.public => @phone_id}

    session_opts =
      [
        peer: {127, 0, 0, 1},
        gateway_keypair: ctx.gateway,
        primary_epoch: 4,
        device_store: :store,
        device_registry: ctx.registry,
        desktop_peers: ctx.peers,
        desktop_peer_supervisor: ctx.peer_supervisor,
        phone_families: %{
          companion:
            {Companion,
             kind: :phone,
             endpoint: ctx.companion.endpoint,
             supervisor: ctx.tunnels,
             socket_dir: ctx.companion.socket_dir}
        },
        find_device: fn :store, key -> {:ok, row(Map.fetch!(keys, key))} end,
        update_device: fn :store, id, %{last_seen: _seen} -> {:ok, row(id)} end,
        wall_clock: fn -> @seen end,
        hello_ack_builder: fn _state -> {:ok, hello_ack()} end,
        pending_approvals: fn "main" -> [] end,
        history_head: fn "main" -> {:ok, 0} end,
        read_frontier: fn "main" -> {:ok, 0} end,
        discover: fn -> {:ok, []} end,
        iroh_candidate: fn -> :none end,
        call_caps: fn _device ->
          %{"available" => true, "min_version" => 2, "max_version" => 3, "camera" => false}
        end,
        # A phone's msg is reported to the test; everything else is routed.
        event_router: fn
          %{type: "msg"} = event, _context, _opts ->
            send(test_pid, {:routed, event})
            :ok

          event, context, router_opts ->
            EventRouter.route(event, context, router_opts)
        end,
        run_request: &Task.start(&1)
      ]
      |> Keyword.merge(opts)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    driver = Driver.start!(session_opts)

    {:ok, client} =
      Noise.initialize(:initiator, :ik,
        static_keypair: ctx.phone,
        remote_static: ctx.gateway.public
      )

    client = Driver.handshake!(driver, client)

    hello = %{
      "device_id" => @phone_id,
      "app_version" => "0.18.0",
      "last_server_seq" => 0,
      "protocol_v" => Protocol.protocol_version()
    }

    client = Driver.client_send(driver, client, "hello", hello, 1)
    assert {[{%{"t" => "hello_ack"} = ack, <<>>}], client} = Driver.client_receive(driver, client)
    {driver, client, ack}
  end

  defp row(id), do: %{device_id: id, name: "Garden phone", kind: :phone}

  defp hello_ack do
    {min_version, max_version} = Protocol.supported_version_range()

    %{
      "session_id" => "phone-session",
      "min_version" => min_version,
      "max_version" => max_version,
      "profiles" => [%{"id" => "main", "name" => "Fermix"}],
      "candidates" => [],
      "history_head_seq" => 0,
      "read_up_to_seq" => 0,
      "caps" => %{"commands" => [], "max_media_bytes" => 20_971_520, "lists" => true},
      "primary_epoch" => 4
    }
  end

  # -- the primary's companion socket and lists ----------------------------------------

  defp groceries!(ctx) do
    {:ok, _answer} =
      ChecklistRegistry.edit(
        %{
          "changes" => [
            %{
              "list" => "Groceries",
              "ops" => [%{"op" => "create"}, %{"op" => "add", "text" => "Lemons"}]
            }
          ]
        },
        @owner_turn,
        ctx.companion.checklist_opts
      )

    {:ok, [list]} = ChecklistRegistry.device_index(:independent, ctx.companion.checklist_opts)
    list.id
  end

  defp primary_companion!(suffix) do
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("phone-lists")
    repo = :"phone_lists_repo_#{suffix}"
    registry = :"phone_lists_registry_#{suffix}"
    connections = :"phone_lists_conns_#{suffix}"
    endpoint = :"phone_lists_endpoint_#{suffix}"
    socket_path = Path.join(System.tmp_dir!(), "fermix-plists-#{suffix}.sock")
    socket_dir = Path.join(dir, "mobile")
    File.mkdir_p!(socket_dir)
    File.chmod!(socket_dir, 0o700)

    on_exit(fn ->
      FermixTestSupport.SafeRm.rm_rf!(dir)
      FermixTestSupport.SafeRm.rm(socket_path)
    end)

    start_supervised!(
      {Repo, name: repo, enabled: true, database_path: Path.join(dir, "memory.db")}
    )

    start_supervised!({Registry, keys: :duplicate, name: registry}, id: registry)

    approvals =
      start_supervised!(
        {Approvals,
         name: nil,
         schedule: fn _message, _delay -> make_ref() end,
         announce: fn _profile, _card, _transport -> :ok end}
      )

    start_supervised!(
      Supervisor.child_spec({DynamicSupervisor, name: connections, strategy: :one_for_one},
        id: connections
      )
    )

    checklist_opts = [repo: repo, notifier: &ChecklistNotifier.changed(&1, registry)]

    start_supervised!(
      {Endpoint,
       name: endpoint,
       socket_path: socket_path,
       connection_supervisor: connections,
       connection_opts: [
         registry: registry,
         approvals: approvals,
         checklist_opts: checklist_opts,
         request_opts: [engine_role: %{role: :primary, primary: nil}],
         primary_epoch: fn -> {:ok, 4} end,
         status_watch: nil
       ]},
      id: endpoint
    )

    %{endpoint: endpoint, socket_dir: socket_dir, checklist_opts: checklist_opts}
  end
end
