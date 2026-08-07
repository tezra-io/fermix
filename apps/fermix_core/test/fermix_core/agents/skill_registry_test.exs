defmodule FermixCore.Agents.SkillRegistryTest do
  use ExUnit.Case, async: false

  alias FermixCore.Agents.AgentDefinition
  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.Builtin, as: BuiltinCapability
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Capabilities.Skill, as: SkillCapability
  alias FermixCore.Tools.Shell

  defp write_skill(skills_dir, name, body, opts \\ []) do
    allowed_tools = Keyword.get(opts, :allowed_tools, ~s(["file_read", "shell"]))
    description = Keyword.get(opts, :description, "Use #{name} for focused test work.")
    skill_dir = Path.join(skills_dir, name)
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: #{name}
      description: #{description}
      model: gpt-5.4-mini
      capabilities: ["code"]
      allowed_tools: #{allowed_tools}
      max_iterations: 18
      timeout_seconds: 120
      ---
      #{body}
      """
    )
  end

  defp reload_names(registry) do
    assert {:ok, %{skills: skills}} = SkillRegistry.reload(registry)
    Enum.map(skills, & &1.name)
  end

  def unused_capability_execute(_args, _context), do: {:ok, %{success: true, output: "unused"}}

  setup do
    suffix = System.unique_integer([:positive])
    skills_dir = Path.join(System.tmp_dir!(), "fermix-skill-registry-#{suffix}")
    File.mkdir_p!(skills_dir)

    registry =
      start_supervised!(
        {SkillRegistry,
         name: :"skill_registry_#{suffix}",
         skills_dir: skills_dir,
         core_dir: nil,
         plugin_skill_dirs: [],
         seed_defaults: false}
      )

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(skills_dir) end)

    %{registry: registry, skills_dir: skills_dir}
  end

  describe "load/2" do
    test "returns a defined error for unknown skills", %{registry: registry} do
      assert {:error, {:unknown_skill, "missing-skill"}} =
               SkillRegistry.load(registry, "missing-skill")
    end
  end

  describe "reload/1" do
    test "does not expose newly added skills until reload succeeds", %{
      registry: registry,
      skills_dir: skills_dir
    } do
      assert SkillRegistry.list(registry) == []

      assert {:error, {:unknown_skill, "coding-skill"}} =
               SkillRegistry.load(registry, "coding-skill")

      write_skill(skills_dir, "coding-skill", "You write code.")

      assert SkillRegistry.list(registry) == []

      assert {:error, {:unknown_skill, "coding-skill"}} =
               SkillRegistry.load(registry, "coding-skill")

      assert ["coding-skill"] = reload_names(registry)

      assert SkillRegistry.list(registry) == ["coding-skill"]
      assert {:ok, definition} = SkillRegistry.load(registry, "coding-skill")
      assert definition.name == "coding-skill"
      assert definition.description == "Use coding-skill for focused test work."
      assert definition.system_prompt == "You write code."
      assert definition.allowed_tools == ["file_read", "shell"]
      assert definition.max_iterations == 18
      assert definition.timeout_seconds == 120
    end

    test "skips invalid skills during reload instead of failing the whole snapshot", %{
      registry: registry,
      skills_dir: skills_dir
    } do
      write_skill(skills_dir, "coding-skill", "You write code.")

      assert ["coding-skill"] = reload_names(registry)
      assert SkillRegistry.list(registry) == ["coding-skill"]
      assert {:ok, definition} = SkillRegistry.load(registry, "coding-skill")
      assert definition.system_prompt == "You write code."

      File.write!(Path.join([skills_dir, "coding-skill", "SKILL.md"]), "not valid frontmatter")

      assert [] = reload_names(registry)

      assert SkillRegistry.list(registry) == []

      assert {:error, {:unknown_skill, "coding-skill"}} =
               SkillRegistry.load(registry, "coding-skill")
    end

    test "removes deleted skills from the snapshot on reload", %{
      registry: registry,
      skills_dir: skills_dir
    } do
      write_skill(skills_dir, "coding-skill", "You write code.")
      write_skill(skills_dir, "ops-skill", "You operate systems.")

      assert ["coding-skill", "ops-skill"] = reload_names(registry)
      assert SkillRegistry.list(registry) == ["coding-skill", "ops-skill"]

      FermixTestSupport.SafeRm.rm_rf!(Path.join(skills_dir, "ops-skill"))

      assert SkillRegistry.list(registry) == ["coding-skill", "ops-skill"]
      assert ["coding-skill"] = reload_names(registry)

      assert SkillRegistry.list(registry) == ["coding-skill"]
      assert {:error, {:unknown_skill, "ops-skill"}} = SkillRegistry.load(registry, "ops-skill")
    end

    # MILESTONE_26_SKILL_CURATION §6.9: archived skills live under
    # `skills/_archive/<name>/` — one level deeper than the `*/SKILL.md`
    # discovery glob reaches. Curation's archive flow relies on that invisibility
    # with zero loader changes, so a glob change that starts descending must fail
    # here loudly.
    test "skills under _archive/<name>/ are invisible to discovery", %{
      registry: registry,
      skills_dir: skills_dir
    } do
      write_skill(skills_dir, "live-skill", "You are live.")
      write_skill(Path.join(skills_dir, "_archive"), "buried-skill", "You are archived.")

      assert ["live-skill"] = reload_names(registry)

      assert {:error, {:unknown_skill, "buried-skill"}} =
               SkillRegistry.load(registry, "buried-skill")
    end
  end

  describe "seeded defaults" do
    test "copies bundled skills into an empty local dir", %{skills_dir: skills_dir} do
      bundled =
        Path.join(System.tmp_dir!(), "fermix-bundled-#{System.unique_integer([:positive])}")

      write_skill(bundled, "fixture-core", "Fixture core skill body.")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(bundled) end)

      seeded_registry =
        start_supervised!(
          {SkillRegistry,
           name: :"seeded_skill_registry_#{System.unique_integer([:positive])}",
           skills_dir: skills_dir,
           core_dir: nil,
           bundled_dir: bundled,
           plugin_skill_dirs: [],
           seed_defaults: true},
          id: :"seeded_skill_registry_child_#{System.unique_integer([:positive])}"
        )

      assert "fixture-core" in SkillRegistry.list(seeded_registry)
    end
  end

  describe "source classifier" do
    test "skills under priv/skills are tagged as :operator" do
      core = Path.join(System.tmp_dir!(), "fermix-core-#{System.unique_integer([:positive])}")
      local = Path.join(System.tmp_dir!(), "fermix-local-#{System.unique_integer([:positive])}")
      File.mkdir_p!(local)
      write_skill(core, "core-skill", "Core skill body.")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(core) end)
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(local) end)

      registry =
        start_supervised!(
          {SkillRegistry,
           name: :"classifier_core_#{System.unique_integer([:positive])}",
           skills_dir: local,
           core_dir: core,
           plugin_skill_dirs: [],
           seed_defaults: false},
          id: :"classifier_core_child_#{System.unique_integer([:positive])}"
        )

      [definition] = SkillRegistry.list_detailed(registry)
      assert definition.name == "core-skill"
      assert definition.trust == :operator
    end

    test "skills under the local dir are tagged as :operator" do
      local = Path.join(System.tmp_dir!(), "fermix-local-#{System.unique_integer([:positive])}")
      write_skill(local, "local-skill", "Local skill body.")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(local) end)

      registry =
        start_supervised!(
          {SkillRegistry,
           name: :"classifier_local_#{System.unique_integer([:positive])}",
           skills_dir: local,
           core_dir: nil,
           plugin_skill_dirs: [],
           seed_defaults: false},
          id: :"classifier_local_child_#{System.unique_integer([:positive])}"
        )

      [definition] = SkillRegistry.list_detailed(registry)
      assert definition.trust == :operator
    end

    test "skills under workspace plugins are tagged as :guest (untrusted)" do
      home = Path.join(System.tmp_dir!(), "fermix-home-#{System.unique_integer([:positive])}")
      local = Path.join(home, "skills")
      plugin_skills = Path.join([home, "plugins", "fixture_plugin", "skills"])
      File.mkdir_p!(plugin_skills)
      write_skill(plugin_skills, "plugin-skill", "Plugin skill body.")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(home) end)

      registry =
        start_supervised!(
          {SkillRegistry,
           name: :"classifier_plugin_#{System.unique_integer([:positive])}",
           skills_dir: local,
           core_dir: nil,
           plugin_skill_dirs: [plugin_skills],
           seed_defaults: false},
          id: :"classifier_plugin_child_#{System.unique_integer([:positive])}"
        )

      [definition] = SkillRegistry.list_detailed(registry)
      assert definition.trust == :guest
    end

    test "enabled bundled plugin skills seed into the workspace plugins dir" do
      home = Path.join(System.tmp_dir!(), "fermix-home-#{System.unique_integer([:positive])}")
      local = Path.join(home, "skills")
      plugins = Application.get_env(:fermix_core, :plugins, [])
      previous_home = System.get_env("FERMIX_HOME")

      System.put_env("FERMIX_HOME", home)

      Application.put_env(:fermix_core, :plugins,
        enabled: ["google_calendar"],
        entries: %{"google_calendar" => [auth_profile: "google_calendar:primary"]}
      )

      on_exit(fn ->
        restore_env("FERMIX_HOME", previous_home)
        Application.put_env(:fermix_core, :plugins, plugins)
        FermixTestSupport.SafeRm.rm_rf!(home)
      end)

      registry =
        start_supervised!(
          {SkillRegistry,
           name: :"classifier_bundled_plugin_#{System.unique_integer([:positive])}",
           skills_dir: local,
           core_dir: nil,
           seed_defaults: false},
          id: :"classifier_bundled_plugin_child_#{System.unique_integer([:positive])}"
        )

      skill_path =
        Path.join([
          home,
          "plugins",
          "google_calendar",
          "skills",
          "google-calendar",
          "SKILL.md"
        ])

      [definition] = SkillRegistry.list_detailed(registry)
      assert definition.name == "google-calendar"
      assert definition.trust == :guest
      assert definition.source_path == skill_path
      assert File.exists?(skill_path)

      File.write!(skill_path, """
      ---
      name: google-calendar
      description: Workspace copy.
      ---
      Workspace override.
      """)

      assert ["google-calendar"] = reload_names(registry)
      assert {:ok, definition} = SkillRegistry.load(registry, "google-calendar")
      assert definition.description == "Workspace copy."
      assert definition.system_prompt == "Workspace override."
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  describe "capability_registry integration" do
    test "skill cannot evict an existing built-in capability with the same name", %{
      skills_dir: skills_dir
    } do
      cap_registry =
        start_supervised!(
          {CapabilityRegistry, [name: :"cap_skill_collide_#{System.unique_integer([:positive])}"]}
        )

      # Built-in registers FIRST (mirrors the boot-order guarantee).
      :ok =
        CapabilityRegistry.register(cap_registry, BuiltinCapability.from_tool_module(Shell))

      assert {:ok, %{name: "shell", kind: :builtin}} =
               CapabilityRegistry.find(cap_registry, "shell")

      # A user/plugin skill named "shell" fails discovery.
      write_skill(skills_dir, "shell", "Pretend to be the shell tool.")

      registry =
        start_supervised!(
          {SkillRegistry,
           name: :"skill_collide_#{System.unique_integer([:positive])}",
           skills_dir: skills_dir,
           core_dir: nil,
           plugin_skill_dirs: [],
           seed_defaults: false,
           capability_registry: cap_registry},
          id: :"skill_collide_child_#{System.unique_integer([:positive])}"
        )

      assert {:ok, %{name: "shell", kind: :builtin}} =
               CapabilityRegistry.find(cap_registry, "shell")

      assert SkillRegistry.list(registry) == []
      assert {:ok, snapshot} = SkillRegistry.snapshot(registry)
      assert [{:invalid_skill, "shell", {:name_collision, "shell", :builtin}}] = snapshot.errors
    end

    test "does not register loaded skills as capabilities and removes stale skill caps", %{
      skills_dir: skills_dir
    } do
      cap_registry =
        start_supervised!(
          {CapabilityRegistry, [name: :"cap_skill_reg_#{System.unique_integer([:positive])}"]}
        )

      write_skill(skills_dir, "alpha-skill", "Alpha skill body.")

      stale =
        SkillCapability.from_definition(%AgentDefinition{
          name: "stale-skill",
          description: "Old stale skill.",
          role: :sub,
          persistent: false,
          system_prompt: "Old body.",
          capabilities: [],
          allowed_tools: [],
          max_iterations: 4,
          timeout_seconds: 60,
          parent: nil,
          delegates_to: [],
          trust: :operator
        })

      :ok = CapabilityRegistry.register(cap_registry, stale)

      registry =
        start_supervised!(
          {SkillRegistry,
           name: :"skill_with_caps_#{System.unique_integer([:positive])}",
           skills_dir: skills_dir,
           core_dir: nil,
           plugin_skill_dirs: [],
           seed_defaults: false,
           capability_registry: cap_registry},
          id: :"skill_with_caps_child_#{System.unique_integer([:positive])}"
        )

      assert :error = CapabilityRegistry.find(cap_registry, "alpha-skill")
      assert :error = CapabilityRegistry.find(cap_registry, "stale-skill")

      FermixTestSupport.SafeRm.rm_rf!(Path.join(skills_dir, "alpha-skill"))
      write_skill(skills_dir, "beta-skill", "Beta skill body.")

      assert ["beta-skill"] = reload_names(registry)
      assert :error = CapabilityRegistry.find(cap_registry, "alpha-skill")
      assert :error = CapabilityRegistry.find(cap_registry, "beta-skill")
    end

    test "skill cannot shadow an MCP capability with the same name", %{skills_dir: skills_dir} do
      cap_registry =
        start_supervised!(
          {CapabilityRegistry, [name: :"cap_mcp_collide_#{System.unique_integer([:positive])}"]}
        )

      mcp_capability =
        Capability.new(%{
          name: "mcp_demo_tool",
          description: "MCP fixture",
          parameters: %{type: "object", properties: %{}},
          kind: :mcp,
          executor: {__MODULE__, :unused_capability_execute, []},
          policy_class: :external_api
        })

      :ok = CapabilityRegistry.register(cap_registry, mcp_capability)
      write_skill(skills_dir, "mcp_demo_tool", "Pretend to be an MCP tool.")

      registry =
        start_supervised!(
          {SkillRegistry,
           name: :"skill_mcp_collide_#{System.unique_integer([:positive])}",
           skills_dir: skills_dir,
           core_dir: nil,
           plugin_skill_dirs: [],
           seed_defaults: false,
           capability_registry: cap_registry},
          id: :"skill_mcp_collide_child_#{System.unique_integer([:positive])}"
        )

      assert SkillRegistry.list(registry) == []
      assert {:ok, snapshot} = SkillRegistry.snapshot(registry)

      assert [{:invalid_skill, "mcp_demo_tool", {:name_collision, "mcp_demo_tool", :mcp}}] =
               snapshot.errors
    end
  end
end
