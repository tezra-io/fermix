defmodule FermixChannels.Desktop.TwoEnginesHistoryTest do
  # M97 §8: a server and one of its computers in one VM, joined by the real
  # link. History is recorded into the computer's own store, each finished
  # sitting goes to the server with `history.submit`, and the server keeps the
  # note, marked with that computer, and never the raw text. A purge and a
  # late sitting give the same home in either order; a pause from chat holds a
  # sitting stamped inside it; a computer that summarizes on its own device
  # sends only the note; the roll-up runs once across computers.
  use ExUnit.Case, async: false

  alias FermixChannels.Desktop.HistoryUplink
  alias FermixChannels.Desktop.Offers
  alias FermixChannels.Test.TwoEngines
  alias FermixCore.ComputerHistory
  alias FermixCore.ComputerHistory.Delivery
  alias FermixCore.ComputerHistory.Ingest
  alias FermixCore.ComputerHistory.Purge
  alias FermixCore.ComputerHistory.Recall
  alias FermixCore.ComputerHistory.Report
  alias FermixCore.ComputerHistory.Sittings
  alias FermixCore.ComputerHistory.Spool
  alias FermixCore.ComputerHistory.Submission
  alias FermixCore.ComputerHistory.Summarizer
  alias FermixCore.Computers.Switches
  alias FermixCore.Memory.Repo
  alias FermixTestSupport.SafeRm

  @typed "the Juniper Street lease renewal moves the rent to nine forty in March"
  @app "com.example.notes"
  @minute 60_000

  # The provider on either engine: what it says comes from the test, and every
  # call is told to it, from whichever process made it. Like a real adapter it
  # reports each call through the one emitter, with its request and reply.
  defmodule Provider do
    @behaviour FermixCore.Providers.Adapter

    alias FermixCore.Providers.Telemetry, as: ProviderTelemetry

    @impl true
    def chat(messages, _capabilities, opts) do
      send(:persistent_term.get({__MODULE__, :test}), {:provider, opts[:agent], messages})
      reply = :persistent_term.get({__MODULE__, :reply}, "The owner revised the rent note.")

      ProviderTelemetry.emit_call(
        %{provider: :ollama, model: opts[:model], agent: opts[:agent], status: :ok},
        1,
        session_id: opts[:session_id],
        input: messages,
        output: reply
      )

      {:ok, %{content: reply, tool_calls: [], provider_state: nil, usage: %{}}}
    end

    @impl true
    def continue(_state, _results, _opts), do: {:error, :not_supported}
    @impl true
    def to_provider_tools(_caps), do: []
    @impl true
    def parse_tool_calls(_response), do: []
    @impl true
    def parse_response(response), do: response
  end

  setup do
    :persistent_term.put({Provider, :test}, self())
    capture = Application.get_env(:fermix_core, :telemetry, [])
    Application.put_env(:fermix_core, :telemetry, Keyword.put(capture, :capture_content, true))

    on_exit(fn ->
      Application.put_env(:fermix_core, :telemetry, capture)
      :persistent_term.erase({Provider, :test})
      :persistent_term.erase({Provider, :reply})
    end)

    store = SafeRm.make_tmp_dir!("two_engines_history_home")
    on_exit(fn -> SafeRm.rm_rf!(store) end)
    db_path = Path.join(store, "memory.db")
    repo = :"two_engines_history_repo_#{System.unique_integer([:positive])}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)

    # Which machines the server takes history from, by the one rule, from what
    # its computer offers now (M97 §8.5).
    contributors = fn ->
      ComputerHistory.contributors(
        repo: repo,
        recording?: false,
        computers: [TwoEngines.computer(:persistent_term.get({__MODULE__, :engines}))]
      )
    end

    history = [
      repo: repo,
      adapter: Provider,
      config: [summarizer: :local],
      route_opts: [model: "llama3"],
      contributors: contributors
    ]

    e = TwoEngines.start!(offers: [:files, :history], history: history)
    :persistent_term.put({__MODULE__, :engines}, e)
    on_exit(fn -> :persistent_term.erase({__MODULE__, :engines}) end)

    spool =
      start_supervised!({Spool, path: Path.join([e.root, "device", "history.db"]), name: nil})

    t0 = System.system_time(:millisecond) - 3 * 60 * @minute

    %{e: e, repo: repo, store: store, spool: spool, t0: t0}
  end

  # -- the computer's side -------------------------------------------------------------

  defp record!(ctx, minutes, text) do
    events =
      Enum.with_index(minutes, fn minute, i ->
        %{
          boot_id: "computer-boot",
          source_seq: minute * 10 + i,
          ts: ctx.t0 + minute * @minute,
          type: "field.value",
          bundle_id: @app,
          window_title: "Rent — Notes",
          field_label: "Body",
          text: text
        }
      end)

    assert {:ok, %{written: written}} =
             Ingest.ingest(events, spool: ctx.spool, apps: [@app], now: at(ctx, 0))

    written
  end

  defp send_sittings(ctx, opts \\ []) do
    uplink = fn payload ->
      send(self(), {:sent, payload})

      HistoryUplink.submit(payload,
        relay: ctx.e.relay,
        switches: Switches.only([:files, :history])
      )
    end

    Sittings.run(
      [
        uplink: uplink,
        spool: ctx.spool,
        now: at(ctx, Keyword.get(opts, :at_minute, 60)),
        timezone: "Etc/UTC",
        config: Keyword.get(opts, :config, enabled: true)
      ] ++ Keyword.take(opts, [:adapter, :route_opts])
    )
  end

  defp at(ctx, minute), do: DateTime.from_unix!(ctx.t0 + minute * @minute, :millisecond)

  defp raw_events(ctx) do
    {:ok, events} = Spool.events_after(0, 100, server: ctx.spool)
    events
  end

  # -- the server's side ---------------------------------------------------------------

  defp notes(ctx, computer \\ :all) do
    {:ok, rows} =
      Repo.computer_history_memories_in_window(0, ctx.t0 * 2, 50,
        server: ctx.repo,
        computer: computer
      )

    rows
  end

  defp purge!(ctx, at_minute) do
    {:ok, %{interval: id}} =
      Purge.purge({:last, 2 * 60 * @minute},
        repo: ctx.repo,
        spool: nil,
        now: ctx.t0 + at_minute * @minute
      )

    id
  end

  # Every byte the server's history store holds, its WAL included.
  defp server_bytes(ctx) do
    ctx.store
    |> File.ls!()
    |> Enum.map_join(&File.read!(Path.join(ctx.store, &1)))
  end

  defp provider_calls(ref) do
    receive do
      {[:fermix, :provider, :call], ^ref, _measures, metadata} -> [metadata | provider_calls(ref)]
    after
      0 -> []
    end
  end

  # -- the tests -------------------------------------------------------------------------

  test "a sitting recorded on the computer becomes a note on the server, marked with it", ctx do
    record!(ctx, [0, 1, 2], @typed)
    ref = :telemetry_test.attach_event_handlers(self(), [[:fermix, :provider, :call]])

    {result, log} = ExUnit.CaptureLog.with_log(fn -> send_sittings(ctx) end)

    assert {:ok, %{sent: 1, notes: 1}} = result
    assert_received {:sent, %{"text" => text}}
    assert text =~ "Juniper Street lease renewal"

    assert [note] = notes(ctx)
    assert note.computer_id == ctx.e.device_id
    assert note.summary == "The owner revised the rent note."
    assert notes(ctx, ctx.e.device_id) == [note]
    assert notes(ctx, "") == []

    # The summary was made from the text, which the server holds nowhere: not
    # in its store, not in a provider call's telemetry (what its trace and
    # Opik export record), not in its log.
    assert_received {:provider, "computer_history_summarizer", [_system, %{content: input}]}
    assert input =~ "Juniper Street lease renewal"
    refute server_bytes(ctx) =~ "Juniper Street lease"
    refute log =~ "Juniper Street lease"

    # Every provider call seen while it ran (another test's among them, perhaps):
    # the summary call's withheld, and none carries the typed text.
    :telemetry.detach(ref)
    calls = provider_calls(ref)

    assert Enum.any?(
             calls,
             &(&1[:agent] == "computer_history_summarizer" and &1[:content_withheld])
           )

    refute Enum.any?(calls, &(inspect(&1) =~ "Juniper"))

    # The computer's cursor moved on the answer, and its raw events stay there.
    assert {:ok, %{last_status: "summarized"}} = Spool.state(server: ctx.spool)
    assert length(raw_events(ctx)) == 3
  end

  # A purge from chat while the computer is away, then the computer comes back
  # with a sitting inside the window: refused with the interval, which it applies.
  test "a purge first, then a late sitting from a computer that was away: no note", ctx do
    record!(ctx, [10, 11], @typed)
    interval = purge!(ctx, 120)

    assert {:ok, %{sent: 1, notes: 0}} = send_sittings(ctx, at_minute: 130)
    assert notes(ctx) == []
    assert raw_events(ctx) == []
    assert {:ok, %{home_mark: ^interval}} = Spool.link(server: ctx.spool)
    assert record!(ctx, [12], "late again") == 0
  end

  test "a sitting first, then a purge, then a late sitting in the window: no note", ctx do
    record!(ctx, [10, 11], "first draft of the rent note")
    assert {:ok, %{notes: 1}} = send_sittings(ctx, at_minute: 40)
    assert [_note] = notes(ctx)

    record!(ctx, [50, 51], @typed)
    purge!(ctx, 120)
    assert notes(ctx) == []

    assert {:ok, %{notes: 0}} = send_sittings(ctx, at_minute: 130)
    assert notes(ctx) == []
    assert raw_events(ctx) == []
  end

  test "a pause from chat refuses a sitting stamped inside it, and the computer pauses", ctx do
    {:ok, _id} =
      Repo.computer_history_home(
        :pause_window,
        [ctx.t0, ctx.t0 + 120 * @minute, ctx.t0, :all],
        server: ctx.repo
      )

    record!(ctx, [5, 6], @typed)

    assert {:ok, %{notes: 0}} = send_sittings(ctx, at_minute: 30)
    assert notes(ctx) == []
    assert raw_events(ctx) == []
    assert {:ok, %{pause_until: until}} = Spool.state(server: ctx.spool)
    assert is_binary(until)
  end

  test "a computer that summarizes on its own device sends only the note", ctx do
    record!(ctx, [0, 1, 2], @typed)
    :persistent_term.put({Provider, :reply}, "Updated the rent note before Friday.")

    assert {:ok, %{notes: 1}} =
             send_sittings(ctx,
               config: [enabled: true, summarizer: :local],
               adapter: Provider,
               route_opts: [model: "llama3"]
             )

    assert_received {:sent, payload}
    refute Map.has_key?(payload, "text")
    assert %{"summary" => "Updated the rent note before Friday."} = payload["note"]
    refute Jason.encode!(payload) =~ "Juniper"

    # One call, the computer's; the server made none.
    assert_received {:provider, "computer_history_summarizer", _messages}
    refute_received {:provider, _agent, _messages}
    assert [%{summary: "Updated the rent note before Friday."}] = notes(ctx, ctx.e.device_id)
  end

  # A purge from chat reaches the computer's raw events over the link
  # (`history.apply`); one that is away is told once it is back, and the home
  # never sends an interval twice.
  test "a purge from chat deletes the computer's raw events, once it is reachable", ctx do
    record!(ctx, [10, 11], @typed)
    interval = purge!(ctx, 120)
    away = %{TwoEngines.computer(ctx.e) | connected: false}
    deliver = [repo: ctx.repo, call_opts: TwoEngines.call_opts(ctx.e)]

    assert %{away: ["studio Mac"]} = Delivery.deliver([computers: [away]] ++ deliver)
    assert length(raw_events(ctx)) == 2

    back = TwoEngines.computer(ctx.e)
    assert %{applied: ["studio Mac"]} = Delivery.deliver([computers: [back]] ++ deliver)
    assert raw_events(ctx) == []
    assert {:ok, %{home_mark: ^interval}} = Spool.link(server: ctx.spool)

    assert {:ok, [%{delivered_mark: ^interval}]} =
             Repo.computer_history_home(:computer_rows, [], server: ctx.repo)

    # Nothing left to tell: no second request.
    assert %{applied: ["studio Mac"]} =
             Delivery.deliver(
               [
                 computers: [back],
                 call: fn _c, _m, _o, _a, _ctx, _opts -> flunk("sent twice") end
               ] ++
                 deliver
             )
  end

  test "recall takes one computer's notes and names where each happened", ctx do
    record!(ctx, [0, 1], @typed)
    assert {:ok, %{notes: 1}} = send_sittings(ctx)

    loft = %{
      "v" => Submission.version(),
      "sitting" => "1-1:#{ctx.t0}",
      "from_ts" => ctx.t0 + 30 * @minute,
      "to_ts" => ctx.t0 + 31 * @minute,
      "event_count" => 2,
      "field_values" => 2,
      "titles" => ["Ledger"],
      "text" => ~s(00:30 field.value app=com.example.editor text="the loft ledger")
    }

    :persistent_term.put({Provider, :reply}, "Balanced the loft ledger.")

    assert %{status: :summarized} =
             Submission.accept("loft-91c2", loft,
               repo: ctx.repo,
               adapter: Provider,
               config: [summarizer: :local],
               route_opts: [model: "llama3"],
               contributors: ["loft-91c2"]
             )

    machines = %{ctx.e.device_id => "studio Mac", "loft-91c2" => "loft Linux"}
    opts = [repo: ctx.repo, machines: machines, now: at(ctx, 60), timezone: "Etc/UTC"]

    assert {:ok, studio} = Recall.query("today", [computer: ctx.e.device_id] ++ opts)
    assert studio =~ "[studio Mac, "
    assert studio =~ "rent note"
    refute studio =~ "loft ledger"

    assert {:ok, both} = Recall.query("today", opts)
    assert both =~ "[studio Mac, "
    assert both =~ "[loft Linux, "
  end

  test "the roll-up runs once on the home across computers, citing both", ctx do
    record!(ctx, [0, 1], "rent note on the studio Mac")
    assert {:ok, %{notes: 1}} = send_sittings(ctx)
    [%{id: studio_note}] = notes(ctx, ctx.e.device_id)

    loft = %{
      "v" => Submission.version(),
      "sitting" => "1-2:#{ctx.t0}",
      "from_ts" => ctx.t0 + 30 * @minute,
      "to_ts" => ctx.t0 + 31 * @minute,
      "event_count" => 2,
      "field_values" => 2,
      "titles" => ["Rent — Editor"],
      "text" => ~s(00:30 field.value app=com.example.editor text="rent ledger")
    }

    assert %{status: :summarized} =
             Submission.accept("loft-91c2", loft,
               repo: ctx.repo,
               adapter: Provider,
               config: [summarizer: :local],
               route_opts: [model: "llama3"],
               contributors: ["loft-91c2"]
             )

    [%{id: loft_note}] = notes(ctx, "loft-91c2")

    :persistent_term.put(
      {Provider, :reply},
      "## The rent\nThe owner keeps the rent ledger across both machines.\n" <>
        "sources: #{studio_note}, #{loft_note}"
    )

    assert :ok =
             Summarizer.run_rollup(
               repo: ctx.repo,
               spool: nil,
               machines: [ctx.e.device_id, "loft-91c2"],
               adapter: Provider,
               config: [summarizer: :local],
               route_opts: [model: "llama3"],
               now: DateTime.utc_now()
             )

    assert {:ok, [thread]} = Repo.computer_history_active_threads(8, server: ctx.repo)
    assert Enum.sort(Jason.decode!(thread.source_ids)) == Enum.sort([studio_note, loft_note])
  end

  # M97 §7.2, §8.5: `/history off` naming the computer, over the real link. The
  # home records it, the computer switches its history off as its own switch
  # does (the recorder's setting and the server's offer), and from then on the
  # home takes no sitting from it and makes no call for it.
  test "off from chat for this computer switches it off there, and the home takes nothing", ctx do
    record!(ctx, [0, 1, 2], @typed)
    # The computer's own file holds the switches its rig reads from an Agent.
    :ok = Switches.write(ctx.e.root, Switches.only([:files, :history]))
    computer = TwoEngines.computer(ctx.e)
    deliver = [repo: ctx.repo, call_opts: TwoEngines.call_opts(ctx.e)]

    assert :done = Delivery.switch_off(computer, deliver)

    assert {:ok, switches} = Switches.read(ctx.e.root)
    refute Keyword.fetch!(switches, :history)
    assert Keyword.fetch!(switches, :files)
    machine = File.read!(Path.join(ctx.e.root, "machine.toml"))
    assert machine =~ ~r/\[fermix_core\.computer_history\]\s+enabled = false/

    assert {:ok, [%{computer_id: id, off_requested_at: nil}]} =
             Repo.computer_history_home(:computer_rows, [], server: ctx.repo)

    assert id == ctx.e.device_id

    # What the computer's own reader does when its switches change: read them
    # again and send its offers.
    Agent.update(ctx.e.switch_agent, fn _switches -> switches end)
    Offers.changed(ctx.e.offers)
    await_history_off(ctx)

    # A sitting still sent (one the computer formed before it went off) is
    # refused off, with no call.
    assert {:held, "off"} = send_sittings(ctx)
    refute_received {:provider, _agent, _messages}
    assert notes(ctx) == []
  end

  # The home keeps a computer's report of its recorder (a state word and
  # counts, no text), which its `/history status` shows.
  test "a computer's report of its recorder is kept on the home", ctx do
    record!(ctx, [0, 1], @typed)

    {:ok, report} =
      Report.build(
        spool: ctx.spool,
        now_ms: ctx.t0 + 60 * @minute,
        recording?: true,
        status: %{mode: :capturing, reason: nil, lock_holder: nil}
      )

    assert :ok =
             HistoryUplink.report(report,
               relay: ctx.e.relay,
               switches: Switches.only([:files, :history])
             )

    assert {:ok, [%{report: kept, report_at: at}]} =
             Repo.computer_history_home(:computer_rows, [], server: ctx.repo)

    assert is_integer(at)
    assert %{"recorder" => "running", "events" => 2, "unsent" => 2} = Jason.decode!(kept)
    refute kept =~ "Juniper"
  end

  # The computer re-sends its offers when a switch changes; the server's live
  # record follows within the suite's bound.
  defp await_history_off(ctx, attempts \\ 1_000) do
    case Enum.find(TwoEngines.computer(ctx.e).offers, &(&1.id == "history")) do
      %{state: :on} when attempts > 0 ->
        Process.sleep(10)
        await_history_off(ctx, attempts - 1)

      %{state: :on} ->
        flunk("the server never heard that this computer's history went off")

      _off ->
        :ok
    end
  end
end
