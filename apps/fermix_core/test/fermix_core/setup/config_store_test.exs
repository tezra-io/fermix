defmodule FermixCore.Setup.ConfigStoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.MCP.Inbound.Config, as: InboundConfig
  alias FermixCore.Meetings.Config, as: MeetingsConfig
  alias FermixCore.Setup.ConfigStore

  setup do
    fermix_home = System.get_env("FERMIX_HOME")
    personalization = Application.get_env(:fermix_core, :personalization, [])
    agent = Application.get_env(:fermix_core, :agent, [])
    jobs = Application.get_env(:fermix_core, :jobs, [])
    compaction = Application.get_env(:fermix_core, :compaction, [])
    harness = Application.get_env(:fermix_core, :harness, [])
    skill_curation = Application.get_env(:fermix_core, :skill_curation, [])
    memory = Application.get_env(:fermix_core, :memory, [])
    realtime = Application.get_env(:fermix_core, :realtime, [])
    computer_use = Application.get_env(:fermix_core, :computer_use, [])
    transcription = Application.get_env(:fermix_core, :transcription, [])
    meetings = Application.get_env(:fermix_core, :meetings, [])
    tools = Application.get_env(:fermix_core, :tools, [])
    plugins = Application.get_env(:fermix_core, :plugins, [])
    oauth = Application.get_env(:fermix_core, :oauth, %{})
    sandbox = Application.get_env(:fermix_core, :sandbox)
    mcp_servers = Application.get_env(:fermix_core, :mcp_servers, [])
    mcp_inbound = Application.get_env(:fermix_core, :mcp_inbound, InboundConfig.default())
    secret_writer = Application.get_env(:fermix_core, :secret_writer)
    mobile = Application.get_env(:fermix_channels, :mobile, [])

    FermixTestSupport.SecretWriterStub.reset()
    Application.put_env(:fermix_core, :secret_writer, FermixTestSupport.SecretWriterStub)

    on_exit(fn ->
      Application.put_env(:fermix_core, :personalization, personalization)
      Application.put_env(:fermix_core, :agent, agent)
      Application.put_env(:fermix_core, :jobs, jobs)
      Application.put_env(:fermix_core, :compaction, compaction)
      Application.put_env(:fermix_core, :harness, harness)
      Application.put_env(:fermix_core, :skill_curation, skill_curation)
      Application.put_env(:fermix_core, :memory, memory)
      Application.put_env(:fermix_core, :realtime, realtime)
      Application.put_env(:fermix_core, :computer_use, computer_use)
      Application.put_env(:fermix_core, :transcription, transcription)
      Application.put_env(:fermix_core, :meetings, meetings)
      Application.put_env(:fermix_core, :tools, tools)
      Application.put_env(:fermix_core, :plugins, plugins)
      Application.put_env(:fermix_core, :oauth, oauth)
      restore_sandbox(sandbox)
      Application.put_env(:fermix_core, :mcp_servers, mcp_servers)
      Application.put_env(:fermix_core, :mcp_inbound, mcp_inbound)
      restore_secret_writer(secret_writer)
      Application.put_env(:fermix_channels, :mobile, mobile)
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

  # Captures the opts each keyring read receives so the apply_snapshot/2 →
  # SecretStore → SecretWriter → CommandRunner threading is observable.
  defmodule OptsRecordingWriter do
    @behaviour FermixCore.Setup.SecretWriter

    @table __MODULE__

    def start do
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :bag])
      end

      :ets.delete_all_objects(@table)
      :ok
    end

    def recorded_opts, do: @table |> :ets.tab2list() |> Enum.map(fn {_key, opts} -> opts end)

    @impl true
    def available?(_opts \\ []), do: true

    @impl true
    def get(key, opts \\ []) do
      :ets.insert(@table, {key, opts})
      {:ok, "resolved-" <> Atom.to_string(key)}
    end

    @impl true
    def put(_key, _value, _opts \\ []), do: raise("resolution must never write")

    @impl true
    def delete(_key, _opts \\ []), do: raise("resolution must never delete")

    @impl true
    def command_source(key, _opts \\ []) do
      %{source: :command, command: "recording", args: [Atom.to_string(key)]}
    end
  end

  describe "apply_snapshot/2 supervised threading (boot config-provider chain)" do
    setup do
      core = Application.get_all_env(:fermix_core)
      channels = Application.get_all_env(:fermix_channels)

      :ok = OptsRecordingWriter.start()
      Application.put_env(:fermix_core, :secret_writer, OptsRecordingWriter)

      on_exit(fn ->
        Enum.each(core, fn {k, v} -> Application.put_env(:fermix_core, k, v) end)
        Enum.each(channels, fn {k, v} -> Application.put_env(:fermix_channels, k, v) end)
      end)

      :ok
    end

    @sentinel_snapshot %{fermix_core: [providers: [openai: [api_key: "@keyring"]]]}

    test "the boot entry point threads supervised: false down to the read" do
      :ok = ConfigStore.apply_snapshot(@sentinel_snapshot, supervised: false)

      opts = List.first(OptsRecordingWriter.recorded_opts())
      assert opts, "apply_snapshot resolved no keyring sentinel"
      assert Keyword.get(opts, :supervised) == false
    end

    test "a daemon apply_snapshot omits supervised (defaults to the supervised host)" do
      :ok = ConfigStore.apply_snapshot(@sentinel_snapshot)

      opts = List.first(OptsRecordingWriter.recorded_opts())
      assert opts, "apply_snapshot resolved no keyring sentinel"
      refute Keyword.has_key?(opts, :supervised)
    end
  end

  describe "bootstrap_runtime_config/1 supervised threading (boot config-provider chain)" do
    setup do
      core = Application.get_all_env(:fermix_core)
      channels = Application.get_all_env(:fermix_channels)

      :ok = OptsRecordingWriter.start()
      Application.put_env(:fermix_core, :secret_writer, OptsRecordingWriter)

      tmp_home = FermixTestSupport.SafeRm.make_tmp_dir!("config-store-bootstrap")
      System.put_env("FERMIX_HOME", tmp_home)

      File.write!(Path.join(tmp_home, "config.toml"), """
      [fermix_core.providers.openai]
      api_key = "@keyring"
      """)

      on_exit(fn ->
        Enum.each(core, fn {k, v} -> Application.put_env(:fermix_core, k, v) end)
        Enum.each(channels, fn {k, v} -> Application.put_env(:fermix_channels, k, v) end)
        FermixTestSupport.SafeRm.rm_rf!(tmp_home)
      end)

      :ok
    end

    # The boot resolve happens in load_runtime_config/1 (the sentinel is gone
    # from the snapshot before apply_snapshot re-resolves), so this must drive
    # the real entry point over a sentinel-bearing TOML — asserting only the
    # apply_snapshot seam leaves the actual boot read uncovered.
    test "the boot entry threads supervised: false through the load-path keyring read" do
      :ok = ConfigStore.bootstrap_runtime_config(supervised: false)

      recorded = OptsRecordingWriter.recorded_opts()
      assert recorded != [], "bootstrap resolved no keyring sentinel"

      for opts <- recorded do
        assert Keyword.get(opts, :supervised) == false,
               "a boot-path keyring read ran without supervised: false: #{inspect(opts)}"
      end
    end
  end

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
             mobile: Path.join(tmp_home, "mobile"),
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
            perplexity_api_key: "@keyring",
            firecrawl_api_key: "@keyring"
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
    assert Keyword.get(web_search, :firecrawl_api_key) == "@keyring"
  end

  test "save/load round-trip preserves generate_image backend config (M15)" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [
        tools: [
          generate_image: [
            backend: "openai",
            model: "gpt-image-2",
            size: "1024x1024",
            google_api_key: "@keyring"
          ]
        ]
      ],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)

    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ "[fermix_core.tools.generate_image]"
    assert contents =~ ~s(backend = "openai")
    # A keyring sentinel is never written back as plaintext.
    assert contents =~ ~s(google_api_key = "@keyring")

    assert {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false)

    generate_image =
      loaded.fermix_core
      |> Keyword.get(:tools, [])
      |> Keyword.get(:generate_image, [])

    assert Keyword.get(generate_image, :backend) == "openai"
    assert Keyword.get(generate_image, :model) == "gpt-image-2"
    assert Keyword.get(generate_image, :size) == "1024x1024"
    assert Keyword.get(generate_image, :google_api_key) == "@keyring"
  end

  test "load refuses to boot on an unknown generate_image key (M15)" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.tools.generate_image]
    backend = "openai"
    bakend = "typo"
    """)

    assert_raise ArgumentError, ~r/unknown key\(s\): bakend/, fn ->
      ConfigStore.load_runtime_config(resolve_secrets: false)
    end
  end

  test "save/load round-trip preserves computer_history config (M32)" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [
        computer_history: [
          enabled: true,
          apps: ["com.apple.Safari"],
          sites: ["github.com"],
          summarizer: :local
        ]
      ],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)

    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ "[fermix_core.computer_history]"
    assert contents =~ "enabled = true"
    assert contents =~ ~s(summarizer = "local")

    assert {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false)
    computer_history = Keyword.get(loaded.fermix_core, :computer_history, [])
    assert Keyword.get(computer_history, :enabled) == true
    assert Keyword.get(computer_history, :apps) == ["com.apple.Safari"]
    assert Keyword.get(computer_history, :summarizer) == :local
  end

  test "load refuses to boot on an unknown computer_history key (M32)" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.computer_history]
    enabled = true
    aps = ["com.apple.Safari"]
    """)

    assert_raise ArgumentError, ~r/unknown key\(s\): aps/, fn ->
      ConfigStore.load_runtime_config(resolve_secrets: false)
    end
  end

  test "load refuses to boot on an unknown generate_image backend (M15)" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.tools.generate_image]
    backend = "midjourney"
    """)

    assert_raise ArgumentError, ~r/unknown backend.*midjourney/s, fn ->
      ConfigStore.load_runtime_config(resolve_secrets: false)
    end
  end

  test "save/load round-trip preserves transcription config incl. the secret sentinel (M21)" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [
        transcription: [
          backend: "deepgram",
          model: "nova-3",
          openai_api_key: "@keyring",
          xai_api_key: "@keyring",
          deepgram_api_key: "@keyring",
          max_file_mb: 25
        ]
      ],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)

    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ "[fermix_core.transcription]"
    assert contents =~ ~s(backend = "deepgram")
    assert contents =~ ~s(model = "nova-3")
    assert contents =~ "max_file_mb = 25"
    # Each per-backend keyring sentinel round-trips (never plaintext).
    assert contents =~ ~s(openai_api_key = "@keyring")
    assert contents =~ ~s(xai_api_key = "@keyring")
    assert contents =~ ~s(deepgram_api_key = "@keyring")

    assert {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false)
    transcription = Keyword.get(loaded.fermix_core, :transcription, [])

    assert Keyword.get(transcription, :backend) == "deepgram"
    assert Keyword.get(transcription, :model) == "nova-3"
    assert Keyword.get(transcription, :openai_api_key) == "@keyring"
    assert Keyword.get(transcription, :xai_api_key) == "@keyring"
    assert Keyword.get(transcription, :deepgram_api_key) == "@keyring"
    assert Keyword.get(transcription, :max_file_mb) == 25
  end

  test "load refuses to boot on an unknown transcription key (M21)" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.transcription]
    backend = "openai"
    modle = "typo"
    """)

    assert_raise ArgumentError, ~r/unknown key\(s\): modle/, fn ->
      ConfigStore.load_runtime_config(resolve_secrets: false)
    end
  end

  test "load refuses to boot on an unknown transcription backend (M21)" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.transcription]
    backend = "vosk"
    """)

    assert_raise ArgumentError, ~r/unknown backend.*vosk/s, fn ->
      ConfigStore.load_runtime_config(resolve_secrets: false)
    end
  end

  # The allowed set is the registry's, so the on-device backend became
  # selectable the day it was registered — no second list to update here.
  test "load accepts every backend the transcription registry ships, local included (M21)" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    for {name, _module} <- FermixCore.Transcription.Registry.backends() do
      File.write!(Path.join(tmp_home, "config.toml"), """
      [fermix_core.transcription]
      backend = "#{name}"
      """)

      assert {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false)
      transcription = Keyword.get(loaded.fermix_core, :transcription, [])
      assert Keyword.get(transcription, :backend) == Atom.to_string(name)
    end
  end

  test "load refuses to boot on a non-positive transcription max_file_mb (M21)" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.transcription]
    backend = "openai"
    max_file_mb = 0
    """)

    assert_raise ArgumentError, ~r/max_file_mb.*positive integer/s, fn ->
      ConfigStore.load_runtime_config(resolve_secrets: false)
    end
  end

  test "save secures a plaintext transcription api_key through the keychain (M21)" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [transcription: [backend: "deepgram", deepgram_api_key: "dg-secret-plaintext"]],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)

    contents = File.read!(Path.join(tmp_home, "config.toml"))
    # The plaintext key never lands in config.toml; the sentinel does.
    assert contents =~ ~s(deepgram_api_key = "@keyring")
    refute contents =~ "dg-secret-plaintext"

    # …and the real value lives in the (stubbed) keychain under its secret key.
    assert {:ok, "dg-secret-plaintext"} =
             FermixTestSupport.SecretWriterStub.get(:deepgram_api_key)
  end

  test "save secures the openai/xai transcription override keys to their own keychain slots (M21)" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [
        transcription: [
          backend: "openai",
          openai_api_key: "sk-transcription-plaintext",
          xai_api_key: "xai-transcription-plaintext"
        ]
      ],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)

    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ ~s(openai_api_key = "@keyring")
    assert contents =~ ~s(xai_api_key = "@keyring")
    refute contents =~ "sk-transcription-plaintext"
    refute contents =~ "xai-transcription-plaintext"

    # Each override lands under its own distinct keychain key, not the chat-key one.
    assert {:ok, "sk-transcription-plaintext"} =
             FermixTestSupport.SecretWriterStub.get(:transcription_openai_api_key)

    assert {:ok, "xai-transcription-plaintext"} =
             FermixTestSupport.SecretWriterStub.get(:transcription_xai_api_key)
  end

  test "apply_snapshot merges transcription config into app env (M21)" do
    Application.put_env(:fermix_core, :transcription, backend: "openai", max_file_mb: 20)

    ConfigStore.apply_snapshot(%{
      fermix_core: [transcription: [backend: "xai"]],
      fermix_channels: [],
      fermix_web: []
    })

    transcription = Application.get_env(:fermix_core, :transcription, [])
    assert Keyword.get(transcription, :backend) == "xai"
    # Other baseline keys survive the partial edit.
    assert Keyword.get(transcription, :max_file_mb) == 20
  end

  test "apply_snapshot drops the OpenAI-shaped baseline model when a hand-edit switches backend without a model (M21 §5.4)" do
    # The compile-time baseline (config.exs) always carries the OpenAI model. A
    # config.toml that names a different backend but pins no model must NOT let
    # that model bleed onto Deepgram (which would 400 on the OpenAI id) — and the
    # modelless xai backend must not carry a stale model either.
    Application.put_env(:fermix_core, :transcription,
      backend: "openai",
      model: "gpt-4o-mini-transcribe",
      max_file_mb: 20
    )

    ConfigStore.apply_snapshot(%{
      fermix_core: [transcription: [backend: "xai"]],
      fermix_channels: [],
      fermix_web: []
    })

    transcription = Application.get_env(:fermix_core, :transcription, [])
    assert Keyword.get(transcription, :backend) == "xai"
    # No model key survives — xai is modelless and sends no model to the API.
    refute Keyword.has_key?(transcription, :model)
    # Other baseline keys still survive the partial edit.
    assert Keyword.get(transcription, :max_file_mb) == 20
  end

  test "save/load round-trip preserves meetings config incl. the secret sentinel (M21)" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [
        meetings: [
          enabled: true,
          bot_name: "Notes Bot",
          announce: false,
          announce_message: "Recording notes for the team.",
          transcription_backend: "deepgram",
          retain_audio: true,
          zoom_account_id: "acct-1",
          zoom_client_id: "client-1",
          zoom_client_secret: "@keyring",
          zoom_ws_subscription_id: "sub-1"
        ]
      ],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)

    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ "[fermix_core.meetings]"
    assert contents =~ "enabled = true"
    assert contents =~ ~s(bot_name = "Notes Bot")
    assert contents =~ "announce = false"
    assert contents =~ "retain_audio = true"
    assert contents =~ ~s(zoom_client_secret = "@keyring")

    assert {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false)
    meetings = Keyword.get(loaded.fermix_core, :meetings, [])

    assert Keyword.get(meetings, :enabled) == true
    assert Keyword.get(meetings, :bot_name) == "Notes Bot"
    assert Keyword.get(meetings, :announce) == false
    assert Keyword.get(meetings, :announce_message) == "Recording notes for the team."
    assert Keyword.get(meetings, :transcription_backend) == "deepgram"
    assert Keyword.get(meetings, :retain_audio) == true
    assert Keyword.get(meetings, :zoom_account_id) == "acct-1"
    assert Keyword.get(meetings, :zoom_client_id) == "client-1"
    assert Keyword.get(meetings, :zoom_client_secret) == "@keyring"
    assert Keyword.get(meetings, :zoom_ws_subscription_id) == "sub-1"
  end

  test "load refuses to boot on an unknown meetings key (M21)" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.meetings]
    enabled = true
    bot_nmae = "typo"
    """)

    assert_raise ArgumentError, ~r/unknown key\(s\): bot_nmae/, fn ->
      ConfigStore.load_runtime_config(resolve_secrets: false)
    end
  end

  test "load refuses to boot on an unknown meetings transcription_backend (M21)" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.meetings]
    transcription_backend = "vosk"
    """)

    assert_raise ArgumentError, ~r/unknown transcription_backend.*vosk/s, fn ->
      ConfigStore.load_runtime_config(resolve_secrets: false)
    end
  end

  # Blank is the documented "use whatever [fermix_core.transcription] selected"
  # value, so it must parse — the meeting Session reads an absent key as blank.
  test "load accepts a blank meetings transcription_backend (M21)" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.meetings]
    enabled = true
    transcription_backend = ""
    """)

    assert {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false)
    meetings = Keyword.get(loaded.fermix_core, :meetings, [])

    assert Keyword.get(meetings, :enabled) == true
    refute Keyword.has_key?(meetings, :transcription_backend)
  end

  test "apply_snapshot applies meetings config to app env (M21)" do
    Application.put_env(:fermix_core, :meetings, enabled: false)

    ConfigStore.apply_snapshot(%{
      fermix_core: [meetings: [enabled: true, bot_name: "Notes Bot"]],
      fermix_channels: [],
      fermix_web: []
    })

    meetings = Application.get_env(:fermix_core, :meetings, [])
    assert Keyword.get(meetings, :enabled) == true
    assert Keyword.get(meetings, :bot_name) == "Notes Bot"
    # Keys the edit omitted are read back from Meetings.Config's own defaults.
    assert MeetingsConfig.load().announce == true
  end

  test "apply_snapshot lets a cleared meetings value take effect live (M21)" do
    Application.put_env(:fermix_core, :meetings,
      enabled: true,
      bot_name: "Notes Bot",
      announce_message: "Recording for the team.",
      zoom_account_id: "acct-1",
      zoom_client_id: "client-1",
      zoom_client_secret: "s3cr3t",
      zoom_ws_subscription_id: "sub-1"
    )

    # The card writes every text field on every save; blanks are dropped by
    # normalization, so a merge would keep the stale live values.
    ConfigStore.apply_snapshot(%{
      fermix_core: [
        meetings: [
          enabled: true,
          bot_name: "",
          announce_message: "",
          zoom_account_id: "",
          zoom_client_id: "",
          zoom_client_secret: "",
          zoom_ws_subscription_id: ""
        ]
      ],
      fermix_channels: [],
      fermix_web: []
    })

    config = MeetingsConfig.load()
    assert config.bot_name == "Fermix Notetaker"
    assert config.announce_message =~ "AI notetaker"
    refute config.announce_message =~ "Recording for the team."
    refute MeetingsConfig.rtms_configured?(config)
  end

  test "save secures a plaintext zoom_client_secret through the keychain (M21)" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [meetings: [enabled: true, zoom_client_secret: "zoom-secret-plaintext"]],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)

    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ ~s(zoom_client_secret = "@keyring")
    refute contents =~ "zoom-secret-plaintext"

    assert {:ok, "zoom-secret-plaintext"} =
             FermixTestSupport.SecretWriterStub.get(:meetings_zoom_client_secret)
  end

  test "save/load round-trip preserves the tool_search deferral flag (M10)" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [tools: [tool_search: [enabled: false]]],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)

    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ "[fermix_core.tools.tool_search]"
    assert contents =~ "enabled = false"

    assert {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false)

    tool_search =
      loaded.fermix_core
      |> Keyword.get(:tools, [])
      |> Keyword.get(:tool_search, [])

    # The explicit kill-switch survives the round-trip — it is not dropped on
    # the way to Application.get_env, so Deferral.enabled?/0 can read it.
    assert Keyword.get(tool_search, :enabled) == false
  end

  test "save/load round-trips subagent/cron routing keys and drops the removed dormant keys" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [
        routing: [
          # removed dormant keys (old config) — must degrade cleanly on next save
          coding_model: "old-coding-model",
          default_provider: "openai",
          # live keys
          subagent_provider: "openai",
          subagent_model: "gpt-5.4-mini",
          subagent_reasoning_effort: "low",
          cron_model: "claude-haiku-4-5",
          meeting_model: "claude-haiku-4-5",
          meeting_reasoning_effort: "low"
        ]
      ],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)

    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ "[fermix_core.routing]"
    assert contents =~ ~s(subagent_model = "gpt-5.4-mini")
    refute contents =~ "coding_model"
    refute contents =~ "default_provider"

    assert {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false)
    routing = Keyword.get(loaded.fermix_core, :routing, [])

    assert Keyword.get(routing, :subagent_provider) == "openai"
    assert Keyword.get(routing, :subagent_model) == "gpt-5.4-mini"
    assert Keyword.get(routing, :subagent_reasoning_effort) == "low"
    assert Keyword.get(routing, :cron_model) == "claude-haiku-4-5"
    # The meeting-summary route survives too — a dropped key would silently send
    # every summary back to the main model (M21 Phase 3).
    assert Keyword.get(routing, :meeting_model) == "claude-haiku-4-5"
    assert Keyword.get(routing, :meeting_reasoning_effort) == "low"
    refute Keyword.has_key?(routing, :coding_model)
    refute Keyword.has_key?(routing, :default_provider)
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

  test "load/save round-trips plugins dev_local as a top-level scalar" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.plugins]
    enabled = ["google_calendar"]
    dev_local = "/tmp/x"

    [fermix_core.plugins.google_calendar]
    auth_profile = "google_calendar:primary"
    """)

    assert {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false)
    plugins = Keyword.get(loaded.fermix_core, :plugins, [])

    assert Keyword.get(plugins, :dev_local) == "/tmp/x"
    assert Keyword.get(plugins, :enabled) == ["google_calendar"]

    entries = Keyword.get(plugins, :entries, %{})
    assert Map.keys(entries) == ["google_calendar"]

    assert :ok = ConfigStore.save_snapshot(loaded)

    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ ~s(dev_local = "/tmp/x")
    refute contents =~ "[fermix_core.plugins.dev_local]"
  end

  test "a non-string plugins dev_local is dropped like other bad config values" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.plugins]
    enabled = ["google_calendar"]
    dev_local = 42
    """)

    assert {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false)
    plugins = Keyword.get(loaded.fermix_core, :plugins, [])

    refute Keyword.has_key?(plugins, :dev_local)
    assert Keyword.get(plugins, :entries, %{}) == %{}
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

  test "load_runtime_config warns for missing optional web search keyring secrets" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.tools.web_search]
    backend = "tavily"
    tavily_api_key = "@keyring"
    """)

    log =
      capture_log(fn ->
        assert {:ok, loaded} = ConfigStore.load_runtime_config()

        web_search =
          loaded.fermix_core
          |> Keyword.get(:tools, [])
          |> Keyword.get(:web_search, [])

        assert Keyword.get(web_search, :backend) == :tavily
        assert Keyword.get(web_search, :tavily_api_key) == "@keyring"
      end)

    assert log =~ "TAVILY_API_KEY"
    assert log =~ "Tavily web_search backend"
    assert log =~ "will fail"
    assert log =~ "fermix setup"
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

  test "save/load round-trips the harness config section" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [
        harness: [
          enabled: true,
          cloud_enabled: true,
          default_vendor: "codex",
          max_active: 3,
          default_timeout_minutes: 20,
          max_event_bytes: 2_097_152,
          max_framing_errors: 0,
          codex_home: "/home/op/.codex"
        ]
      ],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)

    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ "[fermix_core.harness]"
    assert contents =~ "enabled = true"
    assert contents =~ ~s(default_vendor = "codex")
    assert contents =~ "max_active = 3"
    assert contents =~ "max_event_bytes = 2097152"
    assert contents =~ "max_framing_errors = 0"
    assert contents =~ ~s(codex_home = "/home/op/.codex")

    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    harness = Keyword.get(loaded.fermix_core, :harness, [])

    assert Keyword.get(harness, :enabled) == true
    assert Keyword.get(harness, :cloud_enabled) == true
    assert Keyword.get(harness, :default_vendor) == "codex"
    assert Keyword.get(harness, :max_active) == 3
    assert Keyword.get(harness, :default_timeout_minutes) == 20
    assert Keyword.get(harness, :max_event_bytes) == 2_097_152
    assert Keyword.get(harness, :max_framing_errors) == 0
    assert Keyword.get(harness, :codex_home) == "/home/op/.codex"
  end

  # `allowed_hosts` is the documented recovery for every host the browser policy
  # refuses (`browser_guidance` SKILL.md tells the operator to list the host
  # there), so it has to be reachable from `config.toml`. It was not: the section
  # existed in `Browser.Config` and nothing carried it from the file into app env.
  test "save/load round-trips the browser allowed_hosts section" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [browser: [allowed_hosts: ["printer.local", "build.internal"]]],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)

    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ "[fermix_core.browser]"
    assert contents =~ ~s(allowed_hosts = ["printer.local", "build.internal"])

    assert {:ok, loaded} = ConfigStore.load_runtime_config()

    assert loaded.fermix_core
           |> Keyword.get(:browser, [])
           |> Keyword.get(:allowed_hosts) == ["printer.local", "build.internal"]
  end

  test "apply_snapshot puts browser config in Application env" do
    # `apply_snapshot/1` applies the WHOLE snapshot, so a snapshot naming only
    # `browser` still rewrites `:sandbox` to its default as a side effect. Both
    # keys are therefore saved and restored here — restoring only the one this
    # test is about leaves the next test reading a sandbox config this test set.
    previous = %{
      browser: Application.get_env(:fermix_core, :browser),
      sandbox: Application.get_env(:fermix_core, :sandbox)
    }

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:fermix_core, key)
        {key, value} -> Application.put_env(:fermix_core, key, value)
      end)
    end)

    ConfigStore.apply_snapshot(%{
      fermix_core: [browser: [allowed_hosts: ["build.internal"]]],
      fermix_channels: [],
      fermix_web: []
    })

    assert Application.get_env(:fermix_core, :browser, [])
           |> Keyword.get(:allowed_hosts) == ["build.internal"]
  end

  # Everything else in `Browser.Config` is a timeout, a cap, or a buffer size —
  # tuning, which is an internal constant here rather than a config surface. A
  # key that names one is refused loudly at the parse boundary so an operator who
  # tries is told it is not settable, rather than editing a line that does
  # nothing.
  test "load refuses to boot on a browser key that is not settable" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.browser]
    allowed_hosts = ["build.internal"]
    action_timeout_ms = 60000
    """)

    assert_raise ArgumentError,
                 ~r/\[fermix_core.browser\].*action_timeout_ms/s,
                 fn -> ConfigStore.load_runtime_config() end
  end

  test "apply_snapshot replaces harness config in Application env" do
    Application.put_env(:fermix_core, :harness, enabled: true, max_active: 9)

    ConfigStore.apply_snapshot(%{
      fermix_core: [harness: [enabled: false]],
      fermix_channels: [],
      fermix_web: []
    })

    harness = Application.get_env(:fermix_core, :harness, [])

    # Replace (not merge): the stale max_active must not survive the edit.
    assert Keyword.get(harness, :enabled) == false
    refute Keyword.has_key?(harness, :max_active)
  end

  test "load refuses to boot on an unknown harness key" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.harness]
    enabled = true
    max_activ = 2
    """)

    assert_raise ArgumentError, ~r/\[fermix_core.harness\].*unknown key\(s\): max_activ/s, fn ->
      ConfigStore.load_runtime_config()
    end
  end

  test "load refuses to boot on an invalid harness value" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.harness]
    max_active = 0
    """)

    assert_raise ArgumentError, ~r/harness\.max_active.*positive integer/s, fn ->
      ConfigStore.load_runtime_config()
    end
  end

  test "save/load round-trips the skill_curation config section" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [skill_curation: [enabled: false]],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)

    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ "[fermix_core.skill_curation]"
    assert contents =~ "enabled = false"

    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    skill_curation = Keyword.get(loaded.fermix_core, :skill_curation, [])
    assert Keyword.get(skill_curation, :enabled) == false
  end

  test "an empty skill_curation section is omitted from the TOML" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    assert :ok =
             ConfigStore.save_snapshot(%{
               fermix_core: [skill_curation: []],
               fermix_channels: [],
               fermix_web: []
             })

    refute File.read!(Path.join(tmp_home, "config.toml")) =~ "[fermix_core.skill_curation]"
  end

  test "apply_snapshot replaces skill_curation config in Application env" do
    Application.put_env(:fermix_core, :skill_curation, enabled: true)

    ConfigStore.apply_snapshot(%{
      fermix_core: [skill_curation: [enabled: false]],
      fermix_channels: [],
      fermix_web: []
    })

    skill_curation = Application.get_env(:fermix_core, :skill_curation, [])
    assert Keyword.get(skill_curation, :enabled) == false
  end

  test "load refuses to boot on an unknown skill_curation key" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.skill_curation]
    enabld = true
    """)

    assert_raise ArgumentError,
                 ~r/\[fermix_core.skill_curation\].*unknown key\(s\): enabld/s,
                 fn -> ConfigStore.load_runtime_config() end
  end

  test "load refuses to boot on an invalid skill_curation value" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.skill_curation]
    enabled = "yes"
    """)

    assert_raise ArgumentError, ~r/skill_curation\.enabled "yes"/s, fn ->
      ConfigStore.load_runtime_config()
    end
  end

  test "save/load round-trips memory.review_interval_hours" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [
        providers: [openai: []],
        agent: [name: "fermix"],
        memory: [review_interval_hours: 48]
      ],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)

    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ "[fermix_core.memory]"
    assert contents =~ "review_interval_hours = 48"

    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    memory = Keyword.get(loaded.fermix_core, :memory, [])
    assert Keyword.get(memory, :review_interval_hours) == 48
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
      review_interval_hours: 1
    )

    ConfigStore.apply_snapshot(%{
      fermix_core: [
        memory: [review_interval_hours: 48]
      ],
      fermix_channels: [],
      fermix_web: []
    })

    memory = Application.get_env(:fermix_core, :memory, [])

    assert Keyword.get(memory, :review_interval_hours) == 48
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

  test "save/load round-trips computer_use config" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [
        providers: [openai: []],
        computer_use: [
          enabled: true,
          screenshot_after: false,
          max_retained_screenshots: 5,
          max_actions: 25
        ]
      ],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)

    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ "[fermix_core.computer_use]"
    assert contents =~ "enabled = true"
    assert contents =~ "screenshot_after = false"
    # access is derived from [sandbox] mode — it is NEVER persisted in this section.
    refute contents =~ "access ="

    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    computer_use = Keyword.get(loaded.fermix_core, :computer_use, [])

    assert Keyword.get(computer_use, :enabled) == true
    refute Keyword.has_key?(computer_use, :mode)
    refute Keyword.has_key?(computer_use, :access)
    # the `?`-suffix struct fields must round-trip under their TOML key names
    assert Keyword.get(computer_use, :screenshot_after) == false
    assert Keyword.get(computer_use, :max_retained_screenshots) == 5
    assert Keyword.get(computer_use, :max_actions) == 25
  end

  test "apply_snapshot writes computer_use config into Application env" do
    Application.put_env(:fermix_core, :computer_use, enabled: true, max_actions: 25)

    ConfigStore.apply_snapshot(%{
      fermix_core: [
        computer_use: [enabled: false]
      ],
      fermix_channels: [],
      fermix_web: []
    })

    computer_use = Application.get_env(:fermix_core, :computer_use, [])

    # Replace (not merge): a disabled snapshot must not leave the prior `max_actions: 25`
    # / `enabled: true` behind — the section is fully normalized to the intended state.
    assert Keyword.get(computer_use, :enabled) == false
    assert Keyword.get(computer_use, :max_actions) == 80
  end

  test "load_runtime_config rejects negative review_interval_hours from hand-edited TOML" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.memory]
    review_interval_hours = -1
    """)

    assert_raise ArgumentError, ~r/review_interval_hours/, fn ->
      ConfigStore.load_runtime_config()
    end
  end

  # An absent section normalizes to `[]`, which merges over nothing — that is
  # what leaves the compile-time default (on) intact across an upgrade. The
  # boot-path consequence is pinned in
  # FermixChannels.Channels.Acp.UpgradeDefaultTest.
  test "acp normalizes an absent section to no override and round-trips when enabled" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    previous_acp = Application.fetch_env(:fermix_channels, :acp)

    on_exit(fn ->
      case previous_acp do
        {:ok, value} -> Application.put_env(:fermix_channels, :acp, value)
        :error -> Application.delete_env(:fermix_channels, :acp)
      end

      FermixTestSupport.SafeRm.rm_rf!(tmp_home)
    end)

    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.agent]
    name = "fermix"
    """)

    assert {:ok, absent} = ConfigStore.load_runtime_config()
    assert Keyword.fetch!(absent.fermix_channels, :acp) == []

    :ok =
      ConfigStore.save_snapshot(%{
        fermix_core: [],
        fermix_channels: [acp: [enabled: true]],
        fermix_web: []
      })

    assert File.read!(Path.join(tmp_home, "config.toml")) =~ "[fermix_channels.acp]"

    assert {:ok, reloaded} = ConfigStore.load_runtime_config()
    assert Keyword.fetch!(reloaded.fermix_channels, :acp) == [enabled: true]

    Application.put_env(:fermix_channels, :acp, enabled: false)

    assert :ok = ConfigStore.apply_snapshot(reloaded)
    assert Keyword.get(Application.get_env(:fermix_channels, :acp, []), :enabled) == true
  end

  test "mobile config and nested APNs push round-trip without plaintext secrets" do
    tmp_home = FermixTestSupport.SafeRm.make_tmp_dir!("config-store-mobile")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [],
      fermix_channels: [
        mobile: [
          enabled: true,
          mode: :listener,
          port: 4_031,
          bind: "0.0.0.0",
          advertise_mdns: true,
          streaming: "draft",
          max_media_bytes: 20_971_520,
          media_store_max_bytes: 2_147_483_648,
          push: [
            enabled: true,
            team_id: "TEAM123",
            key_id: "KEY123",
            key: "apns-private-key",
            topic: "io.tezra.fermix",
            environment: "development"
          ]
        ]
      ],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)
    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ "[fermix_channels.mobile]"
    assert contents =~ "mode = \"listener\""
    assert contents =~ "port = 4031"
    assert contents =~ "streaming = \"draft\""
    assert contents =~ "[fermix_channels.mobile.push]"
    assert contents =~ ~s(key = "@keyring")
    refute contents =~ "apns-private-key"
    assert {:ok, "apns-private-key"} = FermixTestSupport.SecretWriterStub.get(:mobile_apns_key)

    assert {:ok, loaded} = ConfigStore.load_runtime_config(resolve_secrets: false)
    mobile = Keyword.fetch!(loaded.fermix_channels, :mobile)
    assert Keyword.get(mobile, :mode) == :listener
    assert Keyword.get(mobile, :port) == 4_031
    assert Keyword.get(mobile, :max_media_bytes) == 20_971_520
    assert Keyword.get(mobile, :media_store_max_bytes) == 2_147_483_648
    assert Keyword.get(mobile, :push)[:key] == "@keyring"
    assert Keyword.get(mobile, :push)[:environment] == "development"
  end

  test "mobile config rejects unsafe ports, modes, media caps, and push environments" do
    invalid_configs = [
      {[port: 0], ~r/mobile.port/},
      {[mode: :gateway], ~r/mobile.mode/},
      {[bind: "0.0.0"], ~r/mobile.bind/},
      {[bind: "localhost"], ~r/mobile.bind/},
      {[max_media_bytes: -1], ~r/mobile.max_media_bytes/},
      {[media_store_max_bytes: 0], ~r/mobile.media_store_max_bytes/},
      {[push: [environment: "staging"]], ~r/mobile.push.environment/}
    ]

    for {mobile, message} <- invalid_configs do
      snapshot = %{fermix_core: [], fermix_channels: [mobile: mobile], fermix_web: []}
      assert_raise ArgumentError, message, fn -> ConfigStore.persistable_snapshot(snapshot) end
    end
  end

  test "apply_snapshot merges mobile settings over compile defaults" do
    Application.put_env(:fermix_channels, :mobile,
      enabled: false,
      mode: :listener,
      port: 4_031,
      streaming: "draft"
    )

    assert :ok =
             ConfigStore.apply_snapshot(%{
               fermix_core: [],
               fermix_channels: [mobile: [enabled: true, port: 4_032]],
               fermix_web: []
             })

    mobile = Application.fetch_env!(:fermix_channels, :mobile)
    assert mobile[:enabled] == true
    assert mobile[:port] == 4_032
    assert mobile[:mode] == :listener
    assert mobile[:streaming] == "draft"
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

  test "save/load round-trips the network readiness job flag" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)

    snapshot = %{
      fermix_core: [
        providers: [openai: []],
        agent: [name: "fermix"],
        jobs: [network_readiness_enabled: false]
      ],
      fermix_channels: [],
      fermix_web: []
    }

    assert :ok = ConfigStore.save_snapshot(snapshot)

    contents = File.read!(Path.join(tmp_home, "config.toml"))
    assert contents =~ "network_readiness_enabled = false"

    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    jobs = Keyword.get(loaded.fermix_core, :jobs, [])

    assert Keyword.get(jobs, :network_readiness_enabled) == false
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
          anthropic: [auth_mode: :api_key, api_key: "sk-ant", default_model: "claude-opus-4-8"]
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
    assert contents =~ ~s(default_model = "claude-opus-4-8")

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
    assert Keyword.get(anthropic, :default_model) == "claude-opus-4-8"
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
          anthropic: [auth_mode: :oauth, default_model: "claude-opus-4-8"],
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
          anthropic: [auth_mode: :api_key, api_key: "sk-ant", default_model: "claude-opus-4-8"]
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

  test "openrouter and ollama blocks round-trip through dump -> parse -> normalize" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.providers.openrouter]
    api_key = "sk-or-disk"
    base_url = "https://proxy.example/api/v1"
    default_model = "z-ai/glm-5.1"
    primary = true

    [fermix_core.providers.ollama]
    base_url = "http://localhost:11434/v1"
    default_model = "qwen3:32b"
    """)

    assert {:ok, loaded} = ConfigStore.load_runtime_config()
    providers = Keyword.get(loaded.fermix_core, :providers, [])

    assert Keyword.get(providers[:openrouter], :api_key) == "sk-or-disk"
    assert Keyword.get(providers[:openrouter], :base_url) == "https://proxy.example/api/v1"
    assert Keyword.get(providers[:openrouter], :primary) == true
    assert Keyword.get(providers[:ollama], :base_url) == "http://localhost:11434/v1"
    assert Keyword.get(providers[:ollama], :default_model) == "qwen3:32b"

    # Idempotent round-trip: save the loaded snapshot and reload byte-stable
    # provider blocks (secure_secrets: false keeps the plaintext fixture).
    assert :ok = ConfigStore.save_snapshot(loaded, secure_secrets: false)
    assert {:ok, reloaded} = ConfigStore.load_runtime_config()

    assert Keyword.get(reloaded.fermix_core, :providers) ==
             Keyword.get(loaded.fermix_core, :providers)
  end

  test "rejects an api_key in the keyless ollama block from hand-edited TOML" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.providers.ollama]
    api_key = "nonsense"
    """)

    assert_raise ArgumentError, ~r/unknown key\(s\): api_key/, fn ->
      ConfigStore.load_runtime_config()
    end
  end

  test "rejects an unknown legacy agent provider from hand-edited TOML" do
    tmp_home =
      Path.join(System.tmp_dir!(), "fermix-config-store-#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)
    System.put_env("FERMIX_HOME", tmp_home)
    File.mkdir_p!(tmp_home)

    File.write!(Path.join(tmp_home, "config.toml"), """
    [fermix_core.agent]
    provider = "gemini"
    """)

    # M12 §2.3-1: an unknown provider used to silently normalize to nil and
    # boot on the default provider — the worst silent failure on record.
    assert_raise ArgumentError, ~r/provider = "gemini" is unknown/, fn ->
      ConfigStore.load_runtime_config()
    end
  end

  test "rejects unknown keys (auth_mode) in the openai block from hand-edited TOML" do
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

    # M12 §4: user-authored keys outside the descriptor allowlist raise at
    # the parse boundary instead of being silently dropped.
    assert_raise ArgumentError, ~r/unknown key\(s\): auth_mode/, fn ->
      ConfigStore.load_runtime_config()
    end
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
