defmodule FermixCore.Tools.CodexRunTest do
  # async: false — the advertise?/1 tests flip the global `:harness` app-env
  # (Config.enabled?) and restore it. The execute tests stub the manager via the
  # `:harness_manager` context seam, so they touch no OS process or real repo.
  use ExUnit.Case, async: false

  alias FermixCore.Tools.CancelCodingRun
  alias FermixCore.Tools.ClaudeCodeRun
  alias FermixCore.Tools.CodexCloudRun
  alias FermixCore.Tools.CodexRun
  alias FermixCore.Tools.GetCodingRun
  alias FermixCore.Tools.ListCodingRuns
  alias FermixCore.Tools.StopTrackingCodingRun

  # A stub `Harness.Manager`: the real `Manager.start_run/2` is pointed at this pid
  # via the `:harness_manager` context seam, so it must answer its GenServer
  # protocol. It echoes every `start_run` to the test so refusals can assert
  # admission was never reached.
  defmodule StubManager do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))
    def init(state), do: {:ok, state}

    def handle_call({:start_run, request}, _from, state) do
      notify(state, {:start_run, request})
      {:reply, Map.get(state, :start_run_reply, {:ok, "hr_stub000001"}), state}
    end

    def handle_call({:block_scheduled, block}, _from, state) do
      notify(state, {:block_scheduled, block})
      {:reply, :ok, state}
    end

    defp notify(%{sink: pid}, message) when is_pid(pid), do: send(pid, message)
    defp notify(_state, _message), do: :ok
  end

  defmodule EmptyAllowlistRegistry do
    def get_job(_id, _opts), do: {:ok, %{allowed_tools: []}}
  end

  # An allowlisted job row so the scheduled-origin authorization gate passes and
  # consent becomes the gate under test.
  defmodule AllowlistedRegistry do
    def get_job(_id, _opts), do: {:ok, %{allowed_tools: ["codex_run"]}}
  end

  # A `Memory.Repo` stub answering only `{:get_scheduled_job, id}` so a scheduled
  # origin resolves a delivery snapshot without a real memory repo.
  defmodule MemoryRepoStub do
    use GenServer

    def start_link(job), do: GenServer.start_link(__MODULE__, job)
    def init(job), do: {:ok, job}

    def handle_call({:get_scheduled_job, _id}, _from, job), do: {:reply, {:ok, job}, job}
  end

  setup do
    prior = Application.get_env(:fermix_core, :harness)
    prior_detector = Application.get_env(:fermix_core, :harness_vendor_detector)
    # The first-use consent gate (design §23.3) refuses execution until approved;
    # seed it so the attended-execute tests exercise the run path. The consent and
    # advertise describe blocks override `approved` per-test.
    Application.put_env(:fermix_core, :harness, approved: true)
    cwd = FermixTestSupport.SafeRm.make_tmp_dir!("codex-run-cwd")

    on_exit(fn ->
      restore(prior)
      restore_detector(prior_detector)
    end)

    %{cwd: cwd}
  end

  # --- Execute-time authorization refusals (no admission) -----------------

  describe "execute refuses before any admission" do
    test "a delegated worker is refused and never reaches start_run", ctx do
      manager = stub_manager()
      context = worker_context(ctx.cwd, manager)

      assert {:ok, %{success: false, error: error}} = CodexRun.execute(run_args(ctx.cwd), context)
      assert error =~ "subagents"
      refute_received {:start_run, _request}
    end

    test "a guest is refused and never reaches start_run", ctx do
      manager = stub_manager()
      context = guest_context(ctx.cwd, manager)

      assert {:ok, %{success: false, error: error}} = CodexRun.execute(run_args(ctx.cwd), context)
      assert error =~ "owner only"
      refute_received {:start_run, _request}
    end

    test "an unattended operator turn is refused and never reaches start_run", ctx do
      manager = stub_manager()
      context = ctx.cwd |> attended_context(manager) |> Map.delete(:reply_fn)

      assert {:ok, %{success: false, error: error}} = CodexRun.execute(run_args(ctx.cwd), context)
      assert error =~ "attended operator"
      refute_received {:start_run, _request}
    end

    test "a plain operator cron with no allowlist is refused and never reaches start_run", ctx do
      manager = stub_manager()
      context = cron_context(ctx.cwd, manager, EmptyAllowlistRegistry)

      assert {:ok, %{success: false, error: error}} = CodexRun.execute(run_args(ctx.cwd), context)
      assert error =~ "not authorized"
      refute_received {:start_run, _request}
    end
  end

  # --- Attended operator: background-only launch (design §23.1) -----------

  describe "attended operator launch" do
    test "the launch returns immediately with the run id and admits the run", ctx do
      manager = stub_manager(start_run_reply: {:ok, "hr_run00000001"})
      context = attended_context(ctx.cwd, manager)

      assert {:ok, %{success: true, output: output}} =
               CodexRun.execute(run_args(ctx.cwd), context)

      assert %{"run_id" => "hr_run00000001", "status" => "launched", "detail" => detail} =
               Jason.decode!(output)

      # The guidance removes the reason to poll: the outcome returns on its own.
      assert detail =~ "reports back into this conversation"
      assert detail =~ "end your turn now"
      assert detail =~ "Do not poll get_coding_run"

      assert_received {:start_run, request}
      assert request.vendor == "codex"
      assert request.continuation_depth == 0
      # working_dir/3 resolves symlinks (macOS /var → /private/var), so compare
      # by the sandbox-resolved path, not the raw tmp path.
      assert request.cwd =~ Path.basename(ctx.cwd)
    end

    test "wait_seconds is no longer accepted (unknown-option rejection still works)", ctx do
      manager = stub_manager()
      context = attended_context(ctx.cwd, manager)

      args = ctx.cwd |> run_args() |> Map.put("wait_seconds", 30)
      assert {:ok, %{success: false, error: error}} = CodexRun.execute(args, context)
      assert error =~ "Unknown parameter: wait_seconds"
      refute_received {:start_run, _request}
    end

    test "notify_on_inline is no longer accepted", ctx do
      manager = stub_manager()
      context = attended_context(ctx.cwd, manager)

      args = ctx.cwd |> run_args() |> Map.put("notify_on_inline", true)
      assert {:ok, %{success: false, error: error}} = CodexRun.execute(args, context)
      assert error =~ "Unknown parameter: notify_on_inline"
      refute_received {:start_run, _request}
    end

    test "a continuation turn's depth rides into the run request", ctx do
      manager = stub_manager(start_run_reply: {:ok, "hr_run00000004"})

      context =
        ctx.cwd |> attended_context(manager) |> Map.put(:harness_continuation_depth, 2)

      assert {:ok, %{success: true}} = CodexRun.execute(run_args(ctx.cwd), context)
      assert_received {:start_run, request}
      assert request.continuation_depth == 2
    end

    test "an unknown vendor param fails loud before admission", ctx do
      manager = stub_manager()
      context = attended_context(ctx.cwd, manager)

      args = ctx.cwd |> run_args() |> Map.put("bogus_flag", "x")
      assert {:ok, %{success: false, error: error}} = CodexRun.execute(args, context)
      assert error =~ "Unknown parameter: bogus_flag"
      refute_received {:start_run, _request}
    end

    # §23.2's two configurations: only a chat origin re-enters the conversation, so
    # a scheduled launch must not be told the outcome comes back "into this
    # conversation" — it goes to the job's frozen target.
    test "a scheduled launch is told the outcome goes to the job's target", ctx do
      manager = stub_manager(start_run_reply: {:ok, "hr_run00000005"})

      assert {:ok, %{success: true, output: output}} =
               CodexRun.execute(run_args(ctx.cwd), scheduled_context(ctx.cwd, manager))

      assert %{"detail" => detail} = Jason.decode!(output)
      assert detail =~ "delivered to this job's configured target"
      refute detail =~ "into this conversation"
      assert detail =~ "end your turn now"
    end

    test "a start_run refusal surfaces as an honest tool error", ctx do
      manager = stub_manager(start_run_reply: {:error, :max_active})
      context = attended_context(ctx.cwd, manager)

      assert {:ok, %{success: false, error: error}} = CodexRun.execute(run_args(ctx.cwd), context)
      assert error =~ "concurrent-run limit"
    end
  end

  # --- First-use consent gate (design §23.3) -------------------------------

  describe "first-use consent gate" do
    test "an approved machine runs straight through", ctx do
      # `approved: true` is seeded in setup.
      manager = stub_manager(start_run_reply: {:ok, "hr_consent0001"})
      context = attended_context(ctx.cwd, manager)

      assert {:ok, %{success: true}} = CodexRun.execute(run_args(ctx.cwd), context)
      assert_received {:start_run, _request}
    end

    test "an unapproved attended owner is refused with no prompt, no admission, no block", ctx do
      Application.put_env(:fermix_core, :harness, approved: false)
      manager = stub_manager()
      test_pid = self()

      # An approval seam is present and must stay untouched: consent is a setup
      # decision, never an in-chat ask (design §23.3).
      context =
        ctx.cwd
        |> attended_context(manager)
        |> Map.merge(%{
          reply_fn: fn payload -> send(test_pid, payload) end,
          approval_fn: fn _request -> raise "consent must never be prompted" end
        })

      assert {:ok, %{success: false, error: error}} = CodexRun.execute(run_args(ctx.cwd), context)
      assert error =~ "Setup → Coding Agents"
      refute_received {:approval_prompt, _prompt, _token}
      refute_received {:start_run, _request}
      refute_received {:block_scheduled, _block}
    end

    test "the refusal ends by telling the caller to proceed directly (no dead end)", ctx do
      Application.put_env(:fermix_core, :harness, approved: false)
      manager = stub_manager()

      assert {:ok, %{success: false, error: error}} =
               CodexRun.execute(run_args(ctx.cwd), attended_context(ctx.cwd, manager))

      assert String.ends_with?(
               error,
               "Do not retry this tool — carry out the work yourself now with your ordinary file and shell tools."
             )
    end

    test "a scheduled unapproved run is ledgered blocked/:consent_required and never admitted",
         ctx do
      Application.put_env(:fermix_core, :harness, approved: false)
      manager = stub_manager()
      context = scheduled_context(ctx.cwd, manager)

      assert {:ok, %{success: false, error: error}} = CodexRun.execute(run_args(ctx.cwd), context)
      assert error =~ "not yet approved"
      assert_received {:block_scheduled, block}
      assert block.reason == :consent_required
      refute_received {:start_run, _request}
    end
  end

  # --- Unapproved advertisement (design §23.4) ------------------------------

  # §23.4 collapses the harness into two states, and the state is a property of
  # the WHOLE surface: unusable ⇒ nothing harness-shaped is advertised and Fermix
  # codes with its own tools, silently. Asserting only the run tools let the four
  # manage tools keep advertising with `approved: false` — a wire that offered
  # `get_coding_run` while the prompt (which drops the entire :harness category
  # when unusable) said nothing about the harness at all. Every tool the seeder
  # can register is listed here so the gate cannot drift per-tool again.
  @harness_tools [
    CodexRun,
    ClaudeCodeRun,
    CodexCloudRun,
    GetCodingRun,
    ListCodingRuns,
    CancelCodingRun,
    StopTrackingCodingRun
  ]

  describe "advertise?/1 with consent withheld" do
    test "no harness tool is advertised when approved is false", ctx do
      Application.put_env(:fermix_core, :harness, enabled: true, approved: false)
      put_both_installed()
      context = attended_context(ctx.cwd, nil)

      for tool <- @harness_tools do
        refute tool.advertise?(context), "#{inspect(tool)} advertised on an unapproved host"
      end
    end

    test "every harness tool advertises for the same turn once approved is true", ctx do
      Application.put_env(:fermix_core, :harness, enabled: true, approved: true)
      put_both_installed()
      context = attended_context(ctx.cwd, nil)

      for tool <- @harness_tools do
        assert tool.advertise?(context), "#{inspect(tool)} stayed hidden on an approved host"
      end
    end
  end

  # --- advertise?/1 visibility matrix -------------------------------------

  describe "advertise?/1" do
    test "true for a live attended operator when the harness is enabled and approved", ctx do
      Application.put_env(:fermix_core, :harness, enabled: true, approved: true)
      assert CodexRun.advertise?(attended_context(ctx.cwd, nil))
    end

    test "false when the harness is disabled, even for an attended operator", ctx do
      Application.put_env(:fermix_core, :harness, enabled: false, approved: true)
      refute CodexRun.advertise?(attended_context(ctx.cwd, nil))
    end

    test "false for a guest / worker / unattended turn when enabled", ctx do
      Application.put_env(:fermix_core, :harness, enabled: true, approved: true)

      refute CodexRun.advertise?(guest_context(ctx.cwd, nil))
      refute CodexRun.advertise?(worker_context(ctx.cwd, nil))
      refute CodexRun.advertise?(ctx.cwd |> attended_context(nil) |> Map.delete(:reply_fn))
    end

    test "advertises when it is the selected default and both CLIs are installed", ctx do
      Application.put_env(:fermix_core, :harness,
        enabled: true,
        approved: true,
        default_vendor: "codex"
      )

      put_both_installed()

      assert CodexRun.advertise?(attended_context(ctx.cwd, nil))
    end

    test "does NOT advertise when the OTHER vendor is the selected default", ctx do
      # claude is the default and both are installed → codex_run is filtered off
      # the advertised wire (it stays dispatchable by name — see the execute tests).
      Application.put_env(:fermix_core, :harness,
        enabled: true,
        approved: true,
        default_vendor: "claude"
      )

      put_both_installed()

      refute CodexRun.advertise?(attended_context(ctx.cwd, nil))
    end

    test "advertises regardless of default_vendor when it is the only CLI installed", ctx do
      Application.put_env(:fermix_core, :harness,
        enabled: true,
        approved: true,
        default_vendor: "claude"
      )

      put_installed(codex: true, claude: false)

      assert CodexRun.advertise?(attended_context(ctx.cwd, nil))
    end
  end

  # --- Helpers ------------------------------------------------------------

  defp stub_manager(replies \\ []) do
    opts = replies |> Map.new() |> Map.put(:sink, self())
    start_supervised!({StubManager, opts})
  end

  defp run_args(cwd), do: %{"prompt" => "fix the bug", "cwd" => cwd}

  defp attended_context(cwd, manager) do
    %{
      agent_name: "main",
      source_trust: :operator,
      subagent_depth: 0,
      reply_fn: fn _text -> :ok end,
      conversation_key: {"telegram", "123", :root},
      session_id: "main-1",
      sandbox_config: %{mode: :open, workspace_root: cwd, allowed_roots: [cwd]},
      harness_manager: manager
    }
  end

  defp guest_context(cwd, manager) do
    attended_context(cwd, manager) |> Map.put(:source_trust, :guest)
  end

  defp worker_context(cwd, manager) do
    attended_context(cwd, manager)
    |> Map.delete(:source_trust)
    |> Map.put(:subagent_depth, 1)
  end

  defp cron_context(cwd, manager, registry) do
    attended_context(cwd, manager)
    |> Map.delete(:reply_fn)
    |> Map.merge(%{
      conversation_key: {:scheduled_job, "job_x", "run_1"},
      job_id: "job_x",
      jobs_registry: registry
    })
  end

  # An unattended scheduled origin that PASSES authorization (allowlisted job row)
  # and resolves a `scheduled` delivery snapshot via the memory-repo stub, so the
  # consent gate reaches its scheduled-block branch.
  defp scheduled_context(cwd, manager) do
    job = %{
      id: "job_x",
      allowed_tools: ["codex_run"],
      delivery_mode: "origin",
      delivery_target: %{"platform" => "telegram", "chat_id" => "123"}
    }

    repo = start_supervised!({MemoryRepoStub, job})

    cwd
    |> cron_context(manager, AllowlistedRegistry)
    |> Map.put(:memory_repo, repo)
  end

  defp restore(nil), do: Application.delete_env(:fermix_core, :harness)
  defp restore(prior), do: Application.put_env(:fermix_core, :harness, prior)

  defp restore_detector(nil), do: Application.delete_env(:fermix_core, :harness_vendor_detector)

  defp restore_detector(prior),
    do: Application.put_env(:fermix_core, :harness_vendor_detector, prior)

  defp put_both_installed, do: put_installed(codex: true, claude: true)

  # Override the hermetic `:harness_vendor_detector` seam (config/test.exs installs
  # an all-absent stub) so advertise_vendor? sees the given CLI availability
  # without spawning a real probe.
  defp put_installed(codex: codex?, claude: claude?) do
    detections = %{
      "codex" => %{vendor: "codex", available?: codex?},
      "claude" => %{vendor: "claude", available?: claude?}
    }

    Application.put_env(:fermix_core, :harness_vendor_detector, fn -> detections end)
  end
end
