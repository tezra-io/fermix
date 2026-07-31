defmodule FermixCore.Tools.CloudRunToolsTest do
  # The cloud tool surface: codex_cloud_run + stop_tracking_coding_run + the
  # cancel_coding_run cloud branch. No OS processes; the manager is a stub pid via
  # the `:harness_manager` seam that records the request it receives.
  #
  # async: false — the first-use consent gate (design §23.3) reads the global
  # `[fermix_core.harness]` app env (`Config.approved?`) and the setup seeds it;
  # an async test mutating `:harness` would reintroduce the order-dependent-env
  # flake (CLAUDE.md pitfall).
  use ExUnit.Case, async: false

  alias FermixCore.Tools.CancelCodingRun
  alias FermixCore.Tools.CodexCloudRun
  alias FermixCore.Tools.StopTrackingCodingRun

  @run_id "hr_0123456789ab"
  @task_url "https://chatgpt.com/codex/tasks/task_i_abc123"

  defmodule StubManager do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))
    def init(state), do: {:ok, state}

    def handle_call({:start_cloud_run, request}, _from, state) do
      notify(state, {:start_cloud_run, request})
      {:reply, Map.get(state, :start_reply, {:ok, "hr_cloud0001"}), state}
    end

    def handle_call({:block_scheduled_cloud, block}, _from, state) do
      notify(state, {:block_scheduled_cloud, block})
      {:reply, :ok, state}
    end

    def handle_call({:stop_tracking, run_id}, _from, state) do
      notify(state, {:stop_tracking, run_id})
      {:reply, Map.get(state, :stop_reply, {:ok, nil}), state}
    end

    def handle_call({:cancel, _run_id, :owner}, _from, state) do
      notify(state, :cancel_called)
      {:reply, Map.get(state, :cancel_reply, :ok), state}
    end

    defp notify(%{sink: pid}, message) when is_pid(pid), do: send(pid, message)
    defp notify(_state, _message), do: :ok
  end

  # A `Memory.Repo` stub answering only `{:get_scheduled_job, id}` so a scheduled
  # origin resolves a delivery snapshot without a real memory repo (used by the
  # consent scheduled-block test via `Delivery.resolve_snapshot`).
  defmodule MemoryRepoStub do
    use GenServer

    def start_link(job), do: GenServer.start_link(__MODULE__, job)
    def init(job), do: {:ok, job}

    def handle_call({:get_scheduled_job, _id}, _from, job), do: {:reply, {:ok, job}, job}
  end

  # An allowlisted job registry so the scheduled-origin authorization gate passes
  # (the raw job row names `codex_cloud_run`); consent is the next gate under test.
  defmodule AllowlistedRegistry do
    def get_job(_id, _opts), do: {:ok, %{allowed_tools: ["codex_cloud_run"]}}
  end

  setup do
    prior = Application.get_env(:fermix_core, :harness)
    # The first-use consent gate refuses execution until approved; seed it so the
    # manager-boundary tests exercise the run path. The consent describe block
    # overrides `approved` per-test.
    Application.put_env(:fermix_core, :harness, approved: true)
    on_exit(fn -> restore(prior) end)
    :ok
  end

  # --- codex_cloud_run ------------------------------------------------------

  describe "codex_cloud_run" do
    test "an attended submit returns immediately and passes the schema'd params", %{} do
      manager = stub_manager(start_reply: {:ok, @run_id})

      args = %{
        "query" => "fix the flaky test",
        "env_id" => "proj-web",
        "branch" => "feature/x",
        "attempts" => 3
      }

      assert {:ok, %{success: true, output: output}} =
               CodexCloudRun.execute(args, attended(manager))

      assert %{"run_id" => @run_id, "status" => "launched", "detail" => detail} =
               Jason.decode!(output)

      # Background-only (design §23.1): the outcome returns on its own, so the
      # guidance ends the turn instead of inviting a poll.
      assert detail =~ "end your turn now"
      assert detail =~ "Do not poll get_coding_run"

      assert_received {:start_cloud_run, request}

      assert request.params == %{
               query: "fix the flaky test",
               env_id: "proj-web",
               branch: "feature/x",
               attempts: 3
             }

      assert request.continuation_depth == 0
    end

    test "a manager query_too_large is surfaced honestly (tool boundary)" do
      manager = stub_manager(start_reply: {:error, :query_too_large})

      assert {:ok, %{success: false, error: error}} =
               CodexCloudRun.execute(%{"query" => "q", "env_id" => "e"}, attended(manager))

      assert error =~ "too large"
    end

    test "timeout_minutes is rejected as an unknown parameter (poll deadline supersedes it)" do
      manager = stub_manager()

      assert {:ok, %{success: false, error: error}} =
               CodexCloudRun.execute(
                 %{"query" => "q", "env_id" => "e", "timeout_minutes" => 30},
                 attended(manager)
               )

      assert error =~ "Unknown parameter: timeout_minutes"
      refute_received {:start_cloud_run, _request}
    end

    test "a missing query fails loud before reaching the manager" do
      manager = stub_manager()

      assert {:ok, %{success: false, error: error}} =
               CodexCloudRun.execute(%{"env_id" => "e"}, attended(manager))

      assert error =~ "Missing required parameter: query"
      refute_received {:start_cloud_run, _request}
    end

    test "a delegated worker is refused and never reaches the manager" do
      manager = stub_manager()

      assert {:ok, %{success: false, error: error}} =
               CodexCloudRun.execute(%{"query" => "q", "env_id" => "e"}, worker(manager))

      assert error =~ "subagents"
      refute_received {:start_cloud_run, _request}
    end

    test "wait_seconds and notify_on_inline are no longer accepted" do
      manager = stub_manager()

      for key <- ["wait_seconds", "notify_on_inline"] do
        assert {:ok, %{success: false, error: error}} =
                 CodexCloudRun.execute(
                   %{"query" => "q", "env_id" => "e", key => 5},
                   attended(manager)
                 )

        assert error =~ "Unknown parameter: #{key}"
      end

      refute_received {:start_cloud_run, _request}
    end

    test "a continuation turn's depth rides into the submission" do
      manager = stub_manager(start_reply: {:ok, @run_id})
      context = manager |> attended() |> Map.put(:harness_continuation_depth, 3)

      assert {:ok, %{success: true}} =
               CodexCloudRun.execute(%{"query" => "q", "env_id" => "e"}, context)

      assert_received {:start_cloud_run, request}
      assert request.continuation_depth == 3
    end

    test "an out-of-range attempts is refused with the honest attempts vocabulary" do
      manager = stub_manager(start_reply: {:error, {:invalid_param, :attempts, 5}})

      assert {:ok, %{success: false, error: error}} =
               CodexCloudRun.execute(
                 %{"query" => "q", "env_id" => "e", "attempts" => 5},
                 attended(manager)
               )

      assert error =~ "attempts (expected an integer 1-4"
      refute error =~ "invalid_param"
    end
  end

  # --- codex_cloud_run first-use consent gate (design §23.3) ---------------

  describe "codex_cloud_run consent gate" do
    test "an unapproved attended owner is refused with no prompt and no block" do
      Application.put_env(:fermix_core, :harness, approved: false)
      manager = stub_manager()
      test_pid = self()

      # An approval seam is present and must stay untouched: consent is a setup
      # decision, never an in-chat ask (design §23.3).
      context =
        manager
        |> attended()
        |> Map.merge(%{
          reply_fn: fn payload -> send(test_pid, payload) end,
          approval_fn: fn _request -> raise "consent must never be prompted" end
        })

      assert {:ok, %{success: false, error: error}} =
               CodexCloudRun.execute(%{"query" => "q", "env_id" => "e"}, context)

      assert error =~ "Setup → Coding Agents"
      # No dead end: the refusal closes by telling the caller to proceed directly.
      assert error =~ "carry out the work yourself"
      refute_received {:approval_prompt, _prompt, _token}
      refute_received {:start_cloud_run, _request}
      refute_received {:block_scheduled_cloud, _block}
    end

    test "a scheduled unapproved run is ledgered blocked/:consent_required and never submitted" do
      Application.put_env(:fermix_core, :harness, approved: false)
      manager = stub_manager()
      context = scheduled_context(manager)

      assert {:ok, %{success: false, error: error}} =
               CodexCloudRun.execute(%{"query" => "q", "env_id" => "e"}, context)

      assert error =~ "not yet approved"
      assert_received {:block_scheduled_cloud, block}
      assert block.reason == :consent_required
      refute_received {:start_cloud_run, _request}
    end
  end

  # --- stop_tracking_coding_run --------------------------------------------

  describe "stop_tracking_coding_run" do
    test "an attended stop returns tracking_stopped with the task url" do
      manager = stub_manager(stop_reply: {:ok, @task_url})

      assert {:ok, %{success: true, output: output}} =
               StopTrackingCodingRun.execute(%{"run_id" => @run_id}, attended(manager))

      assert %{"run_id" => @run_id, "status" => "tracking_stopped", "task_url" => @task_url} =
               Jason.decode!(output)

      assert_received {:stop_tracking, @run_id}
    end

    test "a local run is refused as not_cloud" do
      manager = stub_manager(stop_reply: {:error, :not_cloud})

      assert {:ok, %{success: false, error: error}} =
               StopTrackingCodingRun.execute(%{"run_id" => @run_id}, attended(manager))

      assert error =~ "not a cloud run"
    end

    test "a delegated worker is refused and never reaches the manager" do
      manager = stub_manager()

      assert {:ok, %{success: false, error: error}} =
               StopTrackingCodingRun.execute(%{"run_id" => @run_id}, worker(manager))

      assert error =~ "subagents"
      refute_received {:stop_tracking, _run_id}
    end
  end

  # --- cancel_coding_run cloud branch --------------------------------------

  describe "cancel_coding_run on a cloud run" do
    test "surfaces vendor_cancel_unsupported with the stop-tracking pointer and task url" do
      manager = stub_manager(cancel_reply: {:error, {:vendor_cancel_unsupported, @task_url}})

      assert {:ok, %{success: false, error: error}} =
               CancelCodingRun.execute(%{"run_id" => @run_id}, attended(manager))

      assert error =~ "cannot be cancelled"
      assert error =~ "stop_tracking_coding_run"
      assert error =~ @task_url
    end
  end

  # --- Helpers --------------------------------------------------------------

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

  # An unattended scheduled origin: authorization passes via the allowlisted job
  # row; the memory-repo stub resolves the delivery snapshot as `scheduled`.
  defp scheduled_context(manager) do
    job = %{
      id: "job_x",
      allowed_tools: ["codex_cloud_run"],
      delivery_mode: "origin",
      delivery_target: %{"platform" => "telegram", "chat_id" => "123"}
    }

    repo = start_supervised!({MemoryRepoStub, job})

    attended(manager)
    |> Map.delete(:reply_fn)
    |> Map.merge(%{
      conversation_key: {:scheduled_job, "job_x", "run_1"},
      job_id: "job_x",
      jobs_registry: AllowlistedRegistry,
      memory_repo: repo
    })
  end

  defp worker(manager) do
    attended(manager) |> Map.delete(:source_trust) |> Map.put(:subagent_depth, 1)
  end

  defp restore(nil), do: Application.delete_env(:fermix_core, :harness)
  defp restore(prior), do: Application.put_env(:fermix_core, :harness, prior)
end
