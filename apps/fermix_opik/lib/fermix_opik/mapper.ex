defmodule FermixOpik.Mapper do
  @moduledoc """
  Pure builders that turn Fermix telemetry metadata into Opik trace/span maps.

  Field names match Opik's REST write schema exactly (see the project README):
  span `type` ∈ general|tool|llm, `usage` keys are OpenAI-style integers, and
  `provider` + `model` + `usage` are what Opik uses to auto-compute USD cost —
  so cost is never computed here.
  """

  alias FermixOpik.UUID7

  @doc "ISO-8601 UTC timestamp with millisecond precision (Opik's expected shape)."
  @spec iso(DateTime.t()) :: String.t()
  def iso(%DateTime{} = dt), do: dt |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  @doc "`end_time` minus `duration_ms`, the start of a point-measured call."
  @spec start_of(DateTime.t(), non_neg_integer()) :: DateTime.t()
  def start_of(%DateTime{} = ended, duration_ms) when is_integer(duration_ms) do
    DateTime.add(ended, -duration_ms, :millisecond)
  end

  @doc "A new id stamped at `dt` so the UUIDv7 timestamp matches `start_time`."
  @spec new_id(DateTime.t()) :: String.t()
  def new_id(%DateTime{} = dt), do: UUID7.generate(DateTime.to_unix(dt, :millisecond))

  @doc """
  Build an `llm` span from a `[:fermix, :provider, :call]` event.
  """
  @spec llm_span(map(), map(), keyword()) :: map()
  def llm_span(metadata, measurements, opts) do
    ended = Keyword.fetch!(opts, :ended)
    duration_ms = Map.get(measurements, :duration_ms, 0)
    started = start_of(ended, duration_ms)

    %{
      id: new_id(started),
      trace_id: Keyword.fetch!(opts, :trace_id),
      parent_span_id: Keyword.get(opts, :parent_span_id),
      project_name: Keyword.fetch!(opts, :project_name),
      name: provider_span_name(metadata),
      type: "llm",
      start_time: iso(started),
      end_time: iso(ended),
      model: Map.get(metadata, :model),
      provider: provider_string(Map.get(metadata, :provider)),
      usage: usage(Map.get(metadata, :tokens)),
      metadata:
        drop_nil(%{
          status: stringify(Map.get(metadata, :status)),
          reasoning_effort: Map.get(metadata, :reasoning_effort),
          adapter: Map.get(metadata, :adapter)
        })
    }
    |> put_io(Map.get(metadata, :input), Map.get(metadata, :output))
    |> put_error(metadata)
    |> drop_nil()
  end

  @doc """
  Build a provider-failover transition span from a
  `[:fermix, :provider, :failover]` event (one per transition; see
  docs/design/MULTI_PROVIDER_FAILOVER.md §9 in the fermix repo).
  """
  @spec failover_span(map(), map(), keyword()) :: map()
  def failover_span(metadata, _measurements, opts) do
    ended = Keyword.fetch!(opts, :ended)
    started = start_of(ended, 0)

    %{
      id: new_id(started),
      trace_id: Keyword.fetch!(opts, :trace_id),
      parent_span_id: Keyword.get(opts, :parent_span_id),
      project_name: Keyword.fetch!(opts, :project_name),
      name:
        "failover:#{Map.get(metadata, :from_provider, "unknown")}->" <>
          "#{Map.get(metadata, :to_provider, "unknown")}",
      type: "general",
      start_time: iso(started),
      end_time: iso(ended),
      metadata:
        drop_nil(%{
          from_provider: stringify(Map.get(metadata, :from_provider)),
          from_model: Map.get(metadata, :from_model),
          to_provider: stringify(Map.get(metadata, :to_provider)),
          to_model: Map.get(metadata, :to_model),
          reason_kind: stringify(Map.get(metadata, :reason_kind)),
          surface: stringify(Map.get(metadata, :surface))
        })
    }
    |> drop_nil()
  end

  @doc """
  Build a draft-stream lifecycle span from a `[:fermix, :channel, :stream]`
  event (phases `:open`/`:block`/`:rotate`/`:seal`/`:discard`; see
  docs/design/CHANNEL_STREAMING.md §8 in the fermix repo).
  """
  @spec stream_span(map(), map(), keyword()) :: map()
  def stream_span(metadata, measurements, opts) do
    ended = Keyword.fetch!(opts, :ended)
    started = start_of(ended, 0)

    %{
      id: new_id(started),
      trace_id: Keyword.fetch!(opts, :trace_id),
      parent_span_id: Keyword.get(opts, :parent_span_id),
      project_name: Keyword.fetch!(opts, :project_name),
      name: "stream:#{Map.get(metadata, :phase, "event")}",
      type: "tool",
      start_time: iso(started),
      end_time: iso(ended),
      metadata:
        drop_nil(%{
          channel: Map.get(metadata, :channel),
          status: stringify(Map.get(metadata, :status)),
          ttfd_ms: Map.get(measurements, :ttfd_ms),
          block_index: Map.get(measurements, :block_index),
          # The write phases' own pair (`Gateway.DraftStream`): unlisted, a
          # :rotate span exported as channel+status alone, so every rotation in a
          # turn was indistinguishable from the next. Microseconds keep the
          # emitter's unit in the key name, as `Aggregation` does.
          edit_index: Map.get(measurements, :edit_index),
          duration_us: Map.get(measurements, :duration_us),
          total_edits: Map.get(measurements, :total_edits),
          dropped_snapshots: Map.get(measurements, :dropped_snapshots)
        })
    }
    |> drop_nil()
  end

  @doc """
  Build a `tool` span from a `[:fermix, :tool, :exec]` event.
  """
  @spec tool_span(map(), map(), keyword()) :: map()
  def tool_span(metadata, measurements, opts) do
    ended = Keyword.fetch!(opts, :ended)
    duration_ms = Map.get(measurements, :duration_ms, 0)
    started = start_of(ended, duration_ms)

    %{
      id: new_id(started),
      trace_id: Keyword.fetch!(opts, :trace_id),
      parent_span_id: Keyword.get(opts, :parent_span_id),
      project_name: Keyword.fetch!(opts, :project_name),
      name: to_string(Map.get(metadata, :tool, "tool")),
      type: "tool",
      start_time: iso(started),
      end_time: iso(ended),
      metadata:
        drop_nil(
          # `:policy_enforcement` is three fixed strings with no user content, so
          # it rides outside the capture_content gate: a blocked-before-execution
          # claim must stay provable in a content-free export.
          Map.take(metadata, [
            :plugin,
            :action,
            :kind,
            :profile,
            :url,
            :target_ref,
            :selector,
            :policy_enforcement,
            # `MCP.Capability.invoke/3` stamps the outbound server on every MCP
            # tool exec; without it here the server identity was dropped from
            # every Opik tool span (this map is the only allowlist there is).
            :mcp_server,
            # The signed remote-MCP subset (M27 §11.1): source-qualified server
            # identity, the operator-selected scope KIND (never the workspace
            # id), the signed policy flags, and the network attempt number. The
            # MCP session id and the resource id are never emitted at all.
            :mcp_source,
            :workspace_scope,
            :read_only,
            :replay_safe,
            :attempt,
            # The search family's bounded metadata (MILESTONE_31 §16). Counts and
            # provider name only — never a query, a place record, or a
            # coordinate. `:location_mode` is the sole record of WHICH anchor a
            # place search used (query_only / named / explicit_coordinates), so
            # dropping it erases the privacy evidence itself.
            :backend,
            :result_count,
            :has_media_count,
            :location_mode
          ])
        )
    }
    |> put_io(Map.get(metadata, :input), Map.get(metadata, :output))
    |> put_error(metadata)
    |> drop_nil()
  end

  @doc """
  Build a `tool` span from a `[:fermix, :memory, :write]` event — one durable
  memory write by the background reviewer. Makes a reviewer-driven persist
  observable: the old behavior emitted no span, so a real durable write was
  indistinguishable from a no-op under the turn that triggered it. Point event
  (no duration); `:tool` type + `memory_write` name so it surfaces alongside
  tool spans.
  """
  @spec memory_write_span(map(), map(), keyword()) :: map()
  def memory_write_span(metadata, _measurements, opts) do
    ended = Keyword.fetch!(opts, :ended)
    started = start_of(ended, 0)

    %{
      id: new_id(started),
      trace_id: Keyword.fetch!(opts, :trace_id),
      parent_span_id: Keyword.get(opts, :parent_span_id),
      project_name: Keyword.fetch!(opts, :project_name),
      name: to_string(Map.get(metadata, :tool, "memory_write")),
      type: "tool",
      start_time: iso(started),
      end_time: iso(ended),
      metadata:
        drop_nil(
          Map.take(metadata, [:action, :category, :key, :scope_type, :memory_id, :agent, :owner])
        )
    }
    |> drop_nil()
  end

  @doc """
  Build a realtime-lifecycle span from a `[:fermix, :realtime, <phase>]` event.

  The model turn and tool calls reuse `llm_span`/`tool_span`; these point spans
  mark a realtime call's provider lifecycle (session setup, reconnects, errors).
  `:phase` names the event.
  """
  @spec realtime_span(map(), map(), keyword()) :: map()
  def realtime_span(metadata, _measurements, opts) do
    ended = Keyword.fetch!(opts, :ended)
    started = start_of(ended, 0)

    %{
      id: new_id(started),
      trace_id: Keyword.fetch!(opts, :trace_id),
      parent_span_id: Keyword.get(opts, :parent_span_id),
      project_name: Keyword.fetch!(opts, :project_name),
      name: "realtime:#{Keyword.fetch!(opts, :phase)}",
      type: "general",
      start_time: iso(started),
      end_time: iso(ended),
      metadata:
        drop_nil(%{
          device_id: Map.get(metadata, :device_id),
          model: Map.get(metadata, :model),
          voice: Map.get(metadata, :voice),
          reason: Map.get(metadata, :reason),
          attempt: Map.get(metadata, :attempt)
        })
    }
    |> drop_nil()
  end

  @doc """
  Build a point span from a `[:fermix, :mcp_client, :lifecycle]` event — one
  outbound MCP client lifecycle phase that happened *inside* a turn
  (`security_block`/`drift`/`reconnect`); the boot-time phases become their own
  self-closing traces in `Aggregation` instead.

  The key list mirrors the emitter's allowlist exactly
  (`FermixCore.Capabilities.MCP.Telemetry`): there is no global allowlist here,
  every builder hard-codes its own, so a key not named below never exports.
  """
  @spec mcp_client_span(map(), map(), keyword()) :: map()
  def mcp_client_span(metadata, measurements, opts) do
    ended = Keyword.fetch!(opts, :ended)
    duration_ms = Map.get(measurements, :duration_ms, 0)
    started = start_of(ended, duration_ms)

    %{
      id: new_id(started),
      trace_id: Keyword.fetch!(opts, :trace_id),
      parent_span_id: Keyword.get(opts, :parent_span_id),
      project_name: Keyword.fetch!(opts, :project_name),
      name: "mcp_client:#{stringify(Map.get(metadata, :phase)) || "lifecycle"}",
      type: "general",
      start_time: iso(started),
      end_time: iso(ended),
      metadata:
        drop_nil(%{
          source_id: Map.get(metadata, :source_id),
          plugin: Map.get(metadata, :plugin),
          phase: stringify(Map.get(metadata, :phase)),
          result: stringify(Map.get(metadata, :result)),
          error_class: stringify(Map.get(metadata, :error_class)),
          attempt: Map.get(metadata, :attempt)
        })
    }
    |> drop_nil()
  end

  @doc """
  Build a point span from a `[:fermix, :timeout, :expired]` event — a failure
  deadline that fired. `error_info` flags it so the span surfaces as errored, not
  silently green; the timeout `name` rides in the event metadata (the event name
  is stable).
  """
  @spec timeout_span(map(), map(), keyword()) :: map()
  def timeout_span(metadata, measurements, opts) do
    ended = Keyword.fetch!(opts, :ended)
    started = start_of(ended, 0)
    name = stringify(Map.get(metadata, :name)) || "timeout"
    ms = Map.get(measurements, :ms)

    %{
      id: new_id(started),
      trace_id: Keyword.fetch!(opts, :trace_id),
      parent_span_id: Keyword.get(opts, :parent_span_id),
      project_name: Keyword.fetch!(opts, :project_name),
      name: "timeout:#{name}",
      type: "general",
      start_time: iso(started),
      end_time: iso(ended),
      metadata: drop_nil(%{ms: ms, context: Map.get(metadata, :context)}),
      error_info: %{exception_type: "Timeout", message: "#{name} after #{ms}ms"}
    }
    |> drop_nil()
  end

  @doc "OpenAI-style integer usage map, or nil when no token counts are present."
  @spec usage(map() | nil) :: map() | nil
  def usage(%{} = tokens) when map_size(tokens) > 0 do
    prompt = int(Map.get(tokens, :prompt) || Map.get(tokens, :prompt_tokens))
    completion = int(Map.get(tokens, :completion) || Map.get(tokens, :completion_tokens))
    total = int(Map.get(tokens, :total) || Map.get(tokens, :total_tokens)) || prompt + completion

    drop_nil(%{prompt_tokens: prompt, completion_tokens: completion, total_tokens: total})
    |> case do
      empty when map_size(empty) == 0 -> nil
      usage -> usage
    end
  end

  def usage(_other), do: nil

  @doc """
  The short provider token Opik recognizes for auto-cost. Codex is OpenAI.
  """
  @spec provider_string(atom() | String.t() | nil) :: String.t() | nil
  def provider_string(nil), do: nil
  def provider_string(:openai), do: "openai"
  def provider_string(:openai_codex), do: "openai"
  def provider_string(:anthropic), do: "anthropic"
  def provider_string(:xai), do: "xai"
  # Explicit clauses pin the Opik pricing tokens for the M12 providers —
  # the catch-all would produce the same strings today, but the clause +
  # test is the documented contract (provider playbook notes 2/34).
  def provider_string(:openrouter), do: "openrouter"
  def provider_string(:ollama), do: "ollama"
  def provider_string(:mistral), do: "mistral"
  def provider_string(other), do: to_string(other)

  defp provider_span_name(metadata) do
    case Map.get(metadata, :adapter) do
      nil -> "llm:#{Map.get(metadata, :model, "call")}"
      adapter -> "llm:#{adapter}:#{Map.get(metadata, :model, "call")}"
    end
  end

  defp put_io(span, nil, nil), do: span

  defp put_io(span, input, output) do
    span
    |> maybe_put(:input, wrap_io(input))
    |> maybe_put(:output, wrap_io(output))
  end

  defp wrap_io(nil), do: nil
  defp wrap_io(value) when is_binary(value), do: %{text: value}
  defp wrap_io(value), do: %{value: value}

  # Tools surface failure as either a free-form `:error` (plugin/MCP) or the
  # bounded `:error_code`/`:error_summary` pair the builtin browser/shell tools
  # emit. Both map to Opik's structured `error_info` so a failed span is flagged
  # as errored, not silently green.
  defp put_error(span, %{error_code: code} = metadata) when not is_nil(code) do
    message = Map.get(metadata, :error_summary) || code
    Map.put(span, :error_info, %{exception_type: to_string(code), message: to_string(message)})
  end

  defp put_error(span, %{error_summary: summary}) when not is_nil(summary) do
    Map.put(span, :error_info, %{exception_type: "ToolError", message: to_string(summary)})
  end

  defp put_error(span, %{error: error}) when not is_nil(error) do
    Map.put(span, :error_info, %{exception_type: "ToolError", message: to_string(error)})
  end

  defp put_error(span, _metadata), do: span

  defp int(value) when is_integer(value), do: value
  defp int(_value), do: nil

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: inspect(value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc false
  def drop_nil(map) when is_map(map) do
    map
    |> Map.reject(fn {_k, v} -> is_nil(v) or v == %{} end)
  end
end
