defmodule FermixCore.OpenLoops.CheckIn do
  @moduledoc """
  One rung 2 check-in run: one due loop, one isolated model run, at most one
  message (MILESTONE_78 §04 stage 3, §07, §11, §18).

  The scheduler claims the row and starts this process; the run decides, and
  only code acts on the decision. `restart: :temporary`, and `init/1` does no
  work (it defers to `handle_continue/2`), so the supervisor's `start_child`
  returns at once and a model-long run never holds the scheduler.

  The run sees IDENTITY.md and SOUL.md (so it sounds like Fermix, never
  FERMIX.md), the §07 check-in guidance, the current date, and the loop. It may
  call exactly `memory_recall`, `open_loop_list` and `open_loop_respond`, under
  a six-iteration cap and a wall-clock watchdog. Its loop context carries
  `open_loop_checkin: %{id, reply_to, ref}`, the one key that admits
  `open_loop_respond` and refuses the main agent's open-loop tools; the tool
  sends `{:open_loop_respond, ref, decision}` here. The first well-formed
  decision is kept and every later one ignored; when the loop ends, by its own
  final text, the iteration cap or the watchdog, the decision held is the one
  acted on.

  Outcomes, each written through `Repo.finalize_open_loop_checkin/4`, a
  compare-and-set on the claim this run holds:

    * `spoke`: the owner's daily budget is spent on this run's claim
      (`Repo.spend_open_loop_budget/5`, which refuses a day another loop of
      the owner's already spent), then one `ChannelSend` attempt to the
      snapshotted target; on a confirmed send the message is written to that
      conversation's history and THEN the touch ledger advances, so a history
      row without a ledger advance is the visible sign of a crash between the
      two, never the reverse;
    * `silent`: the slot advances, nothing is sent;
    * `closed`: the owner already reported it settled; the loop closes as
      `reported_elsewhere`;
    * `empty`: no decision at all, the absence of a protocol marker rather
      than a decision, traced as the anomaly it is; the slot advances;
    * `delivery_failed`: the one send failed; the touches stay, the loop
      re-arms, and the day's budget stays spent;
    * `timeout` / `error`: the watchdog or a loop failure with no decision,
      or a spend refused because the owner's day was already spent (a fault of
      the scheduler above, which holds one run per owner); the loop re-arms
      (§11).

  A finalising write that finds the claim gone means the owner settled the
  loop meanwhile: the run traces `skipped closed_meanwhile` and sends nothing.
  A spoken decision re-reads the row before it sends for the same reason.
  """

  use GenServer, restart: :temporary

  require Logger

  alias FermixCore.AgentLoop
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Clock
  alias FermixCore.Delivery.ChannelSend
  alias FermixCore.Delivery.Error
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo
  alias FermixCore.OpenLoops.ActiveHours
  alias FermixCore.OpenLoops.Defaults
  alias FermixCore.OpenLoops.Lifecycle
  alias FermixCore.OpenLoops.Registry
  alias FermixCore.OpenLoops.Telemetry
  alias FermixCore.Prompt.BootstrapLoader
  alias FermixCore.Prompt.CurrentDate
  alias FermixCore.Providers.Selection
  alias FermixCore.Temporal.Delivery

  # No channel tools (Fermix sends the one message itself), no event or job
  # mutation, no browsing, no delegation, no `memory_store` (§08).
  @allowed_tools ["memory_recall", "open_loop_list", "open_loop_respond"]
  @policy [:read_only, :read_write]

  # How long a killed loop's `:DOWN` is awaited before the watchdog returns.
  @kill_grace_ms 100

  @type decision :: %{
          decision: :speak | :silent | :close,
          message: String.t() | nil,
          reason: String.t() | nil
        }

  @type args :: %{
          required(:loop) => map(),
          required(:claimed_at) => DateTime.t(),
          required(:touch) => pos_integer(),
          required(:rung) => 2,
          required(:active_hours) => ActiveHours.hours(),
          required(:repo) => GenServer.server(),
          required(:delivery_opts) => keyword(),
          optional(:capability_registry) => GenServer.server(),
          optional(:adapter) => module() | nil,
          optional(:adapter_opts) => keyword(),
          optional(:timeout_ms) => pos_integer(),
          optional(:conversation_store) => GenServer.server(),
          optional(:now_fn) => (-> DateTime.t()),
          optional(:bootstrap_dir) => String.t()
        }

  @spec start_link(args()) :: GenServer.on_start()
  def start_link(
        %{
          loop: %{id: id, state: "due", touches: touches},
          claimed_at: %DateTime{},
          touch: touch,
          rung: 2,
          active_hours: %{start: %Time{}, finish: %Time{}},
          repo: repo,
          delivery_opts: delivery_opts
        } = args
      )
      when is_binary(id) and touch == touches + 1 and is_list(delivery_opts) and
             not is_nil(repo) do
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
      loop: args.loop,
      claimed_at: args.claimed_at,
      touch: args.touch,
      rung: args.rung,
      active_hours: args.active_hours,
      repo: args.repo,
      delivery_opts: args.delivery_opts,
      capability_registry: Map.get(args, :capability_registry, CapabilityRegistry),
      adapter: Map.get(args, :adapter),
      adapter_opts: Map.get(args, :adapter_opts, []),
      # The wall-clock seam, as the follow-up's: production has one value and
      # tests need a short one.
      timeout_ms: Map.get(args, :timeout_ms, Defaults.checkin_watchdog_ms()),
      conversation_store: Map.get(args, :conversation_store, ConversationStore),
      now_fn: Map.get(args, :now_fn, &DateTime.utc_now/0),
      bootstrap_dir: Map.get(args, :bootstrap_dir),
      run: Telemetry.correlation(args.loop.id, args.touch),
      ref: make_ref()
    }
  end

  # --- the run ---------------------------------------------------------------

  defp run(state) do
    Telemetry.run_start(
      state.run,
      state.rung,
      state.loop.horizon_class,
      ActiveHours.label(state.active_hours),
      state.timeout_ms
    )

    started = System.monotonic_time(:millisecond)
    state |> run_loop() |> conclude(state, started)
  end

  defp run_loop(state) do
    with {:ok, messages} <- messages(state),
         {:ok, routing} <- routing(state) do
      supervise_loop(loop_opts(state, messages, routing), state)
    else
      {:error, reason} -> {{:error, reason}, nil}
    end
  end

  # An injected adapter drives the loop directly (the follow-up's test seam); a
  # real run follows the main selection chain: no pin, no override, no knob.
  defp routing(%{adapter: adapter, adapter_opts: adapter_opts})
       when is_atom(adapter) and not is_nil(adapter) do
    {:ok, [adapter: adapter, adapter_opts: adapter_opts]}
  end

  defp routing(_state) do
    case Selection.ordered_routes() do
      {:ok, routes} -> {:ok, [routes: routes]}
      {:error, reason} -> {:error, {:route_selection_failed, reason}}
    end
  end

  defp loop_opts(state, messages, routing) do
    [
      messages: messages,
      context: loop_context(state),
      capability_registry: state.capability_registry,
      allowed_tools: @allowed_tools,
      policy: @policy,
      trust: :operator,
      max_iterations: Defaults.checkin_max_iterations()
    ] ++ routing
  end

  @doc false
  # Public so the whole-family trust invariant can assert against the context
  # this run ACTUALLY builds. Called inside the check-in process, so `reply_to`
  # is that process.
  @spec loop_context(map()) :: map()
  def loop_context(%{loop: loop, touch: touch, repo: repo, ref: ref} = state)
      when is_map(loop) and is_reference(ref) do
    run = Telemetry.correlation(loop.id, touch)

    %{
      session_id: run.session_id,
      agent_name: run.agent,
      conversation_key: conversation_key(loop),
      source_trust: :operator,
      route_transient_retry: false,
      capability_registry: Map.get(state, :capability_registry, CapabilityRegistry),
      memory_repo: repo,
      memory_agent_id: loop.agent_id,
      memory_owner_id: loop.owner_id,
      open_loop_checkin: %{id: loop.id, reply_to: self(), ref: ref}
    }
  end

  # The delivery-target triple in the shape every turn keys its conversation
  # by (`Agents.ConversationKey`): the stored `"root"` is the `:root` scope, so
  # the history row lands in the very conversation the owner answers in.
  defp conversation_key(loop) do
    {loop.delivery_platform, loop.delivery_destination, thread_scope(loop.delivery_thread_scope)}
  end

  defp thread_scope("root"), do: :root
  defp thread_scope(scope) when is_binary(scope) and scope != "", do: scope

  # --- the watchdog ------------------------------------------------------------

  defp supervise_loop(opts, state) do
    parent = self()
    tag = make_ref()

    {pid, monitor} =
      spawn_monitor(fn -> send(parent, {:open_loop_checkin_loop, tag, AgentLoop.run(opts)}) end)

    watch = %{
      pid: pid,
      monitor: monitor,
      tag: tag,
      ref: state.ref,
      timeout_ms: state.timeout_ms,
      deadline: System.monotonic_time(:millisecond) + state.timeout_ms
    }

    await_loop(watch, nil)
  end

  # Bounded by the deadline: every pass recomputes what is left of the one
  # wall-clock budget, so decisions arriving cannot extend the run.
  defp await_loop(watch, held) do
    %{ref: ref, tag: tag, monitor: monitor} = watch
    remaining = max(watch.deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:open_loop_respond, ^ref, reply} ->
        await_loop(watch, keep_first(held, reply))

      {:open_loop_checkin_loop, ^tag, result} ->
        Process.demonitor(monitor, [:flush])
        {loop_ending(result), drain_decisions(ref, held)}

      {:DOWN, ^monitor, :process, _pid, reason} ->
        {{:error, {:agent_loop_exit, reason}}, drain_decisions(ref, held)}
    after
      remaining -> {kill_loop(watch), drain_decisions(ref, held)}
    end
  end

  defp loop_ending({:ok, _result}), do: :finished
  defp loop_ending({:error, reason}), do: {:error, reason}

  defp kill_loop(%{pid: pid, monitor: monitor, timeout_ms: timeout_ms}) do
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
    after
      @kill_grace_ms -> :ok
    end

    {:timeout, "wall-clock timeout after #{timeout_ms}ms"}
  end

  # A decision the tool sent just before the loop ended is still the run's: the
  # mailbox holds a finite number of them, read without waiting.
  defp drain_decisions(ref, held) do
    receive do
      {:open_loop_respond, ^ref, reply} -> drain_decisions(ref, keep_first(held, reply))
    after
      0 -> held
    end
  end

  defp keep_first(nil, reply) do
    case decision(reply) do
      {:ok, decision} ->
        decision

      :error ->
        Logger.error("Open-loop check-in ignored a malformed decision: #{inspect(reply)}")
        nil
    end
  end

  defp keep_first(held, _later) do
    Logger.info("Open-loop check-in kept its first decision and ignored a later one")
    held
  end

  defp decision(%{decision: :speak, message: message} = reply) when is_binary(message) do
    if speakable?(message), do: {:ok, normalize_decision(reply)}, else: :error
  end

  defp decision(%{decision: choice} = reply) when choice in [:silent, :close],
    do: {:ok, normalize_decision(reply)}

  defp decision(_reply), do: :error

  defp normalize_decision(reply) do
    %{
      decision: reply.decision,
      message: Map.get(reply, :message),
      reason: Map.get(reply, :reason)
    }
  end

  defp speakable?(message) do
    String.trim(message) != "" and byte_size(message) <= Defaults.message_max_bytes()
  end

  # --- outcomes ------------------------------------------------------------------

  defp conclude({_ending, %{decision: :speak, message: text}}, state, started),
    do: speak(state, text, started)

  defp conclude({_ending, %{decision: :silent}}, state, started),
    do: quiet(state, "silent", started)

  defp conclude({_ending, %{decision: :close}}, state, started), do: close(state, started)

  defp conclude({:finished, nil}, state, started) do
    Logger.warning(
      "Open loop #{state.loop.id} check-in ended without an open_loop_respond decision; " <>
        "sending nothing"
    )

    quiet(state, "empty", started)
  end

  defp conclude({{:timeout, reason}, nil}, state, started),
    do: failed(state, "timeout", reason, started)

  defp conclude({{:error, reason}, nil}, state, started),
    do: failed(state, "error", reason, started)

  defp quiet(state, outcome, started) do
    finalize(state, Lifecycle.after_outcome(state.loop, outcome, now(state), state.active_hours))
    Telemetry.run_complete(state.run, outcome, elapsed(started))
  end

  defp close(state, started) do
    finalize(state, Lifecycle.after_outcome(state.loop, "closed", now(state), state.active_hours))
    Telemetry.run_complete(state.run, "closed", elapsed(started))
  end

  defp failed(state, status, reason, started) do
    Logger.warning("Open loop #{state.loop.id} check-in #{status}: #{inspect(reason)}")
    finalize(state, Lifecycle.after_outcome(state.loop, status, now(state), state.active_hours))
    Telemetry.run_error(state.run, status, elapsed(started), reason)
  end

  # A spoken decision is acted on only while this run still holds the loop: a
  # loop the owner settled during the run is reported, never sent to. The
  # withheld message closes the run as `silent`, since nothing reached the
  # owner, beside the `closed_meanwhile` skip that says why.
  defp speak(state, text, started) do
    case still_claimed(state) do
      :ok -> spend_then_deliver(state, text, started)
      :closed_meanwhile -> withheld(state, started)
      {:error, reason} -> failed(state, "error", {:claim_check_failed, reason}, started)
    end
  end

  # The owner's one unprompted check-in a day is spent BEFORE the send, on the
  # claim this run holds, so a message that got out is always counted: a send
  # that then fails, a crash before the outcome is written, or an answer that
  # lands during the send all leave the day spent. That is the safe direction:
  # a lost message costs the owner a quiet day, never a second message.
  #
  # The single writer refuses a day already spent by another loop of the
  # owner's. The scheduler's one run per owner should have held this run back,
  # so that refusal is a fault: nothing is sent, the run closes as an error and
  # the loop re-arms at the next active-hours start, which the spent day holds
  # to tomorrow.
  defp spend_then_deliver(state, text, started) do
    case spend_budget(state) do
      :ok -> deliver(state, text, started)
      :closed_meanwhile -> withheld(state, started)
      {:error, :budget_spent} -> failed(state, "error", :budget_spent, started)
      {:error, reason} -> failed(state, "error", {:budget_spend_failed, reason}, started)
    end
  end

  defp withheld(state, started) do
    closed_meanwhile(state)
    Telemetry.run_complete(state.run, "silent", elapsed(started))
  end

  defp spend_budget(%{loop: loop} = state) do
    now = now(state)
    since = ActiveHours.day_start(now, loop.timezone)
    opts = [server: state.repo]

    case Repo.spend_open_loop_budget(loop.id, state.claimed_at, since, now, opts) do
      {:ok, _row} -> :ok
      {:error, :closed_meanwhile} -> :closed_meanwhile
      {:error, reason} -> {:error, reason}
    end
  end

  defp still_claimed(state) do
    case Repo.get_open_loop(state.loop.id, server: state.repo) do
      {:ok, %{state: "due", claimed_at: %DateTime{} = at}} -> same_claim(at, state.claimed_at)
      {:ok, _settled} -> :closed_meanwhile
      {:error, reason} -> {:error, reason}
    end
  end

  defp same_claim(at, claimed_at),
    do: if(DateTime.compare(at, claimed_at) == :eq, do: :ok, else: :closed_meanwhile)

  # Exactly one attempt: no retry ladder, no failover platform (§11).
  defp deliver(state, text, started) do
    case send_once(state, text) do
      :ok -> record_spoken(state, text, started)
      {:error, reason} -> delivery_failed(state, reason, started)
    end
  end

  defp send_once(%{loop: loop} = state, text) do
    with {:ok, thread} <- Delivery.thread_opts(loop) do
      send_opts = thread ++ [proactive_key: "open_loop:#{loop.id}:#{state.touch}"]
      opts = Keyword.put(state.delivery_opts, :delivery_max_attempts, 1)

      Defaults.send_timeout_ms()
      |> ChannelSend.with_timeout(fn ->
        ChannelSend.send(loop.delivery_platform, loop.delivery_destination, text, send_opts, opts)
      end)
      |> Error.normalize()
    end
  end

  defp record_spoken(%{loop: loop} = state, text, started) do
    :ok =
      ConversationStore.add_message(conversation_key(loop), "assistant", text,
        kind: "chat_message",
        metadata: %{open_loop_checkin: loop.id},
        server: state.conversation_store
      )

    now = now(state)

    changes =
      loop
      |> Lifecycle.after_touch(state.rung, now, state.active_hours)
      |> Map.merge(%{last_outcome: "spoke", last_outcome_at: now, last_message: text})

    if finalize(state, changes) == :closed_meanwhile do
      Logger.warning(
        "Open loop #{loop.id} check-in was sent and written to its conversation history, " <>
          "but the owner settled the loop meanwhile, so the touch is not counted " <>
          "(the day's budget was spent before the send)"
      )
    end

    Telemetry.run_complete(state.run, "spoke", elapsed(started), text)
  end

  defp delivery_failed(state, reason, started) do
    Logger.warning(
      "Open loop #{state.loop.id} check-in could not be sent: #{Delivery.error_text(reason)}"
    )

    changes =
      Lifecycle.after_outcome(state.loop, "delivery_failed", now(state), state.active_hours)

    finalize(state, changes)
    Telemetry.run_complete(state.run, "delivery_failed", elapsed(started))
  end

  # --- the finalising write ------------------------------------------------------

  defp finalize(state, changes) do
    opts = [server: state.repo, now: now(state)]

    case Repo.finalize_open_loop_checkin(state.loop.id, state.claimed_at, changes, opts) do
      {:ok, row} ->
        trace_settled(state, row)

      {:error, :closed_meanwhile} ->
        closed_meanwhile(state)

      {:error, reason} ->
        Logger.error(
          "Open loop #{state.loop.id} check-in could not record its outcome: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # A check-in's own write that moved the loop is traced as one; an expiry is
  # the scheduler's word for it, with no session (the contract's rule).
  defp trace_settled(_state, %{state: "due"}), do: :ok

  defp trace_settled(state, %{state: "expired"}) do
    Telemetry.settled(state.loop.id, "due", "expired", nil, "scheduler", nil)
  end

  defp trace_settled(state, %{state: to}) do
    Telemetry.settled(state.loop.id, "due", to, nil, "checkin", state.run.session_id)
  end

  defp closed_meanwhile(state) do
    Logger.info(
      "Open loop #{state.loop.id} was settled while its check-in ran; the check-in sends nothing"
    )

    Telemetry.skipped("closed_meanwhile", state.loop.id)
    :closed_meanwhile
  end

  defp now(state), do: state.now_fn.()
  defp elapsed(started), do: System.monotonic_time(:millisecond) - started

  # --- the prompt ----------------------------------------------------------------

  defp messages(state) do
    case BootstrapLoader.load(state.loop.agent_id, bootstrap_opts(state)) do
      {:ok, bootstrap} -> {:ok, compose(bootstrap, state)}
      {:error, reason} -> {:error, {:bootstrap_load_failed, reason}}
    end
  end

  defp bootstrap_opts(%{bootstrap_dir: nil, repo: repo}), do: [server: repo]
  defp bootstrap_opts(%{bootstrap_dir: dir, repo: repo}), do: [server: repo, bootstrap_dir: dir]

  # IDENTITY and SOUL so it sounds like Fermix; never FERMIX.md, whose tool and
  # channel guidance belongs to the main agent.
  defp compose(bootstrap, state) do
    persona =
      [bootstrap.identity, bootstrap.soul]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&%{role: "system", content: &1.content})

    persona ++
      [
        %{role: "system", content: guidance()},
        %{role: "system", content: CurrentDate.note()},
        %{role: "user", content: occasion(state)}
      ]
  end

  defp occasion(%{loop: loop, touch: touch} = state) do
    facts =
      %{
        "open_loop" => Registry.view(loop),
        "touch" => touch,
        "repeat" => loop.touches > 0,
        "last_touch" => Lifecycle.final_touch?(loop)
      }
      |> maybe_put_previous(loop.last_message)

    """
    #{Clock.now_line(now(state))}

    The open loop this check-in is about, as the open-loop tools show it, and where this touch stands:

    #{Jason.encode!(facts, pretty: true)}
    """
    |> String.trim()
  end

  defp maybe_put_previous(facts, nil), do: facts
  defp maybe_put_previous(facts, text), do: Map.put(facts, "previous_message", text)

  # §07, verbatim; the owner edits the wording.
  defp guidance do
    """
    You are a Fermix check-in. The owner once told Fermix they meant to do something by a date, and has not said since whether it happened. Decide whether one short message would help them right now; staying silent is a good answer. Recall memory first: if the owner has since said it is done, close the loop instead of asking.

    Speak only if the date is still live and the message adds something: the time left, or an offer of help. Open with what they said and when they said it, so they know where this comes from. State the fact that makes now relevant, never an obligation. Ask one open or two-sided question that makes "not yet" as easy to say as "done". Use no words that imply lateness or duty. Offer one small next step with permission, and leave the choice with them. One or two sentences, one loop, no preamble, no sign-off.

    If this is a repeat, bring only what has changed since or make a smaller ask; never restate the earlier question. If it is the last touch, say plainly that you won't raise it again. Report the decision with open_loop_respond; Fermix delivers the message, so never try to send it yourself.
    """
    |> String.trim()
  end
end
