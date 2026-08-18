defmodule FermixCore.Timeouts do
  @moduledoc """
  The single registry of named **failure-deadline** timeouts plus `expired/3`,
  the helper every firing routes through.

  A timeout that fires should announce itself — `timeout: <name> after <ms>ms` —
  not surface as a downstream symptom. The motivating incident: a slow cold
  screen capture exceeded a bare `@exec_timeout_ms` in the computer-use Port
  driver, and the late response then reappeared as the cryptic
  `Session received unexpected message in handle_info/2`. Naming the deadline and
  logging at the firing site turns that into one greppable line.

  ## Scope — failure deadlines only

  Only deadlines whose expiry is an *error* belong here. Expected/periodic timers
  (heartbeats, polls, idle-flush, socket-accept) are normal control flow, not
  failures — do **not** route them through `expired/3`.

  ## Not an HTTP receive registry

  Per-kind HTTP whole-response receive budgets live in
  `FermixCore.Net.TimeoutPolicy` (`:llm_buffered`/`:image_generation`/…). This
  module owns the non-HTTP deadlines (and, as they migrate, HTTP connect +
  per-chunk) — never a flat `http_recv` that would regress those per-kind budgets.

  ## Compile-time literals vs delegators

  The values below are compile-time literals (greppable, doc-attachable). Config
  driven, operator-tunable single-global timeouts are exposed as thin runtime
  delegators that read their config owner at call time — `harness_inactivity/0`
  and `harness_wall_clock/0` are the first, reading `Harness.Config`. Per-entity
  timeouts that vary (e.g. a scheduled job's `:timeout_seconds`, or a coding
  harness run's per-invocation `timeout_minutes`) are **not** indexed here: there
  is no single value to name — the delegators expose only the configured default.
  """

  alias FermixCore.Harness.Config, as: HarnessConfig
  alias FermixCore.Timeouts.Telemetry

  require Logger

  # --- Computer-use ---------------------------------------------------------
  # The sidecar action receive (cold capture can be slow; the legacy 15_000 was
  # too tight and caused the incident) and the outer Session call that wraps it.
  #
  # INVARIANT: cu_session_call() >= cu_sidecar_action() + cu_call_cushion(), so
  # the inner receive reports the timeout before the outer GenServer.call exits.
  # A tighter gap lets the call exit first and re-creates the desync the incident
  # exposed. Locked by a test in timeouts_test.exs.
  @cu_sidecar_action_ms 30_000
  @cu_call_cushion_ms 5_000
  @cu_session_call_ms 40_000

  @doc "Receive budget for one sidecar action (cold screen capture included)."
  @spec cu_sidecar_action() :: pos_integer()
  def cu_sidecar_action, do: @cu_sidecar_action_ms

  @doc "Outer `Session.execute` GenServer.call budget; outlives `cu_sidecar_action/0`."
  @spec cu_session_call() :: pos_integer()
  def cu_session_call, do: @cu_session_call_ms

  @doc "Minimum cushion the outer call must keep over the inner receive (invariant)."
  @spec cu_call_cushion() :: pos_integer()
  def cu_call_cushion, do: @cu_call_cushion_ms

  # --- Coding harness -------------------------------------------------------
  # The tiered stall watchdog for a local harness run (design §9.2): a fixed
  # first-event deadline plus two config-driven deadlines. Only the wall clock is
  # a true failure (the run terminates `failed/:timeout`, routed through
  # `expired/3`); first-event and inactivity are advisory notices, so they are
  # NOT routed through `expired/3` (scope rule above — failure deadlines only).
  #
  # INVARIANT: harness_first_event() < harness_inactivity() < harness_wall_clock()
  # at their defaults, so the tiers escalate in order (a first-event notice, then
  # an inactivity notice, then termination). Locked by a test in timeouts_test.exs.
  @harness_first_event_ms 120_000

  @doc "Fixed deadline to the first stream event before the auth/config notice fires."
  @spec harness_first_event() :: pos_integer()
  def harness_first_event, do: @harness_first_event_ms

  @doc """
  Config-driven inactivity deadline (`inactivity_minutes`) between events before
  the stall notice fires. Advisory — the run continues; not a `expired/3` failure.
  """
  @spec harness_inactivity() :: pos_integer()
  def harness_inactivity, do: HarnessConfig.inactivity_minutes() * 60_000

  @doc """
  Config-driven default wall-clock deadline (`default_timeout_minutes`) after
  which a run is terminated `failed/:timeout`. This is the DEFAULT only; a run's
  actual wall clock is its per-invocation `timeout_minutes` and the firing (from
  `CommandHost`'s timer) routes the measured ms through `expired/3`.
  """
  @spec harness_wall_clock() :: pos_integer()
  def harness_wall_clock, do: HarnessConfig.default_timeout_minutes() * 60_000

  # --- Remote MCP (M27 §7.4) ------------------------------------------------
  # Every one of these is a failure deadline: expiry means the remote plugin is
  # unusable, never "wait longer". They are fixed constants, not config knobs —
  # a remote endpoint is a signed-manifest contract, and an operator who could
  # stretch a deadline could hold a hostile server's connection open at will.
  #
  # INVARIANT: mcp_remote_startup() must exceed
  # mcp_remote_connect() + mcp_remote_initialize() + mcp_remote_discover(), so
  # the overall startup window can actually contain one full attempt and the
  # inner deadline is what reports. Locked by a test in timeouts_test.exs.
  @mcp_remote_startup_ms 60_000
  @mcp_remote_connect_ms 10_000
  @mcp_remote_initialize_ms 15_000
  @mcp_remote_discover_ms 15_000
  @mcp_remote_call_ms 60_000
  @mcp_remote_teardown_ms 10_000

  @doc "Overall window for one connect + initialize + discover attempt."
  @spec mcp_remote_startup() :: pos_integer()
  def mcp_remote_startup, do: @mcp_remote_startup_ms

  @doc "One TCP/TLS connection to a validated remote MCP peer."
  @spec mcp_remote_connect() :: pos_integer()
  def mcp_remote_connect, do: @mcp_remote_connect_ms

  @doc "The MCP `initialize` request/response."
  @spec mcp_remote_initialize() :: pos_integer()
  def mcp_remote_initialize, do: @mcp_remote_initialize_ms

  @doc "One `tools/list` page."
  @spec mcp_remote_discover() :: pos_integer()
  def mcp_remote_discover, do: @mcp_remote_discover_ms

  @doc "One remote tool call, INCLUDING its wait in the serialization queue."
  @spec mcp_remote_call() :: pos_integer()
  def mcp_remote_call, do: @mcp_remote_call_ms

  @doc "Authenticated MCP session teardown (`DELETE`) before the socket closes."
  @spec mcp_remote_teardown() :: pos_integer()
  def mcp_remote_teardown, do: @mcp_remote_teardown_ms

  # --- ACP bridge -----------------------------------------------------------
  # The `fermix acp` handshake deadline (MILESTONE_29 §6.2). Both ends of the
  # same exchange read it: the daemon's `Channels.Acp.Peer` refuses a connection
  # that has not sent its hello line in time (routing the firing through
  # `expired/3`), and `Fermix.CLI.AcpCommand` gives up waiting for the ack. One
  # name, one value — a local constant on either side would drift.
  @acp_bridge_hello_ms 5_000

  @doc "Deadline for the `fermix acp` bridge hello/ack exchange, read by both ends."
  @spec acp_bridge_hello() :: pos_integer()
  def acp_bridge_hello, do: @acp_bridge_hello_ms

  # --- Transcription streaming (M21 Phase 2) --------------------------------
  # WS connect covers TCP+TLS+upgrade for a native STT stream; close-drain bounds
  # the window between CloseStream/audio.done and the vendor's final results +
  # server close. KeepAlive is a periodic timer and deliberately NOT here.
  @transcription_ws_connect_ms 10_000
  @transcription_ws_close_drain_ms 10_000

  @doc "WS handshake budget for a native transcription stream (Deepgram/xAI)."
  @spec transcription_ws_connect() :: pos_integer()
  def transcription_ws_connect, do: @transcription_ws_connect_ms

  @doc "Budget from CloseStream/audio.done to the vendor's final results + close."
  @spec transcription_ws_close_drain() :: pos_integer()
  def transcription_ws_close_drain, do: @transcription_ws_close_drain_ms

  # --- Local STT sidecar (M21 Phase 2b) -------------------------------------
  # hello is emitted before model load, so it bounds process start only. batch
  # bounds one whole-file recognition (20 MB ingress cap, 7-20x realtime ⇒ minutes
  # of headroom). flush bounds stream_end -> stream_done.
  @stt_sidecar_hello_ms 10_000
  @stt_sidecar_batch_ms 300_000
  @stt_sidecar_flush_ms 30_000

  @doc "fermix-stt hello line deadline after spawn."
  @spec stt_sidecar_hello() :: pos_integer()
  def stt_sidecar_hello, do: @stt_sidecar_hello_ms

  @doc "One fermix-stt batch transcribe round-trip."
  @spec stt_sidecar_batch() :: pos_integer()
  def stt_sidecar_batch, do: @stt_sidecar_batch_ms

  @doc "fermix-stt stream_end -> stream_done flush deadline."
  @spec stt_sidecar_flush() :: pos_integer()
  def stt_sidecar_flush, do: @stt_sidecar_flush_ms

  # --- Meetings (M21 Phase 3) -----------------------------------------------
  # The meetbot sidecar's hello handshake, the join attempt (which includes the
  # host's admission of the bot from the waiting room), and the post-meeting
  # summarization — the last also bounds the drain of the transcription tail, so
  # it is the longest deadline in this module by design.
  @meetbot_handshake_ms 15_000
  @meetbot_join_ms 90_000
  @meeting_summarize_ms 600_000

  @doc "meetbot sidecar hello line deadline after spawn."
  @spec meetbot_handshake() :: pos_integer()
  def meetbot_handshake, do: @meetbot_handshake_ms

  @doc "Join request to admission (knock included) before the attempt is failed."
  @spec meetbot_join() :: pos_integer()
  def meetbot_join, do: @meetbot_join_ms

  @doc "Transcript drain plus map-reduce summarization of one meeting."
  @spec meeting_summarize() :: pos_integer()
  def meeting_summarize, do: @meeting_summarize_ms

  @doc """
  Record a fired failure timeout and return its firing-site error shape.

  Logs a greppable line, emits the shared `[:fermix, :timeout, :expired]` event
  (via `Timeouts.Telemetry`), and returns `{:error, {:timeout, name, ms}}`.

  `ctx` carries correlation identifiers (`:session_id`, `:parent_session`) and
  optional context. Correlation IDs always ride the event and the log line; any
  other context is gated by content capture in the emitter (never leaked into
  always-on traces). Each caller maps the returned tuple back to its own public
  error shape — `{:error, {:timeout, name, ms}}` is not a blanket return.
  """
  @spec expired(atom(), non_neg_integer(), map()) ::
          {:error, {:timeout, atom(), non_neg_integer()}}
  def expired(name, ms, ctx \\ %{})
      when is_atom(name) and is_integer(ms) and ms >= 0 and is_map(ctx) do
    Logger.warning("timeout: #{name} after #{ms}ms" <> ctx_suffix(ctx))
    Telemetry.emit_expired(name, ms, ctx)
    {:error, {:timeout, name, ms}}
  end

  # Only the scalar correlation id is appended to the human log line; richer
  # context is gated/redacted in the telemetry emitter, not logged raw.
  defp ctx_suffix(ctx) do
    case Map.get(ctx, :session_id) do
      nil -> ""
      session_id -> " session_id=#{session_id}"
    end
  end
end
