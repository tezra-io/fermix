defmodule FermixCore.Harness.Run do
  @moduledoc """
  One temporary GenServer per local coding-harness run (design §6.1, §9.2).

  Started by `Harness.Manager` after admission with
  `%{row, plan, prompt, adapter, manager: pid}`; owns exactly one vendor CLI
  invocation from spawn to terminal. Its jobs, in order (all bounded, linear):

    1. Prepare the run's `artifacts_dir`, snapshot the prompt, transport it
       (inline argv vs. an oversized-`brief.md` pointer, `Harness.Prompt`),
       substitute the plan's `:prompt`/`:output_file` placeholders, build the
       isolated `env -i` argv (`Harness.Env`), open the event spool, and start
       the stream (`CommandRunner.start_stream/3`, `stream_to: self()`). The run
       row's `started_at` is recorded here; `run_start` telemetry is the
       Manager's single emission point, not this module's.
    2. For each streamed chunk: reassemble lines (`Harness.EventStream`), spool
       each event (bounded by `max_run_artifact_mb`; a breach stops spooling,
       sets `artifact_truncated`, and the run continues), harvest the vendor
       session id / usage / result text (`adapter.extract/1`), record throttled
       progress, and — under `progress: :milestones` — send throttled phase
       notices. A framing-budget breach cancels the host and terminalizes
       `failed/:protocol`.
    3. Watchdog clocks: a fixed first-event deadline and a config-driven
       inactivity deadline fire best-effort advisory notices (the run
       continues); the wall clock is owned by the host's own timer (single
       owner), whose `{:error, {:timeout, ms}}` terminal maps to `failed/:timeout`
       and routes through `Timeouts.expired/3`.
    4. On the terminal `{:command_host_exit, ...}`, finalize the event stream,
       classify the outcome (design §12.1), harvest result text/usage, and
       report the terminal state to the `:manager` pid — this module never
       writes the terminal ledger row (the Manager is the single terminal
       writer).

  The terminal report is delivered as
  `{:harness_report_terminal, run_id, status, fields}` to the `:manager` pid;
  advisory notices go through the injected `:notice_fn` seam (the Manager wires
  the real `Delivery.notice/2` later). `status` is one of `"completed"`,
  `"failed"`, `"cancelled"`, `"interrupted"`; `fields` always carries `reason`,
  `exit_code`, `usage`, `result_text`, `diagnostics_tail`, `framing_errors`,
  `vendor_session_id`, and `artifact_truncated`.
  """

  use GenServer

  require Logger

  alias FermixCore.CommandHost
  alias FermixCore.CommandRunner
  alias FermixCore.Harness.Artifacts
  alias FermixCore.Harness.Config
  alias FermixCore.Harness.Env
  alias FermixCore.Harness.EventStream
  alias FermixCore.Harness.Ledger
  alias FermixCore.Harness.Prompt
  alias FermixCore.Harness.Telemetry
  alias FermixCore.Timeouts

  @mb 1_048_576
  @result_text_max 65_536
  @diagnostics_ring 20
  @progress_throttle_ms 30_000
  @milestone_throttle_ms 60_000
  # The host's hard byte cap is a VM-memory backstop, NOT the artifact budget: it
  # must sit ABOVE the spool cap so a chatty run trips the spool truncate-and-
  # continue path (§6.5) — `artifact_truncated`, run continues — instead of being
  # killed. The host cap only fires for genuinely runaway output far past the
  # artifact budget.
  @host_output_headroom 4

  @doc "Starts a run from its `%{row, plan, prompt, adapter, manager}` (+ opts) args."
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(args) when is_map(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @spec child_spec(map()) :: Supervisor.child_spec()
  def child_spec(args) when is_map(args) do
    %{
      id: {__MODULE__, run_id_of(args)},
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc """
  Requests cancellation. `:owner` terminalizes `cancelled` (owner intent),
  `:interrupted` terminalizes `interrupted` (system caused).
  """
  @spec cancel(pid(), :owner | :interrupted) :: :ok
  def cancel(pid, reason) when is_pid(pid) and reason in [:owner, :interrupted] do
    GenServer.cast(pid, {:harness_cancel, reason})
  end

  @impl true
  def init(args) do
    {:ok, build_state(args), {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    case start_run(state) do
      {:ok, running} -> {:noreply, running}
      {:error, status, reason, aborted} -> abort(aborted, status, reason)
    end
  end

  @impl true
  def handle_info(
        {:command_host_data, ref, chunk},
        %{ref: ref, cancel_reason: nil, terminal_reported?: false} = state
      ) do
    CommandHost.ack(state.host, ref, 1)
    {:noreply, consume_chunk(state, chunk)}
  end

  def handle_info({:command_host_data, ref, _chunk}, %{ref: ref} = state) do
    # Draining after a self-initiated cancel or an already-reported terminal:
    # keep the host's ack window open, discard the payload.
    CommandHost.ack(state.host, ref, 1)
    {:noreply, state}
  end

  def handle_info(
        {:command_host_exit, ref, result},
        %{ref: ref, terminal_reported?: false} = state
      ) do
    {status, fields} = resolve_terminal(state, result)
    report_and_stop(state, status, fields)
  end

  def handle_info({:command_host_exit, _ref, _result}, state), do: {:noreply, state}

  def handle_info(
        :harness_first_event_timeout,
        %{first_event_seen?: false, cancel_reason: nil, terminal_reported?: false} = state
      ) do
    notice(state, first_event_text(state))
    {:noreply, %{state | first_event_timer: nil}}
  end

  def handle_info(:harness_first_event_timeout, state), do: {:noreply, state}

  def handle_info(
        :harness_inactivity_timeout,
        %{cancel_reason: nil, terminal_reported?: false} = state
      ) do
    notice(state, inactivity_text(state))
    {:noreply, %{state | inactivity_timer: nil}}
  end

  def handle_info(:harness_inactivity_timeout, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_cast(
        {:harness_cancel, reason},
        %{cancel_reason: nil, terminal_reported?: false} = state
      ) do
    if state.host, do: CommandHost.cancel(state.host, state.ref)
    {:noreply, %{state | cancel_reason: reason}}
  end

  def handle_cast({:harness_cancel, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: close_spool(state)

  # --- Startup ------------------------------------------------------------

  defp start_run(state) do
    case prepare_dir(state) do
      {:ok, dir} -> start_run_prepared(%{state | artifacts_dir: dir}, dir)
      {:error, status, reason} -> {:error, status, reason, state}
    end
  end

  defp start_run_prepared(state, dir) do
    with :ok <- record_started(state),
         {:ok, positional} <- transport_prompt(state, dir),
         {:ok, _snapshot} <- snapshot(dir, state.prompt),
         {:ok, argv, output_file} <- build_argv(state, dir, positional),
         {:ok, env} <- build_env(state, argv) do
      open_and_spawn(%{state | output_file: output_file}, dir, env)
    else
      {:error, status, reason} -> {:error, status, reason, state}
    end
  end

  defp open_and_spawn(state, dir, env) do
    case Artifacts.open_spool(dir) do
      {:ok, io} -> spawn_with_spool(%{state | spool_io: io}, env)
      {:error, reason} -> {:error, "failed", "artifact_spool:#{inspect(reason)}", state}
    end
  end

  defp spawn_with_spool(state, env) do
    case spawn_stream(state, env) do
      {:ok, stream} ->
        {:ok, arm_watchdogs(%{state | host: stream.host, ref: stream.ref})}

      {:error, status, reason} ->
        close_spool(state)
        {:error, status, reason, %{state | spool_io: nil}}
    end
  end

  defp prepare_dir(state) do
    case Artifacts.prepare(state.run_id, prepare_opts(state)) do
      {:ok, %{dir: dir}} -> {:ok, dir}
      {:error, reason} -> {:error, "failed", "artifact_prepare:#{inspect(reason)}"}
    end
  end

  defp prepare_opts(%{runs_root: nil}), do: []
  defp prepare_opts(%{runs_root: root}), do: [runs_root: root]

  defp transport_prompt(state, dir) do
    case Prompt.transport(state.prompt, dir, max_argv_bytes: Config.prompt_argv_max_kb() * 1024) do
      {:ok, {:argv, prompt}} -> {:ok, prompt}
      {:ok, {:brief, pointer, _path}} -> {:ok, pointer}
      {:error, reason} -> {:error, "failed", "prompt_transport:#{inspect(reason)}"}
    end
  end

  defp snapshot(dir, prompt) do
    case Artifacts.snapshot_prompt(dir, prompt) do
      {:ok, path} -> {:ok, path}
      {:error, reason} -> {:error, "failed", "prompt_snapshot:#{inspect(reason)}"}
    end
  end

  defp build_argv(state, dir, positional) do
    output_file = if Enum.member?(state.plan.argv, :output_file), do: Artifacts.result_path(dir)
    argv = Enum.map(state.plan.argv, &substitute(&1, positional, output_file))
    {:ok, argv, output_file}
  end

  defp substitute(:prompt, positional, _output_file), do: positional
  defp substitute(:output_file, _positional, output_file), do: output_file
  defp substitute(literal, _positional, _output_file) when is_binary(literal), do: literal

  defp build_env(state, argv) do
    with {:ok, allowed} <- build_allowed_env(state) do
      case Env.build(state.plan.binary, argv, allowed,
             home: home(state),
             path: path(state),
             user: user(state)
           ) do
        {:ok, built} -> {:ok, built}
        # A named reason, not an inspected tuple: this one is an operator-actionable
        # daemon-environment problem, and `env:{:missing_opt, :user}` in the failure
        # message would send the reader hunting through Fermix instead of their
        # service definition.
        {:error, {:missing_opt, :user}} -> {:error, "failed", "env_missing_user"}
        {:error, reason} -> {:error, "failed", "env:#{inspect(reason)}"}
      end
    end
  end

  defp build_allowed_env(state) do
    case resolve_env_names(state.plan.env_names) do
      {:ok, resolved} -> {:ok, Map.merge(resolved, config_env(state))}
      {:error, reason} -> {:error, "failed", "env_resolve:#{inspect(reason)}"}
    end
  end

  # An empty passthrough set (codex always; claude unless `bare`) never touches
  # Sandbox.Env; only a declared name is resolved. `Map.take/2` keeps just the
  # declared names, so everything `Sandbox.Env.default_env/0` contributes on its
  # own (HOME, PATH, USER, LANG, SHELL, TMPDIR, LC_*) is dropped here — the
  # reserved identity set is supplied separately by `Harness.Env`, which rejects
  # it in `allowed_env`.
  defp resolve_env_names([]), do: {:ok, %{}}

  defp resolve_env_names(names) do
    case FermixCore.Sandbox.Env.build(FermixCore.Sandbox.Config.current(), names) do
      {:ok, kv} -> {:ok, kv |> Map.new() |> Map.take(names)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp config_env(%{adapter: adapter}) do
    case adapter.vendor() do
      "codex" -> path_env("CODEX_HOME", Config.codex_home())
      "claude" -> path_env("CLAUDE_CONFIG_DIR", Config.claude_config_dir())
      _other -> %{}
    end
  end

  defp path_env(_name, nil), do: %{}
  defp path_env(name, value) when is_binary(value), do: %{name => value}

  defp spawn_stream(state, env) do
    opts = [
      cwd: state.plan.cwd,
      stream_to: self(),
      timeout_ms: state.wall_clock_ms,
      max_output_bytes: state.host_output_max_bytes,
      dynamic_supervisor: state.command_supervisor
    ]

    case CommandRunner.start_stream(env.executable, env.args, opts) do
      {:ok, stream} -> {:ok, stream}
      {:error, {:executable_not_found, _path}} -> {:error, "blocked", "cli_unavailable"}
      {:error, reason} -> {:error, "failed", "spawn:#{inspect(reason)}"}
    end
  end

  defp arm_watchdogs(state) do
    %{
      state
      | first_event_timer: send_after(:harness_first_event_timeout, state.first_event_ms),
        inactivity_timer: send_after(:harness_inactivity_timeout, state.inactivity_ms),
        spawned_at: mono()
    }
  end

  # --- Stream consumption -------------------------------------------------

  defp consume_chunk(state, chunk) do
    case EventStream.push(state.stream, chunk) do
      {:ok, emitted, stream} -> apply_emitted(%{state | stream: stream}, emitted)
      {:error, {:protocol, _detail}, stream} -> begin_protocol_cancel(%{state | stream: stream})
    end
  end

  defp apply_emitted(state, emitted), do: Enum.reduce(emitted, state, &apply_item/2)

  defp apply_item({:event, event}, state), do: apply_event(state, event)
  defp apply_item({:diagnostic, line}, state), do: push_diagnostic(state, line)

  defp apply_event(state, event) do
    fields = state.adapter.extract(event)
    phase = Map.get(fields, :phase)

    state
    |> spool_event(event)
    |> capture_fields(fields)
    |> mark_activity()
    |> throttled_progress(phase)
    |> maybe_milestone(phase)
  end

  defp capture_fields(state, fields) do
    state
    |> capture_session(Map.get(fields, :vendor_session_id))
    |> capture_usage(Map.get(fields, :usage))
    |> capture_result_text(Map.get(fields, :result_text))
  end

  defp capture_session(%{vendor_session_id: nil} = state, sid) when is_binary(sid) do
    record_session(state, sid)
    %{state | vendor_session_id: sid}
  end

  defp capture_session(state, _sid), do: state

  defp capture_usage(state, usage) when is_map(usage), do: %{state | usage: usage}
  defp capture_usage(state, _usage), do: state

  defp capture_result_text(state, text) when is_binary(text),
    do: %{state | streamed_result_text: text}

  defp capture_result_text(state, _text), do: state

  defp mark_activity(state) do
    state
    |> maybe_first_event()
    |> rearm_inactivity()
  end

  defp maybe_first_event(%{first_event_seen?: true} = state), do: state

  defp maybe_first_event(state) do
    cancel_timer(state.first_event_timer)
    now = DateTime.utc_now()
    record_progress(state, %{first_event_at: now, last_event_at: now})
    mark_running(state)
    %{state | first_event_seen?: true, first_event_timer: nil, last_progress_at: mono()}
  end

  defp rearm_inactivity(state) do
    cancel_timer(state.inactivity_timer)
    %{state | inactivity_timer: send_after(:harness_inactivity_timeout, state.inactivity_ms)}
  end

  defp throttled_progress(%{last_progress_at: nil} = state, _phase), do: state

  defp throttled_progress(state, phase) do
    now = mono()

    if now - state.last_progress_at >= state.progress_throttle_ms do
      record_progress(state, %{last_event_at: DateTime.utc_now()})
      Telemetry.progress(state.row, %{phase: phase})
      %{state | last_progress_at: now}
    else
      state
    end
  end

  defp maybe_milestone(%{progress: :milestones} = state, phase) when is_binary(phase) do
    now = mono()

    if state.last_milestone_at == nil or
         now - state.last_milestone_at >= state.milestone_throttle_ms do
      notice(state, milestone_text(state, phase))
      %{state | last_milestone_at: now}
    else
      state
    end
  end

  defp maybe_milestone(state, _phase), do: state

  defp push_diagnostic(state, line) do
    %{state | diagnostics: Enum.take([line | state.diagnostics], @diagnostics_ring)}
  end

  defp begin_protocol_cancel(state) do
    if state.host, do: CommandHost.cancel(state.host, state.ref)
    %{state | cancel_reason: :protocol}
  end

  # --- Spool --------------------------------------------------------------

  defp spool_event(%{spooling?: false} = state, _event), do: state

  defp spool_event(state, event) do
    line = Jason.encode!(event)
    size = byte_size(line) + 1

    if state.spool_bytes + size > state.spool_limit_bytes do
      truncate_spool(state)
    else
      write_spool(state, line, size)
    end
  end

  defp write_spool(state, line, size) do
    case Artifacts.append_spool(state.spool_io, line) do
      :ok -> %{state | spool_bytes: state.spool_bytes + size}
      {:error, reason} -> spool_write_failed(state, reason)
    end
  end

  defp truncate_spool(state) do
    Logger.info("harness run #{state.run_id} artifact spool capped at #{state.spool_bytes} bytes")
    %{state | spooling?: false, artifact_truncated: true}
  end

  defp spool_write_failed(state, reason) do
    Logger.warning("harness run #{state.run_id} spool write failed: #{inspect(reason)}")
    %{state | spooling?: false, artifact_truncated: true}
  end

  # --- Terminalization ----------------------------------------------------

  defp resolve_terminal(state, result) do
    summary = EventStream.finalize(state.stream, finalize_exit(result))
    {status, reason, extra} = classify_terminal(state, result, summary)
    fields = terminal_fields(state, summary) |> Map.put(:reason, reason) |> Map.merge(extra)
    persist_streamed_result(state, status, fields)
  end

  # Codex writes its authoritative result to the `-o` artifact; claude carries it
  # on the terminal `result` event, so nothing has written `result.txt` yet. It is
  # the single file the delivery, continuation, and get_coding_run paths all read,
  # so persist a completed stream-sourced result here. A write failure downgrades
  # the run to `failed/:artifact_write` (§12.1) — the result is unrecoverable.
  defp persist_streamed_result(%{output_file: path}, status, fields) when is_binary(path),
    do: {status, fields}

  defp persist_streamed_result(state, "completed", %{result_text: text} = fields)
       when is_binary(text) and text != "" do
    case Artifacts.write_result(state.artifacts_dir, text) do
      {:ok, _path} -> {"completed", fields}
      {:error, reason} -> {"failed", artifact_write_fields(state, fields, reason)}
    end
  end

  # A failed run's `result_text` is the vendor's own explanation — claude reports
  # "Not logged in · Please run /login" on its terminal `result` event — and it is
  # the only actionable diagnosis the run produces. Persist it so the durable
  # delivery retry (which sees the ledger row, never this process) can read it
  # back. Unlike a completed run the text is supplementary, not the deliverable,
  # so a write failure is logged and dropped: it must never overwrite the real
  # failure reason with `artifact_write`.
  defp persist_streamed_result(state, status, %{result_text: text} = fields)
       when is_binary(text) and text != "" do
    case Artifacts.write_result(state.artifacts_dir, text) do
      {:ok, _path} ->
        {status, fields}

      {:error, reason} ->
        Logger.warning(
          "harness run #{state.run_id} diagnosis artifact write failed: #{inspect(reason)}"
        )

        # Same marker `spool_write_failed/2` uses: the in-process continuation still
        # carries the text, but a retried delivery reads disk and will find nothing,
        # so the loss has to be visible on the row rather than only in the daemon log.
        {status, Map.put(fields, :artifact_truncated, true)}
    end
  end

  defp persist_streamed_result(_state, status, fields), do: {status, fields}

  defp artifact_write_fields(state, fields, reason) do
    Logger.warning("harness run #{state.run_id} result artifact write failed: #{inspect(reason)}")

    fields
    |> Map.put(:reason, "artifact_write")
    |> Map.put(:result_text, nil)
  end

  defp finalize_exit({:ok, %{exit: code}}), do: code
  defp finalize_exit(_result), do: 0

  defp terminal_fields(state, summary) do
    %{
      reason: nil,
      exit_code: nil,
      usage: state.usage,
      result_text: harvest_result_text(state),
      diagnostics_tail: summary.diagnostics_tail,
      framing_errors: summary.framing_errors,
      vendor_session_id: state.vendor_session_id,
      artifact_truncated: state.artifact_truncated
    }
  end

  # A self-initiated cancel decides the status independently of the host's late
  # result (a race where the process exited cleanly must still honor the intent).
  defp classify_terminal(%{cancel_reason: :protocol}, _result, _summary),
    do: {"failed", "protocol", %{}}

  defp classify_terminal(%{cancel_reason: :owner}, _result, _summary),
    do: {"cancelled", nil, %{}}

  defp classify_terminal(%{cancel_reason: :interrupted}, _result, _summary),
    do: {"interrupted", nil, %{}}

  defp classify_terminal(state, result, summary),
    do: classify_host_result(state, result, summary)

  # The host's VM-memory backstop hard-killed the process before its terminal
  # event (only genuinely runaway output reaches this, past the spool cap's
  # truncate-and-continue). No real exit code exists — reporting a fabricated one
  # would be dishonest.
  defp classify_host_result(_state, {:ok, %{truncated?: true}}, _summary),
    do: {"failed", "output_limit", %{}}

  defp classify_host_result(_state, {:ok, %{exit: code}}, summary),
    do: from_outcome(summary.outcome, code)

  defp classify_host_result(state, {:error, {:timeout, ms}}, _summary), do: on_timeout(state, ms)

  defp classify_host_result(_state, {:error, :cancelled}, _summary),
    do: {"cancelled", nil, %{}}

  defp classify_host_result(_state, {:error, {:subscriber_stalled, _bytes}}, _summary),
    do: {"failed", "subscriber_stalled", %{}}

  defp classify_host_result(_state, {:error, reason}, _summary),
    do: {"failed", "host_error:#{inspect(reason)}", %{}}

  defp from_outcome(:completed, code), do: {"completed", nil, %{exit_code: code}}

  defp from_outcome({:failed, {:exit, code}}, _code),
    do: {"failed", "exit_#{code}", %{exit_code: code}}

  defp from_outcome({:failed, :protocol}, code), do: {"failed", "protocol", %{exit_code: code}}

  defp on_timeout(state, ms) do
    Timeouts.expired(:harness_wall_clock, ms, %{session_id: session_id(state)})
    {"failed", "timeout", %{}}
  end

  # Codex writes its authoritative result to the `-o` artifact; claude carries it
  # on the terminal `result` event. There is no cross-source fallback: a codex
  # run whose file is absent (a non-completing run) reports nil.
  defp harvest_result_text(%{output_file: path}) when is_binary(path),
    do: bound_text(read_result_file(path))

  defp harvest_result_text(state), do: bound_text(state.streamed_result_text)

  defp read_result_file(path) do
    case File.read(path) do
      {:ok, ""} -> nil
      {:ok, content} -> content
      {:error, _absent} -> nil
    end
  end

  defp bound_text(nil), do: nil
  defp bound_text(text) when byte_size(text) <= @result_text_max, do: text
  defp bound_text(text), do: binary_part(text, 0, @result_text_max)

  defp abort(state, status, reason) do
    fields = %{
      reason: reason,
      exit_code: nil,
      usage: nil,
      result_text: nil,
      diagnostics_tail: Enum.reverse(state.diagnostics),
      framing_errors: 0,
      vendor_session_id: state.vendor_session_id,
      artifact_truncated: state.artifact_truncated
    }

    report_and_stop(state, status, fields)
  end

  defp report_and_stop(state, status, fields) do
    state = cancel_timers(state)
    close_spool(state)
    send(state.manager, {:harness_report_terminal, state.run_id, status, fields})
    {:stop, :normal, %{state | terminal_reported?: true, spool_io: nil}}
  end

  # --- Notices (best-effort, non-blocking, never retried) ------------------

  # Isolated in an unlinked process so a slow or raising notice sink (real
  # delivery does network I/O) can neither block nor crash the run.
  defp notice(state, text) do
    fun = state.notice_fn
    spawn(fn -> fun.(text) end)
    state
  end

  defp first_event_text(state) do
    "[run #{state.run_id}] no output yet — likely an auth or config problem." <>
      diag_suffix(state)
  end

  defp inactivity_text(state) do
    "[run #{state.run_id}] no activity for a while; the run is still going." <> diag_suffix(state)
  end

  defp milestone_text(state, phase), do: "[run #{state.run_id}] #{phase}"

  defp diag_suffix(state) do
    case Enum.reverse(state.diagnostics) do
      [] -> ""
      lines -> "\n" <> Enum.join(lines, "\n")
    end
  end

  # --- Ledger (best-effort liveness metadata) ------------------------------

  defp record_started(state) do
    ledger_write(state, fn ->
      Ledger.record_progress(state.run_id, %{started_at: DateTime.utc_now()}, ledger_opts(state))
    end)

    :ok
  end

  defp record_session(state, sid) do
    ledger_write(state, fn -> Ledger.record_session(state.run_id, sid, ledger_opts(state)) end)
  end

  # Best-effort `starting` → `running` flip on the first event, so `get_coding_run`
  # and `list_coding_runs` report an actively-streaming run honestly (the terminal
  # writer stays the single terminal authority).
  defp mark_running(state) do
    ledger_write(state, fn -> Ledger.mark_running(state.run_id, ledger_opts(state)) end)
  end

  defp record_progress(state, fields) do
    ledger_write(state, fn -> Ledger.record_progress(state.run_id, fields, ledger_opts(state)) end)
  end

  defp ledger_write(state, fun) do
    case fun.() do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        Logger.warning("harness run #{state.run_id} ledger write failed: #{inspect(reason)}")
        :ok
    end
  end

  defp ledger_opts(%{repo: nil}), do: []
  defp ledger_opts(%{repo: repo}), do: [server: repo]

  # --- Resource + timer helpers -------------------------------------------

  defp close_spool(%{spool_io: nil}), do: :ok

  defp close_spool(%{spool_io: io, run_id: id}) do
    case Artifacts.close_spool(io) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("harness run #{id} spool close failed: #{inspect(reason)}")
    end
  end

  defp cancel_timers(state) do
    cancel_timer(state.first_event_timer)
    cancel_timer(state.inactivity_timer)
    %{state | first_event_timer: nil, inactivity_timer: nil}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp send_after(message, ms), do: Process.send_after(self(), message, ms)

  defp mono, do: System.monotonic_time(:millisecond)

  defp session_id(state), do: "harness_" <> state.run_id

  defp home(state), do: state.home || System.get_env("HOME") || System.user_home!()
  defp path(state), do: state.path || System.get_env("PATH")

  # Identity, resolved the same way as HOME/PATH: from the daemon's own
  # environment, never from tool args or sandbox config. A daemon with no USER
  # cannot authenticate a keychain-backed vendor, so `Harness.Env` refuses the run
  # with `{:missing_opt, :user}` rather than spawning a CLI that will fail with an
  # opaque "Not logged in".
  defp user(state), do: state.user || System.get_env("USER")

  # --- State construction -------------------------------------------------

  defp build_state(args) do
    row = Map.fetch!(args, :row)
    adapter = Map.fetch!(args, :adapter)
    run_id = Map.fetch!(row, :id)

    %{
      run_id: run_id,
      row: row,
      plan: Map.fetch!(args, :plan),
      prompt: Map.fetch!(args, :prompt),
      adapter: adapter,
      manager: Map.fetch!(args, :manager),
      notice_fn: Map.get(args, :notice_fn, fn _text -> :ok end),
      progress: progress_mode(Map.get(args, :progress, :quiet)),
      repo: Map.get(args, :repo),
      runs_root: Map.get(args, :runs_root),
      home: Map.get(args, :home),
      path: Map.get(args, :path),
      user: Map.get(args, :user),
      command_supervisor: Map.get(args, :command_supervisor, FermixCore.CommandHost.Supervisor),
      wall_clock_ms: Map.get(args, :wall_clock_ms, timeout_minutes(args) * 60_000),
      host_output_max_bytes:
        Map.get(
          args,
          :max_output_bytes,
          Config.max_run_artifact_mb() * @mb * @host_output_headroom
        ),
      spool_limit_bytes: Map.get(args, :spool_limit_bytes, Config.max_run_artifact_mb() * @mb),
      first_event_ms: Map.get(args, :first_event_ms, Timeouts.harness_first_event()),
      inactivity_ms: Map.get(args, :inactivity_ms, Timeouts.harness_inactivity()),
      progress_throttle_ms: Map.get(args, :progress_throttle_ms, @progress_throttle_ms),
      milestone_throttle_ms: Map.get(args, :milestone_throttle_ms, @milestone_throttle_ms),
      stream: build_stream(args, adapter),
      artifacts_dir: nil,
      output_file: nil,
      host: nil,
      ref: nil,
      spool_io: nil,
      spooling?: true,
      spool_bytes: 0,
      vendor_session_id: nil,
      streamed_result_text: nil,
      usage: nil,
      first_event_seen?: false,
      artifact_truncated: false,
      diagnostics: [],
      first_event_timer: nil,
      inactivity_timer: nil,
      last_progress_at: nil,
      last_milestone_at: nil,
      spawned_at: nil,
      cancel_reason: nil,
      terminal_reported?: false
    }
  end

  defp build_stream(args, adapter) do
    EventStream.new(
      terminal?: fn event -> adapter.terminal?(event) end,
      max_event_bytes: Map.get(args, :max_event_bytes, Config.max_event_bytes()),
      max_framing_errors: Map.get(args, :max_framing_errors, Config.max_framing_errors())
    )
  end

  defp timeout_minutes(args),
    do: Map.get(args, :timeout_minutes, Config.default_timeout_minutes())

  defp progress_mode(:milestones), do: :milestones
  defp progress_mode("milestones"), do: :milestones
  defp progress_mode(_quiet), do: :quiet

  defp run_id_of(args) do
    args |> Map.get(:row, %{}) |> Map.get(:id)
  end
end
