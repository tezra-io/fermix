defmodule FermixCore.Setup.WizardTest do
  use ExUnit.Case, async: false

  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.Wizard

  setup do
    providers = Application.get_env(:fermix_core, :providers)
    telegram = Application.get_env(:fermix_channels, :telegram)
    fermix_home = System.get_env("FERMIX_HOME")

    on_exit(fn ->
      restore_env(:fermix_core, :providers, providers)
      restore_env(:fermix_channels, :telegram, telegram)

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

  test "save_answers persists config, creates workspace directories, and updates readiness" do
    tmp_home = Path.join(System.tmp_dir!(), "fermix-setup-#{System.unique_integer([:positive])}")

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

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
