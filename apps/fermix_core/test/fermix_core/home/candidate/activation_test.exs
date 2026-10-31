defmodule FermixCore.Home.Candidate.ActivationTest do
  use ExUnit.Case, async: true

  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Candidate.Activation
  alias FermixCore.Home.EnrollmentCode
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Snapshot
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Home.Snapshot.Status
  alias FermixCore.Plugins.Dist.Reinstall
  alias FermixTestSupport.SafeRm

  @now ~U[2031-05-04 10:00:00Z]
  @recovery "fxsnap1.AAAAAAAAAAAAAAAAAAAAAA.BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"

  setup do
    tmp = SafeRm.make_tmp_dir!("activation")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)

    source = Path.join(tmp, "source")
    File.mkdir_p!(Path.join(source, "journals"))

    File.write!(
      Path.join(source, "config.toml"),
      """
      [fermix_core.engine]
      role = "device"

      [sandbox]
      workspace_root = "#{source}/workspace"

      [fermix_channels.imessage]
      enabled = true
      """
    )

    File.write!(Path.join([source, "journals", "day.md"]), "an invented day\n")
    :ok = Epoch.write(source, 6)

    home = Path.join(tmp, "candidate-home")
    {:ok, code} = EnrollmentCode.encode(code_facts())

    {:ok, _code} =
      Candidate.enroll(home, code,
        destination: %{"s3_bucket" => "invented-bucket-91", "s3_region" => "eu-north-1"},
        now: @now
      )

    {:ok, pair} = Candidate.recipient_pair(home)
    incoming = Candidate.incoming_path(home)

    {:ok, _written} =
      Snapshot.write(source, Recipient.public(pair), incoming, host: "macos-aarch64")

    %{tmp: tmp, source: source, home: home, pair: pair, incoming: incoming}
  end

  test "stages the stream one epoch up, settled for this home", ctx do
    {:ok, destination} = Candidate.destination(ctx.home)

    assert {:ok, 7} =
             Activation.stage(
               ctx.home,
               ctx.incoming,
               ctx.pair,
               %{"destination" => destination, "recovery_recipient" => @recovery},
               restore_opts()
             )

    staging = Candidate.staging_path(ctx.home)
    config = File.read!(Path.join(staging, "config.toml"))

    assert config =~ ~s(role = "primary")
    refute config =~ ~s(role = "device")
    assert config =~ ~s(workspace_root = "#{ctx.home}/workspace")
    assert config =~ ~s(s3_bucket = "invented-bucket-91")
    assert config =~ ~s(s3_region = "eu-north-1")
    refute config =~ "s3_credentials"
    assert config =~ ~s(recipient = "#{@recovery}")
    # iMessage runs only on a Mac; left on, the settings would not load here.
    assert config =~ "[fermix_channels.imessage]\nenabled = false"
    assert {:ok, 7} = Epoch.read(staging)
    assert File.read!(Path.join([staging, "journals", "day.md"])) == "an invented day\n"

    # Still a candidate until the staged home is renamed into place.
    assert File.read!(Path.join(ctx.home, "config.toml")) =~ ~s(role = "candidate")
  end

  test "the keychain's secrets the stream carried land in the file store, referenced as files",
       ctx do
    File.write!(
      Path.join(ctx.source, "config.toml"),
      """
      [fermix_core.providers.anthropic]
      api_key = "@keyring"

      [fermix_channels.telegram]
      bot_token = "@keyring"
      """
    )

    SafeRm.rm!(ctx.incoming)

    {:ok, _written} =
      Snapshot.write(ctx.source, Recipient.public(ctx.pair), ctx.incoming,
        host: "macos-aarch64",
        extra_files: [{"secrets/ANTHROPIC_API_KEY", "sk-ant-invented"}]
      )

    assert {:ok, 7} = Activation.stage(ctx.home, ctx.incoming, ctx.pair, %{}, restore_opts())

    staging = Candidate.staging_path(ctx.home)
    config = File.read!(Path.join(staging, "config.toml"))
    assert config =~ "[fermix_core.providers.anthropic]\napi_key = \"@file\""
    # Not carried, so still a keychain reference the new primary reports missing.
    assert config =~ "[fermix_channels.telegram]\nbot_token = \"@keyring\""
    secret = Path.join(staging, "secrets/ANTHROPIC_API_KEY")
    assert File.read!(secret) == "sk-ant-invented"
    assert Bitwise.band(File.stat!(secret).mode, 0o777) == 0o600
  end

  test "activation asks the new primary's first boot for a snapshot at once", ctx do
    {:ok, 7} = Activation.stage(ctx.home, ctx.incoming, ctx.pair, %{}, restore_opts())
    assert :ok = Activation.activate(ctx.home)

    assert {:ok, %{run_at_boot: true}} = Status.read(ctx.home)
  end

  # Plugins installed for another system are installed again by the new
  # primary's first boot (`Plugins.Dist.Reinstall`): the staged home names
  # them, and the name list moves into place with it.
  test "the plugins the stream brought from another system wait to be installed again", ctx do
    File.mkdir_p!(Path.join(ctx.source, "plugins"))

    File.write!(
      Path.join(ctx.source, "plugins/installed.json"),
      ~s({"invented-notes": {"version": "1.0.0"}, "invented-tasks": {"version": "2.1.0"}})
    )

    SafeRm.rm!(ctx.incoming)

    {:ok, _written} =
      Snapshot.write(ctx.source, Recipient.public(ctx.pair), ctx.incoming, host: "macos-aarch64")

    assert {:ok, 7} = Activation.stage(ctx.home, ctx.incoming, ctx.pair, %{}, restore_opts())
    assert :ok = Activation.activate(ctx.home)

    plugins = Path.join(ctx.home, "plugins")

    assert %{"pending" => ["invented-notes", "invented-tasks"]} =
             Jason.decode!(File.read!(Reinstall.path(plugins)))
  end

  test "from a computer of the same system nothing waits", ctx do
    File.mkdir_p!(Path.join(ctx.source, "plugins"))
    File.write!(Path.join(ctx.source, "plugins/installed.json"), ~s({"invented-notes": {}}))
    SafeRm.rm!(ctx.incoming)

    {:ok, _written} =
      Snapshot.write(ctx.source, Recipient.public(ctx.pair), ctx.incoming, host: "linux-aarch64")

    assert {:ok, 7} = Activation.stage(ctx.home, ctx.incoming, ctx.pair, %{}, restore_opts())
    refute File.exists?(Reinstall.path(Path.join(Candidate.staging_path(ctx.home), "plugins")))
  end

  test "a Mac keeps its iMessage setting", ctx do
    assert {:ok, 7} =
             Activation.stage(ctx.home, ctx.incoming, ctx.pair, %{},
               host: "macos-aarch64",
               keyring_usable?: fn -> true end
             )

    config = File.read!(Path.join(Candidate.staging_path(ctx.home), "config.toml"))
    assert config =~ "[fermix_channels.imessage]\nenabled = true"
  end

  test "a stream to another key stages nothing", ctx do
    other = Recipient.generate()

    assert {:error, _reason} =
             Activation.stage(ctx.home, ctx.incoming, other, %{}, restore_opts())

    refute File.exists?(Candidate.staging_path(ctx.home))
  end

  test "activation renames the staged home into place, settings last, then drops the candidate",
       ctx do
    {:ok, 7} = Activation.stage(ctx.home, ctx.incoming, ctx.pair, %{}, restore_opts())
    File.mkdir_p!(Path.join(ctx.home, "journals"))
    File.write!(Path.join([ctx.home, "journals", "own.md"]), "the candidate's own\n")

    assert :ok = Activation.activate(ctx.home)

    assert File.read!(Path.join(ctx.home, "config.toml")) =~ ~s(role = "primary")
    assert {:ok, 7} = Epoch.read(ctx.home)
    assert File.read!(Path.join([ctx.home, "journals", "day.md"])) == "an invented day\n"
    refute File.exists?(Path.join([ctx.home, "journals", "own.md"]))
    refute Candidate.present?(ctx.home)
  end

  test "a crash in the middle is finished by the next boot of either role", ctx do
    {:ok, 7} = Activation.stage(ctx.home, ctx.incoming, ctx.pair, %{}, restore_opts())
    {:ok, state} = Candidate.read_state(ctx.home)
    :ok = Candidate.put_state(ctx.home, Map.put(state, "phase", "activating"), @now)

    # Some entries were in place when it stopped; the settings were not.
    staging = Candidate.staging_path(ctx.home)
    File.rename!(Path.join(staging, "journals"), Path.join(ctx.home, "journals"))
    assert {:error, :activation_unfinished} = Activation.finish_activation(ctx.home)

    assert :ok = Activation.activate(ctx.home)
    assert File.read!(Path.join(ctx.home, "config.toml")) =~ ~s(role = "primary")
    refute Candidate.present?(ctx.home)
  end

  test "a primary's boot removes a candidate directory its activation left", ctx do
    {:ok, 7} = Activation.stage(ctx.home, ctx.incoming, ctx.pair, %{}, restore_opts())
    {:ok, state} = Candidate.read_state(ctx.home)
    :ok = Candidate.put_state(ctx.home, Map.put(state, "phase", "activating"), @now)
    staging = Candidate.staging_path(ctx.home)

    for entry <- File.ls!(staging),
        do: File.rename!(Path.join(staging, entry), Path.join(ctx.home, entry))

    assert :ok = Activation.finish_activation(ctx.home)
    refute Candidate.present?(ctx.home)
    assert :ok = Activation.finish_activation(ctx.home)
  end

  test "a primary's boot leaves a candidate in any other phase alone", ctx do
    assert :ok = Activation.finish_activation(ctx.home)
    assert Candidate.present?(ctx.home)
  end

  defp restore_opts, do: [host: "linux-aarch64", keyring_usable?: fn -> false end]

  defp code_facts do
    %{
      secret: :binary.copy(<<0x5A>>, 32),
      gateway_pk: :binary.copy(<<0x3C>>, 32),
      node_id: String.duplicate("4f", 32),
      relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
      relays_rev: "0123456789abcdef",
      name: "orchard-mini",
      expires_at: ~U[2031-05-04 10:10:00Z]
    }
  end
end
