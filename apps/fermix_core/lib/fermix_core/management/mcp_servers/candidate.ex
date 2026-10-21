defmodule FermixCore.Management.McpServers.Candidate do
  @moduledoc """
  The one owner of an import candidate (M74 §5, E8): one server another app's
  settings on this Mac hold, as the import page lists it, in the daemon's own
  words.

  `build/3` is pure. A candidate says what a draft of the same server says
  (`Draft.build/2`: its name, transport, summary, command line or URL, where
  it runs, its resolved program), so a server reads the same pasted or
  imported, and adds where it comes from (`source`, the closed id, and
  `source_label`, the daemon's name for the app) and `secret_names`, the names
  of the values it declares, the key's header included. A value never is in
  one. Every field is always present, null where the transport has none.
  """

  alias FermixCore.Capabilities.MCP.LoginPath
  alias FermixCore.Management.McpServers.Draft
  alias FermixCore.Management.McpServers.ImportSources
  alias FermixCore.Management.McpServers.Interchange

  @draft_fields ~w(name transport summary command_line url consent_sentence resolved_command command_sentence conflict)

  @type facts :: %{resolution: LoginPath.resolution() | nil, conflict: boolean()}

  @doc "One candidate."
  @spec build(ImportSources.source(), Interchange.translated(), facts()) :: map()
  def build(source, %{server: server} = translated, facts) when is_map(facts) do
    translated
    |> Draft.build(Map.put(facts, :draft_id, nil))
    |> Map.take(@draft_fields)
    |> Map.merge(%{
      "source" => source.id,
      "source_label" => source.label,
      "secret_names" => Map.get(server, :env_secrets, []) ++ Map.get(server, :header_secrets, [])
    })
  end
end
