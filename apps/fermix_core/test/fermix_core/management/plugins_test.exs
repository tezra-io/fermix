defmodule FermixCore.Management.PluginsTest do
  @moduledoc """
  The `plugins.*` surface (M34 native setup §5.6, §7.3).

  Nothing here downloads, signs in, or opens a socket: the installer, the health
  probe, the workspace discovery and the workspace binding are all injected, and
  the two write verbs that persist run against a tmp `FERMIX_HOME` through the
  real writer, which is the half a stub would hide.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Capabilities.MCP.RuntimeStatus
  alias FermixCore.ComputerUse.SidecarInstaller
  alias FermixCore.Management.Auth, as: ManagementAuth
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.Plugins
  alias FermixCore.Management.Plugins.Discovery
  alias FermixCore.Management.Plugins.Row
  alias FermixCore.Management.Secrets
  alias FermixCore.Plugins.CanonicalJson
  alias FermixCore.Plugins.Config, as: PluginConfig
  alias FermixCore.Plugins.Dist.Store, as: DistStore
  alias FermixCore.Plugins.Status
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState
  alias FermixTestSupport.DistFixtures
  alias FermixTestSupport.DistVerifierStub
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub

  @bundled "google_calendar"
  @remote "workspacedemo"
  @configurable "settingdemo"

  setup do
    home = System.get_env("FERMIX_HOME")
    plugins = Application.get_env(:fermix_core, :plugins)
    oauth = Application.get_env(:fermix_core, :oauth)
    secrets = Application.get_env(:fermix_core, :plugin_secrets)
    writer = Application.get_env(:fermix_core, :secret_writer)

    tmp = SafeRm.make_tmp_dir!("management_plugins_home")
    System.put_env("FERMIX_HOME", tmp)
    Application.put_env(:fermix_core, :plugins, [])
    Application.put_env(:fermix_core, :oauth, %{})
    Application.put_env(:fermix_core, :plugin_secrets, %{})
    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    SecretWriterStub.reset()

    on_exit(fn ->
      RuntimeStatus.clear(RuntimeStatus, {:plugin, @remote})
      restore(:fermix_core, :plugins, plugins)
      restore(:fermix_core, :oauth, oauth)
      restore(:fermix_core, :plugin_secrets, secrets)
      restore(:fermix_core, :secret_writer, writer)
      SecretWriterStub.reset()

      case home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      SafeRm.rm_rf!(tmp)
    end)

    %{home: tmp, discovery: start_discovery()}
  end

  describe "list/1" do
    test "publishes the registry as installed rows and the rest of the catalog as available ones" do
      {:ok, %{"plugins" => rows}} = Plugins.list()

      installed = row(rows, @bundled)

      assert installed["installed"] == true
      assert installed["enabled"] == false
      assert installed["title"] == "Google Calendar"
      assert installed["auth_kind"] == "oauth"
      assert installed["auth_provider"] == "google"
      assert installed["status"] == "not_configured"
      assert installed["status_sentence"] == "Installed and turned off."
      assert installed["primary_verb"] == "Turn on"
      assert is_binary(installed["summary"])

      available = row(rows, "notion")

      assert available["installed"] == false
      assert available["status"] == "available"
      assert available["status_sentence"] == "Not installed."
      assert available["primary_verb"] == "Install…"
      assert available["verbs"] == ["Install…"]
    end

    # A row a client cannot decode is worse than a row it never sees, so both
    # halves of the union publish exactly one shape.
    test "both halves of the union publish the same fields" do
      {:ok, %{"plugins" => rows}} = Plugins.list()

      installed = rows |> Enum.filter(& &1["installed"]) |> List.first()
      available = rows |> Enum.reject(& &1["installed"]) |> List.first()

      assert Enum.sort(Map.keys(installed)) == Enum.sort(Map.keys(available))
    end

    # Computer use is a settings pane with its own switch. A row here would be a
    # second writer of one daemon key, and the browser door drops it for the same
    # reason.
    test "the native driver sidecar never appears as an integration" do
      {:ok, %{"plugins" => rows}} = Plugins.list()

      refute Enum.any?(rows, &(&1["name"] == SidecarInstaller.plugin_name()))
    end

    test "a sign-in client is published only where a plugin needs one" do
      {:ok, %{"oauth_clients" => clients}} = Plugins.list()

      providers = Enum.map(clients, & &1["provider"])

      assert "google" in providers
      assert "github" in providers
      # The Slack plugin authenticates with a bot token, so it names no OAuth
      # provider and its client row must not appear.
      refute "slack" in providers
      assert Enum.all?(clients, &(&1["configured"] == false))
      assert Enum.all?(clients, &(&1["redirect_port"] == nil))
    end

    test "a client identifier remains editable when its secret is absent" do
      Application.put_env(:fermix_core, :oauth, %{"google" => [client_id: "public-client"]})

      {:ok, %{"oauth_clients" => clients}} = Plugins.list()
      google = Enum.find(clients, &(&1["provider"] == "google"))

      assert google["client_id"] == "public-client"
      assert google["secret_present"] == false
      assert google["configured"] == false
    end

    test "a stored secret is present independently of a complete client" do
      Application.put_env(:fermix_core, :oauth, %{"google" => [client_secret: "private-secret"]})

      {:ok, %{"oauth_clients" => clients}} = Plugins.list()
      google = Enum.find(clients, &(&1["provider"] == "google"))

      assert google["client_id"] == nil
      assert google["secret_present"] == true
      assert google["configured"] == false
      refute Jason.encode!(clients) =~ "private-secret"
    end

    test "a stored client id and secret make the client configured" do
      Application.put_env(:fermix_core, :oauth, %{
        "google" => [
          client_id: "123.apps.googleusercontent.com",
          client_secret: "s",
          redirect_port: 1455
        ]
      })

      {:ok, %{"oauth_clients" => clients}} = Plugins.list()
      google = Enum.find(clients, &(&1["provider"] == "google"))

      assert google["configured"] == true
      assert google["redirect_port"] == 1455
    end

    # The consent sentence is the field the catalog shipped wrong once: a hosted
    # plugin rendering the local-process line tells the operator their content
    # stays on this Mac when it does not.
    test "the consent sentence names where the plugin's code actually runs" do
      {:ok, %{"plugins" => rows}} = Plugins.list()

      assert row(rows, @bundled)["consent_sentence"] == "Runs inside Fermix on this Mac."
      assert row(rows, @bundled)["remote_disclosure"] == nil

      hosted = row(rows, "eden")
      assert hosted["runtime_kind"] == "remote_mcp"
      assert hosted["consent_sentence"] == "Runs on the plugin's own servers, not on this Mac."
      assert hosted["remote_disclosure"] =~ "leave this Mac"

      separate = row(rows, "obsidian")
      assert separate["runtime_kind"] == "local_stdio"
      assert separate["consent_sentence"] == "Runs on this Mac as a separate process."
    end

    test "an installed remote plugin publishes its access profiles and its binding", %{home: home} do
      install_remote(home)

      {:ok, %{"plugins" => rows}} = Plugins.list()
      hosted = row(rows, @remote)

      assert hosted["runtime_kind"] == "remote_mcp"
      assert hosted["auth_kind"] == "api_key"

      assert hosted["access_profiles"] == [
               %{"id" => "retrieval", "label" => "Retrieval only", "write" => false},
               %{"id" => "capture", "label" => "Retrieval and capture", "write" => true}
             ]

      assert hosted["workspaces"] == []
      assert hosted["workspace_id"] == nil
    end

    test "the live runtime table refines a plugin the local ladder calls startable", %{home: home} do
      install_remote(home)
      enable_remote()

      entries = %{{:plugin, @remote} => %{status: :remote_unreachable}}
      {:ok, %{"plugins" => rows}} = Plugins.list(runtime_entries: fn -> entries end)

      assert row(rows, @remote)["status"] == "remote_unreachable"

      assert row(rows, @remote)["status_sentence"] ==
               "Turned on, but its service could not be reached."
    end

    # The local ladder answers whether the plugin can start at all. A live table
    # that outranked it would report a connection for a plugin with no token.
    test "the live table never outranks a plugin that cannot start", %{home: home} do
      install_remote(home)

      entries = %{{:plugin, @remote} => %{status: :ready}}
      {:ok, %{"plugins" => rows}} = Plugins.list(runtime_entries: fn -> entries end)

      assert row(rows, @remote)["status"] == "not_configured"
    end

    test "republishes what the last workspace discovery found", %{home: home, discovery: server} do
      install_remote(home)
      :ok = Discovery.record(@remote, [%{id: "ws_alpha", label: "Alpha"}], discovery: server)

      {:ok, %{"plugins" => rows}} = Plugins.list(discovery: server)

      assert row(rows, @remote)["workspaces"] == [%{id: "ws_alpha", label: "Alpha"}]
    end
  end

  describe "vocabulary" do
    # Hand-maintained sentence tables rot. This derives the case set from the two
    # modules that mint statuses, so one added there fails here rather than
    # reaching a surface with no words for it.
    test "every status the daemon can answer with carries a sentence" do
      minted = Enum.uniq(Status.statuses() ++ RuntimeStatus.statuses() ++ [:available])

      assert Enum.sort(Row.statuses()) == Enum.sort(minted)

      for status <- Row.statuses() do
        sentence = Row.check_sentence(status)

        assert String.ends_with?(sentence, "."), "#{status} has no sentence"
      end
    end

    test "every verb a row publishes is in the published vocabulary", %{home: home} do
      install_remote(home)
      {:ok, %{"plugins" => rows}} = Plugins.list()

      published = rows |> Enum.flat_map(& &1["verbs"]) |> Enum.uniq()
      leading = rows |> Enum.map(& &1["primary_verb"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()

      assert published != []
      assert Enum.all?(published, &(&1 in Row.verbs()))
      assert Enum.all?(leading, &(&1 in Row.verbs()))
    end

    test "the leading verb is the first of the row's own verbs" do
      {:ok, %{"plugins" => rows}} = Plugins.list()

      for row <- rows, verb = row["primary_verb"], not is_nil(verb) do
        assert List.first(row["verbs"]) == verb
      end
    end
  end

  describe "enable/2 and disable/2" do
    test "turning one on answers with its row and persists", %{home: home} do
      assert {:ok, %{"plugin" => enabled}} = Plugins.enable(@bundled)

      assert enabled["enabled"] == true
      assert enabled["name"] == @bundled
      assert File.read!(Path.join(home, "config.toml")) =~ "[fermix_core.plugins]"

      assert {:ok, %{"plugin" => disabled}} = Plugins.disable(@bundled)
      assert disabled["enabled"] == false
      assert disabled["status_sentence"] == "Installed and turned off."
    end

    test "a name this daemon has never heard of is refused with a sentence" do
      assert {:error, {:invalid_params, "name", sentence}} = Plugins.enable("nope")
      assert sentence == "This daemon has no plugin by that name."
    end

    # A catalog name is not a typo: the operator picked it off the very list
    # this daemon published, so "no plugin by that name" sends them hunting for
    # a misspelling instead of pressing Install.
    test "a name the catalog carries but nothing has installed says to install it" do
      catalog_only = catalog_only_name()

      for verb <- [&Plugins.enable/1, &Plugins.disable/1, &Plugins.disconnect/1] do
        assert {:error, {:invalid_params, "name", sentence}} = verb.(catalog_only)
        assert sentence == "Install this plugin before using it."
      end
    end
  end

  describe "disconnect/2" do
    test "an OAuth plugin forgets its session and answers with the row" do
      logout = fn name ->
        send(self(), {:logged_out, name})
        :ok
      end

      assert {:ok, %{"plugin" => row}} = Plugins.disconnect(@bundled, logout: logout)
      assert_received {:logged_out, @bundled}
      assert row["credential_present"] == false
    end

    test "a plugin holding no credential says so rather than reporting a forget", %{home: home} do
      install_configurable(home)

      assert {:error, {:invalid_params, "name", sentence}} = Plugins.disconnect(@configurable)
      assert sentence == "This plugin holds no credential to forget."
    end
  end

  describe "setting_set/4" do
    test "writes one manifest-declared setting and republishes it on the row", %{home: home} do
      install_configurable(home)

      assert {:ok, %{"plugin" => row}} =
               Plugins.setting_set(@configurable, "DEMO_FOLDER", "/tmp/notes")

      assert row["settings"] == [
               %{
                 "key" => "DEMO_FOLDER",
                 "label" => "Folder to read",
                 "value" => "/tmp/notes",
                 "required" => true
               }
             ]
    end

    test "a key the manifest does not declare is refused", %{home: home} do
      install_configurable(home)

      assert {:error, {:invalid_params, "key", sentence}} =
               Plugins.setting_set(@configurable, "DEMO_OTHER", "x")

      assert sentence == "This plugin declares no setting by that name."
    end

    test "a value that is not text is refused before any write", %{home: home} do
      install_configurable(home)

      assert {:error, {:invalid_params, "value", sentence}} =
               Plugins.setting_set(@configurable, "DEMO_FOLDER", 5)

      assert sentence == "A plugin setting is text, and cannot be empty."
      assert PluginConfig.plugin_settings(@configurable) == %{}
    end
  end

  describe "oauth_client_set/4" do
    test "refuses until the client secret has been stored" do
      assert {:error, {:invalid_params, "provider", sentence}} =
               Plugins.oauth_client_set("google", "123.apps.googleusercontent.com", 1455)

      assert sentence == "Add this provider's client secret first."
    end

    # The client secret arrives only through `secret.set`, and the one writer
    # replaces the provider block whole: a call that does not carry it forward
    # erases the credential it is not allowed to send.
    test "carries the stored client secret through the write" do
      Application.put_env(:fermix_core, :oauth, %{"google" => [client_secret: "kept"]})

      assert {:ok, %{"oauth_client" => client}} =
               Plugins.oauth_client_set("google", "123.apps.googleusercontent.com", 1455)

      assert client == %{
               "provider" => "google",
               "configured" => true,
               "redirect_port" => 1455,
               "client_id" => "123.apps.googleusercontent.com",
               "secret_present" => true
             }

      stored = Application.get_env(:fermix_core, :oauth)["google"]
      assert Keyword.get(stored, :client_secret) == "kept"
      assert Keyword.get(stored, :client_id) == "123.apps.googleusercontent.com"
    end

    test "an absent redirect port clears the override" do
      Application.put_env(:fermix_core, :oauth, %{
        "google" => [client_secret: "kept", redirect_port: 4321]
      })

      assert {:ok, %{"oauth_client" => client}} =
               Plugins.oauth_client_set("google", "123.apps.googleusercontent.com", nil)

      assert client["redirect_port"] == nil
    end

    # The app's own order: the sheet stores the secret through `secret.set` and
    # then registers the client. The second call must find the first call's
    # value, or the client is written without the credential it needs.
    test "follows the secret that secret.set stored" do
      assert {:ok, _view} = Secrets.set("oauth_client:google", "client-secret")

      assert {:ok, %{"oauth_client" => client}} =
               Plugins.oauth_client_set("google", "123.apps.googleusercontent.com", 1455)

      assert client["configured"] == true

      {:ok, %{"oauth_clients" => clients}} = Plugins.list()
      assert Enum.find(clients, &(&1["provider"] == "google"))["configured"] == true
      assert Keyword.get(PluginConfig.oauth_provider("google"), :client_secret) == "client-secret"
    end

    test "a provider no plugin signs in through is refused" do
      assert {:error, {:invalid_params, "provider", sentence}} =
               Plugins.oauth_client_set("linear", "id", nil)

      assert sentence == "No plugin on this Mac signs in through that."
    end
  end

  describe "install_start/2" do
    test "publishes its own kind, phase and budget, and finishes with the name" do
      parent = self()

      install = fn name, _opts ->
        send(parent, {:installing, name})
        {:ok, :installed}
      end

      assert {:ok, view} = Plugins.install_start("notion", jobs: jobs(), install: install)

      assert view["kind"] == "plugin_install"
      assert view["budget_ms"] == 600_000
      assert_received {:installing, "notion"}
      assert %{"status" => "completed", "phase" => nil} = await(view, jobs())
    end

    test "a refused install carries the installer's own words, never an exit code" do
      install = fn _name, _opts -> {:error, {:bundled_plugin, "notion"}} end

      assert {:ok, view} = Plugins.install_start("notion", jobs: jobs(), install: install)

      finished = await(view, jobs())
      assert finished["status"] == "failed"

      assert finished["failure"]["sentence"] ==
               "This plugin ships inside Fermix and is already installed."
    end

    # The one refusal the design wrote a sentence for. `Installer.run_install/2`
    # answers `{:verification_failed, reason}`; a clause spelled `verify_failed`
    # never matched it, so a signature refusal reached the operator as an
    # inspected tuple instead.
    test "a signature refusal reads as the sentence written for it" do
      install = fn _name, _opts ->
        {:error, {:verification_failed, {:verification_denied, {"notion", "1.2.0"}}}}
      end

      assert {:ok, view} = Plugins.install_start("notion", jobs: jobs(), install: install)
      finished = await(view, jobs())

      assert finished["failure"]["sentence"] ==
               "The download did not match the signature it was published with."
    end

    test "a store lock held by another operation says so" do
      install = fn _name, _opts -> {:error, :lock_unavailable} end

      assert {:ok, view} = Plugins.install_start("notion", jobs: jobs(), install: install)

      assert await(view, jobs())["failure"]["sentence"] ==
               "Another plugin operation is using the plugin store."
    end

    test "a staged tree that vanished says so" do
      install = fn _name, _opts -> {:error, {:tree_missing, "/Users/example/.fermix/plugins"}} end

      assert {:ok, view} = Plugins.install_start("notion", jobs: jobs(), install: install)

      assert await(view, jobs())["failure"]["sentence"] ==
               "The downloaded files were gone before they could be checked."
    end

    # The residue. A reason with no sentence of its own carries the operator's
    # own paths, so the published sentence is fixed and the term goes to the
    # daemon log rather than to the wire and the job bookend.
    test "an unnamed failure publishes a fixed sentence and logs the term" do
      install = fn _name, _opts ->
        {:error, {:store_write_failed, "/Users/example/.fermix/plugins/notion"}}
      end

      log =
        capture_log(fn ->
          assert {:ok, view} = Plugins.install_start("notion", jobs: jobs(), install: install)

          assert await(view, jobs())["failure"]["sentence"] ==
                   "The install did not finish. See the daemon log."
        end)

      assert log =~ "store_write_failed"
      assert log =~ "/Users/example/.fermix/plugins/notion"
    end

    test "one install per plugin at a time" do
      install = fn _name, _opts ->
        Process.sleep(100)
        {:ok, :installed}
      end

      assert {:ok, _view} = Plugins.install_start("notion", jobs: jobs(), install: install)

      assert {:error, {:busy, "plugin_install"}} =
               Plugins.install_start("notion", jobs: jobs(), install: install)
    end
  end

  describe "check_start/2" do
    test "reports the probe it ran" do
      parent = self()

      check = fn name, opts ->
        send(parent, {:checked, name, opts})
        {:ok, %{status: :ready, live_probe?: true}}
      end

      assert {:ok, view} = Plugins.check_start(@bundled, jobs: jobs(), check: check)

      assert view["kind"] == "plugin_check"
      assert_received {:checked, @bundled, [full?: true]}
      assert %{"result" => result} = await(view, jobs())
      assert result == %{"name" => @bundled, "status" => "ready", "live_probe" => true}
    end

    test "a plugin that is not ready is refused with the ladder's own sentence" do
      check = fn _name, _opts -> {:error, {:not_ready, :needs_auth}} end

      assert {:ok, view} = Plugins.check_start(@bundled, jobs: jobs(), check: check)

      finished = await(view, jobs())
      assert finished["failure"]["code"] == "refused"
      assert finished["failure"]["sentence"] =~ "waiting for a sign-in"
    end

    test "a check that failed for another reason publishes a fixed sentence" do
      check = fn _name, _opts -> {:error, {:probe_crashed, "/Users/example/.fermix/plugins"}} end

      log =
        capture_log(fn ->
          assert {:ok, view} = Plugins.check_start(@bundled, jobs: jobs(), check: check)

          assert await(view, jobs())["failure"]["sentence"] ==
                   "The check did not finish. See the daemon log."
        end)

      assert log =~ "probe_crashed"
    end
  end

  describe "the workspace flow" do
    test "a discovery records what it found so the row can republish it", %{
      home: home,
      discovery: server
    } do
      install_remote(home)
      discover = fn _plugin, _opts -> {:ok, [%{id: "ws_alpha", label: "Alpha"}]} end

      assert {:ok, view} =
               Plugins.workspaces_discover_start(@remote,
                 jobs: jobs(),
                 discovery: server,
                 discover: discover
               )

      assert view["kind"] == "plugin_workspaces_discover"
      assert view["budget_ms"] == 60_000
      assert %{"result" => %{"found" => 1}} = await(view, jobs())
      assert Discovery.fetch(@remote, discovery: server) == [%{id: "ws_alpha", label: "Alpha"}]
    end

    test "a selection binds through the reconnect that owns it", %{home: home} do
      install_remote(home)

      parent = self()

      select = fn _plugin, opts ->
        send(parent, {:selected, Keyword.take(opts, [:access_profile, :workspace_id])})
        :ok
      end

      selection = %{"profile" => "retrieval", "workspace_id" => "ws_alpha", "label" => "Alpha"}

      assert {:ok, view} =
               Plugins.workspace_select_start(@remote, selection, jobs: jobs(), select: select)

      assert view["kind"] == "plugin_workspace_select"
      assert %{"result" => %{"bound" => true}} = await(view, jobs())
      assert_received {:selected, [access_profile: "retrieval", workspace_id: "ws_alpha"]}
    end

    test "an access profile the manifest never declared is refused inside the job", %{home: home} do
      install_remote(home)

      select = fn _plugin, _opts -> {:error, {:invalid_access_profile, @remote, "captur"}} end
      selection = %{"profile" => "captur", "workspace_id" => "ws_alpha", "label" => "Alpha"}

      assert {:ok, view} =
               Plugins.workspace_select_start(@remote, selection, jobs: jobs(), select: select)

      finished = await(view, jobs())
      assert finished["failure"]["code"] == "refused"
      assert finished["failure"]["sentence"] == "This plugin does not offer that access level."
    end

    test "a plugin that binds no workspace is refused at the request" do
      assert {:error, {:invalid_params, "name", sentence}} =
               Plugins.workspaces_discover_start(@bundled, jobs: jobs())

      assert sentence == "This plugin does not bind to a workspace."
    end
  end

  # `auth.start` addresses a plugin by the one prefix the contract publishes, and
  # what it refuses is a property of the plugin's own credential kind.
  describe "a plugin sign-in" do
    test "a plugin whose credential is a typed token has no browser flow", %{home: home} do
      install_remote(home)

      assert {:error, {:invalid_params, "provider", sentence}} =
               ManagementAuth.start("plugin:" <> @remote, jobs: jobs())

      assert sentence == "This plugin signs in with a token, not a browser."
    end

    test "a plugin that needs no sign-in says so", %{home: home} do
      install_configurable(home)

      assert {:error, {:invalid_params, "provider", sentence}} =
               ManagementAuth.start("plugin:" <> @configurable, jobs: jobs())

      assert sentence == "This plugin needs no sign-in."
    end
  end

  describe "an outside edit" do
    # The plugin family persists through its own tail, so the refusal reaches the
    # wire as the tagged error the router renders rather than as a bare failure.
    test "refuses the write and names the section", %{home: home} do
      File.write!(
        Path.join(home, "config.toml"),
        "[fermix_core.providers.openai]\napi_key = \"a\"\n"
      )

      :ok = RestartState.record_persisted_baseline()

      File.write!(
        Path.join(home, "config.toml"),
        "[fermix_core.providers.openai]\napi_key = \"b\"\n"
      )

      assert {:error, {:external_change, sections}} = Plugins.enable(@bundled)
      assert "providers" in sections
    end
  end

  # --- helpers ---

  defp row(rows, name) do
    Enum.find(rows, &(&1["name"] == name)) || flunk("no row for #{name}")
  end

  # Read out of the baked catalog rather than named here: the entry that is in
  # the index and nowhere else changes with every catalog sync.
  defp catalog_only_name do
    {:ok, %{"plugins" => rows}} = Plugins.list()
    row = Enum.find(rows, &(&1["installed"] == false)) || flunk("the catalog has no remainder")
    row["name"]
  end

  defp jobs, do: [server: jobs_server()]

  defp jobs_server do
    case Process.whereis(:management_plugins_jobs) do
      nil -> start_jobs()
      pid -> pid
    end
  end

  defp start_jobs do
    tasks = :"management_plugins_tasks_#{System.unique_integer([:positive])}"
    start_supervised!({Task.Supervisor, name: tasks}, id: tasks)

    start_supervised!({Jobs, name: :management_plugins_jobs, task_supervisor: tasks})
  end

  defp start_discovery do
    start_supervised!({Discovery, name: :management_plugins_discovery})
    :management_plugins_discovery
  end

  # Bounded poll: every run in this suite is a stub that answers at once, so a
  # job that has not finished inside the cap is a defect rather than slowness.
  defp await(view, jobs_opts), do: await(view["job_id"], jobs_opts, 50)

  defp await(job_id, jobs_opts, 0) do
    {:ok, view} = Jobs.get(job_id, jobs_opts)
    flunk("job #{job_id} never finished: #{inspect(view)}")
  end

  defp await(job_id, jobs_opts, attempts) do
    {:ok, view} = Jobs.get(job_id, jobs_opts)

    if view["status"] == "running" do
      Process.sleep(10)
      await(job_id, jobs_opts, attempts - 1)
    else
      view
    end
  end

  defp enable_remote do
    Application.put_env(:fermix_core, :plugin_secrets, %{@remote => "token"})
    {:ok, _snapshot} = PluginConfig.enable(@remote)

    {:ok, _snapshot} =
      PluginConfig.set_workspace_selection(@remote,
        access_profile: "retrieval",
        workspace_id: "ws_alpha",
        workspace_label: "Alpha"
      )

    :ok
  end

  defp install_remote(home) do
    store = ConfigStore.workspace_paths().plugins
    fixtures = Path.join(home, "fixtures")
    File.mkdir_p!(fixtures)
    DistStore.ensure!(store)
    DistVerifierStub.init()
    on_exit(&DistVerifierStub.cleanup/0)

    :ok = DistFixtures.install_remote_plugin(store, fixtures, @remote, "1.0.0", remote_manifest())
    :ok = DistVerifierStub.allow(@remote, "1.0.0")
  end

  # A plain local plugin with one declared config key: the setting rows are a
  # manifest fact, and no bundled plugin declares one.
  defp install_configurable(_home) do
    store = ConfigStore.workspace_paths().plugins
    DistStore.ensure!(store)
    dir = DistStore.version_dir(store, @configurable, "1.0.0")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "plugin.json"), Jason.encode!(configurable_manifest()))
    :ok = DistStore.activate(store, @configurable, "1.0.0")

    :ok =
      DistStore.record(store, @configurable, %{
        "version" => "1.0.0",
        "sha256" => String.duplicate("0", 64),
        "h1" => String.duplicate("0", 64),
        "plugin_api" => 2,
        "min_core_version" => "0.1.0"
      })
  end

  defp configurable_manifest do
    %{
      "schema_version" => 2,
      "name" => @configurable,
      "display_name" => "Setting Demo",
      "description" => "A local plugin with one declared setting.",
      "category" => "developer",
      "version" => "1.0.0",
      "min_core_version" => "0.1.0",
      "plugin_api" => 2,
      "auth" => %{"type" => "none"},
      "config" => [%{"key" => "DEMO_FOLDER", "prompt" => "Folder to read", "required" => true}],
      "tools" => [],
      "skills" => []
    }
  end

  defp remote_manifest do
    %{
      "schema_version" => 2,
      "plugin_api" => 3,
      "min_core_version" => "0.1.0",
      "name" => @remote,
      "display_name" => "Workspace Demo",
      "description" => "A remote MCP plugin with a single-workspace resource scope.",
      "category" => "productivity",
      "version" => "1.0.0",
      "default_enabled" => false,
      "auth" => %{
        "type" => "api_key",
        "key_name" => "WORKSPACEDEMO_TOKEN",
        "header" => "Authorization",
        "scheme" => "Bearer",
        "prompt" => "Paste a token"
      },
      "runtime" => %{
        "kind" => "remote_mcp",
        "transport" => "streamable_http",
        "protocol_version" => "2025-06-18",
        "base_url" => "https://mcp.example.com",
        "mcp_path" => "/mcp",
        "tool_name_mode" => "preserve"
      },
      "tool_profiles" => [
        %{
          "name" => "retrieval",
          "display_name" => "Retrieval only",
          "default" => true,
          "required_credential_scope" => "read",
          "scope_visibility" => "none",
          "tools" => ["workspacedemo_search"]
        },
        %{
          "name" => "capture",
          "display_name" => "Retrieval and capture",
          "default" => false,
          "required_credential_scope" => "write",
          "scope_visibility" => "none",
          "tools" => ["workspacedemo_search", "workspacedemo_write"]
        }
      ],
      "setup_tools" => ["workspacedemo_list_workspaces"],
      "resource_scope" => %{
        "kind" => "single_workspace",
        "discovery_tool" => "workspacedemo_list_workspaces",
        "id_field" => "id",
        "label_field" => "name",
        "argument" => "workspaceId"
      },
      "budgets" => %{"agent_turn_calls" => 20, "agent_turn_paginated_calls" => 5},
      "result_contract" => %{
        "kind" => "json_boolean",
        "success_field" => "ok",
        "status_field" => "status",
        "message_field" => "message"
      },
      "tools" => [workspaces_tool(), search_tool(), write_tool()],
      "skills" => []
    }
  end

  defp workspaces_tool do
    sign(%{
      "name" => "workspacedemo_list_workspaces",
      "description" => "List workspaces available to the connected token.",
      "policy_class" => "external_api",
      "read_only" => true,
      "replay_safe" => false,
      "required_credential_scope" => "read",
      "rail" => "mcp",
      "collection_policy" => nil,
      "argument_guards" => [],
      "parameters" => %{"type" => "object", "properties" => %{}},
      "output_schema" => nil,
      "upstream_annotations" => nil
    })
  end

  defp search_tool do
    sign(%{
      "name" => "workspacedemo_search",
      "description" => "Search a workspace.",
      "policy_class" => "external_api",
      "read_only" => true,
      "replay_safe" => true,
      "required_credential_scope" => "read",
      "rail" => "mcp",
      "collection_policy" => nil,
      "argument_guards" => [],
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "workspaceId" => %{"type" => "string"},
          "query" => %{"type" => "string"}
        },
        "required" => ["workspaceId", "query"]
      },
      "output_schema" => nil,
      "upstream_annotations" => nil
    })
  end

  defp write_tool do
    sign(%{
      "name" => "workspacedemo_write",
      "description" => "Append to a note.",
      "policy_class" => "external_api",
      "read_only" => false,
      "replay_safe" => false,
      "required_credential_scope" => "write",
      "rail" => "mcp",
      "collection_policy" => nil,
      "argument_guards" => [],
      "parameters" => %{
        "type" => "object",
        "properties" => %{
          "workspaceId" => %{"type" => "string"},
          "text" => %{"type" => "string"}
        }
      },
      "output_schema" => nil,
      "upstream_annotations" => nil
    })
  end

  defp sign(tool) do
    {:ok, digest} =
      CanonicalJson.descriptor_digest(
        Map.fetch!(tool, "name"),
        Map.fetch!(tool, "parameters"),
        Map.get(tool, "output_schema"),
        Map.get(tool, "upstream_annotations")
      )

    Map.put(tool, "descriptor_sha256", digest)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
