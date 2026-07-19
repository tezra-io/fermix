defmodule FermixCore.CommandHost do
  @moduledoc """
  Supervised owner of one external command's OS process group.

  In the daemon configuration (`CommandRunner.run/3` with `supervised: true`),
  each command is run by a `CommandHost` started under
  `FermixCore.CommandHost.Supervisor`. The host — not the requester — opens the
  port, so ownership is structural: there is no window in which the process
  group exists unowned.

  Lifecycle (design §3, §4):

    * The host monitors the requester **first**, then `Port.open`s, then reads
      `os_pid` immediately (`Port.info`) — the port child is its own group
      leader, so `os_pid` is the pgid.
    * Every command **ending** sweeps the group. Success/failure exit → immediate
      group-SIGKILL (any survivor is a leak). Output-cap truncation / wall-clock
      timeout → group-SIGTERM, drain (discarding output) until `exit_status` or
      `kill_grace_ms`, then **unconditional** group-SIGKILL. Requester death →
      immediate group-SIGKILL, no reply. Supervisor shutdown → `terminate/2`
      sweeps.
    * On an ending the host replies `{:command_result, ref, result}` to the
      requester and stops `:normal`.

  The host holds the port, so a late secret-helper output line (the drain-discard
  guard) can never reach the requester's mailbox; the host flushes internally.
  """

  use GenServer

  require Logger

  alias FermixCore.CommandRunner
  alias FermixCore.ProcessGroup

  @type start_arg ::
          {pid(), reference(), String.t(), [String.t()], CommandRunner.opts()}

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

  @impl true
  # Output while draining (timeout/cap): discard — a late secret-helper line
  # must never be retained.
  def handle_info({port, {:data, _chunk}}, %{port: port, draining?: true} = state) do
    {:noreply, state}
  end

  # Output accumulation with the cap; a breach is a truncation ending.
  def handle_info({port, {:data, chunk}}, %{port: port, draining?: false} = state) do
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
  def handle_info({port, {:exit_status, _code}}, %{port: port, draining?: true} = state) do
    finalize(state, state.pending_result)
  end

  # Normal exit ending: immediate group-SIGKILL (any survivor is a leak).
  def handle_info({port, {:exit_status, code}}, %{port: port, draining?: false} = state) do
    result = {:ok, %{exit: code, stdout: IO.iodata_to_binary(state.acc), truncated?: false}}
    finalize(state, result)
  end

  # Wall-clock timeout ending: SIGTERM, then drain until exit or grace.
  def handle_info(:command_host_timeout, %{draining?: false} = state) do
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

  # Requester death ending: sweep immediately, no reply, stop.
  def handle_info({:DOWN, mon, :process, _pid, _reason}, %{requester_mon: mon} = state) do
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

  defp enter_drain(state, pending_result) do
    if state.os_pid, do: ProcessGroup.signal(state.os_pid, :sigterm)
    grace_ref = Process.send_after(self(), :command_host_grace, state.limits.kill_grace_ms)
    {:noreply, %{state | draining?: true, pending_result: pending_result, grace_ref: grace_ref}}
  end

  defp finalize(state, result) do
    state = cancel_timers(state)
    sweep_and_close(state)
    send(state.requester, {:command_result, state.reply_ref, result})
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
end
