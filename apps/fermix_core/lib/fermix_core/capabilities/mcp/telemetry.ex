defmodule FermixCore.Capabilities.MCP.Telemetry do
  @moduledoc """
  The single emitter for outbound-MCP **client** events.

  Two events live here:

  - `[:fermix, :mcp_client, :lifecycle]` — one event per remote-client lifecycle
    phase (`initialize`, `discover`, `ready`, `drift`, `reconnect`,
    `security_block`, `owner_down`, `teardown`). These happen before or outside a
    tool invocation, so they cannot ride `[:fermix, :tool, :exec]`.
  - `[:fermix, :capability, :mcp_name_collision]` — two distinct `{server, tool}`
    pairs sanitizing to the same agent-facing name (`Naming.register/3`).

  The `mcp_client` root is deliberate: inbound MCP (Fermix as a *server*) owns
  `[:fermix, :mcp, :inbound, :tools_listed]` / `[:fermix, :mcp, :inbound, :call]`,
  and the outbound client lifecycle must not share a prefix with server-side
  events. One **stable** event name carries every phase — a dynamic
  `[:fermix, :mcp_client, <phase>]` tail would never be delivered, because both
  `FermixCore.Trace.TelemetryHandler` and `FermixOpik.Reporter` bind exact names.

  ## Why there is no caller metadata map

  `emit_lifecycle/5` builds its metadata from an explicit allowlist of
  constructed keys — `source_id`, `plugin`, `phase`, `result`, `error_class`,
  `attempt`, plus turn correlation — and accepts no free-form map at all (the
  closest sibling is `FermixCore.Timeouts.Telemetry`, the only other emitter that
  redacts). A remote MCP client holds exactly the material that must never reach
  a trace: the bearer credential and authorization headers, the MCP session ID,
  the selected workspace ID, the endpoint URL, discovered tool schemas, tool
  arguments, and response bodies. With no pass-through map and a fixed key set,
  no caller — present or future — can attach any of them; a leak would require
  editing this module.

  For the same reason `error_class` is *derived*, never caller-supplied: a
  reason's message body can embed the endpoint URL or a credential, so only an
  atom class (or a tuple's atom head) survives and anything else is flattened to
  `"unclassified"`. The class is a label for grouping failures, not a diagnosis —
  the vendor's own words stay in the `{:error, reason}` the caller still returns.

  Both events are registered in `FermixCore.Trace.TelemetryHandler`; the
  lifecycle event is additionally consumed by `FermixOpik` (`Reporter` →
  `Aggregation` → `Mapper.mcp_client_span/3`) per `docs/TELEMETRY_CONTRACT.md`.
  Never hand-roll either event elsewhere.
  """

  alias FermixCore.Telemetry

  @lifecycle_event [:fermix, :mcp_client, :lifecycle]
  @collision_event [:fermix, :capability, :mcp_name_collision]

  @phases [
    :initialize,
    :discover,
    :ready,
    :drift,
    :reconnect,
    :security_block,
    :owner_down,
    :teardown
  ]

  @trace_event_definitions [
    %{
      event: @lifecycle_event,
      trace_event: "mcp_client_lifecycle",
      trace_type: :agent_event,
      agent_field: :source_id
    },
    %{
      event: @collision_event,
      trace_event: "mcp_name_collision",
      trace_type: :agent_event,
      agent_field: :server
    }
  ]

  @doc "Every lifecycle phase this emitter can emit."
  @spec phases() :: [atom()]
  def phases, do: @phases

  @doc "The stable outbound-client lifecycle event name."
  @spec lifecycle_event() :: [atom()]
  def lifecycle_event, do: @lifecycle_event

  @doc "The name-collision event name."
  @spec collision_event() :: [atom()]
  def collision_event, do: @collision_event

  @spec trace_event_definitions() :: [map()]
  def trace_event_definitions, do: @trace_event_definitions

  @doc """
  Emit one `[:fermix, :mcp_client, :lifecycle]` event.

  `source` is the source-qualified server identity — `%{source_id: {:plugin,
  "eden"}, plugin: "eden"}` or `%{source_id: {:operator, "fs"}}`. `source_id` is
  serialized to a stable string (`"plugin:eden"`): a tuple raises on the daemon
  wire path and is `inspect`-ed into JSONL, so neither consumer can group on it.

  `result` is the operation's return value verbatim (`:ok` | `{:ok, _}` |
  `:error` | `{:error, reason}`); its tag and, on failure, its redacted
  `error_class` are derived here. `opts` accepts `:attempt` (a positive integer)
  and the turn correlation ids (`:session_id`/`:parent_session`) for the phases
  that can occur inside a turn.
  """
  @spec emit_lifecycle(atom(), map(), term(), non_neg_integer(), keyword()) :: :ok
  def emit_lifecycle(phase, source, result, duration_ms, opts \\ [])
      when phase in @phases and is_map(source) and is_integer(duration_ms) and
             duration_ms >= 0 and is_list(opts) do
    metadata =
      %{
        source_id: source_id!(source),
        plugin: plugin!(source),
        phase: phase,
        result: result_tag(result),
        error_class: error_class(result),
        attempt: attempt!(opts)
      }
      |> compact()
      |> Map.merge(Telemetry.correlation_from_opts(opts))

    :telemetry.execute(@lifecycle_event, %{duration_ms: duration_ms}, metadata)
  end

  @doc """
  Emit one `[:fermix, :capability, :mcp_name_collision]` event — two distinct
  `{server, tool}` pairs sanitizing to the same agent-facing name.

  Name and payload are unchanged from the hand-rolled `:telemetry.execute/3` this
  replaced, so anything grepping for the event keeps working. Server and tool
  names are local configuration identifiers, never remote content.
  """
  @spec emit_collision(String.t(), String.t(), String.t(), {String.t(), String.t()}) :: :ok
  def emit_collision(server, original, sanitized, {existing_server, existing_original})
      when is_binary(server) and is_binary(original) and is_binary(sanitized) and
             is_binary(existing_server) and is_binary(existing_original) do
    :telemetry.execute(@collision_event, %{count: 1}, %{
      server: server,
      original: original,
      sanitized: sanitized,
      collided_with: %{server: existing_server, original: existing_original}
    })
  end

  defp source_id!(%{source_id: {kind, name}})
       when is_atom(kind) and is_binary(name) and name != "" do
    "#{kind}:#{name}"
  end

  defp source_id!(source) do
    raise ArgumentError,
          "mcp_client telemetry requires source_id: {kind, name}, got: " <>
            inspect(Map.get(source, :source_id))
  end

  defp plugin!(source) do
    case Map.get(source, :plugin) do
      nil ->
        nil

      plugin when is_binary(plugin) and plugin != "" ->
        plugin

      other ->
        raise ArgumentError,
              "mcp_client telemetry :plugin must be a non-empty binary or nil, got: " <>
                inspect(other)
    end
  end

  defp attempt!(opts) do
    case Keyword.get(opts, :attempt) do
      nil ->
        nil

      attempt when is_integer(attempt) and attempt > 0 ->
        attempt

      other ->
        raise ArgumentError,
              "mcp_client telemetry :attempt must be a positive integer, got: " <> inspect(other)
    end
  end

  defp result_tag(:ok), do: :ok
  defp result_tag({:ok, _value}), do: :ok
  defp result_tag(:error), do: :error
  defp result_tag({:error, _reason}), do: :error

  defp error_class({:error, reason}), do: class_of(reason)
  defp error_class(_result), do: nil

  defp class_of(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp class_of(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      head when is_atom(head) -> Atom.to_string(head)
      _other -> "unclassified"
    end
  end

  defp class_of(_reason), do: "unclassified"

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
