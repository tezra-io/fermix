defmodule FermixCore.Home.MoveReadinessTest do
  # Every fact comes from the home on disk and seams: the free space, this
  # engine's version and host. The keychain is the stub store, under a
  # profile of this test's own.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Candidates
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.MoveReadiness
  alias FermixCore.Setup.SecretWriter
  alias FermixTestSupport.DistFixtures
  alias FermixTestSupport.SafeRm

  @now ~U[2031-05-04 10:00:00Z]
  @plenty 1_099_511_627_776

  setup do
    home = SafeRm.make_tmp_dir!("move_readiness")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    :ok = Epoch.write(home, 4)
    profile = "ready-#{System.unique_integer([:positive])}"

    File.write!(Path.join(home, "config.toml"), """
    [fermix_core]
    profile = "#{profile}"

    [fermix_core.providers.anthropic]
    api_key = "@keyring"

    [fermix_core.harness]
    approved = true

    [fermix_channels.whatsapp]
    enabled = true

    [fermix_channels.slack]
    enabled = true

    [fermix_channels.imessage]
    enabled = true

    [fermix_core.meetings]
    enabled = true
    """)

    File.mkdir_p!(Path.join(home, "plugins"))

    File.write!(
      Path.join(home, "plugins/installed.json"),
      ~s({"invented-notes": {"version": "1.0.0"}, "invented-tasks": {"version": "2.1.0"}})
    )

    # The catalog this engine ships: invented-notes is built for this Mac
    # only, invented-tasks for any system.
    index =
      DistFixtures.write_index(Path.join(home, "catalog/index.json"), [
        catalog_entry("invented-notes", "1.0.0", ["macos-aarch64"]),
        catalog_entry("invented-tasks", "2.1.0", ["any"])
      ])

    {:ok, candidate} = Candidates.add(home, candidate_attrs(), @now)
    %{home: home, candidate: candidate, profile: profile, index: index}
  end

  test "a ready move: the keychain's secret can be read, and every warning is said", ctx do
    :ok =
      SecretWriter.put(:anthropic_api_key, "sk-ant-invented",
        profile: ctx.profile,
        store: :keyring
      )

    assert %{ready: true, items: items} =
             MoveReadiness.report(ctx.home, ctx.candidate, opts(ctx))

    assert Enum.map(items, &{&1.id, &1.status}) == [
             {"keychain_secrets", :ok},
             {"engine_version", :ok},
             {"disk", :ok},
             {"s3_size", :ok},
             {"plugins", :warn},
             {"stays_here", :warn},
             {"whatsapp", :warn},
             {"slack", :warn},
             {"coding_agents", :warn},
             {"cutover_gap", :warn},
             {"serves_nothing", :warn},
             {"service", :ok}
           ]

    sentence = fn id -> Enum.find(items, &(&1.id == id)).sentence end
    assert sentence.("keychain_secrets") =~ "1 secret kept in this computer's keychain moves"
    # Reading it can raise the keychain's own prompt, here and once more when
    # the move carries it.
    assert sentence.("keychain_secrets") =~
             "Checking it opened this computer's keychain, and the move opens it once more"

    # Only the plugin with no build for the server is named: the server
    # installs the others again itself.
    assert sentence.("plugins") ==
             "These plugins have no build for north-box, so they stop working after the " <>
               "move: invented-notes."

    # Only what this home uses of what runs here alone is named.
    assert sentence.("stays_here") ==
             "iMessage and meetings stop after the move: neither this Mac nor north-box " <>
               "runs them."

    assert sentence.("whatsapp") ==
             "WhatsApp stops after the move: it needs an address on the internet that " <>
               "WhatsApp can send messages to, and north-box has none."

    assert sentence.("slack") ==
             "Slack stops after the move unless it uses Socket Mode, which you turn on in " <>
               "your Slack app's settings and then in Fermix's Slack settings."

    assert sentence.("coding_agents") ==
             "Coding agents ask for your approval again on north-box."

    # Telegram keeps what it holds until the poller asks again.
    assert sentence.("cutover_gap") =~ "Telegram while the move runs wait until it is done"
    refute sentence.("cutover_gap") =~ "lost"
    assert sentence.("serves_nothing") =~ "north-box"
    refute Enum.any?(items, &(&1.sentence =~ "sk-ant-invented"))
  end

  test "WhatsApp and Slack turned off, Slack on Socket Mode, and no coding agent approved say so",
       ctx do
    File.write!(Path.join(ctx.home, "config.toml"), """
    [fermix_channels.whatsapp]
    enabled = false

    [fermix_channels.slack]
    enabled = true
    mode = "socket"
    """)

    assert %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, opts(ctx))
    item = fn id -> Enum.find(items, &(&1.id == id)) end

    assert %{status: :ok, sentence: "WhatsApp is not turned on."} = item.("whatsapp")

    assert %{status: :ok, sentence: "Slack uses Socket Mode and keeps working on north-box."} =
             item.("slack")

    assert %{status: :ok, sentence: "No coding agent has your approval on this computer."} =
             item.("coding_agents")

    assert %{status: :ok, sentence: "iMessage, voice calls and meetings are not turned on."} =
             item.("stays_here")

    File.write!(Path.join(ctx.home, "config.toml"), "")
    assert %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, opts(ctx))
    assert %{status: :ok, sentence: "Slack is not turned on."} = item_in(items, "slack")
  end

  test "plugins with a build for the server are installed again there, and say so", ctx do
    File.write!(
      Path.join(ctx.home, "plugins/installed.json"),
      ~s({"invented-tasks": {"version": "2.1.0"}})
    )

    assert %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, opts(ctx))

    assert %{status: :ok, sentence: "north-box installs the plugins again for itself right " <> _} =
             item_in(items, "plugins")

    # A plugin the catalog does not carry, or carries in another version, has
    # no build Fermix can install there either.
    File.write!(
      Path.join(ctx.home, "plugins/installed.json"),
      ~s({"invented-tasks": {"version": "9.9.9"}, "invented-local": {"version": "1.0.0"}})
    )

    assert %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, opts(ctx))
    assert %{status: :warn, sentence: sentence} = item_in(items, "plugins")
    assert sentence =~ "move: invented-local, invented-tasks."
  end

  test "blocks: an unreadable secret named, an older server, a disk with no room", ctx do
    old = %{ctx.candidate | version: "0.0.1"}
    tight = Keyword.put(opts(ctx), :free_bytes, fn _dir -> {:ok, 1_000} end)

    assert %{ready: false, items: items} = MoveReadiness.report(ctx.home, old, tight)
    blocks = for %{status: :block} = item <- items, do: {item.id, item.sentence}

    assert [
             {"keychain_secrets", secrets},
             {"engine_version", version},
             {"disk", disk}
           ] = blocks

    assert secrets ==
             "The keychain did not give Fermix your Anthropic key: unlock it, or set it " <>
               "again or clear it in settings, then check again."

    assert version =~ "north-box runs an older Fermix"
    assert disk =~ "make room first"
  end

  test "on a Linux computer, voice calls on are named, and iMessage never is", ctx do
    File.write!(Path.join(ctx.home, "config.toml"), """
    [fermix_core.realtime]
    enabled = true

    [fermix_channels.imessage]
    enabled = true
    """)

    linux = Keyword.put(opts(ctx), :host, "linux-x86_64")
    assert %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, linux)

    assert %{status: :warn, sentence: sentence} = item_in(items, "stays_here")

    assert sentence ==
             "Voice calls stop after the move: neither this computer nor north-box runs them."

    File.write!(Path.join(ctx.home, "config.toml"), "")
    assert %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, linux)

    assert %{status: :ok, sentence: "Voice calls and meetings are not turned on."} =
             item_in(items, "stays_here")
  end

  test "a home over one S3 upload warns where the server keeps snapshots in S3", ctx do
    s3 = %{ctx.candidate | snapshots: %{"s3_bucket" => "invented-bucket", "s3_region" => "eu-1"}}
    big = Keyword.put(opts(ctx), :home_bytes, 6 * 1_073_741_824)

    assert %{items: items} = MoveReadiness.report(ctx.home, s3, big)
    assert %{status: :warn, sentence: sentence} = Enum.find(items, &(&1.id == "s3_size"))
    assert sentence =~ "5 GiB"
  end

  # Always On setup §9: under `fermix run` at a terminal a move stops Fermix
  # and nothing starts it again.
  test "Fermix run from a terminal warns that the move stops it", ctx do
    terminal = Keyword.put(opts(ctx), :restarts_itself, false)

    assert %{items: items} = report = MoveReadiness.report(ctx.home, ctx.candidate, terminal)
    refute Enum.any?(MoveReadiness.blocks(report), &(&1 =~ "terminal"))

    assert item_in(items, "service") == %{
             id: "service",
             status: :warn,
             sentence:
               "Fermix runs from a terminal here, so it stops when the move starts. Start it " <>
                 "again to finish."
           }

    assert %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, opts(ctx))
    assert %{status: :ok} = item_in(items, "service")
  end

  # What Move now's confirm is built from before the owner presses it: the
  # items that read the settings alone, as the full review gives them.
  test "the items that read the settings alone are the review's, in its order", ctx do
    report = MoveReadiness.report(ctx.home, ctx.candidate, opts(ctx))

    for restarts? <- [true, false] do
      seams = Keyword.put(opts(ctx), :restarts_itself, restarts?)
      items = settings_items(ctx, seams)

      assert Enum.map(items, & &1.id) ==
               ~w(stays_here whatsapp slack coding_agents cutover_gap serves_nothing service)

      full = MoveReadiness.report(ctx.home, ctx.candidate, seams).items
      assert items == Enum.filter(full, &(&1.id in Enum.map(items, fn item -> item.id end)))
    end

    assert Enum.take(report.items, -7) == settings_items(ctx, opts(ctx))
  end

  test "the items that read the settings alone say an unreadable file", ctx do
    SafeRm.rm!(Path.join(ctx.home, "config.toml"))
    File.mkdir!(Path.join(ctx.home, "config.toml"))
    seams = opts(ctx) ++ [unreadable_files: nil]

    {items, log} =
      ExUnit.CaptureLog.with_log(fn ->
        settings_items(ctx, seams)
      end)

    assert log =~ "could not be read"

    for id <- ~w(stays_here whatsapp slack coding_agents) do
      assert item_in(items, id) == %{
               id: id,
               status: :warn,
               sentence: "The settings file could not be read; Fermix's log says why."
             }
    end
  end

  test "the report as the wire carries it" do
    report = %{ready: false, items: [%{id: "disk", status: :block, sentence: "No room."}]}

    assert MoveReadiness.view(report) == %{
             "ready" => false,
             "items" => [%{"id" => "disk", "status" => "block", "sentence" => "No room."}]
           }
  end

  # A secret no settings row shows is counted, never named by its id, and a
  # keychain item of no setting Fermix knows is said without its key.
  test "a secret with no settings label is counted, and an unknown item is not named", ctx do
    File.write!(Path.join(ctx.home, "config.toml"), """
    [fermix_core]
    profile = "#{ctx.profile}"

    [fermix_core.providers.anthropic]
    api_key = "@keyring"

    [fermix_core.providers.openai]
    api_key = "@keyring"
    """)

    unlabelled = Keyword.put(opts(ctx), :secret_names, %{"anthropic_api_key" => "Anthropic key"})
    %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, unlabelled)

    assert item_in(items, "keychain_secrets").sentence ==
             "The keychain did not give Fermix your Anthropic key and 1 other secret: unlock " <>
               "it, or set them again or clear them in settings, then check again."

    File.write!(Path.join(ctx.home, "config.toml"), """
    [invented.section]
    token = "@keyring"
    """)

    %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, opts(ctx))

    assert item_in(items, "keychain_secrets").sentence ==
             "Fermix cannot tell which setting a keychain item belongs to: set it again in " <>
               "settings, then check again."
  end

  # Always On setup §3.1: Move now's confirm is built at `ready` from the
  # items that need neither the keychain nor a walk of the home, which the
  # summary reads on every `home.status`; they are the review's own, so the
  # full review at the press names them in the same words.
  describe "the items the summary reads" do
    test "are the review's last items, in its order and its words", ctx do
      %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, opts(ctx))
      settings = MoveReadiness.settings(ctx.home, unreadable_files: nil)
      summary = MoveReadiness.summary_items(settings, true, "north-box", opts(ctx))

      assert Enum.map(summary, & &1.id) ==
               ~w(stays_here whatsapp slack coding_agents cutover_gap serves_nothing service)

      assert Enum.take(items, -length(summary)) == summary
    end

    test "read settings that cannot be read as the review does", ctx do
      File.write!(Path.join(ctx.home, "config.toml"), "not = [toml")
      File.chmod!(Path.join(ctx.home, "config.toml"), 0o000)
      on_exit(fn -> File.chmod(Path.join(ctx.home, "config.toml"), 0o600) end)

      assert {:error, sentence} = MoveReadiness.settings(ctx.home, unreadable_files: nil)
      items = MoveReadiness.summary_items({:error, sentence}, false, "north-box", opts(ctx))

      assert %{status: :warn, sentence: ^sentence} = item_in(items, "whatsapp")
      assert %{status: :warn} = item_in(items, "serves_nothing")
    end
  end

  defp opts(ctx),
    do: [
      free_bytes: fn _dir -> {:ok, @plenty} end,
      version: "0.16.9",
      host: "macos-aarch64",
      index_opts: [seed_path: ctx.index],
      restarts_itself: true
    ]

  defp item_in(items, id), do: Enum.find(items, &(&1.id == id))

  # The items Move now's confirm is built from, read as the summary reads them.
  defp settings_items(ctx, seams) do
    settings = MoveReadiness.settings(ctx.home, seams)
    MoveReadiness.summary_items(settings, true, ctx.candidate.name, seams)
  end

  defp catalog_entry(name, version, targets) do
    %{
      "name" => name,
      "latest" => version,
      "versions" => [
        %{
          "version" => version,
          "artifacts" =>
            for target <- targets do
              %{
                "target" => target,
                "url" => "https://example.com/#{name}-#{target}.tar.gz",
                "sha256" => String.duplicate("0", 64),
                "sig_url" => "https://example.com/#{name}-#{target}.sig",
                "cert_url" => "https://example.com/#{name}-#{target}.pem"
              }
            end
        }
      ]
    }
  end

  defp candidate_attrs do
    %{
      name: "north-box",
      os: "linux",
      arch: "aarch64",
      version: "0.17.0",
      node_id: String.duplicate("ab", 32),
      relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
      noise_pk: :binary.copy(<<1>>, 32),
      recipient: :binary.copy(<<2>>, 32),
      snapshots: nil
    }
  end
end
