defmodule FermixCore.Capabilities.MCP.Capability do
  @moduledoc """
  Wraps an MCP tool descriptor (returned by a server's `tools/list`) as a
  `%Capability{kind: :mcp}`.

  The executor closes over one **private invoke spec**: the source-qualified
  identity, the exact original tool name, the agent-facing name, the caller
  module, and — for a signed remote contract — the compiled policy handle
  (selected profile, resource-scope kind, read-only / replay-safe /
  credential-scope facts). At call time the spec plus the turn's own context
  produce the invoke context the caller boundary receives (M27 §11.1).

  That split is the security property: model arguments arrive as a separate
  argument and are never consulted when the context is built, so a tool call
  cannot supply or override its own identity, profile, scope, or policy. There
  is no path from `args` into the closure.

  Telemetry rides the shared `Tools.Telemetry.exec/5` emitter and carries only
  the redacted correlatable subset — capability name, plugin, source-qualified
  server id, the turn `session_id` (never the MCP session id), profile,
  `workspace_scope: single_selected` (never the workspace id), the signed flags,
  attempt number, outcome, duration.

  Default policy class is `:external_api`. MCP tools are visible to the agent by
  default (`hidden_from_agent?: false`); operators can hide individual tools by
  setting `[mcp.servers.X.tools.Y] hidden_from_agent = true` in the TOML, which
  is wired through `tool_overrides`.
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

  @type policy :: %{
          profile: String.t(),
          read_only: boolean(),
          replay_safe: boolean(),
          credential_scope: :read | :write,
          resource_scope_kind: atom()
        }

  @type invoke_spec :: %{
          source_id: {atom(), String.t()},
          server_name: String.t(),
          plugin: String.t() | nil,
          original: String.t(),
          sanitized: String.t(),
          caller: module(),
          policy: policy() | nil
        }

  @doc """
  Build a `%Capability{}` for an MCP tool. The descriptor uses the keys
  returned by `Anubis.Client.list_tools/2` (`:name`, `:description`,
  `:input_schema`).

  Opts:

    * `:source_id` — the source-qualified identity; defaults to
      `{:operator, server}` for a `[mcp.servers.*]` TOML server.
    * `:name_prefix` — `"<plugin>_"` for a plugin-owned server (continuous with
      the `http` rail's namespace, M8 §8.2).
    * `:final_name` — the already-preflighted agent-facing name. The signed
      remote path supplies it, because its name is validated and reserved before
      any capability is built; the stdio path lets `Naming` derive and register
      one.
    * `:policy` — the compiled signed policy handle. `nil` for stdio.
    * `:extra_metadata` — `plugin_owned?`/`plugin`/`auth_profile`/`category`.
  """
  @spec from_tool_descriptor(String.t(), tool_descriptor(), keyword()) :: Capability.t()
  def from_tool_descriptor(server, descriptor, opts \\ [])
      when is_binary(server) and is_map(descriptor) do
    original = fetch_name!(descriptor)
    sanitized = resolve_name(server, original, opts)
    source_id = Keyword.get(opts, :source_id) || {:operator, server}

    overrides = Keyword.get(opts, :tool_overrides, %{})
    policy_class = Map.get(overrides, :policy_class, :external_api)
    hidden_from_agent? = Map.get(overrides, :hidden_from_agent?, false)

    spec = %{
      source_id: source_id,
      server_name: server,
      plugin: plugin_of(source_id),
      original: original,
      sanitized: sanitized,
      caller: Keyword.get(opts, :caller, FermixCore.Capabilities.MCP.Caller.Anubis),
      policy: Keyword.get(opts, :policy)
    }

    base_metadata = %{
      mcp_server: server,
      mcp_source: source_label(source_id),
      original_name: original,
      sanitized_name: sanitized
    }

    Capability.new(%{
      name: sanitized,
      description: Map.get(descriptor, :description, ""),
      parameters: Keyword.get(opts, :parameters) || descriptor_parameters(descriptor),
      kind: :mcp,
      executor: {__MODULE__, :invoke, [spec]},
      policy_class: policy_class,
      hidden_from_agent?: hidden_from_agent?,
      metadata: Map.merge(base_metadata, Keyword.get(opts, :extra_metadata) || %{})
    })
  end

  @doc """
  Capability executor entry point. Mints the private invoke context, calls the
  underlying MCP tool through the configured caller, and converts the response
  into the standard tool result shape consumed by `AgentLoop`.

  Emits `[:fermix, :tool, :exec]` through the shared `Tools.Telemetry` emitter
  (the same one builtin/plugin tools use), tagged with the agent-facing name, so
  outbound MCP tool calls are correlatable and Opik-traceable like every other
  tool.
  """
  @spec invoke(map(), map(), invoke_spec()) :: {:ok, map()}
  def invoke(args, context, spec) when is_map(args) and is_map(context) and is_map(spec) do
    start = System.monotonic_time(:millisecond)
    invoke_context = invoke_context(context, spec)
    result = run_call(spec, invoke_context, args)
    duration = System.monotonic_time(:millisecond) - start

    success = match?({:ok, %{success: true}}, result)

    ToolTelemetry.exec(spec.sanitized, context, success, duration,
      metadata: exec_metadata(spec, result),
      result: result
    )

    result
  end

  # Built from the closure and the TURN, never from `args`. The turn pid is this
  # process: the agent loop runs the executor inline, so `self()` is the process
  # whose death releases the budget.
  defp invoke_context(context, spec) do
    %{
      source_id: spec.source_id,
      session_id: Map.get(context, :session_id),
      turn_pid: self()
    }
    |> Map.merge(policy_facts(spec.policy))
  end

  defp policy_facts(nil), do: %{}

  defp policy_facts(policy) do
    %{
      profile: policy.profile,
      read_only: policy.read_only,
      replay_safe: policy.replay_safe,
      credential_scope: policy.credential_scope,
      resource_scope_kind: policy.resource_scope_kind
    }
  end

  defp run_call(spec, invoke_context, args) do
    case spec.caller.call_tool(spec.source_id, spec.original, args, invoke_context) do
      {:ok, result} ->
        {:ok, Tool.success(format_result(result))}

      {:error, reason} ->
        Logger.error(
          "MCP call failed for #{source_label(spec.source_id)}/#{spec.original}: " <>
            inspect(error_class(reason))
        )

        {:ok,
         Tool.error(
           "MCP tool '#{spec.server_name}/#{spec.original}' failed: #{format_reason(reason)}"
         )}
    end
  end

  # The redacted correlatable subset (§11.1). `workspace_scope` says the call was
  # scoped to one selected resource; the resource's ID is never recorded.
  defp exec_metadata(spec, result) do
    %{
      mcp_server: spec.server_name,
      mcp_source: source_label(spec.source_id),
      plugin: spec.plugin,
      attempt: 1
    }
    |> Map.merge(policy_metadata(spec.policy))
    |> Map.merge(error_metadata(result))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp policy_metadata(nil), do: %{}

  defp policy_metadata(policy) do
    %{
      profile: policy.profile,
      workspace_scope: :single_selected,
      read_only: policy.read_only,
      replay_safe: policy.replay_safe
    }
  end

  defp error_metadata({:ok, %{success: false, error: error}}) when is_binary(error),
    do: %{error: error}

  defp error_metadata(_result), do: %{}

  defp resolve_name(server, original, opts) do
    case Keyword.get(opts, :final_name) do
      name when is_binary(name) ->
        name

      nil ->
        candidate = Naming.candidate(server, original, prefix: Keyword.get(opts, :name_prefix))
        Naming.register(server, original, candidate)
    end
  end

  defp descriptor_parameters(descriptor),
    do: Map.get(descriptor, :input_schema, %{type: "object", properties: %{}})

  defp plugin_of({:plugin, name}), do: name
  defp plugin_of({_kind, _name}), do: nil

  defp source_label({kind, name}), do: "#{kind}:#{name}"

  defp fetch_name!(%{name: name}) when is_binary(name) and name != "", do: name

  defp fetch_name!(descriptor) do
    raise ArgumentError,
          "MCP tool descriptor missing :name binary, got: #{inspect(descriptor)}"
  end

  defp format_result(result) when is_binary(result), do: result
  defp format_result(result), do: inspect(result, pretty: true, limit: :infinity)

  defp format_reason(reason) when is_binary(reason), do: reason

  # A remote vendor error carries a machine status AND the vendor's own
  # sentence. Rendering it as a sentence rather than an inspected tuple is the
  # difference between an agent that can act ("out of credits — stop asking")
  # and one that blind-retries into the same wall.
  defp format_reason({:remote_tool_error, status, nil}), do: status
  defp format_reason({:remote_tool_error, status, message}), do: "#{status} — #{message}"
  defp format_reason(reason), do: inspect(reason)

  # A remote reason can embed an endpoint or a peer message; only its atom class
  # reaches the log. The reason itself still rides the tool result the agent and
  # the trace see, which is where the vendor's own words belong.
  defp error_class(reason) when is_atom(reason), do: reason
  defp error_class(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: elem(reason, 0)
  defp error_class(_reason), do: :unclassified
end
