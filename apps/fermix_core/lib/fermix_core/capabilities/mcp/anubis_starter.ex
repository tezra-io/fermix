defmodule FermixCore.Capabilities.MCP.AnubisStarter do
  @moduledoc """
  Behaviour for "build the client child spec for one MCP server."

  Production uses `Default`, which spawns either an `Anubis.Client` over a
  stdio transport (`command`/`args`/`env`) or, for a `remote_mcp` spec, a
  `Remote.Owner` holding one authenticated Streamable HTTP session (M27 §7.3).
  Tests substitute a stub that returns no children (and records the parsed
  config) so they don't have to spawn real subprocesses or open sockets.

  `config` carries the supervisor's collaborators; a remote owner needs the
  `RuntimeStatus` sink to publish `:connecting` and its terminal states into.

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
  `transport: :streamable_http` builds a `Remote.Owner`, a `:command` builds an
  `Anubis.Client` over stdio, and a spec with neither gets an empty child list
  — the test/discoverer-only path.

  The remote owner is `:transient` + `significant: true`: when it exhausts its
  bounded startup attempts it exits `:normal`, which is terminal for the
  subtree (`auto_shutdown: :any_significant`) rather than a respawn loop
  against an endpoint that is rejecting the credential.
  """

  @behaviour FermixCore.Capabilities.MCP.AnubisStarter

  alias FermixCore.Capabilities.MCP.Remote.Owner, as: RemoteOwner
  alias FermixCore.Timeouts

  @impl true
  def child_specs_for(%{name: name} = server, config) when is_binary(name) and is_map(config) do
    case Map.get(server, :transport) do
      :streamable_http -> remote_specs(server, config)
      _local_or_absent -> stdio_specs(server)
    end
  end

  defp stdio_specs(server) do
    case Map.get(server, :command) do
      cmd when is_binary(cmd) and cmd != "" -> build_specs(server, cmd)
      _no_command -> %{children: [], client_name: nil}
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

  defp build_specs(server, command) do
    client_name = client_name_for(server.name)

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
           client_info: client_info(),
           capabilities: %{}
         ]},
        id: {:anubis_client, server.name},
        restart: :permanent
      )

    %{children: [client_spec], client_name: client_name}
  end

  defp add_optional(opts, _key, nil), do: opts
  defp add_optional(opts, _key, value) when value == [] or value == %{}, do: opts
  defp add_optional(opts, key, value), do: Keyword.put(opts, key, value)

  defp client_name_for(server_name), do: :"#{__MODULE__}.Client.#{server_name}"

  defp client_info do
    version = Application.spec(:fermix_core, :vsn) |> to_string()
    %{"name" => "fermix", "version" => version}
  end
end
