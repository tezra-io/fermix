defmodule FermixCore.CommandRunner do
  @moduledoc """
  Single supervised entry point for spawning external OS commands.

  Owns the OS child via `Port.open/2`, caps captured output, enforces a
  wall-clock timeout, and on timeout sends SIGTERM and SIGKILL to the
  child process so it cannot outlive the BEAM task that started it.

  This module replaces the prior `Task.async/Task.yield/Task.shutdown`
  pattern that wrapped `System.cmd/3`. That pattern only ended the BEAM
  task — the OS child kept running after Fermix returned `:timeout`
  (audit F-05).

  Public contract:

      iex> CommandRunner.run("/bin/echo", ["hi"], timeout_ms: 1_000)
      {:ok, %{exit: 0, stdout: "hi\\n", truncated?: false}}

  All callers must pass an absolute executable path (resolved by
  `System.find_executable/1` upstream). The runner does not search
  PATH itself, to keep the resolution decision visible at the call
  site.
  """

  alias FermixCore.ProcessGroup

  @type opts :: [
          {:cwd, String.t() | nil}
          | {:env, [{String.t() | charlist(), String.t() | charlist()}]}
          | {:timeout_ms, pos_integer()}
          | {:max_output_bytes, pos_integer()}
          | {:kill_grace_ms, pos_integer()}
          | {:supervised, boolean()}
          | {:dynamic_supervisor, atom() | pid()}
        ]

  @type result :: %{exit: integer(), stdout: binary(), truncated?: boolean()}
  @type limits :: %{
          timeout_ms: pos_integer(),
          max_output_bytes: pos_integer(),
          kill_grace_ms: pos_integer()
        }
  @type reason ::
          {:timeout, pos_integer()}
          | {:executable_not_found, String.t()}
          | {:command_host_crashed, term()}
          | {:port_failed, term()}
          | term()

  @default_timeout_ms 30_000
  @default_max_output_bytes 1_048_576
  @default_kill_grace_ms 200

  @doc """
  Runs an external command, returning its captured output once.

  Two configurations, chosen by `:supervised` (default `true`):

    * `supervised: true` — the daemon path. A `FermixCore.CommandHost` under
      `FermixCore.CommandHost.Supervisor` owns the OS process group and sweeps
      it on every ending, including requester death. If the supervisor is not
      running this **raises before any OS process spawns** (never a silent
      inline run). `:dynamic_supervisor` (atom or pid, default the global
      supervisor) is a test seam.
    * `supervised: false` — the one-shot path (config-provider boot, tree-less
      CLI verbs). The call collects inline and sweeps at end of run; owner-death
      coverage is out of scope there.
  """
  @spec run(String.t(), [String.t()], opts()) :: {:ok, result()} | {:error, reason()}
  def run(executable, args, opts \\ [])
      when is_binary(executable) and is_list(args) and is_list(opts) do
    limits = build_limits(opts)

    cond do
      not File.exists?(executable) ->
        {:error, {:executable_not_found, executable}}

      Keyword.get(opts, :supervised, true) ->
        run_supervised(executable, args, opts)

      true ->
        do_run(executable, args, opts, limits)
    end
  end

  @doc false
  @spec build_limits(opts()) :: limits()
  def build_limits(opts) when is_list(opts) do
    %{
      timeout_ms: positive_int_opt(opts, :timeout_ms, @default_timeout_ms),
      max_output_bytes: positive_int_opt(opts, :max_output_bytes, @default_max_output_bytes),
      kill_grace_ms: positive_int_opt(opts, :kill_grace_ms, @default_kill_grace_ms)
    }
  end

  # Exact Port.open construction shared by the one-shot path (`do_run`) and the
  # supervised host (`CommandHost.init`). Kept in one place so the two configs
  # can never drift on cwd/env/stderr/binary handling.
  @doc false
  @spec build_port_opts([String.t()], opts()) :: keyword()
  def build_port_opts(args, opts) when is_list(args) and is_list(opts) do
    [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      :hide,
      args: args
    ]
    |> maybe_put_cwd(Keyword.get(opts, :cwd))
    |> maybe_put_env(Keyword.get(opts, :env, []))
  end

  # Daemon path: start a supervised host (fail loud if the supervisor is absent —
  # before any OS process exists), then block on a monitor for the result. No
  # receive timeout — the host is bounded by its own timers; the monitor is the
  # hang protection (a host crash surfaces as {:error, {:command_host_crashed, _}}).
  defp run_supervised(executable, args, opts) do
    dyn_sup = Keyword.get(opts, :dynamic_supervisor, FermixCore.CommandHost.Supervisor)
    supervisor = resolve_supervisor!(dyn_sup)
    reply_ref = make_ref()
    child = {FermixCore.CommandHost, {self(), reply_ref, executable, args, opts}}

    case DynamicSupervisor.start_child(supervisor, child) do
      {:ok, host} -> await_host(host, reply_ref)
      {:error, reason} -> {:error, {:command_host_crashed, reason}}
    end
  end

  defp resolve_supervisor!(dyn_sup) do
    case GenServer.whereis(dyn_sup) do
      pid when is_pid(pid) ->
        pid

      _absent ->
        raise "CommandRunner: command host supervisor #{inspect(dyn_sup)} is not running. " <>
                "Daemon call sites need the supervision tree started; tree-less callers " <>
                "(config-provider boot, CLI verbs) must pass supervised: false."
    end
  end

  defp await_host(host, reply_ref) do
    mon = Process.monitor(host)

    receive do
      {:command_result, ^reply_ref, result} ->
        Process.demonitor(mon, [:flush])
        result

      {:DOWN, ^mon, :process, ^host, reason} ->
        {:error, {:command_host_crashed, reason}}
    end
  end

  defp do_run(executable, args, opts, limits) do
    port = Port.open({:spawn_executable, executable}, build_port_opts(args, opts))
    deadline = System.monotonic_time(:millisecond) + limits.timeout_ms

    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        collect(port, os_pid, deadline, limits, [], 0)

      nil ->
        # The port closed before we could read its OS pid — rare but
        # observed under heavy umbrella-test parallelism. Drain any
        # queued output and final exit_status message; treat as a
        # normal completion.
        drain_orphan(port, deadline, limits, [], 0)
    end
  end

  defp drain_orphan(port, deadline, limits, acc, total) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        new_total = total + byte_size(chunk)

        if new_total > limits.max_output_bytes do
          _ = safe_port_close(port)
          {:ok, %{exit: 124, stdout: take_prefix(acc, limits.max_output_bytes), truncated?: true}}
        else
          drain_orphan(port, deadline, limits, [acc | chunk], new_total)
        end

      {^port, {:exit_status, exit_code}} ->
        {:ok, %{exit: exit_code, stdout: IO.iodata_to_binary(acc), truncated?: false}}
    after
      remaining ->
        _ = safe_port_close(port)
        flush_port_messages(port)
        {:error, {:timeout, limits.timeout_ms}}
    end
  end

  defp collect(port, os_pid, deadline, limits, acc, total) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        new_total = total + byte_size(chunk)

        if new_total > limits.max_output_bytes do
          drain_and_kill(port, os_pid, limits)
          {:ok, %{exit: 124, stdout: take_prefix(acc, limits.max_output_bytes), truncated?: true}}
        else
          collect(port, os_pid, deadline, limits, [acc | chunk], new_total)
        end

      {^port, {:exit_status, exit_code}} ->
        # Exit ending: immediate group-SIGKILL — any group member still alive is
        # a leak by definition (e.g. a `nohup … &` descendant on `exit 0`).
        sweep_kill(port, os_pid)
        {:ok, %{exit: exit_code, stdout: IO.iodata_to_binary(acc), truncated?: false}}
    after
      remaining ->
        drain_and_kill(port, os_pid, limits)
        {:error, {:timeout, limits.timeout_ms}}
    end
  end

  # Exit ending sweep: unconditional group-SIGKILL, then close + flush.
  defp sweep_kill(port, os_pid) do
    ProcessGroup.signal(os_pid, :sigkill)
    _ = safe_port_close(port)
    flush_port_messages(port)
  end

  # Timeout / output-cap ending: group-SIGTERM, drain (discarding output) until
  # the direct child exits or the grace elapses, then **unconditional**
  # group-SIGKILL. The KILL no longer depends on the direct child's exit — a
  # TERM-trapping, fd-closing grandchild is reaped regardless.
  defp drain_and_kill(port, os_pid, %{kill_grace_ms: grace_ms}) do
    ProcessGroup.signal(os_pid, :sigterm)
    _ = await_exit(port, grace_ms)
    ProcessGroup.signal(os_pid, :sigkill)

    # SIGKILL is non-blockable; close the port (no more messages after this) and
    # flush anything already queued.
    _ = safe_port_close(port)
    flush_port_messages(port)
  end

  # Wait up to grace_ms for the child's exit_status, DISCARDING any late output
  # in the meantime. For a secret helper (`security`) that late output is the
  # secret value itself — it must never be left in the caller's mailbox, where it
  # would crash a GenServer caller (SetupLive/BootReport) and leak the secret
  # into the crash log. Returns true once the exit_status arrives.
  defp await_exit(port, grace_ms) do
    receive do
      {^port, {:exit_status, _}} -> true
      {^port, {:data, _discard}} -> await_exit(port, grace_ms)
    after
      grace_ms -> false
    end
  end

  # Final non-blocking sweep after Port.close: discard any {port, _} that raced
  # the close so a synchronous caller never receives a stray port message.
  defp flush_port_messages(port) do
    receive do
      {^port, _} -> flush_port_messages(port)
    after
      0 -> :ok
    end
  end

  defp safe_port_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp take_prefix(iodata, max_bytes) do
    iodata
    |> IO.iodata_to_binary()
    |> binary_part(0, min(byte_size(IO.iodata_to_binary(iodata)), max_bytes))
  end

  defp maybe_put_cwd(port_opts, nil), do: port_opts
  defp maybe_put_cwd(port_opts, ""), do: port_opts

  defp maybe_put_cwd(port_opts, cwd) when is_binary(cwd) do
    [{:cd, String.to_charlist(cwd)} | port_opts]
  end

  defp maybe_put_env(port_opts, []), do: port_opts

  defp maybe_put_env(port_opts, env) when is_list(env) do
    encoded =
      Enum.map(env, fn
        {k, v} when is_binary(k) and is_binary(v) ->
          {String.to_charlist(k), String.to_charlist(v)}

        {k, v} when is_list(k) and is_list(v) ->
          {k, v}

        other ->
          raise ArgumentError,
                "CommandRunner env entry must be {String, String}: #{inspect(other)}"
      end)

    [{:env, encoded} | port_opts]
  end

  defp positive_int_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 ->
        value

      other ->
        raise ArgumentError,
              "CommandRunner option #{inspect(key)} must be a positive integer, got: #{inspect(other)}"
    end
  end
end
