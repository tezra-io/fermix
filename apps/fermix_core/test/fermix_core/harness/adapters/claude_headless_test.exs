defmodule FermixCore.Harness.Adapters.ClaudeHeadlessTest do
  # Pure plan rendering + fixture-driven stream classification: no OS spawn, no
  # real claude CLI (the binary is an injected fake path), path gating runs
  # against a per-test SafeRm sandbox root.
  use ExUnit.Case, async: true

  alias FermixCore.Harness.Adapters.ClaudeHeadless
  alias FermixCore.Sandbox

  @fixtures Path.expand("../../../fixtures/harness", __DIR__)
  @base ["-p", "--output-format", "stream-json", "--verbose"]

  setup do
    workspace = FermixTestSupport.SafeRm.make_tmp_dir!("harness-claude-adapter")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(workspace) end)

    ctx = %{
      cwd: workspace,
      agent_name: "test_agent",
      conversation_key: :test,
      sandbox_config: %{mode: :strict, workspace_root: workspace, allowed_roots: []},
      find_executable: fn
        "claude" -> "/opt/fake/bin/claude"
        _other -> nil
      end
    }

    %{workspace: workspace, ctx: ctx}
  end

  describe "vendor/0" do
    test "is claude" do
      assert ClaudeHeadless.vendor() == "claude"
    end
  end

  describe "plan/2 — argv rendering" do
    test "the base plan is -p stream-json --verbose with a prompt slot", %{
      workspace: workspace,
      ctx: ctx
    } do
      assert {:ok, plan} = ClaudeHeadless.plan(%{}, ctx)

      assert plan.binary == "/opt/fake/bin/claude"
      assert plan.cwd == workspace
      assert plan.resumable == true
      assert plan.extra_lock_roots == []
      assert plan.env_names == []
      assert plan.argv == @base ++ [:prompt]
    end

    test "model, effort and permission_mode render their flags", %{ctx: ctx} do
      params = %{model: "claude-fable-5", effort: "high", permission_mode: "acceptEdits"}
      assert {:ok, plan} = ClaudeHeadless.plan(params, ctx)

      assert opts(plan.argv) == [
               "--model",
               "claude-fable-5",
               "--effort",
               "high",
               "--permission-mode",
               "acceptEdits"
             ]
    end

    test "a bad effort enum fails loud", %{ctx: ctx} do
      assert {:error, {:invalid_effort, "turbo"}} = ClaudeHeadless.plan(%{effort: "turbo"}, ctx)
    end

    test "a bad permission_mode fails loud", %{ctx: ctx} do
      assert {:error, {:invalid_permission_mode, "yolo"}} =
               ClaudeHeadless.plan(%{permission_mode: "yolo"}, ctx)
    end

    test "allowed and disallowed tool lists are comma-joined", %{ctx: ctx} do
      params = %{allowed_tools: ["Bash", "Edit"], disallowed_tools: ["WebSearch"]}
      assert {:ok, plan} = ClaudeHeadless.plan(params, ctx)

      assert opts(plan.argv) == [
               "--allowed-tools",
               "Bash,Edit",
               "--disallowed-tools",
               "WebSearch"
             ]
    end

    test "append_system_prompt renders the string content", %{ctx: ctx} do
      assert {:ok, plan} = ClaudeHeadless.plan(%{append_system_prompt: "be terse"}, ctx)
      assert opts(plan.argv) == ["--append-system-prompt", "be terse"]
    end

    test "max_turns and json_schema render", %{ctx: ctx} do
      assert {:ok, plan} =
               ClaudeHeadless.plan(%{max_turns: 5, json_schema: ~s({"type":"object"})}, ctx)

      assert opts(plan.argv) == ["--max-turns", "5", "--json-schema", ~s({"type":"object"})]
    end

    test "a map json_schema is encoded", %{ctx: ctx} do
      assert {:ok, plan} = ClaudeHeadless.plan(%{json_schema: %{"type" => "object"}}, ctx)
      assert opts(plan.argv) == ["--json-schema", ~s({"type":"object"})]
    end

    test "dangerously_skip_permissions and bare are flag-only", %{ctx: ctx} do
      params = %{dangerously_skip_permissions: true, bare: true}
      assert {:ok, plan} = ClaudeHeadless.plan(params, ctx)
      assert "--dangerously-skip-permissions" in plan.argv
      assert "--bare" in plan.argv
    end

    test "bare declares ANTHROPIC_API_KEY in the env passthrough set", %{ctx: ctx} do
      assert {:ok, plan} = ClaudeHeadless.plan(%{bare: true}, ctx)
      assert plan.env_names == ["ANTHROPIC_API_KEY"]
    end

    test "every schema'd non-path param renders together in a stable order", %{ctx: ctx} do
      params = %{
        model: "claude-fable-5",
        effort: "medium",
        permission_mode: "auto",
        allowed_tools: ["Bash"],
        disallowed_tools: ["Edit"],
        dangerously_skip_permissions: true,
        append_system_prompt: "hi",
        max_turns: 3,
        json_schema: ~s({"a":1}),
        continue: true,
        bare: true
      }

      assert {:ok, plan} = ClaudeHeadless.plan(params, ctx)

      assert opts(plan.argv) == [
               "--model",
               "claude-fable-5",
               "--effort",
               "medium",
               "--permission-mode",
               "auto",
               "--allowed-tools",
               "Bash",
               "--disallowed-tools",
               "Edit",
               "--append-system-prompt",
               "hi",
               "--max-turns",
               "3",
               "--json-schema",
               ~s({"a":1}),
               "--dangerously-skip-permissions",
               "--continue",
               "--bare"
             ]
    end
  end

  describe "plan/2 — path-bearing params" do
    test "append_system_prompt_file is read-gated and resolved", %{workspace: workspace, ctx: ctx} do
      file = Path.join(workspace, "sys.md")
      File.write!(file, "extra")
      {:ok, resolved} = Sandbox.read_path(file, :harness_input, ctx)

      assert {:ok, plan} = ClaudeHeadless.plan(%{append_system_prompt_file: file}, ctx)
      assert opts(plan.argv) == ["--append-system-prompt-file", resolved]
    end

    test "add_dirs are write-gated, resolved, and become lock roots", %{
      workspace: workspace,
      ctx: ctx
    } do
      sub = Path.join(workspace, "extra")
      File.mkdir_p!(sub)
      {:ok, resolved} = Sandbox.write_path(sub, :harness_add_dir, ctx)

      assert {:ok, plan} = ClaudeHeadless.plan(%{add_dirs: [sub]}, ctx)
      assert opts(plan.argv) == ["--add-dir", resolved]
      assert plan.extra_lock_roots == [resolved]
    end

    test "append_system_prompt_file outside the sandbox is denied", %{ctx: ctx} do
      assert {:error, {:path_denied, :append_system_prompt_file, _reason}} =
               ClaudeHeadless.plan(%{append_system_prompt_file: "/etc/passwd"}, ctx)
    end

    test "an add_dir outside the sandbox is denied", %{ctx: ctx} do
      assert {:error, {:path_denied, :add_dirs, _reason}} =
               ClaudeHeadless.plan(%{add_dirs: ["/etc"]}, ctx)
    end
  end

  describe "plan/2 — resume/continue" do
    test "resume renders --resume with the session id", %{ctx: ctx} do
      assert {:ok, plan} = ClaudeHeadless.plan(%{resume: "sess-42"}, ctx)
      assert opts(plan.argv) == ["--resume", "sess-42"]
    end

    test "resume and continue together are rejected", %{ctx: ctx} do
      assert {:error, :resume_and_continue} =
               ClaudeHeadless.plan(%{resume: "sess-42", continue: true}, ctx)
    end
  end

  describe "plan/2 — failures" do
    test "an unknown param is rejected by key", %{ctx: ctx} do
      assert {:error, {:unknown_param, :sandbox}} = ClaudeHeadless.plan(%{sandbox: "x"}, ctx)
    end

    test "a missing binary is a clean cli_unavailable", %{ctx: ctx} do
      ctx = %{ctx | find_executable: fn _name -> nil end}
      assert {:error, :cli_unavailable} = ClaudeHeadless.plan(%{}, ctx)
    end

    test "a missing cwd fails loud", %{ctx: ctx} do
      assert {:error, :missing_cwd} = ClaudeHeadless.plan(%{}, Map.delete(ctx, :cwd))
    end
  end

  describe "terminal?/1" do
    test "a result event is terminal regardless of position" do
      assert ClaudeHeadless.terminal?(%{"type" => "result", "subtype" => "success"})
    end

    test "non-result events are not terminal" do
      refute ClaudeHeadless.terminal?(%{"type" => "assistant"})
      refute ClaudeHeadless.terminal?(%{"type" => "system", "subtype" => "init"})
      refute ClaudeHeadless.terminal?(%{"type" => "rate_limit_event"})
    end
  end

  describe "extract/1 driven by the recorded fixtures" do
    test "the success stream yields session id, usage and result" do
      events = read_events("claude_stream_success.jsonl")

      assert extract_value(events, :vendor_session_id) == "19191a60-736f-4477-a4ac-0c0b3641cbcb"
      assert extract_value(events, :result_text) == "ok"

      usage = extract_value(events, :usage)
      assert usage["total_cost_usd"] == 0.300185
      assert is_map(usage["usage"])
      assert is_map(usage["modelUsage"])
    end

    test "the result event is detected even when a hook event trails it" do
      events = read_events("claude_stream_failure.jsonl")
      terminal_index = Enum.find_index(events, &ClaudeHeadless.terminal?/1)

      assert terminal_index != nil
      refute terminal_index == length(events) - 1
    end
  end

  describe "resume_hint/1" do
    test "a run with a session id yields the cwd-scoped resume invocation" do
      row = %{vendor_session_id: "sess-9", cwd: "/repo"}
      assert ClaudeHeadless.resume_hint(row) == "cd /repo && claude --resume sess-9"
    end

    test "a run without a session id yields nil" do
      assert ClaudeHeadless.resume_hint(%{vendor_session_id: nil, cwd: "/repo"}) == nil
    end
  end

  defp read_events(name) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp extract_value(events, key) do
    Enum.find_value(events, fn event -> Map.get(ClaudeHeadless.extract(event), key) end)
  end

  # The rendered option args: everything between the fixed prefix and the prompt slot.
  defp opts(argv) do
    argv
    |> Enum.drop(length(@base))
    |> Enum.reject(&(&1 == :prompt))
  end
end
