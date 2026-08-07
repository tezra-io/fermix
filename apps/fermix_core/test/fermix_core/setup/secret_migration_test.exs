defmodule FermixCore.Setup.SecretMigrationTest do
  use ExUnit.Case, async: false

  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.SecretMigration
  alias FermixCore.Setup.SecretPaths

  setup do
    previous_home = System.get_env("FERMIX_HOME")
    previous_writer = Application.get_env(:fermix_core, :secret_writer)
    home = FermixTestSupport.SafeRm.make_tmp_dir!("secret-migration")

    System.put_env("FERMIX_HOME", home)
    FermixTestSupport.SecretWriterStub.reset()
    Application.put_env(:fermix_core, :secret_writer, FermixTestSupport.SecretWriterStub)

    on_exit(fn ->
      case previous_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      restore_secret_writer(previous_writer)
      FermixTestSupport.SecretWriterStub.reset()
      FermixTestSupport.SafeRm.rm_rf!(home)
    end)

    %{home: home}
  end

  test "run migrates plaintext setup secrets to keyring sentinels", %{home: home} do
    write_plaintext_config(home)
    test_pid = self()

    assert :ok =
             SecretMigration.run([],
               puts: fn line -> send(test_pid, {:puts, line}) end,
               prompt: fn label ->
                 send(test_pid, {:prompt, label})
                 "yes"
               end
             )

    contents = File.read!(ConfigStore.path())
    backup = File.read!(ConfigStore.path() <> ".pre-m5")

    assert contents =~ ~s(api_key = "@keyring")
    assert contents =~ ~s(bot_token = "@keyring")
    assert contents =~ ~s(signing_secret = "@keyring")
    assert backup =~ "sk-old"

    Enum.each(secret_values(), fn {_key, value} ->
      refute contents =~ value
    end)

    Enum.each(SecretPaths.all(), fn secret ->
      label = "Migrate #{secret.env} to the OS keyring? [y/N]: "
      assert_received {:prompt, ^label}
      assert {:ok, value} = FermixTestSupport.SecretWriterStub.get(secret.key)
      assert value == Map.fetch!(secret_values(), secret.key)
    end)

    assert_received {:puts, "Migrated 31 secret(s) to keyring."}
  end

  test "run writes a sandbox.env source for migrated AI-provider secrets", %{home: home} do
    write_plaintext_config(home)

    assert :ok =
             SecretMigration.run([],
               puts: fn _ -> :ok end,
               prompt: fn _ -> "yes" end
             )

    contents = File.read!(ConfigStore.path())

    assert contents =~ ~s([sandbox.env.OPENAI_API_KEY])
    assert contents =~ ~s([sandbox.env.ANTHROPIC_API_KEY])
    assert contents =~ ~s(source = "command")
    assert contents =~ ~s(command = "stub-keyring")

    assert contents =~
             ~s(args = ["openai_api_key"])

    assert contents =~ ~r/allow = \[[^\]]*"OPENAI_API_KEY"/
    assert contents =~ ~r/allow = \[[^\]]*"ANTHROPIC_API_KEY"/

    refute contents =~ ~s([sandbox.env.TELEGRAM_BOT_TOKEN])
    refute contents =~ ~s([sandbox.env.SLACK_BOT_TOKEN])
  end

  test "run reports when no plaintext setup secrets exist" do
    :ok = ConfigStore.save_snapshot(%{fermix_core: [], fermix_channels: [], fermix_web: []})
    test_pid = self()

    assert :ok =
             SecretMigration.run([],
               puts: fn line -> send(test_pid, {:puts, line}) end,
               prompt: fn _label -> raise "unexpected prompt" end
             )

    assert_received {:puts, "No plaintext setup secrets found."}
  end

  test "run does not require a secret writer when there is nothing to migrate" do
    Application.put_env(:fermix_core, :secret_writer, FermixTestSupport.UnavailableSecretWriter)
    :ok = ConfigStore.save_snapshot(%{fermix_core: [], fermix_channels: [], fermix_web: []})
    test_pid = self()

    assert :ok =
             SecretMigration.run([],
               puts: fn line -> send(test_pid, {:puts, line}) end,
               prompt: fn _label -> raise "unexpected prompt" end
             )

    assert_received {:puts, "No plaintext setup secrets found."}
  end

  defp write_plaintext_config(home) do
    File.write!(Path.join(home, "config.toml"), """
    [fermix_core.providers.openai]
    api_key = "sk-old"

    [fermix_core.providers.anthropic]
    api_key = "sk-ant-old"

    [fermix_core.providers.xai]
    api_key = "xai-old"

    [fermix_core.providers.openrouter]
    api_key = "openrouter-old"

    [fermix_core.providers.mistral]
    api_key = "mistral-old"

    [fermix_core.tools.web_search]
    tavily_api_key = "tavily-old"
    exa_api_key = "exa-old"
    parallel_api_key = "parallel-old"
    brave_api_key = "brave-old"
    perplexity_api_key = "perplexity-old"
    firecrawl_api_key = "firecrawl-old"

    [fermix_core.tools.generate_image]
    google_api_key = "gemini-old"

    [fermix_core.transcription]
    openai_api_key = "transcription-openai-old"
    xai_api_key = "transcription-xai-old"
    deepgram_api_key = "deepgram-old"

    [fermix_core.oauth.google]
    client_type = "desktop_public_pkce"
    client_id = "123.apps.googleusercontent.com"
    client_secret = "google-oauth-old"

    [fermix_core.oauth.github]
    client_type = "desktop_public_pkce"
    client_id = "github-client-id"
    client_secret = "github-oauth-old"

    [fermix_core.oauth.notion]
    client_type = "desktop_public_pkce"
    client_id = "notion-client-id"
    client_secret = "notion-oauth-old"

    [fermix_core.oauth.x]
    client_type = "desktop_public_pkce"
    client_id = "x-client-id"
    client_secret = "x-oauth-old"

    [fermix_channels.telegram]
    bot_token = "telegram-old"

    [fermix_channels.whatsapp]
    access_token = "whatsapp-access-old"
    verify_token = "whatsapp-verify-old"
    app_secret = "whatsapp-app-old"
    phone_number_id = "phone-123"

    [fermix_channels.discord]
    bot_token = "discord-old"

    [fermix_channels.slack]
    bot_token = "slack-old"
    signing_secret = "slack-signing-old"

    [fermix_core.oauth.slack]
    client_type = "desktop_public_pkce"
    client_id = "slack-client-id"
    client_secret = "slack-oauth-old"

    [fermix_core.plugin_secrets]
    discord = "discord-plugin-old"
    agentmail = "agentmail-plugin-old"
    slack = "slack-plugin-old"
    eden = "eden-plugin-old"
    """)
  end

  defp secret_values do
    %{
      openai_api_key: "sk-old",
      anthropic_api_key: "sk-ant-old",
      xai_api_key: "xai-old",
      openrouter_api_key: "openrouter-old",
      mistral_api_key: "mistral-old",
      tavily_api_key: "tavily-old",
      exa_api_key: "exa-old",
      parallel_api_key: "parallel-old",
      brave_api_key: "brave-old",
      perplexity_api_key: "perplexity-old",
      firecrawl_api_key: "firecrawl-old",
      google_api_key: "gemini-old",
      transcription_openai_api_key: "transcription-openai-old",
      transcription_xai_api_key: "transcription-xai-old",
      deepgram_api_key: "deepgram-old",
      google_oauth_client_secret: "google-oauth-old",
      github_oauth_client_secret: "github-oauth-old",
      notion_oauth_client_secret: "notion-oauth-old",
      x_oauth_client_secret: "x-oauth-old",
      telegram_bot_token: "telegram-old",
      whatsapp_access_token: "whatsapp-access-old",
      whatsapp_verify_token: "whatsapp-verify-old",
      whatsapp_app_secret: "whatsapp-app-old",
      discord_bot_token: "discord-old",
      slack_bot_token: "slack-old",
      slack_signing_secret: "slack-signing-old",
      slack_oauth_client_secret: "slack-oauth-old",
      discord_plugin_secret: "discord-plugin-old",
      agentmail_plugin_secret: "agentmail-plugin-old",
      slack_plugin_secret: "slack-plugin-old",
      eden_plugin_secret: "eden-plugin-old"
    }
  end

  defp restore_secret_writer(nil), do: Application.delete_env(:fermix_core, :secret_writer)
  defp restore_secret_writer(value), do: Application.put_env(:fermix_core, :secret_writer, value)
end
