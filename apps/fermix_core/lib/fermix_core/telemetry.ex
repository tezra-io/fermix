defmodule FermixCore.Telemetry do
  @moduledoc """
  Shared telemetry helpers.

  Beyond the `timed_us/1` stopwatch, this module owns the cross-cutting trace
  contract used by every emitter: correlation identifiers (`session_id`,
  `parent_session`) and the opt-in content capture (`input`/`output` previews)
  that lets a turn, subagent run, or scheduled job be reassembled downstream.

  Content capture is gated by `config :fermix_core, :telemetry, capture_content:`
  (default `false`) so production traces stay lean; flip it on for end-to-end
  evaluation where prompt/response bodies matter.
  """

  @max_content_chars 2_000
  @correlation_keys [:session_id, :parent_session]

  @spec timed_us((-> result)) :: {result, non_neg_integer()} when result: term()
  def timed_us(fun) when is_function(fun, 0) do
    start = System.monotonic_time(:microsecond)
    result = fun.()
    {result, System.monotonic_time(:microsecond) - start}
  end

  @doc """
  Whether prompt/response bodies should be attached to telemetry and traces.

  Off by default. Enable via config or the `FERMIX_TRACE_CONTENT` env var
  (wired in `config/runtime.exs`) when capturing traces for evaluation.
  """
  @spec capture_content?() :: boolean()
  def capture_content? do
    :fermix_core
    |> Application.get_env(:telemetry, [])
    |> Keyword.get(:capture_content, false)
  end

  @doc """
  Correlation identifiers pulled from a loop/tool `context` map.

  Returns only the keys that are present and non-nil, so callers can
  `Map.merge/2` it into telemetry metadata without introducing nil noise.
  """
  @spec correlation(map()) :: map()
  def correlation(context) when is_map(context) do
    context
    |> Map.take(@correlation_keys)
    |> reject_nil()
  end

  @doc "Correlation identifiers pulled from an adapter/provider opts keyword."
  @spec correlation_from_opts(keyword()) :: map()
  def correlation_from_opts(opts) when is_list(opts) do
    @correlation_keys
    |> Enum.into(%{}, fn key -> {key, Keyword.get(opts, key)} end)
    |> reject_nil()
  end

  @doc """
  A bounded, JSON-safe preview of a content value for traces.

  Strings are truncated to #{@max_content_chars} characters; other terms are
  inspected first. `nil` passes through so callers can drop empty fields.
  """
  @spec preview(term()) :: String.t() | nil
  def preview(nil), do: nil
  def preview(value) when is_binary(value), do: truncate(value)
  def preview(value), do: value |> inspect() |> truncate()

  defp truncate(string) when is_binary(string) do
    if String.length(string) <= @max_content_chars do
      string
    else
      String.slice(string, 0, @max_content_chars) <> "…[truncated]"
    end
  end

  defp reject_nil(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
