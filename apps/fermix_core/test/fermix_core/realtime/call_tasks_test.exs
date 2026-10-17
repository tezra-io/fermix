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
end
