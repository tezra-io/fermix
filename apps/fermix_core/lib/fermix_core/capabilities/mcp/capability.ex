defmodule FermixCore.Capabilities.MCP.Capability do
  @moduledoc """
  Wraps an MCP tool descriptor (returned by a server's `tools/list`) as a
  `%Capability{kind: :mcp}`. The capability's executor closes over
  `{server_name, original_tool_name, sanitized_name}` and dispatches through
  the `:caller` module so tests can swap in a stub instead of going through
  a live `Anubis.Client`. The sanitized (agent-facing) name is carried so the
  executor can emit tool telemetry under the same name the agent called.

  Default policy class is `:external_api`. MCP tools are visible to the
  agent by default (`hidden_from_agent?: false`); operators can hide
  individual tools by setting `[mcp.servers.X.tools.Y] hidden_from_agent
  = true` in the TOML, which is wired through `tool_overrides`.
  """

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.MCP.Naming
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  require Logger

  @type tool_descriptor :: %{
          required(:name) => String.t(),
          optional(:description) => String.t(),
          optional(:input_schema) => map()
        }

  @doc """
  Build a `%Capability{}` for an MCP tool. The descriptor uses the keys
  returned by `Anubis.Client.list_tools/2` (`:name`, `:description`,
  `:input_schema`).

  Plugin-owned servers pass `name_prefix: "<plugin>_"` (continuous with the
  `http` rail's namespace) and `extra_metadata` (`plugin_owned?`/`plugin`/
  `auth_profile`/`category: :plugin`) so PromptCatalog grouping and
  per-plugin surfaces treat both rails identically (M8 §8.2).
  """
  @spec from_tool_descriptor(String.t(), tool_descriptor(), keyword()) :: Capability.t()
  def from_tool_descriptor(server, descriptor, opts \\ [])
      when is_binary(server) and is_map(descriptor) do
    original = fetch_name!(descriptor)
    name_prefix = Keyword.get(opts, :name_prefix)
    sanitized_candidate = Naming.candidate(server, original, prefix: name_prefix)
    sanitized = Naming.register(server, original, sanitized_candidate)

    caller = Keyword.get(opts, :caller, FermixCore.Capabilities.MCP.Caller.Anubis)
    overrides = Keyword.get(opts, :tool_overrides, %{})
    policy_class = Map.get(overrides, :policy_class, :external_api)
    hidden_from_agent? = Map.get(overrides, :hidden_from_agent?, false)

    base_metadata = %{
      mcp_server: server,
      original_name: original,
      sanitized_name: sanitized
    }

    Capability.new(%{
      name: sanitized,
      description: Map.get(descriptor, :description, ""),
      parameters: Map.get(descriptor, :input_schema, %{type: "object", properties: %{}}),
      kind: :mcp,
      executor: {__MODULE__, :invoke, [server, original, sanitized, caller]},
      policy_class: policy_class,
      hidden_from_agent?: hidden_from_agent?,
      metadata: Map.merge(base_metadata, Keyword.get(opts, :extra_metadata) || %{})
    })
  end

  @doc """
  Capability executor entry point. Calls the underlying MCP tool
  through the configured caller and converts the response into the
  standard tool result shape consumed by `AgentLoop`.

  Emits `[:fermix, :tool, :exec]` through the shared `Tools.Telemetry`
  emitter (the same one builtin/plugin tools use), tagged with the
  agent-facing `sanitized` name and `mcp_server`, so outbound MCP tool
  calls are correlatable and Opik-traceable like every other tool.
  """
  @spec invoke(map(), map(), String.t(), String.t(), String.t(), module()) :: {:ok, map()}
  def invoke(args, context, server, original, sanitized, caller)
      when is_map(args) and is_map(context) and is_binary(server) and is_binary(original) and
             is_binary(sanitized) and is_atom(caller) do
    start = System.monotonic_time(:millisecond)
    result = run_call(server, original, caller, args)
    duration = System.monotonic_time(:millisecond) - start

    success = match?({:ok, %{success: true}}, result)

    ToolTelemetry.exec(sanitized, context, success, duration,
      metadata: exec_metadata(server, result),
      result: result
    )

    result
  end

  defp run_call(server, original, caller, args) do
    case caller.call_tool(server, original, args) do
      {:ok, result} ->
        {:ok, Tool.success(format_result(result))}

      {:error, reason} ->
        Logger.error("MCP call failed for #{server}/#{original}: #{inspect(reason)}")
        {:ok, Tool.error("MCP tool '#{server}/#{original}' failed: #{format_reason(reason)}")}
    end
  end

  defp exec_metadata(server, {:ok, %{success: false, error: error}}) when is_binary(error),
    do: %{mcp_server: server, error: error}

  defp exec_metadata(server, _result), do: %{mcp_server: server}

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
