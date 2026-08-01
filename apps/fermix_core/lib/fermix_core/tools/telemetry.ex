defmodule FermixCore.Tools.Telemetry do
  @moduledoc """
  The single emitter for `[:fermix, :tool, :exec]` telemetry.

  Every tool — builtin, plugin, MCP — routes its execution event through here so
  the metadata shape stays uniform: the `agent` name and correlation identifiers
  (`session_id`, `parent_session`) come from the call `context`, which lets a
  tool call be attributed to the exact main turn, subagent run, or scheduled job
  that issued it. Optional `:input`/`:output` previews are attached only when
  content capture is enabled.
  """

  alias FermixCore.Telemetry

  # The emitter is authoritative for these; a caller's `:metadata` cannot
  # override them (defends against a tool injecting a false agent/success).
  @authoritative [:tool, :agent, :success]

  # A turn may carry `:redact_values` — secret values that must not leave the
  # machine in an exported event (MILESTONE_29_ACP_AGENT_SURFACE §8.3). This is
  # the single choke point every tool's content passes through, so the scrub
  # lives here rather than in each tool. Short values are skipped: a two-byte
  # "secret" occurs inside ordinary output and scrubbing it would shred the
  # text without protecting anything.
  @redaction_marker "«redacted»"
  @min_redact_bytes 8

  # Caller `:metadata` is scrubbed too, and unconditionally: unlike the previews
  # it is attached on every emit, so a free-form field (`Tools.Shell`'s verbatim
  # `:command`, or an `:error_summary` carrying a failed child's stdout) is the
  # always-on leak path. Nested maps/lists are walked to this depth; deeper
  # values are passed through unchanged — the cap bounds the work, it never
  # crashes or truncates, and no tool's metadata nests anywhere near it.
  @max_scrub_depth 8

  @type opt ::
          {:metadata, map()}
          | {:input, term()}
          | {:output, term()}
          | {:result, term()}

  @doc """
  Emit a tool-execution event.

  `context` supplies `:agent_name` and correlation ids. `opts`:
    * `:metadata` — extra tool-specific fields (e.g. `:plugin`, `:error`)
    * `:input` — the tool arguments, attached as a bounded preview
    * `:output` — an explicit output preview (overrides `:result`)
    * `:result` — the tool result tuple; its `:output`/`:error` is previewed
      when no explicit `:output` is given

  `:input`/`:output` are attached only when
  `FermixCore.Telemetry.capture_content?/0` is true. Every emitted string has the
  context's `:redact_values` replaced with a redaction marker — metadata values
  included, and for those regardless of capture, since metadata is always
  attached.
  """
  @spec exec(String.t(), map(), boolean(), non_neg_integer(), [opt()]) :: :ok
  def exec(tool_name, context, success, duration_ms, opts \\ [])
      when is_binary(tool_name) and is_map(context) and is_boolean(success) and
             is_integer(duration_ms) and duration_ms >= 0 and is_list(opts) do
    agent = Map.get(context, :agent_name, "unknown")
    redact = redact_values(context)

    metadata =
      opts
      |> Keyword.get(:metadata, %{})
      |> Map.drop(@authoritative)
      |> scrub_metadata(redact)
      |> Map.merge(Telemetry.correlation(context))
      |> maybe_put_content(opts, redact)
      |> Map.merge(%{tool: tool_name, agent: agent, success: success})

    :telemetry.execute([:fermix, :tool, :exec], %{duration_ms: duration_ms}, metadata)
  end

  defp maybe_put_content(metadata, opts, redact) do
    if Telemetry.capture_content?() do
      metadata
      |> put_preview(:input, Keyword.get(opts, :input), redact)
      |> put_preview(:output, output_value(opts), redact)
    else
      metadata
    end
  end

  defp redact_values(context) do
    context
    |> Map.get(:redact_values, [])
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= @min_redact_bytes))
  end

  defp output_value(opts) do
    case Keyword.fetch(opts, :output) do
      {:ok, value} -> value
      :error -> opts |> Keyword.get(:result) |> result_output()
    end
  end

  # Builtin failures (`Tool.error/1`) carry `output: ""` — fall through to the
  # error text instead of tracing an empty body.
  defp result_output({:ok, tool_result}) when is_map(tool_result) do
    case Map.get(tool_result, :output) do
      nil -> Map.get(tool_result, :error)
      "" -> Map.get(tool_result, :error)
      output -> output
    end
  end

  defp result_output(_other), do: nil

  defp put_preview(metadata, key, value, redact) do
    case Telemetry.preview(value) do
      nil -> metadata
      preview -> Map.put(metadata, key, scrub(preview, redact))
    end
  end

  # Scrub caller metadata VALUES. Map keys are never rewritten — a key is a fixed
  # field name every downstream consumer reads by. With nothing to redact the map
  # is returned as-is, so the dominant non-ACP path does no traversal at all.
  defp scrub_metadata(metadata, []), do: metadata

  defp scrub_metadata(metadata, values) do
    Map.new(metadata, fn {key, value} -> {key, scrub_value(value, values, 1)} end)
  end

  defp scrub_value(value, _values, depth) when depth > @max_scrub_depth, do: value

  defp scrub_value(value, values, _depth) when is_binary(value), do: scrub(value, values)

  defp scrub_value(value, values, depth) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, inner} -> {key, scrub_value(inner, values, depth + 1)} end)
  end

  defp scrub_value(value, values, depth) when is_list(value) do
    Enum.map(value, &scrub_value(&1, values, depth + 1))
  end

  # Everything else — atoms, numbers, pids, tuples, structs — is not text, so it
  # holds no occurrence to replace and passes through exactly as the caller wrote
  # it (a struct's shape is part of its contract; no tool's metadata carries one).
  defp scrub_value(value, _values, _depth), do: value

  # Scrub the FINAL preview string, so a secret is caught however it reached the
  # preview (argument, command echo, inspected term).
  defp scrub(preview, []), do: preview

  defp scrub(preview, values) do
    Enum.reduce(values, preview, &String.replace(&2, &1, @redaction_marker))
  end
end
