defmodule FermixCore.Realtime.GrokSessionServerTest do
  use ExUnit.Case, async: false

  alias FermixCore.Realtime.CallRegistry
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.GrokSessionServer
  alias FermixCore.Realtime.SessionControl
  alias FermixCore.Realtime.XAIRealtimeClient

  @moduletag :capture_log

  @call_registry Module.concat(__MODULE__, CallRegistry)
  # One 100 ms chunk of 24 kHz PCM16 silence, as the vendor sends it.
  @chunk Base.encode64(:binary.copy(<<0, 0>>, 2_400))

  defmodule FakeXAI do
    @moduledoc """
    The xAI socket: `start_link/1` starts a process LINKED to the session, as
    WebSockex does, so a close or a crash reaches the session as the socket's
    EXIT, its one liveness signal. Every event the session sends is recorded
    and echoed to the test; `deliver/1` runs the REAL decoder on a vendor frame
    and hands the session what the real client would.
    """

    @name __MODULE__.State

    def start_agent(test_pid),
      do: Agent.start_link(fn -> %{test_pid: test_pid, events: [], socket: nil} end, name: @name)

    def start_link(opts) do
      parent = Keyword.fetch!(opts, :parent)
      {:ok, socket} = Agent.start_link(fn -> parent end)
      Agent.update(@name, &%{&1 | socket: socket})
      send(test_pid(), {:socket_opened, socket, opts})
      {:ok, socket}
    end

    def send_event(_pid, event) do
      Agent.update(@name, &%{&1 | events: &1.events ++ [event]})
      send(test_pid(), {:sent, event})
      :ok
    end

    def close(socket), do: Agent.stop(socket)

    def events, do: Agent.get(@name, & &1.events)
    def socket, do: Agent.get(@name, & &1.socket)

    def deliver(frame) do
      socket = socket()
      {:ok, decoded} = XAIRealtimeClient.decode_server_event(frame)
      send(Agent.get(socket, & &1), {:xai_realtime_event, socket, decoded})
      :ok
    end

    defp test_pid, do: Agent.get(@name, & &1.test_pid)
  end

  defmodule RefusingXAI do
    def start_link(_opts),
      do: {:error, %WebSockex.RequestError{code: 401, message: "Unauthorized"}}
  end

  defmodule FakeBridge do
    @behaviour FermixCore.Realtime.VoiceBridge

    def start(test_pid) do
      Agent.start(
        fn ->
          %{test_pid: test_pid, callbacks: %{}, window: {:ok, %{messages: [], gists: []}}}
        end,
        name: __MODULE__
      )
    end

    def stop do
      case Process.whereis(__MODULE__) do
        nil -> :ok
        pid -> Agent.stop(pid)
      end
    end

    def set_window(window), do: Agent.update(__MODULE__, &%{&1 | window: window})

    def fire(task_id, revision, kind, payload) do
      callbacks = Agent.get(__MODULE__, &Map.fetch!(&1.callbacks, {task_id, revision}))
      Map.fetch!(callbacks, kind).(payload)
      :ok
    end

    @impl true
    def conversation_window(bounds) do
      send(test_pid(), {:bridge_window, bounds})
      Agent.get(__MODULE__, & &1.window)
    end

    @impl true
    def call_active?, do: false
    @impl true
    def chat_call(_key, _channel), do: :none

    @impl true
    def open_call(call) do
      send(test_pid(), {:bridge_open_call, call})
      {:ok, {:handle, call.call_id}}
    end

    @impl true
    def show(call, text) do
      send(test_pid(), {:bridge_show, call, text})
      {:ok, 42}
    end

    @impl true
    def submit(_handle, request, callbacks) do
      key = {request.delegation_id, request.revision}
      Agent.update(__MODULE__, &%{&1 | callbacks: Map.put(&1.callbacks, key, callbacks)})
      send(test_pid(), {:bridge_submit, request})
      {:ok, {:task, request.delegation_id, request.revision}}
    end

    @impl true
    def cancel(_handle, task_ref) do
      send(test_pid(), {:bridge_cancel, task_ref})
      :ok
    end

    @impl true
    def detach(_handle, task_ref, task) do
      send(test_pid(), {:bridge_detach, task_ref, task})
      {:ok, fn _event -> :ok end}
    end

    @impl true
    def close_call(handle) do
      send(test_pid(), {:bridge_close_call, handle})
      :ok
    end

    defp test_pid, do: Agent.get(__MODULE__, & &1.test_pid)
  end

  setup do
    {:ok, _bridge} = FakeBridge.start(self())
    on_exit(&FakeBridge.stop/0)
    start_supervised!(%{id: :fake_xai, start: {FakeXAI, :start_agent, [self()]}})
    start_supervised!({CallRegistry, name: @call_registry})
    clock = start_supervised!({Agent, fn -> 0 end}, id: :grok_clock)
    %{clock: clock}
  end

  describe "starting a call" do
    test "a session refuses any engine but xai_realtime" do
      Process.flag(:trap_exit, true)
      live = Config.normalize(enabled: true, engine: "openai_live", model: "gpt-live-1")

      assert {:error, {:invalid_engine, "openai_live"}} =
               GrokSessionServer.start_link(session_opts(config: live))
    end

    test "dials the pinned model with the key and configures exactly one function", %{
      clock: clock
    } do
      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)

      assert_received {:realtime, %{type: "state", state: "listening"}}
      assert_receive {:socket_opened, _socket, opts}
      assert opts[:url] == "wss://api.x.ai/v1/realtime?model=grok-voice-3.0"
      assert opts[:headers] == [{"Authorization", "Bearer xai-test"}]
      assert FakeXAI.events() == []

      deliver(%{"type" => "session.created", "session" => %{"id" => "sess_1"}})

      assert_receive {:sent, %{type: "session.update", session: session_config}}
      assert session_config.voice == "eve"
      assert session_config.turn_detection == %{type: "server_vad"}
      assert session_config.audio.input.format == %{type: "audio/pcm", rate: 24_000}
      assert session_config.reasoning == %{effort: "high"}
      assert session_config.resumption == %{enabled: false}
      assert [%{type: "function", name: "fermix_task"}] = session_config.tools
      refute Map.has_key?(session_config.turn_detection, :idle_timeout_ms)
    end

    test "a refused handshake answers the companion in the vendor's words", %{clock: clock} do
      session = start_session(clock: clock, client: RefusingXAI)

      assert {:error, :provider_refused} = SessionControl.call_start(session)

      assert_received {:realtime,
                       %{type: "error", kind: "provider_refused", detail: "401 Unauthorized"}}
    end

    test "call_ready waits for the context's acknowledgement and the bridge", %{clock: clock} do
      FakeBridge.set_window(
        {:ok,
         %{
           messages: [
             %{role: "user", content: "use the lease link", timestamp: ~U[2026-10-02 09:00:00Z]}
           ],
           gists: []
         }}
      )

      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)
      configure(session)

      items = for %{type: "conversation.item.create", item: item} <- FakeXAI.events(), do: item
      assert [%{role: "user"} = chat, %{role: "system"} = closing] = items
      assert [%{type: "input_text", text: "use the lease link"}] = chat.content
      assert hd(closing.content).text =~ "not a request"
      refute Enum.any?(FakeXAI.events(), &(&1.type == "response.create"))
      refute_received {:realtime, %{type: "call_ready"}}
      refute_received {:bridge_open_call, _call}

      ack(chat.id)
      refute_received {:realtime, %{type: "call_ready"}}

      ack(closing.id)
      sync(session)
      assert_received {:bridge_open_call, %{conversation: "chat"}}

      assert_received {:realtime,
                       %{
                         type: "call_ready",
                         engine: "xai_realtime",
                         provider_session_id: "sess_1"
                       }}

      assert :sys.get_state(session).ledger.text_items_sent == 2
    end

    test "a private call reads no chat and is ready once configured", %{clock: clock} do
      session = start_session(clock: clock, config: grok_config(conversation: "private"))
      ready(session)

      refute_received {:bridge_window, _bounds}
      assert_received {:realtime, %{type: "call_ready", conversation: "private"}}
    end

    test "audio said while the session starts is held, then sent first and in order", %{
      clock: clock
    } do
      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)
      :ok = SessionControl.audio_chunk(session, <<1, 2>>)
      :ok = SessionControl.audio_chunk(session, <<3, 4>>)
      sync(session)
      refute Enum.any?(FakeXAI.events(), &(&1.type == "input_audio_buffer.append"))

      configure(session)
      :ok = SessionControl.audio_chunk(session, <<5, 6>>)
      sync(session)

      assert appended_audio() == [<<1, 2>>, <<3, 4>>, <<5, 6>>]
    end

    test "an error before the session is ready ends the call with the vendor's reason", %{
      clock: clock
    } do
      Process.flag(:trap_exit, true)
      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)
      deliver(%{"type" => "session.created", "session" => %{"id" => "sess_1"}})

      deliver(%{
        "type" => "error",
        "error" => %{
          "type" => "invalid_request_error",
          "code" => "invalid_voice",
          "message" => "Unknown voice."
        }
      })

      assert_receive {:realtime, %{type: "error", kind: "provider_refused", detail: detail}}
      assert detail =~ "invalid_voice"
      assert_receive {:EXIT, ^session, {:shutdown, :provider_refused}}
    end
  end

  describe "fermix_task" do
    test "a submit runs a task on the owner's words and answers once, when it ends", %{
      clock: clock
    } do
      session = ready_session(clock)
      user_says(session, "u1", "book the meeting room at ten", clock)

      call(session, "r1", "call_1", %{action: "submit", request: "Book the room at 10am"})

      assert_receive {:bridge_submit, %{delegation_id: id, revision: 1, text: text}}
      assert text =~ "user: book the meeting room at ten"
      assert text =~ "voice model's summary of the request: Book the room at 10am"
      refute outputs() |> Enum.any?()

      :ok = FakeBridge.fire(id, 1, :result, {:ok, "The room is booked for 10am."})
      sync(session)

      assert [%{call_id: "call_1", output: output}] = outputs()

      assert Jason.decode!(output) == %{
               "status" => "completed",
               "task_id" => id,
               "result" => "The room is booked for 10am."
             }

      assert_received {:realtime, %{type: "task", delegation_id: ^id, status: "completed"}}
    end

    test "a task's id is the daemon's own, never reused by a later call", %{clock: clock} do
      Process.flag(:trap_exit, true)
      first = ready_session(clock)
      user_says(first, "u1", "book the room", clock)
      call(first, "r1", "call_1", %{action: "submit", request: "Book the room"})
      assert_receive {:bridge_submit, %{delegation_id: first_id}}
      :ok = SessionControl.call_stop(first)
      assert_receive {:EXIT, ^first, _reason}

      second = ready_session(clock)
      user_says(second, "u1", "book the room", clock)
      call(second, "r1", "call_1", %{action: "submit", request: "Book the room"})
      assert_receive {:bridge_submit, %{delegation_id: second_id}}

      refute second_id == first_id
    end

    test "a task asked for while the owner's words are still being transcribed waits for them",
         %{clock: clock} do
      session = ready_session(clock)
      deliver(%{"type" => "input_audio_buffer.speech_started", "item_id" => "u1"})
      deliver(%{"type" => "input_audio_buffer.speech_stopped", "item_id" => "u1"})
      call(session, "r1", "call_1", %{action: "submit", request: "Book the room"})
      refute_received {:bridge_submit, _request}

      deliver(%{
        "type" => "conversation.item.input_audio_transcription.completed",
        "item_id" => "u1",
        "transcript" => "book the meeting room"
      })

      expire_context_wait(session)

      assert_receive {:bridge_submit, %{text: text}}
      assert text =~ "user: book the meeting room"
    end

    test "the owner keeps talking while a task runs; its result is continued once", %{
      clock: clock
    } do
      session = ready_session(clock)
      user_says(session, "u1", "find the parking rules", clock)
      call(session, "r1", "call_1", %{action: "submit", request: "Find the parking rules"})
      deliver(response_done("r1"))
      assert_receive {:bridge_submit, %{delegation_id: id}}

      # Another question, answered by Grok's own response while the task runs.
      deliver(%{"type" => "input_audio_buffer.speech_started", "item_id" => "u2"})
      deliver(%{"type" => "input_audio_buffer.speech_stopped", "item_id" => "u2"})
      deliver(%{"type" => "response.created", "response" => %{"id" => "r2"}})

      :ok = FakeBridge.fire(id, 1, :result, {:ok, "Parking is free after six."})
      sync(session)
      assert [_output] = outputs()
      refute continuations() |> Enum.any?()

      deliver(response_done("r2"))
      sync(session)

      assert [%{response: %{metadata: %{"fermix_continuation" => _id}}}] = continuations()
    end

    test "a response Grok starts after the output consumes the continuation", %{clock: clock} do
      session = ready_session(clock)
      user_says(session, "u1", "check my calendar", clock)
      call(session, "r1", "call_1", %{action: "submit", request: "Check the calendar"})
      deliver(response_done("r1"))
      assert_receive {:bridge_submit, %{delegation_id: id}}

      deliver(%{"type" => "input_audio_buffer.speech_started", "item_id" => "u2"})
      :ok = FakeBridge.fire(id, 1, :result, {:ok, "You are free at three."})
      sync(session)
      assert [_output] = outputs()
      refute continuations() |> Enum.any?()

      deliver(%{"type" => "input_audio_buffer.speech_stopped", "item_id" => "u2"})
      deliver(%{"type" => "response.created", "response" => %{"id" => "r_vad"}})
      deliver(response_done("r_vad"))
      grace_over(session)

      assert continuations() == []
    end

    test "a call of an interrupted response still runs: interrupting stops audio only", %{
      clock: clock
    } do
      session = ready_session(clock)
      user_says(session, "u1", "book the room", clock)
      deliver(%{"type" => "response.created", "response" => %{"id" => "r1"}})
      :ok = SessionControl.interrupt(session, nil)

      call(session, "r1", "call_1", %{action: "submit", request: "Book the room"})

      assert_receive {:bridge_submit, %{delegation_id: _id}}
    end

    test "a repeated call runs once; a third task in flight is refused busy", %{clock: clock} do
      session = ready_session(clock)
      user_says(session, "u1", "do three things", clock)

      call(session, "r1", "call_1", %{action: "submit", request: "one"})
      call(session, "r1", "call_1", %{action: "submit", request: "one"})
      call(session, "r1", "call_2", %{action: "submit", request: "two"})
      call(session, "r1", "call_3", %{action: "submit", request: "three"})

      assert_receive {:bridge_submit, _first}
      refute_received {:bridge_submit, _second}

      assert [%{call_id: "call_3", output: busy}] = outputs()
      assert %{"status" => "busy"} = Jason.decode!(busy)
    end

    test "a cancel stops the task and answers both calls", %{clock: clock} do
      session = ready_session(clock)
      user_says(session, "u1", "book the room", clock)
      call(session, "r1", "call_1", %{action: "submit", request: "Book the room"})
      assert_receive {:bridge_submit, %{delegation_id: id}}

      user_says(session, "u2", "stop that", clock)
      call(session, "r2", "call_2", %{action: "cancel", task_id: id})

      assert_receive {:bridge_cancel, {:task, ^id, 1}}
      statuses = for %{call_id: c, output: o} <- outputs(), do: {c, Jason.decode!(o)["status"]}
      assert statuses == [{"call_1", "cancelled"}, {"call_2", "cancelled"}]
    end

    test "only the owner's own words cancel or replace a task", %{clock: clock} do
      session = ready_session(clock)
      user_says(session, "u1", "book the room", clock)
      call(session, "r1", "call_1", %{action: "submit", request: "Book the room"})
      assert_receive {:bridge_submit, %{delegation_id: id}}

      call(session, "r2", "call_2", %{action: "cancel", task_id: id})
      call(session, "r2", "call_3", %{action: "submit", request: "Book another", task_id: id})

      refute_received {:bridge_cancel, _ref}
      reasons = for %{call_id: c, output: o} <- outputs(), do: {c, Jason.decode!(o)["reason"]}
      assert reasons == [{"call_2", "no_owner_words"}, {"call_3", "no_owner_words"}]
    end

    test "a corrected request replaces the running revision, whose late answer never speaks", %{
      clock: clock
    } do
      session = ready_session(clock)
      user_says(session, "u1", "book the room at ten", clock)
      call(session, "r1", "call_1", %{action: "submit", request: "Book at ten"})
      assert_receive {:bridge_submit, %{delegation_id: id, revision: 1}}

      user_says(session, "u2", "no, make it eleven", clock)
      call(session, "r2", "call_2", %{action: "submit", request: "Book at eleven", task_id: id})

      assert_receive {:bridge_cancel, {:task, ^id, 1}}
      assert_receive {:bridge_submit, %{delegation_id: ^id, revision: 2, text: text}}
      assert text =~ "make it eleven"
      assert [%{call_id: "call_1", output: superseded}] = outputs()
      assert %{"status" => "superseded", "task_id" => ^id} = Jason.decode!(superseded)

      :ok = FakeBridge.fire(id, 1, :result, {:ok, "Booked at ten."})
      sync(session)
      assert length(outputs()) == 1

      :ok = FakeBridge.fire(id, 2, :result, {:ok, "Booked at eleven."})
      sync(session)
      assert [_superseded, %{call_id: "call_2", output: done}] = outputs()
      assert %{"status" => "completed", "result" => "Booked at eleven."} = Jason.decode!(done)
    end

    test "replacing a task that already ended is refused, and the call goes on", %{clock: clock} do
      session = ready_session(clock)
      user_says(session, "u1", "book the room", clock)
      call(session, "r1", "call_1", %{action: "submit", request: "Book the room"})
      assert_receive {:bridge_submit, %{delegation_id: id}}
      :ok = FakeBridge.fire(id, 1, :result, {:ok, "Booked."})

      user_says(session, "u2", "actually make it seven", clock)
      call(session, "r2", "call_2", %{action: "submit", request: "Make it seven", task_id: id})

      assert [_completed, %{call_id: "call_2", output: refused}] = outputs()
      assert %{"status" => "rejected", "reason" => "unknown_task"} = Jason.decode!(refused)
      assert Process.alive?(session)
    end

    test "refuses what it cannot run, with one output each", %{clock: clock} do
      session = ready_session(clock)
      user_says(session, "u1", "hello", clock)

      call(session, "r1", "c_unknown_task", %{action: "cancel", task_id: "t99"})
      call(session, "r1", "c_invalid", %{action: "submit"})
      call(session, "r1", "c_other", %{action: "submit", request: "x"}, "web_search")

      reasons = for %{call_id: c, output: o} <- outputs(), do: {c, Jason.decode!(o)["reason"]}

      assert reasons == [
               {"c_unknown_task", "unknown_task"},
               {"c_invalid", "missing_request"},
               {"c_other", "unknown_function"}
             ]

      refute_received {:bridge_submit, _request}
    end

    test "every call is one tool event under its advertised name", %{clock: clock} do
      handler = attach_tool_handler()
      session = ready_session(clock)
      user_says(session, "u1", "book it", clock)

      call(session, "r1", "call_1", %{action: "submit", request: "Book it"})
      assert_receive {:bridge_submit, %{delegation_id: id}}
      call(session, "r1", "call_2", %{action: "cancel", task_id: "t404"})
      :ok = FakeBridge.fire(id, 1, :result, {:ok, "Booked."})
      sync(session)

      assert_receive {:tool_exec, %{tool: "fermix_task", status: "rejected", action: "cancel"}}
      assert_receive {:tool_exec, %{tool: "fermix_task", status: "completed", action: "submit"}}
      refute_received {:tool_exec, _meta}
      :telemetry.detach(handler)
    end
  end

  describe "playback" do
    test "audio carries a playback id and the reply plays out on the client's drain", %{
      clock: clock
    } do
      session = ready_session(clock)
      deliver(%{"type" => "response.created", "response" => %{"id" => "r1"}})
      deliver(audio_delta("r1", "a1"))
      sync(session)

      assert_received {:realtime, %{type: "state", state: "speaking"}}
      assert_received {:realtime, %{type: "audio_delta", playback_id: playback_id, audio: @chunk}}

      deliver(response_done("r1"))
      :ok = SessionControl.playback_progress(session, playback_id, 100, true)

      assert_received {:realtime, %{type: "state", state: "listening"}}
    end

    test "a report the daemon cannot match is refused", %{clock: clock} do
      session = ready_session(clock)

      assert {:error, :unknown_playback} =
               SessionControl.playback_progress(session, "p404", 0, false)
    end

    test "speech over a playing reply flushes it and cuts the item where it was heard", %{
      clock: clock
    } do
      session = ready_session(clock)
      deliver(%{"type" => "response.created", "response" => %{"id" => "r1"}})
      deliver(audio_delta("r1", "a1"))
      deliver(audio_delta("r1", "a1"))
      sync(session)
      assert_received {:realtime, %{type: "audio_delta", playback_id: playback_id}}
      :ok = SessionControl.playback_progress(session, playback_id, 120, false)

      deliver(%{"type" => "input_audio_buffer.speech_started", "item_id" => "u2"})
      sync(session)

      assert_received {:realtime, %{type: "playback_stop"}}

      assert [%{type: "conversation.item.truncate", item_id: "a1", audio_end_ms: 120}] =
               Enum.filter(FakeXAI.events(), &(&1.type == "conversation.item.truncate"))

      flush_frames()
      deliver(audio_delta("r1", "a1"))
      sync(session)
      refute_received {:realtime, %{type: "audio_delta"}}

      deliver(%{
        "type" => "conversation.item.truncated",
        "item_id" => "a1",
        "content_index" => 0,
        "audio_end_ms" => 120,
        "transcript" => "The weather"
      })

      sync(session)
      assert_received {:realtime, %{type: "caption", speaker: "assistant", delta: "The weather"}}
    end

    test "audio left unacknowledged ends the call", %{clock: clock} do
      Process.flag(:trap_exit, true)
      session = ready_session(clock)
      deliver(%{"type" => "response.created", "response" => %{"id" => "r1"}})
      deliver(audio_delta("r1", "a1"))
      %{ack_timer: {_timer, token, _heard}} = :sys.get_state(session)

      send(session, {:ack_timeout, token})

      assert_receive {:realtime, %{type: "error", reason: "playback_stalled"}}
      assert_receive {:EXIT, ^session, {:shutdown, :playback_stalled}}
    end

    test "a client repeating the same offset is still a stalled client", %{clock: clock} do
      Process.flag(:trap_exit, true)
      session = ready_session(clock)
      deliver(%{"type" => "response.created", "response" => %{"id" => "r1"}})
      deliver(audio_delta("r1", "a1"))
      sync(session)
      assert_received {:realtime, %{type: "audio_delta", playback_id: playback_id}}
      %{ack_timer: {_timer, first, _heard}} = :sys.get_state(session)

      # It played some, so the first watch ends in another, not in a stall.
      :ok = SessionControl.playback_progress(session, playback_id, 40, false)
      send(session, {:ack_timeout, first})
      %{ack_timer: {_timer, second, _heard}} = :sys.get_state(session)

      # Then it sticks: reports that move nothing neither reset the watch nor
      # satisfy it.
      :ok = SessionControl.playback_progress(session, playback_id, 40, false)
      deliver(audio_delta("r1", "a1"))
      assert %{ack_timer: {_timer, ^second, _heard}} = :sys.get_state(session)

      send(session, {:ack_timeout, second})
      assert_receive {:EXIT, ^session, {:shutdown, :playback_stalled}}
    end

    test "a client still playing is watched again, not ended", %{clock: clock} do
      session = ready_session(clock)
      deliver(%{"type" => "response.created", "response" => %{"id" => "r1"}})
      deliver(audio_delta("r1", "a1"))
      deliver(audio_delta("r1", "a1"))
      sync(session)
      assert_received {:realtime, %{type: "audio_delta", playback_id: playback_id}}
      %{ack_timer: {_timer, token, _heard}} = :sys.get_state(session)
      :ok = SessionControl.playback_progress(session, playback_id, 80, false)

      send(session, {:ack_timeout, token})

      assert %{ack_timer: {_timer, new_token, _heard}} = :sys.get_state(session)
      refute new_token == token
      assert Process.alive?(session)
    end
  end

  describe "captions" do
    test "each finished utterance is captioned once, on the call's clock", %{clock: clock} do
      session = ready_session(clock)
      user_says(session, "u1", "what time is it", clock)

      assert_received {:realtime,
                       %{
                         type: "caption",
                         speaker: "user",
                         delta: "what time is it",
                         start_ms: 1_000,
                         end_ms: 2_000
                       }}

      deliver(%{"type" => "response.created", "response" => %{"id" => "r1"}})
      deliver(audio_delta("r1", "a1"))

      for delta <- ["It is ", "three."] do
        deliver(%{
          "type" => "response.output_audio_transcript.delta",
          "response_id" => "r1",
          "item_id" => "a1",
          "delta" => delta
        })
      end

      deliver(%{
        "type" => "response.output_audio_transcript.done",
        "response_id" => "r1",
        "item_id" => "a1"
      })

      sync(session)
      assert_received {:realtime, %{type: "audio_delta", playback_id: playback_id}}
      refute_received {:realtime, %{type: "caption", speaker: "assistant"}}

      :ok = SessionControl.playback_progress(session, playback_id, 100, true)

      assert_received {:realtime, %{type: "caption", speaker: "assistant", delta: "It is three."}}
      refute_received {:realtime, %{type: "caption", speaker: "assistant"}}
    end

    test "a reply cut after its words were final is captioned once, as far as it was heard", %{
      clock: clock
    } do
      session = ready_session(clock)
      deliver(%{"type" => "response.created", "response" => %{"id" => "r1"}})
      deliver(audio_delta("r1", "a1"))
      deliver(audio_delta("r1", "a1"))

      deliver(%{
        "type" => "response.output_audio_transcript.delta",
        "response_id" => "r1",
        "item_id" => "a1",
        "delta" => "The weather today is sunny."
      })

      deliver(%{
        "type" => "response.output_audio_transcript.done",
        "response_id" => "r1",
        "item_id" => "a1"
      })

      sync(session)
      assert_received {:realtime, %{type: "audio_delta", playback_id: playback_id}}
      :ok = SessionControl.playback_progress(session, playback_id, 60, false)

      deliver(%{"type" => "input_audio_buffer.speech_started", "item_id" => "u2"})

      deliver(%{
        "type" => "conversation.item.truncated",
        "item_id" => "a1",
        "content_index" => 0,
        "audio_end_ms" => 60,
        "transcript" => "The weather"
      })

      sync(session)
      assert_received {:realtime, %{type: "caption", speaker: "assistant", delta: "The weather"}}
      refute_received {:realtime, %{type: "caption", speaker: "assistant"}}
    end
  end

  describe "the chat, mirrored" do
    test "a typed line reaches a call in the chat as one quiet system item", %{clock: clock} do
      session = ready_session(clock)
      :ok = SessionControl.chat_typed(session, "use https://x.test/lease")
      sync(session)

      assert [
               %{
                 item: %{
                   role: "system",
                   content: [%{text: "The owner typed in the chat: use https://x.test/lease"}]
                 }
               }
             ] =
               Enum.filter(FakeXAI.events(), &(&1.type == "conversation.item.create"))

      refute Enum.any?(FakeXAI.events(), &(&1.type == "response.create"))
      assert :sys.get_state(session).ledger.text_items_sent == 1
    end

    test "a private call is told nothing", %{clock: clock} do
      session = start_session(clock: clock, config: grok_config(conversation: "private"))
      ready(session)
      :ok = SessionControl.chat_typed(session, "use https://x.test/lease")
      sync(session)

      assert Enum.filter(FakeXAI.events(), &(&1.type == "conversation.item.create")) == []
    end

    test "an answer drawn from Computer History is withheld when only OpenAI is granted", %{
      clock: clock
    } do
      prior = Application.get_env(:fermix_core, :computer_history)

      Application.put_env(:fermix_core, :computer_history,
        enabled: true,
        summarizer: :local,
        remote_summaries: [:openai]
      )

      on_exit(fn -> restore(:computer_history, prior) end)
      session = ready_session(clock)

      tainted = %{
        role: "assistant",
        content: "You were editing the Q3 report.",
        history_tainted: true
      }

      :ok = SessionControl.chat_answered(session, tainted)
      sync(session)

      assert Enum.filter(FakeXAI.events(), &(&1.type == "conversation.item.create")) == []
    end
  end

  describe "the end of a call" do
    test "a call in the chat hands its running task over and settles incomplete", %{
      clock: clock
    } do
      Process.flag(:trap_exit, true)
      handler = attach_call_stop_handler()
      session = ready_session(clock)
      user_says(session, "u1", "summarise the report", clock)
      call(session, "r1", "call_1", %{action: "submit", request: "Summarise the report"})
      assert_receive {:bridge_submit, %{delegation_id: id}}
      Agent.update(clock, fn _ms -> 90_000 end)

      :ok = SessionControl.call_stop(session)

      assert_received {:bridge_detach, {:task, ^id, 1},
                       %{engine: "xai_realtime", provider: "xai"}}

      assert_received {:realtime, %{type: "task", delegation_id: ^id, detached: true}}

      assert_received {:realtime,
                       %{
                         type: "usage",
                         accounting: "incomplete",
                         voice_text_items: 0,
                         voice_cost_cents: cents
                       }}

      assert cents == 12.0

      assert_received {:call_stop, %{voice_cost_millicents: 12_000},
                       %{engine: "xai_realtime", provider: "xai", reason: "call_stop"}}

      :telemetry.detach(handler)
    end

    test "call_stop carries how long the owner waited, apart from the bill", %{clock: clock} do
      Process.flag(:trap_exit, true)
      handler = attach_call_stop_handler()
      session = ready_session(clock)
      user_says(session, "u1", "what time is it", clock)

      Agent.update(clock, fn _ms -> 2_300 end)
      deliver(%{"type" => "response.created", "response" => %{"id" => "r1"}})
      deliver(audio_delta("r1", "a1"))
      sync(session)
      assert_received {:realtime, %{type: "audio_delta", playback_id: playback_id}}

      Agent.update(clock, fn _ms -> 2_600 end)
      :ok = SessionControl.playback_progress(session, playback_id, 50, false)
      :ok = SessionControl.call_stop(session)

      assert_received {:call_stop, measurements, _meta}

      assert %{
               user_turns: 1,
               generation_latency_ms_median: 300,
               audible_latency_ms_median: 600
             } = measurements

      :telemetry.detach(handler)
    end

    test "the provider's socket going away ends the call", %{clock: clock} do
      Process.flag(:trap_exit, true)
      session = ready_session(clock)

      Process.exit(FakeXAI.socket(), :kill)

      assert_receive {:realtime, %{type: "error", kind: "provider_disconnected"}}
      assert_receive {:EXIT, ^session, {:shutdown, :provider_disconnected}}
    end

    test "the budget ends a silent call at its own deadline", %{clock: clock} do
      Process.flag(:trap_exit, true)
      session = start_session(clock: clock, config: grok_config(cost_cents: 8))
      ready(session)
      Agent.update(clock, &(&1 + 60_000))

      send(session, :ceiling)

      assert_receive {:realtime, %{type: "error", kind: "cost_limit"}}
      assert_receive {:EXIT, ^session, {:shutdown, :cost_limit}}
    end

    test "a configured duration past Grok's 120 minutes is capped", %{clock: clock} do
      session = start_session(clock: clock, config: grok_config(minutes: 240))
      assert :sys.get_state(session).max_duration_ms == 120 * 60_000
    end
  end

  test "a second call is refused while one is up", %{clock: clock} do
    Process.flag(:trap_exit, true)
    _session = start_session(clock: clock)

    assert {:error, :call_in_progress} = GrokSessionServer.start_link(session_opts(clock: clock))
  end

  ## Helpers

  defp start_session(opts) do
    {:ok, session} = GrokSessionServer.start_link(session_opts(opts))
    on_exit(fn -> await_down(session) end)
    session
  end

  defp session_opts(opts) do
    [
      companion: self(),
      config: grok_config(),
      api_key: "xai-test",
      device_id: "device-1",
      session_scope: "voice_live:#{System.unique_integer([:positive, :monotonic])}",
      client: FakeXAI,
      voice_bridge: FakeBridge,
      call_registry: @call_registry,
      prompt: "## Role & Persona\nYou are Fermix.",
      unix_clock: fn -> 1_000 end,
      gist: []
    ]
    |> Keyword.merge(opts)
    |> Keyword.update(:clock, fn -> 0 end, fn agent -> fn -> Agent.get(agent, & &1) end end)
  end

  defp grok_config(opts \\ []) do
    Config.normalize(
      enabled: true,
      engine: "xai_realtime",
      model: "grok-voice-3.0",
      voice: "eve",
      max_session_minutes: Keyword.get(opts, :minutes, 15),
      max_estimated_cost_cents_per_session: Keyword.get(opts, :cost_cents, 100),
      conversation: Keyword.get(opts, :conversation)
    )
  end

  defp ready_session(clock) do
    session = start_session(clock: clock)
    ready(session)
    flush_frames()
    session
  end

  # A started call with no chat to prime: ready as soon as it is configured.
  defp ready(session) do
    :ok = SessionControl.call_start(session)
    configure(session)
  end

  defp configure(session) do
    deliver(%{"type" => "session.created", "session" => %{"id" => "sess_1"}})

    deliver(%{
      "type" => "session.updated",
      "session" => %{"turn_detection" => %{"type" => "server_vad"}}
    })

    sync(session)
  end

  defp ack(item_id) do
    deliver(%{
      "type" => "conversation.item.added",
      "item" => %{"id" => item_id, "type" => "message", "role" => "user"}
    })
  end

  # The owner says `text` between 1 s and 2 s after the call started, as VAD
  # and the transcription report it.
  defp user_says(session, item_id, text, clock) do
    Agent.update(clock, &max(&1, 1_000))
    deliver(%{"type" => "input_audio_buffer.speech_started", "item_id" => item_id})
    sync(session)
    Agent.update(clock, &max(&1 + 1_000, 2_000))
    deliver(%{"type" => "input_audio_buffer.speech_stopped", "item_id" => item_id})

    deliver(%{
      "type" => "conversation.item.input_audio_transcription.completed",
      "item_id" => item_id,
      "transcript" => text
    })

    sync(session)
  end

  defp call(session, response_id, call_id, args, name \\ "fermix_task") do
    deliver(%{
      "type" => "response.function_call_arguments.done",
      "response_id" => response_id,
      "item_id" => "fc_" <> call_id,
      "call_id" => call_id,
      "name" => name,
      "arguments" => Jason.encode!(args)
    })

    sync(session)
  end

  defp response_done(response_id),
    do: %{
      "type" => "response.done",
      "response" => %{"id" => response_id, "status" => "completed"}
    }

  defp audio_delta(response_id, item_id) do
    %{
      "type" => "response.output_audio.delta",
      "response_id" => response_id,
      "item_id" => item_id,
      "content_index" => 0,
      "delta" => @chunk
    }
  end

  # The one bounded wait for a task's words, delivered by hand.
  defp expire_context_wait(session) do
    %{tasks: %{context_timers: timers}} = :sys.get_state(session)

    Enum.each(timers, fn {task_id, {_timer, revision}} ->
      send(session, {:context_wait_expired, task_id, revision})
    end)

    sync(session)
  end

  defp grace_over(session) do
    case :sys.get_state(session).vad_timer do
      {_timer, token} -> send(session, {:vad_grace_over, token})
      nil -> :ok
    end

    sync(session)
  end

  defp outputs do
    for %{type: "conversation.item.create", item: %{type: "function_call_output"} = item} <-
          FakeXAI.events(),
        do: item
  end

  defp continuations, do: Enum.filter(FakeXAI.events(), &(&1.type == "response.create"))

  defp appended_audio do
    for %{type: "input_audio_buffer.append", audio: audio} <- FakeXAI.events(),
        do: Base.decode64!(audio)
  end

  defp deliver(frame), do: FakeXAI.deliver(frame)

  defp sync(session), do: :sys.get_state(session)

  defp flush_frames do
    receive do
      {:realtime, _frame} -> flush_frames()
    after
      0 -> :ok
    end
  end

  defp attach_tool_handler do
    handler_id = "grok-tool-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:fermix, :tool, :exec],
      fn _event, _measurements, meta, _config ->
        if meta.tool == "fermix_task" and
             String.starts_with?(meta[:session_id] || "", "voice_live:"),
           do: send(test_pid, {:tool_exec, meta})
      end,
      nil
    )

    handler_id
  end

  defp attach_call_stop_handler do
    handler_id = "grok-call-stop-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:fermix, :voice_live, :call_stop],
      fn _event, measurements, meta, _config ->
        if meta.engine == "xai_realtime", do: send(test_pid, {:call_stop, measurements, meta})
      end,
      nil
    )

    handler_id
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)

  defp await_down(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      2_000 -> raise "the grok session never stopped"
    end
  end
end
