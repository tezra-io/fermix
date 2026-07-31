defmodule FermixCore.Tools.CodingRunManageTest do
  # The read/manage tools: cancel_coding_run (stubbed manager) plus the shared
  # authorization gate on list/get. No OS processes; the manager is a stub pid
  # via the `:harness_manager` seam.
  use ExUnit.Case, async: true

  alias FermixCore.Tools.CancelCodingRun
  alias FermixCore.Tools.GetCodingRun
  alias FermixCore.Tools.HarnessSupport
  alias FermixCore.Tools.ListCodingRuns

  defmodule StubManager do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))
    def init(state), do: {:ok, state}

    def handle_call({:cancel, _run_id, :owner}, _from, state) do
      notify(state, :cancel_called)
      {:reply, Map.get(state, :cancel_reply, :ok), state}
    end

    defp notify(%{sink: pid}, message) when is_pid(pid), do: send(pid, message)
    defp notify(_state, _message), do: :ok
  end

  @run_id "hr_0123456789ab"

  # --- cancel_coding_run --------------------------------------------------

  describe "cancel_coding_run" do
    test "an attended operator cancel returns cancelling" do
      manager = stub_manager(cancel_reply: :ok)

      assert {:ok, %{success: true, output: output}} =
               CancelCodingRun.execute(%{"run_id" => @run_id}, attended(manager))

      assert %{"run_id" => @run_id, "status" => "cancelling"} = Jason.decode!(output)
      assert_received :cancel_called
    end

    test "an unknown id is reported honestly" do
      manager = stub_manager(cancel_reply: {:error, :not_found})

      assert {:ok, %{success: false, error: error}} =
               CancelCodingRun.execute(%{"run_id" => @run_id}, attended(manager))

      assert error =~ "No coding run found"
    end

    test "an already-terminal run is reported honestly" do
      manager = stub_manager(cancel_reply: {:error, :already_terminal})

      assert {:ok, %{success: false, error: error}} =
               CancelCodingRun.execute(%{"run_id" => @run_id}, attended(manager))

      assert error =~ "already finished"
    end

    test "a delegated worker is refused and never reaches the manager" do
      manager = stub_manager()

      assert {:ok, %{success: false, error: error}} =
               CancelCodingRun.execute(%{"run_id" => @run_id}, worker(manager))

      assert error =~ "subagents"
      refute_received :cancel_called
    end

    test "a missing run_id fails loud" do
      manager = stub_manager()

      assert {:ok, %{success: false, error: error}} =
               CancelCodingRun.execute(%{}, attended(manager))

      assert error =~ "Missing required parameter: run_id"
      refute_received :cancel_called
    end
  end

  # --- list / get authorization gate --------------------------------------

  describe "list_coding_runs / get_coding_run share the gate" do
    test "list refuses a guest before touching the ledger" do
      assert {:ok, %{success: false, error: error}} = ListCodingRuns.execute(%{}, guest())
      assert error =~ "owner only"
    end

    test "get refuses a worker before touching the ledger" do
      assert {:ok, %{success: false, error: error}} =
               GetCodingRun.execute(%{"run_id" => @run_id}, worker(nil))

      assert error =~ "subagents"
    end
  end

  # An agent that polls a run instead of awaiting its continuation must still get
  # the diagnosis: a claude auth failure reaches the ledger as a bare `exit_1` with
  # an empty diagnostics tail, so before `result_tail` the polling path was the one
  # surface where the vendor's own explanation stayed invisible. It is exactly the
  # path the agent took on 2026-07-26 — three get_coding_run calls, nothing learned.
  describe "get_coding_run payload" do
    test "carries the run's harvested text read back off disk" do
      dir = FermixTestSupport.SafeRm.make_tmp_dir!("harness-payload")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)
      File.write!(Path.join(dir, "result.txt"), "Not logged in · Please run /login")

      row = %{id: @run_id, status: "failed", reason: "exit_1", artifacts_dir: dir}

      payload = HarnessSupport.run_payload(row, HarnessSupport.read_run_text(row))

      assert payload.result_tail == "Not logged in · Please run /login"
    end

    test "is nil when the run left no text" do
      dir = FermixTestSupport.SafeRm.make_tmp_dir!("harness-payload-empty")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

      row = %{id: @run_id, status: "failed", reason: "spawn", artifacts_dir: dir}

      assert HarnessSupport.run_payload(row, HarnessSupport.read_run_text(row)).result_tail == nil
    end
  end

  # --- Helpers ------------------------------------------------------------

  defp stub_manager(replies \\ []) do
    opts = replies |> Map.new() |> Map.put(:sink, self())
    start_supervised!({StubManager, opts})
  end

  defp attended(manager) do
    %{
      agent_name: "main",
      source_trust: :operator,
      subagent_depth: 0,
      reply_fn: fn _text -> :ok end,
      conversation_key: {"telegram", "123", :root},
      session_id: "main-1",
      harness_manager: manager
    }
  end

  defp guest, do: attended(nil) |> Map.put(:source_trust, :guest)

  defp worker(manager) do
    attended(manager) |> Map.delete(:source_trust) |> Map.put(:subagent_depth, 1)
  end
end
