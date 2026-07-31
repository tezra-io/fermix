defmodule FermixCore.Harness.MemoryWritebackTest do
  use ExUnit.Case, async: true

  alias FermixCore.Harness.MemoryWriteback
  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Scope

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-harness-writeback-#{unique}.db")
    repo = :"harness_writeback_repo_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo, agent_id: MemoryConfig.agent_id(), owner_id: MemoryConfig.owner_id()}
  end

  defp chat_row(overrides \\ %{}) do
    Map.merge(
      %{
        id: "hr_chat00000001",
        status: "completed",
        vendor: "codex",
        worktree_root: "/repo",
        origin_kind: "chat",
        parent_job_id: nil,
        platform: "telegram",
        destination: "chat-7",
        thread: nil
      },
      overrides
    )
  end

  defp selector(agent_id, owner_id, scope_type, scope_id) do
    %{
      agent_id: agent_id,
      owner_id: owner_id,
      scope_type: scope_type,
      scope_id: scope_id,
      key: "harness_latest",
      archived?: false
    }
  end

  test "writes an untrusted-provenance conversation record for a chat run", %{
    repo: repo,
    agent_id: agent_id,
    owner_id: owner_id
  } do
    assert :ok =
             MemoryWriteback.write(chat_row(), "Refactored the seam; gates green.", repo: repo)

    scope_id = Scope.conversation_scope_id("telegram", "chat-7", :root)

    assert {:ok, memory} =
             Repo.get_memory(selector(agent_id, owner_id, "conversation", scope_id), server: repo)

    assert memory.category == "harness_run_summary"
    assert memory.source_type == "coding_harness"
    assert memory.source_name == "codex"
    assert memory.value == "Refactored the seam; gates green."
    assert memory.confidence == 0.6
    assert memory.promote_target == "none"
    assert memory.session_id == "harness_hr_chat00000001"
    assert memory.run_id == "hr_chat00000001"
    assert memory.source_description =~ "run hr_chat00000001 in /repo"
  end

  test "carries the thread into the conversation scope id", %{
    repo: repo,
    agent_id: agent_id,
    owner_id: owner_id
  } do
    row = chat_row(%{thread: "88"})
    assert :ok = MemoryWriteback.write(row, "Done.", repo: repo)

    scope_id = Scope.conversation_scope_id("telegram", "chat-7", "88")

    assert {:ok, _memory} =
             Repo.get_memory(selector(agent_id, owner_id, "conversation", scope_id), server: repo)
  end

  test "writes under the parent job's memory scope for a scheduled run", %{repo: repo} do
    {:ok, job} =
      JobsRegistry.create_job(
        %{
          created_by_trust: "operator",
          name: "Nightly",
          description: "Nightly refactor.",
          schedule: "every 15 minutes",
          timezone: "UTC",
          task_prompt: "Refactor.",
          created_by_agent_id: "main",
          created_by_session_id: "telegram:chat-1:root",
          allowed_tools: ["codex_run"],
          capability_policy: ["exec"],
          delivery_mode: "none"
        },
        repo: repo,
        now: ~U[2026-07-20 14:00:00Z]
      )

    row =
      chat_row(%{
        id: "hr_sched00000001",
        origin_kind: "scheduled",
        parent_job_id: job.id,
        platform: nil,
        destination: nil
      })

    assert :ok = MemoryWriteback.write(row, "Scheduled summary.", repo: repo)

    assert {:ok, memory} =
             Repo.get_memory(
               selector("main", MemoryConfig.owner_id(), "job", job.memory_source_id),
               server: repo
             )

    assert memory.source_type == "coding_harness"
    assert memory.value == "Scheduled summary."
  end

  test "harness summary does not overwrite the job's own run summary under the same scope", %{
    repo: repo
  } do
    {:ok, job} =
      JobsRegistry.create_job(
        %{
          created_by_trust: "operator",
          name: "Nightly",
          description: "Nightly refactor.",
          schedule: "every 15 minutes",
          timezone: "UTC",
          task_prompt: "Refactor.",
          created_by_agent_id: "main",
          created_by_session_id: "telegram:chat-1:root",
          allowed_tools: ["codex_run"],
          capability_policy: ["exec"],
          delivery_mode: "none"
        },
        repo: repo,
        now: ~U[2026-07-20 14:00:00Z]
      )

    # The job writes its trusted (confidence 1.0) run summary under key "latest".
    {:ok, _} =
      Repo.upsert_memory(
        %{
          agent_id: "main",
          owner_id: MemoryConfig.owner_id(),
          scope_type: "job",
          scope_id: job.memory_source_id,
          category: "job_run_summary",
          key: "latest",
          value: "Job's own summary.",
          confidence: 1.0,
          promote_target: "none",
          source_type: "scheduled_job"
        },
        server: repo
      )

    row =
      chat_row(%{
        id: "hr_sched00000002",
        origin_kind: "scheduled",
        parent_job_id: job.id,
        platform: nil,
        destination: nil
      })

    assert :ok = MemoryWriteback.write(row, "Harness summary.", repo: repo)

    # Both records coexist: the job's confidence-1.0 summary is untouched, and the
    # harness's confidence-0.6 summary lives under its own key.
    job_selector = %{
      agent_id: "main",
      owner_id: MemoryConfig.owner_id(),
      scope_type: "job",
      scope_id: job.memory_source_id,
      key: "latest",
      archived?: false
    }

    assert {:ok, job_memory} = Repo.get_memory(job_selector, server: repo)
    assert job_memory.value == "Job's own summary."
    assert job_memory.confidence == 1.0
    assert job_memory.category == "job_run_summary"

    assert {:ok, harness_memory} =
             Repo.get_memory(
               selector("main", MemoryConfig.owner_id(), "job", job.memory_source_id),
               server: repo
             )

    assert harness_memory.value == "Harness summary."
    assert harness_memory.category == "harness_run_summary"
  end

  test "skips a non-completed run", %{repo: repo, agent_id: agent_id, owner_id: owner_id} do
    row = chat_row(%{status: "failed"})
    assert :ok = MemoryWriteback.write(row, "Should not be stored.", repo: repo)

    scope_id = Scope.conversation_scope_id("telegram", "chat-7", :root)

    assert {:error, :not_found} =
             Repo.get_memory(selector(agent_id, owner_id, "conversation", scope_id), server: repo)
  end

  test "skips an empty result", %{repo: repo, agent_id: agent_id, owner_id: owner_id} do
    assert :ok = MemoryWriteback.write(chat_row(), "   ", repo: repo)

    scope_id = Scope.conversation_scope_id("telegram", "chat-7", :root)

    assert {:error, :not_found} =
             Repo.get_memory(selector(agent_id, owner_id, "conversation", scope_id), server: repo)
  end

  test "is best-effort when the repo is disabled" do
    disabled = :"harness_writeback_disabled_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: disabled,
      start: {Repo, :start_link, [[name: disabled, enabled: false, database_path: ":memory:"]]}
    })

    assert :ok = MemoryWriteback.write(chat_row(), "Anything.", repo: disabled)
  end
end
