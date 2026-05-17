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
    client |> Hermes.Client.Base.list_tools() |> interpret_response()
  end

  @doc """
  Decode the `Hermes.Client.Base.list_tools/2` return into the
  `Discoverer` callback shape. Public so tests can exercise each
  response shape without spawning a real MCP transport.
  """
  @spec interpret_response({:ok, term()} | {:error, term()}) ::
          {:ok, [FermixCore.Capabilities.MCP.Discoverer.tool_descriptor()]} | {:error, term()}
  def interpret_response({:ok, %Hermes.MCP.Response{is_error: true} = response}) do
    {:error, {:tools_error, response}}
  end

  def interpret_response({:ok, %Hermes.MCP.Response{result: %{"tools" => tools}}})
      when is_list(tools) do
    {:ok, Enum.map(tools, &normalize/1)}
  end

  def interpret_response({:ok, response}), do: {:error, {:unexpected_tools_response, response}}
  def interpret_response({:error, reason}), do: {:error, reason}

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
