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
  delegators that read their config owner at call time — there are none yet.
  Per-entity timeouts that vary (e.g. a scheduled job's `:timeout_seconds`) are
  **not** indexed here: there is no single value to name.
  """

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
