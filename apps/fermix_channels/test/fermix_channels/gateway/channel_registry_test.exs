defmodule FermixChannels.Gateway.ChannelRegistryTest do
  use ExUnit.Case, async: false

  alias FermixChannels.Gateway.Authorizer
  alias FermixChannels.Gateway.ChannelRegistry
  alias FermixChannels.Gateway.Source
  alias FermixCore.IMessage.HelperInstaller
  alias FermixTestSupport.SafeRm

  defmodule FakeChild do
    @moduledoc false
  end

  # A fake Fermix Messages bundle where `HelperInstaller.installed?/0` looks
  # for the pinned version under the test's own FERMIX_HOME.
  defp lay_helper!(home) do
    binary =
      Path.join([
        home,
        "plugins",
        "imessage_helper",
        HelperInstaller.pinned_version(),
        "macos-universal",
        "Fermix Messages.app",
        "Contents",
        "MacOS",
        "fermix-messages"
      ])

    File.mkdir_p!(Path.dirname(binary))
    File.write!(binary, "#!/bin/sh\n")
    File.chmod!(binary, 0o755)
  end

  defp restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_app_env(app, key, value), do: Application.put_env(app, key, value)

  defp restore_fermix_home(nil), do: System.delete_env("FERMIX_HOME")
  defp restore_fermix_home(value), do: System.put_env("FERMIX_HOME", value)

  # A `trust: :local_operator` entry shaped like the acp channel M29 adds: a
  # remote?-true lifecycle with a same-user local transport and no ingress list.
  defp registry_entry(overrides) do
    Enum.into(overrides, %{
      name: "fake_local",
      config_key: :fake_local,
      adapter: nil,
      remote?: true,
      transport: :gateway,
      child: nil,
      trust: :local_operator
    })
  end

  defp register(entries) do
    Application.put_env(:fermix_channels, :channel_registry, entries)

    on_exit(fn ->
      Application.delete_env(:fermix_channels, :channel_registry)
      Application.delete_env(:fermix_channels, :fake_local)
      Application.delete_env(:fermix_channels, :fake_remote)
    end)
  end

  describe "channel_key/1" do
    test "maps remote channel strings to their config key" do
      assert ChannelRegistry.channel_key("telegram") == :telegram
      assert ChannelRegistry.channel_key("whatsapp") == :whatsapp
      assert ChannelRegistry.channel_key("slack") == :slack
      assert ChannelRegistry.channel_key("discord") == :discord
      assert ChannelRegistry.channel_key("signal") == :signal
      assert ChannelRegistry.channel_key("mobile") == :mobile
      assert ChannelRegistry.channel_key("imessage") == :imessage
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

  describe "trust/1" do
    test "the loopback channels carry :local_operator; remote and unknown carry none" do
      assert ChannelRegistry.trust("cli") == :local_operator
      assert ChannelRegistry.trust("daemon") == :local_operator
      assert ChannelRegistry.trust("telegram") == nil
      assert ChannelRegistry.trust("mobile") == nil
      assert ChannelRegistry.trust("matrix") == nil
    end
  end

  describe "ingress_auth/1" do
    test "mobile requires paired-device transport proof" do
      assert ChannelRegistry.ingress_auth("mobile") == :paired_device
      assert ChannelRegistry.ingress_auth("telegram") == nil
      assert ChannelRegistry.ingress_auth("matrix") == nil
    end
  end

  describe "commands?/1" do
    test "defaults to true for every shipped channel that does not opt out" do
      for %{name: name} = channel <- ChannelRegistry.channels(),
          not Map.has_key?(channel, :commands?) do
        assert ChannelRegistry.commands?(name), "#{name} must default to commands enabled"
      end

      assert ChannelRegistry.commands?("matrix")
    end

    test "the shipped opt-outs are exactly the machine surfaces" do
      opted_out =
        ChannelRegistry.channels()
        |> Enum.reject(&ChannelRegistry.commands?(&1.name))
        |> Enum.map(& &1.name)

      assert opted_out == ["acp", "voice"]
    end

    test "false only when the entry opts out" do
      register([registry_entry(commands?: false)])
      refute ChannelRegistry.commands?("fake_local")
    end
  end

  describe "ingress gating vs trust" do
    test "a :local_operator entry needs no ingress list to start" do
      register([registry_entry(child: FakeChild)])
      Application.put_env(:fermix_channels, :fake_local, enabled: true)

      assert {FakeChild, []} in ChannelRegistry.transport_children(%{status: :ready})
      assert ChannelRegistry.missing_ingress_authorizations() == []
    end

    test "a remote gateway channel with empty ingress still refuses to start" do
      remote = %{
        name: "fake_remote",
        config_key: :fake_remote,
        adapter: nil,
        remote?: true,
        transport: :gateway,
        child: FakeChild
      }

      register([remote])
      Application.put_env(:fermix_channels, :fake_remote, enabled: true, mode: :gateway)

      assert ChannelRegistry.transport_children(%{status: :ready}) == []
      assert ChannelRegistry.missing_ingress_authorizations() == [:fake_remote]
    end

    test "a paired-device listener needs no config sender allowlist" do
      listener =
        registry_entry(
          name: "fake_mobile",
          config_key: :fake_local,
          child: FakeChild,
          trust: nil,
          ingress_auth: :paired_device,
          transport: :listener
        )

      register([listener])
      Application.put_env(:fermix_channels, :fake_local, enabled: true, mode: :listener)

      assert {FakeChild, []} in ChannelRegistry.transport_children(%{status: :ready})
      assert ChannelRegistry.missing_ingress_authorizations() == []
    end
  end

  describe "remote_channels/0" do
    test "lists the remote config keys, excluding local channels" do
      remote = ChannelRegistry.remote_channels()
      # `acp` is `remote?: true` for its lifecycle meanings (§4) even though its
      # transport is a same-user socket, so it belongs to this list. `voice` is
      # remote for the same reason but carries no config key at all, so it
      # contributes nothing — a key list must never contain a nil.
      # `imessage` is listed on every host: this is the static set of keys an
      # ingress check may name. Whether its transport runs is the platform
      # gate's question (`transport_children/2`), not this list's.
      assert Enum.sort(remote) ==
               [:acp, :discord, :imessage, :mobile, :signal, :slack, :telegram, :whatsapp]

      refute nil in remote
    end
  end

  # MILESTONE_41_OPENAI_LIVE_VOICE.md §7: the Live delegation surface. Trust
  # comes from the transport (the daemon's own session, in process), so it has
  # no inbox, no allow-list, and no slash-command pipeline — and no transport
  # child, because nothing external connects to it.
  describe "the voice channel" do
    test "is a remote, command-less, local-operator loopback with no child" do
      voice = Enum.find(ChannelRegistry.channels(), &(&1.name == "voice"))

      assert voice.adapter == FermixChannels.Channels.Voice
      assert voice.config_key == nil
      assert voice.remote? == true
      assert voice.transport == :loopback
      assert voice.child == nil
      assert ChannelRegistry.trust("voice") == :local_operator
      refute ChannelRegistry.commands?("voice")
      assert ChannelRegistry.ingress_auth("voice") == nil
    end

    test "is remote for lifecycle purposes, so a turn never reaps its browser" do
      refute ChannelRegistry.local?("voice")
    end

    test "starts no transport child and needs no ingress authorization" do
      children = ChannelRegistry.transport_children(%{status: :ready})

      refute Enum.any?(children, fn {child, _opts} -> child == nil end)
      refute :voice in ChannelRegistry.missing_ingress_authorizations()
    end
  end

  describe "transport_children/1" do
    test "returns no children when readiness is not ready" do
      assert ChannelRegistry.transport_children(%{status: :setup_required, failures: []}) == []
    end
  end

  # MILESTONE_54 §12: the helper reads the Messages of the Mac it runs on, so the
  # entry carries `platform: :macos` and the platform is always injected here.
  describe "the imessage channel" do
    setup do
      previous = Application.get_env(:fermix_channels, :imessage)
      previous_home = System.get_env("FERMIX_HOME")
      previous_plugins = Application.get_env(:fermix_core, :plugins)
      home = SafeRm.make_tmp_dir!("channel-registry-imessage")
      System.put_env("FERMIX_HOME", home)
      Application.delete_env(:fermix_core, :plugins)

      on_exit(fn ->
        restore_app_env(:fermix_channels, :imessage, previous)
        restore_app_env(:fermix_core, :plugins, previous_plugins)
        restore_fermix_home(previous_home)
        SafeRm.rm_rf(home)
      end)

      %{home: home}
    end

    test "is a remote subprocess channel, supervised as a unit, for the Mac only" do
      imessage = Enum.find(ChannelRegistry.channels(), &(&1.name == "imessage"))

      assert imessage.config_key == :imessage
      assert imessage.adapter == FermixChannels.Channels.IMessage
      assert imessage.remote? == true
      assert imessage.transport == :subprocess
      assert imessage.child == FermixChannels.Channels.IMessage.Supervisor
      assert imessage.platform == :macos
      assert ChannelRegistry.trust("imessage") == nil
      assert ChannelRegistry.commands?("imessage")
    end

    test "platform_ok?/2 answers from the injected platform alone" do
      imessage = Enum.find(ChannelRegistry.channels(), &(&1.name == "imessage"))
      telegram = Enum.find(ChannelRegistry.channels(), &(&1.name == "telegram"))

      assert ChannelRegistry.platform_ok?(imessage, macos?: true)
      refute ChannelRegistry.platform_ok?(imessage, macos?: false)
      assert ChannelRegistry.platform_ok?(telegram, macos?: false)
      assert ChannelRegistry.platform_ok?(telegram, macos?: true)
    end

    test "starts on a Mac once enabled with an owner and the helper on disk", %{home: home} do
      child = {FermixChannels.Channels.IMessage.Supervisor, []}
      lay_helper!(home)

      Application.put_env(:fermix_channels, :imessage,
        enabled: true,
        owner_user_id: "+15551234567"
      )

      assert child in ChannelRegistry.transport_children(%{status: :ready}, macos?: true)
      refute :imessage in ChannelRegistry.missing_helpers(macos?: true)

      Application.put_env(:fermix_channels, :imessage,
        enabled: false,
        owner_user_id: "+15551234567"
      )

      refute child in ChannelRegistry.transport_children(%{status: :ready}, macos?: true)
    end

    # MILESTONE_54 §14: an enabled channel whose helper is not on disk is not
    # started and is named instead, never a failed channels application at
    # boot. The pin moves with every helper release, so an upgrade meets this.
    test "is not started without the helper on disk, and is named as missing it" do
      child = {FermixChannels.Channels.IMessage.Supervisor, []}

      Application.put_env(:fermix_channels, :imessage,
        enabled: true,
        owner_user_id: "+15551234567"
      )

      refute child in ChannelRegistry.transport_children(%{status: :ready}, macos?: true)
      assert ChannelRegistry.missing_helpers(macos?: true) == [:imessage]
      assert ChannelRegistry.missing_helpers(macos?: false) == []

      Application.put_env(:fermix_channels, :imessage,
        enabled: false,
        owner_user_id: "+15551234567"
      )

      assert ChannelRegistry.missing_helpers(macos?: true) == []
    end

    test "never starts on Linux, and Linux never reports it as missing an owner" do
      child = {FermixChannels.Channels.IMessage.Supervisor, []}

      Application.put_env(:fermix_channels, :imessage,
        enabled: true,
        owner_user_id: "+15551234567"
      )

      refute child in ChannelRegistry.transport_children(%{status: :ready}, macos?: false)

      Application.put_env(:fermix_channels, :imessage, enabled: true)
      refute :imessage in ChannelRegistry.missing_ingress_authorizations(macos?: false)
      assert :imessage in ChannelRegistry.missing_ingress_authorizations(macos?: true)
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
