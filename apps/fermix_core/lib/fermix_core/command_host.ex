defmodule FermixCore.CommandHost do
  @moduledoc """
  Supervised owner of one external command's OS process group.

  In the daemon configuration (`CommandRunner.run/3` with `supervised: true`),
  each command is run by a `CommandHost` started under
  `FermixCore.CommandHost.Supervisor`. The host — not the requester — opens the
  port, so ownership is structural: there is no window in which the process
  group exists unowned.

  Two consumption modes share this one host, chosen at start:

    * `:buffered` — `CommandRunner.run/3`: output is accumulated and returned once
      as `{:command_result, ref, result}` when the command ends.
    * `:streaming` — `CommandRunner.start_stream/3`: raw output chunks are
      forwarded to a subscriber as `{:command_host_data, ref, chunk}` under an
      ack-window flow-control valve, and the run ends with exactly one
      `{:command_host_exit, ref, result}` message.

  Lifecycle (design §3, §4) — identical for both modes:

    * The host monitors the owner (requester / subscriber) **first**, then
      `Port.open`s, then reads `os_pid` immediately (`Port.info`) — the port child
      is its own group leader, so `os_pid` is the pgid.
    * Every command **ending** sweeps the group. Success/failure exit → immediate
      group-SIGKILL (any survivor is a leak). Output-cap truncation / wall-clock
      timeout / cancel / stalled subscriber → group-SIGTERM, drain (discarding
      output) until `exit_status` or `kill_grace_ms`, then **unconditional**
      group-SIGKILL. Owner death → immediate group-SIGKILL, no reply. Supervisor
      shutdown → `terminate/2` sweeps.
    * On an ending the host replies to the owner and stops `:normal`.

  The host holds the port, so a late secret-helper output line (the drain-discard
  guard) can never reach the owner's mailbox; the host flushes internally.

  Streaming flow control (deviation D1): the host forwards while
  `outstanding < ack_window`; beyond that, chunks queue bounded by
  `pending_bytes_max`. Acks (`ack/3`) decrement the window and flush the queue. A
  breach of `pending_bytes_max` is a failed-subscriber ending
  (`{:error, {:subscriber_stalled, bytes}}`). `max_output_bytes` remains a total
  cap: breach → the same truncation ending as buffered mode.
  """

  use GenServer

  require Logger

  alias FermixCore.CommandRunner
  alias FermixCore.ProcessGroup

  @default_ack_window 64
  @default_pending_bytes_max 8 * 1_048_576

  @type start_arg ::
          {pid(), reference(), String.t(), [String.t()], CommandRunner.opts()}
          | {:stream, pid(), pid(), reference(), String.t(), [String.t()],
             CommandRunner.stream_opts()}

  @spec child_spec(start_arg()) :: Supervisor.child_spec()
  def child_spec(arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [arg]},
      # A finished/crashed command is never restarted; one port, one fault.
      restart: :temporary,
      # The sweep runs in terminate/2 on supervisor shutdown; the default 5s
      # brutal-kill would cut a mid-signal drain short.
      shutdown: 10_000,
      type: :worker
    }
  end

  @spec start_link(start_arg()) :: GenServer.on_start()
  def start_link({requester, reply_ref, executable, args, opts} = arg)
      when is_pid(requester) and is_reference(reply_ref) and is_binary(executable) and
             is_list(args) and is_list(opts) do
    GenServer.start_link(__MODULE__, arg)
  end

  def start_link({:stream, caller, stream_to, ref, executable, args, opts} = arg)
      when is_pid(caller) and is_pid(stream_to) and is_reference(ref) and is_binary(executable) and
             is_list(args) and is_list(opts) do
    GenServer.start_link(__MODULE__, arg)
  end

  @doc """
  Acknowledges `n` forwarded chunks (streaming mode), decrementing the outstanding
  window and flushing any queued chunks that now fit. A cast; stale refs and
  ended/draining hosts ignore it.
  """
  @spec ack(pid(), reference(), pos_integer()) :: :ok
  def ack(host, ref, n \\ 1)
      when is_pid(host) and is_reference(ref) and is_integer(n) and n > 0 do
    GenServer.cast(host, {:ack, ref, n})
  end

  @doc """
  Cancels a streaming run: TERM→drain→KILL sweep, terminal `{:error, :cancelled}`.
  Idempotent — a second cancel, a cancel of an already-draining host, or a cancel
  that races the host's own terminal-completion stop is `:ok`. A host that already
  ended is gone, so the `GenServer.call` exits `:noproc`/`:normal`/`:shutdown`;
  those benign races resolve to `:ok` (the run already ended). Any other exit
  reason is a real crash and propagates.
  """
  @spec cancel(pid(), reference()) :: :ok
  def cancel(host, ref) when is_pid(host) and is_reference(ref) do
    GenServer.call(host, {:cancel, ref})
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] -> :ok
  end

  @impl true
  def init({requester, reply_ref, executable, args, opts}) do
    Process.flag(:trap_exit, true)

    # Ownership ordering (principle 1): monitor the requester FIRST, then open
    # the port, then read os_pid immediately with nothing between.
    requester_mon = Process.monitor(requester)
    port = Port.open({:spawn_executable, executable}, CommandRunner.build_port_opts(args, opts))
    os_pid = read_os_pid(port)

    limits = CommandRunner.build_limits(opts)
    timeout_ref = Process.send_after(self(), :command_host_timeout, limits.timeout_ms)

    state = %{
      mode: :buffered,
      requester: requester,
      reply_ref: reply_ref,
      requester_mon: requester_mon,
      port: port,
      os_pid: os_pid,
      limits: limits,
      acc: [],
      total: 0,
      draining?: false,
      pending_result: nil,
      timeout_ref: timeout_ref,
      grace_ref: nil,
      ended?: false
    }

    {:ok, state}
  end

  def init({:stream, caller, stream_to, ref, executable, args, opts}) do
    Process.flag(:trap_exit, true)

    # Validate every option BEFORE spawning the OS child. An init that raises
    # never runs terminate/2, so a raise after Port.open would leak the process
    # group unswept — violating the "no unowned window" invariant. Computing the
    # limits/window here means a bad option fails before any group exists.
    limits = CommandRunner.build_limits(opts)
    ack_window = stream_pos_int(opts, :ack_window, @default_ack_window)
    pending_bytes_max = stream_pos_int(opts, :pending_bytes_max, @default_pending_bytes_max)

    # Same ownership ordering as buffered: monitor the subscriber FIRST, then
    # open the port, then read os_pid. Report the os_pid back to the start caller
    # before the receive loop can process any exit (race-free os_pid discovery).
    subscriber_mon = Process.monitor(stream_to)

    port =
      Port.open({:spawn_executable, executable}, CommandRunner.build_stream_port_opts(args, opts))

    os_pid = read_os_pid(port)
    send(caller, {:command_host_started, ref, os_pid})

    timeout_ref = Process.send_after(self(), :command_host_timeout, limits.timeout_ms)

    state = %{
      mode: :streaming,
      subscriber: stream_to,
      ref: ref,
      subscriber_mon: subscriber_mon,
      port: port,
      os_pid: os_pid,
      limits: limits,
      ack_window: ack_window,
      pending_bytes_max: pending_bytes_max,
      outstanding: 0,
      pending: :queue.new(),
      pending_bytes: 0,
      received: 0,
      forwarded_bytes: 0,
      draining?: false,
      pending_result: nil,
      timeout_ref: timeout_ref,
      grace_ref: nil,
      ended?: false
    }

    {:ok, state}
  end

  @impl true
  # Cancel (streaming) while running: begin the TERM→drain→KILL sweep with a
  # terminal cancelled result. Idempotent — any other state (already draining,
  # buffered, stale ref) is a no-op :ok.
  def handle_call({:cancel, ref}, _from, %{mode: :streaming, ref: ref, draining?: false} = state) do
    {:reply, :ok, begin_drain(state, {:error, :cancelled})}
  end

  def handle_call({:cancel, _ref}, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  # Ack (streaming, running): decrement the window (floored at 0) and flush any
  # queued chunks that now fit.
  def handle_cast({:ack, ref, n}, %{mode: :streaming, ref: ref, draining?: false} = state) do
    outstanding = max(state.outstanding - n, 0)
    {:noreply, flush_to_window(%{state | outstanding: outstanding})}
  end

  def handle_cast({:ack, _ref, _n}, state) do
    {:noreply, state}
  end

  @impl true
  # --- Buffered mode -------------------------------------------------------

  # Output while draining (timeout/cap): discard — a late secret-helper line
  # must never be retained.
  def handle_info(
        {port, {:data, _chunk}},
        %{mode: :buffered, port: port, draining?: true} = state
      ) do
    {:noreply, state}
  end

  # Output accumulation with the cap; a breach is a truncation ending.
  def handle_info(
        {port, {:data, chunk}},
        %{mode: :buffered, port: port, draining?: false} = state
      ) do
    new_total = state.total + byte_size(chunk)

    if new_total > state.limits.max_output_bytes do
      stdout = take_prefix(state.acc, state.limits.max_output_bytes)
      enter_drain(state, {:ok, %{exit: 124, stdout: stdout, truncated?: true}})
    else
      {:noreply, %{state | acc: [state.acc | chunk], total: new_total}}
    end
  end

  # Child exited during a TERM-drain: proceed to the unconditional SIGKILL and
  # reply with the pending (timeout/cap) result.
  def handle_info(
        {port, {:exit_status, _code}},
        %{mode: :buffered, port: port, draining?: true} = state
      ) do
    finalize(state, state.pending_result)
  end

  # Normal exit ending: immediate group-SIGKILL (any survivor is a leak).
  def handle_info(
        {port, {:exit_status, code}},
        %{mode: :buffered, port: port, draining?: false} = state
      ) do
    result = {:ok, %{exit: code, stdout: IO.iodata_to_binary(state.acc), truncated?: false}}
    finalize(state, result)
  end

  # --- Streaming mode ------------------------------------------------------

  # Output while draining (timeout/cancel/cap/stall): discard — same guard.
  def handle_info(
        {port, {:data, _chunk}},
        %{mode: :streaming, port: port, draining?: true} = state
      ) do
    {:noreply, state}
  end

  # Output: honor the total cap, then forward or queue under the ack window.
  def handle_info(
        {port, {:data, chunk}},
        %{mode: :streaming, port: port, draining?: false} = state
      ) do
    received = state.received + byte_size(chunk)

    cond do
      received > state.limits.max_output_bytes ->
        result = {:ok, %{exit: 124, truncated?: true, forwarded_bytes: state.forwarded_bytes}}
        enter_drain(%{state | received: received}, result)

      state.outstanding < state.ack_window and :queue.is_empty(state.pending) ->
        {:noreply, forward_chunk(%{state | received: received}, chunk)}

      true ->
        queue_or_stall(%{state | received: received}, chunk)
    end
  end

  # Child exited during a TERM-drain: proceed to the unconditional SIGKILL and
  # send the pending (timeout/cancel/cap/stall) result.
  def handle_info(
        {port, {:exit_status, _code}},
        %{mode: :streaming, port: port, draining?: true} = state
      ) do
    finalize(state, state.pending_result)
  end

  # Normal/non-zero exit ending: flush any queued chunks in order, then send the
  # terminal exit and immediate group-SIGKILL (any survivor is a leak).
  def handle_info(
        {port, {:exit_status, code}},
        %{mode: :streaming, port: port, draining?: false} = state
      ) do
    state = flush_all(state)
    result = {:ok, %{exit: code, truncated?: false, forwarded_bytes: state.forwarded_bytes}}
    finalize(state, result)
  end

  # --- Shared timers & owner death ----------------------------------------

  # Wall-clock timeout ending (either mode): SIGTERM, then drain until exit or grace.
  def handle_info(:command_host_timeout, %{mode: :buffered, draining?: false} = state) do
    enter_drain(state, {:error, {:timeout, state.limits.timeout_ms}})
  end

  def handle_info(:command_host_timeout, %{mode: :streaming, draining?: false} = state) do
    enter_drain(state, {:error, {:timeout, state.limits.timeout_ms}})
  end

  def handle_info(:command_host_timeout, %{draining?: true} = state) do
    {:noreply, state}
  end

  # Grace expired without the child exiting: unconditional SIGKILL, reply pending.
  def handle_info(:command_host_grace, %{draining?: true} = state) do
    finalize(state, state.pending_result)
  end

  def handle_info(:command_host_grace, %{draining?: false} = state) do
    {:noreply, state}
  end

  # Owner death ending: sweep immediately, no reply, stop.
  def handle_info(
        {:DOWN, mon, :process, _pid, _reason},
        %{mode: :buffered, requester_mon: mon} = state
      ) do
    sweep_and_close(state)
    {:stop, :normal, %{state | ended?: true}}
  end

  def handle_info(
        {:DOWN, mon, :process, _pid, _reason},
        %{mode: :streaming, subscriber_mon: mon} = state
      ) do
    sweep_and_close(state)
    {:stop, :normal, %{state | ended?: true}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  # Supervisor shutdown mid-flight: sweep the group. `ended?` means finalize/DOWN
  # already swept — do not signal a recycled pgid twice.
  def terminate(_reason, %{ended?: true}), do: :ok

  def terminate(_reason, state) do
    sweep_and_close(state)
    :ok
  end

  # --- Streaming forwarding helpers ---------------------------------------

  # Forward one chunk to the subscriber and open one slot of the ack window.
  defp forward_chunk(state, chunk) do
    send(state.subscriber, {:command_host_data, state.ref, chunk})

    %{
      state
      | outstanding: state.outstanding + 1,
        forwarded_bytes: state.forwarded_bytes + byte_size(chunk)
    }
  end

  # Window full: queue the chunk unless doing so breaches pending_bytes_max, in
  # which case the subscriber is stalled and the run ends failed.
  defp queue_or_stall(state, chunk) do
    new_pending_bytes = state.pending_bytes + byte_size(chunk)

    if new_pending_bytes > state.pending_bytes_max do
      enter_drain(state, {:error, {:subscriber_stalled, new_pending_bytes}})
    else
      {:noreply,
       %{state | pending: :queue.in(chunk, state.pending), pending_bytes: new_pending_bytes}}
    end
  end

  # Flush queued chunks while the window has room. Bounded by the queue length
  # (itself bounded by pending_bytes_max); stops at a full window or empty queue.
  defp flush_to_window(%{outstanding: out, ack_window: win} = state) when out >= win do
    state
  end

  defp flush_to_window(state) do
    case :queue.out(state.pending) do
      {{:value, chunk}, rest} ->
        state = forward_chunk(%{state | pending: rest}, chunk)
        flush_to_window(%{state | pending_bytes: state.pending_bytes - byte_size(chunk)})

      {:empty, _rest} ->
        state
    end
  end

  # Flush the entire queue in order, ignoring the window (used on a clean exit,
  # where the run is ending and every buffered byte is still owed to the
  # subscriber). Bounded by the queue length.
  defp flush_all(state) do
    case :queue.out(state.pending) do
      {{:value, chunk}, rest} ->
        state = forward_chunk(%{state | pending: rest}, chunk)
        flush_all(%{state | pending_bytes: state.pending_bytes - byte_size(chunk)})

      {:empty, _rest} ->
        state
    end
  end

  # --- Shared ending machinery --------------------------------------------

  defp enter_drain(state, pending_result), do: {:noreply, begin_drain(state, pending_result)}

  defp begin_drain(state, pending_result) do
    if state.os_pid, do: ProcessGroup.signal(state.os_pid, :sigterm)
    grace_ref = Process.send_after(self(), :command_host_grace, state.limits.kill_grace_ms)
    %{state | draining?: true, pending_result: pending_result, grace_ref: grace_ref}
  end

  defp finalize(%{mode: :buffered} = state, result) do
    state = cancel_timers(state)
    sweep_and_close(state)
    send(state.requester, {:command_result, state.reply_ref, result})
    {:stop, :normal, %{state | ended?: true}}
  end

  defp finalize(%{mode: :streaming} = state, result) do
    state = cancel_timers(state)
    sweep_and_close(state)
    send(state.subscriber, {:command_host_exit, state.ref, result})
    {:stop, :normal, %{state | ended?: true}}
  end

  # The one sweep primitive: unconditional group-SIGKILL, close the port, flush
  # any stray {port, _} that raced the close.
  defp sweep_and_close(state) do
    if state.os_pid, do: ProcessGroup.signal(state.os_pid, :sigkill)
    close_port(state.port)
    flush_port_messages(state.port)
    :ok
  end

  defp cancel_timers(state) do
    if state.timeout_ref, do: Process.cancel_timer(state.timeout_ref)
    if state.grace_ref, do: Process.cancel_timer(state.grace_ref)
    %{state | timeout_ref: nil, grace_ref: nil}
  end

  defp read_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  end

  defp close_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp flush_port_messages(port) do
    receive do
      {^port, _} -> flush_port_messages(port)
    after
      0 -> :ok
    end
  end

  defp take_prefix(iodata, max_bytes) do
    binary = IO.iodata_to_binary(iodata)
    binary_part(binary, 0, min(byte_size(binary), max_bytes))
  end

  defp stream_pos_int(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 ->
        value

      other ->
        raise ArgumentError,
              "CommandHost option #{inspect(key)} must be a positive integer, got: #{inspect(other)}"
    end
  end
end
