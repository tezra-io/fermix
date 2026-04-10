defmodule FermixCore.Setup.ConfigStore do
  @moduledoc """
  Thin persisted setup store shared by web and CLI onboarding.
  """

  @workspace_dirs ~w(skills journals traces logs)

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

  @spec current_snapshot() :: runtime_config()
  def current_snapshot do
    %{
      fermix_core: [
        providers: [
          openai:
            Application.get_env(:fermix_core, :providers, [])
            |> Keyword.get(:openai, [])
        ]
      ],
      fermix_channels: [telegram: Application.get_env(:fermix_channels, :telegram, [])],
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

    apply_telegram_config(Keyword.get(persisted.fermix_channels, :telegram, []))
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
        ]
      ],
      fermix_channels: [
        telegram:
          snapshot
          |> Map.get(:fermix_channels, [])
          |> Keyword.get(:telegram, [])
          |> normalize_telegram()
      ],
      fermix_web: []
    }
  end

  @spec ensure_workspace() :: :ok | {:error, term()}
  def ensure_workspace do
    Enum.reduce_while(workspace_paths(), :ok, fn path, :ok ->
      case File.mkdir_p(path) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp workspace_paths do
    Enum.map(@workspace_dirs, &Path.join(fermix_home(), &1))
  end

  defp empty_runtime_config do
    %{
      fermix_core: [providers: [openai: []]],
      fermix_channels: [telegram: []],
      fermix_web: []
    }
  end

  defp apply_openai_config(openai_config) do
    providers = Application.get_env(:fermix_core, :providers, [])
    merged_openai = Keyword.merge(Keyword.get(providers, :openai, []), openai_config)

    Application.put_env(:fermix_core, :providers, Keyword.put(providers, :openai, merged_openai))
    :ok
  end

  defp apply_telegram_config(telegram_config) do
    merged_telegram =
      Application.get_env(:fermix_channels, :telegram, [])
      |> Keyword.merge(telegram_config)

    Application.put_env(:fermix_channels, :telegram, merged_telegram)
    :ok
  end

  defp dump_snapshot(snapshot) do
    openai =
      snapshot
      |> Map.get(:fermix_core, [])
      |> Keyword.get(:providers, [])
      |> Keyword.get(:openai, [])

    telegram = snapshot |> Map.get(:fermix_channels, []) |> Keyword.get(:telegram, [])

    [
      "# Managed by mix fermix.setup",
      render_section(["fermix_core", "providers", "openai"], openai),
      render_section(["fermix_channels", "telegram"], telegram)
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
        ]
      ],
      fermix_channels: [
        telegram: normalize_telegram(get_in(document, ["fermix_channels", "telegram"]))
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

  defp normalize_auth_mode(:api_key), do: :api_key
  defp normalize_auth_mode(:oauth), do: :oauth
  defp normalize_auth_mode("api_key"), do: :api_key
  defp normalize_auth_mode("oauth"), do: :oauth
  defp normalize_auth_mode(_value), do: nil

  defp normalize_mode(:polling), do: :polling
  defp normalize_mode(:webhook), do: :webhook
  defp normalize_mode("polling"), do: :polling
  defp normalize_mode("webhook"), do: :webhook
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
