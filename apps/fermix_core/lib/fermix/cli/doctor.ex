defmodule Fermix.CLI.Doctor do
  @moduledoc """
  `fermix doctor [--full]` — post-install diagnostics.

  Aggregates checks from `Fermix.CLI.Doctor.Checks` into a single
  human-readable report. Returns:

  - exit `0` when no checks failed (warnings allowed)
  - exit `1` when at least one check failed

  A check the running distribution does not have reports `not_applicable`. It
  is counted separately from `ok`, because nothing was verified, and it never
  fails the run.

  `--full` opts into checks that hit the network — the binary-integrity
  check (fetches `releases.json` and compares sha256 against the manifest
  entry for the host's target), the upgrade-availability check, the
  provider auth probe, channel health probes, the web-search live probe, and
  one metered `place_search` probe.

  On an app-managed macOS engine the checks run in the daemon instead
  (M34 §4): `Fermix.CLI.Doctor.Remote` drives `doctor.start` / `doctor.get`
  and this module never evaluates a check locally. There is no local
  reattempt when the daemon is unreachable — a check run in the CLI process
  would inspect a different world than the daemon runs in, so the command says
  the daemon is down and names the surface that can start it.
  """

  alias Fermix.CLI.Daemon.Client
  alias Fermix.CLI.Doctor.Checks
  alias Fermix.CLI.Doctor.Remote
  alias FermixCore.BuildInfo

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv), do: run(argv, [])

  @doc false
  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(argv, deps) when is_list(argv) and is_list(deps) do
    case OptionParser.parse(argv, strict: [full: :boolean]) do
      {opts, _, []} -> dispatch(opts, deps)
      {_, _, invalid} -> abort("invalid options: #{inspect(invalid)}")
    end
  end

  defp dispatch(opts, deps) do
    build_info = Keyword.get(deps, :build_info, BuildInfo)
    full? = Keyword.get(opts, :full, false)

    if build_info.app_engine?() do
      run_remote(scopes(full?), deps)
    else
      run_local(full?, deps)
    end
  end

  defp scopes(true), do: [:local, :network]
  defp scopes(false), do: [:local]

  defp run_remote(scopes, deps) do
    Enum.reduce_while(scopes, 0, fn scope, worst ->
      case Remote.run(scope, deps) do
        {:ok, status} -> {:cont, max(worst, status)}
        {:error, reason} -> {:halt, abort(remote_message(reason))}
      end
    end)
  end

  defp remote_message(:not_running) do
    "the daemon is not running, and an app-managed engine runs its checks there. " <>
      "Open Fermix.app and enable the background service."
  end

  defp remote_message(:doctor_session_unfinished) do
    "the daemon did not finish the check run within its own budget. " <>
      "Retry, and use Fermix.app's Doctor screen if it keeps happening."
  end

  defp remote_message(reason), do: Client.describe_error(reason)

  defp run_local(full?, deps) do
    collect = Keyword.get(deps, :collect_results, &collect_results/1)
    if full?, do: ensure_http_pool()
    results = collect.(full?)
    print_report(results)
    exit_for(results)
  end

  # `--full` live probes (provider auth, channels, web search) route through
  # `FermixCore.Net.HttpClient`, which pins the shared `FermixCore.Finch`
  # pool. The daemon supervision tree owns that pool, but `fermix doctor`
  # runs in the tree-less CLI dispatch — bring the pool up here (a no-op when
  # a tree is already running, e.g. under `mix test`), mirroring
  # `mix fermix.eval.transcription`.
  defp ensure_http_pool do
    if Process.whereis(FermixCore.Finch) == nil do
      {:ok, _pid} =
        Finch.start_link(name: FermixCore.Finch, pools: FermixCore.Application.finch_pools())
    end

    :ok
  end

  defp collect_results(full?) do
    base = [
      Checks.readiness(),
      Checks.fallback_providers(),
      Checks.workspace_layout(),
      Checks.service_unit(),
      Checks.daemon_socket(),
      Checks.opik_readiness(),
      Checks.recent_log_activity(),
      Checks.compaction_config(),
      Checks.bootstrap_template_drift(),
      Checks.routing_overrides(),
      Checks.command_owner_config(),
      Checks.streaming_config(),
      Checks.sandbox_config(),
      Checks.sandbox_trace_suggestions(),
      Checks.auth_file_permissions(),
      Checks.home_permissions(),
      Checks.cosign(),
      Checks.auth_token_expiry(),
      Checks.plaintext_secrets(),
      Checks.linger(),
      Checks.web_search(full?),
      Checks.place_search(),
      Checks.image_generation(),
      Checks.transcription(),
      Checks.meetings(),
      Checks.realtime(),
      Checks.mobile(),
      Checks.acp(),
      Checks.computer_use_permissions(),
      Checks.computer_history(),
      Checks.browser_disclaim(),
      Checks.harness(),
      Checks.skill_curation(),
      Checks.plugins()
    ]

    network =
      if full?,
        do: [
          Checks.binary_integrity(),
          Checks.upgrade_available?(),
          Checks.auth_probe(),
          Checks.channel_health(),
          Checks.place_probe()
        ],
        else: []

    Enum.reject(base ++ network, &is_nil/1)
  end

  @doc false
  @spec print_report([Checks.result()]) :: :ok
  def print_report(results) when is_list(results) do
    IO.puts("fermix doctor")
    IO.puts(String.duplicate("-", 60))

    Enum.each(results, fn %{name: name, status: status, detail: detail} ->
      IO.puts("[#{format_status(status)}] #{String.pad_trailing(name, 18)}  #{detail}")
    end)

    IO.puts("")
    summary = Enum.frequencies_by(results, & &1.status)
    ok = Map.get(summary, :ok, 0)
    warn = Map.get(summary, :warn, 0)
    fail = Map.get(summary, :fail, 0)
    not_applicable = Map.get(summary, :not_applicable, 0)

    IO.puts("#{ok} ok, #{warn} warning(s), #{fail} failure(s), #{not_applicable} not applicable")
  end

  # `:not_applicable` is not a pass: the check never ran because this
  # distribution does not have it. It cannot fail the run either.
  @doc false
  @spec exit_for([Checks.result()]) :: non_neg_integer()
  def exit_for(results) when is_list(results) do
    if Enum.any?(results, &(&1.status == :fail)), do: 1, else: 0
  end

  defp format_status(:ok), do: " OK "
  defp format_status(:warn), do: "WARN"
  defp format_status(:fail), do: "FAIL"
  defp format_status(:not_applicable), do: "N/A "

  defp abort(message) do
    IO.puts(:stderr, "fermix doctor: #{message}")
    1
  end
end
