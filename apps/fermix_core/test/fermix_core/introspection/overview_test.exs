defmodule FermixCore.Introspection.OverviewTest do
  use ExUnit.Case, async: false

  alias FermixCore.Introspection.Overview
  alias FermixCore.Setup.ConfigStore

  setup do
    previous_home = System.get_env("FERMIX_HOME")
    previous_agent = Application.get_env(:fermix_core, :agent)
    previous_providers = Application.get_env(:fermix_core, :providers)

    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-overview-#{System.unique_integer([:positive])}")

    System.put_env("FERMIX_HOME", tmp_home)

    Application.put_env(:fermix_core, :agent, provider: :openai_codex)

    Application.put_env(:fermix_core, :providers,
      openai_codex: [default_model: "gpt-5.5", reasoning_effort: :high]
    )

    on_exit(fn ->
      restore_env("FERMIX_HOME", previous_home)
      restore_app_env(:fermix_core, :agent, previous_agent)
      restore_app_env(:fermix_core, :providers, previous_providers)
      File.rm_rf!(tmp_home)
    end)

    %{tmp_home: tmp_home}
  end

  test "builds a dashboard-safe overview from injected runtime snapshots", %{tmp_home: tmp_home} do
    health = %{
      status: :ready,
      failures: [],
      channels: [%{name: "telegram", status: :ready, enabled: true, mode: :webhook}],
      memory: %{conversation_store: :ready, store: :ready}
    }

    main_agent = %{
      status: :idle,
      active_conversations: 0,
      pending_conversations: 0
    }

    workers = [
      %{name: "research", role: :worker, status: :running, session_id: "s1", parent: "main"}
    ]

    capabilities = %{
      counts: %{builtin: 2, skill: 1, mcp: 0, total: 3},
      capabilities: []
    }

    jobs = [
      %{id: "job-1", state: "scheduled", next_run_at: ~U[2026-05-05 12:00:00Z]},
      %{id: "job-2", state: "paused", next_run_at: nil}
    ]

    assert {:ok, snapshot} =
             Overview.snapshot(
               health_report: health,
               main_agent_status: main_agent,
               skill_workers: workers,
               capabilities_snapshot: capabilities,
               jobs: jobs,
               running_job_runs: [%{id: "run-1"}],
               failed_job_runs: [%{id: "run-2"}],
               daemon: %{status: :running, pid: "123", uptime_ms: 1_000}
             )

    assert snapshot.readiness == %{status: :ready, failures: []}
    assert snapshot.daemon == %{status: :running, pid: "123", uptime_ms: 1_000}
    assert snapshot.provider.active == :openai_codex
    assert snapshot.provider.model == "gpt-5.5"
    assert snapshot.channels == health.channels
    assert snapshot.jobs.scheduled == 1
    assert snapshot.jobs.running == 1
    assert snapshot.jobs.paused == 1
    assert snapshot.jobs.failed_recent == 1
    assert snapshot.jobs.status == :ready
    assert snapshot.jobs.error == nil
    assert snapshot.agents.main.health == :online
    assert snapshot.agents.main.activity == :idle
    assert snapshot.agents.main.status == :idle
    assert snapshot.agents.skill_workers == 1
    assert snapshot.agents.running_skill_workers == 1
    assert snapshot.capabilities == capabilities.counts
    assert snapshot.paths.home == tmp_home
    assert snapshot.paths.config == ConfigStore.path()
  end

  test "marks job status unavailable when job reads fail" do
    assert {:ok, snapshot} =
             Overview.snapshot(
               health_report: %{status: :ready, failures: [], channels: [], memory: %{}},
               main_agent_status: %{status: :idle},
               skill_workers: [],
               capabilities_snapshot: %{counts: %{builtin: 0, skill: 0, mcp: 0, total: 0}},
               jobs: {:error, :missing_job_table},
               running_job_runs: [],
               failed_job_runs: []
             )

    assert snapshot.jobs.scheduled == 0
    assert snapshot.jobs.status == :unavailable
    assert snapshot.jobs.error == ":missing_job_table"
  end

  test "propagates agent snapshot failures" do
    assert {:error, {:main_agent_unavailable, reason}} =
             Overview.snapshot(
               health_report: %{status: :ready, failures: [], channels: [], memory: %{}},
               main_agent: :missing_main_agent,
               capabilities_snapshot: %{counts: %{builtin: 0, skill: 0, mcp: 0, total: 0}},
               jobs: [],
               running_job_runs: [],
               failed_job_runs: []
             )

    assert reason != nil
  end

  test "propagates capability snapshot failures" do
    assert {:error, :registry_down} =
             Overview.snapshot(
               health_report: %{status: :ready, failures: [], channels: [], memory: %{}},
               main_agent_status: %{status: :idle},
               skill_workers: [],
               capabilities_snapshot: {:error, :registry_down},
               jobs: [],
               running_job_runs: [],
               failed_job_runs: []
             )
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end
