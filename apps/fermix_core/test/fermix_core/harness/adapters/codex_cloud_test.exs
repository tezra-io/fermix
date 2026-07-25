defmodule FermixCore.Harness.Adapters.CodexCloudTest do
  # Pure submit-argv rendering + submit/status output parsing: no OS spawn, no
  # real codex CLI (the binary is an injected fake path), fixtures are the
  # source-derived pinned-CLI forms (see the cloud/ README).
  use ExUnit.Case, async: true

  alias FermixCore.Harness.Adapters.CodexCloud

  @fixtures Path.expand("../../../fixtures/harness/cloud", __DIR__)

  describe "submit_argv/2 — golden argv" do
    test "the base invocation is `cloud exec --env <id> <query>` with the resolved binary" do
      assert {:ok, %{binary: binary, argv: argv}} =
               CodexCloud.submit_argv(
                 %{query: "fix the flaky test", env_id: "proj-web"},
                 find_executable: &fake_codex/1
               )

      assert binary == "/opt/fake/bin/codex"
      assert argv == ["cloud", "exec", "--env", "proj-web", "fix the flaky test"]
    end

    test "branch renders --branch" do
      assert {:ok, %{argv: argv}} =
               CodexCloud.submit_argv(
                 %{query: "q", env_id: "e", branch: "feature/x"},
                 find_executable: &fake_codex/1
               )

      assert argv == ["cloud", "exec", "--env", "e", "--branch", "feature/x", "q"]
    end

    test "attempts renders --attempts stringified" do
      assert {:ok, %{argv: argv}} =
               CodexCloud.submit_argv(
                 %{query: "q", env_id: "e", attempts: 3},
                 find_executable: &fake_codex/1
               )

      assert argv == ["cloud", "exec", "--env", "e", "--attempts", "3", "q"]
    end

    test "every schema'd param renders together in a stable order, query last" do
      assert {:ok, %{argv: argv}} =
               CodexCloud.submit_argv(
                 %{query: "the whole brief", env_id: "e", branch: "b", attempts: 4},
                 find_executable: &fake_codex/1
               )

      assert argv == [
               "cloud",
               "exec",
               "--env",
               "e",
               "--branch",
               "b",
               "--attempts",
               "4",
               "the whole brief"
             ]

      # No brief-file spillover for cloud: the query rides argv verbatim as the
      # last positional (never a pointer/placeholder).
      assert List.last(argv) == "the whole brief"
    end

    test "attempts accepts the clap bounds 1 and 4" do
      assert {:ok, %{argv: min_argv}} =
               CodexCloud.submit_argv(%{query: "q", env_id: "e", attempts: 1},
                 find_executable: &fake_codex/1
               )

      assert {:ok, %{argv: max_argv}} =
               CodexCloud.submit_argv(%{query: "q", env_id: "e", attempts: 4},
                 find_executable: &fake_codex/1
               )

      assert "1" in min_argv
      assert "4" in max_argv
    end
  end

  describe "submit_argv/2 — refusals" do
    test "an unknown param is rejected by key" do
      assert {:error, {:unknown_param, :bogus}} =
               CodexCloud.submit_argv(%{query: "q", env_id: "e", bogus: 1},
                 find_executable: &fake_codex/1
               )
    end

    test "attempts below the clap floor is rejected with the offending value" do
      assert {:error, {:invalid_param, :attempts, 0}} =
               CodexCloud.submit_argv(%{query: "q", env_id: "e", attempts: 0},
                 find_executable: &fake_codex/1
               )
    end

    test "attempts above the clap cap of 4 is rejected with the offending value" do
      assert {:error, {:invalid_param, :attempts, 5}} =
               CodexCloud.submit_argv(%{query: "q", env_id: "e", attempts: 5},
                 find_executable: &fake_codex/1
               )
    end

    test "a non-integer attempts is rejected" do
      assert {:error, {:invalid_param, :attempts, "3"}} =
               CodexCloud.submit_argv(%{query: "q", env_id: "e", attempts: "3"},
                 find_executable: &fake_codex/1
               )
    end

    test "an empty query is refused" do
      assert {:error, {:invalid_param, :query}} =
               CodexCloud.submit_argv(%{query: "", env_id: "e"}, find_executable: &fake_codex/1)
    end

    test "a missing query is refused" do
      assert {:error, {:invalid_param, :query}} =
               CodexCloud.submit_argv(%{env_id: "e"}, find_executable: &fake_codex/1)
    end

    test "an empty env_id is refused" do
      assert {:error, {:invalid_param, :env_id}} =
               CodexCloud.submit_argv(%{query: "q", env_id: ""}, find_executable: &fake_codex/1)
    end

    test "an empty branch is refused" do
      assert {:error, {:invalid_param, :branch}} =
               CodexCloud.submit_argv(%{query: "q", env_id: "e", branch: ""},
                 find_executable: &fake_codex/1
               )
    end

    test "an oversized query is refused (no brief-file spillover for cloud)" do
      big = String.duplicate("x", 200 * 1024 + 1)

      assert {:error, :query_too_large} =
               CodexCloud.submit_argv(%{query: big, env_id: "e"}, find_executable: &fake_codex/1)
    end

    test "a query at exactly the cap is accepted" do
      at_cap = String.duplicate("x", 200 * 1024)

      assert {:ok, %{argv: argv}} =
               CodexCloud.submit_argv(%{query: at_cap, env_id: "e"},
                 find_executable: &fake_codex/1
               )

      assert List.last(argv) == at_cap
    end

    test "a missing codex binary is a clean cli_unavailable" do
      assert {:error, :cli_unavailable} =
               CodexCloud.submit_argv(%{query: "q", env_id: "e"},
                 find_executable: fn _name -> nil end
               )
    end
  end

  describe "parse_submit/2" do
    test "the success line yields the task id (last path segment) and url" do
      assert {:ok, %{task_id: "task_i_abc123def456", task_url: url}} =
               CodexCloud.parse_submit(fixture("submit_success.txt"), 0)

      assert url == "https://chatgpt.com/codex/tasks/task_i_abc123def456"
    end

    test "an env-not-found Error line is a command failure carrying the detail" do
      assert {:error, {:command_failed, "environment 'proj-web' not found"}} =
               CodexCloud.parse_submit(fixture("submit_error_env_not_found.txt"), 1)
    end

    test "an http Error line is a command failure" do
      assert {:error, {:command_failed, detail}} =
               CodexCloud.parse_submit(fixture("submit_error_http.txt"), 1)

      assert detail =~ "502"
    end

    test "the pinned not-signed-in diagnostic is classified as cloud auth" do
      assert {:error, :cloud_auth} =
               CodexCloud.parse_submit(fixture("submit_not_signed_in.txt"), 1)
    end

    test "unrecognized output is a submit_parse failure carrying the exit code" do
      assert {:error, {:submit_parse, detail}} =
               CodexCloud.parse_submit(fixture("submit_unparseable.txt"), 2)

      assert detail =~ "exit=2"
    end

    test "a task URL surrounded by extra lines is NOT a success (§P: exactly one line)" do
      noisy = "some warning\nhttps://chatgpt.com/codex/tasks/task_i_abc123\nmore noise\n"

      assert {:error, {:submit_parse, detail}} = CodexCloud.parse_submit(noisy, 0)
      assert detail =~ "exit=0"
    end

    test "a task URL with a non-zero exit is NOT a success (§P: exit 0)" do
      assert {:error, {:submit_parse, detail}} =
               CodexCloud.parse_submit(fixture("submit_success.txt"), 1)

      assert detail =~ "exit=1"
    end
  end

  describe "parse_status/2 — display states" do
    test "PENDING is nonterminal" do
      assert {:ok, %{state: :pending, raw: raw}} =
               CodexCloud.parse_status(fixture("status_pending.txt"), 1)

      assert raw.title == "Fix the flaky auth test"
      assert raw.env_label == "web-app"
      assert raw.relative_time == "12 seconds ago"
      assert raw.diff == :none
      assert CodexCloud.ledger_mapping(:pending) == :nonterminal
    end

    test "READY maps to completed (the only exit-0 state)" do
      assert {:ok, %{state: :ready, raw: raw}} =
               CodexCloud.parse_status(fixture("status_ready.txt"), 0)

      assert raw.diff == %{adds: 42, dels: 8, files: 3}
      assert CodexCloud.ledger_mapping(:ready) == {:terminal, "completed", nil, nil}
    end

    test "APPLIED maps to completed with a vendor-status note" do
      assert {:ok, %{state: :applied}} =
               CodexCloud.parse_status(fixture("status_applied.txt"), 1)

      assert {:terminal, "completed", nil, note} = CodexCloud.ledger_mapping(:applied)
      assert note =~ "applied"
    end

    test "ERROR maps to failed/:cloud_failed" do
      assert {:ok, %{state: :error}} =
               CodexCloud.parse_status(fixture("status_error.txt"), 1)

      assert {:terminal, "failed", :cloud_failed, _note} = CodexCloud.ledger_mapping(:error)
    end
  end

  describe "parse_status/2 — line-form variants" do
    test "the env line may be omitted entirely" do
      assert {:ok, %{state: :ready, raw: raw}} =
               CodexCloud.parse_status(fixture("status_no_env_line.txt"), 0)

      assert raw.env_label == nil
      assert raw.relative_time == nil
      assert raw.diff == %{adds: 5, dels: 2, files: 2}
    end

    test "the `no diff` summary parses to :none" do
      assert {:ok, %{raw: %{diff: :none, summary: "no diff"}}} =
               CodexCloud.parse_status(fixture("status_no_diff.txt"), 0)
    end

    test "a plural file summary parses the counts" do
      assert {:ok, %{raw: %{diff: %{adds: 120, dels: 45, files: 7}}}} =
               CodexCloud.parse_status(fixture("status_files_plural.txt"), 0)
    end

    test "a singular file summary parses to one file" do
      assert {:ok, %{raw: %{diff: %{adds: 1, dels: 0, files: 1}}}} =
               CodexCloud.parse_status(fixture("status_files_singular.txt"), 0)
    end
  end

  describe "parse_status/2 — failures" do
    test "the pinned not-signed-in diagnostic is classified as cloud auth" do
      assert {:error, :cloud_auth} =
               CodexCloud.parse_status(fixture("status_not_signed_in.txt"), 1)
    end

    test "an http Error line with no status line is a command failure" do
      assert {:error, {:command_failed, detail}} =
               CodexCloud.parse_status(fixture("status_http_error.txt"), 1)

      assert detail =~ "500"
    end

    test "unrecognized output is a status_parse failure carrying the exit code" do
      assert {:error, {:status_parse, detail}} = CodexCloud.parse_status("garbage line\n", 0)
      assert detail =~ "exit=0"
    end
  end

  describe "parse_status/2 — classification is output-driven, not exit-code-driven" do
    test "READY stdout with a (wrong) non-zero exit still classifies READY" do
      # The exit code is NOT consulted while a status line is present — the
      # pinned CLI exits 0 only for READY (the exit-code trap).
      assert {:ok, %{state: :ready}} = CodexCloud.parse_status(fixture("status_ready.txt"), 1)
    end

    test "APPLIED stdout with a (wrong) zero exit still classifies APPLIED" do
      assert {:ok, %{state: :applied}} = CodexCloud.parse_status(fixture("status_applied.txt"), 0)
    end
  end

  describe "ledger_mapping/1" do
    test "the full source-derived table" do
      assert CodexCloud.ledger_mapping(:pending) == :nonterminal
      assert CodexCloud.ledger_mapping(:ready) == {:terminal, "completed", nil, nil}

      assert {:terminal, "completed", nil,
              "the vendor already applied the diff to the environment branch"} =
               CodexCloud.ledger_mapping(:applied)

      assert {:terminal, "failed", :cloud_failed, _} = CodexCloud.ledger_mapping(:error)
    end
  end

  defp fixture(name), do: @fixtures |> Path.join(name) |> File.read!()

  # A hermetic binary resolver: the fake codex is never spawned (submit_argv is
  # pure — it only renders argv), so any absolute path stands in for the CLI.
  defp fake_codex("codex"), do: "/opt/fake/bin/codex"
  defp fake_codex(_other), do: nil
end
