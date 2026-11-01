defmodule FermixCore.Management.HomeMoveReviewTest do
  # M75: a move reads this computer's keychain once before it runs, in the
  # review the owner is shown (`home.move.readiness`); `home.move.start` soon
  # after it takes that review rather than reading the keychain again, and the
  # move's capture reads it once more to carry the values. The keychain is the
  # stub store under a profile of this test's own, so a value taken out of it
  # after the review shows whether the start read it again.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Candidates
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Move
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Router
  alias FermixCore.Setup.SecretWriter
  alias FermixTestSupport.SafeRm

  @now ~U[2031-05-04 10:00:00Z]
  @primary %{role: :primary, primary: nil}
  @passphrase "invented-lantern-orchard"
  @secret "sk-ant-invented-review"

  setup do
    home = SafeRm.make_tmp_dir!("home_move_review")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    :ok = Epoch.write(home, 4)
    profile = "review-#{System.unique_integer([:positive])}"

    File.write!(Path.join(home, "config.toml"), """
    [fermix_core]
    profile = "#{profile}"

    [fermix_core.providers.anthropic]
    api_key = "@keyring"
    """)

    :ok = SecretWriter.put(:anthropic_api_key, @secret, profile: profile, store: :keyring)
    {:ok, record} = Candidates.add(home, candidate_attrs(), @now)
    test = self()

    seams = [
      home: home,
      config: [],
      scheduler: nil,
      now: @now,
      link_status: fn -> %{primary: nil, desktops: [], enrollment: nil} end,
      free_bytes: fn _dir -> {:ok, 1_099_511_627_776} end,
      version: "0.16.0",
      host: "macos-aarch64",
      restarts_itself: true,
      restart: fn ->
        send(test, :restarted)
        :ok
      end,
      save_recipient: fn _recipient -> {:ok, %{}} end
    ]

    %{home: home, profile: profile, candidate_id: record.candidate_id, seams: seams}
  end

  test "a start right after a ready review takes it, and does not read the keychain again",
       ctx do
    assert {:ok, %{"ready" => true}} = review(ctx, ctx.seams)
    review_file = Path.join(Move.dir(ctx.home), "readiness.json")
    refute File.read!(review_file) =~ @secret
    assert Bitwise.band(File.stat!(review_file).mode, 0o777) == 0o600

    # Gone from the keychain after the review: a start that read it again
    # would refuse, naming it.
    forget_secret(ctx)

    assert {:ok, %{"move_id" => "mv-" <> _id}} = start(ctx, ctx.seams)
    assert_received :restarted
    assert Move.pending?(ctx.home)
    # The start replaced `.move/`, so the review served this one start.
    refute File.exists?(review_file)
  end

  test "with no review, an old one or another candidate's, the start reads the keychain itself",
       ctx do
    forget_secret(ctx)
    assert {:error, :unavailable, %{"sentence" => sentence}} = start(ctx, ctx.seams)
    assert sentence =~ "The keychain did not give Fermix your Anthropic key"

    restore_secret(ctx)
    assert {:ok, %{"ready" => true}} = review(ctx, ctx.seams)
    forget_secret(ctx)
    later = Keyword.put(ctx.seams, :now, DateTime.add(@now, 16 * 60, :second))
    assert {:error, :unavailable, %{"sentence" => sentence}} = start(ctx, later)
    assert sentence =~ "your Anthropic key"

    restore_secret(ctx)
    {:ok, other} = Candidates.add(ctx.home, %{candidate_attrs() | name: "south-box"}, @now)

    assert {:ok, %{"ready" => true}} =
             review(%{ctx | candidate_id: other.candidate_id}, ctx.seams)

    forget_secret(ctx)
    assert {:error, :unavailable, %{"sentence" => sentence}} = start(ctx, ctx.seams)
    assert sentence =~ "your Anthropic key"

    refute_received :restarted
    refute Move.pending?(ctx.home)
  end

  test "a review that blocks is not taken: the start checks again", ctx do
    forget_secret(ctx)
    assert {:ok, %{"ready" => false}} = review(ctx, ctx.seams)
    restore_secret(ctx)

    assert {:ok, %{"move_id" => "mv-" <> _id}} = start(ctx, ctx.seams)
    assert_received :restarted
  end

  defp review(ctx, seams),
    do: route("home.move.readiness", %{"candidate_id" => ctx.candidate_id}, seams)

  defp start(ctx, seams) do
    route(
      "home.move.start",
      %{"candidate_id" => ctx.candidate_id, "recovery_passphrase" => @passphrase},
      seams
    )
  end

  defp route(method, params, seams) do
    Router.route(
      %{method: method, protocol_version: Protocol.protocol_version(), params: params},
      engine_role: @primary,
      operation_opts: [home: seams]
    )
  end

  defp forget_secret(ctx),
    do: :ok = SecretWriter.delete(:anthropic_api_key, profile: ctx.profile, store: :keyring)

  defp restore_secret(ctx),
    do: :ok = SecretWriter.put(:anthropic_api_key, @secret, profile: ctx.profile, store: :keyring)

  defp candidate_attrs do
    %{
      name: "north-box",
      os: "linux",
      arch: "aarch64",
      version: "9.9.9",
      node_id: String.duplicate("ab", 32),
      relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
      noise_pk: :binary.copy(<<1>>, 32),
      recipient: :binary.copy(<<2>>, 32),
      snapshots: nil
    }
  end
end
