defmodule FermixCore.Jobs.HealSurfaceTest do
  # M106 §5.5 and §9, as the whole-feature invariant the Known Pitfalls ask
  # for: over everything the registry can register, a heal run's loop is
  # offered exactly `skill_view`, `list_job_runs`, `get_job_run` and
  # `job_heal_respond`; the decision tool is offered to no other run, and no
  # catalog names it; and inside a heal run the two job tools answer for the
  # heal's own job only. The tool list is read from the seeder, never spelled
  # out here, so a tool added later either joins this invariant or fails it.
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Advertisement
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Jobs.HealDiagnosis
  alias FermixCore.Jobs.Registry
  alias FermixCore.Memory.Repo
  alias FermixCore.OpenLoops.CheckIn
  alias FermixCore.Prompt.RuntimeSections
  alias FermixCore.Realtime.LivePrompt
  alias FermixCore.Tools.GetJobRun
  alias FermixCore.Tools.JobHealRespond
  alias FermixCore.Tools.ListJobRuns
  alias FermixTestSupport.SafeRm

  @four ["get_job_run", "job_heal_respond", "list_job_runs", "skill_view"]
  @at ~U[2031-03-04 07:10:00.000000Z]

  # Invented values throughout.
  @checkin_loop %{
    id: "loop_Hq3vZ8nRt2a",
    agent_id: "main",
    owner_id: "default",
    delivery_platform: "telegram",
    delivery_destination: "40017",
    delivery_thread_scope: "root"
  }

  setup do
    unique = System.unique_integer([:positive])
    dir = SafeRm.make_tmp_dir!("job-heal-surface")
    repo = :"heal_surface_repo_#{unique}"
    caps = :"heal_surface_caps_#{unique}"

    start_supervised!(
      {Repo, name: repo, enabled: true, database_path: Path.join(dir, "memory.db")}
    )

    start_supervised!({CapabilityRegistry, name: caps})

    for capability <- every_capability() do
      :ok = CapabilityRegistry.register(caps, capability)
    end

    on_exit(fn -> SafeRm.rm_rf!(dir) end)
    %{repo: repo, caps: caps}
  end

  # Every built-in the seeder can register, and a plugin's, an MCP server's
  # and a skill's capability beside them.
  defp every_capability do
    builtins = Enum.map(BuiltinSeeder.builtin_tool_modules(), &Builtin.from_tool_module/1)

    others =
      for {name, kind, category} <- [
            {"harbour_fetch", :builtin, :plugin},
            {"mcp_tides", :mcp, nil},
            {"tide-reader", :skill, nil}
          ] do
        Capability.new(%{
          name: name,
          description: "Test capability #{name}",
          parameters: %{"type" => "object", "properties" => %{}},
          kind: kind,
          executor: {__MODULE__, :never, []},
          policy_class: :read_only,
          metadata: if(category, do: %{category: category}, else: %{})
        })
      end

    builtins ++ others
  end

  def never(_args, _context), do: raise("no capability may run in this test")

  defp heal_context(ctx, job_id) do
    HealDiagnosis.loop_context(%{
      heal_id: "jhl_0a1b2c3d4e5f6a7b",
      job_id: job_id,
      session_id: "heal_#{job_id}_20310304_073000_a1b2c3",
      parent_session: "cron_#{job_id}_20310304_071000_d4e5f6",
      ref: make_ref(),
      repo: ctx.repo,
      capability_registry: ctx.caps,
      skill_registry: :heal_surface_no_skills
    })
  end

  # What a loop resolves its surface to, and what it then advertises.
  defp offered(ctx, context, filters) do
    ctx.caps
    |> CapabilityRegistry.list_for(filters)
    |> Advertisement.prepare(context)
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  defp heal_filters do
    [
      allowed_tools: HealDiagnosis.allowed_tools(),
      policy: HealDiagnosis.policy(),
      trust: :operator
    ]
  end

  test "over every capability the registry can hold, a heal run is offered exactly four", ctx do
    assert offered(ctx, heal_context(ctx, "job_tides"), heal_filters()) == @four
  end

  test "none of the four changes, sends, runs a command or reaches the network", ctx do
    classes =
      ctx.caps
      |> CapabilityRegistry.list_for(heal_filters())
      |> Map.new(&{&1.name, {&1.policy_class, &1.metadata[:category]}})

    refute Enum.any?(classes, fn {_name, {class, _category}} ->
             class in [:network, :external_api, :gui_control]
           end)

    refute Enum.any?(classes, fn {_name, {_class, category}} ->
             category in [:channel, :plugin, :harness]
           end)

    for name <- @four, do: refute(ctx.caps |> CapabilityRegistry.find(name) |> host_command?())
  end

  defp host_command?({:ok, %Capability{metadata: metadata}}),
    do: Map.get(metadata, :host_command?, false)

  for {label, context} <- [
        {"an owner's turn",
         %{source_trust: :operator, computer_use_origin: :interactive, chat_type: "private"}},
        {"a scheduled run",
         %{source_trust: :operator, trigger: "schedule", job_id: "job_tides", run_id: "run_1"}},
        {"a cue run",
         %{source_trust: :operator, trigger: "cue", cue: %{watcher_id: "cwt_harbour"}}},
        {"a sub-agent",
         %{source_trust: :operator, computer_use_origin: :interactive, subagent_depth: 1}},
        {"a guest", %{source_trust: :guest, computer_use_origin: :interactive}}
      ] do
    test "#{label} is never offered the decision tool, and cannot run it", ctx do
      context = Map.put(unquote(Macro.escape(context)), :memory_repo, ctx.repo)

      refute JobHealRespond.advertise?(context)
      assert [] = Advertisement.prepare([Builtin.from_tool_module(JobHealRespond)], context)

      assert {:ok, result} =
               JobHealRespond.execute(%{"decision" => "tell", "note" => "Nothing."}, context)

      refute result.success
      assert result.error =~ "job_heal_respond"
    end
  end

  test "an open-loop check-in is never offered the decision tool", ctx do
    context =
      CheckIn.loop_context(%{loop: @checkin_loop, touch: 1, repo: ctx.repo, ref: make_ref()})

    refute JobHealRespond.advertise?(context)
    assert [] = Advertisement.prepare([Builtin.from_tool_module(JobHealRespond)], context)
  end

  test "no catalog names the decision tool: the runtime one and the voice call's" do
    capabilities = every_capability()

    refute RuntimeSections.build([], capabilities: capabilities) =~ "job_heal_respond"
    refute LivePrompt.capability_lines(capabilities) =~ "job_heal_respond"
  end

  describe "inside a heal run, the job tools answer for its own job" do
    test "list_job_runs reads the heal's job and refuses any other", ctx do
      own = job_with_run!(ctx)
      other = job_with_run!(ctx)
      context = heal_context(ctx, own.job.id)

      assert {:ok, %{success: true, output: output}} =
               ListJobRuns.execute(%{"job_id" => own.job.id}, context)

      assert [%{"id" => run_id}] = Jason.decode!(output)["runs"]
      assert run_id == own.run.id

      assert {:ok, refused} = ListJobRuns.execute(%{"job_id" => other.job.id}, context)
      refute refused.success
      assert refused.error =~ "only"
    end

    test "get_job_run reads a run of the heal's job and refuses any other", ctx do
      own = job_with_run!(ctx)
      other = job_with_run!(ctx)
      context = heal_context(ctx, own.job.id)

      assert {:ok, %{success: true}} = GetJobRun.execute(%{"run_id" => own.run.id}, context)

      assert {:ok, refused} = GetJobRun.execute(%{"run_id" => other.run.id}, context)
      refute refused.success
      assert refused.error =~ "only"
    end

    test "the owner's own turn still reads any job's runs", ctx do
      other = job_with_run!(ctx)

      context = %{
        memory_repo: ctx.repo,
        source_trust: :operator,
        computer_use_origin: :interactive,
        agent_name: "main"
      }

      assert {:ok, %{success: true}} = ListJobRuns.execute(%{"job_id" => other.job.id}, context)
      assert {:ok, %{success: true}} = GetJobRun.execute(%{"run_id" => other.run.id}, context)
    end
  end

  defp job_with_run!(ctx) do
    {:ok, job} =
      Registry.create_job(
        %{
          name: "Harbour tide table #{System.unique_integer([:positive])}",
          schedule: "every 1 hour",
          timezone: "UTC",
          task_prompt: "Fetch this morning's tides.",
          created_by_trust: "operator"
        },
        repo: ctx.repo,
        now: @at,
        scheduler: nil
      )

    {:ok, run} =
      Repo.upsert_job_run(
        %{
          id: "run_#{System.unique_integer([:positive])}",
          job_id: job.id,
          session_id: "cron_#{job.id}_20310304_071000_a1b2c3",
          trigger: "schedule",
          status: "error",
          error: "wall-clock timeout after 600000ms",
          created_at: @at,
          updated_at: @at
        },
        server: ctx.repo
      )

    %{job: job, run: run}
  end
end
