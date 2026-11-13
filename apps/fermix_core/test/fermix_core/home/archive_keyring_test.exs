defmodule FermixCore.Home.ArchiveKeyringTest do
  @moduledoc """
  The keyring question a restore asks on a host that is not a Mac (M75): a
  keyring-mode home keeps keyring mode only when the keyring answered
  `available`. A probe that timed out (`unknown`), as one can on a busy
  server with no session bus, or any other verdict, moves its secrets into
  the files, and the log says so once. The verdict is the stub store's,
  pinned for the whole VM, so this module runs on its own.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Home.Archive
  alias FermixCore.Home.Epoch
  alias FermixCore.Setup.SecretService.Probe
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub

  @passphrase "invented-harbour-lantern"
  @now 1_793_083_733_000
  @login "/org/freedesktop/secrets/collection/login"

  setup do
    tmp = SafeRm.make_tmp_dir!("archive_keyring")

    on_exit(fn ->
      SecretWriterStub.clear_verdict(:keyring)
      SafeRm.rm_rf!(tmp)
    end)

    home = Path.join(tmp, "home")
    File.mkdir_p!(home)

    File.write!(Path.join(home, "config.toml"), """
    [fermix_core.providers.openai]
    api_key = "@keyring"
    """)

    :ok = Epoch.write(home, 3)
    archive = Path.join(tmp, "home.fxhome")

    {:ok, _created} =
      Archive.create(home, @passphrase,
        to: archive,
        hello: fn -> {:error, :not_running} end,
        host: "macos-aarch64"
      )

    %{archive: archive, into: Path.join(tmp, "restored")}
  end

  test "a probe that timed out moves the secrets into the files, and says so once", ctx do
    verdict = timed_out()
    assert %{state: :unknown, evidence: "timed out after 1500ms"} = verdict
    :ok = SecretWriterStub.set_verdict(verdict)

    log =
      capture_log(fn ->
        assert {:ok, %{secret_store_switched: true}} = restore(ctx)
      end)

    assert File.read!(Path.join(ctx.into, "config.toml")) =~ ~s(secret_store = "file")

    assert [_once] = Regex.scan(~r/keeps its secrets in files/, log)
    assert log =~ "timed out after 1500ms"
  end

  test "a keyring that answered keeps keyring mode, and says nothing", ctx do
    :ok =
      SecretWriterStub.set_verdict(%{store: :keyring, state: :available, sentence: "it answers"})

    log =
      capture_log(fn ->
        assert {:ok, %{secret_store_switched: false}} = restore(ctx)
      end)

    refute File.read!(Path.join(ctx.into, "config.toml")) =~ "secret_store"
    refute log =~ "keeps its secrets in files"
  end

  # M97 F9: a headless Always On server keeps its secrets in files
  # (`[fermix_core] secret_store = "file"`), so it has no keyring to ask: a
  # Mac's home it takes in keeps its secrets in files there too, and nothing
  # says a keyring did not answer.
  test "an engine whose secrets are files asks no keyring, and the home keeps files", ctx do
    :ok =
      SecretWriterStub.set_verdict(%{
        store: :keyring,
        state: :tool_absent,
        sentence: "this machine has no keyring client"
      })

    log =
      capture_log(fn ->
        assert {:ok, %{secret_store_switched: true}} = restore(ctx, secret_store: :file)
      end)

    assert File.read!(Path.join(ctx.into, "config.toml")) =~ ~s(secret_store = "file")
    refute log =~ "the keyring answered"
  end

  test "an engine whose secrets are in its keyring still asks it", ctx do
    :ok =
      SecretWriterStub.set_verdict(%{
        store: :keyring,
        state: :tool_absent,
        sentence: "this machine has no keyring client"
      })

    log =
      capture_log(fn ->
        assert {:ok, %{secret_store_switched: true}} = restore(ctx, secret_store: :keyring)
      end)

    assert log =~ "restore: the keyring answered tool_absent"
  end

  defp restore(ctx, opts \\ []),
    do:
      Archive.restore(
        ctx.archive,
        @passphrase,
        ctx.into,
        [host: "linux-x86_64", now_ms: @now] ++ opts
      )

  # The verdict the real probe gives when its last question times out.
  defp timed_out do
    answers = %{
      "NameHasOwner" => {:ok, "b true\n"},
      "ReadAlias" => {:ok, ~s(o "#{@login}"\n)},
      "Locked" => {:error, {:timeout, 1_500}}
    }

    runner = fn _busctl, args ->
      member = Enum.find(["NameHasOwner", "ReadAlias", "Locked"], &(&1 in args))
      Map.fetch!(answers, member)
    end

    Probe.run(runner: runner, find_executable: fn "busctl" -> "/usr/bin/busctl" end)
  end
end
