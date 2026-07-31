defmodule FermixCore.Harness.Adapters.CodexExecTest do
  # Pure plan rendering + fixture-driven stream classification: no OS spawn, no
  # real codex CLI (the binary is an injected fake path), path gating runs
  # against a per-test SafeRm sandbox root.
  use ExUnit.Case, async: true

  alias FermixCore.Harness.Adapters.CodexExec
  alias FermixCore.Sandbox

  @fixtures Path.expand("../../../fixtures/harness", __DIR__)

  setup do
    workspace = FermixTestSupport.SafeRm.make_tmp_dir!("harness-codex-adapter")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(workspace) end)

    ctx = %{
      cwd: workspace,
      agent_name: "test_agent",
      conversation_key: :test,
      sandbox_config: %{mode: :strict, workspace_root: workspace, allowed_roots: []},
      find_executable: fn
        "codex" -> "/opt/fake/bin/codex"
        _other -> nil
      end
    }

    %{workspace: workspace, ctx: ctx}
  end

  describe "vendor/0" do
    test "is codex" do
      assert CodexExec.vendor() == "codex"
    end
  end

  describe "plan/2 — argv rendering" do
    test "the base plan is exec --json --skip-git-repo-check -C cwd with prompt/output slots", %{
      workspace: workspace,
      ctx: ctx
    } do
      assert {:ok, plan} = CodexExec.plan(%{}, ctx)

      assert plan.binary == "/opt/fake/bin/codex"
      assert plan.cwd == workspace
      assert plan.resumable == true
      assert plan.extra_lock_roots == []
      assert plan.env_names == []

      # `--skip-git-repo-check` is unconditional (design §23.5): codex refuses a
      # non-git cwd, and Fermix's sandbox working-dir gate already ran.
      assert plan.argv == [
               "exec",
               "--json",
               "--skip-git-repo-check",
               "-C",
               workspace,
               "-o",
               :output_file,
               :prompt
             ]
    end

    test "model renders -m", %{ctx: ctx} do
      assert {:ok, plan} = CodexExec.plan(%{model: "gpt-5-codex"}, ctx)
      assert codex_opts(plan.argv) == ["-m", "gpt-5-codex"]
    end

    test "effort renders the single sanctioned -c model_reasoning_effort override", %{ctx: ctx} do
      assert {:ok, plan} = CodexExec.plan(%{effort: "high"}, ctx)
      assert codex_opts(plan.argv) == ["-c", "model_reasoning_effort=high"]
    end

    test "sandbox renders -s and rejects a bad enum", %{ctx: ctx} do
      assert {:ok, plan} = CodexExec.plan(%{sandbox: "workspace-write"}, ctx)
      assert codex_opts(plan.argv) == ["-s", "workspace-write"]

      assert {:error, {:invalid_sandbox, "yolo"}} = CodexExec.plan(%{sandbox: "yolo"}, ctx)
    end

    test "profile renders -p by name", %{ctx: ctx} do
      assert {:ok, plan} = CodexExec.plan(%{profile: "work"}, ctx)
      assert codex_opts(plan.argv) == ["-p", "work"]
    end

    test "ephemeral renders --ephemeral and forces resumable false", %{ctx: ctx} do
      assert {:ok, plan} = CodexExec.plan(%{ephemeral: true}, ctx)
      assert "--ephemeral" in plan.argv
      assert plan.resumable == false
    end

    test "every schema'd param renders together in a stable order", %{
      workspace: workspace,
      ctx: ctx
    } do
      schema = write_fixture_file(workspace, "schema.json")

      params = %{
        model: "gpt-5-codex",
        effort: "medium",
        sandbox: "workspace-write",
        profile: "work",
        ephemeral: true
      }

      assert {:ok, plan} = CodexExec.plan(params, ctx)

      assert codex_opts(plan.argv) == [
               "-m",
               "gpt-5-codex",
               "-c",
               "model_reasoning_effort=medium",
               "-s",
               "workspace-write",
               "-p",
               "work",
               "--ephemeral"
             ]

      refute schema in plan.argv
    end
  end

  describe "plan/2 — path-bearing params" do
    test "add_dirs are write-gated, resolved, and become lock roots", %{
      workspace: workspace,
      ctx: ctx
    } do
      sub = Path.join(workspace, "extra")
      File.mkdir_p!(sub)
      {:ok, resolved} = Sandbox.write_path(sub, :harness_add_dir, ctx)

      assert {:ok, plan} = CodexExec.plan(%{add_dirs: [sub]}, ctx)
      assert codex_opts(plan.argv) == ["--add-dir", resolved]
      assert plan.extra_lock_roots == [resolved]
    end

    test "images and output_schema are read-gated and resolved", %{workspace: workspace, ctx: ctx} do
      img = write_fixture_file(workspace, "shot.png")
      schema = write_fixture_file(workspace, "schema.json")
      {:ok, img_resolved} = Sandbox.read_path(img, :harness_input, ctx)
      {:ok, schema_resolved} = Sandbox.read_path(schema, :harness_input, ctx)

      assert {:ok, plan} = CodexExec.plan(%{images: [img], output_schema: schema}, ctx)

      assert codex_opts(plan.argv) ==
               ["-i", img_resolved, "--output-schema", schema_resolved]
    end

    test "an add_dir outside the sandbox is denied naming the param", %{ctx: ctx} do
      assert {:error, {:path_denied, :add_dirs, _reason}} =
               CodexExec.plan(%{add_dirs: ["/etc"]}, ctx)
    end

    test "an image outside the sandbox is denied naming the param", %{ctx: ctx} do
      assert {:error, {:path_denied, :images, _reason}} =
               CodexExec.plan(%{images: ["/etc/passwd"]}, ctx)
    end

    test "an output_schema outside the sandbox is denied", %{ctx: ctx} do
      assert {:error, {:path_denied, :output_schema, _reason}} =
               CodexExec.plan(%{output_schema: "/etc/hosts"}, ctx)
    end
  end

  describe "plan/2 — resume" do
    test "resume switches to the resume subcommand and drops -C", %{ctx: ctx} do
      assert {:ok, plan} = CodexExec.plan(%{resume: "thread-123"}, ctx)

      assert plan.argv == [
               "exec",
               "resume",
               "thread-123",
               "--json",
               "--skip-git-repo-check",
               "-o",
               :output_file,
               :prompt
             ]

      assert plan.resumable == true
      refute "-C" in plan.argv
    end

    test "resume carries the resume-compatible params", %{ctx: ctx} do
      assert {:ok, plan} = CodexExec.plan(%{resume: "t1", model: "gpt-5-codex"}, ctx)
      assert slice_between(plan.argv, "--skip-git-repo-check", "-o") == ["-m", "gpt-5-codex"]
    end

    test "ephemeral + resume is rejected", %{ctx: ctx} do
      assert {:error, :ephemeral_not_resumable} =
               CodexExec.plan(%{resume: "t1", ephemeral: true}, ctx)
    end

    # `codex exec resume` rejects `-s/--sandbox` outright (clap: "unexpected
    # argument"), but the same policy is a typed config override there, and it
    # beats the policy the resumed thread inherited. Verified live against
    # codex-cli 0.145.0: a resume with no override kept the session's
    # `workspace-write`, and `-c sandbox_mode=read-only` on that same thread
    # landed `read-only`. So the caller's posture is honored on both heads.
    test "sandbox on resume renders the config override, not the rejected flag", %{ctx: ctx} do
      assert {:ok, plan} = CodexExec.plan(%{resume: "t1", sandbox: "workspace-write"}, ctx)

      refute "-s" in plan.argv

      assert slice_between(plan.argv, "--skip-git-repo-check", "-o") == [
               "-c",
               "sandbox_mode=workspace-write"
             ]
    end

    test "sandbox off the resume path still renders the flag", %{ctx: ctx} do
      assert {:ok, plan} = CodexExec.plan(%{sandbox: "workspace-write"}, ctx)

      assert "-s" in plan.argv
      refute "sandbox_mode=workspace-write" in plan.argv
    end

    test "an invalid sandbox mode fails loud on the resume path too", %{ctx: ctx} do
      assert {:error, {:invalid_sandbox, "nope"}} =
               CodexExec.plan(%{resume: "t1", sandbox: "nope"}, ctx)
    end

    # `add_dirs` and `profile` stay refused, for two different reasons that both
    # survive the config route: `-c profile=` is rejected by codex outright
    # ("legacy `profile` config is no longer supported"), and
    # `sandbox_workspace_write.writable_roots` REPLACES the operator's configured
    # list rather than adding to it the way `--add-dir` does — so honoring it that
    # way could silently narrow a sandbox Fermix cannot read to merge.
    test "a resume-incompatible param fails loud rather than being dropped", %{ctx: ctx} do
      assert {:error, {:param_not_supported_with_resume, :add_dirs}} =
               CodexExec.plan(%{resume: "t1", add_dirs: ["/tmp"]}, ctx)

      assert {:error, {:param_not_supported_with_resume, :profile}} =
               CodexExec.plan(%{resume: "t1", profile: "p1"}, ctx)
    end
  end

  describe "plan/2 — failures" do
    test "an unknown param is rejected by key", %{ctx: ctx} do
      assert {:error, {:unknown_param, :bogus}} = CodexExec.plan(%{bogus: 1}, ctx)
    end

    test "a missing binary is a clean cli_unavailable", %{ctx: ctx} do
      ctx = %{ctx | find_executable: fn _name -> nil end}
      assert {:error, :cli_unavailable} = CodexExec.plan(%{}, ctx)
    end

    test "a missing cwd fails loud", %{ctx: ctx} do
      assert {:error, :missing_cwd} = CodexExec.plan(%{}, Map.delete(ctx, :cwd))
    end
  end

  describe "terminal?/1" do
    test "turn.completed and turn.failed are terminal" do
      assert CodexExec.terminal?(%{"type" => "turn.completed"})
      assert CodexExec.terminal?(%{"type" => "turn.failed"})
    end

    test "non-terminal event types are not terminal" do
      refute CodexExec.terminal?(%{"type" => "turn.started"})
      refute CodexExec.terminal?(%{"type" => "item.completed"})
      refute CodexExec.terminal?(%{"type" => "thread.started"})
    end
  end

  describe "extract/1 driven by the recorded fixtures" do
    test "the success stream yields session id, usage, and the agent result" do
      events = read_events("codex_exec_success.jsonl")

      assert extract_value(events, :vendor_session_id) == "019f7d3f-3f21-7482-8c91-749fb4713417"
      assert extract_value(events, :usage)["output_tokens"] == 5
      assert extract_value(events, :result_text) == "ok"
      assert Enum.any?(events, &CodexExec.terminal?/1)
    end

    test "an error item is not a result and does not mark terminal" do
      events = read_events("codex_exec_success.jsonl")
      error_item = Enum.find(events, &match?(%{"item" => %{"type" => "error"}}, &1))

      assert CodexExec.extract(error_item) == %{phase: "error"}
      refute CodexExec.terminal?(error_item)
    end

    test "the failure stream marks terminal on turn.failed" do
      events = read_events("codex_exec_failure.jsonl")
      assert Enum.any?(events, fn e -> e["type"] == "turn.failed" and CodexExec.terminal?(e) end)
    end
  end

  describe "resume_hint/1" do
    test "a resumable run with a session id yields the resume invocation" do
      row = %{resumable: true, vendor_session_id: "thread-9", cwd: "/repo"}
      assert CodexExec.resume_hint(row) == "cd /repo && codex exec resume thread-9 --json"
    end

    test "an ephemeral (non-resumable) run yields nil" do
      row = %{resumable: false, vendor_session_id: "thread-9", cwd: "/repo"}
      assert CodexExec.resume_hint(row) == nil
    end

    test "a run without a session id yields nil" do
      row = %{resumable: true, vendor_session_id: nil, cwd: "/repo"}
      assert CodexExec.resume_hint(row) == nil
    end
  end

  defp read_events(name) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp write_fixture_file(dir, name) do
    path = Path.join(dir, name)
    File.write!(path, "{}")
    path
  end

  # The argv slice strictly between the first `from` and the first `to` token.
  defp slice_between(argv, from, to) do
    start = Enum.find_index(argv, &(&1 == from)) + 1
    stop = Enum.find_index(argv, &(&1 == to))
    Enum.slice(argv, start, stop - start)
  end

  # The rendered option args for a non-resume plan: everything after `-C <cwd>`
  # (which consumes two tokens) and before the `-o` output slot.
  defp codex_opts(argv) do
    start = Enum.find_index(argv, &(&1 == "-C")) + 2
    stop = Enum.find_index(argv, &(&1 == "-o"))
    Enum.slice(argv, start, stop - start)
  end

  defp extract_value(events, key) do
    Enum.find_value(events, fn event -> Map.get(CodexExec.extract(event), key) end)
  end
end
