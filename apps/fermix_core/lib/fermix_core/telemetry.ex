defmodule FermixCore.Telemetry do
  @moduledoc """
  Shared telemetry helpers.

  Beyond the `timed_us/1` stopwatch, this module owns the cross-cutting trace
  contract used by every emitter: correlation identifiers (`session_id`,
  `parent_session`) and the opt-in content capture (`input`/`output` previews)
  that lets a turn, subagent run, or scheduled job be reassembled downstream.

  Content capture is gated by `config :fermix_core, :telemetry, capture_content:`,
  resolved in `config/runtime.exs` — **on** unless `FERMIX_TRACE_CONTENT=0`.
  Bodies stay on the machine (JSONL under a `0700` `FERMIX_HOME`, and the Opik
  instance is local), and a trace missing the request and the response cannot
  answer the questions traces exist for. The test env pins it off.
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

  Reads the configured value; `config/runtime.exs` is the one place that decides
  it (on unless `FERMIX_TRACE_CONTENT=0`). The `false` here is the floor for a VM
  where nothing configured it at all, not a second statement of the default.
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
  A JSON-safe preview of a content value for traces.

  When content capture is off, strings are truncated to #{@max_content_chars}
  characters and other terms are inspected with default limits first. When
  `capture_content?/0` is on the value passes through whole — the operator
  opted into full-fidelity traces, and a clipped preview would defeat the
  point of capturing. `nil` passes through so callers can drop empty fields.
  """
  @spec preview(term()) :: String.t() | nil
  def preview(nil), do: nil

  def preview(value) when is_binary(value) do
    if capture_content?(), do: value, else: truncate(value)
  end

  def preview(value) do
    if capture_content?() do
      inspect(value, limit: :infinity, printable_limit: :infinity)
    else
      value |> inspect() |> truncate()
    end
  end

  defp truncate(string) when is_binary(string) do
    if String.length(string) <= @max_content_chars do
      string
    else
      String.slice(string, 0, @max_content_chars) <> "…[truncated]"
    end
  end

  defp reject_nil(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
