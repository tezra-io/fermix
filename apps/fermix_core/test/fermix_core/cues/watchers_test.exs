defmodule FermixCore.Cues.WatchersTest do
  # Sets `[fermix_core.routing]` for the filter-model default, a global.
  use ExUnit.Case, async: false

  alias FermixCore.Cues.Item
  alias FermixCore.Cues.RecentDrops
  alias FermixCore.Cues.Watchers
  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesFilterSql
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixCore.Memory.Repo.CuesWatchersSql
  alias FermixTestSupport.CueFixtures
  alias FermixTestSupport.TelemetryCapture

  @t0 ~U[2026-10-05 09:00:00.000000Z]
  @cap_sentence "This watcher has 20 instructions; merge some first."
  @needs_words "A watcher that filters needs words to listen for: list the names, products, " <>
                 "abbreviations and phrases an item it should see would contain, as listen_for."
  @no_filter_on_stream "A watcher with no filter cannot listen to a stream (bsky), where it " <>
                         "would pass every item: give it a model filter and words to listen " <>
                         "for, or pick sources that are not streams."
  @streams [
    cues_config: [
      sources: %{
        "bsky" => %{kind: :stream, url: "wss://jetstream.example.org/subscribe"},
        "my-script" => %{kind: :local_push}
      }
    ]
  ]

  setup do
    routing = Application.get_env(:fermix_core, :routing)
    on_exit(fn -> restore_env(:routing, routing) end)
    Application.put_env(:fermix_core, :routing, [])

    %{repo: repo, conn: conn} = CueFixtures.start_repo("watchers")
    %{repo: repo, conn: conn}
  end

  describe "instructions (C49)" do
    test "three added over a week keep their own time and chat, in number order", ctx do
      watcher = watcher!(ctx, "market-news", [])

      for {text, day, chat} <- [
            {"Pass earnings surprises", 0, "telegram:chat-1"},
            {"Drop analyst rating changes", 2, "mobile:phone-1"},
            {"Pass guidance cuts", 6, "telegram:chat-1"}
          ] do
        assert {:ok, _changed} =
                 Watchers.add_instructions(watcher.name, [text], [], chat, opts(ctx, day))
      end

      assert {:ok, shown} = Watchers.show(watcher.name, opts(ctx, 7))

      assert [
               %{number: 1, text: "Pass earnings surprises", added_from: "telegram:chat-1"},
               %{number: 2, text: "Drop analyst rating changes", added_from: "mobile:phone-1"},
               %{number: 3, text: "Pass guidance cuts", added_from: "telegram:chat-1"}
             ] = shown.instructions

      assert Enum.map(shown.instructions, & &1.added_at) == [
               at(0),
               at(2),
               at(6)
             ]
    end

    test "a removed instruction comes back with its number; numbers are never reused", ctx do
      watcher = watcher!(ctx, "release-watch", ["Pass Elixir releases", "Pass Phoenix releases"])

      assert {:ok, %{echo: "Removed 2: Pass Phoenix releases."}} =
               Watchers.remove_instructions(watcher.name, [2], "telegram:chat-1", opts(ctx, 1))

      assert {:ok, %{echo: "Added 3: Pass SQLite releases."}} =
               Watchers.add_instructions(
                 watcher.name,
                 ["Pass SQLite releases"],
                 [],
                 "telegram:chat-1",
                 opts(ctx, 2)
               )

      assert {:ok, %{echo: "Restored 2: Pass Phoenix releases."}} =
               Watchers.restore_instruction(watcher.name, 2, "telegram:chat-1", opts(ctx, 3))

      assert {:ok, shown} = Watchers.show(watcher.name, opts(ctx, 4))
      assert Enum.map(shown.instructions, & &1.number) == [1, 2, 3]
      assert shown.removed_instructions == []
    end

    test "a contradicting instruction replaces the old one in one change, both echoed", ctx do
      watcher = watcher!(ctx, "market-news", ["Include TSLA"])

      assert {:ok, %{echo: echo}} =
               Watchers.add_instructions(
                 watcher.name,
                 ["Ignore analyst rating changes"],
                 [1],
                 "telegram:chat-1",
                 opts(ctx, 1)
               )

      assert echo == "Added 2: Ignore analyst rating changes. Removed 1: Include TSLA."
    end

    test "the 21st is refused until a merge, and the merge is echoed in full", ctx do
      texts = for n <- 1..20, do: "Criterion #{n}"
      watcher = watcher!(ctx, "busy-feed", texts)

      assert {:error, @cap_sentence} =
               Watchers.add_instructions(
                 watcher.name,
                 ["One more"],
                 [],
                 "telegram:chat-1",
                 opts(ctx, 1)
               )

      assert {:error, @cap_sentence} =
               Watchers.restore_instruction(watcher.name, 1, "telegram:chat-1", opts(ctx, 1))

      assert {:ok, %{echo: echo}} =
               Watchers.merge_instructions(
                 watcher.name,
                 [3, 4, 7],
                 "Criteria three, four and seven",
                 "telegram:chat-1",
                 opts(ctx, 2)
               )

      assert echo ==
               "Merged 3, 4 and 7 into 21: Criteria three, four and seven. " <>
                 "Removed 3: Criterion 3. Removed 4: Criterion 4. Removed 7: Criterion 7."

      assert {:ok, %{echo: "Added 22: One more."}} =
               Watchers.add_instructions(
                 watcher.name,
                 ["One more"],
                 [],
                 "telegram:chat-1",
                 opts(ctx, 3)
               )

      assert {:ok, shown} = Watchers.show(watcher.name, opts(ctx, 4))
      merged = Enum.find(shown.instructions, &(&1.number == 21))

      assert shown.removed_instructions |> Enum.map(& &1.replaced_by) |> Enum.uniq() == [
               merged.id
             ]
    end

    test "an instruction over 300 characters is refused", ctx do
      watcher = watcher!(ctx, "market-news", [])
      long = String.duplicate("a", 301)

      assert {:error, "An instruction is at most 300 characters; split it into two."} =
               Watchers.add_instructions(
                 watcher.name,
                 [long],
                 [],
                 "telegram:chat-1",
                 opts(ctx, 1)
               )
    end
  end

  describe "the filter model" do
    test "an llm watcher with no model and no default filter model is made for the main model",
         ctx do
      params = %{
        name: "market-news",
        filter: "llm",
        purpose: "Market moves that need me",
        listen_for: ["earnings"],
        sources: ["alpaca-news"],
        task: "Tell me what matters."
      }

      assert {:ok, %{watcher: watcher}} = Watchers.create(params, private_context(), opts(ctx, 0))
      assert %{filter: "llm"} = watcher
      refute Map.has_key?(watcher, :filter_model)
    end
  end

  describe "words to listen for (M60_CUE_INTAKE_AT_SCALE.md §3.1)" do
    test "a watcher that filters is made with its words, and the echo lists them", ctx do
      params = %{
        name: "chip-news",
        filter: "llm",
        purpose: "AI chip news",
        listen_for: [" TSMC ", "AI chip", "tsmc", "半導体"],
        sources: ["alpaca-news"],
        task: "Tell me what matters."
      }

      assert {:ok, %{watcher: watcher, echo: echo}} =
               Watchers.create(params, private_context(), opts(ctx, 0))

      assert watcher.listen_for == ["TSMC", "AI chip", "半導体"]
      assert echo =~ "\nListens for: TSMC, AI chip, 半導体\n"
    end

    test "one that filters with no words, or with words the rules refuse, is not made", ctx do
      base = %{
        name: "chip-news",
        filter: "llm",
        purpose: "AI chip news",
        sources: ["alpaca-news"],
        task: "Tell me what matters."
      }

      assert {:error, @needs_words} = Watchers.create(base, private_context(), opts(ctx, 0))

      assert {:error, "A watcher listens for at least one word."} =
               Watchers.create(Map.put(base, :listen_for, []), private_context(), opts(ctx, 0))

      long = String.duplicate("a", 65)

      assert {:error, "Each word to listen for is at most 64 characters: " <> ^long} =
               Watchers.create(
                 Map.put(base, :listen_for, [long]),
                 private_context(),
                 opts(ctx, 0)
               )

      assert {:ok, []} = Watchers.list(opts(ctx, 0))
      assert {:ok, []} = JobsRegistry.list_jobs(repo: ctx.repo)
    end

    test "one with no filter takes no words and cannot listen to a stream", ctx do
      params = %{
        name: "all-posts",
        filter: "none",
        daily_cap: 10,
        sources: ["my-script", "bsky"],
        task: "Report it."
      }

      assert {:error, @no_filter_on_stream} =
               Watchers.create(params, private_context(), opts(ctx, 0) ++ @streams)

      with_words = %{params | sources: ["my-script"]} |> Map.put(:listen_for, ["post"])

      assert {:error,
              "A watcher with no filter takes no purpose, instructions or words to listen for."} =
               Watchers.create(with_words, private_context(), opts(ctx, 0) ++ @streams)

      assert {:ok, %{watcher: %{filter: "none", listen_for: []}}} =
               Watchers.create(
                 %{params | sources: ["my-script"]},
                 private_context(),
                 opts(ctx, 0) ++ @streams
               )
    end

    test "an update replaces the words, and every echo lists what is stored", ctx do
      watcher = watcher!(ctx, "chip-news", [])

      assert {:ok, %{watcher: updated, echo: echo}} =
               Watchers.update(watcher.name, %{listen_for: ["TSMC", "Nvidia"]}, opts(ctx, 1))

      assert updated.listen_for == ["TSMC", "Nvidia"]

      assert echo ==
               "Watcher chip-news changed: new words to listen for.\nListens for: TSMC, Nvidia"

      assert {:ok, %{echo: echo}} = Watchers.update(watcher.name, %{daily_cap: 5}, opts(ctx, 2))
      assert echo == "Watcher chip-news changed: daily cap 5 runs.\nListens for: TSMC, Nvidia"

      assert {:error, "A watcher listens for at least one word."} =
               Watchers.update(watcher.name, %{listen_for: []}, opts(ctx, 3))
    end

    test "a change that leaves a rule broken is refused, naming the fix", ctx do
      watcher = watcher!(ctx, "old-news", [], ["alpaca-news"], [])

      assert {:error, @needs_words} =
               Watchers.update(watcher.name, %{daily_cap: 5}, opts(ctx, 1) ++ @streams)

      assert {:ok, _given} =
               Watchers.update(watcher.name, %{listen_for: ["outage"]}, opts(ctx, 2) ++ @streams)

      assert {:error, @no_filter_on_stream} =
               Watchers.update(
                 watcher.name,
                 %{filter: "none", daily_cap: 3, sources: ["bsky"]},
                 opts(ctx, 3) ++ @streams
               )

      assert {:ok, %{watcher: none}} =
               Watchers.update(
                 watcher.name,
                 %{filter: "none", daily_cap: 3},
                 opts(ctx, 4) ++ @streams ++ [wake_scheduler: fn -> :ok end]
               )

      # The words stay for a switch back, as the instructions do.
      assert none.listen_for == ["outage"]

      assert {:error, @no_filter_on_stream} =
               Watchers.update(watcher.name, %{sources: ["bsky"]}, opts(ctx, 5) ++ @streams)

      assert {:error,
              "A watcher with no filter takes no purpose, instructions or words to listen for."} =
               Watchers.update(watcher.name, %{listen_for: ["x"]}, opts(ctx, 6) ++ @streams)
    end

    test "update_needed names the rule a stored watcher breaks, or nil" do
      words = %{filter: "llm", listen_for: ["outage"], sources: ["bsky"]}
      no_filter = %{filter: "none", listen_for: [], sources: ["my-script"]}

      assert Watchers.update_needed(words, ["bsky"]) == nil
      assert Watchers.update_needed(%{words | listen_for: []}, []) == :words
      assert Watchers.update_needed(no_filter, ["bsky"]) == nil

      assert Watchers.update_needed(%{no_filter | sources: ["my-script", "bsky"]}, ["bsky"]) ==
               :filter
    end

    test "the stream sources are read from the cue settings" do
      assert Watchers.stream_refs(@streams) == ["bsky"]
      assert Watchers.stream_refs(cues_config: []) == []
    end
  end

  describe "creation refusals" do
    test "a watcher with no filter states its daily cap (decision 3)", ctx do
      params = %{name: "my-script", filter: "none", sources: ["local-push"], task: "Report it."}

      assert {:error,
              "A watcher with no filter wakes its task for every cue; say how many runs a day " <>
                "it may cause, or say none."} =
               Watchers.create(params, private_context(), opts(ctx, 0))

      with_list = Map.merge(params, %{daily_cap: "none", instructions: ["Pass it all"]})

      assert {:error,
              "A watcher with no filter takes no purpose, instructions or words to listen for."} =
               Watchers.create(with_list, private_context(), opts(ctx, 0))
    end

    test "a task with delivery none never reaches the owner and is refused", ctx do
      params = %{
        name: "my-script",
        filter: "none",
        daily_cap: 10,
        sources: ["local-push"],
        task: "Report it.",
        delivery_mode: "none"
      }

      assert {:error, "A watcher's task must reach you: pick where it reports."} =
               Watchers.create(params, private_context(), opts(ctx, 0))
    end

    test "from the command line the task needs an explicit delivery target", ctx do
      params = %{
        name: "my-script",
        filter: "none",
        daily_cap: 10,
        sources: ["local-push"],
        task: "Report it."
      }

      context = %{private_context() | conversation_key: {"cli", "cli", :root}}

      assert {:error, sentence} = Watchers.create(params, context, opts(ctx, 0))
      assert sentence =~ "Pass an explicit delivery_target on a configured channel instead."
      assert {:ok, []} = JobsRegistry.list_jobs(repo: ctx.repo)
    end
  end

  describe "removal (design §8.8)" do
    test "refused while a delivery is filtering or claimed; otherwise expires and writes gaps",
         ctx do
      watcher = watcher!(ctx, "eng-feeds", ["Pass outages"], ["eng-blogs", "gh-releases"])
      pending = delivery!(ctx, watcher.id, "eng-blogs", "pending")
      passed = delivery!(ctx, watcher.id, "gh-releases", "passed")
      other = delivery!(ctx, watcher.id, "eng-blogs", "pending")
      filtering = delivery!(ctx, watcher.id, "eng-blogs", "filtering", filter_call_id: "cfc_x")

      assert {:error, refusal} = Watchers.remove(watcher.name, opts(ctx, 1))
      assert refusal =~ "is filtering an item or running its task right now"
      assert {:ok, _still_there} = Watchers.show(watcher.name, opts(ctx, 1))

      CueFixtures.exec!(
        ctx.conn,
        "UPDATE cue_deliveries SET state = 'dropped', settled_at = ?, filter_call_id = NULL " <>
          "WHERE id = ?",
        ["2026-10-05T09:00:00.000000Z", filtering]
      )

      assert {:ok, %{echo: echo}} = Watchers.remove(watcher.name, opts(ctx, 2))
      assert echo =~ "3 waiting items expired"

      for id <- [pending, passed, other] do
        assert [["expired", "watcher_removed"]] =
                 CueFixtures.rows(
                   ctx.conn,
                   "SELECT state, outcome FROM cue_deliveries WHERE id = ?",
                   [id]
                 )
      end

      assert CueFixtures.rows(
               ctx.conn,
               "SELECT source_ref, reason, count FROM cue_gaps WHERE watcher_id = ? ORDER BY source_ref",
               [watcher.id]
             ) == [["eng-blogs", "watcher_removed", 2], ["gh-releases", "watcher_removed", 1]]

      assert {:error, "There is no watcher named eng-feeds."} =
               Watchers.show(watcher.name, opts(ctx, 3))

      assert [[0]] =
               CueFixtures.rows(
                 ctx.conn,
                 "SELECT count(*) FROM cue_watcher_instructions WHERE watcher_id = ?",
                 [watcher.id]
               )

      assert {:ok, _job} = JobsRegistry.get_job(watcher.task_job_id, repo: ctx.repo)
    end
  end

  describe "examples" do
    test "an example must name a cue this watcher received; its snapshot is copied", ctx do
      watcher = watcher!(ctx, "market-news", ["Pass earnings"])
      other = watcher!(ctx, "eng-feeds", ["Pass outages"])
      delivery!(ctx, watcher.id, "alpaca-news", "dropped", cue_id: 41)
      delivery!(ctx, other.id, "alpaca-news", "dropped", cue_id: 42)

      assert {:error,
              "That cue was never delivered to this watcher; an example must be one it received."} =
               Watchers.add_example(watcher.name, 42, "pass", nil, opts(ctx, 1))

      assert {:ok, %{example: example}} =
               Watchers.add_example(watcher.name, 41, "pass", "earnings beat", opts(ctx, 1))

      assert example.snapshot =~ "Item 41"

      assert {:ok, shown} = Watchers.show(watcher.name, opts(ctx, 2))
      assert [%{id: id, label: "pass", note: "earnings beat"}] = shown.examples

      assert {:ok, %{echo: echo}} = Watchers.remove_example(watcher.name, id, opts(ctx, 3))
      assert echo =~ "Removed the pass example"
    end

    # A stream keeps only what passes, so "that one should have passed" names a
    # drop from the watcher's recent drops (M60_CUE_INTAKE_AT_SCALE.md §3.2):
    # the item is kept then, as a receipt, and the example with it.
    test "a recent drop of a stream watcher becomes an example, its item kept with it", ctx do
      watcher = watcher!(ctx, "chip-news", ["Pass AI chip news"], ["bsky"])
      RecentDrops.new_table()

      {:ok, item} =
        Item.new(
          %{item_id: "at://post/1", type: "post", data: %{"text" => "TSMC opens a fab"}},
          at(0)
        )

      drop = RecentDrops.put(watcher.id, item, "bsky", "Not about AI.", at(0))

      assert {:ok, %{example: example, echo: echo}} =
               Watchers.add_drop_example(
                 watcher.name,
                 drop.key,
                 "pass",
                 "chip news",
                 opts(ctx, 1)
               )

      assert echo ==
               "Stored cue #{example.cue_id} as a pass example for watcher chip-news " <>
                 "(#{example.id}); the filter sees it from its next call."

      assert example.snapshot == item.snapshot

      assert [["bsky", nil, 0]] =
               CueFixtures.rows(
                 ctx.conn,
                 "SELECT source_ref, payload, routed_count FROM cues WHERE id = ?",
                 [example.cue_id]
               )

      assert [[0]] =
               CueFixtures.rows(ctx.conn, "SELECT count(*) FROM cue_deliveries", [])

      # Labelled again, it is the same kept item.
      assert {:ok, %{example: again}} =
               Watchers.add_drop_example(watcher.name, drop.key, "pass", nil, opts(ctx, 2))

      assert again.cue_id == example.cue_id

      assert {:error,
              "That drop is no longer kept: Fermix keeps a stream watcher's last 50 drops " <>
                "until it restarts."} =
               Watchers.add_drop_example(watcher.name, drop.key + 1, "pass", nil, opts(ctx, 3))
    end
  end

  describe "update" do
    test "a change computed from an older state is refused as stale", ctx do
      watcher = watcher!(ctx, "market-news", [])

      {:ok, read} =
        Repo.cues_call(CuesWatchersSql, {:get_watcher, {:id, watcher.id}}, server: ctx.repo)

      assert {:ok, _updated} =
               Repo.cues_call(
                 CuesWatchersSql,
                 {:update_watcher, watcher.id, read.updated_at, %{daily_cap: 5}, nil,
                  read.updated_at},
                 server: ctx.repo
               )

      assert {:error, :stale} =
               Repo.cues_call(
                 CuesWatchersSql,
                 {:update_watcher, watcher.id, read.updated_at, %{daily_cap: 6}, nil,
                  read.updated_at},
                 server: ctx.repo
               )
    end

    test "switching to no filter states a daily cap and clears the model and purpose", ctx do
      watcher = watcher!(ctx, "market-news", ["Pass earnings"])

      assert {:error, sentence} = Watchers.update(watcher.name, %{filter: "none"}, opts(ctx, 1))
      assert sentence =~ "say how many runs a day"

      assert {:ok, %{watcher: updated}} =
               Watchers.update(watcher.name, %{filter: "none", daily_cap: 30}, opts(ctx, 2))

      assert %{filter: "none", purpose: nil, daily_cap: 30} = updated
      assert [%{number: 1}] = updated.instructions
    end

    test "sources not set up are echoed as missing", ctx do
      watcher = watcher!(ctx, "market-news", [])

      assert {:ok, %{echo: echo}} =
               Watchers.update(
                 watcher.name,
                 %{sources: ["alpaca-news", "eng-blogs"]},
                 opts(ctx, 1) ++
                   [cues_config: [sources: %{"alpaca-news" => %{kind: :local_push}}]]
               )

      assert echo =~ "eng-blogs is not set up yet; add it in settings."
      refute echo =~ "alpaca-news is not set up"
    end
  end

  describe "pause (design §8.8)" do
    test "the echo says what stops and what still reaches the task", ctx do
      watcher = watcher!(ctx, "market-news", ["Pass earnings"])

      assert {:ok, %{echo: echo}} = Watchers.pause(watcher.name, opts(ctx, 1))

      assert echo ==
               "Watcher market-news is paused. New items are not delivered to it and nothing " <>
                 "waiting is filtered; items it already passed still go to its task."
    end
  end

  # Design §8.8 does not cover taking a source off a watcher; it is treated as
  # removing the watcher for that source.
  describe "taking a source off" do
    test "discards what waited from it with no gap, says how many, and traces each", ctx do
      watcher = watcher!(ctx, "market-news", ["Pass earnings"], ["alpaca-news", "sec-filings"])
      TelemetryCapture.attach([[:fermix, :cue, :lifecycle]], watcher_id: watcher.id)
      waiting = for _n <- 1..2, do: delivery!(ctx, watcher.id, "alpaca-news", "pending")
      passed = delivery!(ctx, watcher.id, "alpaca-news", "passed")
      kept = delivery!(ctx, watcher.id, "sec-filings", "pending")

      assert {:ok, %{echo: echo}} =
               Watchers.update(watcher.name, %{sources: ["sec-filings"]}, opts(ctx, 1))

      assert echo =~ "2 items waiting from sources it no longer listens to were discarded."

      for id <- waiting do
        assert_received {:telemetry, [:fermix, :cue, :lifecycle], _m,
                         %{phase: :expired, delivery_id: ^id, reason: "source_removed"}}
      end

      states =
        CueFixtures.rows(
          ctx.conn,
          "SELECT id, state, outcome FROM cue_deliveries WHERE watcher_id = ? ORDER BY id",
          [watcher.id]
        )

      assert states ==
               Enum.map(waiting, &[&1, "expired", "watcher_removed"]) ++
                 [[passed, "passed", nil], [kept, "pending", nil]]

      assert [[0]] = CueFixtures.rows(ctx.conn, "SELECT count(*) FROM cue_gaps", [])
    end

    # One change that switches to no filter and takes a source off: that
    # source's item under a call expires before the switch passes what is left.
    test "with a switch to none, the taken source's item under a call expires, nothing " <>
           "wakes, and the call's answer is refused as stale",
         ctx do
      watcher = watcher!(ctx, "market-news", ["Pass earnings"], ["alpaca-news", "sec-filings"])

      filtering =
        delivery!(ctx, watcher.id, "alpaca-news", "filtering", filter_call_id: "cfc_live")

      CueFixtures.exec!(
        ctx.conn,
        "INSERT INTO cue_filter_calls (id, watcher_id, delivery_id, session_id, started_at) " <>
          "VALUES ('cfc_live', ?, ?, 'cue_filter_live', ?)",
        [watcher.id, filtering, CuesSql.stamp(at(0))]
      )

      test_pid = self()
      opts = opts(ctx, 1) ++ [wake_scheduler: fn -> send(test_pid, :scheduler_woken) end]
      changes = %{filter: "none", daily_cap: 30, sources: ["sec-filings"]}

      assert {:ok, %{echo: echo}} = Watchers.update(watcher.name, changes, opts)
      assert echo =~ "1 item waiting from a source it no longer listens to was discarded."
      refute echo =~ "now go"
      refute_received :scheduler_woken

      assert {:error, :stale} =
               Repo.cues_call(CuesFilterSql, {:settle, "cfc_live", {:pass, "Late.", nil}, at(1)},
                 server: ctx.repo
               )

      assert [["expired", "watcher_removed", "aborted"]] =
               CueFixtures.rows(
                 ctx.conn,
                 "SELECT d.state, d.outcome, c.result FROM cue_deliveries d " <>
                   "JOIN cue_filter_calls c ON c.id = 'cfc_live' WHERE d.id = ?",
                 [filtering]
               )
    end
  end

  describe "switching the filter (design §8.1)" do
    test "to none passes what waited for the filter, wakes the task and says how many", ctx do
      watcher = watcher!(ctx, "market-news", ["Pass earnings"])
      waiting = for _n <- 1..2, do: delivery!(ctx, watcher.id, "alpaca-news", "pending")

      filtering =
        delivery!(ctx, watcher.id, "alpaca-news", "filtering", filter_call_id: "cfc_live")

      test_pid = self()
      wake = fn -> send(test_pid, :scheduler_woken) end
      opts = opts(ctx, 1) ++ [wake_scheduler: wake]

      assert {:ok, %{echo: echo}} =
               Watchers.update(watcher.name, %{filter: "none", daily_cap: 30}, opts)

      assert echo =~ "3 items that waited for the filter now go to its task."
      assert_receive :scheduler_woken

      # The item under a call in flight passes too: with no filter there is
      # nothing left for that call to decide.
      for id <- waiting ++ [filtering] do
        assert [["passed", "no filter", ready_at, nil]] =
                 CueFixtures.rows(
                   ctx.conn,
                   "SELECT state, decision_reason, ready_at, filter_call_id FROM cue_deliveries " <>
                     "WHERE id = ?",
                   [id]
                 )

        assert ready_at == CuesSql.stamp(at(1))
      end
    end

    # A call that settled after the switch, or that failed and would have put
    # its item back to `pending` where no `llm` claim ever takes it again,
    # finds its fence gone: its result is refused and the call closed.
    test "to none refuses the result of a call still in flight", ctx do
      watcher = watcher!(ctx, "market-news", ["Pass earnings"])

      filtering =
        delivery!(ctx, watcher.id, "alpaca-news", "filtering", filter_call_id: "cfc_live")

      CueFixtures.exec!(
        ctx.conn,
        "INSERT INTO cue_filter_calls (id, watcher_id, delivery_id, session_id, started_at) " <>
          "VALUES ('cfc_live', ?, ?, 'cue_filter_live', ?)",
        [watcher.id, filtering, CuesSql.stamp(at(0))]
      )

      opts = opts(ctx, 1) ++ [wake_scheduler: fn -> :ok end]

      assert {:ok, _updated} =
               Watchers.update(watcher.name, %{filter: "none", daily_cap: 30}, opts)

      failure = {:provider_failure, %{kind: :network, message: "connection refused"}}

      assert {:error, :stale} =
               Repo.cues_call(CuesFilterSql, {:settle, "cfc_live", failure, at(1)},
                 server: ctx.repo
               )

      assert [["passed", "aborted"]] =
               CueFixtures.rows(
                 ctx.conn,
                 "SELECT d.state, c.result FROM cue_deliveries d " <>
                   "JOIN cue_filter_calls c ON c.id = 'cfc_live' WHERE d.id = ?",
                 [filtering]
               )
    end

    test "to none emits passed for each item it passes, as acceptance does", ctx do
      watcher = watcher!(ctx, "market-news", ["Pass earnings"])
      TelemetryCapture.attach([[:fermix, :cue, :lifecycle]], watcher_id: watcher.id)
      cue_ids = for _n <- 1..3, do: System.unique_integer([:positive])
      {pending_ids, [live_cue_id]} = Enum.split(cue_ids, 2)

      pending =
        Enum.map(pending_ids, &delivery!(ctx, watcher.id, "alpaca-news", "pending", cue_id: &1))

      live =
        delivery!(ctx, watcher.id, "alpaca-news", "filtering",
          filter_call_id: "cfc_live",
          cue_id: live_cue_id
        )

      waiting = pending ++ [live]
      opts = opts(ctx, 1) ++ [wake_scheduler: fn -> :ok end]

      assert {:ok, _updated} =
               Watchers.update(watcher.name, %{filter: "none", daily_cap: 30}, opts)

      for {id, cue_id} <- Enum.zip(waiting, cue_ids) do
        assert_received {:telemetry, [:fermix, :cue, :lifecycle], _m,
                         %{phase: :passed, delivery_id: ^id} = meta}

        assert {meta.cue_id, meta.source_ref, meta.reason} == {cue_id, "alpaca-news", "no filter"}
        refute Map.has_key?(meta, :session_id)
      end

      refute_received {:telemetry, [:fermix, :cue, :lifecycle], _m, %{phase: :passed}}
    end

    test "back to a model filter leaves passed items as they are", ctx do
      watcher = watcher!(ctx, "market-news", ["Pass earnings"])
      test_pid = self()
      opts = fn day -> opts(ctx, day) ++ [wake_scheduler: fn -> send(test_pid, :woken) end] end

      assert {:ok, %{echo: none_echo}} =
               Watchers.update(watcher.name, %{filter: "none", daily_cap: 30}, opts.(1))

      refute none_echo =~ "waited for the filter"
      refute_received :woken

      passed = delivery!(ctx, watcher.id, "alpaca-news", "passed")

      assert {:ok, %{echo: echo}} =
               Watchers.update(
                 watcher.name,
                 %{filter: "llm", purpose: "Market moves"},
                 opts.(2)
               )

      refute echo =~ "waited for the filter"
      refute_received :woken

      assert [["passed"]] =
               CueFixtures.rows(ctx.conn, "SELECT state FROM cue_deliveries WHERE id = ?", [
                 passed
               ])
    end
  end

  # --- helpers -----------------------------------------------------------------------

  defp opts(ctx, day), do: [repo: ctx.repo, now: at(day), scheduler: nil]

  defp at(day), do: DateTime.add(@t0, day, :day)

  defp private_context do
    %{
      agent_name: "main",
      conversation_key: {"telegram", "chat-1", :root},
      session_id: "telegram:chat-1:root",
      source_trust: :operator,
      memory_agent_id: "main"
    }
  end

  # A watcher written straight through the SQL module, with a cue-only task, so
  # these tests need nothing from the task surface.
  defp watcher!(ctx, name, instructions, sources \\ ["alpaca-news"], words \\ ["earnings"]) do
    {:ok, job} =
      JobsRegistry.create_cue_job(
        %{
          name: "task #{name}",
          task_prompt: "Report it.",
          delivery_mode: "channel",
          delivery_target: %{"platform" => "telegram", "chat_id" => "chat-1"},
          created_by_trust: "operator"
        },
        repo: ctx.repo,
        scheduler: nil
      )

    attrs = %{
      id: "cwt_#{name}_#{System.unique_integer([:positive])}",
      name: name,
      purpose: "What #{name} is for",
      filter: "llm",
      listen_for: words,
      task_job_id: job.id,
      created_from: "telegram:chat-1"
    }

    {:ok, watcher} =
      Repo.cues_call(
        CuesWatchersSql,
        {:insert_watcher, attrs, sources, instructions, @t0},
        server: ctx.repo
      )

    watcher
  end

  defp delivery!(ctx, watcher_id, ref, state, extra \\ []) do
    cue_id = Keyword.get_lazy(extra, :cue_id, fn -> System.unique_integer([:positive]) end)
    stamp = "2026-10-05T08:00:00.000000Z"

    CueFixtures.exec!(
      ctx.conn,
      "INSERT OR IGNORE INTO cues (id, source_ref, item_id, received_at, content_hash, snapshot, " <>
        "last_seen_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      [
        cue_id,
        ref,
        "item-#{cue_id}",
        stamp,
        "hash-#{cue_id}",
        Jason.encode!(%{"type" => "news", "subject" => "TSLA", "text" => "Item #{cue_id}"}),
        stamp
      ]
    )

    settled = if state in ["dropped", "acked", "exhausted", "expired"], do: stamp

    CueFixtures.exec!(
      ctx.conn,
      "INSERT INTO cue_deliveries (cue_id, watcher_id, source_ref, received_at, state, ready_at, " <>
        "valid_until, filter_call_id, settled_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [
        cue_id,
        watcher_id,
        ref,
        stamp,
        state,
        stamp,
        "2026-10-12T08:00:00.000000Z",
        Keyword.get(extra, :filter_call_id),
        settled
      ]
    )

    [[id]] = CueFixtures.rows(ctx.conn, "SELECT max(id) FROM cue_deliveries", [])
    id
  end

  defp restore_env(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore_env(key, value), do: Application.put_env(:fermix_core, key, value)
end
