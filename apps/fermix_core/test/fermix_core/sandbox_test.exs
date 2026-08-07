defmodule FermixCore.SandboxTest do
  use ExUnit.Case, async: true

  alias FermixCore.Sandbox
  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.Env
  alias FermixCore.Sandbox.PathPolicy

  test "standard mode admits the request cwd for an operator context and denies it without" do
    os_home = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-request-cwd")
    request_dir = Path.join(os_home, "repos/project")
    File.mkdir_p!(request_dir)

    config =
      Config.normalize(
        mode: :standard,
        os_home: os_home,
        workspace_root: Path.join(os_home, "workspace")
      )

    # `request_dir` is reachable ONLY via the request cwd: it is not the
    # workspace and not the launch cwd (File.cwd! is the repo root, outside os_home).
    operator_context = %{sandbox_config: config, cwd: request_dir}
    assert {:ok, resolved} = Sandbox.working_dir(request_dir, :shell, operator_context)
    assert resolved == PathPolicy.canonical_path(request_dir)

    without_cwd = %{sandbox_config: config}

    assert {:error, {:outside_root, _path}} =
             Sandbox.working_dir(request_dir, :shell, without_cwd)

    FermixTestSupport.SafeRm.rm_rf!(os_home)
  end

  test "enforce fails closed for unknown request shapes" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-enforce")
    context = %{sandbox_config: Config.normalize(mode: :strict, workspace_root: root)}

    assert {:deny, :invalid_request} = Sandbox.enforce(:exec, %{operation: :unknown}, context)
    assert {:deny, :invalid_request} = Sandbox.enforce(:exec, %{}, context)

    FermixTestSupport.SafeRm.rm_rf!(root)
  end

  test "shell_plan allows an in-root command and denies an outside working dir" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-shell-plan")
    outside = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-shell-plan-outside")
    context = %{sandbox_config: Config.normalize(mode: :strict, workspace_root: root)}

    # shell_plan resolves config + protected roots once and threads them into both
    # the working-dir decision and the exec decision; the allow/deny outcome must
    # be byte-identical to the per-decision self-resolving path.
    assert {:ok, %{working_dir: working_dir, env: env}} =
             Sandbox.shell_plan("echo hi", root, context)

    assert working_dir == PathPolicy.canonical_path(root)
    assert is_list(env)

    assert {:error, {:outside_root, _path}} = Sandbox.shell_plan("echo hi", outside, context)

    FermixTestSupport.SafeRm.rm_rf!(root)
    FermixTestSupport.SafeRm.rm_rf!(outside)
  end

  test "enforce applies working-dir policy to command capabilities" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-enforce-command")
    outside = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-enforce-command-outside")
    canonical_outside = PathPolicy.canonical_path(outside)
    context = %{sandbox_config: Config.normalize(mode: :strict, workspace_root: root)}

    assert :allow =
             Sandbox.enforce(:exec, %{operation: :command_capability, working_dir: root}, context)

    assert {:deny, {:outside_root, ^canonical_outside}} =
             Sandbox.enforce(
               :exec,
               %{operation: :command_capability, working_dir: outside},
               context
             )

    FermixTestSupport.SafeRm.rm_rf!(root)
    FermixTestSupport.SafeRm.rm_rf!(outside)
  end

  # MILESTONE_29_ACP_AGENT_SURFACE §4/§8.3: the model answers in a Buzz channel by
  # running the `buzz` CLI through the SHELL tool, so the client session's env has
  # to reach the shell plan — the plan's env is the child's whole environment
  # (`shell.ex` spawns `env -i <assignments> sh -c …`). Both halves of the
  # 2026-07-26 env-sanitizer lesson: fidelity (the child can actually resolve and
  # authenticate the CLI) and isolation (a turn without an overlay is unchanged).
  describe "shell_plan session_env overlay" do
    setup do
      root = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-shell-plan-overlay")
      bin = Path.join(root, "bin")
      File.mkdir_p!(bin)
      # A stand-in for the `buzz` CLI, resolvable only through the overlay PATH.
      File.write!(Path.join(bin, "buzz"), "#!/bin/sh\nexec /usr/bin/env\n")
      File.chmod!(Path.join(bin, "buzz"), 0o755)

      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)

      %{root: root, bin: bin, config: Config.normalize(mode: :strict, workspace_root: root)}
    end

    test "fidelity: the plan's env carries the overlay credentials and its PATH", ctx do
      context = %{
        sandbox_config: ctx.config,
        session_env: %{"PATH" => ctx.bin, "BUZZ_PRIVATE_KEY" => "nsec1fakebuzzkeyvalue"}
      }

      assert {:ok, %{env: env}} =
               Sandbox.shell_plan("buzz messages send hi", ctx.root, context)

      assert List.keyfind(env, "BUZZ_PRIVATE_KEY", 0) ==
               {"BUZZ_PRIVATE_KEY", "nsec1fakebuzzkeyvalue"}

      # Not just "PATH is the overlay's" — the PATH the child receives must
      # actually resolve the CLI it is expected to run.
      assert {"PATH", path} = List.keyfind(env, "PATH", 0)
      assert path == ctx.bin
      assert Enum.any?(String.split(path, ":"), &File.regular?(Path.join(&1, "buzz")))

      # The overlay wins on ITS keys only; everything else stays policy env.
      assert {:ok, policy_env} = Env.build(ctx.config)
      assert List.keyfind(env, "HOME", 0) == List.keyfind(policy_env, "HOME", 0)
    end

    test "isolation: without a session_env the plan's env is exactly Env.build/1's", ctx do
      assert {:ok, %{env: env}} =
               Sandbox.shell_plan("echo hi", ctx.root, %{sandbox_config: ctx.config})

      assert {:ok, expected} = Env.build(ctx.config)
      assert Enum.sort(env) == Enum.sort(expected)
    end

    test "isolation: one plan's overlay never leaks into the next plan", ctx do
      overlay = %{
        sandbox_config: ctx.config,
        session_env: %{"PATH" => ctx.bin, "BUZZ_PRIVATE_KEY" => "nsec1fakebuzzkeyvalue"}
      }

      assert {:ok, %{env: _overlaid}} = Sandbox.shell_plan("buzz whoami", ctx.root, overlay)

      assert {:ok, %{env: env}} =
               Sandbox.shell_plan("echo hi", ctx.root, %{sandbox_config: ctx.config})

      assert List.keyfind(env, "BUZZ_PRIVATE_KEY", 0) == nil
      refute List.keyfind(env, "PATH", 0) == {"PATH", ctx.bin}
    end
  end

  # L-2b: the batch gate must yield the byte-identical allow/deny set as filtering
  # each candidate through read_path/3 — including failing CLOSED on a
  # canonicalization error rather than falling back to the unresolved literal.
  test "read_paths matches per-candidate read_path for allow, deny, and fail-closed candidates" do
    %{home: home, context: context, candidates: candidates, allowed: allowed} =
      read_paths_fixture()

    expected =
      Enum.filter(candidates, fn path ->
        match?({:ok, _resolved}, Sandbox.read_path(path, :content_search, context))
      end)

    assert Sandbox.read_paths(candidates, :content_search, context) == expected
    # Only the in-root file survives; protected, escaped, and symlink-loop
    # candidates are all excluded (the loop proves fail-closed).
    assert expected == [allowed]

    FermixTestSupport.SafeRm.rm_rf!(home)
  end

  # L-2b: hoisting the root sets must not drop the security-audit signal. Denied
  # candidates still emit a deny (which DecisionTelemetry persists as a
  # :sandbox_event); the redundant per-allow emit is intentionally dropped.
  test "read_paths preserves per-candidate deny telemetry and drops allow emits" do
    %{home: home, context: base_context, candidates: candidates} = read_paths_fixture()

    # telemetry handlers are global; scope capture to THIS test's decisions via a
    # unique conversation_key so concurrent async tests' emits don't leak in.
    conversation_key = {:read_paths_telemetry, System.unique_integer([:positive])}
    context = Map.put(base_context, :conversation_key, conversation_key)

    test_pid = self()
    ref = make_ref()
    handler = "read-paths-decision-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:fermix, :sandbox, :decision],
      fn _event, _measurements, metadata, _config ->
        if self() == test_pid do
          if metadata[:conversation_key] == conversation_key do
            send(test_pid, {ref, metadata.decision, Map.get(metadata, :reason)})
          end
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    Sandbox.read_paths(candidates, :content_search, context)

    assert_received {^ref, :deny, {:protected_path, _protected}}
    assert_received {^ref, :deny, {:outside_root, _escaped}}
    assert_received {^ref, :deny, {:too_many_symlinks, _looped}}
    # The allowed candidate must NOT emit — allow is dropped in the batch path.
    refute_received {^ref, :allow, _reason}

    FermixTestSupport.SafeRm.rm_rf!(home)
  end

  # A tree with one allowed file and three distinct deny/error shapes: a file
  # under a protected home dir, a file reached through a symlink escaping the
  # root, and a symlink loop (canonicalization error → fail-closed).
  defp read_paths_fixture do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-read-paths")

    File.mkdir_p!(Path.join(home, "work"))
    allowed = Path.join(home, "work/ok.txt")
    File.write!(allowed, "hi")

    File.mkdir_p!(Path.join(home, ".ssh"))
    protected = Path.join(home, ".ssh/id_rsa")
    File.write!(protected, "secret")

    outside = FermixTestSupport.SafeRm.make_tmp_dir!("sandbox-read-paths-outside")
    File.write!(Path.join(outside, "escape.txt"), "x")
    File.ln_s!(outside, Path.join(home, "link"))
    escaped = Path.join(home, "link/escape.txt")

    File.ln_s!("loop", Path.join(home, "loop"))
    looped = Path.join(home, "loop/file.txt")

    # `outside` lives only to back the escaping symlink; the symlink target is
    # captured, so cleaning it here keeps the fixture self-contained.
    FermixTestSupport.SafeRm.rm_rf!(outside)

    context = %{
      agent_name: "test",
      conversation_key: :test,
      cwd: home,
      sandbox_config: Config.normalize(mode: :open, os_home: home, workspace_root: home)
    }

    %{
      home: home,
      context: context,
      allowed: allowed,
      candidates: [allowed, protected, escaped, looped]
    }
  end
end
