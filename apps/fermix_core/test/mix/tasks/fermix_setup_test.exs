defmodule Mix.Tasks.Fermix.SetupTest do
  use ExUnit.Case, async: false

  alias FermixCore.Memory.Repo, as: MemoryRepo
  alias FermixCore.Prompt.BootstrapPaths
  alias FermixCore.Setup.ConfigStore
  alias Mix.Tasks.Fermix.Setup, as: SetupTask

  setup do
    providers = Application.fetch_env(:fermix_core, :providers)
    telegram = Application.fetch_env(:fermix_channels, :telegram)
    # `--acp-enabled` applies the saved snapshot to the live app env, so this
    # module mutates `:acp` globally and must hand it back.
    acp = Application.fetch_env(:fermix_channels, :acp)
    personalization = Application.get_env(:fermix_core, :personalization, [])
    agent = Application.get_env(:fermix_core, :agent, [])
    fermix_home = System.get_env("FERMIX_HOME")
    shell = Mix.shell()

    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      restore_env(:fermix_core, :providers, providers)
      restore_env(:fermix_channels, :telegram, telegram)
      restore_env(:fermix_channels, :acp, acp)
      Application.put_env(:fermix_core, :personalization, personalization)
      Application.put_env(:fermix_core, :agent, agent)

      case fermix_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      Mix.shell(shell)
    end)

    :ok
  end

  test "--print-state reports ready from persisted setup" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-setup-task-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)

    System.put_env("FERMIX_HOME", tmp_home)

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
          telegram: [
            enabled: true,
            mode: :webhook,
            bot_token: "bot-token",
            owner_user_id: "test-owner"
          ]
        ],
        fermix_web: []
      })

    Application.put_env(:fermix_core, :providers, [])
    Application.delete_env(:fermix_channels, :telegram)

    Mix.Task.reenable("fermix.setup")
    SetupTask.run(["--print-state"])

    assert_received {:mix_shell, :info, ["status: ready"]}
    assert_received {:mix_shell, :info, ["All required setup checks are satisfied."]}
  end

  test "no-arg run on ready config seeds missing prompt files" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-setup-task-#{System.unique_integer([:positive])}")

    bootstrap_dir = Path.join(tmp_home, "bootstrap")
    memory_dir = Path.join(tmp_home, "memory")
    db_path = Path.join(tmp_home, "memory.db")

    previous_bootstrap = Application.get_env(:fermix_core, :prompt_bootstrap, [])
    previous_memory = Application.get_env(:fermix_core, :memory, [])

    on_exit(fn ->
      Application.put_env(:fermix_core, :prompt_bootstrap, previous_bootstrap)
      Application.put_env(:fermix_core, :memory, previous_memory)
      restart_global_memory_repo!()
      FermixTestSupport.SafeRm.rm_rf!(tmp_home)
    end)

    System.put_env("FERMIX_HOME", tmp_home)

    Application.put_env(:fermix_core, :prompt_bootstrap, bootstrap_dir: bootstrap_dir)

    Application.put_env(
      :fermix_core,
      :memory,
      Keyword.merge(previous_memory,
        prompt_base_dir: memory_dir,
        agent_id: "main",
        enabled: true,
        database_path: db_path
      )
    )

    restart_global_memory_repo!()

    Application.put_env(:fermix_core, :providers,
      openai: [
        auth_mode: :api_key,
        api_key: "sk-test-123",
        default_model: "gpt-5.5",
        reasoning_effort: :high
      ]
    )

    Application.put_env(:fermix_channels, :telegram, bot_token: "bot-token")

    Application.put_env(:fermix_core, :personalization,
      user_name: "Test",
      timezone: "UTC",
      communication_style: "neutral and direct"
    )

    Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai)

    :ok =
      ConfigStore.save_snapshot(%{
        fermix_core: [
          providers: [
            openai: [
              auth_mode: :api_key,
              api_key: "sk-test-123",
              default_model: "gpt-5.5",
              reasoning_effort: :high
            ]
          ],
          personalization: [
            user_name: "Test",
            timezone: "UTC",
            communication_style: "neutral and direct"
          ],
          agent: [name: "fermix", provider: :openai]
        ],
        fermix_channels: [
          telegram: [
            enabled: true,
            mode: :webhook,
            bot_token: "bot-token",
            owner_user_id: "test-owner"
          ]
        ],
        fermix_web: []
      })

    # Deliberately no `[fermix_channels.mobile]` section: the mobile channel is
    # feature-flagged with no setup surface, so an absent section is
    # disabled-AND-setup-complete. A no-arg run must seed and report ready
    # rather than block on a pending mobile question.
    refute File.read!(ConfigStore.path()) =~ "[fermix_channels.mobile]"

    refute File.exists?(BootstrapPaths.identity_path("main"))

    Mix.Task.reenable("fermix.setup")
    SetupTask.run([])

    assert_received {:mix_shell, :info, ["status: ready"]}
    assert_received {:mix_shell, :info, ["Prompt files:"]}
    assert File.exists?(BootstrapPaths.identity_path("main"))
    assert File.exists?(BootstrapPaths.fermix_path("main"))
    assert File.exists?(BootstrapPaths.soul_path("main"))
  end

  test "accepts provider model and reasoning flags through the Mix wrapper" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-setup-task-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    Application.put_env(:fermix_core, :providers,
      openai: [api_key: "sk-test-123", default_model: "gpt-5.5", reasoning_effort: :high]
    )

    Application.put_env(:fermix_channels, :telegram, enabled: true, mode: :webhook)

    Application.put_env(:fermix_core, :personalization,
      user_name: "Test",
      timezone: "UTC",
      communication_style: "neutral and direct"
    )

    Application.put_env(:fermix_core, :agent, name: "fermix", provider: :openai)

    Mix.Task.reenable("fermix.setup")

    SetupTask.run([
      "--provider",
      "openai_codex",
      "--default-model",
      "gpt-5.5",
      "--reasoning-effort",
      "high",
      "--telegram-bot-token",
      "bot-token",
      "--telegram-owner-user-id",
      "test-owner",
      "--no-realtime-enabled",
      "--skip-probe"
    ])

    assert {:ok, persisted} = ConfigStore.load_runtime_config()
    agent = Keyword.get(persisted.fermix_core, :agent, [])
    providers = Keyword.get(persisted.fermix_core, :providers, [])
    codex = Keyword.get(providers, :openai_codex, [])

    refute Keyword.has_key?(agent, :provider)
    assert Keyword.get(codex, :primary) == true
    assert Keyword.get(codex, :default_model) == "gpt-5.5"
    assert Keyword.get(codex, :reasoning_effort) == :high
    assert Keyword.get(codex, :fast) == false
  end

  # The `--acp-enabled` switch is declared twice (this Mix wrapper and
  # `Fermix.CLI.Setup`); OptionParser is strict, so a one-sided addition makes
  # the other entrypoint reject the flag. Both copies are covered by a test.
  test "accepts --acp-enabled through the Mix wrapper and rejects an unregistered flag" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-setup-task-#{System.unique_integer([:positive])}")

    previous_bootstrap = Application.get_env(:fermix_core, :prompt_bootstrap, [])
    previous_memory = Application.get_env(:fermix_core, :memory, [])

    on_exit(fn ->
      Application.put_env(:fermix_core, :prompt_bootstrap, previous_bootstrap)
      Application.put_env(:fermix_core, :memory, previous_memory)
      restart_global_memory_repo!()
      FermixTestSupport.SafeRm.rm_rf!(tmp_home)
    end)

    System.put_env("FERMIX_HOME", tmp_home)

    # A ready config seeds prompt files on save, which needs the memory repo
    # pointed at this tmp home — same wiring as the seeding test above.
    Application.put_env(:fermix_core, :prompt_bootstrap,
      bootstrap_dir: Path.join(tmp_home, "bootstrap")
    )

    Application.put_env(
      :fermix_core,
      :memory,
      Keyword.merge(previous_memory,
        prompt_base_dir: Path.join(tmp_home, "memory"),
        agent_id: "main",
        enabled: true,
        database_path: Path.join(tmp_home, "memory.db")
      )
    )

    restart_global_memory_repo!()

    :ok =
      ConfigStore.save_snapshot(%{
        fermix_core: [
          providers: [
            openai: [
              auth_mode: :api_key,
              api_key: "sk-test-123",
              primary: true,
              default_model: "gpt-5.5",
              reasoning_effort: :high
            ]
          ],
          personalization: [
            user_name: "Test User",
            timezone: "UTC",
            communication_style: "neutral and direct"
          ],
          agent: [name: "fermix"],
          realtime: [enabled: false]
        ],
        fermix_channels: [
          telegram: [
            enabled: true,
            mode: :webhook,
            bot_token: "bot-token",
            owner_user_id: "test-owner"
          ]
        ],
        fermix_web: []
      })

    Mix.Task.reenable("fermix.setup")

    SetupTask.run([
      "--acp-enabled",
      "--no-realtime-enabled",
      "--skip-probe"
    ])

    assert {:ok, persisted} = ConfigStore.load_runtime_config()
    assert Keyword.fetch!(persisted.fermix_channels, :acp) == [enabled: true]

    Mix.Task.reenable("fermix.setup")

    assert_raise Mix.Error, ~r/invalid options/, fn ->
      SetupTask.run(["--acp-enable"])
    end

    # The mobile channel is feature-flagged with no setup surface, so the Mix
    # wrapper must refuse its withdrawn switches exactly like any other
    # unregistered flag — including the boolean negation OptionParser used to
    # derive for free.
    Enum.each(
      [["--mobile-enabled"], ["--no-mobile-enabled"], ["--mobile-port", "4555"]],
      fn args ->
        Mix.Task.reenable("fermix.setup")

        assert_raise Mix.Error, ~r/invalid options/, fn ->
          SetupTask.run(args)
        end
      end
    )
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

  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
end
