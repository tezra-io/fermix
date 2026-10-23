defmodule FermixCore.Cues.Sweeper do
  @moduledoc """
  The cue inbox's retention and expiry sweeps (design §7.4), every 60 s, last
  in `Cues.Supervisor`, so a crash in sweep logic restarts nothing else.

  A pass runs the steps of `@steps` in order, each in chunks of 1,000 rows,
  within a 250 ms budget: once the budget is spent the pass stops and the next
  tick resumes from the first step. `filtering` and `claimed` deliveries are
  never touched here.

  The first sweep comes after a delay, never from `init`. `timer?: false`
  disables the timer; tests then drive `sweep/2` by hand with their own `now`.
  """

  use GenServer

  require Logger

  alias FermixCore.Cues.Telemetry
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixCore.Timeouts

  @first_sweep_ms 5_000
  @interval_ms 60_000
  @budget_ms 250
  @chunk 1_000
  @max_chunks_per_step 50

  # Every step, in order: `{name, function}`, each function called as
  # `function.(repo_opts, now, limit) :: {:ok, rows_touched} | {:error, reason}`.
  @steps [
    {:expire_lifetime, &__MODULE__.expire_lifetime/3},
    {:mark_terminal, &__MODULE__.mark_terminal/3},
    {:drop_payloads, &__MODULE__.drop_payloads/3},
    {:drop_snapshots, &__MODULE__.drop_snapshots/3},
    {:prune_deliveries, &__MODULE__.prune_deliveries/3},
    {:delete_receipts, &__MODULE__.delete_receipts/3},
    {:prune_gaps, &__MODULE__.prune_gaps/3},
    {:prune_filter_calls, &__MODULE__.prune_filter_calls/3},
    {:gap_notices, &FermixCore.Cues.Notices.sweep_gaps/3},
    # A waiting proposal past its expiry becomes `expired`; a confirmed one
    # that never reported its result (a crash or restart mid-call) is reported
    # to the owner once as an unknown outcome, and never run (M60 §10.9).
    {:proposal_expiry, &FermixCore.Cues.Proposals.expire/3},
    {:proposal_unknown_outcomes, &FermixCore.Cues.Proposals.report_unknown/3},
    # An allowed call in auto mode that never reported, once its run ended, is
    # finished `unknown` and never run again; the run's report already told
    # the owner (M60 §9.4, §10.3).
    {:mandate_unknown_outcomes, &FermixCore.Cues.MandateGate.finish_unreported/3}
  ]

  @type step_result :: non_neg_integer() | {:error, term()}

  @doc """
  Starts the sweeper. Opts: `:name` (default `__MODULE__`), `:repo` (default
  `Memory.Repo`), `:timer?` (default true), `:clock` (default
  `DateTime.utc_now/0`), `:chunk`, `:budget_ms`, `:monotonic_ms` (a zero-arity
  function returning monotonic milliseconds, for the budget).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Runs one pass at `now`. Returns rows touched per step that ran; a step that
  failed maps to `{:error, reason}` (logged and traced), and the steps after a
  spent budget are absent.
  """
  @spec sweep(GenServer.server(), DateTime.t()) :: {:ok, %{atom() => step_result()}}
  def sweep(server, %DateTime{} = now) do
    # A pass stops at the first chunk that ends past its budget, and each Repo
    # call is bounded by the repo budget, so one pass ends within about two.
    GenServer.call(server, {:sweep, now}, 2 * Timeouts.repo_call())
  end

  @doc "The step names, in the order a pass runs them."
  @spec step_names() :: [atom()]
  def step_names, do: Enum.map(@steps, &elem(&1, 0))

  @impl true
  def init(opts) do
    state = %{
      repo: Keyword.get(opts, :repo, Repo),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      chunk: Keyword.get(opts, :chunk, @chunk),
      budget_ms: Keyword.get(opts, :budget_ms, @budget_ms),
      monotonic_ms:
        Keyword.get(opts, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end),
      timer?: Keyword.get(opts, :timer?, true)
    }

    if state.timer?, do: Process.send_after(self(), :sweep, @first_sweep_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:sweep, now}, _from, state), do: {:reply, {:ok, run_pass(state, now)}, state}

  @impl true
  def handle_info(:sweep, state) do
    run_pass(state, state.clock.())
    Process.send_after(self(), :sweep, @interval_ms)
    {:noreply, state}
  end

  # --- one pass ------------------------------------------------------------------

  defp run_pass(state, now) do
    started = state.monotonic_ms.()
    repo_opts = Repo.periodic_opts(state.repo, Timeouts.repo_call())

    Enum.reduce_while(@steps, %{}, fn {name, step}, results ->
      outcome = run_step(state, step, repo_opts, now, started)
      results = Map.put(results, name, step_total(name, outcome))

      if elem(outcome, 0) == :budget_spent,
        do: {:halt, results},
        else: {:cont, results}
    end)
  end

  defp run_step(state, step, repo_opts, now, started) do
    Enum.reduce_while(1..@max_chunks_per_step, {:done, 0}, fn _chunk, {_status, total} ->
      case step.(repo_opts, now, state.chunk) do
        {:ok, rows} -> next_chunk(state, started, total + rows, rows)
        {:error, reason} -> {:halt, {:error, {total, reason}}}
      end
    end)
  end

  defp next_chunk(state, started, total, rows) do
    cond do
      state.monotonic_ms.() - started >= state.budget_ms -> {:halt, {:budget_spent, total}}
      rows < state.chunk -> {:halt, {:done, total}}
      true -> {:cont, {:done, total}}
    end
  end

  defp step_total(_name, {status, total}) when status in [:done, :budget_spent], do: total

  defp step_total(name, {:error, {_total, reason}}) do
    Telemetry.lifecycle(:sweep_error, %{}, %{reason: name, result: {:error, reason}})
    Logger.error("Cue retention step #{name} failed: #{inspect(reason)}")
    {:error, reason}
  end

  # --- the steps -------------------------------------------------------------------

  @doc false
  @spec expire_lifetime(keyword(), DateTime.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def expire_lifetime(repo_opts, now, limit) do
    with {:ok, %{count: count, expired: expired, gaps: gaps}} <-
           Repo.cues_call(CuesSql, {:expire_lifetime, now, limit}, repo_opts) do
      Enum.each(expired, &emit_expired/1)
      Enum.each(gaps, &emit_gap/1)
      {:ok, count}
    end
  end

  @doc false
  @spec mark_terminal(keyword(), DateTime.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def mark_terminal(repo_opts, now, limit), do: sql_step(:mark_terminal, repo_opts, now, limit)

  @doc false
  @spec drop_payloads(keyword(), DateTime.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def drop_payloads(repo_opts, now, limit), do: sql_step(:drop_payloads, repo_opts, now, limit)

  @doc false
  @spec drop_snapshots(keyword(), DateTime.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def drop_snapshots(repo_opts, now, limit), do: sql_step(:drop_snapshots, repo_opts, now, limit)

  @doc false
  @spec prune_deliveries(keyword(), DateTime.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def prune_deliveries(repo_opts, now, limit),
    do: sql_step(:prune_deliveries, repo_opts, now, limit)

  @doc false
  @spec delete_receipts(keyword(), DateTime.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def delete_receipts(repo_opts, now, limit),
    do: sql_step(:delete_receipts, repo_opts, now, limit)

  @doc false
  @spec prune_gaps(keyword(), DateTime.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def prune_gaps(repo_opts, now, limit), do: sql_step(:prune_gaps, repo_opts, now, limit)

  @doc false
  @spec prune_filter_calls(keyword(), DateTime.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def prune_filter_calls(repo_opts, now, limit),
    do: sql_step(:prune_filter_calls, repo_opts, now, limit)

  defp sql_step(name, repo_opts, now, limit) do
    Repo.cues_call(CuesSql, {name, now, limit}, repo_opts)
  end

  defp emit_expired(expired) do
    Telemetry.lifecycle(:expired, %{}, %{
      source_ref: expired.source_ref,
      cue_id: expired.cue_id,
      delivery_id: expired.delivery_id,
      watcher_id: expired.watcher_id,
      reason: "lifetime"
    })
  end

  defp emit_gap(gap) do
    Telemetry.lifecycle(:gap, %{count: gap.count}, %{
      source_ref: gap.source_ref,
      gap_id: gap.gap_id,
      watcher_id: gap.watcher_id,
      reason: gap.reason
    })
  end
end
