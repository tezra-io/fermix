defmodule FermixCore.Cues.StreamIntakeTest do
  # A stream's intake end to end, hermetic (M60_CUE_INTAKE_AT_SCALE.md §7): a
  # stream worker on a stand-in transport the test drives, the real
  # `Cues.LiveFilters` with a model stand-in that answers at once, and a Repo
  # in front of the test's own that records every request. async: false — the
  # live dispatcher creates the named recent-drops table, one per VM.
  use ExUnit.Case, async: false

  import FermixTestSupport.CueFixtures

  alias FermixCore.Cues.Config
  alias FermixCore.Cues.LiveFilters
  alias FermixCore.Cues.Source.Stream
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixTestSupport.FakeCueTransport
  alias FermixTestSupport.TelemetryCapture

  @now ~U[2026-10-12 14:00:00.000000Z]
  @wait_ms 10_000

  # The model: passes an item whose text says `"verdict": "keep"`, drops the rest.
  defmodule VerdictAdapter do
    @moduledoc false

    def chat(messages, [], _opts) do
      user = messages |> Enum.filter(&(&1.role == "user")) |> Enum.map_join("\n", & &1.content)
      decision = if user =~ ~s("verdict": "keep"), do: "pass", else: "drop"

      {:ok,
       %{
         content: ~s({"decision": "#{decision}", "reason": "Judged by its verdict."}),
         tool_calls: [],
         provider_state: nil,
         usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
         model: "gpt-5.4-mini"
       }}
    end
  end

  # Forwards every request to the test's Repo and tells the test which cue
  # request it was.
  defmodule RecordingRepo do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

    @impl true
    def init(config), do: {:ok, config}

    @impl true
    def handle_call({:cues, _module, request} = call, _from, state) do
      send(state.test, {:repo_request, elem(request, 0)})
      {:reply, GenServer.call(state.forward_to, call), state}
    end

    def handle_call(request, _from, state),
      do: {:reply, GenServer.call(state.forward_to, request), state}
  end

  setup do
    ctx = start_repo("stream_intake")
    ref = "quotes-#{System.unique_integer([:positive])}"
    recorder = start_supervised!({RecordingRepo, forward_to: ctx.repo, test: self()})
    watcher = insert_watcher(ctx.conn, %{filter: "llm", sources: [ref], listen_for: ["hgft"]})
    TelemetryCapture.attach([[:fermix, :cue_filter, :run_complete]], watcher_id: watcher)
    Map.merge(ctx, %{ref: ref, recorder: recorder, watcher: watcher})
  end

  defp start_live(ctx) do
    unique = System.unique_integer([:positive])
    supervisor = :"intake_tasks_#{unique}"
    start_supervised!({Task.Supervisor, name: supervisor})

    start_supervised!(
      {LiveFilters,
       name: :"intake_live_#{unique}",
       repo: ctx.recorder,
       timers?: false,
       task_supervisor: supervisor,
       clock: fn -> @now end,
       wake_scheduler: fn -> :ok end,
       llm: [
         adapter: VerdictAdapter,
         retry_delay_fn: fn _ms -> :ok end,
         routes: [
           {%{
              provider: :openai,
              model: "gpt-5.4-mini",
              auth_mode: :api_key,
              base_url: "https://api.openai.com/v1"
            }, []}
         ]
       ]}
    )
  end

  defp start_stream(ctx, live) do
    test = self()
    section = %{"kind" => "stream", "url" => "wss://quotes.example.net/live", "id_path" => "id"}

    {:ok, source} =
      Config.source(ctx.ref, Config.normalize(%{"sources" => %{ctx.ref => section}}))

    opts = [
      source: source,
      repo: ctx.recorder,
      clock: fn -> @now end,
      monotonic_ms: fn -> 0 end,
      schedule: fn message, ms -> send(test, {:scheduled, message, ms}) end,
      transport: FakeCueTransport,
      transport_opts: [test: test],
      live: live,
      admit: fn _ref, n, _now_ms -> n end,
      notify: fn _ref, _kind, _data, _opts -> :sent end
    ]

    pid = start_supervised!({Stream, opts})
    assert_receive {:scheduled, {:timer, :connect, _token} = connect, 0}
    send(pid, connect)
    assert_receive {:dialed, _url, socket, _opts}, @wait_ms
    send(pid, {:cue_stream, socket, :connected})
    {pid, socket}
  end

  # Every cue request the Repo received so far, by name.
  defp requests(acc \\ []) do
    receive do
      {:repo_request, name} -> requests([name | acc])
    after
      0 -> Enum.frequencies(acc)
    end
  end

  test "only passes are stored: N items, P of them matched and passed, make P pass writes, " <>
         "one ledger row per judged item, a few count flushes and no accept",
       ctx do
    live = start_live(ctx)
    {pid, socket} = start_stream(ctx, live)

    # 20 items: 12 carry the watcher's word, and 5 of those the model passes.
    matched = for n <- 1..12, do: tick("m-#{n}", "HGFT", if(n <= 5, do: "keep", else: "skip"))
    unmatched = for n <- 1..8, do: tick("u-#{n}", "QZRX", "keep")
    frame = Enum.zip(matched, unmatched) |> Enum.flat_map(&Tuple.to_list/1)
    frame = frame ++ Enum.drop(matched, 8)
    send(pid, {:cue_stream, socket, {:frame, {:text, Jason.encode!(frame)}}})

    for _judged <- 1..12 do
      assert_receive {:telemetry, [:fermix, :cue_filter, :run_complete], _m, _meta}, @wait_ms
    end

    :sys.get_state(live)
    :ok = stop_supervised(Stream)
    :ok = stop_supervised(LiveFilters)
    seen = requests()

    assert seen[:pass_live] == 5
    assert seen[:settle_live] == 7
    refute Map.has_key?(seen, :accept)
    assert seen[:counts_put] <= 2

    assert [[5, 5]] =
             rows(
               ctx.conn,
               "SELECT (SELECT count(*) FROM cues), (SELECT count(*) FROM cue_deliveries)"
             )

    {:ok, counts} = Repo.cues_call(CuesSql, {:counts_window, "source", @now}, server: ctx.repo)
    assert counts[ctx.ref] == %{"received" => 20, "unmatched" => 8}
  end

  defp tick(id, symbol, verdict),
    do: %{"id" => id, "symbol" => symbol, "verdict" => verdict}
end
