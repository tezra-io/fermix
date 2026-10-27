defmodule FermixCore.Cues.SourceManagerTest do
  # Each test runs its own manager and DynamicSupervisor under unique names,
  # with stand-in workers that report to the test: no poller, no socket. The
  # tests that crash a source out, the one case the manager writes a row, have
  # their own temp Repo.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import FermixTestSupport.CueFixtures, only: [start_repo: 1]

  alias FermixCore.Cues.SourceManager
  alias FermixCore.Cues.SourceSupervisor
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixTestSupport.TelemetryCapture

  @wait_ms 10_000

  defmodule FakeWorker do
    @moduledoc false
    use GenServer, restart: :temporary

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      source = Keyword.fetch!(opts, :source)
      if is_pid(opts[:manager]), do: Process.link(opts[:manager])
      send(Keyword.fetch!(opts, :test), {:worker_started, source.ref, self(), source})
      {:ok, opts}
    end

    @impl true
    def handle_cast(:stop_normally, state), do: {:stop, :normal, state}
    def handle_cast(:crash, state), do: {:stop, :boom, state}
  end

  setup do
    unique = System.unique_integer([:positive])
    supervisor = :"cue_sources_sup_#{unique}"
    start_supervised!({SourceSupervisor, name: supervisor})
    sources = start_supervised!({Agent, fn -> [] end}, id: :sources)
    %{supervisor: supervisor, sources: sources, name: :"cue_source_manager_#{unique}"}
  end

  defp source(ref, kind, overrides \\ %{}) do
    Map.merge(
      %{
        ref: ref,
        kind: kind,
        enabled?: true,
        daily_budget: 0,
        url: "https://example.test/#{ref}"
      },
      overrides
    )
  end

  defp set_sources(ctx, sources), do: Agent.update(ctx.sources, fn _old -> sources end)

  defp start_manager(ctx, opts \\ []) do
    test = self()

    defaults = [
      name: ctx.name,
      clock: fn -> ~U[2026-10-12 22:51:00Z] end,
      supervisor: ctx.supervisor,
      sources: fn -> Agent.get(ctx.sources, & &1) end,
      workers: %{feed: FakeWorker, stream: FakeWorker},
      worker_opts: [test: test],
      schedule: fn message, ms -> send(test, {:scheduled, message, ms}) end,
      notify: fn ref, kind, data, _opts -> send(test, {:notice, ref, kind, data}) && :sent end
    ]

    repo = if ctx[:repo], do: [repo: ctx.repo], else: []
    start_supervised!({SourceManager, defaults |> Keyword.merge(repo) |> Keyword.merge(opts)})
  end

  defp reconcile(ctx) do
    :ok = SourceManager.reconcile(ctx.name)
    SourceManager.workers(ctx.name)
  end

  test "starts one worker per enabled feed or stream source, and none for the others", ctx do
    set_sources(ctx, [
      source("blog", :feed),
      source("bsky", :stream),
      source("hooks", :webhook),
      source("pushes", :local_push),
      source("paused", :feed, %{enabled?: false})
    ])

    start_manager(ctx)

    assert_receive {:worker_started, "blog", blog, _source}
    assert_receive {:worker_started, "bsky", bsky, _source}
    assert SourceManager.workers(ctx.name) == %{"blog" => blog, "bsky" => bsky}
    assert length(DynamicSupervisor.which_children(ctx.supervisor)) == 2
  end

  # M60 app surface §3.8 item 3: a source waiting for its secret runs no worker,
  # and storing the secret (a config change) starts it at the next reconcile.
  test "a source waiting for its secret starts only once the secret is stored", ctx do
    set_sources(ctx, [source("blog", :feed), source("news", :feed, %{missing_secret: :key})])
    start_manager(ctx)

    assert_receive {:worker_started, "blog", blog, _source}
    assert SourceManager.workers(ctx.name) == %{"blog" => blog}

    set_sources(ctx, [source("blog", :feed), source("news", :feed, %{missing_secret: nil})])
    workers = reconcile(ctx)

    assert_receive {:worker_started, "news", news, _source}
    assert workers == %{"blog" => blog, "news" => news}
  end

  test "a config change stops removed sources, restarts changed ones and starts new ones",
       ctx do
    set_sources(ctx, [source("blog", :feed), source("news", :feed), source("bsky", :stream)])
    start_manager(ctx)
    assert_receive {:worker_started, "blog", blog, _source}
    assert_receive {:worker_started, "news", news, _source}
    assert_receive {:worker_started, "bsky", bsky, _source}
    blog_ref = Process.monitor(blog)
    news_ref = Process.monitor(news)

    set_sources(ctx, [
      source("blog", :feed, %{url: "https://example.test/moved"}),
      source("bsky", :stream),
      source("alerts", :feed)
    ])

    workers = reconcile(ctx)

    assert_receive {:DOWN, ^news_ref, :process, ^news, :shutdown}
    assert_receive {:DOWN, ^blog_ref, :process, ^blog, :shutdown}
    assert_receive {:worker_started, "blog", new_blog, %{url: "https://example.test/moved"}}
    assert_receive {:worker_started, "alerts", alerts, _source}
    assert workers == %{"blog" => new_blog, "bsky" => bsky, "alerts" => alerts}

    # Disabled: stopped.
    set_sources(ctx, [source("bsky", :stream, %{enabled?: false})])
    assert reconcile(ctx) == %{}
  end

  test "a worker that stops itself stays stopped until its settings change", ctx do
    set_sources(ctx, [source("blog", :feed)])
    start_manager(ctx)
    assert_receive {:worker_started, "blog", blog, _source}
    monitor = Process.monitor(blog)

    GenServer.cast(blog, :stop_normally)
    assert_receive {:DOWN, ^monitor, :process, ^blog, :normal}

    assert reconcile(ctx) == %{"blog" => :stopped}
    refute_received {:worker_started, "blog", _pid, _source}

    set_sources(ctx, [source("blog", :feed, %{interval: 600})])
    assert %{"blog" => restarted} = reconcile(ctx)
    assert is_pid(restarted)
    assert_received {:worker_started, "blog", ^restarted, %{interval: 600}}
  end

  describe "a source that keeps crashing" do
    setup do
      %{repo: repo} = start_repo("source_manager")
      %{repo: repo}
    end

    test "a crashed worker is restarted after a delay; after five crashes in an hour it stays " <>
           "down, its row reads stopped and the owner is told",
         ctx do
      set_sources(ctx, [source("blog", :feed)])
      start_manager(ctx)
      assert_receive {:worker_started, "blog", worker, _source}

      capture_log(fn -> crash_five_times(ctx, worker) end)

      refute_received {:scheduled, {:restart, "blog", _token}, _delay}
      assert SourceManager.workers(ctx.name) == %{"blog" => :stopped}

      assert {:ok, %{status: "stopped"}} =
               Repo.cues_call(CuesSql, {:get_source, "blog"}, server: ctx.repo)
    end

    test "a stopped row that cannot be written is traced, and the manager runs on", ctx do
      TelemetryCapture.attach([[:fermix, :cue, :lifecycle]], source_ref: "blog")
      stalled = start_supervised!(FermixTestSupport.StalledRepo)
      set_sources(ctx, [source("blog", :feed)])
      start_manager(ctx, repo: stalled, repo_timeout_ms: 50)
      assert_receive {:worker_started, "blog", worker, _source}

      log = capture_log(fn -> crash_five_times(ctx, worker) end)

      assert log =~ "its stopped status could not be written: :repo_timeout"
      assert SourceManager.workers(ctx.name) == %{"blog" => :stopped}

      assert_received {:telemetry, [:fermix, :cue, :lifecycle], _m,
                       %{phase: :ingest_error, error_class: "repo_timeout"}}
    end
  end

  # Four crashes each restarted after its delay, then the fifth, which leaves
  # the source stopped once the owner is told.
  defp crash_five_times(ctx, worker) do
    last =
      Enum.reduce([1_000, 2_000, 4_000, 8_000], worker, fn delay, current ->
        crash(current)
        assert_receive {:scheduled, {:restart, "blog", _token} = restart, ^delay}
        assert SourceManager.workers(ctx.name) == %{"blog" => :restarting}
        send(GenServer.whereis(ctx.name), restart)
        assert_receive {:worker_started, "blog", next, _source}, @wait_ms
        next
      end)

    crash(last)
    assert_receive {:notice, "blog", :unreachable, %{reason: "crashed"}}, @wait_ms
  end

  test "workers left under the supervisor by an earlier manager are ended at start", ctx do
    {:ok, orphan} =
      DynamicSupervisor.start_child(
        ctx.supervisor,
        {FakeWorker, source: source("old", :feed), test: self()}
      )

    monitor = Process.monitor(orphan)
    start_manager(ctx)

    assert_receive {:DOWN, ^monitor, :process, ^orphan, :shutdown}
    assert SourceManager.workers(ctx.name) == %{}
  end

  test "reconcile is a no-op when no manager runs" do
    assert SourceManager.reconcile(:"no_manager_#{System.unique_integer([:positive])}") == :ok
  end

  defp crash(worker) do
    monitor = Process.monitor(worker)
    GenServer.cast(worker, :crash)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :boom}
  end
end
