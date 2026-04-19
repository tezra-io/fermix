defmodule FermixCore.Setup.WizardTest do
  use ExUnit.Case, async: false

  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.Wizard

  setup do
    providers = Application.fetch_env(:fermix_core, :providers)
    telegram = Application.fetch_env(:fermix_channels, :telegram)
    whatsapp = Application.fetch_env(:fermix_channels, :whatsapp)
    discord = Application.fetch_env(:fermix_channels, :discord)
    slack = Application.fetch_env(:fermix_channels, :slack)
    signal = Application.fetch_env(:fermix_channels, :signal)
    fermix_home = System.get_env("FERMIX_HOME")

    on_exit(fn ->
      restore_env(:fermix_core, :providers, providers)
      restore_env(:fermix_channels, :telegram, telegram)
      restore_env(:fermix_channels, :whatsapp, whatsapp)
      restore_env(:fermix_channels, :discord, discord)
      restore_env(:fermix_channels, :slack, slack)
      restore_env(:fermix_channels, :signal, signal)

      case fermix_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end
    end)

    :ok
  end

  test "report returns deterministic wizard state for incomplete config" do
    Application.put_env(:fermix_core, :providers, [])
    Application.delete_env(:fermix_channels, :telegram)

    report = Wizard.report()

    assert report.status == :setup_required
    assert report.wizard.step == :provider
    assert report.wizard.config_snapshot == ConfigStore.current_snapshot()

    assert Enum.any?(report.wizard.validation_errors, fn failure ->
             failure.component == "provider:openai"
           end)
  end

  test "report treats telegram channel as enabled when enabled flag is unset" do
    Application.put_env(:fermix_core, :providers,
      openai: [auth_mode: :api_key, api_key: "sk-test-123"]
    )

    Application.put_env(:fermix_channels, :telegram, bot_token: "bot-token")

    report = Wizard.report()

    assert report.status == :ready
    assert report.wizard.enabled_channels == [:telegram]
  end

  test "report treats disabled telegram channel as optional and hidden" do
    Application.put_env(:fermix_core, :providers,
      openai: [auth_mode: :api_key, api_key: "sk-test-123"]
    )

    Application.put_env(:fermix_channels, :telegram, enabled: false)

    report = Wizard.report()

    assert report.status == :ready
    assert report.wizard.enabled_channels == []

    refute Enum.any?(report.failures, fn failure ->
             failure.component == "channel:telegram"
           end)
  end

  test "report surfaces enabled whatsapp, discord, slack, and signal channel failures" do
    Application.put_env(:fermix_core, :providers,
      openai: [auth_mode: :api_key, api_key: "sk-test-123"]
    )

    Application.put_env(:fermix_channels, :telegram, enabled: false)
    Application.put_env(:fermix_channels, :whatsapp, enabled: true, mode: :webhook)
    Application.put_env(:fermix_channels, :discord, enabled: true, mode: :gateway)
    Application.put_env(:fermix_channels, :slack, enabled: true, mode: :webhook)
    Application.put_env(:fermix_channels, :signal, enabled: true, mode: :subprocess)

    report = Wizard.report()

    assert report.status == :setup_required
    assert :whatsapp in report.wizard.enabled_channels
    assert :discord in report.wizard.enabled_channels
    assert :slack in report.wizard.enabled_channels
    assert :signal in report.wizard.enabled_channels

    assert Enum.any?(report.failures, &(&1.component == "channel:whatsapp"))
    assert Enum.any?(report.failures, &(&1.component == "channel:discord"))
    assert Enum.any?(report.failures, &(&1.component == "channel:slack"))
    assert Enum.any?(report.failures, &(&1.component == "channel:signal"))
  end

  test "save_answers persists config, creates workspace directories, and updates readiness" do
    tmp_home = Path.join(System.tmp_dir!(), "fermix-setup-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(tmp_home) end)

    System.put_env("FERMIX_HOME", tmp_home)
    Application.put_env(:fermix_core, :providers, [])
    Application.delete_env(:fermix_channels, :telegram)

    {:ok, report} =
      Wizard.report().wizard
      |> Wizard.save_answers(openai_api_key: "sk-test-123", telegram_bot_token: "bot-token")

    assert report.status == :ready
    assert File.read!(Path.join(tmp_home, "config.toml")) =~ "[fermix_core.providers.openai]"

    assert Enum.all?(["skills", "journals", "traces", "logs"], fn dir ->
             File.dir?(Path.join(tmp_home, dir))
           end)

    assert {:ok, persisted} = ConfigStore.load_runtime_config()

    openai = persisted.fermix_core |> Keyword.get(:providers, []) |> Keyword.get(:openai, [])
    telegram = Keyword.get(persisted.fermix_channels, :telegram, [])

    assert Keyword.get(openai, :auth_mode) == :api_key
    assert Keyword.get(openai, :api_key) == "sk-test-123"
    assert Keyword.get(telegram, :enabled) == true
    assert Keyword.get(telegram, :mode) == :webhook
    assert Keyword.get(telegram, :bot_token) == "bot-token"
    assert Keyword.get(telegram, :allowed_user_ids) == []
  end

  test "save_answers persists whatsapp and discord setup answers" do
    tmp_home = Path.join(System.tmp_dir!(), "fermix-setup-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(tmp_home) end)

    System.put_env("FERMIX_HOME", tmp_home)

    Application.put_env(:fermix_core, :providers,
      openai: [auth_mode: :api_key, api_key: "sk-test-123"]
    )

    Application.put_env(:fermix_channels, :telegram, enabled: false)
    Application.put_env(:fermix_channels, :whatsapp, enabled: true)
    Application.put_env(:fermix_channels, :discord, enabled: true)

    {:ok, report} =
      Wizard.report().wizard
      |> Wizard.save_answers(
        whatsapp_access_token: "wa-token",
        whatsapp_phone_number_id: "123456789",
        whatsapp_verify_token: "verify-token",
        whatsapp_app_secret: "app-secret",
        discord_bot_token: "discord-token",
        discord_bot_user_id: "999"
      )

    assert report.status == :ready
    assert {:ok, persisted} = ConfigStore.load_runtime_config()

    whatsapp = Keyword.get(persisted.fermix_channels, :whatsapp, [])
    discord = Keyword.get(persisted.fermix_channels, :discord, [])

    assert Keyword.get(whatsapp, :enabled) == true
    assert Keyword.get(whatsapp, :mode) == :webhook
    assert Keyword.get(whatsapp, :access_token) == "wa-token"
    assert Keyword.get(whatsapp, :phone_number_id) == "123456789"
    assert Keyword.get(whatsapp, :verify_token) == "verify-token"
    assert Keyword.get(whatsapp, :app_secret) == "app-secret"

    assert Keyword.get(discord, :enabled) == true
    assert Keyword.get(discord, :mode) == :gateway
    assert Keyword.get(discord, :bot_token) == "discord-token"
    assert Keyword.get(discord, :bot_user_id) == "999"
  end

  test "save_answers persists slack and signal setup answers" do
    tmp_home = Path.join(System.tmp_dir!(), "fermix-setup-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(tmp_home) end)

    System.put_env("FERMIX_HOME", tmp_home)

    Application.put_env(:fermix_core, :providers,
      openai: [auth_mode: :api_key, api_key: "sk-test-123"]
    )

    Application.put_env(:fermix_channels, :telegram, enabled: false)
    Application.put_env(:fermix_channels, :slack, enabled: true)
    Application.put_env(:fermix_channels, :signal, enabled: true)

    {:ok, report} =
      Wizard.report().wizard
      |> Wizard.save_answers(
        slack_bot_token: "xoxb-test-token",
        slack_signing_secret: "slack-signing-secret",
        signal_account: "+15550001111"
      )

    assert report.status == :ready
    assert {:ok, persisted} = ConfigStore.load_runtime_config()

    slack = Keyword.get(persisted.fermix_channels, :slack, [])
    signal = Keyword.get(persisted.fermix_channels, :signal, [])

    assert Keyword.get(slack, :enabled) == true
    assert Keyword.get(slack, :mode) == :webhook
    assert Keyword.get(slack, :bot_token) == "xoxb-test-token"
    assert Keyword.get(slack, :signing_secret) == "slack-signing-secret"

    assert Keyword.get(signal, :enabled) == true
    assert Keyword.get(signal, :mode) == :subprocess
    assert Keyword.get(signal, :account) == "+15550001111"
  end

  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
end
