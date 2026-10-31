defmodule FermixCore.Home.StatusWatchNoticesTest do
  # Companion protocol 6 (M75 lean v1 §7): the writes in core that feed the
  # Always On summary tell the watch, which reads it again. The watch runs
  # here under its own registered name, the one those writes tell, with a
  # read of the test's, so this is async: false; the files are a home of the
  # test's own.
  use ExUnit.Case, async: false

  alias FermixCore.Home.Move
  alias FermixCore.Home.Provision.Ledger
  alias FermixCore.Home.StatusWatch
  alias FermixCore.Setup.ConfigStore
  alias FermixTestSupport.SafeRm

  @now ~U[2031-05-04 10:00:00Z]

  setup do
    home = SafeRm.make_tmp_dir!("status-watch-notices")
    previous_home = System.get_env("FERMIX_HOME")
    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      if previous_home,
        do: System.put_env("FERMIX_HOME", previous_home),
        else: System.delete_env("FERMIX_HOME")

      SafeRm.rm_rf!(home)
    end)

    {:ok, reads} = Agent.start_link(fn -> [] end)

    start_supervised!(
      {StatusWatch,
       read: fn ->
         Agent.update(reads, &[:read | &1])
         %{key: :on, off: false, next_change_ms: nil}
       end,
       timer: fn _message, _delay -> make_ref() end,
       cancel_timer: fn _ref -> false end,
       clock_monitor: false}
    )

    :ok = StatusWatch.subscribe(StatusWatch, self())
    settle()
    assert_received :home_status_changed

    %{home: home, reads: reads}
  end

  test "a write of the Hetzner ledger reads the summary again", ctx do
    assert {:ok, _ledger} =
             Ledger.update(
               ctx.home,
               "hetzner",
               &{:ok, Ledger.connect(&1, "invented-token", @now)}
             )

    settle()
    assert reads(ctx) == 2
  end

  test "a ledger update that writes nothing reads nothing", ctx do
    assert {:error, :nothing} =
             Ledger.update(ctx.home, "hetzner", fn _ledger -> {:error, :nothing} end)

    settle()
    assert reads(ctx) == 1
  end

  test "a move's phase, recorded, reads the summary again", ctx do
    File.mkdir_p!(Move.dir(ctx.home))
    assert :ok = Move.put_phase(ctx.home, "streaming", %{}, @now)
    settle()
    assert reads(ctx) == 2
  end

  test "a settings write reads the summary again (the off line names what stops)", ctx do
    assert :ok =
             ConfigStore.save_snapshot(%{fermix_core: [], fermix_channels: [], fermix_web: []})

    assert File.exists?(Path.join(ctx.home, "config.toml"))
    settle()
    assert reads(ctx) == 2
  end

  defp reads(ctx), do: ctx.reads |> Agent.get(& &1) |> length()

  # The read a change asks for is a message the watch sends itself, queued
  # behind what came with it: handled before a second round trip returns.
  defp settle do
    _state = :sys.get_state(StatusWatch)
    _state = :sys.get_state(StatusWatch)
  end
end
