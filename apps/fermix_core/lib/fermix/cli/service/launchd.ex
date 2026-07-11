defmodule Fermix.CLI.Service.Launchd do
  @moduledoc """
  launchd backend for `Fermix.CLI.Service`.

  Wraps `launchctl bootstrap | bootout | kickstart | kill` against the
  user (`gui/<uid>`) or system (`system`) domain. Each call shells
  out and returns `{:error, {:launchctl_failed, code, output}}` on
  non-zero exit so the caller can surface the failure verbatim.
  """

  @spec install(map()) :: :ok | {:error, term()}
  def install(%{scope: scope, unit_path: path}) do
    with :ok <- bootout_if_loaded(scope, path) do
      launchctl(["bootstrap", domain(scope), path])
    end
  end

  @spec uninstall(map()) :: :ok | {:error, term()}
  def uninstall(%{scope: scope, unit_path: path}) do
    bootout_if_loaded(scope, path)
  end

  # Plain `kickstart` (no `-k`): `-k` SIGKILLs the running instance, which under
  # `fermix restart`/`upgrade` killed the daemon mid-drain (launchctl last-exit
  # -9) and, with KeepAlive=true, produced a relaunch loop. Without `-k`,
  # `start` is idempotent (no-op if already running); graceful restart comes
  # from `stop` (SIGTERM) + KeepAlive relaunch. A drifted-unit reconcile still
  # swaps the plist via install's bootout+bootstrap, not via start.
  @spec start(map()) :: :ok | {:error, term()}
  def start(%{scope: scope, label: label}) do
    launchctl(["kickstart", "#{domain(scope)}/#{label}"])
  end

  # `stop` must GUARANTEE the running instance is gone, not merely that launchd
  # ACCEPTED the signal. `launchctl kill TERM` returns success the instant the signal
  # is delivered; if the BEAM's orderly shutdown stalls (a draining agent turn, an
  # open browser/computer-use session, a hung socket) the old process keeps running —
  # and because `kill` is an out-of-band signal, not a job stop, the plist's
  # ExitTimeOut SIGKILL backstop never arms. So: capture the pid, send SIGTERM, wait a
  # bounded grace for it to actually exit, escalate to SIGKILL, and only report :ok
  # once the ORIGINAL pid is confirmed gone (KeepAlive then relaunches the new binary).
  # Without this, `fermix restart`/`upgrade` silently no-op against a wedged daemon.
  @spec stop(map()) :: :ok | {:error, term()}
  def stop(%{scope: scope, label: label} = spec) do
    job = "#{domain(scope)}/#{label}"

    case job_pid(spec) do
      nil ->
        # No running instance (or launchd reports no pid) — a plain TERM is a
        # harmless no-op; there is nothing to escalate against.
        _ = launchctl(["kill", "TERM", job])
        :ok

      pid ->
        _ = launchctl(["kill", "TERM", job])
        terminate(spec, job, pid)
    end
  end

  # SIGTERM already sent: wait the grace for the original pid to exit, then escalate.
  defp terminate(spec, job, pid) do
    {_poll_ms, term_grace_ms, _kill_grace_ms, _sleep} = stop_config()

    case await_exit(spec, pid, term_grace_ms) do
      :exited -> :ok
      :alive -> force_kill(spec, job, pid)
    end
  end

  # The BEAM's orderly shutdown stalled past the grace — SIGKILL it, and fail loud
  # only if even that leaves the original pid alive.
  defp force_kill(spec, job, pid) do
    {_poll_ms, _term_grace_ms, kill_grace_ms, _sleep} = stop_config()
    _ = launchctl(["kill", "KILL", job])

    case await_exit(spec, pid, kill_grace_ms) do
      :exited -> :ok
      :alive -> {:error, {:stop_failed, pid}}
    end
  end

  # The job's current OS pid via `launchctl print`, or nil when it isn't running
  # (unloaded, or momentarily between a KeepAlive relaunch). Routed through the same
  # launchctl seam as every other call, so it stays test-injectable.
  defp job_pid(%{scope: scope, label: label}) do
    case launchctl_output(["print", "#{domain(scope)}/#{label}"]) do
      {:ok, output} -> parse_pid(output)
      {:error, _} -> nil
    end
  end

  defp parse_pid(output) do
    case Regex.run(~r/\bpid\s*=\s*(\d+)/, output) do
      [_, pid] -> String.to_integer(pid)
      _ -> nil
    end
  end

  # The original process has exited once the job no longer runs under `pid`: it is
  # either gone (nil) or KeepAlive has already relaunched the NEW binary under a
  # different pid. Polls up to `grace_ms`, then reports it is still :alive.
  defp await_exit(spec, pid, grace_ms) do
    {poll_ms, _t, _k, sleep} = stop_config()
    polls = max(1, div(grace_ms, poll_ms))

    Enum.reduce_while(1..polls, :alive, fn i, _acc ->
      cond do
        job_pid(spec) != pid ->
          {:halt, :exited}

        i == polls ->
          {:halt, :alive}

        true ->
          sleep.(poll_ms)
          {:cont, :alive}
      end
    end)
  end

  # Poll cadence + grace windows + the sleep fn, injectable for tests (real waits
  # would make the suite sleep for the full grace). The default SIGTERM grace matches
  # the unit's `ExitTimeOut` (templates.ex, 30s) so a legitimate slow drain (an
  # in-flight agent turn, an open browser/computer-use session) isn't force-killed
  # sooner than the plist itself would tolerate.
  defp stop_config do
    cfg = Application.get_env(:fermix_core, :launchd_stop, [])

    {
      Keyword.get(cfg, :poll_ms, 500),
      Keyword.get(cfg, :term_grace_ms, 30_000),
      Keyword.get(cfg, :kill_grace_ms, 3_000),
      Keyword.get(cfg, :sleep_fun, &Process.sleep/1)
    }
  end

  defp bootout_if_loaded(scope, path) do
    case launchctl(["bootout", domain(scope), path], expect_existing: false) do
      :ok -> :ok
      {:error, {:launchctl_failed, _, _}} -> :ok
    end
  end

  defp domain(:user), do: "gui/#{user_uid()}"
  defp domain(:system), do: "system"

  defp user_uid do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, code} -> raise RuntimeError, "id -u failed (#{code}): #{out}"
    end
  end

  defp launchctl(args, _opts \\ []) do
    case launchctl_output(args) do
      {:ok, _out} -> :ok
      error -> error
    end
  end

  # Like `launchctl/2` but returns the command output (needed to read `print`).
  defp launchctl_output(args) do
    case launchctl_runner().("launchctl", Enum.map(args, &to_string/1)) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {:launchctl_failed, code, String.trim(out)}}
    end
  end

  # Injectable for tests (mirrors the `:secret_writer` seam); defaults to the
  # real `launchctl` shell-out. The runner takes (command, args) → {output, code}.
  defp launchctl_runner do
    Application.get_env(:fermix_core, :launchctl_runner, &default_launchctl/2)
  end

  defp default_launchctl(command, args) do
    System.cmd(command, args, stderr_to_stdout: true)
  end
end
