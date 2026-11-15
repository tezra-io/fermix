defmodule FermixCore.ComputerHistory.HomeIdentityTest do
  # M97 §8.5: a machine's mark is the highest purge or pause interval of ONE
  # home's store it applied. Interval ids restart when that store does (a
  # restore, a rebuilt server, another home), so the mark carries the store's
  # identity, and a machine that hears another identity starts again from the
  # first interval. No reply says a purge was applied where it was not, and a
  # purged window never gains a note.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.ComputerHistory
  alias FermixCore.ComputerHistory.Delivery
  alias FermixCore.ComputerHistory.MachineService
  alias FermixCore.ComputerHistory.Purge
  alias FermixCore.ComputerHistory.Sittings
  alias FermixCore.ComputerHistory.Spool
  alias FermixCore.ComputerHistory.Submission
  alias FermixCore.Computers.Computer
  alias FermixCore.Computers.Outcome
  alias FermixCore.Home.Archive
  alias FermixCore.Home.Epoch
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.ComputerHistorySql
  alias FermixTestSupport.SafeRm

  @now ~U[2031-05-04 09:00:00.000Z]
  @hour 3_600_000
  @studio "studio-7f3a"
  @passphrase "invented-harbour-lantern"
  @archive_host "macos-aarch64"

  defmodule Adapter do
    @moduledoc false
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(_messages, _capabilities, _opts),
      do:
        {:ok,
         %{content: "The owner wrote the lease.", tool_calls: [], provider_state: nil, usage: %{}}}

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
    dir = SafeRm.make_tmp_dir!("ch-home-identity")
    on_exit(fn -> SafeRm.rm_rf(dir) end)

    machine = Path.join(dir, "studio")
    File.mkdir_p!(machine)
    spool = start_supervised!({Spool, name: nil, path: Spool.path(machine)}, id: :machine_spool)

    {:ok, _count} =
      Spool.insert_events(
        [
          typed(1, t(1_000), "the lease"),
          typed(2, t(2_000), "the rent"),
          typed(3, t(3_000), "x")
        ],
        server: spool
      )

    %{dir: dir, machine: machine, spool: spool}
  end

  defp t(offset), do: DateTime.to_unix(@now, :millisecond) + offset

  defp typed(seq, ts, text),
    do: %{
      boot_id: "b1",
      source_seq: seq,
      ts: ts,
      type: "field.value",
      bundle_id: "com.example.notes",
      window_title: "Lease — Notes",
      field_label: "Body",
      text: text
    }

  # A home: its folder (where its epoch lives) and its store.
  defp home!(ctx, name) do
    root = Path.join(ctx.dir, name)
    File.mkdir_p!(root)
    {:ok, :created, 1} = Epoch.initialise(root)
    repo = :"ch_identity_#{name}_#{System.unique_integer([:positive])}"
    db = Path.join(root, "memory.db")
    start_repo!(repo, db)
    %{root: root, repo: repo, db: db}
  end

  defp start_repo!(repo, db),
    do: start_supervised!({Repo, name: repo, enabled: true, database_path: db}, id: repo)

  # A home to back up: its epoch, and a store its own Repo made (with its
  # token), checkpointed and copied in alone, so nothing beside it changes
  # while the archive reads it.
  defp backup_home!(ctx) do
    seed = Path.join([ctx.dir, "seed", "memory.db"])
    File.mkdir_p!(Path.dirname(seed))
    repo = :"ch_identity_seed_#{System.unique_integer([:positive])}"
    start_repo!(repo, seed)
    stop_supervised!(repo)
    raw(seed, "PRAGMA wal_checkpoint(TRUNCATE);")

    root = Path.join(ctx.dir, "backed-up")
    File.mkdir_p!(root)
    {:ok, :created, 1} = Epoch.initialise(root)
    File.cp!(seed, Path.join(root, "memory.db"))
    root
  end

  # A home restored from `archive` into a folder of its own, with its store
  # running.
  defp restored!(ctx, archive, name) do
    root = Path.join(ctx.dir, name)

    {:ok, _restored} =
      Archive.restore(archive, @passphrase, root,
        host: @archive_host,
        keyring_usable?: fn -> true end
      )

    repo = :"ch_identity_#{name}_#{System.unique_integer([:positive])}"
    db = Path.join(root, "memory.db")
    start_repo!(repo, db)
    %{root: root, repo: repo, db: db}
  end

  # The home's store as a snapshot taken after its first interval was applied
  # there, restored in place: its ids restart above that one, and it gets a
  # new identity, as `Archive.install/5` gives a restored store.
  defp restore_after_first!(home) do
    stop_supervised!(home.repo)

    raw(home.db, """
    DELETE FROM computer_history_purges WHERE id > 1;
    UPDATE sqlite_sequence SET seq = 1 WHERE name = 'computer_history_purges';
    UPDATE computer_history_computers SET delivered_mark = 1;
    """)

    renew!(home.db)
    start_repo!(home.repo, home.db)
  end

  defp renew!(db) do
    {:ok, conn} = Sqlite3.open(db)

    try do
      :ok = ComputerHistorySql.renew_home_token(conn)
    after
      Sqlite3.close(conn)
    end
  end

  defp raw(db, sql) do
    {:ok, conn} = Sqlite3.open(db)

    try do
      :ok = Sqlite3.execute(conn, sql)
    after
      Sqlite3.close(conn)
    end
  end

  defp purge!(home, from_ts, to_ts) do
    {:ok, %{interval: id}} =
      Repo.computer_history_home(:purge_notes, [from_ts, to_ts, t(0), :all], server: home.repo)

    id
  end

  # Three purges of windows before anything this computer recorded.
  defp three_earlier!(home),
    do: for(k <- [10, 8, 6], do: purge!(home, t(-k * @hour), t(-(k - 1) * @hour)))

  defp studio, do: %Computer{device_id: @studio, name: "studio Mac", connected: true}

  # The computer, reached in process: what its home sends is checked as the
  # link checks it, then applied to the store under its home.
  defp computer(ctx) do
    fn _computer, MachineService, op, args, _context, _opts ->
      :ok = MachineService.validate(op, args)

      case MachineService.run(op, args, nil, %{home: ctx.machine, clock: fn -> @now end}) do
        {:ok, result, nil} -> {:ok, %Outcome{status: :ok, result: result}}
        {:failed, message} -> {:error, %Outcome{status: :failed, message: message}}
      end
    end
  end

  defp deliver(ctx, home),
    do:
      Delivery.deliver(
        repo: home.repo,
        home: home.root,
        computers: [studio()],
        call: computer(ctx)
      )

  defp seqs(spool) do
    {:ok, events} = Spool.events_after(0, 10, server: spool)
    Enum.map(events, & &1.source_seq)
  end

  # A move raises the epoch and carries the store on with its ids, so it keeps
  # the identity; a restored store gets a new one (`Archive.install/5`).
  test "a home's identity holds across a restart and a move, and differs for another home",
       ctx do
    first = home!(ctx, "first")
    {:ok, identity} = ComputerHistory.home_identity(repo: first.repo)

    stop_supervised!(first.repo)
    start_repo!(first.repo, first.db)
    {:ok, 2} = Epoch.bump(first.root)
    assert {:ok, ^identity} = ComputerHistory.home_identity(repo: first.repo)

    second = home!(ctx, "second")
    {:ok, other} = ComputerHistory.home_identity(repo: second.repo)
    refute other == identity

    stop_supervised!(first.repo)
    renew!(first.db)
    start_repo!(first.repo, first.db)
    {:ok, restored} = ComputerHistory.home_identity(repo: first.repo)
    refute restored == identity
  end

  test "a computer that joined another home is told that home's purges from the first", ctx do
    first = home!(ctx, "first")
    three_earlier!(first)
    assert %{applied: ["studio Mac"]} = deliver(ctx, first)

    second = home!(ctx, "second")
    purge!(second, t(500), t(1_500))
    assert %{applied: ["studio Mac"]} = deliver(ctx, second)
    assert seqs(ctx.spool) == [2, 3]

    # The second home's next purge has an id the first home's mark already
    # passed: it is sent, applied, and only then said to be.
    purge!(second, t(1_500), t(2_500))
    assert %{applied: ["studio Mac"]} = deliver(ctx, second)
    assert seqs(ctx.spool) == [3]
  end

  test "a home restored from a snapshot is applied again from where its store stands", ctx do
    home = home!(ctx, "restored")
    three_earlier!(home)
    assert %{applied: ["studio Mac"]} = deliver(ctx, home)

    restore_after_first!(home)
    assert purge!(home, t(500), t(1_500)) == 2
    assert %{applied: ["studio Mac"]} = deliver(ctx, home)
    assert seqs(ctx.spool) == [2, 3]

    assert purge!(home, t(1_500), t(2_500)) == 3
    assert %{applied: ["studio Mac"]} = deliver(ctx, home)
    assert seqs(ctx.spool) == [3]
  end

  test "a sitting whose mark is another home's is refused for every purge of this one", ctx do
    first = home!(ctx, "first")
    three_earlier!(first)
    assert %{applied: ["studio Mac"]} = deliver(ctx, first)

    second = home!(ctx, "second")
    purge!(second, t(500), t(1_500))
    purge!(second, t(1_500), t(3_500))

    uplink = fn payload ->
      {:ok,
       Submission.accept(@studio, payload,
         repo: second.repo,
         home: second.root,
         contributors: [@studio],
         config: [summarizer: :local],
         adapter: Adapter,
         route_opts: [model: "llama3"],
         now: DateTime.add(@now, 2, :hour)
       )}
    end

    assert {:ok, %{notes: 0}} =
             Sittings.run(
               uplink: uplink,
               spool: ctx.spool,
               home: ctx.machine,
               now: DateTime.add(@now, 2, :hour),
               timezone: "Etc/UTC",
               config: [enabled: true]
             )

    assert seqs(ctx.spool) == []

    assert {:ok, []} =
             Repo.computer_history_memories_in_window(0, t(10 * @hour), 10, server: second.repo)
  end

  # HS-4: a home restored twice from one backup. Each restore is a store whose
  # interval ids start again from the backup's, so each is another identity: a
  # sitting still counting the first restore's mark is checked against every
  # purge of the second, and a window the second purged gains no note.
  test "a home restored twice from one backup refuses a sitting counted under the first",
       ctx do
    backup = backup_home!(ctx)
    archive = Path.join(ctx.dir, "home.fxhome")

    {:ok, _created} =
      Archive.create(backup, @passphrase,
        to: archive,
        hello: fn -> {:error, :not_running} end,
        host: @archive_host
      )

    first = restored!(ctx, archive, "first-restore")
    assert purge!(first, t(500), t(1_500)) == 1
    assert %{applied: ["studio Mac"]} = deliver(ctx, first)
    assert seqs(ctx.spool) == [2, 3]
    stop_supervised!(first.repo)

    second = restored!(ctx, archive, "second-restore")
    assert purge!(second, t(1_500), t(3_500)) == 1

    uplink = fn payload ->
      {:ok,
       Submission.accept(@studio, payload,
         repo: second.repo,
         home: second.root,
         contributors: [@studio],
         config: [summarizer: :local],
         adapter: Adapter,
         route_opts: [model: "llama3"],
         now: DateTime.add(@now, 2, :hour)
       )}
    end

    assert {:ok, %{notes: 0}} =
             Sittings.run(
               uplink: uplink,
               spool: ctx.spool,
               home: ctx.machine,
               now: DateTime.add(@now, 2, :hour),
               timezone: "Etc/UTC",
               config: [enabled: true]
             )

    assert seqs(ctx.spool) == []

    assert {:ok, []} =
             Repo.computer_history_memories_in_window(0, t(10 * @hour), 10, server: second.repo)
  end

  test "a Mac that is its own home applies a purge made after a restore", ctx do
    home = home!(ctx, "own")
    spool = ctx.spool

    for k <- [10, 8, 6] do
      {:ok, %{here: :ok}} =
        Purge.purge({:last, 60_000},
          now: t(-k * @hour),
          repo: home.repo,
          spool: spool,
          home: home.root
        )
    end

    restore_after_first!(home)

    assert {:ok, %{interval: 2, here: :ok, events: 2}} =
             Purge.purge({:last, 2_500},
               now: t(2_500),
               repo: home.repo,
               spool: spool,
               home: home.root
             )

    assert seqs(spool) == [3]
  end

  test "forgetting its home starts a machine's mark again, and a machine with no store has none",
       ctx do
    home = home!(ctx, "first")
    three_earlier!(home)
    assert %{applied: ["studio Mac"]} = deliver(ctx, home)
    assert {:ok, %{home_mark: 3, home: identity}} = Spool.link(server: ctx.spool)
    assert is_binary(identity)

    assert :ok = Spool.forget_home(ctx.machine)
    assert {:ok, %{home_mark: 0, home: nil}} = Spool.link(server: ctx.spool)

    elsewhere = Path.join(ctx.dir, "elsewhere")
    assert :ok = Spool.forget_home(elsewhere)
    refute File.exists?(Spool.path(elsewhere))
  end
end
