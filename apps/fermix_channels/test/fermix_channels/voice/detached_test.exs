defmodule FermixChannels.Voice.DetachedTest do
  @moduledoc """
  The owner of the GPT-Live tasks that outlive their call (M56 §4.6), alone:
  a task handed to it, through the real call-row write on a throwaway
  timeline and the call's record on the same repo, with a stand-in queue
  whose stops it can watch. The session, the bridge and the real queue are
  `Voice.LiveEndToEndTest`'s. The voice and companion registries and the
  mobile sinks are application-wide, so the tests run alone.
  """

  use ExUnit.Case, async: false

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Channels.Voice
  alias FermixChannels.Voice.Detached
  alias FermixCore.Companion.Timeline
  alias FermixCore.Memory.Repo
  alias FermixCore.Realtime.CallRecord

  @moduletag :capture_log

  @repo :voice_detached_test_repo
  @call_uuid "3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b"
  @chat_key {"companion", "main", :root}
  @app_env ~w(companion_store mobile_event_sink mobile_push_launcher)a

  defmodule RepoTimeline do
    @opts [repo: :voice_detached_test_repo]

    def append_proactive(p, key, a, o), do: Timeline.append_proactive(p, key, a, o ++ @opts)
    def history_page(p, o), do: Timeline.history_page(p, o ++ @opts)
  end

  # Answers a stop of one turn as the test says, and tells the test it was
  # asked: the queue's own `{:stop_turn, key, id}` call.
  defmodule StopQueue do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)
    def answer(queue, outcome), do: GenServer.call(queue, {:answer, outcome})

    @impl true
    def init(test_pid), do: {:ok, %{test_pid: test_pid, answer: :stopped}}

    @impl true
    def handle_call({:answer, outcome}, _from, state),
      do: {:reply, :ok, %{state | answer: outcome}}

    def handle_call({:stop_turn, key, message_id}, _from, state) do
      send(state.test_pid, {:stop_turn, key, message_id})
      {:reply, {:ok, state.answer}, state}
    end
  end

  setup do
    test_pid = self()
    previous = Map.new(@app_env, &{&1, Application.fetch_env(:fermix_channels, &1)})
    on_exit(fn -> Enum.each(previous, &restore_env/1) end)
    Application.put_env(:fermix_channels, :companion_store, RepoTimeline)

    Application.put_env(:fermix_channels, :mobile_event_sink, fn profile, event ->
      send(test_pid, {:mobile_event, profile, event})
      :ok
    end)

    Application.put_env(:fermix_channels, :mobile_push_launcher, fn _task ->
      send(test_pid, :push_launched)
      :ok
    end)

    dir = FermixTestSupport.SafeRm.make_tmp_dir!("voice-detached")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

    start_supervised!(
      {Repo, name: @repo, enabled: true, database_path: Path.join(dir, "memory.db")}
    )

    {:ok, _owner} = Registry.register(Companion.registry(), Companion.chat_profile(), 2)
    record!()

    %{queue: start_supervised!({StopQueue, self()}), call_id: "voice_live:#{unique()}"}
  end

  test "an adopted task holds its route and says it is still running", ctx do
    detached = start_detached()

    assert {:ok, forward} = Detached.adopt(detached, task(ctx))
    assert is_function(forward, 1)

    assert [{^detached, %{revision: 1}}] =
             Registry.lookup(Voice.registry(), Detached.route(@call_uuid, "dg_2"))

    assert_receive {:companion_event, %{"t" => "row", "text" => text} = row}
    assert text == "Still working on: user: find the parking rules"

    assert row["metadata"]["call"] == %{
             "uuid" => @call_uuid,
             "event" => "task_running",
             "task_id" => "dg_2",
             "revision" => 1
           }
  end

  test "a reply lands once as the done row, pushed, recorded and stopped", ctx do
    detached = start_detached(mobile_running?: fn -> true end)
    attach_stop_handler(ctx.call_id)
    {:ok, forward} = Detached.adopt(detached, task(ctx))
    assert_receive {:companion_event, %{"t" => "row"}}

    reply = "Parking is in the north garage.\n---shown---\nNorth garage, level 2, three hours."
    :ok = forward.({:result, {:ok, reply}})
    # The same reply routed twice (the session's forward and the adapter's)
    # is one row: the first outcome is kept.
    :ok = forward.({:result, {:ok, reply}})

    assert_receive {:companion_event, %{"t" => "row", "server_seq" => seq} = row}
    assert row["text"] == "North garage, level 2, three hours."
    assert %{"event" => "task_done", "state" => "completed"} = row["metadata"]["call"]
    assert_receive {:mobile_event, "main", %{"t" => "row", "server_seq" => ^seq}}
    assert_receive :push_launched

    assert_receive {:delegation_stop, %{duration_ms: duration}, meta}
    assert duration >= 5_000

    assert %{detached: true, status: "completed", delegation_id: "dg_2", server_seq: ^seq} =
             meta

    assert meta.call_uuid == @call_uuid
    assert meta.turn_session_id == "voice_delegation_9"

    assert eventually(fn -> task_state() == {"completed", "Parking is in the north garage."} end)
    assert Registry.lookup(Voice.registry(), Detached.route(@call_uuid, "dg_2")) == []
    refute_receive {:companion_event, _row}, 100
  end

  test "no push is scheduled while the phone channel does not run", ctx do
    detached = start_detached(mobile_running?: fn -> false end)
    {:ok, forward} = Detached.adopt(detached, task(ctx))
    :ok = forward.({:result, {:error, "The calendar could not be reached."}})

    assert_receive {:companion_event,
                    %{"t" => "row", "text" => "The calendar could not be reached."} = row}

    assert row["metadata"]["call"]["state"] == "failed"
    refute_receive :push_launched, 100
  end

  # The record is the session's until it exits: its settle closes the record
  # with the task list it holds, so an end that arrives sooner waits.
  test "an end that arrives while the session lives is written once it exits", ctx do
    session = spawn(fn -> Process.sleep(:infinity) end)
    detached = start_detached()
    {:ok, forward} = Detached.adopt(detached, %{task(ctx) | session: session})
    assert_receive {:companion_event, %{"t" => "row"}}

    :ok = forward.({:result, {:ok, "Parking is north."}})
    refute_receive {:companion_event, _row}, 200
    assert task_state() == {"detached", "The result will be in the chat."}

    Process.exit(session, :kill)

    assert_receive {:companion_event, %{"t" => "row", "text" => "Parking is north."}}
    assert eventually(fn -> task_state() == {"completed", "Parking is north."} end)
  end

  test "a cancel by its exact ids stops its turn alone, and ends cancelled", ctx do
    detached = start_detached()
    {:ok, forward} = Detached.adopt(detached, task(ctx))

    stale = %{"call_uuid" => @call_uuid, "task_id" => "dg_2", "revision" => 2}
    unknown = %{stale | "task_id" => "dg_9", "revision" => 1}
    assert {:error, :task_not_running} = Detached.cancel(detached, stale)
    assert {:error, :task_not_running} = Detached.cancel(detached, unknown)
    refute_received {:stop_turn, _key, _id}

    assert :ok = Detached.cancel(detached, %{stale | "revision" => 1})
    assert_receive {:stop_turn, @chat_key, "voice-delegation-dg_2-1"}

    # The queue hands the stopped turn's channel `{:cancelled}`.
    :ok = forward.({:result, {:cancelled}})

    assert_receive {:companion_event, %{"t" => "row", "text" => "The task was cancelled."} = row}
    assert row["metadata"]["call"]["state"] == "cancelled"
    assert eventually(fn -> task_state() == {"cancelled", "cancelled"} end)
    assert {:error, :task_not_running} = Detached.cancel(detached, %{stale | "revision" => 1})
  end

  test "past its wall clock its turn is stopped and it ends timed out", ctx do
    detached = start_detached(wall_clock_ms: 50)
    attach_stop_handler(ctx.call_id)
    {:ok, forward} = Detached.adopt(detached, task(ctx))

    assert_receive {:stop_turn, @chat_key, "voice-delegation-dg_2-1"}, 1_000
    :ok = forward.({:result, {:cancelled}})

    assert_receive {:companion_event,
                    %{"t" => "row", "text" => "The task ran past its time limit and was stopped."} =
                      row}

    assert row["metadata"]["call"]["state"] == "timed_out"
    assert_receive {:delegation_stop, _measurements, %{status: "timed_out", detached: true}}
    assert eventually(fn -> task_state() == {"timed_out", "ran past its time limit"} end)
  end

  # A turn no longer in its queue (its queue restarted with it) sends no
  # outcome: the task still ends.
  test "a turn its queue no longer holds ends timed out at the wall clock", ctx do
    :ok = StopQueue.answer(ctx.queue, :not_found)
    detached = start_detached(wall_clock_ms: 50)
    {:ok, _forward} = Detached.adopt(detached, task(ctx))

    assert_receive {:stop_turn, @chat_key, _id}, 1_000

    assert_receive {:companion_event, %{"t" => "row"} = row}, 1_000
    assert row["metadata"]["call"]["event"] == "task_running"
    assert_receive {:companion_event, %{"t" => "row"} = done}, 1_000
    assert done["metadata"]["call"]["state"] == "timed_out"
  end

  test "a ninth task is refused", ctx do
    detached = start_detached()

    for index <- 1..Detached.max_tasks() do
      assert {:ok, _forward} = Detached.adopt(detached, %{task(ctx) | task_id: "dg_#{index}"})
    end

    assert {:error, :full} = Detached.adopt(detached, %{task(ctx) | task_id: "dg_99"})
    assert Registry.lookup(Voice.registry(), Detached.route(@call_uuid, "dg_99")) == []
  end

  defp start_detached(opts \\ []) do
    name = :"voice_detached_#{unique()}"
    defaults = [name: name, mobile_running?: fn -> false end]
    start_supervised!({Detached, Keyword.merge(defaults, opts)}, id: name)
  end

  defp task(ctx) do
    %{
      call_id: ctx.call_id,
      call_uuid: @call_uuid,
      task_id: "dg_2",
      revision: 1,
      request: "user: find the parking rules",
      turn_session_id: "voice_delegation_9",
      elapsed_ms: 5_000,
      record_opts: CallRecord.repo_opts(@repo),
      conversation_key: @chat_key,
      message_id: "voice-delegation-dg_2-1",
      queue: ctx.queue,
      # A session already gone: its record is this owner's from the start.
      session: dead_pid()
    }
  end

  # A closed call in the chat whose second task was handed over as it ended.
  defp record! do
    record =
      CallRecord.new(@call_uuid, "openai_live")
      |> CallRecord.put_task("dg_1", 1, "completed", %{summary: "Booked."})
      |> CallRecord.put_task("dg_2", 1, "running", %{request: "user: find the parking rules"})
      |> CallRecord.put_task("dg_2", 1, "detached", %{
        destination: "chat",
        summary: "The result will be in the chat."
      })

    opts = CallRecord.repo_opts(@repo)
    :ok = CallRecord.open(record, ~U[2026-10-03 09:00:00.000000Z], opts)
    usage = %{voice_cost_cents: 5.35, accounting: "complete"}
    :ok = CallRecord.close(record, :call_stop, usage, ~U[2026-10-03 09:06:00Z], opts, :row)
  end

  defp task_state do
    {:ok, %{tasks: tasks}} = Repo.get_voice_call(@call_uuid, server: @repo)
    task = Enum.find(tasks, &(&1["task_id"] == "dg_2"))
    {task["state"], task["summary"]}
  end

  defp dead_pid do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    pid
  end

  # Pinned to this call's id: the handler is global and another module's call
  # could stop a delegation meanwhile.
  defp attach_stop_handler(call_id) do
    handler_id = "voice-detached-stop-#{unique()}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:fermix, :voice_live, :delegation_stop],
      fn _event, measurements, metadata, _config ->
        if metadata.session_id == call_id,
          do: send(test_pid, {:delegation_stop, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp unique, do: System.unique_integer([:positive])

  defp restore_env({key, {:ok, value}}), do: Application.put_env(:fermix_channels, key, value)
  defp restore_env({key, :error}), do: Application.delete_env(:fermix_channels, key)
end
