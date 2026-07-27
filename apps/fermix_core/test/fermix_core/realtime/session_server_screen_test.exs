defmodule FermixCore.Realtime.SessionServerScreenTest do
  @moduledoc """
  The session half of continuous screen perception (M9.5): what reaches the
  provider, what is evicted, and what happens to the feed across a reconnect, a
  budget stop, and teardown.
  """

  use ExUnit.Case, async: false

  # Screen sharing is gated on computer-use being able to CAPTURE, which this
  # file fakes with a `dev_local` stub binary. compux ships no sidecar artifact
  # for every host, and `Compux.Binary.target/0` is what resolves one, so skip
  # with a reason rather than crash the setup on those legs.
  case Compux.Binary.target() do
    {:ok, _target} ->
      :ok

    {:error, reason} ->
      @moduletag skip:
                   "compux ships no sidecar artifact for this host: " <>
                     "#{inspect(reason)} (supported: macos-aarch64, linux-x86_64)"
  end

  alias FermixCore.ComputerUse.CaptureHealth
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.SessionServer

  defmodule FakeOpenAIClient do
    def start_link(opts), do: Agent.start_link(fn -> %{opts: opts, events: []} end)
    def send_event(pid, event), do: Agent.update(pid, &%{&1 | events: &1.events ++ [event]})
    def close(pid), do: Agent.stop(pid)
    def events(pid), do: Agent.get(pid, & &1.events)

    # Frames take the queued path (they must never block the session), so the fake
    # records them the same way — and reports a backlog on demand so the
    # backpressure branch is exercisable.
    def cast_event(pid, event), do: send_event(pid, event)

    def pending_sends(_pid), do: :persistent_term.get({__MODULE__, :pending}, 0)

    def set_pending(count), do: :persistent_term.put({__MODULE__, :pending}, count)
  end

  # A feed that starts and stops but never captures: this file is about what the
  # SESSION does with frames, so frames are injected directly.
  defmodule FakeFeed do
    use GenServer

    def start_link(opts) do
      if :persistent_term.get({__MODULE__, :refuse}, false) do
        {:error, :capture_unavailable}
      else
        GenServer.start_link(__MODULE__, opts)
      end
    end

    def stop(server, reason \\ :requested) do
      GenServer.stop(server, {:shutdown, reason})
    catch
      :exit, _reason -> :ok
    end

    def set_speaking(server, speaking?), do: GenServer.cast(server, {:speaking, speaking?})

    def refuse(refuse?), do: :persistent_term.put({__MODULE__, :refuse}, refuse?)
    def speaking, do: :persistent_term.get({__MODULE__, :speaking}, nil)

    @impl true
    def init(opts) do
      Process.flag(:trap_exit, true)
      {:ok, %{owner: Keyword.fetch!(opts, :owner)}}
    end

    @impl true
    def handle_cast({:speaking, speaking?}, state) do
      :persistent_term.put({__MODULE__, :speaking}, speaking?)
      {:noreply, state}
    end

    @impl true
    def handle_info({:EXIT, owner, _reason}, %{owner: owner} = state),
      do: {:stop, {:shutdown, :requested}, state}

    def handle_info(_message, state), do: {:noreply, state}

    @impl true
    def terminate(reason, state) do
      send(state.owner, {:screen_feed, {:stopped, stop_reason(reason), %{frames: 0}}})
      :ok
    end

    defp stop_reason({:shutdown, reason}), do: reason
    defp stop_reason(_other), do: :requested
  end

  # The OS-permission probe the start gate reads. Stubbed here because the fake
  # sidecar below is a no-op shell script: it makes `ComputerUse.ready?/0` true but
  # cannot answer a `probe` action.
  defmodule FakeProbe do
    def answer(answer), do: :persistent_term.put({__MODULE__, :answer}, answer)

    def run do
      case :persistent_term.get({__MODULE__, :answer}, :allow) do
        :allow -> {:ok, report(true)}
        :deny -> {:ok, report(false)}
        :error -> {:error, :sidecar_gone}
      end
    end

    defp report(screen_capture?) do
      %{
        platform: "test",
        display_server: "test",
        screen_capture: screen_capture?,
        input_control: true
      }
    end
  end

  setup do
    start_supervised!(CaptureHealth)
    FakeFeed.refuse(false)
    FakeProbe.answer(:allow)
    FakeOpenAIClient.set_pending(0)
    :persistent_term.erase({FakeFeed, :speaking})

    computer_use = Application.get_env(:fermix_core, :computer_use, [])
    plugins = Application.get_env(:fermix_core, :plugins)
    Application.put_env(:fermix_core, :computer_use, enabled: true, display: 0)
    home = install_fake_sidecar()

    on_exit(fn ->
      Application.put_env(:fermix_core, :computer_use, computer_use)
      restore_env(:plugins, plugins)
      FakeFeed.refuse(false)
      FermixTestSupport.SafeRm.rm_rf(home)
    end)

    {:ok, server} =
      SessionServer.start_link(
        companion: self(),
        config: Config.normalize(enabled: true),
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capabilities: [],
        screen_feed_module: FakeFeed,
        screen_probe: &FakeProbe.run/0,
        prompt_loader: fn _opts -> {:ok, %{messages: [], parts: [], accounting: []}} end
      )

    :ok = SessionServer.call_start(server)
    :ok = SessionServer.handle_provider_event(server, {:session_updated, %{}})

    %{server: server, openai: SessionServer.openai_pid(server)}
  end

  # A `dev_local` stub makes `ComputerUse.ready?/0` true without touching host
  # state or downloading anything — the feed itself is faked, so this binary is
  # never executed.
  defp install_fake_sidecar do
    {:ok, target} = Compux.Binary.target()

    home =
      Path.join([
        System.tmp_dir!(),
        "fermix-screen-share",
        "home-#{System.unique_integer([:positive])}"
      ])

    binary = Path.join([home, "dev-plugins", "computer_use_sidecar", "bin", target, "compux"])
    File.mkdir_p!(Path.dirname(binary))
    File.write!(binary, "#!/bin/sh\n")
    File.chmod!(binary, 0o755)

    Application.put_env(:fermix_core, :plugins, dev_local: Path.join(home, "dev-plugins"))
    home
  end

  defp restore_env(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore_env(key, value), do: Application.put_env(:fermix_core, key, value)

  defp start_sharing(server) do
    :ok =
      SessionServer.handle_provider_event(
        server,
        {:function_call,
         %{"call_id" => "call_1", "name" => "screen_share", "arguments" => ~s({"action":"start"})}}
      )
  end

  defp send_frame(server, data) do
    send(
      server,
      {:screen_feed,
       {:frame,
        %{mime_type: "image/png", data: data, bytes: byte_size(data), gated_out: 0, seq: 1}}}
    )

    # Round-trip a call so the async frame message is guaranteed processed.
    _ = :sys.get_state(server)
    :ok
  end

  defp events_of_type(openai, type) do
    openai |> FakeOpenAIClient.events() |> Enum.filter(&(&1[:type] == type))
  end

  defp frame_items(openai) do
    openai
    |> events_of_type("conversation.item.create")
    |> Enum.filter(fn event ->
      # `function_call_output` items carry no content parts at all.
      event.item |> Map.get(:content, []) |> Enum.any?(&(&1[:type] == "input_image"))
    end)
  end

  defp text_parts(openai) do
    openai
    |> events_of_type("conversation.item.create")
    |> Enum.flat_map(&Map.get(&1.item, :content, []))
    |> Enum.filter(&(&1[:type] == "input_text"))
    |> Enum.map(& &1.text)
  end

  test "a frame is appended as passive context and never asks for a response", %{
    server: server,
    openai: openai
  } do
    start_sharing(server)
    before = length(events_of_type(openai, "response.create"))

    send_frame(server, "pixels")

    assert [item] = frame_items(openai)
    assert [%{type: "input_text"}, image] = item.item.content
    assert image.detail == "low", "continuous frames take the cheap end of the detail dial"
    assert String.starts_with?(image.image_url, "data:image/png;base64,")

    assert length(events_of_type(openai, "response.create")) == before,
           "a frame must not trigger a turn — the user's next utterance does"
  end

  # Without eviction every retained frame is re-read (and re-billed) by every later
  # response for the rest of the call.
  test "superseded frames are evicted, newest kept", %{server: server, openai: openai} do
    start_sharing(server)

    send_frame(server, "one")
    send_frame(server, "two")
    assert events_of_type(openai, "conversation.item.delete") == []

    send_frame(server, "three")

    assert [delete] = events_of_type(openai, "conversation.item.delete")
    [oldest | _] = frame_items(openai)
    assert delete.item_id == oldest.item.id
    assert length(frame_items(openai)) == 3, "all three were sent; only the oldest was evicted"
  end

  # A frame arriving between a provider drop and a reconnect has nowhere to go: it
  # must be discarded, not queued into a conversation that no longer exists.
  test "frames are dropped when no provider session is ready", %{server: server} do
    start_sharing(server)
    # Reconnecting: the connection is momentarily gone and its item ids with it.
    send(server, {:openai_realtime_disconnect, :network})
    refute :sys.get_state(server).provider_ready?

    send_frame(server, "pixels")

    assert :sys.get_state(server).screen_frame_items == []
    assert Process.alive?(server)
  end

  # A server-sent error is REPORTED, not fatal: only the socket's own disconnect
  # decides liveness, so one bad event cannot disarm the reconnect path.
  test "a provider error event does not end the call", %{server: server} do
    start_sharing(server)

    :ok = SessionServer.handle_provider_event(server, {:error, %{"code" => "server_error"}})

    assert Process.alive?(server)
    assert is_pid(:sys.get_state(server).openai_pid)
  end

  # The freeze this feature shipped with: frames went out on the session's blocking
  # send, so a slow uplink stalled the call (no audio, no events) and then tore it
  # down on the 5s deadline. A backed-up socket must cost a FRAME, never the call.
  test "a frame is dropped, not queued, when the socket is behind", %{
    server: server,
    openai: openai
  } do
    start_sharing(server)
    FakeOpenAIClient.set_pending(99)

    send_frame(server, "pixels")

    assert frame_items(openai) == []
    assert :sys.get_state(server).screen_frame_items == []
    assert Process.alive?(server), "backpressure must never end the call"
  end

  test "frames resume once the socket drains", %{server: server, openai: openai} do
    start_sharing(server)

    FakeOpenAIClient.set_pending(99)
    send_frame(server, "stale")
    assert frame_items(openai) == []

    FakeOpenAIClient.set_pending(0)
    send_frame(server, "fresh")
    assert length(frame_items(openai)) == 1
  end

  test "starting twice does not open a second feed", %{server: server} do
    start_sharing(server)
    feed = :sys.get_state(server).screen_feed

    start_sharing(server)
    assert :sys.get_state(server).screen_feed == feed
  end

  test "a refused start is answered, and no feed is left behind", %{server: server} do
    FakeFeed.refuse(true)
    start_sharing(server)

    assert :sys.get_state(server).screen_feed == nil
  end

  test "speech boundaries drive the feed's cadence", %{server: server} do
    start_sharing(server)
    feed = :sys.get_state(server).screen_feed

    :ok = SessionServer.handle_provider_event(server, {:input_audio_speech_started, %{}})
    # The feed is told by cast (the session must never block on it), so sync on the
    # feed itself rather than assume the message has landed.
    _ = :sys.get_state(feed)
    assert FakeFeed.speaking() == true

    :ok = SessionServer.handle_provider_event(server, {:input_audio_speech_stopped, %{}})
    _ = :sys.get_state(feed)
    assert FakeFeed.speaking() == false
  end

  test "stopping is answered and clears the feed", %{server: server} do
    start_sharing(server)

    :ok =
      SessionServer.handle_provider_event(
        server,
        {:function_call,
         %{"call_id" => "c2", "name" => "screen_share", "arguments" => ~s({"action":"stop"})}}
      )

    assert :sys.get_state(server).screen_feed == nil
    assert :sys.get_state(server).screen_frame_items == []
  end

  # A reconnect opens a FRESH server-side conversation, so the old frames and
  # their item ids cannot cross it — but the operator should not have to re-ask.
  test "a reconnect suspends the feed and resumes it on the new session", %{server: server} do
    start_sharing(server)
    send_frame(server, "pixels")
    assert :sys.get_state(server).screen_frame_items != []

    send(server, {:openai_realtime_disconnect, :closed})
    state = :sys.get_state(server)

    assert state.screen_feed == nil
    assert state.screen_frame_items == [], "item ids belong to the conversation that went away"
    assert state.screen_share_resume?

    send(server, :reconnect_attempt)
    :ok = SessionServer.handle_provider_event(server, {:session_updated, %{}})

    resumed = :sys.get_state(server)
    assert is_pid(resumed.screen_feed)
    refute resumed.screen_share_resume?
  end

  # Consent is per-use: ending the call must not leave sharing armed for the next
  # one on this process.
  # Consent is per-call, and the call now ENDS: sharing cannot survive into a next
  # call because the session that held it is gone, feed and all.
  test "a call that ends takes the feed with it", %{server: server} do
    Process.unlink(server)
    start_sharing(server)
    feed = :sys.get_state(server).screen_feed
    feed_ref = Process.monitor(feed)
    ref = Process.monitor(server)

    :ok = SessionServer.call_stop(server)

    assert_receive {:DOWN, ^ref, :process, ^server, {:shutdown, :call_stop}}, 500
    assert_receive {:DOWN, ^feed_ref, :process, ^feed, _reason}, 500
  end

  test "the feed stops at its budget share while the call continues", %{
    server: server,
    openai: openai
  } do
    start_sharing(server)

    # 100k image tokens at $5/1M = 50 cents = half of the default 100-cent budget.
    :ok =
      SessionServer.handle_provider_event(
        server,
        {:response_done,
         %{
           "id" => "resp_1",
           "usage" => %{"input_token_details" => %{"image_tokens" => 100_000}}
         }}
      )

    state = :sys.get_state(server)
    assert state.screen_feed == nil, "the eyes close first"
    assert Process.alive?(server), "the call itself continues"

    # The model is told, so it stops narrating a screen it can no longer see.
    assert Enum.any?(text_parts(openai), &String.contains?(&1, "[fermix] Screen sharing stopped"))
  end

  # The verb is answered inline (not via ToolBridge), which once meant it left no
  # tool span at all — a live debug had to infer a stop from the feed's lifecycle
  # event. Answering inline is an implementation detail; the trace must not show it.
  test "screen_share emits a tool span like every other tool", %{server: server} do
    handler = {__MODULE__, :tool_spans, System.unique_integer([:positive])}
    test_pid = self()

    :telemetry.attach(
      handler,
      [:fermix, :tool, :exec],
      fn _event, meas, meta, _cfg -> send(test_pid, {:tool_span, meas, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    start_sharing(server)

    assert_receive {:tool_span, meas, meta}, 1_000
    assert meta.tool == "screen_share"
    assert meta.success
    assert meta.action == "start"
    assert meas.duration_ms >= 0
  end

  test "a refused screen_share is traced as a failed span", %{server: server} do
    FakeFeed.refuse(true)
    handler = {__MODULE__, :tool_spans_error, System.unique_integer([:positive])}
    test_pid = self()

    :telemetry.attach(
      handler,
      [:fermix, :tool, :exec],
      fn _event, _meas, meta, _cfg -> send(test_pid, {:tool_span, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    start_sharing(server)

    assert_receive {:tool_span, meta}, 1_000
    assert meta.tool == "screen_share"
    refute meta.success
  end

  # Without the Screen Recording grant macOS does not FAIL a capture — it hands back
  # a frame with no window content — so a feed started anyway would stream blank
  # desktops while the model narrated an empty screen. Refuse before promising to
  # watch. `ready?/0` cannot see this: it only knows the sidecar is installed.
  test "a missing screen-recording grant refuses the start", %{server: server} do
    FakeProbe.answer(:deny)

    start_sharing(server)

    refute :sys.get_state(server).screen_feed

    assert_receive {:realtime, %{type: "tool_event", status: "error", reason: reason}}, 1_000
    assert reason == "screen_recording_denied"
  end

  # A probe that cannot answer is not the same failure as a grant that is denied,
  # and collapsing the two sends the operator to the wrong settings pane.
  test "a probe that cannot answer refuses distinctly from a denied grant", %{server: server} do
    FakeProbe.answer(:error)

    start_sharing(server)

    refute :sys.get_state(server).screen_feed

    assert_receive {:realtime, %{type: "tool_event", status: "error", reason: reason}}, 1_000
    assert reason =~ "capture_probe_failed"
  end

  test "the feed dies with the session", %{server: server} do
    start_sharing(server)
    feed = :sys.get_state(server).screen_feed
    ref = Process.monitor(feed)

    GenServer.stop(server, :normal)

    assert_receive {:DOWN, ^ref, :process, ^feed, _reason}, 1_000
  end
end
