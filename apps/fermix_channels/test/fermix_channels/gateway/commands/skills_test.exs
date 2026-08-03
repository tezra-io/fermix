defmodule FermixChannels.Gateway.Commands.SkillsTest do
  # async: false — flips the global skill_curation/memory config gates.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias FermixChannels.Gateway.Authorization
  alias FermixChannels.Gateway.Commands
  alias FermixChannels.Gateway.Message
  alias FermixCore.Memory.Repo
  alias FermixCore.SkillCuration.Proposals

  defmodule MinerStub do
    def chat(_messages, [], _opts) do
      {:ok,
       %{
         content: Jason.encode!(%{"cycle_summary" => "window summary", "candidates" => []}),
         tool_calls: [],
         usage: %{},
         model: "stub-model"
       }}
    end
  end

  defmodule DraftStub do
    def chat(_messages, [], opts) do
      {:ok,
       %{
         content:
           Jason.encode!(%{
             "description" => "Chase unpaid invoices.",
             "body_md" => "# Steps\n\nChase them."
           }),
         tool_calls: [],
         usage: %{},
         model: Keyword.get(opts, :model, "stub-model")
       }}
    end
  end

  setup do
    suffix = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-skills-cmd-#{suffix}.db")
    repo = :"skills_cmd_repo_#{suffix}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    skills_root = Path.join(System.tmp_dir!(), "fermix-skills-cmd-root-#{suffix}")
    File.mkdir_p!(skills_root)

    # The command gates on the global config; tests establish their own
    # baseline (enabled, telegram owner configured) and restore the prior env.
    skill_curation = Application.get_env(:fermix_core, :skill_curation, [])
    memory = Application.get_env(:fermix_core, :memory, [])
    telegram = Application.get_env(:fermix_channels, :telegram, [])
    Application.put_env(:fermix_core, :skill_curation, enabled: true)
    Application.put_env(:fermix_core, :memory, Keyword.put(memory, :enabled, true))
    Application.put_env(:fermix_channels, :telegram, owner_user_id: "owner-1")

    on_exit(fn ->
      Application.put_env(:fermix_core, :skill_curation, skill_curation)
      Application.put_env(:fermix_core, :memory, memory)
      Application.put_env(:fermix_channels, :telegram, telegram)
      FermixTestSupport.SafeRm.rm_rf!(skills_root)

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo, skills_root: skills_root}
  end

  defp dispatch(content, ctx, opts \\ []) do
    test_pid = self()

    context = %{
      conversation_key: {"telegram", "chat-1", :root},
      authorization: authorization(Keyword.get(opts, :role, :operator)),
      skill_curation_opts: [
        repo: ctx.repo,
        skills_root: ctx.skills_root,
        main_agent_server: nil,
        adapter: Keyword.get(opts, :adapter, DraftStub),
        configured_owners: %{"telegram" => "owner-1"},
        jobs_config: []
      ]
    }

    message = message(content, opts)
    reply_fn = fn {:text, text} -> send(test_pid, {:skills_reply, text}) end
    Commands.dispatch(Commands.parse(message), reply_fn, context)
  end

  defp authorization(:operator), do: %Authorization{role: :operator, trust: :operator}
  defp authorization(:guest), do: %Authorization{role: :guest, trust: :guest}

  defp message(content, opts) do
    Message.new!(%{
      id: "msg-#{System.unique_integer([:positive])}",
      content: content,
      sender: "alice",
      channel: Keyword.get(opts, :channel, "telegram"),
      chat_id: Keyword.get(opts, :chat_id, "chat-1"),
      reply_target: Keyword.get(opts, :chat_id, "chat-1"),
      metadata: %{user_id: "owner-1"}
    })
  end

  defp insert_proposal!(ctx, overrides) do
    defaults = %{
      cycle_session_id: "skill_curation:test",
      kind: "new_skill",
      skill_name: "invoice_chase",
      task_signature: "chase unpaid invoices",
      summary: "Skill proposal: invoice_chase",
      outline_json: Jason.encode!(["trigger"]),
      evidence_json: Jason.encode!([%{"ref" => "m1", "quote" => "chase"}]),
      status: "pending",
      created_at: ~U[2026-07-01 10:00:00Z]
    }

    {:ok, row} = Proposals.insert(Map.merge(defaults, overrides), repo: ctx.repo)
    row
  end

  test "every subcommand is operator-only", ctx do
    for content <- ["/skills proposals", "/skills approve ABC23456", "/skills deny ABC23456"] do
      assert {:error, :unauthorized} = dispatch(content, ctx, role: :guest)
      assert_receive {:skills_reply, reply}
      assert reply =~ "owner permissions"
    end
  end

  test "bare /skills prints usage", ctx do
    assert :ok = dispatch("/skills", ctx)
    assert_receive {:skills_reply, reply}
    assert reply =~ "/skills review"
    assert reply =~ "/skills restore"
  end

  test "approving a new-skill proposal acks drafting and delivers the outcome", ctx do
    row = insert_proposal!(ctx, %{})

    assert :ok = dispatch("/skills approve #{row.token}", ctx)

    assert_receive {:skills_reply, ack}
    assert ack =~ "drafting invoice_chase"

    assert_receive {:skills_reply, outcome}, 2_000
    assert outcome =~ "invoice_chase is live"
    assert outcome =~ "/skills restore invoice_chase"

    assert File.exists?(Path.join([ctx.skills_root, "invoice_chase", "SKILL.md"]))
    assert {:ok, ledger} = Repo.get_skill_curation_ledger("invoice_chase", server: ctx.repo)
    assert ledger.status == "active"
  end

  test "tokens are single-use through the command path", ctx do
    row = insert_proposal!(ctx, %{})

    assert :ok = dispatch("/skills approve #{row.token}", ctx)
    assert_receive {:skills_reply, _ack}
    assert_receive {:skills_reply, _outcome}, 2_000

    assert :ok = dispatch("/skills approve #{row.token}", ctx)
    assert_receive {:skills_reply, refusal}
    assert refusal =~ "no longer pending"
  end

  test "a button-delivered proposal is origin-checked; listing re-stamps it here", ctx do
    row = insert_proposal!(ctx, %{})

    {:ok, _} =
      Proposals.stamp_origin(row.token, "telegram", "chat-2", ~U[2026-07-01 11:00:00Z],
        repo: ctx.repo
      )

    assert :ok = dispatch("/skills deny #{row.token}", ctx, chat_id: "chat-1")
    assert_receive {:skills_reply, refusal}
    assert refusal =~ "different chat"

    # The token survived the refused action.
    assert {:ok, alive} = Repo.get_skill_curation_proposal(row.token, server: ctx.repo)
    assert alive.status == "pending"

    # Listing from the owner DM re-stamps origin there (§6.7), so the action
    # now works from the listing conversation.
    assert :ok = dispatch("/skills proposals", ctx, chat_id: "owner-1")
    assert_receive {:skills_reply, _listing}

    assert :ok = dispatch("/skills deny #{row.token}", ctx, chat_id: "owner-1")
    assert_receive {:skills_reply, denied}
    assert denied =~ "won't suggest that again"
    assert denied =~ "/skills unpark #{row.token}"
  end

  test "deny then unpark clears the disposition", ctx do
    row = insert_proposal!(ctx, %{})

    assert :ok = dispatch("/skills deny #{row.token}", ctx)
    assert_receive {:skills_reply, _denied}

    assert :ok = dispatch("/skills unpark #{row.token}", ctx)
    assert_receive {:skills_reply, unparked}
    assert unparked =~ "may re-propose once"
  end

  test "approving an archive proposal archives synchronously", ctx do
    File.mkdir_p!(Path.join(ctx.skills_root, "dusty"))

    File.write!(
      Path.join([ctx.skills_root, "dusty", "SKILL.md"]),
      "---\nname: dusty\ndescription: d\n---\n\nbody\n"
    )

    {:ok, _} =
      Repo.insert_skill_curation_ledger(
        %{
          skill_name: "dusty",
          task_signature: "dusty sig",
          status: "active",
          created_proposal_id: 1,
          created_at: ~U[2026-06-01 10:00:00Z]
        },
        server: ctx.repo
      )

    row =
      insert_proposal!(ctx, %{
        kind: "archive_skill",
        skill_name: "dusty",
        task_signature: "archive:dusty"
      })

    assert :ok = dispatch("/skills approve #{row.token}", ctx)
    assert_receive {:skills_reply, reply}
    assert reply =~ "Archived dusty"
    assert reply =~ "/skills restore dusty"
    refute File.exists?(Path.join(ctx.skills_root, "dusty"))
  end

  test "proposals lists actionable, declined, and parked entries", ctx do
    insert_proposal!(ctx, %{})
    declined = insert_proposal!(ctx, %{task_signature: "declined sig", skill_name: "declined_x"})
    {:ok, _} = Proposals.decline(declined.token, ~U[2026-07-02 10:00:00Z], repo: ctx.repo)

    # Two aged-out proposals for one signature -> parked.
    for _round <- 1..2 do
      insert_proposal!(ctx, %{
        task_signature: "buried sig",
        skill_name: "buried_x",
        created_at: ~U[2026-05-01 10:00:00Z]
      })

      {:ok, _} = Proposals.sweep(~U[2026-07-01 10:00:00Z], 15, repo: ctx.repo)
    end

    assert :ok = dispatch("/skills proposals", ctx, chat_id: "owner-1")
    assert_receive {:skills_reply, reply}
    assert reply =~ "Actionable:"
    assert reply =~ "chase unpaid invoices"
    assert reply =~ "Declined:"
    assert reply =~ "declined sig"
    assert reply =~ "Parked (ignored twice):"
    assert reply =~ "buried sig (expired 2x"
  end

  test "review acks immediately and delivers the cycle outcome in the background", ctx do
    assert :ok = dispatch("/skills review", ctx, chat_id: "owner-1", adapter: MinerStub)

    assert_receive {:skills_reply, ack}
    assert ack =~ "results will land here"

    assert_receive {:skills_reply, outcome}, 2_000
    assert outcome =~ "Nothing new"
  end

  test "content-bearing subcommands refuse non-private conversations", ctx do
    insert_proposal!(ctx, %{})

    for content <- ["/skills proposals", "/skills review"] do
      assert :ok = dispatch(content, ctx, chat_id: "group-77")
      assert_receive {:skills_reply, reply}
      assert reply =~ "private history"
    end
  end

  test "list shows curation-managed skills with usage", ctx do
    {:ok, _} =
      Repo.insert_skill_curation_ledger(
        %{
          skill_name: "rubric_reply_judge",
          task_signature: "judge replies",
          status: "active",
          created_proposal_id: 1,
          created_at: ~U[2026-08-01 10:00:00Z]
        },
        server: ctx.repo
      )

    assert :ok =
             Repo.record_skill_usage("rubric_reply_judge", :run, ~U[2026-08-02 10:00:00Z],
               server: ctx.repo
             )

    assert :ok = dispatch("/skills list", ctx, chat_id: "owner-1")
    assert_receive {:skills_reply, reply}
    assert reply =~ "Curation-managed skills:"
    assert reply =~ "rubric_reply_judge (active)"
    assert reply =~ "runs 1"
    assert reply =~ "created 2026-08-01"
  end

  test "list with no managed skills says so", ctx do
    assert :ok = dispatch("/skills list", ctx, chat_id: "owner-1")
    assert_receive {:skills_reply, reply}
    assert reply =~ "Curation manages no skills yet."
  end

  test "archive then restore round-trips a curation-made skill", ctx do
    File.mkdir_p!(Path.join(ctx.skills_root, "fresh_skill"))

    File.write!(
      Path.join([ctx.skills_root, "fresh_skill", "SKILL.md"]),
      "---\nname: fresh_skill\ndescription: d\n---\n\nbody\n"
    )

    {:ok, _} =
      Repo.insert_skill_curation_ledger(
        %{
          skill_name: "fresh_skill",
          task_signature: "fresh sig",
          status: "active",
          created_proposal_id: 1,
          created_at: ~U[2026-08-03 04:00:00Z]
        },
        server: ctx.repo
      )

    assert :ok = dispatch("/skills archive fresh_skill", ctx)
    assert_receive {:skills_reply, archived}
    assert archived =~ "Archived fresh_skill"
    assert archived =~ "/skills restore fresh_skill"
    refute File.exists?(Path.join(ctx.skills_root, "fresh_skill"))

    assert {:ok, ledger} = Repo.get_skill_curation_ledger("fresh_skill", server: ctx.repo)
    assert ledger.status == "archived"

    assert :ok = dispatch("/skills restore fresh_skill", ctx)
    assert_receive {:skills_reply, restored}
    assert restored =~ "Restored fresh_skill from the archive"
    assert File.exists?(Path.join([ctx.skills_root, "fresh_skill", "SKILL.md"]))
  end

  test "archive refuses hand-authored skills", ctx do
    assert :ok = dispatch("/skills archive hand_made", ctx)
    assert_receive {:skills_reply, reply}
    assert reply =~ "not curation-managed"
  end

  test "an unknown token replies loudly", ctx do
    assert :ok = dispatch("/skills approve ZZZZ9999", ctx)
    assert_receive {:skills_reply, reply}
    assert reply =~ "Unknown proposal token"
  end

  test "bare restore reports nothing to restore", ctx do
    assert :ok = dispatch("/skills restore", ctx)
    assert_receive {:skills_reply, reply}
    assert reply =~ "Nothing to restore"
  end

  test "disabled config blocks review and approve but never deny", ctx do
    Application.put_env(:fermix_core, :skill_curation, enabled: false)
    row = insert_proposal!(ctx, %{})

    assert :ok = dispatch("/skills review", ctx)
    assert_receive {:skills_reply, review_reply}
    assert review_reply =~ "disabled in config"

    assert :ok = dispatch("/skills approve #{row.token}", ctx)
    assert_receive {:skills_reply, approve_reply}
    assert approve_reply =~ "disabled in config"

    assert :ok = dispatch("/skills deny #{row.token}", ctx)
    assert_receive {:skills_reply, deny_reply}
    assert deny_reply =~ "won't suggest that again"
  end

  test "memory off names the dependency", ctx do
    memory = Application.get_env(:fermix_core, :memory, [])
    Application.put_env(:fermix_core, :memory, Keyword.put(memory, :enabled, false))

    assert :ok = dispatch("/skills review", ctx)
    assert_receive {:skills_reply, reply}
    assert reply =~ "requires memory persistence"
  end
end
