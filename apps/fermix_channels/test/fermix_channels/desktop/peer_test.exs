defmodule FermixChannels.Desktop.PeerTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Desktop.Peer
  alias FermixChannels.Desktop.Supervisor, as: DesktopSupervisor
  alias FermixChannels.Mobile.Chunks

  @device "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e"
  @since ~U[2026-10-21 08:00:00Z]

  # Tells the session (a forwarder to the test) everything it is handed.
  defmodule RecordingFamily do
    @moduledoc false
    @behaviour FermixChannels.Desktop.Family

    @impl true
    def init(context), do: {:ok, context}

    @impl true
    def handle_event("companion_close", %{"channel" => 9}, _payload, context),
      do: {:error, :channel_not_open, context}

    def handle_event(type, fields, payload, context) do
      send(context.session, {:family_event, type, fields, payload})
      {:ok, context}
    end

    @impl true
    def handle_info(message, context) do
      send(context.session, {:family_info, message})
      {:ok, context}
    end

    @impl true
    def terminate(reason, context) do
      send(context.session, {:family_terminated, reason})
      :ok
    end
  end

  @families %{
    companion: RecordingFamily,
    manage: RecordingFamily,
    loopback: RecordingFamily
  }

  setup do
    suffix = System.unique_integer([:positive])
    registry = Module.concat(__MODULE__, "Peers#{suffix}")
    supervisor = Module.concat(__MODULE__, "PeerSupervisor#{suffix}")

    start_supervised!(
      {DesktopSupervisor, name: nil, registry: registry, peer_supervisor: supervisor}
    )

    %{registry: registry, supervisor: supervisor}
  end

  test "a peer registers its desktop with when it connected, and ends with its session", ctx do
    session = forwarder()
    peer = start_peer!(ctx, session)

    assert [%{device_id: @device, connected_since: @since}] = Peer.connected(ctx.registry)
    assert {:ok, ^peer, %{session: ^session}} = Peer.lookup(ctx.registry, @device)

    ref = Process.monitor(peer)
    Process.unlink(session)
    Process.exit(session, :kill)
    assert_receive {:DOWN, ^ref, :process, ^peer, :normal}
    assert Peer.connected(ctx.registry) == []
  end

  test "an event of a family this primary does not serve is unsupported, and the peer goes on",
       ctx do
    peer = start_peer!(ctx, forwarder(), families: %{})

    assert {:error, {:unsupported_event, "manage"}} =
             Peer.deliver(peer, event("manage", manage_fields(0, true), "{}"))

    assert {:error, {:unsupported_event, "companion_open"}} =
             Peer.deliver(peer, event("companion_open", %{"channel" => 1}))

    assert Process.alive?(peer)
  end

  test "a chunked payload reaches its family whole, one per key, and ends at its last", ctx do
    peer = start_peer!(ctx, forwarder())
    line = :crypto.strong_rand_bytes(130_000)
    other = "a second channel's line\n"

    [{0, false, a}, {1, false, b}, {2, true, c}] = Chunks.split(line)
    assert :ok = Peer.deliver(peer, event("companion_line", line_fields(1, 0, false), a))
    assert :ok = Peer.deliver(peer, event("companion_line", line_fields(2, 0, true), other))
    assert_receive {:family_event, "companion_line", %{"channel" => 2}, ^other}
    assert :ok = Peer.deliver(peer, event("companion_line", line_fields(1, 1, false), b))
    refute_received {:family_event, "companion_line", %{"channel" => 1}, _partial}
    assert :ok = Peer.deliver(peer, event("companion_line", line_fields(1, 2, true), c))

    assert_receive {:family_event, "companion_line", fields, ^line}
    assert fields == %{"channel" => 1}

    # The channel's next line starts again at index 0.
    assert :ok = Peer.deliver(peer, event("companion_line", line_fields(1, 0, true), "next\n"))
    assert_receive {:family_event, "companion_line", %{"channel" => 1}, "next\n"}
  end

  test "a gap, a repeat, a changed header or a payload past its bound closes the session",
       ctx do
    peer = start_peer!(ctx, forwarder())

    assert {:close, {:chunk_gap, 0, 1}} =
             Peer.deliver(peer, event("companion_line", line_fields(3, 1, true), "x"))

    assert :ok = Peer.deliver(peer, event("manage", manage_fields(0, false), "{"))

    assert {:close, {:chunk_repeat, 1, 0}} =
             Peer.deliver(peer, event("manage", manage_fields(0, true), "}"))

    assert :ok = Peer.deliver(peer, event("manage", manage_fields(0, false), "{"))
    changed = %{manage_fields(1, true) | "method" => "settings.apply"}

    assert {:close, {:chunk_header_changed, "manage"}} =
             Peer.deliver(peer, event("manage", changed, "}"))

    # A manage payload is at most 1 MiB: the frame that takes it past is refused.
    frame = :binary.copy("a", 60 * 1_024)

    for index <- 0..16 do
      assert :ok =
               Peer.deliver(peer, event("manage", manage_fields(index, false, "call-2"), frame))
    end

    assert {:close, {:chunk_payload_too_large, 1_105_920, 1_048_576}} =
             Peer.deliver(peer, event("manage", manage_fields(17, false, "call-2"), frame))
  end

  test "more than 32 payloads open at once closes the session", ctx do
    peer = start_peer!(ctx, forwarder())

    for n <- 1..32 do
      assert :ok = Peer.deliver(peer, event("manage", manage_fields(0, false, "call-#{n}"), "{"))
    end

    assert {:close, {:too_many_open_payloads, 32}} =
             Peer.deliver(peer, event("manage", manage_fields(0, false, "call-33"), "{"))
  end

  test "the bytes held across open payloads are bounded by the budget", ctx do
    peer = start_peer!(ctx, forwarder(), open_bytes_budget: 200)
    line = :binary.copy("a", 60)

    for channel <- 1..3 do
      assert :ok =
               Peer.deliver(peer, event("companion_line", line_fields(channel, 0, false), line))
    end

    assert {:close, {:open_payload_bytes, 200}} =
             Peer.deliver(peer, event("companion_line", line_fields(4, 0, false), line))
  end

  test "an event that is not chunked reaches its family as it came, and a refusal is answered",
       ctx do
    peer = start_peer!(ctx, forwarder())

    request = %{
      "loopback_id" => "lb-1",
      "request_id" => "rq-1",
      "method" => "POST",
      "target" => "/token",
      "headers" => [["content-type", "application/x-www-form-urlencoded"]]
    }

    assert :ok = Peer.deliver(peer, event("loopback_request", request, "code=abc"))
    assert_receive {:family_event, "loopback_request", ^request, "code=abc"}

    assert {:error, :channel_not_open} =
             Peer.deliver(peer, event("companion_close", %{"channel" => 9}))
  end

  test "send/4 cuts a payload into frames, checks every one, and hands them to the session",
       ctx do
    session = forwarder()
    start_peer!(ctx, session)
    payload = :crypto.strong_rand_bytes(130_000)
    opts = [registry: ctx.registry]

    assert :ok =
             Peer.send(@device, %{"t" => "manage_result", "call_id" => "call-1"}, payload, opts)

    frames =
      for index <- 0..2 do
        assert_receive {:mobile_event, %{"t" => "manage_result", "index" => ^index} = frame}
        frame
      end

    assert Enum.map(frames, & &1["last"]) == [false, false, true]
    assert frames |> Enum.map(& &1["bytes"]) |> IO.iodata_to_binary() == payload

    assert :ok =
             Peer.send(@device, %{"t" => "loopback_close", "loopback_id" => "lb-1"}, <<>>, opts)

    assert_receive {:mobile_event, %{"t" => "loopback_close", "loopback_id" => "lb-1"}}

    assert {:error, {:not_for_desktop, "text_done"}} =
             Peer.send(@device, %{"t" => "text_done"}, <<>>, opts)

    assert {:error, {:payload_too_large, "manage_result", 4_194_305, 4_194_304}} =
             Peer.send(@device, manage_result_header(), :binary.copy("a", 4_194_305), opts)

    assert {:error, {:invalid_event, "manage_result", {:invalid_field, "call_id"}}} =
             Peer.send(@device, %{"t" => "manage_result", "call_id" => ""}, "{}", opts)

    assert {:error, {:reserved_field, "manage_result"}} =
             Peer.send(
               @device,
               %{"t" => "manage_result", "call_id" => "c", "index" => 0},
               "{}",
               opts
             )

    assert {:error, :not_connected} =
             Peer.send("0d8f7e6a-5b4c-4d3e-8f2a-1b0c9d8e7f6a", manage_result_header(), "{}", opts)

    refute_received {:mobile_event, _frame}
  end

  test "tell/4 reaches a family's own messages", ctx do
    start_peer!(ctx, forwarder())
    assert :ok = Peer.tell(@device, :loopback, {:await, "rq-1"}, registry: ctx.registry)
    assert_receive {:family_info, {:await, "rq-1"}}
  end

  test "a newer session of the same desktop replaces the older peer", ctx do
    older_session = forwarder()
    older = start_peer!(ctx, older_session)
    ref = Process.monitor(older)

    newer_session = forwarder()
    newer = start_peer!(ctx, newer_session, connected_since: ~U[2026-10-21 09:30:00Z])

    assert_receive {:DOWN, ^ref, :process, ^older, :replaced}
    assert_receive {:family_terminated, :replaced}
    assert {:ok, ^newer, %{session: ^newer_session}} = Peer.lookup(ctx.registry, @device)
    assert [%{connected_since: ~U[2026-10-21 09:30:00Z]}] = Peer.connected(ctx.registry)
  end

  test "every desktop-family event names one of the families" do
    for {type, family} <- Peer.event_families() do
      assert family in Peer.family_names(), type
      assert Peer.family_event?(type)
    end

    refute Peer.family_event?("hello")
    refute Peer.family_event?("msg")
  end

  defp start_peer!(ctx, session, opts \\ []) do
    opts =
      Keyword.merge(
        [
          device_id: @device,
          session: session,
          registry: ctx.registry,
          connected_since: @since,
          families: @families
        ],
        opts
      )

    {:ok, peer} = Peer.start(ctx.supervisor, opts)
    peer
  end

  # A stand-in for the desktop's session: whatever reaches it reaches the test.
  defp forwarder do
    test = self()
    spawn_link(fn -> forward(test) end)
  end

  defp forward(test) do
    receive do
      message ->
        send(test, message)
        forward(test)
    end
  end

  defp event(type, fields, bytes \\ <<>>), do: %{type: type, payload: fields, bytes: bytes}

  defp line_fields(channel, index, last),
    do: %{"channel" => channel, "index" => index, "last" => last}

  defp manage_fields(index, last, call_id \\ "call-1") do
    %{
      "call_id" => call_id,
      "method" => "settings.get",
      "protocol_version" => 2,
      "index" => index,
      "last" => last
    }
  end

  defp manage_result_header, do: %{"t" => "manage_result", "call_id" => "call-1"}
end
