defmodule FermixCore.Trips.DayTurnTest do
  # M89 D14: the trips index moves with the date alone when a trip starts or
  # ends at a local midnight, and the day-turn process sends it again, by the
  # path any change takes, when the order or a trip's `past` moved. Its one
  # timer is armed a second past the next such midnight, never more than
  # 10 min ahead: the timer's clock stops while a Mac sleeps, so each wake
  # compares the index the wall clock gives with the one last sent. A boot
  # cannot know what was sent before it, so its read sends once, and a change
  # read after a turn has passed compares too: no turn is swallowed. The
  # clock, the home's zone and the timer are the test's: every expiry is read
  # from the process's state and delivered by hand, so nothing waits on a real
  # clock. Against a real store in a temp file. Every title here is invented.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Memory.Repo
  alias FermixCore.Trips.DayTurn
  alias FermixCore.Trips.Registry

  @owner %{
    agent_name: "main",
    conversation_key: {"telegram", "40023", :root},
    source_trust: :operator,
    computer_use_origin: :interactive,
    chat_type: "private",
    outside_sources: MapSet.new()
  }
  @home [timezone: "Etc/UTC"]
  @cap_ms 10 * 60_000
  # Five minutes before Varonne's last day ends.
  @before_turn ~U[2031-07-05 23:55:00Z]

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-trip-day-turn-#{unique}.db")
    repo = :"trip_day_turn_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)
    clock = start_supervised!({Agent, fn -> @before_turn end})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, clock: clock}
  end

  defp at!(ctx, now), do: Agent.update(ctx.clock, fn _now -> now end)

  defp start!(ctx, extra) do
    test = self()

    opts = [
      name: nil,
      repo: ctx.repo,
      clock: fn -> Agent.get(ctx.clock, & &1) end,
      personalization: @home,
      notifier: fn changes ->
        send(test, {:announced, changes})
        :ok
      end,
      timer: fn _message, _delay -> make_ref() end
    ]

    start_supervised!({DayTurn, Keyword.merge(opts, extra)})
  end

  # Started, its boot read done (the state answers only after it), and the
  # boot's one send taken.
  defp booted!(ctx) do
    pid = start!(ctx, [])
    wake!(pid)
    assert_received {:announced, %{owner_id: "default", trips: []}}
    pid
  end

  defp edit!(ctx, trip, ops, day_turn \\ fn -> :ok end) do
    opts = [
      repo: ctx.repo,
      now: Agent.get(ctx.clock, & &1),
      notifier: fn _changes -> :ok end,
      day_turn: day_turn
    ]

    assert {:ok, _answer} = Registry.edit(%{"trip" => trip, "ops" => ops}, @owner, opts)
  end

  defp varonne!(ctx, day_turn \\ fn -> :ok end) do
    edit!(
      ctx,
      "Varonne",
      [%{"op" => "create", "days" => 2, "starts_on" => "2031-07-04"}],
      day_turn
    )
  end

  # The armed wake, read from the state, which also proves every message sent
  # before it was handled.
  defp wake!(pid) do
    assert %{wake: %{token: _token, delay_ms: _delay} = wake} = :sys.get_state(pid)
    wake
  end

  defp fire!(pid) do
    %{token: token} = wake!(pid)
    send(pid, {:wake, token})
    wake!(pid)
  end

  test "it arms a second past the next midnight a trip starts or ends at, within the cap", ctx do
    # Varonne's last day is today, the 5th: over at midnight, five minutes on.
    varonne!(ctx)
    assert wake!(booted!(ctx)).delay_ms == 5 * 60_000 + 1_000
  end

  test "it never arms more than 10 min ahead, however far off the next turn", ctx do
    at!(ctx, ~U[2031-07-05 23:00:00Z])
    edit!(ctx, "Kell", [%{"op" => "create"}])
    edit!(ctx, "Brask", [%{"op" => "create", "days" => 2, "starts_on" => "2031-09-01"}])
    edit!(ctx, "Salvé", [%{"op" => "create", "days" => 2, "starts_on" => "2031-04-11"}])

    # The next turn is Brask's start, in September.
    pid = booted!(ctx)
    assert wake!(pid).delay_ms == @cap_ms

    # Varonne's last day ends in an hour: still past the cap.
    varonne!(ctx, fn -> DayTurn.trips_changed(pid) end)
    assert wake!(pid).delay_ms == @cap_ms

    # Five minutes before it, the delay is the turn's own.
    at!(ctx, @before_turn)
    assert fire!(pid).delay_ms == 5 * 60_000 + 1_000
    refute_received {:announced, _changes}
  end

  test "at the turn it sends the index again, once, and nothing when nothing moved", ctx do
    varonne!(ctx)
    edit!(ctx, "Brask", [%{"op" => "create", "days" => 1, "starts_on" => "2031-07-06"}])
    pid = booted!(ctx)

    # Midnight: Varonne is over and Brask begins, so the order and a flag move.
    at!(ctx, ~U[2031-07-06 00:00:01Z])
    assert fire!(pid).delay_ms == @cap_ms
    assert_received {:announced, %{owner_id: "default", trips: []}}

    # Ten minutes on nothing has moved: the wake comes and nothing is sent.
    at!(ctx, ~U[2031-07-06 00:10:01Z])
    fire!(pid)
    refute_received {:announced, _changes}
  end

  # A Mac that slept through midnight: its timer fires late, and the compare
  # runs on the wall clock it wakes to.
  test "a wake long after the turn still sends the index that moved", ctx do
    varonne!(ctx)
    pid = booted!(ctx)

    at!(ctx, ~U[2031-07-06 07:00:00Z])
    fire!(pid)
    assert_received {:announced, %{trips: []}}
  end

  test "a change before the turn re-reads and re-arms, and its own push is the only one", ctx do
    edit!(ctx, "Kell", [%{"op" => "create"}])
    pid = booted!(ctx)
    assert wake!(pid).delay_ms == @cap_ms

    varonne!(ctx, fn -> DayTurn.trips_changed(pid) end)

    assert wake!(pid).delay_ms == 5 * 60_000 + 1_000
    refute_received {:announced, _changes}

    # The turn after the change still sends the index, which moved at midnight.
    at!(ctx, ~U[2031-07-06 00:00:01Z])
    fire!(pid)
    assert_received {:announced, %{trips: []}}
  end

  # The change committed at 23:59:59.8, the devices' window read it before
  # midnight, and the change's cast is handled after: its read compares, so
  # the turn it straddled is sent.
  test "a change read after the turn has passed compares, and sends what moved", ctx do
    varonne!(ctx)
    pid = booted!(ctx)

    at!(ctx, ~U[2031-07-05 23:59:59.800000Z])
    edit!(ctx, "Kell", [%{"op" => "create"}])
    at!(ctx, ~U[2031-07-06 00:00:00.300000Z])
    DayTurn.trips_changed(pid)

    assert wake!(pid).delay_ms == @cap_ms
    assert_received {:announced, %{trips: []}}
  end

  test "a wake it replaced does nothing", ctx do
    pid = booted!(ctx)
    %{token: old} = wake!(pid)
    DayTurn.trips_changed(pid)
    assert %{token: new} = wake!(pid)
    refute new == old

    send(pid, {:wake, old})
    assert wake!(pid).token == new
    refute_received {:announced, _changes}
  end

  test "a store it cannot read is logged once, and read again at the next wake", ctx do
    missing = :"trip_day_turn_missing_#{System.unique_integer([:positive])}"

    log =
      capture_log(fn ->
        pid = start!(ctx, repo: missing)
        assert wake!(pid).delay_ms == @cap_ms
        fire!(pid)
        send(pid, :unexpected)
        wake!(pid)
      end)

    assert [_once] = Regex.scan(~r/the trips index could not be read/, log)
    assert log =~ "the day-turn of the owner's trips was sent :unexpected"
    refute_received {:announced, _changes}
  end

  # What a restart cannot know it sends: the first read that succeeds, after a
  # boot whose read failed, sends the index once.
  test "a store that reads again says so once, and sends what it reads once", ctx do
    unique = System.unique_integer([:positive])
    late = :"trip_day_turn_late_#{unique}"
    db_path = Path.join(System.tmp_dir!(), "fermix-trip-day-turn-late-#{unique}.db")

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    # The boot's read is done, and failed, before the store comes up.
    {pid, _log} =
      with_log(fn ->
        pid = start!(ctx, repo: late)
        assert wake!(pid).delay_ms == @cap_ms
        pid
      end)

    start_supervised!({Repo, name: late, enabled: true, database_path: db_path}, id: late)
    varonne!(%{ctx | repo: late})

    log = capture_log(fn -> assert fire!(pid).delay_ms == 5 * 60_000 + 1_000 end)

    assert [_once] = Regex.scan(~r/the trips index is read again/, log)
    assert_received {:announced, %{trips: []}}

    # From then on it compares: at midnight the trip is over, and that is sent.
    at!(ctx, ~U[2031-07-06 00:00:01Z])
    fire!(pid)
    assert_received {:announced, %{trips: []}}
    refute_received {:announced, _changes}
  end
end
