defmodule FermixCore.Trips.PlacerTest do
  # M89 D13 B: the trip placer looks up again the stops a trip keeps waiting
  # (`trip_waits`) once the place search can run: when a Mac that offers
  # places connects, at the reset Brave's pacer last read, and at boot. One
  # run is one session, `trip_place:<hex>`, with its bookends; each trip it
  # places is one write through the trips' one writer, an ordinary rev and the
  # devices' push, nothing said in any chat. A wait ends after three tries or
  # seven days. The process never raises on a run's end, so it takes down
  # nothing after it.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Memory.Repo
  alias FermixCore.ReplyBlocks
  alias FermixCore.Trips.Placer
  alias FermixCore.Trips.Placer.Run
  alias FermixCore.Trips.Registry
  alias FermixCore.Trips.Telemetry
  alias FermixCore.Trips.Wire
  alias FermixTestSupport.TelemetryCapture

  # Every title, stop, place and id here is invented.
  @now ~U[2031-06-02 14:00:00Z]
  @conversation {"telegram", "40017", :root}
  @owner %{
    agent_name: "main",
    conversation_key: @conversation,
    source_trust: :operator,
    computer_use_origin: :interactive,
    chat_type: "private",
    outside_sources: MapSet.new()
  }
  @town "Varonne, Portugal"
  @tower %{latitude: 41.1402, longitude: -8.6113}
  @away {:error, "computer_away: no Mac that looks places up is online", %{attempt: 0}}
  @run_events [
    [:fermix, :trip_place, :run_start],
    [:fermix, :trip_place, :run_complete],
    [:fermix, :trip_place, :run_error]
  ]

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-trip-placer-#{unique}.db")
    repo = :"trip_placer_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)
    holder = start_supervised!(Supervisor.child_spec({ReplyBlocks, name: nil}, id: :holder))
    tasks = start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: :tasks))

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{
      repo: repo,
      db_path: db_path,
      holder: holder,
      tasks: tasks,
      session: "trip_place:t#{unique}"
    }
  end

  defp place(name, id, point \\ @tower) do
    %{
      name: name,
      location: point,
      address: "#{id} Rua Inventada, Varonne",
      apple_place_id: "I#{id}",
      source_url: "https://maps.apple.com/place?place-id=I#{id}"
    }
  end

  defp edit!(ctx, context, ops, answers) do
    context =
      Map.put(context, :place_lookup, fn %{query: query} -> Map.fetch!(answers, query) end)

    opts = [
      repo: ctx.repo,
      now: @now,
      reply_blocks: ctx.holder,
      notifier: fn _changes -> :ok end,
      placer: fn -> :ok end
    ]

    assert {:ok, answer} = Registry.edit(%{"trip" => "Varonne", "ops" => ops}, context, opts)
    answer
  end

  # A trip near the invented town with Lunch at [3] waiting for "Prado", and
  # Quay at [4] waiting for "Cais Velho", added after outside content.
  defp waiting!(ctx) do
    edit!(
      ctx,
      @owner,
      [
        %{"op" => "create", "days" => 2, "near" => @town},
        %{"op" => "add", "text" => "Lunch", "day" => 1, "place" => "Prado"}
      ],
      %{"Prado" => @away}
    )

    outside = %{@owner | outside_sources: MapSet.new([:web_fetch])}

    edit!(
      ctx,
      outside,
      [%{"op" => "add", "text" => "Quay", "day" => 1, "place" => "Cais Velho"}],
      %{
        "Cais Velho" => @away
      }
    )

    trip!(ctx)
  end

  defp trip!(ctx, repo \\ nil) do
    assert {:ok, read} =
             Repo.trips_call({:read_trip, "default", "main", "Varonne"}, server: repo || ctx.repo)

    read
  end

  defp stop!(ctx, n), do: Enum.find(trip!(ctx).rows, &(&1.n == n))

  # Each waiting stop's number and tries, in number order.
  defp waits(ctx) do
    sql =
      "SELECT r.n, w.tries FROM trip_waits AS w JOIN trip_rows AS r ON r.id = w.row_id " <>
        "ORDER BY r.n"

    raw(ctx, sql)
  end

  defp tries(ctx), do: Enum.map(waits(ctx), &List.last/1)

  defp raw(ctx, sql) do
    {:ok, conn} = Exqlite.Sqlite3.open(ctx.db_path)

    try do
      {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, stmt)
      :ok = Exqlite.Sqlite3.release(conn, stmt)
      rows
    after
      Exqlite.Sqlite3.close(conn)
    end
  end

  defp read!(ctx) do
    assert {:ok, %{text: text}} = Registry.read(%{"trip" => "Varonne"}, @owner, repo: ctx.repo)
    text
  end

  defp at(offset_s), do: fn -> DateTime.add(@now, offset_s, :second) end

  # A backend that answers each query from `answers`, telling the test each
  # request; always ready unless `ready` says otherwise.
  defp backend(answers, ready \\ fn -> :ok end) do
    test = self()

    search = fn %{query: query} = request ->
      send(test, {:searched, request})

      case Map.fetch!(answers, query) do
        answer when is_function(answer, 0) -> answer.()
        answer -> answer
      end
    end

    fn _context -> %{name: "computer", search: {:ok, search}, ready: ready} end
  end

  defp run_opts(ctx, backend, more \\ []) do
    test = self()

    Keyword.merge(
      [
        repo: ctx.repo,
        now: fn -> @now end,
        session_id: ctx.session,
        backend: backend,
        notifier: fn changes -> send(test, {:notified, changes}) && :ok end
      ],
      more
    )
  end

  describe "a run" do
    # D9: a place an edit gives after outside content marks its stop. Given
    # by words that waited, it marks the stop when the placer places it, as
    # if it had landed in the call; a clean call's place marks nothing, and a
    # stop already marked stays so.
    test "a place given after outside content marks its stop when placed later; a clean one does not",
         ctx do
      outside = %{@owner | outside_sources: MapSet.new([:web_fetch])}

      edit!(
        ctx,
        @owner,
        [
          %{"op" => "create", "days" => 2, "near" => @town},
          %{"op" => "add", "text" => "Lunch", "day" => 1},
          %{"op" => "add", "text" => "Quay", "day" => 1}
        ],
        %{}
      )

      edit!(ctx, outside, [%{"op" => "add", "text" => "Dock", "day" => 1}], %{})
      edit!(ctx, outside, [%{"op" => "edit", "n" => 3, "place" => "Prado"}], %{"Prado" => @away})

      edit!(
        ctx,
        @owner,
        [
          %{"op" => "edit", "n" => 4, "place" => "Cais Velho"},
          %{"op" => "edit", "n" => 5, "place" => "Doca"}
        ],
        %{"Cais Velho" => @away, "Doca" => @away}
      )

      # Waiting, the stops are as their calls left them.
      assert %{stamped: false} = stop!(ctx, 3)
      assert %{stamped: false} = stop!(ctx, 4)
      assert %{stamped: true} = stop!(ctx, 5)

      answers = %{
        "Prado" => {:ok, [place("Prado", 1)], %{}},
        "Cais Velho" => {:ok, [place("Cais Velho", 2)], %{}},
        "Doca" => {:ok, [place("Doca", 3)], %{}}
      }

      assert %{next_ms: nil} = Run.run(:computer, run_opts(ctx, backend(answers)))

      assert %{place: %{"name" => "Prado"}, stamped: true} = stop!(ctx, 3)
      assert %{place: %{"name" => "Cais Velho"}, stamped: false} = stop!(ctx, 4)
      assert %{place: %{"name" => "Doca"}, stamped: true} = stop!(ctx, 5)
    end

    test "places each waiting stop by the name rule: one write, one push, the mark kept", ctx do
      %{trip: %{rev: rev}, rows: rows} = waiting!(ctx)
      lunch = Enum.find(rows, &(&1.n == 3))
      quay = Enum.find(rows, &(&1.n == 4))
      refute lunch.stamped
      assert quay.stamped

      answers = %{
        "Prado" => {:ok, [place("Prado", 1)], %{}},
        "Cais Velho" => {:ok, [place("Cais Velho", 2)], %{}}
      }

      assert %{next_ms: nil} = Run.run(:computer, run_opts(ctx, backend(answers)))

      # Searched near the trip's town, as the trip stands now.
      assert_received {:searched, %{query: "Prado", anchor: {:location, @town}}}
      assert_received {:searched, %{query: "Cais Velho"}}

      trip_id = lunch.trip_id
      expected = rev + 1

      assert_received {:notified,
                       %{owner_id: "default", trips: [%{id: ^trip_id, rev: ^expected}]}}

      refute_received {:notified, _more}

      assert %{trip: %{rev: ^expected}} = trip!(ctx)
      assert %{place: %{"name" => "Prado"}, stamped: false} = stop!(ctx, 3)
      assert %{place: %{"name" => "Cais Velho"}, stamped: true} = stop!(ctx, 4)
      assert waits(ctx) == []

      # Nothing joins any conversation: no chat hears of it.
      assert ReplyBlocks.take(ctx.holder, @conversation) == []
    end

    test "a result by another name is not placed; the stop stops waiting, its words kept nowhere",
         ctx do
      %{trip: %{rev: rev}} = waiting!(ctx)

      answers = %{
        "Prado" => {:ok, [place("Harbour Rooms", 9)], %{}},
        "Cais Velho" => {:ok, [], %{}}
      }

      assert %{next_ms: nil} = Run.run(:computer, run_opts(ctx, backend(answers)))

      refute_received {:notified, _changes}
      assert %{trip: %{rev: ^rev}} = trip!(ctx)
      assert %{place: nil, text: "Lunch", note: nil} = stop!(ctx, 3)
      assert waits(ctx) == []
    end

    # Only a lookup that reached the place search and failed spends a try,
    # and each retry waits longer, so a burst of wakes spends nothing more.
    test "a try is a lookup sent and failed; retries wait 30 min, then 3 h, then end", ctx do
      waiting!(ctx)
      busy = {:error, "computer_busy: busy", %{attempt: 1}}
      answers = %{"Prado" => busy, "Cais Velho" => busy}

      run = fn offset_s ->
        Run.run(:computer, run_opts(ctx, backend(answers), now: at(offset_s)))
      end

      assert %{next_ms: 1_800_000} = run.(0)
      assert tries(ctx) == [1, 1]
      assert_received {:searched, %{query: "Prado"}}
      assert_received {:searched, %{query: "Cais Velho"}}

      # A burst of offers a minute on: nothing is due, nothing is looked up.
      assert %{next_ms: 1_740_000} = run.(60)
      refute_received {:searched, _request}
      assert tries(ctx) == [1, 1]

      assert %{next_ms: 10_800_000} = run.(1_800)
      assert tries(ctx) == [2, 2]
      assert_received {:searched, %{query: "Prado"}}
      assert_received {:searched, %{query: "Cais Velho"}}
      assert %{next_ms: 7_200_000} = run.(1_800 + 3_600)
      refute_received {:searched, %{query: "Cais Velho"}}

      assert %{next_ms: nil} = run.(1_800 + 10_800)
      assert waits(ctx) == []
      assert %{place: nil} = stop!(ctx, 3)
    end

    test "a lookup a stop left unsent, or one that sent nothing, spends no try", ctx do
      waiting!(ctx)
      limited = {:error, "rate_limited: slow down", %{attempt: 1}}
      away = {:error, "computer_away: no Mac online", %{attempt: 0}}

      # Prado's answer stops the call: Cais Velho was never sent.
      answers = %{"Prado" => limited, "Cais Velho" => {:ok, [place("Cais Velho", 2)], %{}}}
      assert %{next_ms: 300_000} = Run.run(:computer, run_opts(ctx, backend(answers)))
      assert tries(ctx) == [1, 0]
      refute_received {:searched, %{query: "Cais Velho"}}

      answers = %{"Cais Velho" => away}
      Run.run(:computer, run_opts(ctx, backend(answers), now: at(1)))
      assert tries(ctx) == [1, 0]
    end

    test "after a restart, a boot run spends no try on what is not due", ctx do
      waiting!(ctx)
      busy = {:error, "computer_busy: busy", %{attempt: 1}}
      answers = %{"Prado" => busy, "Cais Velho" => busy}
      Run.run(:computer, run_opts(ctx, backend(answers)))
      assert tries(ctx) == [1, 1]
      assert_received {:searched, %{query: "Prado"}}
      assert_received {:searched, %{query: "Cais Velho"}}

      :ok = stop_supervised(ctx.repo)
      reopened = :"#{ctx.repo}_after_restart"
      start_supervised!({Repo, name: reopened, enabled: true, database_path: ctx.db_path})

      for offset_s <- [5, 10] do
        Run.run(:boot, run_opts(ctx, backend(answers), repo: reopened, now: at(offset_s)))
      end

      refute_received {:searched, _request}
      assert tries(ctx) == [1, 1]
    end

    test "a wait seven days old stops waiting, looked up no more", ctx do
      waiting!(ctx)
      later = DateTime.add(@now, 8 * 86_400, :second)
      TelemetryCapture.attach(@run_events, session_id: ctx.session)

      answers = %{"Prado" => {:ok, [place("Prado", 1)], %{}}}

      assert %{next_ms: nil} =
               Run.run(:boot, run_opts(ctx, backend(answers), now: fn -> later end))

      refute_received {:searched, _request}
      assert waits(ctx) == []
      assert %{place: nil} = stop!(ctx, 3)

      assert_received {:telemetry, [:fermix, :trip_place, :run_complete], %{expired: 2}, _meta}
    end

    test "while the place search cannot run, nothing is looked up and no try is spent", ctx do
      waiting!(ctx)

      for {why, next} <- [{:no_mac, 6 * 3_600_000}, {{:brave_spent, 90_000}, 90_000}] do
        answers = %{"Prado" => {:ok, [place("Prado", 1)], %{}}}
        later = fn -> {:later, why} end

        assert %{next_ms: ^next} = Run.run(:timer, run_opts(ctx, backend(answers, later)))
        refute_received {:searched, _request}
        assert tries(ctx) == [0, 0]
      end
    end

    test "an edit made while the lookup ran wins: the placer never overwrites it", ctx do
      %{rows: rows} = waiting!(ctx)
      lunch = Enum.find(rows, &(&1.n == 3))

      # The owner picks Lunch's place on their Mac while the search runs.
      pick = fn ->
        params = %{
          "client_msg_id" => "dev-1",
          "trip_id" => lunch.trip_id,
          "op" => %{
            "op" => "edit",
            "row_id" => lunch.id,
            "place" => %{
              "name" => "Pick",
              "location" => %{"latitude" => 41.1, "longitude" => -8.6}
            }
          }
        }

        {:ok, _edited} =
          Registry.device_edit(params, :independent, repo: ctx.repo, notifier: fn _c -> :ok end)

        {:ok, [place("Prado", 1)], %{}}
      end

      answers = %{"Prado" => pick, "Cais Velho" => {:ok, [place("Cais Velho", 2)], %{}}}
      Run.run(:computer, run_opts(ctx, backend(answers)))

      assert %{place: %{"name" => "Pick"}} = stop!(ctx, 3)
      assert %{place: %{"name" => "Cais Velho"}} = stop!(ctx, 4)
      assert waits(ctx) == []
    end

    test "is one session with its bookends, its trip write the trip's edit under it", ctx do
      waiting!(ctx)
      TelemetryCapture.attach(@run_events ++ [[:fermix, :trip, :edit]], session_id: ctx.session)
      answers = %{"Prado" => {:ok, [place("Prado", 1)], %{}}, "Cais Velho" => @away}

      Run.run(:computer, run_opts(ctx, backend(answers)))

      assert_received {:telemetry, [:fermix, :trip_place, :run_start], %{waiting: 2},
                       %{trigger: :computer, component: "trips"}}

      assert_received {:telemetry, [:fermix, :trip, :edit], %{trips: 1, ops: 1, placed: 1},
                       %{made_via: "trip_place", outcome: :ok, backend: "computer"}}

      assert_received {:telemetry, [:fermix, :trip_place, :run_complete], measurements, metadata}

      assert %{placed: 1, waiting: 1, stopped_waiting: 0, expired: 0, trips: 1, failed: 0} =
               measurements

      assert is_integer(measurements.duration_us)
      assert %{trigger: :computer, backend: "computer", skipped: nil} = metadata
      assert metadata.stop_reason == :computer_away
      refute_received {:telemetry, [:fermix, :trip_place, :run_error], _measurements, _meta}

      assert Telemetry.place_session_id() =~ ~r/\Atrip_place:[0-9a-f]{16}\z/
    end

    # The blocker: newer words that place nothing end the old wait, so the
    # placer never places the old words over them.
    test "newer words not found leave no wait: the placer places nothing on that stop", ctx do
      waiting!(ctx)

      edit!(ctx, @owner, [%{"op" => "edit", "n" => 3, "place" => "Tasca do Zé"}], %{
        "Tasca do Zé" => {:ok, [], %{}}
      })

      assert waits(ctx) == [[4, 0]]

      answers = %{
        "Prado" => {:ok, [place("Prado", 1)], %{}},
        "Cais Velho" => {:ok, [place("Cais Velho", 2)], %{}}
      }

      Run.run(:computer, run_opts(ctx, backend(answers)))

      refute_received {:searched, %{query: "Prado"}}
      assert %{place: nil} = stop!(ctx, 3)
      assert %{place: %{"name" => "Cais Velho"}} = stop!(ctx, 4)
    end

    test "a read shows a waiting stop marked, and no mark once it is placed or ends", ctx do
      %{trip: trip, rows: rows} = waiting!(ctx)
      text = read!(ctx)
      assert text =~ "\n- [3] Lunch (place waiting)\n"
      assert text =~ ~S|"Quay" (place waiting)|

      # A device's wire says nothing of it.
      refute Jason.encode!(Wire.trip(trip, rows)) =~ "waiting"

      answers = %{
        "Prado" => {:ok, [place("Prado", 1)], %{}},
        "Cais Velho" => {:ok, [place("Harbour Rooms", 9)], %{}}
      }

      Run.run(:computer, run_opts(ctx, backend(answers)))
      text = read!(ctx)
      refute text =~ "waiting"
      assert text =~ ~S|- [3] Lunch · at "Prado, 1 Rua Inventada, Varonne"|
    end

    @tag :capture_log
    test "a trip that cannot be read is counted, and the run says it failed", ctx do
      waiting!(ctx)
      TelemetryCapture.attach(@run_events, session_id: ctx.session)
      raw(ctx, "ALTER TABLE trip_rows RENAME COLUMN note TO memo")

      assert %{failed: true} =
               Run.run(:computer, run_opts(ctx, backend(%{"Prado" => {:ok, [], %{}}})))

      assert_received {:telemetry, [:fermix, :trip_place, :run_complete], %{failed: 1}, _meta}
      assert tries(ctx) == [0, 0]
    end

    test "a store that cannot be read ends the run with run_error, its real duration and failed",
         ctx do
      TelemetryCapture.attach(@run_events, session_id: ctx.session)
      stalled = start_supervised!(FermixTestSupport.StalledRepo)

      log =
        capture_log(fn ->
          assert %{failed: true} =
                   Run.run(:boot, run_opts(ctx, backend(%{}), repo: stalled, timeout: 50))
        end)

      assert log =~ "could not read the waiting stops"

      assert_received {:telemetry, [:fermix, :trip_place, :run_error], %{duration_us: us},
                       %{error_code: "repo_timeout", trigger: :boot}}

      assert us >= 50_000
    end

    test "a Mac's computers that cannot be read are said in the log, never taken for none" do
      opts = [
        role: :primary,
        rows: fn -> {:error, :not_running} end,
        records: %{"6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e" => %{}},
        live: %{},
        version: "1.2.3"
      ]

      log =
        capture_log(fn ->
          assert Run.ready(:computer, %{computers_opts: opts}) == {:later, :computers_unread}
        end)

      assert log =~ "not_running"
    end

    test "with nothing waiting a run is no run: no lookup and no event", ctx do
      TelemetryCapture.attach(@run_events, session_id: ctx.session)
      assert %{next_ms: nil} = Run.run(:boot, run_opts(ctx, backend(%{})))
      refute_received {:telemetry, _event, _measurements, _metadata}
    end
  end

  describe "the process" do
    defp start_placer!(ctx, more) do
      test = self()

      opts =
        Keyword.merge(
          [
            name: nil,
            enabled: true,
            task_supervisor: ctx.tasks,
            timer: fn message, delay -> send(test, {:armed, message, delay}) && make_ref() end,
            now_ms: fn -> 0 end
          ],
          more
        )

      start_supervised!({Placer, opts}, id: make_ref())
    end

    # The real run, telling the test each run's trigger once it ends.
    defp told_run do
      test = self()

      fn trigger, opts ->
        result = Run.run(trigger, opts)
        send(test, {:ran, trigger, result})
        result
      end
    end

    test "boot resumes the waits left from before a restart, across a reopen of the store",
         ctx do
      waiting!(ctx)
      :ok = stop_supervised(ctx.repo)
      reopened = :"#{ctx.repo}_reopened"
      start_supervised!({Repo, name: reopened, enabled: true, database_path: ctx.db_path})

      answers = %{
        "Prado" => {:ok, [place("Prado", 1)], %{}},
        "Cais Velho" => {:ok, [place("Cais Velho", 2)], %{}}
      }

      start_placer!(ctx,
        run: told_run(),
        run_opts: run_opts(ctx, backend(answers), repo: reopened)
      )

      assert_receive {:ran, :boot, %{next_ms: nil}}
      assert_receive {:notified, %{trips: [_change]}}
      assert %{rows: rows} = trip!(ctx, reopened)
      assert Enum.all?(Enum.filter(rows, &(&1.kind == :stop)), &match?(%{"name" => _}, &1.place))
    end

    # The blocker, end to end: the stop waits on its old words while the Mac
    # is away; newer words that also wait take their place, alone; the Mac
    # connecting places the stop by the newer words, never the old.
    test "newer words that wait replace the old: the Mac's connect places the newer, only", ctx do
      waiting!(ctx)

      edit!(ctx, @owner, [%{"op" => "edit", "n" => 3, "place" => "Tasca do Zé"}], %{
        "Tasca do Zé" => @away
      })

      assert [["Tasca do Zé"], ["Cais Velho"]] =
               raw(ctx, "SELECT words FROM trip_waits ORDER BY words DESC")

      online = :atomics.new(1, [])
      ready = fn -> if :atomics.get(online, 1) == 1, do: :ok, else: {:later, :no_mac} end

      answers = %{
        "Prado" => {:ok, [place("Prado", 1)], %{}},
        "Tasca do Zé" => {:ok, [place("Tasca do Zé", 7)], %{}},
        "Cais Velho" => {:ok, [place("Cais Velho", 2)], %{}}
      }

      placer =
        start_placer!(ctx, run: told_run(), run_opts: run_opts(ctx, backend(answers, ready)))

      assert_receive {:ran, :boot, _skipped}
      :ok = :atomics.put(online, 1, 1)
      :ok = Placer.places_offered(placer, "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e")
      assert_receive {:ran, :computer, %{next_ms: nil}}

      refute_received {:searched, %{query: "Prado"}}
      assert_received {:searched, %{query: "Tasca do Zé"}}
      assert %{place: %{"name" => "Tasca do Zé"}} = stop!(ctx, 3)
    end

    test "a Mac that offers places connecting places what waited for it, once", ctx do
      waiting!(ctx)
      online = :atomics.new(1, [])
      ready = fn -> if :atomics.get(online, 1) == 1, do: :ok, else: {:later, :no_mac} end

      answers = %{
        "Prado" => {:ok, [place("Prado", 1)], %{}},
        "Cais Velho" => {:ok, [place("Cais Velho", 2)], %{}}
      }

      placer =
        start_placer!(ctx, run: told_run(), run_opts: run_opts(ctx, backend(answers, ready)))

      # At boot no Mac is online: nothing is looked up, nothing is spent.
      assert_receive {:ran, :boot, %{next_ms: 21_600_000}}
      assert_receive {:armed, {:wake, _token}, 21_600_000}
      refute_received {:searched, _request}

      :ok = :atomics.put(online, 1, 1)
      :ok = Placer.places_offered(placer, "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e")

      assert_receive {:ran, :computer, %{next_ms: nil}}
      assert_receive {:notified, %{trips: [_change]}}
      refute_received {:notified, _more}
      assert %{place: %{"name" => "Prado"}} = stop!(ctx, 3)
    end

    test "Brave's reset wakes it: the timer at what the pacer last read, delivered by hand",
         ctx do
      waiting!(ctx)
      spent = :atomics.new(1, [])
      :ok = :atomics.put(spent, 1, 1)

      ready = fn ->
        if :atomics.get(spent, 1) == 1, do: {:later, {:brave_spent, 90_000}}, else: :ok
      end

      answers = %{
        "Prado" => {:ok, [place("Prado", 1)], %{}},
        "Cais Velho" => {:ok, [place("Cais Velho", 2)], %{}}
      }

      placer =
        start_placer!(ctx, run: told_run(), run_opts: run_opts(ctx, backend(answers, ready)))

      assert_receive {:ran, :boot, %{next_ms: 90_000}}
      assert_receive {:armed, {:wake, token} = wake, 90_000}

      :ok = :atomics.put(spent, 1, 0)
      send(placer, wake)

      assert_receive {:ran, :timer, %{next_ms: nil}}
      assert %{place: %{"name" => "Cais Velho"}} = stop!(ctx, 4)

      # A wake whose token is spent starts nothing: the next run is the
      # trigger sent after it.
      send(placer, {:wake, token})
      :ok = Placer.places_offered(placer, "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e")
      assert_receive {:ran, trigger, _result}
      assert trigger == :computer
    end

    test "a saved wait arms a wake five minutes on; the earlier of two wakes stands", ctx do
      placer = start_placer!(ctx, run: fn _trigger, _opts -> %{next_ms: nil} end)
      :ok = Placer.waits_saved(placer)
      assert_receive {:armed, {:wake, _token}, 300_000}
      :ok = Placer.waits_saved(placer)
      :sys.get_state(placer)
      refute_received {:armed, {:wake, _token}, _delay}
    end

    test "one run at a time: a trigger during a run runs once after it", ctx do
      test = self()
      running = :atomics.new(1, [])

      run = fn trigger, _opts ->
        send(test, {:running, trigger, self(), :atomics.add_get(running, 1, 1)})

        receive do
          :finish ->
            :atomics.sub(running, 1, 1)
            %{next_ms: nil}
        end
      end

      placer = start_placer!(ctx, run: run)
      assert_receive {:running, :boot, first, 1}

      :ok = Placer.places_offered(placer, "a")
      :ok = Placer.places_offered(placer, "b")
      send(first, :finish)
      assert_receive {:running, trigger, second, 1}
      assert trigger == :computer

      # Had the two triggers queued two runs, the next run would be the
      # second of them, not the wake's.
      :ok = Placer.waits_saved(placer)
      assert_receive {:armed, {:wake, _token} = wake, 300_000}
      send(second, :finish)
      send(placer, wake)
      assert_receive {:running, trigger, third, 1}
      assert trigger == :timer
      send(third, :finish)
    end

    # A run names its session before it starts, so the placer closes the
    # run's trace itself when the run never does.
    @tag :capture_log
    test "a run that raises is closed by the placer: run_error under its session, its kind",
         ctx do
      TelemetryCapture.attach(@run_events, session_id: ctx.session)
      test = self()

      run = fn _trigger, opts ->
        send(test, {:session, Keyword.fetch!(opts, :session_id)})
        raise "the store is gone"
      end

      start_placer!(ctx, run: run, run_opts: [session_id: ctx.session])
      assert_receive {:session, session}
      assert session == ctx.session

      assert_receive {:telemetry, [:fermix, :trip_place, :run_error], %{duration_us: us},
                      %{error_code: "crashed", reason: "RuntimeError", trigger: :boot}}

      assert is_integer(us)
    end

    @tag :capture_log
    test "a run past 120 s is killed and closed: run_error, overran", ctx do
      TelemetryCapture.attach(@run_events, session_id: ctx.session)
      test = self()

      run = fn _trigger, _opts ->
        send(test, {:running, self()})

        receive do
          :never -> %{next_ms: nil}
        end
      end

      placer = start_placer!(ctx, run: run, run_opts: [session_id: ctx.session])
      assert_receive {:running, pid}
      ref = Process.monitor(pid)
      assert_receive {:armed, {:overran, _task} = overran, 120_000}

      send(placer, overran)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert_receive {:telemetry, [:fermix, :trip_place, :run_error], _measurements,
                      %{error_code: "overran", trigger: :boot}}
    end

    test "each run of the placer gets a session of its own", ctx do
      test = self()

      run = fn _trigger, opts ->
        send(test, {:session, Keyword.fetch!(opts, :session_id)})
        %{next_ms: nil}
      end

      placer = start_placer!(ctx, run: run)
      assert_receive {:session, "trip_place:" <> _hex = first}
      :ok = Placer.places_offered(placer, "a")
      assert_receive {:session, "trip_place:" <> _hex = second}
      assert first != second
    end

    test "failing runs back off, doubling, and a clean run resets the wait", ctx do
      failing = %{next_ms: 300_000, failed: true}

      plan =
        start_supervised!({Agent, fn -> [failing, failing, failing, %{next_ms: 300_000}] end})

      run = fn _trigger, _opts ->
        Agent.get_and_update(plan, fn [next | rest] -> {next, rest} end)
      end

      placer = start_placer!(ctx, run: run)

      for delay <- [300_000, 600_000, 1_200_000] do
        assert_receive {:armed, {:wake, _token} = wake, ^delay}
        send(placer, wake)
      end

      assert_receive {:armed, {:wake, _token}, 300_000}
    end

    test "a placer that dies takes its run with it, so no later run overlaps it", ctx do
      test = self()

      run = fn trigger, _opts ->
        send(test, {:running, trigger, self()})

        receive do
          :finish -> %{next_ms: nil}
        end
      end

      placer = start_placer!(ctx, run: run)
      assert_receive {:running, :boot, first}
      ref = Process.monitor(first)
      Process.exit(placer, :kill)
      assert_receive {:DOWN, ^ref, :process, ^first, :killed}
    end

    @tag :capture_log
    test "under rest_for_one, a run that fails takes down nothing after it", ctx do
      test = self()

      run = fn trigger, _opts ->
        send(test, {:failing, trigger})
        raise "the store is gone"
      end

      children = [
        {Placer,
         name: nil,
         enabled: true,
         run: run,
         task_supervisor: ctx.tasks,
         timer: fn message, delay -> send(test, {:armed, message, delay}) && make_ref() end,
         now_ms: fn -> 0 end},
        Supervisor.child_spec({Agent, fn -> :after end}, id: :after)
      ]

      parent =
        start_supervised!(%{
          id: :parent,
          start: {Supervisor, :start_link, [children, [strategy: :rest_for_one]]},
          type: :supervisor
        })

      before = children(parent)
      placer = Map.fetch!(before, Placer)

      assert_receive {:failing, :boot}
      # It ended without finishing: the next try is armed, and the process stands.
      assert_receive {:armed, {:wake, _token}, 300_000}

      send(placer, :unexpected)
      :sys.get_state(placer)

      assert children(parent) == before
    end

    defp children(parent),
      do: Map.new(Supervisor.which_children(parent), fn {id, pid, _type, _mods} -> {id, pid} end)

    test "dark when not enabled: it runs nothing and arms nothing", ctx do
      test = self()
      placer = start_placer!(ctx, enabled: false, run: fn t, _o -> send(test, {:ran, t, nil}) end)
      :ok = Placer.places_offered(placer, "a")
      :ok = Placer.waits_saved(placer)
      :sys.get_state(placer)
      refute_received {:ran, _trigger, _result}
      refute_received {:armed, _message, _delay}
    end
  end
end
