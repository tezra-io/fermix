defmodule FermixCore.Cues.Ingest do
  @moduledoc """
  Accepts items from one source into the cue inbox (design §7.1, PLAN §4.1).

  `accept/3` takes the source (resolved from config by the caller), the items
  (each an `Item.t()`, or the `{:error, _}` its `Item.new/2` returned, so the
  results stay positional) and opts. In order:

  1. items `Item.new/2` refused are reported `{:invalid, message}` or `:stale`;
  2. the rest are sorted oldest first (by item time, undated last, input order
     kept), so a page or batch is inserted in arrival order;
  3. the `:admit` function (the door's or a worker's rate buckets) decides how
     many go on; the rest are `:rate_limited`;
  4. one Repo transaction: identity, then the daily budget (`daily_budget`,
     0 = none: a new item past what the source may still send today is
     `:over_budget`, and only items accepted are counted in `cue_sources`),
     receipt or routing, inbox eviction, the coalesced reject counts and their
     gaps, and `:source_state`;
  5. lifecycle telemetry per result, then the wake-ups: `Cues.Filters` when an
     `llm` watcher got a delivery, `Jobs.Scheduler` when a `none` watcher did.

  Every error is traced (`ingest_error`) before it is returned.
  """

  require Logger

  alias FermixCore.Cues
  alias FermixCore.Cues.Item
  alias FermixCore.Cues.Telemetry
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql

  @type source :: %{ref: String.t(), daily_budget: non_neg_integer()}
  @type entry :: Item.t() | {:error, {:invalid, String.t()}} | {:error, :stale}
  @type result ::
          :accepted
          | :duplicate
          | :conflict
          | {:invalid, String.t()}
          | :stale
          | :rate_limited
          | :over_budget
  @type source_state :: %{
          optional(:cursor) => String.t() | nil,
          optional(:last_good_at) => DateTime.t() | nil,
          optional(:status) => String.t() | nil
        }

  @source_state_keys [:cursor, :last_good_at, :status]

  @doc """
  Accepts `entries` from `source`. Opts:

  - `:now` (required) — the receipt time, a `DateTime`;
  - `:repo` — the `Memory.Repo` server (default `Memory.Repo`);
  - `:admit` — `(pos_integer() -> non_neg_integer())`: given how many valid
    items arrived, how many the rate buckets admit (default: all);
  - `:source_state` — `cursor`, `last_good_at`, `status` written to
    `cue_sources` in the same transaction (a nil value leaves the column as it
    was); written even when no item arrived (a stream heartbeat);
  - `:received_mono` — monotonic ms at receipt, for `accept_ms` (default: now);
  - `:wake_filters`, `:wake_scheduler` — zero-arity wake-ups (default
    `Cues.wake_filters/0`, `Cues.wake_scheduler/0`).

  Returns one result per entry, in input order.
  """
  @spec accept(source(), [entry()], keyword()) :: {:ok, [result()]} | {:error, term()}
  def accept(%{ref: ref, daily_budget: budget}, entries, opts)
      when is_binary(ref) and is_integer(budget) and budget >= 0 and is_list(entries) and
             is_list(opts) do
    %DateTime{} = now = Keyword.fetch!(opts, :now)
    received = Keyword.get_lazy(opts, :received_mono, &monotonic_ms/0)
    state = source_state!(Keyword.get(opts, :source_state))
    {valid, decided} = classify(entries)

    with {:ok, admitted, decided} <- admit(valid, decided, opts),
         {:ok, summary} <-
           commit(%{ref: ref, budget: budget}, admitted, decided, now, state, opts) do
      results = positional(entries, admitted, summary.results, decided)
      emit(ref, results, summary, monotonic_ms() - received)
      wake(summary, opts)
      {:ok, Enum.map(results, &elem(&1, 0))}
    else
      {:error, reason} -> traced_error(ref, reason)
    end
  end

  # --- steps -------------------------------------------------------------------

  defp classify(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce({[], %{}}, fn
      {%Item{} = item, index}, {valid, decided} ->
        {[{index, item} | valid], decided}

      {{:error, :stale}, index}, {valid, decided} ->
        {valid, Map.put(decided, index, :stale)}

      {{:error, {:invalid, _message} = invalid}, index}, {valid, decided} ->
        {valid, Map.put(decided, index, invalid)}

      {other, _index}, _acc ->
        raise ArgumentError, "Ingest.accept/3 got #{inspect(other)}"
    end)
    |> then(fn {valid, decided} -> {Enum.sort_by(valid, &arrival_key/1), decided} end)
  end

  defp arrival_key({index, %Item{occurred_at: nil}}), do: {1, 0, index}

  defp arrival_key({index, %Item{occurred_at: at}}),
    do: {0, DateTime.to_unix(at, :microsecond), index}

  defp admit([], decided, _opts), do: {:ok, [], decided}

  defp admit(valid, decided, opts) do
    wanted = length(valid)

    case Keyword.get(opts, :admit, & &1).(wanted) do
      granted when is_integer(granted) and granted >= 0 and granted <= wanted ->
        {taken, refused} = Enum.split(valid, granted)
        {:ok, taken, mark(decided, refused, :rate_limited)}

      other ->
        raise ArgumentError, "the :admit function returned #{inspect(other)} for #{wanted} items"
    end
  end

  defp mark(decided, refused, result) do
    Enum.reduce(refused, decided, fn {index, _item}, acc -> Map.put(acc, index, result) end)
  end

  defp commit(%{ref: ref, budget: budget}, admitted, decided, now, state, opts) do
    rejected = rejected_counts(decided)

    if admitted == [] and rejected == %{} and state == nil do
      {:ok, %{results: [], gaps: [], llm?: false, none?: false}}
    else
      items = Enum.map(admitted, &elem(&1, 1))
      source = %{ref: ref, rejected: rejected, daily_budget: budget}
      repo_call({:accept, source, items, now, state}, opts)
    end
  end

  defp rejected_counts(decided) do
    decided
    |> Map.values()
    |> Enum.frequencies_by(fn
      {:invalid, _message} -> "invalid"
      atom -> Atom.to_string(atom)
    end)
  end

  # `{result, detail}` per entry, in input order; `detail` is the SQL result
  # for an item that reached the transaction, else nil.
  defp positional(entries, admitted, sql_results, decided) do
    committed =
      admitted
      |> Enum.zip(sql_results)
      |> Map.new(fn {{index, _item}, detail} -> {index, {detail.result, detail}} end)

    entries
    |> Enum.with_index()
    |> Enum.map(fn {_entry, index} ->
      Map.get_lazy(committed, index, fn -> {Map.fetch!(decided, index), nil} end)
    end)
  end

  defp repo_call(request, opts) do
    Repo.cues_call(CuesSql, request, server: Keyword.get(opts, :repo, Repo))
  end

  defp source_state!(nil), do: nil

  defp source_state!(state) when is_map(state) do
    case Map.keys(state) -- @source_state_keys do
      [] -> state
      unknown -> raise ArgumentError, "unknown :source_state keys #{inspect(unknown)}"
    end
  end

  defp wake(summary, opts) do
    if summary.llm?, do: Keyword.get(opts, :wake_filters, &Cues.wake_filters/0).()
    if summary.none?, do: Keyword.get(opts, :wake_scheduler, &Cues.wake_scheduler/0).()
    :ok
  end

  defp traced_error(ref, reason) do
    Telemetry.lifecycle(:ingest_error, %{}, %{source_ref: ref, result: {:error, reason}})
    Logger.warning("Cue ingest for source #{ref} failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  # --- telemetry (ids and counts only) -----------------------------------------

  defp emit(ref, results, summary, accept_ms) do
    Enum.each(results, fn result -> emit_result(ref, result, max(accept_ms, 0)) end)

    Enum.each(summary.gaps, fn gap ->
      Telemetry.lifecycle(:gap, %{count: gap.count}, %{
        source_ref: gap.source_ref,
        gap_id: gap.gap_id,
        watcher_id: gap.watcher_id,
        reason: gap.reason
      })
    end)
  end

  defp emit_result(ref, {:accepted, detail}, accept_ms) do
    Telemetry.lifecycle(:accepted, %{count: 1, accept_ms: accept_ms}, %{
      source_ref: ref,
      cue_id: detail.cue_id
    })

    Enum.each(detail.deliveries, &emit_delivery(ref, detail.cue_id, &1))
    Enum.each(detail.evicted, &emit_evicted(ref, &1))
  end

  defp emit_result(ref, {result, detail}, _accept_ms) do
    Telemetry.lifecycle(phase(result), %{}, %{source_ref: ref, cue_id: detail && detail.cue_id})
  end

  defp phase({:invalid, _message}), do: :rejected

  defp phase(result) when result in [:duplicate, :conflict, :stale, :rate_limited, :over_budget],
    do: result

  defp emit_delivery(ref, cue_id, delivery) do
    ids = %{
      source_ref: ref,
      cue_id: cue_id,
      delivery_id: delivery.delivery_id,
      watcher_id: delivery.watcher_id
    }

    Telemetry.lifecycle(:routed, %{}, Map.put(ids, :state, delivery.state))

    # A `none` watcher's delivery passes at acceptance, with no filter call (§14).
    if delivery.state == "passed" do
      Telemetry.lifecycle(:passed, %{}, Map.put(ids, :reason, "no filter"))
    end
  end

  defp emit_evicted(ref, evicted) do
    Telemetry.lifecycle(:expired, %{}, %{
      source_ref: ref,
      delivery_id: evicted.delivery_id,
      watcher_id: evicted.watcher_id,
      reason: "inbox_full"
    })
  end
end
