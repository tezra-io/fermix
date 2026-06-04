defmodule FermixCore.Providers.Telemetry do
  @moduledoc """
  The single emitter for `[:fermix, :provider, :call]` telemetry.

  Every provider adapter (OpenAI chat/responses, Codex, Anthropic) routes its
  LLM-call event through here. The provider supplies the call-specific metadata
  (`:provider`, `:model`, `:status`, `:tokens`, `:agent`, ...); this module folds
  in correlation identifiers (`session_id`, `parent_session`) from the adapter
  opts so the call can be attributed to its run, and — when content capture is
  enabled — a bounded preview of the response `:output` plus `:tool_calls`.

  Downstream, `:provider` + `:model` + `:tokens` are exactly what Opik needs to
  auto-compute USD cost, so no cost is calculated here.
  """

  alias FermixCore.Telemetry

  @type opt ::
          {:session_id, String.t() | nil}
          | {:parent_session, String.t() | nil}
          | {:output, term()}
          | {:tool_calls, [term()] | nil}

  @doc "Emit a provider-call event from already-built `metadata`."
  @spec emit_call(map(), non_neg_integer(), [opt()]) :: :ok
  def emit_call(metadata, duration_ms, opts \\ [])
      when is_map(metadata) and is_integer(duration_ms) and duration_ms >= 0 and is_list(opts) do
    metadata =
      metadata
      |> Map.merge(Telemetry.correlation_from_opts(opts))
      |> maybe_put_content(opts)

    :telemetry.execute([:fermix, :provider, :call], %{duration_ms: duration_ms}, metadata)
  end

  defp maybe_put_content(metadata, opts) do
    if Telemetry.capture_content?() do
      metadata
      |> put_preview(:output, Keyword.get(opts, :output))
      |> put_tool_calls(Keyword.get(opts, :tool_calls))
    else
      metadata
    end
  end

  defp put_preview(metadata, key, value) do
    case Telemetry.preview(value) do
      nil -> metadata
      preview -> Map.put(metadata, key, preview)
    end
  end

  defp put_tool_calls(metadata, nil), do: metadata
  defp put_tool_calls(metadata, []), do: metadata

  defp put_tool_calls(metadata, tool_calls) when is_list(tool_calls) do
    Map.put(metadata, :tool_calls, Enum.map(tool_calls, &tool_call_name/1))
  end

  defp tool_call_name(%{"function" => %{"name" => name}}), do: name
  defp tool_call_name(%{function: %{name: name}}), do: name
  defp tool_call_name(%{"name" => name}), do: name
  defp tool_call_name(%{name: name}), do: name
  defp tool_call_name(other), do: inspect(other)
end
