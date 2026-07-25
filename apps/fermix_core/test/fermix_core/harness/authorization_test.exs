defmodule FermixCore.Harness.AuthorizationTest do
  # Pure gate logic: no OS processes, no shared global state. The scheduled
  # branch's job registry is injected via a context seam, so no real Repo is
  # needed and the module stays async.
  use ExUnit.Case, async: true

  alias FermixCore.Harness.Authorization

  # --- Stub job registries (context `:jobs_registry` seam) ----------------

  defmodule AllowlistedRegistry do
    def get_job(_id, _opts), do: {:ok, %{allowed_tools: ["codex_run", "list_coding_runs"]}}
  end

  defmodule CloudAllowlistedRegistry do
    def get_job(_id, _opts),
      do: {:ok, %{allowed_tools: ["codex_cloud_run", "stop_tracking_coding_run"]}}
  end

  defmodule EmptyAllowlistRegistry do
    def get_job(_id, _opts), do: {:ok, %{allowed_tools: []}}
  end

  defmodule NilAllowlistRegistry do
    def get_job(_id, _opts), do: {:ok, %{allowed_tools: nil}}
  end

  defmodule MissingJobRegistry do
    def get_job(_id, _opts), do: {:error, :not_found}
  end

  @chat_key {"telegram", "123", :root}
  @scheduled_key {:scheduled_job, "job_x", "run_1"}

  # --- Attended operator (allowed) ----------------------------------------

  describe "live attended operator" do
    test "a top-level operator turn with a reply surface is authorized" do
      assert :ok = Authorization.authorize("codex_run", attended_operator())
    end

    test "every harness tool name passes the same attended gate" do
      ctx = attended_operator()

      names =
        ~w(codex_run claude_code_run list_coding_runs get_coding_run cancel_coding_run
           codex_cloud_run stop_tracking_coding_run)

      for name <- names do
        assert :ok = Authorization.authorize(name, ctx)
      end
    end
  end

  # --- Refusal classes ----------------------------------------------------

  describe "refusals with class-distinct reasons" do
    test "a delegated subagent worker (no source_trust) is refused :worker_context" do
      ctx = %{subagent_depth: 1, conversation_key: @chat_key, reply_fn: fn _ -> :ok end}
      assert {:error, :worker_context} = Authorization.authorize("codex_run", ctx)
    end

    test "a guest is refused :guest_context" do
      ctx = %{
        source_trust: :guest,
        subagent_depth: 0,
        reply_fn: fn _ -> :ok end,
        conversation_key: @chat_key
      }

      assert {:error, :guest_context} = Authorization.authorize("codex_run", ctx)
    end

    test "an operator turn with no reply surface (unattended/background) is refused :unattended" do
      ctx = %{source_trust: :operator, subagent_depth: 0, conversation_key: @chat_key}
      assert {:error, :unattended} = Authorization.authorize("codex_run", ctx)
    end

    test "an operator subagent (depth > 0) is not attended" do
      ctx = %{
        source_trust: :operator,
        subagent_depth: 1,
        reply_fn: fn _ -> :ok end,
        conversation_key: @chat_key
      }

      assert {:error, :unattended} = Authorization.authorize("codex_run", ctx)
    end
  end

  # --- Scheduled: raw job-row allowlist (gate 2) --------------------------

  describe "scheduled context reads the raw job allowlist" do
    test "a plain operator cron with no allowlist is refused :cron_not_allowlisted" do
      assert {:error, :cron_not_allowlisted} =
               Authorization.authorize("codex_run", scheduled(EmptyAllowlistRegistry))
    end

    test "a nil (unnarrowed) allowlist is not an authorization" do
      assert {:error, :cron_not_allowlisted} =
               Authorization.authorize("codex_run", scheduled(NilAllowlistRegistry))
    end

    test "an explicitly allowlisted job passes" do
      assert :ok = Authorization.authorize("codex_run", scheduled(AllowlistedRegistry))
    end

    test "a job allowlisted for a DIFFERENT harness tool is refused for this one" do
      assert {:error, :cron_not_allowlisted} =
               Authorization.authorize("claude_code_run", scheduled(AllowlistedRegistry))
    end

    test "a job allowlisting the cloud tools authorizes each of them" do
      assert :ok =
               Authorization.authorize("codex_cloud_run", scheduled(CloudAllowlistedRegistry))

      assert :ok =
               Authorization.authorize(
                 "stop_tracking_coding_run",
                 scheduled(CloudAllowlistedRegistry)
               )
    end

    test "a cloud tool not in the job allowlist is refused :cron_not_allowlisted" do
      assert {:error, :cron_not_allowlisted} =
               Authorization.authorize("codex_cloud_run", scheduled(AllowlistedRegistry))
    end

    test "a scheduled context missing its job id is refused :missing_job_id" do
      ctx = %{source_trust: :operator, conversation_key: @scheduled_key}
      assert {:error, :missing_job_id} = Authorization.authorize("codex_run", ctx)
    end

    test "a job lookup failure surfaces honestly, not as an allow" do
      assert {:error, {:job_lookup_failed, :not_found}} =
               Authorization.authorize("codex_run", scheduled(MissingJobRegistry))
    end

    test "a delegated worker inside an allowlisted job cannot ride the scheduled gate" do
      # A subagent fanned out inside a cron job inherits the scheduled key + job_id
      # (source_trust stripped, depth bumped). Even with the job allowlisting the
      # tool, the depth guard refuses it as a worker — never :ok.
      worker = %{
        subagent_depth: 1,
        conversation_key: @scheduled_key,
        job_id: "job_x",
        jobs_registry: AllowlistedRegistry,
        memory_repo: :unused
      }

      assert {:error, :worker_context} = Authorization.authorize("codex_run", worker)
    end
  end

  # --- Helpers ------------------------------------------------------------

  defp attended_operator do
    %{
      source_trust: :operator,
      subagent_depth: 0,
      reply_fn: fn _text -> :ok end,
      conversation_key: @chat_key
    }
  end

  defp scheduled(registry) do
    %{
      source_trust: :operator,
      conversation_key: @scheduled_key,
      job_id: "job_x",
      jobs_registry: registry,
      memory_repo: :unused
    }
  end
end
