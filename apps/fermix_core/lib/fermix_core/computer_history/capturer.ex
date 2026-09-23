defmodule FermixCore.ComputerHistory.Capturer do
  @moduledoc """
  Owns the compux sidecar Port in **capture mode** (MILESTONE_32 §6.4, §8.4a).
  Unlike computer-use (a correlated request→response through `Compux.Transport`),
  capture is an **unsolicited event push**: after `observe_start` is acked, the
  sidecar streams NDJSON event frames. So this process owns a RAW Port and
  `handle_info`s inbound lines itself, reusing `Compux.Port`'s tested open + kill
  lifecycle and `Compux.Frame` to encode its two requests — never a transport,
  which would consume the very lines this rail exists to read.

  Its two requests carry no generations and no deadline: they are not part of the
  action wire's correlated conversation, and the sidecar reads them the same way
  it always has. Its inbound `ack` and `event` families are unchanged by the
  protocol bump apart from the version integer inside the ack, so
  `ComputerHistory.Wire` stays the decoder — it maps an event onto the columns
  `Ingest` writes, which a generic frame decoder does not.

  Lifecycle, all bounded and fail-visible:

    * **singleton** — acquires the machine-wide `SingletonLock` first; a second
      daemon on the same Mac **stands down** and re-acquires on a tick when the
      holder exits (§8.6). The holder heartbeats the lock to prove liveness.
    * **handshake** — `observe_start`'s ack must report the `protocol_version`
      this build speaks; a mismatch, a refused start, or **no ack at all
      within `@handshake_timeout_ms`** **degrades** loudly (doctor-visible)
      rather than crash-looping. The handshake is a mode of its own
      (`:handshaking`): capture does not read as running until the ack lands.
    * **backpressure** — events micro-batch to `Ingest` (which owns
      allowlist ▸ scrub ▸ tag ▸ write); a bounded queue drops to an
      `observer.gap{overflow}` rather than growing the mailbox.
    * **gaps are first-class** — a malformed frame, an oversize frame, a write
      failure, or a sidecar exit each becomes a synthetic `observer.gap` (a
      distinct `boot_id` so it never collides with sidecar `(boot_id, seq)`),
      never a silent hole.
    * **teardown** — flushes the buffer, `observe_stop`s, kills the sidecar pid
      (`Compux.Port.kill/1`), and releases the lock, on every exit path.

  It never uses `CaptureHealth` — that breaker guards ScreenCaptureKit wedges,
  and capture is Accessibility-only (no screen capture); this rail's health is
  bounded restart + gaps + the doctor row.
  """

  use GenServer

  require Logger

  alias Compux.Frame
  alias Compux.Port, as: SidecarPort
  alias FermixCore.ComputerHistory.Config
  alias FermixCore.ComputerHistory.Ingest
  alias FermixCore.ComputerHistory.SingletonLock
  alias FermixCore.ComputerHistory.Wire
  alias FermixCore.ComputerUse.SidecarInstaller
  alias FermixCore.Memory.Repo

  # The wire this rail requires, pinned EQUAL to the library's own
  # `Compux.Protocol.protocol_version()` (a test proves it, so the two constants
  # cannot drift). An installed sidecar from an older release mismatches here and
  # capture degrades loudly rather than interpreting frames it does not speak.
  @capture_protocol_version Compux.Protocol.protocol_version()
  @gap_boot_id "fermix-capturer"

  # An unacked handshake is bounded: a sidecar that answers `observe_start` with
  # nothing at all (or with a frame this wire cannot read) used to leave the
  # capturer waiting forever while it heartbeat the machine-wide lock — so the
  # other daemon on the Mac stood down for good and NOBODY captured (§8.6).
  @handshake_timeout_ms 10_000

  @batch_size 25
  @max_queue 1_000
  @max_frame_bytes 1_048_576
  @flush_interval_ms 2_000

  # A sidecar that exits is retried in-process (bounded, backed-off) rather than
  # crashing the GenServer — so a sidecar dying immediately on every start can
  # never drive a supervisor restart storm that cascades into the daemon. After
  # the budget is spent the rail degrades loudly (doctor-visible) instead. A
  # clean handshake resets the budget, so a sidecar that runs a while then dies
  # gets a fresh allotment.
  @max_restart_attempts 5
  @restart_backoff_ms 1_000

  @type mode ::
          :bootstrapping | :handshaking | :capturing | :restarting | :standing_down | :degraded

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Introspection for `/history status` and the doctor row."
  @spec status(GenServer.server()) :: %{
          mode: mode(),
          reason: term(),
          lock_holder: term(),
          stale_deadlines_ignored: non_neg_integer()
        }
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, _reason -> %{mode: :not_running, reason: nil, lock_holder: nil}
  end

  @impl true
  def init(opts) do
    # Trap exits so `terminate/2` — the SOLE path that releases the singleton
    # lock, `observe_stop`s, kills the sidecar pgid, and does the final flush —
    # actually runs on a supervisor `:shutdown` (`/history off`'s
    # `terminate_child`, a clean tree shutdown, a rest_for_one teardown). Without
    # this, `:shutdown` kills the process outright and none of that cleanup runs
    # (the `ComputerUse.Session` precedent).
    Process.flag(:trap_exit, true)

    state = %{
      mode: :bootstrapping,
      repo: Keyword.get(opts, :repo, Repo),
      apps: Keyword.get_lazy(opts, :apps, &Config.apps/0),
      binary_path: Keyword.get(opts, :binary_path),
      sidecar_env: Keyword.get(opts, :sidecar_env, []),
      lock_path: Keyword.get_lazy(opts, :lock_path, &SingletonLock.default_path/0),
      lock_held?: false,
      lock_holder: nil,
      sidecar: nil,
      buffer: [],
      partial: "",
      # A per-incarnation gap boot_id: a fixed prefix + a boot-unique suffix so a
      # restart's `gap_seq` reset to 0 never collides with a prior incarnation's
      # (boot_id, source_seq) — which `INSERT OR IGNORE` would silently drop,
      # erasing the very discontinuity the gap marks.
      gap_boot_id: gap_boot_id(),
      gap_seq: 0,
      overflow_pending?: false,
      protocol_ok?: false,
      # Bumped on every sidecar open, and carried by that open's handshake
      # deadline, so a deadline armed for a sidecar that is already gone can
      # never tear down the incarnation that replaced it.
      generation: 0,
      stale_deadlines_ignored: 0,
      restart_attempts: 0,
      degraded_reason: nil,
      batch_size: Keyword.get(opts, :batch_size, @batch_size),
      max_queue: Keyword.get(opts, :max_queue, @max_queue),
      flush_interval_ms: Keyword.get(opts, :flush_interval_ms, @flush_interval_ms),
      handshake_timeout_ms: Keyword.get(opts, :handshake_timeout_ms, @handshake_timeout_ms),
      heartbeat_interval_ms:
        Keyword.get(opts, :heartbeat_interval_ms, SingletonLock.heartbeat_interval_ms()),
      reacquire_interval_ms: Keyword.get(opts, :reacquire_interval_ms, 30_000),
      max_restart_attempts: Keyword.get(opts, :max_restart_attempts, @max_restart_attempts),
      restart_backoff_ms: Keyword.get(opts, :restart_backoff_ms, @restart_backoff_ms)
    }

    # All work — lock, Port, repo — happens off `init` so boot never blocks on
    # the sidecar handshake or a contended lock.
    {:ok, state, {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:bootstrap, state) do
    case SingletonLock.acquire(state.lock_path) do
      :ok ->
        {:noreply, begin_capture(%{state | lock_held?: true})}

      {:error, {:held_by, home}} ->
        Logger.warning(
          "computer_history capturer standing down; another daemon holds capture (#{inspect(home)})"
        )

        schedule(:reacquire, state.reacquire_interval_ms)
        {:noreply, %{state | mode: :standing_down, lock_holder: home}}
    end
  end

  # --- start / handshake --------------------------------------------------

  # Fresh entry into the capture lifecycle (bootstrap or reacquire): the periodic
  # timers are started ONCE here and perpetuate through transient sidecar
  # restarts; `open_sidecar/1` (re)opens the Port without touching the timers.
  defp begin_capture(state) do
    schedule(:heartbeat, state.heartbeat_interval_ms)
    schedule(:flush, state.flush_interval_ms)
    open_sidecar(%{state | restart_attempts: 0})
  end

  # The OS process goes into state the instant it exists, before anything can fail
  # against it. Sending `observe_start` can fail on a sidecar that died between the
  # spawn and the write, and a degrade that could not see the port would leave that
  # process running with nobody owning it — the leak `Compux.Port`'s own moduledoc
  # warns about, from the one path where we had just created it. Open → close on
  # every path, including this one.
  defp open_sidecar(state) do
    state = %{state | generation: state.generation + 1}

    case resolve_binary(state.binary_path) do
      {:ok, path} -> open_and_observe(state, path)
      {:error, reason} -> degrade(state, reason)
    end
  end

  defp open_and_observe(state, path) do
    case SidecarPort.open(binary_path: path, env: state.sidecar_env) do
      {:ok, sidecar} -> start_observing(%{state | sidecar: sidecar}, sidecar)
      {:error, reason} -> degrade(state, reason)
    end
  end

  defp start_observing(state, sidecar) do
    request = %{"action" => "observe_start", "params" => params(state)}

    case send_frame(sidecar, "o-start", request) do
      :ok ->
        schedule({:handshake_deadline, state.generation}, state.handshake_timeout_ms)
        %{state | mode: :handshaking, protocol_ok?: false}

      # `degrade/1` reads `state.sidecar`, which is why it was put there first.
      {:error, reason} ->
        degrade(state, reason)
    end
  end

  defp resolve_binary(nil), do: SidecarInstaller.binary_path()
  defp resolve_binary(path) when is_binary(path), do: {:ok, path}

  # The sidecar reads its observe arguments from a nested `params` object, so the
  # shape is preserved exactly across the framing change.
  defp params(state), do: %{"apps" => state.apps}

  # A typed `request` frame with a request id and NOTHING else from the envelope:
  # this rail is not part of the action wire's correlated conversation, so it mints
  # no generations, no mutation sequence and no deadline, and the sidecar requires
  # none of them. A frame that cannot be encoded is a bug here, not a sidecar
  # fault, so it fails loud rather than degrading the rail.
  defp send_frame(sidecar, request_id, args) do
    {:ok, line} = Frame.encode(%Frame.Request{request_id: request_id, args: args})
    Port.command(sidecar.port, line)
    :ok
  rescue
    ArgumentError -> {:error, :sidecar_unavailable}
  end

  # --- inbound frames -----------------------------------------------------

  @impl true
  def handle_info({port, {:data, {:eol, chunk}}}, %{sidecar: %{port: port}} = state) do
    line = state.partial <> chunk

    # The Port's line limit is 16MB (compux sizes it for screenshot responses),
    # so a complete-but-huge frame arrives here as one `:eol`, bypassing the
    # `:noeol` accumulator. Cap it the same way: gap an oversize frame rather
    # than decode a multi-MB blob (event content is capped sidecar-side).
    new_state =
      if byte_size(line) > @max_frame_bytes do
        buffer_gap(state, "oversize")
      else
        route_frame(state, line)
      end

    {:noreply, %{new_state | partial: ""}}
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{sidecar: %{port: port}} = state) do
    partial = state.partial <> chunk

    if byte_size(partial) > @max_frame_bytes do
      # An unterminated frame over the cap: drop it, gap it, and resync on the
      # next complete line rather than accumulating unbounded.
      {:noreply, %{buffer_gap(state, "truncated") | partial: ""}}
    else
      {:noreply, %{state | partial: partial}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{sidecar: %{port: port}} = state) do
    # Flush verified content NOW, while `protocol_ok?` still holds — a restart that
    # later exhausts its budget must never silently drop already-verified events.
    gapped = buffer_gap(flush(state), "restart")

    if state.restart_attempts < state.max_restart_attempts do
      Logger.warning(
        "computer_history sidecar exited (status #{status}); retry " <>
          "#{state.restart_attempts + 1}/#{state.max_restart_attempts} in #{state.restart_backoff_ms}ms"
      )

      schedule(:retry_capture, state.restart_backoff_ms)

      {:noreply,
       %{
         gapped
         | mode: :restarting,
           protocol_ok?: false,
           sidecar: nil,
           restart_attempts: state.restart_attempts + 1
       }}
    else
      Logger.error("computer_history sidecar exited (status #{status}); restart budget exhausted")
      {:noreply, degrade(gapped, {:sidecar_restart_exhausted, status})}
    end
  end

  def handle_info(:retry_capture, %{mode: :restarting} = state) do
    {:noreply, open_sidecar(state)}
  end

  # The ack never came. Degrade (which stops the sidecar and RELEASES the lock)
  # instead of waiting on it forever.
  def handle_info(
        {:handshake_deadline, generation},
        %{mode: :handshaking, generation: generation} = state
      ) do
    {:noreply, degrade(state, :handshake_timeout)}
  end

  # A deadline armed for a sidecar open that has since been acked, restarted or
  # degraded: the incarnation it belonged to is gone, so it decides nothing. The
  # count is a status fact (and the test's observable): "ignored" must be
  # provable, not inferred from a wait.
  def handle_info({:handshake_deadline, generation}, state) do
    Logger.debug(
      "computer_history capturer ignored a stale handshake deadline (gen #{generation})"
    )

    {:noreply, %{state | stale_deadlines_ignored: state.stale_deadlines_ignored + 1}}
  end

  def handle_info(:flush, state) do
    flushed = flush(state)
    # Only the periodic tick reschedules itself; size- and ack-triggered flushes
    # do not (which is what keeps a single flush timer, never a proliferating one).
    # The timer perpetuates through a transient `:restarting` window so buffered
    # gaps/events still drain while the sidecar is being reopened.
    if flushed.mode in [:handshaking, :capturing, :restarting],
      do: schedule(:flush, flushed.flush_interval_ms)

    {:noreply, flushed}
  end

  def handle_info(:heartbeat, %{lock_held?: true} = state) do
    SingletonLock.heartbeat(state.lock_path)
    schedule(:heartbeat, state.heartbeat_interval_ms)
    {:noreply, state}
  end

  def handle_info(:heartbeat, state), do: {:noreply, state}

  def handle_info(:reacquire, %{mode: :standing_down} = state) do
    case SingletonLock.acquire(state.lock_path) do
      :ok ->
        Logger.info("computer_history capturer acquired capture lock; resuming")
        {:noreply, begin_capture(%{state | lock_held?: true, lock_holder: nil})}

      {:error, {:held_by, home}} ->
        schedule(:reacquire, state.reacquire_interval_ms)
        {:noreply, %{state | lock_holder: home}}
    end
  end

  # Stale Port messages after a teardown/degrade — ignore.
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:status, _from, state) do
    reply = %{
      mode: state.mode,
      reason: state.degraded_reason,
      lock_holder: state.lock_holder,
      stale_deadlines_ignored: state.stale_deadlines_ignored
    }

    {:reply, reply, state}
  end

  # --- frame routing ------------------------------------------------------

  defp route_frame(state, line) do
    case Wire.decode(line) do
      {:event, event} -> ingest_event(state, event)
      {:ack, ack} -> handle_ack(state, ack)
      {:error, reason} -> handle_decode_error(state, reason)
    end
  end

  # A sidecar too old to know `observe_start` answers the unknown action with a
  # POSITIONAL frame — no `"type"` — so a typeless line while the handshake is
  # still outstanding IS the protocol mismatch, and gapping it left the rail
  # waiting on an ack that could never come. Once the handshake has verified the
  # wire, a typeless line is an ordinary hole in the record.
  defp handle_decode_error(%{protocol_ok?: false} = state, :missing_frame_type) do
    degrade(state, {:protocol_mismatch, %{required: @capture_protocol_version, sidecar: :pre_v6}})
  end

  defp handle_decode_error(state, reason), do: buffer_gap(state, "malformed:#{gap_label(reason)}")

  defp handle_ack(%{protocol_ok?: true} = state, _ack), do: state

  defp handle_ack(state, %{
         action: "observe_start",
         ok: true,
         protocol_version: @capture_protocol_version
       }) do
    Logger.info("computer_history capture started (protocol v#{@capture_protocol_version})")
    # A clean handshake proves the sidecar is healthy — reset the restart budget.
    flush(%{state | mode: :capturing, protocol_ok?: true, restart_attempts: 0})
  end

  defp handle_ack(state, %{action: "observe_start", protocol_version: version})
       when version != @capture_protocol_version do
    degrade(state, {:protocol_mismatch, %{required: @capture_protocol_version, sidecar: version}})
  end

  defp handle_ack(state, %{action: "observe_start", ok: false}) do
    degrade(state, :observe_start_refused)
  end

  defp handle_ack(state, _ack), do: state

  # Valid events buffer up to `max_queue`; past that they coalesce to one gap
  # (`buffer_gap` owns the bound). They flush only once the handshake confirmed
  # the wire — a mismatched sidecar's frames are never interpreted as real events.
  defp ingest_event(state, event) do
    cond do
      length(state.buffer) >= state.max_queue ->
        buffer_gap(state, "overflow")

      length(state.buffer) + 1 >= state.batch_size ->
        flush(%{state | buffer: [event | state.buffer]})

      true ->
        %{state | buffer: [event | state.buffer]}
    end
  end

  # --- flush + gaps -------------------------------------------------------

  # `flush/1` performs the write only; rescheduling the periodic tick is owned
  # solely by `handle_info(:flush)`, so size- and ack-triggered flushes never
  # spawn a second timer. It PARTITIONS the buffer: Fermix-authored gaps are
  # trustworthy and written regardless of handshake state (so a discontinuity is
  # never lost when the wire is unverified or degrading), while sidecar frames are
  # written only once `protocol_ok?` and otherwise HELD for a later handshake.
  defp flush(%{buffer: []} = state), do: state

  defp flush(state) do
    {writable, held} = Enum.split_with(Enum.reverse(state.buffer), &writable?(&1, state))
    do_flush(state, writable, Enum.reverse(held))
  end

  # A self-authored gap (its boot_id is this incarnation's gap_boot_id) is always
  # writable; any other row is a sidecar frame, writable only after verification.
  defp writable?(%{boot_id: boot_id}, %{gap_boot_id: gap_boot_id}) when boot_id == gap_boot_id,
    do: true

  defp writable?(_entry, state), do: state.protocol_ok?

  defp do_flush(state, [], held), do: %{state | buffer: held}

  defp do_flush(state, writable, held) do
    case Ingest.ingest(writable, repo: state.repo, apps: state.apps) do
      {:ok, stats} ->
        log_ingest_stats(stats)
        %{state | buffer: held, overflow_pending?: false}

      {:error, reason} ->
        Logger.error("computer_history capture flush failed: #{inspect(reason)}; dropping batch")
        # Drop the failed batch (bounded — never re-buffer/retry forever) and gap it.
        buffer_gap(%{state | buffer: held, overflow_pending?: false}, "write_failure")
    end
  end

  # Counts only, never content (§15.1). A flush that silently loses rows to the
  # allowlist, to the title collapse or to the private/URL gates is
  # indistinguishable from a capture gap — the live spool ran at 99% collapsed
  # frames with nothing anywhere to say so. A flush that wrote everything it was
  # given says nothing. Refusals print BY KIND so "the recorder is sending private
  # frames" and "the recorder is sending unusable addresses" stay distinguishable.
  defp log_ingest_stats(%{dropped: 0, collapsed: 0, refused: refused} = stats) do
    if refusals?(refused), do: log_stats(stats), else: :ok
  end

  defp log_ingest_stats(stats), do: log_stats(stats)

  defp refusals?(refused), do: Enum.any?(refused, fn {_kind, count} -> count > 0 end)

  defp log_stats(%{written: written, dropped: dropped, collapsed: collapsed, refused: refused}) do
    Logger.debug(
      "computer_history ingest: written #{written}, dropped #{dropped}, " <>
        "collapsed #{collapsed}#{refused_clause(refused)}"
    )
  end

  defp refused_clause(refused) do
    case Enum.filter(refused, fn {_kind, count} -> count > 0 end) do
      [] -> ""
      kinds -> ", refused " <> Enum.map_join(kinds, " ", fn {k, n} -> "#{k} #{n}" end)
    end
  end

  # A self-generated gap, bounded like the event path: at `max_queue` it coalesces
  # into a SINGLE pending gap (never grows) so a wire that never drains — e.g. a
  # sidecar streaming garbage without ever acking — cannot grow the buffer or heap
  # without bound. The per-incarnation `gap_boot_id` + monotonic seq never collide
  # with a sidecar `(boot_id, source_seq)` NOR with a prior incarnation's gaps.
  defp buffer_gap(%{overflow_pending?: true} = state, _reason), do: state

  defp buffer_gap(state, reason) do
    if length(state.buffer) >= state.max_queue do
      %{prepend_gap(state, "overflow") | overflow_pending?: true}
    else
      prepend_gap(state, reason)
    end
  end

  defp prepend_gap(state, reason) do
    now = System.system_time(:millisecond)

    gap = %{
      boot_id: state.gap_boot_id,
      source_seq: state.gap_seq,
      ts: now,
      type: "observer.gap",
      gap_reason: reason,
      gap_from_ts: now,
      gap_to_ts: now
    }

    %{state | buffer: [gap | state.buffer], gap_seq: state.gap_seq + 1}
  end

  defp gap_label({:missing_field, field}), do: "missing_#{field}"
  defp gap_label({:invalid_field, field}), do: "invalid_#{field}"
  defp gap_label({:unknown_frame_type, _type}), do: "unknown_type"
  defp gap_label({:bad_json, _message}), do: "bad_json"
  defp gap_label(other), do: inspect(other)

  # A boot-unique gap identity so a restart's `gap_seq` reset never collides with a
  # prior incarnation's (boot_id, source_seq): fixed prefix + wall time + a
  # BEAM-unique integer (distinct even for two restarts inside one millisecond).
  defp gap_boot_id do
    "#{@gap_boot_id}-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
  end

  # --- degrade + teardown -------------------------------------------------

  # Degrade is terminal: flush what survived (verified events + self-gaps, so the
  # discontinuity is recorded), stop the sidecar, and RELEASE the machine-wide
  # lock so a healthy daemon on this Mac can take over — a degraded holder that
  # kept heartbeating would brick capture machine-wide until an operator restart.
  defp degrade(state, reason) do
    Logger.error("computer_history capturer degraded: #{inspect(reason)}")
    flushed = flush(state)
    stop_driver(flushed)
    released = release_lock(flushed)
    %{released | mode: :degraded, degraded_reason: reason, sidecar: nil, protocol_ok?: false}
  end

  defp release_lock(%{lock_held?: true} = state) do
    SingletonLock.release(state.lock_path)
    %{state | lock_held?: false}
  end

  defp release_lock(state), do: state

  @impl true
  def terminate(_reason, state) do
    # Runs on supervisor `:shutdown` because `init/1` traps exits. Flush (partition
    # writes verified events + self-gaps, drops unverified), stop the sidecar, and
    # release the lock — the teardown the moduledoc promises on every exit path.
    _ = flush(state)
    stop_driver(state)
    if state.lock_held?, do: SingletonLock.release(state.lock_path)
    :ok
  end

  defp stop_driver(%{sidecar: %SidecarPort{} = sidecar}) do
    _ = send_frame(sidecar, "o-stop", %{"action" => "observe_stop"})
    SidecarPort.kill(sidecar)
  end

  defp stop_driver(_state), do: :ok

  defp schedule(message, delay_ms), do: Process.send_after(self(), message, delay_ms)
end
