defmodule FermixCore.Cues.DoorWebhookTest do
  # async: false — Buckets owns named tables, and the sources are app env.
  use ExUnit.Case, async: false

  import Plug.Conn, only: [put_req_header: 3]
  import Plug.Test

  alias FermixCore.Cues.Buckets
  alias FermixCore.Cues.Config
  alias FermixCore.Cues.Door.Router
  alias FermixCore.Cues.Ingest
  alias FermixCore.Cues.Item
  alias FermixTestSupport.CueFixtures
  alias FermixTestSupport.SecretWriterStub

  @now ~U[2026-10-10 12:00:00Z]
  @github_secret "gh-signing-secret"
  @shared_secret "shared-token-1"
  @std_key "a 24-byte Standard key.."
  @x_secret "x-client-secret-0417"
  @crc_token "Y2hhbGxlbmdlLTA0MTc"
  @path_random "R4nd0m-path_secret0123"
  @token "tok-home-alerts"
  @wait_ms 10_000

  # A body read that holds its door slot until the test releases it: one slow
  # upload, without a real clock or socket. Everything else is Plug's test
  # adapter.
  defmodule SlowBody do
    @moduledoc false
    alias Plug.Adapters.Test.Conn, as: TestConn

    def read_req_body({test, inner}, _opts) do
      send(test, {:reading, self()})

      receive do
        {:release, body} -> {:ok, body, {test, inner}}
      after
        30_000 -> {:error, :timeout}
      end
    end

    def send_resp({test, inner}, status, headers, body) do
      {:ok, sent, inner} = TestConn.send_resp(inner, status, headers, body)
      {:ok, sent, {test, inner}}
    end
  end

  setup do
    cues = Application.get_env(:fermix_core, :cues)
    writer = Application.get_env(:fermix_core, :secret_writer)
    profile = Application.get_env(:fermix_core, :profile)

    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    Application.delete_env(:fermix_core, :profile)
    SecretWriterStub.reset()

    Application.put_env(:fermix_core, :cues, Config.normalize(%{"sources" => sources()}))

    for ref <- ~w(gh-hooks std-hooks shared-hooks off-hooks x-posts x-waiting x-off) do
      :ok = put_secret(ref, :path_secret, @path_random)
    end

    :ok = put_secret("gh-hooks", :secret, @github_secret)
    :ok = put_secret("off-hooks", :secret, @github_secret)
    :ok = put_secret("fresh-hooks", :secret, @github_secret)
    :ok = put_secret("std-hooks", :secret, "whsec_" <> Base.encode64(@std_key))
    :ok = put_secret("shared-hooks", :secret, @shared_secret)
    :ok = put_secret("x-posts", :secret, @x_secret)
    :ok = put_secret("x-off", :secret, @x_secret)
    :ok = put_secret("home-alerts", :token, @token)

    on_exit(fn ->
      restore(:cues, cues)
      restore(:secret_writer, writer)
      restore(:profile, profile)
      SecretWriterStub.reset()
    end)

    start_supervised!(Buckets)
    :ok
  end

  defp sources do
    github = %{"preset" => "github", "secret" => "@keyring", "path_secret" => "@keyring"}

    %{
      "gh-hooks" => Map.put(github, "daily_budget", 40),
      "off-hooks" => Map.put(github, "enabled", false),
      "fresh-hooks" => %{"preset" => "github", "secret" => "@keyring"},
      "std-hooks" => %{
        "kind" => "webhook",
        "verify" => "standard_webhooks",
        "secret" => "@keyring",
        "path_secret" => "@keyring"
      },
      "shared-hooks" => %{
        "kind" => "webhook",
        "verify" => "shared_secret",
        "header" => "X-Hook-Token",
        "id" => "content_hash",
        "secret" => "@keyring",
        "path_secret" => "@keyring"
      },
      "x-posts" => %{"preset" => "x", "secret" => "@keyring", "path_secret" => "@keyring"},
      "x-waiting" => %{"preset" => "x", "path_secret" => "@keyring"},
      "x-off" => %{
        "preset" => "x",
        "enabled" => false,
        "secret" => "@keyring",
        "path_secret" => "@keyring"
      },
      "home-alerts" => %{"kind" => "local_push", "token" => "@keyring"}
    }
  end

  defp put_secret(ref, field, value),
    do: SecretWriterStub.put({:cue_source, ref, field}, value, store: :keyring)

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)

  # An ingest stand-in that reports what it was given and accepts every item.
  defp router_opts(overrides \\ []) do
    test = self()

    ingest = fn source, entries, opts ->
      send(test, {:ingest, source, entries, opts})

      {:ok,
       Enum.map(entries, fn
         %Item{} -> :accepted
         {:error, {:invalid, _message} = invalid} -> invalid
         {:error, :stale} -> :stale
       end)}
    end

    Keyword.merge([ingest: ingest, clock: fn -> 0 end, now: fn -> @now end], overrides)
  end

  defp real_ingest(ctx) do
    fn source, entries, opts ->
      Ingest.accept(source, entries, Keyword.put(opts, :repo, ctx.repo))
    end
  end

  defp hook_path(ref, random \\ @path_random), do: "/cues/hooks/#{ref}/#{random}"

  defp hmac_hex(secret, body),
    do: :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)

  defp issue_body(extra \\ %{}) do
    Jason.encode!(
      Map.merge(
        %{
          "action" => "opened",
          "issue" => %{
            "title" => "Build fails on main",
            "html_url" => "https://github.com/example-org/ops/issues/7"
          },
          "repository" => %{"full_name" => "example-org/ops"}
        },
        extra
      )
    )
  end

  defp github_headers(body, overrides \\ %{}) do
    %{
      "content-type" => "application/json",
      "content-length" => Integer.to_string(byte_size(body)),
      "x-github-delivery" => "d-1",
      "x-github-event" => "issues",
      "x-hub-signature-256" => "sha256=" <> hmac_hex(@github_secret, body)
    }
    |> Map.merge(Map.new(overrides))
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
  end

  defp build(method, path, body, headers) do
    Enum.reduce(headers, conn(method, path, body), fn {key, value}, acc ->
      put_req_header(acc, key, value)
    end)
  end

  defp call(conn, opts), do: Router.call(conn, Router.init(opts))

  defp post_hook(path, body, headers, opts \\ router_opts()),
    do: :post |> build(path, body, headers) |> call(opts)

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp hook_watcher(ctx, words) do
    CueFixtures.insert_watcher(ctx.conn, %{
      filter: "llm",
      sources: ["gh-hooks"],
      listen_for: words
    })
  end

  defp offered(ctx, watcher) do
    ctx.conn
    |> CueFixtures.rows(
      "SELECT c.item_id FROM cue_deliveries d JOIN cues c ON c.id = d.cue_id " <>
        "WHERE d.watcher_id = ? ORDER BY d.id",
      [watcher]
    )
    |> List.flatten()
  end

  describe "a GitHub webhook" do
    test "a signed delivery is accepted, with its delivery id, event type and body hash" do
      body = issue_body()
      conn = post_hook(hook_path("gh-hooks"), body, github_headers(body))

      assert conn.status == 200

      assert json(conn) == %{
               "results" => [%{"index" => 0, "id" => "d-1", "status" => "accepted"}]
             }

      assert_received {:ingest, %{ref: "gh-hooks", daily_budget: 40}, [%Item{} = item], opts}
      assert item.item_id == "d-1"
      assert item.type == "issues"
      assert item.body_hash == :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
      assert opts[:now] == @now
      assert is_function(opts[:admit], 1)
    end

    test "C05: a bad signature is 401, stores nothing and is counted" do
      body = issue_body()
      headers = github_headers(body, %{"x-hub-signature-256" => "sha256=" <> hmac_hex("x", body)})

      conn = post_hook(hook_path("gh-hooks"), body, headers)

      assert conn.status == 401
      refute_received {:ingest, _source, _entries, _opts}
      assert Buckets.take_rejects() == %{"gh-hooks" => %{unauthorized: 1}}
    end

    test "C05: a request with no signature through a tunnel is 401" do
      body = issue_body()

      headers =
        github_headers(body, %{
          "x-hub-signature-256" => nil,
          "tailscale-funnel-request" => "?1",
          "x-forwarded-for" => "203.0.113.9"
        })

      assert post_hook(hook_path("gh-hooks"), body, headers).status == 401
      refute_received {:ingest, _source, _entries, _opts}
    end

    test "a Funnel request with a good signature is accepted: Funnel is the way in" do
      body = issue_body()
      headers = github_headers(body, %{"tailscale-funnel-request" => "?1"})

      assert post_hook(hook_path("gh-hooks"), body, headers).status == 200
    end

    test "a body that is not JSON is 415 and a body without one Content-Length is 411" do
      body = issue_body()

      for type <- ["application/x-www-form-urlencoded", nil] do
        headers = github_headers(body, %{"content-type" => type})
        assert post_hook(hook_path("gh-hooks"), body, headers).status == 415
      end

      headers = github_headers(body, %{"content-length" => nil})
      assert post_hook(hook_path("gh-hooks"), body, headers).status == 411

      headers = github_headers(body, %{"content-type" => "application/vnd.github+json"})
      assert post_hook(hook_path("gh-hooks"), body, headers).status == 200
    end

    test "a signed body with a repeated key is 400 and stores nothing" do
      body = ~s({"action":"opened","action":"closed"})
      conn = post_hook(hook_path("gh-hooks"), body, github_headers(body))

      assert conn.status == 400
      assert json(conn)["error"] =~ "repeats a key"
      refute_received {:ingest, _source, _entries, _opts}
    end

    test "a delivery without its id header is answered invalid on its own line" do
      body = issue_body()
      headers = github_headers(body, %{"x-github-delivery" => nil})
      conn = post_hook(hook_path("gh-hooks"), body, headers)

      assert conn.status == 200
      assert [%{"status" => "invalid", "reason" => reason}] = json(conn)["results"]
      assert reason =~ "no id"
    end

    test "over the source's rate the answer is 429" do
      assert Buckets.admit("gh-hooks", 100, 0) == 100
      body = issue_body()

      assert post_hook(hook_path("gh-hooks"), body, github_headers(body)).status == 429
      refute_received {:ingest, _source, _entries, _opts}
    end

    # M60 app surface §3.8 item 3: a webhook added before its signing secret is
    # stored answers like an unknown path, and reads no secret.
    test "a webhook waiting for its signing secret is 404 and reads no secret" do
      Application.put_env(
        :fermix_core,
        :cues,
        Config.normalize(%{
          "sources" => %{"new-hooks" => %{"preset" => "github", "path_secret" => "@keyring"}}
        })
      )

      test = self()
      load = fn ref, field -> send(test, {:loaded, ref, field}) && {:ok, @path_random} end
      body = issue_body()

      conn =
        post_hook(
          hook_path("new-hooks"),
          body,
          github_headers(body),
          router_opts(load_secret: load)
        )

      assert conn.status == 404
      refute_received {:loaded, _ref, _field}
      refute_received {:ingest, _source, _entries, _opts}
    end

    test "a signing secret that cannot be read is 503" do
      load = fn
        _ref, :path_secret -> {:ok, @path_random}
        _ref, :secret -> {:error, :missing_secret}
      end

      body = issue_body()

      conn =
        post_hook(
          hook_path("gh-hooks"),
          body,
          github_headers(body),
          router_opts(load_secret: load)
        )

      assert conn.status == 503
      refute_received {:ingest, _source, _entries, _opts}
    end

    test "concurrent signed requests read the signing key inside the auth slot, once a minute" do
      test = self()
      reads = :counters.new(1, [])

      load = fn
        _ref, :path_secret ->
          {:ok, @path_random}

        _ref, :secret ->
          :counters.add(reads, 1, 1)
          send(test, {:key_read, self()})

          receive do
            :go -> {:ok, @github_secret}
          after
            @wait_ms -> {:error, :never_released}
          end
      end

      body = issue_body()
      opts = router_opts(load_secret: load)

      requests =
        for n <- 1..8 do
          headers = github_headers(body, %{"x-github-delivery" => "d-#{n}"})
          Task.async(fn -> post_hook(hook_path("gh-hooks"), body, headers, opts).status end)
        end

      assert_receive {:key_read, reader}, @wait_ms
      # The one request reading the key holds the source's one authenticated
      # slot; every other is turned away before it can read the store.
      others = Enum.reject(requests, &(&1.pid == reader))
      refused = Enum.map(others, &Task.await(&1, @wait_ms))
      assert Enum.all?(refused, &(&1 in [429, 503]))
      assert :counters.get(reads, 1) == 1

      send(reader, :go)
      assert [200] = requests |> Enum.filter(&(&1.pid == reader)) |> Enum.map(&Task.await/1)

      # Signed or not, the next requests use the key read a moment ago.
      bad = github_headers(body, %{"x-hub-signature-256" => "sha256=" <> hmac_hex("x", body)})
      assert post_hook(hook_path("gh-hooks"), body, bad, opts).status == 401
      assert post_hook(hook_path("gh-hooks"), body, github_headers(body), opts).status == 200
      assert :counters.get(reads, 1) == 1
    end
  end

  describe "the path is the first secret" do
    test "C05: a wrong or missing random part is 404, like any unknown path" do
      body = issue_body()
      headers = github_headers(body)

      for path <- [
            hook_path("gh-hooks", "wrong-random"),
            hook_path("gh-hooks", String.slice(@path_random, 0..-2//1)),
            "/cues/hooks/gh-hooks",
            "/cues/hooks/gh-hooks/#{@path_random}/extra"
          ] do
        conn = post_hook(path, body, headers)
        assert conn.status == 404
        assert json(conn) == %{"error" => "Not found."}
      end

      refute_received {:ingest, _source, _entries, _opts}
    end

    test "an unknown, disabled, URL-less or non-webhook source is 404" do
      body = issue_body()

      for ref <- ~w(nope off-hooks fresh-hooks home-alerts) do
        assert post_hook(hook_path(ref), body, github_headers(body)).status == 404
      end

      refute_received {:ingest, _source, _entries, _opts}
    end

    test "a wrong path is refused before the body: it never takes a read slot" do
      for _ <- 1..4, do: {:ok, _token} = Buckets.acquire(:read, "gh-hooks")
      body = issue_body()

      assert post_hook(hook_path("gh-hooks", "wrong-random"), body, github_headers(body)).status ==
               404

      assert post_hook(hook_path("gh-hooks"), body, github_headers(body)).status == 503
    end

    test "a path secret that cannot be read is 503 for that source" do
      load = fn _ref, _field -> {:error, :missing_secret} end
      body = issue_body()

      conn =
        post_hook(
          hook_path("gh-hooks"),
          body,
          github_headers(body),
          router_opts(load_secret: load)
        )

      assert conn.status == 503
    end

    test "C05: GET / and GET /live are 404, and so is a GET on a hook path" do
      for path <- ["/", "/live", hook_path("gh-hooks")] do
        conn = :get |> build(path, "", []) |> call(router_opts())
        assert conn.status == 404
      end
    end
  end

  describe "Standard Webhooks" do
    defp std_signature(id, timestamp, body) do
      mac = :crypto.mac(:hmac, :sha256, @std_key, "#{id}.#{timestamp}.#{body}")
      "v1," <> Base.encode64(mac)
    end

    defp std_headers(body, id, timestamp, signature) do
      [
        {"content-type", "application/json"},
        {"content-length", Integer.to_string(byte_size(body))},
        {"webhook-id", id},
        {"webhook-timestamp", Integer.to_string(timestamp)},
        {"webhook-signature", signature}
      ]
    end

    test "a signed message inside the window is accepted under its webhook-id" do
      body = ~s({"type":"invoice.paid","data":{"amount":12}})
      timestamp = DateTime.to_unix(@now) - 30
      headers = std_headers(body, "msg_1", timestamp, std_signature("msg_1", timestamp, body))

      conn = post_hook(hook_path("std-hooks"), body, headers)

      assert conn.status == 200
      assert [%{"id" => "msg_1", "status" => "accepted"}] = json(conn)["results"]
    end

    test "C05: a replay outside the five-minute window is 401 and stores nothing" do
      body = ~s({"type":"invoice.paid"})
      timestamp = DateTime.to_unix(@now) - 301
      headers = std_headers(body, "msg_1", timestamp, std_signature("msg_1", timestamp, body))

      conn = post_hook(hook_path("std-hooks"), body, headers)

      assert conn.status == 401
      assert json(conn)["error"] =~ "5 minutes"
      refute_received {:ingest, _source, _entries, _opts}
    end

    test "a signature over another id is 401" do
      body = ~s({"type":"invoice.paid"})
      timestamp = DateTime.to_unix(@now)
      headers = std_headers(body, "msg_2", timestamp, std_signature("msg_1", timestamp, body))

      assert post_hook(hook_path("std-hooks"), body, headers).status == 401
    end
  end

  describe "an X webhook" do
    defp x_body do
      Jason.encode!(%{
        "data" => %{
          "event_uuid" => "evt-5512-alpha",
          "created_at" => "2026-10-10T11:58:30.000Z",
          "event_type" => "post.create",
          "filter" => %{"user_id" => "4401876523"},
          "payload" => %{"id" => "1981000000000000042", "text" => "Office opens Monday."}
        }
      })
    end

    defp x_signature(secret, body),
      do: "sha256=" <> Base.encode64(:crypto.mac(:hmac, :sha256, secret, body))

    defp x_headers(body, signature_headers) do
      [
        {"content-type", "application/json"},
        {"content-length", Integer.to_string(byte_size(body))}
        | signature_headers
      ]
    end

    defp crc(path, query, headers \\ [], opts \\ router_opts()),
      do: :get |> build(path <> query, "", headers) |> call(opts)

    defp crc_query(token), do: "?" <> URI.encode_query(%{"crc_token" => token})

    test "X's CRC check is answered with the base64 HMAC of its token under the secret" do
      conn = crc(hook_path("x-posts"), crc_query(@crc_token))

      assert conn.status == 200
      mac = :crypto.mac(:hmac, :sha256, @x_secret, @crc_token)
      assert json(conn) == %{"response_token" => "sha256=" <> Base.encode64(mac)}
      refute_received {:ingest, _source, _entries, _opts}
    end

    test "a CRC check through Funnel is answered: Funnel is the way in" do
      headers = [{"tailscale-funnel-request", "?1"}]
      assert crc(hook_path("x-posts"), crc_query(@crc_token), headers).status == 200
    end

    test "C05: a CRC token that decodes as a body is 400 and signs nothing" do
      conn = crc(hook_path("x-posts"), crc_query(x_body()))

      assert conn.status == 400
      refute Map.has_key?(json(conn), "response_token")
      assert Buckets.take_rejects() == %{"x-posts" => %{malformed: 1}}
    end

    test "a CRC check without one token, or with a malformed query, is 400" do
      for query <- [
            "",
            "?crc=#{@crc_token}",
            "?crc_token[a]=b",
            "?crc_token=#{@crc_token}&crc_token=other",
            "?crc_token=%FF"
          ] do
        conn = crc(hook_path("x-posts"), query)
        assert conn.status == 400, query
        assert json(conn)["error"] =~ "crc_token", query
      end
    end

    # The answer is the HMAC a delivery's signature is, so this is the replay
    # the guard exists for: it verifies, and a body that is not JSON is refused.
    test "C05: a CRC answer sent back as a delivery's signature stores nothing" do
      answer = json(crc(hook_path("x-posts"), crc_query(@crc_token)))["response_token"]
      signed = [{"x-twitter-webhooks-signature-oauth2", answer}]

      conn = post_hook(hook_path("x-posts"), @crc_token, x_headers(@crc_token, signed))

      assert conn.status == 400
      refute_received {:ingest, _source, _entries, _opts}
    end

    test "C05: a CRC check on a wrong path, another method's source or one waiting is 404" do
      for path <- [
            hook_path("x-posts", "wrong-random"),
            hook_path("gh-hooks"),
            hook_path("std-hooks"),
            hook_path("x-waiting"),
            hook_path("x-off")
          ] do
        conn = crc(path, crc_query(@crc_token))
        assert conn.status == 404, path
        assert json(conn) == %{"error" => "Not found."}
      end
    end

    test "a secret that cannot be read is 503" do
      load = fn
        _ref, :path_secret -> {:ok, @path_random}
        _ref, :secret -> {:error, :missing_secret}
      end

      opts = router_opts(load_secret: load)
      assert crc(hook_path("x-posts"), crc_query(@crc_token), [], opts).status == 503
    end

    test "a signed delivery is accepted under its event id, with its type, account and time" do
      body = x_body()
      signed = [{"x-twitter-webhooks-signature-oauth2", x_signature(@x_secret, body)}]

      conn = post_hook(hook_path("x-posts"), body, x_headers(body, signed))

      assert conn.status == 200

      assert json(conn) == %{
               "results" => [%{"index" => 0, "id" => "evt-5512-alpha", "status" => "accepted"}]
             }

      assert_received {:ingest, %{ref: "x-posts"}, [%Item{} = item], _opts}
      assert item.type == "post.create"
      assert item.subject == "4401876523"
      assert DateTime.compare(item.occurred_at, ~U[2026-10-10 11:58:30Z]) == :eq
    end

    test "C05: a delivery signed in hex, or under the legacy header alone, is 401" do
      body = x_body()
      hex = "sha256=" <> hmac_hex(@x_secret, body)

      for signed <- [
            [{"x-twitter-webhooks-signature-oauth2", hex}],
            [{"x-twitter-webhooks-signature", x_signature(@x_secret, body)}]
          ] do
        assert post_hook(hook_path("x-posts"), body, x_headers(body, signed)).status == 401
      end

      refute_received {:ingest, _source, _entries, _opts}
    end
  end

  describe "a shared secret in a header" do
    test "the right secret is accepted, under a content_hash id" do
      body = ~s({"alert":"disk full","host":"host-alpha"})

      headers = [
        {"content-type", "application/json"},
        {"content-length", Integer.to_string(byte_size(body))},
        {"x-hook-token", @shared_secret}
      ]

      conn = post_hook(hook_path("shared-hooks"), body, headers)
      assert conn.status == 200
      assert [%{"id" => "sha256:" <> _digest, "status" => "accepted"}] = json(conn)["results"]

      wrong = List.keyreplace(headers, "x-hook-token", 0, {"x-hook-token", "nope"})
      assert post_hook(hook_path("shared-hooks"), body, wrong).status == 401
    end
  end

  # A local push without the token is refused before its body is read and
  # holds no read slot (door_test.exs); slow uploads that do hold the token
  # are still bounded per source.
  describe "C05: slow uploads" do
    test "16 of them hold only one source's read slots; a GitHub delivery elsewhere is accepted" do
      test = self()
      slow_body = String.duplicate("x", 32)

      uploads =
        for _ <- 1..16 do
          Task.async(fn ->
            conn =
              build(:post, "/cues/v1/home-alerts", "", [
                {"content-type", "application/cloudevents+json"},
                {"content-length", Integer.to_string(byte_size(slow_body))},
                {"authorization", "Bearer " <> @token}
              ])

            {Plug.Adapters.Test.Conn, inner} = conn.adapter
            conn = call(%{conn | adapter: {SlowBody, {test, inner}}}, router_opts())
            send(test, {:answered, conn.status})
            conn.status
          end)
        end

      readers =
        for _ <- 1..4 do
          assert_receive {:reading, pid}, @wait_ms
          pid
        end

      for _ <- 1..12, do: assert_receive({:answered, 503}, @wait_ms)

      assert Buckets.counts().read == %{all: 4, by_source: %{"home-alerts" => 4}}

      body = issue_body()
      conn = post_hook(hook_path("gh-hooks"), body, github_headers(body))
      assert conn.status == 200
      assert [%{"status" => "accepted"}] = json(conn)["results"]

      # One at a time, so each finds the source's one authenticated slot free;
      # the four bodies read in the end are not JSON.
      for reader <- readers do
        send(reader, {:release, slow_body})
        assert_receive {:answered, 400}, @wait_ms
      end

      statuses = Enum.map(uploads, &Task.await(&1, @wait_ms))
      assert Enum.frequencies(statuses) == %{503 => 12, 400 => 4}
      assert Buckets.counts().read == %{all: 0, by_source: %{}}
    end
  end

  describe "through the real inbox" do
    test "C38: a captured GitHub body replayed under a new delivery id is a duplicate" do
      ctx = CueFixtures.start_repo("hook_replay")
      opts = router_opts(ingest: real_ingest(ctx))
      body = issue_body()

      first = post_hook(hook_path("gh-hooks"), body, github_headers(body), opts)
      assert [%{"status" => "accepted"}] = json(first)["results"]

      replay =
        post_hook(
          hook_path("gh-hooks"),
          body,
          github_headers(body, %{"x-github-delivery" => "d-2"}),
          opts
        )

      assert replay.status == 200
      assert [%{"id" => "d-2", "status" => "duplicate"}] = json(replay)["results"]

      other = issue_body(%{"action" => "closed"})

      fresh =
        post_hook(
          hook_path("gh-hooks"),
          other,
          github_headers(other, %{"x-github-delivery" => "d-3"}),
          opts
        )

      assert [%{"status" => "accepted"}] = json(fresh)["results"]
      assert [[2]] = CueFixtures.rows(ctx.conn, "SELECT count(*) FROM cues")
    end

    test "routing by words: an llm watcher is offered the event only when its words match" do
      ctx = CueFixtures.start_repo("hook_words")
      builds = hook_watcher(ctx, ["build fails", "flaky test"])
      deploys = hook_watcher(ctx, ["deploy"])
      body = issue_body()

      conn =
        post_hook(
          hook_path("gh-hooks"),
          body,
          github_headers(body),
          router_opts(ingest: real_ingest(ctx))
        )

      assert [%{"status" => "accepted"}] = json(conn)["results"]
      assert offered(ctx, builds) == ["d-1"]
      assert offered(ctx, deploys) == []
    end

    test "a store that does not answer in time is 503 with Retry-After, an unknown outcome" do
      stalled = start_supervised!(FermixTestSupport.StalledRepo)
      body = issue_body()

      ingest = fn source, entries, opts ->
        Ingest.accept(source, entries, Keyword.merge(opts, repo: stalled, repo_timeout_ms: 50))
      end

      {conn, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          post_hook(
            hook_path("gh-hooks"),
            body,
            github_headers(body),
            router_opts(ingest: ingest)
          )
        end)

      assert conn.status == 503
      assert Plug.Conn.get_resp_header(conn, "retry-after") == ["5"]
      assert json(conn)["error"] =~ "retry with the same ids"
    end

    test "a GitHub event over 64 KiB is stored as its projection" do
      ctx = CueFixtures.start_repo("hook_projection")
      # A listening watcher, so the cue keeps its payload rather than a receipt.
      _watcher =
        CueFixtures.insert_watcher(ctx.conn, %{
          filter: "llm",
          sources: ["gh-hooks"],
          listen_for: ["build fails"]
        })

      body =
        issue_body(%{
          "issue" => %{
            "title" => "Build fails on main",
            "html_url" => "https://github.com/example-org/ops/issues/7",
            "body" => String.duplicate("log line\n", 9_000)
          }
        })

      conn =
        post_hook(
          hook_path("gh-hooks"),
          body,
          github_headers(body),
          router_opts(ingest: real_ingest(ctx))
        )

      assert [%{"status" => "accepted"}] = json(conn)["results"]

      assert [[item_id, type, body_hash, payload]] =
               CueFixtures.rows(ctx.conn, "SELECT item_id, type, body_hash, payload FROM cues")

      assert {item_id, type} == {"d-1", "issues"}
      assert body_hash == :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

      assert Jason.decode!(payload) == %{
               "projected" => true,
               "event" => "issues",
               "action" => "opened",
               "repository" => "example-org/ops",
               "title" => "Build fails on main",
               "url" => "https://github.com/example-org/ops/issues/7"
             }
    end
  end
end
