defmodule Fermix.CLI.RestartCommand do
  @moduledoc """
  `fermix restart` — restart the daemon.

  Two configurations, two paths, one job.

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
  """

  alias Fermix.CLI.Daemon.Client
  alias Fermix.CLI.Service
  alias Fermix.CLI.ServiceCommand
  alias FermixCore.BuildInfo

  @switches [user: :boolean, system: :boolean]

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

    if build_info.app_engine?() do
      restart_app_managed(deps)
    else
      restart_legacy(argv, deps)
    end
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
