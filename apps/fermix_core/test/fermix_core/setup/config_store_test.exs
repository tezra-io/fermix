defmodule FermixCore.Setup.ConfigStoreTest do
  use ExUnit.Case, async: false

  alias FermixCore.MCP.Inbound.Config, as: InboundConfig
  alias FermixCore.Setup.ConfigStore

  setup do
    fermix_home = System.get_env("FERMIX_HOME")
    personalization = Application.get_env(:fermix_core, :personalization, [])
    agent = Application.get_env(:fermix_core, :agent, [])
    jobs = Application.get_env(:fermix_core, :jobs, [])
    compaction = Application.get_env(:fermix_core, :compaction, [])
    memory = Application.get_env(:fermix_core, :memory, [])
    realtime = Application.get_env(:fermix_core, :realtime, [])
    tools = Application.get_env(:fermix_core, :tools, [])
    plugins = Application.get_env(:fermix_core, :plugins, [])
    oauth = Application.get_env(:fermix_core, :oauth, %{})
    sandbox = Application.get_env(:fermix_core, :sandbox)
    mcp_servers = Application.get_env(:fermix_core, :mcp_servers, [])
    mcp_inbound = Application.get_env(:fermix_core, :mcp_inbound, InboundConfig.default())
    secret_writer = Application.get_env(:fermix_core, :secret_writer)

    FermixTestSupport.SecretWriterStub.reset()
    Application.put_env(:fermix_core, :secret_writer, FermixTestSupport.SecretWriterStub)

    on_exit(fn ->
      Application.put_env(:fermix_core, :personalization, personalization)
      Application.put_env(:fermix_core, :agent, agent)
      Application.put_env(:fermix_core, :jobs, jobs)
      Application.put_env(:fermix_core, :compaction, compaction)
      Application.put_env(:fermix_core, :memory, memory)
      Application.put_env(:fermix_core, :realtime, realtime)
      Application.put_env(:fermix_core, :tools, tools)
      Application.put_env(:fermix_core, :plugins, plugins)
      Application.put_env(:fermix_core, :oauth, oauth)
      restore_sandbox(sandbox)
      Application.put_env(:fermix_core, :mcp_servers, mcp_servers)
      Application.put_env(:fermix_core, :mcp_inbound, mcp_inbound)
      restore_secret_writer(secret_writer)
      FermixTestSupport.SecretWriterStub.reset()

      case fermix_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end
    end)

    :ok
  end

  defp restore_sandbox(nil), do: Application.delete_env(:fermix_core, :sandbox)
  defp restore_sandbox(value), do: Application.put_env(:fermix_core, :sandbox, value)
  defp restore_secret_writer(nil), do: Application.delete_env(:fermix_core, :secret_writer)
  defp restore_secret_writer(value), do: Application.put_env(:fermix_core, :secret_writer, value)

  test "current_snapshot carries all four provider blocks" do
    original = Application.get_env(:fermix_core, :providers, [])

    try do
      Application.put_env(:fermix_core, :providers, xai: [api_key: "xai-key"])

      providers = ConfigStore.current_snapshot().fermix_core[:providers]

      assert Keyword.has_key?(providers, :openai)
      assert Keyword.has_key?(providers, :openai_codex)
      assert Keyword.has_key?(providers, :anthropic)
      assert providers[:xai] == [api_key: "xai-key"]
    after
      Application.put_env(:fermix_core, :providers, original)
    end
  end

  test "workspace_paths follow FERMIX_HOME and match the persisted runtime layout" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    System.put_env("FERMIX_HOME", tmp_home)

    assert ConfigStore.workspace_paths() == %{
             workspace: Path.join(tmp_home, "workspace"),
             grants: Path.join(tmp_home, "grants"),
             bootstrap: Path.join(tmp_home, "bootstrap"),
             skills: Path.join(tmp_home, "skills"),
             plugins: Path.join(tmp_home, "plugins"),
             browser: Path.join(tmp_home, "browser"),
             journals: Path.join(tmp_home, "journals"),
             realtime: Path.join(tmp_home, "realtime"),
             traces: Path.join(tmp_home, "traces"),
             logs: Path.join(tmp_home, "logs")
           }
  end

  test "an empty FERMIX_HOME is treated as unset, not a cwd-relative path" do
    # An empty string is truthy in Elixir, so `get_env() || default` did NOT
    # fall back — fermix_home/0 returned "" and workspace paths became
    # cwd-relative (e.g. "skills"), so booting from the repo root seeded the
    # bundled skills into ./skills instead of ~/.fermix/skills.
    System.put_env("FERMIX_HOME", "")

    default_home = Path.join(System.user_home!(), ".fermix")

    assert ConfigStore.fermix_home() == default_home
    refute ConfigStore.fermix_home() == ""

    skills = ConfigStore.workspace_paths().skills
    assert skills == Path.join(default_home, "skills")
    assert Path.type(skills) == :absolute
  end

  test "memory_paths follow FERMIX_HOME and match the runtime memory layout" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    System.put_env("FERMIX_HOME", tmp_home)

    assert ConfigStore.memory_paths() == %{
             database_path: Path.join(tmp_home, "memory.db"),
             prompt_base_dir: Path.join(tmp_home, "memory")
           }
  end

  test "save/load round-trip preserves personalization and agent sections" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
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

  test "save/load round-trips provider primary flags" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [
        providers: [
          openai: [primary: false, api_key: "sk-x"],
          anthropic: [primary: true, auth_mode: :oauth]
        ]
      ],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)

    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ "[fermix_core.providers.anthropic]"
    assert contents =~ "primary = true"
    assert contents =~ "primary = false"

    assert {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false)
    providers = Keyword.get(loaded.fermix_core, :providers, [])

    assert Keyword.get(providers[:anthropic], :primary) == true
    assert Keyword.get(providers[:openai], :primary) == false
  end

  test "missing primary stays absent and a non-boolean primary is dropped" do
    snapshot = %{
      fermix_core: [
        providers: [
          openai: [api_key: "sk-x"],
          xai: [api_key: "xai-key", primary: "yes"]
        ]
      ],
      fermix_channels: [],
      fermix_web: []
    }

    providers = ConfigStore.persistable_snapshot(snapshot).fermix_core[:providers]

    refute Keyword.has_key?(providers[:openai], :primary)
    refute Keyword.has_key?(providers[:xai], :primary)
  end

  test "save/load round-trip preserves web search backend config" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [
        tools: [
          web_search: [
            backend: :tavily,
            tavily_api_key: "@keyring",
            exa_api_key: "@keyring",
            parallel_api_key: "@keyring",
            brave_api_key: "@keyring",
            perplexity_api_key: "@keyring"
          ]
        ]
      ],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)

    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ "[fermix_core.tools.web_search]"
    assert contents =~ ~s(backend = "tavily")

    assert {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false)

    web_search =
      loaded.fermix_core
      |> Keyword.get(:tools, [])
      |> Keyword.get(:web_search, [])

    assert Keyword.get(web_search, :backend) == :tavily
    assert Keyword.get(web_search, :tavily_api_key) == "@keyring"
    assert Keyword.get(web_search, :exa_api_key) == "@keyring"
    assert Keyword.get(web_search, :parallel_api_key) == "@keyring"
    assert Keyword.get(web_search, :brave_api_key) == "@keyring"
    assert Keyword.get(web_search, :perplexity_api_key) == "@keyring"
  end

  test "save/load round-trips plugin and oauth provider config" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [
        plugins: [
          enabled: ["google_calendar"],
          entries: %{
            "google_calendar" => [
              auth_profile: "google_calendar:primary"
            ],
            "removed_plugin" => [
              enabled: false,
              unsupported: true
            ]
          }
        ],
        oauth: %{
          "google" => [
            client_type: "desktop_public_pkce",
            client_id: "123.apps.googleusercontent.com",
            client_secret: "desktop-secret",
            redirect_host: "127.0.0.1",
            redirect_port: 1455
          ]
        }
      ],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)

    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ "[fermix_core.plugins]"
    assert contents =~ ~s(enabled = ["google_calendar"])
    assert contents =~ "[fermix_core.plugins.google_calendar]"
    assert contents =~ ~s(auth_profile = "google_calendar:primary")
    assert contents =~ "[fermix_core.plugins.removed_plugin]"
    assert contents =~ "unsupported = true"
    assert contents =~ "[fermix_core.oauth.google]"
    assert contents =~ ~s(client_secret = "@keyring")
    refute contents =~ "desktop-secret"

    assert {:ok, "desktop-secret"} =
             FermixTestSupport.SecretWriterStub.get(:google_oauth_client_secret)

    assert {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false)
    plugins = Keyword.get(loaded.fermix_core, :plugins, [])
    oauth = Keyword.get(loaded.fermix_core, :oauth, [])

    assert Keyword.get(plugins, :enabled) == ["google_calendar"]
    entries = Keyword.get(plugins, :entries, %{})
    assert Keyword.get(entries["google_calendar"], :auth_profile) == "google_calendar:primary"
    assert Keyword.get(entries["removed_plugin"], :unsupported) == true

    google = Map.get(oauth, "google", [])
    assert Keyword.get(google, :client_type) == "desktop_public_pkce"
    assert Keyword.get(google, :client_id) == "123.apps.googleusercontent.com"
    assert Keyword.get(google, :client_secret) == "@keyring"
    assert Keyword.get(google, :redirect_port) == 1455

    assert {:ok, resolved} = ConfigStore.load_runtime_config()
    resolved_oauth = Keyword.get(resolved.fermix_core, :oauth, %{})
    resolved_google = Map.get(resolved_oauth, "google", [])
    assert Keyword.get(resolved_google, :client_secret) == "desktop-secret"
  end

  test "load_runtime_config resolves @keyring sentinels through SecretWriter" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    :ok = FermixTestSupport.SecretWriterStub.put(:openai_api_key, "sk-from-keyring")

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.providers.openai]
    api_key = "@keyring"
    """)

    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    openai = loaded.fermix_core |> Keyword.get(:providers, []) |> Keyword.get(:openai, [])
    assert Keyword.get(openai, :api_key) == "sk-from-keyring"
  end

  test "save_snapshot preserves @keyring sentinels on disk" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [providers: [openai: [api_key: "@keyring"]], agent: [name: "fermix"]],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)
    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ ~s(api_key = "@keyring")
  end

  test "save_snapshot preserves existing @keyring sentinels after runtime resolution" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    :ok = FermixTestSupport.SecretWriterStub.put(:openai_api_key, "sk-from-keyring")

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.providers.openai]
    api_key = "@keyring"
    """)

    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    openai = loaded.fermix_core |> Keyword.get(:providers, []) |> Keyword.get(:openai, [])
    assert Keyword.get(openai, :api_key) == "sk-from-keyring"

    assert :ok = ConfigStore.save_snapshot(loaded)
    contents = File.read!(Path.join(tmp_home, "config.toml"))

    assert contents =~ ~s(api_key = "@keyring")
    refute contents =~ "sk-from-keyring"
  end

  test "save/load round-trips compaction config with float threshold" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [
        providers: [openai: []],
        agent: [name: "fermix"],
        compaction: [enabled: true, threshold: 0.85]
      ],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)

    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ "[fermix_core.compaction]"
    assert contents =~ "enabled = true"
    assert contents =~ "threshold = 0.85"

    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    compaction = Keyword.get(loaded.fermix_core, :compaction, [])

    assert Keyword.get(compaction, :enabled) == true
    assert Keyword.get(compaction, :threshold) == 0.85
  end

  test "save/load round-trips memory.extraction_timeout_ms" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [
        providers: [openai: []],
        agent: [name: "fermix"],
        memory: [extraction_timeout_ms: 90_000]
      ],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)

    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ "[fermix_core.memory]"
    assert contents =~ "extraction_timeout_ms = 90000"

    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    memory = Keyword.get(loaded.fermix_core, :memory, [])
    assert Keyword.get(memory, :extraction_timeout_ms) == 90_000
  end

  test "save/load round-trips realtime config" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [
        providers: [openai: []],
        agent: [name: "fermix"],
        realtime: [
          enabled: true,
          provider: "openai",
          model: "gpt-realtime-2",
          voice: "marin",
          max_session_minutes: 10,
          max_estimated_cost_cents_per_session: 25,
          persist_transcripts: true
        ]
      ],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)

    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ "[fermix_core.realtime]"
    assert contents =~ "enabled = true"
    assert contents =~ ~s(model = "gpt-realtime-2")
    refute contents =~ "activation"
    refute contents =~ "turn_detection"
    refute contents =~ "tool_policy"
    refute contents =~ "allow_network_tools"
    assert contents =~ "persist_transcripts = true"

    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    realtime = Keyword.get(loaded.fermix_core, :realtime, [])

    assert Keyword.get(realtime, :enabled) == true
    refute Keyword.has_key?(realtime, :activation)
    refute Keyword.has_key?(realtime, :turn_detection)
    assert Keyword.get(realtime, :max_session_minutes) == 10
    assert Keyword.get(realtime, :max_estimated_cost_cents_per_session) == 25
    assert Keyword.get(realtime, :persist_transcripts) == true
  end

  test "load rejects removed realtime config keys" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.realtime]
    enabled = true
    max_buffer_chunks = 20
    """)

    assert_raise ArgumentError, ~r/max_buffer_chunks.*removed/, fn ->
      ConfigStore.load_runtime_config()
    end
  end

  test "apply_snapshot merges memory config without wiping non-persisted keys" do
    Application.put_env(:fermix_core, :memory,
      extraction_enabled: false,
      agent_id: "stable-agent",
      extraction_timeout_ms: 1_000
    )

    ConfigStore.apply_snapshot(%{
      fermix_core: [
        memory: [extraction_timeout_ms: 90_000]
      ],
      fermix_channels: [],
      fermix_web: []
    })

    memory = Application.get_env(:fermix_core, :memory, [])

    assert Keyword.get(memory, :extraction_timeout_ms) == 90_000
    assert Keyword.get(memory, :extraction_enabled) == false
    assert Keyword.get(memory, :agent_id) == "stable-agent"
  end

  test "apply_snapshot writes realtime config into Application env" do
    Application.put_env(:fermix_core, :realtime, [])

    ConfigStore.apply_snapshot(%{
      fermix_core: [
        realtime: [
          enabled: true,
          provider: "openai",
          max_session_minutes: 7
        ]
      ],
      fermix_channels: [],
      fermix_web: []
    })

    realtime = Application.get_env(:fermix_core, :realtime, [])

    assert Keyword.get(realtime, :enabled) == true
    assert Keyword.get(realtime, :provider) == "openai"
    refute Keyword.has_key?(realtime, :activation)
    refute Keyword.has_key?(realtime, :turn_detection)
    assert Keyword.get(realtime, :max_session_minutes) == 7
  end

  test "load_runtime_config rejects non-positive extraction_timeout_ms from hand-edited TOML" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.memory]
    extraction_timeout_ms = 0
    """)

    assert_raise ArgumentError, ~r/extraction_timeout_ms/, fn ->
      ConfigStore.load_runtime_config()
    end
  end

  test "channel streaming survives the load normalizers for every channel" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_channels.telegram]
    streaming = "block"

    [fermix_channels.whatsapp]
    streaming = "off"

    [fermix_channels.signal]
    streaming = "draft"
    """)

    assert {:ok, loaded} = ConfigStore.load_runtime_config()

    telegram = Keyword.get(loaded.fermix_channels, :telegram, [])
    assert Keyword.get(telegram, :streaming) == "block"

    whatsapp = Keyword.get(loaded.fermix_channels, :whatsapp, [])
    assert Keyword.get(whatsapp, :streaming) == "off"

    signal = Keyword.get(loaded.fermix_channels, :signal, [])
    assert Keyword.get(signal, :streaming) == "draft"
  end

  test "load_runtime_config rejects an invalid channel streaming value from hand-edited TOML" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_channels.telegram]
    streaming = "blast"
    """)

    assert_raise ArgumentError, ~r/streaming/, fn ->
      ConfigStore.load_runtime_config()
    end
  end

  test "apply_snapshot writes personalization and agent into Application env" do
    Application.put_env(:fermix_core, :personalization, [])
    Application.put_env(:fermix_core, :agent, [])
    Application.put_env(:fermix_core, :compaction, [])

    ConfigStore.apply_snapshot(%{
      fermix_core: [
        personalization: [
          user_name: "Sujeeth",
          timezone: "Asia/Singapore",
          communication_style: "blunt"
        ],
        agent: [name: "aira"],
        compaction: [enabled: false, threshold: 0.5]
      ],
      fermix_channels: [],
      fermix_web: []
    })

    personalization = Application.get_env(:fermix_core, :personalization, [])
    agent = Application.get_env(:fermix_core, :agent, [])
    compaction = Application.get_env(:fermix_core, :compaction, [])

    assert Keyword.get(personalization, :user_name) == "Sujeeth"
    assert Keyword.get(personalization, :timezone) == "Asia/Singapore"
    assert Keyword.get(personalization, :communication_style) == "blunt"
    assert Keyword.get(agent, :name) == "aira"
    assert Keyword.get(compaction, :enabled) == false
    assert Keyword.get(compaction, :threshold) == 0.5
  end

  test "bootstrap_runtime_config hydrates Application env from the persisted TOML" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    Application.put_env(:fermix_core, :personalization, [])
    Application.put_env(:fermix_core, :agent, [])
    Application.put_env(:fermix_core, :jobs, [])
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
          agent: [name: "aira"],
          jobs: [
            default_delivery_mode: "channel",
            default_delivery_target: [platform: "telegram", chat_id: "8217352118"]
          ]
        ],
        fermix_channels: [telegram: [enabled: true, mode: :webhook, bot_token: "bot-token"]],
        fermix_web: []
      })

    Application.put_env(:fermix_core, :personalization, [])
    Application.put_env(:fermix_core, :agent, [])
    Application.put_env(:fermix_core, :jobs, [])
    Application.put_env(:fermix_channels, :telegram, [])

    assert :ok = ConfigStore.bootstrap_runtime_config()

    personalization = Application.get_env(:fermix_core, :personalization, [])
    agent = Application.get_env(:fermix_core, :agent, [])
    jobs = Application.get_env(:fermix_core, :jobs, [])
    telegram = Application.get_env(:fermix_channels, :telegram, [])

    assert Keyword.get(personalization, :user_name) == "Sujeeth"
    assert Keyword.get(personalization, :timezone) == "Asia/Singapore"
    assert Keyword.get(personalization, :communication_style) == "blunt"
    assert Keyword.get(agent, :name) == "aira"
    assert Keyword.get(jobs, :default_delivery_mode) == "channel"

    assert Keyword.get(jobs, :default_delivery_target) == [
             platform: "telegram",
             chat_id: "8217352118"
           ]

    assert Keyword.get(telegram, :bot_token) == "bot-token"
    assert Keyword.get(telegram, :enabled) == true
  end

  test "save/load round-trips cron job default delivery config" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [
        providers: [openai: []],
        agent: [name: "fermix", provider: :openai_codex],
        jobs: [
          default_delivery_mode: "channel",
          default_delivery_target: [
            platform: "telegram",
            chat_id: "8217352118",
            thread_ts: "42"
          ],
          delivery_channels: %{"telegram" => FermixChannels.Channels.Telegram}
        ]
      ],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)

    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ "[fermix_core.jobs]"
    assert contents =~ ~s(default_delivery_mode = "channel")
    assert contents =~ "[fermix_core.jobs.default_delivery_target]"
    assert contents =~ ~s(platform = "telegram")
    assert contents =~ ~s(chat_id = "8217352118")
    assert contents =~ ~s(thread_ts = "42")
    refute contents =~ "delivery_channels"

    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    jobs = Keyword.get(loaded.fermix_core, :jobs, [])

    assert Keyword.get(jobs, :default_delivery_mode) == "channel"

    assert Keyword.get(jobs, :default_delivery_target) == [
             platform: "telegram",
             chat_id: "8217352118",
             thread_ts: "42"
           ]
  end

  test "save/load round-trips per-channel command authorization config" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [providers: [openai: []], agent: [name: "fermix"]],
      fermix_channels: [
        telegram: [
          enabled: true,
          mode: :webhook,
          owner_user_id: "111",
          command_allowlist: ["222", "333"]
        ],
        signal: [owner_user_id: "+15550001111", command_allowlist: ["+15552223333"]]
      ],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)

    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ ~s(owner_user_id = "111")
    assert contents =~ ~s(command_allowlist = ["222", "333"])

    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    channels = loaded.fermix_channels

    assert Keyword.get(channels[:telegram], :owner_user_id) == "111"
    assert Keyword.get(channels[:telegram], :command_allowlist) == ["222", "333"]
    assert Keyword.get(channels[:signal], :owner_user_id) == "+15550001111"
    assert Keyword.get(channels[:signal], :command_allowlist) == ["+15552223333"]
  end

  test "load preserves absent ingress allowlists for owner-user defaults" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_channels.telegram]
    enabled = true
    owner_user_id = "111"
    """)

    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    telegram = loaded.fermix_channels[:telegram]

    refute Keyword.has_key?(telegram, :allowed_user_ids)
    assert Keyword.get(telegram, :owner_user_id) == "111"
  end

  test "bootstrap_runtime_config is a no-op when no TOML exists" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    System.put_env("FERMIX_HOME", tmp_home)

    Application.put_env(:fermix_core, :personalization, user_name: "preserved")

    assert :ok = ConfigStore.bootstrap_runtime_config()

    personalization = Application.get_env(:fermix_core, :personalization, [])
    assert Keyword.get(personalization, :user_name) == "preserved"
    assert %InboundConfig{enabled?: false} = Application.get_env(:fermix_core, :mcp_inbound)
  end

  test "bootstrap_runtime_config hydrates inbound MCP config alongside outbound servers" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      FermixTestSupport.SafeRm.rm_rf!(tmp_home)
      System.delete_env("FERMIX_INBOUND_TOKEN_TEST")
    end)

    System.put_env("FERMIX_HOME", tmp_home)
    System.put_env("FERMIX_INBOUND_TOKEN_TEST", "secret-token")
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [mcp.servers.github]
    command = "npx"
    args = ["-y", "@modelcontextprotocol/server-github"]

    [mcp.inbound]
    enabled = true
    transport = "streamable_http"
    expose_kinds = ["builtin", "mcp"]

    [mcp.inbound.http]
    auth_token = "$env:FERMIX_INBOUND_TOKEN_TEST"
    """)

    assert :ok = ConfigStore.bootstrap_runtime_config()

    assert [%{name: "github", command: "npx"}] = Application.get_env(:fermix_core, :mcp_servers)

    assert %InboundConfig{
             enabled?: true,
             transport: :streamable_http,
             expose_kinds: [:builtin, :mcp],
             http: %{path: "/mcp", auth_token: "secret-token"}
           } = Application.get_env(:fermix_core, :mcp_inbound)
  end

  test "bootstrap_runtime_config persists provider selection under :agent" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    Application.put_env(:fermix_core, :agent, [])

    :ok =
      ConfigStore.save_snapshot(%{
        fermix_core: [
          providers: [openai: []],
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

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
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
          openai_codex: [
            default_model: "gpt-5.5",
            reasoning_effort: :xhigh,
            fast: true,
            store: true
          ],
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
    assert contents =~ "fast = true"
    refute contents =~ "store ="
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
    assert Keyword.get(openai_codex, :fast) == true
    refute Keyword.has_key?(openai_codex, :store)

    anthropic = Keyword.get(providers, :anthropic, [])
    assert Keyword.get(anthropic, :default_model) == "claude-opus-4-7"
    assert Keyword.get(anthropic, :api_key) == "sk-ant"
  end

  test "save/load round-trips auth_mode = :oauth for xai and anthropic" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [
        providers: [
          anthropic: [auth_mode: :oauth, default_model: "claude-opus-4-7"],
          xai: [auth_mode: :oauth, default_model: "grok-4.3"]
        ],
        agent: [name: "fermix", provider: :xai]
      ],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)

    # OAuth mode must survive serialization (the snapshot is normalized on save).
    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ ~s(auth_mode = "oauth")

    # ...and survive parsing back, so RouteResolver/doctor use the OAuth profile
    # instead of silently demanding an API key.
    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    providers = Keyword.get(loaded.fermix_core, :providers, [])

    assert providers |> Keyword.get(:anthropic, []) |> Keyword.get(:auth_mode) == :oauth
    assert providers |> Keyword.get(:xai, []) |> Keyword.get(:auth_mode) == :oauth
  end

  test "load_runtime_config migrates a persisted reasoning_effort = \"minimal\" to :low" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.providers.openai]
    reasoning_effort = "minimal"
    """)

    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    openai = loaded.fermix_core |> Keyword.get(:providers, []) |> Keyword.get(:openai, [])
    assert Keyword.get(openai, :reasoning_effort) == :low
  end

  test "save_snapshot preserves dormant provider blocks when only one provider is updated" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
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

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
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

  test "normalize_openai drops auth_mode from hand-edited TOML" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.providers.openai]
    auth_mode = "oauth"
    api_key = "sk-x"
    """)

    assert {:ok, loaded} = ConfigStore.load_runtime_config()

    openai =
      loaded.fermix_core
      |> Keyword.get(:providers, [])
      |> Keyword.get(:openai, [])

    refute Keyword.has_key?(openai, :auth_mode)
    assert Keyword.get(openai, :api_key) == "sk-x"
  end

  test "load_runtime_config rejects invalid compaction values from hand-edited TOML" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.compaction]
    enabled = "true"
    threshold = 1.2
    """)

    assert_raise ArgumentError, ~r/compaction/, fn ->
      ConfigStore.load_runtime_config()
    end
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

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
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
