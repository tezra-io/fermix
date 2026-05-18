defmodule FermixCore.Capabilities.MCP.Config do
  @moduledoc """
  Parser for the `[mcp.servers.<name>]` blocks in `~/.fermix/config.toml`.

  Returns one config map per configured server with `command`, `args`,
  `env`, `pass_env`, `approved?`, and `tools_overrides` already typed.
  Secret passthrough is declared with `pass_env` and resolved later by
  `FermixCore.Sandbox.Env`.

  This parser is a small purpose-built TOML reader scoped to the MCP
  block. It supports:

    * section headers with two or three dot-separated parts
      (`[mcp.servers.github]`, `[mcp.servers.github.tools.read_file]`)
    * scalar key/value pairs (`command = "npx"`)
    * inline arrays (`args = ["-y", "..."]`)
    * inline tables (`env = { KEY = "..." }`)

  Unknown section blocks under `[mcp.*]` raise loud — silent drops would
  hide misconfiguration.

  MCP tools are visible to the agent by default. To hide a specific tool
  from the LLM, set `[mcp.servers.X.tools.Y] hidden_from_agent = true`.
  """

  @type tool_override :: %{
          optional(:policy_class) => atom(),
          optional(:hidden_from_agent?) => boolean()
        }

  @type server_config :: %{
          name: String.t(),
          command: String.t() | nil,
          args: [String.t()],
          env: %{String.t() => String.t()},
          pass_env: [String.t()],
          tools_overrides: %{String.t() => tool_override()}
        }

  @valid_policy_strings ~w(read_only read_write exec network external_api)

  @spec from_toml(String.t()) :: [server_config()]
  def from_toml(contents) when is_binary(contents) do
    contents
    |> String.split(~r/\r?\n/)
    |> Enum.reduce({nil, %{}}, fn raw_line, {section, acc} ->
      handle_line(String.trim(raw_line), section, acc)
    end)
    |> elem(1)
    |> assemble_configs()
  end

  defp handle_line("", section, acc), do: {section, acc}
  defp handle_line("#" <> _comment, section, acc), do: {section, acc}

  defp handle_line(<<"[", rest::binary>>, _section, acc) do
    body = rest |> String.trim_trailing("]") |> String.trim()
    parts = String.split(body, ".")
    {classify_section(parts), acc}
  end

  defp handle_line(line, section, acc) when section != nil do
    case String.split(line, "=", parts: 2) do
      [key, value] -> {section, store(acc, section, String.trim(key), parse_scalar(value))}
      _ -> {section, acc}
    end
  end

  defp handle_line(_line, section, acc), do: {section, acc}

  defp classify_section(["mcp", "servers", server]), do: {:server, server}

  defp classify_section(["mcp", "servers", server, "tools", tool]),
    do: {:tool, server, tool}

  defp classify_section(["mcp", "inbound" | _]), do: nil

  defp classify_section(["mcp" | _] = parts) do
    raise ArgumentError,
          "Unknown MCP section header: [#{Enum.join(parts, ".")}]"
  end

  defp classify_section(_other), do: nil

  defp store(acc, {:server, name}, key, value) do
    Map.update(acc, name, %{server: %{key => value}}, fn existing ->
      Map.update(existing, :server, %{key => value}, &Map.put(&1, key, value))
    end)
  end

  defp store(acc, {:tool, name, tool}, key, value) do
    Map.update(acc, name, %{tools: %{tool => %{key => value}}}, fn existing ->
      tools = Map.get(existing, :tools, %{})
      tool_block = Map.get(tools, tool, %{}) |> Map.put(key, value)
      Map.put(existing, :tools, Map.put(tools, tool, tool_block))
    end)
  end

  defp assemble_configs(by_name) do
    by_name
    |> Map.to_list()
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map(fn {name, sections} -> assemble_one(name, sections) end)
  end

  defp assemble_one(name, sections) do
    server = Map.get(sections, :server, %{})
    tools = Map.get(sections, :tools, %{})

    reject_removed_server_key!(name, server, "approved",
      "MCP tools are visible to the agent by default. To hide a specific tool, set " <>
        "`[mcp.servers.#{name}.tools.<tool>] hidden_from_agent = true`."
    )

    env = server |> Map.get("env", %{}) |> validate_env(name)
    pass_env = server |> Map.get("pass_env", []) |> ensure_list_of_strings(:pass_env, name)
    validate_env_conflicts!(name, env, pass_env)

    %{
      name: name,
      command: Map.get(server, "command"),
      args: server |> Map.get("args", []) |> ensure_list_of_strings(:args, name),
      env: env,
      pass_env: pass_env,
      tools_overrides: parse_tools_overrides(tools, name)
    }
  end

  defp reject_removed_server_key!(server_name, server, key, hint) do
    if Map.has_key?(server, key) do
      raise ArgumentError,
            "[mcp.servers.#{server_name}] #{key} was removed; #{hint}"
    end
  end

  defp parse_tools_overrides(tools, server_name) do
    Enum.into(tools, %{}, fn {tool_name, opts} ->
      override =
        opts
        |> Enum.reduce(%{}, fn
          {"policy_class", value}, acc ->
            Map.put(acc, :policy_class, validate_policy(value, tool_name, server_name))

          {"hidden_from_agent", value}, acc ->
            Map.put(
              acc,
              :hidden_from_agent?,
              validate_bool(value, :hidden_from_agent, "#{server_name}/#{tool_name}")
            )

          {"requires_approval", _value}, _acc ->
            raise ArgumentError,
                  "[mcp.servers.#{server_name}.tools.#{tool_name}] requires_approval was " <>
                    "renamed; use `hidden_from_agent = true` (semantics are identical — " <>
                    "the flag hides the tool from the agent; there is no approval prompt)."

          _other, acc ->
            acc
        end)

      {tool_name, override}
    end)
  end

  defp validate_policy(value, tool_name, server_name) when is_binary(value) do
    if value in @valid_policy_strings do
      String.to_existing_atom(value)
    else
      raise ArgumentError,
            "Invalid policy_class #{inspect(value)} for #{server_name}/#{tool_name}; " <>
              "expected one of #{inspect(@valid_policy_strings)}"
    end
  end

  defp validate_policy(value, tool_name, server_name) do
    raise ArgumentError,
          "policy_class for #{server_name}/#{tool_name} must be a quoted string, got: " <>
            inspect(value)
  end

  defp validate_bool(true, _key, _ctx), do: true
  defp validate_bool(false, _key, _ctx), do: false

  defp validate_bool(other, key, ctx) do
    raise ArgumentError, "#{key} for #{ctx} must be true or false, got: #{inspect(other)}"
  end

  defp ensure_list_of_strings(value, _key, _name) when is_list(value) do
    Enum.map(value, &to_string/1)
  end

  defp ensure_list_of_strings(other, key, name) do
    raise ArgumentError,
          "#{key} for [mcp.servers.#{name}] must be an array, got: #{inspect(other)}"
  end

  defp validate_env(env, name) when is_map(env) do
    Enum.into(env, %{}, fn {key, value} -> {to_string(key), validate_env_value(value, name)} end)
  end

  defp validate_env(other, name) do
    raise ArgumentError,
          "env for [mcp.servers.#{name}] must be an inline table, got: #{inspect(other)}"
  end

  defp validate_env_value("$env:" <> ref, name) when is_binary(ref) do
    raise ArgumentError,
          "MCP env value '$env:#{ref}' for [mcp.servers.#{name}] uses the removed $env: shorthand. " <>
            "Declare #{ref} in [sandbox.env] and reference it via pass_env = [\"#{ref}\"]."
  end

  defp validate_env_value(value, _name) when is_binary(value), do: value
  defp validate_env_value(value, _name), do: to_string(value)

  defp validate_env_conflicts!(name, env, pass_env) do
    duplicates = MapSet.intersection(MapSet.new(Map.keys(env)), MapSet.new(pass_env))

    if MapSet.size(duplicates) > 0 do
      duplicate_names = duplicates |> MapSet.to_list() |> Enum.sort() |> Enum.join(", ")

      raise ArgumentError,
            "[mcp.servers.#{name}] declares #{duplicate_names} in both env and pass_env. " <>
              "Pick one declaration shape per env name."
    end
  end

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

      String.starts_with?(trimmed, "{") ->
        parse_inline_table(trimmed)

      true ->
        parse_number(trimmed)
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

  defp parse_inline_table("{" <> rest) do
    body =
      rest
      |> String.trim_trailing("}")
      |> String.trim()

    if body == "" do
      %{}
    else
      body
      |> split_inline_pairs()
      |> Enum.into(%{}, fn pair ->
        [key, value] = String.split(pair, "=", parts: 2)
        {String.trim(key), parse_scalar(value)}
      end)
    end
  end

  defp split_inline_pairs(body) do
    body
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_number(value) do
    case Integer.parse(value) do
      {int, ""} ->
        int

      _ ->
        case Float.parse(value) do
          {float, ""} -> float
          _ -> value
        end
    end
  end
end
