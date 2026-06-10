defmodule FermixCore.Realtime.SessionServerTelemetryTest do
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Realtime.Config
  alias FermixCore.Realtime.SessionServer

  @session_scope "session:test-#{System.unique_integer([:positive])}"

  defmodule FakeOpenAIClient do
    def start_link(opts),
      do: Agent.start_link(fn -> %{opts: opts, events: [], closed?: false} end)

    def send_event(pid, event),
      do: Agent.update(pid, fn s -> %{s | events: s.events ++ [event]} end)

    def close(pid), do: Agent.update(pid, &%{&1 | closed?: true})
    def events(pid), do: Agent.get(pid, & &1.events)
  end

  # Self-emits `[:fermix, :tool, :exec]` like the real builtin tools, so we can
  # prove the realtime path carries `session_id` through to exactly one tool_exec
  # with no wrapper double-emit.
  defmodule TelemetryTool do
    alias FermixCore.Tools.Telemetry, as: ToolTelemetry

    def execute(%{"text" => text}, context) do
      result = {:ok, %{success: true, output: text, error: nil}}

      ToolTelemetry.exec("telemetry_echo", context, true, 1,
        input: %{"text" => text},
        result: result
      )

      result
    end
  end

  setup do
    capability =
      Capability.new(%{
        name: "echo",
        description: "Echo text.",
        parameters: %{"type" => "object"},
        kind: :builtin,
        executor: {TelemetryTool, :execute, []},
        policy_class: :read_only
      })

    {:ok, server} =
      SessionServer.start_link(
        companion: self(),
        config: Config.normalize(enabled: true),
        session_scope: @session_scope,
        device_id: "device-1",
        openai_client: FakeOpenAIClient,
        api_key: "sk-test",
        safety_identifier: "safe-id",
        capabilities: [capability],
        prompt_loader: fn _opts ->
          {:ok, %{messages: [%{role: "system", content: "prompt"}], parts: [], accounting: []}}
        end
      )

    handler_id = attach_telemetry()
    on_exit(fn -> :telemetry.detach(handler_id) end)

    %{server: server}
  end

  test "lifecycle events emit [:fermix, :realtime, ...] with session_id", %{server: server} do
    assert :ok = SessionServer.call_start(server)
    assert_receive {:tele, [:fermix, :realtime, :call_start], _m, meta}
    assert meta.session_id == @session_scope
    assert meta.model == "gpt-realtime-2"
    assert meta.voice == "marin"

    assert :ok = SessionServer.handle_provider_event(server, {:session_created, %{}})
    assert_receive {:tele, [:fermix, :realtime, :session_created], _m, created}
    assert created.session_id == @session_scope

    assert :ok = SessionServer.handle_provider_event(server, {:session_updated, %{}})
    assert_receive {:tele, [:fermix, :realtime, :session_updated], _m, updated}
    assert updated.session_id == @session_scope

    assert :ok = SessionServer.call_stop(server)
    assert_receive {:tele, [:fermix, :realtime, :call_stop], _m, stopped}
    assert stopped.session_id == @session_scope
  end

  test "a provider error emits realtime provider_error with a bounded reason", %{server: server} do
    assert :ok = SessionServer.call_start(server)

    error = %{"type" => "error", "code" => "bad_thing", "message" => "boom"}
    assert :ok = SessionServer.handle_provider_event(server, {:error, error})

    assert_receive {:tele, [:fermix, :realtime, :provider_error], _m, meta}
    assert meta.session_id == @session_scope
    assert is_binary(meta.reason)
  end

  test "a disconnect emits the realtime reconnect event", %{server: server} do
    assert :ok = SessionServer.call_start(server)
    send(server, {:openai_realtime_disconnect, :network})

    assert_receive {:tele, [:fermix, :realtime, :reconnect], _m, meta}
    assert meta.session_id == @session_scope
    assert meta.attempt == 0
  end

  test "a function call emits exactly one tool_exec carrying the session_id", %{server: server} do
    assert :ok = SessionServer.call_start(server)

    assert :ok =
             SessionServer.handle_provider_event(server, {
               :function_call,
               %{"call_id" => "call-1", "name" => "echo", "arguments" => ~s({"text":"hi"})}
             })

    assert_receive {:tele, [:fermix, :tool, :exec], _m, meta}
    assert meta.tool == "telemetry_echo"
    assert meta.session_id == @session_scope
    # Exactly one — the capability self-emits; the realtime path must not wrap it.
    refute_receive {:tele, [:fermix, :tool, :exec], _m2, _meta2}, 50
  end

  test "response.done with usage emits one provider.call with model, tokens, session_id", %{
    server: server
  } do
    assert :ok = SessionServer.call_start(server)
    assert :ok = SessionServer.handle_provider_event(server, {:response_created, %{}})

    response = %{"usage" => %{"input_tokens" => 12, "output_tokens" => 8}}
    assert :ok = SessionServer.handle_provider_event(server, {:response_done, response})

    assert_receive {:tele, [:fermix, :provider, :call], _m, meta}
    assert meta.provider == :openai
    assert meta.model == "gpt-realtime-2"
    assert meta.tokens == %{prompt: 12, completion: 8, total: 20}
    assert meta.session_id == @session_scope
    refute_receive {:tele, [:fermix, :provider, :call], _m2, _meta2}, 50
  end

  test "response.done carries the realtime transcripts as input/output when capture is on", %{
    server: server
  } do
    prior = Application.get_env(:fermix_core, :telemetry, [])
    Application.put_env(:fermix_core, :telemetry, Keyword.put(prior, :capture_content, true))
    on_exit(fn -> Application.put_env(:fermix_core, :telemetry, prior) end)

    assert :ok = SessionServer.call_start(server)
    assert :ok = SessionServer.handle_provider_event(server, {:response_created, %{}})

    assert :ok =
             SessionServer.handle_provider_event(server, {:user_transcript_done, "hello there"})

    assert :ok =
             SessionServer.handle_provider_event(server, {:assistant_transcript_done, "hi back"})

    response = %{"usage" => %{"input_tokens" => 5, "output_tokens" => 3}}
    assert :ok = SessionServer.handle_provider_event(server, {:response_done, response})

    assert_receive {:tele, [:fermix, :provider, :call], _m, meta}
    assert meta.input == "hello there"
    assert meta.output == "hi back"
  end

  test "call_stop carries the session's accumulated audio usage as measurements", %{
    server: server
  } do
    assert :ok = SessionServer.call_start(server)
    # 4800 bytes of PCM16 @ 48 bytes/ms = 100 ms of input audio.
    assert :ok = SessionServer.audio_chunk(server, :binary.copy(<<0>>, 4800))

    assert :ok = SessionServer.call_stop(server)

    assert_receive {:tele, [:fermix, :realtime, :call_stop], measurements, _meta}
    assert measurements.input_audio_ms == 100
    assert measurements.input_audio_tokens == 1
    assert measurements.estimated_cost_cents > 0
    assert measurements.reported_cost_cents == 0.0
  end

  defp attach_telemetry do
    handler_id = "test-rt-tele-#{System.unique_integer([:positive])}"
    test_pid = self()

    events = [
      [:fermix, :realtime, :call_start],
      [:fermix, :realtime, :session_created],
      [:fermix, :realtime, :session_updated],
      [:fermix, :realtime, :provider_error],
      [:fermix, :realtime, :reconnect],
      [:fermix, :realtime, :call_stop],
      [:fermix, :tool, :exec],
      [:fermix, :provider, :call]
    ]

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:tele, event, measurements, metadata})
      end,
      nil
    )

    handler_id
  end
end
