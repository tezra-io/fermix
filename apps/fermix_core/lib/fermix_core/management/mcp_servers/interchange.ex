defmodule FermixCore.Management.McpServers.Interchange do
  @moduledoc """
  The one translator from the shapes other apps and READMEs give an MCP server
  in, to the servers Fermix writes (M74 §3, §4, E8). It is pure: it takes text
  and answers servers, and never reads a file, so a paste (`mcp.servers.draft`)
  and an import scan of another app's settings share it.

  It reads:

    * a URL, `https://…` or `http://` to this Mac: one remote server;
    * a command line: one local server, split by `CommandLine`, with its
      refusals and its home-folder rule;
    * JSON: an `mcpServers` map (Claude Desktop, Claude Code, Cursor,
      Windsurf), a `servers` map (VS Code), a bare map of names to servers, or
      one server object. A server object is `command`, `args`, `env` and `cwd`,
      or `url` (Windsurf's `serverUrl`) with `headers`, and `type` or
      `transport` says `stdio`, `http`, `streamable-http` or `sse`. An `sse`
      server is a remote server at its URL as given, and its check says what
      it is;
    * a `claude mcp add` line (`--transport`, `--scope`, `-e`/`--env`,
      `-H`/`--header`, a name, then a URL or `--` and a command), or
      `claude mcp add-json <name> '<json>'`;
    * a Codex block of `[mcp_servers.<name>]` tables (`command`, `args`, `env`,
      `cwd`, `url`, `bearer_token_env_var`, `http_headers`, `env_http_headers`).

  Each server comes back as its §4 attributes (the block `ConfigStore` writes),
  the server they make (`McpConfig.server/2`) and the values the text carried
  (`PastedValues`). A variable's or a header's value is a value, a variable that
  is not secret included, since a server has no other kind. A placeholder
  (`${input:…}`, `${env:…}`, `${NAME}`, `${NAME:-default}`, an empty value,
  Codex's `bearer_token_env_var` and `env_http_headers`) declares its name and
  carries no value, so the server says it is waiting for it. `Authorization:
  Bearer <token>` makes the key header, its value the token (the daemon sends
  `Bearer <value>`); otherwise a remote server's first header is its key
  header and the rest its other headers. A remote server with no header signs
  in by itself (`auto`). JSON keeps the text's order; the TOML reader keeps
  none, so Codex servers and headers come by name.

  A server keeps the name its source gives it (the JSON key, the `claude mcp
  add` name, the Codex table) where a new server may take that name. Otherwise,
  and for a bare URL or command line, the name is derived: from a URL's host
  without a leading `mcp.`, `api.` or `www.` and without its public suffix
  (`mcp.linear.app` is `linear`), from a command's package, the first word after
  `npx`, `bunx`, `uvx` or `pipx run` that is not a flag, else the program's own
  name, without its scope, its version and `mcp-server-`, `server-`,
  `-mcp-server`, `-mcp` or `-server` (a package that is only `mcp`, as
  `@playwright/mcp`, takes its scope's name), then lowercased to the name rule.

  Every refusal is `{:invalid_params, "text", sentence}`. A placeholder Fermix
  would have to fill in itself (in the command or its arguments, the working
  folder or the address) refuses the paste, since none of those is templated,
  and so does anything else one server cannot be written with: in a paste of
  several servers the sentence names the server, and one refusal refuses the
  whole paste, so every draft is a server Fermix can add as given.
  """

  alias FermixCore.Capabilities.MCP.Config, as: McpConfig
  alias FermixCore.Capabilities.MCP.Remote.Endpoint
  alias FermixCore.Capabilities.MCP.Secrets, as: McpSecrets
  alias FermixCore.Management.McpServers.CommandLine
  alias FermixCore.Management.McpServers.PastedValues
  alias FermixCore.Management.McpServers.Row
  alias Jason.OrderedObject

  @max_text_bytes 65_536
  @max_servers 32
  @transports %{"stdio" => :stdio, "http" => :http, "streamable-http" => :http, "sse" => :http}
  @claude_transports %{"stdio" => :stdio, "http" => :http, "sse" => :http}
  @claude_json_options %{"--scope" => :scope, "-s" => :scope}
  @claude_options Map.merge(@claude_json_options, %{
                    "--transport" => :transport,
                    "-t" => :transport,
                    "--env" => :env,
                    "-e" => :env,
                    "--header" => :header,
                    "-H" => :header
                  })
  @claude_line %{transport: nil, env: [], headers: [], words: []}
  @runners ~w(npx bunx uvx)
  @host_prefixes ~w(mcp api www)
  # A country's own second level (`co.uk`, `com.au`) is part of its suffix.
  @second_levels ~w(ac co com edu gov net org)
  @name_prefixes ~w(mcp-server- server-)
  @name_suffixes ~w(-mcp-server -mcp -server)
  @fallback_name "server"
  @max_quoted_chars 64
  @placeholder ~r/\$\{[^}]*\}/
  @bearer ~r/\Abearer\s+/i
  # A shell joins a line that ends in a backslash to the next one.
  @continuation ~r/\\\r?\n/
  @codex_table ~r/^\s*\[mcp_servers\./m

  @unread_sentence "Fermix cannot read this server."
  @json_sentence "Fermix cannot read this JSON."
  @scheme_sentence "Fermix sends an authorization header only with a bearer token, " <>
                     "and this one holds another kind of key."
  @claude_sentence "This line needs the server's name and its address or command."
  @paste_sentence "Paste a server's address, the command that starts it, or the settings " <>
                    "a README or another app gives for it."

  @type translated :: %{
          name: String.t(),
          attrs: %{String.t() => term()},
          server: McpConfig.server_config(),
          values: PastedValues.t()
        }
  @type refusal :: {:invalid_params, String.t(), String.t()}

  @doc "The most servers one translation answers."
  @spec max_servers() :: pos_integer()
  def max_servers, do: @max_servers

  @doc """
  The servers `text` describes, in its order. `home` is the home folder a
  leading `~` in a command line or a working folder stands for.
  """
  @spec translate(String.t(), Path.t()) :: {:ok, [translated()]} | {:error, refusal()}
  def translate(text, home) when is_binary(text) and is_binary(home) do
    with :ok <- bounded(text),
         {:ok, specs} <- specs(String.trim(text), home),
         :ok <- few_enough(specs) do
      translate_all(specs, home, length(specs) > 1)
    end
  end

  @doc """
  The package a runner starts: the first word after `npx`, `bunx`, `uvx` or
  `pipx run` that is not a flag, as written; nil for any other program.
  """
  @spec package(String.t(), [String.t()]) :: String.t() | nil
  def package(command, args) when is_binary(command) and is_list(args) do
    case {Path.basename(command), args} do
      {"pipx", ["run" | rest]} -> Enum.find(rest, &operand?/1)
      {runner, rest} when runner in @runners -> Enum.find(rest, &operand?/1)
      _program -> nil
    end
  end

  defp operand?(word), do: not String.starts_with?(word, "-")

  defp bounded(text) when byte_size(text) <= @max_text_bytes, do: :ok
  defp bounded(_text), do: refuse("This is text of at most #{@max_text_bytes} bytes.")

  defp few_enough(specs) when length(specs) <= @max_servers, do: :ok
  defp few_enough(_specs), do: refuse("Fermix reads at most #{@max_servers} servers at once.")

  # --- shapes ---------------------------------------------------------------

  # A spec is one server as its source wrote it: `source` its own name or nil,
  # the transport, and its fields with raw values, nil where it gave none.
  defp specs("", _home), do: refuse(@paste_sentence)
  defp specs("{" <> _rest = text, _home), do: json_specs(text)

  defp specs(text, home) do
    if Regex.match?(@codex_table, text),
      do: codex_specs(text),
      else: line_specs(String.replace(text, @continuation, ""), home)
  end

  defp line_specs(line, home) do
    cond do
      String.contains?(line, ["\n", "\r"]) -> refuse(@paste_sentence)
      url?(line) -> {:ok, [remote_spec(nil, line, [])]}
      true -> with {:ok, words} <- words(line, home), do: words_specs(words)
    end
  end

  defp url?(line) do
    not String.contains?(line, [" ", "\t"]) and
      match?(%URI{scheme: scheme} when scheme in ["http", "https"], URI.parse(line))
  end

  defp words(line, home) do
    case CommandLine.split(line, home) do
      {:ok, {command, args}} -> {:ok, [command | args]}
      {:error, {:invalid_params, _field, sentence}} -> refuse(sentence)
    end
  end

  defp words_specs(["claude", "mcp", "add" | words]), do: claude_add(words)
  defp words_specs(["claude", "mcp", "add-json" | words]), do: claude_add_json(words)
  defp words_specs([command | args]), do: {:ok, [local_spec(nil, command, args, nil, [])]}

  defp local_spec(source, command, args, cwd, env),
    do: %{source: source, transport: :stdio, command: command, args: args, cwd: cwd, env: env}

  defp remote_spec(source, url, headers),
    do: %{source: source, transport: :http, url: url, headers: headers}

  # --- claude mcp add -------------------------------------------------------

  # Options are read anywhere before `--`; the words after it are the command.
  # Without `--`, the name is followed by a URL, or by a program and its
  # arguments, which then hold no option of Claude's.
  defp claude_add(words) do
    {own, command} = split_at_dashes(words)

    with {:ok, parsed} <- claude_options(own, @claude_line, @claude_options),
         {:ok, transport} <- claude_transport(parsed.transport) do
      claude_spec(transport, Enum.reverse(parsed.words), command, parsed)
    end
  end

  defp claude_add_json(words) do
    with {:ok, parsed} <- claude_options(words, @claude_line, @claude_json_options) do
      case Enum.reverse(parsed.words) do
        [name, json] -> json_server(name, json)
        _other -> refuse("This line needs the server's name and its settings.")
      end
    end
  end

  defp json_server(name, json) do
    case Jason.decode(json, objects: :ordered_objects) do
      {:ok, %OrderedObject{} = object} ->
        with {:ok, spec} <- server_spec(name, object), do: {:ok, [spec]}

      _unread ->
        refuse(@json_sentence)
    end
  end

  defp split_at_dashes(words) do
    case Enum.split_while(words, &(&1 != "--")) do
      {own, ["--" | command]} -> {own, command}
      {own, []} -> {own, nil}
    end
  end

  # `options` are the ones this line takes, each by the key it fills.
  defp claude_options([], parsed, _options), do: {:ok, parsed}

  defp claude_options([word | rest], parsed, options) do
    {option, inline} = option_parts(word)

    case Map.fetch(options, option) do
      {:ok, key} -> claude_value(key, option, inline, rest, {parsed, options})
      :error -> claude_word(word, rest, parsed, options)
    end
  end

  defp claude_word("-" <> _flag = word, _rest, _parsed, _options),
    do: refuse("Fermix does not know the option #{quoted(word)}.")

  defp claude_word(word, rest, parsed, options),
    do: claude_options(rest, %{parsed | words: [word | parsed.words]}, options)

  defp option_parts("--" <> _long = word) do
    case String.split(word, "=", parts: 2) do
      [option, value] -> {option, value}
      [option] -> {option, nil}
    end
  end

  defp option_parts(word), do: {word, nil}

  defp claude_value(key, option, nil, [value | rest], line),
    do: claude_value(key, option, value, rest, line)

  defp claude_value(_key, option, nil, [], _line),
    do: refuse("The option #{option} needs a value.")

  defp claude_value(key, _option, value, rest, {parsed, options}) do
    with {:ok, parsed} <- claude_put(key, value, parsed),
         do: claude_options(rest, parsed, options)
  end

  defp claude_put(:transport, value, parsed), do: {:ok, %{parsed | transport: value}}
  defp claude_put(:scope, _value, parsed), do: {:ok, parsed}

  defp claude_put(:env, value, parsed) do
    case String.split(value, "=", parts: 2) do
      [name, raw] -> {:ok, %{parsed | env: parsed.env ++ [{name, raw}]}}
      [_name] -> refuse("Fermix cannot read the variable #{quoted(value)}.")
    end
  end

  defp claude_put(:header, value, parsed) do
    case String.split(value, ":", parts: 2) do
      [name, raw] ->
        {:ok, %{parsed | headers: parsed.headers ++ [{String.trim(name), String.trim(raw)}]}}

      [_name] ->
        refuse("Fermix cannot read the header #{quoted(value)}.")
    end
  end

  defp claude_transport(nil), do: {:ok, nil}

  defp claude_transport(value) do
    case Map.fetch(@claude_transports, value) do
      {:ok, transport} -> {:ok, transport}
      :error -> refuse("Fermix does not know the transport #{quoted(value)}.")
    end
  end

  defp claude_spec(_transport, [name], [command | args], parsed),
    do: {:ok, [local_spec(name, command, args, nil, parsed.env)]}

  defp claude_spec(transport, [name, target | args], nil, parsed) do
    case {remote?(transport, target), args} do
      {true, []} -> {:ok, [remote_spec(name, target, parsed.headers)]}
      {false, args} -> {:ok, [local_spec(name, target, args, nil, parsed.env)]}
      {true, _words} -> refuse(@claude_sentence)
    end
  end

  defp claude_spec(_transport, _words, _command, _parsed), do: refuse(@claude_sentence)

  defp remote?(nil, target), do: url?(target)
  defp remote?(transport, _target), do: transport == :http

  # --- JSON -----------------------------------------------------------------

  defp json_specs(text) do
    case Jason.decode(text, objects: :ordered_objects) do
      {:ok, %OrderedObject{} = object} -> object_specs(object)
      {:ok, _other} -> refuse(@paste_sentence)
      {:error, _reason} -> refuse(@json_sentence)
    end
  end

  defp object_specs(object) do
    cond do
      match?(%OrderedObject{}, object["mcpServers"]) -> map_specs(object["mcpServers"])
      match?(%OrderedObject{}, object["servers"]) -> map_specs(object["servers"])
      server_object?(object) -> with {:ok, spec} <- server_spec(nil, object), do: {:ok, [spec]}
      named_servers?(object) -> map_specs(object)
      true -> refuse(@paste_sentence)
    end
  end

  defp server_object?(%OrderedObject{} = object),
    do: Enum.any?(~w(command url serverUrl), &(object[&1] != nil))

  defp server_object?(_value), do: false

  defp named_servers?(%OrderedObject{values: values}),
    do: values != [] and Enum.all?(values, fn {_name, value} -> server_object?(value) end)

  defp map_specs(%OrderedObject{values: []}), do: refuse(@paste_sentence)

  defp map_specs(%OrderedObject{values: entries}) do
    several? = length(entries) > 1

    collect(entries, fn {name, value} -> name |> server_spec(value) |> about(name, several?) end)
  end

  defp server_spec(name, %OrderedObject{} = object) do
    with {:ok, transport} <- json_transport(object) do
      json_server_spec(transport, name, object)
    end
  end

  defp server_spec(_name, _value), do: refuse(@unread_sentence)

  defp json_transport(object) do
    case object["type"] || object["transport"] do
      nil -> {:ok, if(object["command"] != nil, do: :stdio, else: :http)}
      type when is_map_key(@transports, type) -> {:ok, Map.fetch!(@transports, type)}
      type when is_binary(type) -> refuse("Fermix does not know the transport #{quoted(type)}.")
      _type -> refuse(@unread_sentence)
    end
  end

  defp json_server_spec(:stdio, name, object) do
    with {:ok, command} <- required_text(object["command"], "This server has no command."),
         {:ok, args} <- texts(object["args"]),
         {:ok, cwd} <- optional_text(object["cwd"]),
         {:ok, env} <- pairs(object["env"]) do
      {:ok, local_spec(name, command, args, cwd, env)}
    end
  end

  defp json_server_spec(:http, name, object) do
    with {:ok, url} <-
           required_text(object["url"] || object["serverUrl"], "This server has no address."),
         {:ok, headers} <- pairs(object["headers"]) do
      {:ok, remote_spec(name, url, headers)}
    end
  end

  defp required_text(value, _sentence) when is_binary(value) and value != "", do: {:ok, value}
  defp required_text(_value, sentence), do: refuse(sentence)

  defp optional_text(nil), do: {:ok, nil}
  defp optional_text(value) when is_binary(value), do: {:ok, value}
  defp optional_text(_value), do: refuse(@unread_sentence)

  defp texts(nil), do: {:ok, []}

  defp texts(values) when is_list(values) do
    collect(values, fn value ->
      case scalar(value) do
        {:ok, text} when is_binary(text) -> {:ok, text}
        _other -> refuse(@unread_sentence)
      end
    end)
  end

  defp texts(_values), do: refuse(@unread_sentence)

  defp pairs(nil), do: {:ok, []}

  defp pairs(%OrderedObject{values: values}) do
    collect(values, fn {name, value} ->
      case scalar(value) do
        {:ok, text} -> {:ok, {name, text}}
        :error -> refuse(@unread_sentence)
      end
    end)
  end

  defp pairs(_value), do: refuse(@unread_sentence)

  defp scalar(value) when is_binary(value) or is_nil(value), do: {:ok, value}
  defp scalar(value) when is_number(value) or is_boolean(value), do: {:ok, to_string(value)}
  defp scalar(_value), do: :error

  # --- Codex ----------------------------------------------------------------

  defp codex_specs(text) do
    case TomlElixir.decode(text) do
      {:ok, %{"mcp_servers" => servers}} when is_map(servers) and map_size(servers) > 0 ->
        table_specs(servers)

      {:ok, _other} ->
        refuse(@paste_sentence)

      {:error, _reason} ->
        refuse("Fermix cannot read these settings.")
    end
  end

  defp table_specs(servers) do
    several? = map_size(servers) > 1

    servers
    |> Enum.sort()
    |> collect(fn {name, table} -> name |> codex_spec(table) |> about(name, several?) end)
  end

  defp codex_spec(name, %{"url" => url} = table) when is_binary(url) do
    with {:ok, headers} <- codex_headers(table) do
      {:ok, remote_spec(name, url, headers)}
    end
  end

  defp codex_spec(name, %{"command" => command} = table) when is_binary(command) do
    with {:ok, args} <- texts(table["args"]),
         {:ok, cwd} <- optional_text(table["cwd"]),
         {:ok, env} <- table_pairs(table["env"]) do
      {:ok, local_spec(name, command, args, cwd, env)}
    end
  end

  defp codex_spec(_name, _table), do: refuse("This server has no command or address.")

  # A bearer token read from a variable is the key, sent in `Authorization`;
  # headers read from variables are named and wait for their values.
  defp codex_headers(table) do
    bearer = if is_binary(table["bearer_token_env_var"]), do: [{"Authorization", nil}], else: []

    with {:ok, static} <- table_pairs(table["http_headers"]),
         {:ok, from_env} <- table_pairs(table["env_http_headers"]) do
      {:ok, bearer ++ static ++ Enum.map(from_env, fn {name, _variable} -> {name, nil} end)}
    end
  end

  defp table_pairs(nil), do: {:ok, []}

  defp table_pairs(table) when is_map(table) do
    table
    |> Enum.sort()
    |> collect(fn {name, value} ->
      case scalar(value) do
        {:ok, text} -> {:ok, {name, text}}
        :error -> refuse(@unread_sentence)
      end
    end)
  end

  defp table_pairs(_value), do: refuse(@unread_sentence)

  # --- servers --------------------------------------------------------------

  defp translate_all(specs, home, several?) do
    collect(specs, fn spec -> spec |> translated(home) |> about(spec.source, several?) end)
  end

  defp translated(%{transport: :stdio} = spec, home) do
    with :ok <-
           not_templated(
             [spec.command | spec.args],
             "the command",
             "Put the value in a variable."
           ),
         {:ok, cwd} <- folder(spec.cwd, home),
         {:ok, env} <- valued(spec.env) do
      attrs = %{
        "command" => spec.command,
        "args" => spec.args,
        "cwd" => cwd,
        "env_secrets" => Enum.map(env, &elem(&1, 0))
      }

      server(name_of(spec), attrs, values(:env, env))
    end
  end

  defp translated(%{transport: :http} = spec, _home) do
    with :ok <- address(spec.url),
         {:ok, headers} <- valued(spec.headers),
         {:ok, headers} <- bearer_key(headers) do
      {auth, key_header} = key_header(headers)

      attrs = %{
        "transport" => "http",
        "url" => spec.url,
        "auth" => auth,
        "key_header" => key_header,
        "header_secrets" => Enum.map(headers, &elem(&1, 0))
      }

      server(name_of(spec), attrs, values(:header, headers))
    end
  end

  # The block holds only what a hand edit would write: no empty list, no null.
  defp server(name, attrs, values) do
    attrs = Map.reject(attrs, fn {_key, value} -> value in [nil, []] end)

    case McpConfig.server(name, attrs) do
      {:ok, server} ->
        {:ok, %{name: name, attrs: attrs, server: server, values: PastedValues.new(values)}}

      {:error, {:invalid_params, _key, sentence}} ->
        refuse(sentence)
    end
  end

  defp not_templated(words, where, remedy) do
    case Enum.find_value(words, &placeholder/1) do
      nil -> :ok
      found -> refuse("Fermix cannot fill in #{found} inside #{where}. #{remedy}")
    end
  end

  defp placeholder(word) do
    case Regex.run(@placeholder, word) do
      [found] -> quoted(found)
      nil -> nil
    end
  end

  defp folder(nil, _home), do: {:ok, nil}

  defp folder(cwd, home) do
    with :ok <- not_templated([cwd], "the working folder", "Write the full path.") do
      case CommandLine.expand_home(cwd, home, "cwd") do
        {:ok, path} -> {:ok, path}
        {:error, {:invalid_params, _field, sentence}} -> refuse(sentence)
      end
    end
  end

  # The remote rail's own rule for an owner's URL, as the add form applies it.
  defp address(url) do
    with :ok <- not_templated([url], "the address", "Write the full address.") do
      case Endpoint.operator(url) do
        {:ok, _endpoint} -> :ok
        {:error, _reason} -> refuse(Row.url_sentence())
      end
    end
  end

  # A name with a placeholder or an empty value is declared and waits for its
  # value; any other value is one the secret store must be able to hold.
  defp valued(pairs), do: collect(pairs, &valued_pair/1)

  defp valued_pair({name, raw}) do
    if raw in [nil, ""] or Regex.match?(@placeholder, raw),
      do: {:ok, {name, nil}},
      else: with(:ok <- storable(raw), do: {:ok, {name, raw}})
  end

  defp storable(value) do
    case McpSecrets.validate_value(value) do
      :ok ->
        :ok

      {:error, :value_too_large} ->
        refuse("A value in this paste is longer than #{McpSecrets.max_value_bytes()} bytes.")

      {:error, _not_one_line} ->
        refuse("A value in this paste is more than one line.")
    end
  end

  # The daemon sends `Authorization` as `Bearer <value>`, so it stores the
  # token alone, and an Authorization header with another scheme cannot be sent.
  defp bearer_key(headers) do
    collect(headers, fn
      {name, value} when is_binary(value) ->
        if authorization?(name), do: bearer_token(name, value), else: {:ok, {name, value}}

      header ->
        {:ok, header}
    end)
  end

  defp bearer_token(name, value) do
    if Regex.match?(@bearer, value),
      do: {:ok, {name, String.trim(Regex.replace(@bearer, value, ""))}},
      else: refuse(@scheme_sentence)
  end

  defp key_header([]), do: {"auto", nil}

  defp key_header([{first, _value} | _rest] = headers) do
    case Enum.find(headers, fn {name, _value} -> authorization?(name) end) do
      {authorization, _value} -> {"header", authorization}
      nil -> {"header", first}
    end
  end

  defp authorization?(name), do: String.downcase(name) == "authorization"

  defp values(kind, pairs),
    do: for({name, value} when is_binary(value) <- pairs, into: %{}, do: {{kind, name}, value})

  # --- names ----------------------------------------------------------------

  defp name_of(%{source: source} = spec) do
    if is_binary(source) and McpConfig.valid_name?(source),
      do: source,
      else: spec |> derived() |> sanitized()
  end

  defp derived(%{transport: :http, url: url}), do: host_name(URI.parse(url).host || "")

  defp derived(%{transport: :stdio, command: command, args: args}),
    do: command_name(command, args)

  defp host_name(host) do
    if ip?(host), do: @fallback_name, else: host |> String.split(".") |> registered()
  end

  defp ip?(host), do: match?({:ok, _address}, :inet.parse_address(String.to_charlist(host)))

  # The host without a leading mcp., api. or www. and without its public suffix.
  defp registered([only]), do: only

  defp registered(labels) do
    case labels |> without_suffix() |> Enum.drop_while(&(&1 in @host_prefixes)) do
      [] -> labels |> without_suffix() |> List.last()
      kept -> Enum.join(kept, ".")
    end
  end

  defp without_suffix(labels) do
    case Enum.reverse(labels) do
      [tld, second | rest] when byte_size(tld) == 2 and second in @second_levels and rest != [] ->
        Enum.reverse(rest)

      [_tld | rest] ->
        Enum.reverse(rest)
    end
  end

  # A package that is only `mcp` (`@playwright/mcp`) is named by its scope.
  defp command_name(command, args) do
    {scope, base} =
      (package(command, args) || Path.basename(command)) |> versionless() |> scoped()

    case base |> strip_prefix(@name_prefixes) |> strip_suffix(@name_suffixes) do
      bare when bare in ["", "mcp"] and is_binary(scope) -> scope
      name -> name
    end
  end

  defp versionless(word), do: Regex.replace(~r/(?<=.)@[^\/@]*\z/, word, "")

  defp scoped("@" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [scope, base] -> {scope, base}
      [base] -> {nil, base}
    end
  end

  defp scoped(word), do: {nil, word}

  defp strip_prefix(name, prefixes) do
    case Enum.find(prefixes, &String.starts_with?(name, &1)) do
      nil -> name
      prefix -> String.replace_prefix(name, prefix, "")
    end
  end

  defp strip_suffix(name, suffixes) do
    case Enum.find(suffixes, &String.ends_with?(name, &1)) do
      nil -> name
      suffix -> String.replace_suffix(name, suffix, "")
    end
  end

  defp sanitized(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.replace(~r/\A[^a-z]+/, "")
    |> String.slice(0, 32)
    |> String.replace(~r/[-_]+\z/, "")
    |> case do
      "" -> @fallback_name
      sanitized -> sanitized
    end
  end

  # --- plumbing -------------------------------------------------------------

  # Each item through `fun`, stopping at the first refusal.
  defp collect(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _refusal} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  # In a paste of several servers, a refusal names the one it is about.
  defp about({:error, {:invalid_params, field, sentence}}, name, true) when is_binary(name),
    do: {:error, {:invalid_params, field, "#{quoted(name)}: #{sentence}"}}

  defp about(result, _name, _several?), do: result

  # What the owner pasted, quoted back bounded so a sentence stays a sentence.
  defp quoted(text), do: String.slice(text, 0, @max_quoted_chars)

  defp refuse(sentence), do: {:error, {:invalid_params, "text", sentence}}
end
