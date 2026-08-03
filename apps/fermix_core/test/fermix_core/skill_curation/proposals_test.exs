defmodule FermixCore.SkillCuration.ProposalsTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Repo
  alias FermixCore.SkillCuration.Proposals

  setup do
    suffix = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-scp-#{suffix}.db")
    repo = :"skill_curation_proposals_repo_#{suffix}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo}
  end

  defp insert!(repo, attrs) do
    defaults = %{
      cycle_session_id: "skill_curation:test",
      kind: "new_skill",
      skill_name: "some_skill",
      task_signature: "some signature",
      summary: "proposal text",
      status: "pending",
      created_at: ~U[2026-07-01 10:00:00Z]
    }

    {:ok, row} = Proposals.insert(Map.merge(defaults, attrs), repo: repo)
    row
  end

  test "generate_token mints 8-char Base32 tokens" do
    token = Proposals.generate_token()
    assert String.length(token) == 8
    assert token =~ ~r/^[A-Z2-7]{8}$/
  end

  test "insert mints a token when none is given", %{repo: repo} do
    row = insert!(repo, %{})
    assert row.token =~ ~r/^[A-Z2-7]{8}$/
  end

  test "approve and decline are single-use across pending and deferred", %{repo: repo} do
    pending = insert!(repo, %{task_signature: "sig-a"})
    deferred = insert!(repo, %{task_signature: "sig-b", status: "deferred"})

    now = ~U[2026-07-02 10:00:00Z]

    assert {:ok, approved} = Proposals.approve(pending.token, now, repo: repo)
    assert approved.status == "approved"

    # Double-approve race: the second take refuses with the actual status.
    assert {:error, {:invalid_status, "approved"}} =
             Proposals.approve(pending.token, now, repo: repo)

    # A deferred proposal dug out of /skills proposals is directly deniable
    # and approvable — the cap bounds delivery, not owner actions.
    assert {:ok, declined} = Proposals.decline(deferred.token, now, repo: repo)
    assert declined.status == "declined"

    assert {:error, :not_found} = Proposals.approve("NOPE1234", now, repo: repo)
  end

  test "a signature expired twice is parked; unpark clears it once", %{repo: repo} do
    signature = "chase unpaid invoices"
    now = ~U[2026-08-01 10:00:00Z]

    # Two proposals for the same signature, both aged out by sweeps.
    insert!(repo, %{task_signature: signature, created_at: ~U[2026-06-01 10:00:00Z]})
    assert {:ok, _} = Proposals.sweep(now, 15, repo: repo)
    insert!(repo, %{task_signature: signature, created_at: ~U[2026-07-01 10:00:00Z]})
    assert {:ok, _} = Proposals.sweep(now, 15, repo: repo)

    assert {:ok, dispositions} = Proposals.dispositions(repo: repo)
    assert dispositions[signature].expired_count == 2
    assert dispositions[signature].parked

    # Unpark by signature clears both rows from the derivation while their
    # status survives for audit.
    assert {:ok, 2} = Proposals.unpark(%{task_signature: signature}, now, repo: repo)

    assert {:ok, cleared} = Proposals.dispositions(repo: repo)
    refute Map.has_key?(cleared, signature)

    assert {:ok, audit_rows} =
             Repo.list_skill_curation_proposals(
               %{task_signature: signature, include_cleared: true},
               server: repo
             )

    assert Enum.map(audit_rows, & &1.status) == ["expired", "expired"]
    assert Enum.all?(audit_rows, & &1.disposition_cleared_at)
  end

  test "dispositions fold declined, open, and created states", %{repo: repo} do
    declined = insert!(repo, %{task_signature: "sig-declined"})
    assert {:ok, _} = Proposals.decline(declined.token, ~U[2026-07-02 10:00:00Z], repo: repo)

    insert!(repo, %{task_signature: "sig-open"})
    insert!(repo, %{task_signature: "sig-deferred", status: "deferred"})

    {:ok, _ledger} =
      Repo.insert_skill_curation_ledger(
        %{
          skill_name: "made_skill",
          task_signature: "sig-created",
          status: "active",
          created_proposal_id: 1,
          created_at: ~U[2026-06-01 10:00:00Z]
        },
        server: repo
      )

    assert {:ok, dispositions} = Proposals.dispositions(repo: repo)
    assert dispositions["sig-declined"].declined
    assert dispositions["sig-open"].open
    assert dispositions["sig-deferred"].open
    assert dispositions["sig-created"].created.skill_name == "made_skill"
    refute dispositions["sig-created"].open
  end

  test "deferred proposals deliver first and expire after two missed cycles", %{repo: repo} do
    deferred = insert!(repo, %{task_signature: "sig-deferred", status: "deferred"})

    assert {:ok, [row]} = Proposals.deliverable_deferred(repo: repo)
    assert row.token == deferred.token

    assert {:ok, delivered} =
             Proposals.deliver_deferred(deferred.token, ~U[2026-07-02 10:00:00Z], repo: repo)

    assert delivered.status == "pending"
    # Delivery is not an owner action: no actioned_at stamp.
    assert delivered.actioned_at == nil

    # A deferred proposal never delivered survives exactly two sweeps.
    survivor = insert!(repo, %{task_signature: "sig-survivor", status: "deferred"})
    now = ~U[2026-08-01 10:00:00Z]
    assert {:ok, _} = Proposals.sweep(now, 15, repo: repo)
    assert {:ok, _} = Proposals.sweep(now, 15, repo: repo)
    assert {:ok, mid} = Repo.get_skill_curation_proposal(survivor.token, server: repo)
    assert mid.status == "deferred"

    assert {:ok, %{expired_deferred: 1}} = Proposals.sweep(now, 15, repo: repo)
    assert {:ok, aged} = Repo.get_skill_curation_proposal(survivor.token, server: repo)
    assert aged.status == "expired"
  end

  test "stamp_origin records the delivery target without consuming the token", %{repo: repo} do
    row = insert!(repo, %{})

    assert {:ok, stamped} =
             Proposals.stamp_origin(row.token, "telegram", "42", ~U[2026-07-01 11:00:00Z],
               repo: repo
             )

    assert stamped.status == "pending"
    assert stamped.origin_channel == "telegram"
    assert stamped.origin_chat_id == "42"

    assert {:ok, approved} = Proposals.approve(row.token, ~U[2026-07-01 12:00:00Z], repo: repo)
    assert approved.status == "approved"
  end

  test "archive proposals respect the cool-down and open-proposal block", %{repo: repo} do
    now = ~U[2026-08-01 10:00:00Z]

    assert {:ok, false} = Proposals.archive_proposal_blocked?("dusty_skill", now, repo: repo)

    open = insert!(repo, %{kind: "archive_skill", skill_name: "dusty_skill"})
    assert {:ok, true} = Proposals.archive_proposal_blocked?("dusty_skill", now, repo: repo)

    # Declined recently -> still blocked (60-day cool-down)...
    assert {:ok, _} = Proposals.decline(open.token, ~U[2026-07-30 10:00:00Z], repo: repo)
    assert {:ok, true} = Proposals.archive_proposal_blocked?("dusty_skill", now, repo: repo)

    # ...but not after the window has passed.
    assert {:ok, false} =
             Proposals.archive_proposal_blocked?("dusty_skill", ~U[2026-10-01 10:00:00Z],
               repo: repo
             )
  end

  test "a failed creation moves approved to failed", %{repo: repo} do
    row = insert!(repo, %{})
    now = ~U[2026-07-02 10:00:00Z]

    assert {:ok, _} = Proposals.approve(row.token, now, repo: repo)
    assert {:ok, failed} = Proposals.fail(row.token, now, repo: repo)
    assert failed.status == "failed"
  end

  test "a failed creation never buries the signature", %{repo: repo} do
    row = insert!(repo, %{task_signature: "transient failure sig"})
    now = ~U[2026-07-02 10:00:00Z]

    assert {:ok, _} = Proposals.approve(row.token, now, repo: repo)
    assert {:ok, _} = Proposals.fail(row.token, now, repo: repo)

    # A transient drafting failure is not an owner answer: the signature
    # carries no disposition and the next cycle may re-propose it.
    assert {:ok, dispositions} = Proposals.dispositions(repo: repo)
    refute Map.has_key?(dispositions, "transient failure sig")
  end
end
