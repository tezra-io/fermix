defmodule FermixCore.Realtime.LiveSessionServerTest do
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.AccessGate.Pending, as: AccessPending
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.LiveSessionServer
  alias FermixCore.Realtime.OpenAILiveClient
  alias FermixCore.Realtime.SessionControl

  @moduletag :capture_log

  @live_title "# LIVE.md — Live Voice Companion"
  @closed_seconds 120.5

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
        fn -> %{test_pid: test_pid, submits: [], cancels: [], closed: 0, callbacks: %{}} end,
        name: __MODULE__
      )
    end

    def stop do
      case Process.whereis(__MODULE__) do
        nil -> :ok
        pid -> Agent.stop(pid)
      end
    end

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

  describe "session.started" do
    test "announces call_ready then listening and opens the bridge call", %{clock: clock} do
      session = start_session(clock: clock)
      :ok = SessionControl.call_start(session)
      start_provider_session(session)

      assert_receive {:bridge_open_call, %{call_id: call_id, persist?: false}}

      assert_receive {:realtime,
                      %{
                        type: "call_ready",
                        engine: "openai_live",
                        call_id: ^call_id,
                        provider_session_id: "sess_live_1",
                        expires_at: 1_060,
                        captions: true
                      }}

      assert_receive {:realtime, %{type: "state", state: "listening"}}
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
      clock: clock
    } do
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

    test "a delegation whose context lands during the wait is submitted", %{clock: clock} do
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
    test "the first delta announces speaking once and user speech returns to listening", %{
      clock: clock
    } do
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

      send(session, {:openai_live_event, {:transcript_delta, :user, "stop", 100, 200}})
      assert_receive {:realtime, %{type: "state", state: "listening"}}
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

    test "a later chunk of the same reply keeps it speaking", %{clock: clock} do
      session = listening_session(clock, reply_margin_ms: 200)

      send(session, {:openai_live_event, {:audio_delta, reply_audio(20)}})
      assert_receive {:realtime, %{type: "state", state: "speaking"}}
      Process.sleep(120)
      send(session, {:openai_live_event, {:audio_delta, reply_audio(20)}})

      refute_receive {:realtime, %{type: "state", state: "listening"}}, 150
      assert_receive {:realtime, %{type: "state", state: "listening"}}, 500
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
      mic(session, clock, 0, :speech)
      send(session, {:openai_live_event, {:audio_delta, padding_audio(100)}})
      mic(session, clock, 2_000, :silence)

      assert_received {:realtime, %{type: "state", state: "thinking"}}
    end

    test "the operator falling quiet after speaking announces thinking", %{clock: clock} do
      session = listening_session(clock)

      mic(session, clock, 0, :speech)
      mic(session, clock, 200, :silence)
      refute_received {:realtime, %{type: "state", state: "thinking"}}

      mic(session, clock, 2_000, :silence)
      assert_received {:realtime, %{type: "state", state: "thinking"}}

      send(session, {:openai_live_event, {:audio_delta, reply_audio(20)}})
      assert_receive {:realtime, %{type: "state", state: "speaking"}}
    end

    test "speaking again while thinking returns to listening", %{clock: clock} do
      session = listening_session(clock)

      mic(session, clock, 0, :speech)
      mic(session, clock, 2_000, :silence)
      assert_received {:realtime, %{type: "state", state: "thinking"}}

      mic(session, clock, 2_100, :speech)
      assert_received {:realtime, %{type: "state", state: "listening"}}
    end

    test "thinking gives way to listening when no reply comes", %{clock: clock} do
      session = listening_session(clock)

      mic(session, clock, 0, :speech)
      mic(session, clock, 2_000, :silence)
      assert_received {:realtime, %{type: "state", state: "thinking"}}

      mic(session, clock, 60_000, :silence)
      assert_received {:realtime, %{type: "state", state: "listening"}}
    end

    # The app does no echo cancellation: the pet's own reply reaches its
    # microphone, and must not be taken for the operator speaking.
    test "the reply heard back through the microphone is not the operator", %{clock: clock} do
      session = listening_session(clock, reply_margin_ms: 10)

      send(session, {:openai_live_event, {:audio_delta, reply_audio(1_000)}})
      assert_receive {:realtime, %{type: "state", state: "speaking"}}

      mic(session, clock, 500, :speech)
      mic(session, clock, 4_000, :silence)

      refute_received {:realtime, %{type: "state", state: "thinking"}}
    end

    test "a muted microphone never announces thinking", %{clock: clock} do
      session = listening_session(clock)
      assert :ok = SessionControl.mute(session, true)

      mic(session, clock, 0, :speech)
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
    config = Keyword.get(opts, :config) || live_config()

    defaults = [
      companion: self(),
      config: config,
      api_key: "sk-test",
      device_id: "device-1",
      session_scope: "voice_live:#{System.unique_integer([:positive, :monotonic])}",
      live_client: FakeLiveClient,
      voice_bridge: FakeBridge,
      prompt: "# LIVE.md\n\nBackend tools:\n- Web: web_search",
      unix_clock: fn -> 1_000 end
    ]

    session_opts =
      defaults
      |> Keyword.merge(opts)
      |> Keyword.update!(:clock, fn agent -> fn -> Agent.get(agent, & &1) end end)
      |> Keyword.put(:config, config)

    {:ok, session} = LiveSessionServer.start_link(session_opts)

    # A session settles its call in `terminate/2`, which runs as the test
    # process exits. Registered AFTER the bridge's own cleanup, so it runs
    # BEFORE it (on_exit is LIFO): the fakes outlive the call they served.
    on_exit(fn -> await_down(session) end)
    session
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
      persist_transcripts: Keyword.get(opts, :persist_transcripts, false)
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
