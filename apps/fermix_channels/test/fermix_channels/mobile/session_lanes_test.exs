defmodule FermixChannels.Mobile.SessionLanesTest do
  @moduledoc """
  The lanes of a session's outbound frames on the primary (M97 §5.1), through
  the real Noise `IK` handshake and codec: each read writes the live lane
  first, drains the interactive lane ahead of every bulk frame, and writes one
  bulk frame; `seq` rises by one per frame in the order written, and an
  `event_part` run is never split.

  Every frame below is put in the carrier's mailbox while it is held, so the
  order the session writes them in is its own, never a race.
  """

  use ExUnit.Case, async: true

  alias FermixChannels.Desktop.Peer
  alias FermixChannels.Desktop.Supervisor, as: DesktopSupervisor
  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.Noise
  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Test.SessionDriver, as: Driver

  @desktop_id "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e"
  @phone_id "2a9b8c7d-6e5f-4a3b-9c2d-1e0f9a8b7c6d"
  @seen ~U[2026-10-21 08:00:00Z]
  @sha String.duplicate("a", 64)

  setup do
    suffix = System.unique_integer([:positive])
    peers = Module.concat(__MODULE__, "Peers#{suffix}")
    peer_supervisor = Module.concat(__MODULE__, "PeerSupervisor#{suffix}")

    start_supervised!(
      {DesktopSupervisor, name: nil, registry: peers, peer_supervisor: peer_supervisor}
    )

    registry =
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
      phone: Noise.generate_keypair(),
      peers: peers,
      peer_supervisor: peer_supervisor,
      registry: registry
    }
  end

  describe "a desktop's session" do
    test "writes the interactive frames queued behind a bulk chunk before it", ctx do
      {driver, client} = ready_desktop!(ctx)

      queued(driver, [
        snapshot_chunk(0),
        snapshot_chunk(1),
        manage_result("m1"),
        companion_line(3, "a chat line")
      ])

      {writes, _client} = receive_writes(driver, client, 2)

      assert types(writes) == [
               ["manage_result", "companion_line", "snapshot_chunk"],
               ["snapshot_chunk"]
             ]

      assert indexes(writes) == [[0, 0, 0], [1]]
      assert gap_free?(writes, 2)
    end

    test "drains at most 16 interactive events ahead of one bulk chunk; the rest go next", ctx do
      {driver, client} = ready_desktop!(ctx)
      lines = for n <- 1..20, do: companion_line(1, "line #{n}")
      queued(driver, [snapshot_chunk(0)] ++ lines ++ [snapshot_chunk(1)])

      {writes, _client} = receive_writes(driver, client, 6)

      assert types(writes) ==
               [List.duplicate("companion_line", 16) ++ ["snapshot_chunk"]] ++
                 List.duplicate(["companion_line"], 4) ++ [["snapshot_chunk"]]

      assert Enum.map(Enum.concat(writes), &line_text/1) |> Enum.reject(&is_nil/1) ==
               for(n <- 1..20, do: "line #{n}")

      assert gap_free?(writes, 2)
    end

    test "answers a sync once every bulk frame handed before it is written", ctx do
      {driver, client} = ready_desktop!(ctx)
      ref = make_ref()

      queued(driver, [
        snapshot_chunk(0),
        snapshot_chunk(1),
        {:mobile_sync, self(), ref},
        companion_line(2, "after the sync")
      ])

      # The line handed after the sync still goes ahead of the bulk chunks; the
      # sync is answered only after the last chunk handed before it.
      {[first], client} = receive_writes(driver, client, 1)
      assert types([first]) == [["companion_line", "snapshot_chunk"]]
      {[second], _client} = receive_writes(driver, client, 1)
      assert types([second]) == [["snapshot_chunk"]]
      assert_receive {:mobile_synced, ^ref}
    end
  end

  describe "a phone's session" do
    test "writes a call's frames before both other lanes, and text before media", ctx do
      {driver, client} = ready_phone!(ctx)

      queued(driver, [
        media_begin("r1"),
        media_chunk("r1", 0),
        notice("before the media"),
        {:mobile_call, self(), :control, call_line()}
      ])

      {writes, _client} = receive_writes(driver, client, 2)

      assert types(writes) == [
               ["call_line", "notice", "media_begin"],
               ["media_chunk"]
             ]

      assert gap_free?(writes, 2)
    end

    test "never splits an event_part run, written whole ahead of the bulk frame", ctx do
      {driver, client} = ready_phone!(ctx)
      long = String.duplicate("a long notice ", 600)
      queued(driver, [media_begin("r1"), notice(long), notice("short")])

      {[writes], _client} = receive_writes(driver, client, 1)

      assert types([writes]) == [["event_part", "event_part", "notice", "media_begin"]]

      assert Enum.map(Enum.take(writes, 2), fn {header, _bytes} ->
               {header["index"], header["count"]}
             end) == [{0, 2}, {1, 2}]

      run = writes |> Enum.take(2) |> Enum.map_join(fn {_header, bytes} -> bytes end)
      assert %{"t" => "notice", "text" => ^long} = Jason.decode!(run)
      assert gap_free?([writes], 2)
    end
  end

  # -- the carrier ---------------------------------------------------------------

  # Each message lands in the held carrier's mailbox in this order before it
  # reads any of them.
  defp queued(driver, messages) do
    hold = Driver.hold(driver)

    Enum.each(messages, fn
      %{} = event -> send(driver, {:mobile_event, event})
      message -> send(driver, message)
    end)

    Driver.release(driver, hold)
  end

  # The session's next `count` writes, each decoded.
  defp receive_writes(driver, client, count) do
    Enum.map_reduce(1..count, client, fn _n, client -> Driver.client_receive(driver, client) end)
  end

  defp types(writes),
    do:
      Enum.map(writes, fn frames -> Enum.map(frames, fn {header, _bytes} -> header["t"] end) end)

  defp indexes(writes),
    do:
      Enum.map(writes, fn frames ->
        Enum.map(frames, fn {header, _bytes} -> header["index"] end)
      end)

  defp line_text({%{"t" => "companion_line"}, bytes}), do: bytes
  defp line_text(_frame), do: nil

  # Every frame's `seq` is one past the frame written before it.
  defp gap_free?(writes, first) do
    seqs = writes |> Enum.concat() |> Enum.map(fn {header, _bytes} -> header["seq"] end)
    seqs == Enum.to_list(first..(first + length(seqs) - 1)//1)
  end

  # -- events ----------------------------------------------------------------------

  defp snapshot_chunk(index),
    do: %{"t" => "snapshot_chunk", "snapshot_id" => "s1", "index" => index, "bytes" => "bytes"}

  defp manage_result(call_id),
    do: %{
      "t" => "manage_result",
      "call_id" => call_id,
      "index" => 0,
      "last" => true,
      "bytes" => ~s({"result":{}})
    }

  defp companion_line(channel, line),
    do: %{
      "t" => "companion_line",
      "channel" => channel,
      "index" => 0,
      "last" => true,
      "bytes" => line
    }

  defp media_begin(ref),
    do: %{
      "t" => "media_begin",
      "ref" => ref,
      "server_seq" => 3,
      "kind" => "image",
      "mime" => "image/png",
      "size_bytes" => 2,
      "sha256" => @sha
    }

  defp media_chunk(ref, index),
    do: %{"t" => "media_chunk", "ref" => ref, "index" => index, "bytes" => "ab"}

  defp notice(text), do: %{"t" => "notice", "kind" => "info", "text" => text}

  defp call_line,
    do: %{
      "t" => "call_line",
      "call_id" => "call-1",
      "bytes" => ~s({"type":"state","state":"speaking"})
    }

  # -- sessions --------------------------------------------------------------------

  defp ready_desktop!(ctx) do
    supervisor = ctx.peer_supervisor

    ready!(ctx, ctx.desktop, @desktop_id,
      start_desktop_peer: fn opts -> Peer.start(supervisor, Keyword.put(opts, :families, %{})) end,
      record_engine_version: fn _id, _version, _at -> :ok end
    )
  end

  defp ready_phone!(ctx), do: ready!(ctx, ctx.phone, @phone_id, [])

  # A paired device's session through IK and hello, its hello_ack read.
  defp ready!(ctx, keypair, device_id, opts) do
    keys = %{ctx.desktop.public => @desktop_id, ctx.phone.public => @phone_id}

    driver =
      Driver.start!(
        [
          peer: {127, 0, 0, 1},
          gateway_keypair: ctx.gateway,
          primary_epoch: 4,
          device_store: :store,
          device_registry: ctx.registry,
          desktop_peers: ctx.peers,
          desktop_peer_supervisor: ctx.peer_supervisor,
          find_device: fn :store, key -> {:ok, row(Map.fetch!(keys, key))} end,
          update_device: fn :store, id, %{last_seen: _seen} -> {:ok, row(id)} end,
          wall_clock: fn -> @seen end,
          hello_ack_builder: fn _state -> {:ok, hello_ack()} end,
          pending_approvals: fn "main" -> [] end
        ] ++ opts
      )

    {:ok, client} =
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

  defp row(@desktop_id), do: %{device_id: @desktop_id, name: "Studio Mac", kind: :desktop}
  defp row(id), do: %{device_id: id, name: "Garden phone", kind: :phone}

  defp hello_ack do
    {min_version, max_version} = Protocol.supported_version_range()

    %{
      "session_id" => "lanes-session",
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
