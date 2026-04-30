defmodule FermixCore.Setup.ConfigStore do
  @moduledoc """
  Thin persisted setup store shared by web and CLI onboarding.

  Persists the runtime snapshot to `config.toml` under `FERMIX_HOME` (or the
  default `~/.fermix`) and owns the local workspace layout used by setup,
  health reporting, traces, and logs.
  """

  alias FermixCore.Capabilities.MCP.Config, as: McpConfig

  @workspace_dirs [
    bootstrap: "bootstrap",
    skills: "skills",
    journals: "journals",
    traces: "traces",
    logs: "logs"
  ]

  @type runtime_config :: %{
          fermix_core: keyword(),
          fermix_channels: keyword(),
          fermix_web: keyword()
        }

  @spec fermix_home() :: String.t()
  def fermix_home do
    System.get_env("FERMIX_HOME") || Path.join(System.user_home!(), ".fermix")
  end

  @spec path() :: String.t()
  def path, do: Path.join(fermix_home(), "config.toml")

  @spec workspace_paths() :: %{
          bootstrap: String.t(),
          skills: String.t(),
          journals: String.t(),
          traces: String.t(),
          logs: String.t()
        }
  def workspace_paths do
    Enum.into(@workspace_dirs, %{}, fn {name, dir} ->
      {name, Path.join(fermix_home(), dir)}
    end)
  end

  @spec current_snapshot() :: runtime_config()
  def current_snapshot do
    %{
      fermix_core: [
        providers: [
          openai:
            Application.get_env(:fermix_core, :providers, [])
            |> Keyword.get(:openai, [])
        ],
        personalization: Application.get_env(:fermix_core, :personalization, []),
        agent: Application.get_env(:fermix_core, :agent, [])
      ],
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

  @spec load_runtime_config() :: {:ok, runtime_config()} | {:error, term()}
  def load_runtime_config do
    case File.read(path()) do
      {:ok, contents} -> {:ok, parse_document(contents)}
      {:error, :enoent} -> {:ok, empty_runtime_config()}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec save_snapshot(runtime_config()) :: :ok | {:error, term()}
  def save_snapshot(snapshot) do
    persisted = persistable_snapshot(snapshot)

    with :ok <- File.mkdir_p(fermix_home()),
         :ok <- ensure_workspace(),
         :ok <- File.write(path(), dump_snapshot(persisted)) do
      :ok
    end
  end

  @spec apply_snapshot(runtime_config()) :: :ok
  def apply_snapshot(snapshot) do
    persisted = persistable_snapshot(snapshot)

    apply_openai_config(
      Keyword.get(persisted.fermix_core, :providers, [])
      |> Keyword.get(:openai, [])
    )

    apply_personalization_config(Keyword.get(persisted.fermix_core, :personalization, []))
    apply_agent_config(Keyword.get(persisted.fermix_core, :agent, []))

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
        Application.put_env(:fermix_core, :mcp_servers, servers)
        :ok

      {:error, :enoent} ->
        Application.put_env(:fermix_core, :mcp_servers, [])
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec persistable_snapshot(runtime_config()) :: runtime_config()
  def persistable_snapshot(snapshot) do
    %{
      fermix_core: [
        providers: [
          openai:
            snapshot
            |> Map.get(:fermix_core, [])
            |> Keyword.get(:providers, [])
            |> Keyword.get(:openai, [])
            |> normalize_openai()
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
          |> normalize_agent()
      ],
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
    Enum.reduce_while(Map.values(workspace_paths()), :ok, fn path, :ok ->
      case File.mkdir_p(path) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp empty_runtime_config do
    %{
      fermix_core: [
        providers: [openai: []],
        personalization: [user_name: nil, timezone: nil, communication_style: nil],
        agent: [name: "fermix"]
      ],
      fermix_channels: [telegram: [], whatsapp: [], discord: [], slack: [], signal: []],
      fermix_web: []
    }
  end

  defp apply_openai_config(openai_config) do
    providers = Application.get_env(:fermix_core, :providers, [])
    merged_openai = Keyword.merge(Keyword.get(providers, :openai, []), openai_config)

    Application.put_env(:fermix_core, :providers, Keyword.put(providers, :openai, merged_openai))
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

  defp apply_channel_config(channel, channel_config) do
    merged =
      Application.get_env(:fermix_channels, channel, [])
      |> Keyword.merge(channel_config)

    Application.put_env(:fermix_channels, channel, merged)
    :ok
  end

  defp dump_snapshot(snapshot) do
    fermix_core = Map.get(snapshot, :fermix_core, [])

    openai =
      fermix_core
      |> Keyword.get(:providers, [])
      |> Keyword.get(:openai, [])

    personalization = Keyword.get(fermix_core, :personalization, [])
    agent = Keyword.get(fermix_core, :agent, [])
    channels = Map.get(snapshot, :fermix_channels, [])

    [
      "# Managed by mix fermix.setup",
      render_section(["fermix_core", "providers", "openai"], openai),
      render_section(["fermix_core", "personalization"], personalization),
      render_section(["fermix_core", "agent"], agent),
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

  defp encode_value(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"#{escaped}\""
  end

  defp encode_value(value) when is_boolean(value), do: to_string(value)
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
          openai: normalize_openai(get_in(document, ["fermix_core", "providers", "openai"]))
        ],
        personalization:
          normalize_personalization(get_in(document, ["fermix_core", "personalization"])),
        agent: normalize_agent(get_in(document, ["fermix_core", "agent"]))
      ],
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

  defp parse_value(value) do
    cond do
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        value
        |> String.trim_leading("\"")
        |> String.trim_trailing("\"")
        |> String.replace("\\\"", "\"")
        |> String.replace("\\\\", "\\")

      value == "true" ->
        true

      value == "false" ->
        false

      String.starts_with?(value, "[") and String.ends_with?(value, "]") ->
        value
        |> String.trim_leading("[")
        |> String.trim_trailing("]")
        |> String.split(",", trim: true)
        |> Enum.map(&parse_value(String.trim(&1)))

      Regex.match?(~r/^\d+$/, value) ->
        String.to_integer(value)

      true ->
        value
    end
  end

  defp normalize_openai(nil), do: []

  defp normalize_openai(config) do
    []
    |> put_if_present(:auth_mode, normalize_auth_mode(lookup(config, "auth_mode", :auth_mode)))
    |> put_if_present(:api_key, normalize_string(lookup(config, "api_key", :api_key)))
    |> put_if_present(:provider, normalize_provider(lookup(config, "provider", :provider)))
  end

  defp normalize_provider(nil), do: nil
  defp normalize_provider(:openai), do: :openai
  defp normalize_provider(:openai_codex), do: :openai_codex
  defp normalize_provider(:anthropic), do: :anthropic
  defp normalize_provider("openai"), do: :openai
  defp normalize_provider("openai_codex"), do: :openai_codex
  defp normalize_provider("anthropic"), do: :anthropic
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
  end

  defp normalize_telegram(nil), do: []

  defp normalize_telegram(config) do
    []
    |> put_if_present(:enabled, lookup(config, "enabled", :enabled))
    |> put_if_present(:mode, normalize_mode(lookup(config, "mode", :mode)))
    |> put_if_present(:bot_token, normalize_string(lookup(config, "bot_token", :bot_token)))
    |> Keyword.put(
      :allowed_user_ids,
      normalize_ids(lookup(config, "allowed_user_ids", :allowed_user_ids) || [])
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
    |> Keyword.put(
      :allowed_sender_ids,
      normalize_ids(lookup(config, "allowed_sender_ids", :allowed_sender_ids) || [])
    )
  end

  defp normalize_discord(nil), do: []

  defp normalize_discord(config) do
    []
    |> put_if_present(:enabled, lookup(config, "enabled", :enabled))
    |> put_if_present(:mode, normalize_mode(lookup(config, "mode", :mode)))
    |> put_if_present(:bot_token, normalize_string(lookup(config, "bot_token", :bot_token)))
    |> put_if_present(:bot_user_id, normalize_string(lookup(config, "bot_user_id", :bot_user_id)))
    |> Keyword.put(
      :allowed_user_ids,
      normalize_ids(lookup(config, "allowed_user_ids", :allowed_user_ids) || [])
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
    |> Keyword.put(
      :allowed_user_ids,
      normalize_ids(lookup(config, "allowed_user_ids", :allowed_user_ids) || [])
    )
  end

  defp normalize_signal(nil), do: []

  defp normalize_signal(config) do
    []
    |> put_if_present(:enabled, lookup(config, "enabled", :enabled))
    |> put_if_present(:mode, normalize_mode(lookup(config, "mode", :mode)))
    |> put_if_present(:account, normalize_string(lookup(config, "account", :account)))
    |> put_if_present(:cli_path, normalize_string(lookup(config, "cli_path", :cli_path)))
    |> Keyword.put(
      :allowed_sender_ids,
      normalize_ids(lookup(config, "allowed_sender_ids", :allowed_sender_ids) || [])
    )
  end

  defp normalize_auth_mode(:api_key), do: :api_key
  defp normalize_auth_mode(:oauth), do: :oauth
  defp normalize_auth_mode("api_key"), do: :api_key
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

  defp lookup(config, string_key, atom_key) when is_map(config) do
    Map.get(config, string_key, Map.get(config, atom_key))
  end

  defp lookup(config, _string_key, atom_key) when is_list(config) do
    Keyword.get(config, atom_key)
  end

  defp put_if_present(keyword, _key, nil), do: keyword
  defp put_if_present(keyword, key, value), do: Keyword.put(keyword, key, value)
end
