defmodule FermixCore.Cues.JetstreamTest do
  use ExUnit.Case, async: true

  alias FermixCore.Cues.Item
  alias FermixCore.Cues.Jetstream
  alias FermixCore.Cues.Presets

  @fixtures Path.join([__DIR__, "..", "..", "fixtures", "cues", "jetstream"])
  @author "did:plc:k4tmw2qzr7bnvx3e5hjy6dfa"
  @friend "did:plc:p2nrd7wq4fxk6jzv3mbt5hce"
  @followed MapSet.new([@author, @friend])

  defp frame(name), do: @fixtures |> Path.join(name) |> File.read!() |> String.trim_trailing()

  defp time_us(datetime), do: DateTime.to_unix(datetime, :microsecond)

  describe "subscribe_url/4" do
    test "puts the subscription and a timestamp cursor in the query of the v2 endpoint" do
      cursor = time_us(~U[2026-10-12 13:58:27.481920Z])

      assert Jetstream.subscribe_url(
               "wss://jetstream.us-east.bsky.network",
               [@author, @friend],
               ["app.bsky.feed.post", "app.bsky.feed.*"],
               cursor
             ) ==
               "wss://jetstream.us-east.bsky.network/xrpc/network.bsky.jetstream.subscribeEvents" <>
                 "?kinds=commit" <>
                 "&dids=did%3Aplc%3Ak4tmw2qzr7bnvx3e5hjy6dfa&dids=did%3Aplc%3Ap2nrd7wq4fxk6jzv3mbt5hce" <>
                 "&collections=app.bsky.feed.post&collections=app.bsky.feed.%2A" <>
                 "&cursor=#{cursor}"
    end

    test "starts at the live tip without a cursor and ignores a trailing slash" do
      assert Jetstream.subscribe_url(
               Jetstream.default_base_url() <> "/",
               [@author],
               Jetstream.default_collections(),
               nil
             ) ==
               "wss://jetstream.us-east.bsky.network/xrpc/network.bsky.jetstream.subscribeEvents" <>
                 "?kinds=commit&dids=did%3Aplc%3Ak4tmw2qzr7bnvx3e5hjy6dfa&collections=app.bsky.feed.post"
    end

    test "plain ws is allowed only on loopback" do
      assert "ws://127.0.0.1:6008/xrpc/" <> _rest =
               Jetstream.subscribe_url(
                 "ws://127.0.0.1:6008",
                 [@author],
                 ["app.bsky.feed.post"],
                 nil
               )

      assert_raise ArgumentError, fn ->
        Jetstream.subscribe_url(
          "ws://jetstream.example.org",
          [@author],
          ["app.bsky.feed.post"],
          nil
        )
      end
    end

    test "refuses what would make a wrong or unbounded subscription" do
      collections = ["app.bsky.feed.post"]

      # No accounts: the stream would carry the whole network.
      assert_raise ArgumentError, "a Bluesky stream needs dids, the accounts to follow", fn ->
        Jetstream.subscribe_url(Jetstream.default_base_url(), [], collections, nil)
      end

      # A value below 1e15 is a sequence number to Jetstream, not a time.
      assert_raise FunctionClauseError, fn ->
        Jetstream.subscribe_url(Jetstream.default_base_url(), [@author], collections, 48_210_375)
      end

      for base <- [
            "https://jetstream.us-east.bsky.network",
            "wss://jetstream.us-east.bsky.network/subscribe",
            "wss://"
          ] do
        assert_raise ArgumentError, fn ->
          Jetstream.subscribe_url(base, [@author], collections, nil)
        end
      end

      assert_raise ArgumentError, fn ->
        Jetstream.subscribe_url(Jetstream.default_base_url(), ["alice"], collections, nil)
      end

      assert_raise ArgumentError, fn ->
        Jetstream.subscribe_url(Jetstream.default_base_url(), [@author], ["app bsky"], nil)
      end
    end
  end

  describe "check_subscription/2" do
    test "names what is wrong in a sentence for the owner" do
      posts = ["app.bsky.feed.post"]

      assert Jetstream.check_subscription([@author], posts) == :ok

      assert Jetstream.check_subscription([], posts) ==
               {:error, "a Bluesky stream needs dids, the accounts to follow"}

      assert Jetstream.check_subscription([@author], []) ==
               {:error, "a Bluesky stream needs at least one collection"}

      assert Jetstream.check_subscription(["@tamsin"], posts) ==
               {:error, ~s("@tamsin" is not a DID)}

      assert Jetstream.check_subscription([@author], ["posts"]) ==
               {:error, ~s("posts" is not a collection)}

      too_many = Enum.map(1..10_001, &"did:plc:#{&1}")

      assert Jetstream.check_subscription(too_many, posts) ==
               {:error, "a Bluesky stream follows at most 10000 accounts"}
    end
  end

  describe "the bluesky_jetstream preset" do
    test "fills a stream on the v2 host that follows posts by default" do
      assert {:ok, filled} = Presets.fill(%{preset: "bluesky_jetstream", dids: [@author]})

      assert filled == %{
               preset: "bluesky_jetstream",
               kind: :stream,
               url: "wss://jetstream.us-east.bsky.network",
               dids: [@author],
               collections: ["app.bsky.feed.post"]
             }
    end

    test "collections the owner writes win" do
      likes = ["app.bsky.feed.like"]

      assert {:ok, %{collections: ^likes}} =
               Presets.fill(%{preset: "bluesky_jetstream", dids: [@author], collections: likes})
    end
  end

  describe "decode/2" do
    test "a create commit by a followed account is an item" do
      created_at = ~U[2026-10-12 14:03:27.481920Z]
      record = frame("commit_create.json") |> Jason.decode!() |> get_in(["payload", "record"])

      assert Jetstream.decode(frame("commit_create.json"), @followed) ==
               {:item,
                %{
                  item_id:
                    "at://did:plc:k4tmw2qzr7bnvx3e5hjy6dfa/app.bsky.feed.post/3m4qzx7jy5k2b",
                  revision: "1",
                  type: "app.bsky.feed.post",
                  subject: @author,
                  occurred_at: created_at,
                  datacontenttype: "application/json",
                  data: record,
                  title: "Shipping the tide-table importer today"
                }, time_us(created_at)}

      assert record["reply"]["parent"]["uri"] =~ "at://"
      assert record["langs"] == ["en"]
    end

    test "an item is Cues.Item.new/2 input" do
      assert {:item, fields, _time_us} = Jetstream.decode(frame("commit_create.json"), @followed)

      assert {:ok, %Item{subject: @author, type: "app.bsky.feed.post"}} =
               Item.new(fields, ~U[2026-10-12 15:00:00Z])
    end

    test "updates, deletes, identity and account events are skipped with their time" do
      assert Jetstream.decode(frame("commit_update.json"), @followed) ==
               {:skip, :update, time_us(~U[2026-10-12 14:05:01.000417Z])}

      assert Jetstream.decode(frame("commit_delete.json"), @followed) ==
               {:skip, :delete, time_us(~U[2026-10-12 14:06:44.123456Z])}

      assert Jetstream.decode(frame("identity.json"), @followed) ==
               {:skip, :identity, time_us(~U[2026-10-12 14:07:10.500000Z])}

      assert Jetstream.decode(frame("account.json"), @followed) ==
               {:skip, :account, time_us(~U[2026-10-12 14:08:00.000001Z])}
    end

    test "a post by an account outside the followed list is not accepted" do
      assert Jetstream.decode(frame("not_followed.json"), @followed) ==
               {:skip, :not_followed, time_us(~U[2026-10-12 14:09:30.250000Z])}
    end

    test "an info frame is skipped by name and carries no time" do
      assert Jetstream.decode(frame("info_outdated_cursor.json"), @followed) ==
               {:skip, {:info, "OutdatedCursor"}, nil}
    end

    test "an error frame is the server's terminal error" do
      assert Jetstream.decode(frame("error_consumer_too_slow.json"), @followed) ==
               {:error, {:stream_error, "ConsumerTooSlow"}}
    end

    test "a frame over 128 KiB is refused; one of exactly 128 KiB is read" do
      template = frame("commit_create.json")
      pad = 128 * 1024 - byte_size(template) + byte_size("Shipping")
      exact = String.replace(template, "Shipping", String.duplicate("s", pad))

      assert byte_size(exact) == 128 * 1024
      assert {:item, _fields, _time_us} = Jetstream.decode(exact, @followed)
      assert Jetstream.decode(exact <> " ", @followed) == {:error, :frame_too_large}
    end

    test "malformed and foreign frames are errors" do
      assert Jetstream.decode(~s({"$type": "message", ), @followed) == {:error, :invalid_json}
      assert Jetstream.decode("[1, 2]", @followed) == {:error, :invalid_frame}
      # A legacy v1 frame is not the stream this preset subscribes to.
      assert Jetstream.decode(frame("v1_commit.json"), @followed) == {:error, :invalid_frame}

      payload = frame("commit_create.json") |> Jason.decode!()

      for broken <- [
            update_in(payload, ["payload"], &Map.delete(&1, "time")),
            update_in(payload, ["payload"], &Map.delete(&1, "record")),
            put_in(payload, ["payload", "rkey"], "../escape"),
            put_in(payload, ["payload", "did"], "not-a-did")
          ] do
        assert Jetstream.decode(Jason.encode!(broken), @followed) == {:error, :invalid_frame}
      end
    end

    test "a post with no text has no title" do
      payload =
        frame("commit_create.json")
        |> Jason.decode!()
        |> update_in(["payload", "record"], &Map.delete(&1, "text"))

      assert {:item, %{title: nil}, _time_us} =
               Jetstream.decode(Jason.encode!(payload), @followed)
    end
  end
end
