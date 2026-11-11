defmodule FermixCore.Computers.JournalTest do
  # M97 §6.3: a computer's own account of what its server asked of it.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Computers.Journal
  alias FermixCore.Home.DeviceLocal
  alias FermixTestSupport.SafeRm

  @now ~U[2031-06-08 12:00:00.000Z]

  setup do
    home = SafeRm.make_tmp_dir!("computer_journal")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{dir: Journal.dir(home), home: home}
  end

  defp started(dir, id, at, extra \\ %{}) do
    fields =
      Map.merge(
        %{
          id: id,
          at: at,
          capability: "system",
          op: "echo",
          target: "echo",
          origin: :chat,
          epoch: 3,
          turn_session: "main-2"
        },
        extra
      )

    :ok = Journal.append_started(dir, fields)
  end

  defp finished(dir, id, at, extra \\ %{}) do
    fields = Map.merge(%{id: id, at: at, status: :ok, result_bytes: 64, duration_ms: 12}, extra)
    :ok = Journal.append_finished(dir, fields)
  end

  test "lives in device/, which never travels and no agent tool reaches", %{dir: dir, home: home} do
    assert dir == Path.join([home, "device", "invocations"])
    assert DeviceLocal.excluded?("device/invocations/2031-06-08.jsonl")
  end

  test "records are one line each, the file 0600 under a 0700 directory", %{dir: dir} do
    started(dir, "inv-a", @now)
    finished(dir, "inv-a", DateTime.add(@now, 12, :millisecond))

    path = Path.join(dir, "2031-06-08.jsonl")
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    assert File.stat!(dir).mode |> Bitwise.band(0o777) == 0o700

    [first, second] = path |> File.read!() |> String.split("\n", trim: true)

    assert Jason.decode!(first) == %{
             "v" => 1,
             "e" => "started",
             "id" => "inv-a",
             "at" => "2031-06-08T12:00:00.000Z",
             "capability" => "system",
             "op" => "echo",
             "target" => "echo",
             "origin" => "chat",
             "epoch" => 3,
             "turn_session" => "main-2"
           }

    assert %{"e" => "finished", "status" => "ok", "result_bytes" => 64} = Jason.decode!(second)
  end

  test "an invocation reads as one entry, a running one with no end yet", %{dir: dir} do
    started(dir, "inv-a", @now)
    finished(dir, "inv-a", DateTime.add(@now, 1, :second))
    started(dir, "inv-b", DateTime.add(@now, 2, :second))

    assert {:ok, a} = Journal.lookup(dir, "inv-a")
    assert %{status: "ok", finished_at: "2031-06-08T12:00:01.000Z", target: "echo"} = a
    assert {:ok, %{status: nil, finished_at: nil}} = Journal.lookup(dir, "inv-b")
    assert Journal.lookup(dir, "inv-none") == :none
  end

  test "a request refused before it ran names itself in its one record", %{dir: dir} do
    finished(dir, "inv-r", @now, %{
      status: :refused,
      refusal: :off,
      capability: "system",
      op: "echo",
      target: "echo",
      origin: :scheduled
    })

    assert {:ok, entry} = Journal.lookup(dir, "inv-r")

    assert entry == %{
             id: "inv-r",
             at: "2031-06-08T12:00:00.000Z",
             finished_at: "2031-06-08T12:00:00.000Z",
             capability: "system",
             op: "echo",
             target: "echo",
             origin: "scheduled",
             status: "refused",
             refusal: "off",
             result_bytes: 64,
             duration_ms: 12
           }
  end

  test "the owner reads the newest first, a page at a time", %{dir: dir} do
    for n <- 1..5, do: started(dir, "inv-#{n}", DateTime.add(@now, n, :second))

    assert {:ok, %{entries: page, more: true}} = Journal.list(dir, limit: 2)
    assert Enum.map(page, & &1.id) == ["inv-5", "inv-4"]

    assert {:ok, %{entries: rest, more: false}} = Journal.list(dir, limit: 10, before: "inv-4")
    assert Enum.map(rest, & &1.id) == ["inv-3", "inv-2", "inv-1"]

    assert {:ok, %{entries: [], more: false}} = Journal.list(Path.join(dir, "none"))
  end

  test "a torn last line is skipped and said once, and the next record starts its own line",
       %{dir: dir} do
    started(dir, "inv-a", @now)
    path = Path.join(dir, "2031-06-08.jsonl")
    File.write!(path, ~s({"v":1,"e":"finished","id":"inv-a","at":"2031-06), [:append])

    finished(dir, "inv-a", DateTime.add(@now, 1, :second))

    log =
      capture_log(fn ->
        assert {:ok, %{status: "ok"}} = Journal.lookup(dir, "inv-a")
      end)

    assert log =~ "1 line(s) skipped"
    assert path |> File.read!() |> String.split("\n", trim: true) |> length() == 3
  end

  test "what a crash left started is closed as interrupted, once", %{dir: dir} do
    started(dir, "inv-a", @now)
    started(dir, "inv-b", @now)
    finished(dir, "inv-b", @now)

    later = DateTime.add(@now, 5, :second)
    assert {:ok, [closed]} = Journal.interrupted(dir, later)
    assert {:ok, []} = Journal.interrupted(dir, later)

    assert {:ok, %{status: "unknown", duration_ms: 5_000} = looked} = Journal.lookup(dir, "inv-a")
    assert closed == looked

    note =
      dir
      |> Path.join("2031-06-08.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(&1["id"] == "inv-a" and &1["e"] == "finished"))

    assert note["note"] == "interrupted"
  end

  test "day files older than seven days go", %{dir: dir} do
    for days <- [8, 7, 6, 0], do: started(dir, "inv-#{days}", DateTime.add(@now, -days, :day))

    assert :ok = Journal.prune(dir, @now)

    assert dir |> File.ls!() |> Enum.sort() ==
             ["2031-06-02.jsonl", "2031-06-08.jsonl"]
  end

  test "past the bound the oldest invocations go, the file rewritten whole", %{dir: dir} do
    File.mkdir_p!(dir)
    count = Journal.max_invocations() + 5

    lines =
      for n <- 1..count do
        Jason.encode!(%{
          "v" => 1,
          "e" => "started",
          "id" => "inv-#{n}",
          "at" => "2031-06-08T00:00:00Z"
        })
      end

    File.write!(Path.join(dir, "2031-06-08.jsonl"), Enum.join(lines, "\n") <> "\n")
    File.chmod!(Path.join(dir, "2031-06-08.jsonl"), 0o600)

    assert :ok = Journal.prune(dir, @now)

    assert {:ok, %{entries: entries, more: true}} = Journal.list(dir, limit: 200)
    assert hd(entries).id == "inv-#{count}"
    assert Journal.lookup(dir, "inv-5") == :none
    assert {:ok, _kept} = Journal.lookup(dir, "inv-6")
    assert File.stat!(Path.join(dir, "2031-06-08.jsonl")).mode |> Bitwise.band(0o777) == 0o600
    refute File.exists?(Path.join(dir, "2031-06-08.jsonl.tmp"))
  end
end
