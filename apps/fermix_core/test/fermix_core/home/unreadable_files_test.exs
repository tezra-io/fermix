defmodule FermixCore.Home.UnreadableFilesTest do
  # M75 lean v1 §7: the apps poll `home.status`, so a file it reads that
  # stays unreadable is logged once when that starts and once when it ends,
  # never on every poll, while every answer still says what is wrong. Each
  # test polls in a sequence and runs a memory of its own; no wait is for
  # time. async: false: it asserts that a line is not logged.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Fermix.CLI.HomeStatusCommand
  alias FermixCore.Home.Move
  alias FermixCore.Home.MoveReadiness
  alias FermixCore.Home.Provision.Ledger
  alias FermixCore.Home.Snapshot.Capture
  alias FermixCore.Home.UnreadableFiles
  alias FermixCore.Management.Home
  alias FermixCore.Management.HomeSummary
  alias FermixTestSupport.SafeRm

  @now ~U[2031-05-04 10:00:00Z]

  setup context do
    home = SafeRm.make_tmp_dir!("unreadable_files")
    on_exit(fn -> SafeRm.rm_rf!(home) end)

    server =
      start_supervised!({UnreadableFiles, name: :"unreadable_#{:erlang.phash2(context.test)}"})

    %{home: home, server: server}
  end

  test "a poll sequence changes only when a file stops and starts being readable" do
    polls = [
      :ok,
      {:error, :eacces},
      {:error, :eacces},
      {:error, :eisdir},
      :ok,
      :ok,
      {:error, :eio},
      :ok
    ]

    {changes, failing} =
      Enum.map_reduce(polls, %{}, fn result, failing ->
        UnreadableFiles.transition(failing, "/invented/a.json", result)
      end)

    assert changes == [
             :fine,
             :started,
             :failing,
             :failing,
             {:ended, 3},
             :fine,
             :started,
             {:ended, 1}
           ]

    assert failing == %{}

    # Two files fail and recover apart.
    {_change, failing} = UnreadableFiles.transition(%{}, "/invented/a.json", {:error, :eacces})

    assert {:started, failing} =
             UnreadableFiles.transition(failing, "/invented/b.json", {:error, :eio})

    assert {{:ended, 1}, failing} = UnreadableFiles.transition(failing, "/invented/a.json", :ok)

    assert {:failing, _failing} =
             UnreadableFiles.transition(failing, "/invented/b.json", {:error, :eio})
  end

  test "the ledger the summary polls is logged once while unreadable, and once when it reads",
       ctx do
    file = unreadable_ledger!(ctx.home)

    log =
      capture_log(fn ->
        for _poll <- 1..3 do
          assert %{state: :unreadable, sentence: sentence} =
                   Ledger.state(ctx.home, "hetzner", unreadable_files: ctx.server)

          assert sentence =~ "could not read its Hetzner file"
        end
      end)

    assert [line] = lines(log, file)
    assert line =~ "could not be read"

    :ok = SafeRm.rm!(file)

    log =
      capture_log(fn ->
        for _poll <- 1..2 do
          assert %{state: :none} = Ledger.state(ctx.home, "hetzner", unreadable_files: ctx.server)
        end
      end)

    assert [line] = lines(log, file)
    assert line =~ "reads again after 3 failed reads"
  end

  test "the settings the summary reads for what stops after a move do the same", ctx do
    file = unreadable_settings!(ctx.home)

    log =
      capture_log(fn ->
        for _poll <- 1..3 do
          assert {:error, sentence} =
                   MoveReadiness.stays_here(ctx.home, true, unreadable_files: ctx.server)

          assert sentence =~ "settings file could not be read"
        end
      end)

    assert [line] = lines(log, file)
    assert line =~ "could not be read"

    :ok = SafeRm.rm_rf!(file)
    File.write!(file, "[fermix_core.meetings]\nenabled = true\n")

    log =
      capture_log(fn ->
        assert {:ok, [:meetings]} =
                 MoveReadiness.stays_here(ctx.home, true, unreadable_files: ctx.server)
      end)

    assert [line] = lines(log, file)
    assert line =~ "reads again after 3 failed reads"
  end

  test "the summary's gather passes its memory to both reads", ctx do
    ledger = unreadable_ledger!(ctx.home)
    settings = unreadable_settings!(ctx.home)

    log =
      capture_log(fn ->
        for _poll <- 1..3 do
          facts = gather(ctx.home, unreadable_files: ctx.server)
          assert %{provision: %{state: :unreadable}, stays_here: []} = facts
        end
      end)

    assert [_line] = lines(log, ledger)
    assert [_line] = lines(log, settings)
  end

  test "the primary's disk home.status reads is logged once while unreadable", ctx do
    poll = fn usage ->
      Home.status(
        home: ctx.home,
        engine_role: %{role: :primary, primary: nil},
        config: [],
        scheduler: nil,
        profile: "general",
        now: @now,
        disk_usage: usage,
        unreadable_files: ctx.server
      )
    end

    log =
      capture_log(fn ->
        for _poll <- 1..3 do
          assert {:ok, %{"disk" => nil}} = poll.(fn _home -> {:error, :df_unavailable} end)
        end
      end)

    assert [line] = lines(log, "the disk of #{ctx.home}")
    assert line =~ "df_unavailable"

    log =
      capture_log(fn ->
        for _poll <- 1..2 do
          assert {:ok, %{"disk" => %{"used" => 0.42}}} =
                   poll.(fn _home -> {:ok, %{used: 0.42, nearly_full: false}} end)
        end
      end)

    assert [line] = lines(log, "the disk of #{ctx.home}")
    assert line =~ "reads again after 3 failed reads"
  end

  test "the last review of the move the summary reads is logged once while unreadable", ctx do
    File.mkdir_p!(Move.dir(ctx.home))
    review = Path.join(Move.dir(ctx.home), "readiness.json")
    File.write!(review, "not json")

    log =
      capture_log(fn ->
        for _poll <- 1..3,
            do: assert(%{review: nil} = gather(ctx.home, unreadable_files: ctx.server))
      end)

    assert [_line] = lines(log, Move.dir(ctx.home))

    :ok = SafeRm.rm!(review)

    log = capture_log(fn -> gather(ctx.home, unreadable_files: ctx.server) end)
    assert [line] = lines(log, Move.dir(ctx.home))
    assert line =~ "reads again after 3 failed reads"
  end

  # A copy that loops back on itself can be listed and never measured.
  test "a desktop's stored copy it cannot measure is logged once while it stays so", ctx do
    copy = Path.join(Capture.dir(ctx.home), "invented.fxsnap")
    File.mkdir_p!(Path.dirname(copy))
    :ok = File.ln_s(copy, copy)

    log =
      capture_log(fn ->
        for _poll <- 1..3 do
          assert %{copies_bytes: 0} =
                   gather(ctx.home, [unreadable_files: ctx.server], %{role: :device, primary: "x"})
        end
      end)

    assert [line] = lines(log, copy)
    assert line =~ "eloop"
  end

  # A verb with no engine running reads once and exits: nothing is
  # remembered, so no process is asked, and each read is its first.
  test "a tree-less read remembers nothing", ctx do
    file = unreadable_ledger!(ctx.home)

    log =
      capture_log(fn ->
        for _run <- 1..2 do
          assert %{state: :unreadable} = Ledger.state(ctx.home, "hetzner", unreadable_files: nil)

          assert {:ok, %{"summary" => %{"state" => "problem"}}} =
                   HomeStatusCommand.offline(ctx.home)
        end
      end)

    assert length(lines(log, file)) == 4
  end

  defp unreadable_ledger!(home) do
    file = Ledger.path(home, "hetzner")
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, ~s({"v": 1, "token": 5}))
    file
  end

  # A folder where the settings file belongs: unreadable for any user, root
  # included.
  defp unreadable_settings!(home) do
    file = Path.join(home, "config.toml")
    File.mkdir_p!(file)
    file
  end

  defp gather(home, opts, record \\ %{role: :primary, primary: nil}) do
    status = %{
      moved: nil,
      move: nil,
      candidates: [],
      snapshots: %{},
      disk: nil,
      primary_home: nil
    }

    HomeSummary.gather(
      home,
      record,
      %{primary: nil, desktops: [], enrollment: nil},
      status,
      [now: @now, host_os: :macos] ++ opts
    )
  end

  defp lines(log, file) do
    log |> String.split("\n") |> Enum.filter(&String.contains?(&1, file))
  end
end
