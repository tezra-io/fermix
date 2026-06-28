defmodule FermixCore.SoulCurationTest do
  use ExUnit.Case, async: true

  # SoulCuration audit-logs draft/apply/revert/reset outcomes; keep the suite quiet.
  @moduletag capture_log: true

  alias FermixCore.Memory.Repo
  alias FermixCore.Prompt.BootstrapPaths
  alias FermixCore.Prompt.Defaults
  alias FermixCore.Resource.Registry
  alias FermixCore.Resource.Revision
  alias FermixCore.SoulCuration
  alias FermixCore.SoulCuration.Proposal

  # Minimal stand-in for the main agent: answers the runtime-context
  # invalidation call and forwards the reason to the test process, so we can
  # assert SoulCuration invalidates after a write without booting a MainAgent.
  defmodule InvalidateStub do
    @moduledoc false
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_call({:invalidate_runtime_context, reason}, _from, test_pid) do
      send(test_pid, {:invalidated, reason})
      {:reply, :ok, test_pid}
    end
  end

  # Stand-in provider for the `:adapter` draft seam: returns the structured
  # payload handed via `adapter_opts[:draft_content]`.
  defmodule DraftStub do
    @moduledoc false

    def chat(_messages, _capabilities, opts) do
      {:ok,
       %{
         content: Keyword.fetch!(opts, :draft_content),
         tool_calls: [],
         provider_state: nil,
         usage: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0},
         model: "stub-model"
       }}
    end
  end

  # No curated memory on disk; keeps `propose/2` off the global prompt base dir.
  defmodule NoMemory do
    @moduledoc false
    def load(_agent_id), do: {:ok, %{user: nil, memory: nil}}
  end

  @stub_route_key %{provider: :stub, model: "stub-model", auth_mode: :none, base_url: ""}

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-soul-curation-#{unique}.db")
    repo_name = :"soul_curation_repo_#{unique}"
    dir = Path.join(System.tmp_dir!(), "fermix-soul-bootstrap-#{unique}")
    File.mkdir_p!(dir)

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      FermixTestSupport.SafeRm.rm_rf(dir)
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo_name, dir: dir, soul_path: BootstrapPaths.soul_path("main", bootstrap_dir: dir)}
  end

  test "apply writes the file and commits exactly one soul_curation revision", ctx do
    seed_soul(ctx, "soul v1\n", :seed)

    proposal = proposal("soul v2\n", "soul v1\n")

    assert {:ok, %Revision{} = revision} =
             SoulCuration.apply("main", proposal, opts(ctx))

    assert revision.mutation_source == "soul_curation"
    assert revision.provenance == %{"trigger" => "curation"}
    assert File.read!(ctx.soul_path) == "soul v2\n"

    # Disk and registry agree after apply, so a later BootstrapLoader pass
    # no-ops instead of capturing a spurious :manual_edit revision.
    assert {:ok, Registry.content_hash("soul v2\n")} ==
             Registry.current_hash("main", "soul_md", "global", repo: ctx.repo)

    assert {:ok, revisions} = SoulCuration.revisions("main", opts(ctx))
    assert Enum.map(revisions, & &1.mutation_source) == ["soul_curation", "seed"]
  end

  test "apply invalidates the runtime context after a successful write", ctx do
    seed_soul(ctx, "soul v1\n", :seed)
    {:ok, stub} = start_supervised({InvalidateStub, self()})

    proposal = proposal("soul v2\n", "soul v1\n")

    assert {:ok, %Revision{}} =
             SoulCuration.apply(
               "main",
               proposal,
               Keyword.put(opts(ctx), :main_agent_server, stub)
             )

    assert_receive {:invalidated, :soul_curation}
  end

  test "apply refuses a stale base and leaves the file untouched", ctx do
    seed_soul(ctx, "soul v1\n", :seed)

    # The draft was built from different bytes than what is on disk now.
    proposal = proposal("soul v2\n", "soul OLD\n")

    assert {:error, :stale_base} = SoulCuration.apply("main", proposal, opts(ctx))
    assert File.read!(ctx.soul_path) == "soul v1\n"
    assert {:ok, [seed]} = SoulCuration.revisions("main", opts(ctx))
    assert seed.mutation_source == "seed"
  end

  test "apply refuses when the registry has drifted from disk", ctx do
    # Disk says "soul v1" but the registry's current revision is "soul OTHER":
    # a pre-existing split that must be resolved, not committed on top of.
    File.mkdir_p!(Path.dirname(ctx.soul_path))
    File.write!(ctx.soul_path, "soul v1\n")

    {:ok, _rev} =
      Registry.commit("main", "soul_md", "global", "soul OTHER\n",
        mutation_source: :imported,
        provenance: %{"trigger" => "imported"},
        resource_path: ctx.soul_path,
        repo: ctx.repo
      )

    proposal = proposal("soul v2\n", "soul v1\n")

    assert {:error, :registry_disk_mismatch} = SoulCuration.apply("main", proposal, opts(ctx))
    assert File.read!(ctx.soul_path) == "soul v1\n"
  end

  test "revert restores prior content and appends a rollback revision", ctx do
    seed_soul(ctx, "soul v1\n", :seed)

    assert {:ok, _rev} =
             SoulCuration.apply("main", proposal("soul v2\n", "soul v1\n"), opts(ctx))

    assert {:ok, %Revision{} = revision} = SoulCuration.revert("main", 1, opts(ctx))

    assert revision.revision == 3
    assert revision.mutation_source == "rollback"
    assert File.read!(ctx.soul_path) == "soul v1\n"
  end

  test "reset restores the shipped default on a seeded install", ctx do
    seed_soul(ctx, "soul v1\n", :seed)

    assert {:ok, %Revision{} = revision} = SoulCuration.reset("main", opts(ctx))

    assert revision.mutation_source == "rollback"

    assert revision.provenance == %{
             "trigger" => "reset",
             "reset" => true,
             "description" => "Reset SOUL.md to the rendered shipped default"
           }

    assert File.read!(ctx.soul_path) == Defaults.soul_md()
  end

  test "reset restores the shipped default on an imported-only install", ctx do
    seed_soul(ctx, "imported soul\n", :imported)

    assert {:ok, %Revision{}} = SoulCuration.reset("main", opts(ctx))
    assert File.read!(ctx.soul_path) == Defaults.soul_md()

    assert {:ok, [latest, imported]} = SoulCuration.revisions("main", opts(ctx))
    assert latest.mutation_source == "rollback"
    assert imported.mutation_source == "imported"
  end

  test "reset is a no-op when SOUL.md already matches the shipped default", ctx do
    seed_soul(ctx, Defaults.soul_md(), :seed)

    assert {:ok, :unchanged} = SoulCuration.reset("main", opts(ctx))
    assert File.read!(ctx.soul_path) == Defaults.soul_md()
  end

  test "revisions lists newest first", ctx do
    seed_soul(ctx, "soul v1\n", :seed)
    assert {:ok, _rev} = SoulCuration.apply("main", proposal("soul v2\n", "soul v1\n"), opts(ctx))

    assert {:ok, [latest, oldest]} = SoulCuration.revisions("main", opts(ctx))
    assert {latest.revision, oldest.revision} == {2, 1}
  end

  test "propose drafts a Proposal with diff, route, and deltas via the :adapter seam", ctx do
    seed_soul(ctx, "soul v1\n", :seed)

    drafted = ~s({"no_change": false, "soul_md": "soul v1\\nterser\\n", "rationale": "Tighter."})

    assert {:ok, %Proposal{} = proposal} = propose_draft(ctx, drafted)

    assert proposal.content == "soul v1\nterser\n"
    assert proposal.rationale == "Tighter."
    assert proposal.route_key == @stub_route_key
    assert proposal.base_revision == 1
    assert proposal.base_disk_hash == Registry.content_hash("soul v1\n")
    assert proposal.byte_delta == byte_size("soul v1\nterser\n") - byte_size("soul v1\n")
    assert proposal.line_delta == 1
    assert proposal.diff =~ "+terser"
    assert proposal.provenance.trigger == "curation"
    assert proposal.provenance.mode == "suggest"
    assert proposal.provenance.route == "stub/stub-model"

    # The drafted proposal applies cleanly against the bytes it was built from.
    assert {:ok, %Revision{revision: 2}} = SoulCuration.apply("main", proposal, opts(ctx))
    assert File.read!(ctx.soul_path) == "soul v1\nterser\n"
  end

  test "propose returns :no_change when the model declines", ctx do
    seed_soul(ctx, "soul v1\n", :seed)

    assert {:ok, :no_change} = propose_draft(ctx, ~s({"no_change": true, "soul_md": ""}))
  end

  test "propose fails loud on malformed provider JSON", ctx do
    seed_soul(ctx, "soul v1\n", :seed)

    assert {:error, {:invalid_soul_output, _reason}} = propose_draft(ctx, "{ not valid json")
  end

  test "a malformed draft never leaks the attempted persona to the log or error", ctx do
    seed_soul(ctx, "soul v1\n", :seed)
    secret = "ACME-LAUNCH-PLAN-DO-NOT-LOG"
    # Unterminated JSON string: Jason fails, and its DecodeError carries this whole
    # body (the model's attempted SOUL.md) in `:data` — the leak surface.
    malformed = ~s({"no_change": false, "soul_md": "#{secret} and the rest of the persona)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:invalid_soul_output, detail}} = propose_draft(ctx, malformed)
        # Reduced to a bounded message at the source, so no consumer (log, trace,
        # reply) can surface the draft body.
        assert is_binary(detail)
        refute detail =~ secret
      end)

    assert log =~ "draft failed"
    refute log =~ secret
  end

  defp propose_draft(ctx, drafted) do
    SoulCuration.propose(:suggest,
      agent_id: "main",
      instruction: "be terser",
      adapter: DraftStub,
      route_key: @stub_route_key,
      prompt_files: NoMemory,
      adapter_opts: [draft_content: drafted],
      repo: ctx.repo,
      bootstrap_dir: ctx.dir
    )
  end

  defp proposal(content, base_content) do
    %Proposal{
      content: content,
      base_disk_hash: Registry.content_hash(base_content),
      provenance: %{"trigger" => "curation"}
    }
  end

  defp seed_soul(ctx, content, source) do
    File.mkdir_p!(Path.dirname(ctx.soul_path))
    File.write!(ctx.soul_path, content)

    {:ok, _revision} =
      Registry.commit("main", "soul_md", "global", content,
        mutation_source: source,
        provenance: %{"trigger" => to_string(source)},
        resource_path: ctx.soul_path,
        repo: ctx.repo
      )

    :ok
  end

  defp opts(ctx), do: [repo: ctx.repo, bootstrap_dir: ctx.dir]
end
