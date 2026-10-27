defmodule FermixCore.Cues.LiveFiltersTest do
  # async: false — the dispatcher creates the named recent-drops table, one
  # per VM. One dispatcher per test on its own temp Repo, with a model stand-in
  # the test answers by hand, a hand-driven clock, no timers (the test sends
  # `:due` and `:flush`) and no real waits between write retries.
  use ExUnit.Case, async: false

  import FermixTestSupport.CueFixtures

  alias FermixCore.Cues.LiveFilters
  alias FermixCore.Cues.RecentDrops
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixCore.Providers.Error, as: ProviderError
  alias FermixTestSupport.TelemetryCapture

  @t0 ~U[2026-10-12 14:00:00.000000Z]
  @lifecycle [:fermix, :cue, :lifecycle]
  @wait_ms 10_000

  # The model: tells the test which item it was handed, then waits for the
  # test to say what it answered.
  defmodule BlockingAdapter do
    @moduledoc false

    def chat(messages, [], opts) do
      send(Keyword.fetch!(opts, :test_pid), {:filter_call, self(), messages, opts})

      receive do
        {:answer, reply} -> reply
      after
        30_000 -> {:error, :test_never_answered}
      end
    end
  end

  defmodule NoticeStub do
    @moduledoc false

    def watcher(watcher_id, kind, data, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:notice, watcher_id, kind, data})
      :sent
    end
  end

  # A Repo in front of the test's own whose first `late` live passes commit but
  # answer `{:error, :repo_timeout}`: what a write that ran after its caller
  # stopped waiting looks like from the task.
  defmodule LatePassRepo do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

    @impl true
    def init(config), do: {:ok, config}

    @impl true
    def handle_call({:cues, CuesSql, request}, _from, %{late: late} = state)
        when elem(request, 0) == :pass_live and late > 0 do
      {:ok, _written} = GenServer.call(state.forward_to, {:cues, CuesSql, request})
      {:reply, {:error, :repo_timeout}, %{state | late: late - 1}}
    end

    def handle_call(request, _from, state),
      do: {:reply, GenServer.call(state.forward_to, request), state}
  end

  # A store whose first `hold` count flushes the test answers: it tells the
  # test the rows of each and replies when the test does; everything else,
  # later flushes included, is forwarded.
  defmodule CountsGateRepo do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

    @impl true
    def init(config), do: {:ok, config}

    @impl true
    def handle_call({:cues, CuesSql, {:counts_put, rows, _now}}, from, %{hold: hold} = state)
        when hold > 0 do
      send(state.test, {:counts_put, rows, from})
      {:noreply, %{state | hold: hold - 1}}
    end

    def handle_call(request, _from, state),
      do: {:reply, GenServer.call(state.forward_to, request), state}
  end

  # A store held up behind a long write: it takes every live pass and answers
  # none until the test does (`GenServer.reply/2`), and forwards the rest.
  defmodule HeldPassRepo do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

    @impl true
    def init(config), do: {:ok, config}

    @impl true
    def handle_call({:cues, CuesSql, request}, from, state)
        when elem(request, 0) == :pass_live do
      send(state.test, {:write_held, from})
      {:noreply, state}
    end

    def handle_call(request, _from, state),
      do: {:reply, GenServer.call(state.forward_to, request), state}
  end

  setup do
    ctx = start_repo("live_filters")
    test = self()
    unique = System.unique_integer([:positive])
    supervisor = :"live_filter_tasks_#{unique}"
    start_supervised!({Task.Supervisor, name: supervisor})
    clock = start_supervised!({Agent, fn -> @t0 end})

    opts = [
      name: :"live_filters_#{unique}",
      repo: ctx.repo,
      repo_timeout_ms: @wait_ms,
      timers?: false,
      task_supervisor: supervisor,
      clock: fn -> Agent.get(clock, & &1) end,
      notices: NoticeStub,
      notice_opts: [test_pid: test],
      wake_scheduler: fn -> send(test, :woke_scheduler) end,
      sleep: fn ms -> send(test, {:slept, ms}) end,
      llm: [
        adapter: BlockingAdapter,
        adapter_opts: [test_pid: test],
        retry_delay_fn: fn _ms -> :ok end,
        routes: [
          {%{
             provider: :openai,
             model: "gpt-5.4-mini",
             auth_mode: :api_key,
             base_url: "https://api.openai.com/v1"
           }, []}
        ]
      ]
    ]

    Map.merge(ctx, %{opts: opts, clock: clock, ref: "stream-#{unique}"})
  end

  # --- helpers ---------------------------------------------------------------

  defp start_live(ctx, overrides \\ []),
    do: start_supervised!({LiveFilters, Keyword.merge(ctx.opts, overrides)})

  # A watcher row, and the spec a stream hands over for it.
  defp watcher(ctx, attrs \\ %{}) do
    id = insert_watcher(ctx.conn, %{filter: "llm", sources: [ctx.ref], listen_for: ["orbit"]})
    TelemetryCapture.attach([@lifecycle], watcher_id: id)

    [[name]] = rows(ctx.conn, "SELECT name FROM cue_watchers WHERE id = ?", [id])

    Map.merge(
      %{
        id: id,
        name: name,
        purpose: "Launch news.",
        filter_budget: 0,
        filter_failures: 0,
        filter_retry_at: nil,
        instructions: [],
        examples: [],
        used: 0
      },
      attrs
    )
  end

  defp item(id, subject \\ nil) do
    item!(%{item_id: id, subject: subject, type: "post", data: %{"title" => id}}, @t0)
  end

  defp offer(live, ctx, items, watchers) do
    ids = Enum.map(watchers, & &1.id)
    LiveFilters.offer(live, ctx.ref, Enum.map(items, &{&1, ids}))
  end

  defp turn(content) do
    {:ok,
     %{
       content: content,
       tool_calls: [],
       provider_state: nil,
       usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
       model: "gpt-5.4-mini"
     }}
  end

  defp pass, do: turn(~s({"decision": "pass", "reason": "A launch."}))
  defp drop, do: turn(~s({"decision": "drop", "reason": "Not a launch."}))
  defp rate_limited, do: {:error, ProviderError.api(:openai, :responses, 429, "slow down")}

  defp next_call do
    assert_receive {:filter_call, pid, messages, _opts}, @wait_ms
    user = messages |> Enum.filter(&(&1.role == "user")) |> Enum.map_join("\n", & &1.content)
    [_all, title] = Regex.run(~r/"title": "([^"]+)"/, user)
    {pid, title}
  end

  # Answers a call and returns once the dispatcher has handled its end: the
  # task reports before it exits, so its report is ahead of the sync.
  defp finish(live, {pid, _title}, reply) do
    ref = Process.monitor(pid)
    send(pid, {:answer, reply})
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, @wait_ms
    :sys.get_state(live)
  end

  defp advance(ctx, seconds), do: Agent.update(ctx.clock, &DateTime.add(&1, seconds, :second))

  defp in_flight(live), do: live |> :sys.get_state() |> Map.fetch!(:in_flight) |> map_size()

  defp queued(live, watcher) do
    queues = live |> :sys.get_state() |> Map.fetch!(:queues)
    queues |> Map.get(watcher.id, :queue.new()) |> :queue.len()
  end

  defp deliveries(ctx, watcher) do
    rows(
      ctx.conn,
      "SELECT c.item_id, d.state FROM cue_deliveries d JOIN cues c ON c.id = d.cue_id " <>
        "WHERE d.watcher_id = ? ORDER BY d.id",
      [watcher.id]
    )
  end

  defp calls(ctx, watcher) do
    rows(
      ctx.conn,
      "SELECT delivery_id, result FROM cue_filter_calls WHERE watcher_id = ? ORDER BY started_at",
      [watcher.id]
    )
  end

  # The counts a clean stop flushes for a watcher: the stop writes them before
  # the dispatcher is gone.
  defp flushed(ctx, watcher) do
    :ok = stop_supervised(LiveFilters)
    {:ok, counts} = Repo.cues_call(CuesSql, {:counts_window, "watcher", @t0}, server: ctx.repo)
    Map.get(counts, watcher.id, %{})
  end

  # --- tests -------------------------------------------------------------------

  describe "judged before stored" do
    test "a pass writes the cue and the watcher's delivery; a drop only its ledger row and " <>
           "the recent drops; both are counted",
         ctx do
      w = watcher(ctx)
      live = start_live(ctx)
      LiveFilters.watchers(live, ctx.ref, [w])
      offer(live, ctx, [item("p-1"), item("p-2")], [w])

      assert {_pid, "p-1"} = first = next_call()
      assert {_pid, "p-2"} = second = next_call()
      finish(live, first, pass())
      assert_receive :woke_scheduler
      finish(live, second, drop())

      assert deliveries(ctx, w) == [["p-1", "passed"]]
      assert [[nil, "pass"], [nil, "drop"]] = calls(ctx, w)
      assert [[1]] = rows(ctx.conn, "SELECT count(*) FROM cues")
      assert [%{item: %{item_id: "p-2"}, reason: "Not a launch."}] = RecentDrops.list(w.id)

      assert flushed(ctx, w) == %{"offered" => 2, "passed" => 1, "dropped" => 1}
      assert_receive {:telemetry, @lifecycle, _m, %{phase: :passed, session_id: _s}}
      assert_receive {:telemetry, @lifecycle, %{count: 1}, %{phase: :dropped, watcher_id: _w}}
    end

    test "a repeat of a passed item is judged again, stores nothing more and counts no " <>
           "second pass",
         ctx do
      w = watcher(ctx)
      live = start_live(ctx)
      LiveFilters.watchers(live, ctx.ref, [w])

      for _sent <- 1..2 do
        offer(live, ctx, [item("r-1")], [w])
        finish(live, next_call(), pass())
      end

      assert deliveries(ctx, w) == [["r-1", "passed"]]
      assert [[nil, "pass"], [nil, "pass"]] = calls(ctx, w)
      assert flushed(ctx, w) == %{"offered" => 2, "passed" => 1}
    end

    test "a pass onto a stored item of other content is an identity conflict: traced with " <>
           "its gap, no delivery and no pass counted",
         ctx do
      TelemetryCapture.attach([@lifecycle], source_ref: ctx.ref)
      other = item!(%{item_id: "k-1", type: "post", data: %{"title" => "another"}}, @t0)
      request = {:store_item, ctx.ref, other, @t0}
      {:ok, _cue_id} = Repo.cues_call(CuesSql, request, server: ctx.repo)
      w = watcher(ctx)
      live = start_live(ctx)
      LiveFilters.watchers(live, ctx.ref, [w])
      offer(live, ctx, [item("k-1")], [w])

      finish(live, next_call(), pass())

      assert deliveries(ctx, w) == []
      assert [[nil, "pass"]] = calls(ctx, w)
      assert_received {:telemetry, @lifecycle, _m, %{phase: :conflict, watcher_id: _w}}
      assert_received {:telemetry, @lifecycle, _m, %{phase: :gap, reason: "identity_conflict"}}
      refute_received {:telemetry, @lifecycle, _m, %{phase: :passed}}
      assert flushed(ctx, w) == %{"offered" => 1}
    end

    test "two watchers passing one item each get a delivery, and both calls run at once", ctx do
      one = watcher(ctx)
      two = watcher(ctx)
      live = start_live(ctx)
      LiveFilters.watchers(live, ctx.ref, [one, two])
      offer(live, ctx, [item("p-1", "launch")], [one, two])

      first = next_call()
      second = next_call()
      assert in_flight(live) == 2
      finish(live, first, pass())
      finish(live, second, pass())

      assert deliveries(ctx, one) == [["p-1", "passed"]]
      assert deliveries(ctx, two) == [["p-1", "passed"]]
      assert [[1, 2]] = rows(ctx.conn, "SELECT count(*), sum(routed_count) FROM cues")
    end
  end

  describe "watchers" do
    test "a watcher its source no longer lists is forgotten, with its queue and its drops",
         ctx do
      w = watcher(ctx)
      live = start_live(ctx)
      LiveFilters.watchers(live, ctx.ref, [w])
      offer(live, ctx, [item("f-1", "alpha"), item("f-2", "alpha")], [w])
      finish(live, next_call(), drop())
      assert [%{item: %{item_id: "f-1"}}] = RecentDrops.list(w.id)
      assert {_pid, "f-2"} = call = next_call()

      LiveFilters.watchers(live, ctx.ref, [])
      finish(live, call, rate_limited())

      assert RecentDrops.list(w.id) == []
      assert %{queues: queues, specs: specs} = :sys.get_state(live)
      assert {queues, specs} == {%{}, %{}}
    end

    test "an item offered before its watcher's spec waits for it", ctx do
      w = watcher(ctx)
      live = start_live(ctx)
      offer(live, ctx, [item("w-1")], [w])
      assert in_flight(live) == 0

      LiveFilters.watchers(live, ctx.ref, [w])
      assert {_pid, "w-1"} = next_call()
    end
  end

  describe "counts" do
    test "a flush writes the hour's totals by a task; one that timed out is sent again whole",
         ctx do
      gate = start_supervised!({CountsGateRepo, forward_to: ctx.repo, test: self(), hold: 2})
      w = watcher(ctx)
      live = start_live(ctx, repo: gate)
      LiveFilters.watchers(live, ctx.ref, [w])
      offer(live, ctx, [item("c-1"), item("c-2")], [w])
      send(live, :flush)

      assert_receive {:counts_put, [%{counts: %{"offered" => 2}} = row], from}, @wait_ms
      # The flush's task waits on this reply; once it is gone, its report is
      # ahead of the sync.
      {flusher, _tag} = from
      flush_ref = Process.monitor(flusher)
      GenServer.reply(from, {:error, :repo_timeout})
      assert_receive {:DOWN, ^flush_ref, :process, ^flusher, _reason}, @wait_ms
      :sys.get_state(live)

      finish(live, next_call(), drop())
      send(live, :flush)
      assert_receive {:counts_put, [again], from}, @wait_ms
      assert again.counts == %{"offered" => 2, "dropped" => 1}
      assert {again.ref, again.hour, again.incarnation} == {row.ref, row.hour, row.incarnation}

      GenServer.reply(
        from,
        Repo.cues_call(CuesSql, {:counts_put, [again], @t0}, server: ctx.repo)
      )

      :sys.get_state(live)
      assert_received {:telemetry, @lifecycle, %{count: 1}, %{phase: :dropped}}
    end

    # The Repo budget here is past the supervisor's 5 s shutdown, so only the
    # clean stop's own bound lets it end before the kill.
    test "a clean stop whose counts the store does not take ends before its shutdown runs out",
         ctx do
      stalled =
        start_supervised!(
          {FermixTestSupport.StalledRepo, forward_to: ctx.repo, stall: [:counts_put]}
        )

      w = watcher(ctx)
      live = start_live(ctx, repo: stalled)
      LiveFilters.watchers(live, ctx.ref, [w])
      offer(live, ctx, [item("x-1")], [w])
      ref = Process.monitor(live)

      ExUnit.CaptureLog.capture_log(fn -> :ok = stop_supervised(LiveFilters) end)
      assert_receive {:DOWN, ^ref, :process, ^live, :shutdown}
    end
  end

  describe "order" do
    test "four calls at once, never two for one subject: a subject's items are stored in " <>
           "arrival order, and items with no subject use the rest",
         ctx do
      w = watcher(ctx)
      live = start_live(ctx)
      LiveFilters.watchers(live, ctx.ref, [w])

      items = [
        item("a-1", "alpha"),
        item("a-2", "alpha"),
        item("b-1", "bravo"),
        item("a-3", "alpha"),
        item("n-1"),
        item("n-2")
      ]

      offer(live, ctx, items, [w])
      started = for _n <- 1..4, do: next_call()
      assert Enum.map(started, &elem(&1, 1)) |> Enum.sort() == ~w(a-1 b-1 n-1 n-2)
      assert in_flight(live) == 4

      a1 = Enum.find(started, &(elem(&1, 1) == "a-1"))
      finish(live, a1, pass())
      assert {_pid, "a-2"} = a2 = next_call()
      finish(live, a2, pass())
      assert {_pid, "a-3"} = a3 = next_call()
      finish(live, a3, pass())

      for call <- started, elem(call, 1) != "a-1", do: finish(live, call, drop())
      assert deliveries(ctx, w) == [["a-1", "passed"], ["a-2", "passed"], ["a-3", "passed"]]
    end

    test "a provider failure puts the item back at the head of its subject and the watcher " <>
           "waits for its backoff",
         ctx do
      w = watcher(ctx)
      live = start_live(ctx)
      LiveFilters.watchers(live, ctx.ref, [w])
      offer(live, ctx, [item("a-1", "alpha"), item("a-2", "alpha")], [w])

      assert {_pid, "a-1"} = call = next_call()
      finish(live, call, rate_limited())
      assert [[nil, "provider_failure"]] = calls(ctx, w)
      assert in_flight(live) == 0

      advance(ctx, 29)
      send(live, :due)
      assert in_flight(live) == 0

      advance(ctx, 1)
      send(live, :due)
      assert {_pid, "a-1"} = call = next_call()
      finish(live, call, pass())
      assert {_pid, "a-2"} = next_call()
    end

    test "a content failure is tried three times, then counted filter_failed", ctx do
      w = watcher(ctx)
      live = start_live(ctx)
      LiveFilters.watchers(live, ctx.ref, [w])
      offer(live, ctx, [item("c-1")], [w])

      for _attempt <- 1..3 do
        assert {_pid, "c-1"} = call = next_call()
        finish(live, call, turn("I would pass this one."))
      end

      assert in_flight(live) == 0
      assert flushed(ctx, w) == %{"offered" => 1, "filter_failed" => 1}
      assert length(calls(ctx, w)) == 3
    end
  end

  describe "budget and hold" do
    test "a watcher past its filter budget takes no more calls and counts what it was offered, " <>
           "what waited in its queue included",
         ctx do
      w = watcher(ctx, %{filter_budget: 2, used: 1})
      live = start_live(ctx)
      LiveFilters.watchers(live, ctx.ref, [w])
      offer(live, ctx, [item("b-1"), item("b-2")], [w])

      call = next_call()
      assert in_flight(live) == 1
      finish(live, call, drop())
      assert in_flight(live) == 0
      offer(live, ctx, [item("b-3")], [w])
      assert in_flight(live) == 0
      assert queued(live, w) == 0

      assert flushed(ctx, w) == %{"offered" => 3, "dropped" => 1, "over_budget" => 2}
    end

    # The ledger has no row for a call still in flight, so a refresh read while
    # calls run must not free their share of the budget.
    test "a refresh counts the calls in flight against the budget, and what waits is counted " <>
           "over_budget",
         ctx do
      w = watcher(ctx, %{filter_budget: 2})
      live = start_live(ctx)
      LiveFilters.watchers(live, ctx.ref, [w])
      offer(live, ctx, [item("n-1"), item("n-2"), item("n-3")], [w])
      calls = [next_call(), next_call()]
      assert in_flight(live) == 2

      LiveFilters.watchers(live, ctx.ref, [w])
      assert in_flight(live) == 2
      assert queued(live, w) == 0

      for call <- calls, do: finish(live, call, drop())
      assert flushed(ctx, w) == %{"offered" => 3, "dropped" => 2, "over_budget" => 1}
    end

    test "three provider failures in a row hold the watcher with a notice; a success after " <>
           "the hold releases it",
         ctx do
      w = watcher(ctx)
      live = start_live(ctx)
      LiveFilters.watchers(live, ctx.ref, [w])
      offer(live, ctx, [item("h-1")], [w])
      wid = w.id

      for wait_s <- [0, 30, 120] do
        advance(ctx, wait_s)
        send(live, :due)
        finish(live, next_call(), rate_limited())
      end

      assert_receive {:notice, ^wid, :filter_held, %{error: _message, waiting: _n}}

      [[failures]] =
        rows(ctx.conn, "SELECT filter_failures FROM cue_watchers WHERE id = ?", [wid])

      assert failures == 3

      advance(ctx, 600)
      send(live, :due)
      finish(live, next_call(), pass())
      assert_receive {:notice, ^wid, :filter_recovered, _data}
      assert deliveries(ctx, w) == [["h-1", "passed"]]
    end
  end

  describe "a slow store" do
    # LatePassRepo answers the first write :repo_timeout itself, so the bound
    # has only the real writes to time, which a loaded runner can hold past
    # a short one.
    test "a pass whose write timed out is written again without a second judgement", ctx do
      late = start_supervised!({LatePassRepo, forward_to: ctx.repo, late: 1})
      w = watcher(ctx)
      live = start_live(ctx, repo: late, repo_timeout_ms: @wait_ms)
      LiveFilters.watchers(live, ctx.ref, [w])
      offer(live, ctx, [item("p-1")], [w])

      finish(live, next_call(), pass())

      assert_received {:slept, 1_000}
      assert in_flight(live) == 0
      refute_received {:filter_call, _pid, _messages, _opts}
      assert deliveries(ctx, w) == [["p-1", "passed"]]
      assert [[nil, "pass"]] = calls(ctx, w)
      assert flushed(ctx, w) == %{"offered" => 1, "passed" => 1}
    end

    test "a store held up behind a write leaves the dispatcher judging, and a pass it " <>
           "cannot write is counted write_failed",
         ctx do
      held = start_supervised!({HeldPassRepo, forward_to: ctx.repo, test: self()})
      w = watcher(ctx)
      live = start_live(ctx, repo: held, repo_timeout_ms: @wait_ms)
      LiveFilters.watchers(live, ctx.ref, [w])
      offer(live, ctx, [item("s-1")], [w])

      {pid, "s-1"} = next_call()
      ref = Process.monitor(pid)
      send(pid, {:answer, pass()})
      assert_receive {:write_held, from}, @wait_ms

      # The write waits; the dispatcher answers, takes new items and judges them.
      offer(live, ctx, [item("s-2")], [w])
      assert {_pid, "s-2"} = second = next_call()
      assert in_flight(live) == 2

      ExUnit.CaptureLog.capture_log(fn ->
        GenServer.reply(from, {:error, :repo_timeout})

        for _retry <- 1..3 do
          assert_receive {:write_held, retry}, @wait_ms
          GenServer.reply(retry, {:error, :repo_timeout})
        end

        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, @wait_ms
        :sys.get_state(live)
      end)

      for ms <- [1_000, 2_000, 4_000], do: assert_received({:slept, ^ms})
      finish(live, second, drop())
      assert flushed(ctx, w) == %{"offered" => 2, "write_failed" => 1, "dropped" => 1}
      assert deliveries(ctx, w) == []
    end
  end

  describe "a crash" do
    test "a call whose ending task crashes too ends there: traced, counted filter_failed, " <>
           "its slot and subject released, and never handed to another task",
         ctx do
      stalled =
        start_supervised!(
          {FermixTestSupport.StalledRepo,
           forward_to: ctx.repo, stall: [:settle_live], notify: self()}
        )

      w = watcher(ctx)
      TelemetryCapture.attach([[:fermix, :cue_filter, :run_error]], watcher_id: w.id)
      live = start_live(ctx, repo: stalled)
      LiveFilters.watchers(live, ctx.ref, [w])
      offer(live, ctx, [item("e-1", "alpha"), item("e-2", "alpha")], [w])
      {pid, "e-1"} = next_call()

      ExUnit.CaptureLog.capture_log(fn ->
        # The call crashes; the task writing its end waits on the store, then
        # crashes too.
        Process.exit(pid, :boom)
        assert_receive {:stalled, :settle_live}, @wait_ms
        [%{pid: ending}] = live |> :sys.get_state() |> Map.fetch!(:in_flight) |> Map.values()
        Process.exit(ending, :boom)

        assert_receive {:telemetry, [:fermix, :cue_filter, :run_error], _m,
                        %{status: "settle_failed", error_kind: "crashed"}},
                       @wait_ms
      end)

      assert {_pid, "e-2"} = next_call()
      refute_received {:stalled, :settle_live}
      assert flushed(ctx, w) == %{"offered" => 2, "filter_failed" => 1}
    end
  end
end
