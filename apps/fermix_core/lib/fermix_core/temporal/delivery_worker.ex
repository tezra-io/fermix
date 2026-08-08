defmodule FermixCore.Temporal.DeliveryWorker do
  @moduledoc """
  One claimed reminder, one bounded send, one durable settlement (M30 §11.2).

  `restart: :temporary`: a worker may only ever run behind a fresh durable claim,
  so neither normal completion nor a crash may make the supervisor re-send
  outside that path. `init/1` performs no I/O at all — it stores its args and
  defers the attempt to `handle_continue/2`, so the scheduler has already
  monitored the returned pid before the channel is touched (§6.3).

  The watchdog is `min(60s, valid_until - now)`: a claimed send always finishes
  or is killed before its validity boundary, which is what stops an obsolete
  early reminder from landing after its superseding rule is due. A non-positive
  remainder means a row was claimed that never should have been — it is settled
  as expired and traced loudly, never sent.

  Settlement is the last **ledger** act the worker performs before exiting
  `:normal`:

    * `:ok` → `delivered` at the send time;
    * a retryable reason (`Delivery.Error.retryable?/1`) → `pending` at the §11.4
      delay, which the Repo turns into `expired` when it would not fit inside the
      validity boundary and into `failed` at the attempt cap;
    * anything else → `failed` with the bounded reason.

  A settlement write that fails is not swallowed: the worker exits abnormally so
  the scheduler's monitor recovers the row rather than leaving it `delivering`.

  One thing follows settlement and touches no ledger state: a `delivered` row
  whose snapshotted payload carries `followup` asks `Temporal.FollowupSupervisor`
  for a post-delivery run (§22.4). That request is fire-and-forget in the strong
  sense — a full, dead, or shutting-down supervisor is logged, traced as a skip,
  and otherwise ignored, because the flourish may never cost the promise.
  """

  use GenServer, restart: :temporary

  require Logger

  alias FermixCore.Delivery.Error
  alias FermixCore.Memory.Repo
  alias FermixCore.Telemetry
  alias FermixCore.Temporal.Delivery
  alias FermixCore.Temporal.FollowupSupervisor
  alias FermixCore.Temporal.Renderer
  alias FermixCore.Temporal.Telemetry, as: TemporalTelemetry

  @max_watchdog_ms 60_000

  # A settlement reached without a channel attempt: no send duration to measure
  # and no rendered message to gate.
  @no_attempt %{text: nil, duration_ms: nil}

  @type args :: %{
          required(:reminder) => map(),
          required(:repo) => GenServer.server(),
          required(:now_fn) => (-> DateTime.t()),
          required(:delivery_opts) => keyword(),
          optional(:followup_supervisor) => Supervisor.supervisor() | nil
        }

  @spec start_link(args()) :: GenServer.on_start()
  def start_link(%{reminder: reminder, repo: repo, now_fn: now_fn, delivery_opts: opts} = args)
      when is_map(reminder) and is_function(now_fn, 0) and is_list(opts) and not is_nil(repo) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init(args), do: {:ok, args, {:continue, :deliver}}

  @impl true
  def handle_continue(:deliver, state) do
    case run(state) do
      :ok -> {:stop, :normal, state}
      {:error, reason} -> {:stop, {:settlement_failed, reason}, state}
    end
  end

  # --- one attempt ---------------------------------------------------------

  defp run(state) do
    row = state.reminder
    now = state.now_fn.()

    case watchdog_ms(row, now) do
      {:ok, timeout_ms} -> render_and_send(state, row, now, timeout_ms)
      :expired -> expire_unclaimable(state, row, now)
    end
  end

  defp render_and_send(state, row, now, timeout_ms) do
    case Renderer.render(row, now) do
      {:ok, text} -> attempt_and_settle(state, row, now, text, timeout_ms)
      {:error, reason} -> fail_unrenderable(state, row, now, reason)
    end
  end

  # The channel send is the work this event family measures, so the settlement it
  # produces carries that duration (§15.2).
  defp attempt_and_settle(state, row, now, text, timeout_ms) do
    {result, elapsed_us} =
      Telemetry.timed_us(fn -> Delivery.attempt(row, text, timeout_ms, state.delivery_opts) end)

    settle(state, row, now, result, %{text: text, duration_ms: div(elapsed_us, 1_000)})
  end

  # The boundary decides, not the millisecond arithmetic: a row with less than a
  # whole millisecond left has NOT expired, and truncating it to zero would
  # report a boundary breach that never happened. Such an attempt gets the
  # smallest watchdog the send can be given.
  defp watchdog_ms(row, now) do
    remaining = DateTime.diff(row.valid_until, now, :millisecond)

    if DateTime.compare(row.valid_until, now) == :gt do
      {:ok, min(@max_watchdog_ms, max(remaining, 1))}
    else
      :expired
    end
  end

  # --- settlement ----------------------------------------------------------

  defp settle(state, row, now, :ok, attempt) do
    case Repo.temporal_reminder_delivered(row.id, now, server: state.repo) do
      {:ok, delivered} ->
        emit(:delivered, delivered, :ok, attempt)
        request_followup(state, row, attempt.text)

      {:error, reason} ->
        settlement_error(row, "delivered", reason)
    end
  end

  defp settle(state, row, now, {:error, reason}, attempt) do
    if Error.retryable?(reason) do
      retry(state, row, now, reason, attempt)
    else
      fail(state, row, now, Delivery.error_text(reason), {:error, reason}, attempt)
    end
  end

  defp retry(state, row, now, reason, attempt) do
    delay_ms = Delivery.retry_delay_ms(row.attempt_count, reason)
    ready_at = DateTime.add(now, delay_ms, :millisecond)
    text = Delivery.error_text(reason)

    case Repo.temporal_reminder_retry(row.id, ready_at, text, now, server: state.repo) do
      {:ok, {outcome, settled}} -> settle_retry(outcome, settled, row, reason, text, attempt)
      {:error, error} -> settlement_error(row, "retry", error)
    end
  end

  defp settle_retry(outcome, settled, row, reason, text, attempt) do
    emit(retry_phase(outcome), settled, {:error, reason}, attempt)
    log_retry(row, outcome, text)
  end

  defp retry_phase(:pending), do: :retry_scheduled
  defp retry_phase(:expired), do: :expired
  defp retry_phase(:failed), do: :failed

  defp fail(state, row, now, text, result, attempt) do
    case Repo.temporal_reminder_failed(row.id, text, now, server: state.repo) do
      {:ok, failed} ->
        Logger.warning("Reminder #{row.id} failed terminally: #{text}")
        emit(:failed, failed, result, attempt)

      {:error, reason} ->
        settlement_error(row, "failed", reason)
    end
  end

  # A claim past the validity boundary cannot happen through the scheduler's due
  # scan, so seeing one means the invariant broke: say so, settle the row as
  # expired through the ordinary retry path (a `ready_at` at/after `valid_until`
  # expires it), and never touch a channel.
  defp expire_unclaimable(state, row, now) do
    Logger.error(
      "Reminder #{row.id} was claimed at or past its validity boundary; expiring without a send"
    )

    case Repo.temporal_reminder_retry(row.id, now, "expired_before_send", now, server: state.repo) do
      {:ok, {outcome, settled}} ->
        emit(retry_phase(outcome), settled, {:error, :claimed_past_validity}, @no_attempt)

      {:error, reason} ->
        settlement_error(row, "expired", reason)
    end
  end

  # An unrenderable payload cannot become truthful on a retry.
  defp fail_unrenderable(state, row, now, reason) do
    Logger.error("Reminder #{row.id} payload could not be rendered: #{inspect(reason)}")
    fail(state, row, now, "unrenderable_payload", {:error, :unrenderable_payload}, @no_attempt)
  end

  defp log_retry(row, :pending, text) do
    Logger.info("Reminder #{row.id} attempt #{row.attempt_count} failed, retrying: #{text}")
    :ok
  end

  defp log_retry(row, outcome, text) do
    Logger.warning(
      "Reminder #{row.id} settled #{outcome} after attempt #{row.attempt_count}: #{text}"
    )

    :ok
  end

  defp settlement_error(row, phase, reason) do
    Logger.error("Reminder #{row.id} #{phase} settlement failed: #{inspect(reason)}")
    {:error, reason}
  end

  # --- the post-delivery follow-up (§22.4) ---------------------------------

  # Absent supervisor means the follow-up rail is not wired into THIS process,
  # which only ever happens where a test constructs worker args by hand: the
  # scheduler always threads the running supervisor, so production has one code
  # path. The flag is read from the row's own snapshotted payload — never from
  # the event, which the delivery path deliberately never reads.
  defp request_followup(state, row, text) do
    case {Map.get(state, :followup_supervisor), row.payload["followup"]} do
      {nil, _flag} -> :ok
      {supervisor, true} -> spawn_followup(supervisor, state, row, text)
      {_supervisor, _unflagged} -> :ok
    end
  end

  # `start_child/2` is a `GenServer.call`, so it EXITS against a dead or
  # shutting-down supervisor rather than returning an error — and shutdown
  # terminates the follow-up supervisor before this worker's own. Catching that
  # exit is what keeps a settled reminder settled.
  defp spawn_followup(supervisor, state, row, text) do
    case FollowupSupervisor.start_followup(supervisor, followup_args(state, row, text)) do
      {:ok, pid} when is_pid(pid) -> :ok
      {:ok, pid, _info} when is_pid(pid) -> :ok
      :ignore -> skip_followup(row, :followup_ignored)
      {:error, reason} -> skip_followup(row, reason)
    end
  catch
    :exit, reason ->
      Logger.warning("Reminder #{row.id} follow-up supervisor is gone: #{inspect(reason)}")
      skip_followup(row, :supervisor_unavailable)
  end

  defp followup_args(state, row, text) do
    %{
      reminder: row,
      delivered_text: text,
      repo: state.repo,
      delivery_opts: state.delivery_opts
    }
  end

  defp skip_followup(row, reason) do
    Logger.warning("Reminder #{row.id} follow-up was not started: #{inspect(reason)}")

    TemporalTelemetry.emit(
      :followup_skipped,
      Keyword.put(TemporalTelemetry.reminder(row), :result, {:error, reason})
    )
  end

  # --- lifecycle telemetry (§15.2) -----------------------------------------

  # The delivered message is the one owner-facing string this family may carry,
  # and only behind the shared content gate the emitter enforces.
  defp emit(:delivered, row, result, attempt) do
    TemporalTelemetry.emit(
      :delivered,
      lifecycle_opts(row, result, attempt) ++ [content: attempt.text]
    )
  end

  defp emit(phase, row, result, attempt) do
    TemporalTelemetry.emit(phase, lifecycle_opts(row, result, attempt))
  end

  defp lifecycle_opts(row, result, attempt) do
    row
    |> TemporalTelemetry.reminder()
    |> Keyword.merge(result: result, duration_ms: attempt.duration_ms)
  end
end
