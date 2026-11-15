defmodule FermixCore.Home.ReleaseTableTest do
  # M97 §3.4: an Always On server keeps the release table it chooses its
  # update from, fetched in a task of its own, the last good table kept, and a
  # table never read failing closed. Every fetch here is a seam; nothing
  # reaches fermix.ai.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Releases
  alias FermixCore.Home.ReleaseTable

  @at ~U[2031-05-04 12:00:00Z]

  setup do
    tasks = start_supervised!({Task.Supervisor, name: nil}, id: :release_table_tasks)
    %{tasks: tasks}
  end

  test "a server reads the table and answers it with when", ctx do
    table = start!(ctx, fetch: fn -> Releases.parse(table_text()) end)

    assert {:ok, %Releases{latest: "4.2.0"}, @at, nil} = ReleaseTable.refresh(table)
    assert {:ok, %Releases{latest: "4.2.0"}, @at, nil} = ReleaseTable.current(table)
  end

  test "a fetch that fails before any table leaves none, and says why", ctx do
    table = start!(ctx, fetch: fn -> {:error, "An invented failure."} end)

    assert ReleaseTable.current(table) ==
             {:error, "Fermix has not read the release table yet."}

    assert ReleaseTable.refresh(table) == {:error, "An invented failure."}
    assert ReleaseTable.current(table) == {:error, "An invented failure."}
  end

  test "a later failure keeps the last good table beside its sentence", ctx do
    answers = :counters.new(1, [])

    fetch = fn ->
      :counters.add(answers, 1, 1)

      case :counters.get(answers, 1) do
        1 -> Releases.parse(table_text())
        _later -> {:error, "An invented failure."}
      end
    end

    table = start!(ctx, fetch: fetch)
    assert {:ok, _table, @at, nil} = ReleaseTable.refresh(table)

    assert {:ok, %Releases{latest: "4.2.0"}, @at, "An invented failure."} =
             ReleaseTable.refresh(table)
  end

  test "a fetch that crashes is a failure, and the table answers on", ctx do
    table = start!(ctx, fetch: fn -> raise "an invented crash" end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, sentence} = ReleaseTable.refresh(table)
        assert sentence =~ "Fermix could not read the release table from fermix.ai"
      end)

    assert log =~ "the fetch ended"
    assert Process.alive?(table)
  end

  test "an engine that is no server fetches nothing and says so", ctx do
    test = self()
    fetch = fn -> send(test, :fetched) end
    table = start!(ctx, fetch: fetch, fetching: false)

    assert {:error, sentence} = ReleaseTable.refresh(table)
    assert sentence == "This computer is not an Always On server, so it reads no release table."
    assert ReleaseTable.current(table) == {:error, sentence}
    refute_received :fetched
  end

  test "a table that is not running answers that Fermix is not running" do
    assert ReleaseTable.current(:"release_table_#{System.unique_integer([:positive])}") ==
             {:error, "Fermix is not running, so it has not read the release table."}
  end

  # A GenServer that blocks answers no call: a fetch that hangs holds no
  # read behind it.
  test "a read is answered while a fetch hangs", ctx do
    test = self()

    fetch = fn ->
      send(test, {:fetching, self()})

      receive do
        :release -> Releases.parse(table_text())
      end
    end

    table = start!(ctx, fetch: fetch)
    waiter = Task.async(fn -> ReleaseTable.refresh(table) end)
    assert_receive {:fetching, fetcher}, 10_000

    for _read <- 1..100 do
      assert ReleaseTable.current(table) == {:error, "Fermix has not read the release table yet."}
    end

    send(fetcher, :release)
    assert {:ok, _table, @at, nil} = Task.await(waiter, 10_000)
  end

  test "the address is the installer's own" do
    assert ReleaseTable.url() == "https://fermix.ai/install/releases"
  end

  # `fetch/1` itself, the network stood in for by a plug: the table read, and
  # each way it cannot be, all one sentence that names no cause but the log.
  describe "one fetch" do
    @unreadable "Fermix could not read the release table from fermix.ai, so it installs no " <>
                  "new release until it can; the log says why."

    test "a table served whole is read" do
      assert {:ok, %Releases{} = table} = fetch_with(&Plug.Conn.send_resp(&1, 200, table_text()))
      assert {:ok, ^table} = Releases.parse(table_text())
    end

    test "an answer other than 200, a redirect included, is no table" do
      assert @unreadable in ReleaseTable.sentences()

      redirect = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://elsewhere.invalid/releases")
        |> Plug.Conn.send_resp(302, "")
      end

      for answer <- [&Plug.Conn.send_resp(&1, 503, table_text()), redirect] do
        assert fetch_with(answer) == {:error, @unreadable}
      end
    end

    test "a body past the cap is refused, not read" do
      row = "4.1.0 #{String.duplicate("a", 64)} fermix_always_on.sh\n"
      big = "format 1\nlatest 4.1.0\n" <> String.duplicate(row, 13_000)
      assert byte_size(big) > 1_048_576

      assert fetch_with(&Plug.Conn.send_resp(&1, 200, big)) == {:error, @unreadable}
    end

    test "a table the reader refuses is no table" do
      assert fetch_with(&Plug.Conn.send_resp(&1, 200, "format 2\nlatest 4.2.0\n")) ==
               {:error, @unreadable}
    end

    defp fetch_with(answer) do
      ExUnit.CaptureLog.with_log(fn -> ReleaseTable.fetch(req_options: [plug: answer]) end)
      |> elem(0)
    end
  end

  defp start!(ctx, opts) do
    defaults = [
      name: nil,
      fetching: true,
      timer_enabled: false,
      now: fn -> @at end,
      task_supervisor: ctx.tasks
    ]

    start_supervised!(
      {ReleaseTable, Keyword.merge(defaults, opts)},
      id: make_ref()
    )
  end

  defp table_text do
    digests =
      for version <- ["4.1.0", "4.2.0"],
          do: "#{version} #{String.duplicate("a", 64)} fermix_always_on.sh"

    Enum.join(["format 1", "latest 4.2.0"] ++ digests, "\n") <> "\n"
  end
end
