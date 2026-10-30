defmodule FermixCore.Management.HomeMoveEndingTest do
  # M75: the engine that comes back after a move's restart says its ending
  # (`Move.finish_at_boot/2` from the boot). When that phase write fails (a
  # full disk, a folder it may not write), the boot says so (`:boot_ending`,
  # `Move.boot_ending/0` in a daemon), and `home.status` tries it again at
  # each read and says why until it is written, instead of answering the
  # half-said phase as if the restart had not happened. The engine about to
  # restart, whose boot had nothing left unsaid, never says it. The write is
  # made to fail by taking write permission off `.move/`.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Move
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Router
  alias FermixTestSupport.SafeRm

  @now ~U[2031-05-04 10:00:00Z]

  setup do
    home = SafeRm.make_tmp_dir!("home_move_ending")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    :ok = Epoch.write(home, 4)
    File.mkdir_p!(Move.dir(home))

    seams = [
      home: home,
      config: [],
      scheduler: nil,
      now: @now,
      link_status: fn -> %{primary: nil, desktops: [], enrollment: nil} end
    ]

    %{home: home, seams: seams}
  end

  test "a desktop whose boot could not record done says so at each read, until it can", ctx do
    :ok = Move.put_phase(ctx.home, "committed", %{"candidate" => "north-box"}, @now)
    unwritable!(ctx.home)
    assert {:error, {:file, _path, :eacces}} = Move.finish_at_boot(ctx.home, :device)

    device = %{role: :device, primary: "north-box"}
    seams = Keyword.put(ctx.seams, :boot_ending, :unrecorded)
    assert %{"phase" => "committed", "sentence" => sentence} = move(device, seams)
    assert sentence =~ "This home moved to north-box; this computer is now a desktop of it."
    assert sentence =~ "Fermix could not record that here"
    assert sentence =~ "permission denied"
    assert sentence =~ "it tries again each time this status is read"

    writable!(ctx.home)
    assert %{"phase" => "done", "sentence" => done} = move(device, seams)
    assert done == Move.sentence("done", "north-box")
    assert {:ok, %{"phase" => "done"}} = Move.read_phase(ctx.home)
  end

  test "a primary whose boot could not record aborted keeps the reason and says so", ctx do
    :ok =
      Move.put_phase(
        ctx.home,
        "undoing",
        %{"candidate" => "north-box", "sentence" => "north-box refused it."},
        @now
      )

    unwritable!(ctx.home)
    primary = %{role: :primary, primary: nil}
    seams = Keyword.put(ctx.seams, :boot_ending, :unrecorded)
    assert %{"phase" => "undoing", "sentence" => sentence} = move(primary, seams)
    assert sentence =~ "north-box refused it."
    assert sentence =~ "Fermix could not record that here"

    writable!(ctx.home)

    assert %{"phase" => "aborted", "sentence" => "north-box refused it."} =
             move(primary, seams)
  end

  test "the engine about to restart never says the ending, though a read could write it",
       ctx do
    # The worker recorded committed and is restarting this device engine,
    # whose boot left nothing unsaid: only the engine that comes back says done.
    :ok = Move.put_phase(ctx.home, "committed", %{"candidate" => "north-box"}, @now)
    seams = Keyword.put(ctx.seams, :boot_ending, :recorded)

    assert %{"phase" => "committed", "sentence" => sentence} =
             move(%{role: :device, primary: "north-box"}, seams)

    assert sentence == Move.sentence("committed", "north-box")
    assert {:ok, %{"phase" => "committed"}} = Move.read_phase(ctx.home)
  end

  test "a read where nothing is half-said writes nothing", ctx do
    :ok = Move.put_phase(ctx.home, "committed", %{"candidate" => "north-box"}, @now)
    unwritable!(ctx.home)
    seams = Keyword.put(ctx.seams, :boot_ending, :unrecorded)

    # A primary never says a desktop's ending.
    assert %{"phase" => "committed"} = move(%{role: :primary, primary: nil}, seams)
    writable!(ctx.home)
    assert {:ok, %{"phase" => "committed"}} = Move.read_phase(ctx.home)
  end

  defp move(role, seams) do
    {:ok, %{"move" => move}} =
      Router.route(
        %{method: "home.status", protocol_version: Protocol.protocol_version(), params: %{}},
        engine_role: role,
        operation_opts: [home: seams]
      )

    move
  end

  # Restored before the temp home is removed (on_exit runs last-registered first).
  defp unwritable!(home) do
    File.chmod!(Move.dir(home), 0o500)
    on_exit(fn -> File.chmod!(Move.dir(home), 0o700) end)
  end

  defp writable!(home), do: File.chmod!(Move.dir(home), 0o700)
end
