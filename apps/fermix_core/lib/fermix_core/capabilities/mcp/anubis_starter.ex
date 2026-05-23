defmodule FermixCore.Capabilities.MCP.AnubisStarter do
  @moduledoc """
  Behaviour for "build the Anubis client child spec for one MCP server."

  Production uses `Default`, which spawns an `Anubis.Client` configured with
  a stdio transport started from the server's `command/args/env`. Tests
  substitute a stub that returns no children (and records the parsed config)
  so they don't have to spawn real subprocesses.

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

defmodule FermixCore.Capabilities.MCP.AnubisStarter.Default do
  @moduledoc """
  Production starter. Builds an `Anubis.Client` child for any server whose
  config provides a `:command`. Servers without `:command` get an empty child
  list — useful in tests and as a safety default until stdio config is supplied.
  """

  @behaviour FermixCore.Capabilities.MCP.AnubisStarter

  @impl true
  def child_specs_for(%{name: name} = server) when is_binary(name) do
    case Map.get(server, :command) do
      cmd when is_binary(cmd) and cmd != "" -> build_specs(server, cmd)
      _ -> %{children: [], client_name: nil}
    end
  end

  defp build_specs(server, command) do
    client_name = client_name_for(server.name)

    transport_opts =
      [command: command]
      |> add_optional(:args, Map.get(server, :args))
      |> add_optional(:env, Map.get(server, :env))

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
