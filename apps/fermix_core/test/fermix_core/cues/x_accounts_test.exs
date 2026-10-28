defmodule FermixCore.Cues.XAccountsTest do
  # The X accounts source's own rules (M60_X_ACCOUNTS_SOURCE.md §3): the
  # handles, the search address, the cursor and the reading of X's answer.
  # async: false only for the sign-in, which reads the plugins the
  # application environment enables; it pins and restores that key.
  use ExUnit.Case, async: false

  alias FermixCore.Cues.XAccounts
  alias FermixCore.Plugins.Plugin

  @now ~U[2026-10-10 12:00:00Z]
  @snowflake_epoch_ms 1_288_834_974_657

  # An X post id made at `at`, as X makes them: the time in its high bits.
  defp post_id(at) do
    ms = DateTime.to_unix(at, :millisecond) - @snowflake_epoch_ms
    Integer.to_string(Bitwise.bsl(ms, 22) + 4_097)
  end

  defp params(url) do
    %URI{scheme: "https", host: "api.x.com", path: "/2/tweets/search/recent", query: query} =
      URI.parse(url)

    URI.decode_query(query)
  end

  describe "handles" do
    test "are written with or without @, kept lowercased and once each" do
      assert XAccounts.handles(["@NASA", "nasa", " SpaceX_News ", "@esa"]) ==
               {:ok, ["nasa", "spacex_news", "esa"]}
    end

    test "a name X would not take is refused, naming it" do
      for bad <- ["not-a-name", "sixteen_letters_", "", "@", "two words"] do
        assert {:error, words} = XAccounts.handles(["nasa", bad])
        assert words =~ inspect(bad), "#{inspect(bad)}: #{words}"
      end

      assert {:error, _words} = XAccounts.handles(["nasa", 42])
      assert {:error, _words} = XAccounts.handles("nasa")
    end

    test "at most 20, and twenty of the longest fit X's 512-character query" do
      longest = for n <- 1..20, do: "h" <> String.pad_leading(Integer.to_string(n), 14, "0")

      assert {:ok, ^longest} = XAccounts.handles(longest)
      assert String.length(XAccounts.query(longest)) <= 512

      assert {:error, words} = XAccounts.handles(longest ++ ["one_more"])
      assert words =~ "20"
    end
  end

  describe "the search address" do
    test "watching starts now; the first poll asks from then, reposts left out, never with since_id" do
      cursor = XAccounts.start_watching(%{}, @now)
      assert cursor == %{"start_time" => "2026-10-10T12:00:00Z"}

      assert params(XAccounts.search_url(["nasa", "esa"], cursor, DateTime.add(@now, 300))) ==
               %{
                 "query" => "(from:nasa OR from:esa) -is:retweet",
                 "tweet.fields" => "created_at,author_id,note_tweet",
                 "expansions" => "author_id",
                 "user.fields" => "username,name",
                 "max_results" => "100",
                 "start_time" => "2026-10-10T12:00:00Z"
               }
    end

    # X's search ends 30 seconds before each request, and a start after its
    # end is refused, so a start that recent goes out a minute back.
    test "a start inside X's search lag goes out a minute before the request" do
      cursor = XAccounts.start_watching(%{}, @now)

      assert %{"start_time" => "2026-10-10T11:59:00Z"} =
               params(XAccounts.search_url(["nasa"], cursor, @now))
    end

    test "once a post arrived it asks for the posts after it, never with start_time" do
      newest = post_id(DateTime.add(@now, -3_600))
      cursor = %{"since_id" => newest, "start_time" => "2026-10-09T08:00:00Z"}
      sent = params(XAccounts.search_url(["nasa"], cursor, @now))

      assert sent["since_id"] == newest
      refute Map.has_key?(sent, "start_time")
    end

    test "past X's 7-day window it resumes from 7 days ago, less a minute" do
      resumed = "2026-10-03T12:01:00Z"

      old_post = %{
        "since_id" => post_id(DateTime.add(@now, -8, :day)),
        "start_time" => "2026-10-01T12:00:00Z"
      }

      for cursor <- [old_post, %{"start_time" => "2026-10-02T09:30:00Z"}] do
        sent = params(XAccounts.search_url(["nasa"], cursor, @now))
        assert sent["start_time"] == resumed
        refute Map.has_key?(sent, "since_id")
      end
    end

    test "watching keeps the cursor it has and drops what is not an X cursor" do
      cursor = %{"since_id" => "1234", "start_time" => "2026-10-09T00:00:00Z", "etag" => "v1"}

      assert XAccounts.start_watching(cursor, @now) ==
               %{"since_id" => "1234", "start_time" => "2026-10-09T00:00:00Z"}

      assert XAccounts.start_watching(%{"since_id" => "abc", "start_time" => "soon"}, @now) ==
               %{"start_time" => "2026-10-10T12:00:00Z"}
    end

    test "the X sign-in goes in Authorization" do
      assert {"authorization", "Bearer x-access-1"} in XAccounts.headers("x-access-1")
    end
  end

  describe "reading X's answer" do
    setup do
      first = post_id(DateTime.add(@now, -120))
      second = post_id(DateTime.add(@now, -600))

      document = %{
        "data" => [
          %{
            "id" => first,
            "text" => "Launch window opens at dawn.",
            "author_id" => "11",
            "created_at" => "2026-10-10T11:58:00.000Z",
            "edit_history_tweet_ids" => [first]
          },
          %{
            "id" => second,
            "text" => "Replying to the launch thread.",
            "author_id" => "22",
            "created_at" => "2026-10-10T11:50:00.000Z"
          }
        ],
        "includes" => %{
          "users" => [
            %{"id" => "11", "username" => "NASA", "name" => "NASA", "protected" => false}
          ]
        },
        "meta" => %{"newest_id" => first, "oldest_id" => second, "result_count" => 2}
      }

      %{first: first, second: second, document: document}
    end

    test "each post is an item with its author and its link; the newest id is the next since_id",
         %{first: first, second: second, document: document} do
      cursor = %{"start_time" => "2026-10-10T11:00:00Z"}
      assert {:ok, [a, b], json, outcome} = XAccounts.read(document, cursor)

      assert %{item_id: ^first, type: "x.post", subject: "11", revision: "1", title: nil} = a
      assert a.occurred_at == ~U[2026-10-10 11:58:00.000Z]
      assert a.data["text"] == "Launch window opens at dawn."
      assert a.data["author"] == %{"id" => "11", "username" => "NASA", "name" => "NASA"}
      assert a.data["url"] == "https://x.com/NASA/status/#{first}"

      # An author X did not include still has a link that opens the post.
      assert b.item_id == second
      refute Map.has_key?(b.data, "author")
      assert b.data["url"] == "https://x.com/i/status/#{second}"

      assert Jason.decode!(json) == %{"since_id" => first, "start_time" => "2026-10-10T11:00:00Z"}
      assert outcome == %{truncation: :complete, skipped: 0}
    end

    # X cuts `text` at 280 characters and sends a long post's whole text in
    # `note_tweet`; the item's `text` is the whole text, held once.
    test "a long post's text is its whole text", %{first: first, document: document} do
      whole = String.duplicate("A launch window that stays open past dawn. ", 12)

      document =
        update_in(document, ["data"], fn [post | rest] ->
          [Map.put(post, "note_tweet", %{"text" => whole, "entities" => %{}}) | rest]
        end)

      assert {:ok, [long, short], _json, _outcome} =
               XAccounts.read(document, %{"start_time" => "2026-10-10T11:00:00Z"})

      assert long.item_id == first
      assert long.data["text"] == whole
      refute Map.has_key?(long.data, "note_tweet")
      assert short.data["text"] == "Replying to the launch thread."
    end

    test "an answer with no posts keeps the cursor" do
      cursor = %{"since_id" => "1849", "start_time" => "2026-10-10T11:00:00Z"}

      assert {:ok, [], json, %{truncation: :complete}} =
               XAccounts.read(%{"meta" => %{"result_count" => 0}}, cursor)

      assert Jason.decode!(json) == cursor
    end

    test "a next page is posts left out: a page_limit gap that ends at the oldest post read",
         %{document: document} do
      document = put_in(document, ["meta", "next_token"], "b26v89c19zqg8o3f")

      assert {:ok, [_a, _b], _json, %{truncation: truncation}} =
               XAccounts.read(document, %{"start_time" => "2026-10-10T11:00:00Z"})

      assert truncation ==
               {:truncated, %{count: 1, range_from: nil, range_to: ~U[2026-10-10 11:50:00.000Z]}}
    end

    test "an answer not in X's shape is refused", %{first: first, document: document} do
      cursor = %{"start_time" => "2026-10-10T11:00:00Z"}

      for bad <- [
            [],
            %{"data" => "posts", "meta" => %{}},
            %{"data" => [], "includes" => %{"users" => "nobody"}, "meta" => %{}},
            %{"data" => [%{"id" => "not-an-id"}], "meta" => %{"newest_id" => first}},
            Map.put(document, "meta", %{"result_count" => 2}),
            Map.delete(document, "meta")
          ] do
        assert {:error, {:invalid_x_response, _what}} = XAccounts.read(bad, cursor),
               inspect(bad)
      end
    end
  end

  describe "X's refusal" do
    test "keeps X's title and detail for the log, and nothing else" do
      body =
        ~s({"title":"Too Many Requests","detail":"Too Many Requests","type":"about:blank",) <>
          ~s("status":429})

      assert XAccounts.refusal(429, body) ==
               {:http_status, 429,
                %{"title" => "Too Many Requests", "detail" => "Too Many Requests"}}

      assert XAccounts.refusal(503, "<html>busy</html>") == {:http_status, 503, %{}}
    end
  end

  describe "the sign-in" do
    setup do
      saved = Application.fetch_env(:fermix_core, :plugins)
      Application.put_env(:fermix_core, :plugins, enabled: [])

      on_exit(fn ->
        case saved do
          {:ok, value} -> Application.put_env(:fermix_core, :plugins, value)
          :error -> Application.delete_env(:fermix_core, :plugins)
        end
      end)

      plugin = %Plugin{
        schema_version: 1,
        name: "x",
        display_name: "X",
        description: "Post, search, and read on X.",
        category: "productivity",
        version: "1.0.1",
        default_enabled?: false,
        auth: %{type: :oauth2, provider: "x", scopes: []},
        tools: [],
        skills: [],
        path: "/plugins/x"
      }

      %{plugin: plugin}
    end

    test "is the X plugin's token, from its auth profile", %{plugin: plugin} do
      Application.put_env(:fermix_core, :plugins, enabled: ["x"])
      test = self()

      get_token = fn profile ->
        send(test, {:asked, profile})
        {:ok, "x-access-1"}
      end

      assert XAccounts.sign_in_token(find: fn "x" -> {:ok, plugin} end, get_token: get_token) ==
               {:ok, "x-access-1"}

      assert_received {:asked, "x:primary"}
    end

    # A token server that does not answer exits the call; the sign-in is then
    # missing, with a reason of its own for the log, never an exit.
    test "a token server that does not answer is no sign-in, for a token or a refresh", %{
      plugin: plugin
    } do
      wedged = fn _profile -> exit({:timeout, {GenServer, :call, [:x_tokens, :get, 15_000]}}) end
      seams = [find: fn "x" -> {:ok, plugin} end, enabled: fn -> ["x"] end]

      assert XAccounts.sign_in_token([get_token: wedged] ++ seams) ==
               {:error, {:token_server_unavailable, :timeout}}

      assert XAccounts.sign_in_refresh([refresh: wedged] ++ seams) ==
               {:error, {:token_server_unavailable, :timeout}}
    end

    test "a refresh asks the X plugin's auth profile for a new token", %{plugin: plugin} do
      test = self()

      refresh = fn profile ->
        send(test, {:refreshed, profile})
        {:ok, "x-access-2"}
      end

      seams = [find: fn "x" -> {:ok, plugin} end, enabled: fn -> ["x"] end, refresh: refresh]
      assert XAccounts.sign_in_refresh(seams) == {:ok, "x-access-2"}
      assert_received {:refreshed, "x:primary"}

      assert XAccounts.sign_in_refresh(Keyword.put(seams, :enabled, fn -> [] end)) ==
               {:error, :x_plugin_off}
    end

    test "there is none without the X plugin, with it switched off, or with no token", %{
      plugin: plugin
    } do
      refused = fn _profile -> flunk("no token is asked for") end

      assert XAccounts.sign_in_token(find: fn "x" -> :error end, get_token: refused) ==
               {:error, :x_plugin_not_installed}

      assert XAccounts.sign_in_token(find: fn "x" -> {:ok, plugin} end, get_token: refused) ==
               {:error, :x_plugin_off}

      Application.put_env(:fermix_core, :plugins, enabled: ["x"])
      none = fn "x:primary" -> {:error, :not_found} end

      assert XAccounts.sign_in_token(find: fn "x" -> {:ok, plugin} end, get_token: none) ==
               {:error, :not_found}
    end
  end
end
