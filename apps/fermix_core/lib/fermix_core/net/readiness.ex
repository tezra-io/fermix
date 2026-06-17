defmodule FermixCore.Net.Readiness do
  @moduledoc """
  Bounded network-readiness gate for scheduled runs.

  On a macOS host the first outbound request just after wake-from-sleep can
  hit a dead local network — DNS and routes are not up yet — and a cron LLM
  call then fails on a pool-checkout timeout (`:connection_unavailable`). This
  module polls a cheap TCP connect against the run's primary-route host until
  it succeeds or a bounded budget elapses, so the agent loop starts only once
  the network is actually reachable.

  It is advisory, not a failover: when the budget is exhausted it returns
  `:unready` and the caller proceeds anyway (the runner's transient-backoff
  retry remains the floor). It never blocks unbounded.
  """

  require Logger

  @default_interval_ms 1_000
  @default_budget_ms 15_000
  @default_connect_timeout_ms 2_000

  @type probe_fn :: (String.t(), :inet.port_number(), timeout() -> :ok | {:error, term()})

  @doc """
  Poll until `host:port` accepts a TCP connection or the budget elapses.

  Returns `:ready` as soon as a probe succeeds, or `:unready` once the next
  backoff would overrun `:budget_ms` (the caller proceeds regardless).

  Options:

    * `:interval_ms` — backoff between probes (default #{@default_interval_ms}).
    * `:budget_ms` — total wait ceiling (default #{@default_budget_ms}).
    * `:connect_timeout_ms` — per-probe connect timeout (default
      #{@default_connect_timeout_ms}).
    * `:probe_fn` — arity-3 probe `(host, port, timeout -> :ok | {:error, _})`,
      injected by tests; production uses a `:gen_tcp` connect.
    * `:delay_fn` — sleep function, injected by tests.
  """
  @spec await(String.t(), :inet.port_number(), keyword()) :: :ready | :unready
  def await(host, port, opts \\ [])
      when is_binary(host) and is_integer(port) and port > 0 do
    cfg = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      budget_ms: Keyword.get(opts, :budget_ms, @default_budget_ms),
      timeout_ms: Keyword.get(opts, :connect_timeout_ms, @default_connect_timeout_ms),
      probe_fn: Keyword.get(opts, :probe_fn, &tcp_probe/3),
      delay_fn: Keyword.get(opts, :delay_fn, &Process.sleep/1)
    }

    poll(host, port, 0, cfg)
  end

  defp poll(host, port, waited_ms, cfg) do
    case cfg.probe_fn.(host, port, cfg.timeout_ms) do
      :ok -> :ready
      {:error, _reason} -> backoff_or_give_up(host, port, waited_ms, cfg)
    end
  end

  defp backoff_or_give_up(host, port, waited_ms, cfg) do
    if waited_ms + cfg.interval_ms > cfg.budget_ms do
      Logger.warning(
        "Network readiness probe for #{host}:#{port} did not succeed within " <>
          "#{cfg.budget_ms}ms budget; proceeding anyway"
      )

      :unready
    else
      cfg.delay_fn.(cfg.interval_ms)
      poll(host, port, waited_ms + cfg.interval_ms, cfg)
    end
  end

  defp tcp_probe(host, port, timeout_ms) do
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], timeout_ms) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
