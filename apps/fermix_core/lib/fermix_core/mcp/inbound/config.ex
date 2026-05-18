defmodule FermixCore.MCP.Inbound.Config do
  @moduledoc """
  Parser and runtime accessor for `[mcp.inbound]` config.

  This mirrors the outbound `Capabilities.MCP.Config` style: a small
  purpose-built TOML reader for the top-level MCP namespace. Outbound
  `[mcp.servers.*]` blocks are ignored here and remain owned by the outbound
  parser.
  """

  alias FermixCore.Capabilities.Capability

  @type tool_override :: %{
          optional(:exposed) => boolean(),
          optional(:description_override) => String.t()
        }

  @type t :: %__MODULE__{
          enabled?: boolean(),
          transport: :stdio | :streamable_http,
          expose_kinds: [Capability.kind()],
          expose_policy_classes: [Capability.policy_class()],
          allowed_tools: [String.t()],
          denied_tools: [String.t()],
          tool_overrides: %{String.t() => tool_override()},
          http: %{path: String.t(), auth_token: String.t() | nil},
          server_name: String.t(),
          server_version: String.t(),
          request_timeout_ms: pos_integer()
        }

  @kind_map %{"builtin" => :builtin, "skill" => :skill, "mcp" => :mcp}
  @policy_map %{
    "read_only" => :read_only,
    "read_write" => :read_write,
    "exec" => :exec,
    "network" => :network,
    "external_api" => :external_api
  }

  # Audit F-07: defaults are now read-only-only and deny-all-by-tool-name.
  # Inbound MCP exposes Fermix's tools to external MCP clients (Claude
  # Desktop, Cursor, …). Older defaults exposed every `:read_only` and
  # `:read_write` builtin out of the box; `file_write`, `file_edit`,
  # `git_write`, `memory_store`, `schedule_job`, etc. classify as
  # `:read_write` and would have been wide open the moment the (currently
  # unwired) supervisor landed. Tighten now so the latent surface can't
  # bite when wired later.
  defstruct enabled?: false,
            transport: :stdio,
            expose_kinds: [:builtin],
            expose_policy_classes: [:read_only],
            allowed_tools: [],
            denied_tools: [],
            tool_overrides: %{},
            http: %{path: "/mcp", auth_token: nil},
            server_name: "fermix",
            server_version: "0.1.0",
            request_timeout_ms: 30_000

  @spec default() :: t()
  def default do
    %__MODULE__{server_version: to_string(Application.spec(:fermix_core, :vsn) || "0.1.0")}
  end

  @spec current() :: t()
  def current do
    Application.get_env(:fermix_core, :mcp_inbound, default())
  end

  @spec from_toml(String.t()) :: t()
  def from_toml(contents) when is_binary(contents) do
    contents
    |> parse_sections()
    |> assemble_config()
    |> validate_config!()
  end

  defp parse_sections(contents) do
    contents
    |> String.split(~r/\r?\n/)
    |> Enum.reduce({nil, %{}}, fn raw_line, {section, acc} ->
      handle_line(String.trim(raw_line), section, acc)
    end)
    |> elem(1)
  end

  defp handle_line("", section, acc), do: {section, acc}
  defp handle_line("#" <> _comment, section, acc), do: {section, acc}

  defp handle_line(<<"[", rest::binary>>, _section, acc) do
    body = rest |> String.trim_trailing("]") |> String.trim()
    section = classify_section(String.split(body, "."))
    {section, init_section(acc, section)}
  end

  defp handle_line(line, section, acc) when not is_nil(section) do
    case String.split(line, "=", parts: 2) do
      [key, value] -> {section, store(acc, section, String.trim(key), parse_scalar(value))}
      _ -> {section, acc}
    end
  end

  defp handle_line(_line, section, acc), do: {section, acc}

  defp classify_section(["mcp", "inbound"]), do: :inbound
  defp classify_section(["mcp", "inbound", "http"]), do: :http
  defp classify_section(["mcp", "inbound", "tools", tool]), do: {:tool, tool}

  defp classify_section(["mcp", "inbound" | _] = parts) do
    raise ArgumentError,
          "Unknown inbound MCP section header: [#{Enum.join(parts, ".")}]"
  end

  defp classify_section(_other), do: nil

  defp store(acc, :inbound, key, value) do
    Map.update(acc, :inbound, %{key => value}, &Map.put(&1, key, value))
  end

  defp store(acc, :http, key, value) do
    Map.update(acc, :http, %{key => value}, &Map.put(&1, key, value))
  end

  defp store(acc, {:tool, tool}, key, value) do
    Map.update(acc, :tools, %{tool => %{key => value}}, fn tools ->
      Map.update(tools, tool, %{key => value}, &Map.put(&1, key, value))
    end)
  end

  defp init_section(acc, {:tool, tool}) do
    Map.update(acc, :tools, %{tool => %{}}, fn tools -> Map.put_new(tools, tool, %{}) end)
  end

  defp init_section(acc, _section), do: acc

  defp assemble_config(sections) do
    inbound = Map.get(sections, :inbound, %{})
    http = Map.get(sections, :http, %{})

    %__MODULE__{
      enabled?: bool_value(Map.get(inbound, "enabled", false), :enabled),
      transport: transport_value(Map.get(inbound, "transport", "stdio")),
      expose_kinds: kind_list(Map.get(inbound, "expose_kinds", ["builtin"])),
      expose_policy_classes:
        policy_list(Map.get(inbound, "expose_policy_classes", ["read_only", "read_write"])),
      allowed_tools: string_list(Map.get(inbound, "allowed_tools", []), :allowed_tools),
      denied_tools: string_list(Map.get(inbound, "denied_tools", []), :denied_tools),
      tool_overrides: parse_tool_overrides(Map.get(sections, :tools, %{})),
      http: %{
        path: http_path(Map.get(http, "path", "/mcp")),
        auth_token: http |> Map.get("auth_token") |> resolve_secret() |> blank_to_nil()
      },
      server_name: inbound |> Map.get("server_name", "fermix") |> normalize_string(:server_name),
      server_version:
        inbound
        |> Map.get("server_version", default().server_version)
        |> normalize_string(:server_version),
      request_timeout_ms:
        inbound
        |> Map.get("request_timeout_ms", 30_000)
        |> positive_int(:request_timeout_ms)
    }
  end

  defp parse_tool_overrides(tools) do
    Enum.into(tools, %{}, fn {tool_name, opts} ->
      {tool_name, parse_tool_override(tool_name, opts)}
    end)
  end

  defp parse_tool_override(tool_name, opts) when is_map(opts) do
    parsed =
      Enum.reduce(opts, %{}, fn
        {"exposed", value}, acc ->
          Map.put(acc, :exposed, bool_value(value, :"tools.#{tool_name}.exposed"))

        {"description_override", value}, acc ->
          Map.put(acc, :description_override, normalize_string(value, :description_override))

        {key, _value}, _acc ->
          raise ArgumentError, "Unknown inbound MCP tool override key #{inspect(key)}"
      end)

    if map_size(parsed) == 0 do
      raise ArgumentError, "Inbound MCP tool override #{tool_name} has no recognized keys"
    end

    parsed
  end

  defp validate_config!(%__MODULE__{} = config) do
    validate_http_auth!(config)
    validate_tool_filter_names!(config.allowed_tools, config.denied_tools)
    config
  end

  defp validate_http_auth!(%{
         enabled?: true,
         transport: :streamable_http,
         http: %{auth_token: nil}
       }) do
    raise ArgumentError, "mcp.inbound.http.auth_token is required for streamable_http"
  end

  defp validate_http_auth!(_config), do: :ok

  defp validate_tool_filter_names!(allowed, denied) do
    names = allowed ++ denied

    if length(names) != MapSet.new(names) |> MapSet.size() do
      raise ArgumentError, "mcp.inbound allowed_tools/denied_tools contain a duplicate tool name"
    end
  end

  defp bool_value(value, _key) when is_boolean(value), do: value

  defp bool_value(value, key) do
    raise ArgumentError, "#{key} must be true or false, got: #{inspect(value)}"
  end

  defp positive_int(value, _key) when is_integer(value) and value > 0, do: value

  defp positive_int(value, key) do
    raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(value)}"
  end

  defp transport_value("stdio"), do: :stdio
  defp transport_value("streamable_http"), do: :streamable_http

  defp transport_value(other) do
    raise ArgumentError,
          "Invalid inbound MCP transport #{inspect(other)}; expected \"stdio\" or \"streamable_http\""
  end

  defp kind_list(values), do: enum_list(values, @kind_map, "kind")
  defp policy_list(values), do: enum_list(values, @policy_map, "policy_class")

  defp enum_list(values, mapping, label) when is_list(values) do
    Enum.map(values, fn value ->
      case Map.fetch(mapping, value) do
        {:ok, atom} -> atom
        :error -> raise ArgumentError, "Invalid inbound MCP #{label} #{inspect(value)}"
      end
    end)
  end

  defp enum_list(other, _mapping, label) do
    raise ArgumentError, "inbound MCP #{label} list must be an array, got: #{inspect(other)}"
  end

  defp string_list(values, key) when is_list(values) do
    Enum.map(values, &normalize_string(&1, key))
  end

  defp string_list(other, key) do
    raise ArgumentError, "mcp.inbound.#{key} must be an array, got: #{inspect(other)}"
  end

  defp http_path(value) do
    path = normalize_string(value, :http_path)

    if String.starts_with?(path, "/") do
      path
    else
      raise ArgumentError, "mcp.inbound.http.path must start with /"
    end
  end

  defp normalize_string(value, _key) when is_binary(value) do
    value = String.trim(value)

    if value == "",
      do: raise(ArgumentError, "inbound MCP string value cannot be empty"),
      else: value
  end

  defp normalize_string(value, key) do
    raise ArgumentError, "#{key} must be a string, got: #{inspect(value)}"
  end

  defp resolve_secret("$env:" <> ref), do: System.get_env(ref) || ""
  defp resolve_secret(value) when is_binary(value), do: value
  defp resolve_secret(nil), do: nil

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp parse_scalar(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "true" ->
        true

      trimmed == "false" ->
        false

      String.starts_with?(trimmed, "\"") and String.ends_with?(trimmed, "\"") ->
        unquote_string(trimmed)

      String.starts_with?(trimmed, "[") ->
        parse_inline_array(trimmed)

      Regex.match?(~r/^-?\d+$/, trimmed) ->
        String.to_integer(trimmed)

      true ->
        trimmed
    end
  end

  defp unquote_string(<<"\"", rest::binary>>) do
    rest
    |> String.trim_trailing("\"")
    |> String.replace("\\\"", "\"")
  end

  defp parse_inline_array(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> list
      _ -> raise ArgumentError, "Invalid inline array: #{value}"
    end
  end
end
