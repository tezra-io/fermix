defmodule FermixCore.Management.McpServers.Draft do
  @moduledoc """
  The one owner of the draft object `mcp.servers.draft` answers (M74 §5, E8):
  one server a paste describes, as the add form takes it, in the daemon's own
  words.

  `build/2` is pure. It composes what `Interchange` translated with the facts
  the daemon holds about it: where its command resolves (`LoginPath`), whether
  the name is already an MCP server here, and the `draft_id` its values are
  held under. Every field is always present, null where the transport has
  none. `command_line` is written back with `CommandLine.join/1`, so it reads as
  the words that will run; `env` and `headers` name every value the server
  declares, the key's header included, and `present` says the paste carried
  its value, which `mcp.servers.add` then stores under the `draft_id`. A value
  itself is never in a draft.
  """

  alias FermixCore.Capabilities.MCP.LoginPath
  alias FermixCore.Management.McpServers.CommandLine
  alias FermixCore.Management.McpServers.Interchange
  alias FermixCore.Management.McpServers.PastedValues
  alias FermixCore.Management.McpServers.Row

  @type facts :: %{
          resolution: LoginPath.resolution() | nil,
          conflict: boolean(),
          draft_id: String.t() | nil
        }

  @doc "One draft."
  @spec build(Interchange.translated(), facts()) :: map()
  def build(%{server: server, values: values}, facts) when is_map(facts) do
    %{
      "name" => server.name,
      "transport" => Atom.to_string(server.transport),
      "url" => Map.get(server, :url),
      "command_line" => command_line(server),
      "resolved_command" => resolved_command(facts.resolution),
      "command_sentence" => command_sentence(facts.resolution),
      "cwd" => Map.get(server, :cwd),
      "env" => names(server, :env, values),
      "headers" => names(server, :header, values),
      "auth" => auth(server),
      "key_header" => Map.get(server, :key_header),
      "oauth_client_id" => Map.get(server, :oauth_client_id),
      "consent_sentence" => Row.consent_sentence(server),
      "summary" => summary(server),
      "conflict" => facts.conflict,
      "draft_id" => facts.draft_id
    }
  end

  defp command_line(%{transport: :stdio, command: command, args: args}),
    do: CommandLine.join([command | args])

  defp command_line(_server), do: nil

  defp resolved_command({:ok, program}), do: program
  defp resolved_command(_unresolved), do: nil

  # Before the login shell's PATH is read, a bare command has no answer yet,
  # and the draft says nothing rather than that it was not found.
  defp command_sentence({:ok, program}), do: "Runs #{program}"

  defp command_sentence({:error, {:command_not_found, command}}),
    do: Row.not_found_sentence(command)

  defp command_sentence(nil), do: nil

  defp names(%{transport: :stdio, env_secrets: names}, :env, values),
    do: Enum.map(names, &name_row(&1, PastedValues.carries?(values, {:env, &1})))

  defp names(%{transport: :http, header_secrets: names}, :header, values),
    do: Enum.map(names, &name_row(&1, PastedValues.carries?(values, {:header, &1})))

  defp names(_server, _kind, _values), do: []

  defp name_row(name, present), do: %{"name" => name, "present" => present}

  defp auth(%{transport: :http, auth: auth}), do: Atom.to_string(auth)
  defp auth(_server), do: "none"

  # "Remote, mcp.linear.app", or the program and the package it starts.
  defp summary(%{transport: :http} = server), do: "Remote, #{Row.location(server)}"

  defp summary(%{command: command, args: args}) do
    [Path.basename(command), Interchange.package(command, args)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end
end
