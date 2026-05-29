defmodule FermixChannels.Gateway.ChannelRegistryTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Gateway.Authorizer
  alias FermixChannels.Gateway.ChannelRegistry
  alias FermixChannels.Gateway.Source

  describe "channel_key/1" do
    test "maps remote channel strings to their config key" do
      assert ChannelRegistry.channel_key("telegram") == :telegram
      assert ChannelRegistry.channel_key("whatsapp") == :whatsapp
      assert ChannelRegistry.channel_key("slack") == :slack
      assert ChannelRegistry.channel_key("discord") == :discord
      assert ChannelRegistry.channel_key("signal") == :signal
    end

    test "is nil for local and unknown channels" do
      assert ChannelRegistry.channel_key("cli") == nil
      assert ChannelRegistry.channel_key("daemon") == nil
      assert ChannelRegistry.channel_key("matrix") == nil
    end
  end

  describe "local?/1" do
    test "true for loopback channels, false for remote and unknown" do
      assert ChannelRegistry.local?("cli")
      assert ChannelRegistry.local?("daemon")
      refute ChannelRegistry.local?("telegram")
      refute ChannelRegistry.local?("matrix")
    end
  end

  describe "remote_channels/0" do
    test "lists the five remote config keys, excluding local channels" do
      remote = ChannelRegistry.remote_channels()
      assert Enum.sort(remote) == [:discord, :signal, :slack, :telegram, :whatsapp]
      refute nil in remote
    end
  end

  describe "transport_children/1" do
    test "returns no children when readiness is not ready" do
      assert ChannelRegistry.transport_children(%{status: :setup_required, failures: []}) == []
    end
  end

  describe "missing_ingress_authorizations/0" do
    test "flags an enabled remote channel with no owner or allowlist" do
      previous = Application.get_env(:fermix_channels, :discord, [])
      on_exit(fn -> Application.put_env(:fermix_channels, :discord, previous) end)

      Application.put_env(:fermix_channels, :discord, enabled: true, mode: :gateway)
      assert :discord in ChannelRegistry.missing_ingress_authorizations()

      Application.put_env(:fermix_channels, :discord,
        enabled: true,
        mode: :gateway,
        owner_user_id: "owner-1"
      )

      refute :discord in ChannelRegistry.missing_ingress_authorizations()
    end
  end

  describe "config-registered channel (the no-gateway-source-edit gate)" do
    test "a channel registered only via config resolves through Source and Authorizer" do
      fake = %{
        name: "fake_channel",
        config_key: :fake_channel,
        adapter: nil,
        remote?: true,
        transport: :webhook,
        child: nil
      }

      Application.put_env(:fermix_channels, :channel_registry, [fake])
      Application.put_env(:fermix_channels, :fake_channel, owner_user_id: "owner-1")

      on_exit(fn ->
        Application.delete_env(:fermix_channels, :channel_registry)
        Application.delete_env(:fermix_channels, :fake_channel)
      end)

      assert ChannelRegistry.channel_key("fake_channel") == :fake_channel
      refute ChannelRegistry.local?("fake_channel")

      # Source picks up the new channel with no edit to gateway source.
      source =
        Source.from_message(%{
          channel: "fake_channel",
          metadata: %{user_id: "owner-1"},
          chat_id: "c-1"
        })

      assert source.channel_key == :fake_channel
      assert source.sender_id == "owner-1"

      # And the Authorizer resolves it via the config key the registry supplied.
      assert {:ok, %{role: :operator, trust: :operator}} = Authorizer.resolve(source)

      stranger = Source.from_message(%{channel: "fake_channel", metadata: %{user_id: "nope"}})
      assert {:error, :unauthorized} = Authorizer.resolve(stranger)
    end
  end
end
