defmodule FermixCore.OpenLoops.TelemetryTest do
  # async: false — the content gate is `Application` env and the trace-registration
  # test attaches the real `Trace.TelemetryHandler`. Both preconditions are
  # established in this file's own setup and restored on exit.
  use ExUnit.Case, async: false

  alias FermixCore.OpenLoops.Telemetry, as: OpenLoopTelemetry
  alias FermixCore.Trace
  alias FermixCore.Trace.TelemetryHandler
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TelemetryCapture

  @start_event [:fermix, :open_loop, :checkin, :start]
  @complete_event [:fermix, :open_loop, :checkin, :complete]
  @error_event [:fermix, :open_loop, :checkin, :error]
  @skipped_event [:fermix, :open_loop, :skipped]
  @settled_event [:fermix, :open_loop, :settled]
  @fault_event [:fermix, :open_loop, :fault]
  @reaction_event [:fermix, :open_loop, :reaction]

  # The check-in is a run kind (three bookends); the other four are sessionless
  # point events. Exactly seven, no more.
  @events [
    @start_event,
    @complete_event,
    @error_event,
    @skipped_event,
    @settled_event,
    @fault_event,
    @reaction_event
  ]

  @loop_id "loop_Vq3kT9wZrHc"
  @session_id "open_loop_loop_Vq3kT9wZrHc_2"
  @agent "open_loop:loop_Vq3kT9wZrHc"

  @outcomes ["spoke", "silent", "later", "closed", "empty", "delivery_failed"]
  @statuses ["timeout", "error"]
  @skip_reasons [
    "disabled",
    "budget",
    "active_hours",
    "no_target",
    "max_children",
    "closed_meanwhile"
  ]
  @settlers ["main_agent", "checkin", "scheduler"]
  @fault_stages ["scan", "claim", "release", "timer", "start_checkin", "sweep"]

  setup do
    prior = Application.get_env(:fermix_core, :telemetry, [])
    capture_content(false)
    on_exit(fn -> Application.put_env(:fermix_core, :telemetry, prior) end)

    TelemetryCapture.attach(@events, :emitter)

    %{run: OpenLoopTelemetry.correlation(@loop_id, 2)}
  end

  defp capture_content(enabled?) do
    prior = Application.get_env(:fermix_core, :telemetry, [])
    Application.put_env(:fermix_core, :telemetry, Keyword.put(prior, :capture_content, enabled?))
  end

  defp base_metadata do
    %{
      agent: @agent,
      session_id: @session_id,
      open_loop_id: @loop_id,
      touch: 2,
      component: "open_loop_checkin"
    }
  end

  describe "correlation/2" do
    test "derives one identity the loop context and the trace both read" do
      assert OpenLoopTelemetry.correlation(@loop_id, 2) == %{
               session_id: @session_id,
               agent: @agent,
               open_loop_id: @loop_id,
               touch: 2
             }
    end

    test "each touch of one loop is its own session" do
      first = OpenLoopTelemetry.correlation(@loop_id, 1)
      third = OpenLoopTelemetry.correlation(@loop_id, 3)

      assert first.session_id == "open_loop_loop_Vq3kT9wZrHc_1"
      assert third.session_id == "open_loop_loop_Vq3kT9wZrHc_3"
      assert first.agent == third.agent
    end

    test "refuses an id that is not a loop id and a touch that is not a positive count" do
      assert_raise FunctionClauseError, fn -> OpenLoopTelemetry.correlation("rem_4", 1) end
      assert_raise FunctionClauseError, fn -> OpenLoopTelemetry.correlation("loop_", 1) end
      assert_raise FunctionClauseError, fn -> OpenLoopTelemetry.correlation(@loop_id, 0) end
      assert_raise FunctionClauseError, fn -> OpenLoopTelemetry.correlation(@loop_id, "2") end
    end
  end

  describe "run_start/5" do
    test "opens the run with its identity, its rung, its horizon, its hours and its sweep floor",
         %{run: run} do
      assert :ok = OpenLoopTelemetry.run_start(run, 2, "medium", "08:00-22:30", 120_000)

      assert_receive {:telemetry, @start_event, measurements, metadata}
      assert measurements == %{count: 1}

      assert metadata ==
               Map.merge(base_metadata(), %{
                 rung: 2,
                 horizon_class: "medium",
                 active_hours: "08:00-22:30",
                 max_duration_ms: 120_000
               })
    end

    test "a check-in for something waited on opens with class after", %{run: run} do
      assert :ok = OpenLoopTelemetry.run_start(run, 2, "after", "08:00-22:30", 120_000)
      assert_receive {:telemetry, @start_event, _measurements, %{horizon_class: "after"}}
    end

    test "refuses a rung, horizon class, hours label or ceiling outside its shape", %{run: run} do
      assert_raise FunctionClauseError, fn ->
        OpenLoopTelemetry.run_start(run, 3, "medium", "08:00-22:30", 120_000)
      end

      assert_raise FunctionClauseError, fn ->
        OpenLoopTelemetry.run_start(run, 2, "soon", "08:00-22:30", 120_000)
      end

      assert_raise ArgumentError, fn ->
        OpenLoopTelemetry.run_start(run, 2, "medium", "morning", 120_000)
      end

      assert_raise FunctionClauseError, fn ->
        OpenLoopTelemetry.run_start(run, 2, "medium", "08:00-22:30", 0)
      end

      refute_received {:telemetry, @start_event, _measurements, _metadata}
    end

    test "refuses a run map that is not a correlation" do
      assert_raise KeyError, fn ->
        OpenLoopTelemetry.run_start(%{session_id: @session_id}, 2, "long", "09:00-21:00", 1)
      end
    end
  end

  describe "run_complete/4" do
    test "closes the run with each outcome word and the run's duration", %{run: run} do
      for outcome <- @outcomes do
        assert :ok = OpenLoopTelemetry.run_complete(run, outcome, 4_321)

        assert_receive {:telemetry, @complete_event, measurements, metadata}
        assert measurements == %{duration_ms: 4_321}
        assert metadata == Map.put(base_metadata(), :outcome, outcome)
      end
    end

    test "refuses an outcome outside the closed set, the error words included", %{run: run} do
      for outcome <- ["sent", "declined", "timeout", "error", :spoke, nil] do
        assert_raise FunctionClauseError, fn ->
          OpenLoopTelemetry.run_complete(run, outcome, 10)
        end
      end

      assert_raise FunctionClauseError, fn -> OpenLoopTelemetry.run_complete(run, "spoke", -1) end
      refute_received {:telemetry, @complete_event, _measurements, _metadata}
    end
  end

  describe "run_error/4" do
    test "closes the run with its status word and the error as a string", %{run: run} do
      for status <- @statuses do
        assert :ok =
                 OpenLoopTelemetry.run_error(run, status, 120_000, "watchdog fired at 120000ms")

        assert_receive {:telemetry, @error_event, measurements, metadata}
        assert measurements == %{duration_ms: 120_000}

        assert metadata ==
                 Map.merge(base_metadata(), %{
                   status: status,
                   error: "watchdog fired at 120000ms"
                 })
      end
    end

    test "a non-binary error is inspected, never passed through as a term", %{run: run} do
      OpenLoopTelemetry.run_error(run, "error", 55, {:provider_error, :overloaded})

      assert_receive {:telemetry, @error_event, _measurements, metadata}
      assert metadata.error == "{:provider_error, :overloaded}"
    end

    test "refuses a status outside the closed set", %{run: run} do
      for status <- ["spoke", "failed", "ok", :timeout] do
        assert_raise FunctionClauseError, fn ->
          OpenLoopTelemetry.run_error(run, status, 10, "boom")
        end
      end

      refute_received {:telemetry, @error_event, _measurements, _metadata}
    end
  end

  describe "the content gate" do
    test "the sent text is dropped while the shared gate is off", %{run: run} do
      OpenLoopTelemetry.run_complete(run, "spoke", 10, "Is the pottery kiln booking still on?")

      assert_receive {:telemetry, @complete_event, _measurements, metadata}
      refute Map.has_key?(metadata, :output)
    end

    test "the sent text rides as a preview only when the operator opted in", %{run: run} do
      capture_content(true)

      OpenLoopTelemetry.run_complete(run, "spoke", 10, "Is the pottery kiln booking still on?")

      assert_receive {:telemetry, @complete_event, _measurements, metadata}
      assert metadata.output == "Is the pottery kiln booking still on?"
    end

    test "a run that sent nothing carries no output even with the gate on", %{run: run} do
      capture_content(true)

      OpenLoopTelemetry.run_complete(run, "silent", 10)

      assert_receive {:telemetry, @complete_event, _measurements, metadata}
      refute Map.has_key?(metadata, :output)
    end
  end

  describe "skipped/2" do
    test "a skip is a sessionless point event naming its reason and its loop" do
      for reason <- @skip_reasons do
        assert :ok = OpenLoopTelemetry.skipped(reason, @loop_id)

        assert_receive {:telemetry, @skipped_event, measurements, metadata}
        assert measurements == %{count: 1}

        assert metadata == %{
                 open_loop_id: @loop_id,
                 reason: reason,
                 component: "open_loop_scheduler"
               }
      end
    end

    test "a skip with no loop to name drops the id rather than emitting nil" do
      OpenLoopTelemetry.skipped("disabled", nil)

      assert_receive {:telemetry, @skipped_event, _measurements, metadata}
      assert metadata == %{reason: "disabled", component: "open_loop_scheduler"}
    end

    test "refuses a reason outside the closed set" do
      for reason <- ["window_open", "imminent", "full", :budget] do
        assert_raise FunctionClauseError, fn -> OpenLoopTelemetry.skipped(reason, @loop_id) end
      end

      assert_raise FunctionClauseError, fn -> OpenLoopTelemetry.skipped("budget", "rem_4") end
      refute_received {:telemetry, @skipped_event, _measurements, _metadata}
    end
  end

  describe "settled/6" do
    test "a settlement names both states, the answer, who settled it and the settling turn" do
      assert :ok =
               OpenLoopTelemetry.settled(
                 @loop_id,
                 "asked",
                 "closed",
                 "done",
                 "main_agent",
                 "main-7"
               )

      assert_receive {:telemetry, @settled_event, measurements, metadata}
      assert measurements == %{count: 1}

      assert metadata == %{
               open_loop_id: @loop_id,
               from: "asked",
               to: "closed",
               answer: "done",
               by: "main_agent",
               component: "open_loops",
               session_id: "main-7"
             }
    end

    test "a moved date and a reach change are answers the trace names" do
      for answer <- ["moved", "reach"] do
        assert :ok =
                 OpenLoopTelemetry.settled(
                   @loop_id,
                   "due",
                   "open",
                   answer,
                   "main_agent",
                   "main-7"
                 )

        assert_receive {:telemetry, @settled_event, _measurements, %{answer: ^answer}}
      end
    end

    test "a settlement with no answer and no session carries neither key" do
      for by <- @settlers do
        OpenLoopTelemetry.settled(@loop_id, "due", "expired", nil, by, nil)

        assert_receive {:telemetry, @settled_event, _measurements, metadata}

        assert metadata == %{
                 open_loop_id: @loop_id,
                 from: "due",
                 to: "expired",
                 by: by,
                 component: "open_loops"
               }
      end
    end

    test "refuses a settler, state or answer outside its closed set" do
      assert_raise FunctionClauseError, fn ->
        OpenLoopTelemetry.settled(@loop_id, "asked", "closed", "done", "owner", nil)
      end

      assert_raise FunctionClauseError, fn ->
        OpenLoopTelemetry.settled(@loop_id, "live", "closed", "done", "main_agent", nil)
      end

      assert_raise FunctionClauseError, fn ->
        OpenLoopTelemetry.settled(@loop_id, "asked", "dropped", "drop", "main_agent", nil)
      end

      assert_raise FunctionClauseError, fn ->
        OpenLoopTelemetry.settled(@loop_id, "asked", "closed", "finished", "main_agent", nil)
      end

      assert_raise FunctionClauseError, fn ->
        OpenLoopTelemetry.settled(@loop_id, "asked", "closed", "done", "main_agent", :turn)
      end

      refute_received {:telemetry, @settled_event, _measurements, _metadata}
    end
  end

  describe "fault/3" do
    test "a fault is a sessionless point event naming its stage, its loop and its class" do
      for stage <- @fault_stages do
        assert :ok = OpenLoopTelemetry.fault(stage, @loop_id, :db_down)

        assert_receive {:telemetry, @fault_event, measurements, metadata}
        assert measurements == %{count: 1}

        assert metadata == %{
                 stage: stage,
                 open_loop_id: @loop_id,
                 component: "open_loop_scheduler",
                 error_class: "db_down"
               }
      end
    end

    test "the class is derived from the reason, which never rides the event" do
      reasons = [
        {:repo_timeout, "repo_timeout"},
        {{:budget, {:sqlite, "disk I/O error at /Users/wren/memory.db"}}, "budget"},
        {{:timeout, {GenServer, :call, [:open_loops_repo, :scan, 15_000]}}, "timeout"},
        {"connection to 10.20.30.40 refused", "unclassified"},
        {{"chat 40001 unreachable", :retry}, "unclassified"},
        {{}, "unclassified"},
        {%{destination: "40001"}, "unclassified"},
        {[:db_down], "unclassified"}
      ]

      for {reason, class} <- reasons do
        OpenLoopTelemetry.fault("claim", @loop_id, reason)

        assert_receive {:telemetry, @fault_event, _measurements, metadata}
        assert metadata.error_class == class, "#{inspect(reason)} classified as #{class}"

        assert Map.keys(metadata) |> Enum.sort() == [
                 :component,
                 :error_class,
                 :open_loop_id,
                 :stage
               ]
      end
    end

    test "a fault with no loop to name drops the id rather than emitting nil" do
      OpenLoopTelemetry.fault("scan", nil, :db_down)

      assert_receive {:telemetry, @fault_event, _measurements, metadata}

      assert metadata == %{
               stage: "scan",
               component: "open_loop_scheduler",
               error_class: "db_down"
             }
    end

    test "refuses a stage outside the closed set and an id that is not a loop id" do
      for stage <- ["due", "finalize", "recovery", "Scan", :scan, nil] do
        assert_raise FunctionClauseError, fn ->
          OpenLoopTelemetry.fault(stage, @loop_id, :db_down)
        end
      end

      assert_raise FunctionClauseError, fn -> OpenLoopTelemetry.fault("scan", "rem_4", :x) end
      assert_raise FunctionClauseError, fn -> OpenLoopTelemetry.fault("scan", "loop_", :x) end
      refute_received {:telemetry, @fault_event, _measurements, _metadata}
    end
  end

  describe "reaction/5" do
    test "a reply names the loop, the rung and the delay, with the observing turn's session" do
      assert :ok = OpenLoopTelemetry.reaction(@loop_id, 1, "replied", 7_200_000, "main-7")

      assert_receive {:telemetry, @reaction_event, measurements, metadata}
      assert measurements == %{count: 1, reply_after_ms: 7_200_000}

      assert metadata == %{
               open_loop_id: @loop_id,
               rung: 1,
               outcome: "replied",
               component: "open_loops",
               session_id: "main-7"
             }
    end

    test "silence carries no delay, and no session when the caller has none" do
      assert :ok = OpenLoopTelemetry.reaction(@loop_id, 2, "no_reply", nil, nil)

      assert_receive {:telemetry, @reaction_event, measurements, metadata}
      assert measurements == %{count: 1}

      assert metadata == %{
               open_loop_id: @loop_id,
               rung: 2,
               outcome: "no_reply",
               component: "open_loops"
             }
    end

    test "refuses an outcome, a rung or a delay outside the contract, and any text" do
      for {rung, outcome, after_ms, session} <- [
            {1, "warm", 10, nil},
            {3, "replied", 10, nil},
            {1, "replied", nil, nil},
            {1, "replied", -1, nil},
            {1, "no_reply", 10, nil},
            {1, "replied", 10, :turn}
          ] do
        assert_raise FunctionClauseError, fn ->
          OpenLoopTelemetry.reaction(@loop_id, rung, outcome, after_ms, session)
        end
      end

      assert_raise FunctionClauseError, fn ->
        OpenLoopTelemetry.reaction("rem_4", 1, "replied", 10, nil)
      end

      refute_received {:telemetry, @reaction_event, _measurements, _metadata}
    end
  end

  describe "trace registration" do
    test "every definition names an agent_field the emitter actually sets" do
      definitions = OpenLoopTelemetry.trace_event_definitions()

      assert Enum.map(definitions, &{&1.event, &1.trace_event, &1.agent_field}) == [
               {@start_event, "open_loop_checkin_start", :agent},
               {@complete_event, "open_loop_checkin_complete", :agent},
               {@error_event, "open_loop_checkin_error", :agent},
               {@skipped_event, "open_loop_skipped", :component},
               {@settled_event, "open_loop_settled", :component},
               {@fault_event, "open_loop_fault", :component},
               {@reaction_event, "open_loop_reaction", :component}
             ]

      assert Enum.all?(definitions, &(&1.trace_type == :agent_event))
    end

    test "the shared handler writes each of the seven events as an agent_event row", %{run: run} do
      dir = SafeRm.make_tmp_dir!("open_loop_trace")
      server = :"open_loop_trace_#{System.unique_integer([:positive])}"
      prefix = "open-loop-test-#{System.unique_integer([:positive])}"

      start_supervised!({Trace, base_dir: dir, name: server})
      TelemetryHandler.attach(trace_server: server, handler_prefix: prefix)

      on_exit(fn ->
        TelemetryHandler.detach(prefix)
        SafeRm.rm_rf!(dir)
      end)

      OpenLoopTelemetry.run_start(run, 2, "long", "09:00-21:00", 120_000)
      OpenLoopTelemetry.run_complete(run, "spoke", 42)
      OpenLoopTelemetry.run_error(run, "timeout", 120_000, "watchdog fired")
      OpenLoopTelemetry.skipped("budget", @loop_id)
      OpenLoopTelemetry.settled(@loop_id, "asked", "open", "not_yet", "main_agent", "main-9")
      OpenLoopTelemetry.fault("claim", @loop_id, {:repo_timeout, "chat 40001"})
      OpenLoopTelemetry.reaction(@loop_id, 2, "replied", 5_400_000, "main-9")

      :sys.get_state(server)

      rows =
        [dir, "*", "agent_event.jsonl"]
        |> Path.join()
        |> Path.wildcard()
        |> Enum.flat_map(&(&1 |> File.read!() |> String.split("\n", trim: true)))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&String.starts_with?(&1["event"] || "", "open_loop_"))

      assert Enum.map(rows, &{&1["event"], &1["agent"]}) == [
               {"open_loop_checkin_start", @agent},
               {"open_loop_checkin_complete", @agent},
               {"open_loop_checkin_error", @agent},
               {"open_loop_skipped", "open_loop_scheduler"},
               {"open_loop_settled", "open_loops"},
               {"open_loop_fault", "open_loop_scheduler"},
               {"open_loop_reaction", "open_loops"}
             ]

      [start, complete, error, skipped, settled, fault, reaction] = rows

      assert start["session_id"] == @session_id
      assert start["horizon_class"] == "long"
      assert start["active_hours"] == "09:00-21:00"
      assert complete["outcome"] == "spoke"
      assert complete["duration_ms"] == 42
      assert error["status"] == "timeout"
      assert skipped["reason"] == "budget"
      refute Map.has_key?(skipped, "session_id")
      assert settled["answer"] == "not_yet"
      assert settled["session_id"] == "main-9"
      assert fault["stage"] == "claim"
      assert fault["open_loop_id"] == @loop_id
      assert fault["error_class"] == "repo_timeout"
      refute Map.has_key?(fault, "session_id")
      refute inspect(fault) =~ "40001"
      assert reaction["rung"] == 2
      assert reaction["outcome"] == "replied"
      assert reaction["reply_after_ms"] == 5_400_000
      assert reaction["session_id"] == "main-9"
    end
  end
end
