defmodule FermixCore.Cues.NoticesTest do
  # The channel stubs report to a registered name, a VM-global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Cues.Notices
  alias FermixCore.Cues.Watchers
  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesWatchersSql
  alias FermixTestSupport.CueFixtures

  @sink :cue_notices_test_sink
  @t0 ~U[2026-10-05 09:00:00.000000Z]

  defmodule SinkAdapter do
    @moduledoc false
    def send_message(destination, text, opts) do
      send(:cue_notices_test_sink, {:sent, destination, text, opts})
      :ok
    end
  end

  defmodule DownAdapter do
    @moduledoc false
    def send_message(_destination, _text, _opts), do: {:error, :channel_down}
  end

  setup do
    Process.register(self(), @sink)
    %{repo: repo, conn: conn} = CueFixtures.start_repo("notices")
    watcher = watcher!(repo, "market-news")
    %{repo: repo, conn: conn, watcher: watcher}
  end

  describe "watcher notices" do
    test "a hold is told once, to the task's target, with link previews off", ctx do
      assert :sent = Notices.watcher(ctx.watcher.id, :filter_held, %{waiting: 12}, opts(ctx, 0))
      assert_receive {:sent, "chat-9", text, send_opts}

      assert text ==
               "Watcher market-news: its filter model cannot be reached; 12 items are waiting. " <>
                 "Fermix tries again every 10 minutes."

      assert Keyword.get(send_opts, :link_previews) == false

      assert :already_sent =
               Notices.watcher(ctx.watcher.id, :filter_held, %{waiting: 15}, opts(ctx, 0))

      refute_received {:sent, _destination, _text, _opts}
    end

    test "recovery is told once, and only after a hold was told", ctx do
      assert :already_sent = Notices.watcher(ctx.watcher.id, :filter_recovered, %{}, opts(ctx, 0))

      assert :sent = Notices.watcher(ctx.watcher.id, :filter_held, %{}, opts(ctx, 0))
      assert :sent = Notices.watcher(ctx.watcher.id, :filter_recovered, %{}, opts(ctx, 0))
      assert :already_sent = Notices.watcher(ctx.watcher.id, :filter_recovered, %{}, opts(ctx, 0))

      assert_receive {:sent, _destination, "Watcher market-news: its filter model cannot" <> _, _}

      assert_receive {:sent, _destination, "Watcher market-news: its filter model answers" <> _,
                      _}

      refute_received {:sent, _destination, _text, _opts}

      assert :sent = Notices.watcher(ctx.watcher.id, :filter_held, %{}, opts(ctx, 0))
    end

    test "a failing filter is told at most once per watcher per UTC day", ctx do
      assert :sent =
               Notices.watcher(
                 ctx.watcher.id,
                 :filter_failed,
                 %{},
                 opts_at(ctx, ~U[2026-10-05 00:10:00Z])
               )

      assert :already_sent =
               Notices.watcher(
                 ctx.watcher.id,
                 :filter_failed,
                 %{},
                 opts_at(ctx, ~U[2026-10-05 23:50:00Z])
               )

      assert :sent =
               Notices.watcher(
                 ctx.watcher.id,
                 :filter_failed,
                 %{},
                 opts_at(ctx, ~U[2026-10-06 00:05:00Z])
               )
    end

    test "a reached cap is told once until the 24-hour window has turned over", ctx do
      assert :sent =
               Notices.watcher(ctx.watcher.id, :cap_reached, %{cap: 10, waiting: 3}, opts(ctx, 0))

      assert_receive {:sent, _destination, text, _opts}
      assert text =~ "it reached its daily cap of 10 runs; 3 items are waiting."

      later = opts_at(ctx, DateTime.add(@t0, 23 * 3600, :second))
      assert :already_sent = Notices.watcher(ctx.watcher.id, :cap_reached, %{}, later)

      next_day = opts_at(ctx, DateTime.add(@t0, 24 * 3600, :second))
      assert :sent = Notices.watcher(ctx.watcher.id, :cap_reached, %{}, next_day)
    end

    test "a send that fails releases its claim, so the next trigger tells the owner", ctx do
      down = Keyword.put(opts(ctx, 0), :adapter, DownAdapter)

      log =
        capture_log(fn ->
          assert {:error, :channel_down} =
                   Notices.watcher(ctx.watcher.id, :filter_budget_reached, %{budget: 500}, down)
        end)

      assert log =~ "was not sent"

      assert :sent =
               Notices.watcher(
                 ctx.watcher.id,
                 :filter_budget_reached,
                 %{budget: 500},
                 opts(ctx, 0)
               )

      assert_receive {:sent, _destination, text, _opts}
      assert text =~ "filter budget of 500 calls in 24 hours"
    end
  end

  # A watcher saved before the rules (M60_CUE_INTAKE_AT_SCALE.md §3.1) gets
  # nothing until a change in chat; the sweeper's first pass tells the owner.
  describe "needs-update notices" do
    test "each watcher that breaks a rule is told once, with what it needs", ctx do
      cues = [
        cues_config: [
          sources: %{"bsky" => %{kind: :stream, url: "wss://jetstream.example.org/subscribe"}}
        ]
      ]

      watcher!(ctx.repo, "chip-news", filter: "llm", listen_for: ["TSMC"])
      watcher!(ctx.repo, "all-posts", filter: "none", sources: ["bsky"])

      assert {:ok, 2} = Watchers.needs_update_notices(opts(ctx, 0) ++ cues)

      assert_receive {:sent, "chat-9",
                      "Watcher market-news: it has no keywords to listen for, so no item reaches " <>
                        "it. Ask Fermix in chat to give it some.", _opts}

      assert_receive {:sent, "chat-9",
                      "Watcher all-posts: it passes every item, so it cannot listen to a stream " <>
                        "and gets nothing from one. Ask Fermix in chat to give it a filter.",
                      _opts}

      refute_received {:sent, _destination, _text, _opts}

      assert {:ok, 0} = Watchers.needs_update_notices(opts(ctx, 1) ++ cues)
      refute_received {:sent, _destination, _text, _opts}
    end

    test "a send that fails is told at the next call", ctx do
      down = Keyword.put(opts(ctx, 0), :adapter, DownAdapter)

      log =
        capture_log(fn -> assert {:ok, 0} = Watchers.needs_update_notices(down) end)

      assert log =~ "notice was not sent"
      assert {:ok, 1} = Watchers.needs_update_notices(opts(ctx, 1))
      assert_receive {:sent, "chat-9", "Watcher market-news: it has no keywords" <> _, _opts}
    end
  end

  describe "gap notices" do
    test "an open gap no run reported within an hour is told once and marked reported", ctx do
      fresh = gap!(ctx, "eng-blogs", "inbox_full", 12, ~U[2026-10-05 08:30:00.000000Z])
      old = gap!(ctx, "alpaca-news", "expired", 3, ~U[2026-10-05 07:14:00.000000Z])

      assert {:ok, 1} = Notices.sweep_gaps([server: ctx.repo] ++ seams(), @t0, 1_000)
      assert_receive {:sent, "chat-9", text, _opts}

      assert text ==
               "Watcher market-news: 3 items from alpaca-news were not delivered since " <>
                 "Monday, October 5, 2026 at 7:14 AM UTC: they waited past their lifetime."

      assert [[reported]] =
               CueFixtures.rows(ctx.conn, "SELECT reported_at FROM cue_gaps WHERE id = ?", [old])

      assert is_binary(reported)

      assert [[nil]] =
               CueFixtures.rows(ctx.conn, "SELECT reported_at FROM cue_gaps WHERE id = ?", [fresh])

      assert {:ok, 0} = Notices.sweep_gaps([server: ctx.repo] ++ seams(), @t0, 1_000)
      refute_received {:sent, _destination, _text, _opts}
    end
  end

  describe "source and mandate notices" do
    test "a source notice goes to the owner inbox once per episode", ctx do
      assert :sent = Notices.source("eng-blogs", :auth_failed, %{}, opts(ctx, 0))

      assert_receive {:sent, "owner-1",
                      "Cue source eng-blogs stopped: its credential was refused." <> _, send_opts}

      assert Keyword.get(send_opts, :link_previews) == false

      assert :already_sent = Notices.source("eng-blogs", :auth_failed, %{}, opts(ctx, 0))

      CueFixtures.exec!(
        ctx.conn,
        "UPDATE cue_sources SET last_good_at = ? WHERE source_ref = ?",
        ["2026-10-06T09:00:00.000000Z", "eng-blogs"]
      )

      assert :sent = Notices.source("eng-blogs", :auth_failed, %{}, opts(ctx, 2))
    end

    # An X accounts source without the X sign-in is not stopped: it starts by
    # itself once X is connected (M60_X_ACCOUNTS_SOURCE.md §3).
    test "a source waiting for the X sign-in says where to connect X, not that it stopped", ctx do
      data = %{reason: "x_sign_in"}
      assert :sent = Notices.source("space-posts", :auth_failed, data, opts(ctx, 0))
      assert_receive {:sent, "owner-1", text, _opts}

      assert text ==
               "Cue source space-posts needs your X sign-in: connect X under Plugins. It " <>
                 "starts by itself once X is connected."

      assert :already_sent = Notices.source("space-posts", :auth_failed, data, opts(ctx, 1))
    end

    test "a stream the service kept refusing is told once per episode, in Fermix's words", ctx do
      assert :sent = Notices.source("live-news", :refused, %{}, opts(ctx, 0))
      assert_receive {:sent, "owner-1", text, _opts}

      assert text ==
               "Cue source live-news stopped: the service sent an error each time Fermix " <>
                 "connected. Some services allow one connection per account, so another " <>
                 "program using the same keys causes this. Check its settings, then save it " <>
                 "again or restart Fermix to try again."

      assert :already_sent = Notices.source("live-news", :refused, %{}, opts(ctx, 1))
    end

    test "a feed larger than Fermix reads is told once per episode", ctx do
      assert :sent = Notices.source("harbour-hours", :too_large, %{}, opts(ctx, 0))
      assert_receive {:sent, "owner-1", text, _opts}

      assert text ==
               "Cue source harbour-hours stopped: its feed is larger than Fermix reads. It " <>
                 "tries again when its settings change or Fermix restarts."

      assert :already_sent = Notices.source("harbour-hours", :too_large, %{}, opts(ctx, 1))
    end

    test "an outage of a source says it cannot catch up and nothing was recorded", ctx do
      since = "2026-10-12T13:45:00Z"
      assert :sent = Notices.source("live-news", :down, %{since: since}, opts(ctx, 0))
      assert_receive {:sent, "owner-1", text, _opts}
      assert text =~ "It cannot catch up, so what the service sent meanwhile is missed"
      refute text =~ "gap"
    end

    test "a reached source budget is told once per UTC day", ctx do
      assert :sent = Notices.source("eng-blogs", :budget_reached, %{budget: 5_000}, opts(ctx, 0))
      assert_receive {:sent, "owner-1", text, _opts}
      assert text =~ "reached its daily budget of 5000 items"
      assert :already_sent = Notices.source("eng-blogs", :budget_reached, %{}, opts(ctx, 0))
      assert :sent = Notices.source("eng-blogs", :budget_reached, %{}, opts(ctx, 1))
    end

    test "a mandate notice goes to the owner inbox", ctx do
      assert :sent = Notices.mandate("release-issues", :unpinned, %{}, opts(ctx, 0))
      assert_receive {:sent, "owner-1", "Mandate release-issues is disabled" <> _, _opts}
    end

    test "with no owner inbox a source notice fails loud and stays unsent", ctx do
      no_inbox = Keyword.put(opts(ctx, 0), :configured_owners, %{})

      capture_log(fn ->
        assert {:error, :no_owner_inbox} = Notices.source("eng-blogs", :down, %{}, no_inbox)
      end)

      assert :sent = Notices.source("eng-blogs", :down, %{}, opts(ctx, 0))
    end
  end

  # --- helpers -------------------------------------------------------------------------

  defp seams,
    do: [adapter: SinkAdapter, jobs_config: [], configured_owners: %{"telegram" => "owner-1"}]

  defp opts(ctx, day), do: opts_at(ctx, DateTime.add(@t0, day, :day))
  defp opts_at(ctx, now), do: [repo: ctx.repo, now: now] ++ seams()

  defp watcher!(repo, name, attrs \\ []) do
    {:ok, job} =
      JobsRegistry.create_cue_job(
        %{
          name: "task #{name}",
          task_prompt: "Report it.",
          delivery_mode: "channel",
          delivery_target: %{"platform" => "telegram", "chat_id" => "chat-9"},
          created_by_trust: "operator"
        },
        repo: repo,
        scheduler: nil
      )

    {sources, attrs} = Keyword.pop(attrs, :sources, ["alpaca-news"])

    attrs =
      Map.merge(
        %{
          id: "cwt_#{name}",
          name: name,
          purpose: "Market moves",
          filter: "llm",
          task_job_id: job.id,
          created_from: "telegram:chat-1"
        },
        Map.new(attrs)
      )

    {:ok, watcher} =
      Repo.cues_call(CuesWatchersSql, {:insert_watcher, attrs, sources, [], @t0}, server: repo)

    watcher
  end

  defp gap!(ctx, ref, reason, count, first_at) do
    id = "cgp_#{System.unique_integer([:positive])}"
    stamp = Calendar.strftime(first_at, "%Y-%m-%dT%H:%M:%S.000000Z")

    CueFixtures.exec!(
      ctx.conn,
      "INSERT INTO cue_gaps (id, source_ref, watcher_id, reason, count, first_at, last_at) " <>
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
      [id, ref, ctx.watcher.id, reason, count, stamp, stamp]
    )

    id
  end
end
