defmodule FermixChannelsTest do
  use ExUnit.Case
  doctest FermixChannels

  import ExUnit.CaptureLog

  alias FermixChannels.Channels.Signal
  alias FermixChannels.Channels.Telegram
  alias FermixChannels.Gateway.ChannelRegistry
  alias FermixChannels.Mobile

  @ready %{status: :ready, failures: []}
  @setup_required %{status: :setup_required, failures: [%{component: "channel"}]}

  test "greets the world" do
    assert FermixChannels.hello() == :world
  end

  describe "registry-driven transport children" do
    test "includes the Telegram poller only when enabled, ready, and ingress authorized" do
      poller = {Telegram.Poller, []}
      previous = Application.get_env(:fermix_channels, :telegram, [])
      on_exit(fn -> Application.put_env(:fermix_channels, :telegram, previous) end)

      Application.put_env(:fermix_channels, :telegram, enabled: true, owner_user_id: "111")
      assert poller in ChannelRegistry.transport_children(@ready)
      refute poller in ChannelRegistry.transport_children(@setup_required)

      Application.put_env(:fermix_channels, :telegram, enabled: false, owner_user_id: "111")
      refute poller in ChannelRegistry.transport_children(@ready)
    end

    test "keeps starting the Telegram poller for legacy webhook-mode configs" do
      poller = {Telegram.Poller, []}
      previous = Application.get_env(:fermix_channels, :telegram, [])
      on_exit(fn -> Application.put_env(:fermix_channels, :telegram, previous) end)

      Application.put_env(:fermix_channels, :telegram,
        enabled: true,
        mode: :webhook,
        owner_user_id: "111"
      )

      assert poller in ChannelRegistry.transport_children(@ready)
    end

    test "refuses the Telegram poller when the ingress allowlist is empty (F-02)" do
      poller = {Telegram.Poller, []}
      previous = Application.get_env(:fermix_channels, :telegram, [])
      on_exit(fn -> Application.put_env(:fermix_channels, :telegram, previous) end)

      Application.put_env(:fermix_channels, :telegram, enabled: true)
      refute poller in ChannelRegistry.transport_children(@ready)
    end

    test "includes the Signal listener only in subprocess mode when enabled, ready, and authorized" do
      listener = {Signal.Listener, []}
      previous = Application.get_env(:fermix_channels, :signal, [])
      on_exit(fn -> Application.put_env(:fermix_channels, :signal, previous) end)

      Application.put_env(:fermix_channels, :signal,
        enabled: true,
        mode: :subprocess,
        owner_user_id: "+1234"
      )

      assert listener in ChannelRegistry.transport_children(@ready)
      refute listener in ChannelRegistry.transport_children(@setup_required)

      # Mode must match the transport.
      Application.put_env(:fermix_channels, :signal,
        enabled: true,
        mode: :webhook,
        owner_user_id: "+1234"
      )

      refute listener in ChannelRegistry.transport_children(@ready)

      Application.put_env(:fermix_channels, :signal,
        enabled: false,
        mode: :subprocess,
        owner_user_id: "+1234"
      )

      refute listener in ChannelRegistry.transport_children(@ready)
    end

    test "refuses the Signal listener when the ingress allowlist is empty (F-02)" do
      listener = {Signal.Listener, []}
      previous = Application.get_env(:fermix_channels, :signal, [])
      on_exit(fn -> Application.put_env(:fermix_channels, :signal, previous) end)

      Application.put_env(:fermix_channels, :signal, enabled: true, mode: :subprocess)
      refute listener in ChannelRegistry.transport_children(@ready)
    end

    # The phone subtree is registered whenever setup is ready, on or off, so its
    # switch can turn it on while the daemon runs (M51 §5.5). Its own start
    # reads the switch and starts nothing while it is off: no listener, no
    # pairing state, no mDNS (Mobile.SupervisorTest, "the live switch").
    test "registers the mobile subtree once setup is ready, whatever its switch says" do
      mobile = {Mobile.Supervisor, []}
      previous = Application.get_env(:fermix_channels, :mobile)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:fermix_channels, :mobile)
          config -> Application.put_env(:fermix_channels, :mobile, config)
        end
      end)

      Application.delete_env(:fermix_channels, :mobile)
      assert mobile in ChannelRegistry.transport_children(@ready)

      Application.put_env(:fermix_channels, :mobile, enabled: false, mode: :listener)
      assert mobile in ChannelRegistry.transport_children(@ready)

      Application.put_env(:fermix_channels, :mobile, enabled: true, mode: :listener)
      assert mobile in ChannelRegistry.transport_children(@ready)
      refute mobile in ChannelRegistry.transport_children(@setup_required)
    end
  end

  # What a boot holds is recorded once, at boot: the transports a boot whose
  # setup was finished registers and this one did not.
  describe "transports a boot holds for setup" do
    setup :telegram_set_to_start

    test "a boot whose setup was not finished holds what a finished one starts" do
      assert Telegram.Poller in FermixChannels.Application.held_by(@setup_required, "held-epoch")
      assert FermixChannels.Application.held_by(@ready, "ready-epoch") == []
    end

    test "this test tree's boot held nothing, so no case here sees a phantom restart" do
      assert FermixChannels.Application.held_at_boot() == []
      assert FermixChannels.Application.waiting_for_restart() == []
    end
  end

  # Core's restart state asks this through `:transport_restart_provider`: what
  # this boot held for setup that the next boot would start. Finishing setup
  # after boot is how it becomes non-empty, which asks for the restart that
  # starts the channels the boot held.
  describe "transports waiting for a restart" do
    setup :telegram_set_to_start

    test "a held transport waits for a restart once setup is finished" do
      assert FermixChannels.Application.waiting_for_restart(
               held: [Telegram.Poller],
               readiness: fn -> @ready end
             ) == [Telegram.Poller]
    end

    test "nothing waits while setup is still not finished" do
      assert FermixChannels.Application.waiting_for_restart(
               held: [Telegram.Poller],
               readiness: fn -> @setup_required end
             ) == []
    end

    test "a held transport turned off since boot does not wait" do
      Application.put_env(:fermix_channels, :telegram, enabled: false, owner_user_id: "111")

      assert FermixChannels.Application.waiting_for_restart(
               held: [Telegram.Poller],
               readiness: fn -> @ready end
             ) == []
    end

    # The phone's subtree is registered on or off, so a held phone waits for a
    # restart only while its switch is on: off, the restart would start nothing.
    test "a held phone waits for a restart only while its switch is on" do
      held_phone = fn switch ->
        FermixChannels.Application.waiting_for_restart(
          held: [Mobile.Supervisor],
          readiness: fn -> @ready end,
          phone_switch: fn -> switch end
        )
      end

      assert held_phone.(true) == [Mobile.Supervisor]
      assert held_phone.(false) == []
    end

    test "a boot that held nothing reads no readiness" do
      assert FermixChannels.Application.waiting_for_restart(
               held: [],
               readiness: fn -> flunk("nothing was held, so nothing is compared") end
             ) == []
    end
  end

  defp telegram_set_to_start(_context) do
    previous = Application.get_env(:fermix_channels, :telegram, [])
    on_exit(fn -> Application.put_env(:fermix_channels, :telegram, previous) end)
    Application.put_env(:fermix_channels, :telegram, enabled: true, owner_user_id: "111")
    :ok
  end

  describe "missing-ingress-authorization startup logs" do
    test "logs enabled ingress channels with no owner or allowlist" do
      previous_telegram = Application.get_env(:fermix_channels, :telegram, [])
      Application.put_env(:fermix_channels, :telegram, enabled: true)

      on_exit(fn ->
        Application.put_env(:fermix_channels, :telegram, previous_telegram)
      end)

      log =
        capture_log(fn ->
          FermixChannels.Application.log_missing_ingress_authorization(%{
            status: :ready,
            failures: []
          })
        end)

      assert log =~
               "telegram ingress is enabled but no owner_user_id or allowed_*_ids list is set"
    end

    test "does not log when a single ingress allowlist entry can act as owner" do
      previous_telegram = Application.get_env(:fermix_channels, :telegram, [])
      Application.put_env(:fermix_channels, :telegram, enabled: true, allowed_user_ids: ["111"])

      on_exit(fn ->
        Application.put_env(:fermix_channels, :telegram, previous_telegram)
      end)

      log =
        capture_log(fn ->
          FermixChannels.Application.log_missing_ingress_authorization(%{
            status: :ready,
            failures: []
          })
        end)

      refute log =~
               "telegram ingress is enabled but no owner_user_id or allowed_*_ids list is set"
    end
  end

  # MILESTONE_54 §14: iMessage on without Fermix Messages on disk is a named
  # refusal at boot, not a failed channels application.
  describe "missing-helper startup logs" do
    test "names an enabled channel whose helper is not installed" do
      previous = Application.get_env(:fermix_channels, :imessage)
      previous_home = System.get_env("FERMIX_HOME")
      previous_plugins = Application.get_env(:fermix_core, :plugins)
      home = FermixTestSupport.SafeRm.make_tmp_dir!("channels-app-missing-helper")
      System.put_env("FERMIX_HOME", home)
      Application.delete_env(:fermix_core, :plugins)

      Application.put_env(:fermix_channels, :imessage,
        enabled: true,
        owner_user_id: "+15551234567"
      )

      on_exit(fn ->
        restore_app_env(:fermix_channels, :imessage, previous)
        restore_app_env(:fermix_core, :plugins, previous_plugins)
        restore_fermix_home(previous_home)
        FermixTestSupport.SafeRm.rm_rf(home)
      end)

      log =
        capture_log(fn ->
          FermixChannels.Application.log_missing_helpers(%{status: :ready, failures: []},
            macos?: true
          )
        end)

      assert log =~ "imessage is enabled but the helper it needs is not installed"
      assert log =~ "Not starting the imessage channel"
    end
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)

  defp restore_fermix_home(nil), do: System.delete_env("FERMIX_HOME")
  defp restore_fermix_home(value), do: System.put_env("FERMIX_HOME", value)
end
