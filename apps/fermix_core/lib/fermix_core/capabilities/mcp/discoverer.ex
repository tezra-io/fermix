defmodule FermixCore.Capabilities.MCP.Discoverer do
  @moduledoc """
  Behaviour for "discover the tools an MCP server exposes."

  Production uses `FermixCore.Capabilities.MCP.Discoverer.Hermes`, which
  delegates to `Hermes.Client.Base.list_tools/2`. Tests stub this
  behaviour to avoid spawning real `npx` subprocesses.
  """

  @type tool_descriptor :: %{
          required(:name) => String.t(),
          optional(:description) => String.t(),
          optional(:input_schema) => map()
        }

  @callback list_tools(client :: term()) ::
              {:ok, [tool_descriptor()]} | {:error, term()}
end

defmodule FermixCore.Capabilities.MCP.Discoverer.Hermes do
  @moduledoc """
  Production discoverer: calls `Hermes.Client.Base.list_tools/2`.
  """

  @behaviour FermixCore.Capabilities.MCP.Discoverer

  @impl true
  def list_tools(client) do
    case Hermes.Client.Base.list_tools(client) do
      {:ok, %{"tools" => tools}} when is_list(tools) ->
        {:ok, Enum.map(tools, &normalize/1)}

      {:ok, response} ->
        {:error, {:unexpected_tools_response, response}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize(tool) when is_map(tool) do
    %{
      name: Map.get(tool, "name") || Map.get(tool, :name),
      description: Map.get(tool, "description") || Map.get(tool, :description, ""),
      input_schema:
        Map.get(tool, "inputSchema") || Map.get(tool, :input_schema) ||
          %{type: "object", properties: %{}}
    }
  end
end
