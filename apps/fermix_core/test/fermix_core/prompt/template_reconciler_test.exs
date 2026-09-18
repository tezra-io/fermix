defmodule FermixCore.Prompt.TemplateReconcilerTest do
  @moduledoc """
  Hermetic: every call is given its own `:repo`, `:bootstrap_dir` and
  `:agent_id`, so nothing here reads or writes global application env, the
  operator's home, or the suite's shared bootstrap directory.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Agents.MainAgent
  alias FermixCore.Memory.Repo, as: MemoryRepo
  alias FermixCore.Prompt.Defaults
  alias FermixCore.Prompt.TemplateReconciler
  alias FermixCore.Resource.Registry

  @agent_id "main"

  # The four reconciled resources and the file each one owns on disk.
  @resources [
    {:fermix, :fermix_md, "FERMIX.md"},
    {:soul, :soul_md, "SOUL.md"},
    {:realtime, :realtime_md, "REALTIME.md"},
    {:live, :live_md, "LIVE.md"}
  ]

  # Never reconciled (§9.4 memory-exclusion invariant), written beside the
  # bootstrap files so every run has the chance to touch them and must not.
  @protected [
    {"IDENTITY.md", "stale identity content\n"},
    {"USER.md", "stale user memory\n"},
    {"MEMORY.md", "stale agent memory\n"}
  ]

  setup do
    unique = System.unique_integer([:positive, :monotonic])
    root = FermixTestSupport.SafeRm.make_tmp_dir!("template-reconciler-#{unique}")
    bootstrap_dir = Path.join(root, "bootstrap")
    agent_dir = Path.join(bootstrap_dir, @agent_id)
    db_path = Path.join(root, "memory.db")
    repo_name = :"template_reconciler_repo_#{unique}"

    File.mkdir_p!(agent_dir)
    start_supervised!({MemoryRepo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      # Restore the permissions the write-failure case removes so cleanup can
      # still descend into the directory.
      _chmod = File.chmod(agent_dir, 0o755)
      FermixTestSupport.SafeRm.rm_rf!(root)
    end)

    %{
      agent_dir: agent_dir,
      opts: [repo: repo_name, bootstrap_dir: bootstrap_dir, agent_id: @agent_id],
      repo: repo_name
    }
  end

  describe "run/1 adoption" do
    test "adopts an untouched shipped default and keeps the previous bytes one rollback away",
         ctx do
      old = "an older fermix template render\n"
      install(ctx, :fermix, old)
      seed(ctx, :fermix, old)

      assert {:ok, report} = TemplateReconciler.run(ctx.opts)
      entry = resource(report, :fermix)

      assert entry.state == :untouched
      assert entry.outcome == :adopted
      assert entry.default_moved? == true
      assert entry.baseline_revision == 1
      assert read(ctx, :fermix) == Defaults.fermix_md()

      assert {:ok, [adopted, seeded]} =
               Registry.list_revisions(@agent_id, :fermix_md, "global", ctx.opts)

      assert adopted.revision == 2
      assert adopted.parent_revision == seeded.revision
      assert adopted.mutation_source == "template_adopt"
      assert adopted.content == Defaults.fermix_md()

      assert adopted.provenance["trigger"] == "template_adopt"
      assert adopted.provenance["from_hash"] == Registry.content_hash(old)
      assert adopted.provenance["to_hash"] == Registry.content_hash(Defaults.fermix_md())
      assert adopted.provenance["description"] =~ "Adopted the shipped FERMIX.md template"
      assert adopted.provenance["description"] =~ "revision 1"

      assert {:ok, _reverted} =
               Registry.rollback(@agent_id, :fermix_md, "global", 1, ctx.opts)

      assert read(ctx, :fermix) == old
    end

    test "adopts every reconciled resource in one run", ctx do
      for {name, _type, _file} <- @resources do
        install(ctx, name, "an older #{name} render\n")
        seed(ctx, name, "an older #{name} render\n")
      end

      assert {:ok, report} = TemplateReconciler.run(ctx.opts)

      assert Enum.map(report.resources, & &1.outcome) == [:adopted, :adopted, :adopted, :adopted]
      assert read(ctx, :fermix) == Defaults.fermix_md()
      assert read(ctx, :soul) == Defaults.soul_md()
      assert read(ctx, :realtime) == Defaults.realtime_md()
      assert read(ctx, :live) == Defaults.live_md()
    end

    test "a second run is a no-op with no new revisions", ctx do
      install(ctx, :fermix, "an older fermix template render\n")
      seed(ctx, :fermix, "an older fermix template render\n")

      assert {:ok, _first} = TemplateReconciler.run(ctx.opts)
      assert {:ok, second} = TemplateReconciler.run(ctx.opts)

      assert Enum.map(second.resources, & &1.outcome) == [:current, :absent, :absent, :absent]
      assert revision_count(ctx, :fermix_md) == 2
      assert read(ctx, :fermix) == Defaults.fermix_md()
    end
  end

  describe "run/1 preservation" do
    test "a customized file is preserved and reported", ctx do
      mine = "my own fermix rules\n"
      install(ctx, :fermix, mine)
      seed(ctx, :fermix, "an older fermix template render\n")

      assert {:ok, report} = TemplateReconciler.run(ctx.opts)
      entry = resource(report, :fermix)

      assert entry.state == :customized
      assert entry.outcome == :customized
      assert entry.default_moved? == true
      assert entry.baseline_revision == 1
      assert read(ctx, :fermix) == mine
      assert revision_count(ctx, :fermix_md) == 1
    end

    test "a file already equal to the shipped default is left alone", ctx do
      install(ctx, :fermix, Defaults.fermix_md())
      seed(ctx, :fermix, Defaults.fermix_md())

      assert {:ok, report} = TemplateReconciler.run(ctx.opts)
      entry = resource(report, :fermix)

      assert entry.state == :current
      assert entry.outcome == :current
      assert entry.default_moved? == false
      assert read(ctx, :fermix) == Defaults.fermix_md()
      assert revision_count(ctx, :fermix_md) == 1
    end

    test "a file with no baseline record is preserved as unknown", ctx do
      mystery = "content of unknown origin\n"
      install(ctx, :fermix, mystery)

      assert {:ok, report} = TemplateReconciler.run(ctx.opts)
      entry = resource(report, :fermix)

      assert entry.state == :unknown
      assert entry.outcome == :unknown
      assert entry.baseline_revision == nil
      assert read(ctx, :fermix) == mystery
      assert revision_count(ctx, :fermix_md) == 0
    end

    test "an absent file is never created", ctx do
      assert {:ok, report} = TemplateReconciler.run(ctx.opts)

      assert Enum.map(report.resources, & &1.state) == [:absent, :absent, :absent, :absent]
      assert Enum.map(report.resources, & &1.outcome) == [:absent, :absent, :absent, :absent]

      for {_name, _type, file} <- @resources do
        refute File.exists?(Path.join(ctx.agent_dir, file))
      end
    end

    test "a whitespace-only file is left exactly as it is", ctx do
      blank = "   \n\n\t\n"
      install(ctx, :soul, blank)
      seed(ctx, :soul, "an older soul render\n")

      assert {:ok, report} = TemplateReconciler.run(ctx.opts)
      entry = resource(report, :soul)

      assert entry.state == :empty
      assert entry.outcome == :empty
      assert entry.installed_hash == nil
      assert read(ctx, :soul) == blank
      assert revision_count(ctx, :soul_md) == 1
    end
  end

  describe "run/1 baseline recognition" do
    test "a soul reset revision counts as a baseline", ctx do
      restored = "the soul shipped two releases ago\n"
      install(ctx, :soul, restored)
      seed(ctx, :soul, "the original seeded soul\n")

      commit(ctx, :soul_md, restored,
        mutation_source: :rollback,
        provenance: %{trigger: "reset", reset: true, description: "reset"}
      )

      assert {:ok, report} = TemplateReconciler.run(ctx.opts)
      entry = resource(report, :soul)

      assert entry.state == :untouched
      assert entry.outcome == :adopted
      assert entry.baseline_revision == 2
      assert read(ctx, :soul) == Defaults.soul_md()
    end

    test "a plain rollback revision is not a baseline", ctx do
      rolled_back = "content an operator hand-wrote and later restored\n"
      install(ctx, :soul, rolled_back)
      seed(ctx, :soul, "the original seeded soul\n")

      commit(ctx, :soul_md, rolled_back,
        mutation_source: :rollback,
        provenance: %{trigger: "rollback", target_revision: 1, from_revision: 2}
      )

      assert {:ok, report} = TemplateReconciler.run(ctx.opts)
      entry = resource(report, :soul)

      assert entry.state == :customized
      assert entry.outcome == :customized
      assert entry.baseline_revision == 1
      assert read(ctx, :soul) == rolled_back
      assert revision_count(ctx, :soul_md) == 2
    end
  end

  describe "run/1 failure and skip" do
    test "a failed write is reported per resource and changes nothing", ctx do
      old = "an older fermix template render\n"
      install(ctx, :fermix, old)
      seed(ctx, :fermix, old)
      install(ctx, :soul, Defaults.soul_md())
      seed(ctx, :soul, Defaults.soul_md())

      File.chmod!(ctx.agent_dir, 0o500)
      result = TemplateReconciler.run(ctx.opts)
      File.chmod!(ctx.agent_dir, 0o755)

      assert {:ok, report} = result
      assert {:error, :eacces} = resource(report, :fermix).outcome
      assert resource(report, :soul).outcome == :current
      assert read(ctx, :fermix) == old
      assert revision_count(ctx, :fermix_md) == 1
      assert Path.wildcard(Path.join(ctx.agent_dir, "FERMIX.md.tmp-*")) == []
    end

    test "a disabled repo skips every resource and writes nothing", ctx do
      old = "an older fermix template render\n"
      install(ctx, :fermix, old)

      disabled = :"template_reconciler_disabled_#{System.unique_integer([:positive])}"

      start_supervised!(
        Supervisor.child_spec({MemoryRepo, name: disabled, enabled: false}, id: disabled)
      )

      opts = Keyword.put(ctx.opts, :repo, disabled)

      assert {:ok, report} = TemplateReconciler.run(opts)

      assert Enum.map(report.resources, & &1.state) == [:skipped, :skipped, :skipped, :skipped]
      assert Enum.map(report.resources, & &1.outcome) == [:skipped, :skipped, :skipped, :skipped]
      assert read(ctx, :fermix) == old
    end

    test "an invalid agent id is refused", ctx do
      assert {:error, {:invalid_agent_id, "../escape"}} =
               TemplateReconciler.run(Keyword.put(ctx.opts, :agent_id, "../escape"))
    end
  end

  describe "classify/2" do
    test "classifies without writing anything", ctx do
      old = "an older fermix template render\n"
      install(ctx, :fermix, old)
      seed(ctx, :fermix, old)

      assert {:ok, entries} = TemplateReconciler.classify(@agent_id, ctx.opts)

      assert Enum.map(entries, & &1.name) == [:fermix, :soul, :realtime, :live]
      assert Enum.map(entries, & &1.state) == [:untouched, :absent, :absent, :absent]
      refute Enum.any?(entries, &Map.has_key?(&1, :outcome))
      assert read(ctx, :fermix) == old
      assert revision_count(ctx, :fermix_md) == 1
    end

    test "a customized file whose shipped template never moved is not drift", ctx do
      mine = "my own fermix rules\n"
      install(ctx, :fermix, mine)
      seed(ctx, :fermix, Defaults.fermix_md())

      assert {:ok, entries} = TemplateReconciler.classify(@agent_id, ctx.opts)
      entry = Enum.find(entries, &(&1.name == :fermix))

      assert entry.state == :customized
      assert entry.default_moved? == false
    end
  end

  describe "memory exclusion" do
    test "identity and memory files are untouched by an adopting run", ctx do
      for {name, _type, _file} <- @resources do
        install(ctx, name, "an older #{name} render\n")
        seed(ctx, name, "an older #{name} render\n")
      end

      for {file, content} <- @protected do
        File.write!(Path.join(ctx.agent_dir, file), content)
      end

      assert {:ok, report} = TemplateReconciler.run(ctx.opts)
      assert Enum.all?(report.resources, &(&1.outcome == :adopted))

      for {file, content} <- @protected do
        assert File.read!(Path.join(ctx.agent_dir, file)) == content
      end

      for type <- [:identity_md, :user_md, :memory_md] do
        assert {:error, :not_found} =
                 Registry.get_resource(@agent_id, type, "global", ctx.opts)
      end
    end
  end

  describe "application tree" do
    test "the reconciler starts after the memory repo and before the main agent" do
      order = FermixCore.Supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))

      # `which_children/1` reports one fixed order per OTP release, but whether
      # that order is start order or its reverse is an implementation detail.
      # `MemoryRepo` provably starts before `MainAgent`, so it calibrates the
      # direction for the two assertions that matter.
      forward? = child_index(order, MemoryRepo) < child_index(order, MainAgent)

      assert child_index(order, MemoryRepo) < child_index(order, TemplateReconciler) == forward?
      assert child_index(order, TemplateReconciler) < child_index(order, MainAgent) == forward?
    end

    test "the boot child reports what it did" do
      assert {:ok, report} = TemplateReconciler.report()
      assert report.agent_id == "main"
      assert Enum.map(report.resources, & &1.name) == [:fermix, :soul, :realtime, :live]
    end
  end

  defp install(ctx, name, content) do
    File.write!(Path.join(ctx.agent_dir, file_of(name)), content)
  end

  defp read(ctx, name), do: File.read!(Path.join(ctx.agent_dir, file_of(name)))

  defp file_of(name) do
    {_name, _type, file} = Enum.find(@resources, fn {n, _t, _f} -> n == name end)
    file
  end

  defp type_of(name) do
    {_name, type, _file} = Enum.find(@resources, fn {n, _t, _f} -> n == name end)
    type
  end

  defp seed(ctx, name, content) do
    commit(ctx, type_of(name), content,
      mutation_source: :seed,
      provenance: %{trigger: "setup_seed"}
    )
  end

  defp commit(ctx, type, content, extra) do
    opts =
      ctx.opts
      |> Keyword.merge(extra)
      |> Keyword.put(:resource_path, Path.join(ctx.agent_dir, file_for_type(type)))

    {:ok, _revision} = Registry.commit(@agent_id, type, "global", content, opts)
    :ok
  end

  defp file_for_type(type) do
    {_name, _type, file} = Enum.find(@resources, fn {_n, t, _f} -> t == type end)
    file
  end

  defp revision_count(ctx, type) do
    {:ok, revisions} = Registry.list_revisions(@agent_id, type, "global", ctx.opts)
    length(revisions)
  end

  defp resource(report, name), do: Enum.find(report.resources, &(&1.name == name))

  defp child_index(order, module) do
    index = Enum.find_index(order, &(&1 == module))
    assert index, "#{inspect(module)} is not a child of the application supervisor"
    index
  end
end
