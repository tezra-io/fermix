defmodule FermixChannels.Desktop.JoinTest do
  # M97 §3.1, §7.5, two engines in one VM: a fresh computer joins with a
  # code from a primary's window, over real Noise from the joiner's worker,
  # shows the same six digits as the window, is added by the owner, and its
  # relay then connects to the primary with its own key. The stub keychain is
  # one table for the VM, so the joiner names a profile of its own.
  use ExUnit.Case, async: true

  alias FermixChannels.Desktop.Join, as: Joiner
  alias FermixChannels.Home.Enrollment
  alias FermixChannels.Mobile.DeviceStore
  alias FermixChannels.Test.DesktopRail
  alias FermixChannels.Test.HomeMove
  alias FermixCore.Home.ComputerKey
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Join

  @wait 10_000
  @host %{
    "host" => %{"name" => "loft-linux", "os" => "linux", "arch" => "x86_64", "version" => "9.9.9"},
    "platform" => "linux"
  }

  setup do
    primary = HomeMove.primary!()
    {:ok, %{code: code}} = Enrollment.open(primary.enrollment, nil, :computer)
    joiner = DesktopRail.root!("fx-dj")
    File.mkdir_p!(joiner)
    profile = ~s([fermix_core]\nprofile = "#{Path.basename(joiner)}"\n)
    File.write!(Path.join(joiner, "config.toml"), profile)
    test = self()
    restart = fn -> send(test, :restarted) && :ok end
    :ok = Join.start(joiner, code, now: HomeMove.now(), restart: restart)
    assert_received :restarted
    %{primary: primary, joiner: joiner, restart: restart}
  end

  test "joins, is added with the digits it shows, and its relay connects", ctx do
    worker = start_worker(ctx)
    sas = await_digits(ctx)

    # The server's window names the computer and never its digits: the owner
    # types the ones the new computer shows, and those approve it.
    assert %{joiner: joiner} = await_window(ctx)
    refute Map.has_key?(joiner, :sas)

    assert {:ok, %{device_id: id, name: "loft-linux"}} =
             Enrollment.approve(ctx.primary.enrollment, sas)

    assert_receive :restarted, @wait
    assert_receive {:DOWN, _ref, :process, ^worker, :normal}, @wait
    refute Join.present?(ctx.joiner)

    assert {:ok, link} = DesktopLink.read(ctx.joiner)
    assert {link.device_id, link.key, link.epoch} == {id, :keyring, 4}
    assert link.primary.gateway_pk == ctx.primary.gateway.public

    {:ok, keypair} = ComputerKey.read(ctx.joiner)

    assert {:ok, [%{device_id: ^id, noise_pk: noise_pk, backups: false}]} =
             DeviceStore.list(ctx.primary.store)

    assert noise_pk == keypair.public

    # The joined computer's relay reaches the home with its own key: the
    # primary's identity and device list, served as a primary's sessions
    # serve a computer (the window's bridge serves enrollment alone).
    serving = DesktopRail.root!("fx-dn")
    File.cp_r!(Path.join(ctx.primary.root, "mobile"), Path.join(serving, "mobile"))
    File.chmod!(Path.join(serving, "mobile"), 0o700)
    socket = HomeMove.new_primary!(serving)
    relay = DesktopRail.start_relay!(ctx.joiner, %{bridge_socket: socket})
    assert %{connected: true} = DesktopRail.await_connected(relay)
  end

  test "a denial is kept with its sentence, and nothing is linked", ctx do
    worker = start_worker(ctx)
    _sas = await_digits(ctx)
    _waiting = await_window(ctx)

    :ok = Enrollment.deny(ctx.primary.enrollment)

    assert_receive {:DOWN, _ref, :process, ^worker, :normal}, @wait
    assert {:ok, %{"phase" => "denied", "sentence" => said}} = Join.read(ctx.joiner)
    assert said == "studio-mac did not add this computer. Open a new code there to try again."
    refute File.exists?(DesktopLink.path(ctx.joiner))
    refute_received :restarted
    assert {:ok, []} = DeviceStore.list(ctx.primary.store)
  end

  defp start_worker(ctx) do
    test = self()

    opts = [
      home: ctx.joiner,
      connect: fn _route -> DesktopRail.bridge_connect(ctx.primary.bridge_socket) end,
      clock: fn -> HomeMove.now() end,
      sleep: fn ms -> send(test, {:slept, ms}) end,
      restart: ctx.restart,
      host: @host,
      status_changed: fn -> send(test, :status_changed) && :ok end
    ]

    {:ok, pid} = Task.start(fn -> Joiner.run(opts) end)
    Process.monitor(pid)
    pid
  end

  # The window once the computer's request reached it: the owner decides on
  # what the window shows.
  defp await_window(ctx) do
    HomeMove.await(fn ->
      case Enrollment.status(ctx.primary.enrollment) do
        %{state: :awaiting_approval} = waiting -> waiting
        _not_yet -> nil
      end
    end)
  end

  # The digits the joiner recorded, once it told the watch it waits; a dial
  # tried again tells it first, at most a few times.
  defp await_digits(ctx, tells \\ 5) do
    assert_receive :status_changed, @wait

    case Join.read(ctx.joiner) do
      {:ok, %{"phase" => "awaiting_approval", "sas" => sas}} -> sas
      {:ok, %{"phase" => "dialing"}} when tells > 1 -> await_digits(ctx, tells - 1)
    end
  end
end
