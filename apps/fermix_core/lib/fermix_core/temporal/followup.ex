defmodule FermixCore.Temporal.Followup do
  @moduledoc """
  One post-delivery follow-up run: one reminder, one model turn, at most one
  extra message (M30 §22.5, §22.6).

  The reminder is the promise and the follow-up is the flourish. This process
  starts only after `DeliveryWorker` has durably settled a row `delivered`, so
  nothing it does — a slow model, a refused send, a crash — can cost the owner
  the reminder itself. Everything here serves that asymmetry: no persisted run
  row, no retry, no boot sweep, no durable outcome. The trace is the record on
  failure; the memory note the run writes is the record on success.

  `restart: :temporary`, and `init/1` performs no work at all — it stores its
  args and defers to `handle_continue/2` — so the supervisor's `start_child`
  returns immediately and a model-long run can never hold the requesting
  delivery worker.

  The run is deliberately indistinguishable, to `Temporal.Access`, from an
  operator-created scheduled run: `source_trust: :operator` with **no**
  `computer_use_origin` key. That lands it precisely in the §12.1 read
  carve-out — `event_list` reads, every mutating event tool refuses at both
  advertisement and execution — so the follow-up structurally cannot edit the
  event it is talking about.

  Its `conversation_key` is the delivery-target triple, which is load-bearing
  rather than cosmetic: it is the only shape `Memory.Store` accepts (an
  atom-headed synthetic key raises out of both memory tools), and it scopes the
  run's memory into the very conversation where the reminder landed — so the
  note it writes is what the main agent recalls when the owner replies there.

  Outcomes (§22.8), all closed through `FollowupTelemetry`:

    * `sent` — one clamped message through `Temporal.Delivery.attempt/4`;
    * `declined` — the model answered exactly `[SILENT]`; a success, recorded
      as itself;
    * `empty` — an empty final text WITHOUT the sentinel, which is the absence
      of a decision rather than a decision, so nothing is sent;
    * `delivery_failed` — the one send failed; no second attempt, no ladder;
    * `timeout` / `error` — the watchdog killed the loop, or the loop failed.
  """

  use GenServer, restart: :temporary

  require Logger

  alias FermixCore.AgentLoop
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Memory.Repo
  alias FermixCore.Prompt.CurrentDate
  alias FermixCore.Providers.Selection
  alias FermixCore.Temporal.Delivery
  alias FermixCore.Temporal.FollowupTelemetry
  alias FermixCore.Temporal.Registry, as: TemporalRegistry
  alias FermixCore.Temporal.Renderer
  alias FermixCore.Temporal.Telemetry, as: TemporalTelemetry

  @max_iterations 6

  # Wall clock only: at six iterations and three tools there is no long tool
  # phase for an inactivity timer to protect.
  @watchdog_ms 120_000

  # Fixed, never derived from `valid_until` — that boundary belongs to the
  # reminder's own attempt and is typically already past by follow-up time.
  @send_timeout_ms 60_000

  # The jobs rail's sentinel convention (`Jobs.Delivery.silent?/2`), matched
  # locally: this is the temporal rail's only use of it, and one exact compare
  # is not worth a dependency on the jobs modules.
  @silent_sentinel "[SILENT]"

  # No channel tools (the rail sends the one message itself), no web, no
  # subagents, no harness — with exactly the policy classes those three need
  # (`memory_store` is `:read_write`).
  @allowed_tools ["event_list", "memory_recall", "memory_store"]
  @policy [:read_only, :read_write]

  @type args :: %{
          required(:reminder) => map(),
          required(:delivered_text) => String.t(),
          required(:repo) => GenServer.server(),
          required(:delivery_opts) => keyword(),
          optional(:capability_registry) => GenServer.server(),
          optional(:adapter) => module() | nil,
          optional(:adapter_opts) => keyword(),
          optional(:timeout_ms) => pos_integer()
        }

  @spec start_link(args()) :: GenServer.on_start()
  def start_link(
        %{reminder: reminder, delivered_text: text, repo: repo, delivery_opts: opts} = args
      )
      when is_map(reminder) and is_binary(text) and is_list(opts) and not is_nil(repo) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init(args), do: {:ok, build_state(args), {:continue, :run}}

  @impl true
  def handle_continue(:run, state) do
    run(state)
    {:stop, :normal, state}
  end

  defp build_state(args) do
    %{
      reminder: args.reminder,
      delivered_text: args.delivered_text,
      repo: args.repo,
      delivery_opts: args.delivery_opts,
      capability_registry: Map.get(args, :capability_registry, CapabilityRegistry),
      adapter: Map.get(args, :adapter),
      adapter_opts: Map.get(args, :adapter_opts, []),
      # The wall-clock seam, like the delivery worker's `now_fn`: production has
      # one value and tests need a short one.
      timeout_ms: Map.get(args, :timeout_ms, @watchdog_ms),
      run: FollowupTelemetry.correlation(args.reminder),
      event: nil
    }
  end

  # --- the run -------------------------------------------------------------

  # A cancel or an un-flagging between settlement and here suppresses the
  # follow-up for free: the event is re-read, never assumed from the payload
  # snapshot the reminder was materialized with.
  defp run(state) do
    case load_event(state) do
      {:ok, event} -> execute(%{state | event: event})
      {:skip, reason} -> skip(state, reason)
    end
  end

  defp load_event(state) do
    case Repo.get_temporal_event(state.reminder.event_id, server: state.repo) do
      {:ok, %{status: "active", followup: true} = event} -> {:ok, event}
      {:ok, %{status: "active"}} -> {:skip, :event_unflagged}
      {:ok, _inactive} -> {:skip, :event_inactive}
      {:error, reason} -> {:skip, reason}
    end
  end

  defp execute(state) do
    FollowupTelemetry.run_start(state.run, state.timeout_ms)
    started = System.monotonic_time(:millisecond)

    state
    |> run_loop()
    |> settle(state, started)
  end

  defp run_loop(state) do
    case routing(state) do
      {:ok, routing} -> supervise_loop(loop_opts(state, routing), state.timeout_ms)
      {:error, reason} -> {:error, {:route_selection_failed, reason}}
    end
  end

  # An injected adapter drives the loop directly (the jobs-runner test seam); a
  # real run follows the main selection chain — no pin, no override, no knob.
  defp routing(%{adapter: adapter, adapter_opts: adapter_opts})
       when is_atom(adapter) and not is_nil(adapter) do
    {:ok, [adapter: adapter, adapter_opts: adapter_opts]}
  end

  defp routing(_state) do
    case Selection.ordered_routes() do
      {:ok, routes} -> {:ok, [routes: routes]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp loop_opts(state, routing) do
    [
      messages: messages(state),
      context: loop_context(state),
      capability_registry: state.capability_registry,
      allowed_tools: @allowed_tools,
      policy: @policy,
      trust: :operator,
      max_iterations: @max_iterations
    ] ++ routing
  end

  @doc false
  # Public so the whole-family access invariant can assert against the context
  # this run ACTUALLY builds rather than a copy of it.
  @spec loop_context(map()) :: map()
  def loop_context(%{reminder: row, event: event} = state) when is_map(event) do
    run = FollowupTelemetry.correlation(row)

    %{
      session_id: run.session_id,
      agent_name: run.agent,
      conversation_key:
        {row.delivery_platform, row.delivery_destination, row.delivery_thread_scope},
      source_trust: :operator,
      route_transient_retry: false,
      capability_registry: state.capability_registry,
      memory_repo: state.repo,
      memory_agent_id: Map.get(event, :agent_id) || MemoryConfig.agent_id(),
      memory_owner_id: MemoryConfig.owner_id()
    }
  end

  # --- the watchdog --------------------------------------------------------

  defp supervise_loop(opts, timeout_ms) do
    parent = self()
    tag = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn -> send(parent, {:followup_loop, tag, AgentLoop.run(opts)}) end)

    await_loop(pid, monitor_ref, tag, timeout_ms)
  end

  defp await_loop(pid, monitor_ref, tag, timeout_ms) do
    receive do
      {:followup_loop, ^tag, {:ok, %{response: response}}} ->
        Process.demonitor(monitor_ref, [:flush])
        {:ok, response}

      {:followup_loop, ^tag, {:error, reason}} ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, reason}

      {:DOWN, ^monitor_ref, :process, _pid, reason} ->
        {:error, {:agent_loop_exit, reason}}
    after
      timeout_ms -> kill_loop(pid, monitor_ref, timeout_ms)
    end
  end

  defp kill_loop(pid, monitor_ref, timeout_ms) do
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor_ref, :process, _pid, _reason} -> :ok
    after
      100 -> :ok
    end

    {:timeout, "wall-clock timeout after #{timeout_ms}ms"}
  end

  # --- outcomes ------------------------------------------------------------

  defp settle({:ok, text}, state, started) do
    cond do
      silent?(text) -> close(state, "declined", nil, started)
      blank?(text) -> close_empty(state, started)
      true -> deliver(state, Renderer.clamp(text), started)
    end
  end

  defp settle({:timeout, reason}, state, started) do
    Logger.warning("Reminder #{state.reminder.id} follow-up timed out: #{reason}")
    FollowupTelemetry.run_error(state.run, "timeout", elapsed(started), reason)
  end

  defp settle({:error, reason}, state, started) do
    Logger.warning("Reminder #{state.reminder.id} follow-up failed: #{inspect(reason)}")
    FollowupTelemetry.run_error(state.run, "error", elapsed(started), inspect(reason))
  end

  # Exactly one attempt: the §11.4 retry ladder is the reminder's, never the
  # flourish's.
  defp deliver(state, text, started) do
    case Delivery.attempt(state.reminder, text, @send_timeout_ms, state.delivery_opts) do
      :ok -> close(state, "sent", text, started)
      {:error, reason} -> close_delivery_failure(state, reason, started)
    end
  end

  defp close(state, outcome, sent_text, started) do
    FollowupTelemetry.run_complete(state.run, outcome, elapsed(started), sent_text)
  end

  # An empty final text without the sentinel is the absence of a protocol
  # marker, not a decision to stay quiet — so it is traced as the anomaly it is
  # and nothing is sent.
  defp close_empty(state, started) do
    Logger.warning(
      "Reminder #{state.reminder.id} follow-up produced an empty message with no [SILENT] " <>
        "sentinel; sending nothing"
    )

    close(state, "empty", nil, started)
  end

  defp close_delivery_failure(state, reason, started) do
    Logger.warning(
      "Reminder #{state.reminder.id} follow-up could not be sent: #{Delivery.error_text(reason)}"
    )

    close(state, "delivery_failed", nil, started)
  end

  defp skip(state, reason) do
    Logger.info("Reminder #{state.reminder.id} follow-up skipped: #{inspect(reason)}")

    TemporalTelemetry.emit(
      :followup_skipped,
      Keyword.put(TemporalTelemetry.reminder(state.reminder), :result, {:error, reason})
    )
  end

  defp silent?(text), do: String.trim(text) == @silent_sentinel
  defp blank?(text), do: String.trim(text) == ""
  defp elapsed(started), do: System.monotonic_time(:millisecond) - started

  # --- the prompt ----------------------------------------------------------

  defp messages(state) do
    [
      %{role: "system", content: guidance()},
      %{role: "system", content: CurrentDate.note()},
      %{role: "user", content: occasion(state)}
    ]
  end

  defp occasion(state) do
    """
    The reminder Fermix has just delivered to the owner, verbatim:

    #{state.delivered_text}

    The stored event it came from:

    #{Jason.encode!(TemporalRegistry.event_view(state.event), pretty: true)}
    """
    |> String.trim()
  end

  defp guidance do
    """
    You are a Fermix follow-up turn.

    Fermix has already delivered the reminder below to the owner, word for word,
    on their own channel. That message is sent. You are not repeating it,
    rewording it, or announcing the schedule again — the owner has just read it.

    Decide whether one short message from you would genuinely help the owner
    right now, and send nothing when it would not. Add only what the reminder
    did not already say: an offer to help act on it, something you actually
    remember about the person or the occasion, or one focused question. Recall
    memory before assuming you know nothing relevant.

    If you have nothing worth adding, reply with exactly #{@silent_sentinel} and
    nothing else. Declining is a good answer, and the right one whenever a
    message would only restate what the owner already has.

    Otherwise reply with the message itself: at most one short message,
    addressed to the owner, no preamble and no sign-off. Fermix delivers your
    final reply to the same conversation the reminder went to, so never try to
    send it yourself.

    When you do send a message, store a one-line memory note of what you offered
    or asked, so the next turn in that conversation knows it happened.

    You can read stored events but cannot change them; a change is the owner's
    to ask for in their own words.
    """
    |> String.trim()
  end
end
