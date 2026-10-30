defmodule Fermix.CLI.HomeCommandTest do
  # Sync: the verbs print their refusals and prompts on `:standard_error`, one
  # globally registered device that concurrent captures would share.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Exqlite.Sqlite3
  alias Fermix.CLI.HomeCommand
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Moved
  alias FermixCore.Memory.Repo.ComputerHistorySql
  alias FermixTestSupport.PipedTerminal
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TtyTerminal

  @passphrase "invented-harbour-lantern"
  @not_running {:error, :not_running}
  @moved "Start the engine here; the old home must be marked moved before it runs again."
  @now 1_793_083_733_000

  setup do
    tmp = SafeRm.make_tmp_dir!("home_command")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)

    home = Path.join(tmp, "home")
    File.mkdir_p!(home)

    File.write!(Path.join(home, "config.toml"), """
    [fermix_core.providers.openai]
    api_key = "@keyring"

    [sandbox]
    workspace_root = "#{home}/workspace"
    """)

    :ok = Epoch.write(home, 5)

    passphrase_file = Path.join(tmp, "passphrase")
    File.write!(passphrase_file, @passphrase <> "\n")

    %{
      tmp: tmp,
      home: home,
      archive: Path.join(tmp, "home.fxhome"),
      into: Path.join(tmp, "restored"),
      passphrase_file: passphrase_file
    }
  end

  test "export then import moves the home and prints what each did", ctx do
    {status, out, err} =
      run(["export", ctx.archive, "--passphrase-file", ctx.passphrase_file], home: ctx.home)

    assert {status, err} == {0, ""}
    assert out =~ "Exported #{ctx.home} to #{ctx.archive}"
    assert out =~ "bytes: #{File.stat!(ctx.archive).size}"
    assert out =~ "files: 2"
    assert out =~ "primary epoch: 5"

    assert out =~
             "This home keeps 1 secret in the OS keyring; the archive carries only their " <>
               "references, so enter them again on the new host."

    assert String.ends_with?(
             out,
             "The passphrase file #{ctx.passphrase_file} holds the owner root: remove it, or " <>
               "keep it protected, once the move is done.\n"
           )

    {status, out, err} =
      run(["import", ctx.archive, "--into", ctx.into, "--passphrase-file", ctx.passphrase_file])

    assert {status, err} == {0, ""}
    assert out =~ "Restored 2 files into #{ctx.into} at primary epoch 6."
    assert out =~ "Rewrote 1 path in config.toml: sandbox.workspace_root."
    assert out =~ "The archived home kept 1 secret in the OS keyring"
    assert out =~ "The passphrase file #{ctx.passphrase_file} holds the owner root"
    assert String.ends_with?(out, @moved <> "\n")
    refute out =~ "Coding-harness"
    refute out =~ "screen-history"
    refute out =~ "Reinstall"
    assert File.read!(Path.join(ctx.into, "config.toml")) =~ ~s("#{ctx.into}/workspace")
    assert Epoch.read(ctx.into) == {:ok, 6}
    refute File.exists?(Path.join(ctx.home, "moved.json"))
  end

  test "export asks twice on a terminal without echo", ctx do
    {status, _out, err} =
      run(
        ["export", ctx.archive],
        [home: ctx.home, terminal: TtyTerminal],
        @passphrase <> "\n" <> @passphrase <> "\n"
      )

    assert status == 0
    assert err =~ "Archive passphrase: "
    assert err =~ "Repeat the passphrase: "
    refute err =~ @passphrase
    assert_received {:secret_input_echo, false}
    assert_received {:secret_input_echo, true}
  end

  test "export refuses two different passphrases and writes nothing", ctx do
    {status, _out, err} =
      run(
        ["export", ctx.archive],
        [home: ctx.home, terminal: TtyTerminal],
        @passphrase <> "\nsomething-else-entirely\n"
      )

    assert status == 1
    assert err =~ "The two passphrases differ"
    refute File.exists?(ctx.archive)
  end

  test "with no terminal and no passphrase file, both verbs refuse by name", ctx do
    {status, _out, err} = run(["export", ctx.archive], home: ctx.home, terminal: PipedTerminal)
    assert status == 1
    assert err =~ "--passphrase-file"

    {status, _out, err} =
      run(["import", ctx.archive, "--into", ctx.into], terminal: PipedTerminal)

    assert status == 1
    assert err =~ "--passphrase-file"
  end

  test "refusals print their sentence and exit 1", ctx do
    {status, _out, err} =
      run(["export", ctx.archive, "--passphrase-file", ctx.passphrase_file],
        home: ctx.home,
        hello: fn -> {:ok, %{}} end
      )

    assert status == 1
    assert err =~ "The engine that owns this home is running"

    File.write!(ctx.passphrase_file, "short\n")

    {status, _out, err} =
      run(["export", ctx.archive, "--passphrase-file", ctx.passphrase_file], home: ctx.home)

    assert status == 1
    assert err =~ "at least 12 bytes"
  end

  test "import refuses a root that is not empty", ctx do
    {0, _out, _err} =
      run(["export", ctx.archive, "--passphrase-file", ctx.passphrase_file], home: ctx.home)

    File.mkdir_p!(ctx.into)
    File.write!(Path.join(ctx.into, "keep.txt"), "mine")

    {status, _out, err} =
      run(["import", ctx.archive, "--into", ctx.into, "--passphrase-file", ctx.passphrase_file])

    assert status == 1
    assert err =~ "#{ctx.into} is not empty"
  end

  test "mark-moved is routed to its own verb with this verb's home and probe", ctx do
    {status, out, err} = run(["mark-moved", "--to", "invented-host"], home: ctx.home)

    assert {status, err} == {0, ""}
    assert out =~ "Marked #{ctx.home} moved to invented-host at epoch 5"
    assert {:ok, %{epoch: 5, to: "invented-host"}} = Moved.read(ctx.home)
  end

  test "export --mark-moved marks the home right after the archive is sealed", ctx do
    {status, out, err} =
      run(
        ["export", ctx.archive, "--passphrase-file", ctx.passphrase_file] ++
          ["--mark-moved", "--to", "invented-vm"],
        home: ctx.home,
        now: fn -> ~U[2026-10-27 09:30:00.123Z] end
      )

    assert {status, err} == {0, ""}
    assert out =~ "Marked #{ctx.home} moved to invented-vm at epoch 5."
    assert File.exists?(ctx.archive)

    assert Moved.read(ctx.home) ==
             {:ok, %{epoch: 5, moved_at: ~U[2026-10-27 09:30:00Z], to: "invented-vm"}}

    # A home already marked is not exported again as the primary.
    other = Path.join(ctx.tmp, "again.fxhome")

    {status, _out, err} =
      run(
        ["export", other, "--passphrase-file", ctx.passphrase_file] ++
          ["--mark-moved", "--to", "elsewhere"],
        home: ctx.home
      )

    assert status == 1
    assert err =~ "This home already moved to invented-vm at epoch 5"
    refute File.exists?(other)
  end

  test "export refuses a home that already moved, by name, and writes nothing", ctx do
    :ok =
      Moved.write(ctx.home, %{epoch: 5, moved_at: ~U[2026-10-27 09:30:00Z], to: "invented-vm"})

    {status, out, err} =
      run(["export", ctx.archive, "--passphrase-file", ctx.passphrase_file], home: ctx.home)

    assert {status, out} == {1, ""}

    assert err ==
             "fermix home: This home moved to invented-vm on 2026-10-27 at epoch 5; a retired " <>
               "copy cannot be exported as a primary.\n"

    refute File.exists?(ctx.archive)
  end

  test "import onto another host names what does not travel", ctx do
    File.write!(Path.join(ctx.home, "config.toml"), """
    [fermix_core.harness]
    approved = true

    [sandbox]
    workspace_root = "#{ctx.home}/workspace"
    extra = "/Users/invented/Projects"
    """)

    seed_database!(Path.join(ctx.home, "memory.db"))
    File.mkdir_p!(Path.join(ctx.home, "plugins"))

    File.write!(
      Path.join(ctx.home, "plugins/installed.json"),
      ~s({"notes": {"version": "1.0.0"}})
    )

    {0, _out, ""} =
      run(["export", ctx.archive, "--passphrase-file", ctx.passphrase_file], home: ctx.home)

    {status, out, err} =
      run(["import", ctx.archive, "--into", ctx.into, "--passphrase-file", ctx.passphrase_file],
        host: "linux-x86_64",
        keyring_usable?: fn -> false end
      )

    assert {status, err} == {0, ""}

    assert out =~
             "Kept as they were; review them, they hold paths outside the old home: sandbox.extra."

    assert out =~ "Coding-harness consent does not travel; approve it again here."

    assert out =~
             ~s(This host has no usable keyring, so secrets are kept in files here: secret_store = "file".)

    assert out =~
             "Removed 1 screen-history row: screen history stays on the machine it describes."

    assert out =~
             "Installed plugins were built for macos-aarch64, and this host is linux-x86_64. " <>
               "Reinstall each:\n  fermix plugins install notes\n"

    assert String.ends_with?(out, @moved <> "\n")
  end

  test "usage errors exit 2 and print no result", ctx do
    for argv <- [
          [],
          ["export"],
          ["export", ctx.archive, "extra"],
          ["export", ctx.archive, "--bogus"],
          ["import", ctx.archive],
          ["import", "--into", ctx.into],
          ["export", ctx.archive, "--mark-moved"],
          ["export", ctx.archive, "--to", "invented-vm"],
          ["unknown"]
        ] do
      {status, out, err} = run(argv, home: ctx.home)
      assert status == 2, inspect(argv)
      assert out == "", inspect(argv)
      assert err =~ "fermix home export FILE", inspect(argv)
    end
  end

  test "the dispatcher routes `fermix home` to this verb", ctx do
    previous = System.get_env("FERMIX_HOME")
    System.put_env("FERMIX_HOME", ctx.home)
    on_exit(fn -> restore_env(previous) end)

    parent = self()

    err =
      capture_io(:stderr, fn ->
        out =
          capture_io(fn ->
            send(
              parent,
              {:status,
               Fermix.CLI.main([
                 "home",
                 "export",
                 ctx.archive,
                 "--passphrase-file",
                 ctx.passphrase_file
               ])}
            )
          end)

        send(parent, {:out, out})
      end)

    assert_received {:status, 0}
    assert_received {:out, out}
    assert err == ""
    assert out =~ "Exported #{ctx.home} to #{ctx.archive}"
  end

  # This host's facts, pinned: a macOS host whose keyring answers, at a fixed now.
  defp run(argv, deps \\ [], input \\ "") do
    defaults = [
      hello: fn -> @not_running end,
      host: "macos-aarch64",
      keyring_usable?: fn -> true end,
      now_ms: @now
    ]

    deps = Keyword.merge(defaults, deps)
    parent = self()

    err =
      capture_io(:stderr, fn ->
        out = capture_io(input, fn -> send(parent, {:status, HomeCommand.run(argv, deps)}) end)
        send(parent, {:out, out})
      end)

    assert_received {:status, status}
    assert_received {:out, out}
    {status, out, err}
  end

  defp seed_database!(db) do
    {:ok, conn} = Sqlite3.open(db)

    for sql <- [
          ComputerHistorySql.events_schema_sql(),
          ComputerHistorySql.memories_schema_sql(),
          ComputerHistorySql.state_schema_sql(),
          ComputerHistorySql.access_schema_sql(),
          ComputerHistorySql.purges_schema_sql(@now - 86_400_000),
          "INSERT INTO computer_history_events (boot_id, source_seq, ts, type) " <>
            "VALUES ('invented', 1, #{@now - 3_600_000}, 'app_switch');"
        ] do
      :ok = Sqlite3.execute(conn, sql)
    end

    :ok = Sqlite3.close(conn)
  end

  defp restore_env(nil), do: System.delete_env("FERMIX_HOME")
  defp restore_env(value), do: System.put_env("FERMIX_HOME", value)
end
