defmodule FermixCore.Cues.ConfigTest do
  # async: false — the accessors read global application environment, and the
  # secret tests share the stub writer's table.
  use ExUnit.Case, async: false

  alias FermixCore.Cues.Config
  alias FermixTestSupport.SecretWriterStub

  setup do
    cues = Application.get_env(:fermix_core, :cues)
    profile = Application.get_env(:fermix_core, :profile)
    writer = Application.get_env(:fermix_core, :secret_writer)

    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    Application.delete_env(:fermix_core, :profile)
    SecretWriterStub.reset()

    on_exit(fn ->
      restore(:cues, cues)
      restore(:profile, profile)
      restore(:secret_writer, writer)
      SecretWriterStub.reset()
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)

  # The shape `ConfigStore.parse_document/1` hands over: string keys, TOML values.
  defp toml_section do
    %{
      "enabled" => true,
      "mandates_enabled" => false,
      "door_port" => 4555,
      "sources" => %{
        "eng-blogs" => %{
          "preset" => "rss",
          "url" => "https://example.org/releases.atom",
          "interval" => 300
        },
        "home-alerts" => %{"kind" => "local_push", "token" => "@keyring", "daily_budget" => 500},
        "gh-hooks" => %{
          "kind" => "webhook",
          "verify" => "hmac",
          "header" => "X-Hub-Signature-256",
          "algorithm" => "sha256",
          "prefix" => "sha256=",
          "id_header" => "X-GitHub-Delivery",
          "type_header" => "X-GitHub-Event",
          "secret" => "@file"
        }
      },
      "mandates" => %{
        "release-issues" => %{
          "job" => "release_watch_4b1e",
          "mode" => "approve",
          "approve_within" => "30m",
          "tools" => ["github_create_issue"],
          "read_tools" => ["github_search_issues"],
          "max_cue_age" => "15m",
          "pin_args" => %{"owner" => "example-org", "draft" => true, "limit" => 3}
        }
      }
    }
  end

  # A general WebSocket source with every field it takes.
  defp general_stream do
    %{
      "kind" => "stream",
      "url" => "wss://stream.example.com/v2/news",
      "key" => "@keyring",
      "secret" => "@file",
      "key_header" => "X-Feed-Key",
      "secret_header" => "X-Feed-Secret",
      "auth_message" => ~s({"action":"auth","key":"{{key}}","secret":"{{secret}}"}),
      "subscribe_message" => ~s({"action":"subscribe","news":["*"]}),
      "items_path" => ".",
      "id_path" => "id",
      "revision_path" => "updated_at",
      "type_path" => "T",
      "subject_path" => "symbols.0",
      "time_path" => "created_at",
      "item_types" => ["n"],
      "error_types" => ["error"],
      "daily_budget" => 2_000
    }
  end

  describe "normalize/1" do
    test "nil and an empty section normalize to nothing" do
      assert Config.normalize(nil) == []
      assert Config.normalize(%{}) == []
    end

    test "a full TOML section normalizes to the internal shape, present keys only" do
      config = Config.normalize(toml_section())

      assert config[:enabled] == true
      assert config[:mandates_enabled] == false
      assert config[:door_port] == 4555

      assert config[:sources]["home-alerts"] ==
               [kind: :local_push, daily_budget: 500, token: "@keyring"]

      assert config[:sources]["eng-blogs"] ==
               [preset: "rss", url: "https://example.org/releases.atom", interval: 300]

      assert config[:sources]["gh-hooks"][:verify] == :hmac

      mandate = config[:mandates]["release-issues"]
      assert mandate[:mode] == :approve
      assert mandate[:approve_within] == "30m"
      assert mandate[:max_cue_age] == "15m"
      assert mandate[:pin_args] == %{"owner" => "example-org", "draft" => true, "limit" => 3}
    end

    test "normalize is idempotent over its own output and over to_keyword's" do
      once = Config.normalize(put_in(toml_section(), ["sources", "live-news"], general_stream()))

      assert Config.normalize(once) == once
      assert once |> Config.to_keyword() |> Config.normalize() == once
    end

    test "to_keyword spells every enumeration the way the parser reads it" do
      persisted = toml_section() |> Config.normalize() |> Config.to_keyword()

      assert persisted[:sources]["home-alerts"][:kind] == "local_push"
      assert persisted[:sources]["gh-hooks"][:verify] == "hmac"
      assert persisted[:mandates]["release-issues"][:mode] == "approve"
    end

    test "an unknown top-level key is refused by name" do
      assert_raise ArgumentError, ~r/\[fermix_core\.cues\].*unknown key\(s\): enabld/s, fn ->
        Config.normalize(%{"enabld" => true})
      end
    end

    test "an unknown source key is refused by name with the section" do
      assert_raise ArgumentError,
                   ~r/\[fermix_core\.cues\.sources\.home-alerts\].*unknown key\(s\): tokn/s,
                   fn ->
                     Config.normalize(%{
                       "sources" => %{"home-alerts" => %{"kind" => "local_push", "tokn" => "x"}}
                     })
                   end
    end

    test "an unknown mandate key is refused by name with the section" do
      assert_raise ArgumentError,
                   ~r/\[fermix_core\.cues\.mandates\.m1\].*unknown key\(s\): toolz/s,
                   fn ->
                     Config.normalize(%{"mandates" => %{"m1" => %{"job" => "j", "toolz" => []}}})
                   end
    end

    test "value errors name the key" do
      cases = [
        {%{"enabled" => "yes"}, ~r/cues\.enabled/},
        {%{"mandates_enabled" => 1}, ~r/cues\.mandates_enabled/},
        {%{"door_port" => 80}, ~r/cues\.door_port.*1024/},
        {%{"door_port" => 70_000}, ~r/cues\.door_port/},
        {source(%{"kind" => "carrier_pigeon"}), ~r/sources\.s1\.kind/},
        {source(%{"kind" => "feed", "url" => "https://e.test/f", "interval" => 30}),
         ~r/sources\.s1\.interval.*at least 60/},
        {source(%{"kind" => "local_push", "token" => "@keyring", "daily_budget" => -1}),
         ~r/sources\.s1\.daily_budget/},
        {source(%{"kind" => "webhook", "verify" => "trust_me"}), ~r/sources\.s1\.verify/},
        {source(%{"kind" => "webhook", "verify" => "hmac", "id" => "uuid"}), ~r/sources\.s1\.id/},
        {source(%{"kind" => "stream", "url" => "wss://e.test", "item_types" => "n"}),
         ~r/sources\.s1\.item_types/},
        {source(%{"kind" => "stream", "url" => ""}), ~r/sources\.s1\.url/},
        {source(%{"enabled" => "true", "kind" => "local_push", "token" => "@keyring"}),
         ~r/sources\.s1\.enabled/},
        {mandate(%{"mode" => "yolo"}), ~r/mandates\.m1\.mode/},
        {mandate(%{"approve_within" => "25h"}), ~r/mandates\.m1\.approve_within.*24/},
        {mandate(%{"approve_within" => 1800}), ~r/mandates\.m1\.approve_within/},
        {mandate(%{"approve_within" => "0"}), ~r/mandates\.m1\.approve_within/},
        {mandate(%{"max_cue_age" => "15 minutes"}), ~r/mandates\.m1\.max_cue_age/},
        {mandate(%{"tools" => "github_create_issue"}), ~r/mandates\.m1\.tools/},
        {mandate(%{"read_tools" => [1]}), ~r/mandates\.m1\.read_tools/},
        {mandate(%{"validator_env" => [""]}), ~r/mandates\.m1\.validator_env/},
        {mandate(%{"enabled" => "no"}), ~r/mandates\.m1\.enabled/},
        {mandate(%{"pin_args" => "{ owner = \"x\" }"}), ~r/mandates\.m1\.pin_args.*table/},
        {mandate(%{"pin_args" => %{"owner" => ["a"]}}), ~r/mandates\.m1\.pin_args\.owner/},
        {mandate(%{"pin_args" => %{"bad key" => "a"}}), ~r/mandates\.m1\.pin_args/},
        {mandate(%{"pin_args" => %{"n" => -5}}), ~r/mandates\.m1\.pin_args\.n/}
      ]

      for {config, pattern} <- cases do
        assert_raise ArgumentError, pattern, fn -> Config.normalize(config) end
      end
    end

    test "a mandate needs a job" do
      assert_raise ArgumentError, ~r/mandates\.m1\.job/, fn ->
        Config.normalize(%{"mandates" => %{"m1" => %{"tools" => []}}})
      end
    end

    test "source refs and mandate names follow one rule" do
      for bad <- ["Eng", "-lead", "has space", "a.b", String.duplicate("a", 65), ""] do
        assert_raise ArgumentError, ~r/cues\.sources/, fn ->
          Config.normalize(%{
            "sources" => %{bad => %{"kind" => "local_push", "token" => "@file"}}
          })
        end

        assert_raise ArgumentError, ~r/cues\.mandates/, fn ->
          Config.normalize(%{"mandates" => %{bad => %{"job" => "j"}}})
        end
      end

      assert [sources: %{"a" => _}] =
               Config.normalize(%{
                 "sources" => %{"a" => %{"kind" => "local_push", "token" => "@file"}}
               })
    end

    test "a secret field takes only a sentinel, and the error never repeats the value" do
      error =
        assert_raise ArgumentError, fn ->
          Config.normalize(source(%{"kind" => "local_push", "token" => "sk-live-very-secret"}))
        end

      assert error.message =~ "sources.s1.token"
      assert error.message =~ ~s("@keyring" or "@file")
      assert error.message =~ "New token"
      refute error.message =~ "mix fermix.cues"
      refute error.message =~ "sk-live-very-secret"
    end

    # A release has no Mix tasks: a raw key or secret is sent to the source's
    # settings, or to `fermix settings` on a host without a browser.
    test "a raw secret is sent to the source's settings, and the error never repeats it" do
      error =
        assert_raise ArgumentError, fn ->
          Config.normalize(source(%{"kind" => "stream", "key" => "pk-live-very-secret"}))
        end

      assert error.message =~ "sources.s1.key"
      assert error.message =~ "Cues tab"
      assert error.message =~ "fermix settings secret set cue_source:s1:key"
      refute error.message =~ "mix fermix.cues"
      refute error.message =~ "pk-live-very-secret"
    end

    test "a source needs a kind, from itself or a preset" do
      assert_raise ArgumentError, ~r/sources\.s1.*needs a kind/, fn ->
        Config.normalize(source(%{"url" => "https://e.test/f"}))
      end
    end

    test "an unknown preset or one contradicted by kind is refused at load" do
      assert_raise ArgumentError, ~r/sources\.s1.*unknown preset "nope"/, fn ->
        Config.normalize(source(%{"preset" => "nope"}))
      end

      assert_raise ArgumentError, ~r/sources\.s1.*preset rss makes a feed source/, fn ->
        Config.normalize(source(%{"preset" => "rss", "kind" => "stream", "url" => "wss://e"}))
      end
    end

    # The engine ships no Bluesky preset: a section written for it does not
    # load, and the refusal names what is wrong, with no migration.
    test "a section written for the removed Bluesky preset is refused, naming the problem" do
      assert_raise ArgumentError,
                   ~s(cues.sources.s1: unknown preset "bluesky_jetstream"; known presets: ) <>
                     "github, rss, x_accounts",
                   fn -> Config.normalize(source(%{"preset" => "bluesky_jetstream"})) end

      for {section, unknown} <- [
            {%{"preset" => "bluesky_jetstream", "dids" => ["did:plc:abc123"]}, "dids"},
            {%{
               "preset" => "bluesky_jetstream",
               "dids" => ["did:plc:abc123"],
               "collections" => ["app.bsky.feed.post"]
             }, "collections, dids"},
            {%{
               "kind" => "stream",
               "url" => "wss://stream.example.com/v2/news",
               "id_path" => "id",
               "collections" => ["app.bsky.feed.post"]
             }, "collections"},
            {%{
               "kind" => "stream",
               "url" => "wss://stream.example.com/v2/news",
               "id_path" => "id",
               "symbols" => ["KTRL"]
             }, "symbols"}
          ] do
        error = assert_raise ArgumentError, fn -> Config.normalize(source(section)) end
        assert error.message =~ "[fermix_core.cues.sources.s1] has unknown key(s): #{unknown}."
      end
    end

    test "a field that does not apply to the source's kind is refused" do
      assert_raise ArgumentError, ~r/sources\.s1\.interval.*feed/, fn ->
        Config.normalize(
          source(%{"kind" => "local_push", "token" => "@keyring", "interval" => 60})
        )
      end

      assert_raise ArgumentError, ~r/sources\.s1\.verify.*webhook/, fn ->
        Config.normalize(source(%{"preset" => "rss", "url" => "https://e", "verify" => "hmac"}))
      end
    end

    test "each kind's required fields are required" do
      assert_raise ArgumentError, ~r/sources\.s1 .*needs url/, fn ->
        Config.normalize(source(%{"preset" => "rss"}))
      end

      assert_raise ArgumentError, ~r/sources\.s1 .*needs interval/, fn ->
        Config.normalize(source(%{"kind" => "feed", "url" => "https://e"}))
      end

      assert_raise ArgumentError, ~r/sources\.s1 .*needs verify/, fn ->
        Config.normalize(source(%{"kind" => "webhook"}))
      end
    end

    # M60 app surface §3.5, §3.8 item 3: a source is added first and its secret
    # stored after, and a hand-edited file may name a source before its secret
    # is stored. Either loads the source waiting for the secret instead of
    # refusing the whole section.
    test "a source whose required secret is not stored loads waiting for it" do
      cues = Config.normalize(source(%{"kind" => "local_push"}))

      assert {:ok, push} = Config.source("s1", cues)
      assert push.missing_secret == :token
      assert push.secrets == %{}

      cues = Config.normalize(source(%{"preset" => "github"}))
      assert {:ok, %{missing_secret: :secret}} = Config.source("s1", cues)

      cues = Config.normalize(source(%{"kind" => "local_push", "token" => "@file"}))
      assert {:ok, %{missing_secret: nil}} = Config.source("s1", cues)

      cues = Config.normalize(source(%{"preset" => "rss", "url" => "https://e"}))
      assert {:ok, %{missing_secret: nil}} = Config.source("s1", cues)
    end

    test "each kind declares its secret fields, and a source the ones it needs" do
      assert Config.secret_fields(:local_push) == [:token]
      assert Config.secret_fields(:webhook) == [:key, :secret, :path_secret]
      assert Config.secret_fields(:feed) == [:key, :secret]
      assert Config.secret_fields(:stream) == [:key, :secret]

      assert Config.needed_secrets(%{kind: :local_push}) == [:token]
      assert Config.needed_secrets(%{kind: :webhook, preset: "github"}) == [:secret]
      assert Config.needed_secrets(%{kind: :feed, preset: "rss"}) == []
      assert Config.needed_secrets(%{kind: :stream, preset: nil}) == []

      assert Config.needed_secrets(%{kind: :stream, preset: nil, key_header: "X-Feed-Key"}) ==
               [:key]

      general = %{kind: :stream, preset: nil, auth_message: ~s({"k":"{{key}}","s":"{{secret}}"})}
      assert Config.needed_secrets(general) == [:key, :secret]
    end

    # A stream with no preset signs in with what its fields name; until each is
    # stored it waits, naming the first one missing, key before secret.
    test "a general stream waits for the first secret its sign-in names" do
      base = %{
        "kind" => "stream",
        "url" => "wss://stream.example.com/v2/news",
        "id_path" => "id",
        "key_header" => "X-Feed-Key",
        "auth_message" => ~s({"action":"auth","secret":"{{secret}}"})
      }

      for {stored, missing} <- [
            {%{}, :key},
            {%{"secret" => "@keyring"}, :key},
            {%{"key" => "@keyring"}, :secret},
            {%{"key" => "@keyring", "secret" => "@file"}, nil}
          ] do
        cues = Config.normalize(source(Map.merge(base, stored)))
        assert {:ok, %{missing_secret: ^missing}} = Config.source("s1", cues)
      end

      no_sign_in = Map.drop(base, ["key_header", "auth_message"])

      assert {:ok, %{missing_secret: nil}} =
               Config.source("s1", Config.normalize(source(no_sign_in)))
    end

    # The feed worker refuses a plain-text URL at poll time; the config refuses it
    # first, so a typo never becomes a source that only fails once it runs.
    test "a feed URL must be https and a stream URL wss" do
      assert_raise ArgumentError, ~r/sources\.s1\.url must start with https:\/\//, fn ->
        Config.normalize(source(%{"preset" => "rss", "url" => "http://example.org/feed"}))
      end

      for url <- ["ws://stream.example.com/v2/news", "https://stream.example.com/v2/news"] do
        assert_raise ArgumentError, ~r/sources\.s1\.url must start with wss:\/\/$/, fn ->
          Config.normalize(source(%{"kind" => "stream", "url" => url, "id_path" => "id"}))
        end
      end
    end

    # The general WebSocket source (a stream with no preset): its own fields,
    # each refused under its own key.
    test "a general stream's fields load, and each of its rules names the field it refuses" do
      section = %{
        "kind" => "stream",
        "url" => "wss://stream.example.com/v2/news",
        "key" => "@keyring",
        "key_header" => "X-Feed-Key",
        "subscribe_message" => ~s({"action":"subscribe","news":["*"]}),
        "type_path" => "T",
        "item_types" => ["n"],
        "error_types" => ["error"],
        "id_path" => "id"
      }

      assert {:ok, stream} = Config.source("s1", Config.normalize(source(section)))
      assert stream.key_header == "X-Feed-Key"
      assert stream.item_types == ["n"]
      assert stream.error_types == ["error"]
      assert stream.missing_secret == nil

      for {change, pattern} <- [
            {%{"id_path" => nil}, ~r/sources\.s1 is a stream source and needs id_path/},
            {%{"key_header" => "Sec-WebSocket-Key"}, ~r/sources\.s1\.key_header is a header/},
            {%{"auth_message" => ~s({"key":{{key}}})}, ~r/sources\.s1\.auth_message must be/},
            {%{"subscribe_message" => "[subscribe"}, ~r/sources\.s1\.subscribe_message must/},
            {%{"type_path" => nil}, ~r/sources\.s1\.item_types needs type_path/},
            {%{"url" => "wss:///news"}, ~r/sources\.s1\.url must name a host/},
            {%{"item_types" => "n"}, ~r/sources\.s1\.item_types/}
          ] do
        changed = section |> Map.merge(change) |> Enum.reject(&is_nil(elem(&1, 1))) |> Map.new()
        assert_raise ArgumentError, pattern, fn -> Config.normalize(source(changed)) end
      end
    end

    test "items_path needs id_path, or no item would have an identity" do
      assert_raise ArgumentError, ~r/sources\.s1\.items_path needs id_path/, fn ->
        Config.normalize(
          source(%{
            "kind" => "feed",
            "url" => "https://e",
            "interval" => 60,
            "items_path" => "data.items"
          })
        )
      end
    end

    test "empty tables and lists keep their round-trip shape" do
      config = Config.normalize(%{"sources" => %{}, "mandates" => %{"m1" => %{"job" => "j"}}})
      refute Keyword.has_key?(config, :sources)

      assert Config.normalize(mandate(%{"tools" => [], "pin_args" => %{}})) ==
               [mandates: %{"m1" => [job: "j", tools: []]}]
    end
  end

  # M60_X_ACCOUNTS_SOURCE.md §3, §4: the handles are the source's whole
  # address; X accounts builds the rest.
  describe "an X accounts source" do
    test "its handles load lowercased, without @ and once each, and it polls every 5 minutes" do
      cues =
        Config.normalize(
          source(%{"preset" => "x_accounts", "handles" => ["@NASA", "nasa", "ESA"]})
        )

      assert cues[:sources]["s1"][:handles] == ["nasa", "esa"]
      assert Config.normalize(Config.to_keyword(cues)) == cues

      assert [x] = Config.sources(cues)
      assert %{kind: :feed, preset: "x_accounts", handles: ["nasa", "esa"], url: nil} = x
      assert x.interval == 300
    end

    test "it needs only its handles" do
      assert Config.required_fields(:feed, "x_accounts", nil) == [:handles]

      for empty <- [%{"preset" => "x_accounts"}, %{"preset" => "x_accounts", "handles" => []}] do
        assert_raise ArgumentError, ~r/sources\.s1 is a feed source and needs handles/, fn ->
          Config.normalize(source(empty))
        end
      end
    end

    test "a handle X would not take, or more than 20, is refused naming the field" do
      assert_raise ArgumentError, ~r/sources\.s1\.handles.*"no-dashes"/, fn ->
        Config.normalize(source(%{"preset" => "x_accounts", "handles" => ["nasa", "no-dashes"]}))
      end

      many = for n <- 1..21, do: "account_#{n}"

      assert_raise ArgumentError, ~r/sources\.s1\.handles.*20/, fn ->
        Config.normalize(source(%{"preset" => "x_accounts", "handles" => many}))
      end
    end

    test "a URL with the preset, or handles without it, is refused" do
      assert_raise ArgumentError, ~r/sources\.s1\.url.*x_accounts builds its own address/, fn ->
        Config.normalize(
          source(%{
            "preset" => "x_accounts",
            "handles" => ["nasa"],
            "url" => "https://api.x.com/2/tweets/search/recent"
          })
        )
      end

      for other <- [
            %{"preset" => "rss", "url" => "https://example.org/feed.xml"},
            %{"kind" => "feed", "url" => "https://example.org/feed.xml", "interval" => 300}
          ] do
        assert_raise ArgumentError, ~r/sources\.s1\.handles.*x_accounts/, fn ->
          Config.normalize(source(Map.put(other, "handles", ["nasa"])))
        end
      end

      assert_raise ArgumentError, ~r/sources\.s1\.handles applies only to feed/, fn ->
        Config.normalize(
          source(%{"kind" => "local_push", "token" => "@keyring", "handles" => ["nasa"]})
        )
      end
    end
  end

  describe "accessors" do
    test "the fields a source must name itself: its kind's, its method's and its preset's, less what the preset fills" do
      assert Config.required_fields(:feed, nil, nil) == [:url, :interval]
      assert Config.required_fields(:feed, "rss", nil) == [:url]
      assert Config.required_fields(:stream, nil, nil) == [:url, :id_path]
      assert Config.required_fields(:webhook, nil, nil) == [:verify]
      assert Config.required_fields(:webhook, nil, "hmac") == [:verify, :header]
      assert Config.required_fields(:webhook, nil, :shared_secret) == [:verify, :header]
      assert Config.required_fields(:webhook, nil, "standard_webhooks") == [:verify]
      assert Config.required_fields(:webhook, "github", nil) == []
      assert Config.required_fields(:webhook, "github", "shared_secret") == []
      assert Config.required_fields(:local_push, nil, nil) == []

      assert_raise ArgumentError, ~r/unknown preset "carrier"/, fn ->
        Config.required_fields(:feed, "carrier", nil)
      end

      assert_raise ArgumentError, ~r/unknown preset "bluesky_jetstream"/, fn ->
        Config.required_fields(:stream, "bluesky_jetstream", nil)
      end
    end

    test "a signed or shared-secret webhook needs an identity, from itself or its preset" do
      assert Config.identity_fields() == [:id_header, :id_path, :id]

      assert Config.missing_identity?(:webhook, nil, "hmac", %{header: "X-Sig"})
      assert Config.missing_identity?(:webhook, nil, :shared_secret, id: "")
      refute Config.missing_identity?(:webhook, nil, "hmac", id_header: "X-Id")
      refute Config.missing_identity?(:webhook, nil, :shared_secret, %{id: "content_hash"})
      refute Config.missing_identity?(:webhook, nil, "hmac", %{id_path: "event.id"})
      refute Config.missing_identity?(:webhook, nil, "standard_webhooks", %{})
      refute Config.missing_identity?(:webhook, "github", nil, %{})
      refute Config.missing_identity?(:feed, "rss", nil, %{})
    end

    test "a field the rule names, left out, is refused by the one presence check" do
      for {section, pattern} <- [
            {%{"kind" => "webhook", "verify" => "hmac", "id" => "content_hash"},
             ~r/sources\.s1 is a webhook source and needs header/},
            {%{"kind" => "stream", "url" => "wss://stream.example.com/v2/news"},
             ~r/sources\.s1 is a stream source and needs id_path/}
          ] do
        assert_raise ArgumentError, pattern, fn -> Config.normalize(source(section)) end
      end
    end

    test "defaults when nothing is configured" do
      Application.put_env(:fermix_core, :cues, [])

      refute Config.enabled?()
      assert Config.mandates_enabled?()
      assert Config.door_port() == 4032
      assert Config.sources() == []
      assert Config.source("eng-blogs") == :error
      assert Config.mandates() == []
    end

    test "sources resolve through presets into maps with defaults" do
      Application.put_env(:fermix_core, :cues, Config.normalize(toml_section()))

      assert Config.enabled?()
      refute Config.mandates_enabled?()
      assert Config.door_port() == 4555

      assert Enum.map(Config.sources(), & &1.ref) == ["eng-blogs", "gh-hooks", "home-alerts"]

      assert {:ok, feed} = Config.source("eng-blogs")
      assert feed.kind == :feed
      assert feed.preset == "rss"
      assert feed.enabled? == true
      assert feed.interval == 300
      assert feed.url == "https://example.org/releases.atom"
      assert feed.daily_budget == 0
      refute Map.has_key?(feed, :dids)
      assert feed.secrets == %{}

      assert {:ok, push} = Config.source("home-alerts")
      assert push.kind == :local_push
      assert push.daily_budget == 500
      assert push.secrets == %{token: :keyring}
      assert push.url == nil

      assert {:ok, hook} = Config.source("gh-hooks")
      assert hook.verify == :hmac
      assert hook.secrets == %{secret: :file}
      assert hook.id_header == "X-GitHub-Delivery"
    end

    test "a disabled source says so" do
      Application.put_env(
        :fermix_core,
        :cues,
        Config.normalize(
          source(%{"kind" => "local_push", "token" => "@file", "enabled" => false})
        )
      )

      assert {:ok, %{enabled?: false}} = Config.source("s1")
    end

    test "mandates come back parsed, with the defaults the design names" do
      Application.put_env(
        :fermix_core,
        :cues,
        Config.normalize(%{
          "mandates" => %{
            "release-issues" => toml_section()["mandates"]["release-issues"],
            "bare" => %{"job" => "job_2"}
          }
        })
      )

      assert [bare, release] = Config.mandates()

      assert bare == %{
               name: "bare",
               job: "job_2",
               enabled?: true,
               mode: :approve,
               approve_within_s: 1_800,
               tools: [],
               read_tools: [],
               max_cue_age_s: 900,
               validator: nil,
               interpreter: nil,
               validator_env: [],
               idempotency_arg: nil,
               unpinned: [],
               pin_args: %{}
             }

      assert release.name == "release-issues"
      assert release.tools == ["github_create_issue"]
      assert release.approve_within_s == 1_800
      assert release.max_cue_age_s == 900
      assert release.pin_args == %{"owner" => "example-org", "draft" => true, "limit" => 3}
    end

    test "max_cue_age \"0\" means none, and durations read in every unit" do
      Application.put_env(
        :fermix_core,
        :cues,
        Config.normalize(mandate(%{"max_cue_age" => "0", "approve_within" => "24h"}))
      )

      assert [%{max_cue_age_s: 0, approve_within_s: 86_400}] = Config.mandates()

      Application.put_env(
        :fermix_core,
        :cues,
        Config.normalize(mandate(%{"max_cue_age" => "90s", "approve_within" => "2h"}))
      )

      assert [%{max_cue_age_s: 90, approve_within_s: 7_200}] = Config.mandates()
    end
  end

  describe "secret/2" do
    setup do
      Application.put_env(
        :fermix_core,
        :cues,
        Config.normalize(%{
          "sources" => %{
            "home-alerts" => %{"kind" => "local_push", "token" => "@keyring"},
            "filed" => %{"kind" => "local_push", "token" => "@file"}
          }
        })
      )

      :ok
    end

    test "resolves the sentinel from the store it names" do
      :ok = SecretWriterStub.put({:cue_source, "home-alerts", :token}, "tok-1", store: :keyring)
      :ok = SecretWriterStub.put({:cue_source, "filed", :token}, "tok-2", store: :file)

      assert Config.secret("home-alerts", :token) == {:ok, "tok-1"}
      assert Config.secret("filed", :token) == {:ok, "tok-2"}
    end

    test "a value in the other store is not found" do
      :ok = SecretWriterStub.put({:cue_source, "filed", :token}, "tok-2", store: :keyring)
      assert Config.secret("filed", :token) == {:error, :missing_secret}
    end

    test "an unknown source or an undeclared field is an error, not a read" do
      assert Config.secret("nope", :token) == {:error, :unknown_source}
      assert Config.secret("home-alerts", :key) == {:error, {:secret_not_configured, :key}}
    end
  end

  defp source(section), do: %{"sources" => %{"s1" => section}}
  defp mandate(section), do: %{"mandates" => %{"m1" => Map.put(section, "job", "j")}}
end
