defmodule FermixCore.Sandbox.OsSandboxTest do
  # async: false — the protected paths read FERMIX_HOME from the environment,
  # which each test sets to its own temp home and restores.
  use ExUnit.Case, async: false

  alias FermixCore.Sandbox.CommandTool
  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.OsSandbox
  alias FermixCore.Sandbox.PathPolicy
  alias FermixCore.Tools.GitWrite
  alias FermixCore.Tools.Shell
  alias FermixTestSupport.SafeRm

  @darwin {:unix, :darwin}

  # The temp tree: an OS home holding Fermix's home, and a folder outside every
  # root. The temp folder itself is a writable root in production, so every
  # test drops it (`scratch: []`), or every write here would be allowed.
  setup do
    previous_home = System.get_env("FERMIX_HOME")
    # The git test runs the real git, which must not read the host's config.
    previous_git =
      for name <- ~w(GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM), do: {name, System.get_env(name)}

    System.put_env("GIT_CONFIG_GLOBAL", "/dev/null")
    System.put_env("GIT_CONFIG_NOSYSTEM", "1")
    base = SafeRm.make_tmp_dir!("os-sandbox")
    os_home = Path.join(base, "home")
    fermix_home = Path.join(os_home, ".fermix")
    workspace = Path.join(fermix_home, "workspace")
    outside = Path.join(base, "outside")
    plugins = Path.join([fermix_home, "plugins", "probe"])

    for dir <- [workspace, Path.join(fermix_home, "secrets"), plugins, outside],
        do: File.mkdir_p!(dir)

    File.write!(Path.join(fermix_home, "config.toml"), "seeded = 1\n")
    File.write!(Path.join([fermix_home, "secrets", "KEY"]), "secret-value\n")
    System.put_env("FERMIX_HOME", fermix_home)

    on_exit(fn ->
      for {name, value} <- [{"FERMIX_HOME", previous_home} | previous_git] do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end

      SafeRm.rm_rf!(base)
    end)

    %{
      base: base,
      os_home: os_home,
      fermix_home: fermix_home,
      workspace: workspace,
      outside: outside,
      plugins: plugins
    }
  end

  defp config(ctx, mode, extra \\ []) do
    Config.normalize(
      [mode: mode, home: ctx.fermix_home, os_home: ctx.os_home, workspace_root: ctx.workspace] ++
        extra
    )
  end

  defp resolved(path) do
    {:ok, path} = PathPolicy.resolve_links(path)
    path
  end

  describe "rules/3" do
    test "strict writes only the workspace once the temp roots are dropped", ctx do
      assert {:ok, rules} = OsSandbox.rules(config(ctx, :strict), nil, scratch: [])
      assert rules.writable == [resolved(ctx.workspace)]
    end

    test "open writes the whole filesystem, Fermix's home aside", ctx do
      assert {:ok, rules} = OsSandbox.rules(config(ctx, :open), nil, scratch: [])
      assert "/" in rules.writable
      assert rules.fermix_home == resolved(ctx.fermix_home)
      assert resolved(ctx.workspace) in rules.fermix_writable
      assert resolved(Path.join(ctx.fermix_home, "skills")) in rules.fermix_writable
    end

    test "a granted folder is writable, so the kernel is never narrower than the policy", ctx do
      granted = Path.join(ctx.base, "granted")
      File.mkdir_p!(granted)

      assert {:ok, rules} =
               OsSandbox.rules(config(ctx, :strict, allowed_roots: [granted]), nil, scratch: [])

      assert resolved(granted) in rules.writable
    end

    test "a request folder inside Fermix's home is not writable there", ctx do
      assert {:ok, rules} = OsSandbox.rules(config(ctx, :standard), ctx.plugins, scratch: [])
      refute Enum.any?(rules.fermix_writable, &String.starts_with?(&1, resolved(ctx.plugins)))
    end

    test "the installed release, launch agents and the Mac app's record are protected", ctx do
      assert {:ok, rules} = OsSandbox.rules(config(ctx, :open), nil, scratch: [])
      assert resolved(List.to_string(:code.root_dir())) in rules.protected
      assert resolved(Path.join(ctx.os_home, "Library/LaunchAgents")) in rules.protected
      support = Path.join(ctx.os_home, "Library/Application Support/Fermix")
      assert resolved(support) in rules.protected
    end

    test "every folder above Fermix's home and a protected path is closed on its own name",
         ctx do
      assert {:ok, rules} = OsSandbox.rules(config(ctx, :open), nil, scratch: [])
      assert resolved(ctx.os_home) in rules.ancestors
      assert rules.fermix_home in rules.ancestors
      assert resolved(ctx.workspace) in rules.ancestors
      refute "/" in rules.ancestors
    end

    test "Fermix's secrets, logs and the browser profiles are read-denied", ctx do
      assert {:ok, rules} = OsSandbox.rules(config(ctx, :open), nil, scratch: [])

      for entry <- ["secrets", "logs", "traces", "browser/profiles"],
          do: assert(resolved(Path.join(ctx.fermix_home, entry)) in rules.secret)

      assert ("^" <> escaped(Path.join(rules.fermix_home, "auth.json"))) in rules.secret_patterns
      assert ("^" <> escaped(Path.join(rules.fermix_home, "memory.db"))) in rules.secret_patterns
    end

    test "the owner's credentials are read-denied in strict and standard, readable in open",
         ctx do
      credentials =
        Enum.map(
          ~w(.ssh .aws .gnupg .npmrc .netrc .git-credentials .config/gcloud/credentials.db),
          &resolved(Path.join(ctx.os_home, &1))
        )

      for mode <- [:strict, :standard] do
        assert {:ok, rules} = OsSandbox.rules(config(ctx, mode), nil, scratch: [])
        for path <- credentials, do: assert(path in rules.secret, "#{mode}: #{path}")
      end

      assert {:ok, rules} = OsSandbox.rules(config(ctx, :open), nil, scratch: [])
      for path <- credentials, do: refute(path in rules.secret, "open: #{path}")
      assert resolved(Path.join(ctx.os_home, ".config/fermix")) in rules.secret
    end

    # `credentials.db-journal`, `.claude.json.backup`: the file tools count a
    # file named after a credential as the credential, so the kernel does too.
    test "the files named after a credential are closed the same way", ctx do
      siblings =
        "^" <>
          escaped(resolved(Path.join(ctx.os_home, ".config/gcloud/credentials.db"))) <> "(\\.|-)"

      assert {:ok, rules} = OsSandbox.rules(config(ctx, :standard), nil, scratch: [])
      assert siblings in rules.secret_patterns
      assert siblings in rules.protected_patterns

      assert {:ok, rules} = OsSandbox.rules(config(ctx, :open), nil, scratch: [])
      refute siblings in rules.secret_patterns
      assert siblings in rules.protected_patterns
    end

    test "a key staged for saving in the temp folder is read-denied", ctx do
      assert {:ok, rules} = OsSandbox.rules(config(ctx, :strict), nil, scratch: [])
      staging = "^" <> escaped(Path.join(resolved(System.tmp_dir!()), "fermix-secret-"))
      assert staging in rules.secret_patterns
    end

    test "unreadable/1 names each read rule and how far it reaches", ctx do
      ssh = {resolved(Path.join(ctx.os_home, ".ssh")), :named}
      fermix_home = resolved(ctx.fermix_home)

      for mode <- [:strict, :standard, :open] do
        assert {:ok, entries} = OsSandbox.unreadable(config(ctx, mode))
        assert {resolved(Path.join(ctx.fermix_home, "secrets")), :tree} in entries
        assert {Path.join(fermix_home, "auth.json"), :prefix} in entries
        staging = Path.join(resolved(System.tmp_dir!()), "fermix-secret-")
        assert {staging, :prefix} in entries
        assert ssh in entries == (mode != :open), "#{mode}"
        paths = Enum.map(entries, &elem(&1, 0))
        assert paths == Enum.uniq(paths), "#{mode}: a path named twice"
      end
    end

    test "the kernel holds commands on macOS and not elsewhere yet" do
      assert OsSandbox.enforcement(os: @darwin) == "held by the kernel (Seatbelt)"
      assert OsSandbox.enforcement(os: {:unix, :linux}) == "not held by the kernel on this system"
    end

    test "a blocked root stays closed to commands, even in open", ctx do
      blocked = Path.join(ctx.base, "blocked")
      File.mkdir_p!(blocked)
      config = config(ctx, :open, blocked_roots: [blocked])

      assert {:ok, rules} = OsSandbox.rules(config, nil, scratch: [])
      assert resolved(blocked) in rules.protected
    end

    test "a home path with regex metacharacters is escaped in its patterns", ctx do
      odd = Path.join(ctx.base, "a.b(c)")
      File.mkdir_p!(odd)
      config = Config.normalize(mode: :strict, home: odd, os_home: ctx.os_home)

      assert {:ok, %{secret_patterns: patterns}} = OsSandbox.rules(config, nil, scratch: [])
      assert Enum.any?(patterns, &String.ends_with?(&1, "/a\\.b\\(c\\)/auth\\.json"))
    end

    # A rule given a path through a symlink matches nothing in the kernel, which
    # resolves the path it checks: every path the profile gets is resolved.
    test "a Fermix home reached through a symlink is resolved", ctx do
      link = Path.join(ctx.base, "home-link")
      File.ln_s!(ctx.fermix_home, link)
      config = Config.normalize(mode: :open, home: link, os_home: ctx.os_home)

      assert {:ok, rules} = OsSandbox.rules(config, nil, scratch: [])
      assert rules.fermix_home == resolved(ctx.fermix_home)
    end

    test "a path that cannot be resolved refuses rather than falling back", ctx do
      loop = Path.join(ctx.base, "loop")
      File.ln_s!(loop, loop)
      config = Config.normalize(mode: :strict, home: loop, os_home: ctx.os_home)

      assert {:error, {:unresolvable_path, ^loop, _reason}} =
               OsSandbox.rules(config, nil, scratch: [])
    end

    # macOS tools write the per-user `T/` and `C/` whatever `$TMPDIR` says, so they
    # are writable by pattern, never the folder above them.
    test "the temp folders are writable, the per-user ones by pattern", ctx do
      assert {:ok, rules} = OsSandbox.rules(config(ctx, :strict), nil, [])
      assert "/private/tmp" in rules.writable
      assert resolved(System.tmp_dir!()) in rules.writable
      assert [pattern] = rules.writable_patterns
      assert Regex.match?(~r/#{pattern}/, "/private/var/folders/zz/abc123/T/x")
      assert Regex.match?(~r/#{pattern}/, "/private/var/folders/zz/abc123/C")
      refute Regex.match?(~r/#{pattern}/, "/private/var/folders/zz/abc123/0/com.apple.dock")
    end
  end

  describe "profile/1 and parameters/1" do
    test "the profile names parameters only, and every parameter is bound", ctx do
      assert {:ok, rules} = OsSandbox.rules(config(ctx, :open), nil, scratch: [])
      profile = OsSandbox.profile(rules)
      refute profile =~ ctx.base

      referenced = Regex.scan(~r/\(param "([A-Z]+\d*)"\)/, profile, capture: :all_but_first)
      bound = for ["-D", binding] <- Enum.chunk_every(OsSandbox.parameters(rules), 2), do: binding

      assert Enum.sort(Enum.uniq(List.flatten(referenced))) ==
               Enum.sort(Enum.map(bound, &(&1 |> String.split("=", parts: 2) |> hd())))
    end
  end

  describe "wrap/5, with_cache_env/3 and refusal/2" do
    test "on macOS the command runs under sandbox-exec, its own argv last", ctx do
      assert {:ok, {"/usr/bin/sandbox-exec", ["-p", _profile | rest]}} =
               OsSandbox.wrap("/bin/sh", ["-c", "true"], config(ctx, :strict), nil,
                 os: @darwin,
                 scratch: []
               )

      assert Enum.take(rest, -3) == ["/bin/sh", "-c", "true"]
    end

    test "Linux runs the command and its environment as before until its stage lands", ctx do
      assert {:ok, {"/bin/sh", ["-c", "true"]}} =
               OsSandbox.wrap("/bin/sh", ["-c", "true"], config(ctx, :strict), nil,
                 os: {:unix, :linux}
               )

      env = [{"PATH", "/bin"}]
      assert OsSandbox.with_cache_env(env, config(ctx, :strict), os: {:unix, :linux}) == env
    end

    test "on macOS the tool caches point into the workspace, an allowed name aside", ctx do
      env = [{"PATH", "/bin"}, {"PIP_CACHE_DIR", "/owner/pip"}]
      built = OsSandbox.with_cache_env(env, config(ctx, :strict), os: @darwin)

      assert {"npm_config_cache", Path.join(ctx.workspace, ".cache/npm")} in built
      assert {"XDG_CACHE_HOME", Path.join(ctx.workspace, ".cache")} in built
      assert {"PIP_CACHE_DIR", "/owner/pip"} in built
      refute {"PIP_CACHE_DIR", Path.join(ctx.workspace, ".cache/pip")} in built
    end

    test "sandbox-exec's own failure is told apart from the command's" do
      assert OsSandbox.refusal(65, "sandbox-exec: invalid data type of path filter\n") =~
               "could not start inside Fermix's sandbox: sandbox-exec: invalid data type"

      # 71 is also what a sandbox the command starts itself exits with.
      assert OsSandbox.refusal(71, "sandbox-exec: sandbox_apply: Operation not permitted") == nil
      assert OsSandbox.refusal(1, "sandbox-exec: looks like it, exit says otherwise") == nil
      assert OsSandbox.refusal(65, "the command's own output") == nil
    end
  end

  # Through the real tools and the real kernel. Only macOS has Seatbelt; there a
  # host that cannot apply a profile fails here, never skips: a skipped proof on
  # the macOS CI leg would read as a pass.
  describe "enforced by macOS" do
    unless :os.type() == {:unix, :darwin} do
      @describetag skip: "Seatbelt exists only on macOS, this is #{inspect(:os.type())}"
    end

    test "sandbox-exec can apply a profile on this Mac" do
      probe = ["-p", "(version 1)(allow default)", "/usr/bin/true"]
      assert {"", 0} = System.cmd("/usr/bin/sandbox-exec", probe, stderr_to_stdout: true)
    end

    test "strict: the workspace is writable and a folder outside the roots is not", ctx do
      inside = Path.join(ctx.workspace, "a.txt")
      blocked = Path.join(ctx.outside, "b.txt")

      assert %{success: true} = shell("echo a > #{inside}", config(ctx, :strict))
      assert %{success: false, error: error} = shell("echo b > #{blocked}", config(ctx, :strict))
      assert error =~ "Operation not permitted"
      assert File.exists?(inside)
      refute File.exists?(blocked)
    end

    test "open: config.toml cannot be written, even by a program the command starts", ctx do
      config_toml = Path.join(ctx.fermix_home, "config.toml")
      script = ~s|python3 -c "open('#{config_toml}', 'a').write('planted = 1\\n')"|

      assert %{success: false, error: error} = shell(script, config(ctx, :open))
      assert error =~ "Operation not permitted"
      assert File.read!(config_toml) == "seeded = 1\n"

      assert %{success: true} =
               shell("echo b > #{Path.join(ctx.outside, "b.txt")}", config(ctx, :open))
    end

    test "open: Fermix's home cannot be renamed away from its rules", ctx do
      moved = Path.join(ctx.os_home, "moved")

      assert %{success: false} = shell("mv #{ctx.fermix_home} #{moved}", config(ctx, :open))
      assert File.dir?(ctx.fermix_home)
      refute File.exists?(moved)
    end

    test "open: a stored secret cannot be read", ctx do
      key = Path.join([ctx.fermix_home, "secrets", "KEY"])

      assert %{success: false, error: error} = shell("cat #{key}", config(ctx, :open))
      assert error =~ "Operation not permitted"
      refute error =~ "secret-value"
    end

    test "standard: the owner's SSH key and npm token cannot be read; open can read them",
         ctx do
      key = Path.join([ctx.os_home, ".ssh", "id_probe"])
      npmrc = Path.join(ctx.os_home, ".npmrc")
      journal = Path.join(ctx.os_home, ".config/gcloud/access_tokens.db-wal")
      File.mkdir_p!(Path.dirname(key))
      File.mkdir_p!(Path.dirname(journal))
      File.write!(key, "private-key\n")
      File.write!(npmrc, "//registry.example/:_authToken=npm-token\n")
      File.write!(journal, "private-key\n")
      script = ~s|python3 -I -c "print(open('#{npmrc}').read())"|

      for command <- ["cat #{key}", script, "cat #{journal}"] do
        assert %{success: false, error: error} = shell(command, config(ctx, :standard))
        assert error =~ "Operation not permitted", command
        refute error =~ "private-key"
        refute error =~ "npm-token"
      end

      assert %{success: true, output: output} = shell("cat #{key}", config(ctx, :open))
      assert output =~ "private-key"
      assert %{success: true, output: output} = shell(script, config(ctx, :open))
      assert output =~ "npm-token"

      # Readable in open, never movable: a sibling renamed away would leave the
      # read rule guarding nothing.
      assert %{success: false} = shell("mv #{journal} #{ctx.outside}/", config(ctx, :open))
      assert File.exists?(journal)
    end

    # A socket file with no listener: the kernel's refusal is EPERM, a socket the
    # sandbox allows answers ECONNREFUSED. Connected by relative name, since a
    # temp home's absolute socket path is longer than a unix address holds.
    test "Fermix's sockets refuse a command; another socket still connects", ctx do
      bind_socket!(ctx.fermix_home, "daemon.sock")
      bind_socket!(ctx.outside, "other.sock")

      daemon = shell(connect(ctx.fermix_home, "daemon.sock"), config(ctx, :open))
      other = shell(connect(ctx.outside, "other.sock"), config(ctx, :open))

      assert daemon.error =~ "Operation not permitted"
      assert other.error =~ "Connection refused"
    end

    test "a plugin binary in Fermix's home cannot be run by a command", ctx do
      tool = Path.join(ctx.plugins, "tool")
      File.write!(tool, "#!/bin/sh\necho ran\n")
      File.chmod!(tool, 0o755)

      assert %{success: false, error: error} = shell(tool, config(ctx, :open))
      assert error =~ "Operation not permitted"
      refute error =~ "ran\n"
    end

    test "nothing can be mounted over a protected folder", ctx do
      image = Path.join(ctx.outside, "probe.dmg")
      create = ["create", "-quiet", "-size", "1m", "-fs", "HFS+", image]
      {_out, 0} = System.cmd("hdiutil", create, stderr_to_stdout: true)

      # Over `plugins/`, which a command may read: over a read-denied folder the
      # attach fails without the mount rule, which would prove nothing.
      plugins = Path.join(ctx.fermix_home, "plugins")
      attach = "hdiutil attach -nobrowse -mountpoint #{plugins} #{image}"
      # Should the sandbox ever let it through, the image must not outlive the test.
      on_exit(fn ->
        if mounted?(plugins), do: {_out, 0} = System.cmd("hdiutil", ["detach", "-force", plugins])
      end)

      assert %{success: false} = shell(attach, config(ctx, :open))
      refute mounted?(plugins)
      assert File.dir?(ctx.plugins)
    end

    test "a Fermix home named through a symlink is still protected", ctx do
      link = Path.join(ctx.base, "home-link")
      File.ln_s!(ctx.fermix_home, link)
      System.put_env("FERMIX_HOME", link)
      config = Config.normalize(mode: :open, home: link, os_home: ctx.os_home)
      config_toml = Path.join(ctx.fermix_home, "config.toml")

      assert %{success: false} = shell("echo x >> #{config_toml}", config)
      assert File.read!(config_toml) == "seeded = 1\n"
    end

    test "strict: ordinary work still runs (/dev/null, mktemp, a pty)", ctx do
      context = Map.put(context(config(ctx, :strict)), :os_sandbox, [])
      pty = ~s|python3 -I -c "import pty, os; m, s = pty.openpty(); os.write(s, b'x')"|

      for command <- ["echo hi > /dev/null", "rm \"$(mktemp)\"", pty] do
        assert {:ok, %{success: true}} = Shell.execute(%{"command" => command}, context),
               command
      end
    end

    test "a profile that cannot be built refuses the command with a sentence", ctx do
      loop = Path.join(ctx.base, "loop")
      File.ln_s!(loop, loop)

      config =
        Config.normalize(
          mode: :strict,
          home: loop,
          os_home: ctx.os_home,
          workspace_root: ctx.workspace
        )

      assert %{success: false, error: error} = shell("echo hi", config)
      assert error =~ "Commands can't run: Fermix's sandbox could not resolve #{loop}"
    end

    test "an operator command runs inside the sandbox", ctx do
      blocked = Path.join(ctx.outside, "c.txt")
      spec = command_spec("echo c > #{blocked}")

      assert {:ok, %{success: false}} =
               CommandTool.execute(%{"prompt" => "x"}, context(config(ctx, :strict)), spec)

      refute File.exists?(blocked)
    end

    # The codex and claude presets carry `confined?: false` until stage C.
    test "a preset marked unconfined runs outside the sandbox", ctx do
      written = Path.join(ctx.outside, "d.txt")
      spec = %{command_spec("echo d > #{written}") | confined?: false}

      assert {:ok, %{success: true}} =
               CommandTool.execute(%{"prompt" => "x"}, context(config(ctx, :strict)), spec)

      assert File.exists?(written)
    end

    test "a git hook in a repo the agent can write runs inside the sandbox", ctx do
      repo = Path.join(ctx.workspace, "repo")
      planted = Path.join(ctx.outside, "hook.txt")
      git_init!(repo)
      hook = Path.join([repo, ".git", "hooks", "pre-commit"])
      File.write!(hook, "#!/bin/sh\necho planted > #{planted}\nexit 0\n")
      File.chmod!(hook, 0o755)

      args = %{"command" => "commit", "repo" => repo, "args" => ["--allow-empty", "-m", "x"]}

      assert {:ok, %{success: true}} = GitWrite.execute(args, context(config(ctx, :strict)))
      refute File.exists?(planted)
    end
  end

  defp shell(command, config) do
    {:ok, result} = Shell.execute(%{"command" => command}, context(config))
    result
  end

  defp context(config) do
    %{
      agent_name: "test_agent",
      conversation_key: :os_sandbox_test,
      sandbox_config: config,
      os_sandbox: [scratch: []]
    }
  end

  defp command_spec(script) do
    %{
      name: "probe",
      command: "/bin/sh",
      args: ["-c", script],
      pass_env: [],
      timeout_ms: 30_000,
      description: "probe",
      confined?: true
    }
  end

  defp bind_socket!(dir, name) do
    script =
      "import os, socket, sys; os.chdir(sys.argv[1]); " <>
        "socket.socket(socket.AF_UNIX).bind(sys.argv[2])"

    {_out, 0} = System.cmd("python3", ["-I", "-c", script, dir, name], stderr_to_stdout: true)
  end

  defp connect(dir, name) do
    ~s|cd #{dir} && python3 -I -c "import socket; socket.socket(socket.AF_UNIX).connect('#{name}')"|
  end

  defp mounted?(dir) do
    {table, 0} = System.cmd("mount", [])
    String.contains?(table, " on #{resolved(dir)} ")
  end

  defp git_init!(repo) do
    for args <- [
          ["init", "-q", repo],
          ["-C", repo, "config", "user.name", "Test Owner"],
          ["-C", repo, "config", "user.email", "owner@example.test"]
        ] do
      {_out, 0} = System.cmd("git", args, stderr_to_stdout: true)
    end
  end

  defp escaped(path), do: String.replace(path, ~r/[\\.\[\](){}*+?^$|]/, "\\\\\\0")
end
