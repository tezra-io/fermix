defmodule FermixCore.Setup.ConfigStore do
  @moduledoc """
  Thin persisted setup store shared by web and CLI onboarding.

  Persists the runtime snapshot to `config.toml` under `FERMIX_HOME` (or the
  default `~/.fermix`) and owns the local workspace layout used by setup,
  health reporting, traces, and logs.
  """

  alias FermixCore.Capabilities.MCP.Config, as: McpConfig
  alias FermixCore.MCP.Inbound.Config, as: InboundMcpConfig
  alias FermixCore.Memory.CompactionConfig
  alias FermixCore.Providers.ReasoningEffort
  alias FermixCore.Realtime.Config, as: RealtimeConfig
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Setup.SecretStore

  require Logger

  @workspace_dirs [
    workspace: "workspace",
    grants: "grants",
    bootstrap: "bootstrap",
    skills: "skills",
    plugins: "plugins",
    browser: "browser",
    journals: "journals",
    realtime: "realtime",
    traces: "traces",
    logs: "logs"
  ]

  @dynamic_section_fields %{
    "auth_profile" => :auth_profile,
    "client_id" => :client_id,
    "client_secret" => :client_secret,
    "client_type" => :client_type,
    "enabled" => :enabled,
    "redirect_host" => :redirect_host,
    "redirect_port" => :redirect_port,
    "scope_profile" => :scope_profile,
    "unsupported" => :unsupported
  }

  @type runtime_config :: %{
          fermix_core: keyword(),
          sandbox: keyword(),
          fermix_channels: keyword(),
          fermix_web: keyword()
        }

  @spec fermix_home() :: String.t()
  def fermix_home do
    # An empty string is truthy, so a bare `|| default` would NOT fall back —
    # it would leave fermix_home as "" and make every workspace path
    # cwd-relative (e.g. ./skills). Treat blank as unset.
    case System.get_env("FERMIX_HOME") do
      home when is_binary(home) and home != "" -> home
      _ -> Path.join(System.user_home!(), ".fermix")
    end
  end

  @spec path() :: String.t()
  def path, do: Path.join(fermix_home(), "config.toml")

  @spec workspace_paths() :: %{
          workspace: String.t(),
          grants: String.t(),
          bootstrap: String.t(),
          skills: String.t(),
          plugins: String.t(),
          browser: String.t(),
          journals: String.t(),
          realtime: String.t(),
          traces: String.t(),
          logs: String.t()
        }
  def workspace_paths do
    Enum.into(@workspace_dirs, %{}, fn {name, dir} ->
      {name, Path.join(fermix_home(), dir)}
    end)
  end

  @spec memory_paths() :: %{database_path: String.t(), prompt_base_dir: String.t()}
  def memory_paths do
    %{
      database_path: Path.join(fermix_home(), "memory.db"),
      prompt_base_dir: Path.join(fermix_home(), "memory")
    }
  end

  @spec current_snapshot() :: runtime_config()
  def current_snapshot do
    providers = Application.get_env(:fermix_core, :providers, [])

    %{
      fermix_core: [
        providers: [
          openai: Keyword.get(providers, :openai, []),
          openai_codex: Keyword.get(providers, :openai_codex, []),
          anthropic: Keyword.get(providers, :anthropic, []),
          xai: Keyword.get(providers, :xai, [])
        ],
        personalization: Application.get_env(:fermix_core, :personalization, []),
        agent: Application.get_env(:fermix_core, :agent, []),
        jobs: Application.get_env(:fermix_core, :jobs, []),
        routing: Application.get_env(:fermix_core, :routing, []),
        compaction: Application.get_env(:fermix_core, :compaction, []),
        memory: Application.get_env(:fermix_core, :memory, []),
        realtime: Application.get_env(:fermix_core, :realtime, []),
        tools: Application.get_env(:fermix_core, :tools, []),
        plugins: Application.get_env(:fermix_core, :plugins, []),
        oauth: Application.get_env(:fermix_core, :oauth, %{})
      ],
      sandbox: Application.get_env(:fermix_core, :sandbox, SandboxConfig.default()),
      fermix_channels: [
        telegram: Application.get_env(:fermix_channels, :telegram, []),
        whatsapp: Application.get_env(:fermix_channels, :whatsapp, []),
        discord: Application.get_env(:fermix_channels, :discord, []),
        slack: Application.get_env(:fermix_channels, :slack, []),
        signal: Application.get_env(:fermix_channels, :signal, [])
      ],
      fermix_web: []
    }
    |> persistable_snapshot()
  end

  @spec load_runtime_config(keyword()) :: {:ok, runtime_config()} | {:error, term()}
  def load_runtime_config(opts \\ []) do
    case File.read(path()) do
      {:ok, contents} -> {:ok, maybe_resolve_keyring(parse_document(contents), opts)}
      {:error, :enoent} -> {:ok, empty_runtime_config()}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec realtime_configured?() :: boolean()
  def realtime_configured? do
    case File.read(path()) do
      {:ok, contents} -> section_present?(contents, ["fermix_core", "realtime"])
      {:error, _reason} -> false
    end
  end

  @spec save_snapshot(runtime_config(), keyword()) :: :ok | {:error, term()}
  def save_snapshot(snapshot, opts \\ []) do
    with {:ok, persisted} <- persisted_snapshot(snapshot, opts),
         :ok <- File.mkdir_p(fermix_home()),
         :ok <- ensure_workspace(),
         :ok <- File.write(path(), dump_snapshot(persisted)) do
      :ok
    end
  end

  @spec apply_snapshot(runtime_config()) :: :ok
  def apply_snapshot(snapshot) do
    persisted =
      snapshot
      |> persistable_snapshot()
      |> SecretStore.resolve_sentinels(warn_plaintext: false)

    providers = Keyword.get(persisted.fermix_core, :providers, [])

    apply_provider_config(:openai, Keyword.get(providers, :openai, []))
    apply_provider_config(:openai_codex, Keyword.get(providers, :openai_codex, []))
    apply_provider_config(:anthropic, Keyword.get(providers, :anthropic, []))
    apply_provider_config(:xai, Keyword.get(providers, :xai, []))

    apply_personalization_config(Keyword.get(persisted.fermix_core, :personalization, []))
    apply_agent_config(Keyword.get(persisted.fermix_core, :agent, []))
    apply_jobs_config(Keyword.get(persisted.fermix_core, :jobs, []))
    apply_routing_config(Keyword.get(persisted.fermix_core, :routing, []))
    apply_compaction_config(Keyword.get(persisted.fermix_core, :compaction, []))
    apply_memory_config(Keyword.get(persisted.fermix_core, :memory, []))
    apply_realtime_config(Keyword.get(persisted.fermix_core, :realtime, []))
    apply_tools_config(Keyword.get(persisted.fermix_core, :tools, []))
    apply_plugins_config(Keyword.get(persisted.fermix_core, :plugins, []))
    apply_oauth_config(Keyword.get(persisted.fermix_core, :oauth, %{}))
    apply_sandbox_config(Map.get(persisted, :sandbox, SandboxConfig.default()))

    apply_channel_config(:telegram, Keyword.get(persisted.fermix_channels, :telegram, []))
    apply_channel_config(:whatsapp, Keyword.get(persisted.fermix_channels, :whatsapp, []))
    apply_channel_config(:discord, Keyword.get(persisted.fermix_channels, :discord, []))
    apply_channel_config(:slack, Keyword.get(persisted.fermix_channels, :slack, []))
    apply_channel_config(:signal, Keyword.get(persisted.fermix_channels, :signal, []))
  end

  @doc """
  Hydrates Application env from the persisted runtime snapshot.

  Single entry point for boot-time config loading: `runtime.exs` calls this
  before layering env-var overrides on top. Any key added to
  `persistable_snapshot/1` and `apply_snapshot/1` is automatically
  propagated to Application env at boot — no per-key wiring in
  `runtime.exs` is required.

  Missing TOML returns `:ok` (the in-memory defaults from
  `empty_runtime_config/0` apply, which normalize to no-op merges).
  Malformed TOML returns `{:error, reason}` so boot can surface the
  problem rather than silently start with stale defaults.
  """
  @spec bootstrap_runtime_config() :: :ok | {:error, term()}
  def bootstrap_runtime_config do
    with {:ok, snapshot} <- load_runtime_config(),
         :ok <- apply_snapshot(snapshot) do
      apply_mcp_config()
    end
  end

  @spec apply_mcp_config() :: :ok | {:error, term()}
  def apply_mcp_config do
    case File.read(path()) do
      {:ok, contents} ->
        servers = McpConfig.from_toml(contents)
        inbound = InboundMcpConfig.from_toml(contents)
        Application.put_env(:fermix_core, :mcp_servers, servers)
        Application.put_env(:fermix_core, :mcp_inbound, inbound)
        :ok

      {:error, :enoent} ->
        Application.put_env(:fermix_core, :mcp_servers, [])
        Application.put_env(:fermix_core, :mcp_inbound, InboundMcpConfig.default())
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec persistable_snapshot(runtime_config()) :: runtime_config()
  def persistable_snapshot(snapshot) do
    providers =
      snapshot
      |> Map.get(:fermix_core, [])
      |> Keyword.get(:providers, [])

    %{
      fermix_core: [
        providers: [
          openai: providers |> Keyword.get(:openai, []) |> normalize_openai(),
          openai_codex: providers |> Keyword.get(:openai_codex, []) |> normalize_openai_codex(),
          anthropic: providers |> Keyword.get(:anthropic, []) |> normalize_anthropic(),
          xai: providers |> Keyword.get(:xai, []) |> normalize_xai()
        ],
        personalization:
          snapshot
          |> Map.get(:fermix_core, [])
          |> Keyword.get(:personalization, [])
          |> normalize_personalization(),
        agent:
          snapshot
          |> Map.get(:fermix_core, [])
          |> Keyword.get(:agent, [])
          |> normalize_agent(),
        jobs:
          snapshot
          |> Map.get(:fermix_core, [])
          |> Keyword.get(:jobs, [])
          |> normalize_jobs(),
        routing:
          snapshot
          |> Map.get(:fermix_core, [])
          |> Keyword.get(:routing, [])
          |> normalize_routing(),
        compaction:
          snapshot
          |> Map.get(:fermix_core, [])
          |> Keyword.get(:compaction, [])
          |> normalize_compaction(),
        memory:
          snapshot
          |> Map.get(:fermix_core, [])
          |> Keyword.get(:memory, [])
          |> normalize_memory(),
        realtime:
          snapshot
          |> Map.get(:fermix_core, [])
          |> Keyword.get(:realtime, [])
          |> normalize_realtime(),
        tools:
          snapshot
          |> Map.get(:fermix_core, [])
          |> Keyword.get(:tools, [])
          |> normalize_tools(),
        plugins:
          snapshot
          |> Map.get(:fermix_core, [])
          |> Keyword.get(:plugins, [])
          |> normalize_plugins(),
        oauth:
          snapshot
          |> Map.get(:fermix_core, [])
          |> Keyword.get(:oauth, %{})
          |> normalize_oauth()
      ],
      sandbox:
        snapshot
        |> Map.get(:sandbox, SandboxConfig.default())
        |> SandboxConfig.to_keyword(),
      fermix_channels: [
        telegram:
          snapshot
          |> Map.get(:fermix_channels, [])
          |> Keyword.get(:telegram, [])
          |> normalize_telegram(),
        whatsapp:
          snapshot
          |> Map.get(:fermix_channels, [])
          |> Keyword.get(:whatsapp, [])
          |> normalize_whatsapp(),
        discord:
          snapshot
          |> Map.get(:fermix_channels, [])
          |> Keyword.get(:discord, [])
          |> normalize_discord(),
        slack:
          snapshot
          |> Map.get(:fermix_channels, [])
          |> Keyword.get(:slack, [])
          |> normalize_slack(),
        signal:
          snapshot
          |> Map.get(:fermix_channels, [])
          |> Keyword.get(:signal, [])
          |> normalize_signal()
      ],
      fermix_web: []
    }
  end

  @spec ensure_workspace() :: :ok | {:error, term()}
  def ensure_workspace do
    result =
      Enum.reduce_while(Map.values(workspace_paths()), :ok, fn path, :ok ->
        case File.mkdir_p(path) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    result
  end

  defp empty_runtime_config do
    %{
      fermix_core: [
        providers: [openai: [], openai_codex: [], anthropic: [], xai: []],
        personalization: [user_name: nil, timezone: nil, communication_style: nil],
        agent: [name: "fermix"],
        jobs: [],
        routing: [],
        compaction: [],
        memory: [],
        realtime: [],
        tools: [],
        plugins: [],
        oauth: %{}
      ],
      sandbox: SandboxConfig.default(),
      fermix_channels: [telegram: [], whatsapp: [], discord: [], slack: [], signal: []],
      fermix_web: []
    }
  end

  defp maybe_resolve_keyring(snapshot, opts) do
    if Keyword.get(opts, :resolve_secrets, true) do
      SecretStore.resolve_sentinels(snapshot, warn_plaintext: true)
    else
      snapshot
    end
  end

  defp persisted_snapshot(snapshot, opts) do
    persistable = persistable_snapshot(snapshot)

    if Keyword.get(opts, :secure_secrets, true) do
      SecretStore.secure_snapshot(persistable, previous: existing_persisted_snapshot())
    else
      {:ok, persistable}
    end
  end

  defp existing_persisted_snapshot do
    case load_runtime_config(resolve_secrets: false) do
      {:ok, persisted} -> persisted
      {:error, _reason} -> nil
    end
  end

  defp apply_provider_config(provider, config) do
    providers = Application.get_env(:fermix_core, :providers, [])
    merged = Keyword.merge(Keyword.get(providers, provider, []), config)
    Application.put_env(:fermix_core, :providers, Keyword.put(providers, provider, merged))
    :ok
  end

  defp apply_personalization_config(personalization_config) do
    merged =
      Application.get_env(:fermix_core, :personalization, [])
      |> Keyword.merge(personalization_config)

    Application.put_env(:fermix_core, :personalization, merged)
    :ok
  end

  defp apply_agent_config(agent_config) do
    merged =
      Application.get_env(:fermix_core, :agent, [])
      |> Keyword.merge(agent_config)

    Application.put_env(:fermix_core, :agent, merged)
    :ok
  end

  defp apply_jobs_config(jobs_config) do
    merged =
      Application.get_env(:fermix_core, :jobs, [])
      |> Keyword.merge(jobs_config)

    Application.put_env(:fermix_core, :jobs, merged)
    :ok
  end

  defp apply_routing_config(routing_config) do
    Application.put_env(:fermix_core, :routing, routing_config)
    :ok
  end

  defp apply_compaction_config(compaction_config) do
    Application.put_env(:fermix_core, :compaction, compaction_config)
    :ok
  end

  # Memory uses merge (not put) so other in-process keys (extraction_enabled,
  # agent_id, prompt_*_token_cap, loop_detection_*) survive partial TOML edits.
  defp apply_memory_config(memory_config) do
    merged =
      Application.get_env(:fermix_core, :memory, [])
      |> Keyword.merge(memory_config)

    Application.put_env(:fermix_core, :memory, merged)
    :ok
  end

  defp apply_realtime_config(realtime_config) do
    merged =
      Application.get_env(:fermix_core, :realtime, [])
      |> Keyword.merge(realtime_config)

    Application.put_env(:fermix_core, :realtime, merged)
    :ok
  end

  defp apply_tools_config(tools_config) do
    Application.put_env(:fermix_core, :tools, tools_config)
    :ok
  end

  defp apply_plugins_config(plugins_config) do
    Application.put_env(:fermix_core, :plugins, plugins_config)
    :ok
  end

  defp apply_oauth_config(oauth_config) do
    Application.put_env(:fermix_core, :oauth, oauth_config)
    :ok
  end

  defp apply_sandbox_config(sandbox_config) do
    Application.put_env(:fermix_core, :sandbox, SandboxConfig.normalize(sandbox_config))
    :ok
  end

  defp apply_channel_config(channel, channel_config) do
    merged =
      Application.get_env(:fermix_channels, channel, [])
      |> Keyword.merge(channel_config)

    Application.put_env(:fermix_channels, channel, merged)
    :ok
  end

  defp dump_snapshot(snapshot) do
    fermix_core = Map.get(snapshot, :fermix_core, [])
    providers = Keyword.get(fermix_core, :providers, [])
    personalization = Keyword.get(fermix_core, :personalization, [])
    agent = Keyword.get(fermix_core, :agent, [])
    jobs = Keyword.get(fermix_core, :jobs, [])
    routing = Keyword.get(fermix_core, :routing, [])
    compaction = Keyword.get(fermix_core, :compaction, [])
    memory = Keyword.get(fermix_core, :memory, [])
    realtime = Keyword.get(fermix_core, :realtime, [])
    tools = Keyword.get(fermix_core, :tools, [])
    plugins = Keyword.get(fermix_core, :plugins, [])
    oauth = Keyword.get(fermix_core, :oauth, %{})
    sandbox = Map.get(snapshot, :sandbox, [])
    channels = Map.get(snapshot, :fermix_channels, [])

    [
      "# Managed by mix fermix.setup",
      "# Built-in tools ship inside Fermix and are always available when registered.",
      "# Skills are separate SKILL.md directories under ~/.fermix/skills and plugin roots.",
      render_section(["fermix_core", "agent"], agent),
      render_section(
        ["fermix_core", "providers", "openai"],
        Keyword.get(providers, :openai, [])
      ),
      render_section(
        ["fermix_core", "providers", "openai_codex"],
        Keyword.get(providers, :openai_codex, [])
      ),
      render_section(
        ["fermix_core", "providers", "anthropic"],
        Keyword.get(providers, :anthropic, [])
      ),
      render_section(
        ["fermix_core", "providers", "xai"],
        Keyword.get(providers, :xai, [])
      ),
      render_section(["fermix_core", "personalization"], personalization),
      render_section(["fermix_core", "jobs"], Keyword.drop(jobs, [:default_delivery_target])),
      render_section(
        ["fermix_core", "jobs", "default_delivery_target"],
        Keyword.get(jobs, :default_delivery_target, [])
      ),
      render_section(["fermix_core", "routing"], routing),
      render_section(["fermix_core", "compaction"], compaction),
      render_section(["fermix_core", "memory"], memory),
      render_section(["fermix_core", "realtime"], realtime),
      render_section(["fermix_core", "tools", "web_search"], Keyword.get(tools, :web_search, [])),
      render_plugins(plugins),
      render_oauth(oauth),
      render_sandbox(sandbox),
      render_section(["fermix_channels", "telegram"], Keyword.get(channels, :telegram, [])),
      render_section(["fermix_channels", "whatsapp"], Keyword.get(channels, :whatsapp, [])),
      render_section(["fermix_channels", "discord"], Keyword.get(channels, :discord, [])),
      render_section(["fermix_channels", "slack"], Keyword.get(channels, :slack, [])),
      render_section(["fermix_channels", "signal"], Keyword.get(channels, :signal, []))
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  defp section_present?(contents, path) do
    header = "[#{Enum.join(path, ".")}]"

    contents
    |> String.split("\n")
    |> Enum.any?(&(String.trim(&1) == header))
  end

  defp render_section(_path, []), do: nil

  defp render_section(path, values) do
    header = "[#{Enum.join(path, ".")}]"

    body =
      Enum.map(values, fn {key, value} ->
        "#{key} = #{encode_value(value)}"
      end)
      |> Enum.join("\n")

    Enum.join([header, body], "\n")
  end

  defp render_plugins([]), do: nil

  defp render_plugins(plugins) when is_list(plugins) do
    entries = Keyword.get(plugins, :entries, %{})

    [
      render_section(["fermix_core", "plugins"], Keyword.drop(plugins, [:entries])),
      render_named_sections(["fermix_core", "plugins"], entries)
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp render_oauth(oauth) when oauth in [%{}, []], do: nil

  defp render_oauth(oauth) when is_map(oauth) or is_list(oauth) do
    render_named_sections(["fermix_core", "oauth"], oauth)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp render_named_sections(parent, entries) when is_map(entries) do
    entries
    |> Enum.sort_by(fn {name, _values} -> name end)
    |> Enum.map(fn {name, values} -> render_section(parent ++ [name], values) end)
  end

  defp render_named_sections(parent, entries) when is_list(entries) do
    entries
    |> Enum.sort_by(fn {name, _values} -> to_string(name) end)
    |> Enum.map(fn {name, values} -> render_section(parent ++ [to_string(name)], values) end)
  end

  defp render_sandbox([]), do: nil

  defp render_sandbox(sandbox) do
    config = SandboxConfig.normalize(sandbox)

    [
      render_section(["sandbox"],
        mode: config.mode,
        workspace_root: config.workspace_root,
        allowed_roots: config.allowed_roots,
        blocked_roots: config.blocked_roots
      ),
      render_section(["sandbox", "env"],
        mode: config.env.mode,
        allow: config.env.allow,
        deny: config.env.deny
      ),
      render_env_sources(config.env.sources),
      render_section(["sandbox", "commands"],
        profile: config.commands.profile,
        presets: config.commands.presets
      ),
      render_command_specs(config.commands.explicit)
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp render_env_sources(sources) do
    Enum.map(sources, fn {name, source} ->
      values =
        source
        |> Map.to_list()
        |> Enum.reject(fn {_key, value} -> value in [nil, []] end)

      render_section(["sandbox", "env", name], values)
    end)
  end

  defp render_command_specs(commands) do
    Enum.map(commands, fn {name, spec} ->
      values =
        spec
        |> Map.to_list()
        |> Enum.reject(fn {_key, value} -> value in [nil, []] end)

      render_section(["sandbox", "commands", name], values)
    end)
  end

  defp encode_value(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"#{escaped}\""
  end

  defp encode_value(value) when is_boolean(value), do: to_string(value)
  defp encode_value(value) when is_float(value), do: :erlang.float_to_binary(value, [:short])
  defp encode_value(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_value(value) when is_atom(value), do: encode_value(Atom.to_string(value))

  defp encode_value(value) when is_list(value) do
    "[#{value |> Enum.map(&encode_value/1) |> Enum.join(", ")}]"
  end

  defp parse_document(contents) do
    document =
      contents
      |> String.split("\n")
      |> Enum.reduce({[], %{}}, fn raw_line, {section, acc} ->
        line = String.trim(raw_line)

        cond do
          line == "" or String.starts_with?(line, "#") ->
            {section, acc}

          String.starts_with?(line, "[") and String.ends_with?(line, "]") ->
            path =
              line
              |> String.trim_leading("[")
              |> String.trim_trailing("]")
              |> String.split(".")

            {path, acc}

          String.contains?(line, "=") ->
            [key, value] = String.split(line, "=", parts: 2)
            {section, put_value(acc, section, String.trim(key), parse_value(String.trim(value)))}

          true ->
            {section, acc}
        end
      end)
      |> elem(1)

    %{
      fermix_core: [
        providers: [
          openai: normalize_openai(get_in(document, ["fermix_core", "providers", "openai"])),
          openai_codex:
            normalize_openai_codex(get_in(document, ["fermix_core", "providers", "openai_codex"])),
          anthropic:
            normalize_anthropic(get_in(document, ["fermix_core", "providers", "anthropic"])),
          xai: normalize_xai(get_in(document, ["fermix_core", "providers", "xai"]))
        ],
        personalization:
          normalize_personalization(get_in(document, ["fermix_core", "personalization"])),
        agent: normalize_agent(get_in(document, ["fermix_core", "agent"])),
        jobs: normalize_jobs(get_in(document, ["fermix_core", "jobs"])),
        routing: normalize_routing(get_in(document, ["fermix_core", "routing"])),
        compaction: normalize_compaction(get_in(document, ["fermix_core", "compaction"])),
        memory: normalize_memory(get_in(document, ["fermix_core", "memory"])),
        realtime: normalize_realtime(get_in(document, ["fermix_core", "realtime"])),
        tools: normalize_tools(get_in(document, ["fermix_core", "tools"])),
        plugins: normalize_plugins(get_in(document, ["fermix_core", "plugins"])),
        oauth: normalize_oauth(get_in(document, ["fermix_core", "oauth"]))
      ],
      sandbox: SandboxConfig.normalize(Map.get(document, "sandbox")),
      fermix_channels: [
        telegram: normalize_telegram(get_in(document, ["fermix_channels", "telegram"])),
        whatsapp: normalize_whatsapp(get_in(document, ["fermix_channels", "whatsapp"])),
        discord: normalize_discord(get_in(document, ["fermix_channels", "discord"])),
        slack: normalize_slack(get_in(document, ["fermix_channels", "slack"])),
        signal: normalize_signal(get_in(document, ["fermix_channels", "signal"]))
      ],
      fermix_web: []
    }
  end

  defp put_value(document, [], key, value), do: Map.put(document, key, value)

  defp put_value(document, [section | rest], key, value) do
    Map.update(document, section, put_value(%{}, rest, key, value), fn existing ->
      put_value(existing, rest, key, value)
    end)
  end

  defp parse_value("true"), do: true
  defp parse_value("false"), do: false

  defp parse_value(value) do
    cond do
      wrapped?(value, "\"", "\"") ->
        parse_quoted_value(value)

      wrapped?(value, "[", "]") ->
        parse_list_value(value)

      Regex.match?(~r/^\d+$/, value) ->
        String.to_integer(value)

      Regex.match?(~r/^-?\d+\.\d+$/, value) ->
        parse_float_value(value)

      true ->
        value
    end
  end

  defp parse_quoted_value(value) do
    value
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end

  defp parse_list_value(value) do
    value
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split(",", trim: true)
    |> Enum.map(&parse_value(String.trim(&1)))
  end

  defp parse_float_value(value) do
    {float, ""} = Float.parse(value)
    float
  end

  defp wrapped?(value, left, right) do
    String.starts_with?(value, left) and String.ends_with?(value, right)
  end

  defp normalize_openai(nil), do: []

  defp normalize_openai(config) do
    if has_provider_key?(config), do: raise_old_provider_layout!()

    []
    |> put_if_present(:api_key, normalize_string(lookup(config, "api_key", :api_key)))
    |> put_if_present(
      :default_model,
      normalize_string(lookup(config, "default_model", :default_model))
    )
    |> put_if_present(
      :reasoning_effort,
      normalize_reasoning_effort(lookup(config, "reasoning_effort", :reasoning_effort))
    )
  end

  defp normalize_openai_codex(nil), do: []

  defp normalize_openai_codex(config) do
    []
    |> put_if_present(
      :default_model,
      normalize_string(lookup(config, "default_model", :default_model))
    )
    |> put_if_present(
      :reasoning_effort,
      normalize_reasoning_effort(lookup(config, "reasoning_effort", :reasoning_effort))
    )
    |> put_if_present(:fast, normalize_bool(lookup(config, "fast", :fast)))
  end

  defp normalize_anthropic(nil), do: []

  defp normalize_anthropic(config) do
    []
    |> put_if_present(:auth_mode, normalize_auth_mode(lookup(config, "auth_mode", :auth_mode)))
    |> put_if_present(:api_key, normalize_string(lookup(config, "api_key", :api_key)))
    |> put_if_present(
      :default_model,
      normalize_string(lookup(config, "default_model", :default_model))
    )
  end

  defp normalize_xai(nil), do: []

  defp normalize_xai(config) do
    []
    |> put_if_present(:auth_mode, normalize_auth_mode(lookup(config, "auth_mode", :auth_mode)))
    |> put_if_present(:api_key, normalize_string(lookup(config, "api_key", :api_key)))
    |> put_if_present(:base_url, normalize_string(lookup(config, "base_url", :base_url)))
    |> put_if_present(
      :default_model,
      normalize_string(lookup(config, "default_model", :default_model))
    )
    |> put_if_present(
      :reasoning_effort,
      normalize_reasoning_effort(lookup(config, "reasoning_effort", :reasoning_effort))
    )
  end

  defp normalize_realtime(config) do
    config
    |> RealtimeConfig.normalize()
    |> RealtimeConfig.to_keyword()
  end

  defp normalize_tools(nil), do: []

  defp normalize_tools(config) when is_map(config) or is_list(config) do
    []
    |> put_if_present(
      :web_search,
      normalize_web_search_tool(lookup(config, "web_search", :web_search))
    )
  end

  defp normalize_tools(_config), do: []

  defp normalize_plugins(nil), do: []

  defp normalize_plugins(config) when is_map(config) or is_list(config) do
    enabled = normalize_string_list(lookup(config, "enabled", :enabled))

    entries =
      config
      |> lookup("entries", :entries)
      |> normalize_named_sections([])
      |> Map.merge(normalize_named_sections(config, ["enabled", :enabled, "entries", :entries]))

    []
    |> put_if_present(:enabled, enabled)
    |> put_if_present(:entries, entries)
  end

  defp normalize_plugins(_config), do: []

  defp normalize_oauth(nil), do: %{}

  defp normalize_oauth(config) when is_map(config) or is_list(config),
    do: normalize_named_sections(config, [])

  defp normalize_oauth(_config), do: %{}

  defp normalize_named_sections(nil, _ignored_keys), do: %{}

  defp normalize_named_sections(config, ignored_keys) when is_map(config) do
    ignored = MapSet.new(Enum.map(ignored_keys, &to_string/1))

    config
    |> Enum.reject(fn {key, _value} -> MapSet.member?(ignored, to_string(key)) end)
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), normalize_named_section(value)} end)
  end

  defp normalize_named_sections(config, ignored_keys) when is_list(config) do
    ignored = MapSet.new(ignored_keys)

    config
    |> Enum.reject(fn {key, _value} -> MapSet.member?(ignored, key) end)
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), normalize_named_section(value)} end)
  end

  defp normalize_named_section(values) when is_map(values) do
    values
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> {to_field_atom(key), value} end)
  end

  defp normalize_named_section(values) when is_list(values) do
    Enum.map(values, fn {key, value} -> {to_field_atom(key), value} end)
  end

  defp normalize_named_section(_values), do: []

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_string_list(_values), do: nil

  defp normalize_web_search_tool(nil), do: []

  defp normalize_web_search_tool(config) when is_map(config) or is_list(config) do
    []
    |> put_if_present(:backend, normalize_web_search_backend(lookup(config, "backend", :backend)))
    |> put_if_present(
      :tavily_api_key,
      normalize_string(lookup(config, "tavily_api_key", :tavily_api_key))
    )
    |> put_if_present(
      :exa_api_key,
      normalize_string(lookup(config, "exa_api_key", :exa_api_key))
    )
    |> put_if_present(
      :parallel_api_key,
      normalize_string(lookup(config, "parallel_api_key", :parallel_api_key))
    )
    |> put_if_present(
      :brave_api_key,
      normalize_string(lookup(config, "brave_api_key", :brave_api_key))
    )
    |> put_if_present(
      :perplexity_api_key,
      normalize_string(lookup(config, "perplexity_api_key", :perplexity_api_key))
    )
  end

  defp normalize_web_search_tool(_config), do: []

  defp normalize_web_search_backend(nil), do: nil
  defp normalize_web_search_backend(:duckduckgo), do: :duckduckgo
  defp normalize_web_search_backend(:tavily), do: :tavily
  defp normalize_web_search_backend(:exa), do: :exa
  defp normalize_web_search_backend(:parallel), do: :parallel
  defp normalize_web_search_backend(:brave), do: :brave
  defp normalize_web_search_backend(:perplexity), do: :perplexity
  defp normalize_web_search_backend("duckduckgo"), do: :duckduckgo
  defp normalize_web_search_backend("tavily"), do: :tavily
  defp normalize_web_search_backend("exa"), do: :exa
  defp normalize_web_search_backend("parallel"), do: :parallel
  defp normalize_web_search_backend("brave"), do: :brave
  defp normalize_web_search_backend("perplexity"), do: :perplexity
  defp normalize_web_search_backend(_value), do: nil

  # Canonical enum + per-provider mapping live in ReasoningEffort.
  # Returns the atom on success, or nil on unknown input — consistent
  # with the rest of this module (normalize_auth_mode, normalize_mode).
  # Hand-edited TOML with an invalid effort silently drops to nil; the
  # wizard never writes an invalid value, and route_resolver still
  # validates at the public boundary, so misconfig surfaces cleanly.
  # `minimal` (removed from the enum) migrates up to `low` so an upgrade
  # with a persisted `minimal` keeps working instead of dropping to nil.
  defp normalize_reasoning_effort(nil), do: nil

  defp normalize_reasoning_effort(value) do
    case value |> migrate_reasoning_effort() |> ReasoningEffort.parse() do
      {:ok, level} -> level
      :error -> nil
    end
  end

  defp migrate_reasoning_effort(value) when value in [:minimal, "minimal"], do: :low
  defp migrate_reasoning_effort(value), do: value

  defp normalize_bool(value) when is_boolean(value), do: value
  defp normalize_bool(_value), do: nil

  defp has_provider_key?(config) when is_map(config) do
    Map.has_key?(config, "provider") or Map.has_key?(config, :provider)
  end

  defp has_provider_key?(config) when is_list(config) do
    Keyword.has_key?(config, :provider)
  end

  defp has_provider_key?(_), do: false

  defp raise_old_provider_layout! do
    raise """
    config.toml has `provider = ...` under [fermix_core.providers.openai].

    M4.10 moved provider selection to [fermix_core.agent]. Edit ~/.fermix/config.toml:

        [fermix_core.agent]
        provider = "openai_codex"   # or "openai" or "anthropic"

    and remove the `provider` key from the [fermix_core.providers.openai] block.
    The daemon will not boot until this is fixed.
    """
  end

  defp normalize_provider(nil), do: nil
  defp normalize_provider(:openai), do: :openai
  defp normalize_provider(:openai_codex), do: :openai_codex
  defp normalize_provider(:anthropic), do: :anthropic
  defp normalize_provider(:xai), do: :xai
  defp normalize_provider("openai"), do: :openai
  defp normalize_provider("openai_codex"), do: :openai_codex
  defp normalize_provider("anthropic"), do: :anthropic
  defp normalize_provider("xai"), do: :xai
  defp normalize_provider(_), do: nil

  defp normalize_personalization(nil), do: []

  defp normalize_personalization(config) do
    []
    |> put_if_present(:user_name, normalize_string(lookup(config, "user_name", :user_name)))
    |> put_if_present(:timezone, normalize_string(lookup(config, "timezone", :timezone)))
    |> put_if_present(
      :communication_style,
      normalize_string(lookup(config, "communication_style", :communication_style))
    )
  end

  defp normalize_agent(nil), do: []

  defp normalize_agent(config) do
    []
    |> put_if_present(:name, normalize_string(lookup(config, "name", :name)))
    |> put_if_present(:provider, normalize_provider(lookup(config, "provider", :provider)))
  end

  defp normalize_jobs(nil), do: []

  defp normalize_jobs(config) do
    []
    |> put_if_present(
      :default_delivery_mode,
      normalize_delivery_mode(lookup(config, "default_delivery_mode", :default_delivery_mode))
    )
    |> put_if_present(
      :default_delivery_target,
      normalize_default_delivery_target(
        lookup(config, "default_delivery_target", :default_delivery_target)
      )
    )
  end

  defp normalize_routing(nil), do: []

  defp normalize_routing(config) do
    []
    |> put_if_present(
      :default_provider,
      normalize_string(lookup(config, "default_provider", :default_provider))
    )
    |> put_if_present(
      :default_model,
      normalize_string(lookup(config, "default_model", :default_model))
    )
    |> put_if_present(
      :coding_model,
      normalize_string(lookup(config, "coding_model", :coding_model))
    )
    |> put_if_present(
      :research_model,
      normalize_string(lookup(config, "research_model", :research_model))
    )
    |> put_if_present(
      :review_model,
      normalize_string(lookup(config, "review_model", :review_model))
    )
  end

  defp normalize_compaction(config), do: CompactionConfig.normalize(config)

  defp normalize_memory(nil), do: []

  defp normalize_memory(config) when is_map(config) or is_list(config) do
    []
    |> put_if_present(
      :extraction_timeout_ms,
      normalize_extraction_timeout_ms(
        lookup(config, "extraction_timeout_ms", :extraction_timeout_ms)
      )
    )
    |> put_if_present(
      :review_interval_hours,
      normalize_non_negative_integer(
        lookup(config, "review_interval_hours", :review_interval_hours),
        :review_interval_hours
      )
    )
    |> put_if_present(
      :review_max_messages,
      normalize_positive_memory_integer(
        lookup(config, "review_max_messages", :review_max_messages),
        :review_max_messages
      )
    )
    |> put_if_present(
      :review_input_token_budget,
      normalize_positive_memory_integer(
        lookup(config, "review_input_token_budget", :review_input_token_budget),
        :review_input_token_budget
      )
    )
    |> put_if_present(
      :review_failure_backoff_ms,
      normalize_non_negative_integer(
        lookup(config, "review_failure_backoff_ms", :review_failure_backoff_ms),
        :review_failure_backoff_ms
      )
    )
  end

  defp normalize_extraction_timeout_ms(nil), do: nil

  defp normalize_extraction_timeout_ms(value) when is_integer(value) and value > 0, do: value

  defp normalize_extraction_timeout_ms(value) do
    raise ArgumentError,
          "invalid memory.extraction_timeout_ms #{inspect(value)}; expected positive integer milliseconds"
  end

  defp normalize_positive_memory_integer(nil, _key), do: nil

  defp normalize_positive_memory_integer(value, _key) when is_integer(value) and value > 0,
    do: value

  defp normalize_positive_memory_integer(value, key) do
    raise ArgumentError,
          "invalid memory.#{key} #{inspect(value)}; expected positive integer"
  end

  defp normalize_non_negative_integer(nil, _key), do: nil

  defp normalize_non_negative_integer(value, _key) when is_integer(value) and value >= 0,
    do: value

  defp normalize_non_negative_integer(value, key) do
    raise ArgumentError,
          "invalid memory.#{key} #{inspect(value)}; expected non-negative integer"
  end

  defp normalize_delivery_mode(:none), do: "none"
  defp normalize_delivery_mode(:origin), do: "origin"
  defp normalize_delivery_mode(:channel), do: "channel"
  defp normalize_delivery_mode(:local), do: "local"
  defp normalize_delivery_mode("none"), do: "none"
  defp normalize_delivery_mode("origin"), do: "origin"
  defp normalize_delivery_mode("channel"), do: "channel"
  defp normalize_delivery_mode("local"), do: "local"
  defp normalize_delivery_mode(_value), do: nil

  defp normalize_default_delivery_target(nil), do: nil

  defp normalize_default_delivery_target(target) when is_map(target) or is_list(target) do
    [
      platform: normalize_string(lookup(target, "platform", :platform)),
      channel: normalize_string(lookup(target, "channel", :channel)),
      chat_id: normalize_string(lookup(target, "chat_id", :chat_id)),
      reply_target: normalize_string(lookup(target, "reply_target", :reply_target)),
      target: normalize_string(lookup(target, "target", :target)),
      recipient: normalize_string(lookup(target, "recipient", :recipient)),
      channel_id: normalize_string(lookup(target, "channel_id", :channel_id)),
      thread_ts: normalize_string(lookup(target, "thread_ts", :thread_ts)),
      message_thread_id:
        normalize_string(lookup(target, "message_thread_id", :message_thread_id)),
      reply_to: normalize_string(lookup(target, "reply_to", :reply_to))
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> case do
      [] -> nil
      values -> values
    end
  end

  defp normalize_default_delivery_target(_target), do: nil

  defp normalize_telegram(nil), do: []

  defp normalize_telegram(config) do
    []
    |> put_if_present(:enabled, lookup(config, "enabled", :enabled))
    |> put_if_present(:mode, normalize_mode(lookup(config, "mode", :mode)))
    |> put_if_present(:bot_token, normalize_string(lookup(config, "bot_token", :bot_token)))
    |> put_command_auth(config)
    |> put_ids_if_present(
      :allowed_user_ids,
      lookup(config, "allowed_user_ids", :allowed_user_ids)
    )
  end

  defp normalize_whatsapp(nil), do: []

  defp normalize_whatsapp(config) do
    []
    |> put_if_present(:enabled, lookup(config, "enabled", :enabled))
    |> put_if_present(:mode, normalize_mode(lookup(config, "mode", :mode)))
    |> put_if_present(
      :access_token,
      normalize_string(lookup(config, "access_token", :access_token))
    )
    |> put_if_present(
      :phone_number_id,
      normalize_string(lookup(config, "phone_number_id", :phone_number_id))
    )
    |> put_if_present(
      :verify_token,
      normalize_string(lookup(config, "verify_token", :verify_token))
    )
    |> put_if_present(:app_secret, normalize_string(lookup(config, "app_secret", :app_secret)))
    |> put_command_auth(config)
    |> put_ids_if_present(
      :allowed_sender_ids,
      lookup(config, "allowed_sender_ids", :allowed_sender_ids)
    )
  end

  defp normalize_discord(nil), do: []

  defp normalize_discord(config) do
    []
    |> put_if_present(:enabled, lookup(config, "enabled", :enabled))
    |> put_if_present(:mode, normalize_mode(lookup(config, "mode", :mode)))
    |> put_if_present(:bot_token, normalize_string(lookup(config, "bot_token", :bot_token)))
    |> put_if_present(:bot_user_id, normalize_string(lookup(config, "bot_user_id", :bot_user_id)))
    |> put_command_auth(config)
    |> put_ids_if_present(
      :allowed_user_ids,
      lookup(config, "allowed_user_ids", :allowed_user_ids)
    )
  end

  defp normalize_slack(nil), do: []

  defp normalize_slack(config) do
    []
    |> put_if_present(:enabled, lookup(config, "enabled", :enabled))
    |> put_if_present(:mode, normalize_mode(lookup(config, "mode", :mode)))
    |> put_if_present(:bot_token, normalize_string(lookup(config, "bot_token", :bot_token)))
    |> put_if_present(
      :signing_secret,
      normalize_string(lookup(config, "signing_secret", :signing_secret))
    )
    |> put_command_auth(config)
    |> put_ids_if_present(
      :allowed_user_ids,
      lookup(config, "allowed_user_ids", :allowed_user_ids)
    )
  end

  defp normalize_signal(nil), do: []

  defp normalize_signal(config) do
    []
    |> put_if_present(:enabled, lookup(config, "enabled", :enabled))
    |> put_if_present(:mode, normalize_mode(lookup(config, "mode", :mode)))
    |> put_if_present(:account, normalize_string(lookup(config, "account", :account)))
    |> put_if_present(:cli_path, normalize_string(lookup(config, "cli_path", :cli_path)))
    |> put_command_auth(config)
    |> put_ids_if_present(
      :allowed_sender_ids,
      lookup(config, "allowed_sender_ids", :allowed_sender_ids)
    )
  end

  defp normalize_auth_mode(:api_key), do: :api_key
  defp normalize_auth_mode("api_key"), do: :api_key
  defp normalize_auth_mode(:oauth), do: :oauth
  defp normalize_auth_mode("oauth"), do: :oauth
  defp normalize_auth_mode(_value), do: nil

  defp normalize_mode(:polling), do: :polling
  defp normalize_mode(:webhook), do: :webhook
  defp normalize_mode(:gateway), do: :gateway
  defp normalize_mode(:subprocess), do: :subprocess
  defp normalize_mode("polling"), do: :polling
  defp normalize_mode("webhook"), do: :webhook
  defp normalize_mode("gateway"), do: :gateway
  defp normalize_mode("subprocess"), do: :subprocess
  defp normalize_mode(_value), do: nil

  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(_value), do: nil

  defp normalize_ids(ids) when is_list(ids), do: ids
  defp normalize_ids(_ids), do: []

  defp put_command_auth(keyword, config) do
    keyword
    |> put_if_present(
      :owner_user_id,
      normalize_string(lookup(config, "owner_user_id", :owner_user_id))
    )
    |> put_command_allowlist(config)
  end

  defp put_command_allowlist(keyword, config) do
    case lookup(config, "command_allowlist", :command_allowlist) do
      nil -> keyword
      ids -> Keyword.put(keyword, :command_allowlist, normalize_ids(ids))
    end
  end

  defp put_ids_if_present(keyword, _key, nil), do: keyword
  defp put_ids_if_present(keyword, key, ids), do: Keyword.put(keyword, key, normalize_ids(ids))

  defp lookup(config, string_key, atom_key) when is_map(config) do
    Map.get(config, string_key, Map.get(config, atom_key))
  end

  defp lookup(config, _string_key, atom_key) when is_list(config) do
    Keyword.get(config, atom_key)
  end

  defp to_field_atom(key) when is_atom(key), do: key
  defp to_field_atom(key) when is_binary(key), do: Map.get(@dynamic_section_fields, key, key)

  defp put_if_present(keyword, _key, nil), do: keyword
  defp put_if_present(keyword, key, value), do: Keyword.put(keyword, key, value)
end
