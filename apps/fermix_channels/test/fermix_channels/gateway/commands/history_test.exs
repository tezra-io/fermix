defmodule FermixChannels.Gateway.Commands.HistoryTest do
  @moduledoc "MILESTONE_32 §5.3 — the /history owner management command."
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixChannels.Gateway.Authorization, as: IngressAuthorization
  alias FermixChannels.Gateway.Commands.History
  alias FermixChannels.Gateway.Message
  alias FermixCore.ComputerHistory.Config, as: ComputerHistoryConfig
  alias FermixCore.ComputerHistory.Ingest
  alias FermixCore.ComputerHistory.Spool
  alias FermixCore.Computers.Computer
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.SafeRm

  defp message(content) do
    Message.new!(%{
      id: "m1",
      content: content,
      sender: "a",
      channel: "telegram",
      chat_id: "c1",
      reply_target: "c1"
    })
  end

  defp reply_fn(pid), do: fn {:text, text} -> send(pid, {:reply, text}) end

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-history-cmd-#{unique}.db")
    repo_name = :"history_cmd_repo_#{unique}"
    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    original = Application.get_env(:fermix_core, :computer_history)
    Application.put_env(:fermix_core, :computer_history, enabled: true)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:fermix_core, :computer_history)
        value -> Application.put_env(:fermix_core, :computer_history, value)
      end

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    # This machine's own store, in a folder of its own; the home has no computer
    # and tells none unless a test says so.
    store = SafeRm.make_tmp_dir!("history_cmd_spool")
    on_exit(fn -> SafeRm.rm_rf!(store) end)

    spool =
      start_supervised!({Spool, path: Path.join([store, "device", "history.db"]), name: nil})

    ctx = %{
      computer_history_repo: repo_name,
      computer_history_spool: spool,
      computer_history_computers: [],
      computer_history_deliver: fn _opts -> flunk("no computer to tell") end
    }

    %{ctx: ctx, repo: repo_name, spool: spool}
  end

  test "metadata: owner-only, no aliases" do
    assert History.name() == "history"
    assert History.aliases() == []
    ctx = %{authorization: %IngressAuthorization{role: :operator, trust: :operator}}
    assert :ok = History.authorize(message(""), %{}, ctx)
    assert {:error, :unauthorized} = History.authorize(message(""), %{}, %{})
  end

  test "status replies with a non-empty overview", %{ctx: ctx} do
    assert :ok = History.execute(message("status"), reply_fn(self()), ctx)
    assert_receive {:reply, text}
    assert is_binary(text) and text != ""
  end

  # This system's recorder is injected, so the status body is asserted on every
  # host (the recorder fact itself is covered by ComputerHistory).
  defp macos_ctx(ctx), do: Map.put(ctx, :computer_history_recorder?, true)

  # Stand-in for the capture rail: the status line reads the live `Capturer` by
  # its module name, and these are the two dead ends an operator has to be told
  # about — a recorder that never answered, and one too old to have the verb.
  defmodule CapturerStub do
    @moduledoc false
    use GenServer

    def start_link(status),
      do: GenServer.start_link(__MODULE__, status, name: FermixCore.ComputerHistory.Capturer)

    @impl true
    def init(status), do: {:ok, status}

    @impl true
    def handle_call(:status, _from, status), do: {:reply, status, status}
  end

  defp capturer(mode, reason) do
    start_supervised!({CapturerStub, %{mode: mode, reason: reason, lock_holder: nil}})
  end

  defp status_reply(ctx) do
    assert :ok = History.execute(message("status"), reply_fn(self()), macos_ctx(ctx))
    assert_receive {:reply, text}
    text
  end

  test "status says the recorder never answered the start request", %{ctx: ctx} do
    capturer(:degraded, :handshake_timeout)

    assert status_reply(ctx) =~
             "Capture: degraded — the recorder never answered the start request " <>
               "(a compux upgrade or reinstall is needed)."
  end

  test "status names a pre-v6 recorder as the protocol mismatch it is", %{ctx: ctx} do
    capturer(:degraded, {:protocol_mismatch, %{required: 7, sidecar: :pre_v6}})

    assert status_reply(ctx) =~
             "Capture: degraded — recorder speaks a pre-v6 protocol ≠ required v7 " <>
               "(a compux upgrade is needed)."

    # A sidecar with no observe_start verb has no version to name, so the numeric
    # clause must not render "vpre_v6".
    refute status_reply(ctx) =~ "vpre_v6"
  end

  test "status says a recorder still handshaking is starting, not running", %{ctx: ctx} do
    capturer(:handshaking, nil)

    assert status_reply(ctx) =~ "Capture: starting the recorder."
  end

  # An unconfirmed `/history off` points the owner here, so a recorder too busy
  # to answer must not read as stopped.
  test "status says a recorder that does not answer may still be running", %{ctx: ctx} do
    capturer(:not_answering, nil)

    assert status_reply(ctx) =~ "Capture: not answering (it may still be running)."
  end

  test "status keeps naming the version a numeric mismatch reported", %{ctx: ctx} do
    capturer(:degraded, {:protocol_mismatch, %{required: 7, sidecar: 5}})

    assert status_reply(ctx) =~
             "Capture: degraded — recorder protocol v5 ≠ required v7 (a compux upgrade is needed)."
  end

  test "status reports the unsummarized backlog and how old it is", %{ctx: ctx, spool: spool} do
    now = System.system_time(:millisecond)

    events = [
      %{
        boot_id: "b1",
        source_seq: 1,
        ts: now - 2 * 3_600_000 - 600_000,
        type: "app.activated",
        bundle_id: "com.a"
      },
      %{boot_id: "b1", source_seq: 2, ts: now, type: "app.activated", bundle_id: "com.a"}
    ]

    assert {:ok, 2} = Spool.insert_events(events, server: spool)

    assert :ok = History.execute(message("status"), reply_fn(self()), macos_ctx(ctx))
    assert_receive {:reply, text}
    assert text =~ "Spool: 2 event(s), 2 unsummarized (oldest 2h 10m old)."
  end

  # M97 §8.1: a sitting that expired before it was sent is shown, never hidden.
  test "status counts the events that expired before they were sent", %{ctx: ctx, spool: spool} do
    events = [
      %{boot_id: "b1", source_seq: 1, ts: 1_000, type: "app.activated", bundle_id: "com.a"},
      %{boot_id: "b1", source_seq: 2, ts: 2_000, type: "app.activated", bundle_id: "com.a"}
    ]

    assert {:ok, 2} = Spool.insert_events(events, server: spool)
    assert {:ok, %{deleted: 2, unsent: 2}} = Spool.sweep_expired(10_000, server: spool)

    text = status_reply(ctx)
    assert text =~ "2 events expired before they were sent."
  end

  test "status states a zero backlog without an age", %{ctx: ctx} do
    assert :ok = History.execute(message("status"), reply_fn(self()), macos_ctx(ctx))
    assert_receive {:reply, text}
    assert text =~ "Spool: 0 event(s), 0 unsummarized. Last summarization:"
  end

  # Per-app coverage states (§8.4a): an app the driver can only see titles in
  # observes no typed text at all, which silently changes what history can answer.
  test "status names the apps only titles are observable in", %{ctx: ctx, spool: spool} do
    now = System.system_time(:millisecond)

    events = [
      %{
        boot_id: "b1",
        source_seq: 1,
        ts: now - 1_000,
        type: "observer.gap",
        bundle_id: "com.microsoft.VSCode",
        gap_reason: "title_only"
      },
      %{
        boot_id: "b1",
        source_seq: 2,
        ts: now - 500,
        type: "observer.gap",
        bundle_id: "com.docker.docker",
        gap_reason: "ax_refused:AXValueChanged"
      }
    ]

    assert {:ok, 2} = Spool.insert_events(events, server: spool)

    assert :ok = History.execute(message("status"), reply_fn(self()), macos_ctx(ctx))
    assert_receive {:reply, text}

    assert text =~ "Coverage: title-only for com.microsoft.VSCode"
    assert text =~ "no typed text is observable there"
    assert text =~ "AX refused for com.docker.docker"
  end

  # M32.1 §2.1: consent is per app and only per app, so the line has no site
  # count to report — a site clause here would contradict "every site in an
  # allowlisted browser is recorded".
  test "status counts allowlisted apps and never sites", %{ctx: ctx} do
    # The module setup establishes this key and restores it in its own on_exit.
    Application.put_env(:fermix_core, :computer_history,
      enabled: true,
      apps: ["com.apple.Safari", "com.microsoft.VSCode"]
    )

    text = status_reply(ctx)

    assert text =~ "Apps allowlisted: 2."
    refute text =~ "sites"
  end

  # M32.1 §2.2: a browser whose private-window state the recorder cannot classify
  # is a THIRD coverage state, and the owner has to be told that its addresses are
  # recorded while its typed text is not.
  test "status names all three coverage states distinctly", %{ctx: ctx, spool: spool} do
    now = System.system_time(:millisecond)

    events = [
      %{
        boot_id: "b1",
        source_seq: 1,
        ts: now - 1_000,
        type: "observer.gap",
        bundle_id: "com.microsoft.VSCode",
        gap_reason: "title_only"
      },
      %{
        boot_id: "b1",
        source_seq: 2,
        ts: now - 900,
        type: "observer.gap",
        bundle_id: "com.apple.Safari",
        gap_reason: "private_unknown"
      },
      %{
        boot_id: "b1",
        source_seq: 3,
        ts: now - 800,
        type: "observer.gap",
        bundle_id: "com.docker.docker",
        gap_reason: "ax_refused:AXValueChanged"
      }
    ]

    assert {:ok, 3} = Spool.insert_events(events, server: spool)

    text = status_reply(ctx)

    assert text =~ "title-only for com.microsoft.VSCode"
    assert text =~ "private-window state unknown for com.apple.Safari"
    assert text =~ "page URLs are recorded there; typed text is not"
    assert text =~ "AX refused for com.docker.docker"
  end

  test "status omits the coverage line when there are no coverage gaps", %{ctx: ctx} do
    assert :ok = History.execute(message("status"), reply_fn(self()), macos_ctx(ctx))
    assert_receive {:reply, text}

    refute text =~ "Coverage:"
  end

  test "status ignores coverage gaps older than the retention window", %{ctx: ctx, spool: spool} do
    stale = System.system_time(:millisecond) - :timer.hours(49)

    events = [
      %{
        boot_id: "b1",
        source_seq: 1,
        ts: stale,
        type: "observer.gap",
        bundle_id: "com.microsoft.VSCode",
        gap_reason: "title_only"
      }
    ]

    assert {:ok, 1} = Spool.insert_events(events, server: spool)

    assert :ok = History.execute(message("status"), reply_fn(self()), macos_ctx(ctx))
    assert_receive {:reply, text}

    refute text =~ "Coverage:"
  end

  # §9.4: the chain rule could deny every owner turn with nothing to read it from —
  # the incident that made a 53-tool turn refuse `recall_activity`. The chat line
  # is the surface that says so.
  test "status names the pinned chain and the failover it turns off", %{ctx: ctx} do
    establish_chain(openai: [api_key: "sk-test", primary: true], anthropic: [api_key: "sk-ant"])

    Application.put_env(:fermix_core, :computer_history,
      enabled: true,
      summarizer: :local,
      remote_summaries: [:openai]
    )

    assert :ok = History.execute(message("status"), reply_fn(self()), macos_ctx(ctx))
    assert_receive {:reply, text}

    assert text =~ "Chat: history turns run on openai;"
    assert text =~ "failover to"
    assert text =~ "anthropic"
  end

  test "status says why history cannot surface when the primary is not granted", %{ctx: ctx} do
    establish_chain(anthropic: [api_key: "sk-ant", primary: true])
    Application.put_env(:fermix_core, :computer_history, enabled: true, summarizer: :local)

    assert :ok = History.execute(message("status"), reply_fn(self()), macos_ctx(ctx))
    assert_receive {:reply, text}

    assert text =~ "Chat: history cannot surface"
    assert text =~ ~s(remote_summaries = ["anthropic"])
  end

  # The chain is resolved from three global env keys; a test that asserts a
  # resolved chain establishes all of them rather than reading what ran before.
  defp establish_chain(providers) do
    for {key, value} <- [providers: providers, agent: [], routing: []] do
      original = Application.get_env(:fermix_core, key)
      Application.put_env(:fermix_core, key, value)
      on_exit(fn -> restore_env(key, original) end)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore_env(key, value), do: Application.put_env(:fermix_core, key, value)

  # M97 §8.5: recorded on the home, which then takes no sitting stamped inside
  # it from any machine, and applied on this machine at once.
  test "pause persists a pause horizon", %{ctx: ctx, repo: repo, spool: spool} do
    assert :ok = History.execute(message("pause 30m"), reply_fn(self()), macos_ctx(ctx))
    assert_receive {:reply, text}
    assert text =~ "paused until"

    {:ok, state} = Spool.state(server: spool)
    assert is_binary(state.pause_until)

    assert {:ok, [%{kind: "pause"}]} =
             Repo.computer_history_home(:intervals_after, ["studio-7f3a", 0, 10], server: repo)
  end

  defp studio(connected?) do
    %Computer{
      device_id: "studio-7f3a",
      name: "studio Mac",
      connected: connected?,
      last_seen: DateTime.add(DateTime.utc_now(), -2, :hour),
      offers: [%{id: "history", state: :on, sentence: nil, detail: nil}]
    }
  end

  # M97 §8.5: one block per computer; what it last sent, and what it has not
  # applied yet.
  test "status shows a block per computer", %{ctx: ctx, repo: repo} do
    {:ok, _id} =
      Repo.computer_history_home(:pause_window, [1, 2, 1, :all], server: repo)

    :ok =
      Repo.computer_history_home(
        :record_submission,
        ["studio-7f3a", "summarized", nil, System.system_time(:millisecond) - 120_000],
        server: repo
      )

    ctx = ctx |> macos_ctx() |> Map.put(:computer_history_computers, [studio(false)])
    text = status_reply(ctx)

    assert text =~ "studio Mac: history on; away, last seen 2h"
    assert text =~ "last sitting 2m ago (summarized)"
    assert text =~ "1 purge or pause not yet applied there"
  end

  test "a purge and a pause from chat are told to the computers, and name who is away", ctx do
    test_pid = self()

    deliver = fn opts ->
      send(test_pid, {:delivered, opts})
      %{applied: ["studio Mac"], away: ["loft Linux"], failed: []}
    end

    ctx =
      ctx.ctx
      |> macos_ctx()
      |> Map.merge(%{
        computer_history_computers: [studio(true)],
        computer_history_deliver: deliver
      })

    assert :ok = History.execute(message("purge 1h"), reply_fn(self()), ctx)
    assert_receive {:reply, purged}
    assert_received {:delivered, [repo: _repo]}
    assert purged =~ "Applied on studio Mac."
    assert purged =~ "loft Linux gets it when next connected"
    assert purged =~ "your Fermix server's"

    assert :ok = History.execute(message("pause 1h"), reply_fn(self()), ctx)
    assert_receive {:reply, paused}
    assert paused =~ "paused until"
    assert paused =~ "loft Linux gets it when next connected"
  end

  # A machine store that answers every request with an error.
  defmodule FailingStore do
    @moduledoc false
    use GenServer

    def start_link(_arg), do: GenServer.start_link(__MODULE__, nil)

    @impl true
    def init(nil), do: {:ok, nil}

    @impl true
    def handle_call(_request, _from, state), do: {:reply, {:error, :injected}, state}
  end

  # The two stores share no transaction: once the home recorded a pause or a
  # purge it stands, and the reply says exactly what did not happen yet.
  test "a pause this Mac could not apply yet says the pause stands and what is owed", %{
    ctx: ctx,
    repo: repo
  } do
    ctx = ctx |> macos_ctx() |> Map.put(:computer_history_spool, start_supervised!(FailingStore))

    assert :ok = History.execute(message("pause 30m"), reply_fn(self()), ctx)
    assert_receive {:reply, text}

    assert text =~ "The pause is recorded on this home until"
    assert text =~ "nothing stamped inside it is summarized from any computer"
    assert text =~ "This Mac's recorder could not be paused yet (:injected)"
    assert text =~ "tries again every five minutes"
    refute text =~ "NOT paused"

    assert {:ok, [%{kind: "pause"}]} =
             Repo.computer_history_home(:intervals_after, ["", 0, 10], server: repo)
  end

  test "a purge this Mac could not apply yet says the purge stands and what is owed", %{ctx: ctx} do
    ctx = ctx |> macos_ctx() |> Map.put(:computer_history_spool, start_supervised!(FailingStore))

    assert :ok = History.execute(message("purge 1h"), reply_fn(self()), ctx)
    assert_receive {:reply, text}

    assert text =~ "Deleted 0 activity memory(ies) on this home, and the purge stands"
    assert text =~ "This Mac's raw record in that window could not be deleted yet (:injected)"
    refute text =~ "Purge failed"
  end

  test "a purge the home could not record says nothing was deleted", %{spool: spool} do
    unique = System.unique_integer([:positive])
    disabled = :"history_cmd_disabled_purge_#{unique}"
    start_supervised!({Repo, name: disabled, enabled: false}, id: :disabled_purge_repo)

    {:ok, 1} =
      Spool.insert_events([%{boot_id: "b1", source_seq: 1, ts: 1_000, type: "app.activated"}],
        server: spool
      )

    ctx = %{
      computer_history_repo: disabled,
      computer_history_spool: spool,
      computer_history_recorder?: true
    }

    assert :ok = History.execute(message("purge all"), reply_fn(self()), ctx)
    assert_receive {:reply, text}
    assert text =~ "Purge failed (:disabled): nothing was deleted."
    assert {:ok, 1} = Spool.count_events(server: spool)
  end

  # M97 §7.2, §8.5: narrowing from anywhere; off for a named computer stands on
  # the home at once and the computer applies it now, or once it is back.
  test "off naming a computer switches it off there, or says it will once it is back", %{
    ctx: ctx
  } do
    test_pid = self()

    switch_off = fn answer ->
      fn computer, opts ->
        send(test_pid, {:switch_off, computer.device_id, Keyword.fetch!(opts, :repo)})
        answer
      end
    end

    ctx =
      ctx
      |> Map.put(:computer_history_computers, [studio(true)])
      |> Map.put(:computer_history_switch_off, switch_off.(:done))

    assert :ok = History.execute(message("off Studio mac"), reply_fn(self()), ctx)
    assert_receive {:reply, done}
    assert_received {:switch_off, "studio-7f3a", _repo}
    assert done =~ "Computer history is off on studio Mac: it records nothing more"
    assert done =~ "only someone at studio Mac can switch it on again"
    assert ComputerHistoryConfig.enabled?()

    ctx = Map.put(ctx, :computer_history_switch_off, switch_off.(:away))
    assert :ok = History.execute(message("off studio-7f3a"), reply_fn(self()), ctx)
    assert_receive {:reply, away}
    assert away =~ "studio Mac is away. Its computer history goes off once it is back"

    ctx = Map.put(ctx, :computer_history_switch_off, switch_off.({:failed, :timeout}))
    assert :ok = History.execute(message("off studio Mac"), reply_fn(self()), ctx)
    assert_receive {:reply, failed}
    assert failed =~ "studio Mac could not be told now (:timeout)"
    assert failed =~ "summarizes nothing from it from now on"
  end

  test "off naming a computer the home does not have names the ones it has", %{ctx: ctx} do
    ctx = Map.put(ctx, :computer_history_computers, [studio(true)])

    assert :ok = History.execute(message("off attic pc"), reply_fn(self()), ctx)
    assert_receive {:reply, text}
    assert text == "This home has no computer named attic pc. Its computers: studio Mac."
  end

  # M97 §8.5: the home holds no raw record of a computer, so its status block
  # shows what the computer last reported, with its age.
  test "status shows what a computer last reported of its recorder, and an off owed", %{
    ctx: ctx,
    repo: repo
  } do
    now = System.system_time(:millisecond)

    report = %{
      "v" => 1,
      "recorder" => "running",
      "events" => 40,
      "unsent" => 12,
      "oldest_unsent_ts" => now - 3_900_000,
      "expired_unsent" => 2,
      "title_only" => 1,
      "private_unknown" => 0,
      "ax_refused" => 2
    }

    :ok =
      Repo.computer_history_home(
        :record_report,
        ["studio-7f3a", Jason.encode!(report), now - 240_000],
        server: repo
      )

    :ok = Repo.computer_history_home(:request_off, ["studio-7f3a", now], server: repo)

    ctx = Map.put(ctx, :computer_history_computers, [studio(true)])
    assert :ok = History.execute(message("status"), reply_fn(self()), ctx)
    assert_receive {:reply, text}

    assert text =~
             "recorder running, 12 event(s) unsent (oldest 1h 5m old), 2 expired before they " <>
               "were sent, coverage: title-only in 1 app, AX refused in 2 apps (reported 4m ago)"

    assert text =~ "asked to switch its history off, not yet done there"
  end

  test "status says when a computer has not reported yet", %{ctx: ctx} do
    ctx = Map.put(ctx, :computer_history_computers, [studio(false)])
    assert :ok = History.execute(message("status"), reply_fn(self()), ctx)
    assert_receive {:reply, text}
    assert text =~ "no recorder report yet"
  end

  test "pause without a duration shows usage", %{ctx: ctx} do
    assert :ok = History.execute(message("pause"), reply_fn(self()), ctx)
    assert_receive {:reply, text}
    assert text =~ "Usage"
  end

  test "pause is ENFORCED at ingest: events stamped before the horizon never reach the spool",
       %{ctx: ctx, spool: spool} do
    assert :ok = History.execute(message("pause 30m"), reply_fn(self()), macos_ctx(ctx))
    assert_receive {:reply, text}
    assert text =~ "paused until"

    event = %{boot_id: "b1", source_seq: 1, ts: 1_000, type: "app.activated", bundle_id: "com.a"}

    assert {:ok, %{written: 0, dropped: 1}} =
             Ingest.ingest([event], spool: spool, apps: ["com.a"])

    assert {:ok, 0} = Spool.count_events(server: spool)

    # The horizon passing resumes capture with no timer to arm — each batch
    # re-reads the persisted state. The event stamped before the horizon stays
    # out even when it is flushed after it (M32 inv. 12); one stamped after the
    # horizon is written. The pause's window is fenced too (M97 §8.5), so only
    # an event stamped after its end is.
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
    assert :ok = Spool.set_pause_until(past, server: spool)
    resumed = %{event | source_seq: 2, ts: System.system_time(:millisecond) + 31 * 60_000}

    assert {:ok, %{written: 1, dropped: 1}} =
             Ingest.ingest([event, resumed], spool: spool, apps: ["com.a"])

    assert {:ok, [%{source_seq: 2}]} =
             Spool.events_after(0, 10, server: spool)
  end

  test "an unparseable pause horizon fails CLOSED (capture stays off)", %{spool: spool} do
    assert :ok = Spool.set_pause_until("not-a-timestamp", server: spool)

    event = %{boot_id: "b1", source_seq: 1, ts: 1_000, type: "app.activated", bundle_id: "com.a"}

    assert {:ok, %{written: 0, dropped: 1}} =
             Ingest.ingest([event], spool: spool, apps: ["com.a"])

    assert {:ok, 0} = Spool.count_events(server: spool)
  end

  test "pause reports failure instead of claiming success when the persist fails", %{ctx: _ctx} do
    unique = System.unique_integer([:positive])
    disabled = :"history_cmd_disabled_repo_#{unique}"
    start_supervised!({Repo, name: disabled, enabled: false}, id: :disabled_repo)

    assert :ok =
             History.execute(
               message("pause 30m"),
               reply_fn(self()),
               %{computer_history_repo: disabled}
             )

    assert_receive {:reply, text}
    assert text =~ "NOT paused"
    refute text =~ "resumes automatically"
  end

  # §24.4: the two derived layers are what the owner actually asks about, and a
  # stalled roll-up or a sitting that never closed is invisible otherwise.
  test "status counts session notes and threads, the roll-up age and the open sitting", %{
    ctx: ctx,
    repo: repo,
    spool: spool
  } do
    now = System.system_time(:millisecond)

    {:ok, note_id} =
      Repo.computer_history_insert_memory(
        %{
          created_at: now - 7_200_000,
          provenance_from_ts: now - 7_200_000,
          provenance_to_ts: now - 7_000_000,
          summary: "drafted the plan",
          model: "llama3",
          event_count: 3
        },
        server: repo
      )

    assert {:ok, _counts} =
             Repo.computer_history_write_rollup(
               [
                 %{
                   subject: "Apollo migration",
                   summary: "Waiting on the restore check.",
                   source_ids: Jason.encode!([note_id]),
                   last_touched_ts: now - 7_000_000,
                   created_at: now - 3_600_000,
                   provenance_from_ts: now - 7_200_000,
                   provenance_to_ts: now - 7_000_000,
                   model: "llama3",
                   event_count: 3
                 }
               ],
               now - 3_600_000,
               %{purge_mark: 0, from_ts: now - 7_200_000, to_ts: now - 7_000_000},
               server: repo
             )

    assert :ok = Spool.set_open_since(now - 600_000, server: spool)

    assert :ok = History.execute(message("status"), reply_fn(self()), macos_ctx(ctx))
    assert_receive {:reply, text}

    assert text =~
             "Memory: 1 session note, 1 active thread (last roll-up 1h 0m old); " <>
               "open sitting for 10m."
  end

  test "status omits the roll-up and open-sitting clauses when there is nothing to say", %{
    ctx: ctx
  } do
    assert :ok = History.execute(message("status"), reply_fn(self()), macos_ctx(ctx))
    assert_receive {:reply, text}
    assert text =~ "Memory: 0 session notes, 0 active threads."
    refute text =~ "last roll-up"
    refute text =~ "open sitting"
  end

  test "purge erases the spool and acknowledges what it cannot reach", %{ctx: ctx, spool: spool} do
    events = [%{boot_id: "b1", source_seq: 1, ts: 1_000, type: "app.activated"}]
    {:ok, 1} = Spool.insert_events(events, server: spool)

    assert :ok = History.execute(message("purge all"), reply_fn(self()), ctx)
    assert_receive {:reply, text}
    assert text =~ "Purged"
    assert text =~ "cannot reach"
    # Threads drew on the purged window, so they go too. The next roll-up reads
    # only the surviving threads and the notes since the last roll-up, so an older
    # note that only a removed thread cited backs no thread again: the reply
    # promises exactly that much, not that the removed threads come back.
    assert text =~
             "the next roll-up rewrites the thread list from the surviving threads and the " <>
               "session notes written since the last roll-up"

    refute text =~ "rebuilt at the next roll-up from what remains"

    assert {:ok, 0} = Spool.count_events(server: spool)
  end

  test "purge with a bad window shows usage", %{ctx: ctx} do
    assert :ok = History.execute(message("purge forever"), reply_fn(self()), ctx)
    assert_receive {:reply, text}
    assert text =~ "Usage"
  end

  # Stand-in for the Controller behind the `:computer_history_controller` seam:
  # `:ok` confirms the stop (and tells the test it was asked), `:raise` crashes
  # mid-call.
  defmodule ControllerStub do
    @moduledoc false
    use GenServer

    def start_link({name, behaviour, test_pid}),
      do: GenServer.start_link(__MODULE__, {behaviour, test_pid}, name: name)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:reconcile, _from, {:ok, test_pid} = state) do
      send(test_pid, :reconciled)
      {:reply, :ok, state}
    end

    def handle_call(:reconcile, _from, {:raise, _test_pid}), do: raise("reconcile failed")
  end

  defp controller_stub(behaviour) do
    name = :"history_ctrl_stub_#{System.unique_integer([:positive])}"
    spec = {ControllerStub, {name, behaviour, self()}}
    start_supervised!(Supervisor.child_spec(spec, restart: :temporary))
    name
  end

  defp off_reply(ctx) do
    assert :ok = History.execute(message("off"), reply_fn(self()), ctx)
    assert_receive {:reply, text}
    text
  end

  test "off flips the enable bit and replies once the stop is confirmed", %{ctx: ctx} do
    ctx = ctx |> macos_ctx() |> Map.put(:computer_history_controller, controller_stub(:ok))

    text = off_reply(ctx)
    assert_received :reconciled
    assert text =~ "disabled — nothing new is captured"

    refute ComputerHistoryConfig.enabled?()
  end

  # CH-3: an exit of the reconcile call (no Controller, a crash mid-call, a
  # timeout) is not a confirmed stop, so the reply must not say capture stopped.
  test "off never says nothing is captured when no controller confirmed the stop", %{ctx: ctx} do
    absent = :"absent_ch_controller_#{System.unique_integer([:positive])}"
    ctx = ctx |> macos_ctx() |> Map.put(:computer_history_controller, absent)

    {text, log} = with_log(fn -> off_reply(ctx) end)

    refute text =~ "nothing new is captured"
    assert text =~ "could not be confirmed stopped"
    assert text =~ "the setting is saved"
    assert log =~ "reconcile_runtime failed"
    refute ComputerHistoryConfig.enabled?()
  end

  test "off never says nothing is captured when the controller crashes mid-call", %{ctx: ctx} do
    ctx = ctx |> macos_ctx() |> Map.put(:computer_history_controller, controller_stub(:raise))

    {text, log} = with_log(fn -> off_reply(ctx) end)

    refute text =~ "nothing new is captured"
    assert text =~ "could not be confirmed stopped"
    assert log =~ "reconcile failed"
    refute ComputerHistoryConfig.enabled?()
  end

  # The rail exists only where this system has a recorder, so elsewhere there is
  # nothing to stop: a second configuration, not a second path.
  test "off on a system with no recorder never calls the controller", %{ctx: ctx} do
    ctx =
      ctx
      |> Map.put(:computer_history_recorder?, false)
      |> Map.put(:computer_history_controller, controller_stub(:ok))

    text = off_reply(ctx)
    refute_received :reconciled
    assert text =~ "disabled — nothing new is captured"
    refute ComputerHistoryConfig.enabled?()
  end

  test "an unknown subcommand shows usage", %{ctx: ctx} do
    assert :ok = History.execute(message("wat"), reply_fn(self()), ctx)
    assert_receive {:reply, text}
    assert text =~ "Usage"
  end
end
