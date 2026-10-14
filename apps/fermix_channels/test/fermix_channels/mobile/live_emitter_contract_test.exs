defmodule FermixChannels.Mobile.LiveEmitterContractTest do
  @moduledoc """
  What the daemon's own emitters put on the phone's wire, validated against
  the schema a phone app vendors (`fermix_core/priv/mobile/protocol.schema.json`).

  The golden fixtures prove the schema and the codec agree on hand-written
  examples. This proves the events the daemon builds (a turn's output, the
  channel adapter's events, rows and history pages read from a real timeline,
  approvals and their re-send, the socket's own replies and refusals) are ones
  a phone validating against the export accepts. Each is encoded as the socket
  encodes it, an `event_part` run is reassembled as a phone reassembles it,
  and none may carry a null anywhere.
  """

  # The channel adapter reads its event sink, store and approvals from the
  # application environment, so this module sets and restores them.
  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Mobile
  alias FermixChannels.Companion.Approvals
  alias FermixChannels.Companion.Output
  alias FermixChannels.Mobile.EventRouter
  alias FermixChannels.Mobile.MediaStore
  alias FermixChannels.Mobile.PairManager
  alias FermixChannels.Mobile.Protocol
  alias FermixChannels.Mobile.SocketHandler
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.WireSchema

  @schema_path Application.app_dir(:fermix_core, "priv/mobile/protocol.schema.json")
  @repo :mobile_live_emitter_test_repo
  @device "device-1"
  @context %{transport: :mobile, authenticated_device_id: "device-1"}
  @env_keys ~w(mobile_event_sink mobile_store companion_approvals mobile_push_launcher
               mobile_media_resolver)a

  # The timeline on this module's repo.
  defmodule RepoTimeline do
    alias FermixCore.Companion.Timeline

    @opts [repo: :mobile_live_emitter_test_repo]

    def append(p, attrs, o), do: Timeline.append(p, attrs, o ++ @opts)
    def history_page(p, o), do: Timeline.history_page(p, o ++ @opts)

    def attach_link_preview(p, seq, preview, o),
      do: Timeline.attach_link_preview(p, seq, preview, o ++ @opts)

    def advance_read_frontier(p, seq, o), do: Timeline.advance_read_frontier(p, seq, o ++ @opts)
  end

  # A claim the request path makes: answered as the durable store would.
  defmodule ClaimStore do
    def claim_client_request(_profile, "dup-" <> _rest = id, _type, _payload, _opts),
      do: {:ok, {:duplicate, %{client_msg_id: id, result_server_seq: 14}}}

    def claim_client_request(_profile, id, _type, _payload, _opts),
      do: {:ok, {:claimed, %{client_msg_id: id, result_server_seq: nil}}}
  end

  defmodule SettledCoordinator do
    def acquire(_server, _profile, _client_id, _opts), do: {:ok, {:completed, %{}}}
  end

  setup_all do
    %{schema: @schema_path |> File.read!() |> Jason.decode!()}
  end

  setup do
    test_pid = self()
    previous = Enum.map(@env_keys, &{&1, Application.fetch_env(:fermix_channels, &1)})
    on_exit(fn -> Enum.each(previous, &restore_env/1) end)

    dir = SafeRm.make_tmp_dir!("mobile-live-emitter")
    on_exit(fn -> SafeRm.rm_rf!(dir) end)

    start_supervised!(
      {Repo, name: @repo, enabled: true, database_path: Path.join(dir, "memory.db")}
    )

    Application.put_env(:fermix_channels, :mobile_event_sink, fn profile, event ->
      send(test_pid, {:phone_event, profile, event})
      :ok
    end)

    Application.put_env(:fermix_channels, :mobile_store, RepoTimeline)
    Application.put_env(:fermix_channels, :mobile_push_launcher, fn _task -> :ok end)
    %{dir: dir, sink: fn target, event -> send(test_pid, {:sink, target, event}) && :ok end}
  end

  test "a turn's output is what the phone's schema accepts", %{schema: schema} do
    huge = {:tool_failed, String.duplicate("é", 2_000), Enum.to_list(1..500)}

    events = [
      Output.turn_started("main", "turn-client-1", "client-1"),
      Output.text_delta("turn-client-1", "Hel"),
      Output.text_done("turn-client-1", 14, "Hello"),
      Output.tool_event("turn-client-1", {:tool_start, "web_search"}),
      Output.tool_event("turn-client-1", {:tool_finish, "web_search", huge}),
      Output.tool_event("turn-client-1", {:something, :else}),
      Output.turn_error("turn-client-1", :cancelled),
      Output.turn_error("turn-client-1", {:queue_unavailable, huge}),
      Output.approval(%{kind: :sandbox, text: "Allow?", token: "TOKEN", detail: "ls ~"}),
      Output.approval(%{kind: :soul, text: "Apply?", token: "TOKEN"}),
      Output.approval_resolved(:sandbox, "TOKEN", :denied)
    ]

    for event <- events, do: assert_on_the_wire!(event, schema)
  end

  test "rows, link previews and history pages from a real timeline", %{schema: schema} = ctx do
    rows = seed_rows!()
    photo = hd(rows)

    Mobile.schedule_unfurl("main", photo.server_seq, "see https://example.com",
      unfurl: fn _text, _thumbnail -> {:ok, unfurled_previews(), []} end,
      unfurl_launcher: fn task -> task.() && :ok end,
      event_sink: ctx.sink,
      store: RepoTimeline
    )

    previews = received_sink_events("link_preview")
    assert length(previews) == 2
    for preview <- previews, do: assert_on_the_wire!(preview, schema)

    for row <- rows, do: assert_on_the_wire!(Output.row("main", row), schema)

    [page] = route!(%{type: "history_pull", payload: history_pull(0)}, ctx)
    [header] = assert_on_the_wire!(page, schema)
    assert [%{"link_previews" => [_first, _second]}, reply, delivery] = header["messages"]
    assert reply["metadata"] == %{"turn_id" => "turn-mac-1"}
    refute Map.has_key?(delivery, "metadata")

    [empty] =
      route!(%{type: "history_pull", payload: history_pull(18_446_744_073_709_551_615)}, ctx)

    assert [%{"messages" => [], "next_after_seq" => 18_446_744_073_709_551_615}] =
             assert_on_the_wire!(empty, schema)

    payload = %{"profile_id" => "main", "read_up_to_seq" => 18_446_744_073_709_551_615}
    [read_state] = route!(%{type: "read_state", payload: payload}, ctx)
    assert [%{"read_up_to_seq" => head}] = assert_on_the_wire!(read_state, schema)
    assert head == List.last(rows).server_seq
  end

  test "a page past the header cap is an event_part run, and a row past 1 MiB is cut",
       %{schema: schema} = ctx do
    long = String.duplicate("long history row ", 2_000)
    for _index <- 1..12, do: {:ok, _row} = RepoTimeline.append("main", assistant(long), [])

    [page] = route!(%{type: "history_pull", payload: history_pull(0)}, ctx)
    assert {:ok, [_first, _second | _parts]} = encode(page)
    [header] = assert_on_the_wire!(page, schema)
    assert length(header["messages"]) < 12
    assert header["next_after_seq"] < header["history_head_seq"]

    {:ok, giant} = RepoTimeline.append("main", assistant(String.duplicate("x", 1_100_000)), [])
    [cut_page] = route!(%{type: "history_pull", payload: history_pull(giant.server_seq - 1)}, ctx)
    assert [%{"messages" => [%{"truncated" => true}]}] = assert_on_the_wire!(cut_page, schema)
    assert [%{"truncated" => true}] = assert_on_the_wire!(Output.row("main", giant), schema)
  end

  test "the request path's receipts", %{schema: schema} = ctx do
    opts = [store: ClaimStore, coordinator: SettledCoordinator, event_sink: ctx.sink]

    for id <- ["client-1", "dup-client-2"] do
      :ok = EventRouter.route(%{type: "msg", payload: msg_payload(id)}, @context, opts)
    end

    :ok = EventRouter.route(%{type: "ping", payload: %{}}, @context, event_sink: ctx.sink)

    [first, duplicate] = received_sink_events("accepted")
    assert [%{"duplicate" => false} = fresh] = assert_on_the_wire!(first, schema)
    refute Map.has_key?(fresh, "server_seq")
    assert [%{"duplicate" => true, "server_seq" => 14}] = assert_on_the_wire!(duplicate, schema)
    assert [_pong] = assert_on_the_wire!(hd(received_sink_events("pong")), schema)
  end

  test "the channel adapter's own events", %{schema: schema, dir: dir} do
    {:ok, [message]} =
      Mobile.parse_event(%{type: "msg", payload: msg_payload("client-7")})

    :ok = Mobile.react(message, "👍")
    {:ok, draft} = Mobile.open_draft(message, "Hel")
    :ok = Mobile.edit_draft(message, draft, "Hello")
    :ok = Mobile.edit_draft(message, draft, "Hi there")
    :ok = Mobile.discard_draft(message, draft)
    activity = Mobile.build_activity_callback(message)
    :ok = activity.({:tool_start, "shell"})
    :ok = activity.({:tool_finish, "shell", String.duplicate("output ", 400)})
    :ok = Mobile.send_message("main", "Your 9am summary")
    :ok = send_document!(dir)

    types = ~w(reaction turn_started text_delta text_delta text_delta tool_event tool_event row
               media_begin media_chunk media_chunk media_chunk media_end)

    events = received_phone_events()
    assert Enum.map(events, & &1["t"]) == types
    for event <- events, do: assert_on_the_wire!(event, schema)

    # A turn's ending, as `Companion.Turns` sends it once the turn completes.
    assert [%{"t" => "turn_done"}] =
             assert_on_the_wire!(Output.turn_done("turn-client-7"), schema)

    # How a reconnecting phone's requests stand, as the router answers it.
    outcomes = [
      %{"client_msg_id" => "client-7", "status" => "completed", "result_server_seq" => 9},
      %{"client_msg_id" => "client-8", "status" => "failed", "error" => "cancelled"}
    ]

    page = %{"t" => "request_status_page", "requests" => outcomes}
    assert [%{"requests" => ^outcomes}] = assert_on_the_wire!(page, schema)
  end

  test "an approval, its re-send with the time it has left, and its expiry", %{schema: schema} do
    test_pid = self()
    clock = :atomics.new(1, [])

    approvals =
      start_supervised!(
        {Approvals,
         name: nil,
         clock: fn -> :atomics.get(clock, 1) end,
         schedule: fn message, delay -> send(test_pid, {:scheduled, message, delay}) end,
         announce: fn profile, event, transport ->
           send(test_pid, {:announced, profile, event, transport})
           :ok
         end}
      )

    Application.put_env(:fermix_channels, :companion_approvals, approvals)
    {:ok, [message]} = Mobile.parse_event(%{type: "msg", payload: msg_payload("client-8")})
    :ok = Mobile.send_approval(message, %{kind: :sandbox, text: "Allow?", token: "TOKEN"})

    assert_receive {:announced, "main", card, :mobile}
    assert [%{"ttl_s" => 60}] = assert_on_the_wire!(card, schema)

    :atomics.put(clock, 1, 22_500)
    assert [resent] = Approvals.pending(approvals, "main", :mobile)
    assert [%{"ttl_s" => 38}] = assert_on_the_wire!(resent, schema)

    assert_receive {:scheduled, expiry, 60_000}
    send(approvals, expiry)
    assert_receive {:announced, "main", expired, :mobile}
    assert [%{"outcome" => "expired"}] = assert_on_the_wire!(expired, schema)
  end

  test "hello_ack with its waiting approval, and the refusal of another version",
       %{schema: schema} do
    card = Map.put(Output.approval(%{kind: :sandbox, text: "Allow?", token: "T"}), "ttl_s", 12)
    state = hello_state(ipv4_candidates(20), pending_approvals: fn "main" -> [card] end)

    {frames, _state} = pushed(SocketHandler.handle_in({hello_frame(2), opcode: :binary}, state))
    assert [%{"t" => "hello_ack"} = ack, %{"t" => "approval"}] = assert_frames!(frames, schema)
    assert length(ack["candidates"]) == 16

    refused = SocketHandler.handle_in({hello_frame(1), opcode: :binary}, hello_state([], []))
    assert {:stop, _reason, {1002, _text}, _frames, _state} = refused
    {frames, _state} = pushed(refused)
    assert [%{"code" => "unsupported_protocol_version"}] = assert_frames!(frames, schema)
  end

  test "the socket's own replies and refusals", %{schema: schema, dir: dir} do
    {store, digest} = stored_blob!(dir, 130_000)
    state = ready_state(store, digest)

    {frames, state} =
      pushed(SocketHandler.handle_in(client(state, "media_fetch", %{"ref" => digest}), state))

    assert frames == []
    {frames, state} = drain_media(state, [])

    assert ~w(media_begin media_chunk media_chunk media_chunk media_end) ==
             frames |> assert_frames!(schema) |> Enum.map(& &1["t"])

    missing = String.duplicate("f", 64)

    {_frames, state} =
      pushed(SocketHandler.handle_in(client(state, "media_fetch", %{"ref" => missing}), state))

    {frames, state} = drain_media(state, [])
    assert [%{"code" => "not_found", "ref" => ^missing}] = assert_frames!(frames, schema)

    # The ninth fetch waiting is refused by name, like every other media error.
    {frames, state} = feed(List.duplicate({"media_fetch", %{"ref" => digest}}, 9), state)

    assert [%{"code" => "media_fetch_backlog_full", "ref" => ^digest}] =
             assert_frames!(frames, schema)

    flush_media_steps()

    ref = make_ref()
    down = {:DOWN, ref, :process, self(), {:crashed, String.duplicate("s", 5_000)}}
    busy = %{state | request_ref: ref, request_client_msg_id: "client-9"}
    {frames, state} = pushed(SocketHandler.handle_info(down, busy))

    assert [%{"code" => "request_failed", "client_msg_id" => "client-9"}] =
             assert_frames!(frames, schema)

    unknown = SocketHandler.handle_in(client(state, "future_event", %{}), state)
    assert {:stop, _reason, {1002, _text}, _frames, _state} = unknown
    {frames, _state} = pushed(unknown)
    assert [%{"code" => "unsupported"}] = assert_frames!(frames, schema)
  end

  test "a request that fails reaches its device correlated", %{schema: schema, dir: dir} do
    test_pid = self()
    {store, digest} = stored_blob!(dir, 10)

    state =
      ready_state(store, digest,
        run_request: fn job -> {:ok, spawn(job)} end,
        event_router: fn _event, _context, _opts -> {:error, :client_message_conflict} end,
        send_device_event: fn _registry, @device, event ->
          send(test_pid, {:device_event, event})
          :ok
        end
      )

    {_frames, _state} =
      pushed(SocketHandler.handle_in(client(state, "msg", msg_payload("c-3")), state))

    assert_receive {:device_event, failure}

    assert [%{"code" => "client_message_conflict", "client_msg_id" => "c-3"}] =
             assert_on_the_wire!(failure, schema)
  end

  test "a long fan-out event is one event_part run, and one past 1 MiB is cut",
       %{schema: schema, dir: dir} do
    {store, digest} = stored_blob!(dir, 10)
    state = ready_state(store, digest)
    long = Output.text_done("turn-client-1", 20, String.duplicate("é", 40_000))

    {frames, state} = pushed(SocketHandler.handle_info({:mobile_event, long}, state))
    assert length(frames) >= 2
    assert [%{"text" => text}] = assert_frames!(frames, schema)
    assert text == long["text"]

    giant = Output.text_done("turn-client-1", 21, String.duplicate("\"", 700_000))
    {frames, _state} = pushed(SocketHandler.handle_info({:mobile_event, giant}, state))
    assert [%{"truncated" => true}] = assert_frames!(frames, schema)
  end

  test "pairing answers the phone in the vocabulary the schema names", %{schema: schema} do
    candidates = ipv4_candidates(20)
    state = pairing_state(candidates)

    {frames, next} = pushed(SocketHandler.handle_in(pairing_ping(), state))
    assert [%{"t" => "pong"}] = assert_frames!(frames, schema)

    device = %{device_id: "new-device", apns_key_salt: :crypto.strong_rand_bytes(32)}
    approval = {:mobile_pair_decision, "pair-session", {:ok, device}}
    {frames, _state} = pushed(SocketHandler.handle_info(approval, next))
    assert [%{"t" => "pair_approved", "candidates" => sent}] = assert_frames!(frames, schema)
    assert length(sent) == 16

    for status <- [:denied, :expired, :cancelled, :device_disconnected] do
      reason = PairManager.outcome_reason(status)
      denial = {:mobile_pair_decision, "pair-session", {:error, reason}}
      stopped = SocketHandler.handle_info(denial, state)
      assert {:stop, ^reason, {4003, _text}, _frames, _state} = stopped
      {frames, _state} = pushed(stopped)
      assert [%{"t" => "pair_denied", "reason" => word}] = assert_frames!(frames, schema)
      assert word == Atom.to_string(reason)
    end
  end

  # M51 asks the largest hello_ack to fit one frame (a 4,096-byte header). With
  # 16 numeric candidates and the whole command catalog it does; with 16
  # candidates of which 8 are MagicDNS names at their 253-byte limit it cannot,
  # and it travels as an event_part run, which is what every client handles.
  describe "hello_ack size" do
    test "16 numeric candidates and the full command catalog fit one frame", %{schema: schema} do
      assert Application.get_env(:fermix_channels, :commands) == nil
      state = hello_state(ipv4_candidates(16), profile_name: String.duplicate("N", 128))

      {[frame], _state} =
        pushed(SocketHandler.handle_in({hello_frame(2), opcode: :binary}, state))

      assert byte_size(frame) - 4 <= Protocol.max_header_bytes()
      assert [%{"caps" => %{"commands" => commands}}] = assert_frames!([frame], schema)
      assert length(commands) == length(Mobile.command_catalog())
    end

    test "the largest one arrives whole as an event_part run", %{schema: schema} do
      candidates = Enum.take(magicdns_candidates(8) ++ ipv4_candidates(8), 16)
      state = hello_state(candidates, profile_name: String.duplicate("N", 128))

      {frames, _state} = pushed(SocketHandler.handle_in({hello_frame(2), opcode: :binary}, state))
      assert [%{"candidates" => sent}] = assert_frames!(frames, schema)
      assert length(sent) == 16
    end
  end

  # -- encoding, reassembly and validation, as a phone does them --

  defp assert_on_the_wire!(event, schema) do
    assert {:ok, frames} = encode(event)
    assert_frames!(frames, schema)
  end

  defp encode(%{"t" => type} = event) do
    payload = Map.drop(event, ["t", "bytes"])
    Protocol.encode_server_event(type, payload, 1, Map.get(event, "bytes", <<>>), [])
  end

  defp assert_frames!(frames, schema) do
    frames
    |> Enum.map(&split_frame/1)
    |> reassemble([], nil)
    |> Enum.map(fn {header, _bytes} ->
      assert WireSchema.errors(header, WireSchema.ref("serverEvent"), schema) == [],
             "#{header["t"]} is refused by the schema"

      assert WireSchema.null_values(header, "#") == [], "#{header["t"]} carries a null"
      header
    end)
  end

  defp split_frame(<<size::unsigned-big-32, header::binary-size(size), bytes::binary>> = frame) do
    assert byte_size(frame) <= Protocol.max_plaintext_bytes()
    assert size <= Protocol.max_header_bytes()
    {Jason.decode!(header), bytes}
  end

  defp reassemble([], events, nil), do: Enum.reverse(events)
  defp reassemble([], _events, run), do: flunk("an event_part run stopped at #{run.next_index}")

  defp reassemble([{%{"t" => "event_part"} = part, tail} | rest], events, run) do
    run = continue_run(run, part, tail)

    if run.next_index == run.count,
      do: reassemble(rest, [finish_run(run) | events], nil),
      else: reassemble(rest, events, run)
  end

  defp reassemble([{header, bytes} | rest], events, nil),
    do: reassemble(rest, [{header, bytes} | events], nil)

  defp reassemble([{header, _bytes} | _rest], _events, _run),
    do: flunk("a #{header["t"]} frame interleaved an event_part run")

  defp continue_run(nil, %{"index" => 0, "count" => count, "seq" => seq, "v" => v}, tail),
    do: %{v: v, first_seq: seq, count: count, next_index: 1, next_seq: seq + 1, tails: [tail]}

  defp continue_run(run, part, tail) do
    assert %{"index" => index, "count" => count, "seq" => seq, "v" => v} = part
    assert {index, count, seq, v} == {run.next_index, run.count, run.next_seq, run.v}
    %{run | next_index: index + 1, next_seq: seq + 1, tails: [tail | run.tails]}
  end

  defp finish_run(run) do
    json = run.tails |> Enum.reverse() |> IO.iodata_to_binary()
    assert byte_size(json) <= Protocol.max_event_bytes()
    logical = Jason.decode!(json)
    refute Map.has_key?(logical, "v") or Map.has_key?(logical, "seq")
    refute logical["t"] == "event_part"
    {Map.merge(logical, %{"v" => run.v, "seq" => run.first_seq}), <<>>}
  end

  # -- the socket, driven with Noise as the identity --

  defp pushed({:ok, state}), do: {[], state}
  defp pushed({:push, {:binary, frame}, state}), do: {[frame], state}
  defp pushed({:push, frames, state}) when is_list(frames), do: {binaries(frames), state}
  defp pushed({:stop, _reason, {_code, _text}, frames, state}), do: {binaries(frames), state}

  defp binaries(frames), do: Enum.map(frames, fn {:binary, frame} -> frame end)

  defp feed(events, state) do
    Enum.reduce(events, {[], state}, fn {type, payload}, {sent, state} ->
      {more, state} = pushed(SocketHandler.handle_in(client(state, type, payload), state))
      {sent ++ more, state}
    end)
  end

  defp drain_media(state, frames) do
    receive do
      :mobile_media_step ->
        {more, state} = pushed(SocketHandler.handle_info(:mobile_media_step, state))
        drain_media(state, frames ++ more)
    after
      0 -> {frames, state}
    end
  end

  defp flush_media_steps do
    receive do
      :mobile_media_step -> flush_media_steps()
    after
      0 -> :ok
    end
  end

  defp client(state, type, payload),
    do: {frame(2, type, state.client_seq + 1, payload), opcode: :binary}

  defp frame(version, type, seq, payload) do
    json = payload |> Map.merge(%{"v" => version, "t" => type, "seq" => seq}) |> Jason.encode!()
    <<byte_size(json)::unsigned-big-32, json::binary>>
  end

  defp hello_frame(version) do
    payload = %{
      "device_id" => @device,
      "app_version" => "1.0.0",
      "last_server_seq" => 0,
      "protocol_v" => version
    }

    frame(version, "hello", 1, payload)
  end

  defp pairing_ping, do: client(%{client_seq: 1}, "ping", %{})

  defp identity_noise do
    %{
      noise: :noise,
      decrypt: fn :noise, frame -> {:ok, frame, :noise} end,
      encrypt: fn :noise, plaintext -> {:ok, plaintext, :noise} end
    }
  end

  defp hello_state(candidates, overrides) do
    {:ok, state} =
      identity_noise()
      |> Map.merge(%{
        phase: :await_hello,
        authenticated_device: %{device_id: @device},
        device_registry: :registry,
        update_device: fn _store, @device, %{last_seen: %DateTime{}} ->
          {:ok, %{device_id: @device}}
        end,
        attach_socket: fn :registry, @device, _pid, profile_id: "main" -> :ok end,
        history_head: fn "main" -> {:ok, 18} end,
        read_frontier: fn "main" -> {:ok, 17} end,
        discover: fn -> {:ok, candidates} end,
        pending_approvals: fn "main" -> [] end
      })
      |> Map.merge(Map.new(overrides))
      |> SocketHandler.init()

    state
  end

  defp ready_state(store, digest, overrides \\ []) do
    {:ok, state} =
      identity_noise()
      |> Map.merge(%{
        phase: :ready,
        device_id: @device,
        profile_id: "main",
        media_store: store,
        negotiated_version: 2,
        authorize_socket: fn _registry, @device, _pid -> :ok end,
        media_descriptor: fn
          "main", ^digest -> {:ok, media_descriptor(digest, store)}
          "main", _other -> {:error, :not_found}
        end
      })
      |> Map.merge(Map.new(overrides))
      |> SocketHandler.init()

    state
  end

  defp pairing_state(candidates) do
    {:ok, state} =
      identity_noise()
      |> Map.merge(%{
        phase: :await_pair_decision,
        pairing_session_id: "pair-session",
        client_seq: 1,
        negotiated_version: 2,
        discover: fn -> {:ok, candidates} end,
        schedule_handshake_deadline: fn _message, _delay -> make_ref() end,
        cancel_handshake_deadline: fn _ref -> false end
      })
      |> SocketHandler.init()

    state
  end

  defp media_descriptor(digest, store) do
    {:ok, blob} = MediaStore.fetch(store, digest)

    %{
      server_seq: 41,
      media: %{
        "ref" => digest,
        "sha256" => digest,
        "kind" => "document",
        "mime" => "application/pdf",
        "size_bytes" => blob.size_bytes,
        "filename" => "answer.pdf"
      }
    }
  end

  defp stored_blob!(dir, size) do
    root = Path.join(dir, "media-#{System.unique_integer([:positive])}")
    store = start_supervised!({MediaStore, name: nil, root: root, max_store_bytes: 1_000_000})
    bytes = for index <- 1..size, into: <<>>, do: <<rem(index, 251)>>
    {:ok, digest} = MediaStore.put_bytes(store, bytes)
    {store, digest}
  end

  # -- the channel adapter and the timeline --

  defp send_document!(dir) do
    path = Path.join(dir, "answer.pdf")
    bytes = for index <- 1..130_000, into: <<>>, do: <<rem(index, 251)>>
    File.write!(path, bytes)
    digest = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

    Application.put_env(:fermix_channels, :mobile_media_resolver, fn _media ->
      {:ok, %{"ref" => digest, "sha256" => digest, "path" => path, "size_bytes" => 130_000}}
    end)

    media = %{
      kind: :document,
      path: path,
      mime_type: "application/pdf",
      filename: "answer.pdf",
      caption: "The report"
    }

    Mobile.send_media("main", media)
  end

  defp seed_rows! do
    digest = String.duplicate("c", 64)

    photo = %{
      role: "user",
      content: "see https://example.com",
      kind: "media",
      client_msg_id: "ipad-1",
      media_refs: [
        %{
          "ref" => digest,
          "sha256" => digest,
          "kind" => "image",
          "mime" => "image/jpeg",
          "size_bytes" => 48_213,
          "filename" => "photo.jpg"
        }
      ]
    }

    reply = %{
      role: "assistant",
      content: "You have one meeting, at 10.",
      kind: "text",
      in_reply_to: "mac-1",
      metadata: %{"turn_id" => "turn-mac-1"}
    }

    for attrs <- [photo, reply, assistant("A delivery")] do
      {:ok, row} = RepoTimeline.append("main", attrs, [])
      row
    end
  end

  defp assistant(text), do: %{role: "assistant", content: text, kind: "text"}

  defp unfurled_previews do
    [
      %{
        url: "https://example.com",
        site: String.duplicate("s", 200),
        title: String.duplicate("t", 400),
        description: String.duplicate("é", 400),
        image: nil
      },
      %{
        url: "https://example.org/post",
        site: "Example Org",
        title: "A post",
        image: %{ref: String.duplicate("d", 64), mime: "image/png", size_bytes: 1_024}
      },
      %{url: "https://example.net/" <> String.duplicate("p", 2_100), site: "Net", title: "Long"}
    ]
  end

  defp route!(event, ctx) do
    :ok = EventRouter.route(event, @context, store: RepoTimeline, event_sink: ctx.sink)
    received_sink_events(nil)
  end

  defp history_pull(after_seq),
    do: %{"profile_id" => "main", "after_seq" => after_seq, "limit" => 200}

  defp msg_payload(id),
    do: %{"client_msg_id" => id, "profile_id" => "main", "text" => "Hello", "attach_ids" => []}

  defp received_sink_events(type) do
    receive do
      {:sink, _target, %{"t" => t} = event} when is_nil(type) or t == type ->
        [event | received_sink_events(type)]
    after
      0 -> []
    end
  end

  defp received_phone_events do
    receive do
      {:phone_event, "main", event} -> [event | received_phone_events()]
    after
      0 -> []
    end
  end

  defp ipv4_candidates(count) do
    for index <- 1..count do
      %{
        address: "100.127.255.#{100 + index}",
        interface: "enp0s31f6abcd#{rem(index, 10)}",
        scope: :tailnet
      }
    end
  end

  # A MagicDNS name at its limit: 253 bytes, every label within 63.
  defp magicdns_candidates(count) do
    label = fn char, size -> String.duplicate(char, size) end

    for index <- 1..count do
      name = Enum.join([label.("a", 63), label.("b", 63), label.("c", 63), label.("d", 52)], ".")
      host = "#{name}#{rem(index, 10)}#{rem(index, 10)}.ts.net"
      %{address: host, interface: "utun#{index}", scope: :tailnet}
    end
  end

  defp restore_env({key, {:ok, value}}), do: Application.put_env(:fermix_channels, key, value)
  defp restore_env({key, :error}), do: Application.delete_env(:fermix_channels, key)
end
