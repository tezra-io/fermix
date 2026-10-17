defmodule FermixChannels.X.AssignmentTest do
  # priv/connect/PROTOCOL.md §4: every check, in the contract's order, with
  # tokens signed by hand by a stand-in Connect key.
  use ExUnit.Case, async: true

  alias FermixChannels.Test.XConnectHelper, as: Fixtures
  alias FermixChannels.X.Assignment

  @now ~U[2026-10-16 05:05:00Z]

  setup do
    {public, seed} = Fixtures.connect_key()
    %{seed: seed, record: Fixtures.record(public)}
  end

  defp verify(payload, %{seed: seed, record: record}, opts \\ []) do
    payload |> Fixtures.sign(seed) |> Assignment.verify(record, @now, opts)
  end

  test "the §4 example verifies once signed, into its claims", ctx do
    assert {:ok, %Assignment{} = assignment} = verify(Fixtures.payload(), ctx)

    assert assignment.assignment_id == "as_01j9x3k2m4n5p6q7"
    assert assignment.requester_x_user_id == "1234567890"
    assert assignment.tenant_generation == 1
    assert assignment.expires_at == ~U[2026-10-16 05:15:00Z]

    assert [%{role: :parent, author_handle: "@alice", missing?: false}, %{role: :invoking}] =
             assignment.context.posts

    refute assignment.context.truncated
  end

  test "the example's digest is the contract's own" do
    # protocol.schema.json fixtures name this digest for "@FermixAI explain this".
    assert Fixtures.sha256_hex("@FermixAI explain this") ==
             "1ff2bfe8ccb22764ffd39f1f4e302432b09d917efafc886ccb4e71299c43da53"
  end

  test "a post that could not be read is kept, marked missing", ctx do
    posts = [
      %{"id" => "1844999999999999980", "role" => "quoted", "missing" => true}
      | Fixtures.payload()["context"]["posts"]
    ]

    payload = Fixtures.payload(%{"context" => %{"posts" => posts, "truncated" => true}})

    assert {:ok, assignment} = verify(payload, ctx)
    assert [%{role: :quoted, missing?: true, text: nil} | _rest] = assignment.context.posts
    assert assignment.context.truncated
  end

  describe "1. the token decodes and names the record's key" do
    test "garbage, two segments and a non-JSON header are malformed", ctx do
      for jws <- ["garbage", "a.b", "bm90IGpzb24.e30.c2ln", "a.b.c.d"] do
        assert {:error, :malformed} = Assignment.verify(jws, ctx.record, @now)
      end
    end

    test "another kid is bad_signature, even when the key would verify", ctx do
      jws = Fixtures.sign(Fixtures.payload(), ctx.seed, %{"alg" => "EdDSA", "kid" => "c2027b"})
      assert {:error, :bad_signature} = Assignment.verify(jws, ctx.record, @now)
    end
  end

  describe "2. the signature verifies with the pinned algorithm" do
    test "another key's signature is bad_signature", ctx do
      {_public, other_seed} = Fixtures.connect_key()
      jws = Fixtures.sign(Fixtures.payload(), other_seed)
      assert {:error, :bad_signature} = Assignment.verify(jws, ctx.record, @now)
    end

    test "an algorithm the token names for itself is not believed", ctx do
      jws = Fixtures.sign(Fixtures.payload(), ctx.seed, %{"alg" => "HS256", "kid" => "c2026a"})
      assert {:error, :bad_signature} = Assignment.verify(jws, ctx.record, @now)

      jws = Fixtures.sign(Fixtures.payload(), ctx.seed, %{"alg" => "none", "kid" => "c2026a"})
      assert {:error, :bad_signature} = Assignment.verify(jws, ctx.record, @now)
    end

    test "a signature checks before any claim: a bad one over a wrong instance is bad_signature",
         ctx do
      {_public, other_seed} = Fixtures.connect_key()
      jws = Fixtures.sign(Fixtures.payload(%{"instance_id" => "ins_other"}), other_seed)
      assert {:error, :bad_signature} = Assignment.verify(jws, ctx.record, @now)
    end
  end

  describe "3. protocol version and shape" do
    test "another protocol version is malformed", ctx do
      assert {:error, :malformed} = verify(Fixtures.payload(%{"protocol_version" => 2}), ctx)
    end

    test "a missing or ill-typed claim is malformed", ctx do
      assert {:error, :malformed} = verify(Map.delete(Fixtures.payload(), "conversation_id"), ctx)
      assert {:error, :malformed} = verify(Fixtures.payload(%{"tenant_generation" => "1"}), ctx)
      assert {:error, :malformed} = verify(Fixtures.payload(%{"request_text" => ""}), ctx)

      assert {:error, :malformed} =
               verify(Fixtures.payload(%{"expires_at" => "2026-10-16T05:15:00+01:00"}), ctx)
    end

    test "a post without its text and author, or with both text and missing, is malformed",
         ctx do
      bare = %{"id" => "1844999999999999990", "role" => "parent", "text" => "no author"}

      both = %{
        "id" => "1844999999999999990",
        "role" => "parent",
        "text" => "x",
        "missing" => true
      }

      role = %{"id" => "1844999999999999990", "role" => "sibling", "missing" => true}

      for post <- [bare, both, role] do
        payload = Fixtures.payload(%{"context" => %{"posts" => [post], "truncated" => false}})
        assert {:error, :malformed} = verify(payload, ctx)
      end
    end

    test "a wrong version wins over a wrong instance", ctx do
      payload = Fixtures.payload(%{"protocol_version" => 2, "instance_id" => "ins_other"})
      assert {:error, :malformed} = verify(payload, ctx)
    end
  end

  describe "4. bound to this pairing" do
    test "a correctly signed assignment for another instance is wrong_instance", ctx do
      assert {:error, :wrong_instance} =
               verify(Fixtures.payload(%{"instance_id" => "ins_other"}), ctx)

      assert {:error, :wrong_instance} = verify(Fixtures.payload(%{"tenant_id" => "999"}), ctx)
    end

    test "another generation is stale_generation", ctx do
      assert {:error, :stale_generation} =
               verify(Fixtures.payload(%{"tenant_generation" => 2}), ctx)

      assert {:error, :stale_generation} = verify(Fixtures.payload(%{"key_generation" => 2}), ctx)
    end

    test "the instance is checked before the clock", ctx do
      payload =
        Fixtures.payload(%{"instance_id" => "ins_other", "expires_at" => "2026-10-16T05:00:00Z"})

      assert {:error, :wrong_instance} = verify(payload, ctx)
    end
  end

  describe "5. the validity window" do
    test "an expires_at that is not in the future is expired", ctx do
      assert {:error, :expired} =
               verify(Fixtures.payload(%{"expires_at" => "2026-10-16T05:05:00Z"}), ctx)
    end

    test "an issued_at more than 60 seconds ahead of the clock is expired", ctx do
      assert {:ok, _assignment} =
               verify(Fixtures.payload(%{"issued_at" => "2026-10-16T05:06:00Z"}), ctx)

      assert {:error, :expired} =
               verify(Fixtures.payload(%{"issued_at" => "2026-10-16T05:06:01Z"}), ctx)
    end

    test "the clock is checked before the digest", ctx do
      payload =
        Fixtures.payload(%{
          "expires_at" => "2026-10-16T05:00:00Z",
          "request_sha256" => String.duplicate("0", 64)
        })

      assert {:error, :expired} = verify(payload, ctx)
    end
  end

  describe "6. the request digest" do
    test "a digest of other text is malformed", ctx do
      payload = Fixtures.payload(%{"request_sha256" => Fixtures.sha256_hex("other text")})
      assert {:error, :malformed} = verify(payload, ctx)
    end

    test "the digest is checked before the caps", ctx do
      posts = List.duplicate(hd(Fixtures.payload()["context"]["posts"]), 9)

      payload =
        Fixtures.payload(%{
          "request_sha256" => Fixtures.sha256_hex("other text"),
          "context" => %{"posts" => posts, "truncated" => false}
        })

      assert {:error, :malformed} = verify(payload, ctx)
    end
  end

  describe "7. the caps" do
    test "nine posts are over_cap; eight are not", ctx do
      post = hd(Fixtures.payload()["context"]["posts"])

      eight =
        Fixtures.payload(%{
          "context" => %{"posts" => List.duplicate(post, 8), "truncated" => false}
        })

      nine =
        Fixtures.payload(%{
          "context" => %{"posts" => List.duplicate(post, 9), "truncated" => false}
        })

      assert {:ok, _assignment} = verify(eight, ctx)
      assert {:error, :over_cap} = verify(nine, ctx)
    end

    test "more than 12,000 characters of post text is over_cap", ctx do
      post = hd(Fixtures.payload()["context"]["posts"])
      long = %{post | "text" => String.duplicate("é", 6_001)}
      payload = Fixtures.payload(%{"context" => %{"posts" => [long, long], "truncated" => true}})

      assert {:error, :over_cap} = verify(payload, ctx)
    end

    test "a token over the session's max_assignment_bytes is over_cap", ctx do
      jws = Fixtures.sign(Fixtures.payload(), ctx.seed)

      assert {:ok, _assignment} =
               Assignment.verify(jws, ctx.record, @now, max_bytes: byte_size(jws))

      assert {:error, :over_cap} =
               Assignment.verify(jws, ctx.record, @now, max_bytes: byte_size(jws) - 1)
    end
  end

  test "peek_id names the claimed id of an unverified token, and nothing else", ctx do
    {_public, other_seed} = Fixtures.connect_key()

    assert {:ok, "as_01j9x3k2m4n5p6q7"} =
             Assignment.peek_id(Fixtures.sign(Fixtures.payload(), other_seed))

    assert :error = Assignment.peek_id("garbage")

    unnamed = Fixtures.sign(Map.delete(Fixtures.payload(), "assignment_id"), ctx.seed)
    assert :error = Assignment.peek_id(unnamed)
  end

  test "claims re-reads a stored token with no signature or clock check", ctx do
    jws = Fixtures.sign(Fixtures.payload(%{"expires_at" => "2026-10-16T05:01:00Z"}), ctx.seed)

    assert {:error, :expired} = Assignment.verify(jws, ctx.record, @now)
    assert {:ok, %Assignment{assignment_id: "as_01j9x3k2m4n5p6q7"}} = Assignment.claims(jws)
    assert {:error, :malformed} = Assignment.claims("garbage")
  end
end
