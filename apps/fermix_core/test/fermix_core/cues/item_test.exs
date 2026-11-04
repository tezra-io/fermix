defmodule FermixCore.Cues.ItemTest do
  use ExUnit.Case, async: true

  alias FermixCore.Cues.Item

  @now ~U[2026-10-10 12:00:00Z]

  defp fields(overrides \\ %{}) do
    Map.merge(
      %{
        item_id: "evt-1",
        type: "com.example.disk.alert",
        subject: "host:alpha",
        occurred_at: ~U[2026-10-10 11:59:00Z],
        datacontenttype: "application/json",
        data: %{"disk" => "/dev/sda", "free_pct" => 3}
      },
      overrides
    )
  end

  test "builds an item with defaults, a canonical payload and its content hash" do
    assert {:ok, %Item{} = item} = Item.new(fields(), @now)

    assert item.revision == "1"
    assert item.self_caused? == false
    assert item.receipt_only? == false
    assert item.body_hash == nil
    assert item.payload == ~s({"disk":"/dev/sda","free_pct":3})
    assert item.payload_bytes == byte_size(item.payload)
    assert item.content_hash =~ ~r/^[0-9a-f]{64}$/
  end

  test "the content hash leaves out the time and covers the revision and data" do
    {:ok, base} = Item.new(fields(), @now)
    {:ok, later} = Item.new(fields(%{occurred_at: ~U[2026-10-10 11:00:00Z]}), @now)
    {:ok, untimed} = Item.new(fields(%{occurred_at: nil}), @now)
    {:ok, revised} = Item.new(fields(%{revision: "2"}), @now)
    {:ok, changed} = Item.new(fields(%{data: %{"disk" => "/dev/sdb"}}), @now)

    assert later.content_hash == base.content_hash
    assert untimed.content_hash == base.content_hash
    refute revised.content_hash == base.content_hash
    refute changed.content_hash == base.content_hash
  end

  test "an integer JSON cannot carry exactly is invalid" do
    assert {:error, {:invalid, message}} =
             Item.new(fields(%{data: %{"n" => 9_007_199_254_740_992}}), @now)

    assert message =~ "number"
    assert {:ok, _item} = Item.new(fields(%{data: %{"n" => 9_007_199_254_740_991}}), @now)
  end

  test "data over 64 KiB is invalid" do
    big = String.duplicate("a", 70 * 1024)

    assert {:error, {:invalid, message}} = Item.new(fields(%{data: big}), @now)
    assert message =~ "64 KiB"
  end

  test "an item with no id, or data that is not UTF-8 text, is invalid" do
    assert {:error, {:invalid, _message}} = Item.new(Map.delete(fields(), :item_id), @now)
    assert {:error, {:invalid, _message}} = Item.new(fields(%{item_id: ""}), @now)
    assert {:error, {:invalid, _message}} = Item.new(fields(%{data: <<0xFF, 0xFE>>}), @now)
    assert {:error, {:invalid, _message}} = Item.new(fields(%{occurred_at: "yesterday"}), @now)
  end

  test "an item older than the 7-day horizon is stale; an item with no time never is" do
    nine_days = DateTime.add(@now, -9, :day)
    six_days = DateTime.add(@now, -6, :day)

    assert {:error, :stale} = Item.new(fields(%{occurred_at: nine_days}), @now)
    assert {:ok, _item} = Item.new(fields(%{occurred_at: six_days}), @now)
    assert {:ok, _item} = Item.new(fields(%{occurred_at: nil}), @now)
  end

  test "the snapshot keeps type, subject and the title, else the first 280 characters" do
    {:ok, titled} = Item.new(fields(%{title: "Disk almost full"}), @now)

    assert Jason.decode!(titled.snapshot) == %{
             "type" => "com.example.disk.alert",
             "subject" => "host:alpha",
             "text" => "Disk almost full"
           }

    long = String.duplicate("é", 300)
    {:ok, text} = Item.new(fields(%{data: long, datacontenttype: "text/plain"}), @now)
    assert Jason.decode!(text.snapshot)["text"] == String.duplicate("é", 280)

    {:ok, json} = Item.new(fields(), @now)
    assert Jason.decode!(json.snapshot)["text"] == ~s({"disk":"/dev/sda","free_pct":3})
  end

  test "an X post's snapshot text is the post's own words, not its JSON" do
    post = %{
      "author" => %{"id" => "4417", "name" => "Tavi Okonkwo", "username" => "tavi_okonkwo"},
      "author_id" => "4417",
      "created_at" => "2026-10-30T21:14:05.000Z",
      "edit_history_tweet_ids" => ["881902"],
      "id" => "881902",
      "text" => "lumen reset is on its way. enjoy.",
      "url" => "https://x.com/tavi_okonkwo/status/881902"
    }

    {:ok, item} = Item.new(fields(%{type: "x.post", subject: "4417", data: post}), @now)

    assert Jason.decode!(item.snapshot) == %{
             "type" => "x.post",
             "subject" => "4417",
             "text" => "lumen reset is on its way. enjoy."
           }

    long = %{"id" => "881903", "text" => String.duplicate("é", 300)}
    {:ok, long_post} = Item.new(fields(%{data: long}), @now)
    assert Jason.decode!(long_post.snapshot)["text"] == String.duplicate("é", 280)
  end

  test "data whose text field is missing, blank or not a string keeps the payload's start" do
    for data <- [%{"body" => "hi"}, %{"text" => "  "}, %{"text" => 3}, [%{"text" => "a"}]] do
      {:ok, item} = Item.new(fields(%{data: data}), @now)
      assert Jason.decode!(item.snapshot)["text"] == String.slice(item.payload, 0, 280)
    end
  end

  test "flags and the webhook body hash are kept" do
    {:ok, item} =
      Item.new(fields(%{self_caused?: true, receipt_only?: true, body_hash: "abc123"}), @now)

    assert item.self_caused?
    assert item.receipt_only?
    assert item.body_hash == "abc123"
  end

  test "an unknown field is a programming error" do
    assert_raise ArgumentError, ~r/unknown/, fn -> Item.new(fields(%{priority: 1}), @now) end
  end
end
