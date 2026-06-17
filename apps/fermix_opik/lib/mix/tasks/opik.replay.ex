defmodule Mix.Tasks.Opik.Replay do
  @shortdoc "Replay Fermix JSONL traces into Opik"
  @moduledoc """
  Replays historical Fermix traces from disk into Opik.

  Reads the JSONL trace files Fermix writes, reassembles them into Opik
  traces/spans (reusing the same logic as the live exporter), and posts them.
  Useful for evaluating past runs or backfilling Opik after an e2e session.

      mix opik.replay --dir ~/.fermix-dev/traces --project fermix
      mix opik.replay --dir ~/.fermix/traces --base-url http://localhost:5173/api

  Options:
    --dir       Trace directory (default: $FERMIX_TRACE_DIR or ~/.fermix/traces)
    --project   Opik project name (default: $FERMIX_OPIK_PROJECT or "fermix")
    --base-url  Opik REST base (default: $FERMIX_OPIK_BASE_URL or http://localhost:5173/api)
    --dry-run   Reassemble and report counts without posting to Opik
  """
  use Mix.Task

  alias FermixOpik.Aggregation
  alias FermixOpik.Client
  alias FermixOpik.TraceFile

  @switches [dir: :string, project: :string, base_url: :string, dry_run: :boolean]

  @impl true
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    {:ok, _apps} = Application.ensure_all_started(:req)

    dir = opts[:dir] || System.get_env("FERMIX_TRACE_DIR") || Path.expand("~/.fermix/traces")
    project = opts[:project] || System.get_env("FERMIX_OPIK_PROJECT") || "fermix"

    config = %{
      base_url:
        opts[:base_url] || System.get_env("FERMIX_OPIK_BASE_URL") || "http://localhost:5173/api",
      api_key: System.get_env("FERMIX_OPIK_API_KEY"),
      workspace: System.get_env("FERMIX_OPIK_WORKSPACE")
    }

    unless File.dir?(dir), do: Mix.raise("trace directory not found: #{dir}")

    traces = assemble(dir, project)
    Mix.shell().info("Reassembled #{length(traces)} trace(s) from #{dir}")

    if opts[:dry_run], do: report(traces), else: ship(traces, config)
  end

  defp assemble(dir, project) do
    events = TraceFile.read_events(dir)

    # Replay never sweeps (it drains at the end), so the TTL only needs to be
    # large enough never to matter.
    agg = Aggregation.new(project: project, ttl_ms: 86_400_000)

    {agg, closed} =
      Enum.reduce(events, {agg, []}, fn {event, meas, meta, at}, {acc_agg, acc} ->
        at_ctx = %{at: at, mono: DateTime.to_unix(at, :microsecond)}
        {acc_agg, new} = Aggregation.apply_event(acc_agg, event, meas, meta, at_ctx)
        {acc_agg, acc ++ new}
      end)

    {_agg, drained} = Aggregation.drain(agg)
    closed ++ drained
  end

  defp report(traces) do
    span_total = Enum.reduce(traces, 0, fn %{spans: spans}, sum -> sum + length(spans) end)
    Mix.shell().info("Dry run: #{length(traces)} traces, #{span_total} spans (not posted)")
  end

  defp ship(traces, config) do
    {ok, failed} =
      Enum.reduce(traces, {0, 0}, fn closed, {ok, failed} ->
        case Client.send_trace(config, closed) do
          :ok -> {ok + 1, failed}
          {:error, _reason} -> {ok, failed + 1}
        end
      end)

    Mix.shell().info("Posted #{ok} trace(s) to Opik (#{failed} failed)")
    if failed > 0, do: exit({:shutdown, 1})
  end
end
