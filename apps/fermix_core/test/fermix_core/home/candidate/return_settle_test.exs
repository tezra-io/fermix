defmodule FermixCore.Home.Candidate.ReturnSettleTest do
  # A return (Always On's move back): the server's copy is staged on the
  # computer it left, beside that computer's retired one. The stub keychain is
  # one table for the VM, so each test writes under its own profile.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Archive.ConfigText
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Candidate.Activation
  alias FermixCore.Home.Candidate.Return
  alias FermixCore.Home.ComputerKey
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Moved
  alias FermixCore.Home.Readable
  alias FermixCore.Home.Snapshot
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Setup.MachineFile
  alias FermixCore.Setup.SecretWriter
  alias FermixTestSupport.CraftedSnapshot
  alias FermixTestSupport.SafeRm

  @now ~U[2031-06-01 09:00:00Z]
  @mac_machine """
  [sandbox]
  mode = "standard"

  [sandbox.env]
  allow = ["MAC_ONLY"]

  [fermix_core.computer_use]
  enabled = true

  [fermix_core.plugins]
  dev_local = "/Users/invented/.fermix/dev-plugins"

  [fermix_channels.imessage]
  enabled = true
  """
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

    %{tmp: tmp, mac: mac, profile: profile, pair: pair, incoming: incoming}
  end

  test "stages the server's copy one epoch up, settled for this computer as it was", ctx do
    assert {:ok, 7} = stage(ctx)

    staging = Candidate.staging_path(ctx.mac)
    config = File.read!(Path.join(staging, "config.toml"))

    assert {:ok, 7} = Epoch.read(staging)
    assert value(config, "fermix_core.engine", "role") == ~s("primary")
    assert value(config, "fermix_core.snapshots", "recipient") == ~s("#{@recovery}")
    # M97 §4: what only a computer configures is in its own machine file,
    # which never left this one and which the staging leaves as it is; the
    # server's, which an earlier engine kept in its settings, stays out.
    assert MachineFile.strip(config) == {config, []}
    refute config =~ "SERVER_ONLY"
    refute File.exists?(MachineFile.path(staging))
    assert File.read!(MachineFile.path(ctx.mac)) == @mac_machine
    # Everything else is the server's, and comes back with the home.
    assert value(config, "fermix_core.memory", "enabled") == "true"
    assert value(config, "fermix_core.agent", "name") == ~s("Orchard")
    # Whether coding agents may run is this computer's own (M98 D5): the
    # server's approval stays on the server, and this computer's own file says.
    assert ConfigText.value(config, "fermix_core.harness", "approved") == :absent
    # Still a device until the move commits.
    assert File.read!(Path.join(ctx.mac, "config.toml")) =~ ~s(role = "device")
    assert {:ok, _marker} = Moved.read(ctx.mac)
  end

  # M102 D6: a home off a server holds no computer, so every computer's row
  # goes from the staged device list, this computer's and every other's,
  # whether or not this computer still has its key (the rows themselves are
  # pinned in the channels app's `MoveBackComputersTest`).
  test "drops every computer's row from the staged device list", ctx do
    assert {:ok, 7} = stage(ctx, drop_desktop_rows: dropped(self()))

    staging = Candidate.staging_path(ctx.mac)
    assert_received {:dropped, ^staging}
  end

  test "a computer with no desktop key drops every computer's row all the same", ctx do
    :ok = ComputerKey.delete(ctx.mac, :keyring)

    assert {:ok, 7} = stage(ctx, drop_desktop_rows: dropped(self()))

    staging = Candidate.staging_path(ctx.mac)
    assert_received {:dropped, ^staging}
  end

  test "a device list that cannot be changed fails the staging", ctx do
    assert {:error, {:desktop_rows, :unwritable}} =
             stage(ctx, drop_desktop_rows: fn _root -> {:error, :unwritable} end)

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

  # M97 D16: a move back stages the server's home by its format, as a move
  # and a restore do: a newer engine's home of this format comes back here.
  test "a move back stages the server's home of this format that a newer engine wrote", ctx do
    stream = crafted!(ctx, "same", home_format: Readable.home_format(), engine_version: "99.0.0")

    assert {:ok, 7} = stage(%{ctx | incoming: stream})
    assert {:ok, 7} = Epoch.read(Candidate.staging_path(ctx.mac))
  end

  test "a move back refuses the server's home in a newer format, and stages nothing", ctx do
    ours = Readable.home_format()
    stream = crafted!(ctx, "newer", home_format: ours + 1, engine_version: "0.1.0")

    assert stage(%{ctx | incoming: stream}) == {:error, {:newer_home_format, ours + 1, ours}}
    refute File.exists?(Candidate.staging_path(ctx.mac))
  end

  test "a computer whose own settings cannot be read stages nothing", ctx do
    SafeRm.rm!(Path.join(ctx.mac, "config.toml"))

    assert {:error, {:retired_config, {:file, _path, :enoent}}} = stage(ctx)
    refute File.exists?(Candidate.staging_path(ctx.mac))
  end

  # The rows' drop is the rail's (`FermixCore.Home.Link`), which this app
  # does not compile against; it is pinned in the channels app's own test.
  defp stage(ctx, opts \\ []) do
    {:ok, _state} = prepare(ctx.mac)
    opts = Keyword.put_new(opts, :drop_desktop_rows, fn _root -> :ok end)

    Activation.stage(
      ctx.mac,
      ctx.incoming,
      ctx.pair,
      %{"destination" => %{}, "recovery_recipient" => @recovery},
      :return,
      [host: "macos-aarch64", keyring_usable?: fn -> true end] ++ opts
    )
  end

  defp dropped(test), do: fn root -> send(test, {:dropped, root}) && :ok end

  # The server's home as a stream whose manifest says what the test states.
  defp crafted!(ctx, name, opts) do
    path = Path.join(ctx.tmp, "#{name}.fxsnap")
    server = Path.join(ctx.tmp, "server")
    CraftedSnapshot.write!(path, Recipient.public(ctx.pair), server, opts)
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
  # marker, and its own machine file for what only it configures.
  defp mac_home!(root, profile) do
    File.mkdir_p!(root)

    File.write!(Path.join(root, "config.toml"), """
    [fermix_core]
    profile = "#{profile}"

    [fermix_core.engine]
    role = "device"

    [fermix_core.providers.anthropic]
    api_key = "@keyring"
    """)

    File.write!(MachineFile.path(root), @mac_machine)

    :ok =
      Moved.write(root, %{epoch: 5, moved_at: ~U[2031-05-01 10:00:00Z], to: "hetzner-orchard"})

    {:ok, _keypair, :keyring} = ComputerKey.create(root)
    :ok = DesktopLink.write(root, desktop_link())
    root
  end

  defp desktop_link do
    %{
      device_id: "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e",
      key: :keyring,
      primary: %{
        name: "hetzner-orchard",
        gateway_pk: :binary.copy(<<3>>, 32),
        node_id: String.duplicate("c4", 32),
        relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
        relays_rev: String.duplicate("a1", 8)
      },
      epoch: 5
    }
  end
end
