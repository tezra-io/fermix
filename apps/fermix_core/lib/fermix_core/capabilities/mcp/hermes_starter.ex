defmodule FermixCore.Capabilities.MCP.HermesStarter do
  @moduledoc """
  Behaviour for "build the Hermes (`Client.Base` + transport) child specs
  for one MCP server."

  Production uses `Default`, which spawns a `Hermes.Client.Base` linked to
  a `Hermes.Transport.STDIO` started from the server's `command/args/env`.
  Tests substitute a stub that returns no children (and records the parsed
  config) so they don't have to spawn real subprocesses.

  Returning `nil` for `:client_name` tells `MCP.Supervisor` not to override
  the `:client` opt passed to `MCP.Server` — the test path that pre-supplies
  a `:client` keeps using it.
  """

  @type result :: %{
          required(:children) => [Supervisor.child_spec()],
          required(:client_name) => GenServer.name() | nil
        }

  @callback child_specs_for(server :: map()) :: result()
end

defmodule FermixCore.Capabilities.MCP.HermesStarter.Default do
  @moduledoc """
  Production starter. Builds a `Hermes.Client.Base` + `Hermes.Transport.STDIO`
  pair for any server whose config provides a `:command`. Servers without
  `:command` get an empty child list — useful in tests and as a safety
  default until stdio config is supplied.
  """

  @behaviour FermixCore.Capabilities.MCP.HermesStarter

  alias Hermes.Client.Base
  alias Hermes.Transport.STDIO

  @impl true
  def child_specs_for(%{name: name} = server) when is_binary(name) do
    case Map.get(server, :command) do
      cmd when is_binary(cmd) and cmd != "" -> build_specs(server, cmd)
      _ -> %{children: [], client_name: nil}
    end
  end

  defp build_specs(server, command) do
    client_name = client_name_for(server.name)
    transport_name = transport_name_for(server.name)

    base_spec =
      Supervisor.child_spec(
        {Base,
         [
           transport: [layer: STDIO, name: transport_name],
           client_info: client_info(),
           capabilities: %{},
           name: client_name
         ]},
        id: {:hermes_base, server.name},
        restart: :permanent
      )

    transport_opts =
      [command: command, client: client_name, name: transport_name]
      |> add_optional(:args, Map.get(server, :args))
      |> add_optional(:env, Map.get(server, :env))

    transport_spec =
      Supervisor.child_spec({STDIO, transport_opts},
        id: {:hermes_stdio, server.name},
        restart: :permanent
      )

    %{children: [base_spec, transport_spec], client_name: client_name}
  end

  defp add_optional(opts, _key, nil), do: opts
  defp add_optional(opts, _key, value) when value == [] or value == %{}, do: opts
  defp add_optional(opts, key, value), do: Keyword.put(opts, key, value)

  defp client_name_for(server_name), do: :"#{__MODULE__}.Client.#{server_name}"
  defp transport_name_for(server_name), do: :"#{__MODULE__}.Transport.#{server_name}"

  defp client_info do
    version = Application.spec(:fermix_core, :vsn) |> to_string()
    %{"name" => "fermix", "version" => version}
  end
end
