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
  `FermixCore.Telemetry.capture_content?/0` is true.
  """
  @spec exec(String.t(), map(), boolean(), non_neg_integer(), [opt()]) :: :ok
  def exec(tool_name, context, success, duration_ms, opts \\ [])
      when is_binary(tool_name) and is_map(context) and is_boolean(success) and
             is_integer(duration_ms) and duration_ms >= 0 and is_list(opts) do
    agent = Map.get(context, :agent_name, "unknown")

    metadata =
      opts
      |> Keyword.get(:metadata, %{})
      |> Map.drop(@authoritative)
      |> Map.merge(Telemetry.correlation(context))
      |> maybe_put_content(opts)
      |> Map.merge(%{tool: tool_name, agent: agent, success: success})

    :telemetry.execute([:fermix, :tool, :exec], %{duration_ms: duration_ms}, metadata)
  end

  defp maybe_put_content(metadata, opts) do
    if Telemetry.capture_content?() do
      metadata
      |> put_preview(:input, Keyword.get(opts, :input))
      |> put_preview(:output, output_value(opts))
    else
      metadata
    end
  end

  defp output_value(opts) do
    case Keyword.fetch(opts, :output) do
      {:ok, value} -> value
      :error -> opts |> Keyword.get(:result) |> result_output()
    end
  end

  defp result_output({:ok, tool_result}) when is_map(tool_result),
    do: Map.get(tool_result, :output) || Map.get(tool_result, :error)

  defp result_output(_other), do: nil

  defp put_preview(metadata, key, value) do
    case Telemetry.preview(value) do
      nil -> metadata
      preview -> Map.put(metadata, key, preview)
    end
  end
end
