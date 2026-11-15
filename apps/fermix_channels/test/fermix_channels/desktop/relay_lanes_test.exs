defmodule FermixChannels.Desktop.RelayLanesTest do
  @moduledoc """
  The lanes of a desktop's link, on the desktop (M97 §5.1), against the
  primary's real responder: the relay keeps the session and hands each family
  of the primary's events to a process of its own, so a backup being written
  no longer delays a chat line or a settings answer; and it writes its own
  frames by lane, one at a time, a frame the primary sends interactive going
  before the next bulk one, at the rail's next `seq`.

  The snapshot store is a held stand-in under the store's own name, so the
  order of what happens is the test's, never a race; the relay's writes are
  held behind a gate the same way.

  Sync: the stand-in takes the snapshot store's (global) name, and the bounds'
  refusals are read from the log.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixChannels.Desktop.Manage
  alias FermixChannels.Desktop.Peer
  alias FermixChannels.Desktop.Relay
  alias FermixChannels.Desktop.SnapshotStore
  alias FermixChannels.Desktop.SnapshotTarget
  alias FermixChannels.Mobile.Rail
  alias FermixChannels.Test.DesktopRail

  @arrival_ms 10_000
  @mib 1_024 * 1_024

  # A family of the primary, reporting each event the desktop sends it.
  defmodule CaptureFamily do
    @moduledoc false
    @behaviour FermixChannels.Desktop.Family

    @impl true
    def init(context), do: {:ok, Keyword.fetch!(context.options, :test)}

    @impl true
    def handle_event(type, fields, payload, test) do
      send(test, {:primary_got, type, fields, byte_size(payload)})
      {:ok, test}
    end

    @impl true
    def handle_info(_message, test), do: {:ok, test}

    @impl true
    def terminate(_reason, _test), do: :ok
  end

  setup do
    test = self()
    tasks = start_supervised!({Task.Supervisor, []}, id: :lanes_tasks)

    serve = fn frame, _device_id ->
      %{"request_id" => id} = Jason.decode!(frame)
      %{"request_id" => id, "result" => %{"answered" => id}}
    end

    primary =
      DesktopRail.primary!(
        families: %{
          companion: {CaptureFamily, test: test},
          snapshots: {CaptureFamily, test: test},
          manage: {Manage, serve: serve, task_supervisor: tasks}
        }
      )

    %{primary: primary, root: DesktopRail.desktop_home!(primary)}
  end

  test "a snapshot being written delays neither a settings answer nor a chat line", ctx do
    store = start_store!()
    relay = DesktopRail.start_relay!(ctx.root, ctx.primary)
    DesktopRail.await_connected(relay)
    {:ok, channel, _relay} = Relay.open_channel(relay)

    # The store takes the snapshot's start and holds on it, as a slow disk
    # does; its first chunk waits behind it.
    to_desktop(ctx, snapshot_begin("s1"))
    assert_receive {:store_got, "snapshot_begin"}, @arrival_ms
    to_desktop(ctx, snapshot_chunk("s1", 0), "bytes")

    call = Task.async(fn -> Relay.forward(relay, request("r-held")) end)
    to_desktop(ctx, %{"t" => "companion_line", "channel" => channel}, "a chat line")

    assert_receive {:relay_line, ^channel, "a chat line"}, @arrival_ms
    assert {:ok, %{"answered" => _id}} = Task.await(call, @arrival_ms)

    send(store, :release)
    assert_receive {:store_got, "snapshot_chunk"}, @arrival_ms
  end

  test "a store that dies takes the session down with nothing; it is said once", ctx do
    store = start_store!()
    relay = DesktopRail.start_relay!(ctx.root, ctx.primary)
    pid = GenServer.whereis(relay)
    DesktopRail.await_connected(relay)
    {:ok, channel, _relay} = Relay.open_channel(relay)

    ref = Process.monitor(store)
    Process.exit(store, :kill)
    assert_receive {:DOWN, ^ref, :process, ^store, :killed}

    log =
      capture_log(fn ->
        to_desktop(ctx, snapshot_begin("s2"))
        to_desktop(ctx, snapshot_chunk("s2", 0), "bytes")
        to_desktop(ctx, snapshot_chunk("s2", 1), "bytes")
        probe(ctx, channel)
      end)

    assert count(log, "snapshots are not taken here") == 1
    assert %{connected: true} = Relay.status(relay)
    assert GenServer.whereis(relay) == pid
    assert {:ok, %{"answered" => _id}} = Relay.forward(relay, request("r-after"))

    # A store running again takes the next snapshot, and that is said once.
    _store = start_store!()

    log =
      capture_log(fn ->
        to_desktop(ctx, snapshot_begin("s3"))
        assert_receive {:store_got, "snapshot_begin"}, @arrival_ms
        # The relay says so as it hands the begin over; its next answer is after.
        _status = Relay.status(relay)
      end)

    assert count(log, "snapshots are taken again; 3 dropped") == 1
  end

  test "past its bound a copy is refused, its later frames dropped, said once each way", ctx do
    store = start_store!()
    relay = DesktopRail.start_relay!(ctx.root, ctx.primary)
    DesktopRail.await_connected(relay)
    {:ok, channel, _relay} = Relay.open_channel(relay)

    to_desktop(ctx, snapshot_begin("s4"))
    assert_receive {:store_got, "snapshot_begin"}, @arrival_ms

    # 256 chunks fill the store's hand-off; the next three and the end are
    # dropped, and the store is told to refuse the copy.
    log =
      capture_log(fn ->
        for index <- 0..258, do: to_desktop(ctx, snapshot_chunk("s4", index), "bytes")
        to_desktop(ctx, %{"t" => "snapshot_end", "snapshot_id" => "s4"})
        probe(ctx, channel)
      end)

    assert count(log, "the snapshot copy s4 outran this computer's disk") == 1
    assert count(log, "snapshots are taken again; 4 dropped") == 1

    send(store, :release)

    for index <- 0..255 do
      assert_receive {:store_got, "snapshot_chunk", %{"index" => ^index}}, @arrival_ms
    end

    assert_receive {:store_refused, "s4", "write_failed"}, @arrival_ms
    refute_received {:store_got, "snapshot_end", _fields}
  end

  test "an interactive frame is written before the next bulk one, at the next seq", ctx do
    {gate, write} = gate()
    relay = DesktopRail.start_relay!(ctx.root, ctx.primary, write: write)
    DesktopRail.await_connected(relay)

    # The first answer is taken by the writer and held there; a second waits
    # in the bulk lane, and a settings call comes after both.
    :ok = flush_writes()
    :ok = close(gate)
    first = Task.async(fn -> Relay.send_event(relay, refused("s5")) end)
    assert_receive {:writer_held, "snapshot_refused"}, @arrival_ms
    second = Task.async(fn -> Relay.send_event(relay, refused("s6")) end)
    call = Task.async(fn -> Relay.forward(relay, request("r-first")) end)
    await_queued(relay, 2)
    :ok = open(gate)

    assert :ok = Task.await(first, @arrival_ms)
    assert :ok = Task.await(second, @arrival_ms)
    assert {:ok, %{"answered" => _id}} = Task.await(call, @arrival_ms)

    # Written in this order, each at the rail's next `seq`.
    assert_receive {:writing, "snapshot_refused", %{"snapshot_id" => "s5"}}
    assert_receive {:writing, type, _fields}
    assert type == "manage"
    assert_receive {:writing, "snapshot_refused", %{"snapshot_id" => "s6"}}

    # The primary's session refuses any frame out of `seq` order, closing the
    # session; it took each, and stayed up.
    assert_receive {:primary_got, "snapshot_refused", %{"snapshot_id" => "s5"}, 0}
    assert_receive {:primary_got, "snapshot_refused", %{"snapshot_id" => "s6"}, 0}
    assert %{connected: true} = Relay.status(relay)
  end

  test "a full interactive lane refuses: a chat ends, a call is busy, said once each way",
       ctx do
    {gate, write} = gate()
    relay = DesktopRail.start_relay!(ctx.root, ctx.primary, write: write)
    DesktopRail.await_connected(relay)
    {:ok, channel, _relay} = Relay.open_channel(relay)
    line = :binary.copy("l", @mib)

    log =
      capture_log(fn ->
        :ok = close(gate)
        # 16 MiB of a chat's lines fill the lane behind the frame held in the
        # writer; the seventeenth line does not fit, and its chat ends.
        for _n <- 1..17, do: Relay.send_line(relay, channel, line)
        assert_receive {:relay_down, ^channel, sentence}, @arrival_ms
        assert sentence =~ "too busy"

        big = %{request("r-busy") | params: %{"blob" => :binary.copy("b", 900_000)}}

        assert {:error, :busy, %{"operation" => "forwarded management"}} =
                 Relay.forward(relay, big)

        # Once the lane has drained, it is said once; the primary takes the
        # sixteen lines that fitted, whole.
        :ok = open(gate)

        for _n <- 1..16,
            do: assert_receive({:primary_got, "companion_line", _fields, @mib}, @arrival_ms)
      end)

    assert count(log, "the interactive lane is full") == 1
    assert count(log, "the interactive lane takes frames again; 2 refused") == 1
    assert {:ok, %{"answered" => _id}} = Relay.forward(relay, request("r-room"))
    assert %{connected: true} = Relay.status(relay)
  end

  test "a blob that outruns the media process is dropped, said once each way", ctx do
    media = start_held!()
    relay = DesktopRail.start_relay!(ctx.root, ctx.primary, families: %{media: media})
    DesktopRail.await_connected(relay)
    {:ok, channel, _relay} = Relay.open_channel(relay)
    ref = String.duplicate("b", 64)

    to_desktop(ctx, media_begin(ref))
    assert_receive {:held_got, {:begin, _relay, %{"ref" => ^ref}, false, _max}}, @arrival_ms

    # 256 chunks fill the hand-off; the next two and the end are dropped, and
    # the process is told to let the blob go.
    log =
      capture_log(fn ->
        for index <- 0..257, do: to_desktop(ctx, media_chunk(ref, index), "bytes")
        to_desktop(ctx, %{"t" => "media_end", "ref" => ref, "sha256" => ref})
        probe(ctx, channel)
      end)

    assert count(log, "the blob #{ref} outran this computer's disk") == 1
    assert count(log, "media frames are taken again; 3 dropped") == 1

    send(media, :release)

    for index <- 0..255,
        do: assert_receive({:held_got, {:chunk, ^ref, ^index, _bytes}}, @arrival_ms)

    assert_receive {:held_got, {:drop, ^ref}}, @arrival_ms
    refute_received {:held_got, {:finish, ^ref}}

    # The next blob is handed as usual.
    next = String.duplicate("c", 64)
    to_desktop(ctx, media_begin(next))
    assert_receive {:held_got, {:begin, _relay, %{"ref" => ^next}, false, _max}}, @arrival_ms
  end

  test "a sign-in forward past its bound drops its events, said once each way", ctx do
    loopback = start_held!()
    relay = DesktopRail.start_relay!(ctx.root, ctx.primary, families: %{loopback: loopback})
    DesktopRail.await_connected(relay)
    {:ok, channel, _relay} = Relay.open_channel(relay)

    close = fn n -> %{"t" => "loopback_close", "loopback_id" => "lb-#{n}"} end
    to_desktop(ctx, close.(0))
    assert_receive {:held_got, {:event, "loopback_close", %{"loopback_id" => "lb-0"}, <<>>}}

    # 64 wait behind the one held; the next two are dropped.
    log =
      capture_log(fn ->
        for n <- 1..66, do: to_desktop(ctx, close.(n))
        probe(ctx, channel)

        # Once the 64 waiting are taken, the next is handed again.
        send(loopback, :release)

        for n <- 1..64 do
          id = "lb-#{n}"
          assert_receive {:held_got, {:event, "loopback_close", %{"loopback_id" => ^id}, _}}
        end

        to_desktop(ctx, close.(67))

        assert_receive {:held_got, {:event, "loopback_close", %{"loopback_id" => "lb-67"}, _}},
                       @arrival_ms

        # The relay says so as it hands the event over; its next answer is after.
        _status = Relay.status(relay)
      end)

    assert count(log, "the sign-in forward is behind (64 events waiting)") == 1
    assert count(log, "sign-in forwards are taken again; 2 dropped") == 1
  end

  test "a chat whose app leaves 256 lines unread ends, and the primary is told", ctx do
    relay = DesktopRail.start_relay!(ctx.root, ctx.primary)
    DesktopRail.await_connected(relay)

    # This test is the channel's tunnel, and reads nothing until the end.
    {:ok, channel, _relay} = Relay.open_channel(relay)
    assert_receive {:primary_got, "companion_open", %{"channel" => ^channel}, 0}

    log =
      capture_log(fn ->
        for n <- 1..300,
            do: to_desktop(ctx, %{"t" => "companion_line", "channel" => channel}, "line #{n}")

        assert_receive {:primary_got, "companion_close", %{"channel" => ^channel}, 0}, @arrival_ms
      end)

    assert_received {:relay_down, ^channel, sentence}
    assert sentence =~ "fell too far behind"
    assert count(log, "channel #{channel}'s app left 256 lines unread") == 1
    assert %{connected: true} = Relay.status(relay)
  end

  # -- a family's held process --------------------------------------------------------

  # A family's process that tells the test each message it takes, and holds
  # on the first until `:release`.
  defp start_held! do
    test = self()
    held = spawn(fn -> held_loop(test, :held) end)

    on_exit(fn ->
      ref = Process.monitor(held)
      Process.exit(held, :kill)

      receive do
        {:DOWN, ^ref, :process, ^held, _reason} -> :ok
      end
    end)

    held
  end

  defp held_loop(test, mode) do
    receive do
      {:"$gen_cast", message} ->
        send(test, {:held_got, message})
        held_loop(test, hold(mode))
    end
  end

  defp hold(:held) do
    receive do
      :release -> :free
    end
  end

  defp hold(:free), do: :free

  # -- the store ---------------------------------------------------------------------

  # A stand-in for the desktop's snapshot store under its own name: it tells
  # the test each event and holds on the first until `:release`.
  defp start_store! do
    test = self()
    store = spawn(fn -> store_loop(test, :held) end)
    true = Process.register(store, SnapshotStore)

    on_exit(fn ->
      ref = Process.monitor(store)
      Process.exit(store, :kill)

      receive do
        {:DOWN, ^ref, :process, ^store, _reason} -> :ok
      end
    end)

    store
  end

  defp store_loop(test, mode) do
    receive do
      {:"$gen_call", from, {type, fields, _payload}} ->
        mode = took(test, type, fields, mode)
        GenServer.reply(from, :ok)
        store_loop(test, mode)

      {:"$gen_cast", {:event, type, fields, _payload}} ->
        store_loop(test, took(test, type, fields, mode))

      {:"$gen_cast", {:refuse, id, reason}} ->
        send(test, {:store_refused, id, reason})
        store_loop(test, mode)
    end
  end

  defp took(test, type, fields, mode) do
    send(test, {:store_got, type})
    send(test, {:store_got, type, fields})

    if mode == :held do
      receive do
        :release -> :free
      end
    else
      mode
    end
  end

  # -- the writer's gate ------------------------------------------------------------

  # A write the gate holds tells the test, and waits for the gate to open.
  defp gate do
    test = self()
    {:ok, gate} = Agent.start_link(fn -> %{open: true, held: []} end)

    write = fn rail, type, fields, bytes ->
      if Agent.get(gate, & &1.open) == false do
        writer = self()
        Agent.update(gate, &%{&1 | held: [writer | &1.held]})
        send(test, {:writer_held, type})

        receive do
          :gate_open -> :ok
        end
      end

      send(test, {:writing, type, fields})
      Rail.send_event(rail, type, fields, bytes)
    end

    {gate, write}
  end

  defp close(gate), do: Agent.update(gate, &%{&1 | open: false})

  # The writes so far (the hello): the session is up, so each is told already.
  defp flush_writes do
    receive do
      {:writing, _type, _fields} -> flush_writes()
    after
      0 -> :ok
    end
  end

  defp open(gate) do
    held = Agent.get_and_update(gate, &{&1.held, %{open: true, held: []}})
    Enum.each(held, &send(&1, :gate_open))
  end

  # The relay's frames queued behind the one held in its writer.
  defp await_queued(relay, count, attempts \\ 1_000) do
    queued = relay |> :sys.get_state() |> Map.fetch!(:outbox) |> Relay.Outbox.size()

    cond do
      queued >= count ->
        :ok

      attempts == 0 ->
        flunk("the relay queued #{queued} frames, not #{count}")

      true ->
        # sleep: polls the relay's queue, which announces nothing
        Process.sleep(10)
        await_queued(relay, count, attempts - 1)
    end
  end

  # -- the primary's side -----------------------------------------------------------

  defp to_desktop(ctx, event, payload \\ <<>>) do
    :ok = Peer.send(DesktopRail.device_id(), event, payload, registry: ctx.primary.peers)
  end

  # Once the primary's session has written everything handed to it (its
  # bulk frames go after interactive ones), a line it writes after reaches
  # this test (the channel's tunnel) after the relay took all of it: the
  # relay takes the primary's frames in the order they come.
  defp probe(ctx, channel) do
    {:ok, _peer, %{session: session}} = Peer.lookup(ctx.primary.peers, DesktopRail.device_id())
    :ok = SnapshotTarget.sync_session(session)
    to_desktop(ctx, %{"t" => "companion_line", "channel" => channel}, "probe")
    assert_receive {:relay_line, ^channel, "probe"}, @arrival_ms
  end

  defp snapshot_begin(id),
    do: %{
      "t" => "snapshot_begin",
      "snapshot_id" => id,
      "name" => "20261110T090000Z-e3.fxsnap",
      "size_bytes" => 1_000,
      "sha256" => String.duplicate("0", 64)
    }

  defp media_begin(ref),
    do: %{
      "t" => "media_begin",
      "ref" => ref,
      "server_seq" => 4,
      "kind" => "image",
      "mime" => "image/png",
      "size_bytes" => 1_000,
      "sha256" => ref
    }

  defp media_chunk(ref, index), do: %{"t" => "media_chunk", "ref" => ref, "index" => index}

  defp snapshot_chunk(id, index),
    do: %{"t" => "snapshot_chunk", "snapshot_id" => id, "index" => index}

  defp refused(id),
    do: %{"t" => "snapshot_refused", "snapshot_id" => id, "reason" => "write_failed"}

  defp request(id),
    do: %{request_id: id, protocol_version: 2, method: "cues.status", params: %{}}

  defp count(log, text), do: log |> String.split(text) |> length() |> Kernel.-(1)
end
