defmodule Fermix.CLI.MigrateToApp do
  @moduledoc """
  `fermix migrate-to-app` — the bridge from a Homebrew formula install to the
  unified Fermix macOS application (M34 §4, Homebrew contract).

  `brew uninstall` alone strands the KeepAlive launch agent `fermix setup`
  wrote, pointing at a Cellar binary that no longer exists, so retirement of the
  formula needs one journaled transaction that runs in the operator's own shell
  — which is also the only place a custom `FERMIX_HOME` exported there is
  visible.

  The order is fixed and each step proves the previous one:

      preflight discovery
        → lifecycle.prepare (the single drain lease)
        → strict launchctl bootout
        → verify the original pid exited and the socket was released
        → remove the byte-verified plist
        → write the owner-only handoff journal
        → brew uninstall --formula
        → brew install --cask
        → launch Fermix.app

  Two rules hold the whole thing together. A failure inside the drain window
  releases the lease and exits non-zero with the inspected facts, leaving the
  legacy install exactly as it was — in particular a bootout that launchd
  refused fails the migration rather than proceeding to delete the plist out
  from under a live daemon. And every `brew` step is *executed*, never printed
  as advice: a non-zero exit is reported with brew's own words and stops the
  transaction, because a half-migrated account with a hint in the scrollback is
  the state this command exists to prevent. No path removes a Fermix home.
  """

  alias Fermix.CLI.Daemon.Client
  alias Fermix.CLI.Migrate.Discovery
  alias Fermix.CLI.Migrate.Journal
  alias Fermix.CLI.Service.Launchd

  @formula "fermix"
  @cask "tezra-io/tap/fermix"
  @journal_keys [:home, :journal_dir, :transaction_id, :now]

  # 250 ms × 120 = 30 s, matching the unit's own ExitTimeOut: a legitimate slow
  # drain (an in-flight agent turn, an open browser session) gets exactly the
  # window the plist already tolerates before this call gives up.
  @verify_poll_ms 250
  @verify_polls 120

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv), do: run(argv, [])

  @doc false
  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(argv, deps) when is_list(argv) and is_list(deps) do
    case argv do
      [] -> discover(false, deps)
      ["--yes"] -> discover(true, deps)
      other -> unknown_arguments(other)
    end
  end

  defp discover(confirmed?, deps) do
    case Discovery.capture(deps) do
      {:ok, facts} when confirmed? -> migrate(facts, deps)
      {:ok, facts} -> print_plan(facts)
      {:error, error} -> report_preflight(error)
    end
  end

  defp migrate(facts, deps) do
    with {:ok, lease} <- prepare(facts, deps),
         :ok <- drain(facts, lease, deps),
         :ok <- remove_unit(facts),
         {:ok, _record} <- write_handoff(facts, deps),
         :ok <- swap_package(deps),
         :ok <- launch(facts, deps) do
      report_success(facts, deps)
    else
      {:error, reason} -> report_failure(reason, deps)
    end
  end

  # ── the drain window ───────────────────────────────────────────────────────

  defp prepare(%{daemon_pid: nil}, _deps), do: {:ok, :none}

  defp prepare(_facts, deps) do
    case client(deps).("lifecycle.prepare", %{}, socket_opts(deps)) do
      {:ok, %{"lease_id" => lease_id}} when is_binary(lease_id) -> {:ok, lease_id}
      {:ok, other} -> {:error, {:prepare_failed, other}}
      {:error, reason} -> {:error, {:prepare_failed, reason}}
    end
  end

  # The lease lives exactly as long as the daemon does. Any failure while the
  # daemon may still be serving releases it, so a prepared daemon resumes at
  # once instead of waiting out its TTL; once the stop is verified the process
  # that held the lease is gone and there is nothing left to cancel.
  defp drain(facts, lease, deps) do
    case stop_legacy(facts, lease, deps) do
      :ok -> :ok
      {:error, reason} -> cancel(lease, reason, deps)
    end
  end

  defp stop_legacy(facts, lease, deps) do
    with :ok <- retire(facts, lease, deps), do: verify_stopped(facts, deps)
  end

  # Two configurations, one job. A recognized launch agent is retired by
  # booting the job out — launchd would otherwise KeepAlive-relaunch it — while
  # a daemon running without any unit is stopped by committing its drain lease.
  defp retire(%{unit_sha256: nil}, lease, deps), do: commit(lease, deps)
  defp retire(facts, _lease, _deps), do: Launchd.bootout(:user, facts.unit_path)

  defp commit(:none, _deps), do: :ok

  defp commit(lease_id, deps) do
    case client(deps).("lifecycle.commit", %{"lease_id" => lease_id}, socket_opts(deps)) do
      {:ok, _committed} -> :ok
      {:error, reason} -> {:error, {:commit_failed, reason}}
    end
  end

  defp cancel(:none, reason, _deps), do: {:error, reason}

  defp cancel(lease_id, reason, deps) do
    case client(deps).("lifecycle.cancel", %{"lease_id" => lease_id}, socket_opts(deps)) do
      {:ok, _released} -> {:error, reason}
      {:error, cancel_reason} -> {:error, {:cancel_failed, reason, cancel_reason}}
    end
  end

  defp verify_stopped(facts, deps) do
    sleep = Keyword.get(deps, :sleep, &Process.sleep/1)
    await_stop(facts, deps, sleep, Keyword.get(deps, :verify_polls, @verify_polls))
  end

  # The retire step already ran, so what the operator's machine looks like now
  # depends on which of the two configurations they were in. Carrying that in
  # the reason is the only way `describe/1` can report inspected facts rather
  # than a comforting guess.
  defp await_stop(facts, _deps, _sleep, 0),
    do: {:error, {:daemon_still_running, facts.daemon_pid, facts.socket_path, retired(facts)}}

  defp await_stop(facts, deps, sleep, remaining) do
    if stopped?(facts, deps) do
      :ok
    else
      sleep.(@verify_poll_ms)
      await_stop(facts, deps, sleep, remaining - 1)
    end
  end

  defp retired(%{unit_sha256: nil}), do: :lease_committed
  defp retired(_facts), do: :unit_booted_out

  defp stopped?(facts, deps) do
    pid_exited?(facts, deps) and not File.exists?(facts.socket_path)
  end

  defp pid_exited?(%{daemon_pid: nil}, _deps), do: true

  defp pid_exited?(%{daemon_pid: pid}, deps) do
    {_output, code} = Discovery.run(deps, "kill", ["-0", pid])
    code != 0
  end

  # ── the handoff ────────────────────────────────────────────────────────────

  defp remove_unit(%{unit_sha256: nil}), do: :ok

  defp remove_unit(facts) do
    case File.read(facts.unit_path) do
      {:ok, body} -> remove_verified(facts, body)
      {:error, reason} -> {:error, {:unit_unreadable, facts.unit_path, reason}}
    end
  end

  # Preflight recorded the exact bytes. Anything else on disk now is a unit this
  # transaction never inspected, and it is left alone.
  defp remove_verified(facts, body) do
    if Discovery.sha256(body) == facts.unit_sha256 do
      delete(facts.unit_path)
    else
      {:error, {:unit_changed, facts.unit_path}}
    end
  end

  defp delete(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:unit_remove_failed, path, reason}}
    end
  end

  defp write_handoff(facts, deps) do
    Journal.write(
      %{
        "fermix_home" => facts.fermix_home,
        "source" => %{
          "product_version" => facts.daemon_version,
          "daemon_pid" => facts.daemon_pid,
          "socket_path" => facts.socket_path,
          "unit_path" => facts.unit_path,
          "unit_sha256" => facts.unit_sha256,
          "unit_program" => facts.unit_program,
          "cli_targets" => facts.cli_targets,
          "formula_versions" => facts.formula_versions
        }
      },
      journal_opts(deps)
    )
  end

  defp swap_package(deps) do
    with :ok <- brew(deps, ["uninstall", "--formula", @formula], "formula_uninstalled") do
      brew(deps, ["install", "--cask", @cask], "cask_installed")
    end
  end

  defp brew(deps, args, phase) do
    case Discovery.run(deps, "brew", args) do
      {_output, 0} -> advance(phase, deps)
      {output, code} -> {:error, {:command_failed, "brew " <> Enum.join(args, " "), code, output}}
    end
  end

  defp launch(facts, deps) do
    case Discovery.run(deps, "open", ["-a", facts.app_path]) do
      {_output, 0} -> advance("app_launched", deps)
      {output, code} -> {:error, {:command_failed, "open -a " <> facts.app_path, code, output}}
    end
  end

  defp advance(phase, deps) do
    with {:ok, _record} <- Journal.advance(phase, journal_opts(deps)), do: :ok
  end

  # ── output ─────────────────────────────────────────────────────────────────

  defp print_plan(facts) do
    IO.puts("fermix migrate-to-app would perform this transaction:")
    Enum.each(inspected(facts), &IO.puts("  " <> &1))
    IO.puts("")
    IO.puts("Steps: drain the daemon, boot out and remove the launch agent, write the handoff")
    IO.puts("journal, `brew uninstall --formula #{@formula}`, `brew install --cask #{@cask}`,")
    IO.puts("then launch Fermix.app. Your Fermix home is never removed.")
    IO.puts("")
    IO.puts("Nothing has changed. Re-run as `fermix migrate-to-app --yes` to perform it.")
    2
  end

  defp report_success(facts, deps) do
    IO.puts("Migrated to Fermix.app.")
    IO.puts("  Fermix home preserved: #{facts.fermix_home}")
    IO.puts("  Handoff journal: #{Journal.path(journal_opts(deps))}")
    IO.puts("")
    IO.puts("Fermix.app is opening. Finish in its onboarding: it reads the handoff, keeps this")
    IO.puts("home, registers its background service, and verifies the same data.")
    0
  end

  defp report_preflight({:refused, code, facts, remediation}) do
    IO.puts(:stderr, "fermix migrate-to-app: refused (#{code})")
    Enum.each(facts, &IO.puts(:stderr, "  " <> &1))
    IO.puts(:stderr, remediation)
    1
  end

  defp report_preflight({:probe_failed, description}) do
    IO.puts(:stderr, "fermix migrate-to-app: could not inspect this account — #{description}")
    IO.puts(:stderr, "Nothing has changed. Fix the reported command and re-run.")
    1
  end

  defp report_failure(reason, deps) do
    IO.puts(:stderr, "fermix migrate-to-app: " <> describe(reason))
    Enum.each(recovery(reason, deps), &IO.puts(:stderr, &1))
    1
  end

  defp describe({:launchctl_failed, code, output}) do
    "launchctl refused to boot out the launch agent (launchctl_failed, exit #{code}): " <>
      "#{output}. The launch agent and the daemon are untouched."
  end

  defp describe({:daemon_still_running, pid, socket, :unit_booted_out}) do
    "the daemon did not stop: pid #{pid} is still alive or #{socket} still exists. " <>
      "The launch agent has already been unloaded and its plist was left in place, so the " <>
      "background service stays down until you log in again or run `fermix start`. " <>
      "Nothing was removed."
  end

  defp describe({:daemon_still_running, pid, socket, :lease_committed}) do
    "the daemon did not stop: pid #{pid} is still alive or #{socket} still exists. " <>
      "No launch agent is installed; the daemon was asked to shut down and has not exited. " <>
      "Nothing was removed — stop it yourself and re-run, or start it again with `fermix start`."
  end

  defp describe({:unit_changed, path}) do
    "#{path} changed after preflight, so it was not removed. Re-run to inspect it again."
  end

  defp describe({:unit_unreadable, path, reason}),
    do: "#{path} could not be read (#{inspect(reason)}), so it was not removed."

  defp describe({:unit_remove_failed, path, reason}),
    do: "#{path} could not be removed (#{inspect(reason)})."

  defp describe({:command_failed, command, code, output}),
    do: "`#{command}` failed (exit #{code}): #{String.trim(to_string(output))}"

  defp describe({:prepare_failed, reason}),
    do: "the daemon would not open a drain window: #{Client.describe_error(reason)}"

  defp describe({:commit_failed, reason}),
    do: "the daemon would not commit the drain: #{Client.describe_error(reason)}"

  defp describe({:journal_write_failed, reason}),
    do: "the handoff journal could not be written (#{inspect(reason)})."

  defp describe({:cancel_failed, reason, cancel_reason}) do
    describe(reason) <>
      " The drain lease could not be cancelled either (#{Client.describe_error(cancel_reason)}); " <>
      "a prepared daemon resumes on its own once the lease expires."
  end

  defp describe(reason), do: inspect(reason)

  # The handoff journal exists only from the plist removal onwards, so only the
  # failures that can happen after it get a recovery line — and what that line
  # may name depends on the phase it reached. Once `brew uninstall --formula`
  # has succeeded there is no `fermix` binary on PATH to re-run, so the
  # remediation has to be the cask install itself.
  defp recovery({:command_failed, _command, _code, _output}, deps) do
    [journal_line(deps) | next_step(Journal.read(journal_opts(deps)))]
  end

  defp recovery(_reason, _deps), do: []

  defp journal_line(deps) do
    "The handoff journal at #{Journal.path(journal_opts(deps))} records how far this got."
  end

  defp next_step({:ok, %{"phase" => "handoff_written"}}),
    do: ["The Homebrew formula is still installed, so re-run `fermix migrate-to-app --yes`."]

  defp next_step({:ok, %{"phase" => "formula_uninstalled"}}) do
    [
      "The formula is gone, so there is no `fermix` on your PATH to re-run. Finish with:",
      "  brew install --cask #{@cask}",
      "then open Fermix.app — it reads the journal and keeps your existing Fermix home."
    ]
  end

  defp next_step({:ok, %{"phase" => "cask_installed"}}),
    do: ["Fermix.app is installed. Open it to finish: it reads the journal and keeps your home."]

  defp next_step({:ok, %{"phase" => phase}}),
    do: ["The journal records phase #{phase}; open Fermix.app to finish the handoff."]

  defp next_step({:error, reason}),
    do: ["The journal could not be read (#{inspect(reason)}), so no next step can be named."]

  defp inspected(facts) do
    [
      "Fermix home: #{facts.fermix_home}",
      "launch agent: #{unit_line(facts)}",
      "daemon: #{daemon_line(facts)}",
      "`fermix` on PATH: #{list(facts.cli_targets)}",
      "Homebrew formula: #{list(facts.formula_versions)}",
      "application: #{facts.app_path}"
    ]
  end

  defp unit_line(%{unit_sha256: nil} = facts), do: "#{facts.unit_path} (none installed)"
  defp unit_line(facts), do: "#{facts.unit_path} running #{facts.unit_program}"

  defp daemon_line(%{daemon_pid: nil}), do: "not running"
  defp daemon_line(facts), do: "pid #{facts.daemon_pid}, version #{facts.daemon_version}"

  defp list([]), do: "none"
  defp list(values), do: Enum.join(values, ", ")

  defp unknown_arguments(argv) do
    IO.puts(:stderr, "fermix migrate-to-app: unexpected arguments: #{Enum.join(argv, " ")}")
    IO.puts(:stderr, "Usage: fermix migrate-to-app [--yes]")
    2
  end

  defp client(deps), do: Keyword.get(deps, :client, &Client.request_v1/3)
  defp socket_opts(deps), do: [socket_path: Discovery.socket_path(deps)]
  defp journal_opts(deps), do: Keyword.take(deps, @journal_keys)
end
