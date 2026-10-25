defmodule FermixCore.Jobs.RunnerCueTest do
  @moduledoc """
  The runner's cue branch end to end (M60 §9.3–§9.5, C10, C27, C31, C41): a
  claimed cue run builds its prompt and surface from the claimed delivery,
  settles the delivery with its outcome, writes no `latest` summary and no
  reply into its artifact, and sends the owner a prefixed message with Fermix's
  report of its mandate calls, with link previews off.
  """
  # async: false — the runner reads the shared :routing app env.
  use ExUnit.Case, async: false

  import FermixTestSupport.CueFixtures

  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Jobs.CueSurface
  alias FermixCore.Jobs.Registry
  alias FermixCore.Jobs.Runner
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixTestSupport.TelemetryCapture

  @runner_exit_ms 10_000
  @now ~U[2026-10-10 12:00:00Z]
  @report_to %{"platform" => "telegram", "chat_id" => "4242"}
  @provider_down "Watcher release-watch: its task's model provider cannot be reached; passed " <>
                   "items wait and are tried again."

  defmodule ScriptAdapter do
    @moduledoc false
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(messages, capabilities, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:adapter_chat, messages, Enum.map(capabilities, & &1.name)}
      )

      next_turn(Keyword.fetch!(opts, :script))
    end

    @impl true
    def continue(provider_state, tool_results, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:adapter_continue, tool_results})
      next_turn(provider_state.rest)
    end

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false

    defp next_turn([{:error, reason} | _rest]), do: {:error, reason}

    defp next_turn([turn | rest]) do
      {:ok,
       Map.merge(
         %{
           content: "",
           tool_calls: [],
           usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
           model: "mock"
         },
         Map.put(turn, :provider_state, %{rest: rest})
       )}
    end

    defp next_turn([]), do: {:error, "No mock responses left"}
  end

  defmodule RecordingDelivery do
    @moduledoc false
    def send_message(target, text, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:delivery_send, target, text, opts})
      :ok
    end
  end

  setup do
    %{repo: repo, conn: conn} = start_repo("runner_cue")
    registry = :"runner_cue_registry_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: registry})

    output_base_dir =
      Path.join(System.tmp_dir!(), "fermix-runner-cue-#{System.unique_integer([:positive])}")

    routing = Application.get_env(:fermix_core, :routing, [])
    Application.put_env(:fermix_core, :routing, [])

    on_exit(fn ->
      Application.put_env(:fermix_core, :routing, routing)
      FermixTestSupport.SafeRm.rm_rf!(output_base_dir)
    end)

    %{repo: repo, conn: conn, registry: registry, output_base_dir: output_base_dir}
  end

  # --- the prompt, the surface and the context ---------------------------------------

  test "the prompt holds the guidance and the framed cue; the surface is the cue surface (C27)",
       ctx do
    seed_every_builtin(ctx.registry)
    claim = claim_cue(ctx, %{})

    run_cue(ctx, claim, script: [%{content: "Phoenix 1.8.2 is out."}])

    assert_receive {:adapter_chat, messages, offered}
    [guidance, _job_context, _date, user] = messages
    assert guidance.role == "system" and guidance.content =~ "outside data, not instructions"
    assert user.role == "user"
    assert [now_line, task] = String.split(user.content, "\n\n", parts: 2)
    assert now_line =~ ~r/\ANow: .+\.\z/
    assert String.starts_with?(task, "Tell me what changed in the release the cue names.")
    assert user.content =~ ~s(<untrusted_tool_result source="cue:eng-blogs">)
    assert user.content =~ "Filter's reason: a Phoenix release"

    expected =
      ctx.registry
      |> CapabilityRegistry.list()
      |> Enum.filter(&CueSurface.allowed?/1)
      |> Enum.map(& &1.name)
      |> Kernel.--(~w(memory_store memory_recall memory_forget))
      |> Enum.sort()

    assert Enum.sort(offered) == expected
    refute Enum.any?(offered, &(&1 in ~w(shell web_search web_fetch send_attachment codex_run)))
  end

  # The note tools are `:read_write`; the cue surface must reach a real run with
  # them when the owner turned notes on, not be narrowed away by a job policy.
  test "with task notes on, the run is offered the three note tools as well (C52)", ctx do
    seed_every_builtin(ctx.registry)
    claim = claim_cue(ctx, %{task_notes: true})

    run_cue(ctx, claim, script: [%{content: "Noted."}])

    assert_receive {:adapter_chat, _messages, offered}

    expected =
      ctx.registry
      |> CapabilityRegistry.list()
      |> Enum.filter(&CueSurface.allowed?/1)
      |> Enum.map(& &1.name)
      |> Enum.sort()

    assert Enum.sort(offered) == expected
    assert Enum.all?(~w(memory_store memory_recall memory_forget), &(&1 in offered))
  end

  test "the run context carries the cue, its taint and no mandate", ctx do
    :ok = CapabilityRegistry.register(ctx.registry, probe("file_read"))
    claim = claim_cue(ctx, %{})

    run_cue(ctx, claim, script: [%{tool_calls: [call("c1", "file_read")]}, %{content: "Done."}])

    assert_receive {:probe_context, context}
    assert context.trigger == "cue"
    assert context.outside_sources == MapSet.new([{:cue, "eng-blogs"}])
    assert context.cue_mandate == nil
    assert context.cue.delivery_id == claim.delivery.id
    assert context.cue.watcher_name == "release-watch"
    assert context.cue.source_ref == "eng-blogs"
    assert context.cue.task_notes? == false
    refute Map.has_key?(context, :reply_fn)
  end

  # C10, graded on refusal: each call outside the surface comes back "not
  # available" with success false and exactly one exec event, never silence.
  test "calls outside the surface are refused, one exec event each (C10)", ctx do
    seed_every_builtin(ctx.registry)
    claim = claim_cue(ctx, %{})
    TelemetryCapture.attach([[:fermix, :tool, :exec]], session_id: claim.run.session_id)
    refused = ~w(shell memory_store send_attachment web_fetch schedule_job)

    run_cue(ctx, claim,
      script: [
        %{tool_calls: Enum.with_index(refused, &call("c#{&2}", &1))},
        %{content: "Nothing I can do."}
      ]
    )

    assert_receive {:adapter_continue, results}

    assert Enum.map(results, & &1.output) ==
             Enum.map(refused, &"Error: Tool '#{&1}' not available")

    for name <- refused do
      assert_receive {:telemetry, [:fermix, :tool, :exec], _m, %{tool: ^name, success: false}}
      refute_receive {:telemetry, [:fermix, :tool, :exec], _m, %{tool: ^name}}, 0
    end
  end

  # --- the outcome, the message and what is written -----------------------------------

  test "a reply is acted: prefixed, previews off, no latest summary, no reply in the artifact",
       ctx do
    claim = claim_cue(ctx, %{})

    run_cue(ctx, claim, script: [%{content: "Phoenix 1.8.2 is out; upgrade next week."}])

    assert_receive {:delivery_send, "4242", text, opts}

    assert text ==
             "Watcher release-watch · from eng-blogs\n\nPhoenix 1.8.2 is out; upgrade next week."

    assert Keyword.fetch!(opts, :link_previews) == false
    assert delivery_state(ctx.conn, claim.delivery.id) == {"acked", "acted"}

    assert [] ==
             rows(ctx.conn, "SELECT id FROM memories WHERE key = 'latest' AND scope_type = 'job'")

    {:ok, run} = Repo.get_job_run(claim.run.id, server: ctx.repo)
    assert run.final_response == "Phoenix 1.8.2 is out; upgrade next week."
    artifact = File.read!(Path.join(ctx.output_base_dir, run.output_ref))
    refute artifact =~ "Phoenix"
    assert artifact =~ "Run ID: #{run.id}"
    assert artifact =~ "Delivery ID: #{claim.delivery.id}"
    assert artifact =~ "Outcome: acted"
  end

  test "a silent run with no mandate call is ignored and sends nothing", ctx do
    claim = claim_cue(ctx, %{})

    run_cue(ctx, claim, script: [%{content: "[SILENT]"}])

    refute_received {:delivery_send, _target, _text, _opts}
    assert delivery_state(ctx.conn, claim.delivery.id) == {"acked", "ignored"}
    {:ok, run} = Repo.get_job_run(claim.run.id, server: ctx.repo)
    assert run.delivery_status == "skipped"
  end

  # C31: a mandate call, then [SILENT]: acted, and the owner gets the report.
  test "a silent run with a mandate call is acted and sends Fermix's report (C31)", ctx do
    claim = claim_cue(ctx, %{})
    mandate_call(ctx.conn, claim, "allow", nil)

    run_cue(ctx, claim, script: [%{content: "[SILENT]"}])

    assert_receive {:delivery_send, "4242", text, _opts}
    assert String.starts_with?(text, "Watcher release-watch · from eng-blogs\n\n")
    assert text =~ "github_create_issue under mandate release-issues: allowed"
    refute text =~ "[SILENT]"
    assert delivery_state(ctx.conn, claim.delivery.id) == {"acked", "acted"}
  end

  # C41: the only mandate call was refused, then [SILENT]: still acted, still told.
  test "a silent run whose only mandate call was refused is acted and reported (C41)", ctx do
    claim = claim_cue(ctx, %{})
    mandate_call(ctx.conn, claim, "refuse", "the task changed since the mandate was granted")

    run_cue(ctx, claim, script: [%{content: "[SILENT]"}])

    assert_receive {:delivery_send, "4242", text, _opts}
    assert text =~ "refused (the task changed since the mandate was granted)"
    assert delivery_state(ctx.conn, claim.delivery.id) == {"acked", "acted"}
  end

  test "the watcher's unreported gaps reach the prompt and are marked reported", ctx do
    claim = claim_cue(ctx, %{})
    gap_id = gap(ctx.conn, claim.watcher_id, "inbox_full", 12)

    run_cue(ctx, claim, script: [%{content: "[SILENT]"}])

    assert_receive {:adapter_chat, messages, _offered}
    user = List.last(messages)
    assert user.content =~ "Fermix: 12 items from eng-blogs were not delivered since"
    assert user.content =~ "the inbox was full."

    assert [[reported]] =
             rows(ctx.conn, "SELECT reported_at FROM cue_gaps WHERE id = ?", [gap_id])

    assert is_binary(reported)
  end

  # A gap named in a run's prompt is marked reported only by the run that tells
  # the owner: an acked run, or the final failure that names it. A retried
  # attempt leaves it for the next one.
  test "a retried failure leaves the prompt's gaps unreported for the next attempt", ctx do
    claim = claim_cue(ctx, %{})
    gap_id = gap(ctx.conn, claim.watcher_id, "inbox_full", 12)

    run_cue(ctx, claim, script: [{:error, "the loop failed"}])

    assert_receive {:adapter_chat, messages, _offered}
    assert List.last(messages).content =~ "Fermix: 12 items from eng-blogs were not delivered"
    assert [[nil, nil]] == gap_marks(ctx.conn, gap_id)
  end

  test "the final failure names the prompt's gaps and marks them reported", ctx do
    claim = claim_cue(ctx, %{task_attempts: 2})
    gap_id = gap(ctx.conn, claim.watcher_id, "inbox_full", 12)

    run_cue(ctx, claim, script: [{:error, "the loop failed"}])

    assert_receive {:delivery_send, "4242", text, _opts}
    assert text =~ "finished with error"
    assert text =~ "Fermix: 12 items from eng-blogs were not delivered since"
    assert text =~ "the inbox was full."
    assert [[reported, closed]] = gap_marks(ctx.conn, gap_id)
    assert is_binary(reported) and is_binary(closed)
  end

  # --- failures -------------------------------------------------------------------------

  test "a retried failure sends nothing and leaves the memory source as it was", ctx do
    claim = claim_cue(ctx, %{})

    run_cue(ctx, claim, script: [{:error, "the loop failed"}])

    refute_received {:delivery_send, _target, _text, _opts}
    assert [[0 + 1, "passed"]] == attempts_and_state(ctx.conn, claim.delivery.id)
    assert memory_source_status(ctx.conn, claim.job) == nil
    {:ok, run} = Repo.get_job_run(claim.run.id, server: ctx.repo)
    assert run.status == "error"
    assert run.delivery_status == "skipped"
  end

  test "the delivery's final failure sends the failure text once, prefixed", ctx do
    claim = claim_cue(ctx, %{task_attempts: 2})

    run_cue(ctx, claim, script: [{:error, "the loop failed"}])

    assert_receive {:delivery_send, "4242", text, opts}
    assert String.starts_with?(text, "Watcher release-watch · from eng-blogs\n\n")
    assert text =~ "finished with error"
    assert Keyword.fetch!(opts, :link_previews) == false
    refute_receive {:delivery_send, _target, _text, _opts}, 0
    assert delivery_state(ctx.conn, claim.delivery.id) == {"exhausted", "task_failed"}
    assert memory_source_status(ctx.conn, claim.job) == "error"
  end

  # §9.4 row 3, §9.5: a provider failure retries without spending an attempt,
  # and the owner hears once that the task's provider is down, never the
  # failure text.
  test "a provider failure retries without spending an attempt and says the provider is down",
       ctx do
    claim = claim_cue(ctx, %{})

    rate_limited =
      {:provider_error,
       %{
         provider: :openai,
         adapter: :openai,
         status: 429,
         kind: :rate_limit,
         code: nil,
         message: "slow down",
         stage: :before_response
       }}

    run_cue(ctx, claim, script: [{:error, rate_limited}])

    assert_receive {:delivery_send, "4242", @provider_down, opts}
    assert Keyword.fetch!(opts, :link_previews) == false
    refute_received {:delivery_send, _target, _text, _opts}
    assert [[0, "passed"]] == attempts_and_state(ctx.conn, claim.delivery.id)

    assert [[notices]] =
             rows(ctx.conn, "SELECT notices FROM cue_watchers WHERE id = ?", [claim.watcher_id])

    assert Map.has_key?(Jason.decode!(notices), "task_provider_down")
  end

  test "a run with no route is a provider failure", ctx do
    claim = claim_cue(ctx, %{})

    exec!(ctx.conn, "UPDATE scheduled_jobs SET provider = 'no_such_provider' WHERE id = ?", [
      claim.job.id
    ])

    run_cue(ctx, %{claim | job: %{claim.job | provider: "no_such_provider"}}, script: [])

    assert_receive {:delivery_send, "4242", @provider_down, _opts}
    refute_received {:delivery_send, _target, _text, _opts}
    assert [[0, "passed"]] == attempts_and_state(ctx.conn, claim.delivery.id)
  end

  test "a report never goes to a channel a cue run may not reach", ctx do
    claim = claim_cue(ctx, %{target: %{"platform" => "imessage", "chat_id" => "+15550100"}})

    run_cue(ctx, claim, script: [%{content: "Phoenix 1.8.2 is out."}])

    refute_received {:delivery_send, _target, _text, _opts}
    {:ok, run} = Repo.get_job_run(claim.run.id, server: ctx.repo)
    assert run.delivery_status == "failed"
    assert run.delivery_error =~ "imessage"
    assert delivery_state(ctx.conn, claim.delivery.id) == {"acked", "acted"}
  end

  # --- fixtures -------------------------------------------------------------------------

  defp run_cue(ctx, claim, opts) do
    parent = self()
    Process.flag(:trap_exit, true)

    {:ok, pid} =
      Runner.start_link(
        repo: ctx.repo,
        job: claim.job,
        run: claim.run,
        notify: parent,
        capability_registry: ctx.registry,
        adapter: ScriptAdapter,
        adapter_opts: [test_pid: parent, script: Keyword.fetch!(opts, :script)],
        output_base_dir: ctx.output_base_dir,
        timeout_ms: nil,
        default_timeout_ms: nil,
        inactivity_timeout_ms: nil,
        network_readiness_enabled: false,
        delivery_adapter: RecordingDelivery,
        delivery_opts: [test_pid: parent],
        delivery_timeout_ms: nil
      )

    assert_receive {:EXIT, ^pid, :normal}, @runner_exit_ms
  end

  # A cue-only job, its watcher on `eng-blogs`, one passed delivery, claimed.
  defp claim_cue(ctx, attrs) do
    {:ok, job} =
      Registry.create_cue_job(
        %{
          created_by_trust: "operator",
          name: "Release Notes Task",
          task_prompt: "Tell me what changed in the release the cue names.",
          delivery_mode: "channel",
          delivery_target: Map.get(attrs, :target, @report_to)
        },
        repo: ctx.repo,
        scheduler: nil
      )

    watcher_id = "cwt_#{System.unique_integer([:positive])}"

    exec!(
      ctx.conn,
      """
      INSERT INTO cue_watchers
        (id, name, filter, task_job_id, task_notes, enabled, created_at, updated_at)
      VALUES (?, 'release-watch', 'none', ?, ?, 1, ?, ?)
      """,
      [
        watcher_id,
        job.id,
        if(Map.get(attrs, :task_notes, false), do: 1, else: 0),
        stamp(@now),
        stamp(@now)
      ]
    )

    exec!(ctx.conn, "INSERT INTO cue_watcher_sources (watcher_id, source_ref) VALUES (?, ?)", [
      watcher_id,
      "eng-blogs"
    ])

    insert_passed_delivery(ctx.conn, watcher_id, Map.get(attrs, :task_attempts, 0))

    {:ok, claim} =
      Repo.claim_cue_run(
        job.id,
        %{
          id: "run_#{System.unique_integer([:positive])}",
          job_id: job.id,
          session_id: "cron_#{job.id}_20261010_120000_#{System.unique_integer([:positive])}",
          trigger: "cue",
          status: "queued",
          claimed_at: @now,
          delivery_status: "none",
          created_at: @now,
          updated_at: @now
        },
        @now,
        server: ctx.repo
      )

    Map.put(claim, :watcher_id, watcher_id)
  end

  defp insert_passed_delivery(conn, watcher_id, attempts) do
    received = DateTime.add(@now, -60, :second)

    [[cue_id]] =
      rows(
        conn,
        """
        INSERT INTO cues (source_ref, item_id, type, subject, occurred_at, received_at,
          content_hash, payload, payload_bytes, snapshot, routed_count, last_seen_at)
        VALUES ('eng-blogs', ?, 'feed.item', 'phoenix', ?, ?, ?, ?, 30, ?, 1, ?) RETURNING id
        """,
        [
          "item-#{System.unique_integer([:positive])}",
          stamp(received),
          stamp(received),
          "h#{System.unique_integer([:positive])}",
          ~s({"title":"Phoenix 1.8.2 released"}),
          ~s({"type":"feed.item","subject":"phoenix","text":"Phoenix 1.8.2 released"}),
          stamp(received)
        ]
      )

    exec!(
      conn,
      """
      INSERT INTO cue_deliveries (cue_id, watcher_id, source_ref, subject, received_at, state,
        decision_reason, task_attempts, ready_at, valid_until)
      VALUES (?, ?, 'eng-blogs', 'phoenix', ?, 'passed', 'a Phoenix release', ?, ?, ?)
      """,
      [
        cue_id,
        watcher_id,
        stamp(received),
        attempts,
        stamp(received),
        stamp(DateTime.add(@now, 7 * 86_400, :second))
      ]
    )
  end

  defp mandate_call(conn, claim, decision, reason) do
    exec!(
      conn,
      """
      INSERT INTO cue_mandate_calls (id, run_id, job_id, mandate, tool, args_json,
        idempotency_key, delivery_id, decision, reason, created_at, decided_at)
      VALUES (?, ?, ?, 'release-issues', 'github_create_issue', '{"title":"Upgrade"}', ?, ?, ?,
        ?, ?, ?)
      """,
      [
        "cmc_#{System.unique_integer([:positive])}",
        claim.run.id,
        claim.job.id,
        "key-#{System.unique_integer([:positive])}",
        claim.delivery.id,
        decision,
        reason,
        stamp(@now),
        stamp(@now)
      ]
    )
  end

  defp gap(conn, watcher_id, reason, count) do
    id = "cgp_#{System.unique_integer([:positive])}"

    exec!(
      conn,
      """
      INSERT INTO cue_gaps (id, source_ref, watcher_id, reason, count, first_at, last_at)
      VALUES (?, 'eng-blogs', ?, ?, ?, ?, ?)
      """,
      [id, watcher_id, reason, count, stamp(@now), stamp(@now)]
    )

    id
  end

  defp gap_marks(conn, gap_id),
    do: rows(conn, "SELECT reported_at, closed_at FROM cue_gaps WHERE id = ?", [gap_id])

  defp delivery_state(conn, id) do
    [[state, outcome]] =
      rows(conn, "SELECT state, outcome FROM cue_deliveries WHERE id = ?", [id])

    {state, outcome}
  end

  defp attempts_and_state(conn, id),
    do: rows(conn, "SELECT task_attempts, state FROM cue_deliveries WHERE id = ?", [id])

  defp memory_source_status(conn, job) do
    [[status]] =
      rows(conn, "SELECT last_status FROM memory_sources WHERE id = ?", [job.memory_source_id])

    status
  end

  defp seed_every_builtin(registry) do
    :ignore =
      BuiltinSeeder.start_link(
        capability_registry: registry,
        tool_modules: BuiltinSeeder.builtin_tool_modules()
      )

    :ok
  end

  defp probe(name) do
    Capability.new(%{
      name: name,
      description: "records the loop context",
      parameters: %{"type" => "object", "properties" => %{}},
      kind: :builtin,
      executor: {__MODULE__, :execute_probe, [self()]},
      policy_class: :read_only
    })
  end

  def execute_probe(_args, context, test_pid) do
    send(test_pid, {:probe_context, context})
    {:ok, %{success: true, output: "probed"}}
  end

  defp call(call_id, name),
    do: %{id: "fc_#{call_id}", call_id: call_id, name: name, arguments: "{}"}

  defp stamp(at), do: CuesSql.stamp(at)
end
