defmodule FermixCore.Management.McpServers do
  @moduledoc """
  The `mcp.servers.*` methods: the MCP servers the owner adds, over
  `daemon.sock` alone (M74 §5, E7).

  An operator server is one `[mcp.servers.<name>]` block in `config.toml`, and
  every write goes through the one write path `ConfigStore` owns
  (`add_mcp_server/3`, `put_mcp_server/3`, `delete_mcp_server/2`,
  `put_mcp_tool/4`), which applies it to the one server it names with no
  restart. Every answer is a row from `McpServers.Row`, the one owner of its
  shape and its words.

  A form writes a server as fields: `command_line` (split as a shell would,
  `McpServers.CommandLine`) or `url`, `cwd`, `env_names`, `auth`,
  `key_header`, `header_names` (the headers besides the key's own) and
  `oauth_client_id`. A refusal is `invalid_params` with the daemon's sentence
  and the field it is about, named as the form names it, so the writer's
  `command`/`args`, `env_secrets` and `header_secrets` become `command_line`,
  `env_names` and `header_names` here. Values never ride these methods: they
  arrive through `secret.set mcp:<name>/…`. A leading `~` in `command_line`
  or `cwd` is the home folder the daemon gives the program (`:home`, the
  daemon's own by default), so the file holds the absolute path that runs.

  `draft/2` reads what the owner typed or pasted into the add form (a URL, a
  command line, a configuration block, `McpServers.Interchange`) and answers
  drafts that fill the form, writing nothing. A value the paste carried is held
  in memory under its draft's `draft_id` (`McpServers.DraftValues`), and an add
  that names it stores the values for the names the form still declares.

  `import_scan/1` reads the other apps' settings on this Mac
  (`McpServers.ImportSources`) when the owner opens the import page, and only
  then (D3), and answers the servers they hold as candidates, names only.
  `import_servers/2` reads them again, never from what a scan saw, and adds
  each server asked for through the add path an add takes, with the values
  its file held stored as a paste's are and `origin = "imported:<source>"`.

  A check (`mcp_check`) is a job: it connects the server, starting it again if
  it is not running or has failed and waiting for it if it is starting, then
  asks it for its tools once and answers how many and how long that took. Only
  a server the daemon runs (`McpSupervisor.runs?/1`) is checked.
  """

  alias FermixCore.Auth.Redaction
  alias FermixCore.Capabilities.MCP.Config, as: McpConfig
  alias FermixCore.Capabilities.MCP.LoginPath
  alias FermixCore.Capabilities.MCP.OAuth.Grant
  alias FermixCore.Capabilities.MCP.Remote.Endpoint
  alias FermixCore.Capabilities.MCP.RuntimeStatus
  alias FermixCore.Capabilities.MCP.Secrets, as: McpSecrets
  alias FermixCore.Capabilities.MCP.Supervisor, as: McpSupervisor
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.McpServers.Candidate
  alias FermixCore.Management.McpServers.CommandLine
  alias FermixCore.Management.McpServers.Draft
  alias FermixCore.Management.McpServers.DraftValues
  alias FermixCore.Management.McpServers.ImportSources
  alias FermixCore.Management.McpServers.Interchange
  alias FermixCore.Management.McpServers.PastedValues
  alias FermixCore.Management.McpServers.Row
  alias FermixCore.Management.Secrets
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState

  require Logger

  @transport_fields %{
    stdio: ~w(command_line cwd env_names),
    http: ~w(url auth key_header header_names oauth_client_id)
  }
  @text_bytes %{
    "command_line" => 4_096,
    "url" => 2_048,
    "cwd" => 1_024,
    "key_header" => 64,
    "oauth_client_id" => 256
  }
  @nullable ~w(cwd key_header oauth_client_id)
  @lists %{"env_names" => 64, "header_names" => 32}
  @max_name_bytes 128
  # The most servers one import names, and the most read from one settings
  # file: the most this daemon holds.
  @import_listed McpConfig.max_servers()
  @auth_modes ~w(auto header none)
  # The writer's keys, named as the form names them.
  @wire_fields %{
    "command" => "command_line",
    "args" => "command_line",
    "env_secrets" => "env_names",
    "header_secrets" => "header_names"
  }
  # A check waits for the server to connect, leaving the rest of its budget for
  # the one tool listing it then asks for. The wait outlasts a first start's own
  # verdict (`MCP.Server`'s 60 s), so the job reports how the start ended.
  @listing_reserve_ms 10_000

  @no_server "There is no MCP server by that name."
  @expired_draft "This paste has expired. Paste it again."
  @import_shape "This is a list of at most #{@import_listed} servers, each with its source and name."

  @type error ::
          {:invalid_params, String.t(), String.t()}
          | {:busy, String.t()}
          | {:unavailable, String.t()}
          | {:external_change, [String.t()]}
          | {:config_unreadable, String.t()}

  @doc "Every operator server, the most there may be, and whether one more fits."
  @spec list(keyword()) :: {:ok, map()}
  def list(opts \\ []) when is_list(opts) do
    servers = servers(opts)
    sources = sources(opts)

    {:ok,
     %{
       "servers" => Enum.map(servers, &row(&1, sources, [])),
       "limits" => %{"max_servers" => McpConfig.max_servers()},
       "can_add" => length(servers) < McpConfig.max_servers()
     }}
  end

  @doc "One server's row, with the tools it listed."
  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def get(name, opts \\ []) when is_binary(name) and is_list(opts) do
    with {:ok, server} <- fetch_server(name, opts) do
      {:ok, %{"server" => row(server, sources(opts), tools?: true)}}
    end
  end

  @doc """
  The servers `text` describes, as drafts that fill the add form, and nothing
  written. Each draft that carried a value names it by its own `draft_id`, so
  each add takes only its own values. A command without a slash is resolved
  on the login shell's `PATH`, which a draft starts reading and waits for
  once, briefly; past the wait its `resolved_command` is null.
  """
  @spec draft(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def draft(text, opts \\ []) when is_binary(text) and is_list(opts) do
    with {:ok, translated} <- Interchange.translate(text, home(opts)) do
      login_path = Keyword.get(opts, :login_path, LoginPath)
      :ok = await_path(translated, login_path)
      names = Enum.map(servers(opts), & &1.name)
      {:ok, %{"drafts" => Enum.map(translated, &draft_row(&1, names, login_path, opts))}}
    end
  end

  @doc """
  Adds one server, `origin = "added"`, and starts a check of it. `job_id` is
  null when the server does not start yet, because a value it declares is not
  stored, or when no check could start beside the ones running.

  With a `draft_id`, the values its paste carried for the names the form still
  declares are stored under the name the form chose, after the server is
  written and before it starts: the write applies the server, which waits for
  them, and storing them starts it once. A refused add stores nothing, and
  leaves the `draft_id` for the next try.
  """
  @spec add(map(), keyword()) :: {:ok, map()} | {:error, error()}
  def add(params, opts \\ []) when is_map(params) and is_list(opts) do
    {draft_id, params} = Map.pop(params, "draft_id")

    with {:ok, name} <- name_param(params),
         {:ok, transport} <- transport_param(params),
         :ok <- draft_held(draft_id, opts),
         {:ok, attrs} <- attrs(transport, params, nil, opts),
         attrs = Map.put(attrs, "origin", "added"),
         {:ok, server, row} <- add_server(name, attrs, fn -> taken(draft_id, opts) end, opts) do
      {:ok, %{"server" => row, "job_id" => first_check(server, row, opts)}}
    end
  end

  @doc """
  The MCP servers other apps' settings on this Mac hold, as `candidates` for
  the import page, each with where it comes from, the names of the values it
  declares and never a value, read now (D3). A server one of them holds that
  could not be added as it is written, and a settings file that could not be
  read, is a `skipped` entry with the daemon's sentence; neither stops the
  rest. At most 32 servers are read from one file. A local command is
  resolved as a draft's is.
  """
  @spec import_scan(keyword()) :: {:ok, map()}
  def import_scan(opts \\ []) when is_list(opts) do
    {found, skipped} =
      ImportSources.all()
      |> Enum.map(&scan_source(&1, opts))
      |> Enum.unzip()

    found = List.flatten(found)
    login_path = Keyword.get(opts, :login_path, LoginPath)
    :ok = await_path(Enum.map(found, &elem(&1, 1)), login_path)
    names = Enum.map(servers(opts), & &1.name)

    {:ok,
     %{
       "candidates" => Enum.map(found, &candidate(&1, names, login_path)),
       "skipped" => List.flatten(skipped)
     }}
  end

  @doc """
  Adds each server `servers` names (`[%{"source" => id, "name" => name}]`, at
  most 32), read again from its source's file, through the add path: the block,
  then the values the file held under `mcp:<name>/…`, then one start, with
  `origin = "imported:<source>"`. Answers the new rows in `servers` and, for
  each server that was not added, its sentence in `refused`: one refused
  server leaves the others. A settings file changed outside Fermix refuses the
  whole import before anything is read.
  """
  @spec import_servers(term(), keyword()) :: {:ok, map()} | {:error, error()}
  def import_servers(servers, opts \\ []) when is_list(opts) do
    with {:ok, wanted} <- import_param(servers),
         :ok <- RestartState.writable() do
      read = Map.new(Enum.uniq_by(wanted, & &1.id), &{&1.id, read_source(&1, opts)})

      {added, refused} =
        wanted
        |> Enum.map(fn source -> import_one(source, read[source.id], opts) end)
        |> Enum.split_with(&match?({:ok, _row}, &1))

      {:ok,
       %{
         "servers" => Enum.map(added, fn {:ok, row} -> row end),
         "refused" => Enum.map(refused, fn {:refused, entry} -> entry end)
       }}
    end
  end

  @doc """
  Changes the fields given of one server. Its name and transport stay; a value
  it no longer declares is deleted from the secret store.
  """
  @spec update(map(), keyword()) :: {:ok, map()} | {:error, error()}
  def update(params, opts \\ []) when is_map(params) and is_list(opts) do
    with {:ok, name} <- name_param(params),
         {:ok, before} <- fetch_server(name, opts),
         {:ok, attrs} <- attrs(before.transport, params, before, opts),
         attrs = with_transport(attrs, params, before),
         :ok <- write(fn -> put_server(name, attrs, opts) end),
         {:ok, server} <- fetch_server(name, opts) do
      :ok = forget_dropped(before, server)
      {:ok, %{"server" => row(server, sources(opts), [])}}
    end
  end

  @doc "Removes one server, the values it declares, its sign-in grant and its live status."
  @spec remove(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def remove(name, opts \\ []) when is_binary(name) and is_list(opts) do
    with :ok <- write(fn -> ConfigStore.delete_mcp_server(name, writer_opts(opts)) end) do
      :ok = clear_status(name, opts)
      {:ok, %{"name" => name, "removed" => true}}
    end
  end

  @doc "Turns one server on."
  @spec enable(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def enable(name, opts \\ []) when is_binary(name) and is_list(opts), do: switch(name, nil, opts)

  @doc "Turns one server off."
  @spec disable(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def disable(name, opts \\ []) when is_binary(name) and is_list(opts),
    do: switch(name, false, opts)

  @doc "Switches one tool of one server on or off. The server keeps running."
  @spec tool_set(String.t(), String.t(), boolean(), keyword()) :: {:ok, map()} | {:error, error()}
  def tool_set(name, tool, enabled, opts \\ [])
      when is_binary(name) and is_binary(tool) and is_boolean(enabled) and is_list(opts) do
    with :ok <- write(fn -> ConfigStore.put_mcp_tool(name, tool, enabled, writer_opts(opts)) end) do
      row_result(name, opts)
    end
  end

  @doc """
  Starts one check. A server the daemon does not run (turned off, naming
  nothing to start, or waiting for a value) is refused with its own row's
  sentence.
  """
  @spec check_start(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def check_start(name, opts \\ []) when is_binary(name) and is_list(opts) do
    with {:ok, server} <- fetch_server(name, opts),
         :ok <- checkable(server, row(server, sources(opts), [])) do
      start_check(server, opts)
    end
  end

  # --- drafts ---------------------------------------------------------------

  # One wait for the login shell's PATH covers every bare command in a paste.
  defp await_path(translated, login_path) do
    if Enum.any?(translated, &bare_command?(&1.server)), do: LoginPath.await_read(login_path)
    :ok
  end

  defp bare_command?(%{transport: :stdio, command: command}),
    do: not String.contains?(command, "/")

  defp bare_command?(_server), do: false

  defp draft_row(%{server: server, values: values} = translated, names, login_path, opts) do
    Draft.build(translated, %{
      resolution: resolution(server, login_path),
      conflict: Enum.any?(names, &McpConfig.same_prefix?(&1, server.name)),
      draft_id: hold(values, opts)
    })
  end

  defp hold(values, opts) do
    if PastedValues.empty?(values), do: nil, else: DraftValues.hold(draft_values(opts), values)
  end

  defp draft_held(nil, _opts), do: :ok

  defp draft_held(id, opts) do
    if is_binary(id) and DraftValues.held?(draft_values(opts), id),
      do: :ok,
      else: refuse("draft_id", @expired_draft)
  end

  # The id was held a moment ago; one that expired or was taken by another add
  # since leaves the server waiting for what it declares, as its row says.
  defp taken(nil, _opts), do: nil

  defp taken(id, opts) do
    case DraftValues.take(draft_values(opts), id) do
      {:ok, values} -> values
      :error -> nil
    end
  end

  # The one add path, an add's and an import's: the block, under the config
  # lock that refuses a name already here; then the values for the names it
  # declares, read only once the block is written; then one start, when they
  # complete it (`Secrets.store_mcp_values/3`).
  defp add_server(name, attrs, values, opts) do
    with :ok <- write(fn -> ConfigStore.add_mcp_server(name, attrs, writer_opts(opts)) end),
         {:ok, server} <- fetch_server(name, opts) do
      :ok = store_values(server, values.(), opts)
      {:ok, server, row(server, sources(opts), [])}
    end
  end

  defp store_values(_server, nil, _opts), do: :ok

  defp store_values(server, values, opts),
    do: Secrets.store_mcp_values(server, values, writer_opts(opts))

  # --- import ---------------------------------------------------------------

  defp scan_source(source, opts) do
    case read_source(source, opts) do
      {:ok, results, over?} -> scanned(source, results, over?, opts)
      {:error, sentence} -> {[], [skipped(source, nil, sentence)]}
    end
  end

  # A server is offered only where the add form would take it as written, so
  # what the page lists is what an import adds.
  defp scanned(source, results, over?, opts) do
    {found, skipped} =
      Enum.reduce(results, {[], []}, fn {key, result}, {found, skipped} ->
        case offerable(result, opts) do
          {:ok, translated} ->
            {[{source, translated} | found], skipped}

          {:error, {:invalid_params, _field, sentence}} ->
            {found, [skipped(source, key, sentence) | skipped]}
        end
      end)

    over = if over?, do: [skipped(source, nil, over_sentence(source))], else: []
    {Enum.reverse(found), Enum.reverse(skipped) ++ over}
  end

  defp over_sentence(source),
    do: "Fermix lists the first #{@import_listed} servers in #{source.label}'s settings."

  # One read and one translation of a source's file per call: its servers by
  # their key there, each translated or refused on its own.
  defp read_source(source, opts) do
    with {:ok, entries} <- ImportSources.servers(source, import_home(opts)) do
      results =
        entries
        |> Enum.take(@import_listed)
        |> Enum.map(fn {key, raw} ->
          {key, Interchange.translate_server(source.format, key, raw, home(opts))}
        end)

      {:ok, results, length(entries) > @import_listed}
    end
  end

  defp offerable({:ok, translated}, opts) do
    with {:ok, _attrs} <- form_attrs(translated, opts), do: {:ok, translated}
  end

  defp offerable(refused, _opts), do: refused

  # A translated server as the add form would send it, typed and composed by
  # the form's own rules, so an import writes what an add of it would.
  defp form_attrs(%{server: server} = translated, opts),
    do: attrs(server.transport, form_fields(translated), nil, opts)

  defp form_fields(%{name: name, server: %{transport: :stdio} = server}) do
    %{
      "name" => name,
      "transport" => "stdio",
      "command_line" => CommandLine.join([server.command | server.args]),
      "cwd" => server.cwd,
      "env_names" => server.env_secrets
    }
  end

  defp form_fields(%{name: name, server: %{transport: :http} = server}) do
    %{
      "name" => name,
      "transport" => "http",
      "url" => server.url,
      "auth" => Atom.to_string(server.auth),
      "key_header" => server.key_header,
      "header_names" => server.header_secrets -- [server.key_header]
    }
  end

  defp candidate({source, %{server: server} = translated}, names, login_path) do
    Candidate.build(source, translated, %{
      resolution: resolution(server, login_path),
      conflict: Enum.any?(names, &McpConfig.same_prefix?(&1, server.name))
    })
  end

  defp skipped(source, key, sentence) do
    %{
      "source" => source.id,
      "source_label" => source.label,
      "name" => key && String.slice(key, 0, @max_name_bytes),
      "sentence" => sentence
    }
  end

  defp import_param(servers) when is_list(servers) and length(servers) in 1..@import_listed do
    Enum.reduce_while(servers, {:ok, []}, fn entry, {:ok, acc} ->
      case wanted(entry) do
        {:ok, source} -> {:cont, {:ok, [source | acc]}}
        :error -> {:halt, refuse("servers", @import_shape)}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      refusal -> refusal
    end
  end

  defp import_param(_servers), do: refuse("servers", @import_shape)

  defp wanted(%{"source" => id, "name" => name} = entry)
       when map_size(entry) == 2 and is_binary(id) and is_binary(name) and
              byte_size(name) in 1..@max_name_bytes do
    with {:ok, source} <- ImportSources.fetch(id), do: {:ok, Map.put(source, :name, name)}
  end

  defp wanted(_entry), do: :error

  defp import_one(wanted, {:error, sentence}, _opts), do: import_refused(wanted, sentence)

  defp import_one(wanted, {:ok, results, _over?}, opts) do
    case importable(results, wanted.name) do
      {:ok, translated} -> import_added(wanted, translated, opts)
      {:error, {:invalid_params, _field, sentence}} -> import_refused(wanted, sentence)
      :gone -> import_refused(wanted, "This server is no longer in #{wanted.label}'s settings.")
    end
  end

  # The server the scan named, by the name it was offered under; one that no
  # longer translates is found by its key, and answers why.
  defp importable(results, name) do
    case Enum.find(results, &offered?(&1, name)) || Enum.find(results, &refused?(&1, name)) do
      {_key, result} -> result
      nil -> :gone
    end
  end

  defp offered?({_key, {:ok, %{name: name}}}, name), do: true
  defp offered?(_result, _name), do: false

  defp refused?({name, {:error, _refusal}}, name), do: true
  defp refused?(_result, _name), do: false

  defp import_added(wanted, translated, opts) do
    origin = "imported:" <> wanted.id

    with {:ok, attrs} <- form_attrs(translated, opts),
         {:ok, _server, row} <-
           add_server(
             translated.name,
             Map.put(attrs, "origin", origin),
             fn -> translated.values end,
             opts
           ) do
      {:ok, row}
    else
      {:error, {:invalid_params, _field, sentence}} ->
        import_refused(wanted, sentence)

      {:error, reason} ->
        Logger.error(
          "MCP import of #{wanted.name} from #{wanted.id} was refused: #{Redaction.format(reason)}"
        )

        import_refused(wanted, "Fermix could not add it. See the daemon log.")
    end
  end

  defp import_refused(wanted, sentence),
    do: {:refused, %{"source" => wanted.id, "name" => wanted.name, "sentence" => sentence}}

  # --- rows -----------------------------------------------------------------

  defp row(server, sources, row_opts), do: Row.build(server, facts(server, sources), row_opts)

  defp row_result(name, opts) do
    with {:ok, server} <- fetch_server(name, opts) do
      {:ok, %{"server" => row(server, sources(opts), [])}}
    end
  end

  # What the daemon knows beside the configuration: read once per answer, so a
  # list of 32 rows asks the status table once.
  defp sources(opts) do
    %{
      entries: runtime_entries(opts),
      supervisor: supervisor(opts),
      login_path: Keyword.get(opts, :login_path, LoginPath),
      grant_opts: Keyword.take(opts, [:auth_path])
    }
  end

  defp facts(server, sources) do
    source_id = {:operator, server.name}

    %{
      presence: McpSecrets.presence(server),
      entry: Map.get(sources.entries, source_id),
      alive?: sources.supervisor.subtree_alive?(source_id),
      resolution: resolution(server, sources.login_path),
      grant: grant(server, sources.grant_opts)
    }
  end

  # Only an `auto` server signs in; another has no grant to read.
  defp grant(%{transport: :http, auth: :auto, url: url} = server, grant_opts) when is_binary(url),
    do: Grant.row_state(server, grant_opts)

  defp grant(_server, _grant_opts), do: nil

  # Never the blocking resolve: a row answers from the PATH already read.
  defp resolution(%{transport: :stdio, command: command, cwd: cwd}, login_path)
       when is_binary(command) and command != "",
       do: LoginPath.known(login_path, command, cwd)

  defp resolution(_server, _login_path), do: nil

  # The live table lives in the daemon's own memory. A tree-less verb has no
  # table, and its absence is "no status yet", never a status.
  defp runtime_entries(opts) do
    status = runtime_status(opts)
    if alive?(status), do: RuntimeStatus.list(status), else: %{}
  end

  # --- params ---------------------------------------------------------------

  defp name_param(%{"name" => name})
       when is_binary(name) and byte_size(name) in 1..@max_name_bytes,
       do: {:ok, name}

  defp name_param(_params), do: refuse("name", "A server has a name.")

  defp transport_param(%{"transport" => "stdio"}), do: {:ok, :stdio}
  defp transport_param(%{"transport" => "http"}), do: {:ok, :http}

  defp transport_param(_params),
    do: refuse("transport", "A server runs on this Mac (stdio) or at a URL (http).")

  defp attrs(transport, params, before, opts) do
    fields = Map.drop(params, ["name", "transport"])

    with :ok <- of_transport(transport, fields),
         :ok <- typed(fields) do
      compose(transport, fields, before, home(opts))
    end
  end

  # An update that names another transport is passed to the writer, which
  # refuses it: a server's tools were learned under the transport it has.
  defp with_transport(attrs, %{"transport" => transport}, before) do
    if transport == Atom.to_string(before.transport),
      do: attrs,
      else: Map.put(attrs, "transport", transport)
  end

  defp with_transport(attrs, _params, _before), do: attrs

  defp of_transport(transport, fields) do
    case Enum.find(Map.keys(fields), &(&1 not in @transport_fields[transport])) do
      nil -> :ok
      field -> refuse(field, other_transport_sentence(transport))
    end
  end

  defp other_transport_sentence(:stdio), do: "A server on this Mac does not take this."
  defp other_transport_sentence(:http), do: "A server at a URL does not take this."

  defp typed(fields) do
    Enum.reduce_while(fields, :ok, fn {field, value}, :ok ->
      case typed(field, value) do
        :ok -> {:cont, :ok}
        {:error, _refusal} = error -> {:halt, error}
      end
    end)
  end

  defp typed("auth", value) when value in @auth_modes, do: :ok
  defp typed("auth", _value), do: refuse("auth", "Sign-in is auto, header or none.")
  defp typed(field, nil) when field in @nullable, do: :ok

  defp typed(field, value) when is_map_key(@text_bytes, field) do
    max = Map.fetch!(@text_bytes, field)

    if is_binary(value) and byte_size(value) in 1..max,
      do: :ok,
      else: refuse(field, "This is text of at most #{max} bytes.")
  end

  defp typed(field, values) when is_map_key(@lists, field) do
    max = Map.fetch!(@lists, field)

    if is_list(values) and length(values) <= max and Enum.all?(values, &name?/1),
      do: :ok,
      else: refuse(field, "This is a list of at most #{max} names.")
  end

  defp name?(value), do: is_binary(value) and byte_size(value) in 1..@max_name_bytes

  defp compose(:stdio, fields, _before, home) do
    with {:ok, command} <- command_attrs(fields, home),
         {:ok, fields} <- cwd_at_home(fields, home) do
      {:ok, Map.merge(command, renamed(fields, %{"cwd" => "cwd", "env_names" => "env_secrets"}))}
    end
  end

  defp compose(:http, fields, before, _home) do
    with :ok <- url_check(fields) do
      attrs = renamed(fields, %{"url" => "url", "oauth_client_id" => "oauth_client_id"})
      attrs = if before, do: attrs, else: Map.put(attrs, "transport", "http")
      {:ok, Map.merge(attrs, auth_attrs(fields, before))}
    end
  end

  defp command_attrs(%{"command_line" => line}, home) do
    with {:ok, {command, args}} <- CommandLine.split(line, home) do
      {:ok, %{"command" => command, "args" => nil_if_empty(args)}}
    end
  end

  defp command_attrs(_fields, _home), do: {:ok, %{}}

  # The working folder takes the command line's own rule for a leading `~`.
  defp cwd_at_home(%{"cwd" => cwd} = fields, home) when is_binary(cwd) do
    with {:ok, path} <- CommandLine.expand_home(cwd, home, "cwd") do
      {:ok, Map.put(fields, "cwd", path)}
    end
  end

  defp cwd_at_home(fields, _home), do: {:ok, fields}

  # The one rule for an owner's URL is the remote rail's own, so a URL the
  # server would be refused at start is refused at the form instead.
  defp url_check(%{"url" => url}) do
    case Endpoint.operator(url) do
      {:ok, _endpoint} -> :ok
      {:error, _reason} -> refuse("url", Row.url_sentence())
    end
  end

  defp url_check(_fields), do: :ok

  # `header_secrets` is the headers besides the key's, and the key's own last:
  # the form names them apart, the configuration holds them together (§4).
  defp auth_attrs(fields, before) do
    if Enum.any?(~w(auth key_header header_names), &Map.has_key?(fields, &1)) do
      auth = Map.get(fields, "auth") || auth_of(before)
      key_header = Map.get(fields, "key_header", kept_key_header(auth, before))
      extras = Map.get(fields, "header_names", extra_headers(before))

      %{
        "auth" => auth,
        "key_header" => key_header,
        "header_secrets" => nil_if_empty(with_key(extras, key_header))
      }
    else
      %{}
    end
  end

  defp auth_of(nil), do: nil
  defp auth_of(server), do: Atom.to_string(server.auth)

  # A key header means something only to a server that sends a key.
  defp kept_key_header("header", %{key_header: key_header}), do: key_header
  defp kept_key_header(_auth, _before), do: nil

  defp extra_headers(nil), do: []
  defp extra_headers(server), do: server.header_secrets -- [server.key_header]

  defp with_key(extras, nil), do: extras

  defp with_key(extras, key_header) do
    if Enum.any?(extras, &(String.downcase(&1) == String.downcase(key_header))),
      do: extras,
      else: extras ++ [key_header]
  end

  defp renamed(fields, mapping) do
    for {field, key} <- mapping, Map.has_key?(fields, field), into: %{} do
      {key, nil_if_empty(Map.fetch!(fields, field))}
    end
  end

  defp nil_if_empty([]), do: nil
  defp nil_if_empty(value), do: value

  # --- writes ---------------------------------------------------------------

  defp put_server(name, attrs, opts),
    do: ConfigStore.put_mcp_server(name, attrs, writer_opts(opts))

  defp switch(name, enabled, opts) do
    with {:ok, _server} <- fetch_server(name, opts),
         :ok <- write(fn -> put_server(name, %{"enabled" => enabled}, opts) end) do
      row_result(name, opts)
    end
  end

  defp write(commit) do
    case commit.() do
      :ok -> :ok
      {:error, {:invalid_params, field, sentence}} -> refuse(wire_field(field), sentence)
      {:error, {:external_change, _sections} = reason} -> {:error, reason}
      {:error, {:config_unreadable, _sentence} = reason} -> {:error, reason}
      {:error, reason} -> unavailable("the write was refused", reason)
    end
  end

  defp wire_field(field), do: Map.get(@wire_fields, field, field)

  # A value the server no longer declares could never be read or deleted again
  # (the family cannot be listed), so it goes with the declaration. The write
  # has landed, so a refused delete is said in the log and the row answers.
  defp forget_dropped(before, server) do
    dropped = McpSecrets.declared(before) -- McpSecrets.declared(server)

    Enum.each(dropped, fn ref ->
      case McpSecrets.delete(server.name, ref) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "MCP server #{server.name} kept a value it no longer declares: " <>
              Redaction.format(reason)
          )
      end
    end)
  end

  # The live status, and the discovery it carries, belong to the removed
  # server and not to one added later under its name.
  defp clear_status(name, opts) do
    status = runtime_status(opts)
    if alive?(status), do: RuntimeStatus.clear(status, {:operator, name}), else: :ok
  end

  # --- checks ---------------------------------------------------------------

  defp first_check(server, row, opts) do
    with :ok <- checkable(server, row),
         {:ok, %{"job_id" => job_id}} <- start_check(server, opts) do
      job_id
    else
      {:error, {:invalid_params, "name", _sentence}} ->
        nil

      {:error, {:busy, _kind}} ->
        Logger.warning("MCP server #{server.name} was added; no check could start beside others")
        nil
    end
  end

  # The daemon's own rule for a server it runs, so the gate and the start
  # never disagree; the row says why one does not run.
  defp checkable(server, row) do
    if McpSupervisor.runs?(server),
      do: :ok,
      else: refuse("name", row["status_sentence"])
  end

  defp start_check(server, opts) do
    run = check_run(server, opts)

    case Jobs.start(:mcp_check, Keyword.merge(jobs_opts(opts), name: server.name, run: run)) do
      {:ok, view} -> {:ok, view}
      {:error, :busy} -> {:error, {:busy, "mcp_check"}}
    end
  end

  defp check_run(server, opts) do
    fn _job_id, report ->
      report.({:phase, "connecting"})

      with {:ok, generation} <- connected_generation(server, opts),
           :ok <- await_ready(server, generation, opts) do
        report.({:phase, "listing"})
        list_tools(server, opts)
      end
    end
  end

  # A server that is starting is waited for; one that is not running, or whose
  # last status is a failure, is started again, which proves the old one gone.
  defp connected_generation(server, opts) do
    source_id = {:operator, server.name}

    if live?(source_id, opts),
      do: current_generation(source_id, opts),
      else: restart(server, source_id, opts)
  end

  defp live?(source_id, opts) do
    supervisor(opts).subtree_alive?(source_id) and
      match?(
        {:ok, %{status: status}} when status in [:connecting, :ready],
        fetch(source_id, opts)
      )
  end

  defp restart(server, source_id, opts) do
    case supervisor(opts).restart_server(source_id, server) do
      {:ok, _pid} -> current_generation(source_id, opts)
      {:error, reason} -> unavailable_check("did not start", reason)
    end
  end

  defp current_generation(source_id, opts) do
    case RuntimeStatus.owner(runtime_status(opts), source_id) do
      {:ok, _owner, generation} -> {:ok, generation}
      :error -> unavailable_check("has no owner", :no_owner)
    end
  end

  defp await_ready(server, generation, opts) do
    wait_ms = Jobs.budget_ms(:mcp_check) - @listing_reserve_ms

    case RuntimeStatus.await(runtime_status(opts), {:operator, server.name}, generation, wait_ms) do
      {:ok, :ready} -> :ok
      {:error, :timeout} -> check_failed("The server is still starting.")
      {:error, {:generation_replaced, _source}} -> check_failed("It restarted during the check.")
      {:error, {:cleared, _source}} -> check_failed("It was removed during the check.")
      {:error, {_status, _detail, _subject}} -> check_failed(row_sentence(server, opts))
    end
  end

  # The server's own row says why it did not connect, in the words it shows.
  defp row_sentence(server, opts) do
    row = row(server, sources(opts), [])
    row["last_error"] || row["status_sentence"]
  end

  defp list_tools(server, opts) do
    started = System.monotonic_time(:millisecond)

    case supervisor(opts).list_tools({:operator, server.name}, server) do
      {:ok, tools} ->
        latency_ms = System.monotonic_time(:millisecond) - started
        {:ok, %{"tool_count" => length(tools), "latency_ms" => latency_ms}}

      {:error, reason} ->
        Logger.warning(
          "MCP server #{server.name} did not list its tools for a check: " <>
            RuntimeStatus.describe(RuntimeStatus.classify(reason))
        )

        check_failed("The server did not answer when asked for its tools.")
    end
  end

  defp check_failed(sentence), do: {:error, {:unavailable, sentence}}

  defp unavailable_check(what, reason) do
    Logger.error("MCP check: the server #{what}: #{Redaction.format(reason)}")
    check_failed("Fermix could not start the server. See the daemon log.")
  end

  # --- plumbing -------------------------------------------------------------

  defp servers(opts), do: Keyword.get(opts, :servers, &McpConfig.configured/0).()

  defp fetch_server(name, opts) do
    case Enum.find(servers(opts), &(&1.name == name)) do
      nil -> refuse("name", @no_server)
      server -> {:ok, server}
    end
  end

  defp fetch(source_id, opts), do: RuntimeStatus.fetch(runtime_status(opts), source_id)

  defp writer_opts(opts), do: Keyword.take(opts, [:mcp_supervisor])
  defp import_home(opts), do: Keyword.get_lazy(opts, :import_home, fn -> home(opts) end)
  defp draft_values(opts), do: Keyword.get(opts, :draft_values, DraftValues)
  defp home(opts), do: Keyword.get_lazy(opts, :home, &System.user_home!/0)
  defp supervisor(opts), do: Keyword.get(opts, :mcp_supervisor, McpSupervisor)
  defp runtime_status(opts), do: Keyword.get(opts, :runtime_status, RuntimeStatus)
  defp jobs_opts(opts), do: Keyword.get(opts, :jobs, [])

  defp alive?(name) when is_atom(name), do: Process.whereis(name) != nil
  defp alive?(pid) when is_pid(pid), do: Process.alive?(pid)

  defp refuse(field, sentence), do: {:error, {:invalid_params, field, sentence}}

  defp unavailable(what, reason) do
    Logger.error("management mcp servers: #{what}: #{Redaction.format(reason)}")
    {:error, {:unavailable, "mcp_servers"}}
  end
end
