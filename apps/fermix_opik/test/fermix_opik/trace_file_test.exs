defmodule FermixOpik.TraceFileTest do
  use ExUnit.Case, async: true

  alias FermixOpik.Aggregation
  alias FermixOpik.TraceFile

  test "normalizes an llm_call row into a provider.call event with usage" do
    row = %{
      "ts" => "2026-06-02T12:00:00.000Z",
      "type" => "llm_call",
      "agent" => "main",
      "duration_ms" => 900,
      "provider" => "openai",
      "model" => "gpt-5",
      "status" => "ok",
      "session_id" => "main-1",
      "tokens" => %{"prompt" => 40, "completion" => 8}
    }

    assert {[:fermix, :provider, :call], %{duration_ms: 900}, meta} =
             TraceFile.normalize("llm_call", row)

    assert meta.session_id == "main-1"
    assert meta.model == "gpt-5"
    assert meta.tokens == %{prompt: 40, completion: 8}
  end

  test "normalizes agent_event rows by their event name" do
    base = %{"ts" => "2026-06-02T12:00:00.000Z", "type" => "agent_event"}

    assert {[:fermix, :agent, :start], %{}, %{session_id: "s", parent_session: "main-1"}} =
             TraceFile.normalize(
               "agent_event",
               Map.merge(base, %{
                 "event" => "agent_start",
                 "session_id" => "s",
                 "parent_session" => "main-1"
               })
             )

    assert {[:fermix, :job, :run_start], %{}, meta} =
             TraceFile.normalize(
               "agent_event",
               Map.merge(base, %{
                 "event" => "job_run_start",
                 "job_id" => "j",
                 "session_id" => "cron_j_1"
               })
             )

    assert meta.job_id == "j"
  end

  test "a job_run_complete row carries its tool failure count" do
    row = %{
      "ts" => "2026-06-02T12:00:00.000Z",
      "type" => "agent_event",
      "event" => "job_run_complete",
      "job_id" => "j",
      "session_id" => "cron_j_1",
      "duration_ms" => 900,
      "iterations" => 4,
      "total_tokens" => 64_245,
      "tool_failures" => 2
    }

    assert {[:fermix, :job, :run_complete], measurements, _meta} =
             TraceFile.normalize("agent_event", row)

    assert measurements.tool_failures == 2
  end

  test "skips non-trace rows" do
    assert :skip = TraceFile.normalize("channel_msg", %{"ts" => "x"})
    assert :skip = TraceFile.normalize("agent_event", %{"event" => "prompt_context"})
  end

  test "tool_exec normalize keeps the browser safe diagnostics and error pair" do
    row = %{
      "ts" => "2026-06-02T12:00:00.000Z",
      "type" => "tool_exec",
      "tool" => "browser",
      "agent" => "main",
      "success" => false,
      "duration_ms" => 12,
      "action" => "click",
      "kind" => "interaction",
      "profile" => "default",
      "url" => "https://example.com/x",
      "target_ref" => "ref-1",
      "selector" => "#go",
      "error_code" => "timeout",
      "error_summary" => "navigation timed out"
    }

    assert {[:fermix, :tool, :exec], %{duration_ms: 12}, meta} =
             TraceFile.normalize("tool_exec", row)

    assert meta.profile == "default"
    assert meta.url == "https://example.com/x"
    assert meta.target_ref == "ref-1"
    assert meta.selector == "#go"
    assert meta.error_code == "timeout"
    assert meta.error_summary == "navigation timed out"
  end

  # ExUnit owns this directory: it clears and recreates it per test, so the
  # test needs no cleanup call of its own. FermixTestSupport.SafeRm — the
  # repo's guarded alternative to a bare File.rm_rf! in test/ — is compiled
  # only into fermix_core, so it is not reachable from this app.
  @tag :tmp_dir
  test "read_events reads a day directory and feeds the aggregator end to end", %{tmp_dir: dir} do
    day = Path.join(dir, "2026-06-02")
    File.mkdir_p!(day)

    write(day, "llm_call.jsonl", [
      %{
        ts: "2026-06-02T12:00:00.100Z",
        type: "llm_call",
        agent: "main",
        duration_ms: 100,
        provider: "openai",
        model: "gpt-5",
        status: "ok",
        session_id: "main-1",
        tokens: %{prompt: 5, completion: 2}
      }
    ])

    write(day, "agent_event.jsonl", [
      %{
        ts: "2026-06-02T12:00:00.300Z",
        type: "agent_event",
        event: "turn_complete",
        agent: "main",
        session_id: "main-1",
        channel: "telegram",
        chat_id: "c",
        iterations: 1,
        total_tokens: 7
      }
    ])

    events = TraceFile.read_events(dir)
    # sorted by ts: llm_call first, then turn_complete
    assert [{[:fermix, :provider, :call], _, _, _}, {[:fermix, :agent, :message], _, _, _}] =
             events

    agg = Aggregation.new(project: "fermix", ttl_ms: 1_000_000)

    {_agg, closed} =
      Enum.reduce(events, {agg, []}, fn {ev, meas, meta, at}, {a, acc} ->
        {a, new} =
          Aggregation.apply_event(a, ev, meas, meta, %{
            at: at,
            mono: DateTime.to_unix(at, :microsecond)
          })

        {a, acc ++ new}
      end)

    assert [%{trace: trace, spans: spans}] = closed
    assert trace.name == "agent:main"
    assert Enum.any?(spans, &(&1[:type] == "llm"))
  end

  test "normalizes realtime agent_event rows into realtime events" do
    base = %{"ts" => "2026-06-02T12:00:00.000Z", "type" => "agent_event"}

    assert {[:fermix, :realtime, :call_start], %{}, start_meta} =
             TraceFile.normalize(
               "agent_event",
               Map.merge(base, %{
                 "event" => "realtime_call_start",
                 "session_id" => "session:1",
                 "agent" => "realtime",
                 "model" => "gpt-realtime-2",
                 "voice" => "marin",
                 "device_id" => "dev-1"
               })
             )

    assert start_meta.session_id == "session:1"
    assert start_meta.model == "gpt-realtime-2"

    assert {[:fermix, :realtime, :call_stop], %{}, _stop_meta} =
             TraceFile.normalize(
               "agent_event",
               Map.merge(base, %{"event" => "realtime_call_stop", "session_id" => "session:1"})
             )
  end

  test "realtime_call_stop normalize reconstructs the final usage measurements" do
    base = %{"ts" => "2026-06-02T12:00:00.000Z", "type" => "agent_event"}

    assert {[:fermix, :realtime, :call_stop], measurements, meta} =
             TraceFile.normalize(
               "agent_event",
               Map.merge(base, %{
                 "event" => "realtime_call_stop",
                 "session_id" => "session:1",
                 "input_audio_ms" => 2400,
                 "input_audio_tokens" => 24,
                 "estimated_cost_cents" => 0.0768,
                 "reported_cost_cents" => 0.0
               })
             )

    assert measurements == %{
             input_audio_ms: 2400,
             input_audio_tokens: 24,
             estimated_cost_cents: 0.0768,
             reported_cost_cents: 0.0
           }

    assert meta.session_id == "session:1"
  end

  # A Live call's whole record in the JSONL is these six rows: replay has to
  # rebuild every one of them, including the `parent_session` that is the only
  # link between a call and the backend turns it delegated.
  test "normalizes every voice_live agent_event row back into its event" do
    base = %{"ts" => "2026-09-12T12:00:00.000Z", "type" => "agent_event"}

    phases = [
      {"voice_live_call_start", :call_start},
      {"voice_live_session_started", :session_started},
      {"voice_live_delegation_start", :delegation_start},
      {"voice_live_delegation_stop", :delegation_stop},
      {"voice_live_provider_error", :provider_error},
      {"voice_live_call_stop", :call_stop}
    ]

    for {row_event, phase} <- phases do
      row =
        Map.merge(base, %{
          "event" => row_event,
          "session_id" => "voice_live:1",
          "parent_session" => "main-4",
          "agent" => "voice_live",
          "engine" => "openai_live",
          "device_id" => "dev-1",
          "model" => "gpt-live-1",
          "voice" => "marin",
          "provider_session_id" => "sess_live_abc",
          "delegation_id" => "dlg_1",
          "revision" => 1,
          "turn_session_id" => "voice_delegation_7",
          "status" => "completed",
          "reason" => "call_stop"
        })

      assert {[:fermix, :voice_live, ^phase], _meas, meta} =
               TraceFile.normalize("agent_event", row)

      assert meta.session_id == "voice_live:1"
      assert meta.parent_session == "main-4"
      assert meta.engine == "openai_live"
      assert meta.turn_session_id == "voice_delegation_7"
    end
  end

  test "voice_live_call_stop normalize reconstructs the numeric ledger" do
    base = %{"ts" => "2026-09-12T12:00:00.000Z", "type" => "agent_event"}

    assert {[:fermix, :voice_live, :call_stop], measurements, meta} =
             TraceFile.normalize(
               "agent_event",
               Map.merge(base, %{
                 "event" => "voice_live_call_stop",
                 "session_id" => "voice_live:1",
                 "voice_seconds" => 62,
                 "voice_cost_millicents" => 5_167,
                 "backend_turns" => 2,
                 "accounting_complete" => 1,
                 "reason" => "cost_limit"
               })
             )

    assert measurements == %{
             voice_seconds: 62,
             voice_cost_millicents: 5_167,
             backend_turns: 2,
             accounting_complete: 1
           }

    assert meta.reason == "cost_limit"
  end

  # A pre-ledger row replays with no measurements rather than fabricated zeros:
  # a measured 0 cent call and an unaccounted one price differently.
  test "a voice_live row without the ledger replays with empty measurements" do
    base = %{"ts" => "2026-09-12T12:00:00.000Z", "type" => "agent_event"}

    assert {[:fermix, :voice_live, :call_stop], %{}, _meta} =
             TraceFile.normalize(
               "agent_event",
               Map.merge(base, %{
                 "event" => "voice_live_call_stop",
                 "session_id" => "voice_live:1"
               })
             )
  end

  test "a voice_live_delegation_stop row replays its duration measurement" do
    base = %{"ts" => "2026-09-12T12:00:00.000Z", "type" => "agent_event"}

    assert {[:fermix, :voice_live, :delegation_stop], %{duration_ms: 1_200}, meta} =
             TraceFile.normalize(
               "agent_event",
               Map.merge(base, %{
                 "event" => "voice_live_delegation_stop",
                 "session_id" => "voice_live:1",
                 "delegation_id" => "dlg_1",
                 "status" => "failed",
                 "duration_ms" => 1_200
               })
             )

    assert meta.status == "failed"
  end

  # A computer-use session's whole record in the JSONL is these five rows, and
  # replay has to rebuild every one of them — including `parent_session`, which
  # is the only link back to the turn that opened the session.
  test "normalizes every computer_use agent_event row back into its event" do
    base = %{"ts" => "2026-09-19T12:00:00.000Z", "type" => "agent_event"}

    verbs = [
      {"computer_use_session_start", :session_start},
      {"computer_use_session_complete", :session_complete},
      {"computer_use_session_error", :session_error},
      {"computer_use_session_pause", :session_pause},
      {"computer_use_session_resume", :session_resume}
    ]

    for {row_event, verb} <- verbs do
      row =
        Map.merge(base, %{
          "event" => row_event,
          "session_id" => "cua_ab12",
          "parent_session" => "main-9",
          "agent" => "main",
          "mode" => "host",
          "origin" => "interactive"
        })

      assert {[:fermix, :computer_use, ^verb], _meas, meta} =
               TraceFile.normalize("agent_event", row)

      assert meta.session_id == "cua_ab12"
      assert meta.parent_session == "main-9"
      assert meta.mode == "host"
      assert meta.origin == "interactive"
    end
  end

  test "a computer_use_session_complete row replays its action and duration counts" do
    base = %{"ts" => "2026-09-19T12:00:00.000Z", "type" => "agent_event"}

    assert {[:fermix, :computer_use, :session_complete], measurements, meta} =
             TraceFile.normalize(
               "agent_event",
               Map.merge(base, %{
                 "event" => "computer_use_session_complete",
                 "session_id" => "cua_ab12",
                 "actions" => 7,
                 "duration_ms" => 4_200
               })
             )

    assert measurements == %{actions: 7, duration_ms: 4_200}
    assert meta.session_id == "cua_ab12"
  end

  test "a computer_use_session_error row replays the bounded reason" do
    base = %{"ts" => "2026-09-19T12:00:00.000Z", "type" => "agent_event"}

    assert {[:fermix, :computer_use, :session_error], %{}, meta} =
             TraceFile.normalize(
               "agent_event",
               Map.merge(base, %{
                 "event" => "computer_use_session_error",
                 "session_id" => "cua_ab12",
                 "reason" => "{:sidecar_exited, 1}"
               })
             )

    assert meta.reason == "{:sidecar_exited, 1}"
  end

  # The computer-use run is its own root, so these two keys are the only link
  # from a replayed action back to the session that performed it. The screen
  # snippet must still drop: this stays an allowlist, not a passthrough.
  test "tool_exec normalize keeps the computer-use session id and outcome" do
    row = %{
      "ts" => "2026-09-19T12:00:00.000Z",
      "type" => "tool_exec",
      "tool" => "computer_use",
      "agent" => "main",
      "session_id" => "main-9",
      "success" => true,
      "duration_ms" => 40,
      "action" => "click",
      "cu_session" => "cua_ab12",
      "outcome" => "performed_unverified",
      # Coexistence (V3 R0): what the arbiter did about a present human.
      "courtesy" => "deferred",
      # Addressing (M42 slice 3): how stale the image the action aimed at was, and
      # the code when it named no addressable one.
      "observation_age_ms" => 5_100,
      "geometry_refusal" => "expired_observation",
      # References (M42 slice 4): which mechanism the input went out by, and what
      # the helper observed of it.
      "input_method" => "ax",
      "effect" => "verified",
      # The check (M42 slice 6): which evidence came back, whether the view it
      # acted in changed, and what each phase of it cost.
      "check_kind" => "image",
      "check_changed" => false,
      "cu_input_ms" => 12,
      "cu_settle_ms" => 180,
      "cu_capture_ms" => 40,
      "cu_encode_ms" => 9,
      # Bound windows (M42 slice 5): what the action was pointed at, and how it
      # reached the screen.
      "target_kind" => "window",
      "cu_mode" => "background",
      "title" => "Inbox (3) — work@example.com",
      "value" => "hunter2",
      "screen_text" => "Transfer $4,000 to account 12345"
    }

    assert {[:fermix, :tool, :exec], %{duration_ms: 40}, meta} =
             TraceFile.normalize("tool_exec", row)

    assert meta.cu_session == "cua_ab12"
    assert meta.outcome == "performed_unverified"
    assert meta.observation_age_ms == 5_100
    assert meta.geometry_refusal == "expired_observation"
    assert meta.input_method == "ax"
    assert meta.effect == "verified"
    assert meta.check_kind == "image"
    assert meta.check_changed == false
    assert meta.cu_input_ms == 12
    assert meta.cu_settle_ms == 180
    assert meta.cu_capture_ms == 40
    assert meta.cu_encode_ms == 9
    assert meta.target_kind == "window"
    assert meta.cu_mode == "background"
    assert meta.courtesy == "deferred"
    refute Map.has_key?(meta, :title), "a window title is content, not a row field"
    refute Map.has_key?(meta, :value), "the value a set_value carried is content, not a row field"
    refute Map.has_key?(meta, :screen_text)
  end

  # The atom/string seam, end to end: the live emitter sends `outcome: :performed`
  # and `Trace` writes it through Jason, so the row on disk holds a string and
  # replay hands the aggregation a string where live traffic handed it an atom.
  # Both render identically downstream, but nothing proved the round trip until
  # here — so the row is built the way the daemon writes one.
  test "a tool_exec row written from an atom outcome replays as its string" do
    row =
      Jason.decode!(
        Jason.encode!(%{
          ts: "2026-09-19T12:00:00.000Z",
          type: "tool_exec",
          tool: "computer_use",
          agent: "main",
          session_id: "main-9",
          success: true,
          duration_ms: 40,
          cu_session: "cua_ab12",
          outcome: :performed
        })
      )

    assert {[:fermix, :tool, :exec], %{duration_ms: 40}, meta} =
             TraceFile.normalize("tool_exec", row)

    assert meta.cu_session == "cua_ab12"
    assert meta.outcome == "performed"
  end

  defp write(dir, file, rows) do
    content = Enum.map_join(rows, &(Jason.encode!(&1) <> "\n"))
    File.write!(Path.join(dir, file), content)
  end
end
