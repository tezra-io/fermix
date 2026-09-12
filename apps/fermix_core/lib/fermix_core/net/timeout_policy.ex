defmodule FermixCore.Net.TimeoutPolicy do
  @moduledoc """
  Centralized `receive_timeout` policy, keyed by request kind.

  An outbound HTTP request that sets no `receive_timeout` silently inherits
  Req's 15s default — far too tight for a buffered LLM turn or an image
  generation that routinely runs 30-120s. Each call site that knows its kind
  reads its ceiling from here instead of omitting one (and inheriting 15s) or
  hardcoding a duplicate constant, so the numbers live in one table.

  Apply the value as the `Req.new(receive_timeout: ...)` default *before*
  merging any per-route/test `req_options`, so an explicit caller override still
  wins (last-write). Unknown kinds fail loud — there is no catch-all default
  (Rule #12).
  """

  @typedoc "A request kind with its own timeout ceiling."
  @type kind :: :llm_buffered | :image_generation | :media_download | :transcription | :unfurl

  # Buffered LLM: whole-turn response budget (the full body lands at once).
  # Fermix consumes every LLM adapter except Codex in buffered mode; Codex
  # streams and owns its own effort-tuned window, so it is not listed here.
  # 240s (not 120s): Anthropic runs adaptive thinking inside the buffered
  # response, so a high-effort turn deliberates before any byte arrives —
  # the window must cover thinking + answer up to the adapter's max_tokens.
  @llm_buffered_ms 240_000
  # Image generation: providers routinely take 30-120s to render; give headroom.
  @image_generation_ms 300_000
  # Media download: idle window while streaming a provider image/result to disk.
  @media_download_ms 120_000
  # Audio transcription: a buffered multipart upload whose latency tracks the
  # audio length — a multi-minute voice note far exceeds Req's 15s default.
  @transcription_ms 120_000
  # Link previews are auxiliary and must never hold a turn open. The one MiB
  # streaming cap bounds bytes; this bounds idle network time.
  @unfurl_ms 15_000

  @doc """
  Returns the `receive_timeout` (ms) for a request `kind`.

  Raises `FunctionClauseError` on an unknown kind — callers must name a real
  request kind; there is no silent default.
  """
  @spec receive_timeout_for(kind()) :: pos_integer()
  def receive_timeout_for(:llm_buffered), do: @llm_buffered_ms
  def receive_timeout_for(:image_generation), do: @image_generation_ms
  def receive_timeout_for(:media_download), do: @media_download_ms
  def receive_timeout_for(:transcription), do: @transcription_ms
  def receive_timeout_for(:unfurl), do: @unfurl_ms
end
