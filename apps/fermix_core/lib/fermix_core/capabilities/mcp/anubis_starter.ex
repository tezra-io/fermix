defmodule FermixCore.Capabilities.MCP.AnubisStarter do
  @moduledoc """
  Behaviour for "build the client child spec for one MCP server."

  Production uses `Default`, which spawns either an `Anubis.Client` over a
  stdio transport (`command`/`args`/`env`) or, for a `remote_mcp` plugin spec
  or an operator `http` server, a `Remote.Owner` holding one authenticated
  Streamable HTTP session (M27 §7.3, M74 E4).
  Tests substitute a stub that returns no children (and records the parsed
  config) so they don't have to spawn real subprocesses or open sockets.

  `config` carries the supervisor's collaborators: a remote owner and an
  operator stdio transport publish into the `RuntimeStatus` sink, and the
  transport finds its program through `login_path`.

  Returning `nil` for `:client_name` tells `MCP.Supervisor` not to override
  the `:client` opt passed to `MCP.Server` — the test path that pre-supplies
  a `:client` keeps using it.
  """

  @type result :: %{
          required(:children) => [Supervisor.child_spec()],
          required(:client_name) => GenServer.name() | nil
        }

  @callback child_specs_for(server :: map(), config :: map()) :: result()
end

defmodule FermixCore.Capabilities.MCP.AnubisStarter.Default do
  @moduledoc """
  Production starter.

  A spec is either local or remote, never both (`McpSource` refuses the blend):
  `transport: :streamable_http` (a plugin's) and `transport: :http` (an
  operator server's) build a `Remote.Owner`; a stdio spec with a `:command`
  builds an `Anubis.Client`; a spec with neither gets an empty child list —
  the test/discoverer-only path.

  The stdio client runs over one of two transports. An operator server
  (`[mcp.servers.*]`, `transport: :stdio`) runs over `StdioTransport`, which
  reads its secrets itself, builds its environment, resolves its program and
  keeps its stderr (M74 E3). A plugin's `local_stdio` server still runs over
  Anubis's own, inside `Anubis.Client`'s supervisor, with the environment
  `MCP.Supervisor` resolved into its spec.

  Every name a client is known by is source-qualified, `{:operator, "x"}` or
  `{:plugin, "x"}`: its registered name, and the `client_info` name it sends.
  Anubis keys its per-client ETS cache (`Anubis.Client.Cache`) by
  `client_info["name"]` and creates the table protected, owned by the first
  client to touch it, so two clients sharing a name crash on the second
  `tools/list` reply. An operator server and a plugin of one name run side by
  side, as two local plugins do.

  The remote owner is `:transient` + `significant: true`: when it exhausts its
  bounded startup attempts it exits `:normal`, which is terminal for the
  subtree (`auto_shutdown: :any_significant`) rather than a respawn loop
  against an endpoint that is rejecting the credential. The stdio transport is
  too, for a start that cannot run its program.
  """

  @behaviour FermixCore.Capabilities.MCP.AnubisStarter

  alias FermixCore.Capabilities.MCP.AnubisStarter.OperatorClient
  alias FermixCore.Capabilities.MCP.Remote.Owner, as: RemoteOwner
  alias FermixCore.Capabilities.MCP.Server, as: McpServer
  alias FermixCore.Capabilities.MCP.StdioTransport
  alias FermixCore.Timeouts

  # Anubis's own default for a request the client makes on its own behalf.
  @operation_timeout_ms 30_000
  @transport_keys [:source_id, :name, :command, :args, :cwd, :env, :env_secrets, :pass_env]

  @impl true
  def child_specs_for(%{name: name} = server, config) when is_binary(name) and is_map(config) do
    case Map.get(server, :transport) do
      remote when remote in [:streamable_http, :http] -> remote_specs(server, config)
      transport -> local_specs(transport, server, config)
    end
  end

  defp local_specs(transport, server, config) do
    case {transport, Map.get(server, :command)} do
      {_transport, command} when not is_binary(command) or command == "" ->
        %{children: [], client_name: nil}

      {:stdio, _command} ->
        operator_specs(server, config)

      {nil, command} ->
        plugin_specs(server, command)
    end
  end

  # The child spec carries the opaque `auth_ref` and nothing else about the
  # credential: an OTP child spec is retained for the child's lifetime and is
  # printed verbatim in a `failed_to_start_child` report.
  defp remote_specs(server, config) do
    source_id = Map.fetch!(server, :source_id)
    client_name = RemoteOwner.name_for(source_id)

    owner_spec =
      Supervisor.child_spec(
        {RemoteOwner,
         [
           name: client_name,
           spec: server,
           runtime_status: Map.get(config, :runtime_status)
         ]},
        id: {:remote_owner, source_id},
        restart: :transient,
        significant: true,
        # Long enough for `terminate/2` to run the authenticated session
        # teardown before the socket closes.
        shutdown: Timeouts.mcp_remote_teardown() + 2_000
      )

    %{children: [owner_spec], client_name: client_name}
  end

  # The client and its transport are children of the server's own subtree,
  # client first: the transport tells it to initialize once the program runs.
  # The client is started as a plain `GenServer`, because Anubis's start path
  # accepts only the transports it ships; its `init/1` takes the same options,
  # and `OperatorClient` is `Anubis.Client` with the one clause it lacks.
  defp operator_specs(server, config) do
    source_id = Map.fetch!(server, :source_id)
    client_name = client_name_for(source_id)
    transport_name = Module.concat(client_name, "Transport")

    client_options = %{
      name: client_name,
      transport: [layer: StdioTransport, name: transport_name],
      client_info: client_info(source_id),
      capabilities: %{},
      protocol_version: Anubis.Protocol.latest_version(),
      timeout: handshake_timeout_ms()
    }

    client_spec = %{
      id: {:anubis_client, source_id},
      start: {GenServer, :start_link, [OperatorClient, client_options, [name: client_name]]},
      restart: :permanent
    }

    transport_spec =
      Supervisor.child_spec(
        {StdioTransport,
         [
           name: transport_name,
           client: client_name,
           spec: Map.take(server, @transport_keys),
           runtime_status: Map.get(config, :runtime_status),
           login_path: Map.fetch!(config, :login_path)
         ]},
        id: {:stdio_transport, source_id},
        restart: :transient,
        significant: true
      )

    %{children: [client_spec, transport_spec], client_name: client_name}
  end

  # The client's own timeout ends the `initialize` it sends on its own behalf.
  # It outlasts `MCP.Server`'s first-connection window by one operation, so
  # the window alone decides how long a first start may take: a window that
  # closes ends this subtree, and the client in it, first.
  defp handshake_timeout_ms, do: McpServer.first_connection_ms() + @operation_timeout_ms

  defp plugin_specs(server, command) do
    source_id = Map.fetch!(server, :source_id)
    client_name = client_name_for(source_id)

    transport_opts =
      [command: command]
      |> add_optional(:args, Map.get(server, :args))
      |> add_optional(:env, Map.get(server, :env))
      |> add_optional(:cwd, Map.get(server, :cwd))

    client_spec =
      Supervisor.child_spec(
        {Anubis.Client,
         [
           name: client_name,
           transport: {:stdio, transport_opts},
           client_info: client_info(source_id),
           capabilities: %{}
         ]},
        id: {:anubis_client, source_id},
        restart: :permanent
      )

    %{children: [client_spec], client_name: client_name}
  end

  defp add_optional(opts, _key, nil), do: opts
  defp add_optional(opts, _key, value) when value == [] or value == %{}, do: opts
  defp add_optional(opts, key, value), do: Keyword.put(opts, key, value)

  defp client_name_for({kind, name}), do: :"#{__MODULE__}.Client.#{kind}.#{name}"

  defp client_info({kind, name}) do
    version = Application.spec(:fermix_core, :vsn) |> to_string()
    %{"name" => "fermix-#{kind}-#{name}", "version" => version}
  end
end

defmodule FermixCore.Capabilities.MCP.AnubisStarter.OperatorClient do
  @moduledoc """
  The callback module an operator stdio server's client runs (M74 E3):
  `Anubis.Client`, with the clauses it lacks.

  Anubis sends `initialize` on its own behalf, with `{self(), make_ref()}` as
  the caller to answer. Whatever ends that request without a handshake
  replies there: its timeout, an error the server answers, or a result
  without the `serverInfo` the protocol requires, which Anubis passes on as
  it would any answer. The reply reaches the client itself, which has no
  clause for it and stops on a `FunctionClauseError` (`anubis_mcp` 2.0.0 and
  2.1.0 alike). No other request names the client as its caller, so a reply
  here is that one. It is logged and dropped: the client stays up,
  uninitialized, and `MCP.Server`'s first-connection window decides, as for a
  program that never answers.

  Every other callback is Anubis's own.
  """

  @behaviour GenServer

  require Logger

  @impl GenServer
  defdelegate init(options), to: Anubis.Client

  @impl GenServer
  defdelegate handle_call(request, from, state), to: Anubis.Client

  @impl GenServer
  defdelegate handle_cast(request, state), to: Anubis.Client

  @impl GenServer
  defdelegate handle_continue(continue, state), to: Anubis.Client

  @impl GenServer
  def handle_info({ref, {:error, %Anubis.MCP.Error{reason: reason}}}, state)
      when is_reference(ref) do
    %{client_info: %{"name" => name}} = state

    Logger.warning(
      "MCP client #{name}: its initialize ended without a result: #{inspect(reason)}"
    )

    {:noreply, state}
  end

  def handle_info({ref, {:ok, %Anubis.MCP.Response{method: "initialize"}}}, state)
      when is_reference(ref) do
    %{client_info: %{"name" => name}} = state
    Logger.warning("MCP client #{name}: its initialize was answered without serverInfo")
    {:noreply, state}
  end

  def handle_info(message, state), do: Anubis.Client.handle_info(message, state)

  @impl GenServer
  defdelegate terminate(reason, state), to: Anubis.Client
end
