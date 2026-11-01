defmodule FermixCore.Home.Candidate.ReturnSettleTest do
  # A return (Always On's move back): the server's copy is staged on the
  # computer it left, beside that computer's retired one. The stub keychain is
  # one table for the VM, so each test writes under its own profile.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Archive.ConfigText
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Candidate.Activation
  alias FermixCore.Home.Candidate.Return
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Moved
  alias FermixCore.Home.Snapshot
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Management.Placement
  alias FermixCore.Setup.SecretWriter
  alias FermixTestSupport.SafeRm

  @now ~U[2031-06-01 09:00:00Z]
  @recovery "fxsnap1.AAAAAAAAAAAAAAAAAAAAAA.BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"

  setup do
    tmp = SafeRm.make_tmp_dir!("return_settle")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)
    profile = "rs-#{System.unique_integer([:positive])}"
    server = server_home!(Path.join(tmp, "server"), profile)
    mac = mac_home!(Path.join(tmp, "mac"), profile)
    pair = Recipient.generate()
    incoming = Path.join(tmp, "incoming.fxsnap")

    {:ok, _written} =
      Snapshot.write(server, Recipient.public(pair), incoming, host: "linux-x86_64")

    {:ok, desktop} = DesktopLink.read_key(mac)

    %{tmp: tmp, mac: mac, profile: profile, pair: pair, incoming: incoming, desktop: desktop}
  end

  test "the device-class sections name every section only this machine configures" do
    assert Enum.sort(Map.keys(Return.device_tables())) == Enum.sort(Placement.device_sections())
  end

  test "stages the server's copy one epoch up, settled for this computer as it was", ctx do
    assert {:ok, 7} = stage(ctx)

    staging = Candidate.staging_path(ctx.mac)
    config = File.read!(Path.join(staging, "config.toml"))

    assert {:ok, 7} = Epoch.read(staging)
    assert value(config, "fermix_core.engine", "role") == ~s("primary")
    assert value(config, "fermix_core.snapshots", "recipient") == ~s("#{@recovery}")
    # What only this computer configures is this computer's again.
    assert value(config, "fermix_channels.imessage", "enabled") == "true"
    assert value(config, "sandbox", "mode") == ~s("standard")
    assert value(config, "sandbox.env", "allow") == ~s(["MAC_ONLY"])
    refute config =~ "SERVER_ONLY"
    assert value(config, "fermix_core.computer_use", "enabled") == "true"
    assert value(config, "fermix_core.computer_history", "apps") == ~s(["Safari"])
    # Everything else is the server's.
    assert value(config, "fermix_core.memory", "enabled") == "true"
    assert value(config, "fermix_core.agent", "name") == ~s("Orchard")
    # Every restore withdraws coding-agent consent.
    assert value(config, "fermix_core.harness", "approved") == "false"
    # Still a device until the move commits.
    assert File.read!(Path.join(ctx.mac, "config.toml")) =~ ~s(role = "device")
    assert {:ok, _marker} = Moved.read(ctx.mac)
  end

  test "drops this computer's own desktop row from the staged device list", ctx do
    test = self()

    drop = fn root, noise_pk ->
      send(test, {:dropped, root, noise_pk})
      :ok
    end

    assert {:ok, 7} = stage(ctx, drop_desktop_row: drop)

    staging = Candidate.staging_path(ctx.mac)
    public = ctx.desktop.public
    assert_received {:dropped, ^staging, ^public}
  end

  test "a computer with no desktop key holds no row to drop", ctx do
    SafeRm.rm!(DesktopLink.key_path(ctx.mac))

    assert {:ok, 7} = stage(ctx, drop_desktop_row: fn _root, _pk -> flunk("no row to drop") end)
  end

  test "a device list that cannot be changed fails the staging", ctx do
    assert {:error, {:desktop_row, :unwritable}} =
             stage(ctx, drop_desktop_row: fn _root, _pk -> {:error, :unwritable} end)

    refute File.exists?(Candidate.staging_path(ctx.mac))
  end

  describe "the secrets, by the store this computer used" do
    test "a keychain computer gets every secret back into its keychain, the new value winning",
         ctx do
      stale = [profile: ctx.profile, store: :keyring]
      :ok = SecretWriter.put(:anthropic_api_key, "sk-ant-stale", stale)

      assert {:ok, 7} = stage(ctx)

      staging = Candidate.staging_path(ctx.mac)
      config = File.read!(Path.join(staging, "config.toml"))

      assert value(config, "fermix_core", "secret_store") == ~s("keyring")
      assert value(config, "fermix_core.providers.anthropic", "api_key") == ~s("@keyring")
      assert value(config, "fermix_core.cues.sources.invented-feed", "key") == ~s("@keyring")
      # No file came back for it, so it stays a file reference.
      assert value(config, "fermix_channels.telegram", "bot_token") == ~s("@file")

      assert SecretWriter.get(:anthropic_api_key, stale) == {:ok, "sk-ant-changed-on-server"}

      assert SecretWriter.get({:cue_source, "invented-feed", :key}, stale) ==
               {:ok, "invented-cue-key"}

      refute File.exists?(Path.join(staging, "secrets/ANTHROPIC_API_KEY"))
      refute File.exists?(Path.join(staging, "secrets/cue_source.invented-feed.key"))
    end

    test "a file-store computer keeps its secrets as files", ctx do
      put_retired(ctx.mac, "fermix_core", "secret_store", ~s("file"))

      assert {:ok, 7} = stage(ctx)

      staging = Candidate.staging_path(ctx.mac)
      config = File.read!(Path.join(staging, "config.toml"))

      assert value(config, "fermix_core", "secret_store") == ~s("file")
      assert value(config, "fermix_core.providers.anthropic", "api_key") == ~s("@file")

      assert File.read!(Path.join(staging, "secrets/ANTHROPIC_API_KEY")) ==
               "sk-ant-changed-on-server"

      assert SecretWriter.get(:anthropic_api_key, profile: ctx.profile, store: :keyring) ==
               {:error, :missing_secret}
    end

    test "a keychain that refuses fails the staging, naming what it did not take", ctx do
      assert {:error, {:keychain_refused, ["anthropic_api_key", "cue_source:invented-feed:key"]}} =
               stage(ctx, impl: FermixTestSupport.UnavailableSecretWriter)

      refute File.exists?(Candidate.staging_path(ctx.mac))

      assert Return.error_sentence(
               {:keychain_refused, ["anthropic_api_key", "cue_source:invented-feed:key"]},
               %{"anthropic_api_key" => "Anthropic key"}
             ) ==
               "This computer's keychain did not take your Anthropic key and 1 other secret, " <>
                 "so Fermix did not move back: unlock it, then move back again."
    end
  end

  test "a computer whose own settings cannot be read stages nothing", ctx do
    SafeRm.rm!(Path.join(ctx.mac, "config.toml"))

    assert {:error, {:retired_config, {:file, _path, :enoent}}} = stage(ctx)
    refute File.exists?(Candidate.staging_path(ctx.mac))
  end

  describe "settle/4's device-class sections" do
    test "come whole from the retired settings, and a section only the server set goes" do
      staged = """
      [fermix_core]
      profile = "general"

      [sandbox]
      mode = "open"

      [sandbox.commands.server-only]
      argv = ["true"]

      [fermix_core.computer_use]
      enabled = false

      [fermix_core.memory]
      enabled = true
      """

      retired = """
      [fermix_core.engine]
      role = "device"

      [sandbox]
      mode = "strict" # this Mac's own
      """

      text = Return.device_sections(staged, retired)

      assert value(text, "sandbox", "mode") == ~s("strict")
      assert text =~ "# this Mac's own"
      refute text =~ "server-only"
      refute text =~ "computer_use"
      assert value(text, "fermix_core.memory", "enabled") == "true"
      assert value(text, "fermix_core", "profile") == ~s("general")
    end
  end

  # The row drop is the rail's (`FermixCore.Home.Link`), which this app does
  # not compile against; it is pinned in the channels app's own test.
  defp stage(ctx, opts \\ []) do
    {:ok, _state} = prepare(ctx.mac)
    opts = Keyword.put_new(opts, :drop_desktop_row, fn _root, _noise_pk -> :ok end)

    Activation.stage(
      ctx.mac,
      ctx.incoming,
      ctx.pair,
      %{"destination" => %{}, "recovery_recipient" => @recovery},
      :return,
      [host: "macos-aarch64", keyring_usable?: fn -> true end] ++ opts
    )
  end

  defp prepare(mac),
    do:
      Candidate.prepare_return(mac, {:local, "hetzner-cx22-orchard"},
        role: :device,
        restarts_itself?: true,
        now: @now
      )

  defp value(text, section, key) do
    case ConfigText.value(text, section, key) do
      {:ok, raw} -> raw
      :absent -> :absent
    end
  end

  defp put_retired(mac, section, key, raw) do
    file = Path.join(mac, "config.toml")
    File.write!(file, ConfigText.put(File.read!(file), section, key, raw))
  end

  # The server as its move left it: the device role its start wrote, the
  # file store its restore chose, the secrets the move brought in its files.
  defp server_home!(root, profile) do
    File.mkdir_p!(Path.join(root, "secrets"))

    File.write!(Path.join(root, "config.toml"), """
    [fermix_core]
    profile = "#{profile}"
    secret_store = "file"

    [fermix_core.engine]
    role = "device"

    [fermix_core.agent]
    name = "Orchard"

    [fermix_core.harness]
    approved = true

    [fermix_core.memory]
    enabled = true

    [fermix_core.providers.anthropic]
    api_key = "@file"

    [fermix_core.cues.sources.invented-feed]
    kind = "webhook"
    key = "@file"

    [sandbox]
    mode = "open"

    [sandbox.env]
    allow = ["SERVER_ONLY"]

    [fermix_channels.telegram]
    bot_token = "@file"

    [fermix_channels.imessage]
    enabled = false
    """)

    File.write!(Path.join(root, "secrets/ANTHROPIC_API_KEY"), "sk-ant-changed-on-server")
    File.write!(Path.join(root, "secrets/cue_source.invented-feed.key"), "invented-cue-key")
    :ok = Epoch.write(root, 6)
    root
  end

  # The computer the home left: a linked desktop in the device role, its
  # marker, its own settings for what only it configures.
  defp mac_home!(root, profile) do
    File.mkdir_p!(root)

    File.write!(Path.join(root, "config.toml"), """
    [fermix_core]
    profile = "#{profile}"

    [fermix_core.engine]
    role = "device"

    [fermix_core.providers.anthropic]
    api_key = "@keyring"

    [sandbox]
    mode = "standard"

    [sandbox.env]
    allow = ["MAC_ONLY"]

    [fermix_core.computer_use]
    enabled = true

    [fermix_core.computer_history]
    enabled = true
    apps = ["Safari"]

    [fermix_channels.imessage]
    enabled = true
    """)

    :ok =
      Moved.write(root, %{epoch: 5, moved_at: ~U[2031-05-01 10:00:00Z], to: "hetzner-orchard"})

    :ok = DesktopLink.write_key(root, :crypto.strong_rand_bytes(32))
    root
  end
end
