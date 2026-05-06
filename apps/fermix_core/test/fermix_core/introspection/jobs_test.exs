defmodule FermixCore.Introspection.JobsTest do
  use ExUnit.Case, async: true

  alias FermixCore.Introspection.Jobs

  test "returns display-safe scheduled job rows and counts" do
    jobs = [
      %{
        id: "daily_digest",
        name: "Daily Digest",
        description: "Summarizes the morning state.",
        schedule_kind: "interval",
        schedule_expr: "every 15 minutes",
        next_run_at: ~U[2026-05-05 12:00:00Z],
        task_prompt: "include private operator detail",
        state: "scheduled",
        enabled?: true,
        last_run_at: ~U[2026-05-05 11:45:00Z],
        last_status: "ok",
        last_error: nil,
        delivery_mode: "origin",
        memory_source_id: "job:daily_digest",
        created_by_agent_id: "main"
      },
      %{
        id: "paused_digest",
        name: "Paused Digest",
        description: nil,
        schedule_kind: "cron",
        schedule_expr: "0 9 * * *",
        next_run_at: nil,
        task_prompt: "private",
        state: "paused",
        enabled?: false,
        last_run_at: nil,
        last_status: nil,
        last_error: nil,
        delivery_mode: "none",
        memory_source_id: "job:paused_digest",
        created_by_agent_id: "main"
      }
    ]

    assert {:ok, snapshot} = Jobs.snapshot(jobs: jobs)

    assert snapshot.status == :ready
    assert snapshot.error == nil
    assert snapshot.counts == %{disabled: 1, paused: 1, running: 0, scheduled: 1, total: 2}

    assert [%{id: "daily_digest"} = row, %{id: "paused_digest"}] = snapshot.jobs
    assert row.name == "Daily Digest"
    assert row.state == "scheduled"
    assert row.enabled? == true
    assert row.next_run_at == ~U[2026-05-05 12:00:00Z]
    refute Map.has_key?(row, :task_prompt)
  end

  test "marks job list unavailable when the registry cannot be read" do
    assert {:ok, snapshot} = Jobs.snapshot(jobs: {:error, :disabled})

    assert snapshot.status == :unavailable
    assert snapshot.error == ":disabled"
    assert snapshot.jobs == []
    assert snapshot.counts.total == 0
  end
end
