defmodule FermixCore.Memory.RepoXAssignmentsTest do
  # The `x_assignments` table (MILESTONE_63, priv/connect/PROTOCOL.md §6): one
  # row per Connect assignment, every transition a compare-and-set on its
  # status. Membership, never list equality, for the migration version.
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Repo

  @version 40
  @claimed ~U[2026-10-16 05:00:01.000000Z]
  @expires ~U[2026-10-16 05:15:00.000000Z]
  @deadline ~U[2026-10-16 05:01:30.000000Z]
  @later ~U[2026-10-16 05:01:00.000000Z]
  @sha String.duplicate("a", 64)
  @result_sha String.duplicate("b", 64)

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-x-assignments-#{unique}.db")
    repo = :"memory_repo_x_assignments_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo}
  end

  defp claim_attrs(id, overrides) do
    Map.merge(
      %{
        assignment_id: id,
        interaction_id: "ix_" <> id,
        tenant_id: "1234567890",
        instance_id: "ins_7f3c2a9e1b4d",
        requester_x_user_id: "1234567890",
        conversation_id: "1844999999999999990",
        request_sha256: @sha,
        jws: "aGVhZGVy.cGF5bG9hZA.c2ln",
        expires_at: @expires,
        claimed_at: @claimed
      },
      overrides
    )
  end

  defp claim!(repo, id, overrides \\ %{}) do
    assert {:ok, {:claimed, row}} =
             Repo.x_claim_assignment(claim_attrs(id, overrides), server: repo)

    row
  end

  defp start!(repo, id, attempt \\ 1) do
    grant = %{attempt: attempt, runner_epoch: "epoch-a", deadline_at: @deadline, now: @later}
    assert {:ok, row} = Repo.x_start_assignment(id, grant, server: repo)
    row
  end

  defp result(decision) do
    %{
      decision: decision,
      result_sha256: @result_sha,
      result_json: ~s({"t":"result","decision":"#{decision}"}),
      now: @later
    }
  end

  test "the migration is applied on a fresh database and reruns cleanly", %{repo: repo} do
    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert @version in versions

    assert :ok = Repo.migrate(server: repo)
    assert {:ok, again} = Repo.migration_versions(server: repo)
    assert length(again) == length(Enum.uniq(again))
  end

  test "a claim stores the assignment as accepted, decoded", %{repo: repo} do
    row = claim!(repo, "as_1")

    assert row.status == :accepted
    assert row.attempt == nil
    assert row.decision == nil
    assert row.expires_at == @expires
    assert row.claimed_at == @claimed
    assert row.receipt_sent_at == nil
    assert {:ok, ^row} = Repo.x_assignment("as_1", server: repo)
  end

  test "a duplicate claim stores nothing and answers the row as it stands", %{repo: repo} do
    first = claim!(repo, "as_dup")
    start!(repo, "as_dup")

    assert {:ok, {:duplicate, again}} =
             Repo.x_claim_assignment(
               claim_attrs("as_dup", %{jws: "b3RoZXI.b3RoZXI.b3RoZXI"}),
               server: repo
             )

    assert again.status == :running
    assert again.jws == first.jws
  end

  test "a claim with a bad value is refused before the writer", %{repo: repo} do
    assert {:error, {:invalid, :request_sha256, :not_a_sha256}} =
             Repo.x_claim_assignment(claim_attrs("as_bad", %{request_sha256: "nope"}),
               server: repo
             )

    assert {:error, {:invalid, :tenant_id, :not_a_string}} =
             Repo.x_claim_assignment(claim_attrs("as_bad", %{tenant_id: 1}), server: repo)

    assert {:error, :not_found} = Repo.x_assignment("as_bad", server: repo)
  end

  test "the receipt stamp is the first one", %{repo: repo} do
    claim!(repo, "as_receipt")
    assert {:ok, row} = Repo.x_mark_receipt_sent("as_receipt", @claimed, server: repo)
    assert row.receipt_sent_at == @claimed
    assert {:ok, row} = Repo.x_mark_receipt_sent("as_receipt", @later, server: repo)
    assert row.receipt_sent_at == @claimed
  end

  test "a start moves accepted to running once, with its attempt and epoch", %{repo: repo} do
    claim!(repo, "as_start")
    row = start!(repo, "as_start", 2)

    assert row.status == :running
    assert row.attempt == 2
    assert row.runner_epoch == "epoch-a"
    assert row.deadline_at == @deadline

    grant = %{attempt: 3, runner_epoch: "epoch-b", deadline_at: @deadline, now: @later}
    assert {:error, :not_found} = Repo.x_start_assignment("as_start", grant, server: repo)
  end

  test "a reply is staged only while running, and the last one wins", %{repo: repo} do
    claim!(repo, "as_stage")
    assert {:error, :not_found} = Repo.x_stage_reply("as_stage", "early", @later, server: repo)

    start!(repo, "as_stage")
    assert {:ok, _row} = Repo.x_stage_reply("as_stage", "first", @later, server: repo)
    assert {:ok, row} = Repo.x_stage_reply("as_stage", "second", @later, server: repo)
    assert row.reply_text == "second"

    assert {:ok, _row} =
             Repo.x_complete_assignment("as_stage", 1, result(:public_reply), server: repo)

    assert {:error, :not_found} = Repo.x_stage_reply("as_stage", "late", @later, server: repo)
  end

  test "completion settles the running attempt only, and once", %{repo: repo} do
    claim!(repo, "as_done")
    start!(repo, "as_done", 1)

    assert {:error, :not_found} =
             Repo.x_complete_assignment("as_done", 2, result(:no_reply), server: repo)

    assert {:ok, row} = Repo.x_complete_assignment("as_done", 1, result(:no_reply), server: repo)
    assert row.status == :completed
    assert row.decision == :no_reply
    assert row.result_sha256 == @result_sha

    assert {:error, :not_found} =
             Repo.x_complete_assignment("as_done", 1, result(:public_reply), server: repo)
  end

  test "a failure moves only the named status, with or without a result", %{repo: repo} do
    claim!(repo, "as_refused")

    refused = %{from: :running, reason: "start_refused:expired", result: nil, now: @later}
    assert {:error, :not_found} = Repo.x_fail_assignment("as_refused", refused, server: repo)

    assert {:ok, row} =
             Repo.x_fail_assignment("as_refused", %{refused | from: :accepted}, server: repo)

    assert row.status == :failed
    assert row.failure_reason == "start_refused:expired"
    assert row.result_json == nil

    claim!(repo, "as_died")
    start!(repo, "as_died")
    died = %{from: :running, reason: :deadline, result: Map.delete(result(:failed), :now)}

    assert {:ok, row} =
             Repo.x_fail_assignment("as_died", Map.put(died, :now, @later), server: repo)

    assert row.status == :failed
    assert row.decision == :failed
    assert row.failure_reason == "deadline"
    assert is_binary(row.result_json)
  end

  test "a cancel settles an accepted or running row and nothing settled", %{repo: repo} do
    cancellation = %{reason: "cancelled:operator", now: @later}

    claim!(repo, "as_c1")

    assert {:ok, %{status: :cancelled}} =
             Repo.x_cancel_assignment("as_c1", cancellation, server: repo)

    claim!(repo, "as_c2")
    start!(repo, "as_c2")

    assert {:ok, %{status: :cancelled}} =
             Repo.x_cancel_assignment("as_c2", cancellation, server: repo)

    claim!(repo, "as_c3")
    start!(repo, "as_c3")
    assert {:ok, _row} = Repo.x_complete_assignment("as_c3", 1, result(:no_reply), server: repo)
    assert {:error, :not_found} = Repo.x_cancel_assignment("as_c3", cancellation, server: repo)
  end

  test "the expiry sweep settles accepted rows past their expiry and nothing else", %{repo: repo} do
    claim!(repo, "as_old")
    claim!(repo, "as_fresh", %{expires_at: ~U[2026-10-16 06:00:00.000000Z]})
    claim!(repo, "as_running")
    start!(repo, "as_running")

    assert {:ok, ["as_old"]} = Repo.x_expire_assignments(~U[2026-10-16 05:20:00Z], server: repo)
    assert {:ok, %{status: :expired}} = Repo.x_assignment("as_old", server: repo)
    assert {:ok, %{status: :accepted}} = Repo.x_assignment("as_fresh", server: repo)
    assert {:ok, %{status: :running}} = Repo.x_assignment("as_running", server: repo)
    assert {:ok, []} = Repo.x_expire_assignments(~U[2026-10-16 05:20:00Z], server: repo)
  end

  test "an ack settles the attempt's result once", %{repo: repo} do
    claim!(repo, "as_ack")
    start!(repo, "as_ack")
    assert {:error, :not_found} = Repo.x_ack_result("as_ack", 1, @later, server: repo)

    assert {:ok, _row} = Repo.x_complete_assignment("as_ack", 1, result(:no_reply), server: repo)
    assert {:error, :not_found} = Repo.x_ack_result("as_ack", 2, @later, server: repo)
    assert {:ok, row} = Repo.x_ack_result("as_ack", 1, @later, server: repo)
    assert row.result_acked_at == @later
    assert {:error, :not_found} = Repo.x_ack_result("as_ack", 1, @later, server: repo)
  end

  test "a conflict keeps the row's record; any other refusal fails it", %{repo: repo} do
    claim!(repo, "as_conflict")
    start!(repo, "as_conflict")

    {:ok, _row} =
      Repo.x_complete_assignment("as_conflict", 1, result(:public_reply), server: repo)

    assert {:ok, row} = Repo.x_reject_result("as_conflict", 1, :conflict, @later, server: repo)
    assert row.status == :completed
    assert row.decision == :public_reply
    assert row.failure_reason == "result_rejected:conflict"
    assert row.result_acked_at == @later

    claim!(repo, "as_long")
    start!(repo, "as_long")
    {:ok, _row} = Repo.x_complete_assignment("as_long", 1, result(:public_reply), server: repo)

    assert {:ok, row} = Repo.x_reject_result("as_long", 1, :too_long, @later, server: repo)
    assert row.status == :failed
    assert row.failure_reason == "result_rejected:too_long"
  end

  test "recovery lists waiting, running and unanswered rows, oldest first", %{repo: repo} do
    claim!(repo, "as_wait", %{claimed_at: ~U[2026-10-16 05:00:01.000000Z]})
    claim!(repo, "as_run", %{claimed_at: ~U[2026-10-16 05:00:02.000000Z]})
    start!(repo, "as_run")
    claim!(repo, "as_owed", %{claimed_at: ~U[2026-10-16 05:00:03.000000Z]})
    start!(repo, "as_owed")
    {:ok, _row} = Repo.x_complete_assignment("as_owed", 1, result(:no_reply), server: repo)

    claim!(repo, "as_acked", %{claimed_at: ~U[2026-10-16 05:00:04.000000Z]})
    start!(repo, "as_acked")
    {:ok, _row} = Repo.x_complete_assignment("as_acked", 1, result(:no_reply), server: repo)
    {:ok, _row} = Repo.x_ack_result("as_acked", 1, @later, server: repo)

    claim!(repo, "as_gone", %{claimed_at: ~U[2026-10-16 05:00:05.000000Z]})

    {:ok, _row} =
      Repo.x_cancel_assignment("as_gone", %{reason: "cancelled:operator", now: @later},
        server: repo
      )

    assert {:ok, rows} = Repo.x_recoverable_assignments(server: repo)
    assert Enum.map(rows, & &1.assignment_id) == ["as_wait", "as_run", "as_owed"]
    assert Enum.map(rows, & &1.status) == [:accepted, :running, :completed]
  end
end
