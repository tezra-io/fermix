defmodule FermixCore.Capabilities.MCP.Discoverer do
  @moduledoc """
  Behaviour for "discover the tools an MCP server exposes."

  Production uses `FermixCore.Capabilities.MCP.Discoverer.Anubis`, which
  delegates to `Anubis.Client.list_tools/2`. Tests stub this
  behaviour to avoid spawning real `npx` subprocesses.
  """

  @type tool_descriptor :: %{
          required(:name) => String.t(),
          optional(:description) => String.t(),
          optional(:input_schema) => map(),
          optional(:output_schema) => map() | nil,
          optional(:annotations) => map() | nil
        }

  @callback list_tools(client :: term()) ::
              {:ok, [tool_descriptor()]} | {:error, term()}

  @doc """
  The ONE definition of a normalized tool descriptor, shared by every discovery
  path (stdio via `Discoverer.Anubis`, remote via `Remote.Owner`).

  It lives here, beside the type it produces, because the signed descriptor
  (M27 §7.6) is the canonicalization of **name + inputSchema + outputSchema +
  annotations** — so a path that drops any of those hashes to something the
  publisher never signed, and every tool reads as drifted. That has now
  happened twice, once per path, because each had its own copy of this
  function. There is one copy.

  Absent `outputSchema`/`annotations` normalize to `nil`, which
  `CanonicalJson.descriptor_digest/4` hashes identically to an explicit null —
  a server that simply omits a field must not read as drift. Keys stay in their
  wire (string-keyed JSON) form, which is what the signature is defined over.
  """
  @spec normalize(map()) :: tool_descriptor()
  def normalize(tool) when is_map(tool) do
    %{
      name: Map.get(tool, "name") || Map.get(tool, :name),
      description: Map.get(tool, "description") || Map.get(tool, :description) || "",
      input_schema:
        Map.get(tool, "inputSchema") || Map.get(tool, :input_schema) ||
          %{"type" => "object", "properties" => %{}},
      output_schema: Map.get(tool, "outputSchema") || Map.get(tool, :output_schema),
      annotations: Map.get(tool, "annotations") || Map.get(tool, :annotations)
    }
  end
end

defmodule FermixCore.Capabilities.MCP.Discoverer.Anubis do
  @moduledoc """
  Production discoverer: calls `Anubis.Client.list_tools/2`.
  """

  @behaviour FermixCore.Capabilities.MCP.Discoverer

  alias FermixCore.Capabilities.MCP.Discoverer

  @impl true
  def list_tools(client) do
    client |> Anubis.Client.list_tools() |> interpret_response()
  end

  @doc """
  Decode the `Anubis.Client.list_tools/2` return into the
  `Discoverer` callback shape. Public so tests can exercise each
  response shape without spawning a real MCP transport.
  """
  @spec interpret_response({:ok, term()} | {:error, term()}) ::
          {:ok, [FermixCore.Capabilities.MCP.Discoverer.tool_descriptor()]} | {:error, term()}
  def interpret_response({:ok, %Anubis.MCP.Response{is_error: true} = response}) do
    {:error, {:tools_error, response}}
  end

  def interpret_response({:ok, %Anubis.MCP.Response{result: %{"tools" => tools}}})
      when is_list(tools) do
    {:ok, Enum.map(tools, &normalize/1)}
  end

  def interpret_response({:ok, response}), do: {:error, {:unexpected_tools_response, response}}
  def interpret_response({:error, reason}), do: {:error, reason}

  defp normalize(tool), do: Discoverer.normalize(tool)
end
