defmodule FermixCore.Management.McpServers.Row do
  @moduledoc """
  The one owner of `mcpServerRow` (M74 §5): one operator MCP server, a
  `[mcp.servers.<name>]` block, in the daemon's own words.

  `build/3` is pure. It composes the server's configuration with the facts the
  daemon holds about it: which declared values are stored, the source's live
  status and what its last discovery found (`RuntimeStatus`), whether its
  subtree is still running, and where its command resolves (`LoginPath`).
  Every field is always present, null where the transport has none.

  The status is derived in one order, and the first that holds wins: `off`
  (written `enabled = false`), `failed` for a block that names nothing to
  start (`McpConfig.startable?/1`: a stdio server without its command, an http
  one without its URL, which no stored value would help), `needs_secret` (a
  declared value is not stored, so the server is not started), `needs_sign_in`
  (an `auto` server the server itself asked to sign in), `starting`
  (connecting, or no status yet for a server that runs), `connected` (ready),
  `retrying` (the last status is a failure and the subtree still runs, so it is
  being started again), `failed` (a failure with the subtree gone). The status
  is published for logs and support; a client draws `status_sentence` and
  switches on `primary_action` and `actions`.

  Stage 1 has no sign-in (M74 E5), so no row carries `sign_in` or `sign_out`
  yet, and an `auto` server's sign-in state is `signed_out` only where the
  server asked to sign in, `not_needed` otherwise.
  """

  alias FermixCore.Capabilities.MCP.Config, as: McpConfig
  alias FermixCore.Capabilities.MCP.LoginPath
  alias FermixCore.Capabilities.MCP.RuntimeStatus
  alias FermixCore.Capabilities.MCP.Secrets, as: McpSecrets
  alias FermixCore.Management.McpServers.CommandLine

  @statuses ~w(off needs_secret needs_sign_in starting connected retrying failed)a
  @actions ~w(sign_in sign_out check enable disable)
  @auth_states ~w(not_needed signed_out signed_in expired)
  # A check reconnects a server that has something to say about its connection;
  # one waiting for a value or a sign-in would only fail again.
  @checkable [:connected, :retrying, :failed]
  @node_commands ~w(npx node npm)
  @uv_commands ~w(uvx uv)
  @max_said_chars 200

  @local_consent "Runs on this Mac as a separate program, with your access."
  @node_hint "Install Node.js or use the full path."
  @uv_hint "Install uv or use the full path."
  @path_hint "Use the full path."
  @url_sentence "Fermix cannot connect to this address. Use https, or http only to this Mac."

  @type facts :: %{
          presence: McpSecrets.presence(),
          entry: RuntimeStatus.entry() | nil,
          alive?: boolean(),
          resolution: LoginPath.resolution() | nil
        }

  @doc "Every status a row can carry, ordered as they are derived."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc "The closed set of action ids a row may publish."
  @spec actions() :: [String.t()]
  def actions, do: @actions

  @doc "Every sign-in state a row's `auth.state` may carry."
  @spec auth_states() :: [String.t()]
  def auth_states, do: @auth_states

  @doc "The sentence a refused URL carries, here and on a row the URL failed."
  @spec url_sentence() :: String.t()
  def url_sentence, do: @url_sentence

  @doc """
  One server's row. `tools?: true` adds `tools`, which only `mcp.servers.get`
  carries: 32 servers of 256 described tools would pass the result bound.
  """
  @spec build(McpConfig.server_config(), facts(), keyword()) :: map()
  def build(server, facts, opts \\ []) when is_map(server) and is_map(facts) and is_list(opts) do
    status = status(server, facts)
    discovery = discovery(facts.entry)

    row = %{
      "name" => server.name,
      "transport" => Atom.to_string(server.transport),
      "enabled" => server.enabled?,
      "status" => published(status),
      "status_sentence" => status_sentence(status, server, facts),
      "primary_action" => primary_action(status),
      "actions" => actions(status),
      "consent_sentence" => consent_sentence(server),
      "location" => location(server),
      "url" => Map.get(server, :url),
      "resolved_command" => resolved_command(facts.resolution),
      "cwd" => Map.get(server, :cwd),
      "env" => names(facts.presence.env),
      "headers" => names(extra_headers(server, facts.presence.headers)),
      "auth" => auth(server, facts),
      "oauth_client" => oauth_client(server, facts.presence),
      "server_info" => server_info(discovery),
      "tool_count" => tool_count(discovery),
      "tools_on" => tools_on(server, discovery),
      "last_error" => last_error(status, server, facts),
      "origin" => server.origin
    }

    if Keyword.get(opts, :tools?, false),
      do: Map.put(row, "tools", tools(server, discovery)),
      else: row
  end

  # --- status ---------------------------------------------------------------

  defp status(server, facts) do
    cond do
      not server.enabled? -> :off
      not McpConfig.startable?(server) -> :unaddressed
      missing(server, facts.presence) != [] -> :needs_secret
      sign_in_required?(server, facts.entry) -> :needs_sign_in
      starting?(facts.entry) -> :starting
      facts.entry.status == :ready -> :connected
      facts.alive? -> :retrying
      true -> :failed
    end
  end

  # What the owner is asked for, in the row's words: a variable or a header by
  # its name, the key by what it is.
  defp missing(server, presence) do
    env = for {name, false} <- presence.env, do: name
    headers = for {name, false} <- presence.headers, do: header_label(server, name)
    secret = if client_secret_missing?(server, presence), do: ["the client secret"], else: []
    env ++ headers ++ secret
  end

  defp header_label(%{key_header: name}, name), do: "the key"
  defp header_label(_server, name), do: name

  defp client_secret_missing?(%{transport: :http, oauth_client_id: id}, presence)
       when is_binary(id),
       do: not presence.client_secret

  defp client_secret_missing?(_server, _presence), do: false

  defp sign_in_required?(%{transport: :http, auth: :auto}, %{
         status: :reauthorization_required,
         detail: :sign_in_required
       }),
       do: true

  defp sign_in_required?(_server, _entry), do: false

  defp starting?(nil), do: true
  defp starting?(%{status: :connecting}), do: true
  defp starting?(_entry), do: false

  # A server with nothing to start fails before it is started, so it is
  # published as `failed`, with nothing a check could change.
  defp published(:unaddressed), do: "failed"
  defp published(status), do: Atom.to_string(status)

  defp primary_action(:off), do: "enable"
  defp primary_action(:failed), do: "check"
  defp primary_action(_status), do: nil

  defp actions(:off), do: ["enable"]
  defp actions(status) when status in @checkable, do: ["check", "disable"]
  defp actions(_status), do: ["disable"]

  # --- sentences ------------------------------------------------------------

  defp status_sentence(:off, _server, _facts), do: "Turned off."
  defp status_sentence(:unaddressed, server, _facts), do: unaddressed(server)

  defp status_sentence(:needs_secret, server, facts),
    do: "Waiting for #{listed(missing(server, facts.presence))}."

  defp status_sentence(:needs_sign_in, _server, _facts), do: "Sign in to finish connecting."
  defp status_sentence(:starting, _server, _facts), do: "Starting."

  defp status_sentence(:connected, _server, facts),
    do: "Connected. #{tools_phrase(tool_count(discovery(facts.entry)))}."

  defp status_sentence(:retrying, _server, _facts), do: "Trying again."
  defp status_sentence(:failed, server, facts), do: failure(server, facts.entry, true)

  defp last_error(:unaddressed, server, _facts), do: unaddressed(server)
  defp last_error(:retrying, server, facts), do: failure(server, facts.entry, false)
  defp last_error(:failed, server, facts), do: failure(server, facts.entry, true)
  defp last_error(_status, _server, _facts), do: nil

  defp unaddressed(%{transport: :stdio}),
    do: "It has no command to start. Add one in its settings."

  defp unaddressed(%{transport: :http}), do: "It has no address. Add one in its settings."

  defp tools_phrase(1), do: "1 tool"
  defp tools_phrase(count), do: "#{count} tools"

  defp listed([one]), do: one
  defp listed(names), do: Enum.join(Enum.drop(names, -1), ", ") <> " and " <> List.last(names)

  # One sentence per class a failed operator server can end in (M74 §5, E3,
  # E4). `gave_up?` tells a program that is being started again from one whose
  # subtree stopped trying.
  defp failure(server, %{status: :invalid_remote_config, detail: detail}, _gave_up?),
    do: config_failure(server, detail)

  defp failure(_server, %{status: :reauthorization_required, detail: :key_refused}, _gave_up?),
    do: "The server refused the key."

  defp failure(_server, %{status: :reauthorization_required}, _gave_up?),
    do: "The server asks for a sign-in or a key."

  defp failure(_server, %{status: :remote_protocol_error, detail: :legacy_sse_transport}, _),
    do: "This server uses the older SSE transport, which Fermix does not support."

  defp failure(_server, %{status: :remote_protocol_error}, _gave_up?),
    do: "The server answered in a way Fermix does not understand."

  defp failure(_server, %{status: :remote_security_blocked}, _gave_up?),
    do: "Fermix will not connect to that address."

  defp failure(_server, %{status: :capability_conflict}, _gave_up?),
    do: "Its tools have the names of tools Fermix already has."

  defp failure(server, %{status: :remote_unreachable} = entry, gave_up?),
    do: unreachable(server, entry, gave_up?)

  defp failure(_server, _entry, _gave_up?), do: "It stopped. See the daemon log."

  defp config_failure(%{transport: :stdio} = server, :command_not_found),
    do: not_found_sentence(server.command)

  defp config_failure(%{transport: :stdio} = server, :cwd_not_found),
    do: "Fermix could not find the working folder #{server.cwd} on this Mac."

  defp config_failure(_server, :env_unavailable),
    do: "Fermix could not read one of its stored variables."

  defp config_failure(_server, :header_unavailable),
    do: "Fermix could not read one of its stored headers."

  defp config_failure(_server, :reserved_header),
    do: "One of its headers is one Fermix sets itself. Remove it."

  defp config_failure(_server, :invalid_url), do: @url_sentence

  defp config_failure(_server, _detail),
    do: "Fermix cannot start it as it is set up. Check its settings."

  defp unreachable(_server, %{detail: :exited, stderr_tail: tail}, true),
    do: said("It kept stopping, so Fermix stopped starting it.", tail)

  defp unreachable(_server, %{detail: :exited, stderr_tail: tail}, false),
    do: said("It stopped.", tail)

  defp unreachable(_server, %{detail: :retries_exhausted}, _gave_up?),
    do: "It started but did not answer within a minute."

  defp unreachable(_server, %{detail: :spawn_failed}, _gave_up?),
    do: "Fermix could not start the program."

  defp unreachable(_server, %{detail: :rate_limited}, _gave_up?),
    do: "The server is turning requests away for now. Try again later."

  defp unreachable(%{transport: :http} = server, _entry, _gave_up?),
    do: "Fermix could not reach #{host(server) || "the server"}."

  defp unreachable(_server, _entry, _gave_up?), do: "The program stopped unexpectedly."

  # The program's own last line, as it wrote it: data on the row, bounded here.
  defp said(lead, []), do: lead

  defp said(lead, tail),
    do: "#{lead} The last thing it said: #{String.slice(List.last(tail), 0, @max_said_chars)}"

  @doc """
  What a row says of a command this Mac does not have, and a draft says under
  the command it fills in: with the install hint for Node's and uv's programs.
  """
  @spec not_found_sentence(String.t()) :: String.t()
  def not_found_sentence(command) when is_binary(command) do
    base = "Fermix could not find #{command} on this Mac."

    cond do
      String.contains?(command, "/") -> base
      command in @node_commands -> "#{base} #{@node_hint}"
      command in @uv_commands -> "#{base} #{@uv_hint}"
      true -> "#{base} #{@path_hint}"
    end
  end

  @doc """
  Where `server`'s code runs and what leaves this Mac, on its row and on the
  draft that adds it (M74 §7).
  """
  @spec consent_sentence(McpConfig.server_config()) :: String.t()
  def consent_sentence(%{transport: :stdio}), do: @local_consent

  def consent_sentence(server) do
    case host(server) do
      nil -> "Runs on another computer. What you ask its tools is sent there."
      host -> "Runs on #{host}. What you ask its tools is sent there."
    end
  end

  # --- fields ---------------------------------------------------------------

  @doc "Where a server is: a remote one's host, a local one's command line as it runs."
  @spec location(McpConfig.server_config()) :: String.t()
  def location(%{transport: :http} = server), do: host(server) || server.url || ""
  def location(%{command: nil}), do: ""
  def location(%{command: command, args: args}), do: CommandLine.join([command | args])

  defp host(%{url: url}) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _unparsed -> nil
    end
  end

  defp host(_server), do: nil

  defp resolved_command({:ok, program}), do: program
  defp resolved_command(_unresolved), do: nil

  defp names(presence), do: Enum.map(presence, fn {name, present} -> name_row(name, present) end)
  defp name_row(name, present), do: %{"name" => name, "present" => present}

  # The key's header is the row's `auth.key_header`, so `headers` holds the rest.
  defp extra_headers(%{key_header: key_header}, headers) when is_binary(key_header),
    do: Enum.reject(headers, fn {name, _present} -> name == key_header end)

  defp extra_headers(_server, headers), do: headers

  defp auth(%{transport: :http, auth: :header, key_header: key_header}, facts) do
    present = Enum.any?(facts.presence.headers, &(&1 == {key_header, true}))
    auth_row("header", if(present, do: "signed_in", else: "signed_out"), key_header)
  end

  # Stage 1 has no sign-in, so an `auto` server is signed out only where the
  # server itself asked for one.
  defp auth(%{transport: :http, auth: :auto} = server, facts) do
    state = if sign_in_required?(server, facts.entry), do: "signed_out", else: "not_needed"
    auth_row("auto", state, nil)
  end

  defp auth(_server, _facts), do: auth_row("none", "not_needed", nil)

  defp auth_row(mode, state, key_header) do
    %{
      "mode" => mode,
      "state" => state,
      "key_header" => key_header,
      "account_label" => nil,
      "issuer" => nil
    }
  end

  defp oauth_client(server, presence) do
    %{
      "client_id" => Map.get(server, :oauth_client_id),
      "secret_present" => presence.client_secret
    }
  end

  defp discovery(%{discovery: discovery}), do: discovery
  defp discovery(nil), do: nil

  defp server_info(%{server_info: %{} = info}),
    do: %{"name" => info.name, "title" => info.title, "version" => info.version}

  defp server_info(_discovery), do: nil

  defp tool_count(%{tool_count: count}), do: count
  defp tool_count(nil), do: 0

  # A tool switched off is one the server listed and the owner hid. Only the
  # tools the row describes can be told apart, so the rest, past 256 or with a
  # name too long to describe, count as on.
  defp tools_on(_server, nil), do: 0

  defp tools_on(server, discovery),
    do: discovery.tool_count - Enum.count(discovery.tools, &hidden?(server, &1.name))

  defp tools(_server, nil), do: []

  defp tools(server, discovery) do
    Enum.map(discovery.tools, fn tool ->
      %{
        "name" => tool.name,
        "title" => tool.title,
        "description" => tool.description,
        "read_only" => tool.read_only,
        "destructive" => tool.destructive,
        "enabled" => not hidden?(server, tool.name)
      }
    end)
  end

  defp hidden?(server, tool),
    do: match?(%{hidden_from_agent?: true}, Map.get(server.tools_overrides, tool))
end
