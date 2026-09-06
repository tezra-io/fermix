defmodule FermixCore.SkillCurationTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Repo
  alias FermixCore.SkillCuration
  alias FermixCore.SkillCuration.Proposals

  @now ~U[2026-07-31 12:00:00Z]
  @owners %{"telegram" => "owner-1"}

  defmodule MinerStub do
    def chat(messages, [], opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:miner_call, messages})

      case Keyword.fetch!(opts, :reply) do
        :raise -> raise "miner boom"
        {:error, reason} -> {:error, reason}
        content -> {:ok, %{content: content, tool_calls: [], usage: %{}, model: "stub"}}
      end
    end
  end

  defmodule ChannelStub do
    # Send opts cannot thread a test pid through the cycle's Task boundary, so
    # sends are recorded in a module-named Agent (tests in a module run
    # serially; start_recorder! is per-test via start_supervised).
    @recorder :skill_curation_test_channel_recorder

    def recorder_spec do
      %{id: @recorder, start: {Agent, :start_link, [fn -> [] end, [name: @recorder]]}}
    end

    def sent, do: @recorder |> Agent.get(& &1) |> Enum.reverse()

    def send_message(destination, text, _opts) do
      Agent.update(@recorder, &[{:message, destination, text} | &1])
      :ok
    end
  end

  defmodule ButtonChannelStub do
    def send_message(destination, text, _opts) do
      Agent.update(:skill_curation_test_channel_recorder, &[{:message, destination, text} | &1])
      :ok
    end

    def send_proposal(target, text, token) do
      Agent.update(
        :skill_curation_test_channel_recorder,
        &[{:proposal, target, text, token} | &1]
      )

      :ok
    end
  end

  setup do
    suffix = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-skill-curation-#{suffix}.db")
    repo = :"skill_curation_repo_#{suffix}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo}
  end

  defp insert_message!(repo, overrides) do
    defaults = %{
      agent_id: "main",
      owner_id: "default",
      channel: "telegram",
      chat_id: "owner-1",
      thread_scope: "root",
      sender: "display-name",
      role: "user",
      kind: "chat_message",
      content: "chase the unpaid invoices again",
      metadata: %{"user_id" => "owner-1"},
      created_at: ~U[2026-07-20 10:00:00Z]
    }

    {:ok, row} = Repo.insert_message(Map.merge(defaults, overrides), server: repo)
    row
  end

  defp assemble!(repo, opts \\ []) do
    {:ok, history} =
      SkillCuration.assemble_history(
        @now,
        Keyword.merge([repo: repo, configured_owners: @owners], opts)
      )

    history
  end

  describe "assemble_history/2 owner resolution" do
    test "keeps owner-id rows and local-channel rows", %{repo: repo} do
      insert_message!(repo, %{content: "owner turn"})

      insert_message!(repo, %{
        channel: "cli",
        chat_id: "local",
        metadata: nil,
        content: "cli turn"
      })

      history = assemble!(repo)

      assert Enum.map(history.entries, & &1.text) == ["owner turn", "cli turn"]
      assert [%{index: "m1"}, %{index: "m2"}] = history.entries
    end

    test "excludes a guest row with an owner-lookalike display name", %{repo: repo} do
      # The spoofable `sender` column carries the owner's id as display text;
      # the metadata id is a different account. Never consulted -> excluded.
      insert_message!(repo, %{
        sender: "owner-1",
        metadata: %{"user_id" => "guest-9"},
        content: "guest message"
      })

      history = assemble!(repo)

      assert history.entries == []
      assert history.dropped_unattributed == 1
    end

    test "excludes metadata-less remote rows (under-mining is the failure direction)", %{
      repo: repo
    } do
      insert_message!(repo, %{metadata: nil, content: "no metadata"})

      history = assemble!(repo)
      assert history.entries == []
      assert history.dropped_unattributed == 1
    end

    test "excludes rows from channels with no configured owner", %{repo: repo} do
      insert_message!(repo, %{channel: "discord", content: "discord row"})

      history = assemble!(repo)
      assert history.entries == []
      assert history.dropped_unattributed == 1
    end

    test "excludes rows outside the trailing window", %{repo: repo} do
      insert_message!(repo, %{created_at: ~U[2026-06-01 10:00:00Z], content: "too old"})

      history = assemble!(repo)
      assert history.entries == []
      assert history.scanned_messages == 0
    end
  end

  describe "assemble_history/2 checkpoints" do
    test "includes DM checkpoints, excludes group checkpoints", %{repo: repo} do
      insert_message!(repo, %{
        kind: "checkpoint_summary",
        role: "system",
        sender: "compactor",
        chat_id: "owner-1",
        metadata: nil,
        content: "summary of the owner DM"
      })

      insert_message!(repo, %{
        kind: "checkpoint_summary",
        role: "system",
        sender: "compactor",
        chat_id: "group-77",
        metadata: nil,
        content: "summary of a group chat"
      })

      history = assemble!(repo)

      assert [entry] = history.entries
      assert entry.kind == :checkpoint
      assert entry.text == "summary of the owner DM"
      assert history.checkpoints_included == 1
      assert history.dropped_guest_checkpoints == 1
    end

    test "preserves the history_tainted marker from a checkpoint row", %{repo: repo} do
      # MILESTONE_32 §13.6: `Compactor.checkpoint_metadata/1` stamps a checkpoint
      # distilled from activity-derived turns. Curation must carry that marker
      # onto the entry or the miner cannot keep it off an ungranted-remote chain.
      insert_message!(repo, %{
        kind: "checkpoint_summary",
        role: "system",
        sender: "compactor",
        metadata: %{source: "agent_loop_compaction", history_tainted: true},
        content: "summary that folded activity context"
      })

      insert_message!(repo, %{
        kind: "checkpoint_summary",
        role: "system",
        sender: "compactor",
        created_at: ~U[2026-07-21 10:00:00Z],
        metadata: %{source: "agent_loop_compaction"},
        content: "an ordinary summary"
      })

      assert [tainted, clean] = assemble!(repo).entries
      assert tainted.history_tainted == true
      refute Map.has_key?(clean, :history_tainted)
    end

    test "an owner message row carries no marker", %{repo: repo} do
      insert_message!(repo, %{content: "an ordinary owner turn"})

      assert [entry] = assemble!(repo).entries
      refute Map.has_key?(entry, :history_tainted)
    end
  end

  describe "assemble_history/2 caps" do
    test "stratified eviction keeps every day represented", %{repo: repo} do
      # Day one is heavy (500 rows), days two and three are light. A
      # newest-wins cap would erase day one entirely; the stratified cap must
      # keep all three days while landing at the message cap.
      for i <- 1..500 do
        insert_message!(repo, %{
          created_at: DateTime.add(~U[2026-07-28 00:00:00Z], i, :second),
          content: "day1 message #{i}"
        })
      end

      insert_message!(repo, %{created_at: ~U[2026-07-29 10:00:00Z], content: "day2 message"})
      insert_message!(repo, %{created_at: ~U[2026-07-30 10:00:00Z], content: "day3 message"})

      history = assemble!(repo)

      assert length(history.entries) == 400
      days = history.entries |> Enum.map(& &1.day) |> Enum.uniq()
      assert ~D[2026-07-28] in days
      assert ~D[2026-07-29] in days
      assert ~D[2026-07-30] in days
      assert history.dropped_caps == 102
    end

    test "byte budget evicts and reports drops", %{repo: repo} do
      # 60 entries x ~4KB comfortably exceeds the 96KB byte budget.
      for i <- 1..60 do
        insert_message!(repo, %{
          created_at: DateTime.add(~U[2026-07-20 00:00:00Z], i * 3_600, :second),
          content: String.duplicate("x", 4_000) <> " #{i}"
        })
      end

      history = assemble!(repo)

      total_bytes = Enum.sum_by(history.entries, &byte_size(&1.text))
      assert total_bytes <= 24_000 * 4
      assert history.dropped_caps > 0
    end

    test "a single oversized entry is truncated UTF-8-safely, not evicted", %{repo: repo} do
      insert_message!(repo, %{content: String.duplicate("é", 70_000)})

      history = assemble!(repo)

      assert [entry] = history.entries
      assert byte_size(entry.text) <= 24_000 * 4
      assert String.valid?(entry.text)
    end
  end

  describe "run_cycle/1" do
    defp seed_repeated_task!(repo) do
      insert_message!(repo, %{
        created_at: ~U[2026-07-10 10:00:00Z],
        content: "chase the unpaid invoices for acme"
      })

      insert_message!(repo, %{
        created_at: ~U[2026-07-17 10:00:00Z],
        content: "again: chase unpaid invoices please"
      })

      insert_message!(repo, %{
        created_at: ~U[2026-07-24 10:00:00Z],
        content: "invoice chasing time, same as before"
      })
    end

    defp miner_reply(candidates) do
      Jason.encode!(%{"cycle_summary" => "window summary", "candidates" => candidates})
    end

    defp valid_candidate do
      %{
        "kind" => "new_skill",
        "name" => "invoice_chase",
        "task_signature" => "chase unpaid invoices",
        "evidence" => [
          %{"ref" => "m1", "quote" => "chase the unpaid invoices"},
          %{"ref" => "m2", "quote" => "chase unpaid invoices"},
          %{"ref" => "m3", "quote" => "invoice chasing time"}
        ],
        "outline" => ["trigger", "steps", "outputs"],
        "rationale" => "no coverage"
      }
    end

    defp cycle_opts(repo, overrides) do
      Keyword.merge(
        [
          now: @now,
          trigger: :scheduled,
          repo: repo,
          adapter: MinerStub,
          adapter_opts: [test_pid: self(), reply: miner_reply([valid_candidate()])],
          configured_owners: @owners,
          jobs_config: [],
          channel_adapter: ChannelStub
        ],
        overrides
      )
    end

    defp state!(repo) do
      {:ok, state} = Repo.ensure_skill_curation_state(@now, server: repo)
      state
    end

    test "a full cycle persists, delivers, stamps origin, and terminalizes ok", %{repo: repo} do
      start_supervised!(ChannelStub.recorder_spec())
      seed_repeated_task!(repo)

      handler = "sc-cycle-telemetry-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach_many(
        handler,
        [[:fermix, :skill_curation, :run_start], [:fermix, :skill_curation, :run_complete]],
        fn event, _meas, metadata, _config ->
          send(test_pid, {:sc_cycle_event, event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, counts} = SkillCuration.run_cycle(cycle_opts(repo, []))

      # The cycle emits both bookends under one minted session id (stage
      # :cycle filters out concurrent creator-stage events from other files).
      assert_receive {:sc_cycle_event, [:fermix, :skill_curation, :run_start],
                      %{stage: :cycle, session_id: "skill_curation:" <> _ = session_id}}

      assert_receive {:sc_cycle_event, [:fermix, :skill_curation, :run_complete],
                      %{stage: :cycle, session_id: ^session_id} = complete_meta}

      assert complete_meta.proposals_new == 1
      assert complete_meta.delivery_status == :delivered

      assert counts.proposals_new == 1
      assert counts.candidates == 1
      assert counts.delivery_status == :delivered
      assert counts.messages_scanned == 3

      assert {:ok, [row]} =
               Repo.list_skill_curation_proposals(%{statuses: ["pending"]}, server: repo)

      assert row.kind == "new_skill"
      assert row.skill_name == "invoice_chase"
      assert row.origin_channel == "telegram"
      assert row.origin_chat_id == "owner-1"
      assert row.summary =~ "asked 3x in the last month"

      assert [{:message, "owner-1", text}] = ChannelStub.sent()
      assert text =~ "/skills approve #{row.token}"
      assert text =~ "/skills deny #{row.token}"

      state = state!(repo)
      assert state.status == "idle"
      assert state.last_status == "ok"
      assert DateTime.compare(state.last_cycle_at, @now) == :eq
      assert state.retry_at == nil
    end

    test "a button-capable adapter gets the proposal dispatch", %{repo: repo} do
      start_supervised!(ChannelStub.recorder_spec())
      seed_repeated_task!(repo)

      assert {:ok, %{delivery_status: :delivered}} =
               SkillCuration.run_cycle(cycle_opts(repo, channel_adapter: ButtonChannelStub))

      assert [{:proposal, %{chat_id: "owner-1"}, text, token}] = ChannelStub.sent()
      assert token =~ ~r/^[A-Z2-7]{8}$/
      # Button-capable rendering never spells out the typed commands.
      refute text =~ "/skills approve"
    end

    test "no owner-configured channel completes with no_delivery_target", %{repo: repo} do
      # CLI-only install: local rows mine fine, but there is no remote owner
      # inbox to deliver to.
      for {content, at} <- [
            {"chase the unpaid invoices for acme", ~U[2026-07-10 10:00:00Z]},
            {"again: chase unpaid invoices please", ~U[2026-07-17 10:00:00Z]},
            {"invoice chasing time, same as before", ~U[2026-07-24 10:00:00Z]}
          ] do
        insert_message!(repo, %{
          channel: "cli",
          chat_id: "local",
          metadata: nil,
          content: content,
          created_at: at
        })
      end

      assert {:ok, counts} =
               SkillCuration.run_cycle(cycle_opts(repo, configured_owners: %{}))

      assert counts.delivery_status == :no_delivery_target

      # Proposals stay pending and actionable via /skills proposals.
      assert {:ok, [row]} =
               Repo.list_skill_curation_proposals(%{statuses: ["pending"]}, server: repo)

      assert row.origin_channel == nil
    end

    test "an empty window is a successful cycle with zero proposals", %{repo: repo} do
      assert {:ok, counts} =
               SkillCuration.run_cycle(
                 cycle_opts(repo, adapter_opts: [test_pid: self(), reply: miner_reply([])])
               )

      assert counts.candidates == 0
      assert counts.delivery_status == :nothing_to_deliver
      assert state!(repo).last_status == "ok"
    end

    test "a concurrent claim refuses", %{repo: repo} do
      assert {:ok, _} = Repo.ensure_skill_curation_state(@now, server: repo)
      assert {:ok, _} = Repo.claim_skill_curation_cycle(@now, 3_600_000, server: repo)

      assert {:error, :concurrent_run} = SkillCuration.run_cycle(cycle_opts(repo, []))
    end

    test "scheduled failures earn exactly one state-enforced retry per period", %{repo: repo} do
      seed_repeated_task!(repo)
      failing = [test_pid: self(), reply: {:error, :boom}]

      # Cadence-due attempt: error advances the clock and schedules the retry.
      assert {:error, {:provider, _}} =
               SkillCuration.run_cycle(cycle_opts(repo, adapter_opts: failing))

      state = state!(repo)
      assert state.last_status == "error:provider"
      assert DateTime.compare(state.last_cycle_at, @now) == :eq
      assert DateTime.compare(state.retry_at, DateTime.add(@now, 12 * 3_600, :second)) == :eq

      # Retry-due attempt: error clears retry_at and never re-arms it.
      retry_now = DateTime.add(@now, 12 * 3_600, :second)

      assert {:error, {:provider, _}} =
               SkillCuration.run_cycle(cycle_opts(repo, adapter_opts: failing, now: retry_now))

      state = state!(repo)
      assert state.retry_at == nil
      assert DateTime.compare(state.last_cycle_at, retry_now) == :eq
    end

    test "manual failure leaves the cadence clock and retry state untouched", %{repo: repo} do
      seed_repeated_task!(repo)
      {:ok, initial} = Repo.ensure_skill_curation_state(~U[2026-07-20 00:00:00Z], server: repo)

      assert {:error, {:provider, _}} =
               SkillCuration.run_cycle(
                 cycle_opts(repo,
                   trigger: :manual,
                   adapter_opts: [test_pid: self(), reply: {:error, :boom}]
                 )
               )

      state = state!(repo)
      assert state.last_status == "error:provider"
      assert DateTime.compare(state.last_cycle_at, initial.last_cycle_at) == :eq
      assert state.retry_at == nil
    end

    test "a crash mid-pipeline terminalizes as error:crash, never wedges", %{repo: repo} do
      seed_repeated_task!(repo)

      assert {:error, {:crash, _reason}} =
               SkillCuration.run_cycle(
                 cycle_opts(repo, adapter_opts: [test_pid: self(), reply: :raise])
               )

      state = state!(repo)
      assert state.status == "idle"
      assert state.last_status == "error:crash"

      # The next cycle claims cleanly.
      assert {:ok, _counts} =
               SkillCuration.run_cycle(
                 cycle_opts(repo,
                   now: DateTime.add(@now, 12 * 3_600, :second),
                   adapter_opts: [test_pid: self(), reply: miner_reply([])]
                 )
               )
    end

    test "deferred proposals fill the cap: delivered first, mining skipped", %{repo: repo} do
      start_supervised!(ChannelStub.recorder_spec())

      for i <- 1..3 do
        {:ok, _} =
          Proposals.insert(
            %{
              cycle_session_id: "skill_curation:prev",
              kind: "new_skill",
              skill_name: "deferred_#{i}",
              task_signature: "deferred sig #{i}",
              summary: "Deferred proposal #{i}",
              status: "deferred",
              created_at: ~U[2026-07-30 10:00:00Z]
            },
            repo: repo
          )
      end

      assert {:ok, counts} = SkillCuration.run_cycle(cycle_opts(repo, []))

      assert counts.delivered_deferred == 3
      assert counts.candidates == 0
      refute_receive {:miner_call, _messages}

      assert {:ok, pending} =
               Repo.list_skill_curation_proposals(%{statuses: ["pending"]}, server: repo)

      assert length(pending) == 3
      assert Enum.all?(pending, &(&1.origin_channel == "telegram"))
      assert length(ChannelStub.sent()) == 3
    end

    test "overflow candidates become next cycle's deferred, bounded", %{repo: repo} do
      start_supervised!(ChannelStub.recorder_spec())
      seed_repeated_task!(repo)

      candidates =
        for i <- 1..8 do
          valid_candidate()
          |> Map.put("name", "candidate_#{i}")
          |> Map.put("task_signature", "distinct signature #{i}")
        end

      assert {:ok, counts} =
               SkillCuration.run_cycle(
                 cycle_opts(repo,
                   adapter_opts: [test_pid: self(), reply: miner_reply(candidates)]
                 )
               )

      assert counts.proposals_new == 3
      assert counts.deferred == 3
      assert counts.dropped_overflow == 2

      assert {:ok, deferred} =
               Repo.list_skill_curation_proposals(%{statuses: ["deferred"]}, server: repo)

      assert length(deferred) == 3
    end

    test "the audit proposes archiving aged unused ledger skills, capped", %{repo: repo} do
      start_supervised!(ChannelStub.recorder_spec())

      for i <- 1..3 do
        {:ok, _} =
          Repo.insert_skill_curation_ledger(
            %{
              skill_name: "dusty_#{i}",
              task_signature: "dusty sig #{i}",
              status: "active",
              created_proposal_id: i,
              created_at: ~U[2026-06-01 10:00:00Z]
            },
            server: repo
          )
      end

      # A recently-used ledger skill is never flagged.
      {:ok, _} =
        Repo.insert_skill_curation_ledger(
          %{
            skill_name: "busy_skill",
            task_signature: "busy sig",
            status: "active",
            created_proposal_id: 9,
            created_at: ~U[2026-06-01 10:00:00Z]
          },
          server: repo
        )

      assert :ok =
               Repo.record_skill_usage("busy_skill", :run, ~U[2026-07-30 10:00:00Z], server: repo)

      # dusty_3 was used once, long ago: still archive-eligible, but it sorts
      # after the never-used skills.
      assert :ok =
               Repo.record_skill_usage("dusty_3", :run, ~U[2026-06-15 10:00:00Z], server: repo)

      assert {:ok, counts} =
               SkillCuration.run_cycle(
                 cycle_opts(repo, adapter_opts: [test_pid: self(), reply: miner_reply([])])
               )

      assert counts.proposals_archive == 2
      assert counts.archive_overflow == 1

      assert {:ok, archive_rows} =
               Repo.list_skill_curation_proposals(%{kind: "archive_skill"}, server: repo)

      # Oldest-unused first: dusty_3 has (old) recorded usage, so the two
      # never-used skills win the per-cycle cap.
      assert archive_rows |> Enum.map(& &1.skill_name) |> Enum.sort() == ["dusty_1", "dusty_2"]
      assert Enum.all?(archive_rows, &(&1.summary =~ "Never used since created"))
    end
  end

  describe "assemble_history/2 indexing" do
    test "entries are m-indexed chronologically with labels and day stamps", %{repo: repo} do
      insert_message!(repo, %{created_at: ~U[2026-07-21 10:00:00Z], content: "second"})
      insert_message!(repo, %{created_at: ~U[2026-07-20 10:00:00Z], content: "first"})

      history = assemble!(repo)

      assert [first, second] = history.entries
      assert first.index == "m1"
      assert first.text == "first"
      assert first.label == "telegram:owner-1/root"
      assert first.day == ~D[2026-07-20]
      assert second.index == "m2"
      assert second.text == "second"
    end
  end
end
