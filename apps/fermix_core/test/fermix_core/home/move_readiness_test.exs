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
             {"serves_nothing", :warn}
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

    assert sentence.("stays_here") =~ "iMessage"

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

    assert secrets =~ "anthropic_api_key"
    assert version =~ "north-box runs an older Fermix"
    assert disk =~ "make room first"
  end

  test "a home over one S3 upload warns where the server keeps snapshots in S3", ctx do
    s3 = %{ctx.candidate | snapshots: %{"s3_bucket" => "invented-bucket", "s3_region" => "eu-1"}}
    big = Keyword.put(opts(ctx), :home_bytes, 6 * 1_073_741_824)

    assert %{items: items} = MoveReadiness.report(ctx.home, s3, big)
    assert %{status: :warn, sentence: sentence} = Enum.find(items, &(&1.id == "s3_size"))
    assert sentence =~ "5 GiB"
  end

  test "the report as the wire carries it" do
    report = %{ready: false, items: [%{id: "disk", status: :block, sentence: "No room."}]}

    assert MoveReadiness.view(report) == %{
             "ready" => false,
             "items" => [%{"id" => "disk", "status" => "block", "sentence" => "No room."}]
           }
  end

  defp opts(ctx),
    do: [
      free_bytes: fn _dir -> {:ok, @plenty} end,
      version: "0.16.9",
      host: "macos-aarch64",
      index_opts: [seed_path: ctx.index]
    ]

  defp item_in(items, id), do: Enum.find(items, &(&1.id == id))

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
