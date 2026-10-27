defmodule FermixCore.Cues.FeedParserTest do
  use ExUnit.Case, async: true

  alias FermixCore.Cues.FeedParser
  alias FermixCore.Cues.Item

  @fixtures Path.join([__DIR__, "..", "..", "fixtures", "cues"])
  @xxe_marker "XXE-MARKER-9F2C-READ"

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  defp xxe_payload(template) do
    target = @fixtures |> Path.join("xxe_target.txt") |> Path.expand()
    template |> fixture() |> String.replace("__TARGET__", target)
  end

  defp rss_with_items(count), do: rss_items(Enum.to_list(1..count))

  # Item n is published n hours before the base, listed in the order given.
  defp rss_items(indexes) do
    base = ~U[2026-10-14 12:00:00Z]

    items =
      Enum.map(indexes, fn index ->
        published = base |> DateTime.add(-index * 3600, :second) |> rfc822()

        """
        <item><title>Entry #{index}</title><link>https://bulk.example.org/#{index}</link>\
        <guid>item-#{index}</guid><pubDate>#{published}</pubDate></item>
        """
      end)

    ~s(<?xml version="1.0"?><rss version="2.0"><channel><title>Bulk</title>#{items}</channel></rss>)
  end

  defp rfc822(datetime), do: Calendar.strftime(datetime, "%a, %d %b %Y %H:%M:%S GMT")

  # A podcast's whole archive, newest first: episode n published n days before
  # `now`, each with about 2 KB of show notes.
  defp podcast(count, now) do
    notes = String.duplicate("Guests talk about tides, maps and long walks. ", 44)

    items =
      Enum.map(1..count, fn n ->
        published = now |> DateTime.add(-n, :day) |> rfc822()

        "<item><title>Episode #{n}</title><guid isPermaLink=\"false\">episode-#{n}</guid>" <>
          "<pubDate>#{published}</pubDate><description><![CDATA[<p>#{notes}</p>]]></description>" <>
          "<content:encoded><![CDATA[<p>#{notes}</p>]]></content:encoded></item>"
      end)

    ~s(<?xml version="1.0" encoding="UTF-8"?><rss version="2.0" ) <>
      ~s(xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel>) <>
      "<title>Harbour Hours</title>#{items}</channel></rss>"
  end

  # The reader given `body` in pieces of `size` bytes, as a download arrives.
  defp read_in_pieces(body, size, content_type, opts \\ []) do
    {:ok, reader} = FeedParser.reader(content_type, opts)

    pieces =
      for offset <- 0..(byte_size(body) - 1)//size,
          do: binary_part(body, offset, min(size, byte_size(body) - offset))

    result =
      Enum.reduce_while(pieces, {:ok, reader}, fn piece, {:ok, reader} ->
        case FeedParser.read(reader, piece) do
          {:ok, reader} -> {:cont, {:ok, reader}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    with {:ok, reader} <- result, do: FeedParser.finish(reader)
  end

  describe "parse/3 with RSS 2.0" do
    test "turns each item into cue fields in the feed's order" do
      assert {:ok, [first, second, third], %{truncation: :complete}} =
               FeedParser.parse(fixture("rss.xml"), "application/rss+xml; charset=utf-8")

      assert first == %{
               item_id: "larkspur-release-4.2",
               revision: "1",
               type: "feed.item",
               subject: nil,
               occurred_at: ~U[2026-10-12 14:03:27Z],
               datacontenttype: "application/json",
               title: "Larkspur 4.2 & the new importer",
               data: %{
                 "title" => "Larkspur 4.2 & the new importer",
                 "link" => "https://releases.example.org/posts/larkspur-4-2",
                 "summary" => "The importer now reads three formats. Upgrade today — it’s free.",
                 "author" => "Tamsin Okoro",
                 "categories" => ["releases", "importer"]
               }
             }

      assert second.item_id == "https://releases.example.org/posts/larkspur-4-1-3"
      assert second.occurred_at == ~U[2026-10-09 13:15:00Z]
      assert second.data["author"] == "security@example.org (Ilse Varga)"
      assert second.data["summary"] == "Fixes a path check in the archive reader."
      assert second.data["categories"] == []

      assert third.item_id == "roadmap-2026-q4"
      assert third.occurred_at == nil
      assert third.data["summary"] == "Next Faster sync Offline mode"
      assert third.data["author"] == nil
    end

    test "an item without a guid takes a hash of link, title and time, never the link alone" do
      body = fixture("rss_no_guid.xml")

      assert {:ok, items, %{truncation: :complete}} =
               FeedParser.parse(body, "application/rss+xml")

      ids = Enum.map(items, & &1.item_id)

      assert Enum.all?(ids, &String.starts_with?(&1, "sha256:"))

      refute Enum.any?(
               ids,
               &(&1 in ["https://maps.example.com/canals", "https://maps.example.com/rivers"])
             )

      # Same link: a different title or a different time is a different item.
      assert length(Enum.uniq(ids)) == 4
      # The identity is stable across polls.
      assert {:ok, again, %{truncation: :complete}} =
               FeedParser.parse(body, "application/rss+xml")

      assert Enum.map(again, & &1.item_id) == ids
    end

    test "at most 100 items are kept, the newest; the rest is a gap with its range" do
      assert {:ok, items, %{truncation: {:truncated, truncation}}} =
               FeedParser.parse(rss_with_items(150), nil)

      assert length(items) == 100
      assert Enum.map(items, & &1.item_id) == Enum.map(1..100, &"item-#{&1}")

      assert truncation == %{
               count: 50,
               range_from: ~U[2026-10-08 06:00:00Z],
               range_to: ~U[2026-10-10 07:00:00Z]
             }
    end

    test "exactly 100 items are complete" do
      assert {:ok, items, %{truncation: :complete}} = FeedParser.parse(rss_with_items(100), nil)
      assert length(items) == 100
    end

    test "summaries and titles are plain text with a bounded length" do
      long = String.duplicate("word ", 1_000)

      body = """
      <rss version="2.0"><channel><item><guid>long-1</guid>
      <title>#{String.duplicate("t", 400)}</title>
      <description>&lt;div&gt;#{long}&lt;/div&gt;</description></item></channel></rss>
      """

      assert {:ok, [item], %{truncation: :complete}} = FeedParser.parse(body, nil)
      assert String.length(item.title) == 300
      assert String.length(item.data["summary"]) == 2_000
      refute item.data["summary"] =~ "<"
    end
  end

  describe "parse/3 with Atom 1.0" do
    test "reads id, the alternate link, published-or-updated, authors and text constructs" do
      opts = [base_url: "https://eng.example.com/atom.xml"]

      assert {:ok, [first, second], %{truncation: :complete}} =
               FeedParser.parse(fixture("atom.xml"), "application/atom+xml", opts)

      assert first == %{
               item_id: "tag:eng.example.com,2026:sharding-ledger",
               revision: "1",
               type: "feed.item",
               subject: nil,
               occurred_at: ~U[2026-10-13 07:30:00Z],
               datacontenttype: "application/json",
               title: "Sharding the ledger",
               data: %{
                 "title" => "Sharding the ledger",
                 "link" => "https://eng.example.com/posts/sharding-ledger",
                 "summary" => "How we split ledger across four nodes.",
                 "author" => "Rafael Imbert",
                 "categories" => ["databases", "scaling"]
               }
             }

      assert second.item_id == "tag:eng.example.com,2026:queue-alerts"
      # A plain-text title keeps what looks like markup.
      assert second.title == "Queue depth alerts < 5 minutes"
      assert second.occurred_at == ~U[2026-10-10 16:45:12.250Z]
      assert second.data["link"] == "https://eng.example.com/posts/queue-alerts"
      assert second.data["author"] == "Quillmere Staff"

      assert second.data["summary"] ==
               "Alerts now fire within five minutes. Thresholds are per queue."
    end

    test "a relative link stays as written without a base URL" do
      assert {:ok, [first, _second], %{truncation: :complete}} =
               FeedParser.parse(fixture("atom.xml"), "application/atom+xml")

      assert first.data["link"] == "/posts/sharding-ledger"
    end
  end

  describe "parse/3 with JSON Feed" do
    test "reads JSON Feed 1.1 items" do
      assert {:ok, [first, second, third], %{truncation: :complete}} =
               FeedParser.parse(fixture("feed.json"), "application/feed+json")

      assert first == %{
               item_id: "https://notes.example.net/2026/10/tide-tables",
               revision: "1",
               type: "feed.item",
               subject: nil,
               occurred_at: ~U[2026-10-11 11:20:00Z],
               datacontenttype: "application/json",
               title: "Tide tables, again",
               data: %{
                 "title" => "Tide tables, again",
                 "link" => "https://notes.example.net/2026/10/tide-tables",
                 "summary" => "Why the harbour tables drift every spring.",
                 "author" => "Corin Hale",
                 "categories" => ["harbour", "data"]
               }
             }

      assert second.item_id == "4417"
      assert second.occurred_at == ~U[2026-10-08 18:00:00Z]
      assert second.data["summary"] == "Replaced the wick & the glass."
      assert second.data["author"] == "Odile Fenwick"

      assert "sha256:" <> _hash = third.item_id
      assert third.occurred_at == nil
      assert third.data["summary"] == "Plain text body."
    end

    test "reads a JSON Feed 1.0 author object" do
      body =
        Jason.encode!(%{
          "version" => "https://jsonfeed.org/version/1",
          "items" => [
            %{"id" => "a", "author" => %{"name" => "Wren Talbot"}, "content_text" => "x"}
          ]
        })

      assert {:ok, [item], %{truncation: :complete}} = FeedParser.parse(body, "application/json")
      assert item.data["author"] == "Wren Talbot"
    end
  end

  describe "parse/3 refuses what is not a feed" do
    test "malformed XML is an error" do
      assert {:error, {:invalid_xml, message}} =
               FeedParser.parse(fixture("malformed.xml"), "application/rss+xml")

      assert is_binary(message)
    end

    test "XML past 32 MiB and JSON past 4 MiB are past the read limit, refused before parsing" do
      {:ok, reader} = FeedParser.reader("application/rss+xml")
      {:ok, reader} = FeedParser.read(reader, ~s(<rss version="2.0"><channel>))
      blank = String.duplicate(" ", 32 * 1024 * 1024)
      assert FeedParser.read(reader, blank) == {:error, :read_limit}

      json = "{" <> binary_part(blank, 0, 4 * 1024 * 1024)
      assert FeedParser.parse(json, nil) == {:error, :read_limit}
      paths = %{items_path: "items", id_path: "id"}
      assert FeedParser.parse_json_api(json, paths) == {:error, :read_limit}
    end

    test "a body whose first 64 KiB are blank is not a feed" do
      body = String.duplicate(" ", 65_537) <> fixture("rss.xml")
      assert FeedParser.parse(body, "application/rss+xml") == {:error, :not_a_feed}
    end

    test "a content type that contradicts the body is refused" do
      assert FeedParser.parse(fixture("rss.xml"), "application/json") ==
               {:error, :content_type_mismatch}

      assert FeedParser.parse(fixture("feed.json"), "application/rss+xml") ==
               {:error, :content_type_mismatch}
    end

    test "an unspecific content type lets the body decide" do
      assert {:ok, [_ | _], %{truncation: :complete}} =
               FeedParser.parse(fixture("rss.xml"), "text/html; charset=utf-8")

      assert {:ok, [_ | _], %{truncation: :complete}} =
               FeedParser.parse(fixture("feed.json"), "text/plain")
    end

    test "text that is neither XML nor JSON is not a feed" do
      assert FeedParser.parse("Service unavailable", "text/plain") == {:error, :not_a_feed}
    end

    test "unsupported formats are named" do
      rdf = ~s(<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><item/></rdf:RDF>)

      assert FeedParser.parse(rdf, "application/rdf+xml") ==
               {:error, {:unsupported_feed, "rdf:RDF"}}

      future = Jason.encode!(%{"version" => "https://jsonfeed.org/version/9", "items" => []})

      assert FeedParser.parse(future, nil) ==
               {:error, {:unsupported_feed, "https://jsonfeed.org/version/9"}}
    end

    test "a feed missing its item list is invalid" do
      assert FeedParser.parse(~s(<rss version="2.0"></rss>), nil) == {:error, :invalid_feed}
      assert FeedParser.parse(Jason.encode!(%{"title" => "x"}), nil) == {:error, :invalid_feed}

      not_objects =
        Jason.encode!(%{"version" => "https://jsonfeed.org/version/1.1", "items" => ["x"]})

      assert FeedParser.parse(not_objects, nil) == {:error, :invalid_feed}
    end

    test "a declared encoding other than UTF-8 is refused" do
      body = ~s(<?xml version="1.0" encoding="ISO-8859-1"?><rss version="2.0"><channel/></rss>)
      assert {:error, {:invalid_xml, _message}} = FeedParser.parse(body, nil)
    end

    test "a leading byte-order mark is accepted" do
      assert {:ok, [_, _, _], %{truncation: :complete}} =
               FeedParser.parse(<<0xEF, 0xBB, 0xBF>> <> fixture("rss.xml"), nil)
    end

    test "unknown options and a relative base URL are programming errors" do
      assert_raise ArgumentError, fn -> FeedParser.parse(fixture("rss.xml"), nil, page: 2) end

      assert_raise ArgumentError, fn ->
        FeedParser.parse(fixture("rss.xml"), nil, base_url: "/feed")
      end
    end
  end

  describe "reading a feed as it arrives" do
    test "an archive of 2,770 episodes keeps the ones inside the horizon; its past is no gap" do
      now = ~U[2026-10-25 12:00:00Z]
      body = podcast(2_770, now)
      assert byte_size(body) > 4 * 1024 * 1024
      stale_before = DateTime.add(now, -Item.horizon_days(), :day)

      assert {:ok, items, %{truncation: :complete, skipped: 2_763}} =
               FeedParser.parse(body, "application/rss+xml", stale_before: stale_before)

      assert Enum.map(items, & &1.item_id) == Enum.map(1..7, &"episode-#{&1}")
      assert hd(items).occurred_at == DateTime.add(now, -1, :day)

      # With no horizon it keeps the 100 newest, and the rest is left out.
      assert {:ok, items, %{truncation: {:truncated, %{count: 2_670}}}} =
               FeedParser.parse(body, "application/rss+xml")

      assert Enum.map(items, & &1.item_id) == Enum.map(1..100, &"episode-#{&1}")
    end

    test "a feed listed oldest first keeps its newest items, in the feed's order" do
      assert {:ok, items, %{truncation: {:truncated, truncation}}} =
               FeedParser.parse(rss_items(Enum.to_list(150..1//-1)), nil)

      assert Enum.map(items, & &1.item_id) == Enum.map(100..1//-1, &"item-#{&1}")

      assert truncation == %{
               count: 50,
               range_from: ~U[2026-10-08 06:00:00Z],
               range_to: ~U[2026-10-10 07:00:00Z]
             }
    end

    test "an undated item ranks below every dated one, and its absence counts with no time" do
      undated =
        Enum.map_join(1..3, "", &"<item><title>Note #{&1}</title><guid>note-#{&1}</guid></item>")

      body =
        String.replace(
          rss_with_items(100),
          "<title>Bulk</title>",
          "<title>Bulk</title>" <> undated
        )

      assert {:ok, items,
              %{truncation: {:truncated, %{count: 3, range_from: nil, range_to: nil}}}} =
               FeedParser.parse(body, nil, stale_before: ~U[2026-10-01 00:00:00Z])

      assert Enum.map(items, & &1.item_id) == Enum.map(1..100, &"item-#{&1}")
    end

    test "an item past the horizon is skipped; one inside it that is left out is a gap with its range" do
      stale_before = DateTime.add(~U[2026-10-14 12:00:00Z], -125, :hour)

      assert {:ok, _items, %{truncation: {:truncated, truncation}}} =
               FeedParser.parse(rss_with_items(150), nil, stale_before: stale_before)

      assert truncation == %{
               count: 25,
               range_from: ~U[2026-10-09 07:00:00Z],
               range_to: ~U[2026-10-10 07:00:00Z]
             }
    end

    test "Atom's feed-level author applies though it comes after the entries" do
      body =
        ~s(<feed xmlns="http://www.w3.org/2005/Atom"><title>Tidewater Notes</title>) <>
          "<entry><id>urn:tide:1</id><title>Spring tides</title>" <>
          "<updated>2026-10-20T10:00:00Z</updated></entry>" <>
          "<author><name>Wren Albarran</name></author></feed>"

      assert {:ok, [item], %{truncation: :complete}} =
               FeedParser.parse(body, "application/atom+xml")

      assert item.data["author"] == "Wren Albarran"
    end

    test "a root that is not a feed stops the parse at its start tag" do
      body = "<html><body>" <> String.duplicate("<p>Closed for the season", 50) <> "<<"
      assert FeedParser.parse(body, nil) == {:error, {:unsupported_feed, "html"}}
    end

    test "a long item is read whole, its guid and time after the long text; past 4 MiB it is past the read limit" do
      notes = String.duplicate("Tides turn twice a day. ", 4_500)

      long =
        Enum.map_join(
          ~w(description content:encoded itunes:summary itunes:subtitle),
          "",
          &"<#{&1}><![CDATA[#{notes}]]></#{&1}>"
        )

      item =
        "<item><title>Long notes</title>#{long}<guid>long-notes</guid>" <>
          "<pubDate>Tue, 20 Oct 2026 10:00:00 GMT</pubDate><category>tides</category></item>"

      feed = &~s(<rss version="2.0"><channel><title>Harbour Hours</title>#{&1}</channel></rss>)

      assert {:ok, [read], %{truncation: :complete}} = FeedParser.parse(feed.(item), nil)
      assert read.item_id == "long-notes"
      assert read.occurred_at == ~U[2026-10-20 10:00:00Z]
      assert read.data["categories"] == ["tides"]
      assert String.starts_with?(read.data["summary"], "Tides turn twice a day.")

      huge =
        "<item><guid>huge</guid><description>#{String.duplicate(notes, 40)}</description></item>"

      assert FeedParser.parse(feed.(huge), nil) == {:error, :read_limit}
    end

    test "CDATA and an attribute value longer than 64 KiB read the same in pieces as whole" do
      title = "a" <> String.duplicate("é tides ", 9_000)
      href = "https://notes.example.org/" <> String.duplicate("x", 70_000)

      body =
        ~s(<feed xmlns="http://www.w3.org/2005/Atom"><title>Notes</title>) <>
          ~s(<entry><id>urn:notes:1</id><title type="html"><![CDATA[#{title}]]></title>) <>
          ~s(<link href="#{href}"/><updated>2026-10-20T10:00:00Z</updated></entry></feed>)

      assert {:ok, [item], %{truncation: :complete}} = whole = FeedParser.parse(body, nil)
      assert String.starts_with?(item.title, "aé tides")
      assert read_in_pieces(body, 1_000, nil) == whole
      assert read_in_pieces(body, 7, nil) == whole
    end

    test "elements nested 65 deep are not a feed; 64 deep are" do
      nest = fn depth -> String.duplicate("<x>", depth) <> String.duplicate("</x>", depth) end
      feed = &~s(<rss version="2.0"><channel>#{&1}</channel></rss>)

      assert FeedParser.parse(feed.(nest.(62)), nil) ==
               {:ok, [], %{truncation: :complete, skipped: 0}}

      assert FeedParser.parse(feed.(nest.(63)), nil) == {:error, :invalid_feed}
    end

    test "a body read a byte at a time, splitting characters and the byte-order mark, reads as it does whole" do
      for {name, content_type} <- [
            {"rss.xml", "application/rss+xml"},
            {"atom.xml", "application/atom+xml"},
            {"feed.json", "application/feed+json"}
          ] do
        body = <<0xEF, 0xBB, 0xBF>> <> fixture(name)
        assert read_in_pieces(body, 1, content_type) == FeedParser.parse(body, content_type)
      end
    end

    test "a body that starts with a blank character split across chunks reads as it does whole" do
      body = "\u00A0" <> fixture("rss.xml")
      assert {:error, {:invalid_xml, _message}} = whole = FeedParser.parse(body, nil)
      assert read_in_pieces(body, 1, nil) == whole
    end

    test "entities stay literal and no DTD is read when the body comes a byte at a time" do
      for body <- [
            fixture("billion_laughs.xml"),
            xxe_payload("xxe_entity.xml.template"),
            xxe_payload("xxe_dtd.xml.template")
          ] do
        whole = FeedParser.parse(body, "application/rss+xml")
        assert read_in_pieces(body, 1, "application/rss+xml") == whole
        refute inspect(whole) =~ @xxe_marker
      end
    end
  end

  describe "parse/3 resolves no DTD and no external entity" do
    test "billion laughs: the DTD is skipped and the entity stays literal" do
      assert {:ok, [item], %{truncation: :complete}} =
               FeedParser.parse(fixture("billion_laughs.xml"), "application/rss+xml")

      assert item.title == "&lol9;"
      assert item.data["summary"] == "&lol9;"
    end

    test "an external entity is never read" do
      assert {:ok, [item], %{truncation: :complete}} =
               FeedParser.parse(xxe_payload("xxe_entity.xml.template"), nil)

      assert item.title == "&xxe;"
      assert item.data["summary"] == "before &xxe; after"
      refute inspect(item) =~ @xxe_marker
    end

    test "an external DTD is never fetched" do
      assert {:ok, [item], %{truncation: :complete}} =
               FeedParser.parse(xxe_payload("xxe_dtd.xml.template"), nil)

      assert item.title == "&marker;"
      refute inspect(item) =~ @xxe_marker
    end

    test "element names and JSON keys never become atoms" do
      name = "zqfeed#{System.unique_integer([:positive])}"

      xml =
        ~s(<rss version="2.0"><channel><item><guid>a</guid><#{name}>x</#{name}></item></channel></rss>)

      json =
        Jason.encode!(%{
          "version" => "https://jsonfeed.org/version/1.1",
          "items" => [%{"id" => "a", name => 1}]
        })

      assert {:ok, [_], %{truncation: :complete}} = FeedParser.parse(xml, nil)
      assert {:ok, [_], %{truncation: :complete}} = FeedParser.parse(json, nil)
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end
  end

  describe "fields are Cues.Item.new/2 input" do
    @now ~U[2026-10-14 12:00:00Z]

    test "every item of every fixture format builds an item" do
      sources = [
        {fixture("rss.xml"), "application/rss+xml"},
        {fixture("atom.xml"), "application/atom+xml"},
        {fixture("feed.json"), "application/feed+json"},
        {fixture("rss_no_guid.xml"), nil}
      ]

      for {body, content_type} <- sources do
        assert {:ok, items, %{truncation: :complete}} = FeedParser.parse(body, content_type)
        for fields <- items, do: assert({:ok, %Item{}} = Item.new(fields, @now))
      end
    end

    test "a JSON API item without an id is refused by Item.new/2" do
      body = Jason.encode!(%{"items" => [%{"id" => "a"}, %{"name" => "no id"}]})

      assert {:ok, [with_id, without_id], %{truncation: :complete}} =
               FeedParser.parse_json_api(body, %{items_path: "items", id_path: "id"})

      assert {:ok, %Item{item_id: "a"}} = Item.new(with_id, @now)
      assert Item.new(without_id, @now) == {:error, {:invalid, "The item has no id."}}
    end
  end

  describe "parse_json_api/3" do
    @paths %{
      items_path: "data.items",
      id_path: "id",
      revision_path: "meta.version",
      type_path: "kind",
      subject_path: "service.name",
      time_path: "at"
    }

    @api_body Jason.encode!(%{
                "data" => %{
                  "items" => [
                    %{
                      "id" => 901,
                      "kind" => "deploy.finished",
                      "service" => %{"name" => "ledger"},
                      "meta" => %{"version" => 3},
                      "at" => "2026-10-14T09:00:00Z",
                      "tags" => ["prod"]
                    },
                    %{
                      "id" => "a-77",
                      "kind" => "deploy.started",
                      "service" => %{"name" => "billing"},
                      "at" => "yesterday"
                    },
                    %{"kind" => "deploy.started"}
                  ]
                }
              })

    test "reads each field at its configured dot path" do
      assert {:ok, [first, second, third], %{truncation: :complete}} =
               FeedParser.parse_json_api(@api_body, @paths)

      assert first == %{
               item_id: "901",
               revision: "3",
               type: "deploy.finished",
               subject: "ledger",
               occurred_at: ~U[2026-10-14 09:00:00Z],
               datacontenttype: "application/json",
               title: nil,
               data: %{
                 "id" => 901,
                 "kind" => "deploy.finished",
                 "service" => %{"name" => "ledger"},
                 "meta" => %{"version" => 3},
                 "at" => "2026-10-14T09:00:00Z",
                 "tags" => ["prod"]
               }
             }

      assert {second.item_id, second.revision, second.subject, second.occurred_at} ==
               {"a-77", "1", "billing", nil}

      # No id at the configured path: Item.new/2 refuses it as invalid.
      assert {third.item_id, third.type, third.subject} == {nil, "deploy.started", nil}
    end

    test "optional paths default to revision 1 and type feed.item" do
      body = Jason.encode!([%{"id" => "x", "tags" => ["alpha", "beta"]}])

      assert {:ok, [item], %{truncation: :complete}} =
               FeedParser.parse_json_api(body, %{
                 items_path: ".",
                 id_path: "id",
                 subject_path: "tags.1"
               })

      assert {item.item_id, item.revision, item.type, item.subject} ==
               {"x", "1", "feed.item", "beta"}
    end

    test "truncates past 100 items with the range of what it dropped" do
      base = ~U[2026-10-14 12:00:00Z]

      items =
        Enum.map(1..150, fn index ->
          %{
            "id" => index,
            "at" => base |> DateTime.add(-index * 60, :second) |> DateTime.to_iso8601()
          }
        end)

      body = Jason.encode!(%{"items" => items})
      paths = %{items_path: "items", id_path: "id", time_path: "at"}

      assert {:ok, kept, %{truncation: {:truncated, truncation}}} =
               FeedParser.parse_json_api(body, paths)

      assert length(kept) == 100

      assert truncation == %{
               count: 50,
               range_from: ~U[2026-10-14 09:30:00Z],
               range_to: ~U[2026-10-14 10:19:00Z]
             }
    end

    test "refuses invalid paths, a missing item list and invalid JSON" do
      assert FeedParser.parse_json_api(@api_body, %{@paths | id_path: "a..b"}) ==
               {:error, {:invalid_path, :id_path}}

      assert FeedParser.parse_json_api(@api_body, Map.put(@paths, :title_path, "t")) ==
               {:error, {:invalid_path, :title_path}}

      assert FeedParser.parse_json_api(@api_body, %{@paths | items_path: "data"}) ==
               {:error, :no_items_list}

      assert FeedParser.parse_json_api(@api_body, %{@paths | items_path: "nope.items"}) ==
               {:error, :no_items_list}

      assert FeedParser.parse_json_api("{\"data\": ", @paths) == {:error, :invalid_json}
    end

    test "validate_paths/1 needs items_path and id_path and bounds the depth" do
      assert FeedParser.validate_paths(%{items_path: ".", id_path: "id"}) == :ok
      assert FeedParser.validate_paths(%{items_path: "."}) == {:error, {:invalid_path, :id_path}}
      deep = Enum.map_join(1..17, ".", &"k#{&1}")

      assert FeedParser.validate_paths(%{items_path: deep, id_path: "id"}) ==
               {:error, {:invalid_path, :items_path}}
    end
  end
end
