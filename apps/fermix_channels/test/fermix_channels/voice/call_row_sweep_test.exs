defmodule FermixChannels.Voice.CallRowSweepTest do
  @moduledoc """
  The boot pass that writes the chat rows Live calls still owe (M56 §4.2,
  §8), through the real bridge and companion channel to a throwaway timeline.
  The companion registry and the phones' sink are application-wide, so the
  tests run alone.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Voice.CallRowSweep
  alias FermixCore.Companion.Timeline
  alias FermixCore.Memory.Repo
  alias FermixCore.Realtime.CallRecord

  @repo :voice_call_row_sweep_repo
  @gisted "3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b"
  @silent "6f1c2a4e-9b3d-4c5e-8a7f-0123456789ab"
  @this_boot "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
  @app_env ~w(companion_store mobile_event_sink)a

  defmodule SweepTimeline do
    @opts [repo: :voice_call_row_sweep_repo]

    def append_proactive(p, key, a, o), do: Timeline.append_proactive(p, key, a, o ++ @opts)
    def history_page(p, o), do: Timeline.history_page(p, o ++ @opts)
  end

  setup do
    previous = Map.new(@app_env, &{&1, Application.fetch_env(:fermix_channels, &1)})
    on_exit(fn -> Enum.each(previous, &restore_env/1) end)
    Application.put_env(:fermix_channels, :companion_store, SweepTimeline)
    Application.put_env(:fermix_channels, :mobile_event_sink, fn _profile, _event -> :ok end)

    dir = FermixTestSupport.SafeRm.make_tmp_dir!("voice-call-row-sweep")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

    start_supervised!(
      {Repo, name: @repo, enabled: true, database_path: Path.join(dir, "memory.db")}
    )

    {:ok, _owner} = Registry.register(Companion.registry(), Companion.chat_profile(), 2)
    :ok
  end

  # A daemon that died after a call settled left its gist pending and its row
  # owed: no process will finish the gist, so it fails, and the row carries
  # the task list. A call that said nothing owed its row alone.
  test "every row a dead daemon left owed is written to the chat, once", %{} do
    earlier = DateTime.add(DateTime.utc_now(), -600, :second)
    owe!(@gisted, earlier, :gist, [{"dg_1", "Booked the room for 10am."}])
    owe!(@silent, earlier, :row, [])

    log = capture_log(fn -> run_sweep() end)
    assert log =~ "wrote 2 chat row(s)"

    assert_receive {:companion_event, %{"t" => "row", "text" => gisted_text} = gisted_row}
    assert_receive {:companion_event, %{"t" => "row", "text" => "Voice call, 10 minutes"}}

    assert gisted_text == "Voice call, 10 minutes\n\n- Completed: Booked the room for 10am."
    assert gisted_row["metadata"]["call"]["gist_status"] == "failed"

    assert {:ok, %{gist_status: "failed", row_state: "row_written"}} =
             Repo.get_voice_call(@gisted, server: @repo)

    assert {:ok, %{row_state: "row_written"}} = Repo.get_voice_call(@silent, server: @repo)
    assert {:ok, %{messages: [_one, _two]}} = SweepTimeline.history_page("main", limit: 10)

    # The next boot finds nothing owed.
    refute capture_log(fn -> run_sweep() end) =~ "chat row"
    refute_received {:companion_event, _row}
  end

  # M56 §4.6, §8: a daemon that died while a task it had detached still ran
  # left it detached in its closed record; the boot writes its done row once
  # and fails it.
  test "a task a dead daemon left detached gets its done row, once", %{} do
    earlier = DateTime.add(DateTime.utc_now(), -600, :second)
    opts = CallRecord.repo_opts(@repo)

    record =
      CallRecord.new(@gisted, "openai_live")
      |> CallRecord.put_task("dg_1", 1, "running", %{request: "user: find parking"})
      |> CallRecord.put_task("dg_1", 1, "detached", %{destination: "chat"})

    :ok = CallRecord.open(record, earlier, opts)
    usage = %{voice_cost_cents: 50.0, accounting: "complete"}
    :ok = CallRecord.close(record, :call_stop, usage, DateTime.add(earlier, 60), opts, :nothing)

    log = capture_log(fn -> run_sweep() end)
    assert log =~ "ended the tasks a daemon restart left running after 1 call(s)"

    assert_receive {:companion_event,
                    %{"t" => "row", "text" => "The task stopped when Fermix restarted."} = row}

    assert row["metadata"]["call"] == %{
             "uuid" => @gisted,
             "event" => "task_done",
             "task_id" => "dg_1",
             "revision" => 1,
             "state" => "failed"
           }

    assert {:ok, %{tasks: [%{"state" => "failed", "summary" => "daemon_restarted"}]}} =
             Repo.get_voice_call(@gisted, server: @repo)

    refute capture_log(fn -> run_sweep() end) =~ "left running"
    refute_received {:companion_event, _row}
  end

  test "a call this boot started is left to its own session's gist" do
    later = DateTime.add(DateTime.utc_now(), 3_600, :second)
    owe!(@this_boot, later, :gist, [])

    run_sweep()

    assert {:ok, %{gist_status: "pending", row_state: "row_pending"}} =
             Repo.get_voice_call(@this_boot, server: @repo)

    refute_received {:companion_event, _row}
  end

  test "with memory off there is nothing to write and nothing is said" do
    repo = :"voice_call_row_sweep_off_#{System.unique_integer([:positive])}"
    start_supervised!({Repo, name: repo, enabled: false}, id: repo)

    refute capture_log(fn -> run_sweep(repo) end) =~ "chat row"
  end

  defp owe!(uuid, started_at, owes, tasks) do
    opts = CallRecord.repo_opts(@repo)

    record =
      Enum.reduce(tasks, CallRecord.new(uuid, "openai_live"), fn {id, summary}, acc ->
        CallRecord.put_task(acc, id, 1, "completed", %{summary: summary})
      end)

    :ok = CallRecord.open(record, started_at, opts)
    usage = %{voice_cost_cents: 50.0, accounting: "complete"}
    ended_at = DateTime.add(started_at, 600, :second)
    :ok = CallRecord.close(record, :call_stop, usage, ended_at, opts, owes)
  end

  # A boot step, not a service: the pass runs once and the process stops normally.
  defp run_sweep(repo \\ @repo) do
    {:ok, sweep} = CallRowSweep.start_link(record_repo: repo)
    ref = Process.monitor(sweep)
    assert_receive {:DOWN, ^ref, :process, ^sweep, :normal}, 5_000
  end

  defp restore_env({key, {:ok, value}}), do: Application.put_env(:fermix_channels, key, value)
  defp restore_env({key, :error}), do: Application.delete_env(:fermix_channels, key)
end
