defmodule FermixCore.Capabilities.MCP.Config do
  @moduledoc """
  The `[mcp.servers.<name>]` blocks in `~/.fermix/config.toml`: the one
  definition of an operator MCP server (M74 §4), read here and edited here.

  `from_toml/1` returns one config map per configured server, typed and
  checked. Every server has a `name`, a `transport` (`:stdio`, the default
  when the key is absent, or `:http`), `enabled?` (true unless written false),
  an `origin` that only labels the row, and `tools_overrides`. A stdio server
  adds `command`, `args`, `cwd`, literal `env`, `env_secrets` (names whose
  values live in the secret store, `Capabilities.MCP.Secrets`) and `pass_env`
  (names resolved through `[sandbox.env]` by `FermixCore.Sandbox.Env`). An
  http server adds `url`, `auth` (`:auto`, `:header` or `:none`),
  `header_secrets`, `key_header` and `oauth_client_id`.

  A new server's name is `^[a-z][a-z0-9_-]{0,31}$`, there are at most 32
  servers, and no two names share a tool prefix: `foo-bar` and `foo_bar` both
  name tools `mcp_foo_bar_…`. Those rules bind a server being added
  (`put_server/4`); a file that already breaks them loads as it always did, and
  `rule_breaks/1` names what it breaks, because a name the owner wrote must
  never stop the daemon. Only a dot in a name, which this reader has always
  refused, refuses the file. A key this reader does not read, a key of the
  other transport included, is kept in the file and named by `unread_keys/1`
  so the caller can say so; it never refuses the file either.

  This parser is a small purpose-built TOML reader scoped to the MCP block. It
  supports:

    * section headers with two or three dot-separated parts
      (`[mcp.servers.github]`, `[mcp.servers.github.tools.read_file]`)
    * scalar key/value pairs (`command = "npx"`)
    * inline arrays (`args = ["-y", "..."]`)
    * inline tables (`env = { KEY = "..." }`)

  Unknown section blocks under `[mcp.*]` raise loud — silent drops would
  hide misconfiguration.

  MCP tools are visible to the agent by default. To hide a specific tool
  from the LLM, set `[mcp.servers.X.tools.Y] hidden_from_agent = true`.

  The editors (`put_server/4`, `delete_server/2`, `put_tool/4`) change the
  `document/1` shape and nothing else, and refuse what this reader's dialect
  cannot hold, so the settings writer renders their result and it reads back
  as it was written (M74 E2). Every refusal is `{:invalid_params, field,
  sentence}`, the field being the key it is about.
  """

  alias FermixCore.Capabilities.MCP.Naming
  alias FermixCore.Capabilities.MCP.Secrets

  @type tool_override :: %{
          optional(:policy_class) => atom(),
          optional(:hidden_from_agent?) => boolean()
        }

  @type stdio_server :: %{
          name: String.t(),
          transport: :stdio,
          enabled?: boolean(),
          origin: String.t() | nil,
          command: String.t() | nil,
          args: [String.t()],
          cwd: String.t() | nil,
          env: %{String.t() => String.t()},
          env_secrets: [String.t()],
          pass_env: [String.t()],
          tools_overrides: %{String.t() => tool_override()}
        }

  @type http_server :: %{
          name: String.t(),
          transport: :http,
          enabled?: boolean(),
          origin: String.t() | nil,
          url: String.t() | nil,
          auth: :auto | :header | :none,
          key_header: String.t() | nil,
          header_secrets: [String.t()],
          oauth_client_id: String.t() | nil,
          tools_overrides: %{String.t() => tool_override()}
        }

  @type server_config :: stdio_server() | http_server()

  @typedoc """
  The `[mcp.servers.*]` blocks as written: every key of every server and tool
  block, the ones `from_toml/1` ignores included, each value as this parser
  reads it and before any check.
  """
  @type document :: %{
          String.t() => %{
            optional(:server) => %{String.t() => term()},
            optional(:tools) => %{String.t() => %{String.t() => term()}}
          }
        }

  @typedoc "A refusal: the key it is about, and the sentence that says why."
  @type refusal :: {:invalid_params, String.t(), String.t()}

  @valid_policy_strings ~w(read_only read_write exec network external_api)

  @name_pattern ~r/\A[a-z][a-z0-9_-]{0,31}\z/
  @max_servers 32
  @transports %{"stdio" => :stdio, "http" => :http}
  @auth_modes %{"auto" => :auto, "header" => :header, "none" => :none}
  @common_keys ~w(transport enabled origin)
  @transport_keys %{
    "stdio" => ~w(command args cwd env env_secrets pass_env),
    "http" => ~w(url auth key_header header_secrets oauth_client_id)
  }
  @tool_keys ~w(policy_class hidden_from_agent)
  # What the daemon writes. `env` (a literal value) and `pass_env` are the
  # owner's to write by hand; a hand-written one is carried through every edit.
  @writable_keys ~w(transport enabled origin command args cwd env_secrets url auth key_header header_secrets oauth_client_id)
  @required_keys %{stdio: "command", http: "url"}

  @name_rule "server name is lowercase letters, digits, - and _, starts with a letter, " <>
               "and is at most 32 characters"

  @spec from_toml(String.t()) :: [server_config()]
  def from_toml(contents) when is_binary(contents) do
    contents
    |> document()
    |> assemble_configs()
  end

  @doc """
  Every `[mcp.servers.*]` key in `contents`, by server, before `from_toml/1`
  validates and assembles it.

  The settings writer carries this through a save and writes it back, so a key
  this module ignores today is still the owner's and is never dropped.
  """
  @spec document(String.t()) :: document()
  def document(contents) when is_binary(contents) do
    contents
    |> String.split(~r/\r?\n/)
    |> Enum.reduce({nil, %{}}, fn raw_line, {section, acc} ->
      handle_line(String.trim(raw_line), section, acc)
    end)
    |> elem(1)
  end

  @doc """
  The retired `[mcp.*]` section headers in `contents`, as written: today the
  inbound server's `[mcp.inbound*]` (M73). `from_toml/1` and `document/1` skip
  them so a file that still has one boots; the caller says so.
  """
  @spec retired_sections(String.t()) :: [String.t()]
  def retired_sections(contents) when is_binary(contents) do
    contents
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(String.starts_with?(&1, "[") and retired_section?(header_parts(&1))))
  end

  @doc """
  The keys in `contents` this reader does not read, as `[mcp.servers.x] key`:
  a key §4 does not define, or one of the other transport's. They stay in the
  file; the caller says once that they are ignored.
  """
  @spec unread_keys(String.t()) :: [String.t()]
  def unread_keys(contents) when is_binary(contents) do
    contents
    |> document()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {name, sections} -> unread_in(name, sections) end)
  end

  defp unread_in(name, sections) do
    server = Map.get(sections, :server, %{})
    read = @common_keys ++ Map.get(@transport_keys, Map.get(server, "transport", "stdio"), [])
    server_keys = server |> Map.keys() |> Enum.reject(&(&1 in read)) |> Enum.sort()

    tool_keys =
      sections
      |> Map.get(:tools, %{})
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {tool, keys} -> unread_tool_keys(name, tool, keys) end)

    Enum.map(server_keys, &"[mcp.servers.#{name}] #{&1}") ++ tool_keys
  end

  defp unread_tool_keys(name, tool, keys) do
    keys
    |> Map.keys()
    |> Enum.reject(&(&1 in @tool_keys))
    |> Enum.sort()
    |> Enum.map(&"[mcp.servers.#{name}.tools.#{tool}] #{&1}")
  end

  @doc "The servers the boot read applied, which `ConfigStore.apply_mcp_config/0` writes."
  @spec configured() :: [server_config()]
  def configured, do: Application.get_env(:fermix_core, :mcp_servers, [])

  @doc """
  Whether the daemon starts this server by its configuration: an enabled one,
  stdio or `http` (the remote rail takes an operator endpoint, M74 E4). This is
  the one place that decides.
  """
  @spec startable?(server_config()) :: boolean()
  def startable?(%{enabled?: enabled?, transport: transport}) when transport in [:stdio, :http],
    do: enabled?

  @doc "The most operator servers one settings file holds."
  @spec max_servers() :: pos_integer()
  def max_servers, do: @max_servers

  @doc """
  The §4 name rules the loaded `servers` break, one sentence per rule: a name
  outside the pattern, more than 32 servers, names that give their tools one
  prefix. The servers still load; the caller says so once.
  """
  @spec rule_breaks([server_config()]) :: [String.t()]
  def rule_breaks(servers) when is_list(servers) do
    names = Enum.map(servers, & &1.name)
    pattern_breaks(names) ++ count_breaks(names) ++ prefix_breaks(names)
  end

  defp pattern_breaks(names) do
    case Enum.reject(names, &valid_name?/1) do
      [] -> []
      broken -> ["#{listed(broken)}: a #{@name_rule}"]
    end
  end

  defp count_breaks(names) when length(names) > @max_servers,
    do: ["#{length(names)} servers: Fermix holds at most #{@max_servers}"]

  defp count_breaks(_names), do: []

  defp prefix_breaks(names) do
    names
    |> Enum.group_by(&Naming.sanitize_segment/1)
    |> Enum.filter(fn {_prefix, group} -> length(group) > 1 end)
    |> Enum.sort()
    |> Enum.map(fn {prefix, group} ->
      "#{listed(group)}: their tools share the names mcp_#{prefix}_…"
    end)
  end

  defp listed(names) do
    sections = Enum.map(names, &"[mcp.servers.#{&1}]")

    case sections do
      [one] -> one
      _many -> Enum.join(Enum.drop(sections, -1), ", ") <> " and " <> List.last(sections)
    end
  end

  @doc "Whether `name` may name a new operator server."
  @spec valid_name?(String.t()) :: boolean()
  def valid_name?(name) when is_binary(name), do: Regex.match?(@name_pattern, name)

  @doc """
  Whether two names give their tools one prefix: `sanitize_segment/1` maps
  `foo-bar` and `foo_bar` to the same `mcp_foo_bar_`, so the second would
  collide into hash-suffixed tool names.
  """
  @spec same_prefix?(String.t(), String.t()) :: boolean()
  def same_prefix?(name, other) when is_binary(name) and is_binary(other),
    do: Naming.sanitize_segment(name) == Naming.sanitize_segment(other)

  @doc """
  One server block, checked and typed, without its tool blocks: the reader's
  rule for every server, and the check every edit's result passes. A refusal
  names the key it is about. The name is not checked here: a loaded server
  keeps the name it has, and `put_server/4` checks a new one.
  """
  @spec server(String.t(), %{String.t() => term()}) ::
          {:ok, server_config()} | {:error, refusal()}
  def server(name, block) when is_binary(name) and is_map(block) do
    with :ok <- reject_removed_server_key(name, block),
         {:ok, transport} <- transport(block),
         {:ok, enabled?} <- optional_bool(block, "enabled", true),
         {:ok, origin} <- optional_string(block, "origin"),
         {:ok, fields} <- transport_fields(transport, block) do
      common = %{
        name: name,
        transport: transport,
        enabled?: enabled?,
        origin: origin,
        tools_overrides: %{}
      }

      {:ok, Map.merge(common, fields)}
    end
  end

  # --- editing (M74 E2) -----------------------------------------------------

  @doc """
  `document` with server `name` written from `attrs`, its §4 keys.

  A new server takes `attrs` as its block; an existing one merges them over
  the block it has, `nil` removing a key, so a key the owner wrote by hand and
  `attrs` does not name is carried. Refused: a name that is not valid, a key
  the daemon does not write, a value the reader's dialect cannot hold, a
  changed transport, a server without its command or URL, and, for a new
  server, a name outside the pattern, a 33rd one, or a name whose tool prefix
  another operator server or one of `plugin_names` already gives. A server the
  file already holds keeps its name, whatever the rules say of it, so the owner
  can still change or remove it.
  """
  @spec put_server(document(), String.t(), %{String.t() => term()}, [String.t()]) ::
          {:ok, document()} | {:error, refusal()}
  def put_server(document, name, attrs, plugin_names)
      when is_map(document) and is_binary(name) and is_map(attrs) and is_list(plugin_names) do
    sections = Map.get(document, name, %{})
    block = merge_block(Map.get(sections, :server, %{}), attrs)

    with :ok <- room_for(document, name, plugin_names),
         :ok <- writable(attrs),
         :ok <- same_transport(Map.get(sections, :server), attrs),
         {:ok, server} <- server(name, block),
         :ok <- required(server, block) do
      {:ok, Map.put(document, name, Map.put(sections, :server, block))}
    end
  end

  @doc """
  `document` without server `name`, and the server it held, so the caller can
  forget what it declared.
  """
  @spec delete_server(document(), String.t()) ::
          {:ok, document(), server_config()} | {:error, refusal()}
  def delete_server(document, name) when is_map(document) and is_binary(name) do
    with {:ok, sections} <- fetch_server(document, name),
         {:ok, server} <- server(name, Map.get(sections, :server, %{})) do
      {:ok, Map.delete(document, name), server}
    end
  end

  @doc """
  `document` with one tool of server `name` switched: off writes
  `hidden_from_agent = true` in its tool block, on removes the key and a block
  left empty, which is what a hand edit would hold.
  """
  @spec put_tool(document(), String.t(), String.t(), boolean()) ::
          {:ok, document()} | {:error, refusal()}
  def put_tool(document, name, tool, enabled?)
      when is_map(document) and is_binary(name) and is_binary(tool) and is_boolean(enabled?) do
    with {:ok, sections} <- fetch_server(document, name),
         :ok <- tool_header_safe(tool) do
      tools = Map.get(sections, :tools, %{})
      keys = tools |> Map.get(tool, %{}) |> switch_tool(enabled?)
      tools = if keys == %{}, do: Map.delete(tools, tool), else: Map.put(tools, tool, keys)
      {:ok, Map.put(document, name, put_tools(sections, tools))}
    end
  end

  defp switch_tool(keys, true), do: Map.delete(keys, "hidden_from_agent")
  defp switch_tool(keys, false), do: Map.put(keys, "hidden_from_agent", true)

  defp put_tools(sections, tools) when tools == %{}, do: Map.delete(sections, :tools)
  defp put_tools(sections, tools), do: Map.put(sections, :tools, tools)

  defp fetch_server(document, name) do
    case Map.fetch(document, name) do
      {:ok, sections} -> {:ok, sections}
      :error -> {:error, {:invalid_params, "name", "There is no MCP server by that name."}}
    end
  end

  defp merge_block(block, attrs) do
    Enum.reduce(attrs, block, fn
      {key, nil}, acc -> Map.delete(acc, key)
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp writable(attrs) do
    Enum.reduce_while(attrs, :ok, fn {key, value}, :ok ->
      case writable_value(key, value) do
        :ok -> {:cont, :ok}
        {:error, _refusal} = error -> {:halt, error}
      end
    end)
  end

  defp writable_value(key, _value) when key not in @writable_keys,
    do: refuse(key, "Fermix does not write this key.")

  defp writable_value(key, value) when is_binary(value), do: dialect_safe(key, value)

  defp writable_value(key, values) when is_list(values) do
    if Enum.all?(values, &is_binary/1),
      do: :ok,
      else: refuse(key, "Every entry is text.")
  end

  defp writable_value(_key, value) when is_boolean(value) or is_nil(value), do: :ok
  defp writable_value(key, _value), do: refuse(key, "This value is not one Fermix writes here.")

  # The reader's own dialect: a line break ends the value, and a value ending in
  # a quotation mark is written bare, where a leading quote, bracket, brace or
  # space reads back as something else. A list is written as JSON on one line,
  # which holds any text.
  defp dialect_safe(key, value) do
    cond do
      String.contains?(value, ["\n", "\r"]) -> refuse(key, "A value is one line.")
      String.ends_with?(value, "\"") -> refuse(key, "A value cannot end with a quotation mark.")
      true -> :ok
    end
  end

  # A tool block's header is split on dots and trimmed, so a tool whose name
  # has a dot, a line break, a closing bracket at its end or space at either end
  # cannot be named in one.
  defp tool_header_safe(tool) do
    cond do
      tool == "" -> refuse("tool", "A tool has a name.")
      String.contains?(tool, [".", "\n", "\r"]) -> refuse("tool", tool_sentence())
      String.ends_with?(tool, "]") or String.trim(tool) != tool -> refuse("tool", tool_sentence())
      true -> :ok
    end
  end

  defp tool_sentence,
    do: "Fermix cannot switch a tool whose name has a dot, a line break or space at either end."

  defp same_transport(nil, _attrs), do: :ok

  defp same_transport(block, attrs) do
    if Map.get(attrs, "transport", Map.get(block, "transport", "stdio")) ==
         Map.get(block, "transport", "stdio"),
       do: :ok,
       else:
         refuse("transport", "A server's transport cannot change. Remove it and add it again.")
  end

  defp required(server, block) do
    key = Map.fetch!(@required_keys, server.transport)

    case Map.get(block, key) do
      value when is_binary(value) and value != "" -> :ok
      _absent -> refuse(key, required_sentence(server.transport))
    end
  end

  defp required_sentence(:stdio), do: "A local server needs the command that starts it."
  defp required_sentence(:http), do: "A remote server needs its URL."

  defp room_for(document, name, _plugin_names) when is_map_key(document, name), do: :ok

  defp room_for(document, name, plugin_names) do
    cond do
      not valid_name?(name) ->
        refuse("name", "A #{@name_rule}.")

      map_size(document) >= @max_servers ->
        refuse("name", "Fermix holds at most #{@max_servers} MCP servers. Remove one first.")

      Enum.any?(Map.keys(document), &same_prefix?(&1, name)) ->
        refuse(
          "name",
          "Another MCP server's name gives its tools the same names. Choose another."
        )

      Enum.any?(plugin_names, &same_prefix?(&1, name)) ->
        refuse("name", "A plugin already uses this name. Choose another.")

      true ->
        :ok
    end
  end

  defp refuse(field, sentence), do: {:error, {:invalid_params, field, sentence}}

  # --- reading ----------------------------------------------------------------

  defp handle_line("", section, acc), do: {section, acc}
  defp handle_line("#" <> _comment, section, acc), do: {section, acc}

  defp handle_line(<<"[", _rest::binary>> = header, _section, acc) do
    parts = header_parts(header)
    if retired_section?(parts), do: {nil, acc}, else: {classify_section(parts), acc}
  end

  defp handle_line(line, section, acc) when section != nil do
    case String.split(line, "=", parts: 2) do
      [key, value] -> {section, store(acc, section, String.trim(key), parse_scalar(value))}
      _ -> {section, acc}
    end
  end

  defp handle_line(_line, section, acc), do: {section, acc}

  defp header_parts(<<"[", rest::binary>>) do
    rest |> String.trim_trailing("]") |> String.trim() |> String.split(".")
  end

  defp retired_section?(["mcp", "inbound" | _]), do: true
  defp retired_section?(_parts), do: false

  defp classify_section(["mcp", "servers", server]), do: {:server, server}

  defp classify_section(["mcp", "servers", server, "tools", tool]),
    do: {:tool, server, tool}

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
    case server(name, Map.get(sections, :server, %{})) do
      {:ok, config} ->
        %{config | tools_overrides: parse_tools_overrides(Map.get(sections, :tools, %{}), name)}

      {:error, {:invalid_params, _field, sentence}} ->
        raise ArgumentError, "[mcp.servers.#{name}] #{sentence}"
    end
  end

  defp reject_removed_server_key(name, block) do
    if Map.has_key?(block, "approved") do
      refuse(
        "approved",
        "approved was removed; MCP tools are visible to the agent by default. To hide a " <>
          "specific tool, set `[mcp.servers.#{name}.tools.<tool>] hidden_from_agent = true`."
      )
    else
      :ok
    end
  end

  defp transport(block) do
    value = Map.get(block, "transport", "stdio")

    case Map.fetch(@transports, value) do
      {:ok, transport} -> {:ok, transport}
      :error -> refuse("transport", "transport is \"stdio\" or \"http\", got: #{inspect(value)}")
    end
  end

  defp transport_fields(:stdio, block) do
    with {:ok, command} <- optional_string(block, "command"),
         {:ok, args} <- string_list(block, "args"),
         {:ok, cwd} <- optional_string(block, "cwd"),
         {:ok, env} <- env_table(block),
         {:ok, env_secrets} <- secret_names(block, "env_secrets", &Secrets.env_name?/1),
         {:ok, pass_env} <- string_list(block, "pass_env"),
         :ok <- one_declaration_per_name(env, pass_env, env_secrets) do
      {:ok,
       %{
         command: command,
         args: args,
         cwd: cwd,
         env: env,
         env_secrets: env_secrets,
         pass_env: pass_env
       }}
    end
  end

  defp transport_fields(:http, block) do
    with {:ok, url} <- optional_string(block, "url"),
         {:ok, auth} <- auth_mode(block),
         {:ok, headers} <- secret_names(block, "header_secrets", &Secrets.header_name?/1),
         :ok <- distinct_headers(headers),
         {:ok, key_header} <- optional_string(block, "key_header"),
         :ok <- key_header_declared(auth, key_header, headers),
         {:ok, client_id} <- optional_string(block, "oauth_client_id") do
      {:ok,
       %{
         url: url,
         auth: auth,
         key_header: key_header,
         header_secrets: headers,
         oauth_client_id: client_id
       }}
    end
  end

  defp auth_mode(block) do
    value = Map.get(block, "auth", "auto")

    case Map.fetch(@auth_modes, value) do
      {:ok, mode} -> {:ok, mode}
      :error -> refuse("auth", "auth is \"auto\", \"header\" or \"none\", got: #{inspect(value)}")
    end
  end

  # Header names are case-insensitive on the wire, so two that differ only in
  # case would be one header with two stored values.
  defp distinct_headers(headers) do
    folded = Enum.map(headers, &String.downcase/1)

    if folded == Enum.uniq(folded),
      do: :ok,
      else: refuse("header_secrets", "Each header is named once.")
  end

  defp key_header_declared(:header, nil, _headers),
    do: refuse("key_header", "A server that sends a key names the header it goes in.")

  defp key_header_declared(:header, key_header, headers) do
    if key_header in headers,
      do: :ok,
      else: refuse("key_header", "The key's header is one of the server's headers.")
  end

  defp key_header_declared(_auth, nil, _headers), do: :ok

  defp key_header_declared(_auth, _key_header, _headers),
    do: refuse("key_header", "Only a server that sends a key names a key header.")

  defp optional_bool(block, key, default) do
    case Map.get(block, key, default) do
      value when is_boolean(value) -> {:ok, value}
      other -> refuse(key, "#{key} is true or false, got: #{inspect(other)}")
    end
  end

  defp optional_string(block, key) do
    case Map.get(block, key) do
      value when is_binary(value) or is_nil(value) -> {:ok, value}
      other -> refuse(key, "#{key} is text, got: #{inspect(other)}")
    end
  end

  defp string_list(block, key) do
    case Map.get(block, key, []) do
      values when is_list(values) -> {:ok, Enum.map(values, &to_string/1)}
      other -> refuse(key, "#{key} must be an array, got: #{inspect(other)}")
    end
  end

  defp secret_names(block, key, valid?) do
    with {:ok, names} <- string_list(block, key) do
      cond do
        not Enum.all?(names, valid?) -> refuse(key, secret_name_sentence(key))
        names != Enum.uniq(names) -> refuse(key, "Each name is declared once.")
        true -> {:ok, names}
      end
    end
  end

  defp secret_name_sentence("env_secrets"),
    do:
      "A variable name is letters, digits and underscores, does not start with a digit, " <>
        "and is at most 128 characters."

  defp secret_name_sentence("header_secrets"),
    do:
      "A header name is letters, digits, - and _, starts with a letter or digit, " <>
        "and is at most 64 characters."

  defp env_table(block) do
    case Map.get(block, "env", %{}) do
      env when is_map(env) -> env_values(env)
      other -> refuse("env", "env must be an inline table, got: #{inspect(other)}")
    end
  end

  defp env_values(env) do
    Enum.reduce_while(env, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case env_value(to_string(key), value) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, to_string(key), value)}}
        {:error, _refusal} = error -> {:halt, error}
      end
    end)
  end

  defp env_value(key, "$env:" <> ref) do
    refuse(
      "env",
      "env value '$env:#{ref}' for #{key} uses the removed $env: shorthand. " <>
        "Declare #{ref} in [sandbox.env] and reference it via pass_env = [\"#{ref}\"]."
    )
  end

  defp env_value(_key, value) when is_binary(value), do: {:ok, value}
  defp env_value(_key, value), do: {:ok, to_string(value)}

  # One declaration per variable: a name given a literal value, passed through
  # from `[sandbox.env]` and read from the secret store would have three values
  # and no rule for which one the server sees.
  defp one_declaration_per_name(env, pass_env, env_secrets) do
    names = Map.keys(env) ++ Enum.uniq(pass_env) ++ env_secrets

    case names -- Enum.uniq(names) do
      [] ->
        :ok

      duplicates ->
        listed = duplicates |> Enum.uniq() |> Enum.sort() |> Enum.join(", ")

        field =
          if Enum.any?(duplicates, &(&1 in env_secrets)), do: "env_secrets", else: "pass_env"

        refuse(
          field,
          "declares #{listed} in more than one of env, pass_env and env_secrets. " <>
            "Pick one declaration shape per env name."
        )
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
