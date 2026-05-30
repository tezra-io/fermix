defmodule FermixChannelsTest do
  use ExUnit.Case
  doctest FermixChannels

  import ExUnit.CaptureLog

  alias FermixChannels.Channels.Signal
  alias FermixChannels.Channels.Telegram
  alias FermixChannels.Gateway.ChannelRegistry

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
end
