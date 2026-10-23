defmodule FermixCore.Management.CuesTest do
  @moduledoc """
  The `cues.*` methods (M60 app surface §3.1 to §3.5) against the one write
  path, `Cues.Settings`, the setup page's own functions.

  Every case runs against its own home and the stub secret store, with a
  private temp Repo for the rows (`FermixTestSupport.CueFixtures`). No cue
  tree runs, so no door listens and no worker starts.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Cues.Config, as: CuesConfig
  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Management.Cues
  alias FermixCore.Management.Router
  alias FermixCore.Management.Secrets
  alias FermixCore.Management.Settings
  alias FermixCore.Management.Settings.Cues, as: CuesSection
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixCore.Setup.RestartState
  alias FermixTestSupport.CueFixtures
  alias FermixTestSupport.MandateFixtures
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub

  @now ~U[2026-10-17 12:00:00.000000Z]
  @unavailable %{"capability" => "cues", "sentence" => "Cues are not part of this build."}
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

  # A Repo that answers every request with an error, for the reads whose
  # failure must be said rather than counted as nothing.
  defmodule FailingRepo do
    @moduledoc false
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, nil)

    @impl true
    def init(nil), do: {:ok, nil}

    @impl true
    def handle_call(_request, _from, state), do: {:reply, {:error, :corrupt}, state}
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
      available?: true,
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
    test "a build without cues says so and counts nothing", %{opts: opts} do
      assert {:ok, status} = Cues.status(Keyword.put(opts, :available?, false))

      assert %{
               "available" => false,
               "state" => "unavailable",
               "status_sentence" => "Cues are not part of this build.",
               "door" => %{"state" => "not_running", "reason" => nil}
             } = status

      assert Enum.all?(status["counts"], fn {_key, count} -> count == 0 end)
    end

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
      {:ok, _} = Cues.sources_add("gh-hooks", nil, "github", %{}, opts)
      CueFixtures.insert_watcher(conn, %{name: "release-watch", filter: "llm", sources: ["x"]})
      Process.put(:fake_proposals, %{waiting: [FakeProposals.record("cpr_1", :waiting)]})

      assert {:ok, %{"counts" => counts}} =
               Cues.status(Keyword.put(opts, :proposals, FakeProposals))

      assert counts == %{
               "sources" => 2,
               "sources_attention" => 1,
               "watchers" => 1,
               "watchers_held" => 1,
               "mandates" => 0,
               "mandates_attention" => 0,
               "proposals_waiting" => 1
             }
    end
  end

  describe "a build without cues" do
    # D1: the methods join the catalog on every build; only the status answers.
    test "every method but the status answers unavailable with the daemon's sentence", %{
      opts: opts
    } do
      opts = Keyword.put(opts, :available?, false)

      cases = [
        {"cues.sources.list", %{}},
        {"cues.sources.get", %{"ref" => "a"}},
        {"cues.sources.form", %{}},
        {"cues.sources.add", %{"ref" => "a", "kind" => "feed", "values" => %{}}},
        {"cues.sources.update", %{"ref" => "a", "values" => %{}}},
        {"cues.sources.remove", %{"ref" => "a"}},
        {"cues.sources.enable", %{"ref" => "a"}},
        {"cues.sources.disable", %{"ref" => "a"}},
        {"cues.sources.token.new", %{"ref" => "a"}},
        {"cues.sources.url.get", %{"ref" => "a"}},
        {"cues.watchers.list", %{}},
        {"cues.watchers.get", %{"name" => "a"}},
        {"cues.mandates.list", %{}},
        {"cues.mandates.choices", %{}},
        {"cues.mandates.add", %{"name" => "a", "values" => %{}}},
        {"cues.mandates.update", %{"name" => "a", "values" => %{}}},
        {"cues.mandates.remove", %{"name" => "a"}},
        {"cues.mandates.enable", %{"name" => "a"}},
        {"cues.mandates.disable", %{"name" => "a"}},
        {"cues.mandates.approve", %{"name" => "a"}},
        {"cues.proposals.list", %{}},
        {"cues.proposals.get", %{"proposal_id" => "cpr_1"}},
        {"cues.proposals.decide", %{"proposal_id" => "cpr_1", "decision" => "deny"}}
      ]

      for {method, params} <- cases do
        assert route(method, params, opts) == {:error, :unavailable, @unavailable}, method
      end

      assert {:ok, %{"available" => false}} = route("cues.status", %{}, opts)
    end

    test "publishes no cues section" do
      refute Enum.any?(Settings.sections(cues_available?: false), &(&1.id == "cues"))
      assert Settings.get("cues", cues_available?: false) == {:error, {:unknown_section, "cues"}}
    end

    test "refuses a cue source's secret as unavailable" do
      assert Secrets.set("cue_source:gh:secret", "s3cret", cues_available?: false) ==
               {:error, {:unavailable, "cues", "Cues are not part of this build."}}
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

    test "a webhook added before its secret waits for it, and storing it starts it", %{
      opts: opts,
      home: home
    } do
      assert {:ok, %{"source" => row}} = Cues.sources_add("gh-hooks", nil, "github", %{}, opts)

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

      assert {:ok, %{"id" => "cue_source:gh-hooks:secret", "present" => true}} =
               Secrets.set("cue_source:gh-hooks:secret", "whsec-invented-7781")

      assert {:ok, %{"source" => stored}} = Cues.sources_get("gh-hooks", opts)
      assert %{"state" => "not_running", "missing_secret" => nil} = stored
      assert {:ok, %{missing_secret: nil}} = CuesConfig.source("gh-hooks")
      refute config_text(home) =~ "whsec-invented-7781"
      assert config_text(home) =~ ~s(secret = "@keyring")

      assert {:ok, %{"present" => false}} = Secrets.clear("cue_source:gh-hooks:secret")
      assert {:ok, %{missing_secret: :secret}} = CuesConfig.source("gh-hooks")
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

      assert {:error, {:invalid_params, "ref", _name_rule}} =
               Cues.sources_add("Bad Name", "local_push", nil, %{}, opts)
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
    test "with nothing chosen it is a feed's" do
      assert {:ok, form} = Cues.sources_form(nil, nil, nil, available?: true)

      assert Enum.map(form["kinds"], & &1["id"]) == ~w(feed stream webhook local_push)
      assert Enum.map(form["presets"], & &1["id"]) == ~w(bluesky_jetstream github rss)
      assert Enum.map(form["rows"], & &1["key"]) == ~w(ref url interval_minutes daily_budget)
      assert form["consent_sentence"] =~ "new items"
      assert form["notes"] == []
    end

    test "a preset decides the kind and fills its fields under More options" do
      assert {:ok, form} = Cues.sources_form(nil, "github", nil, available?: true)

      keys = Enum.map(form["rows"], & &1["key"])
      assert keys == ~w(ref verify header algorithm prefix id_header content_hash type_header
                        daily_budget secret)

      assert %{"value" => "hmac", "advanced" => true} =
               Enum.find(form["rows"], &(&1["key"] == "verify"))

      assert %{"kind" => "secret", "present" => false, "label" => "Signing secret"} =
               List.last(form["rows"])

      assert "In GitHub's webhook form, choose `application/json` as the content type." in form[
               "notes"
             ]
    end

    test "a choice it does not know, or a preset of another kind, is refused" do
      assert Cues.sources_form("pigeon", nil, nil, available?: true) ==
               {:error, {:invalid_params, "kind", "Fermix has no source kind by that name."}}

      assert Cues.sources_form("feed", "github", nil, available?: true) ==
               {:error, {:invalid_params, "preset", "The GitHub preset makes a Webhook source."}}

      assert Cues.sources_form("webhook", nil, "md5", available?: true) ==
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

    test "an llm watcher with no model while no default is set waits for one", %{
      opts: opts,
      conn: conn
    } do
      CueFixtures.insert_watcher(conn, %{name: "news", filter: "llm", sources: ["s"]})

      assert {:ok, %{"watchers" => [%{"state" => "no_model"}]}} = Cues.watchers_list(opts)

      Application.put_env(:fermix_core, :routing,
        filter_provider: "anthropic",
        filter_model: "claude-haiku-4-5"
      )

      assert {:ok, %{"watchers" => [%{"state" => "on"}]}} = Cues.watchers_list(opts)
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
               {"filter_provider", "choice", false},
               {"filter_model", "choice", false},
               {"cues_door_port", "number", true}
             ]

      provider = Enum.find(rows, &(&1["key"] == "filter_provider"))
      assert %{"value" => "", "label" => "None"} = hd(provider["options"])
      assert Enum.find(rows, &(&1["key"] == "filter_model"))["suggestions"] == true
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

    test "clearing the default model says how many watchers now wait for one", %{
      conn: conn,
      repo: repo
    } do
      CueFixtures.insert_watcher(conn, %{name: "a", filter: "llm", sources: ["s"]})
      CueFixtures.insert_watcher(conn, %{name: "b", filter: "llm", sources: ["s"]})
      CueFixtures.insert_watcher(conn, %{name: "c", filter: "none", sources: ["s"]})

      before = %{fermix_core: [routing: [filter_provider: "anthropic", filter_model: "m"]]}
      current = %{fermix_core: [routing: []]}

      assert CuesSection.side_effects(before, current, repo: repo) ==
               ["2 watchers now wait for a filter model."]

      assert CuesSection.side_effects(current, before, repo: repo) == []

      # Watchers that cannot be read are not "none waiting": the sentence says
      # so without a count, and the log says why.
      failing = start_supervised!(FailingRepo)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert CuesSection.side_effects(before, current, repo: failing) ==
                   ["Watchers with no filter model of their own now wait for one."]
        end)

      assert log =~ "corrupt"
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
        {"cues.sources.add", %{"kind" => "feed", "values" => %{}}, %{"field" => "ref"}},
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
         %{"ref" => "gh-hooks", "preset" => "github", "values" => %{}}},
        {"cues_sources_url_get", "cues.sources.url.get", %{"ref" => "gh-hooks"}},
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

    test "the cue refusals are the golden ones", %{opts: opts} do
      assert {:error, :unavailable, details} =
               route("cues.sources.list", %{}, Keyword.put(opts, :available?, false))

      assert details == golden_error("unavailable_cues_build")

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
