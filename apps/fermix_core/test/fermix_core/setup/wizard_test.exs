defmodule FermixCore.Setup.WizardTest do
  use ExUnit.Case, async: false

  alias FermixCore.Memory.Repo, as: MemoryRepo
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.Wizard

  setup do
    providers = Application.fetch_env(:fermix_core, :providers)
    telegram = Application.fetch_env(:fermix_channels, :telegram)
    whatsapp = Application.fetch_env(:fermix_channels, :whatsapp)
    discord = Application.fetch_env(:fermix_channels, :discord)
    slack = Application.fetch_env(:fermix_channels, :slack)
    signal = Application.fetch_env(:fermix_channels, :signal)
    personalization = Application.get_env(:fermix_core, :personalization, [])
    agent = Application.get_env(:fermix_core, :agent, [])
    fermix_home = System.get_env("FERMIX_HOME")

    Application.put_env(:fermix_core, :personalization,
      user_name: "Test User",
      timezone: "UTC",
      communication_style: "neutral and direct"
    )

    Application.put_env(:fermix_core, :agent, name: "fermix")

    on_exit(fn ->
      restore_env(:fermix_core, :providers, providers)
      restore_env(:fermix_channels, :telegram, telegram)
      restore_env(:fermix_channels, :whatsapp, whatsapp)
      restore_env(:fermix_channels, :discord, discord)
      restore_env(:fermix_channels, :slack, slack)
      restore_env(:fermix_channels, :signal, signal)
      Application.put_env(:fermix_core, :personalization, personalization)
      Application.put_env(:fermix_core, :agent, agent)

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
    start_memory_repo!()

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

  test "report routes to :personalization step when only personalization is missing" do
    Application.put_env(:fermix_core, :providers,
      openai: [auth_mode: :api_key, api_key: "sk-test-123"]
    )

    Application.put_env(:fermix_channels, :telegram, bot_token: "bot-token")
    Application.put_env(:fermix_core, :personalization, [])

    report = Wizard.report()

    assert report.status == :setup_required
    assert report.wizard.step == :personalization

    prompts = Wizard.prompts(report.wizard)
    assert Enum.any?(prompts, &(&1.key == :user_name and &1.required?))
    assert Enum.any?(prompts, &(&1.key == :timezone and &1.required?))
    assert Enum.any?(prompts, &(&1.key == :communication_style and &1.required?))
  end

  test "save_answers seeds prompt files when readiness becomes :ready" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-wizard-seed-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    Application.put_env(:fermix_core, :providers,
      openai: [auth_mode: :api_key, api_key: "sk-test-123"]
    )

    Application.put_env(:fermix_channels, :telegram, bot_token: "bot-token")
    Application.put_env(:fermix_core, :personalization, [])
    start_memory_repo!()

    {:ok, report} =
      Wizard.report().wizard
      |> Wizard.save_answers(
        user_name: "Sujeeth",
        timezone: "Asia/Singapore",
        communication_style: "blunt"
      )

    assert report.status == :ready

    assert Enum.map(report.seeding_results, & &1.name) == [
             :identity,
             :agents,
             :soul,
             :user,
             :memory
           ]

    assert Enum.all?(report.seeding_results, &(&1.outcome == :seeded))

    bootstrap_dir = Application.get_env(:fermix_core, :prompt_bootstrap)[:bootstrap_dir]
    assert File.exists?(Path.join([bootstrap_dir, "main", "IDENTITY.md"]))
    assert File.exists?(Path.join([bootstrap_dir, "main", "AGENTS.md"]))
    assert File.exists?(Path.join([bootstrap_dir, "main", "SOUL.md"]))
  end

  test "save_answers skips seeding when prerequisites are still missing" do
    Application.put_env(:fermix_core, :providers, [])
    Application.put_env(:fermix_core, :personalization, [])
    start_memory_repo!()

    {:ok, report} =
      Wizard.report().wizard
      |> Wizard.save_answers(
        user_name: "Sujeeth",
        timezone: "Asia/Singapore",
        communication_style: "blunt"
      )

    assert report.status == :setup_required
    assert report.seeding_results == []
  end

  test "seed_now restores files deleted from disk when readiness is :ready" do
    Application.put_env(:fermix_core, :providers,
      openai: [auth_mode: :api_key, api_key: "sk-test-123"]
    )

    Application.put_env(:fermix_channels, :telegram, bot_token: "bot-token")
    start_memory_repo!()

    assert {:ok, first_results} = Wizard.seed_now()
    assert Enum.all?(first_results, &(&1.outcome == :seeded))

    bootstrap_dir = Application.get_env(:fermix_core, :prompt_bootstrap)[:bootstrap_dir]
    soul_path = Path.join([bootstrap_dir, "main", "SOUL.md"])
    File.rm!(soul_path)

    assert {:ok, second_results} = Wizard.seed_now()

    by_name = Map.new(second_results, &{&1.name, &1.outcome})
    assert by_name[:soul] == :seeded
    assert by_name[:identity] == :skipped_exists
    assert by_name[:agents] == :skipped_exists
    assert by_name[:user] == :skipped_exists
    assert by_name[:memory] == :skipped_exists
    assert File.exists?(soul_path)
  end

  test "seed_now is a no-op when readiness is not :ready" do
    Application.put_env(:fermix_core, :providers, [])
    start_memory_repo!()

    assert {:ok, []} = Wizard.seed_now()
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
    start_memory_repo!()

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

  test "prompts surface telegram bot_token when env satisfies readiness but TOML has not persisted it" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-wizard-prompt-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    Application.put_env(:fermix_core, :providers,
      openai: [auth_mode: :api_key, api_key: "sk-test-123"]
    )

    # TOML on disk: telegram enabled but no bot_token persisted (matches the
    # state after a setup run where the env supplied the value).
    :ok =
      ConfigStore.save_snapshot(%{
        fermix_core: [
          providers: [openai: [auth_mode: :api_key, api_key: "sk-test-123"]],
          personalization: [
            user_name: "Test User",
            timezone: "UTC",
            communication_style: "neutral and direct"
          ],
          agent: [name: "fermix"]
        ],
        fermix_channels: [
          telegram: [enabled: true, mode: :webhook, allowed_user_ids: []]
        ]
      })

    # Application env carries the env-derived bot_token (what runtime.exs
    # would have layered on top during boot).
    Application.put_env(:fermix_channels, :telegram,
      enabled: true,
      mode: :webhook,
      bot_token: "env-only-token",
      allowed_user_ids: []
    )

    report = Wizard.report()

    # Readiness sees the merged env value and reports :ready, but the prompt
    # gate must still surface the bot_token because TOML lacks it.
    assert report.status == :ready

    prompts = Wizard.prompts(report.wizard)
    assert Enum.any?(prompts, &(&1.key == :telegram_bot_token and &1.required?))
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
    start_memory_repo!()

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

  defp start_memory_repo! do
    unique = System.unique_integer([:positive, :monotonic])
    db_path = Path.join(System.tmp_dir!(), "fermix-wizard-#{unique}.db")
    bootstrap_dir = Path.join(System.tmp_dir!(), "fermix-wizard-bootstrap-#{unique}")
    memory_dir = Path.join(System.tmp_dir!(), "fermix-wizard-memory-#{unique}")

    previous_bootstrap = Application.get_env(:fermix_core, :prompt_bootstrap, [])
    previous_memory = Application.get_env(:fermix_core, :memory, [])

    Application.put_env(
      :fermix_core,
      :prompt_bootstrap,
      Keyword.put(previous_bootstrap, :bootstrap_dir, bootstrap_dir)
    )

    Application.put_env(
      :fermix_core,
      :memory,
      previous_memory
      |> Keyword.merge(
        prompt_base_dir: memory_dir,
        agent_id: "main",
        enabled: true,
        database_path: db_path
      )
    )

    restart_global_memory_repo!()

    on_exit(fn ->
      Application.put_env(:fermix_core, :prompt_bootstrap, previous_bootstrap)
      Application.put_env(:fermix_core, :memory, previous_memory)
      restart_global_memory_repo!()
      File.rm_rf!(bootstrap_dir)
      File.rm_rf!(memory_dir)

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path -> File.rm(path) end)
    end)
  end

  defp restart_global_memory_repo! do
    case Process.whereis(MemoryRepo) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        :ok = Supervisor.terminate_child(FermixCore.Supervisor, MemoryRepo)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          1_000 -> Process.demonitor(ref, [:flush])
        end
    end

    {:ok, _pid} = Supervisor.restart_child(FermixCore.Supervisor, MemoryRepo)
    :ok
  end
end
