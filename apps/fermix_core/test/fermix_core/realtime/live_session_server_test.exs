defmodule FermixCore.Realtime.LiveSessionServerTest do
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.AccessGate.Pending, as: AccessPending
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.Repo
  alias FermixCore.Prompt.CurrentDate
  alias FermixCore.Realtime.CallRegistry
  alias FermixCore.Realtime.CallSpeech
  alias FermixCore.Realtime.CallSweep
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.LiveChat
  alias FermixCore.Realtime.LiveSessionServer
  alias FermixCore.Realtime.LiveText
  alias FermixCore.Realtime.LiveTranscript
  alias FermixCore.Realtime.OpenAILiveClient
  alias FermixCore.Realtime.SessionControl

  @moduletag :capture_log

  @live_title "# LIVE.md — Live Voice Companion"
  @closed_seconds 120.5
  @uuid_v4 ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  # This module's own registry, started fresh for every test: the daemon's is
  # under the realtime supervisor, which the suite never starts.
  @call_registry Module.concat(__MODULE__, CallRegistry)

  defmodule FakeLiveClient do
    @moduledoc """
    Records every event the session sends and answers `session.close` the way
    the provider does — from inside the send, which runs in the session's own
    process, so the reply is already in the mailbox when the close handshake's
    selective receive runs.

    The recorder is a named agent the TEST owns, not one the session spawns, so
    what a call put on the wire is still readable after that call has ended.
    """

    @name __MODULE__.State

    def start_agent(test_pid) do
      Agent.start_link(
        fn -> %{test_pid: test_pid, events: [], closed?: false, answer_close?: true} end,
        name: @name
      )
    end

    def start_link(opts) do
      Agent.update(@name, &Map.put(&1, :parent, Keyword.fetch!(opts, :parent)))
      {:ok, Process.whereis(@name)}
    end

    def send_event(_pid, %{type: "session.close"} = event) do
      record(event)
      answer_close(Agent.get(@name, & &1))
      :ok
    end

    def send_event(_pid, event), do: record(event)

    def close(_pid), do: Agent.update(@name, &%{&1 | closed?: true})
    def events, do: Agent.get(@name, & &1.events)
    def closed?, do: Agent.get(@name, & &1.closed?)

    @doc "Stop answering `session.close`, the way a socket that is already gone behaves."
    def silence_close, do: Agent.update(@name, &%{&1 | answer_close?: false})

    @doc """
    A raw text frame arrives on the socket: the REAL `OpenAILiveClient.handle_frame/2`
    runs inside this process, where WebSockex runs it.
    """
    def deliver_frame(payload) when is_binary(payload) do
      {:ok, _state} =
        Agent.get(@name, &OpenAILiveClient.handle_frame({:text, payload}, %{parent: &1.parent}))

      :ok
    end

    defp answer_close(%{answer_close?: true, parent: parent}) do
      send(parent, {:openai_live_event, {:session_closed, "close_requested", 120.5}})
    end

    defp answer_close(_state), do: :ok

    defp record(event) do
      Agent.update(@name, fn state -> %{state | events: state.events ++ [event]} end)
      :ok
    end
  end

  defmodule FakeBridge do
    @moduledoc """
    A `VoiceBridge` that records what the session asked for and hands the test
    the callbacks, so a result or a cancellation is fired deliberately rather
    than waited for.
    """

    @behaviour FermixCore.Realtime.VoiceBridge

    # Deliberately NOT linked to the test process: a session settles its call in
    # `terminate/2`, which runs while the test process is already exiting, and a
    # bridge that died first would make every test log a close failure that the
    # product does not have.
    def start(test_pid) do
      Agent.start(
        fn ->
          %{
            test_pid: test_pid,
            submits: [],
            cancels: [],
            closed: 0,
            callbacks: %{},
            window: {:ok, %{messages: [], gists: []}}
          }
        end,
        name: __MODULE__
      )
    end

    @doc "What the next `conversation_window/1` answers."
    def set_window(result), do: Agent.update(__MODULE__, &%{&1 | window: result})

    @impl true
    def conversation_window(bounds) do
      send(test_pid(), {:bridge_window, bounds})
      Agent.get(__MODULE__, & &1.window)
    end

    def stop do
      case Process.whereis(__MODULE__) do
        nil -> :ok
        pid -> Agent.stop(pid)
      end
    end

    @impl true
    def call_active?, do: false

    @impl true
    def chat_call(_key), do: :none

    @impl true
    def open_call(call) do
      Agent.update(__MODULE__, fn state -> Map.put(state, :call, call) end)
      send(test_pid(), {:bridge_open_call, call})
      {:ok, {:handle, call.call_id}}
    end

    @impl true
    def submit(handle, request, callbacks) do
      Agent.update(__MODULE__, fn state ->
        %{
          state
          | submits: state.submits ++ [request],
            callbacks: Map.put(state.callbacks, request.delegation_id, callbacks)
        }
      end)

      send(test_pid(), {:bridge_submit, handle, request})
      {:ok, {:task, request.delegation_id}}
    end

    @impl true
    def cancel(_handle, task_ref) do
      Agent.update(__MODULE__, fn state -> %{state | cancels: state.cancels ++ [task_ref]} end)
      send(test_pid(), {:bridge_cancel, task_ref})
      :ok
    end

    @impl true
    def close_call(handle) do
      Agent.update(__MODULE__, fn state -> %{state | closed: state.closed + 1} end)
      send(test_pid(), {:bridge_close_call, handle})
      :ok
    end

    def submits, do: Agent.get(__MODULE__, & &1.submits)
    def cancels, do: Agent.get(__MODULE__, & &1.cancels)
    def closed, do: Agent.get(__MODULE__, & &1.closed)

    def fire(delegation_id, kind, payload) do
      callbacks = Agent.get(__MODULE__, &Map.fetch!(&1.callbacks, delegation_id))
      Map.fetch!(callbacks, kind).(payload)
      :ok
    end

    defp test_pid, do: Agent.get(__MODULE__, & &1.test_pid)
  end

  defmodule RefusingBridge do
    @behaviour FermixCore.Realtime.VoiceBridge

    @impl true
    def conversation_window(_bounds), do: {:ok, %{messages: [], gists: []}}
    @impl true
    def call_active?, do: false
    @impl true
    def chat_call(_key), do: :none
    @impl true
    def open_call(_call), do: {:error, :no_queue}
    @impl true
    def submit(_handle, _request, _callbacks), do: {:error, :queue_down}
    @impl true
    def cancel(_handle, _ref), do: :ok
    @impl true
    def close_call(_handle), do: :ok
  end

  defmodule RefusingLiveClient do
    @moduledoc """
    The provider refusing the WebSocket handshake, the way it answers a stale
    key: `start_link/1` never returns a pid, only the vendor's own words.
    """

    def start_link(_opts),
      do: {:error, %WebSockex.RequestError{code: 401, message: "Unauthorized"}}
  end

  defmodule FakeRecorder do
    def record_caption(config, device_id, speaker, delta, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:record_caption, config, device_id, speaker, delta, opts}
      )

      :ok
    end
  end

  setup do
    {:ok, _bridge} = FakeBridge.start(self())
    on_exit(&FakeBridge.stop/0)
    start_supervised!(%{id: :fake_live_client, start: {FakeLiveClient, :start_agent, [self()]}})
    start_supervised!({CallRegistry, name: @call_registry})
    clock = start_supervised!({Agent, fn -> 0 end}, id: :live_clock)
    %{clock: clock}
  end

  describe "call_start" do
    test "sends session.start and nothing else until the provider accepts", %{clock: clock} do
      session = start_session(clock: clock)

      assert :ok = SessionControl.call_start(session)

      assert [%{type: "session.start"}] = FakeLiveClient.events()
    end

    test "audio before session.started is dropped and never sent", %{clock: clock} do
      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)

      :ok = SessionControl.audio_chunk(session, <<1, 2, 3, 4>>)
      sync(session)

      assert [%{type: "session.start"}] = FakeLiveClient.events()

      start_provider_session(session)
      :ok = SessionControl.audio_chunk(session, <<1, 2, 3, 4>>)
      sync(session)

      assert Enum.any?(FakeLiveClient.events(), &(&1.type == "session.input_audio.append"))
    end

    test "the session.start payload carries the LIVE.md prompt and no Realtime-only key", %{
      clock: clock
    } do
      registry = start_capability_registry()
      session = start_session(clock: clock, prompt: nil, capability_registry: registry)

      :ok = SessionControl.call_start(session)
      [%{type: "session.start", session: payload}] = FakeLiveClient.events()

      assert payload.instructions =~ @live_title
      assert payload.instructions =~ "Backend tools:"
      assert payload.instructions =~ "read_file"
      assert payload.store == false
      assert payload.delegation == %{type: "client"}
      assert payload.audio.output.voice == "marin"
      assert payload.audio.format == %{type: "audio/pcm", rate: 24_000}

      keys = payload |> Map.keys() |> Enum.map(&to_string/1)
      assert Enum.sort(keys) == ~w(audio delegation instructions model store)
    end

    # M56 §4.3 (D5): generated in code at the start of every call, after
    # LIVE.md, so an owner's edit to LIVE.md can never shadow it.
    test "the instructions name the assistant and the owner and carry today's date", %{
      clock: clock
    } do
      saved = Map.new([:agent, :personalization], &{&1, Application.fetch_env(:fermix_core, &1)})
      on_exit(fn -> Enum.each(saved, &restore_core_env/1) end)
      Application.put_env(:fermix_core, :agent, name: "Nova")
      Application.put_env(:fermix_core, :personalization, user_name: "Sujeeth")

      session =
        start_session(clock: clock, prompt: nil, capability_registry: start_capability_registry())

      :ok = SessionControl.call_start(session)
      [%{type: "session.start", session: payload}] = FakeLiveClient.events()

      assert payload.instructions =~ "Your name is Nova."
      assert payload.instructions =~ "## The owner\n\n- Name: Sujeeth"
      assert payload.instructions =~ CurrentDate.note()
    end

    test "a v1-shaped realtime key never appears in any Live payload", %{clock: clock} do
      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)
      start_provider_session(session)

      :ok = SessionControl.audio_chunk(session, <<1, 2, 3, 4>>)
      :ok = SessionControl.mute(session, true)
      :ok = SessionControl.interrupt(session, 120)
      sync(session)

      keys =
        FakeLiveClient.events()
        |> Enum.flat_map(&payload_keys/1)
        |> Enum.uniq()

      for key <- ~w(reasoning turn_detection transcription max_output_tokens tools tool_choice
                    response item conversation output_modalities) do
        refute key in keys
      end

      for %{type: type} <- FakeLiveClient.events() do
        assert String.starts_with?(type, "session.")
      end
    end

    test "refuses the call when no voice bridge is registered", %{clock: clock} do
      registered = Application.get_env(:fermix_core, :voice_bridge)
      Application.delete_env(:fermix_core, :voice_bridge)
      on_exit(fn -> restore_voice_bridge(registered) end)

      session = start_session(clock: clock, voice_bridge: nil)

      assert {:error, :voice_bridge_unavailable} = SessionControl.call_start(session)

      assert_receive {:realtime,
                      %{
                        type: "error",
                        reason: "voice_bridge_unavailable",
                        kind: "bridge_unavailable"
                      }}
    end

    test "a refused provider handshake answers provider_refused and quotes the vendor", %{
      clock: clock
    } do
      Process.flag(:trap_exit, true)
      scope = "voice_live:refused_#{System.unique_integer([:positive, :monotonic])}"
      attach_provider_error_handler(scope)

      session =
        start_session(clock: clock, live_client: RefusingLiveClient, session_scope: scope)

      assert {:error, :provider_refused} = SessionControl.call_start(session)

      assert_receive {:realtime,
                      %{
                        type: "error",
                        reason: "provider_refused",
                        kind: "provider_refused",
                        detail: "401 Unauthorized"
                      }}

      # The trace has to carry the same sentence: a bare `provider_refused` is a
      # status word, not a diagnosis.
      assert_receive {:provider_error, %{session_id: ^scope, reason: "401 Unauthorized"}}

      # The refusal is not a crash: the session is still there to be hung up.
      assert Process.alive?(session)
      assert :ok = SessionControl.call_stop(session)
      assert_receive {:EXIT, ^session, {:shutdown, :call_stop}}
    end

    test "ends the call when the bridge refuses to open it", %{clock: clock} do
      Process.flag(:trap_exit, true)
      session = start_session(clock: clock, voice_bridge: RefusingBridge)
      :ok = SessionControl.call_start(session)

      send_session_started(session)

      assert_receive {:realtime, %{type: "error", kind: "bridge_unavailable"}}
      assert_receive {:EXIT, ^session, {:shutdown, :bridge_unavailable}}
    end
  end

  # M56 §4.3 (D5, D6): a call in the chat's conversation starts with the chat
  # as `session.input`, read through the bridge before `session.start`.
  describe "what a call starts with" do
    test "a chat call's session.start carries what the bridge reads of the chat", %{
      clock: clock
    } do
      window = %{
        messages: [
          %{role: "user", content: "here is the lease: https://x.test/lease"},
          %{role: "assistant", content: "Got it."}
        ],
        gists: ["Booked the dentist."]
      }

      FakeBridge.set_window({:ok, window})
      session = start_session(clock: clock)

      :ok = SessionControl.call_start(session)

      assert_received {:bridge_window, %{messages: 6, gists: 3}}
      [%{type: "session.start", session: payload}] = FakeLiveClient.events()
      assert payload.input == LiveChat.input(window)

      assert Enum.map(payload.input, & &1.role) ==
               ~w(developer user assistant developer)
    end

    test "an empty chat sends no session.input", %{clock: clock} do
      session = start_session(clock: clock)

      :ok = SessionControl.call_start(session)

      assert_received {:bridge_window, _bounds}
      [%{type: "session.start", session: payload}] = FakeLiveClient.events()
      refute Map.has_key?(payload, :input)
    end

    # M56 §5: a private call is kept apart from the chat, in both directions.
    test "a private call reads nothing of the chat and sends no input", %{clock: clock} do
      FakeBridge.set_window({:ok, %{messages: [%{role: "user", content: "x"}], gists: []}})
      session = start_session(clock: clock, config: live_config(conversation: "private"))

      :ok = SessionControl.call_start(session)

      refute_received {:bridge_window, _bounds}
      [%{type: "session.start", session: payload}] = FakeLiveClient.events()
      refute Map.has_key?(payload, :input)
    end

    # The same as a LIVE.md that cannot be read: the call does not start on
    # half of what it was meant to know, and the reason is on the frame.
    test "a chat the bridge cannot read refuses the call before any socket opens", %{
      clock: clock
    } do
      FakeBridge.set_window({:error, :store_unavailable})
      session = start_session(clock: clock)

      assert {:error, :store_unavailable} = SessionControl.call_start(session)

      assert_receive {:realtime, %{type: "error", reason: "store_unavailable"}}
      assert FakeLiveClient.events() == []
    end

    # M56 §8: one retry without the input, logged; the call proceeds. Before
    # `session.started` only `session.start` has been sent, and the provider's
    # error names the field it refused in `param`.
    test "a start refused over its input is sent once more without it", %{clock: clock} do
      scope = "voice_live:input_#{System.unique_integer([:positive, :monotonic])}"
      attach_provider_error_handler(scope)

      FakeBridge.set_window(
        {:ok, %{messages: [%{role: "user", content: "the lease"}], gists: []}}
      )

      session = start_session(clock: clock, session_scope: scope)
      :ok = SessionControl.call_start(session)
      [%{type: "session.start", session: first}] = FakeLiveClient.events()

      send(session, {:openai_live_event, {:error, input_refusal("session.input[0].content")}})
      sync(session)

      assert [_first, %{type: "session.start", session: second}] = FakeLiveClient.events()
      refute Map.has_key?(second, :input)
      assert second.instructions == first.instructions

      # Logged with the field and the code, never the vendor's message, which
      # may quote the chat text it refused.
      assert_receive {:provider_error, %{reason: reason}}
      assert reason =~ "session.input"
      refute reason =~ "the lease"

      start_provider_session(session)
      assert_receive {:realtime, %{type: "call_ready"}}
    end

    test "a second refusal over the input is not retried again", %{clock: clock} do
      FakeBridge.set_window({:ok, %{messages: [%{role: "user", content: "x"}], gists: []}})
      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)

      send(session, {:openai_live_event, {:error, input_refusal("session.input")}})
      send(session, {:openai_live_event, {:error, input_refusal("session.input")}})
      sync(session)

      assert [%{type: "session.start"}, %{type: "session.start"}] = FakeLiveClient.events()
    end

    test "a refusal naming any other field, or of a start with no input, is not retried", %{
      clock: clock
    } do
      FakeBridge.set_window({:ok, %{messages: [%{role: "user", content: "x"}], gists: []}})
      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)

      send(session, {:openai_live_event, {:error, input_refusal("session.audio.output.voice")}})
      send(session, {:openai_live_event, {:error, input_refusal("session.input_audio")}})
      sync(session)
      assert [%{type: "session.start"}] = FakeLiveClient.events()

      end_call(session)
      FakeBridge.set_window({:ok, %{messages: [], gists: []}})
      bare = start_session(clock: clock)
      :ok = SessionControl.call_start(bare)

      send(bare, {:openai_live_event, {:error, input_refusal("session.input")}})
      sync(bare)
      assert Enum.count(FakeLiveClient.events(), &(&1.type == "session.start")) == 2
    end

    test "call_start says how large the instructions and the input are, never what", %{
      clock: clock
    } do
      scope = "voice_live:sizes_#{System.unique_integer([:positive, :monotonic])}"
      attach_call_start_handler([scope])
      window = %{messages: [%{role: "user", content: "a private link"}], gists: []}
      FakeBridge.set_window({:ok, window})
      session = start_session(clock: clock, session_scope: scope)

      :ok = SessionControl.call_start(session)

      assert_receive {:call_start, metadata}
      [%{type: "session.start", session: payload}] = FakeLiveClient.events()
      assert metadata.instructions_bytes == byte_size(payload.instructions)
      assert %{input_items: 2, input_bytes: input_bytes} = metadata
      assert input_bytes == LiveChat.input_size(payload.input).input_bytes
      refute inspect(metadata) =~ "private link"
    end
  end

  describe "session.started" do
    test "announces call_ready then listening and opens the bridge call", %{clock: clock} do
      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)
      start_provider_session(session)

      assert_receive {:bridge_open_call, %{call_id: call_id, persist?: false} = call}

      assert_receive {:realtime,
                      %{
                        type: "call_ready",
                        engine: "openai_live",
                        call_id: ^call_id,
                        conversation: "chat",
                        provider_session_id: "sess_live_1",
                        expires_at: 1_060,
                        captions: true
                      }}

      assert_receive {:realtime, %{type: "state", state: "listening"}}

      # The bridge is told the call's durable identity and, the setting being
      # unset, that its hand-offs join the chat (M56 §4.1, §5).
      assert call.call_uuid == :sys.get_state(session).call_uuid
      assert call.conversation == "chat"
    end

    test "a private call opens its bridge call as private", %{clock: clock} do
      config = live_config(conversation: "private")
      session = start_session(clock: clock, config: config)
      :ok = SessionControl.call_start(session)
      start_provider_session(session)

      assert_receive {:bridge_open_call, %{conversation: "private"}}
      assert_receive {:realtime, %{type: "call_ready", conversation: "private"}}
    end

    test "expires_at shorter than max_session_minutes wins", %{clock: clock} do
      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)
      start_provider_session(session, expires_at: 1_060)

      assert :sys.get_state(session).max_duration_ms == 60_000
    end

    test "the configured cap wins when the provider expiry is further out", %{clock: clock} do
      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)
      start_provider_session(session, expires_at: 99_999)

      assert :sys.get_state(session).max_duration_ms == 15 * 60_000
    end
  end

  describe "call identity" do
    test "one UUID names the call on call_ready, every task and every usage frame", %{
      clock: clock
    } do
      Process.flag(:trap_exit, true)
      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)
      start_provider_session(session)

      assert_receive {:realtime, %{type: "call_ready", call_uuid: uuid}}
      assert uuid =~ @uuid_v4

      speak(session, "book the room", 1_000, 4_000)
      send(session, {:openai_live_event, {:delegation_created, "dg_1", 4_200}})

      assert_receive {:realtime,
                      %{type: "task", delegation_id: "dg_1", status: "running", call_uuid: ^uuid}}

      assert :ok = SessionControl.call_stop(session)

      assert_receive {:realtime, %{type: "task", status: "cancelled", call_uuid: ^uuid}}
      assert_receive {:realtime, %{type: "usage", accounting: "complete", call_uuid: ^uuid}}
      assert_receive {:EXIT, ^session, {:shutdown, :call_stop}}
    end

    test "each call mints its own UUID and keeps the counter as its trace session id", %{
      clock: clock
    } do
      Process.flag(:trap_exit, true)
      first_scope = "voice_live:identity_#{System.unique_integer([:positive, :monotonic])}"
      second_scope = "voice_live:identity_#{System.unique_integer([:positive, :monotonic])}"
      attach_call_start_handler([first_scope, second_scope])

      first = start_session(clock: clock, session_scope: first_scope)
      :ok = SessionControl.call_start(first)
      assert_receive {:call_start, %{session_id: ^first_scope, call_uuid: first_uuid}}
      :ok = SessionControl.call_stop(first)
      assert_receive {:EXIT, ^first, {:shutdown, :call_stop}}

      second = start_session(clock: clock, session_scope: second_scope)
      :ok = SessionControl.call_start(second)
      assert_receive {:call_start, %{session_id: ^second_scope, call_uuid: second_uuid}}

      assert first_uuid =~ @uuid_v4
      assert second_uuid =~ @uuid_v4
      refute first_uuid == second_uuid
    end
  end

  describe "one call per daemon" do
    test "the call is in the registry under its UUID while it is up, and gone after", %{
      clock: clock
    } do
      Process.flag(:trap_exit, true)
      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)
      start_provider_session(session)
      assert_receive {:realtime, %{type: "call_ready", call_uuid: uuid}}

      assert CallRegistry.lookup(@call_registry, uuid) == {:ok, session}

      assert {:ok, %{call_uuid: ^uuid, conversation: "chat", session: ^session}} =
               CallRegistry.active(@call_registry)

      :ok = SessionControl.call_stop(session)
      assert_receive {:EXIT, ^session, {:shutdown, :call_stop}}

      assert CallRegistry.lookup(@call_registry, uuid) == :none
      assert CallRegistry.active(@call_registry) == :none
    end

    # M56 §4.4: whoever reads the call in progress tells a call in the chat
    # from a private one, and when it started, without asking the session.
    test "the claim names the call's conversation and its start", %{clock: clock} do
      Process.flag(:trap_exit, true)
      before = DateTime.utc_now()
      session = start_session(clock: clock, config: live_config(conversation: "private"))
      :ok = SessionControl.call_start(session)

      assert {:ok, %{conversation: "private", started_at: started_at, session: ^session}} =
               CallRegistry.active(@call_registry)

      assert DateTime.compare(started_at, before) in [:gt, :eq]
      assert DateTime.compare(started_at, DateTime.utc_now()) in [:lt, :eq]
      end_call(session)
    end

    test "a second session is refused while a call is up", %{clock: clock} do
      Process.flag(:trap_exit, true)
      first = start_session(clock: clock)
      :ok = SessionControl.call_start(first)
      start_provider_session(first)

      assert {:error, :call_in_progress} =
               LiveSessionServer.start_link(session_opts(clock: clock))

      # The refused start touched nothing of the call that is up.
      assert {:ok, %{session: ^first}} = CallRegistry.active(@call_registry)
      assert [%{type: "session.start"}] = FakeLiveClient.events()
    end

    test "a second session is refused while the first is still settling", %{clock: clock} do
      Process.flag(:trap_exit, true)
      first = start_session(clock: clock, close_deadline_ms: 5_000)
      :ok = SessionControl.call_start(first)
      start_provider_session(first)
      FakeLiveClient.silence_close()

      stopper = Task.async(fn -> SessionControl.call_stop(first) end)

      # `idle` is the first thing a settle does; the settle then waits for
      # `session.closed`, which the provider has not sent.
      assert_receive {:realtime, %{type: "state", state: "idle"}}

      assert {:error, :call_in_progress} =
               LiveSessionServer.start_link(session_opts(clock: clock))

      send(first, {:openai_live_event, {:session_closed, "close_requested", 10.0}})
      assert :ok = Task.await(stopper)
      assert_receive {:EXIT, ^first, {:shutdown, :call_stop}}

      second = start_session(clock: clock)
      assert {:ok, %{session: ^second}} = CallRegistry.active(@call_registry)
    end
  end

  describe "the call record" do
    setup do
      unique = System.unique_integer([:positive])
      db_path = Path.join(System.tmp_dir!(), "fermix-live-record-#{unique}.db")
      repo = :"live_record_repo_#{unique}"
      start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

      on_exit(fn ->
        Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
      end)

      %{repo: repo}
    end

    # `persist_transcripts` is off here: it gates verbatim captions, not this.
    test "a call writes its record, every task state, and closes before the final usage", %{
      clock: clock,
      repo: repo
    } do
      Process.flag(:trap_exit, true)
      session = start_session(clock: clock, record_repo: repo)
      :ok = SessionControl.call_start(session)
      uuid = :sys.get_state(session).call_uuid

      assert {:ok, %{engine: "openai_live", ended_at: nil, tasks: [], started_at: started_at}} =
               Repo.get_voice_call(uuid, server: repo)

      # The record starts when the claim does: the call has one start.
      assert {:ok, %{started_at: claimed_at}} = CallRegistry.active(@call_registry)
      assert {:ok, ^claimed_at, 0} = DateTime.from_iso8601(started_at)

      start_provider_session(session)
      speak(session, "book the room", 1_000, 4_000)
      send(session, {:openai_live_event, {:delegation_created, "dg_1", 4_200}})
      assert_receive {:bridge_submit, _handle, %{delegation_id: "dg_1"}}
      # The fake bridge reports the submit from inside it, before the session
      # writes the task as running: wait for the session to finish the event.
      sync(session)

      assert record_tasks(repo, uuid) == [
               %{
                 "task_id" => "dg_1",
                 "revision" => 1,
                 "state" => "running",
                 "request" => "user: book the room",
                 "summary" => nil
               }
             ]

      send(session, {:openai_live_event, {:delegation_created, "dg_2", 4_400}})
      send(session, {:openai_live_event, {:delegation_created, "dg_3", 4_600}})
      assert_receive {:realtime, %{type: "task", delegation_id: "dg_3", status: "failed"}}

      assert task_states(record_tasks(repo, uuid)) ==
               [{"dg_1", "running"}, {"dg_2", "created"}, {"dg_3", "failed"}]

      :ok = FakeBridge.fire("dg_1", :result, {:ok, "The room is booked for 10am."})
      assert_receive {:bridge_submit, _handle, %{delegation_id: "dg_2"}}

      :ok = SessionControl.call_stop(session)
      assert_receive {:realtime, %{type: "usage", accounting: "complete", voice_cost_cents: cost}}

      # Written before that frame went out, from the same settled ledger.
      assert {:ok, record} = Repo.get_voice_call(uuid, server: repo)
      assert %{end_reason: "call_stop", accounting: "complete", voice_cost_cents: ^cost} = record
      assert is_binary(record.ended_at)

      assert task_states(record.tasks) ==
               [{"dg_1", "completed"}, {"dg_2", "cancelled"}, {"dg_3", "failed"}]

      assert Enum.map(record.tasks, & &1["summary"]) ==
               ["The room is booked for 10am.", "cancelled", "busy"]

      assert_receive {:EXIT, ^session, {:shutdown, :call_stop}}
    end

    # M56 §5: a private call is kept apart from the chat, and its record keeps
    # the states and summaries only, never the words.
    test "a private call's record keeps no request words", %{clock: clock, repo: repo} do
      Process.flag(:trap_exit, true)
      config = live_config(conversation: "private")
      session = start_session(clock: clock, record_repo: repo, config: config)
      :ok = SessionControl.call_start(session)
      uuid = :sys.get_state(session).call_uuid
      start_provider_session(session)

      speak(session, "book the room", 1_000, 4_000)
      send(session, {:openai_live_event, {:delegation_created, "dg_1", 4_200}})
      assert_receive {:bridge_submit, _handle, %{delegation_id: "dg_1"}}
      :ok = FakeBridge.fire("dg_1", :result, {:ok, "The room is booked for 10am."})
      assert_receive {:realtime, %{type: "task", delegation_id: "dg_1", status: "completed"}}

      assert [
               %{
                 "task_id" => "dg_1",
                 "state" => "completed",
                 "request" => nil,
                 "summary" => "The room is booked for 10am."
               }
             ] = record_tasks(repo, uuid)

      end_call(session)
    end

    test "a call the daemon ends is closed with its reason and an unsettled bill", %{
      clock: clock,
      repo: repo
    } do
      Process.flag(:trap_exit, true)
      session = start_session(clock: clock, record_repo: repo, close_deadline_ms: 20)
      :ok = SessionControl.call_start(session)
      start_provider_session(session)
      uuid = :sys.get_state(session).call_uuid
      FakeLiveClient.silence_close()

      send(session, {:openai_live_disconnect, %{reason: {:remote, :closed}}})
      assert_receive {:EXIT, ^session, {:shutdown, :provider_disconnected}}

      assert {:ok, %{end_reason: "provider_disconnected", accounting: "incomplete"}} =
               Repo.get_voice_call(uuid, server: repo)
    end

    # The stage's gate: a kill leaves a closed record with its tasks marked.
    test "a call killed mid-task is closed by the next boot's sweep, its task failed", %{
      clock: clock,
      repo: repo
    } do
      Process.flag(:trap_exit, true)
      session = start_session(clock: clock, record_repo: repo)
      :ok = SessionControl.call_start(session)
      start_provider_session(session)
      uuid = :sys.get_state(session).call_uuid
      speak(session, "book the room", 1_000, 4_000)
      send(session, {:openai_live_event, {:delegation_created, "dg_1", 4_200}})
      assert_receive {:bridge_submit, _handle, %{delegation_id: "dg_1"}}
      sync(session)

      Process.exit(session, :kill)
      assert_receive {:EXIT, ^session, :killed}

      assert {:ok, %{ended_at: nil, tasks: [%{"state" => "running"}]}} =
               Repo.get_voice_call(uuid, server: repo)

      {:ok, sweep} = CallSweep.start_link(record_repo: repo)
      ref = Process.monitor(sweep)
      assert_receive {:DOWN, ^ref, :process, ^sweep, :normal}, 5_000

      assert {:ok,
              %{
                end_reason: "daemon_restarted",
                accounting: "incomplete",
                voice_cost_cents: nil,
                tasks: [
                  %{
                    "task_id" => "dg_1",
                    "state" => "failed",
                    "summary" => "daemon_restarted",
                    "request" => "user: book the room"
                  }
                ]
              }} = Repo.get_voice_call(uuid, server: repo)
    end

    test "a call the provider refused leaves no record", %{clock: clock, repo: repo} do
      Process.flag(:trap_exit, true)

      session =
        start_session(clock: clock, record_repo: repo, live_client: RefusingLiveClient)

      uuid = :sys.get_state(session).call_uuid

      assert {:error, :provider_refused} = SessionControl.call_start(session)
      :ok = SessionControl.call_stop(session)
      assert_receive {:EXIT, ^session, {:shutdown, :call_stop}}

      assert Repo.get_voice_call(uuid, server: repo) == {:error, :not_found}
    end
  end

  describe "mute" do
    test "gates chunks locally before the provider acknowledges", %{clock: clock} do
      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)
      start_provider_session(session)

      assert :ok = SessionControl.mute(session, true)
      assert_receive {:realtime, %{type: "state", state: "muted"}}

      :ok = SessionControl.audio_chunk(session, <<1, 2, 3, 4>>)
      sync(session)

      refute :sys.get_state(session).provider_muted?
      refute Enum.any?(FakeLiveClient.events(), &(&1.type == "session.input_audio.append"))
      assert Enum.any?(FakeLiveClient.events(), &(&1.type == "session.input_audio.mute"))

      send(session, {:openai_live_event, {:input_muted, true}})
      assert :sys.get_state(session).provider_muted?
    end

    test "a mute applied before the session started reaches the provider once it does", %{
      clock: clock
    } do
      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)

      assert :ok = SessionControl.mute(session, true)
      assert [%{type: "session.start"}] = FakeLiveClient.events()

      start_provider_session(session)

      assert Enum.any?(FakeLiveClient.events(), &(&1.type == "session.input_audio.mute"))
    end
  end

  describe "captions" do
    test "persist_transcripts false records nothing", %{clock: clock} do
      session = start_session(clock: clock, recorder_module: FakeRecorder)
      :ok = SessionControl.call_start(session)
      start_provider_session(session)

      send(session, {:openai_live_event, {:transcript_delta, :user, "book ", 1_200, 1_640}})

      assert_receive {:realtime,
                      %{
                        type: "caption",
                        speaker: "user",
                        delta: "book ",
                        start_ms: 1_200,
                        end_ms: 1_640
                      }}

      refute_receive {:record_caption, _config, _device, _speaker, _delta, _opts}
    end

    test "persist_transcripts true records a live_caption fragment verbatim", %{clock: clock} do
      session =
        start_session(
          clock: clock,
          config: live_config(persist_transcripts: true),
          recorder_module: FakeRecorder,
          recorder_opts: [test_pid: self()]
        )

      :ok = SessionControl.call_start(session)
      start_provider_session(session)

      send(session, {:openai_live_event, {:transcript_delta, :assistant, "on it ", 2_000, 2_400}})

      assert_receive {:record_caption, _config, "device-1", "assistant", "on it ", opts}
      assert opts[:start_ms] == 2_000
      assert opts[:end_ms] == 2_400
    end
  end

  describe "usage and the cost ceiling" do
    test "usage snapshots are never summed and a regressed snapshot is ignored", %{clock: clock} do
      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)
      start_provider_session(session)

      send(session, {:openai_live_event, {:usage_updated, 30}})
      assert_receive {:realtime, %{type: "usage", status: "live", voice_seconds: 30.0}}

      send(session, {:openai_live_event, {:usage_updated, 60}})
      assert_receive {:realtime, %{type: "usage", voice_seconds: 60.0}}

      send(session, {:openai_live_event, {:usage_updated, 45}})
      assert_receive {:realtime, %{type: "usage", voice_seconds: 60.0}}
      assert :sys.get_state(session).ledger.regressed?
    end

    test "silence alone reaches the cost ceiling through the local tick", %{clock: clock} do
      Process.flag(:trap_exit, true)
      session = start_session(clock: clock, config: live_config(cost_cents: 5))
      :ok = SessionControl.call_start(session)
      start_provider_session(session)

      # A full silent minute: no provider snapshot, no audio, no delegation.
      Agent.update(clock, fn _now -> 60_000 end)
      send(session, :usage_tick)

      assert_receive {:realtime, %{type: "usage", status: "limit_reached"}}
      assert_receive {:realtime, %{type: "error", reason: "cost_limit", kind: "cost_limit"}}
      assert_receive {:realtime, %{type: "usage", accounting: "complete"}}
      assert_receive {:EXIT, ^session, {:shutdown, :cost_limit}}
    end
  end

  # M56 §4.1: in the chat's conversation the request a hand-off persists is the
  # exchange since the previous hand-off, speaker labelled and bounded, not the
  # overlapping 30 second window; one text is sent and recorded. A private call
  # keeps today's window, and its record keeps no words (M56 §5).
  describe "the request a hand-off sends" do
    test "in the chat it is the exchange since the previous hand-off", %{clock: clock} do
      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)
      start_provider_session(session)

      speak(session, "book the room", 1_000, 4_000)
      send(session, {:openai_live_event, {:delegation_created, "dg_1", 4_200}})
      assert_receive {:bridge_submit, _handle, %{delegation_id: "dg_1", text: first}}
      assert first == "user: book the room"
      :ok = FakeBridge.fire("dg_1", :result, {:ok, "Booked for ten."})

      send(
        session,
        {:openai_live_event, {:transcript_delta, :assistant, "booked ", 5_000, 6_000}}
      )

      speak(session, "and email Ana", 8_000, 9_000)
      send(session, {:openai_live_event, {:delegation_created, "dg_2", 9_200}})

      # The 30 second window would repeat "book the room"; the exchange does not.
      assert_receive {:bridge_submit, _handle, %{delegation_id: "dg_2", text: second}}
      assert second == "assistant: booked \nuser: and email Ana"
    end

    # Live can raise two tasks from one sentence. The second has no word of
    # the owner's after the first went out, and a request without the words
    # that asked for it is no request (an empty user turn is refused by a
    # provider), so it is sent the window a private call reads.
    test "a second hand-off from the same sentence is sent that sentence", %{clock: clock} do
      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)
      start_provider_session(session)

      speak(session, "book the room and email Ana", 1_000, 4_000)
      send(session, {:openai_live_event, {:delegation_created, "dg_1", 4_200}})
      send(session, {:openai_live_event, {:delegation_created, "dg_2", 4_400}})
      assert_receive {:bridge_submit, _handle, %{delegation_id: "dg_1"}}

      send(session, {:openai_live_event, {:transcript_delta, :assistant, "on it", 4_500, 5_000}})
      :ok = FakeBridge.fire("dg_1", :result, {:ok, "Booked."})

      assert_receive {:bridge_submit, _handle, %{delegation_id: "dg_2", text: text}}
      assert text == "user: book the room and email Ana\nassistant: on it"
    end

    test "a long exchange is cut from the front to 4 KB behind a marker", %{clock: clock} do
      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)
      start_provider_session(session)

      speak(session, String.duplicate("blah ", 1_000), 1_000, 20_000)
      speak(session, "use that link", 20_000, 21_000)
      send(session, {:openai_live_event, {:delegation_created, "dg_1", 21_200}})

      assert_receive {:bridge_submit, _handle, %{text: text}}
      assert byte_size(text) <= 4_096
      assert String.starts_with?(text, LiveText.cut_marker())
      assert String.ends_with?(text, "use that link")
    end

    test "a private call sends the 30 second window, as before", %{clock: clock} do
      session = start_session(clock: clock, config: live_config(conversation: "private"))
      :ok = SessionControl.call_start(session)
      start_provider_session(session)

      speak(session, "book the room", 1_000, 4_000)
      send(session, {:openai_live_event, {:delegation_created, "dg_1", 4_200}})
      assert_receive {:bridge_submit, _handle, %{delegation_id: "dg_1"}}
      :ok = FakeBridge.fire("dg_1", :result, {:ok, "Booked for ten."})

      speak(session, "and email Ana", 8_000, 9_000)
      send(session, {:openai_live_event, {:delegation_created, "dg_2", 9_200}})

      assert_receive {:bridge_submit, _handle, %{delegation_id: "dg_2", text: second}}
      # Fragments of one speaker join verbatim, as they always have.
      assert second == "user: book the roomand email Ana"
    end
  end

  # M56 §4.3: a message typed in the chat during a call, and its answer, reach
  # the voice model as session-wide quiet context, so "use that link" said
  # aloud has something to hand off. Channels finds the call and casts here.
  describe "the chat mirrored into a call" do
    test "a typed message and its answer are thinking appends for the whole session", %{
      clock: clock
    } do
      session = listening_session(clock)

      :ok = LiveSessionServer.chat_typed(session, "use https://x.test/lease")
      :ok = LiveSessionServer.chat_answered(session, %{role: "assistant", content: "Saved it."})
      sync(session)

      assert [typed, answered] = Enum.filter(FakeLiveClient.events(), &mirror?/1)

      assert %{
               delegation_id: nil,
               content: "The owner typed in the chat: use https://x.test/lease"
             } = typed

      assert %{delegation_id: nil, content: "Fermix answered in the chat: Saved it."} = answered

      # Tracked like every other append, so a refusal of it is explained.
      pending = :sys.get_state(session).pending_appends
      assert {answered.event_id, :thinking, nil} in pending
    end

    test "an answer drawn from Computer History never reaches the voice", %{clock: clock} do
      session = listening_session(clock)

      tainted = %{
        role: "assistant",
        content: "You were reading the Q3 report.",
        history_tainted: true
      }

      :ok = LiveSessionServer.chat_answered(session, tainted)
      sync(session)

      assert Enum.filter(FakeLiveClient.events(), &mirror?/1) == []
    end

    test "nothing is mirrored before the provider session is up", %{clock: clock} do
      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)

      :ok = LiveSessionServer.chat_typed(session, "too early")
      sync(session)

      assert [%{type: "session.start"}] = FakeLiveClient.events()
    end

    # M56 §4.4: a private call gets no mirror; the chat does not know it exists.
    test "nothing is mirrored into a private call", %{clock: clock} do
      session = listening_session(clock, config: live_config(conversation: "private"))

      :ok = LiveSessionServer.chat_typed(session, "use https://x.test/lease")
      sync(session)

      assert Enum.filter(FakeLiveClient.events(), &mirror?/1) == []
    end
  end

  # M56 §4.4: what a typed chat turn reads of the call in progress
  # (`voice_call_context`), from the session that holds it.
  describe "the call's context" do
    test "names the start, the time since, the tasks and everything said", %{clock: clock} do
      session = listening_session(clock)
      {:ok, %{started_at: started_at}} = CallRegistry.active(@call_registry)

      speak(session, "book the room", 1_000, 4_000)
      send(session, {:openai_live_event, {:delegation_created, "dg_1", 4_200}})
      assert_receive {:bridge_submit, _handle, %{delegation_id: "dg_1"}}
      :ok = FakeBridge.fire("dg_1", :result, {:ok, "The room is booked for 10am."})
      assert_receive {:realtime, %{type: "task", delegation_id: "dg_1", status: "completed"}}
      Agent.update(clock, fn _ms -> 372_000 end)

      assert {:ok, context} = LiveSessionServer.call_context(session, 1_000)

      assert context.started_at == started_at
      assert context.elapsed_ms == 372_000

      assert [
               %{
                 "task_id" => "dg_1",
                 "revision" => 1,
                 "state" => "completed",
                 "summary" => "The room is booked for 10am."
               }
             ] = context.tasks

      assert CallSpeech.text(context.speech) == "user: book the room"
    end

    # The 128-fragment window a hand-off reads forgets the start of a long
    # call; what the call said is kept whole, up to its byte bound.
    test "keeps the whole call, not the hand-off window", %{clock: clock} do
      session = listening_session(clock)

      for index <- 1..200 do
        send(
          session,
          {:openai_live_event,
           {:transcript_delta, :user, " word#{index}", index * 100, index * 100 + 50}}
        )
      end

      assert {:ok, %{speech: speech}} = LiveSessionServer.call_context(session, 1_000)
      assert CallSpeech.text(speech) =~ ~r/^user:  word1 word2 .* word200$/
      assert length(LiveTranscript.fragments(:sys.get_state(session).transcript)) == 128
    end

    # M56 §10: `conversation = "private"` is today's behaviour, so a private
    # call keeps nothing of what was said beyond the hand-off window.
    test "a private call keeps no call-long speech", %{clock: clock} do
      session = listening_session(clock, config: live_config(conversation: "private"))
      speak(session, "a private aside", 1_000, 2_000)

      assert {:ok, %{speech: speech}} = LiveSessionServer.call_context(session, 1_000)
      assert CallSpeech.text(speech) == ""
    end
  end

  describe "delegations" do
    setup %{clock: clock} do
      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)
      start_provider_session(session)
      speak(session, "book the room", 1_000, 4_000)
      %{session: session}
    end

    test "a duplicate delegation id submits once", %{session: session} do
      send(session, {:openai_live_event, {:delegation_created, "dg_1", 4_200}})
      assert_receive {:bridge_submit, _handle, %{delegation_id: "dg_1", revision: 1}}

      send(session, {:openai_live_event, {:delegation_created, "dg_1", 4_600}})
      sync(session)

      assert length(FakeBridge.submits()) == 1
    end

    test "the request carries the speaker-labelled transcript and a voice_delegation session id",
         %{session: session} do
      send(session, {:openai_live_event, {:delegation_created, "dg_1", 4_200}})

      assert_receive {:bridge_submit, _handle, request}
      assert request.text == "user: book the room"
      assert request.turn_session_id =~ ~r/^voice_delegation_\d+$/
      assert request.screen_frame == nil
      assert_receive {:realtime, %{type: "task", delegation_id: "dg_1", status: "running"}}
    end

    test "a second delegation waits as pending and a third is refused as busy", %{
      session: session
    } do
      send(session, {:openai_live_event, {:delegation_created, "dg_1", 4_200}})
      assert_receive {:bridge_submit, _handle, %{delegation_id: "dg_1"}}

      send(session, {:openai_live_event, {:delegation_created, "dg_2", 4_400}})
      assert_receive {:realtime, %{type: "task", delegation_id: "dg_2", status: "pending"}}

      send(session, {:openai_live_event, {:delegation_created, "dg_3", 4_600}})

      assert_receive {:realtime,
                      %{type: "task", delegation_id: "dg_3", status: "failed", summary: "busy"}}

      sync(session)
      assert length(FakeBridge.submits()) == 1

      assert Enum.any?(FakeLiveClient.events(), fn event ->
               event.type == "session.thinking.append" and event.delegation_id == "dg_3"
             end)
    end

    test "a delegation before sufficient context waits once then asks for a repeat", %{
      clock: clock,
      session: setup_call
    } do
      end_call(setup_call)
      session = start_session(clock: clock, context_wait_ms: 10)
      :ok = SessionControl.call_start(session)
      start_provider_session(session)

      send(session, {:openai_live_event, {:delegation_created, "dg_1", 9_000}})

      assert_receive {:realtime,
                      %{
                        type: "task",
                        delegation_id: "dg_1",
                        status: "failed",
                        summary: "insufficient_context"
                      }},
                     1_000

      assert FakeBridge.submits() == []

      assert Enum.any?(
               FakeLiveClient.events(),
               fn event ->
                 event.type == "session.commentary.append" and
                   event.content =~ "could you say it again"
               end
             )
    end

    test "a delegation whose context lands during the wait is submitted", %{
      clock: clock,
      session: setup_call
    } do
      end_call(setup_call)
      session = start_session(clock: clock, context_wait_ms: 50)
      :ok = SessionControl.call_start(session)
      start_provider_session(session)

      send(session, {:openai_live_event, {:delegation_created, "dg_1", 9_000}})
      speak(session, "book the room", 7_500, 8_900)

      assert_receive {:bridge_submit, _handle, %{delegation_id: "dg_1"}}, 1_000
    end

    test "a result becomes commentary with the delegation id and a completed task frame", %{
      session: session
    } do
      send(session, {:openai_live_event, {:delegation_created, "dg_1", 4_200}})
      assert_receive {:bridge_submit, _handle, _request}

      :ok = FakeBridge.fire("dg_1", :result, {:ok, "The room is booked for 10am."})

      assert_receive {:realtime,
                      %{
                        type: "task",
                        delegation_id: "dg_1",
                        status: "completed",
                        summary: "The room is booked for 10am."
                      }}

      assert Enum.any?(FakeLiveClient.events(), fn event ->
               event.type == "session.commentary.append" and
                 event.delegation_id == "dg_1" and
                 event.content == "The room is booked for 10am."
             end)

      assert :sys.get_state(session).ledger.backend_turns == 1
    end

    test "progress and a tool start become bounded thinking appends", %{
      session: session
    } do
      send(session, {:openai_live_event, {:delegation_created, "dg_1", 4_200}})
      assert_receive {:bridge_submit, _handle, _request}

      :ok = FakeBridge.fire("dg_1", :progress, String.duplicate("a", 4_000))
      :ok = FakeBridge.fire("dg_1", :activity, {:tool_start, "read_file"})
      # The second tool start inside the throttle window is dropped.
      :ok = FakeBridge.fire("dg_1", :activity, {:tool_start, "read_file"})
      sync(session)

      appends =
        FakeLiveClient.events()
        |> Enum.filter(&(&1.type == "session.thinking.append"))

      assert length(appends) == 2
      assert Enum.all?(appends, &(byte_size(&1.content) <= 1_200))
      assert Enum.any?(appends, &(&1.content == "Using read_file"))
    end

    test "a failed result speaks the vendor sentence and fails the task", %{session: session} do
      send(session, {:openai_live_event, {:delegation_created, "dg_1", 4_200}})
      assert_receive {:bridge_submit, _handle, _request}

      :ok = FakeBridge.fire("dg_1", :result, {:error, "The calendar provider is out of credits."})

      assert_receive {:realtime, %{type: "task", delegation_id: "dg_1", status: "failed"}}

      assert Enum.any?(FakeLiveClient.events(), fn event ->
               event.type == "session.commentary.append" and
                 event.content =~ "out of credits"
             end)
    end

    test "cancel_task reaches the bridge and produces a cancelled task frame", %{
      session: session
    } do
      send(session, {:openai_live_event, {:delegation_created, "dg_1", 4_200}})
      assert_receive {:bridge_submit, _handle, _request}

      assert :ok = SessionControl.cancel_task(session, "dg_1")

      assert_receive {:bridge_cancel, {:task, "dg_1"}}
      assert_receive {:realtime, %{type: "task", delegation_id: "dg_1", status: "cancelled"}}
      assert {:error, :unknown_delegation} = SessionControl.cancel_task(session, "dg_1")
    end

    test "completing the active delegation starts the pending one", %{session: session} do
      send(session, {:openai_live_event, {:delegation_created, "dg_1", 4_200}})
      assert_receive {:bridge_submit, _handle, %{delegation_id: "dg_1"}}

      send(session, {:openai_live_event, {:delegation_created, "dg_2", 4_400}})
      assert_receive {:realtime, %{type: "task", delegation_id: "dg_2", status: "pending"}}

      :ok = FakeBridge.fire("dg_1", :result, {:ok, "done"})

      assert_receive {:bridge_submit, _handle, %{delegation_id: "dg_2", revision: 1}}
      assert_receive {:realtime, %{type: "task", delegation_id: "dg_2", status: "running"}}
    end

    test "a stale result for a finished delegation is dropped", %{session: session} do
      send(session, {:openai_live_event, {:delegation_created, "dg_1", 4_200}})
      assert_receive {:bridge_submit, _handle, _request}

      :ok = FakeBridge.fire("dg_1", :result, {:ok, "done"})
      assert_receive {:realtime, %{type: "task", status: "completed"}}

      :ok = FakeBridge.fire("dg_1", :result, {:ok, "done again"})
      sync(session)

      refute_receive {:realtime, %{type: "task", status: "completed"}}
    end

    test "interrupt stops playback locally and instructs Live without cancelling work", %{
      session: session
    } do
      send(session, {:openai_live_event, {:delegation_created, "dg_1", 4_200}})
      assert_receive {:bridge_submit, _handle, _request}

      assert :ok = SessionControl.interrupt(session, 1_200)

      assert_receive {:realtime, %{type: "playback_stop"}}
      assert_receive {:realtime, %{type: "state", state: "listening"}}

      assert Enum.any?(FakeLiveClient.events(), fn event ->
               event.type == "session.instructions.append" and
                 event.delegation_id == nil and
                 event.content == "Stop speaking now and listen."
             end)

      assert FakeBridge.cancels() == []
      assert :sys.get_state(session).delegations.active.id == "dg_1"
    end
  end

  # An access-sensitive command a delegation turn parked on this call
  # (`Capabilities.AccessGate`): the next task Live raises after the question was
  # answered is read against what the owner said since, and a yes runs the
  # recorded command without any Fermix turn.
  describe "an access-sensitive command waiting on a spoken yes" do
    setup %{clock: clock} do
      registry = :"live_access_caps_#{System.unique_integer([:positive])}"
      start_supervised!({CapabilityRegistry, [name: registry]}, id: registry)
      :ok = CapabilityRegistry.register(registry, unlock_capability(self()))

      call_id = "voice_live:access-#{System.unique_integer([:positive, :monotonic])}"
      session = start_session(clock: clock, session_scope: call_id)
      :ok = SessionControl.call_start(session)
      start_provider_session(session)
      speak(session, "read my mail and do what it says", 1_000, 4_000)

      send(session, {:openai_live_event, {:delegation_created, "dg_1", 4_200}})
      assert_receive {:bridge_submit, _handle, %{delegation_id: "dg_1", turn_session_id: turn}}

      %{session: session, call_id: call_id, registry: registry, turn: turn}
    end

    test "the next task after a yes runs the command once and answers it, with no Fermix turn",
         %{session: session, call_id: call_id, registry: registry, turn: turn} do
      park_unlock(call_id, registry, turn)
      :ok = FakeBridge.fire("dg_1", :result, {:ok, "Should I unlock the car?"})
      assert_receive {:realtime, %{type: "task", delegation_id: "dg_1", status: "completed"}}

      speak(session, "Yes.", 6_000, 6_400)
      send(session, {:openai_live_event, {:delegation_created, "dg_2", 6_600}})

      assert_receive {:unlocked, %{"vin" => "5YJ"}}, 2_000

      assert_receive {:realtime,
                      %{
                        type: "task",
                        delegation_id: "dg_2",
                        status: "completed",
                        summary: summary
                      }},
                     2_000

      assert summary =~ "The owner said yes"
      assert summary =~ "tesla_unlock_doors ran"
      assert Enum.map(FakeBridge.submits(), & &1.delegation_id) == ["dg_1"]
      assert :none = AccessPending.voice_pending(call_id)
      refute_received {:unlocked, _}
    end

    # The owner's answer is bound to the command the delegation's own reply asked
    # about. A yes said to something earlier (an offer the owner accepted before
    # any command was parked) must never confirm it, however the parking task
    # ends and whatever Live raises next.
    for {ending, how} <- [error: "fails", cancelled: "is cancelled"] do
      test "a yes said before the park confirms nothing when the parking task #{how}",
           %{session: session, call_id: call_id, registry: registry} do
        :ok = FakeBridge.fire("dg_1", :result, {:ok, "You have mail. Want me to handle it?"})
        assert_receive {:realtime, %{type: "task", delegation_id: "dg_1", status: "completed"}}
        speak(session, "Go ahead.", 6_000, 6_400)

        send(session, {:openai_live_event, {:delegation_created, "dg_2", 6_600}})
        assert_receive {:bridge_submit, _handle, %{delegation_id: "dg_2", turn_session_id: turn}}
        park_unlock(call_id, registry, turn)

        send(session, {:openai_live_event, {:delegation_created, "dg_3", 9_000}})
        assert_receive {:realtime, %{type: "task", delegation_id: "dg_3", status: "pending"}}
        end_parking_task(session, unquote(ending))

        assert_receive {:bridge_submit, _handle, %{delegation_id: "dg_3"}}, 2_000
        sync(session)
        refute_received {:unlocked, _}
        assert {:ok, _intent} = AccessPending.voice_pending(call_id)
      end
    end

    test "a later task's reply cannot open the answer to a command an earlier task parked",
         %{session: session, call_id: call_id, registry: registry, turn: turn} do
      park_unlock(call_id, registry, turn)
      :ok = FakeBridge.fire("dg_1", :result, {:error, "Maximum iterations (20) reached"})
      assert_receive {:realtime, %{type: "task", delegation_id: "dg_1", status: "failed"}}

      speak(session, "What's the weather?", 5_000, 5_400)
      send(session, {:openai_live_event, {:delegation_created, "dg_2", 5_600}})
      assert_receive {:bridge_submit, _handle, %{delegation_id: "dg_2"}}
      :ok = FakeBridge.fire("dg_2", :result, {:ok, "Sunny. Shall I add it to your calendar?"})
      assert_receive {:realtime, %{type: "task", delegation_id: "dg_2", status: "completed"}}

      speak(session, "Yes.", 7_000, 7_300)
      send(session, {:openai_live_event, {:delegation_created, "dg_3", 7_500}})

      assert_receive {:bridge_submit, _handle, %{delegation_id: "dg_3"}}, 2_000
      sync(session)
      refute_received {:unlocked, _}
    end

    test "anything but a yes is submitted as a task and the command is dropped",
         %{session: session, call_id: call_id, registry: registry, turn: turn} do
      park_unlock(call_id, registry, turn)
      :ok = FakeBridge.fire("dg_1", :result, {:ok, "Should I unlock the car?"})

      speak(session, "No, what's the weather?", 6_000, 6_900)
      send(session, {:openai_live_event, {:delegation_created, "dg_2", 7_100}})

      assert_receive {:bridge_submit, _handle, %{delegation_id: "dg_2"}}
      assert :none = AccessPending.voice_pending(call_id)
      refute_received {:unlocked, _}
    end

    test "a task raised before the question was asked is submitted and the command kept",
         %{session: session, call_id: call_id, registry: registry, turn: turn} do
      park_unlock(call_id, registry, turn)
      send(session, {:openai_live_event, {:delegation_created, "dg_2", 4_400}})
      assert_receive {:realtime, %{type: "task", delegation_id: "dg_2", status: "pending"}}

      :ok = FakeBridge.fire("dg_1", :result, {:ok, "Should I unlock the car?"})

      assert_receive {:bridge_submit, _handle, %{delegation_id: "dg_2"}}
      assert {:ok, _intent} = AccessPending.voice_pending(call_id)
      refute_received {:unlocked, _}
    end

    test "cancelling the answered task makes no bridge call",
         %{session: session, call_id: call_id, registry: registry, turn: turn} do
      park_unlock(call_id, registry, turn, %{"vin" => "5YJ", "hold" => true})
      :ok = FakeBridge.fire("dg_1", :result, {:ok, "Should I unlock the car?"})

      speak(session, "yes", 6_000, 6_300)
      send(session, {:openai_live_event, {:delegation_created, "dg_2", 6_500}})
      assert_receive {:unlocking, runner}, 2_000

      assert :ok = SessionControl.cancel_task(session, "dg_2")
      assert_receive {:realtime, %{type: "task", delegation_id: "dg_2", status: "cancelled"}}
      refute_received {:bridge_cancel, _}

      send(runner, :go)
      sync(session)
      refute_receive {:realtime, %{type: "task", delegation_id: "dg_2", status: "completed"}}, 200
    end

    test "a confirmed run that crashes fails the task and says the outcome is unknown",
         %{session: session, call_id: call_id, registry: registry, turn: turn} do
      park_unlock(call_id, registry, turn, %{"vin" => "5YJ", "crash" => true})
      :ok = FakeBridge.fire("dg_1", :result, {:ok, "Should I unlock the car?"})

      speak(session, "yes", 6_000, 6_300)
      send(session, {:openai_live_event, {:delegation_created, "dg_2", 6_500}})

      assert_receive {:realtime,
                      %{type: "task", delegation_id: "dg_2", status: "failed", summary: summary}},
                     2_000

      assert summary =~ "unknown"
    end
  end

  def unlock(%{"crash" => true}, _context, _test_pid),
    do: raise("the helper connection dropped mid-command")

  def unlock(%{"hold" => true} = args, _context, test_pid) do
    send(test_pid, {:unlocking, self()})

    receive do
      :go -> send(test_pid, {:unlocked, args})
    end

    {:ok, %{success: true, output: ~s({"result":true}), error: nil}}
  end

  def unlock(args, _context, test_pid) do
    send(test_pid, {:unlocked, args})
    {:ok, %{success: true, output: ~s({"result":true}), error: nil}}
  end

  defp unlock_capability(test_pid) do
    Capability.new(%{
      name: "tesla_unlock_doors",
      description: "Unlock the car's doors.",
      parameters: %{"type" => "object"},
      kind: :mcp,
      executor: {__MODULE__, :unlock, [test_pid]},
      policy_class: :external_api,
      metadata: %{access_sensitive?: true, plugin_owned?: true, plugin: "tesla"}
    })
  end

  defp end_parking_task(_session, :error),
    do: FakeBridge.fire("dg_2", :result, {:error, "Maximum iterations (20) reached"})

  defp end_parking_task(session, :cancelled), do: SessionControl.cancel_task(session, "dg_2")

  # What the delegation turn does when it asks for the command after reading
  # someone else's mail: the gate parks the call on this voice call, recorded
  # against the turn session the Live session minted for that delegation.
  defp park_unlock(call_id, registry, turn_session_id, args \\ %{"vin" => "5YJ"}) do
    {:ok, capability} = CapabilityRegistry.find(registry, "tesla_unlock_doors")

    context = %{
      source_trust: :operator,
      computer_use_origin: :interactive,
      session_id: turn_session_id,
      voice_call_id: call_id,
      capability_registry: registry,
      outside_sources: MapSet.new([{:plugin, "agentmail"}])
    }

    assert {:ok, %{success: false, error: text}} = Capability.execute(capability, args, context)
    assert text =~ "say yes"
    assert {:ok, _intent} = AccessPending.voice_pending(call_id)
    :ok
  end

  describe "audio output" do
    test "the first delta announces speaking once", %{clock: clock} do
      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)
      start_provider_session(session)
      assert_receive {:realtime, %{type: "state", state: "listening"}}

      first = reply_audio(10)
      second = reply_audio(10)
      send(session, {:openai_live_event, {:audio_delta, first}})
      send(session, {:openai_live_event, {:audio_delta, second}})

      assert_receive {:realtime, %{type: "state", state: "speaking"}}
      assert_receive {:realtime, %{type: "audio_delta", audio: ^first}}
      assert_receive {:realtime, %{type: "audio_delta", audio: ^second}}
      refute_receive {:realtime, %{type: "state", state: "speaking"}}
    end
  end

  # Live publishes no turn boundaries and cannot cancel a reply, so the daemon,
  # as the relay both audio streams pass through, reads the turn from them.
  describe "turn state" do
    test "a reply that has had time to play out returns the pet to listening", %{clock: clock} do
      session = listening_session(clock, reply_margin_ms: 10)

      send(session, {:openai_live_event, {:audio_delta, reply_audio(20)}})
      assert_receive {:realtime, %{type: "state", state: "speaking"}}
      assert_receive {:realtime, %{type: "audio_delta"}}

      assert_receive {:realtime, %{type: "state", state: "listening"}}, 500
    end

    # How long the reply plays is LiveTurn's (live_turn_test); here, each chunk
    # re-arms the played-out timer. The margin keeps both timers from firing, and
    # each expiry is delivered by hand, so no wall-clock window is raced.
    test "a later chunk of the same reply keeps it speaking", %{clock: clock} do
      session = listening_session(clock, reply_margin_ms: 60_000)

      send(session, {:openai_live_event, {:audio_delta, reply_audio(20)}})
      assert_receive {:realtime, %{type: "state", state: "speaking"}}
      %{reply_timer: {_timer, first}} = sync(session)

      send(session, {:openai_live_event, {:audio_delta, reply_audio(20)}})
      %{reply_timer: {_timer, current}} = sync(session)
      assert current != first

      send(session, {:reply_played_out, first})
      sync(session)
      refute_received {:realtime, %{type: "state", state: "listening"}}

      send(session, {:reply_played_out, current})
      assert_receive {:realtime, %{type: "state", state: "listening"}}
    end

    test "the rest of a stopped reply is dropped, and a later reply plays", %{clock: clock} do
      session = listening_session(clock)

      send(session, {:openai_live_event, {:audio_delta, reply_audio(20)}})
      assert_receive {:realtime, %{type: "state", state: "speaking"}}
      assert_receive {:realtime, %{type: "audio_delta"}}

      assert :ok = SessionControl.interrupt(session, 10)
      assert_receive {:realtime, %{type: "playback_stop"}}
      assert_receive {:realtime, %{type: "state", state: "listening"}}

      Agent.update(clock, &(&1 + 100))
      send(session, {:openai_live_event, {:audio_delta, reply_audio(20)}})
      sync(session)
      refute_received {:realtime, %{type: "audio_delta"}}
      refute_received {:realtime, %{type: "state", state: "speaking"}}

      Agent.update(clock, &(&1 + 5_000))
      next = reply_audio(20)
      send(session, {:openai_live_event, {:audio_delta, next}})
      assert_receive {:realtime, %{type: "state", state: "speaking"}}
      assert_receive {:realtime, %{type: "audio_delta", audio: ^next}}
    end

    # Measured on the dev engine: Live's output never stops, and between
    # replies it is digital silence, one chunk every 100 ms.
    test "padding between replies is forwarded but is not speech", %{clock: clock} do
      session = listening_session(clock)

      for _ <- 1..3, do: send(session, {:openai_live_event, {:audio_delta, padding_audio(100)}})
      sync(session)

      assert_received {:realtime, %{type: "audio_delta"}}
      refute_received {:realtime, %{type: "state", state: "speaking"}}
    end

    test "a reply ends while padding keeps streaming after it", %{clock: clock} do
      session = listening_session(clock, reply_margin_ms: 10)

      send(session, {:openai_live_event, {:audio_delta, reply_audio(20)}})
      assert_receive {:realtime, %{type: "state", state: "speaking"}}

      for _ <- 1..5, do: send(session, {:openai_live_event, {:audio_delta, padding_audio(100)}})

      assert_receive {:realtime, %{type: "state", state: "listening"}}, 500
    end

    test "padding after Stop does not keep the stopped reply alive", %{clock: clock} do
      session = listening_session(clock)
      send(session, {:openai_live_event, {:audio_delta, reply_audio(20)}})
      assert_receive {:realtime, %{type: "state", state: "speaking"}}
      assert :ok = SessionControl.interrupt(session, 10)
      assert_receive {:realtime, %{type: "state", state: "listening"}}

      for at <- [100, 400, 700, 1_000, 1_300] do
        Agent.update(clock, fn _ -> at end)
        send(session, {:openai_live_event, {:audio_delta, padding_audio(100)}})
      end

      Agent.update(clock, fn _ -> 1_400 end)
      next = reply_audio(20)
      send(session, {:openai_live_event, {:audio_delta, next}})
      assert_receive {:realtime, %{type: "state", state: "speaking"}}
      assert_receive {:realtime, %{type: "audio_delta", audio: ^next}}
    end

    test "the operator falling quiet announces thinking while padding streams", %{clock: clock} do
      session = listening_session(clock)

      send(session, {:openai_live_event, {:audio_delta, padding_audio(100)}})
      words(session, clock, 0)
      send(session, {:openai_live_event, {:audio_delta, padding_audio(100)}})
      mic(session, clock, 2_000, :silence)

      assert_received {:realtime, %{type: "state", state: "thinking"}}
    end

    test "the operator falling quiet after speaking announces thinking", %{clock: clock} do
      session = listening_session(clock)

      words(session, clock, 0)
      mic(session, clock, 200, :silence)
      refute_received {:realtime, %{type: "state", state: "thinking"}}

      mic(session, clock, 2_000, :silence)
      assert_received {:realtime, %{type: "state", state: "thinking"}}

      send(session, {:openai_live_event, {:audio_delta, reply_audio(20)}})
      assert_receive {:realtime, %{type: "state", state: "speaking"}}
    end

    test "speaking again while thinking returns to listening", %{clock: clock} do
      session = listening_session(clock)

      words(session, clock, 0)
      mic(session, clock, 2_000, :silence)
      assert_received {:realtime, %{type: "state", state: "thinking"}}

      words(session, clock, 2_100)
      assert_received {:realtime, %{type: "state", state: "listening"}}
    end

    test "thinking gives way to listening when no reply comes", %{clock: clock} do
      session = listening_session(clock)

      words(session, clock, 0)
      mic(session, clock, 2_000, :silence)
      assert_received {:realtime, %{type: "state", state: "thinking"}}

      mic(session, clock, 60_000, :silence)
      assert_received {:realtime, %{type: "state", state: "listening"}}
    end

    # Where echo cancellation fails the pet's own reply reaches its microphone,
    # and Live transcribes it as the operator's words.
    test "words during a reply leave the pet speaking until it has played", %{clock: clock} do
      session = listening_session(clock, reply_margin_ms: 10)

      send(session, {:openai_live_event, {:audio_delta, reply_audio(300)}})
      assert_receive {:realtime, %{type: "state", state: "speaking"}}

      words(session, clock, 100)
      refute_receive {:realtime, %{type: "state", state: "listening"}}, 150
      assert_receive {:realtime, %{type: "state", state: "listening"}}, 1_000
    end

    # Live's words trail the audio: in a call through display speakers the
    # reply's last word arrived as the operator's after the reply had played,
    # and the pet sat thinking (2026-09-28).
    test "the reply heard back through the microphone is not the operator", %{clock: clock} do
      session = listening_session(clock, reply_margin_ms: 10)

      send(session, {:openai_live_event, {:audio_delta, reply_audio(200)}})
      assert_receive {:realtime, %{type: "state", state: "speaking"}}
      assert_receive {:realtime, %{type: "state", state: "listening"}}, 1_000

      words(session, clock, 1_500)
      mic(session, clock, 4_000, :silence)

      refute_received {:realtime, %{type: "state", state: "thinking"}}
    end

    # Keyboard noise is as loud as speech, and an energy detector took every
    # burst of typing for a sentence (owner, 2026-09-28). Live transcribes words.
    test "typing is not the operator speaking", %{clock: clock} do
      session = listening_session(clock)

      for at <- [0, 100, 200, 300], do: mic(session, clock, at, :speech)
      mic(session, clock, 2_000, :silence)
      mic(session, clock, 4_000, :silence)

      refute_received {:realtime, %{type: "state", state: "thinking"}}
    end

    test "a muted microphone never announces thinking", %{clock: clock} do
      session = listening_session(clock)
      words(session, clock, 0)
      assert :ok = SessionControl.mute(session, true)

      mic(session, clock, 2_000, :silence)

      refute_received {:realtime, %{type: "state", state: "thinking"}}
    end
  end

  describe "teardown" do
    test "call_stop closes gracefully and finalizes usage from session.closed", %{clock: clock} do
      Process.flag(:trap_exit, true)
      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)
      start_provider_session(session)

      send(session, {:openai_live_event, {:delegation_created, "dg_1", 4_200}})
      speak(session, "book the room", 1_000, 4_000)
      assert_receive {:bridge_submit, _handle, _request}

      assert :ok = SessionControl.call_stop(session)

      assert_receive {:realtime, %{type: "state", state: "idle"}}
      assert_receive {:bridge_cancel, {:task, "dg_1"}}
      assert_receive {:bridge_close_call, _handle}

      assert_receive {:realtime,
                      %{
                        type: "usage",
                        accounting: "complete",
                        voice_seconds: @closed_seconds,
                        backend_cost: "unknown"
                      }}

      assert Enum.any?(FakeLiveClient.events(), &(&1.type == "session.close"))
      assert_receive {:EXIT, ^session, {:shutdown, :call_stop}}
    end

    test "a missing session.closed within the deadline records incomplete accounting", %{
      clock: clock
    } do
      Process.flag(:trap_exit, true)

      session = start_session(clock: clock, close_deadline_ms: 20)
      :ok = SessionControl.call_start(session)
      start_provider_session(session)
      FakeLiveClient.silence_close()

      assert :ok = SessionControl.call_stop(session)

      assert_receive {:realtime, %{type: "usage", accounting: "incomplete"}}
      assert_receive {:EXIT, ^session, {:shutdown, :call_stop}}
    end

    test "a disconnect ends the call with provider_disconnected and never reconnects", %{
      clock: clock
    } do
      Process.flag(:trap_exit, true)
      session = start_session(clock: clock, close_deadline_ms: 20)
      :ok = SessionControl.call_start(session)
      start_provider_session(session)
      FakeLiveClient.silence_close()

      send(session, {:openai_live_disconnect, %{reason: {:remote, :closed}}})

      assert_receive {:realtime, %{type: "state", state: "idle"}}

      assert_receive {:realtime,
                      %{
                        type: "error",
                        reason: "provider_disconnected",
                        kind: "provider_disconnected"
                      }}

      assert_receive {:realtime, %{type: "usage", accounting: "incomplete"}}
      assert_receive {:EXIT, ^session, {:shutdown, :provider_disconnected}}
      assert FakeBridge.closed() == 1
    end

    test "an unsolicited expiry ends the call as session_expired", %{clock: clock} do
      Process.flag(:trap_exit, true)
      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)
      start_provider_session(session)

      send(session, {:openai_live_event, {:session_closed, "expired", 300.0}})

      assert_receive {:realtime,
                      %{type: "error", reason: "session_expired", kind: "session_expired"}}

      assert_receive {:realtime, %{type: "usage", accounting: "complete", voice_seconds: 300.0}}
      assert_receive {:EXIT, ^session, {:shutdown, :session_expired}}
    end

    test "the max session duration ends the call", %{clock: clock} do
      Process.flag(:trap_exit, true)
      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)
      start_provider_session(session)

      send(session, :max_session_duration)

      assert_receive {:realtime,
                      %{
                        type: "error",
                        reason: "max_session_duration",
                        kind: "max_session_duration"
                      }}

      assert_receive {:EXIT, ^session, {:shutdown, :max_session_duration}}
    end

    test "a provider error is not terminal and never reaches the companion", %{clock: clock} do
      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)
      start_provider_session(session)

      send(
        session,
        {:openai_live_event, {:error, %{"type" => "moderation", "message" => "blocked"}}}
      )

      sync(session)

      refute_receive {:realtime, %{type: "error"}}
      assert Process.alive?(session)
    end

    # Live never reconnects, so a socket crashed by this frame used to end the call.
    test "a JSON frame that is not an object is not terminal", %{clock: clock} do
      scope = "voice_live:non_object_#{System.unique_integer([:positive, :monotonic])}"
      attach_provider_error_handler(scope)
      session = start_session(clock: clock, session_scope: scope)
      :ok = SessionControl.call_start(session)
      start_provider_session(session)

      assert :ok = FakeLiveClient.deliver_frame(~s([1]))
      sync(session)

      assert_receive {:provider_error, %{session_id: ^scope, reason: reason}}
      assert reason =~ "invalid_server_event"
      refute_received {:realtime, %{type: "error"}}
      assert Process.alive?(session)
      assert LiveSessionServer.live_pid(session) == Process.whereis(FakeLiveClient.State)
    end
  end

  describe "reload_runtime" do
    test "reports that a Live session is immutable mid-call", %{clock: clock} do
      session = start_session(clock: clock)

      assert {:ok, %{tools: 0, applies: :next_call}} = SessionControl.reload_runtime(session)
    end
  end

  ## Helpers

  defp start_session(opts) do
    {:ok, session} = LiveSessionServer.start_link(session_opts(opts))

    # A session settles its call in `terminate/2`, which runs as the test
    # process exits. Registered AFTER the bridge's own cleanup, so it runs
    # BEFORE it (on_exit is LIFO): the fakes outlive the call they served.
    on_exit(fn -> await_down(session) end)
    session
  end

  defp record_tasks(repo, uuid) do
    {:ok, %{tasks: tasks}} = Repo.get_voice_call(uuid, server: repo)
    tasks
  end

  defp task_states(tasks), do: Enum.map(tasks, &{&1["task_id"], &1["state"]})

  # One call per daemon: a test that needs a session of its own first ends the
  # call its describe's setup started.
  defp end_call(session) do
    Process.flag(:trap_exit, true)
    :ok = SessionControl.call_stop(session)
    assert_receive {:EXIT, ^session, {:shutdown, :call_stop}}
  end

  defp session_opts(opts) do
    config = Keyword.get(opts, :config) || live_config()

    defaults = [
      companion: self(),
      config: config,
      api_key: "sk-test",
      device_id: "device-1",
      session_scope: "voice_live:#{System.unique_integer([:positive, :monotonic])}",
      live_client: FakeLiveClient,
      voice_bridge: FakeBridge,
      call_registry: @call_registry,
      prompt: "# LIVE.md\n\nBackend tools:\n- Web: web_search",
      unix_clock: fn -> 1_000 end
    ]

    defaults
    |> Keyword.merge(opts)
    |> Keyword.update!(:clock, fn agent -> fn -> Agent.get(agent, & &1) end end)
    |> Keyword.put(:config, config)
  end

  # The session emits from its OWN process, so the handler cannot filter on
  # `self()`. It pins this call's id instead: a globally attached handler that
  # forwarded every event would hand this test another module's fixture.
  defp attach_provider_error_handler(call_id) do
    handler_id = "live-session-provider-error-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:fermix, :voice_live, :provider_error],
      fn _event, _measurements, metadata, _config ->
        if metadata.session_id == call_id, do: send(test_pid, {:provider_error, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  # Pinned to these calls' ids, for the same reason as the handler above.
  defp attach_call_start_handler(call_ids) do
    handler_id = "live-session-call-start-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:fermix, :voice_live, :call_start],
      fn _event, _measurements, metadata, _config ->
        if metadata.session_id in call_ids, do: send(test_pid, {:call_start, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp await_down(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      2_000 -> raise "the live session never stopped"
    end
  end

  defp live_config(opts \\ []) do
    Config.normalize(
      enabled: true,
      engine: "openai_live",
      model: "gpt-live-1",
      voice: "marin",
      max_session_minutes: 15,
      max_estimated_cost_cents_per_session: Keyword.get(opts, :cost_cents, 100),
      persist_transcripts: Keyword.get(opts, :persist_transcripts, false),
      conversation: Keyword.get(opts, :conversation)
    )
  end

  defp start_provider_session(session, opts \\ []) do
    send_session_started(session, opts)
    sync(session)
  end

  defp send_session_started(session, opts \\ []) do
    send(
      session,
      {:openai_live_event,
       {:session_started,
        %{
          id: Keyword.get(opts, :id, "sess_live_1"),
          expires_at: Keyword.get(opts, :expires_at, 1_060)
        }}}
    )
  end

  defp mirror?(%{type: "session.thinking.append", delegation_id: nil}), do: true
  defp mirror?(_event), do: false

  # The provider's answer to a start whose input it will not take, in the
  # shape its Live guide documents for a refused command.
  defp input_refusal(param) do
    %{
      "type" => "invalid_request_error",
      "code" => "invalid_value",
      "message" => "Invalid value: 'the lease'.",
      "param" => param
    }
  end

  defp restore_core_env({key, {:ok, value}}), do: Application.put_env(:fermix_core, key, value)
  defp restore_core_env({key, :error}), do: Application.delete_env(:fermix_core, key)

  defp restore_voice_bridge(nil), do: Application.delete_env(:fermix_core, :voice_bridge)

  defp restore_voice_bridge(module),
    do: Application.put_env(:fermix_core, :voice_bridge, module)

  defp speak(session, text, start_ms, end_ms) do
    send(session, {:openai_live_event, {:transcript_delta, :user, text, start_ms, end_ms}})
    sync(session)
  end

  # A synchronous round trip through the session's own mailbox: everything sent
  # before it has been handled by the time it returns. No sleeps.
  defp sync(session), do: :sys.get_state(session)

  # A started call on the provider's side, its first `listening` consumed.
  defp listening_session(clock, opts \\ []) do
    session = start_session(Keyword.put(opts, :clock, clock))
    :ok = SessionControl.call_start(session)
    start_provider_session(session)
    assert_receive {:realtime, %{type: "state", state: "listening"}}
    session
  end

  # `ms` of the assistant's voice as Live sends it: base64 24 kHz PCM16.
  defp reply_audio(ms), do: Base.encode64(square_wave(24 * ms, 2_000))

  # Live pads its output with digital silence between replies, one chunk every
  # 100 ms for the whole call.
  defp padding_audio(ms), do: Base.encode64(:binary.copy(<<0, 0>>, 24 * ms))

  defp square_wave(samples, amplitude) do
    for index <- 1..samples, into: <<>> do
      value = if rem(index, 2) == 0, do: amplitude, else: -amplitude
      <<value::little-signed-16>>
    end
  end

  # A fragment of the operator's words from Live's recognition, at clock time
  # `at_ms`.
  defp words(session, clock, at_ms) do
    Agent.update(clock, fn _ -> at_ms end)
    speak(session, "words", at_ms, at_ms + 100)
  end

  # 100 ms of the microphone at clock time `at_ms`: a square wave well above
  # speech level, or silence.
  defp mic(session, clock, at_ms, kind) do
    Agent.update(clock, fn _ -> at_ms end)
    sample = if kind == :speech, do: 3_000, else: 0

    pcm =
      for index <- 1..2_400, into: <<>> do
        value = if rem(index, 2) == 0, do: sample, else: -sample
        <<value::little-signed-16>>
      end

    :ok = SessionControl.audio_chunk(session, pcm)
    sync(session)
  end

  defp start_capability_registry do
    registry = :"live_session_capabilities_#{System.unique_integer([:positive, :monotonic])}"
    start_supervised!({CapabilityRegistry, [name: registry]}, id: registry)

    :ok =
      CapabilityRegistry.register(
        registry,
        Capability.new(%{
          name: "read_file",
          description: "Read a file.",
          parameters: %{"type" => "object"},
          kind: :builtin,
          executor: {__MODULE__, :execute, []},
          policy_class: :read_only,
          metadata: %{category: :file, when_to_use: "Never, this is a fixture."}
        })
      )

    registry
  end

  defp payload_keys(map) when is_map(map) do
    Enum.flat_map(map, fn {key, value} -> [to_string(key) | payload_keys(value)] end)
  end

  defp payload_keys(_value), do: []
end
