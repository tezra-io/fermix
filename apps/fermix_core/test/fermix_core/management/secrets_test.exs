defmodule FermixCore.Management.SecretsTest do
  @moduledoc """
  `secret.set` and `secret.clear` (M34 native setup §7.4).

  The two properties worth proving are the ones that were silently wrong before
  this method existed: a stored key has to be READABLE afterwards, which means
  the reference has to land beside the keyring item, and a rotation into an
  unreadable keyring has to fail loud rather than report success while the old
  value survives.
  """

  use ExUnit.Case, async: false

  alias FermixCore.Auth.Store, as: AuthStore
  alias FermixCore.Auth.TokenSupervisor
  alias FermixCore.Management.Secrets
  alias FermixCore.Plugins.Config, as: PluginConfig
  alias FermixCore.Providers.PrimaryConfig
  alias FermixCore.Providers.Selection
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState
  alias FermixCore.Setup.SecretStore
  alias FermixCore.Setup.SecretWriter
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub
  alias FermixTestSupport.UnavailableSecretWriter

  @core_keys [:providers, :tools, :transcription, :meetings, :secret_writer]

  setup do
    home = System.get_env("FERMIX_HOME")
    core = Map.new(@core_keys, fn key -> {key, Application.get_env(:fermix_core, key)} end)
    telegram = Application.get_env(:fermix_channels, :telegram)

    Application.put_env(:fermix_core, :secret_writer, SecretWriterStub)
    SecretWriterStub.reset()

    tmp = SafeRm.make_tmp_dir!("management_secrets_home")
    System.put_env("FERMIX_HOME", tmp)
    :ok = RestartState.record_persisted_baseline()

    on_exit(fn ->
      :ok = TokenSupervisor.stop_profile(AuthStore.profile(:anthropic))
      Enum.each(core, fn {key, value} -> restore(:fermix_core, key, value) end)
      restore(:fermix_channels, :telegram, telegram)
      SecretWriterStub.reset()

      case home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      SafeRm.rm_rf!(tmp)
      :ok = RestartState.record_persisted_baseline()
    end)

    %{home: tmp}
  end

  describe "storing a secret" do
    # The half that used to be missed: a write that stored the item alone would
    # report the key present and never load it, leaving the provider
    # unconfigured while the pane said otherwise.
    test "the value reaches the keyring and the reference reaches the settings file", %{
      home: home
    } do
      Application.put_env(:fermix_core, :providers, openai: [])

      assert {:ok, view} = Secrets.set("openai_api_key", "sk-live")

      assert view["id"] == "openai_api_key"
      assert view["present"]
      assert SecretWriter.get(:openai_api_key) == {:ok, "sk-live"}
      assert File.read!(Path.join(home, "config.toml")) =~ SecretWriter.sentinel()
      refute File.read!(Path.join(home, "config.toml")) =~ "sk-live"

      assert Selection.configured?(
               :openai,
               Application.get_env(:fermix_core, :providers)[:openai]
             )
    end

    test "the result carries the restart state and never the value" do
      assert {:ok, view} = Secrets.set("openai_api_key", "sk-live")

      assert %{"required" => _required, "reasons" => _reasons} = view["restart"]
      assert Map.keys(view) |> Enum.sort() == ~w(id present restart)
      refute inspect(view) =~ "sk-live"
    end

    test "a channel token lands in its own channel block" do
      assert {:ok, %{"present" => true}} = Secrets.set("telegram_bot_token", "1:abc")

      assert value_at([:fermix_channels, :telegram, :bot_token]) == "1:abc"
      assert SecretWriter.get(:telegram_bot_token) == {:ok, "1:abc"}
    end

    # A save runs the whole pipeline every sibling writer runs, including the
    # env-only drop, or a key the shell supplied would be persisted as plaintext
    # by a write that was about a different key.
    test "a value supplied only by the environment is not persisted by an unrelated write", %{
      home: home
    } do
      Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-from-the-shell"])

      assert {:ok, _view} = Secrets.set("telegram_bot_token", "1:abc")

      contents = File.read!(Path.join(home, "config.toml"))
      refute contents =~ "sk-from-the-shell"
    end
  end

  describe "forgetting a secret" do
    # The runtime has to stop using it, not only the file: `apply_snapshot/2`
    # merges, so a forget that rewrote the document alone would leave the value
    # in application environment until a restart.
    test "removes the keyring item, the reference, and the value in force", %{home: home} do
      assert {:ok, %{"present" => true}} = Secrets.set("openai_api_key", "sk-live")

      assert {:ok, view} = Secrets.clear("openai_api_key")

      refute view["present"]
      assert SecretWriter.get(:openai_api_key) == {:error, :missing_secret}
      refute File.read!(Path.join(home, "config.toml")) =~ SecretWriter.sentinel()
      assert value_at([:fermix_core, :providers, :openai, :api_key]) == nil
    end
  end

  describe "refusals" do
    test "an id this daemon does not store is refused by name" do
      assert {:error, {:invalid_params, "id", sentence}} = Secrets.set("not_a_secret", "x")
      assert sentence =~ "no secret by that name"
    end

    test "an empty value is refused rather than stored as a blank credential" do
      assert {:error, {:invalid_params, "value", _sentence}} = Secrets.set("openai_api_key", "")
    end

    test "a value above the published ceiling is refused" do
      oversized = String.duplicate("x", 8_193)

      assert {:error, {:invalid_params, "value", sentence}} =
               Secrets.set("openai_api_key", oversized)

      assert sentence =~ "8192"
    end

    # The operator typed a new credential. Reporting success while the keyring
    # refused would leave the old value in force with nothing saying so.
    test "a keyring that cannot be written fails loud with a published reason" do
      Application.put_env(:fermix_core, :secret_writer, UnavailableSecretWriter)

      assert {:error, {:secret_store_failed, "openai_api_key", reason}} =
               Secrets.set("openai_api_key", "sk-live")

      assert reason in ~w(unavailable locked timeout)
    end

    test "a write refuses while the settings file has changed outside Fermix", %{home: home} do
      File.write!(Path.join(home, "config.toml"), """
      [fermix_core.memory]
      review_interval_hours = 12
      """)

      assert {:error, {:external_change, _sections}} = Secrets.set("openai_api_key", "sk-live")
    end
  end

  test "every published id is a registry key, so a client can enumerate them" do
    assert "openai_api_key" in Secrets.ids()
    assert "telegram_bot_token" in Secrets.ids()
    assert Secrets.ids() == Enum.uniq(Secrets.ids())
  end

  # The integrations surface addresses two families by prefix rather than by the
  # registry key behind them, and both land on the same keychain-first write:
  # routing them through `Plugins.Config` instead would rotate into a locked
  # keychain and report success while the old value survived.
  describe "the prefixed id families" do
    test "a plugin's own token stores under the plugin's registered key", %{home: home} do
      Application.put_env(:fermix_core, :plugin_secrets, %{})

      assert {:ok, view} = Secrets.set("plugin:eden", "eden-token")

      assert view["id"] == "plugin:eden"
      assert view["present"]
      assert SecretWriter.get(:eden_plugin_secret) == {:ok, "eden-token"}
      assert PluginConfig.plugin_secret("eden") == "eden-token"

      persisted = File.read!(Path.join(home, "config.toml"))
      assert persisted =~ SecretWriter.sentinel()
      refute persisted =~ "eden-token"
    end

    test "a sign-in client's secret stores under the provider's registered key", %{home: home} do
      assert {:ok, view} = Secrets.set("oauth_client:google", "client-secret")

      assert view["id"] == "oauth_client:google"
      assert view["present"]
      assert SecretWriter.get(:google_oauth_client_secret) == {:ok, "client-secret"}
      assert Keyword.get(PluginConfig.oauth_provider("google"), :client_secret) == "client-secret"
      refute File.read!(Path.join(home, "config.toml")) =~ "client-secret"
    end

    test "clearing one forgets the keyring item and then the reference" do
      assert {:ok, _stored} = Secrets.set("plugin:eden", "eden-token")
      assert {:ok, view} = Secrets.clear("plugin:eden")

      refute view["present"]
      assert {:error, _absent} = SecretWriter.get(:eden_plugin_secret)
      assert PluginConfig.plugin_secret("eden") in [nil, ""]
    end

    test "a plugin with no registered token slot is refused by name" do
      assert {:error, {:invalid_params, "id", sentence}} = Secrets.set("plugin:gmail", "x")
      assert sentence == "This plugin stores no token of its own."
    end

    test "a provider with no sign-in client is refused by name" do
      assert {:error, {:invalid_params, "id", sentence}} = Secrets.set("oauth_client:linear", "x")
      assert sentence == "This daemon has no sign-in client for that."
    end

    test "both families are enumerable beside the registry keys" do
      assert "plugin:eden" in Secrets.ids()
      assert "oauth_client:google" in Secrets.ids()
      assert Secrets.ids() == Enum.uniq(Secrets.ids())
    end
  end

  # Anthropic's second way in (M34 native setup §7.3/§7.4). It is not a keychain
  # write and not a `SecretPaths` path: a `claude setup-token` value is a
  # long-lived subscription credential that lives in the auth store.
  describe "anthropic_setup_token" do
    test "storing one selects the route that reads it and reports it present" do
      assert {:ok, view} = Secrets.set("anthropic_setup_token", "sk-ant-oat-live")

      assert view["id"] == "anthropic_setup_token"
      assert view["present"]

      assert {:ok, entry} = AuthStore.read(AuthStore.profile(:anthropic))
      assert entry.auth_mode == "setup_token"

      # Stored is not enough: the route has to select it, or the runtime never
      # calls the credential the operator just added.
      assert Keyword.get(provider_block(:anthropic), :auth_mode) == :oauth
      assert Selection.configured?(:anthropic, provider_block(:anthropic))
    end

    # The whole point of the id: it is a connect, so on a fresh home it clears
    # the provider gate rather than leaving the compiled-in default primary.
    test "storing one on a fresh home makes Anthropic primary" do
      assert {:ok, _view} = Secrets.set("anthropic_setup_token", "sk-ant-oat-live")

      assert PrimaryConfig.primary() == {:ok, :anthropic}
    end

    test "the token never reaches the settings file", %{home: home} do
      assert {:ok, _view} = Secrets.set("anthropic_setup_token", "sk-ant-oat-live")

      refute File.read!(Path.join(home, "config.toml")) =~ "sk-ant-oat-live"
    end

    test "clearing one forgets it and reverts the route" do
      assert {:ok, _stored} = Secrets.set("anthropic_setup_token", "sk-ant-oat-live")
      assert {:ok, view} = Secrets.clear("anthropic_setup_token")

      refute view["present"]
      assert {:error, _absent} = AuthStore.read(AuthStore.profile(:anthropic))
      assert Keyword.get(provider_block(:anthropic), :auth_mode) == :api_key
    end

    # Same rule as every other clear: the postcondition already holds.
    test "clearing one that was never stored succeeds" do
      assert {:ok, view} = Secrets.clear("anthropic_setup_token")

      refute view["present"]
    end

    test "an empty token is refused by field" do
      assert {:error, {:invalid_params, "value", sentence}} =
               Secrets.set("anthropic_setup_token", "")

      assert sentence == "A secret cannot be empty."
    end

    test "it is enumerable beside the registry keys" do
      assert "anthropic_setup_token" in Secrets.ids()
      assert Secrets.ids() == Enum.uniq(Secrets.ids())
    end
  end

  describe "the published contract" do
    # Storing a boot-bound key is itself the restart reason, so the reason list
    # this case compares is seeded by this case rather than by whichever one ran
    # before it.
    test "the set and clear fixtures carry the shape the writer returns" do
      assert {:ok, stored} = Secrets.set("openai_api_key", "sk-live")
      assert stored["restart"]["reasons"] != []
      assert shape(stored) == shape(fixture_result("secret.set"))

      assert {:ok, cleared} = Secrets.clear("openai_api_key")
      assert shape(cleared) == shape(fixture_result("secret.clear"))
    end
  end

  defp fixture_result(method) do
    :fermix_core
    |> Application.app_dir("priv/management/fixtures/success.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.find(&(&1["method"] == method))
    |> get_in(["response", "result"])
  end

  defp shape(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, shape(v)} end)
  defp shape([]), do: []
  defp shape([head | _rest]), do: [shape(head)]
  defp shape(_value), do: :scalar

  defp value_at(path),
    do: SecretStore.get_snapshot_value(ConfigStore.current_snapshot(), path)

  defp provider_block(provider) do
    Application.get_env(:fermix_core, :providers, []) |> Keyword.get(provider, [])
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
