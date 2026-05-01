defmodule FermixCore.Setup.ConfigStoreTest do
  use ExUnit.Case, async: false

  alias FermixCore.Setup.ConfigStore

  setup do
    fermix_home = System.get_env("FERMIX_HOME")
    personalization = Application.get_env(:fermix_core, :personalization, [])
    agent = Application.get_env(:fermix_core, :agent, [])

    on_exit(fn ->
      Application.put_env(:fermix_core, :personalization, personalization)
      Application.put_env(:fermix_core, :agent, agent)

      case fermix_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end
    end)

    :ok
  end

  test "workspace_paths follow FERMIX_HOME and match the persisted runtime layout" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    System.put_env("FERMIX_HOME", tmp_home)

    assert ConfigStore.workspace_paths() == %{
             bootstrap: Path.join(tmp_home, "bootstrap"),
             skills: Path.join(tmp_home, "skills"),
             journals: Path.join(tmp_home, "journals"),
             traces: Path.join(tmp_home, "traces"),
             logs: Path.join(tmp_home, "logs")
           }
  end

  test "save/load round-trip preserves personalization and agent sections" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [
        providers: [openai: [auth_mode: :api_key, api_key: "sk-x"]],
        personalization: [
          user_name: "Sujeeth",
          timezone: "Asia/Singapore",
          communication_style: "blunt"
        ],
        agent: [name: "aira"]
      ],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)

    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ "[fermix_core.personalization]"
    assert contents =~ ~s(user_name = "Sujeeth")
    assert contents =~ "[fermix_core.agent]"
    assert contents =~ ~s(name = "aira")

    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    personalization = Keyword.get(loaded.fermix_core, :personalization, [])
    agent = Keyword.get(loaded.fermix_core, :agent, [])

    assert Keyword.get(personalization, :user_name) == "Sujeeth"
    assert Keyword.get(personalization, :timezone) == "Asia/Singapore"
    assert Keyword.get(personalization, :communication_style) == "blunt"
    assert Keyword.get(agent, :name) == "aira"
  end

  test "apply_snapshot writes personalization and agent into Application env" do
    Application.put_env(:fermix_core, :personalization, [])
    Application.put_env(:fermix_core, :agent, [])

    ConfigStore.apply_snapshot(%{
      fermix_core: [
        personalization: [
          user_name: "Sujeeth",
          timezone: "Asia/Singapore",
          communication_style: "blunt"
        ],
        agent: [name: "aira"]
      ],
      fermix_channels: [],
      fermix_web: []
    })

    personalization = Application.get_env(:fermix_core, :personalization, [])
    agent = Application.get_env(:fermix_core, :agent, [])

    assert Keyword.get(personalization, :user_name) == "Sujeeth"
    assert Keyword.get(personalization, :timezone) == "Asia/Singapore"
    assert Keyword.get(personalization, :communication_style) == "blunt"
    assert Keyword.get(agent, :name) == "aira"
  end

  test "bootstrap_runtime_config hydrates Application env from the persisted TOML" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    Application.put_env(:fermix_core, :personalization, [])
    Application.put_env(:fermix_core, :agent, [])
    Application.put_env(:fermix_channels, :telegram, [])

    :ok =
      ConfigStore.save_snapshot(%{
        fermix_core: [
          providers: [openai: [auth_mode: :api_key, api_key: "sk-x"]],
          personalization: [
            user_name: "Sujeeth",
            timezone: "Asia/Singapore",
            communication_style: "blunt"
          ],
          agent: [name: "aira"]
        ],
        fermix_channels: [telegram: [enabled: true, mode: :webhook, bot_token: "bot-token"]],
        fermix_web: []
      })

    Application.put_env(:fermix_core, :personalization, [])
    Application.put_env(:fermix_core, :agent, [])
    Application.put_env(:fermix_channels, :telegram, [])

    assert :ok = ConfigStore.bootstrap_runtime_config()

    personalization = Application.get_env(:fermix_core, :personalization, [])
    agent = Application.get_env(:fermix_core, :agent, [])
    telegram = Application.get_env(:fermix_channels, :telegram, [])

    assert Keyword.get(personalization, :user_name) == "Sujeeth"
    assert Keyword.get(personalization, :timezone) == "Asia/Singapore"
    assert Keyword.get(personalization, :communication_style) == "blunt"
    assert Keyword.get(agent, :name) == "aira"
    assert Keyword.get(telegram, :bot_token) == "bot-token"
    assert Keyword.get(telegram, :enabled) == true
  end

  test "bootstrap_runtime_config is a no-op when no TOML exists" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    System.put_env("FERMIX_HOME", tmp_home)

    Application.put_env(:fermix_core, :personalization, user_name: "preserved")

    assert :ok = ConfigStore.bootstrap_runtime_config()

    personalization = Application.get_env(:fermix_core, :personalization, [])
    assert Keyword.get(personalization, :user_name) == "preserved"
  end

  test "bootstrap_runtime_config persists provider selection under :agent" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    Application.put_env(:fermix_core, :agent, [])

    :ok =
      ConfigStore.save_snapshot(%{
        fermix_core: [
          providers: [openai: [auth_mode: :oauth]],
          agent: [name: "fermix", provider: :openai_codex]
        ],
        fermix_channels: [],
        fermix_web: []
      })

    Application.put_env(:fermix_core, :agent, [])

    assert :ok = ConfigStore.bootstrap_runtime_config()

    agent = Application.get_env(:fermix_core, :agent, [])
    assert Keyword.get(agent, :provider) == :openai_codex
    assert Keyword.get(agent, :name) == "fermix"

    # And the openai block does NOT carry the provider key.
    openai = Application.get_env(:fermix_core, :providers, []) |> Keyword.get(:openai, [])
    refute Keyword.has_key?(openai, :provider)
  end

  test "save/load round-trips default_model and reasoning_effort across all three provider blocks" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [
        providers: [
          openai: [
            auth_mode: :api_key,
            api_key: "sk-x",
            default_model: "gpt-5.5",
            reasoning_effort: :high
          ],
          openai_codex: [default_model: "gpt-5.5", reasoning_effort: :xhigh],
          anthropic: [auth_mode: :api_key, api_key: "sk-ant", default_model: "claude-opus-4-7"]
        ],
        agent: [name: "fermix", provider: :openai_codex]
      ],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)

    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ "[fermix_core.providers.openai]"
    assert contents =~ ~s(default_model = "gpt-5.5")
    assert contents =~ ~s(reasoning_effort = "high")
    assert contents =~ "[fermix_core.providers.openai_codex]"
    assert contents =~ ~s(reasoning_effort = "xhigh")
    assert contents =~ "[fermix_core.providers.anthropic]"
    assert contents =~ ~s(default_model = "claude-opus-4-7")

    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    providers = Keyword.get(loaded.fermix_core, :providers, [])

    openai = Keyword.get(providers, :openai, [])
    assert Keyword.get(openai, :default_model) == "gpt-5.5"
    assert Keyword.get(openai, :reasoning_effort) == :high

    openai_codex = Keyword.get(providers, :openai_codex, [])
    assert Keyword.get(openai_codex, :default_model) == "gpt-5.5"
    assert Keyword.get(openai_codex, :reasoning_effort) == :xhigh

    anthropic = Keyword.get(providers, :anthropic, [])
    assert Keyword.get(anthropic, :default_model) == "claude-opus-4-7"
    assert Keyword.get(anthropic, :api_key) == "sk-ant"
  end

  test "save_snapshot preserves dormant provider blocks when only one provider is updated" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    # Initial: all three providers configured.
    initial = %{
      fermix_core: [
        providers: [
          openai: [auth_mode: :api_key, api_key: "sk-x", default_model: "gpt-5.5"],
          openai_codex: [default_model: "gpt-5.5", reasoning_effort: :high],
          anthropic: [auth_mode: :api_key, api_key: "sk-ant", default_model: "claude-opus-4-7"]
        ],
        agent: [name: "fermix", provider: :openai]
      ],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(initial)

    # User switches to anthropic. The save must keep openai + openai_codex blocks intact.
    {:ok, current} = ConfigStore.load_runtime_config()
    providers = Keyword.get(current.fermix_core, :providers, [])

    updated_anthropic =
      Keyword.put(Keyword.get(providers, :anthropic, []), :default_model, "claude-haiku-4-5")

    next_providers = Keyword.put(providers, :anthropic, updated_anthropic)

    next = %{
      fermix_core:
        Keyword.merge(
          current.fermix_core,
          providers: next_providers,
          agent: [name: "fermix", provider: :anthropic]
        ),
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(next)

    {:ok, reloaded} = ConfigStore.load_runtime_config()
    providers = Keyword.get(reloaded.fermix_core, :providers, [])

    # Anthropic was updated.
    assert Keyword.get(providers, :anthropic, [])[:default_model] == "claude-haiku-4-5"

    # Openai and openai_codex still intact.
    assert Keyword.get(providers, :openai, [])[:default_model] == "gpt-5.5"
    assert Keyword.get(providers, :openai, [])[:api_key] == "sk-x"
    assert Keyword.get(providers, :openai_codex, [])[:reasoning_effort] == :high
  end

  test "normalize_openai silently drops invalid reasoning_effort from hand-edited TOML" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.providers.openai]
    auth_mode = "api_key"
    api_key = "sk-x"
    reasoning_effort = "absurd"
    """)

    assert {:ok, loaded} = ConfigStore.load_runtime_config()

    openai =
      loaded.fermix_core
      |> Keyword.get(:providers, [])
      |> Keyword.get(:openai, [])

    refute Keyword.has_key?(openai, :reasoning_effort)
    assert Keyword.get(openai, :api_key) == "sk-x"
  end

  test "apply_snapshot puts all three provider blocks into Application env" do
    Application.put_env(:fermix_core, :providers, [])

    on_exit(fn -> Application.put_env(:fermix_core, :providers, []) end)

    ConfigStore.apply_snapshot(%{
      fermix_core: [
        providers: [
          openai: [auth_mode: :api_key, api_key: "sk-x", default_model: "gpt-5.5"],
          openai_codex: [default_model: "gpt-5.5", reasoning_effort: :high],
          anthropic: [auth_mode: :api_key, api_key: "sk-ant"]
        ]
      ],
      fermix_channels: [],
      fermix_web: []
    })

    providers = Application.get_env(:fermix_core, :providers, [])
    assert Keyword.get(providers, :openai, [])[:default_model] == "gpt-5.5"
    assert Keyword.get(providers, :openai_codex, [])[:reasoning_effort] == :high
    assert Keyword.get(providers, :anthropic, [])[:api_key] == "sk-ant"
  end

  test "bootstrap_runtime_config raises on legacy c4f02a4 layout (provider under [providers.openai])" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    # Hand-write a TOML in the old c4f02a4 shape so we can prove the loader refuses it.
    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.providers.openai]
    auth_mode = "oauth"
    provider = "openai_codex"
    """)

    err =
      assert_raise RuntimeError, fn ->
        ConfigStore.bootstrap_runtime_config()
      end

    assert err.message =~ "[fermix_core.providers.openai]"
    assert err.message =~ "[fermix_core.agent]"
  end
end
