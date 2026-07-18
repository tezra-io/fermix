defmodule Fermix.CLI.Doctor do
  @moduledoc """
  `fermix doctor [--full]` — post-install diagnostics.

  Aggregates checks from `Fermix.CLI.Doctor.Checks` into a single
  human-readable report. Returns:

  - exit `0` when no checks failed (warnings allowed)
  - exit `1` when at least one check failed

  `--full` opts into checks that hit the network — the binary-integrity
  check (fetches `releases.json` and compares sha256 against the manifest
  entry for the host's target), the upgrade-availability check, the
  provider auth probe, channel health probes, and the web-search live probe.
  """

  alias Fermix.CLI.Doctor.Checks

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) do
    case OptionParser.parse(argv, strict: [full: :boolean]) do
      {opts, _, []} -> dispatch(opts)
      {_, _, invalid} -> abort("invalid options: #{inspect(invalid)}")
    end
  end

  defp dispatch(opts) do
    full? = Keyword.get(opts, :full, false)
    if full?, do: ensure_http_pool()
    results = collect_results(full?)
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
      Checks.auth_token_expiry(),
      Checks.plaintext_secrets(),
      Checks.linger(),
      Checks.web_search(full?),
      Checks.image_generation(),
      Checks.transcription(),
      Checks.realtime(),
      Checks.computer_use_permissions()
    ]

    network =
      if full?,
        do: [
          Checks.binary_integrity(),
          Checks.upgrade_available?(),
          Checks.auth_probe(),
          Checks.channel_health()
        ],
        else: []

    Enum.reject(base ++ network, &is_nil/1)
  end

  defp print_report(results) do
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

    IO.puts("#{ok} ok, #{warn} warning(s), #{fail} failure(s)")
  end

  defp exit_for(results) do
    if Enum.any?(results, &(&1.status == :fail)), do: 1, else: 0
  end

  defp format_status(:ok), do: " OK "
  defp format_status(:warn), do: "WARN"
  defp format_status(:fail), do: "FAIL"

  defp abort(message) do
    IO.puts(:stderr, "fermix doctor: #{message}")
    1
  end
end
