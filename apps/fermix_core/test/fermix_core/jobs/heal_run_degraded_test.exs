defmodule FermixCore.Jobs.HealRunDegradedTest do
  # M106 §6, §5.5, §9 (stage S5): the heal a run that ended ok without working
  # opens. A job's is diagnosed like any other: the run gets the tool's name
  # and its failed calls in each of the three runs as Fermix's own facts, and
  # the tool's last words only inside the frame that marks text someone else
  # could have written, never in a tool result or anywhere else in its
  # prompt. A plugin's has no job of its own: no model runs, and code sends one
  # message naming the plugin, the tool and the jobs. The model is a scripted
  # adapter, the channel a named Agent, every time injected.
  use ExUnit.Case, async: true

  alias FermixCore.Agents.AgentDefinition
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Jobs.HealRun
  alias FermixCore.Jobs.Registry
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo
  alias FermixCore.Tools.GetJobRun
  alias FermixCore.Tools.JobHealRespond
  alias FermixCore.Tools.ListJobRuns
  alias FermixCore.Tools.SkillView
  alias FermixTestSupport.SafeRm

  # Every value here is invented.
  @created ~U[2031-03-03 06:00:00.000000Z]
  @now ~U[2031-03-04 09:30:00.000000Z]
  @lease_s 300
  @lisbon [personalization: [timezone: "Europe/Lisbon"]]
  @words "needs reconnection: words-marker-5T"
  @frame ~s(<untrusted_tool_result source="job_failure">)

  defmodule ScriptedChannel do
    @moduledoc false

    def send_message(destination, text, opts) do
      destination
      |> String.to_existing_atom()
      |> Agent.get_and_update(fn calls -> {:ok, calls ++ [%{text: text, opts: opts}]} end)
    end
  end

  # A scripted turn list, no network: `{:call, name, args}`, a decision, or
  # text. The prompt and every tool result are echoed to the test.
  defmodule ScriptedProvider do
    @moduledoc false

    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(messages, _capabilities, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:provider_chat, messages})
      reply(Keyword.fetch!(opts, :script))
    end

    @impl true
    def continue(%{rest: rest}, tool_results, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:provider_continue, tool_results})
      reply(rest)
    end

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false

    defp reply([]), do: {:ok, turn("", [], [])}
    defp reply([{:text, text} | rest]), do: {:ok, turn(text, [], rest)}

    defp reply([{:call, name, args} | rest]) do
      call = %{
        id: "fc_#{name}",
        call_id: "call_#{name}",
        name: name,
        arguments: Jason.encode!(args)
      }

      {:ok, turn("", [call], rest)}
    end

    defp turn(content, tool_calls, rest) do
      %{
        content: content,
        tool_calls: tool_calls,
        usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
        model: "mock",
        provider_state: %{rest: rest}
      }
    end
  end

  defmodule SkillRegistryStub do
    @moduledoc false

    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

    @impl true
    def init(nil), do: {:ok, nil}

    @impl true
    def handle_call({:load, name}, _from, state) do
      {:ok, skill} =
        AgentDefinition.new(%{
          "name" => name,
          "description" => "Use #{name}.",
          "system_prompt" => "Be #{name}."
        })

      {:reply, {:ok, AgentDefinition.with_trust(skill, :operator)}, state}
    end
  end

  setup do
    unique = System.unique_integer([:positive])
    dir = SafeRm.make_tmp_dir!("job-heal-degraded")
    repo = :"heal_degraded_repo_#{unique}"
    store = :"heal_degraded_store_#{unique}"
    tasks = :"heal_degraded_tasks_#{unique}"
    caps = :"heal_degraded_caps_#{unique}"
    skills = :"heal_degraded_skills_#{unique}"
    channel = :"heal_degraded_channel_#{unique}"

    start_supervised!(
      {Repo, name: repo, enabled: true, database_path: Path.join(dir, "memory.db")}
    )

    start_supervised!({Task.Supervisor, name: tasks})

    start_supervised!(
      {ConversationStore, name: store, repo: repo, durable_task_supervisor: tasks}
    )

    start_supervised!({CapabilityRegistry, name: caps})
    start_supervised!({SkillRegistryStub, skills})

    for module <- [JobHealRespond, ListJobRuns, GetJobRun, SkillView] do
      :ok = CapabilityRegistry.register(caps, Builtin.from_tool_module(module))
    end

    start_supervised!(%{
      id: {:channel, channel},
      start: {Agent, :start_link, [fn -> [] end, [name: channel]]}
    })

    bootstrap = Path.join(dir, "bootstrap")
    :ok = File.mkdir_p(Path.join(bootstrap, "main"))
    File.write!(Path.join(bootstrap, "main/IDENTITY.md"), "Identity marker: Quillfeather.")
    on_exit(fn -> SafeRm.rm_rf!(dir) end)

    %{
      repo: repo,
      store: store,
      caps: caps,
      skills: skills,
      channel: channel,
      bootstrap: bootstrap
    }
  end

  test "a job's heal is diagnosed with the tool's facts; its words reach the model only framed",
       ctx do
    job = create_job!(ctx)
    [tripped | _earlier] = trip!(ctx, job, nil)
    {:ok, heal} = claim(ctx)
    assert heal.subject_kind == "job"

    script = [
      {:call, "get_job_run", %{"run_id" => tripped.id}},
      {:call, "list_job_runs", %{"job_id" => job.id}},
      {:call, "job_heal_respond", %{"decision" => "tell", "note" => "Sign it in again."}},
      {:text, ""}
    ]

    run!(ctx, heal, script)

    assert_received {:provider_chat, messages}
    prompt = Enum.map_join(messages, "\n", & &1.content)
    [occasion] = for %{role: "user", content: content} <- messages, do: content

    assert [before_frame, framed] = String.split(occasion, @frame)
    facts = before_frame |> json_block() |> Jason.decode!()

    assert facts["failure"]["kind"] == "tool_never_succeeded"

    assert facts["failure"]["tool"] == %{
             "name" => "tide_lookup",
             "failed_calls_per_run_newest_first" => [3, 2, 1]
           }

    assert framed =~ "words-marker-5T"
    refute before_frame =~ "words-marker-5T"
    assert prompt |> String.split("words-marker-5T") |> length() == 2

    # What the two job tools gave back holds the tally's names and numbers,
    # never its words.
    results = tool_results()
    assert length(results) == 3
    assert Enum.any?(results, &(&1 =~ "tide_lookup"))
    refute Enum.any?(results, &(&1 =~ "words-marker-5T"))

    assert {:ok, %{decision: "tell", state: "waiting"}} = get_heal(ctx, heal.id)
    assert [%{text: text}] = sent(ctx)
    assert text =~ ~s(ran without its tool "tide_lookup" working)
    assert text =~ ~s(The tool said: "#{@words}")
    assert text =~ "Fermix's reading: Sign it in again."
  end

  test "a plugin's heal runs no model and sends one message naming the plugin, the tool and the jobs",
       ctx do
    first = create_job!(ctx, "Harbour tide table")
    second = create_job!(ctx, "Morning brief")
    trip!(ctx, first, "harbour_id")
    trip!(ctx, second, "harbour_id")

    {:ok, heal} = claim(ctx)
    assert %{subject_kind: "plugin", subject_id: "harbour_id", run_count: 2} = heal

    run!(ctx, heal, [{:call, "job_heal_respond", %{"decision" => "pause", "note" => "x"}}])

    refute_received {:provider_chat, _messages}
    assert [%{text: text}] = sent(ctx)
    assert text =~ ~s(Scheduled jobs cannot use the plugin "harbour_id")
    assert text =~ ~s(its tool "tide_lookup")
    assert text =~ ~s(The tool said: "#{@words}")
    # The jobs are named, with no count or "since" (stage S4, round two).
    assert text =~ ~s(It affects these jobs: )
    assert text =~ ~s("Harbour tide table")
    assert text =~ ~s("Morning brief")
    refute text =~ "since"

    assert {:ok, %{state: "waiting", decision: nil, delivery_status: "delivered"}} =
             get_heal(ctx, heal.id)

    for job <- [first, second] do
      assert {:ok, %{enabled?: true, state: "scheduled"}} =
               Repo.get_scheduled_job(job.id, server: ctx.repo)
    end
  end

  # --- helpers -------------------------------------------------------------------

  # Three ok runs of `job` in which `tide_lookup` never succeeded, newest
  # first: the third trips the trigger.
  defp trip!(ctx, job, plugin) do
    for {hour, failed} <- [{6, 1}, {7, 2}, {8, 3}] do
      at = %{@created | day: 4, hour: hour}
      entry = %{"name" => "tide_lookup", "ok" => 0, "error" => failed, "last_error" => @words}
      entry = if plugin, do: Map.put(entry, "plugin", plugin), else: entry

      run = claim_run!(ctx.repo, job.id, at)
      done = DateTime.add(at, 300, :second)

      attrs =
        Map.merge(run, %{
          status: "ok",
          completed_at: done,
          updated_at: done,
          final_response: "Tides fetched.",
          tool_tally: [entry],
          tool_timeline: [%{"name" => "tide_lookup", "duration_ms" => 40, "status" => "error"}],
          heal_facts: %{provider: "anthropic"}
        })

      {:ok, {settled, _job, _settlement}} = Repo.settle_job_run(attrs, :ok, server: ctx.repo)
      settled
    end
    |> Enum.reverse()
  end

  defp create_job!(ctx, name \\ "Harbour tide table") do
    attrs = %{
      name: name,
      schedule: "every 1 hour",
      timezone: "UTC",
      task_prompt: "Fetch this morning's tides.",
      created_by_trust: "operator"
    }

    {:ok, job} = Registry.create_job(attrs, repo: ctx.repo, now: @created, scheduler: nil)
    job
  end

  defp claim_run!(repo, job_id, at) do
    run_attrs = %{
      id: "run_#{System.unique_integer([:positive])}",
      job_id: job_id,
      session_id: "cron_#{job_id}_#{System.unique_integer([:positive])}",
      trigger: "schedule",
      status: "queued",
      claimed_at: at,
      started_at: at,
      delivery_status: "none",
      created_at: at,
      updated_at: at
    }

    patch = %{state: "running", updated_at: at}
    {:ok, {_job, run}} = Repo.claim_job_now(job_id, patch, run_attrs, server: repo)
    run
  end

  defp run!(ctx, heal, script) do
    opts = [
      heal: heal,
      repo: ctx.repo,
      conversation_store: ctx.store,
      delivery_opts: [adapter: ScriptedChannel],
      inbox_opts: [
        jobs_config: [],
        configured_owners: %{"telegram" => Atom.to_string(ctx.channel)}
      ],
      clock: fn -> @now end,
      clock_opts: @lisbon,
      capability_registry: ctx.caps,
      skill_registry: ctx.skills,
      bootstrap_dir: ctx.bootstrap,
      adapter: ScriptedProvider,
      adapter_opts: [test_pid: self(), script: script]
    ]

    pid = start_supervised!({HealRun, opts}, id: {:heal_run, System.unique_integer([:positive])})
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 10_000
    assert reason in [:normal, :noproc], "the heal run exited #{inspect(reason)}"
  end

  # The facts block: the pretty-printed JSON between the two lead-ins.
  defp json_block(before_frame) do
    [_lead, rest] = String.split(before_frame, "(Fermix's own facts):\n\n", parts: 2)
    [json | _tail] = String.split(rest, "\n\nThe failure's own sentence", parts: 2)
    json
  end

  defp tool_results do
    receive do
      {:provider_continue, results} -> Enum.map(results, &inspect/1) ++ tool_results()
    after
      0 -> []
    end
  end

  defp sent(ctx), do: Agent.get(ctx.channel, & &1)

  defp claim(ctx),
    do:
      Repo.job_heals_call({:claim, @now, DateTime.add(@now, @lease_s, :second)}, server: ctx.repo)

  defp get_heal(ctx, id), do: Repo.job_heals_call({:get, id}, server: ctx.repo)
end
