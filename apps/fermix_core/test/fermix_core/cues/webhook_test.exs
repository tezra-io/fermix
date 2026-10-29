defmodule FermixCore.Cues.WebhookTest do
  # async: false — the stub writer's table and the `:cues` app env are global.
  use ExUnit.Case, async: false

  alias FermixCore.Cues.Config
  alias FermixCore.Cues.Item
  alias FermixCore.Cues.Webhook
  alias FermixTestSupport.SecretWriterStub

  @now ~U[2026-10-10 12:00:00Z]
  @github_secret "gh-signing-secret"
  @std_key "a 24-byte Standard key.."

  setup do
    writer = Application.get_env(:fermix_core, :secret_writer)
    store = Application.get_env(:fermix_core, :secret_store)
    profile = Application.get_env(:fermix_core, :profile)

    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    Application.put_env(:fermix_core, :secret_store, :keyring)
    Application.delete_env(:fermix_core, :profile)
    SecretWriterStub.reset()

    on_exit(fn ->
      restore(:secret_writer, writer)
      restore(:secret_store, store)
      restore(:profile, profile)
      SecretWriterStub.reset()
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)

  defp normalize(sources), do: Config.normalize(%{"sources" => sources})

  defp source!(section, ref \\ "hooks") do
    {:ok, source} = Config.source(ref, normalize(%{ref => section}))
    source
  end

  defp github, do: source!(%{"preset" => "github", "secret" => "@keyring"})

  defp hmac_hex(secret, body),
    do: :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)

  defp github_headers(body, overrides \\ %{}) do
    Map.merge(
      %{
        "x-github-delivery" => "d-1",
        "x-github-event" => "issues",
        "x-hub-signature-256" => "sha256=" <> hmac_hex(@github_secret, body)
      },
      overrides
    )
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
  end

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

  describe "configuration" do
    test "the github preset fills the HMAC method, its header and the identity headers" do
      source = github()

      assert source.kind == :webhook
      assert source.preset == "github"
      assert source.verify == :hmac
      assert source.header == "X-Hub-Signature-256"
      assert source.algorithm == "sha256"
      assert source.prefix == "sha256="
      assert source.id_header == "X-GitHub-Delivery"
      assert source.type_header == "X-GitHub-Event"
      assert source.secrets == %{secret: :keyring}
    end

    test "path_secret is a secret field of webhook sources only" do
      source = source!(%{"preset" => "github", "secret" => "@keyring", "path_secret" => "@file"})
      assert source.secrets == %{secret: :keyring, path_secret: :file}

      assert_raise ArgumentError, ~r/path_secret applies only to webhook/, fn ->
        normalize(%{
          "p" => %{"kind" => "local_push", "token" => "@file", "path_secret" => "@file"}
        })
      end

      assert_raise ArgumentError, ~r/path_secret must be "@keyring" or "@file"/, fn ->
        normalize(%{"h" => %{"preset" => "github", "secret" => "@file", "path_secret" => "abc"}})
      end
    end

    # M60 app surface §3.8 item 3: it loads waiting for that secret, and the door
    # and the workers leave it alone until the secret is stored.
    test "a webhook without the secret its method checks waits for it" do
      assert %{missing_secret: :secret} = source!(%{"preset" => "github"}, "h")
      assert %{missing_secret: nil} = source!(%{"preset" => "github", "secret" => "@file"}, "h")
    end

    test "each method takes only its own fields" do
      refusals = [
        {%{"kind" => "webhook", "verify" => "hmac", "id" => "content_hash"},
         ~r/webhook source and needs header, the request header that carries the signature/},
        {%{"preset" => "github", "algorithm" => "md5"},
         ~r/algorithm "md5".*sha1, sha256, sha512/},
        {%{"kind" => "webhook", "verify" => "shared_secret", "id" => "content_hash"},
         ~r/webhook source and needs header/},
        {%{
           "kind" => "webhook",
           "verify" => "shared_secret",
           "header" => "X-Token",
           "prefix" => "t=",
           "id" => "content_hash"
         }, ~r/shared_secret takes no prefix/},
        {%{"kind" => "webhook", "verify" => "standard_webhooks", "header" => "X-Sig"},
         ~r/Standard Webhooks.*header/},
        {%{"kind" => "webhook", "verify" => "standard_webhooks", "id_header" => "X-Id"},
         ~r/takes its identity from webhook-id/}
      ]

      for {section, pattern} <- refusals do
        assert_raise ArgumentError, pattern, fn ->
          normalize(%{"h" => Map.put(section, "secret", "@keyring")})
        end
      end
    end

    test "an HMAC or shared-secret webhook names exactly one identity" do
      base = %{"kind" => "webhook", "verify" => "hmac", "header" => "X-Sig", "secret" => "@file"}

      assert_raise ArgumentError,
                   ~r/needs an identity: id_header, id_path or id = "content_hash"/,
                   fn ->
                     normalize(%{"h" => base})
                   end

      assert_raise ArgumentError, ~r/takes one identity/, fn ->
        normalize(%{"h" => Map.merge(base, %{"id_header" => "X-Id", "id" => "content_hash"})})
      end

      for identity <- [
            %{"id_header" => "X-Id"},
            %{"id_path" => "event.id"},
            %{"id" => "content_hash"}
          ] do
        assert [sources: %{"h" => _section}] = normalize(%{"h" => Map.merge(base, identity)})
      end
    end

    test "a webhook item is the whole body, with one type source and valid paths" do
      base = %{"preset" => "github", "secret" => "@file"}

      assert_raise ArgumentError, ~r/items_path does not apply/, fn ->
        normalize(%{"h" => Map.put(base, "items_path", "events")})
      end

      assert_raise ArgumentError, ~r/type_header or type_path, not both/, fn ->
        normalize(%{"h" => Map.put(base, "type_path", "action")})
      end

      assert_raise ArgumentError, ~r/subject_path "a\.\.b" is not a dot path/, fn ->
        normalize(%{"h" => Map.put(base, "subject_path", "a..b")})
      end

      assert_raise ArgumentError, ~r/header "X Sig" is not a header name/, fn ->
        normalize(%{"h" => Map.put(base, "header", "X Sig")})
      end
    end
  end

  describe "signatures" do
    test "an HMAC over the raw body with the configured prefix is accepted, in either hex case" do
      body = issue_body()
      headers = github_headers(body)

      assert {:ok, presented} = Webhook.presented(github(), headers, @now)
      assert Webhook.verify(github(), presented, body, @github_secret) == :ok

      upper = "sha256=" <> String.upcase(hmac_hex(@github_secret, body))

      assert {:ok, presented} =
               Webhook.presented(github(), [{"x-hub-signature-256", upper}], @now)

      assert Webhook.verify(github(), presented, body, @github_secret) == :ok
    end

    test "a wrong HMAC, a wrong prefix or another body is refused" do
      body = issue_body()
      source = github()

      for presented <- [
            "sha256=" <> hmac_hex("another secret", body),
            "sha1=" <> hmac_hex(@github_secret, body),
            hmac_hex(@github_secret, body),
            "sha256=not-hex"
          ] do
        assert Webhook.verify(source, presented, body, @github_secret) == {:error, :bad_signature}
      end

      {:ok, presented} = Webhook.presented(source, github_headers(body), @now)

      assert Webhook.verify(source, presented, body <> " ", @github_secret) ==
               {:error, :bad_signature}
    end

    test "a missing or repeated signature header is missing" do
      source = github()
      assert Webhook.presented(source, [], @now) == {:error, :missing_signature}

      twice = [{"x-hub-signature-256", "sha256=aa"}, {"x-hub-signature-256", "sha256=bb"}]
      assert Webhook.presented(source, twice, @now) == {:error, :missing_signature}
    end

    test "sha512 HMACs use their own algorithm" do
      source =
        source!(%{
          "kind" => "webhook",
          "verify" => "hmac",
          "header" => "X-Signature",
          "algorithm" => "sha512",
          "id" => "content_hash",
          "secret" => "@keyring"
        })

      body = ~s({"ok":true})
      mac = :crypto.mac(:hmac, :sha512, "k", body) |> Base.encode16(case: :lower)

      assert {:ok, presented} = Webhook.presented(source, [{"x-signature", mac}], @now)
      assert Webhook.verify(source, presented, body, "k") == :ok
    end

    test "Standard Webhooks: any one of several v1 signatures over id.timestamp.body" do
      source = standard_source()
      body = ~s({"type":"invoice.paid"})
      timestamp = DateTime.to_unix(@now) - 60
      good = std_signature("msg_1", timestamp, body)

      headers = std_headers("msg_1", timestamp, "v1,bm9wZQ== v1a,ZWQ= " <> good)
      assert {:ok, presented} = Webhook.presented(source, headers, @now)
      assert Webhook.verify(source, presented, body, std_secret()) == :ok

      # Without the whsec_ prefix the key is the same base64.
      assert Webhook.verify(source, presented, body, Base.encode64(@std_key)) == :ok

      {:ok, presented} = Webhook.presented(source, std_headers("msg_2", timestamp, good), @now)
      assert Webhook.verify(source, presented, body, std_secret()) == {:error, :bad_signature}
    end

    test "Standard Webhooks: a timestamp outside five minutes is refused before the body" do
      source = standard_source()
      now_s = DateTime.to_unix(@now)

      for timestamp <- [now_s - 301, now_s + 301] do
        headers = std_headers("msg_1", timestamp, "v1,AAAA")
        assert Webhook.presented(source, headers, @now) == {:error, :outside_window}
      end

      for timestamp <- [now_s - 300, now_s + 300] do
        assert {:ok, _presented} =
                 Webhook.presented(source, std_headers("msg_1", timestamp, "v1,AAAA"), @now)
      end

      assert Webhook.presented(source, std_headers("msg_1", "soon", "v1,AAAA"), @now) ==
               {:error, :missing_signature}

      assert Webhook.presented(source, [{"webhook-id", "msg_1"}], @now) ==
               {:error, :missing_signature}
    end

    test "Standard Webhooks: a secret that is not base64 is the source's fault" do
      source = standard_source()
      timestamp = DateTime.to_unix(@now)
      {:ok, presented} = Webhook.presented(source, std_headers("m", timestamp, "v1,AAAA"), @now)

      assert Webhook.verify(source, presented, "{}", "whsec_%%%") == {:error, :bad_secret}
    end
  end

  defp standard_source do
    source!(%{"kind" => "webhook", "verify" => "standard_webhooks", "secret" => "@keyring"})
  end

  defp std_secret, do: "whsec_" <> Base.encode64(@std_key)

  defp std_signature(id, timestamp, body) do
    mac = :crypto.mac(:hmac, :sha256, @std_key, "#{id}.#{timestamp}.#{body}")
    "v1," <> Base.encode64(mac)
  end

  defp std_headers(id, timestamp, signature) do
    [
      {"webhook-id", id},
      {"webhook-timestamp", to_string(timestamp)},
      {"webhook-signature", signature}
    ]
  end

  describe "items" do
    test "a GitHub delivery: id and type from its headers, the raw body's hash, a title" do
      body = issue_body()

      assert {:ok, %{id: "d-1", entry: %Item{} = item}} =
               Webhook.entry(github(), github_headers(body), body, @now)

      assert item.item_id == "d-1"
      assert item.type == "issues"
      assert item.body_hash == :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
      assert item.title == "Build fails on main"
      assert item.datacontenttype == "application/json"
      assert item.data["repository"]["full_name"] == "example-org/ops"
      assert item.occurred_at == nil
      refute item.receipt_only?
    end

    test "a GitHub ping is kept as a receipt, never routed" do
      body = ~s({"zen":"Keep it logically awesome.","hook_id":1})
      headers = github_headers(body, %{"x-github-event" => "ping"})

      assert {:ok, %{entry: %Item{receipt_only?: true, type: "ping"}}} =
               Webhook.entry(github(), headers, body, @now)
    end

    test "a missing identity header makes the item invalid, never a fallback" do
      body = issue_body()
      headers = github_headers(body, %{"x-github-delivery" => nil})

      assert {:ok, %{id: nil, entry: {:error, {:invalid, message}}}} =
               Webhook.entry(github(), headers, body, @now)

      assert message =~ "no id"
    end

    test "paths pick the id, revision, subject and time out of the body" do
      source =
        source!(%{
          "kind" => "webhook",
          "verify" => "hmac",
          "header" => "X-Signature",
          "id_path" => "event.id",
          "revision_path" => "event.version",
          "subject_path" => "event.host",
          "time_path" => "event.at",
          "type_path" => "event.kind",
          "secret" => "@keyring"
        })

      body =
        Jason.encode!(%{
          "event" => %{
            "id" => 4_411,
            "version" => 3,
            "host" => "host-alpha",
            "at" => "2026-10-10T11:58:00Z",
            "kind" => "disk.alert"
          }
        })

      assert {:ok, %{id: "4411", entry: item}} = Webhook.entry(source, [], body, @now)
      assert item.revision == "3"
      assert item.subject == "host-alpha"
      assert item.type == "disk.alert"
      assert item.occurred_at == ~U[2026-10-10 11:58:00Z]
    end

    test "content_hash identity: the same content is the same id, whatever its key order" do
      source =
        source!(%{
          "kind" => "webhook",
          "verify" => "shared_secret",
          "header" => "X-Token",
          "id" => "content_hash",
          "secret" => "@keyring"
        })

      assert {:ok, %{id: "sha256:" <> _digest = id, entry: item}} =
               Webhook.entry(source, [], ~s({"a":1,"b":2}), @now)

      assert item.item_id == id
      assert {:ok, %{id: ^id}} = Webhook.entry(source, [], ~s({ "b": 2, "a": 1 }), @now)
      assert {:ok, %{id: other}} = Webhook.entry(source, [], ~s({"a":1,"b":3}), @now)
      refute other == id
    end

    test "a GitHub body over 64 KiB is kept as its projection" do
      body =
        issue_body(%{
          "issue" => %{
            "title" => "Build fails on main",
            "html_url" => "https://github.com/example-org/ops/issues/7",
            "body" => String.duplicate("log line\n", 9_000)
          }
        })

      assert byte_size(body) > 65_536

      assert {:ok, %{entry: %Item{} = item}} =
               Webhook.entry(github(), github_headers(body), body, @now)

      assert item.data == %{
               "projected" => true,
               "event" => "issues",
               "action" => "opened",
               "repository" => "example-org/ops",
               "title" => "Build fails on main",
               "url" => "https://github.com/example-org/ops/issues/7"
             }

      assert item.body_hash == :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    end

    test "a push projection takes the compare URL and the head commit's first line" do
      body =
        Jason.encode!(%{
          "ref" => "refs/heads/main",
          "compare" => "https://github.com/example-org/ops/compare/a...b",
          "head_commit" => %{"message" => "Fix the build\n\nLonger text"},
          "repository" => %{"full_name" => "example-org/ops"},
          "commits" => [%{"patch" => String.duplicate("x", 70_000)}]
        })

      headers = github_headers(body, %{"x-github-event" => "push"})
      assert {:ok, %{entry: item}} = Webhook.entry(github(), headers, body, @now)

      assert item.data["title"] == "Fix the build"
      assert item.data["url"] == "https://github.com/example-org/ops/compare/a...b"
      assert item.data["action"] == nil
    end

    test "another webhook over 64 KiB is invalid, not projected" do
      source =
        source!(%{
          "kind" => "webhook",
          "verify" => "shared_secret",
          "header" => "X-Token",
          "id" => "content_hash",
          "secret" => "@keyring"
        })

      body = Jason.encode!(%{"text" => String.duplicate("a", 70_000)})

      assert {:ok, %{entry: {:error, {:invalid, message}}}} =
               Webhook.entry(source, [], body, @now)

      assert message =~ "64 KiB"
    end

    test "a body that is not JSON, or repeats a key, is refused as a request" do
      assert Webhook.entry(github(), github_headers("x"), "{nope", @now) ==
               {:error, :invalid_json}

      body = ~s({"a":1,"a":2})

      assert Webhook.entry(github(), github_headers(body), body, @now) ==
               {:error, :duplicate_object_key}
    end
  end

  describe "the URL" do
    test "a path is /cues/hooks/<ref>/<random>" do
      assert Webhook.path("gh-hooks", "AbC_-9") == "/cues/hooks/gh-hooks/AbC_-9"
    end

    test "the first call makes 16 random bytes, stores them and saves the sentinel" do
      config = normalize(%{"gh-hooks" => %{"preset" => "github", "secret" => "@keyring"}})
      test = self()
      persist = fn ref, sentinel -> send(test, {:persisted, ref, sentinel}) && :ok end

      assert {:ok, "/cues/hooks/gh-hooks/" <> random} =
               Webhook.ensure_path_secret("gh-hooks", config: config, persist: persist)

      assert {:ok, bytes} = Base.url_decode64(random, padding: false)
      assert byte_size(bytes) == 16
      assert_received {:persisted, "gh-hooks", "@keyring"}

      assert SecretWriterStub.get({:cue_source, "gh-hooks", :path_secret}, store: :keyring) ==
               {:ok, random}
    end

    test "a new URL goes to the configured store" do
      Application.put_env(:fermix_core, :secret_store, :file)
      config = normalize(%{"gh-hooks" => %{"preset" => "github", "secret" => "@file"}})
      test = self()
      persist = fn ref, sentinel -> send(test, {:persisted, ref, sentinel}) && :ok end

      assert {:ok, "/cues/hooks/gh-hooks/" <> random} =
               Webhook.ensure_path_secret("gh-hooks", config: config, persist: persist)

      assert_received {:persisted, "gh-hooks", "@file"}

      assert SecretWriterStub.get({:cue_source, "gh-hooks", :path_secret}, store: :file) ==
               {:ok, random}
    end

    test "a source that has its URL keeps it" do
      config =
        normalize(%{
          "gh-hooks" => %{"preset" => "github", "secret" => "@keyring", "path_secret" => "@file"}
        })

      :ok =
        SecretWriterStub.put({:cue_source, "gh-hooks", :path_secret}, "kept-random-0123456",
          store: :file
        )

      persist = fn _ref, _sentinel -> flunk("a kept URL saves no config") end

      assert Webhook.ensure_path_secret("gh-hooks", config: config, persist: persist) ==
               {:ok, "/cues/hooks/gh-hooks/kept-random-0123456"}
    end

    test "a sentinel whose item is gone gets a new URL in the sentinel's store" do
      config =
        normalize(%{
          "gh-hooks" => %{"preset" => "github", "secret" => "@keyring", "path_secret" => "@file"}
        })

      persist = fn _ref, _sentinel -> flunk("the sentinel is already saved") end

      assert {:ok, "/cues/hooks/gh-hooks/" <> random} =
               Webhook.ensure_path_secret("gh-hooks", config: config, persist: persist)

      assert SecretWriterStub.get({:cue_source, "gh-hooks", :path_secret}, store: :file) ==
               {:ok, random}
    end

    # An outside edit and an unreadable settings file are the write tail's own
    # refusals, so they come back as the terms every settings write answers,
    # never folded into a sentence. Either way the secret comes back out.
    test "a sentinel that cannot be saved takes its secret back out" do
      config = normalize(%{"gh-hooks" => %{"preset" => "github", "secret" => "@keyring"}})

      for refusal <- [
            {:external_change, ["fermix_core.cues"]},
            {:config_unreadable, "The settings file could not be read."}
          ] do
        persist = fn _ref, _sentinel -> {:error, refusal} end

        assert Webhook.ensure_path_secret("gh-hooks", config: config, persist: persist) ==
                 {:error, refusal}

        assert SecretWriterStub.get({:cue_source, "gh-hooks", :path_secret}, store: :keyring) ==
                 {:error, :missing_secret}
      end

      persist = fn _ref, _sentinel -> {:error, :source_not_saved} end

      assert {:error, message} =
               Webhook.ensure_path_secret("gh-hooks", config: config, persist: persist)

      assert message == "The URL for gh-hooks was not saved. See the daemon log."
    end

    test "only a configured webhook source has a URL" do
      config =
        normalize(%{
          "gh-hooks" => %{"preset" => "github", "secret" => "@keyring"},
          "home-alerts" => %{"kind" => "local_push", "token" => "@keyring"}
        })

      assert Webhook.ensure_path_secret("nope", config: config) ==
               {:error, "There is no source nope; save it first."}

      assert Webhook.ensure_path_secret("home-alerts", config: config) ==
               {:error,
                "Source home-alerts is a local_push source; only a webhook source has a URL."}
    end

    test "the saved sentinel lands in the source's section of the snapshot" do
      snapshot = %{
        fermix_core: [
          profile: "general",
          cues: [
            enabled: true,
            sources: %{"gh-hooks" => [preset: "github", secret: "@keyring"]}
          ]
        ]
      }

      updated = Webhook.put_path_sentinel(snapshot, "gh-hooks", "@file")

      assert updated.fermix_core[:cues][:sources]["gh-hooks"] ==
               [preset: "github", secret: "@keyring", path_secret: "@file"]

      assert updated.fermix_core[:cues][:enabled] == true
      assert updated.fermix_core[:profile] == "general"
    end
  end
end
