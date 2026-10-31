defmodule FermixCore.Home.MoveReadinessTest do
  # Every fact comes from the home on disk and seams: the free space, this
  # engine's version and host. The keychain is the stub store, under a
  # profile of this test's own.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Candidates
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.MoveReadiness
  alias FermixCore.Setup.SecretWriter
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
    """)

    File.mkdir_p!(Path.join(home, "plugins"))
    File.write!(Path.join(home, "plugins/installed.json"), ~s({"invented-notes": {}}))
    {:ok, candidate} = Candidates.add(home, candidate_attrs(), @now)
    %{home: home, candidate: candidate, profile: profile}
  end

  test "a ready move: the keychain's secret can be read, and every warning is said", ctx do
    :ok =
      SecretWriter.put(:anthropic_api_key, "sk-ant-invented",
        profile: ctx.profile,
        store: :keyring
      )

    assert %{ready: true, items: items} = MoveReadiness.report(ctx.home, ctx.candidate, opts())

    assert Enum.map(items, &{&1.id, &1.status}) == [
             {"keychain_secrets", :ok},
             {"engine_version", :ok},
             {"disk", :ok},
             {"s3_size", :ok},
             {"plugins", :warn},
             {"stays_here", :warn},
             {"cutover_gap", :warn},
             {"serves_nothing", :warn}
           ]

    sentence = fn id -> Enum.find(items, &(&1.id == id)).sentence end
    assert sentence.("keychain_secrets") =~ "1 secret kept in this computer's keychain moves"
    # Reading it can raise the keychain's own prompt, here and once more when
    # the move carries it.
    assert sentence.("keychain_secrets") =~
             "Checking it opened this computer's keychain, and the move opens it once more"

    assert sentence.("plugins") =~ "invented-notes"
    assert sentence.("stays_here") =~ "iMessage"
    # Telegram keeps what it holds until the poller asks again.
    assert sentence.("cutover_gap") =~ "Telegram while the move runs wait until it is done"
    refute sentence.("cutover_gap") =~ "lost"
    assert sentence.("serves_nothing") =~ "north-box"
    refute Enum.any?(items, &(&1.sentence =~ "sk-ant-invented"))
  end

  test "blocks: an unreadable secret named, an older server, a disk with no room", ctx do
    old = %{ctx.candidate | version: "0.0.1"}
    tight = Keyword.put(opts(), :free_bytes, fn _dir -> {:ok, 1_000} end)

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
    big = Keyword.put(opts(), :home_bytes, 6 * 1_073_741_824)

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

  defp opts,
    do: [
      free_bytes: fn _dir -> {:ok, @plenty} end,
      version: "0.16.9",
      host: "macos-aarch64"
    ]

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
