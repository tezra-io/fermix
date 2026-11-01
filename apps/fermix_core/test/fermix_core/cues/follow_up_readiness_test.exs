defmodule FermixCore.Cues.FollowUpReadinessTest do
  @moduledoc """
  A follow-up's readiness (M60_WATCHER_CODING_RUNS.md §3.2): each family says
  what is missing in its words, with where to fix it, from cheap reads only.
  Every read is a seam here: the harness config, `PATH`, the vendors' config
  dirs (temporary), the plugins and their status, the channels, and the
  sandbox (a strict one in a temporary folder).
  """
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Cues.FollowUpReadiness
  alias FermixCore.Sandbox.PathPolicy
  alias FermixTestSupport.SafeRm

  setup do
    registry = :"follow_up_readiness_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: registry})

    root = SafeRm.make_tmp_dir!("follow-up-readiness")
    on_exit(fn -> SafeRm.rm_rf!(root) end)
    %{registry: registry, root: root}
  end

  describe "a coding agent" do
    test "is ready when allowed, installed, signed in and loaded", ctx do
      register!(ctx, "codex_run")
      assert FollowUpReadiness.check(job(["codex_run"]), opts(ctx)) == :ready
    end

    test "says the harness is off, or not allowed, before anything else", ctx do
      register!(ctx, "codex_run")

      assert {:not_ready, "Coding agents are turned off: turn them on in the coding agents " <> _} =
               FollowUpReadiness.check(job(["codex_run"]), opts(ctx, harness: [enabled: false]))

      assert {:not_ready, "Coding agents are not allowed on this computer yet" <> _} =
               FollowUpReadiness.check(job(["codex_run"]), opts(ctx, harness: [approved: false]))
    end

    test "names a program that is not on PATH, and a Codex that is not signed in", ctx do
      assert {:not_ready,
              "Codex is not installed on this computer: install its `codex` program, then " <>
                "restart Fermix."} =
               FollowUpReadiness.check(job(["codex_run"]), opts(ctx, path: []))

      assert {:not_ready, "Codex is not signed in on this computer: run `codex login` there."} =
               FollowUpReadiness.check(job(["codex_run"]), opts(ctx, codex_signed_in: false))
    end

    test "counts Claude Code's unverified sign-in as ready, and its absent config dir as not",
         ctx do
      register!(ctx, "claude_code_run")
      assert FollowUpReadiness.check(job(["claude_code_run"]), opts(ctx)) == :ready

      assert {:not_ready, "Claude Code is not signed in on this computer" <> _} =
               FollowUpReadiness.check(job(["claude_code_run"]), opts(ctx, claude_dir: false))
    end

    test "installed after Fermix started, it is not loaded until a restart", ctx do
      assert {:not_ready, "Codex was installed after Fermix started: restart Fermix to use it."} =
               FollowUpReadiness.check(job(["codex_run"]), opts(ctx))
    end

    test "Codex cloud also needs cloud_enabled", ctx do
      register!(ctx, "codex_cloud_run")

      assert {:not_ready,
              "Codex cloud is off: set `[fermix_core.harness] cloud_enabled = true`" <> _} =
               FollowUpReadiness.check(job(["codex_cloud_run"]), opts(ctx))

      assert FollowUpReadiness.check(
               job(["codex_cloud_run"]),
               opts(ctx, harness: [cloud_enabled: true])
             ) == :ready
    end
  end

  describe "a plugin's tool" do
    test "is ready while it is offered, whatever the plugin's state reads", ctx do
      register!(ctx, "github_create_issue")
      opts = opts(ctx, plugin_status: fn _plugin -> flunk("an offered tool reads no state") end)
      assert FollowUpReadiness.check(job(["github_create_issue"]), opts) == :ready
    end

    test "not offered, names its plugin and its state", ctx do
      for {status, sentence} <- [
            {:needs_auth, "GitHub is not connected: connect it under Plugins in settings."},
            {:reauthorization_required,
             "GitHub is not connected: connect it under Plugins in settings."},
            {:not_configured, "GitHub is turned off: turn it on under Plugins in settings."},
            {:needs_secret, "GitHub is waiting for its token: add it under Plugins in settings."},
            {:needs_config,
             "GitHub is waiting for a setting: finish it under Plugins in settings."}
          ] do
        opts = opts(ctx, plugin_status: fn %{name: "github"} -> status end)

        assert FollowUpReadiness.check(job(["github_create_issue"]), opts) ==
                 {:not_ready, sentence}
      end
    end

    # Its runtime's rung is a check that runs the program: never asked here.
    test "of a plugin whose runtime is a program, is named without its state", ctx do
      opts =
        opts(ctx,
          plugins: [plugin("linear", "Linear", ["linear_create"], %{"kind" => "node"})],
          plugin_status: fn _plugin -> flunk("a runtime plugin's state is not read") end
        )

      assert {:not_ready,
              "Linear is not ready, so linear_create is not offered: check it under Plugins " <>
                "in settings."} = FollowUpReadiness.check(job(["linear_create"]), opts)
    end

    test "that no plugin declares is named as not set up", ctx do
      assert {:not_ready, "deploy_check is not set up on this computer" <> _} =
               FollowUpReadiness.check(job(["deploy_check"]), opts(ctx))
    end
  end

  describe "the channel it reports to" do
    test "must be set up; the Mac app needs nothing", ctx do
      register!(ctx, "shell")
      slack = job(["shell"], %{"platform" => "slack", "channel_id" => "C1"})

      assert {:not_ready,
              "Slack, where the follow-up reports, is not set up: set it up under Channels in " <>
                "settings."} =
               FollowUpReadiness.check(slack, opts(ctx, channels: []))

      assert FollowUpReadiness.check(slack, opts(ctx, channels: [:slack])) == :ready

      companion = job(["shell"], %{"platform" => "companion", "chat_id" => "mac"})
      assert FollowUpReadiness.check(companion, opts(ctx, channels: [])) == :ready
    end
  end

  # The folders its instructions name, checked against the sandbox as a
  # follow-up's run meets it (no request folder): every root is a seam here, a
  # strict sandbox in a temporary folder with only the grants a test gives.
  describe "the folders its instructions name" do
    test "one outside the sandbox's roots holds it, naming the grant that opens it", ctx do
      project = Path.join(ctx.root, "src/quarry")
      instructions = "Have Codex review the last day's commits in #{project} and report."

      assert FollowUpReadiness.check(folder_job(instructions), opts(ctx)) ==
               {:not_ready, cant_open(project)}

      # A grant fixes it, so the setup writes it, held.
      assert FollowUpReadiness.unopenable(instructions, opts(ctx)) == nil
    end

    test "granted, it is ready, and so is a folder the run will make inside a grant", ctx do
      src = Path.join(ctx.root, "src")

      instructions =
        "Review #{src}/quarry, then write a report into #{src}/reports/new-folder."

      assert FollowUpReadiness.check(folder_job(instructions), opts(ctx, grants: [src])) ==
               :ready
    end

    test "says each folder once, and reads ~/ as the sandbox's home folder", ctx do
      project = Path.join([ctx.root, "home", "src", "quarry"])
      notes = Path.join([ctx.root, "home", "notes"])
      instructions = "Run the tests in ~/src/quarry (#{project}) and note it in `~/notes`."

      assert FollowUpReadiness.check(folder_job(instructions), opts(ctx)) ==
               {:not_ready, cant_open(project) <> " " <> cant_open(notes)}
    end

    test "one the sandbox blocks holds it, naming the setting", ctx do
      # Canonical: the policy matches a blocked root as written.
      src = canonical(Path.join(ctx.root, "src"))
      vault = Path.join(src, "vault")

      assert FollowUpReadiness.check(
               folder_job("Back up #{vault}/keys."),
               opts(ctx, grants: [src], blocked: [vault])
             ) ==
               {:not_ready,
                "Fermix can't open `#{canonical(vault)}/keys`: the sandbox blocks it, and no " <>
                  "grant reaches inside a blocked folder: take it out of " <>
                  "`[sandbox] blocked_roots` in the settings file, then restart Fermix."}
    end

    test "a protected one is refused at setup, and holds it if it gets that far", ctx do
      keys = Path.join([ctx.root, "home", ".ssh", "deploy"])
      instructions = "Copy #{keys} to the build host."
      opts = opts(ctx, grants: [Path.join(ctx.root, "home")])

      protected =
        "Fermix never opens `#{canonical(keys)}`: the sandbox protects it in every mode, " <>
          "even with a grant, so leave it out of the follow-up's instructions."

      assert FollowUpReadiness.unopenable(instructions, opts) == protected
      assert FollowUpReadiness.check(folder_job(instructions), opts) == {:not_ready, protected}
    end

    test "no path on this computer, no check: URLs, relative paths, slash commands", ctx do
      refute File.exists?("/v1")

      instructions =
        "Fetch https://example.com/releases/latest and file:///notes, run ./bin/check and " <>
          "bin/lint on origin/dev, call POST /v1/issues on the API, then /confirm."

      # The sandbox here grants nothing, so a path it checked would hold it.
      assert FollowUpReadiness.check(folder_job(instructions), opts(ctx)) == :ready
      assert FollowUpReadiness.unopenable(instructions, opts(ctx)) == nil
    end

    test "more than 10 is refused at setup and holds it; 10 are checked", ctx do
      src = Path.join(ctx.root, "src")
      paths = for n <- 1..11, do: Path.join(src, "project-#{n}")
      eleven = "Review " <> Enum.join(paths, ", ") <> "."
      ten = "Review " <> Enum.join(Enum.take(paths, 10), ", ") <> ", and #{hd(paths)} again."
      opts = opts(ctx, grants: [src])

      too_many =
        "The follow-up's instructions name more than 10 folders, more than Fermix checks " <>
          "before a run: name at most 10."

      assert FollowUpReadiness.unopenable(eleven, opts) == too_many
      assert FollowUpReadiness.check(folder_job(eleven), opts) == {:not_ready, too_many}
      assert FollowUpReadiness.unopenable(ten, opts) == nil
      assert FollowUpReadiness.check(folder_job(ten), opts) == :ready
    end
  end

  test "every gap is said, once each", ctx do
    assert {:not_ready, sentence} =
             FollowUpReadiness.check(
               job(["codex_run", "claude_code_run", "deploy_check"]),
               opts(ctx, harness: [approved: false], channels: [])
             )

    assert sentence ==
             "Coding agents are not allowed on this computer yet: allow them in the coding " <>
               "agents settings. deploy_check is not set up on this computer (its program was " <>
               "not found or its plugin is not installed). Telegram, where the follow-up " <>
               "reports, is not set up: set it up under Channels in settings."
  end

  describe "the coding agent when the owner names none" do
    test "is the configured default, ready or not", ctx do
      assert FollowUpReadiness.coding_agent(opts(ctx, harness: [default_vendor: "claude"])) ==
               {:ok, "claude_code_run"}
    end

    test "else the one that is ready", ctx do
      register!(ctx, "codex_run")
      assert FollowUpReadiness.coding_agent(opts(ctx, claude_dir: false)) == {:ok, "codex_run"}
    end

    test "else Fermix asks which", ctx do
      register!(ctx, "codex_run")
      register!(ctx, "claude_code_run")

      assert {:error, "Codex and Claude Code are both ready and neither is the default" <> _} =
               FollowUpReadiness.coding_agent(opts(ctx))

      assert {:error, "No coding agent is ready on this computer, so say which one" <> rest} =
               FollowUpReadiness.coding_agent(opts(ctx, path: []))

      assert rest =~ "Codex is not installed"
      assert rest =~ "Claude Code is not installed"
    end
  end

  # --- fixtures ----------------------------------------------------------------------

  defp job(tools, target \\ %{"platform" => "telegram", "chat_id" => "chat-1"}),
    do: %{allowed_tools: tools, delivery_mode: "channel", delivery_target: target}

  # A follow-up that names no tool, so only its instructions' folders can hold it.
  defp folder_job(instructions), do: Map.put(job([]), :task_prompt, instructions)

  defp cant_open(path) do
    path = canonical(path)

    "Fermix can't open `#{path}` yet: grant it with `/grant path #{path}` in chat, or " <>
      "`fermix grant path #{path}` in a terminal on Linux."
  end

  # The sandbox's own form of a path (symlinks resolved: macOS's /var is /private/var).
  defp canonical(path), do: PathPolicy.canonical_path(path)

  # Allowed and installed, Codex signed in, Claude Code's config dir present, no
  # plugin but GitHub, every channel set up, and a strict sandbox granting nothing,
  # unless `overrides` says otherwise.
  defp opts(ctx, overrides \\ []) do
    codex_home = Path.join(ctx.root, "codex")
    claude? = Keyword.get(overrides, :claude_dir, true)
    claude_dir = Path.join(ctx.root, if(claude?, do: "claude", else: "no-claude"))
    File.mkdir_p!(codex_home)

    if Keyword.get(overrides, :codex_signed_in, true),
      do: File.write!(Path.join(codex_home, "auth.json"), auth_json()),
      else: File.write!(Path.join(codex_home, "auth.json"), "{}")

    if claude?, do: File.mkdir_p!(claude_dir)

    path = Keyword.get(overrides, :path, ["codex", "claude"])
    channels = Keyword.get(overrides, :channels, [:telegram, :slack])

    [
      capability_registry: ctx.registry,
      harness_config: Keyword.merge([enabled: true, approved: true], overrides[:harness] || []),
      vendor_opts: [
        find_executable: fn name -> if name in path, do: "/stub/bin/#{name}" end,
        codex_home: codex_home,
        claude_config_dir: claude_dir
      ],
      plugins: fn ->
        {:ok,
         Keyword.get(overrides, :plugins, [plugin("github", "GitHub", ["github_create_issue"])])}
      end,
      plugin_status: Keyword.get(overrides, :plugin_status, fn _plugin -> :needs_auth end),
      channel_ready?: fn channel -> channel in channels end,
      sandbox_config: %{
        mode: :strict,
        home: Path.join(ctx.root, "fermix"),
        os_home: Path.join(ctx.root, "home"),
        workspace_root: Path.join(ctx.root, "workspace"),
        allowed_roots: Keyword.get(overrides, :grants, []),
        blocked_roots: Keyword.get(overrides, :blocked, [])
      }
    ]
  end

  defp auth_json, do: Jason.encode!(%{"tokens" => %{"refresh_token" => "rt-test"}})

  defp plugin(name, title, tools, runtime \\ nil),
    do: %{
      name: name,
      display_name: title,
      runtime: runtime,
      tools: Enum.map(tools, &%{"name" => &1})
    }

  defp register!(ctx, name) do
    :ok =
      CapabilityRegistry.register(
        ctx.registry,
        Capability.new(%{
          name: name,
          description: "a test tool",
          parameters: %{"type" => "object", "properties" => %{}},
          kind: :builtin,
          executor: {__MODULE__, :never, []},
          policy_class: :exec
        })
      )
  end
end
