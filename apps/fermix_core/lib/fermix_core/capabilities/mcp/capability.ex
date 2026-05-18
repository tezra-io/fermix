defmodule FermixCore.Capabilities.MCP.Capability do
  @moduledoc """
  Wraps an MCP tool descriptor (returned by a server's `tools/list`) as a
  `%Capability{kind: :mcp}`. The capability's executor closes over
  `{server_name, original_tool_name}` and dispatches through the
  `:caller` module so tests can swap in a stub instead of going through
  a live `Hermes.Client`.

  Default policy class is `:external_api`. MCP tools are visible to the
  agent by default (`hidden_from_agent?: false`); operators can hide
  individual tools by setting `[mcp.servers.X.tools.Y] hidden_from_agent
  = true` in the TOML, which is wired through `tool_overrides`.
  """

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.MCP.Naming

  require Logger

  @type tool_descriptor :: %{
          required(:name) => String.t(),
          optional(:description) => String.t(),
          optional(:input_schema) => map()
        }

  @doc """
  Build a `%Capability{}` for an MCP tool. The descriptor uses the keys
  returned by `Hermes.Client.list_tools/2` (`:name`, `:description`,
  `:input_schema`).
  """
  @spec from_tool_descriptor(String.t(), tool_descriptor(), keyword()) :: Capability.t()
  def from_tool_descriptor(server, descriptor, opts \\ [])
      when is_binary(server) and is_map(descriptor) do
    original = fetch_name!(descriptor)
    sanitized_candidate = Naming.candidate(server, original)
    sanitized = Naming.register(server, original, sanitized_candidate)

    caller = Keyword.get(opts, :caller, FermixCore.Capabilities.MCP.Caller.Hermes)
    overrides = Keyword.get(opts, :tool_overrides, %{})
    policy_class = Map.get(overrides, :policy_class, :external_api)
    hidden_from_agent? = Map.get(overrides, :hidden_from_agent?, false)

    Capability.new(%{
      name: sanitized,
      description: Map.get(descriptor, :description, ""),
      parameters: Map.get(descriptor, :input_schema, %{type: "object", properties: %{}}),
      kind: :mcp,
      executor: {__MODULE__, :invoke, [server, original, caller]},
      policy_class: policy_class,
      hidden_from_agent?: hidden_from_agent?,
      metadata: %{
        mcp_server: server,
        original_name: original,
        sanitized_name: sanitized
      }
    })
  end

  @doc """
  Capability executor entry point. Calls the underlying MCP tool
  through the configured caller and converts the response into the
  standard tool result shape consumed by `AgentLoop`.
  """
  @spec invoke(map(), map(), String.t(), String.t(), module()) :: {:ok, map()}
  def invoke(args, _context, server, original, caller)
      when is_map(args) and is_binary(server) and is_binary(original) and is_atom(caller) do
    case caller.call_tool(server, original, args) do
      {:ok, result} ->
        {:ok, Tool.success(format_result(result))}

      {:error, reason} ->
        Logger.error("MCP call failed for #{server}/#{original}: #{inspect(reason)}")
        {:ok, Tool.error("MCP tool '#{server}/#{original}' failed: #{format_reason(reason)}")}
    end
  end

  defp fetch_name!(%{name: name}) when is_binary(name) and name != "", do: name

  defp fetch_name!(descriptor) do
    raise ArgumentError,
          "MCP tool descriptor missing :name binary, got: #{inspect(descriptor)}"
  end

  defp format_result(result) when is_binary(result), do: result
  defp format_result(result), do: inspect(result, pretty: true, limit: :infinity)

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
