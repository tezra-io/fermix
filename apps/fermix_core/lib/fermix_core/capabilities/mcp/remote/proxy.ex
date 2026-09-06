defmodule FermixCore.Capabilities.MCP.Remote.Proxy do
  @moduledoc """
  The allowlisted call proxy for one source-qualified remote MCP client
  (M27 §7.6, §7.8, §7.9).

  The raw client is private. `MCP.Registry` publishes **this** process instead,
  and every `tools/call` passes the same gate immediately before dispatch:

    * source-qualified plugin identity (a context minted for another source is
      refused, not translated);
    * current `:ready` state (a suspended or drifting client serves nothing);
    * selected-profile membership and the exact original tool name;
    * the signed read-only / replay-safe facts; and
    * resource scope — the operator-selected value is injected here, and a
      model-supplied one is refused **before** network I/O.

  So a stale capability whose registration was rolled back, and a direct
  internal caller that guessed an excluded tool name, both fail at this gate
  rather than at the peer.

  ## Serialization

  One in-flight call, a FIFO queue capped at `Limits.max_queued_calls/0`, and
  pacing at `Limits.min_call_interval_ms/0`; overflow returns `:remote_busy`
  rather than growing an unbounded backlog behind a rate limit. Every queued
  entry carries its caller's monitor and an absolute deadline no later than the
  call's own; caller death or deadline expiry removes it **before** dispatch, so
  an abandoned queued write can never start minutes later against a workspace
  nobody is watching.

  After dispatch the rule inverts: the network effect is already visible to the
  peer, so a dead caller's call is allowed to resolve — and is never replayed.

  ## Drift

  `tools_changed/1` suspends new calls. The owner of registration (`MCP.Server`)
  rediscovers and re-registers; `resume/1` reopens the gate. Notifications that
  arrive while suspended coalesce — the proxy holds one boolean, not a queue of
  pending passes. The old contract is never served after a drift notification.

  Suspension covers already-queued work too, not just admission. Dispatch is
  driven by the in-flight call settling and by the pacing timer, so without that
  a queued entry went out on the old contract moments after the gate closed.

  Drift **holds** and terminal **rejects**. A drift suspension is transient and
  `resume/2` hands back the same compiled signed contract, so a held entry's
  policy is unchanged and its caller is still inside its own deadline; entries
  whose deadline passed while held are settled `:call_deadline_expired` on the
  way out rather than dispatched. The gate a terminal protocol error closes
  never reopens, so holding there would leave every queued caller waiting out a
  full call timeout for a dispatch that can never come — they are rejected with
  `{:remote_protocol_error, class}` and their monitors released instead.
  """

  use GenServer

  alias FermixCore.Capabilities.MCP.Remote.Budget
  alias FermixCore.Capabilities.MCP.Remote.Contract
  alias FermixCore.Capabilities.MCP.Remote.Limits
  alias FermixCore.Timeouts

  require Logger

  @type invoke_context :: %{
          required(:source_id) => Contract.source_id(),
          required(:session_id) => String.t() | nil,
          required(:turn_pid) => pid(),
          required(:profile) => String.t(),
          required(:read_only) => boolean(),
          required(:replay_safe) => boolean(),
          optional(atom()) => term()
        }

  @type opt ::
          {:contract, Contract.t()}
          | {:dispatch, module()}
          | {:target, term()}
          | {:budget, GenServer.server()}
          | {:notify, pid() | nil}
          | {:name, GenServer.name()}

  @doc """
  Dispatch seam: the thing that actually performs one `tools/call` over the
  authenticated session. Production is the connection owner; tests supply a
  fake transport.
  """
  @callback call_tool(
              target :: term(),
              tool :: String.t(),
              args :: map(),
              timeout :: pos_integer()
            ) ::
              {:ok, map()} | {:error, term()}

  @spec start_link([opt()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    if name,
      do: GenServer.start_link(__MODULE__, opts, name: name),
      else: GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Call one allowlisted tool. Every check above runs before the peer is touched.
  """
  @spec call(GenServer.server(), invoke_context(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def call(proxy, context, tool, args)
      when is_map(context) and is_binary(tool) and is_map(args) do
    GenServer.call(proxy, {:call, context, tool, args}, Timeouts.mcp_remote_call() + 10_000)
  catch
    :exit, {reason, {GenServer, :call, _args}} when reason in [:noproc, :normal, :shutdown] ->
      {:error, :remote_not_connected}
  end

  @doc "Suspend new calls (drift notification, rediscovery in progress)."
  @spec suspend(GenServer.server()) :: :ok
  def suspend(proxy), do: GenServer.call(proxy, :suspend)

  @doc "Reopen the gate after a successful transactional re-registration."
  @spec resume(GenServer.server(), Contract.t()) :: :ok
  def resume(proxy, contract) when is_map(contract),
    do: GenServer.call(proxy, {:resume, contract})

  @doc "Record a `notifications/tools/list_changed`; suspends and coalesces."
  @spec tools_changed(GenServer.server()) :: :ok
  def tools_changed(proxy), do: GenServer.call(proxy, :tools_changed)

  @doc "Current gate state, for status surfaces and tests."
  @spec state(GenServer.server()) :: :ready | :suspended
  def state(proxy), do: GenServer.call(proxy, :state)

  @doc "Gate, queue depth, and single-flight occupancy — for status and tests."
  @spec stats(GenServer.server()) :: %{
          gate: :ready | :suspended,
          queued: non_neg_integer(),
          inflight?: boolean()
        }
  def stats(proxy), do: GenServer.call(proxy, :stats)

  @impl true
  def init(opts) do
    contract = Keyword.fetch!(opts, :contract)

    {:ok,
     %{
       contract: contract,
       dispatch: Keyword.fetch!(opts, :dispatch),
       target: Keyword.fetch!(opts, :target),
       # Required, never defaulted: a proxy with no budget sink is a proxy with
       # no ceiling, and that must be impossible to construct by omission.
       budget: Keyword.fetch!(opts, :budget),
       notify: Keyword.get(opts, :notify),
       gate: :ready,
       queue: :queue.new(),
       queued: 0,
       inflight: nil,
       last_dispatch_at: nil,
       timer: nil,
       invalid_results: 0,
       monitors: %{}
     }}
  end

  @impl true
  def handle_call({:call, context, tool, args}, from, state) do
    case admit(state, context, tool, args) do
      {:ok, entry} -> enqueue(state, %{entry | from: from})
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:suspend, _from, state), do: {:reply, :ok, %{state | gate: :suspended}}

  # Reopening also releases the work held during the drift: it drains under the
  # same pacing as anything else, and an entry whose deadline passed while held
  # is settled by `pop_live/1` before it can reach the peer.
  def handle_call({:resume, contract}, _from, state),
    do: {:reply, :ok, dispatch_next(%{state | gate: :ready, contract: contract})}

  def handle_call(:tools_changed, _from, state), do: {:reply, :ok, %{state | gate: :suspended}}

  def handle_call(:state, _from, state), do: {:reply, state.gate, state}

  def handle_call(:stats, _from, state) do
    stats = %{gate: state.gate, queued: state.queued, inflight?: not is_nil(state.inflight)}
    {:reply, stats, state}
  end

  @impl true
  def handle_info(:pace, state), do: {:noreply, dispatch_next(%{state | timer: nil})}

  def handle_info({:dispatch_result, ref, result}, %{inflight: %{ref: ref}} = state) do
    {:noreply, settle(state, result)}
  end

  # The dispatch task died without answering. The call fails; the network effect,
  # if any, is NOT replayed.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{inflight: %{monitor: ref}} = state) do
    Logger.warning("remote MCP dispatch task died: #{inspect(class_of(reason))}")
    {:noreply, settle(state, {:error, :dispatch_failed})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, drop_queued(state, ref)}
  end

  def handle_info({:dispatch_result, _stale_ref, _result}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Logger.debug("remote MCP proxy ignored #{inspect(kind_of(message))}")
    {:noreply, state}
  end

  # --- admission ---------------------------------------------------------

  # Every check here is cheap and happens before the entry can occupy a queue
  # slot, so a refused call costs nothing and cannot displace a valid one.
  defp admit(state, context, tool, args) do
    with :ok <- check_gate(state),
         {:ok, policy} <- check_identity(state, context, tool),
         :ok <- check_policy_facts(policy, context),
         {:ok, args} <- check_resource_scope(state, args),
         :ok <- Budget.check_arguments(policy.argument_guards, args),
         {:ok, args} <- Budget.apply_request_limit(policy.collection_policy, args) do
      {:ok, entry(context, tool, args, policy)}
    end
  end

  defp check_gate(%{gate: :ready}), do: :ok
  defp check_gate(%{gate: :suspended}), do: {:error, :remote_suspended}

  defp check_identity(state, context, tool) do
    contract = state.contract

    cond do
      Map.get(context, :source_id) != contract.source_id -> {:error, :source_mismatch}
      Map.get(context, :profile) != contract.selected_profile -> {:error, :profile_mismatch}
      true -> fetch_tool(contract, tool)
    end
  end

  # Exact original name only. A sanitized, truncated, or near-miss name is a
  # different tool, and the allowlist is the only place a name becomes callable.
  defp fetch_tool(contract, tool) do
    case Map.fetch(contract.tools, tool) do
      {:ok, policy} -> {:ok, policy}
      :error -> {:error, :tool_not_allowed}
    end
  end

  # The invoke context is minted from the signed policy at registration time, so
  # a mismatch means the capability outlived the contract that produced it.
  defp check_policy_facts(policy, context) do
    if Map.get(context, :read_only) == policy.read_only and
         Map.get(context, :replay_safe) == policy.replay_safe,
       do: :ok,
       else: {:error, :stale_capability}
  end

  defp check_resource_scope(state, args) do
    scope = state.contract.resource_scope

    if Map.has_key?(args, scope.argument),
      do: {:error, :resource_scope_violation},
      else: {:ok, Map.put(args, scope.argument, scope.id)}
  end

  defp entry(context, tool, args, policy) do
    %{
      from: nil,
      context: context,
      tool: tool,
      args: args,
      policy: policy,
      deadline: System.monotonic_time(:millisecond) + Timeouts.mcp_remote_call(),
      monitor: nil,
      ref: nil
    }
  end

  # --- queue -------------------------------------------------------------

  defp enqueue(state, entry) do
    if state.queued >= Limits.max_queued_calls() do
      {:reply, {:error, :remote_busy}, state}
    else
      {:noreply, admit_to_queue(state, entry)}
    end
  end

  defp admit_to_queue(state, entry) do
    ref = Process.monitor(caller_pid(entry.from))
    entry = %{entry | monitor: ref}

    state = %{
      state
      | queue: :queue.in(entry, state.queue),
        queued: state.queued + 1,
        monitors: Map.put(state.monitors, ref, entry.from)
    }

    dispatch_next(state)
  end

  defp caller_pid({pid, _tag}), do: pid

  defp drop_queued(state, ref) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} -> state
      {from, monitors} -> %{state | monitors: monitors} |> remove_from_queue(from)
    end
  end

  defp remove_from_queue(state, from) do
    kept = state.queue |> :queue.to_list() |> Enum.reject(&(&1.from == from))
    %{state | queue: :queue.from_list(kept), queued: length(kept)}
  end

  # A suspended gate holds the queue as well as admission. Every other caller of
  # this function is an event the drift did not cause — the in-flight call
  # settling, the pacing timer, a refusal — and each of them would otherwise put
  # a queued entry on the wire under the contract the drift just invalidated.
  # Entries keep their monitors and absolute deadlines while held.
  defp dispatch_next(%{gate: :suspended} = state), do: state

  # Pacing and single-flight are one decision: dispatch only when nothing is in
  # flight AND the interval since the last dispatch has elapsed.
  defp dispatch_next(%{inflight: inflight} = state) when not is_nil(inflight), do: state
  defp dispatch_next(%{timer: timer} = state) when not is_nil(timer), do: state

  defp dispatch_next(state) do
    case wait_ms(state) do
      0 -> take_and_dispatch(state)
      wait -> %{state | timer: Process.send_after(self(), :pace, wait)}
    end
  end

  defp wait_ms(%{last_dispatch_at: nil}), do: 0

  defp wait_ms(%{last_dispatch_at: at}) do
    elapsed = System.monotonic_time(:millisecond) - at
    max(Limits.min_call_interval_ms() - elapsed, 0)
  end

  defp take_and_dispatch(state) do
    case pop_live(state) do
      {:empty, state} -> state
      {{:ok, entry}, state} -> charge_and_dispatch(state, entry)
    end
  end

  # Expiry and caller death are settled HERE, before dispatch: this is the last
  # moment at which a queued write can still be cancelled without a visible
  # network effect.
  defp pop_live(state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        {:empty, state}

      {{:value, entry}, queue} ->
        state = %{state | queue: queue, queued: state.queued - 1}
        settle_or_skip(state, entry)
    end
  end

  defp settle_or_skip(state, entry) do
    if System.monotonic_time(:millisecond) >= entry.deadline do
      reply(entry, {:error, :call_deadline_expired})
      pop_live(release(state, entry))
    else
      {{:ok, entry}, state}
    end
  end

  defp charge_and_dispatch(state, entry) do
    case charge(state, entry) do
      :ok -> start_dispatch(state, entry)
      {:error, reason} -> refuse(state, entry, reason)
    end
  end

  defp refuse(state, entry, reason) do
    reply(entry, {:error, reason})
    dispatch_next(release(state, entry))
  end

  # Charged immediately before dispatch, never at admission: a queued call that
  # its caller abandoned must not have spent the turn's ceiling.
  defp charge(state, entry) do
    case budget_key(state, entry) do
      {:ok, key} ->
        Budget.charge(
          state.budget,
          key,
          charge_kind(entry),
          state.contract.budgets,
          turn_pid(entry)
        )

      :error ->
        {:error, :missing_turn_identity}
    end
  end

  defp budget_key(state, entry) do
    case Map.get(entry.context, :session_id) do
      session_id when is_binary(session_id) and session_id != "" ->
        {:ok, Budget.turn_key(state.contract.source_id, session_id)}

      _absent ->
        :error
    end
  end

  defp turn_pid(entry) do
    case Map.get(entry.context, :turn_pid) do
      pid when is_pid(pid) -> pid
      _absent -> caller_pid(entry.from)
    end
  end

  defp charge_kind(%{policy: %{collection_policy: nil}}), do: :call
  defp charge_kind(_entry), do: :paginated_call

  # The exchange runs in a monitored task so a 60-second call cannot also block
  # admission, queue accounting, and caller-death handling for 60 seconds. The
  # single-flight invariant is `state.inflight`, not a blocked mailbox.
  defp start_dispatch(state, entry) do
    ref = make_ref()
    proxy = self()
    %{dispatch: dispatch, target: target} = state
    %{tool: tool, args: args} = entry
    timeout = Timeouts.mcp_remote_call()

    {task, monitor} =
      spawn_monitor(fn ->
        send(proxy, {:dispatch_result, ref, dispatch.call_tool(target, tool, args, timeout)})
      end)

    %{
      state
      | inflight: %{entry: entry, ref: ref, task: task, monitor: monitor},
        last_dispatch_at: System.monotonic_time(:millisecond)
    }
  end

  # --- settlement --------------------------------------------------------

  defp settle(state, result) do
    %{entry: entry, monitor: monitor} = state.inflight
    Process.demonitor(monitor, [:flush])

    {reply, state} = classify(state, entry, result)
    reply(entry, reply)

    state
    |> release(entry)
    |> Map.put(:inflight, nil)
    |> dispatch_next()
  end

  defp classify(state, entry, {:ok, raw}) do
    case Contract.classify_result(state.contract, raw) do
      {:ok, text} -> settle_success(state, entry, raw, text)
      {:error, {:invalid_remote_result, class}} -> count_invalid(state, class)
      {:error, reason} -> {{:error, reason}, reset_invalid(state)}
    end
  end

  defp classify(state, _entry, {:error, reason}), do: {{:error, reason}, state}

  defp settle_success(state, entry, raw, text) do
    case Budget.check_returned_items(entry.policy.collection_policy, collection_body(raw, text)) do
      :ok -> {{:ok, text}, reset_invalid(state)}
      {:error, reason} -> {{:error, reason}, reset_invalid(state)}
    end
  end

  defp collection_body(%{"structuredContent" => %{} = structured}, _text), do: structured

  defp collection_body(_raw, text) do
    case Jason.decode(text) do
      {:ok, %{} = decoded} -> decoded
      _not_an_object -> %{}
    end
  end

  # Three consecutive invalid results in one session is a broken peer, not a
  # flaky call. Any reviewed valid result resets the counter.
  defp count_invalid(state, class) do
    count = state.invalid_results + 1
    state = %{state | invalid_results: count}

    if count >= Limits.max_consecutive_invalid_results(),
      do: {{:error, {:remote_protocol_error, class}}, terminal(state, class)},
      else: {{:error, {:invalid_remote_result, class}}, state}
  end

  # The gate closes here; unregistering the capabilities and closing the session
  # belong to the registration owner, which is told exactly once.
  #
  # This gate never reopens, so — unlike a drift suspension — the queue cannot be
  # held: every waiting caller would sit out its full call timeout for a dispatch
  # that can never come. They are answered now, with the reason.
  defp terminal(state, class) do
    if is_pid(state.notify), do: send(state.notify, {:mcp_proxy, :protocol_error, class})

    state
    |> reject_queued({:remote_protocol_error, class})
    |> Map.put(:gate, :suspended)
  end

  defp reject_queued(state, reason) do
    entries = :queue.to_list(state.queue)
    Enum.each(entries, &reply(&1, {:error, reason}))

    state = Enum.reduce(entries, state, fn entry, acc -> release(acc, entry) end)
    %{state | queue: :queue.new(), queued: 0}
  end

  defp reset_invalid(state), do: %{state | invalid_results: 0}

  defp release(state, %{monitor: nil}), do: state

  defp release(state, entry) do
    Process.demonitor(entry.monitor, [:flush])
    %{state | monitors: Map.delete(state.monitors, entry.monitor)}
  end

  defp reply(%{from: nil}, _reply), do: :ok
  defp reply(%{from: from}, reply), do: GenServer.reply(from, reply)

  defp class_of(reason) when is_atom(reason), do: reason
  defp class_of(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: elem(reason, 0)
  defp class_of(_reason), do: :unclassified

  defp kind_of(message) when is_tuple(message) and tuple_size(message) > 0, do: elem(message, 0)
  defp kind_of(message) when is_atom(message), do: message
  defp kind_of(_message), do: :unknown
end
