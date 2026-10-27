defmodule FermixCore.Tools.ManageWatcherTest do
  # The advertisement test sets `[fermix_core.cues]` and `[fermix_core.memory]`,
  # both globals.
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.Cues.Item
  alias FermixCore.Cues.RecentDrops
  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesWatchersSql
  alias FermixCore.Tools.ListJobs
  alias FermixCore.Tools.ManageWatcher
  alias FermixCore.Tools.RemoveJob
  alias FermixCore.Tools.UpdateJob
  alias FermixTestSupport.CueFixtures
  alias FermixTestSupport.TelemetryCapture

  @t0 ~U[2026-10-05 09:00:00.000000Z]
  @tainted "This turn has read outside text, so it cannot change a watcher; ask for the change " <>
             "again in a new message."
  @shared "Create the watcher from a private chat with Fermix."
  @needs_words "A watcher that filters needs words to listen for: list the names, products, " <>
                 "abbreviations and phrases an item it should see would contain, as listen_for."

  setup do
    %{repo: repo, conn: conn} = CueFixtures.start_repo("manage_watcher")
    %{repo: repo, conn: conn}
  end

  describe "who may call it (C42)" do
    test "a scheduled run is not offered it and gets a refusal with no cue text", ctx do
      watcher!(ctx, "market-news", ["Pass earnings"])
      session = "job_run_#{System.unique_integer([:positive])}"
      TelemetryCapture.attach([[:fermix, :tool, :exec]], session_id: session)

      context =
        ctx
        |> turn(session_id: session, trigger: "schedule")
        |> Map.delete(:computer_use_origin)

      refute ManageWatcher.advertise?(context)

      assert {:ok, result} =
               ManageWatcher.execute(%{"action" => "show", "name" => "market-news"}, context)

      assert result.success == false
      assert result.output == ""
      assert result.error =~ "manage_watcher is available only when the owner asks"
      refute result.error =~ "Pass earnings"

      assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements,
                      %{tool: "manage_watcher", success: false}}

      refute_received {:telemetry, [:fermix, :tool, :exec], _measurements, _metadata}
    end

    # The cue tree starts only at boot: the switch flipped live neither offers
    # the tool with no tree behind it nor withdraws it from a running tree.
    test "offered on an attended operator turn only while the cue tree runs", ctx do
      cues = Application.get_env(:fermix_core, :cues)
      memory = Application.get_env(:fermix_core, :memory)

      on_exit(fn ->
        Application.put_env(:fermix_core, :cues, cues || [])
        Application.put_env(:fermix_core, :memory, memory)
      end)

      Application.put_env(:fermix_core, :cues, enabled: true)
      Application.put_env(:fermix_core, :memory, Keyword.put(memory, :enabled, true))
      refute ManageWatcher.advertise?(turn(ctx, []))

      # A stand-in for the tree's supervisor, registered by this test's process.
      true = Process.register(self(), FermixCore.Cues.Supervisor)
      Application.put_env(:fermix_core, :cues, enabled: false)
      assert ManageWatcher.advertise?(turn(ctx, []))
      refute ManageWatcher.advertise?(turn(ctx, source_trust: :guest))
      refute ManageWatcher.advertise?(turn(ctx, subagent_depth: 1))
      Process.unregister(FermixCore.Cues.Supervisor)
    end
  end

  describe "reactions and consent (C09, S6)" do
    test "a drop example from a tainted private turn is stored; show returns none of its text",
         ctx do
      watcher = watcher!(ctx, "market-news", ["Pass earnings"])
      cue_id = delivered!(ctx, watcher.id)

      assert {:ok, %{success: true, output: echo}} =
               ManageWatcher.execute(
                 %{
                   "action" => "add_example",
                   "name" => "market-news",
                   "cue_id" => cue_id,
                   "label" => "drop"
                 },
                 turn(ctx, outside_sources: MapSet.new([{:tool, "list_cues"}]))
               )

      assert echo =~ "Stored cue #{cue_id} as a drop example for watcher market-news"

      assert {:ok, %{success: true, output: shown}} =
               ManageWatcher.execute(
                 %{"action" => "show", "name" => "market-news"},
                 turn(ctx, [])
               )

      assert shown =~ ~r/: drop, cue #{cue_id}, stored \w+day, \w+ \d{1,2}, \d{4} at /
      refute shown =~ "Analyst upgrades TSLA"
    end

    test "reading the list and changing it in the same turn is allowed; another read is not",
         ctx do
      watcher!(ctx, "market-news", ["Include TSLA"])

      args = %{
        "action" => "add_instructions",
        "name" => "market-news",
        "instructions" => ["Ignore TSLA"],
        "remove" => [1]
      }

      # `show` returns only Fermix's text and the owner's own instructions, so it
      # leaves the turn untainted and the change in the same turn is consent.
      assert {:ok, %{success: true}} =
               ManageWatcher.execute(
                 %{"action" => "show", "name" => "market-news"},
                 turn(ctx, [])
               )

      assert {:ok, %{success: true, output: "Added 2: Ignore TSLA. Removed 1: Include TSLA."}} =
               ManageWatcher.execute(args, turn(ctx, []))

      read_more = turn(ctx, outside_sources: MapSet.new([{:tool, "list_cues"}]))

      assert {:ok, %{success: false, error: @tainted}} =
               ManageWatcher.execute(
                 %{args | "instructions" => ["Ignore NVDA"], "remove" => []},
                 read_more
               )
    end

    test "an instruction from an untainted turn is added, the others unchanged, echoed", ctx do
      watcher!(ctx, "market-news", ["Pass earnings"])

      assert {:ok, %{success: true, output: "Added 2: Stop sending analyst notes."}} =
               ManageWatcher.execute(
                 %{
                   "action" => "add_instructions",
                   "name" => "market-news",
                   "instructions" => ["Stop sending analyst notes"]
                 },
                 turn(ctx, [])
               )

      assert {:ok, %{output: shown}} =
               ManageWatcher.execute(
                 %{"action" => "show", "name" => "market-news"},
                 turn(ctx, [])
               )

      assert shown =~
               "1. Pass earnings (added Monday, October 5, 2026 at 9:00 AM UTC from telegram:chat-1)"

      assert shown =~ "2. Stop sending analyst notes (added"
    end

    test "the same edit from a turn that read list_cues is refused", ctx do
      watcher!(ctx, "market-news", ["Pass earnings"])
      tainted = turn(ctx, outside_sources: MapSet.new([{:tool, "list_cues"}]))

      assert {:ok, %{success: false, error: @tainted}} =
               ManageWatcher.execute(
                 %{
                   "action" => "add_instructions",
                   "name" => "market-news",
                   "instructions" => ["Stop sending analyst notes"]
                 },
                 tainted
               )

      assert [[1]] =
               CueFixtures.rows(ctx.conn, "SELECT count(*) FROM cue_watcher_instructions", [])
    end

    test "a pass example needs the consent turn", ctx do
      watcher = watcher!(ctx, "market-news", ["Pass earnings"])
      cue_id = delivered!(ctx, watcher.id)

      args = %{
        "action" => "add_example",
        "name" => "market-news",
        "cue_id" => cue_id,
        "label" => "pass"
      }

      assert {:ok, %{success: false, error: @tainted}} =
               ManageWatcher.execute(
                 args,
                 turn(ctx, outside_sources: MapSet.new([{:tool, "list_cues"}]))
               )

      assert {:ok, %{success: true}} = ManageWatcher.execute(args, turn(ctx, []))
    end

    test "a drop example from a group chat is refused", ctx do
      watcher = watcher!(ctx, "market-news", ["Pass earnings"])
      cue_id = delivered!(ctx, watcher.id)

      assert {:ok,
              %{success: false, error: "Change the watcher from a private chat with Fermix."}} =
               ManageWatcher.execute(
                 %{
                   "action" => "add_example",
                   "name" => "market-news",
                   "cue_id" => cue_id,
                   "label" => "drop"
                 },
                 turn(ctx, chat_type: "group")
               )
    end
  end

  describe "where a watcher may be created (C15)" do
    test "a Telegram group and a Slack channel mention are refused", ctx do
      group = turn(ctx, chat_type: "group")

      slack =
        turn(ctx,
          chat_type: nil,
          channel: "slack",
          source_channel: "slack",
          conversation_key: {"slack", "C123", :root}
        )

      for context <- [group, slack] do
        assert {:ok, %{success: false, error: @shared}} =
                 ManageWatcher.execute(create_args(), context)
      end

      assert {:ok, []} = JobsRegistry.list_jobs(repo: ctx.repo)
    end

    test "fermix ask is refused without an explicit delivery target", ctx do
      cli =
        turn(ctx,
          channel: "cli",
          source_channel: "cli",
          conversation_key: {"cli", "cli", :root}
        )

      assert {:ok, %{success: false, error: error}} = ManageWatcher.execute(create_args(), cli)
      assert error =~ ~s(delivery_mode "origin" cannot be used from the command line)
      assert error =~ "Pass an explicit delivery_target on a configured channel instead."
    end

    test "delivery none is refused", ctx do
      args = Map.put(create_args(), "delivery_mode", "none")

      assert {:ok,
              %{success: false, error: "A watcher's task must reach you: pick where it reports."}} =
               ManageWatcher.execute(args, turn(ctx, []))
    end
  end

  describe "creating" do
    test "from a private chat the new task reports there and Fermix echoes the setup", ctx do
      cues = Application.get_env(:fermix_core, :cues)
      on_exit(fn -> Application.put_env(:fermix_core, :cues, cues || []) end)
      Application.put_env(:fermix_core, :cues, [])

      assert {:ok, %{success: true, output: echo}} =
               ManageWatcher.execute(create_args(), turn(ctx, []))

      assert echo =~
               ~r/^Watcher market-news is set up: it listens to alpaca-news, filters with the Cues filter model \(the main model unless settings name another\), and wakes job \S+ \(watcher market-news\), which reports to Telegram chat-1\./

      assert echo =~ "Purpose: Market moves that need me"
      assert echo =~ "Listens for: earnings, guidance cut"
      assert echo =~ "Instructions:\n1. Pass earnings surprises"
      assert echo =~ "Missing: alpaca-news is not set up yet; add it in settings."

      assert {:ok, [job]} = JobsRegistry.list_jobs(repo: ctx.repo)
      assert job.schedule_kind == "cue"
      assert job.delivery_mode == "origin"
      assert job.delivery_target["platform"] == "telegram"
      assert job.delivery_target["chat_id"] == "chat-1"

      assert [["telegram:chat-1"]] =
               CueFixtures.rows(ctx.conn, "SELECT created_from FROM cue_watchers", [])

      assert [["telegram:chat-1"]] =
               CueFixtures.rows(ctx.conn, "SELECT added_from FROM cue_watcher_instructions", [])
    end

    test "a report target on a channel cue runs cannot use yet is refused", ctx do
      args =
        Map.put(create_args(), "delivery_target", %{
          "platform" => "imessage",
          "chat_id" => "+15550100"
        })

      assert {:ok, %{success: false, error: error}} = ManageWatcher.execute(args, turn(ctx, []))

      assert error ==
               "Watcher reports cannot go to iMessage yet; pick Telegram, Slack, Discord, " <>
                 "WhatsApp, the phone or the Mac app."

      assert {:ok, []} = JobsRegistry.list_jobs(repo: ctx.repo)
    end

    # The Mac app is the owner's own device, and its channel fetches no preview
    # for a cue run's message, so an owner who uses only the app can set one up.
    test "a watcher created from the Mac app reports to the Mac app", ctx do
      companion =
        turn(ctx,
          channel: "companion",
          source_channel: "companion",
          chat_type: nil,
          conversation_key: {"companion", "mac-1", :root}
        )

      assert {:ok, %{success: true}} = ManageWatcher.execute(create_args(), companion)
      assert {:ok, [job]} = JobsRegistry.list_jobs(repo: ctx.repo)
      assert job.delivery_target["platform"] == "companion"
    end

    test "linking a job echoes the tools a cue run will not have", ctx do
      {:ok, job} = cue_job(ctx, "triage", allowed_tools: ["web_search", "file_read"])

      args =
        create_args()
        |> Map.delete("task")
        |> Map.put("task_job_id", job.id)

      assert {:ok, %{success: true, output: echo}} = ManageWatcher.execute(args, turn(ctx, []))
      assert echo =~ "A cue run will not have web_search: it reads and reports"

      second = args |> Map.put("name", "second-watch")

      assert {:ok,
              %{success: false, error: "That job is already the task of watcher market-news."}} =
               ManageWatcher.execute(second, turn(ctx, []))
    end

    test "a job with a schedule of its own cannot be a task", ctx do
      {:ok, job} =
        JobsRegistry.create_job(
          %{
            name: "weather",
            schedule: "every 15 minutes",
            task_prompt: "Weather.",
            created_by_trust: "operator"
          },
          repo: ctx.repo,
          scheduler: nil
        )

      args = create_args() |> Map.delete("task") |> Map.put("task_job_id", job.id)

      assert {:ok, %{success: false, error: error}} = ManageWatcher.execute(args, turn(ctx, []))

      assert error ==
               "Job #{job.id} runs on a schedule; a watcher's task must be a job that runs on cues."
    end

    test "every watcher filters with the one Cues filter model; a model per watcher is not taken",
         ctx do
      args =
        Map.merge(create_args(), %{"filter_provider" => "openai", "filter_model" => "gpt-5-mini"})

      assert {:ok, %{success: true, output: echo}} = ManageWatcher.execute(args, turn(ctx, []))

      assert echo =~
               "filters with the Cues filter model (the main model unless settings name another)"

      refute echo =~ "gpt-5-mini"
      refute Map.has_key?(ManageWatcher.parameters().properties, :filter_model)
    end
  end

  describe "words to listen for (M60_CUE_INTAKE_AT_SCALE.md §3.1)" do
    test "a watcher that filters needs words; the rules' refusals come back as written", ctx do
      no_words = Map.delete(create_args(), "listen_for")

      assert {:ok, %{success: false, error: @needs_words}} =
               ManageWatcher.execute(no_words, turn(ctx, []))

      assert {:ok, %{success: false, error: "Give the words to listen for as a list."}} =
               ManageWatcher.execute(Map.put(no_words, "listen_for", "TSMC"), turn(ctx, []))

      assert {:ok, []} = JobsRegistry.list_jobs(repo: ctx.repo)
      assert ManageWatcher.description() =~ "never ask the owner for a pattern"
    end

    test "a watcher with no filter cannot listen to a stream", ctx do
      cues = Application.get_env(:fermix_core, :cues)
      on_exit(fn -> Application.put_env(:fermix_core, :cues, cues || []) end)

      Application.put_env(:fermix_core, :cues,
        sources: %{"bsky" => %{kind: :stream, url: "wss://jetstream.example.org/subscribe"}}
      )

      args =
        create_args()
        |> Map.drop(["purpose", "instructions", "listen_for"])
        |> Map.merge(%{"filter" => "none", "daily_cap" => "20", "sources" => ["bsky"]})

      assert {:ok, %{success: false, error: error}} = ManageWatcher.execute(args, turn(ctx, []))
      assert error =~ "A watcher with no filter cannot listen to a stream (bsky)"
    end

    test "an update replaces the words; show lists them and what a watcher needs", ctx do
      watcher!(ctx, "market-news", [], [])

      assert {:ok, %{success: true, output: shown}} =
               ManageWatcher.execute(
                 %{"action" => "show", "name" => "market-news"},
                 turn(ctx, [])
               )

      assert shown =~
               "It needs words to listen for, and no item reaches it until an update gives it some."

      assert {:ok, %{success: true, output: "market-news: needs words to listen for" <> _}} =
               ManageWatcher.execute(%{"action" => "list"}, turn(ctx, []))

      update = %{"action" => "update", "name" => "market-news", "listen_for" => ["NVDA", "AMD"]}

      assert {:ok, %{success: true, output: echo}} = ManageWatcher.execute(update, turn(ctx, []))

      assert echo ==
               "Watcher market-news changed: new words to listen for.\nListens for: NVDA, AMD"

      assert {:ok, %{success: true, output: shown}} =
               ManageWatcher.execute(
                 %{"action" => "show", "name" => "market-news"},
                 turn(ctx, [])
               )

      assert "Listens for: NVDA, AMD" in String.split(shown, "\n")
      refute shown =~ "It needs words"
    end

    test "a stream watcher's recent drop is labelled by its key", ctx do
      watcher = watcher!(ctx, "market-news", [])
      RecentDrops.new_table()

      {:ok, item} =
        Item.new(%{item_id: "n-1", type: "news", data: %{"text" => "NVDA guidance raised"}}, @t0)

      drop = RecentDrops.put(watcher.id, item, "alpaca-news", "Not a market move.", @t0)

      args = %{
        "action" => "add_example",
        "name" => "market-news",
        "drop_key" => drop.key,
        "label" => "pass"
      }

      assert {:ok, %{success: true, output: echo}} = ManageWatcher.execute(args, turn(ctx, []))
      assert echo =~ ~r/^Stored cue \d+ as a pass example for watcher market-news/

      both = Map.put(args, "cue_id", 41)

      assert {:ok, %{success: false, error: "Name the item by cue_id or by drop_key, not both."}} =
               ManageWatcher.execute(both, turn(ctx, []))
    end
  end

  describe "the jobs a watcher wakes" do
    test "remove_job refuses a watched job and removes an unwatched one", ctx do
      watcher = watcher!(ctx, "market-news", [])
      {:ok, spare} = cue_job(ctx, "spare")

      assert {:ok,
              %{success: false, error: "Remove the watcher first, or link it to another job."}} =
               RemoveJob.execute(%{"job_id" => watcher.task_job_id}, turn(ctx, []))

      assert {:ok, _job} = JobsRegistry.get_job(watcher.task_job_id, repo: ctx.repo)
      assert {:ok, %{success: true}} = RemoveJob.execute(%{"job_id" => spare.id}, turn(ctx, []))
    end

    test "update_job on a watched job needs the consent turn", ctx do
      watcher = watcher!(ctx, "market-news", [])
      args = %{"job_id" => watcher.task_job_id, "task" => "Summarise it in one line."}

      assert {:ok, %{success: false, error: error}} =
               UpdateJob.execute(
                 args,
                 # The consent refusal, not the host-command one: a host whose
                 # kernel holds commands.
                 turn(ctx,
                   outside_sources: MapSet.new([{:tool, "list_cues"}]),
                   os_sandbox: [os: {:unix, :darwin}]
                 )
               )

      assert error =~ "Watcher market-news wakes this job"
      assert {:ok, job} = JobsRegistry.get_job(watcher.task_job_id, repo: ctx.repo)
      assert job.task_prompt == "Report it."

      assert {:ok, %{success: true}} = UpdateJob.execute(args, turn(ctx, []))

      assert {:ok, %{task_prompt: "Summarise it in one line."}} =
               JobsRegistry.get_job(watcher.task_job_id, repo: ctx.repo)
    end

    test "list_jobs labels a watched job with its watcher's name", ctx do
      watcher = watcher!(ctx, "market-news", [])
      {:ok, spare} = cue_job(ctx, "spare")

      assert {:ok, %{output: output}} = ListJobs.execute(%{}, turn(ctx, []))
      jobs = Map.new(Jason.decode!(output)["jobs"], &{&1["id"], &1})

      assert jobs[watcher.task_job_id]["schedule_label"] ==
               "runs on cues from watcher market-news"

      assert jobs[spare.id]["schedule_label"] == "runs on cues"
    end
  end

  describe "removal through the tool" do
    test "removing needs consent and is refused while a delivery is being filtered", ctx do
      watcher = watcher!(ctx, "market-news", [])
      delivered!(ctx, watcher.id, "filtering")
      args = %{"action" => "remove", "name" => "market-news"}

      assert {:ok, %{success: false, error: @tainted}} =
               ManageWatcher.execute(args, turn(ctx, outside_sources: MapSet.new([{:tool, "x"}])))

      assert {:ok, %{success: false, error: error}} = ManageWatcher.execute(args, turn(ctx, []))
      assert error =~ "is filtering an item or running its task right now"
    end
  end

  test "manage_watcher returns no outside text, so reading it does not taint the turn" do
    capability = Builtin.from_tool_module(ManageWatcher)
    assert UntrustedContent.outside_source(capability) == nil
    assert capability.owner_only?
    assert capability.policy_class == :read_write
  end

  # --- helpers -------------------------------------------------------------------------

  defp turn(ctx, overrides) do
    Map.merge(
      %{
        agent_name: "main",
        memory_repo: ctx.repo,
        memory_agent_id: "main",
        conversation_key: {"telegram", "chat-1", :root},
        session_id: "telegram:chat-1:root",
        source_trust: :operator,
        computer_use_origin: :interactive,
        chat_type: "private",
        channel: "telegram",
        source_channel: "telegram",
        outside_sources: MapSet.new(),
        scheduler: nil
      },
      Map.new(overrides)
    )
  end

  defp create_args do
    %{
      "action" => "create",
      "name" => "market-news",
      "filter" => "llm",
      "purpose" => "Market moves that need me",
      "listen_for" => ["earnings", "guidance cut"],
      "instructions" => ["Pass earnings surprises"],
      "sources" => ["alpaca-news"],
      "task" => "Tell me what it means for my positions."
    }
  end

  defp cue_job(ctx, name, extra \\ []) do
    JobsRegistry.create_cue_job(
      Map.merge(
        %{
          name: "task #{name}",
          task_prompt: "Report it.",
          delivery_mode: "channel",
          delivery_target: %{"platform" => "telegram", "chat_id" => "chat-1"},
          created_by_trust: "operator"
        },
        Map.new(extra)
      ),
      repo: ctx.repo,
      scheduler: nil
    )
  end

  defp watcher!(ctx, name, instructions, words \\ ["earnings"]) do
    {:ok, job} = cue_job(ctx, name)

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
        {:insert_watcher, attrs, ["alpaca-news"], instructions, @t0},
        server: ctx.repo
      )

    watcher
  end

  defp delivered!(ctx, watcher_id, state \\ "dropped") do
    cue_id = System.unique_integer([:positive])
    stamp = "2026-10-05T08:00:00.000000Z"

    snapshot =
      Jason.encode!(%{"type" => "news", "subject" => "TSLA", "text" => "Analyst upgrades TSLA"})

    CueFixtures.exec!(
      ctx.conn,
      "INSERT INTO cues (id, source_ref, item_id, received_at, content_hash, snapshot, last_seen_at) " <>
        "VALUES (?, 'alpaca-news', ?, ?, ?, ?, ?)",
      [cue_id, "item-#{cue_id}", stamp, "hash-#{cue_id}", snapshot, stamp]
    )

    settled = if state == "dropped", do: stamp
    filter_call = if state == "filtering", do: "cfc_test"

    CueFixtures.exec!(
      ctx.conn,
      "INSERT INTO cue_deliveries (cue_id, watcher_id, source_ref, received_at, state, ready_at, " <>
        "valid_until, settled_at, filter_call_id) VALUES (?, ?, 'alpaca-news', ?, ?, ?, ?, ?, ?)",
      [
        cue_id,
        watcher_id,
        stamp,
        state,
        stamp,
        "2026-10-12T08:00:00.000000Z",
        settled,
        filter_call
      ]
    )

    cue_id
  end
end
