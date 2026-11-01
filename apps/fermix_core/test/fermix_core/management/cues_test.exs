defmodule FermixCore.Management.CuesTest do
  @moduledoc """
  The `cues.*` methods (M60 app surface §3.1 to §3.5) against the one write
  path, `Cues.Settings`, the setup page's own functions.

  Every case runs against its own home and the stub secret store, with a
  private temp Repo for the rows (`FermixTestSupport.CueFixtures`). No cue
  tree runs, so no door listens and no worker starts.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Cues.Config, as: CuesConfig
  alias FermixCore.Cues.Settings, as: CueSettings
  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Management.Cues
  alias FermixCore.Management.Cues.SourceForm
  alias FermixCore.Management.Cues.WatcherRow
  alias FermixCore.Management.Router
  alias FermixCore.Management.Secrets
  alias FermixCore.Management.Settings
  alias FermixCore.Management.Settings.Cues, as: SettingsCues
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Sandbox.PathPolicy
  alias FermixCore.Setup.RestartState
  alias FermixTestSupport.CueDeliveryFixtures, as: Rows
  alias FermixTestSupport.CueFixtures
  alias FermixTestSupport.MandateFixtures
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub
  alias FermixTestSupport.TelemetryCapture

  @now ~U[2026-10-17 12:00:00.000000Z]
  @memory_off "Cues keep their records in memory, which is off."

  # Stands in for `Cues.Proposals` (lane E2's `records/2`, `card/2` and
  # `decide/4`): answers from the process dictionary and reports each call.
  defmodule FakeProposals do
    @moduledoc false

    def records(state, opts) do
      send(self(), {:records, state, opts})
      {:ok, Map.fetch!(Process.get(:fake_proposals), state)}
    end

    def card("cpr_missing", _opts), do: {:error, :not_found}

    def card(id, _opts),
      do: {:ok, Map.put(record(id, :waiting), :summary, "A task wants to act.")}

    def decide("cpr_expired", _decision, _origin, _opts),
      do: {:error, "That proposal expired; nothing ran."}

    def decide(id, decision, origin, _opts) do
      send(self(), {:decided, id, decision, origin})
      state = if decision == :confirm, do: :confirmed, else: :denied
      {:ok, record(id, state)}
    end

    def record(id, state) do
      %{
        proposal_id: id,
        state: state,
        mandate: "release-issues",
        tool: "github_create_issue",
        task: %{job_id: "job_1", name: "Release watch"},
        watcher: "release-watch",
        source_ref: "eng-blogs",
        created_at: ~U[2026-10-17 11:50:00Z],
        expires_at: ~U[2026-10-17 12:20:00Z],
        decided_at: nil,
        decided_from: nil,
        result_status: nil,
        status_sentence: "Waiting for your decision."
      }
    end
  end

  setup do
    home = SafeRm.make_tmp_dir!("management-cues")
    previous_home = System.get_env("FERMIX_HOME")
    previous_env = Application.get_all_env(:fermix_core)

    SecretWriterStub.reset()
    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    Application.delete_env(:fermix_core, :profile)
    Application.put_env(:fermix_core, :cues, [])
    Application.put_env(:fermix_core, :routing, [])
    System.put_env("FERMIX_HOME", home)
    :ok = RestartState.record_persisted_baseline()

    on_exit(fn ->
      restore_core_env(previous_env)
      SecretWriterStub.reset()
      restore_home(previous_home)
      SafeRm.rm_rf!(home)
      :ok = RestartState.record_persisted_baseline()
    end)

    %{repo: repo, conn: conn} = CueFixtures.start_repo("management")

    opts = [
      memory?: true,
      running?: false,
      repo: repo,
      door: :management_cues_test_no_door,
      now: fn -> @now end
    ]

    %{home: home, opts: opts, repo: repo, conn: conn}
  end

  defp restore_core_env(previous) do
    for {key, _value} <- Application.get_all_env(:fermix_core),
        not Keyword.has_key?(previous, key) do
      Application.delete_env(:fermix_core, key)
    end

    Enum.each(previous, fn {key, value} -> Application.put_env(:fermix_core, key, value) end)
  end

  defp restore_home(nil), do: System.delete_env("FERMIX_HOME")
  defp restore_home(value), do: System.put_env("FERMIX_HOME", value)

  defp config_text(home), do: File.read!(Path.join(home, "config.toml"))

  defp stream_config do
    CuesConfig.normalize(%{
      "enabled" => true,
      "sources" => %{
        "bsky" => %{
          "kind" => "stream",
          "url" => "wss://jetstream.example.org/subscribe",
          "id_path" => "id"
        }
      }
    })
  end

  defp listen_for!(conn, id, words),
    do:
      CueFixtures.exec!(conn, "UPDATE cue_watchers SET listen_for = ? WHERE id = ?", [
        Jason.encode!(words),
        id
      ])

  defp counts!(repo, rows) do
    rows =
      for {scope, ref, hour, incarnation, counts} <- rows,
          do: %{scope: scope, ref: ref, hour: hour, incarnation: incarnation, counts: counts}

    {:ok, _written} = Repo.cues_call(CuesSql, {:counts_put, rows, @now}, server: repo)
  end

  defp route(method, params, cue_opts) do
    request = %{request_id: "req-1", protocol_version: 2, method: method, params: params}
    Router.route(request, operation_opts: [cues: cue_opts])
  end

  defp add_feed(opts, ref \\ "eng-blogs") do
    {:ok, _} =
      Cues.sources_add(
        ref,
        nil,
        "rss",
        %{"url" => "https://example.org/releases.atom"},
        opts
      )
  end

  describe "cues.status" do
    test "off, waiting for memory, waiting for a restart, and running", %{opts: opts} do
      assert {:ok, %{"state" => "off", "status_sentence" => "Cues are off."}} = Cues.status(opts)

      Application.put_env(:fermix_core, :cues, enabled: true)

      assert {:ok, %{"state" => "needs_memory", "status_sentence" => @memory_off}} =
               Cues.status(Keyword.put(opts, :memory?, false))

      assert {:ok, %{"state" => "needs_restart"}} = Cues.status(opts)
      assert {:ok, %{"state" => "running"}} = Cues.status(Keyword.put(opts, :running?, true))

      Application.put_env(:fermix_core, :cues, enabled: false)

      assert {:ok, %{"state" => "needs_restart", "status_sentence" => sentence}} =
               Cues.status(Keyword.put(opts, :running?, true))

      assert sentence == "Restart Fermix to stop cues."
    end

    test "the door says where it would listen while it is not running", %{opts: opts} do
      assert {:ok, %{"door" => door}} = Cues.status(opts)

      assert door == %{
               "state" => "not_running",
               "port" => 4032,
               "reason" => nil,
               "sentence" => "The door is not running."
             }
    end

    test "the counts read the sources, watchers, mandates and waiting proposals", %{
      opts: opts,
      conn: conn
    } do
      add_feed(opts)
      # A webhook waiting for its secret needs the owner's attention.
      standard = %{"verify" => "standard_webhooks"}
      {:ok, _} = Cues.sources_add("shop-hooks", "webhook", nil, standard, opts)

      for name <- ["release-watch", "quiet-watch"] do
        id = CueFixtures.insert_watcher(conn, %{name: name, filter: "llm", sources: ["x"]})
        listen_for!(conn, id, ["release"])
      end

      # Held from the third provider failure in a row; the other filters normally.
      CueFixtures.exec!(
        conn,
        "UPDATE cue_watchers SET filter_failures = 3 WHERE name = 'release-watch'",
        []
      )

      Process.put(:fake_proposals, %{waiting: [FakeProposals.record("cpr_1", :waiting)]})

      assert {:ok, %{"counts" => counts}} =
               Cues.status(Keyword.put(opts, :proposals, FakeProposals))

      assert counts == %{
               "sources" => 2,
               "sources_attention" => 1,
               "watchers" => 2,
               "watchers_held" => 1,
               "mandates" => 0,
               "mandates_attention" => 0,
               "proposals_waiting" => 1
             }
    end
  end

  describe "every build" do
    # D1: every build has cues, so the methods, the status and the section are
    # on all of them.
    test "publishes the cues section and a status that says cues are here", %{opts: opts} do
      assert Enum.any?(Settings.sections(), &(&1.id == "cues"))
      assert {:ok, %{"available" => true}} = route("cues.status", %{}, opts)
    end
  end

  describe "memory off" do
    test "the reads that need rows answer unavailable with the daemon's sentence", %{opts: opts} do
      opts = Keyword.put(opts, :memory?, false)
      refusal = {:error, :unavailable, %{"capability" => "cues", "sentence" => @memory_off}}

      for {method, params} <- [
            {"cues.watchers.list", %{}},
            {"cues.watchers.get", %{"name" => "w"}},
            {"cues.mandates.choices", %{}},
            {"cues.proposals.list", %{}},
            {"cues.proposals.get", %{"proposal_id" => "cpr_1"}},
            {"cues.proposals.decide", %{"proposal_id" => "cpr_1", "decision" => "confirm"}}
          ] do
        assert route(method, params, opts) == refusal, method
      end
    end

    test "the lists are drawn from configuration", %{opts: opts} do
      add_feed(opts)
      opts = Keyword.put(opts, :memory?, false)

      assert {:ok, %{"sources" => [row]}} = Cues.sources_list(opts)
      assert %{"state" => "not_running", "status_sentence" => @memory_off} = row
      assert {:ok, %{"mandates" => []}} = Cues.mandates_list(opts)
    end
  end

  describe "sources" do
    test "a feed added here reads back from the settings file as a hand edit holds it", %{
      opts: opts,
      home: home
    } do
      assert {:ok, %{"source" => row, "token" => nil}} =
               Cues.sources_add(
                 "eng-blogs",
                 nil,
                 "rss",
                 %{"url" => "https://example.org/releases.atom", "interval_minutes" => 15},
                 opts
               )

      assert %{
               "ref" => "eng-blogs",
               "kind" => "feed",
               "preset" => "rss",
               "label" => "RSS, Atom or JSON Feed",
               "enabled" => true,
               "state" => "not_running",
               "status_sentence" => "Cues are off.",
               "location" => "example.org",
               "url" => "https://example.org/releases.atom",
               "secrets" => [],
               "missing_secret" => nil,
               "primary_action" => nil,
               "actions" => ["disable"]
             } = row

      text = config_text(home)
      assert text =~ "[fermix_core.cues.sources.eng-blogs]"
      assert text =~ ~s(preset = "rss")
      assert text =~ ~s(url = "https://example.org/releases.atom")
      # Fifteen minutes is what the preset polls at, so it is left to the preset.
      refute text =~ ~r/^interval = /m

      assert {:ok, persisted} = RestartState.load_persisted()
      sources = persisted.fermix_core |> Keyword.fetch!(:cues) |> Keyword.fetch!(:sources)
      assert Map.keys(sources) == ["eng-blogs"]
    end

    test "a settings save after a socket write is not refused as an outside edit", %{opts: opts} do
      add_feed(opts)

      assert {:ok, %{"applied" => ["cues_mandates_enabled"]}} =
               Settings.apply("cues", %{"cues_mandates_enabled" => false})
    end

    test "a new local push source hands out its first token once", %{opts: opts, home: home} do
      assert {:ok, %{"source" => row, "token" => token}} =
               Cues.sources_add("home-alerts", "local_push", nil, %{}, opts)

      assert is_binary(token) and byte_size(token) >= 40

      assert %{
               "secrets" => [%{"field" => "token", "label" => "Token", "present" => true}],
               "actions" => ["disable", "new_token"],
               "status_sentence" => "Cues are off."
             } = row

      refute config_text(home) =~ token
      {:ok, list} = Cues.sources_list(opts)
      refute inspect(list) =~ token
    end

    # M60 simpler setup D2: the name is optional, and the answer's row carries
    # the one in force, which a client stores typed secrets under.
    test "a source left unnamed is named from what it reads, and a typed name is kept", %{
      opts: opts,
      home: home
    } do
      hn = %{"url" => "https://news.ycombinator.com/rss"}

      assert {:ok, %{"source" => %{"ref" => "ycombinator"}, "token" => nil, "secret" => nil}} =
               Cues.sources_add(nil, nil, "rss", hn, opts)

      assert {:ok, %{"source" => %{"ref" => "ycombinator-2"}}} =
               Cues.sources_add("", nil, "rss", hn, opts)

      # Adding X accounts never waits on the X sign-in.
      unasked = Keyword.put(opts, :x_sign_in, fn -> flunk("an add asks for no sign-in") end)

      assert {:ok, %{"source" => %{"ref" => "x-nasa"}}} =
               Cues.sources_add(nil, nil, "x_accounts", %{"handles" => ["@NASA"]}, unasked)

      assert {:ok, %{"source" => %{"ref" => "scripts"}, "token" => token}} =
               Cues.sources_add(nil, "local_push", nil, %{}, opts)

      assert SecretWriterStub.get({:cue_source, "scripts", :token}, store: :keyring) ==
               {:ok, token}

      assert {:ok, %{"source" => %{"ref" => "hn-front"}}} =
               Cues.sources_add("hn-front", nil, "rss", hn, opts)

      # The socket takes an add with no name at all.
      standard = %{"verify" => "standard_webhooks"}

      assert {:ok, %{"source" => %{"ref" => "webhook"}, "secret" => nil}} =
               route("cues.sources.add", %{"kind" => "webhook", "values" => standard}, opts)

      text = config_text(home)

      for ref <- ~w(ycombinator ycombinator-2 x-nasa scripts hn-front webhook),
          do: assert(text =~ "[fermix_core.cues.sources.#{ref}]", ref)
    end

    # M60 simpler setup D3: GitHub's secret is Fermix's to make, as a local
    # push token is, and is handed out once, beside the token.
    test "a GitHub source gets a secret Fermix makes, handed out once and stored as a typed one",
         %{opts: opts, home: home} do
      log =
        capture_log(fn ->
          send(self(), {:added, Cues.sources_add(nil, nil, "github", %{}, opts)})
        end)

      assert_received {:added, {:ok, %{"source" => row, "token" => nil, "secret" => secret}}}
      assert is_binary(secret) and byte_size(secret) >= 40

      # Its next step is the address to paste into GitHub beside the secret.
      assert %{
               "ref" => "github",
               "missing_secret" => nil,
               "primary_action" => "get_url",
               "secrets" => [
                 %{"field" => "secret", "present" => true},
                 %{"field" => "path_secret", "present" => false}
               ]
             } = row

      # Where a typed GitHub secret is stored: the keychain item the sentinel names.
      assert SecretWriterStub.get({:cue_source, "github", :secret}, store: :keyring) ==
               {:ok, secret}

      assert config_text(home) =~ ~s(secret = "@keyring")
      refute config_text(home) =~ secret
      refute log =~ secret

      # No later read repeats it.
      {:ok, list} = Cues.sources_list(opts)
      {:ok, got} = Cues.sources_get("github", opts)
      {:ok, form} = Cues.sources_form(nil, "github", nil)
      for answer <- [list, got, form], do: refute(inspect(answer) =~ secret)

      assert {:ok, %{"source" => %{"ref" => "github-2"}, "secret" => other}} =
               Cues.sources_add(nil, nil, "github", %{}, opts)

      assert is_binary(other) and other != secret

      # Every other add answers a null secret.
      assert {:ok, %{"secret" => nil, "token" => token}} =
               Cues.sources_add(nil, "local_push", nil, %{}, opts)

      assert is_binary(token)
    end

    test "a GitHub secret that cannot be stored leaves no source behind", %{
      opts: opts,
      home: home
    } do
      SecretWriterStub.set_verdict(%{store: :keyring, state: :locked, sentence: "locked"})
      on_exit(fn -> SecretWriterStub.clear_verdict(:keyring) end)

      log =
        capture_log(fn ->
          send(self(), {:added, Cues.sources_add(nil, nil, "github", %{}, opts)})
        end)

      assert_received {:added,
                       {:error, {:secret_store_failed, "cue_source:github:secret", "unavailable"}}}

      config = Path.join(home, "config.toml")
      refute File.exists?(config) and File.read!(config) =~ "[fermix_core.cues.sources.github]"
      assert CuesConfig.source("github") == :error
      assert log =~ "cue source github"
    end

    # The setup page's door: a secret the owner typed is kept, not replaced.
    test "a GitHub source given its secret keeps it" do
      assert CueSettings.add_source("repo-events", [preset: "github"], %{
               secret: "whsec-invented-4410"
             }) == {:ok, %{ref: "repo-events", token: nil, secret: nil}}

      assert SecretWriterStub.get({:cue_source, "repo-events", :secret}, store: :keyring) ==
               {:ok, "whsec-invented-4410"}
    end

    test "a webhook added before its secret waits for it, and storing it starts it", %{
      opts: opts,
      home: home
    } do
      standard = %{"verify" => "standard_webhooks"}

      assert {:ok, %{"source" => row, "secret" => nil}} =
               Cues.sources_add("shop-hooks", "webhook", nil, standard, opts)

      assert %{
               "state" => "needs_secret",
               "status_sentence" => "Waiting for its signing secret.",
               "missing_secret" => "secret",
               "primary_action" => "set_secret",
               "actions" => ["disable", "set_secret", "get_url"],
               "has_url" => false,
               "secrets" => [
                 %{"field" => "secret", "label" => "Signing secret", "present" => false},
                 %{"field" => "path_secret", "label" => "Address", "present" => false}
               ]
             } = row

      assert {:ok, %{"id" => "cue_source:shop-hooks:secret", "present" => true}} =
               Secrets.set("cue_source:shop-hooks:secret", "whsec-invented-7781")

      assert {:ok, %{"source" => stored}} = Cues.sources_get("shop-hooks", opts)
      assert %{"state" => "not_running", "missing_secret" => nil} = stored
      assert {:ok, %{missing_secret: nil}} = CuesConfig.source("shop-hooks")
      refute config_text(home) =~ "whsec-invented-7781"
      assert config_text(home) =~ ~s(secret = "@keyring")

      assert {:ok, %{"present" => false}} = Secrets.clear("cue_source:shop-hooks:secret")
      assert {:ok, %{missing_secret: :secret}} = CuesConfig.source("shop-hooks")
    end

    # The general WebSocket source signs in with a key and a secret, each its
    # own row and its own presence; it waits for the first one its sign-in
    # names, key before secret.
    test "a stream with no preset waits for each secret its sign-in names, one field at a time",
         %{opts: opts, home: home} do
      values = %{
        "url" => "wss://stream.example.com/v2/news",
        "key_header" => "X-Feed-Key",
        "auth_message" => ~s({"action":"auth","secret":"{{secret}}"}),
        "subscribe_message" => ~s({"action":"subscribe","news":["*"]}),
        "id_path" => "id",
        "type_path" => "T",
        "item_types" => ["n", " "],
        "error_types" => ["error"]
      }

      assert {:ok, %{"source" => row}} =
               Cues.sources_add("live-news", "stream", nil, values, opts)

      assert %{
               "label" => "Stream",
               "state" => "needs_secret",
               "status_sentence" => "Waiting for its key.",
               "missing_secret" => "key",
               "primary_action" => "set_secret",
               "actions" => ["disable", "set_secret"],
               "location" => "stream.example.com",
               "secrets" => [
                 %{"field" => "key", "label" => "API key", "present" => false},
                 %{"field" => "secret", "label" => "API secret", "present" => false}
               ]
             } = row

      text = config_text(home)
      assert text =~ ~s(kind = "stream")
      assert text =~ ~s(item_types = ["n"])
      assert text =~ "key_header = "

      assert {:ok, _} = Secrets.set("cue_source:live-news:key", "PK7Q2ZTW9M")
      assert {:ok, %{"source" => waiting, "values" => rows}} = Cues.sources_get("live-news", opts)
      assert %{"state" => "needs_secret", "missing_secret" => "secret"} = waiting

      assert [%{"key" => "key", "present" => true}, %{"key" => "secret", "present" => false}] =
               Enum.filter(rows, &(&1["kind"] == "secret"))

      # The edit form names each secret as the source's page does.
      assert for(%{"kind" => "secret", "label" => label} <- rows, do: label) ==
               Enum.map(row["secrets"], & &1["label"])

      assert {:ok, _} = Secrets.set("cue_source:live-news:secret", ~S(s3"cr\et))

      assert {:ok, %{"source" => %{"missing_secret" => nil}}} =
               Cues.sources_get("live-news", opts)

      refute config_text(home) =~ "PK7Q2ZTW9M"
    end

    test "a stream's refusals land under the row they are about", %{opts: opts} do
      base = %{"url" => "wss://stream.example.com/v2/news", "id_path" => "id"}
      add = fn values -> Cues.sources_add("live-news", "stream", nil, values, opts) end

      assert add.(Map.delete(base, "id_path")) ==
               {:error, {:invalid_params, "id_path", "Needed when no preset fills it."}}

      for {field, value, words} <- [
            {"key_header", "Sec-WebSocket-Key", "sets itself"},
            {"auth_message", ~s({"key":{{key}}}), "inside a JSON string"},
            {"subscribe_message", ~s({"key":"{{key}}"}), "no placeholder"},
            {"item_types", ["n"], "needs type_path"},
            {"url", "https://stream.example.com/v2/news", "wss://"}
          ] do
        assert {:error, {:invalid_params, ^field, sentence}} = add.(Map.put(base, field, value))
        assert sentence =~ words
      end

      assert add.(Map.put(base, "dids", ["did:plc:abc123"])) ==
               {:error, {:invalid_params, "dids", "This source has no setting by that name."}}

      assert add.(Map.put(base, "key", "PK7Q2ZTW9M")) ==
               {:error,
                {:invalid_params, "key", "This is a secret. Store it with secret.set instead."}}

      assert Cues.sources_add("bsky", nil, "bluesky_jetstream", %{"id_path" => "id"}, opts) ==
               {:error, {:invalid_params, "preset", "Fermix has no preset by that name."}}
    end

    # The settings file is checked and the change planned before the stored
    # item goes, so an outside edit never leaves a sentinel naming nothing.
    test "forgetting a secret under an outside edit keeps the stored item", %{
      opts: opts,
      home: home
    } do
      {:ok, _} = Cues.sources_add("gh-hooks", nil, "github", %{}, opts)
      {:ok, _} = Secrets.set("cue_source:gh-hooks:secret", "whsec-invented-7781")

      path = Path.join(home, "config.toml")

      File.write!(
        path,
        String.replace(
          File.read!(path),
          ~s(preset = "github"),
          ~s(preset = "github"\ndaily_budget = 9)
        )
      )

      assert {:error, {:external_change, _sections}} =
               FermixCore.Cues.Settings.clear_secret("gh-hooks", :secret)

      assert {:ok, "whsec-invented-7781"} =
               SecretWriterStub.get({:cue_source, "gh-hooks", :secret}, store: :keyring)
    end

    test "refusals name the field the form marks", %{opts: opts} do
      add_feed(opts)

      assert Cues.sources_add("eng-blogs", nil, "rss", %{"url" => "https://e"}, opts) ==
               {:error, {:invalid_params, "ref", "There is already a source named eng-blogs."}}

      assert {:error, {:invalid_params, "url", sentence}} =
               Cues.sources_add(
                 "plain",
                 "feed",
                 nil,
                 %{"url" => "http://e", "interval_minutes" => 5},
                 opts
               )

      assert sentence =~ "https://"

      # Thirty seconds: the config's floor is a minute, and its sentence names
      # `cues.sources.<ref>.interval`, the form's `interval_minutes`.
      assert {:error, {:invalid_params, "interval_minutes", _sentence}} =
               Cues.sources_add(
                 "fast",
                 "feed",
                 nil,
                 %{"url" => "https://e", "interval_minutes" => 0.5},
                 opts
               )

      assert Cues.sources_add("x", "feed", nil, %{"secret" => "s"}, opts) ==
               {:error,
                {:invalid_params, "secret", "This is a secret. Store it with secret.set instead."}}

      assert Cues.sources_add("x", "feed", nil, %{"bogus" => 1}, opts) ==
               {:error, {:invalid_params, "bogus", "This source has no setting by that name."}}

      assert Cues.sources_add("x", "local_push", nil, %{"url" => "https://e"}, opts) ==
               {:error,
                {:invalid_params, "url", "This setting does not apply to this kind of source."}}

      assert Cues.sources_get("nowhere", opts) ==
               {:error, {:invalid_params, "ref", "There is no source named nowhere."}}

      # The name's rule is said where a name breaks it, not on the row.
      assert {:error, {:invalid_params, "ref", name_rule}} =
               Cues.sources_add("Bad Name", "local_push", nil, %{}, opts)

      assert name_rule =~ "lowercase letters, digits and hyphens"
    end

    test "at most 64 sources are added", %{opts: opts} do
      sources = Map.new(1..64, &{"s#{&1}", [kind: :local_push, token: "@keyring"]})
      Application.put_env(:fermix_core, :cues, sources: sources)

      assert {:ok, %{"can_add" => false, "limits" => %{"max_sources" => 64}}} =
               Cues.sources_list(opts)

      assert Cues.sources_add("one-more", "local_push", nil, %{}, opts) ==
               {:error,
                {:invalid_params, "ref", "Fermix holds at most 64 sources. Remove one first."}}
    end

    # The refusal names the form's own row, so a client draws it under Poll
    # every or URL rather than the config's sentence under Name.
    test "a field the kind needs and no preset fills is refused under its own row", %{
      opts: opts,
      home: home
    } do
      url = %{"url" => "https://blog.example.org/feed.xml"}

      assert Cues.sources_add("blog-notes", "feed", nil, url, opts) ==
               {:error, {:invalid_params, "interval_minutes", "Needed when no preset fills it."}}

      assert Cues.sources_add("live-posts", "stream", nil, %{}, opts) ==
               {:error, {:invalid_params, "url", "Needed when no preset fills it."}}

      # A method's own needs are the same rule.
      hmac = %{"verify" => "hmac", "content_hash" => true}

      assert Cues.sources_add("shop-orders", "webhook", nil, hmac, opts) ==
               {:error, {:invalid_params, "header", "Needed when no preset fills it."}}

      # So is its identity: a delivery id header or items identified by content.
      signed = %{"verify" => "hmac", "header" => "X-Shop-Signature"}
      no_identity = "Give a delivery id header, or have Fermix identify items by their content."

      assert Cues.sources_add("shop-orders", "webhook", nil, signed, opts) ==
               {:error, {:invalid_params, "id_header", no_identity}}

      identified = Map.put(signed, "id_header", "X-Shop-Delivery")
      assert {:ok, _added} = Cues.sources_add("shop-orders", "webhook", nil, identified, opts)

      assert Cues.sources_update("shop-orders", %{"id_header" => ""}, opts) ==
               {:error, {:invalid_params, "id_header", no_identity}}

      add_feed(opts)
      refute config_text(home) =~ "blog-notes"
      refute config_text(home) =~ "live-posts"

      assert Cues.sources_update("eng-blogs", %{"url" => ""}, opts) ==
               {:error, {:invalid_params, "url", "Needed when no preset fills it."}}

      assert config_text(home) =~ "https://example.org/releases.atom"
    end

    test "an X accounts source is added and updated with its handles, and takes no URL", %{
      opts: opts,
      home: home
    } do
      assert Cues.sources_add("space-posts", nil, "x_accounts", %{}, opts) ==
               {:error, {:invalid_params, "handles", "Needed when no preset fills it."}}

      assert Cues.sources_add(
               "space-posts",
               nil,
               "x_accounts",
               %{"handles" => ["nasa"], "url" => "https://api.x.com/2/tweets/search/recent"},
               opts
             ) ==
               {:error,
                {:invalid_params, "url", "This setting does not apply to this kind of source."}}

      assert {:error, {:invalid_params, "handles", sentence}} =
               Cues.sources_add(
                 "space-posts",
                 nil,
                 "x_accounts",
                 %{"handles" => ["no-dashes"]},
                 opts
               )

      assert sentence =~ "no-dashes"

      assert {:ok, %{"source" => row}} =
               Cues.sources_add(
                 "space-posts",
                 nil,
                 "x_accounts",
                 %{"handles" => ["@NASA", " esa "]},
                 opts
               )

      assert %{"preset" => "x_accounts", "label" => "X accounts", "url" => nil} = row
      assert row["location"] == "@nasa, @esa"
      # Kept as X spells them in a search: no @, lowercased.
      assert config_text(home) =~ ~s(preset = "x_accounts")
      assert config_text(home) =~ ~s(handles = ["nasa", "esa"])
      refute config_text(home) =~ ~r/^url = /m

      assert {:ok, %{"values" => values}} = Cues.sources_get("space-posts", opts)
      assert %{"value" => ["nasa", "esa"]} = Enum.find(values, &(&1["key"] == "handles"))

      assert {:ok, %{"source" => %{"location" => "@spacex"}}} =
               Cues.sources_update("space-posts", %{"handles" => ["spacex"]}, opts)

      assert {:ok, persisted} = RestartState.load_persisted()
      sources = persisted.fermix_core |> Keyword.fetch!(:cues) |> Keyword.fetch!(:sources)
      assert Keyword.get(sources["space-posts"], :handles) == ["spacex"]
    end

    test "an update changes the fields it names and keeps the rest", %{opts: opts, home: home} do
      add_feed(opts)

      assert {:ok, %{"source" => %{"url" => "https://example.org/moved.atom"}}} =
               Cues.sources_update(
                 "eng-blogs",
                 %{"url" => "https://example.org/moved.atom", "daily_budget" => 50},
                 opts
               )

      assert config_text(home) =~ "daily_budget = 50"
      assert config_text(home) =~ ~s(preset = "rss")

      assert Cues.sources_update("eng-blogs", %{"kind" => "stream"}, opts) ==
               {:error, {:invalid_params, "kind", "This source has no setting by that name."}}
    end

    # The form of the new method hides the old one's fields, so a change of
    # method drops them rather than refusing under a field the owner cannot see.
    test "a webhook's change of method drops the old method's fields", %{
      opts: opts,
      home: home
    } do
      values = %{"verify" => "hmac", "header" => "X-Sig", "id_header" => "X-Delivery"}
      {:ok, _} = Cues.sources_add("hooks", "webhook", nil, values, opts)

      assert {:ok, %{"source" => %{"ref" => "hooks"}}} =
               Cues.sources_update("hooks", %{"verify" => "standard_webhooks"}, opts)

      text = config_text(home)
      assert text =~ ~s(verify = "standard_webhooks")
      refute text =~ "X-Sig"
      refute text =~ "X-Delivery"
    end

    test "switching a source off and on", %{opts: opts, home: home} do
      add_feed(opts)

      assert {:ok, %{"source" => off}} = Cues.sources_switch("eng-blogs", false, opts)

      assert %{"enabled" => false, "state" => "off", "primary_action" => "enable"} = off
      assert config_text(home) =~ "enabled = false"

      assert {:ok, %{"source" => %{"enabled" => true}}} =
               Cues.sources_switch("eng-blogs", true, opts)
    end

    test "removing a source deletes its secrets and names its watchers", %{
      opts: opts,
      conn: conn
    } do
      {:ok, %{"token" => _token}} = Cues.sources_add("home-alerts", "local_push", nil, %{}, opts)

      CueFixtures.insert_watcher(conn, %{
        name: "disk-watch",
        filter: "none",
        sources: ["home-alerts"]
      })

      assert {:ok,
              %{
                "ref" => "home-alerts",
                "removed" => true,
                "left" => [],
                "watchers" => ["disk-watch"]
              }} =
               Cues.sources_remove("home-alerts", opts)

      assert {:error, _missing} =
               SecretWriterStub.get({:cue_source, "home-alerts", :token}, store: :keyring)

      assert CuesConfig.source("home-alerts") == :error
    end

    # A hand-edited local push source with no token waits for one. Editing it
    # must not mint a token nobody is shown: only New token makes its first.
    test "an edit leaves a tokenless local push source waiting for New token", %{opts: opts} do
      Application.put_env(:fermix_core, :cues, sources: %{"new-alerts" => [kind: :local_push]})

      assert {:ok, %{"source" => row}} =
               Cues.sources_update("new-alerts", %{"daily_budget" => 5}, opts)

      assert %{"state" => "needs_secret", "primary_action" => "new_token", "daily_budget" => 5} =
               row

      assert {:error, _none} =
               SecretWriterStub.get({:cue_source, "new-alerts", :token}, store: :keyring)

      assert {:ok, %{"token" => token}} = Cues.sources_token_new("new-alerts", opts)

      assert {:ok, ^token} =
               SecretWriterStub.get({:cue_source, "new-alerts", :token}, store: :keyring)

      assert {:ok, %{missing_secret: nil}} = CuesConfig.source("new-alerts")
    end

    test "a new token replaces the old one, for a local push source only", %{opts: opts} do
      {:ok, %{"token" => first}} = Cues.sources_add("home-alerts", "local_push", nil, %{}, opts)

      assert {:ok, %{"ref" => "home-alerts", "token" => second}} =
               Cues.sources_token_new("home-alerts", opts)

      assert second != first

      assert {:ok, ^second} =
               SecretWriterStub.get({:cue_source, "home-alerts", :token}, store: :keyring)

      add_feed(opts)

      assert {:error, {:invalid_params, "ref", sentence}} =
               Cues.sources_token_new("eng-blogs", opts)

      assert sentence =~ "only a local-push source has a token"
    end

    test "a webhook's address is made on the first ask and the same after", %{opts: opts} do
      {:ok, _} = Cues.sources_add("gh-hooks", nil, "github", %{}, opts)

      assert {:ok, %{"ref" => "gh-hooks", "url" => url, "path" => path}} =
               Cues.sources_url_get("gh-hooks", opts)

      assert path =~ ~r{\A/cues/hooks/gh-hooks/[A-Za-z0-9_-]+\z}
      assert url == "http://127.0.0.1:4032" <> path
      assert {:ok, %{"path" => ^path}} = Cues.sources_url_get("gh-hooks", opts)

      assert {:ok, %{"source" => %{"has_url" => true}}} = Cues.sources_get("gh-hooks", opts)
      {:ok, list} = Cues.sources_list(opts)
      refute inspect(list) =~ path
    end

    # A webhook's first address saves its sentinel, so an outside edit refuses
    # it the way it refuses every cue write: as `external_change`, with nothing
    # stored, never as a sentence under a field.
    test "a webhook's first address is refused while an outside edit stands", %{
      opts: opts,
      home: home
    } do
      {:ok, _} = Cues.sources_add("gh-hooks", nil, "github", %{}, opts)
      path = Path.join(home, "config.toml")

      edited =
        String.replace(
          File.read!(path),
          ~s(preset = "github"),
          ~s(preset = "github"\ndaily_budget = 9)
        )

      assert edited != File.read!(path)
      File.write!(path, edited)

      assert {:error, :external_change, %{"section" => _section}} =
               route("cues.sources.url.get", %{"ref" => "gh-hooks"}, opts)

      assert {:error, _missing} =
               SecretWriterStub.get({:cue_source, "gh-hooks", :path_secret}, store: :keyring)
    end

    test "get carries the editable fields, the open gaps and the refused requests", %{
      opts: opts,
      repo: repo
    } do
      add_feed(opts)

      {:ok, _} =
        Repo.cues_call(CuesSql, {:source_reject, "eng-blogs", %{"unauthorized" => 3}, @now},
          server: repo
        )

      {:ok, _} =
        Repo.cues_call(
          CuesSql,
          {:extend_gap, "eng-blogs", nil, "inbox_full", 12, nil, @now},
          server: repo
        )

      assert {:ok, result} = Cues.sources_get("eng-blogs", opts)

      assert Enum.map(result["values"], & &1["key"]) ==
               ~w(url interval_minutes daily_budget)

      assert %{"value" => 15, "advanced" => true} =
               Enum.find(result["values"], &(&1["key"] == "interval_minutes"))

      assert result["rejected"] == [
               %{
                 "reason" => "unauthorized",
                 "count" => 3,
                 "sentence" => "3 refused without a valid signature or token."
               }
             ]

      assert [%{"reason" => "inbox_full", "count" => 12, "sentence" => sentence}] =
               result["gaps"]

      assert sentence == "12 items were not delivered: the inbox was full."
    end
  end

  describe "the source form" do
    @choices [
      %{
        "id" => "rss",
        "label" => "Website or blog",
        "sentence" => "New posts from a site's RSS, Atom or JSON feed.",
        "kind" => "feed",
        "preset" => "rss",
        "featured" => true
      },
      %{
        "id" => "x_accounts",
        "label" => "X accounts",
        "sentence" => "New posts from accounts you choose. Uses your X sign-in.",
        "kind" => "feed",
        "preset" => "x_accounts",
        "featured" => true
      },
      %{
        "id" => "github",
        "label" => "GitHub",
        "sentence" => "Pushes, issues and pull requests. Needs a tunnel to this computer.",
        "kind" => "webhook",
        "preset" => "github",
        "featured" => true
      },
      %{
        "id" => "local_push",
        "label" => "Your scripts",
        "sentence" => "Programs on this computer send items with a token.",
        "kind" => "local_push",
        "preset" => nil,
        "featured" => true
      },
      %{
        "id" => "feed",
        "label" => "Any feed address",
        "sentence" => "Fermix checks an address on a schedule.",
        "kind" => "feed",
        "preset" => nil,
        "featured" => false
      },
      %{
        "id" => "stream",
        "label" => "Live stream",
        "sentence" => "Fermix keeps a WebSocket connection open and takes items as they arrive.",
        "kind" => "stream",
        "preset" => nil,
        "featured" => false
      },
      %{
        "id" => "webhook",
        "label" => "Any webhook",
        "sentence" => "A service sends items to an address Fermix makes.",
        "kind" => "webhook",
        "preset" => nil,
        "featured" => false
      }
    ]

    defp form!(kind, preset, verify \\ nil) do
      {:ok, form} = Cues.sources_form(kind, preset, verify, signed_in())
      form
    end

    # Every form test that reaches X accounts answers its sign-in from here,
    # never from the plugin store or a token server.
    defp signed_in, do: [x_sign_in: fn -> :ready end]

    defp open_keys(form), do: for(row <- form["rows"], not row["advanced"], do: row["key"])
    defp labels(form), do: Map.new(form["rows"], &{&1["key"], &1["label"]})

    test "with nothing chosen it is a feed's" do
      assert {:ok, form} = Cues.sources_form(nil, nil, nil)

      assert Enum.map(form["kinds"], & &1["id"]) == ~w(feed stream webhook local_push)
      assert Enum.map(form["presets"], & &1["id"]) == ~w(github rss x_accounts)
      assert Enum.map(form["rows"], & &1["key"]) == ~w(ref url interval_minutes daily_budget)
      assert form["consent_sentence"] =~ "new items"
      assert form["notes"] == []
      assert form["requirement"] == nil
    end

    # A webhook has no URL to type and a local push no token to paste: the
    # kind's own line says Fermix makes them when the source is added.
    test "a kind that Fermix makes an address or a token for says so" do
      assert {:ok, form} = Cues.sources_form(nil, nil, nil)
      sentences = Map.new(form["kinds"], &{&1["id"], &1["sentence"]})

      assert sentences["webhook"] =~ "address Fermix makes when you add this source"
      assert sentences["local_push"] =~ "token made when you add this source"
    end

    # M60 simpler setup D1: the first question is what to watch, in the
    # daemon's words, and every answer carries the same list.
    test "every answer carries the same seven choices, featured first" do
      assert SourceForm.choices() == @choices

      for choice <- @choices do
        assert {:ok, %{"choices" => @choices}} =
                 Cues.sources_form(choice["kind"], choice["preset"], nil, signed_in()),
               choice["id"]
      end

      # The kinds and presets an older app draws are as they were.
      form = form!(nil, "rss")
      assert Enum.map(form["kinds"], & &1["label"]) == ["Feed", "Stream", "Webhook", "Local push"]

      assert Enum.map(form["presets"], & &1["label"]) ==
               ["GitHub", "RSS, Atom or JSON Feed", "X accounts"]
    end

    test "X accounts says whether the X sign-in is there; no other choice needs one" do
      requirement = fn sign_in ->
        {:ok, form} = Cues.sources_form(nil, "x_accounts", nil, x_sign_in: sign_in)
        form["requirement"]
      end

      assert requirement.(fn -> :ready end) ==
               %{"state" => "ready", "sentence" => "Signed in to X.", "plugin" => "x"}

      for reason <- [:x_plugin_not_installed, :x_plugin_off, :no_token, :sign_in_refused] do
        assert requirement.(fn -> {:error, reason} end) == %{
                 "state" => "needs_sign_in",
                 "sentence" => "Connect X to read these accounts.",
                 "plugin" => "x"
               }
      end

      unasked = [x_sign_in: fn -> flunk("only X accounts asks for the X sign-in") end]

      for choice <- @choices, choice["id"] != "x_accounts" do
        assert {:ok, %{"requirement" => nil}} =
                 Cues.sources_form(choice["kind"], choice["preset"], nil, unasked)
      end
    end

    # M60 simpler setup D2: the name comes last in importance, so it is folded,
    # empty, with what Fermix would call that choice as its example.
    test "the name is folded under More options, empty, with an example per choice" do
      examples = %{
        "rss" => "ycombinator",
        "x_accounts" => "x-nasa",
        "github" => "github",
        "local_push" => "scripts",
        "feed" => "weatherdesk",
        "stream" => "marketwire",
        "webhook" => "webhook"
      }

      for choice <- @choices do
        [name | _rest] = form!(choice["kind"], choice["preset"])["rows"]
        example = Map.fetch!(examples, choice["id"])

        assert %{
                 "key" => "ref",
                 "kind" => "text",
                 "label" => "Name",
                 "value" => "",
                 "advanced" => true,
                 "example" => ^example,
                 "info" =>
                   "How you and Fermix refer to it in chat. Left empty, Fermix names it " <>
                     "from what you enter."
               } = name

        assert SourceForm.name_row(choice["id"]) ==
                 %{label: name["label"], info: name["info"], example: example}
      end
    end

    # M60 simpler setup §3: each choice opens only what it needs; everything
    # else waits under More options with its current default.
    test "each choice opens only what it needs" do
      assert open_keys(form!(nil, "rss")) == ~w(url)
      assert open_keys(form!(nil, "x_accounts")) == ~w(handles)
      assert open_keys(form!(nil, "github")) == []
      assert open_keys(form!("local_push", nil)) == []
      assert open_keys(form!("feed", nil)) == ~w(url interval_minutes)
      assert open_keys(form!("stream", nil)) == ~w(url key secret subscribe_message id_path)
      assert open_keys(form!("webhook", nil)) == ~w(verify secret)
      assert open_keys(form!("webhook", nil, "standard_webhooks")) == ~w(verify secret)

      # A signed or shared-secret webhook names its header and how one delivery
      # is told from another, so those stay open too.
      for method <- ~w(hmac shared_secret) do
        assert open_keys(form!("webhook", nil, method)) ==
                 ~w(verify header id_header content_hash secret)
      end

      # The rule is published for the setup page, which draws its own fields.
      for {kind, preset, verify} <- [
            {"stream", nil, nil},
            {"webhook", nil, "hmac"},
            {nil, "rss", nil}
          ] do
        form = form!(kind, preset, verify)
        resolved = kind || "feed"
        method = verify || (preset == "github" && "hmac") || nil

        assert Enum.sort(SourceForm.add_open_keys(resolved, preset, method)) ==
                 Enum.sort(open_keys(form))
      end
    end

    # M60 simpler setup D5: the labels say what a field is in plain words.
    test "the labels are plain words, on the add form and the edit form alike", %{opts: opts} do
      rss = labels(form!(nil, "rss"))
      assert rss["url"] == "Feed address"
      assert rss["interval_minutes"] == "Check every"
      assert rss["daily_budget"] == "Daily limit"
      assert labels(form!("feed", nil))["url"] == "Address"
      assert labels(form!("stream", nil))["url"] == "Address"
      assert labels(form!(nil, "x_accounts"))["handles"] == "Accounts"

      hmac = labels(form!("webhook", nil, "hmac"))
      assert hmac["verify"] == "Verification"
      assert hmac["secret"] == "Secret"
      assert labels(form!("webhook", nil, "shared_secret"))["secret"] == "Shared secret"

      budget = Enum.find(form!("local_push", nil)["rows"], &(&1["key"] == "daily_budget"))
      assert budget["info"] == "The most items a day. 0 means no limit."

      assert {:ok, _added} = Cues.sources_add(nil, nil, "github", %{}, opts)
      {:ok, %{"values" => values}} = Cues.sources_get("github", opts)
      edit = Map.new(values, &{&1["key"], &1["label"]})
      assert edit["verify"] == "Verification"
      assert edit["daily_budget"] == "Daily limit"
      assert edit["secret"] == "Secret"
    end

    test "a preset decides the kind and fills its fields under More options" do
      assert {:ok, form} = Cues.sources_form(nil, "github", nil)

      # Fermix makes GitHub's secret, so its add form has no secret row.
      keys = Enum.map(form["rows"], & &1["key"])
      assert keys == ~w(ref verify header algorithm prefix id_header content_hash type_header
                        daily_budget)

      assert Enum.all?(form["rows"], & &1["advanced"])

      assert %{"value" => "hmac", "advanced" => true} =
               Enum.find(form["rows"], &(&1["key"] == "verify"))

      # GitHub's delivery id settles the identity, so the content toggle is
      # under More options too.
      assert %{"value" => false, "advanced" => true} =
               Enum.find(form["rows"], &(&1["key"] == "content_hash"))

      # The tunnel, then GitHub's three steps, in plain text a client shows as is.
      assert [tunnel | steps] = form["notes"]
      assert tunnel =~ "tunnel you run"
      assert steps == SourceForm.github_steps()

      assert steps == [
               "In your repository, open Settings → Webhooks → Add webhook.",
               "As the Payload URL, paste your tunnel's address followed by this source's " <>
                 "path. Paste the secret Fermix made as the webhook's secret.",
               "Choose application/json as the content type."
             ]

      refute Enum.any?(form["notes"], &String.contains?(&1, "`"))
    end

    # Replacing GitHub's secret later is the edit form's secret row, as before.
    test "a GitHub source's edit form keeps its secret row", %{opts: opts} do
      assert {:ok, _added} = Cues.sources_add("gh-hooks", nil, "github", %{}, opts)
      {:ok, %{"values" => values}} = Cues.sources_get("gh-hooks", opts)

      assert %{"key" => "secret", "kind" => "secret", "present" => true} = List.last(values)
    end

    # M60_X_ACCOUNTS_SOURCE.md §4: the handles are the only field to type; the
    # X plugin's sign-in reads, so there is no URL and no secret.
    test "the X accounts preset asks only for the handles, signed in through the X plugin" do
      form = form!(nil, "x_accounts")
      rows = Map.new(form["rows"], &{&1["key"], &1})

      assert Enum.find(form["presets"], &(&1["id"] == "x_accounts")) ==
               %{"id" => "x_accounts", "label" => "X accounts", "kind" => "feed"}

      assert Enum.map(form["rows"], & &1["key"]) == ~w(ref handles interval_minutes daily_budget)

      assert %{
               "kind" => "list",
               "label" => "Accounts",
               "value" => [],
               "example" => "nasa",
               "info" => "X usernames, with or without @. Up to 20."
             } = rows["handles"]

      assert %{"label" => "Check every", "value" => 5} = rows["interval_minutes"]

      # It asks X, not an address the owner gave.
      assert form["consent_sentence"] ==
               "Fermix asks X for these accounts' new posts on the schedule you set."

      assert form["notes"] == [
               "Reads with your X sign-in from the X plugin. Connect X under Plugins first. X " <>
                 "bills your X app for each post it returns."
             ]
    end

    test "every row keeps its explanation behind info, with no footer" do
      rows =
        for {kind, preset, verify} <- [
              {"feed", nil, nil},
              {"stream", nil, nil},
              {"webhook", nil, "hmac"}
            ],
            row <- form!(kind, preset, verify)["rows"],
            do: row

      assert Enum.all?(rows, &is_nil(&1["footer"]))

      assert %{"info" => "How you and Fermix refer to it in chat." <> _rest} =
               Enum.find(rows, &(&1["key"] == "ref"))

      assert %{"info" => "Stored in your keychain and never shown again."} =
               Enum.find(rows, &(&1["key"] == "secret"))
    end

    # A stream with no preset is the general WebSocket source: its own rows,
    # each explained behind an info control and none with a footer, each field
    # with an example for its empty state, its API key and secret straight after
    # its address, and a note saying what it does.
    test "a stream with no preset is the general WebSocket source's form" do
      assert {:ok, form} = Cues.sources_form("stream", nil, nil)

      assert Enum.map(form["rows"], & &1["key"]) ==
               ~w(ref url key secret key_header secret_header auth_message subscribe_message
                  id_path type_path item_types error_types items_path revision_path time_path
                  subject_path daily_budget)

      rows = Map.new(form["rows"], &{&1["key"], &1})
      assert %{"label" => "Address", "kind" => "text", "advanced" => false} = rows["url"]
      assert %{"label" => "Sign-in message", "info" => info} = rows["auth_message"]
      assert info =~ "JSON on one line"
      assert info =~ "`{{key}}`"
      assert %{"kind" => "list", "value" => [], "example" => "news"} = rows["item_types"]

      assert %{"label" => "Header name for the API key", "example" => "X-Api-Key"} =
               rows["key_header"]

      # How it signs in by header or message, and the message's shape, wait
      # under More options with the rest.
      for key <- ~w(key_header secret_header auth_message type_path item_types error_types
                    items_path revision_path time_path subject_path daily_budget),
          do: assert(rows[key]["advanced"], key)

      fields =
        ~w(url key_header secret_header auth_message subscribe_message id_path type_path
           item_types error_types items_path revision_path time_path subject_path)

      for key <- fields do
        assert is_binary(rows[key]["info"]) and is_nil(rows[key]["footer"]), key
        assert is_binary(rows[key]["example"]), key
      end

      assert %{"kind" => "secret", "label" => "API key", "present" => false, "example" => nil} =
               rows["key"]

      assert %{"kind" => "secret", "label" => "API secret", "present" => false} = rows["secret"]
      assert %{"example" => nil} = rows["daily_budget"]

      sentence = Enum.find(form["kinds"], &(&1["id"] == "stream"))["sentence"]
      assert sentence =~ "WebSocket (wss://) address"

      assert form["notes"] == [
               "Any WebSocket service. Fermix signs in with your API key and secret, sends the " <>
                 "subscribe message, and keeps each message of a type you list."
             ]
    end

    test "the engine ships no Bluesky preset: its form is refused" do
      for kind <- [nil, "stream"] do
        assert Cues.sources_form(kind, "bluesky_jetstream", nil) ==
                 {:error, {:invalid_params, "preset", "Fermix has no preset by that name."}}
      end
    end

    test "a choice it does not know, or a preset of another kind, is refused" do
      assert Cues.sources_form("pigeon", nil, nil) ==
               {:error, {:invalid_params, "kind", "Fermix has no source kind by that name."}}

      assert Cues.sources_form("feed", "github", nil) ==
               {:error, {:invalid_params, "preset", "The GitHub preset makes a Webhook source."}}

      assert Cues.sources_form("webhook", nil, "md5") ==
               {:error,
                {:invalid_params, "verify", "This setting takes one of its published values."}}
    end
  end

  describe "watchers" do
    test "are listed with their counts and read with the owner's own words", %{
      opts: opts,
      conn: conn
    } do
      id =
        CueFixtures.insert_watcher(conn, %{
          name: "release-watch",
          filter: "none",
          sources: ["eng-blogs"]
        })

      CueFixtures.exec!(conn, "UPDATE cue_watchers SET purpose = ? WHERE id = ?", [
        "Releases of software I run.",
        id
      ])

      CueFixtures.exec!(
        conn,
        """
        INSERT INTO cue_watcher_instructions (id, watcher_id, number, text, added_at, added_from)
        VALUES ('cwi_1', ?, 1, 'Ignore opinion pieces.', '2026-10-12T00:00:00.000000Z', 'chat')
        """,
        [id]
      )

      assert {:ok, %{"watchers" => [row], "window_s" => 86_400, "truncated" => false}} =
               Cues.watchers_list(opts)

      assert %{
               "name" => "release-watch",
               "state" => "on",
               "status_sentence" => "Passes every item to its task.",
               "sources" => ["eng-blogs"],
               "instruction_count" => 1,
               "counts" => %{
                 "waiting" => 0,
                 "passed" => 0,
                 "dropped" => 0,
                 "acted" => 0,
                 "failed" => 0
               }
             } = row

      assert {:ok, %{"watcher" => watcher}} = Cues.watchers_get("release-watch", opts)
      assert watcher["purpose"] == "Releases of software I run."

      assert [%{"number" => 1, "text" => "Ignore opinion pieces."}] = watcher["instructions"]
      assert watcher["examples"] == %{"pass" => 0, "drop" => 0}

      assert Cues.watchers_get("nowhere", opts) ==
               {:error, {:invalid_params, "name", "There is no watcher named nowhere."}}
    end

    # M60_WATCHER_CODING_RUNS.md §3.5: the Cues pane shows a watcher's follow-up
    # with whether it is always allowed and its readiness; a watcher with only a
    # follow-up has no task.
    test "carry the follow-up, whether it is always allowed and its readiness, and a null task",
         %{opts: opts, conn: conn, repo: repo} do
      id =
        CueFixtures.insert_watcher(conn, %{name: "deploy-watch", filter: "none", sources: ["s"]})

      {:ok, job} =
        JobsRegistry.create_follow_up_job(
          %{
            name: "Deploy check",
            task_prompt: "Run the deploy check.",
            allowed_tools: ["deploy_check"],
            delivery_mode: "channel",
            delivery_target: %{"platform" => "slack", "channel_id" => "C1"},
            created_by_trust: "operator"
          },
          repo: repo,
          scheduler: nil
        )

      CueFixtures.exec!(
        conn,
        "UPDATE cue_watchers SET task_job_id = NULL, follow_up_job_id = ?, daily_cap = 5 " <>
          "WHERE id = ?",
        [job.id, id]
      )

      CueFixtures.always_allow!(conn, id)

      held = Keyword.put(opts, :follow_up_opts, plugins: fn -> {:ok, []} end)

      assert {:ok, %{"watchers" => [row]}} = Cues.watchers_list(held)
      # Never null: an app that predates follow-ups requires a task on every row.
      assert row["task"] == %{"job_id" => job.id, "name" => "Deploy check", "paused" => false}
      assert row["status_sentence"] == "Passes every item to its follow-up."

      assert row["follow_up"] == %{
               "job_id" => job.id,
               "name" => "Deploy check",
               "always_allowed" => true,
               "state" => "held",
               "status_sentence" =>
                 "deploy_check is not set up on this computer (its program was not found or " <>
                   "its plugin is not installed). Slack, where the follow-up reports, is not " <>
                   "set up: set it up under Channels in settings."
             }

      registry = :"cues_test_caps_#{System.unique_integer([:positive])}"
      start_supervised!({CapabilityRegistry, name: registry})

      :ok =
        CapabilityRegistry.register(
          registry,
          Capability.new(%{
            name: "deploy_check",
            description: "a test tool",
            parameters: %{"type" => "object", "properties" => %{}},
            kind: :builtin,
            executor: {__MODULE__, :never, []},
            policy_class: :exec
          })
        )

      ready =
        Keyword.put(opts, :follow_up_opts,
          capability_registry: registry,
          channel_ready?: fn :slack -> true end
        )

      assert {:ok, %{"watcher" => detail}} = Cues.watchers_get("deploy-watch", ready)

      assert %{
               "state" => "ready",
               "always_allowed" => true,
               "status_sentence" => "Always allowed: it runs on each passing item with no card."
             } = detail["follow_up"]
    end

    # A follow-up held for a folder its instructions name says which folder and
    # the grant that opens it, on the row an app draws; granted, it is ready.
    test "a follow-up held for a folder names it and the grant that opens it",
         %{opts: opts, conn: conn, repo: repo} do
      root = SafeRm.make_tmp_dir!("cues-follow-up-folder")
      on_exit(fn -> SafeRm.rm_rf!(root) end)
      project = Path.join(root, "src/quarry")

      id =
        CueFixtures.insert_watcher(conn, %{name: "deploy-watch", filter: "none", sources: ["s"]})

      {:ok, job} =
        JobsRegistry.create_follow_up_job(
          %{
            name: "Deploy check",
            task_prompt: "Run the deploy check in #{project}.",
            allowed_tools: ["deploy_check"],
            delivery_mode: "channel",
            delivery_target: %{"platform" => "slack", "channel_id" => "C1"},
            created_by_trust: "operator"
          },
          repo: repo,
          scheduler: nil
        )

      CueFixtures.exec!(conn, "UPDATE cue_watchers SET follow_up_job_id = ? WHERE id = ?", [
        job.id,
        id
      ])

      registry = :"cues_test_folder_caps_#{System.unique_integer([:positive])}"
      start_supervised!({CapabilityRegistry, name: registry})

      :ok =
        CapabilityRegistry.register(
          registry,
          Capability.new(%{
            name: "deploy_check",
            description: "a test tool",
            parameters: %{"type" => "object", "properties" => %{}},
            kind: :builtin,
            executor: {__MODULE__, :never, []},
            policy_class: :exec
          })
        )

      seams = fn grants ->
        Keyword.put(opts, :follow_up_opts,
          capability_registry: registry,
          channel_ready?: fn :slack -> true end,
          sandbox_config: %{
            mode: :strict,
            home: Path.join(root, "fermix"),
            os_home: Path.join(root, "home"),
            workspace_root: Path.join(root, "workspace"),
            allowed_roots: grants
          }
        )
      end

      folder = PathPolicy.canonical_path(project)

      assert {:ok, %{"watchers" => [%{"follow_up" => held}]}} = Cues.watchers_list(seams.([]))
      assert held["state"] == "held"

      assert held["status_sentence"] ==
               "Fermix can't open `#{folder}` yet: grant it with `/grant path #{folder}` in " <>
                 "chat, or `fermix grant path #{folder}` in a terminal on Linux."

      assert {:ok, %{"watcher" => %{"follow_up" => ready}}} =
               Cues.watchers_get("deploy-watch", seams.([project]))

      assert ready["state"] == "ready"
    end

    # The 2026-10-31 revision of M60_WATCHER_CODING_RUNS.md: the app takes a
    # follow-up's Always allow back, and only ever back.
    test "a follow-up's Always allow is taken back from the app, and its row asks first",
         %{opts: opts, conn: conn, repo: repo} do
      id =
        CueFixtures.insert_watcher(conn, %{name: "deploy-watch", filter: "none", sources: ["s"]})

      {:ok, job} =
        JobsRegistry.create_follow_up_job(
          %{
            name: "Deploy check",
            task_prompt: "Run the deploy check.",
            allowed_tools: ["deploy_check"],
            delivery_mode: "channel",
            delivery_target: %{"platform" => "slack", "channel_id" => "C1"},
            created_by_trust: "operator"
          },
          repo: repo,
          scheduler: nil
        )

      CueFixtures.exec!(conn, "UPDATE cue_watchers SET follow_up_job_id = ? WHERE id = ?", [
        job.id,
        id
      ])

      CueFixtures.always_allow!(conn, id)
      TelemetryCapture.attach([[:fermix, :cue, :lifecycle]], watcher_id: id)
      ready = Keyword.put(opts, :follow_up_opts, plugins: fn -> {:ok, []} end)

      assert {:ok, %{"watcher" => row}} =
               route("cues.watchers.always_allow.revoke", %{"name" => "deploy-watch"}, ready)

      assert %{"always_allowed" => false} = row["follow_up"]

      assert_receive {:telemetry, _event, _measurements,
                      %{phase: :follow_up_always_allow_revoked, kind: "management"} = meta}

      assert meta.job_id == job.id

      # Again: it already asks first, and nothing more is traced.
      assert {:ok, %{"watcher" => %{"follow_up" => %{"always_allowed" => false}}}} =
               Cues.watchers_always_allow_revoke("deploy-watch", ready)

      refute_received {:telemetry, _event, _measurements,
                       %{phase: :follow_up_always_allow_revoked}}

      CueFixtures.insert_watcher(conn, %{name: "task-only", filter: "none", sources: ["s"]})

      assert Cues.watchers_always_allow_revoke("task-only", ready) ==
               {:error, {:invalid_params, "name", "Watcher task-only has no follow-up."}}

      assert Cues.watchers_always_allow_revoke("nowhere", ready) ==
               {:error, {:invalid_params, "name", "There is no watcher named nowhere."}}
    end

    test "an llm watcher with no model while no default is set is on: the main model filters",
         %{opts: opts, conn: conn} do
      id = CueFixtures.insert_watcher(conn, %{name: "news", filter: "llm", sources: ["s"]})
      listen_for!(conn, id, ["Orrin DB", "outage"])

      assert {:ok, %{"watchers" => [%{"state" => "on", "filter_model" => nil} = row]}} =
               Cues.watchers_list(opts)

      assert row["status_sentence"] == "Filtering normally."
      refute "no_model" in WatcherRow.states()

      assert {:ok, %{"watcher" => %{"listen_for" => ["Orrin DB", "outage"]}}} =
               Cues.watchers_get("news", opts)
    end

    # M60_CUE_INTAKE_AT_SCALE.md §3.1: a watcher saved before the rules gets
    # nothing until a change in chat, and its row says what it needs.
    test "one stored before the rules reads needs_update with what it needs", %{
      opts: opts,
      conn: conn
    } do
      CueFixtures.insert_watcher(conn, %{name: "old-news", filter: "llm", sources: ["eng-blogs"]})
      CueFixtures.insert_watcher(conn, %{name: "all-posts", filter: "none", sources: ["bsky"]})

      CueFixtures.insert_watcher(conn, %{
        name: "paused-news",
        filter: "llm",
        sources: ["eng-blogs"],
        enabled: false
      })

      held = CueFixtures.insert_watcher(conn, %{name: "held-news", filter: "llm", sources: ["s"]})
      listen_for!(conn, held, ["outage"])
      CueFixtures.exec!(conn, "UPDATE cue_watchers SET filter_failures = 3 WHERE id = ?", [held])

      assert {:ok, %{"watchers" => rows}} =
               Cues.watchers_list(Keyword.put(opts, :config, stream_config()))

      states = Map.new(rows, &{&1["name"], {&1["state"], &1["status_sentence"]}})

      assert states["old-news"] ==
               {"needs_update", "Needs keywords to listen for: update it in chat."}

      assert states["all-posts"] ==
               {"needs_update",
                "Passes everything, so it can't listen to a stream: give it a filter in chat."}

      assert {"paused", _sentence} = states["paused-news"]
      assert {"held", _sentence} = states["held-news"]
      assert "needs_update" in WatcherRow.states()
    end

    # M60_CUE_INTAKE_AT_SCALE.md §3.4: a stream keeps only what passes, so
    # what its watcher was offered, dropped or failed is counted, not stored.
    # A stream's pass is a stored delivery and a counted offer, so `offered`
    # adds the counts to the deliveries from every other source, and the
    # counts' whole hours never meet the deliveries' exact 24 hours.
    test "a stream watcher's counts add what it judged and did not keep", %{
      opts: opts,
      conn: conn,
      repo: repo
    } do
      id =
        CueFixtures.insert_watcher(conn, %{
          name: "chip-news",
          filter: "llm",
          sources: ["bsky", "eng-blogs"]
        })

      listen_for!(conn, id, ["TSMC"])
      now = ~U[2026-10-17 12:30:00.000000Z]
      two_hours_ago = DateTime.add(now, -2 * 3_600, :second)
      # In the counted hours (from 12:00 a day ago), past the exact 24 hours.
      day_ago = ~U[2026-10-16 12:10:00.000000Z]

      for {ref, at, state} <- [
            {"bsky", two_hours_ago, "passed"},
            {"bsky", two_hours_ago, "passed"},
            {"bsky", day_ago, "passed"},
            {"eng-blogs", two_hours_ago, "dropped"}
          ] do
        cue = Rows.cue(conn, %{source_ref: ref, received_at: at})

        Rows.delivery(conn, cue, %{watcher_id: id, source_ref: ref, received_at: at, state: state})
      end

      hour = CuesSql.hour_of(now)

      counts!(repo, [
        {"watcher", id, hour, "inc-a",
         %{"offered" => 40, "passed" => 2, "dropped" => 30, "filter_failed" => 1, "overflow" => 5}},
        {"watcher", id, DateTime.add(hour, -3_600, :second), "inc-b",
         %{"offered" => 10, "dropped" => 8, "write_failed" => 1}},
        {"watcher", id, CuesSql.hour_of(day_ago), "inc-c", %{"offered" => 1, "passed" => 1}},
        {"watcher", id, DateTime.add(hour, -30 * 3_600, :second), "inc-d",
         %{"offered" => 900, "dropped" => 900}}
      ])

      opts = Keyword.merge(opts, config: stream_config(), now: fn -> now end)
      assert {:ok, %{"watchers" => [row]}} = Cues.watchers_list(opts)

      assert row["counts"] == %{
               "offered" => 52,
               "waiting" => 0,
               "passed" => 2,
               "dropped" => 39,
               "acted" => 0,
               "failed" => 2
             }
    end

    test "a stream source's row counts what it received, not only what it kept", %{
      opts: opts,
      conn: conn,
      repo: repo
    } do
      for _pass <- 1..2,
          do: Rows.cue(conn, %{source_ref: "bsky", received_at: DateTime.add(@now, -60, :second)})

      counts!(repo, [
        {"source", "bsky", CuesSql.hour_of(@now), "inc-a",
         %{"received" => 1_000, "unmatched" => 900, "rate_limited" => 50}}
      ])

      assert {:ok, %{"sources" => [row]}} =
               Cues.sources_list(Keyword.put(opts, :config, stream_config()))

      assert %{"received" => 1_000, "routed" => 50, "not_routed" => 950} = row["counts"]
    end
  end

  describe "mandates" do
    test "one added here reads back with its load sentence, and an inactive one is not approved",
         %{opts: opts, home: home} do
      values = %{
        "job" => "job_nowhere",
        "mode" => "approve",
        "tools" => ["github_create_issue"],
        "approve_within_s" => 1_800,
        "max_cue_age_s" => 900
      }

      assert {:ok, %{"mandate" => row}} = Cues.mandates_add("release-issues", values, opts)

      assert %{
               "name" => "release-issues",
               "mode" => "approve",
               "approve_within_s" => 1_800,
               "max_cue_age_s" => 900,
               "load" => %{"state" => "inactive", "sentence" => sentence},
               "approval" => %{"state" => "unapproved"},
               "primary_action" => nil,
               "actions" => ["disable"],
               "consent_sentence" => "Each call waits for your yes before it runs."
             } = row

      assert row["status_sentence"] == sentence
      assert config_text(home) =~ ~s(approve_within = "30m")
      assert config_text(home) =~ ~s(max_cue_age = "15m")

      assert {:error, {:invalid_params, "name", ^sentence}} =
               Cues.mandates_approve("release-issues", opts)
    end

    test "an active mandate is approved from the Fermix app", %{opts: opts, repo: repo} do
      {:ok, job} =
        JobsRegistry.create_cue_job(
          %{
            name: "release issues",
            task_prompt: "Open an issue for each release.",
            delivery_mode: "channel",
            delivery_target: %{"platform" => "telegram", "chat_id" => "123"},
            created_by_trust: "operator"
          },
          repo: repo,
          scheduler: nil
        )

      values = %{
        "job" => job.id,
        "mode" => "auto",
        "tools" => [MandateFixtures.tool()],
        "pin_args" => [%{"key" => "owner", "value" => "example-org"}]
      }

      mandate_opts = [
        plugin_tool: MandateFixtures.plugin_tool(),
        stat: MandateFixtures.root_stat()
      ]

      opts = Keyword.put(opts, :mandate_opts, mandate_opts)

      assert {:ok, %{"mandate" => row}} = Cues.mandates_add("release-issues", values, opts)

      assert %{
               "load" => %{"state" => "active"},
               "approval" => %{"state" => "unapproved"},
               "primary_action" => "approve",
               "actions" => ["disable", "approve"],
               "pin_args" => [%{"key" => "owner", "value" => "example-org"}],
               "job" => %{"name" => "release issues"}
             } = row

      assert {:ok, %{"mandate" => approved}} = Cues.mandates_approve("release-issues", opts)

      assert %{
               "approval" => %{"state" => "approved", "approved_from" => "Fermix app"},
               "primary_action" => nil,
               "status_sentence" => "Approved. Calls run without asking you."
             } = approved

      assert {:ok, %{"mandate" => changed}} =
               Cues.mandates_update("release-issues", %{"max_cue_age_s" => 60}, opts)

      assert %{"approval" => %{"state" => "changed"}, "primary_action" => "approve"} = changed

      assert {:ok, %{"mandate" => %{"enabled" => false, "status_sentence" => "Off."}}} =
               Cues.mandates_switch("release-issues", false, opts)

      assert {:ok, %{"name" => "release-issues", "removed" => true}} =
               Cues.mandates_remove("release-issues", opts)
    end

    # A refusal the config's check words is filed under the mandate form's own
    # key, read from the `cues.mandates.<name>.<key>` it names, never under a
    # source field a free word in the sentence happens to spell.
    test "a refusal of the settings check is filed under the mandate's own key", %{opts: opts} do
      assert {:error, {:invalid_params, "job", sentence}} =
               Cues.mandates_add("m", %{"mode" => "approve"}, opts)

      assert sentence =~ "job is required"

      assert {:error, {:invalid_params, "max_cue_age_s", _sentence}} =
               Cues.mandates_add("m", %{"job" => "j", "max_cue_age_s" => 999_999_999}, opts)
    end

    test "values that are not the form's shape are refused by field", %{opts: opts} do
      assert Cues.mandates_add("m", %{"job" => "j", "approve_within_s" => 0}, opts) ==
               {:error,
                {:invalid_params, "approve_within_s",
                 "A proposal waits from 1 second to 24 hours."}}

      assert Cues.mandates_add("m", %{"job" => "j", "bogus" => 1}, opts) ==
               {:error, {:invalid_params, "bogus", "A mandate has no setting by that name."}}

      assert {:error, {:invalid_params, "pin_args", _sentence}} =
               Cues.mandates_add("m", %{"job" => "j", "pin_args" => [%{"key" => 1}]}, opts)

      assert Cues.mandates_update("nowhere", %{}, opts) ==
               {:error, {:invalid_params, "name", "There is no mandate named nowhere."}}
    end

    test "at most 64 mandates are added", %{opts: opts} do
      mandates = Map.new(1..64, &{"m#{&1}", [job: "j#{&1}"]})
      Application.put_env(:fermix_core, :cues, mandates: mandates)

      assert {:ok, %{"can_add" => false, "limits" => %{"max_mandates" => 64}}} =
               Cues.mandates_list(opts)

      assert Cues.mandates_add("one-more", %{"job" => "j"}, opts) ==
               {:error,
                {:invalid_params, "name", "Fermix holds at most 64 mandates. Remove one first."}}
    end

    test "the choices are the jobs that run on cues and the enabled http plugin tools", %{
      opts: opts,
      repo: repo
    } do
      {:ok, job} =
        JobsRegistry.create_cue_job(
          %{
            name: "release issues",
            task_prompt: "Open an issue for each release.",
            delivery_mode: "channel",
            delivery_target: %{"platform" => "telegram", "chat_id" => "123"},
            created_by_trust: "operator"
          },
          repo: repo,
          scheduler: nil
        )

      plugin = %{
        name: "github",
        tools: [
          %{"name" => "github_create_issue", "title" => "Create an issue", "request" => %{}},
          %{"name" => "github_search_issues", "read_only" => true, "request" => %{}},
          %{"name" => "github_mcp_tool", "rail" => "mcp", "request" => %{}}
        ]
      }

      opts =
        Keyword.merge(opts,
          plugins: fn ->
            {:ok, [plugin, %{name: "off", tools: [%{"name" => "x", "request" => %{}}]}]}
          end,
          enabled_plugins: fn -> ["github"] end
        )

      assert {:ok, %{"jobs" => jobs, "tools" => tools}} = Cues.mandates_choices(opts)

      assert [%{"id" => id, "name" => "release issues", "watcher" => nil, "mandate" => nil}] =
               jobs

      assert id == job.id

      assert tools == [
               %{
                 "name" => "github_create_issue",
                 "plugin" => "github",
                 "title" => "Create an issue",
                 "read_only" => false
               },
               %{
                 "name" => "github_search_issues",
                 "plugin" => "github",
                 "title" => nil,
                 "read_only" => true
               }
             ]
    end
  end

  describe "proposals" do
    setup %{opts: opts} do
      waiting = [FakeProposals.record("cpr_1", :waiting)]
      recent = waiting ++ [FakeProposals.record("cpr_0", :denied)]
      Process.put(:fake_proposals, %{waiting: waiting, recent: recent})
      %{opts: Keyword.put(opts, :proposals, FakeProposals)}
    end

    test "are listed waiting by default, or the last week's", %{opts: opts} do
      assert {:ok, %{"proposals" => [record], "waiting" => 1}} =
               route("cues.proposals.list", %{}, opts)

      assert %{
               "proposal_id" => "cpr_1",
               "state" => "waiting",
               "task" => %{"job_id" => "job_1", "name" => "Release watch"},
               "created_at" => "2026-10-17T11:50:00Z",
               "decided_from" => nil
             } = record

      assert {:ok, %{"proposals" => [_waiting, _denied], "waiting" => 1}} =
               route("cues.proposals.list", %{"state" => "recent"}, opts)
    end

    test "one is read with its card, and an unknown one is refused by field", %{opts: opts} do
      assert {:ok, %{"proposal" => %{"proposal_id" => "cpr_1", "summary" => _summary}}} =
               route("cues.proposals.get", %{"proposal_id" => "cpr_1"}, opts)

      assert route("cues.proposals.get", %{"proposal_id" => "cpr_missing"}, opts) ==
               {:error, :invalid_params,
                %{"field" => "proposal_id", "sentence" => "There is no proposal with that id."}}
    end

    test "a decision from the socket is recorded as the management surface's", %{opts: opts} do
      assert {:ok, %{"proposal" => %{"state" => "confirmed"}}} =
               route(
                 "cues.proposals.decide",
                 %{"proposal_id" => "cpr_1", "decision" => "confirm"},
                 opts
               )

      assert_received {:decided, "cpr_1", :confirm, %{surface: :management, device_id: nil}}

      assert route(
               "cues.proposals.decide",
               %{"proposal_id" => "cpr_expired", "decision" => "deny"},
               opts
             ) ==
               {:error, :invalid_params,
                %{"field" => "proposal_id", "sentence" => "That proposal expired; nothing ran."}}
    end
  end

  describe "the cues section" do
    test "publishes the switches, the filter pair and the door's port" do
      assert %{id: "cues", pane: "cues", title: "Cues"} in Settings.sections()
      assert {:ok, %{"rows" => rows}} = Settings.get("cues")

      assert Enum.map(rows, &{&1["key"], &1["kind"], &1["restart"]}) == [
               {"cues_enabled", "toggle", true},
               {"cues_mandates_enabled", "toggle", false},
               {"cues_screen", "choice", false},
               {"filter_provider", "choice", false},
               {"filter_model", "choice", false},
               {"cues_door_port", "number", true}
             ]

      provider = Enum.find(rows, &(&1["key"] == "filter_provider"))
      assert Enum.find(rows, &(&1["key"] == "filter_model"))["suggestions"] == true
      assert provider["label"] == "Filter model"

      assert provider["info"] ==
               "Judges each item on its own, so a smaller, faster model works well and costs " <>
                 "much less than your main model."

      assert Enum.all?(rows, &is_nil(&1["footer"]))
    end

    test "the filter defaults to the main model and offers only providers that are set up" do
      Application.put_env(:fermix_core, :providers,
        anthropic: [api_key: "sk-ant-invented", primary: true, default_model: "claude-sonnet-5-5"],
        openai: [api_key: "sk-invented"],
        mistral: [default_model: "mistral-large-latest"]
      )

      assert {:ok, %{"rows" => rows}} = Settings.get("cues")
      provider = Enum.find(rows, &(&1["key"] == "filter_provider"))
      anthropic = Descriptor.fetch!(:anthropic).label

      assert [%{"value" => "", "label" => main} | set_up] = provider["options"]
      assert main == "Default: your main model (#{anthropic} · claude-sonnet-5-5)"
      assert Enum.sort(Enum.map(set_up, & &1["value"])) == ["anthropic", "openai"]
      refute Enum.any?(provider["options"], & &1["disabled"])
    end

    test "a saved filter provider that is no longer set up stays in the menu, disabled" do
      Application.put_env(:fermix_core, :providers,
        anthropic: [api_key: "sk-ant-invented", primary: true]
      )

      Application.put_env(:fermix_core, :routing,
        filter_provider: "openai",
        filter_model: "gpt-5.4-mini"
      )

      assert {:ok, %{"rows" => rows}} = Settings.get("cues")
      provider = Enum.find(rows, &(&1["key"] == "filter_provider"))

      assert provider["value"] == "openai"

      assert %{"disabled" => true, "hint" => "Set up this provider first."} =
               Enum.find(provider["options"], &(&1["value"] == "openai"))

      assert Enum.map(provider["options"], & &1["value"]) == ["", "anthropic", "openai"]
    end

    test "the filter pair is applied together, and either alone is refused", %{home: home} do
      assert Settings.apply("cues", %{"filter_model" => "claude-haiku-4-5"}) ==
               {:error,
                {:invalid_params, "filter_model", "Pick a provider and a model, or clear both."}}

      Application.put_env(:fermix_core, :providers, anthropic: [api_key: "sk-ant-invented"])

      assert {:ok, %{"applied" => applied}} =
               Settings.apply("cues", %{
                 "filter_provider" => "anthropic",
                 "filter_model" => "claude-haiku-4-5"
               })

      assert Enum.sort(applied) == ["filter_model", "filter_provider"]
      assert config_text(home) =~ ~s(filter_model = "claude-haiku-4-5")

      assert {:ok, _cleared} =
               Settings.apply("cues", %{"filter_provider" => "", "filter_model" => ""})

      refute config_text(home) =~ "filter_model"
    end

    test "the screen offers keyword match and the decision model Fermix picks" do
      Application.put_env(:fermix_core, :providers,
        anthropic: [api_key: "sk-ant-invented", primary: true],
        venice: [api_key: "vn-invented"],
        openai: [api_key: "sk-invented"]
      )

      assert {:ok, %{"rows" => rows}} = Settings.get("cues")
      screen = Enum.find(rows, &(&1["key"] == "cues_screen"))

      assert %{"label" => "Screen", "value" => "keyword"} = screen

      assert screen["info"] ==
               "How items are checked before the filter model reads them. Keyword match: an " <>
                 "item must contain one of the watcher's keywords. Decision model: each item " <>
                 "is checked by its meaning, with the watcher's purpose, instructions and " <>
                 "keywords as hints, in about a third of a second, roughly ten times faster " <>
                 "than a chat model."

      assert Enum.map(screen["options"], &Map.take(&1, ["value", "label", "hint", "disabled"])) ==
               [
                 %{
                   "value" => "keyword",
                   "label" => "Keyword match",
                   "hint" => nil,
                   "disabled" => false
                 },
                 %{
                   "value" => "decision_model",
                   "label" => "Decision model",
                   "hint" => "Uses OpenAI · gpt-6-luna",
                   "disabled" => false
                 }
               ]
    end

    test "a primary that serves a decision model is the one the screen uses" do
      Application.put_env(:fermix_core, :providers,
        openai: [api_key: "sk-invented"],
        venice: [api_key: "vn-invented", primary: true]
      )

      assert {:ok, %{"rows" => rows}} = Settings.get("cues")
      screen = Enum.find(rows, &(&1["key"] == "cues_screen"))

      assert %{"hint" => "Uses Venice · Jev", "disabled" => false} =
               Enum.find(screen["options"], &(&1["value"] == "decision_model"))
    end

    test "the decision model is refused while none is set up, then applies live and clears " <>
           "back to keyword match",
         %{home: home} do
      Application.put_env(:fermix_core, :providers,
        anthropic: [api_key: "sk-ant-invented", primary: true]
      )

      assert {:error, {:invalid_params, "cues_screen", sentence}} =
               Settings.apply("cues", %{"cues_screen" => "decision_model"})

      # The disabled option's hint is the refusal.
      assert sentence == "Set up OpenAI, OpenRouter or Venice first."
      refute File.exists?(Path.join(home, "config.toml"))

      Application.put_env(:fermix_core, :providers,
        anthropic: [api_key: "sk-ant-invented", primary: true],
        openrouter: [api_key: "sk-or-invented"]
      )

      assert {:ok, %{"applied" => ["cues_screen"]}} =
               Settings.apply("cues", %{"cues_screen" => "decision_model"})

      assert config_text(home) =~ ~s(screen = "decision_model")
      assert CuesConfig.screen() == :decision_model

      assert {:ok, _keyword} = Settings.apply("cues", %{"cues_screen" => "keyword"})
      refute config_text(home) =~ "screen ="
      assert CuesConfig.screen() == :keyword
    end

    test "the setup page's save checks the screen first and refuses what it cannot run",
         %{home: home} do
      Application.put_env(:fermix_core, :providers,
        anthropic: [api_key: "sk-ant-invented", primary: true]
      )

      refusal =
        {:error,
         {:invalid,
          "Set up OpenAI, OpenRouter or Venice first: a decision model runs on one of them."}}

      assert CueSettings.check_screen("decision_model") == refusal
      assert CueSettings.save_screen("decision_model") == refusal

      assert {:error, {:invalid, unknown}} = CueSettings.check_screen("regex")
      assert unknown =~ ~s(invalid cues.screen "regex")

      for keyword <- ["keyword", "", nil], do: assert(CueSettings.check_screen(keyword) == :ok)
      refute File.exists?(Path.join(home, "config.toml"))

      assert CueSettings.save_screen(nil) == {:ok, %{screen: :keyword}}
      refute config_text(home) =~ "screen ="
    end

    test "a saved decision model with none set up keeps its value, its option disabled" do
      Application.put_env(:fermix_core, :providers,
        anthropic: [api_key: "sk-ant-invented", primary: true]
      )

      Application.put_env(:fermix_core, :cues, screen: :decision_model)

      assert {:ok, %{"rows" => rows}} = Settings.get("cues")
      screen = Enum.find(rows, &(&1["key"] == "cues_screen"))

      assert screen["value"] == "decision_model"
      assert Enum.map(screen["options"], & &1["value"]) == ["keyword", "decision_model"]

      assert %{"disabled" => true, "hint" => "Set up OpenAI, OpenRouter or Venice first."} =
               Enum.find(screen["options"], &(&1["value"] == "decision_model"))
    end

    test "the switches write through the setup page's own path", %{home: home} do
      assert {:ok, %{"applied" => ["cues_enabled"]}} =
               Settings.apply("cues", %{"cues_enabled" => true})

      assert config_text(home) =~ "[fermix_core.cues]"
      assert config_text(home) =~ "enabled = true"

      assert {:error, {:invalid_params, "cues_door_port", sentence}} =
               Settings.apply("cues", %{"cues_door_port" => 80})

      assert sentence =~ "1024"
    end

    test "every step is checked before any is written, and a refusal names its row", %{
      home: home
    } do
      Application.put_env(:fermix_core, :providers, anthropic: [api_key: "sk-ant-invented"])

      # The filter pair and Run cues are fine, the door's port is not: nothing lands.
      assert {:error, {:invalid_params, "cues_door_port", sentence}} =
               Settings.apply("cues", %{
                 "filter_provider" => "anthropic",
                 "filter_model" => "claude-haiku-4-5",
                 "cues_enabled" => true,
                 "cues_door_port" => 80
               })

      assert sentence =~ "1024"
      refute File.exists?(Path.join(home, "config.toml"))

      # A decision model while none is set up, refused before the filter pair is written.
      assert SettingsCues.save(
               filter_provider: "anthropic",
               filter_model: "claude-haiku-4-5",
               screen: "decision_model"
             ) ==
               {:error,
                {:invalid_value, "cues_screen",
                 "Set up OpenAI, OpenRouter or Venice first: a decision model runs on one of them."}}

      refute File.exists?(Path.join(home, "config.toml"))

      # A lone half of the filter pair names the half that was sent.
      assert SettingsCues.save(filter_model: "claude-haiku-4-5") ==
               {:error,
                {:invalid_value, "filter_model", "Pick a provider and a model, or clear both."}}
    end
  end

  describe "a cue source's secret" do
    setup %{opts: opts} do
      {:ok, _} = Cues.sources_add("gh-hooks", nil, "github", %{}, opts)
      {:ok, _} = Cues.sources_add("home-alerts", "local_push", nil, %{}, opts)
      :ok
    end

    test "Fermix's own two values are refused by name" do
      assert Secrets.set("cue_source:home-alerts:token", "t") ==
               {:error,
                {:invalid_params, "id",
                 "Fermix makes this source's token: ask for a new one instead."}}

      assert Secrets.set("cue_source:gh-hooks:path_secret", "p") ==
               {:error,
                {:invalid_params, "id",
                 "Fermix makes this webhook's address: copy it from the source instead."}}

      assert Secrets.clear("cue_source:home-alerts:token") ==
               {:error,
                {:invalid_params, "id",
                 "Fermix makes this source's token: ask for a new one instead."}}
    end

    test "an id the family does not address, or a field the kind does not declare, is refused" do
      assert {:error, {:invalid_params, "id", sentence}} = Secrets.set("cue_source:gh-hooks", "v")
      assert sentence =~ "`cue_source:<source>:key`"

      assert Secrets.set("cue_source:nowhere:secret", "v") ==
               {:error, {:invalid_params, "id", "There is no source named nowhere."}}

      assert Secrets.set("cue_source:home-alerts:key", "v") ==
               {:error, {:invalid_params, "id", "A local push source keeps no key."}}

      assert Secrets.set("cue_source:gh-hooks:secret", "  ") ==
               {:error, {:invalid_params, "value", "A secret cannot be empty."}}

      assert Secrets.set("cue_source:gh-hooks:secret", "two\nlines") ==
               {:error, {:invalid_params, "value", "A secret is one line."}}
    end
  end

  describe "the router's parameter refusals" do
    test "name the field before any operation runs", %{opts: opts} do
      cases = [
        {"cues.status", %{"x" => 1}, %{"method" => "cues.status"}},
        {"cues.sources.list", %{"x" => 1}, %{"method" => "cues.sources.list"}},
        {"cues.sources.get", %{}, %{"field" => "ref"}},
        {"cues.sources.get", %{"ref" => "a", "x" => 1}, %{"field" => "x"}},
        {"cues.sources.form", %{"kind" => 5}, %{"field" => "kind"}},
        {"cues.sources.form", %{"bogus" => "x"}, %{"field" => "bogus"}},
        {"cues.sources.add", %{"ref" => "a", "values" => %{}}, %{"field" => "kind"}},
        {"cues.sources.add", %{"ref" => "a", "kind" => "feed", "values" => []},
         %{"field" => "values"}},
        {"cues.sources.add", %{"ref" => 7, "kind" => "feed", "values" => %{}},
         %{"field" => "ref"}},
        {"cues.sources.update", %{"ref" => "a"}, %{"field" => "values"}},
        {"cues.watchers.get", %{"name" => ""}, %{"field" => "name"}},
        {"cues.mandates.add", %{"name" => "m"}, %{"field" => "values"}},
        {"cues.mandates.approve", %{}, %{"field" => "name"}},
        {"cues.proposals.list", %{"state" => "old"}, %{"field" => "state"}},
        {"cues.proposals.get", %{}, %{"field" => "proposal_id"}},
        {"cues.proposals.decide", %{"proposal_id" => "cpr_1", "decision" => "maybe"},
         %{"field" => "decision"}},
        {"cues.proposals.decide", %{"decision" => "deny"}, %{"field" => "proposal_id"}}
      ]

      for {method, params, details} <- cases do
        assert route(method, params, opts) == {:error, :invalid_params, details},
               "#{method} #{inspect(params)}"
      end
    end
  end

  # The write goldens answer from a home, so they are pinned here, serially,
  # rather than beside the read goldens in the async contract test.
  describe "the goldens" do
    test "every cue write answers the shape its golden illustrates", %{
      opts: opts,
      repo: repo,
      conn: conn
    } do
      {:ok, job} =
        JobsRegistry.create_cue_job(
          %{
            name: "Release watch",
            task_prompt: "Open an issue for each release.",
            delivery_mode: "channel",
            delivery_target: %{"platform" => "telegram", "chat_id" => "4417"},
            created_by_trust: "operator"
          },
          repo: repo,
          scheduler: nil
        )

      mandate_opts = [
        plugin_tool: MandateFixtures.plugin_tool(),
        stat: MandateFixtures.root_stat(),
        configured_owners: %{"telegram" => "4417"},
        jobs_config: []
      ]

      opts = Keyword.put(opts, :mandate_opts, mandate_opts)
      feed = %{"url" => "https://example.org/releases.atom"}
      mandate = %{"job" => job.id, "mode" => "approve", "tools" => [MandateFixtures.tool()]}
      mandate = Map.put(mandate, "read_tools", [MandateFixtures.reader()])

      writes = [
        {"cues_sources_add", "cues.sources.add",
         %{"ref" => "eng-blogs", "preset" => "rss", "values" => feed}},
        {"cues_sources_add_local_push", "cues.sources.add",
         %{"ref" => "home-alerts", "kind" => "local_push", "values" => %{"daily_budget" => 500}}},
        {"cues_sources_add_webhook", "cues.sources.add",
         %{"preset" => "github", "values" => %{}}},
        {"cues_sources_url_get", "cues.sources.url.get", %{"ref" => "github"}},
        {"cues_sources_update", "cues.sources.update",
         %{"ref" => "eng-blogs", "values" => %{"daily_budget" => 200}}},
        {"cues_sources_disable", "cues.sources.disable", %{"ref" => "home-alerts"}},
        {"cues_sources_enable", "cues.sources.enable", %{"ref" => "home-alerts"}},
        {"cues_sources_token_new", "cues.sources.token.new", %{"ref" => "home-alerts"}},
        {"cues_mandates_add", "cues.mandates.add",
         %{"name" => "release-issues", "values" => mandate}},
        {"cues_mandates_approve", "cues.mandates.approve", %{"name" => "release-issues"}},
        {"cues_mandates_update", "cues.mandates.update",
         %{"name" => "release-issues", "values" => %{"approve_within_s" => 3_600}}},
        {"cues_mandates_disable", "cues.mandates.disable", %{"name" => "release-issues"}},
        {"cues_mandates_enable", "cues.mandates.enable", %{"name" => "release-issues"}},
        {"cues_mandates_remove", "cues.mandates.remove", %{"name" => "release-issues"}},
        {"cues_sources_remove", "cues.sources.remove", %{"ref" => "eng-blogs"}}
      ]

      for {golden, method, params} <- writes do
        # The feed's later goldens illustrate a watcher listening to it.
        if golden == "cues_sources_update",
          do:
            CueFixtures.insert_watcher(conn, %{name: "w", filter: "none", sources: ["eng-blogs"]})

        assert {:ok, result} = route(method, params, opts), golden
        assert shape(result) == shape(named_result(golden)), golden
      end
    end

    # The forms are the daemon's words, so their goldens are held to the very
    # rows and sentences the form answers, not only their shape.
    test "the golden forms are the ones the daemon answers" do
      assert Cues.sources_form(nil, "github", nil) ==
               {:ok, named_result("cues_sources_form")}

      assert Cues.sources_form("stream", nil, nil) ==
               {:ok, named_result("cues_sources_form_stream")}

      signed_out = [x_sign_in: fn -> {:error, :x_plugin_not_installed} end]

      assert Cues.sources_form(nil, "x_accounts", nil, signed_out) ==
               {:ok, named_result("cues_sources_form_x_accounts")}
    end

    test "the cue refusals are the golden ones", %{opts: opts} do
      assert {:error, :unavailable, details} =
               route("cues.watchers.list", %{}, Keyword.put(opts, :memory?, false))

      assert details == golden_error("unavailable_cues_memory_off")

      assert {:error, :invalid_params, details} =
               route("cues.sources.get", %{"ref" => "home-alerts"}, opts)

      assert details == golden_error("invalid_params_cues_unknown_source")

      {:ok, _} = Cues.sources_add("home-alerts", "local_push", nil, %{}, opts)

      request = %{
        request_id: "req-1",
        protocol_version: 2,
        method: "secret.set",
        params: %{"id" => "cue_source:home-alerts:token", "value" => "t"}
      }

      assert {:error, :invalid_params, details} = Router.route(request)
      assert details == golden_error("invalid_params_cue_source_token")
    end
  end

  @successes Application.app_dir(:fermix_core, "priv/management/fixtures/success.jsonl")
  @errors Application.app_dir(:fermix_core, "priv/management/fixtures/errors.jsonl")

  defp named_result(name), do: @successes |> fixture(name) |> get_in(["response", "result"])

  defp golden_error(name),
    do: @errors |> fixture(name) |> get_in(["response", "error", "details"])

  defp fixture(path, name) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.find(&(&1["name"] == name))
  end

  # Keys and container kinds only, as the contract test compares them.
  defp shape(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, shape(v)} end)
  defp shape([]), do: []
  defp shape([head | _rest]), do: [shape(head)]
  defp shape(_value), do: :scalar
end
