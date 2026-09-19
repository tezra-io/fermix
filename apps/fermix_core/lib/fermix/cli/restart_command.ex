defmodule Fermix.CLI.RestartCommand do
  @moduledoc """
  `fermix restart` — restart the daemon.

  Three configurations, three paths, one job.

  **Standalone:** restarts the installed OS service. Refuses on uninstalled
  hosts (no implicit install) and surfaces scope mismatches the same way
  `start`/`stop` do, so `--user` against a `--system` install fails with a clear
  pointer instead of looking like a no-op restart.

  **App-managed (M34 §4):** follows the app-owned restart contract without
  creating legacy units — prepare and commit the drain lease, then wait for a
  *different* pid to answer `hello`. Registration is never touched, so launchd
  brings the agent back on its own. There is no legacy branch to fall through
  to: an app-managed engine refuses `fermix service install`, so the standalone
  "no service installed, run `fermix service install` first" message would send
  the operator round a loop with no exit.

  **Packaged (M38 §4.1):** systemd owns the termination signal, so this CLI
  never stops and starts anything itself. It takes the admission lease from the
  generation being replaced, resets the start budget, issues one `systemctl
  --user restart`, waits for a different generation and reports the typed
  alignment. `--json` prints the shared envelope; `--when-idle` is refused with
  a sentence until protocol 3 publishes `lifecycle.prepare_idle`, because a mode
  that silently interrupted work would be the opposite of what it asked for.
  """

  alias Fermix.CLI.Daemon.Client
  alias Fermix.CLI.MachineOutput
  alias Fermix.CLI.Service
  alias Fermix.CLI.ServiceCommand
  alias FermixCore.BuildInfo

  @switches [user: :boolean, system: :boolean]
  @packaged_switches [json: :boolean, when_idle: :boolean]

  # 250 ms × 120 = 30 s. A restarting daemon has to stop, be relaunched by
  # launchd, boot its supervision tree, and bind the socket; this is the same
  # window the migration allows for a drain.
  @poll_interval_ms 250
  @verify_polls 120

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv), do: run(argv, [])

  @doc false
  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(argv, deps) when is_list(argv) and is_list(deps) do
    build_info = Keyword.get(deps, :build_info, BuildInfo)

    cond do
      build_info.distribution_identity() == "linux_package" -> restart_packaged(argv, deps)
      build_info.app_engine?() -> restart_app_managed(deps)
      true -> restart_legacy(argv, deps)
    end
  end

  # ── packaged ───────────────────────────────────────────────────────────────

  defp restart_packaged(argv, deps) do
    case OptionParser.parse(argv, strict: @packaged_switches) do
      {opts, [], []} -> packaged_mode(opts, deps)
      {_opts, [extra | _rest], []} -> usage("unexpected argument: #{extra}")
      {_opts, _argv, invalid} -> usage("invalid options: #{inspect(invalid)}")
    end
  end

  defp packaged_mode(opts, deps) do
    json? = Keyword.get(opts, :json, false)

    # Deferred and recorded (M38 §4.1): published protocol 1 and 2 have no
    # `lifecycle.prepare_idle`, so the only restart this engine can perform is
    # the interrupting one. Saying so is the whole answer — quietly running the
    # interrupting restart instead would be the opposite of what was asked.
    if Keyword.get(opts, :when_idle, false) do
      refuse(:idle_restart_unavailable, [], json?)
    else
      run_packaged(json?, deps)
    end
  end

  defp run_packaged(json?, deps) do
    service = Keyword.get(deps, :service, Service)

    case service.restart(:user, Keyword.get(deps, :service_opts, [])) do
      {:ok, result} -> report_packaged(result, json?)
      {:error, reason} -> refuse_reason(reason, json?, deps)
    end
  end

  defp report_packaged(result, true) do
    IO.puts(MachineOutput.ok(result))
    0
  end

  defp report_packaged(result, false) do
    IO.puts(
      "fermix restart: daemon restarted (pid #{result["pid"]}, was " <>
        "#{result["previous_pid"] || "not running"}, engine #{result["alignment"]})."
    )

    0
  end

  defp refuse_reason(reason, json?, deps) do
    case ServiceCommand.published_reason(reason, deps) do
      {code, details} -> refuse(code, details, json?)
      :untyped -> refuse_untyped(ServiceCommand.format_reason(reason), json?)
    end
  end

  defp refuse(code, details, true) do
    IO.puts(MachineOutput.error(code, details))
    1
  end

  defp refuse(code, details, false) do
    abort(MachineOutput.sentence(code, details))
  end

  defp refuse_untyped(sentence, true) do
    IO.puts(MachineOutput.error(:systemctl_failed, output: sentence))
    1
  end

  defp refuse_untyped(sentence, false), do: abort(sentence)

  defp usage(message) do
    IO.puts(:stderr, "fermix restart: #{message}")
    IO.puts(:stderr, "Usage: fermix restart [--json] [--when-idle]")
    2
  end

  # ── app-managed ────────────────────────────────────────────────────────────

  defp restart_app_managed(deps) do
    with {:ok, previous_pid} <- current_pid(deps),
         {:ok, lease_id} <- prepare(deps),
         :ok <- commit(lease_id, deps),
         {:ok, new_pid} <- await_new_pid(previous_pid, deps) do
      IO.puts("fermix restart: daemon restarted (pid #{new_pid}).")
      0
    else
      {:error, reason} -> abort(describe(reason))
    end
  end

  defp current_pid(deps) do
    case hello(deps) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {:no_daemon, reason}}
    end
  end

  defp hello(deps) do
    case client(deps).("hello", %{}, []) do
      {:ok, %{"engine" => %{"pid" => pid}}} when is_binary(pid) -> {:ok, pid}
      {:ok, _other} -> {:error, :invalid_management_response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare(deps) do
    case client(deps).("lifecycle.prepare", %{}, []) do
      {:ok, %{"lease_id" => lease_id}} when is_binary(lease_id) -> {:ok, lease_id}
      {:ok, _other} -> {:error, {:prepare_failed, :invalid_management_response}}
      {:error, reason} -> {:error, {:prepare_failed, reason}}
    end
  end

  defp commit(lease_id, deps) do
    case client(deps).("lifecycle.commit", %{"lease_id" => lease_id}, []) do
      {:ok, _committed} -> :ok
      {:error, reason} -> {:error, {:commit_failed, reason}}
    end
  end

  # A daemon answering with the SAME pid has not restarted yet — the commit
  # replies before the VM stops, so the old process can still be serving.
  defp await_new_pid(previous_pid, deps) do
    sleep = Keyword.get(deps, :sleep, &Process.sleep/1)
    poll(previous_pid, deps, sleep, Keyword.get(deps, :verify_polls, @verify_polls))
  end

  defp poll(previous_pid, _deps, _sleep, 0), do: {:error, {:no_new_daemon, previous_pid}}

  defp poll(previous_pid, deps, sleep, remaining) do
    sleep.(@poll_interval_ms)

    case hello(deps) do
      {:ok, pid} when pid != previous_pid -> {:ok, pid}
      _same_or_down -> poll(previous_pid, deps, sleep, remaining - 1)
    end
  end

  defp describe({:no_daemon, _reason}) do
    "the daemon is not answering, and an app-managed engine is restarted through the app. " <>
      "Open Fermix.app and use its background service controls."
  end

  defp describe({:prepare_failed, reason}),
    do: "the daemon would not open a drain window: #{Client.describe_error(reason)}"

  defp describe({:commit_failed, reason}),
    do: "the daemon would not commit the drain: #{Client.describe_error(reason)}"

  defp describe({:no_new_daemon, previous_pid}) do
    "the daemon stopped but did not come back (it was pid #{previous_pid}). " <>
      "Open Fermix.app and enable the background service from there."
  end

  defp client(deps), do: Keyword.get(deps, :client, &Client.request_v1/3)

  # ── standalone ─────────────────────────────────────────────────────────────

  defp restart_legacy(argv, deps) do
    service = Keyword.get(deps, :service, Service)

    case ServiceCommand.parse_scope(argv, @switches) do
      {:ok, scope} -> dispatch(scope, service)
      {:error, reason} -> abort(reason)
    end
  end

  defp dispatch(scope, service) do
    cond do
      service.installed?(scope) ->
        ServiceCommand.run_action(
          fn selected_scope -> service.restart(selected_scope) end,
          scope,
          "restarted",
          "fermix restart"
        )

      service.installed?(other_scope(scope)) ->
        abort(
          "no #{scope}-scope unit installed; the #{other_scope(scope)}-scope unit is. " <>
            "Use `fermix restart --#{other_scope(scope)}`."
        )

      true ->
        abort("no service installed. Run `fermix service install` first.")
    end
  end

  defp other_scope(:user), do: :system
  defp other_scope(:system), do: :user

  defp abort(message) do
    IO.puts(:stderr, "fermix restart: #{message}")
    1
  end
end
