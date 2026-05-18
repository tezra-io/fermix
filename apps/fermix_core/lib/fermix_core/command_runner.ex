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

  @type opts :: [
          {:cwd, String.t() | nil}
          | {:env, [{String.t() | charlist(), String.t() | charlist()}]}
          | {:timeout_ms, pos_integer()}
          | {:max_output_bytes, pos_integer()}
          | {:kill_grace_ms, pos_integer()}
        ]

  @type result :: %{exit: integer(), stdout: binary(), truncated?: boolean()}
  @type reason ::
          {:timeout, pos_integer()}
          | {:executable_not_found, String.t()}
          | {:port_failed, term()}
          | term()

  @default_timeout_ms 30_000
  @default_max_output_bytes 1_048_576
  @default_kill_grace_ms 200

  @spec run(String.t(), [String.t()], opts()) :: {:ok, result()} | {:error, reason()}
  def run(executable, args, opts \\ [])
      when is_binary(executable) and is_list(args) and is_list(opts) do
    timeout_ms = positive_int_opt(opts, :timeout_ms, @default_timeout_ms)
    max_output_bytes = positive_int_opt(opts, :max_output_bytes, @default_max_output_bytes)
    kill_grace_ms = positive_int_opt(opts, :kill_grace_ms, @default_kill_grace_ms)

    if File.exists?(executable) do
      do_run(executable, args, opts, %{
        timeout_ms: timeout_ms,
        max_output_bytes: max_output_bytes,
        kill_grace_ms: kill_grace_ms
      })
    else
      {:error, {:executable_not_found, executable}}
    end
  end

  defp do_run(executable, args, opts, limits) do
    port_opts =
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: args
      ]
      |> maybe_put_cwd(Keyword.get(opts, :cwd))
      |> maybe_put_env(Keyword.get(opts, :env, []))

    port = Port.open({:spawn_executable, executable}, port_opts)
    os_pid = Port.info(port, :os_pid) |> elem(1)
    deadline = System.monotonic_time(:millisecond) + limits.timeout_ms

    collect(port, os_pid, deadline, limits, [], 0)
  end

  defp collect(port, os_pid, deadline, limits, acc, total) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        new_total = total + byte_size(chunk)

        if new_total > limits.max_output_bytes do
          kill_and_drain(port, os_pid, limits)
          {:ok, %{exit: 124, stdout: take_prefix(acc, limits.max_output_bytes), truncated?: true}}
        else
          collect(port, os_pid, deadline, limits, [acc | chunk], new_total)
        end

      {^port, {:exit_status, exit_code}} ->
        {:ok, %{exit: exit_code, stdout: IO.iodata_to_binary(acc), truncated?: false}}
    after
      remaining ->
        kill_and_drain(port, os_pid, limits)
        {:error, {:timeout, limits.timeout_ms}}
    end
  end

  defp kill_and_drain(port, os_pid, %{kill_grace_ms: grace_ms}) do
    _ = os_signal(os_pid, "TERM")

    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      grace_ms ->
        _ = os_signal(os_pid, "KILL")

        receive do
          {^port, {:exit_status, _}} -> :ok
        after
          grace_ms ->
            # SIGKILL is non-blockable by the child; if we did not receive
            # the exit_status it means the port has already been reaped
            # elsewhere. Close defensively and move on.
            _ = safe_port_close(port)
        end
    end
  end

  defp safe_port_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp os_signal(pid, signal) when is_integer(pid) and is_binary(signal) do
    case System.cmd("kill", ["-" <> signal, Integer.to_string(pid)], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {_out, _code} -> :no_such_process
    end
  rescue
    error -> {:error, error}
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
          raise ArgumentError, "CommandRunner env entry must be {String, String}: #{inspect(other)}"
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
