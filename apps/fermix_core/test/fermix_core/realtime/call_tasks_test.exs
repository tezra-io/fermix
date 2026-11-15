defmodule FermixCore.Realtime.CallTasksTest do
  # The task half both task engines share. GPT Live's whole behaviour is held by
  # `live_session_server_test.exs` and Grok's by `grok_session_server_test.exs`;
  # this pins what only revisions can reach.
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Repo
  alias FermixCore.Realtime.CallRecord
  alias FermixCore.Realtime.CallTasks
  alias FermixCore.Realtime.LiveTranscript

  defmodule Bridge do
    @behaviour FermixCore.Realtime.VoiceBridge

    @impl true
    def conversation_window(_bounds), do: {:ok, %{messages: [], gists: []}}
    @impl true
    def call_active?, do: false
    @impl true
    def chat_call(_key, _channel), do: :none
    @impl true
    def open_call(call), do: {:ok, {:handle, call.call_id}}
    @impl true
    def show(_call, _text), do: {:ok, 7}

    @impl true
    def submit(_handle, request, _callbacks) do
      send(self(), {:submitted, request.delegation_id, request.revision})
      send(self(), {:request, request})
      {:ok, {:task, request.delegation_id, request.revision}}
    end

    @impl true
    def cancel(_handle, task_ref) do
      send(self(), {:cancelled, task_ref})
      :ok
    end

    @impl true
    def detach(_handle, _task_ref, task) do
      test = self()
      {:ok, fn event -> send(test, {:forwarded, task.revision, event}) && :ok end}
    end

    @impl true
    def close_call(_handle), do: :ok
  end

  setup do
    {:ok, tasks} =
      [
        call_id: "voice_live:1",
        call_uuid: "6f1c2a4e-9b3d-4c5e-8a7f-0123456789ab",
        conversation: "chat",
        device_id: "device-1",
        voice_provider: :xai,
        meta: %{session_id: "voice_live:1", engine: "xai_realtime", provider: "xai"},
        clock: fn -> 10_000 end,
        # Memory is off in the suite: the record's writes are a configuration
        # that writes nothing.
        record_opts: CallRecord.repo_opts(Repo)
      ]
      |> CallTasks.new()
      |> CallTasks.put_bridge(Bridge)
      |> CallTasks.open_record("xai_realtime", ~U[2026-10-02 09:00:00Z])
      |> CallTasks.open_bridge_call()

    transcript = LiveTranscript.append(LiveTranscript.new(), :user, "book the room", 8_000, 9_000)
    %{tasks: tasks, transcript: transcript}
  end

  test "revising a task no longer in flight answers unknown, never raises", %{
    tasks: tasks,
    transcript: transcript
  } do
    assert {:error, :unknown_delegation} =
             CallTasks.revise(tasks, "t404", 9_500, transcript, voice_request: "x")
  end

  test "a revision's stale context wait does nothing; the current one submits once", %{
    tasks: tasks
  } do
    silent = LiveTranscript.new()
    {:ok, tasks, []} = CallTasks.create(tasks, "t1", 9_500, silent, voice_request: "Book it")
    assert %{"t1" => {_timer, 1}} = tasks.context_timers

    {:ok, tasks, _told} =
      CallTasks.revise(tasks, "t1", 9_600, silent, voice_request: "Book it at ten")

    assert %{"t1" => {_timer, 2}} = tasks.context_timers

    assert {^tasks, []} = CallTasks.context_wait_expired(tasks, "t1", 1, silent)

    heard = LiveTranscript.append(silent, :user, "book it at ten", 9_000, 9_550)
    {tasks, _told} = CallTasks.context_wait_expired(tasks, "t1", 2, heard)
    assert_received {:submitted, "t1", 2}

    assert {_tasks, []} = CallTasks.context_wait_expired(tasks, "t1", 2, heard)
    refute_received {:submitted, "t1", _revision}
  end

  test "a running revision is cancelled and its task frame says it was replaced", %{
    tasks: tasks,
    transcript: transcript
  } do
    {:ok, tasks, _told} = CallTasks.create(tasks, "t1", 9_500, transcript, voice_request: "a")
    assert_received {:submitted, "t1", 1}

    {:ok, _tasks, told} =
      CallTasks.revise(tasks, "t1", 9_600, transcript, voice_request: "b")

    assert_received {:cancelled, {:task, "t1", 1}}
    assert_received {:submitted, "t1", 2}

    assert [
             {:frame, %{delegation_id: "t1", revision: 1, status: "cancelled"}},
             {:frame, %{delegation_id: "t1", revision: 2, status: "running"}}
           ] = told
  end

  test "only the handed-over revision's events reach its new owner", %{
    tasks: tasks,
    transcript: transcript
  } do
    {:ok, tasks, _told} = CallTasks.create(tasks, "t1", 9_500, transcript, voice_request: "a")
    {:ok, tasks, _told} = CallTasks.revise(tasks, "t1", 9_600, transcript, voice_request: "b")
    {tasks, told} = CallTasks.leave(tasks, transcript)
    assert :handed_over in told

    send(self(), {:delegation_event, "t1", 1, {:result, {:cancelled}}})
    send(self(), {:delegation_event, "t1", 2, {:result, {:ok, "Booked."}}})
    :ok = CallTasks.forward_detached(tasks, 8)

    assert_received {:forwarded, 2, {:result, {:ok, "Booked."}}}
    refute_received {:forwarded, _revision, {:result, {:cancelled}}}
  end

  # M87 Phase 2: the phone's camera. A hand-off carries the newest frame the
  # call holds while the camera is on and the frame is fresh (2 s); with the
  # camera on and none fresh, it carries none and says the camera is on, so
  # the agent is told there is no current picture.
  describe "the camera's frame on a hand-off" do
    setup %{tasks: tasks} do
      Process.put(:now, 10_000)
      %{tasks: %{tasks | clock: fn -> Process.get(:now) end}}
    end

    test "with the camera off a hand-off carries no frame and says it is off", %{
      tasks: tasks,
      transcript: transcript
    } do
      tasks = CallTasks.put_frame(tasks, jpeg("ignored"))
      {:ok, _tasks, _told} = CallTasks.create(tasks, "t1", 9_500, transcript)

      assert_received {:request, %{frame: nil, camera_on?: false}}
    end

    test "the newest fresh frame rides the hand-off, named as the camera's", %{
      tasks: tasks,
      transcript: transcript
    } do
      tasks =
        tasks
        |> CallTasks.camera(true)
        |> CallTasks.put_frame(jpeg("older"))
        |> CallTasks.put_frame(jpeg("newest"))

      Process.put(:now, 12_000)
      {:ok, _tasks, _told} = CallTasks.create(tasks, "t1", 9_500, transcript)

      assert_received {:request,
                       %{
                         frame: %{source: :camera, mime_type: "image/jpeg", data: "newest"},
                         camera_on?: true
                       }}
    end

    test "a frame older than the freshness bound is not used, and is let go", %{
      tasks: tasks,
      transcript: transcript
    } do
      tasks = tasks |> CallTasks.camera(true) |> CallTasks.put_frame(jpeg("stale"))

      Process.put(:now, 10_000 + CallTasks.frame_fresh_ms() + 1)
      {:ok, tasks, _told} = CallTasks.create(tasks, "t1", 9_500, transcript)

      assert_received {:request, %{frame: nil, camera_on?: true}}
      assert tasks.frame == nil
    end

    test "turning the camera off, or clearing, lets the frame go", %{
      tasks: tasks,
      transcript: transcript
    } do
      on = tasks |> CallTasks.camera(true) |> CallTasks.put_frame(jpeg("seen"))

      assert (on |> CallTasks.camera(false)).frame == nil
      assert (on |> CallTasks.put_frame(nil)).frame == nil

      back_on = on |> CallTasks.camera(false) |> CallTasks.camera(true)
      {:ok, _tasks, _told} = CallTasks.create(back_on, "t1", 9_500, transcript)

      assert_received {:request, %{frame: nil, camera_on?: true}}
    end

    test "a frame that comes while the camera is off is not kept", %{tasks: tasks} do
      assert CallTasks.put_frame(tasks, jpeg("late")).frame == nil
    end

    # The phone's documented cadence (M87 Phase 2, the app's `CallStills`): a
    # still each second while the owner speaks, each two otherwise, and each
    # six once the scene is still, each up to 100 ms late on the link. A
    # hand-off at any moment finds a frame: the oldest it can be is just before
    # the next one comes.
    test "a hand-off at any moment of a call at the phone's cadence finds a frame", %{
      tasks: tasks,
      transcript: transcript
    } do
      sends =
        [{1_000, 30_000}, {2_000, 30_000}, {6_000, 60_000}, {1_000, 20_000}, {6_000, 40_000}]
        |> Enum.flat_map_reduce(10_000, fn {every, span}, start ->
          {Enum.to_list(start..(start + span - every)//every), start + span}
        end)
        |> elem(0)

      arrivals = Enum.with_index(sends, fn send, n -> send + rem(n, 2) * 100 end)
      on = CallTasks.camera(tasks, true)

      for {at, next} <- Enum.zip(arrivals, tl(arrivals) ++ [List.last(arrivals) + 6_100]) do
        Process.put(:now, at)
        held = CallTasks.put_frame(on, jpeg("at #{at}"))

        Process.put(:now, next - 1)
        {:ok, _tasks, _told} = CallTasks.create(held, "t1", 9_500, transcript)

        assert_received {:request, %{frame: %{data: data}}}, "no frame #{next - 1 - at} ms on"
        assert data == "at #{at}"
      end
    end

    # Kept only while fresh, not until the next hand-off: each frame arms its
    # own clear at the freshness bound, and a newer frame's supersedes it.
    test "a frame is let go by its own timer once it is no longer fresh", %{tasks: tasks} do
      first = tasks |> CallTasks.camera(true) |> CallTasks.put_frame(jpeg("first"))
      %{ref: first_ref, timer: first_timer} = first.frame

      assert Process.read_timer(first_timer) in (CallTasks.frame_fresh_ms() - 100)..CallTasks.frame_fresh_ms()

      second = CallTasks.put_frame(first, jpeg("second"))
      %{ref: second_ref} = second.frame
      refute Process.read_timer(first_timer)

      # The superseded frame's clear, already on its way, is ignored.
      assert CallTasks.frame_stale(second, first_ref).frame.data == "second"
      assert CallTasks.frame_stale(second, second_ref).frame == nil
    end

    test "Camera off and a clear stop the frame's timer", %{tasks: tasks} do
      on = tasks |> CallTasks.camera(true) |> CallTasks.put_frame(jpeg("seen"))

      for gone <- [CallTasks.camera(on, false), CallTasks.put_frame(on, nil)] do
        assert gone.frame == nil
        refute Process.read_timer(on.frame.timer)
      end
    end

    # A crash report prints the session's state: the frame is its size and source.
    test "the frame prints as its size, never its bytes", %{tasks: tasks} do
      tasks =
        tasks
        |> CallTasks.camera(true)
        |> CallTasks.put_frame(jpeg(<<0xFF, 0xD8, 0xFF, "picture">>))

      printable = CallTasks.printable(tasks)

      assert %{source: :camera, bytes: 10} = printable.frame
      refute inspect(printable, limit: :infinity) =~ "255, 216, 255"
      assert CallTasks.printable(CallTasks.camera(tasks, false)).frame == nil
    end
  end

  defp jpeg(data), do: %{mime_type: "image/jpeg", data: data}
end
