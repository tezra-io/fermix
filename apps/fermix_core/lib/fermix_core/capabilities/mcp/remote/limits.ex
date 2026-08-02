defmodule FermixCore.Capabilities.MCP.Remote.Limits do
  @moduledoc """
  Fixed bounds for the remote MCP rail (M27 §7.4).

  These are code constants, never config knobs. A remote endpoint is a
  signed-manifest contract with a hosted third party; an operator who could
  widen a limit could widen the blast radius of a hostile or broken server
  without the signature changing.

  Exceeding any count, byte, node, event, page, or cursor bound fails
  **visibly**. Nothing here truncates a schema or a result and continues with
  partial semantics — a partially-parsed contract is exactly what the signed
  descriptor hash exists to prevent.

  Deadlines are not here: they are named failure deadlines and live in
  `FermixCore.Timeouts` (`mcp_remote_*`), so a firing routes through
  `Timeouts.expired/3` like every other one.
  """

  # --- wire framing -------------------------------------------------------
  # The response cap is UNIVERSAL: it applies before status or content-type
  # dispatch, so an initialize body, a JSON success, a 500 error page, a
  # redirect body, and a teardown body are all bounded the same way. It is
  # enforced while streaming, never after buffering.
  @max_response_bytes 4 * 1024 * 1024
  @max_header_block_bytes 64 * 1024
  @max_header_value_bytes 8 * 1024

  @max_request_bytes 1024 * 1024
  @max_request_depth 64

  # --- SSE ----------------------------------------------------------------
  @max_sse_event_bytes 2 * 1024 * 1024
  @max_sse_stream_bytes 4 * 1024 * 1024
  @max_sse_events 256

  # --- discovery ----------------------------------------------------------
  @max_discovery_pages 10
  @max_cursor_bytes 1024
  @max_discovered_tools 128
  @max_discovery_bytes 4 * 1024 * 1024

  @max_schema_bytes 256 * 1024
  @max_schema_depth 32
  @max_schema_nodes 20_000

  # --- results ------------------------------------------------------------
  @max_result_bytes 2 * 1024 * 1024
  @max_result_depth 64

  # --- session shape ------------------------------------------------------
  @max_startup_attempts 3
  @max_queued_calls 16
  # The documented approximate ceiling is ~120 JSON-RPC calls per minute per
  # session; one call per 500 ms is that ceiling, paced rather than burst.
  @min_call_interval_ms 500
  @max_session_id_bytes 256
  # Eden documents `Retry-After` as optional, so an absent header uses one
  # fixed local backoff. A server-supplied value beyond this bound is refused
  # rather than honoured: server-controlled state must not create an unbounded
  # timer.
  @max_retry_after_ms 300_000
  @default_retry_after_ms 60_000
  # Three consecutive unparseable results in one session is a broken peer, not
  # a flaky call; any reviewed valid result resets the counter.
  @max_consecutive_invalid_results 3
  # A drift notification storm must not become a rediscovery loop.
  @max_rediscoveries_per_session 3
  @min_rediscovery_interval_ms 5_000

  @spec max_response_bytes() :: pos_integer()
  def max_response_bytes, do: @max_response_bytes

  @spec max_header_block_bytes() :: pos_integer()
  def max_header_block_bytes, do: @max_header_block_bytes

  @spec max_header_value_bytes() :: pos_integer()
  def max_header_value_bytes, do: @max_header_value_bytes

  @spec max_request_bytes() :: pos_integer()
  def max_request_bytes, do: @max_request_bytes

  @spec max_request_depth() :: pos_integer()
  def max_request_depth, do: @max_request_depth

  @spec max_sse_event_bytes() :: pos_integer()
  def max_sse_event_bytes, do: @max_sse_event_bytes

  @spec max_sse_stream_bytes() :: pos_integer()
  def max_sse_stream_bytes, do: @max_sse_stream_bytes

  @spec max_sse_events() :: pos_integer()
  def max_sse_events, do: @max_sse_events

  @spec max_discovery_pages() :: pos_integer()
  def max_discovery_pages, do: @max_discovery_pages

  @spec max_cursor_bytes() :: pos_integer()
  def max_cursor_bytes, do: @max_cursor_bytes

  @spec max_discovered_tools() :: pos_integer()
  def max_discovered_tools, do: @max_discovered_tools

  @spec max_discovery_bytes() :: pos_integer()
  def max_discovery_bytes, do: @max_discovery_bytes

  @spec max_schema_bytes() :: pos_integer()
  def max_schema_bytes, do: @max_schema_bytes

  @spec max_schema_depth() :: pos_integer()
  def max_schema_depth, do: @max_schema_depth

  @spec max_schema_nodes() :: pos_integer()
  def max_schema_nodes, do: @max_schema_nodes

  @spec max_result_bytes() :: pos_integer()
  def max_result_bytes, do: @max_result_bytes

  @spec max_result_depth() :: pos_integer()
  def max_result_depth, do: @max_result_depth

  @spec max_startup_attempts() :: pos_integer()
  def max_startup_attempts, do: @max_startup_attempts

  @spec max_queued_calls() :: pos_integer()
  def max_queued_calls, do: @max_queued_calls

  @spec min_call_interval_ms() :: pos_integer()
  def min_call_interval_ms, do: @min_call_interval_ms

  @spec max_session_id_bytes() :: pos_integer()
  def max_session_id_bytes, do: @max_session_id_bytes

  @spec max_retry_after_ms() :: pos_integer()
  def max_retry_after_ms, do: @max_retry_after_ms

  @spec default_retry_after_ms() :: pos_integer()
  def default_retry_after_ms, do: @default_retry_after_ms

  @spec max_consecutive_invalid_results() :: pos_integer()
  def max_consecutive_invalid_results, do: @max_consecutive_invalid_results

  @spec max_rediscoveries_per_session() :: pos_integer()
  def max_rediscoveries_per_session, do: @max_rediscoveries_per_session

  @spec min_rediscovery_interval_ms() :: pos_integer()
  def min_rediscovery_interval_ms, do: @min_rediscovery_interval_ms
end
