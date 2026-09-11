defmodule FermixChannels.Gateway.Commands.HistoryTest do
  @moduledoc "MILESTONE_32 §5.3 — the /history owner management command."
  use ExUnit.Case, async: false

  alias FermixChannels.Gateway.Authorization, as: IngressAuthorization
  alias FermixChannels.Gateway.Commands.History
  alias FermixChannels.Gateway.Message
  alias FermixCore.ComputerHistory.Config, as: ComputerHistoryConfig
  alias FermixCore.ComputerHistory.Ingest
  alias FermixCore.Memory.Repo

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

    %{ctx: %{computer_history_repo: repo_name}, repo: repo_name}
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

  # The macOS-only guard is injected, so the status body is asserted on every
  # host (the feature's own platform check is covered by ComputerHistory).
  defp macos_ctx(ctx), do: Map.put(ctx, :computer_history_macos?, true)

  test "status reports the unsummarized backlog and how old it is", %{ctx: ctx, repo: repo} do
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

    assert {:ok, 2} = Repo.computer_history_insert_events(events, server: repo)

    assert :ok = History.execute(message("status"), reply_fn(self()), macos_ctx(ctx))
    assert_receive {:reply, text}
    assert text =~ "Spool: 2 event(s), 2 unsummarized (oldest 2h 10m old)."
  end

  test "status states a zero backlog without an age", %{ctx: ctx} do
    assert :ok = History.execute(message("status"), reply_fn(self()), macos_ctx(ctx))
    assert_receive {:reply, text}
    assert text =~ "Spool: 0 event(s), 0 unsummarized. Last summarization:"
  end

  # Per-app coverage states (§8.4a): an app the driver can only see titles in
  # observes no typed text at all, which silently changes what history can answer.
  test "status names the apps only titles are observable in", %{ctx: ctx, repo: repo} do
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

    assert {:ok, 2} = Repo.computer_history_insert_events(events, server: repo)

    assert :ok = History.execute(message("status"), reply_fn(self()), macos_ctx(ctx))
    assert_receive {:reply, text}

    assert text =~ "Coverage: title-only for com.microsoft.VSCode"
    assert text =~ "no typed text is observable there"
    assert text =~ "AX refused for com.docker.docker"
  end

  test "status omits the coverage line when there are no coverage gaps", %{ctx: ctx} do
    assert :ok = History.execute(message("status"), reply_fn(self()), macos_ctx(ctx))
    assert_receive {:reply, text}

    refute text =~ "Coverage:"
  end

  test "status ignores coverage gaps older than the retention window", %{ctx: ctx, repo: repo} do
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

    assert {:ok, 1} = Repo.computer_history_insert_events(events, server: repo)

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

  test "pause persists a pause horizon", %{ctx: ctx, repo: repo} do
    assert :ok = History.execute(message("pause 30m"), reply_fn(self()), ctx)
    assert_receive {:reply, text}
    assert text =~ "paused until"

    {:ok, state} = Repo.computer_history_fetch_state(server: repo)
    assert is_binary(state.pause_until)
  end

  test "pause without a duration shows usage", %{ctx: ctx} do
    assert :ok = History.execute(message("pause"), reply_fn(self()), ctx)
    assert_receive {:reply, text}
    assert text =~ "Usage"
  end

  test "pause is ENFORCED at ingest: events inside the window never reach the spool",
       %{ctx: ctx, repo: repo} do
    assert :ok = History.execute(message("pause 30m"), reply_fn(self()), ctx)
    assert_receive {:reply, text}
    assert text =~ "paused until"

    event = %{boot_id: "b1", source_seq: 1, ts: 1_000, type: "app.activated", bundle_id: "com.a"}

    assert {:ok, %{written: 0, dropped: 1}} =
             Ingest.ingest([event], repo: repo, apps: ["com.a"], sites: [])

    assert {:ok, 0} = Repo.computer_history_count_events(server: repo)

    # The horizon passing resumes capture with no timer to arm — each batch
    # re-reads the persisted state.
    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
    assert :ok = Repo.computer_history_set_pause_until(past, server: repo)

    assert {:ok, %{written: 1, dropped: 0}} =
             Ingest.ingest([event], repo: repo, apps: ["com.a"], sites: [])

    assert {:ok, 1} = Repo.computer_history_count_events(server: repo)
  end

  test "an unparseable pause horizon fails CLOSED (capture stays off)", %{repo: repo} do
    assert :ok = Repo.computer_history_set_pause_until("not-a-timestamp", server: repo)

    event = %{boot_id: "b1", source_seq: 1, ts: 1_000, type: "app.activated", bundle_id: "com.a"}

    assert {:ok, %{written: 0, dropped: 1}} =
             Ingest.ingest([event], repo: repo, apps: ["com.a"], sites: [])

    assert {:ok, 0} = Repo.computer_history_count_events(server: repo)
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

  test "purge erases the spool and acknowledges what it cannot reach", %{ctx: ctx, repo: repo} do
    events = [%{boot_id: "b1", source_seq: 1, ts: 1_000, type: "app.activated"}]
    {:ok, 1} = Repo.computer_history_insert_events(events, server: repo)

    assert :ok = History.execute(message("purge all"), reply_fn(self()), ctx)
    assert_receive {:reply, text}
    assert text =~ "Purged"
    assert text =~ "cannot reach"

    assert {:ok, 0} = Repo.computer_history_count_events(server: repo)
  end

  test "purge with a bad window shows usage", %{ctx: ctx} do
    assert :ok = History.execute(message("purge forever"), reply_fn(self()), ctx)
    assert_receive {:reply, text}
    assert text =~ "Usage"
  end

  test "off flips the enable bit (un-advertises next turn)", %{ctx: ctx} do
    assert :ok = History.execute(message("off"), reply_fn(self()), ctx)
    assert_receive {:reply, text}
    assert text =~ "disabled"

    refute ComputerHistoryConfig.enabled?()
  end

  test "an unknown subcommand shows usage", %{ctx: ctx} do
    assert :ok = History.execute(message("wat"), reply_fn(self()), ctx)
    assert_receive {:reply, text}
    assert text =~ "Usage"
  end
end
