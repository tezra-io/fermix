defmodule FermixCore.Jobs.CueSurfaceTest do
  @moduledoc """
  The one cue-run surface (M60 §9.3, S5; PLAN §1): what a run a cue woke is
  offered, whatever its job names, and what Fermix's echo says it will lack.
  """
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Jobs.CueSurface

  @base ~w(file_read view_image glob_search content_search git_read)
  @notes ~w(memory_store memory_recall memory_forget)
  @never ~w(web_search web_fetch shell browser send_attachment file_write file_edit git_write
            schedule_job update_job run_job_now subagents skill_run tool_search tool_describe
            tool_call recall_activity voice_call_context memory_sources_list list_jobs
            get_job_run list_job_runs codex_run claude_code_run computer_use)

  @notes_off %{task_notes?: false}
  @notes_on %{task_notes?: true}

  describe "tools/4" do
    test "a job with no allowlist gets the base readers and cue_history" do
      assert CueSurface.tools(%{allowed_tools: nil}, nil, @notes_off, nil) ==
               @base ++ ["cue_history"]

      assert CueSurface.tools(%{allowed_tools: []}, nil, @notes_off, nil) ==
               @base ++ ["cue_history"]
    end

    # C28: a job naming web_search and file_read keeps only file_read.
    test "a job naming web_search and file_read runs with file_read only of the two" do
      tools =
        CueSurface.tools(%{allowed_tools: ["web_search", "file_read"]}, nil, @notes_off, nil)

      assert tools == ["file_read", "cue_history"]
      refute "web_search" in tools
    end

    test "the skill's allowlist narrows the base readers too" do
      job = %{allowed_tools: ["file_read", "git_read", "shell"]}
      skill = %{allowed_tools: ["git_read", "glob_search"]}

      assert CueSurface.tools(job, skill, @notes_off, nil) == ["git_read", "cue_history"]

      assert CueSurface.tools(%{allowed_tools: nil}, skill, @notes_off, nil) ==
               ["glob_search", "git_read", "cue_history"]
    end

    test "the note tools come only with the watcher's task notes on" do
      assert CueSurface.tools(%{allowed_tools: nil}, nil, @notes_on, nil) ==
               @base ++ ["cue_history"] ++ @notes

      # Not narrowed by the job: notes are the watcher's switch, not the job's.
      assert CueSurface.tools(%{allowed_tools: ["file_read"]}, nil, @notes_on, nil) ==
               ["file_read", "cue_history"] ++ @notes
    end

    test "a mandate adds its tools and read tools in full, whatever the job names" do
      mandate = %{tools: ["github_create_issue"], read_tools: ["github_list_issues"]}
      tools = CueSurface.tools(%{allowed_tools: ["file_read"]}, nil, @notes_off, mandate)

      assert tools == ["file_read", "cue_history", "github_create_issue", "github_list_issues"]
    end

    test "nothing outside the surface is ever offered, whatever the job and skill name" do
      job = %{allowed_tools: @never ++ @base}
      skill = %{allowed_tools: @never ++ @base}

      tools = CueSurface.tools(job, skill, @notes_on, nil)

      assert Enum.filter(@never, &(&1 in tools)) == []
    end
  end

  describe "allowed?/1" do
    test "admits the base readers, cue_history and the note tools, and nothing else" do
      for name <- @base ++ ["cue_history"] ++ @notes, do: assert(CueSurface.allowed?(name))
      for name <- @never, do: refute(CueSurface.allowed?(name))
    end

    test "a plugin, MCP or skill capability is never allowed, whatever its name" do
      for kind <- [:mcp, :skill] do
        refute CueSurface.allowed?(capability("file_read", kind, :read_only))
      end

      assert CueSurface.allowed?(capability("file_read", :builtin, :read_only))
    end
  end

  describe "lacking/4" do
    test "names what the job's allowlist has that a cue run will not, sorted" do
      job = %{allowed_tools: ["web_search", "file_read", "shell"]}

      assert CueSurface.lacking(job, nil, @notes_off, nil) == ["shell", "web_search"]
    end

    test "a tool the mandate grants is not lacking" do
      job = %{allowed_tools: ["github_create_issue", "shell"]}
      mandate = %{tools: ["github_create_issue"], read_tools: []}

      assert CueSurface.lacking(job, nil, @notes_off, mandate) == ["shell"]
    end

    test "with the job and skill both named, it is their intersection that is compared" do
      job = %{allowed_tools: ["shell", "file_read", "web_fetch"]}
      skill = %{allowed_tools: ["shell", "file_read"]}

      assert CueSurface.lacking(job, skill, @notes_off, nil) == ["shell"]
    end

    test "memory tools are lacking with notes off and present with notes on" do
      job = %{allowed_tools: ["memory_store", "file_read"]}

      assert CueSurface.lacking(job, nil, @notes_off, nil) == ["memory_store"]
      assert CueSurface.lacking(job, nil, @notes_on, nil) == []
    end

    test "a job with no allowlist names nothing, so nothing is listed" do
      assert CueSurface.lacking(%{allowed_tools: nil}, nil, @notes_off, nil) == []
    end
  end

  # C27 at the registry: for every capability the seeder can register, plus a
  # plugin tool and an MCP tool, the cue surface resolves to exactly what
  # allowed?/1 admits (notes on), plus the mandate's tools. The runner test
  # proves the same set reaches the provider through a real cue run.
  describe "the whole surface" do
    setup do
      registry = :"cue_surface_registry_#{System.unique_integer([:positive])}"
      start_supervised!({CapabilityRegistry, name: registry})

      :ignore =
        BuiltinSeeder.start_link(
          capability_registry: registry,
          tool_modules: BuiltinSeeder.builtin_tool_modules()
        )

      :ok = CapabilityRegistry.register(registry, plugin_capability("github_create_issue"))
      :ok = CapabilityRegistry.register(registry, capability("mcp_read", :mcp, :read_only))

      %{registry: registry}
    end

    test "every registrable capability resolves to allowed?/1 and nothing more", %{
      registry: registry
    } do
      expected =
        registry
        |> CapabilityRegistry.list()
        |> Enum.filter(&CueSurface.allowed?/1)
        |> names()

      offered = resolved(registry, CueSurface.tools(%{allowed_tools: nil}, nil, @notes_on, nil))

      assert offered == expected
      assert_read_and_report(registry, offered, @notes)
    end

    test "a mandate adds exactly its tools to that set", %{registry: registry} do
      mandate = %{tools: ["github_create_issue"], read_tools: ["mcp_read"]}

      base = resolved(registry, CueSurface.tools(%{allowed_tools: nil}, nil, @notes_off, nil))

      with_mandate =
        resolved(registry, CueSurface.tools(%{allowed_tools: nil}, nil, @notes_off, mandate))

      assert with_mandate -- base == ["github_create_issue", "mcp_read"]
      assert_read_and_report(registry, base, [])
    end

    test "no harness tool is ever offered", %{registry: registry} do
      harness =
        BuiltinSeeder.harness_modules(
          harness_enabled: true,
          cloud_enabled: true,
          vendor_available_fn: fn _vendor -> true end
        )

      assert harness != []
      offered = resolved(registry, CueSurface.tools(%{allowed_tools: nil}, nil, @notes_on, nil))

      for module <- harness, do: refute(module.name() in offered)
    end
  end

  # The surface is exact: the loop resolves an allowlist with no deferral, the
  # way it does for a cue run.
  defp resolved(registry, tools) do
    registry
    |> CapabilityRegistry.list_for(allowed_tools: tools, policy: nil, trust: :operator)
    |> names()
  end

  # Whole feature surface: apart from the note tools, nothing offered may write,
  # run, reach the network, drive the desktop, send, schedule or delegate.
  defp assert_read_and_report(registry, offered, note_tools) do
    for name <- offered -- note_tools do
      {:ok, cap} = CapabilityRegistry.find(registry, name)

      refute cap.policy_class in [:read_write, :exec, :gui_control, :network, :external_api],
             "#{name} is #{cap.policy_class}"

      refute Map.get(cap.metadata, :category) in [:channel, :scheduling, :harness, :delegation],
             "#{name} is in #{inspect(Map.get(cap.metadata, :category))}"
    end
  end

  defp names(capabilities), do: capabilities |> Enum.map(& &1.name) |> Enum.sort()

  defp capability(name, kind, policy_class) do
    Capability.new(%{
      name: name,
      description: "test capability #{name}",
      parameters: %{"type" => "object", "properties" => %{}},
      kind: kind,
      executor: {__MODULE__, :never, []},
      policy_class: policy_class
    })
  end

  defp plugin_capability(name) do
    %{capability(name, :builtin, :external_api) | metadata: %{plugin_owned?: true, plugin: "gh"}}
  end

  def never(_args, _context), do: raise("a test capability never runs")
end
