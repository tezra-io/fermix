defmodule FermixCore.Cues.Deliveries do
  @moduledoc """
  The read side of the cue inbox (M60 §9.5, §9.10): what `list_cues` shows the
  owner's chat and what `cue_history` shows a cue run, through
  `Memory.Repo.CuesDeliveriesSql`.

  A delivery reads as Fermix's own record (ids, times, state, outcome, attempts,
  the run's status, each mandate call's decision and result status, each
  proposal's state) beside everything a cue's source could have written: the
  cue's type, subject and snapshot, the filter's reason and hint, the head of
  the run's reply (a model wrote it from outside text), and each call's
  arguments, reason and result. That second part is framed as outside data
  (`UntrustedContent.frame/2`), one frame per delivery labelled with its source,
  so a page holds one frame preamble per delivery rather than one per field.

  The summary answers from receipts: a cue no watcher took is kept, without
  its payload, about eight days, so "this source sent 40 cues this week and
  nothing is listening" reads straight from the rows.

  A stream keeps only what passes (M60_CUE_INTAKE_AT_SCALE.md §3.2), so a
  stream watcher's drops are not rows: `present_drop/1` shows one of its recent
  drops (`Cues.RecentDrops`), marked as not kept, framed like a delivery.
  """

  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.Clock
  alias FermixCore.Cues.RecentDrops
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesDeliveriesSql
  alias FermixCore.Memory.Repo.CuesSql

  # `list_cues` pages and windows.
  @page_default 10
  @page_max 25
  @summary_days 7
  # `cue_history` (design §9.10): at most 20, within the 30-day retention.
  @history_default 10
  @history_max 20
  @history_days 30

  @delivery_states ~w(pending filtering passed claimed acked dropped exhausted expired)
  @proposal_states ~w(waiting confirmed denied expired refused)

  @type delivery :: map()

  @doc "Delivery states a filter may name."
  @spec delivery_states() :: [String.t()]
  def delivery_states, do: @delivery_states

  @doc "Proposal states a filter may name."
  @spec proposal_states() :: [String.t()]
  def proposal_states, do: @proposal_states

  @doc "`{default, max}` of a `list_cues` page."
  @spec page_limits() :: {pos_integer(), pos_integer()}
  def page_limits, do: {@page_default, @page_max}

  @doc "`{default, max}` of a `cue_history` answer."
  @spec history_limits() :: {pos_integer(), pos_integer()}
  def history_limits, do: {@history_default, @history_max}

  @doc "Days a summary covers when no `since` is given."
  @spec summary_days() :: pos_integer()
  def summary_days, do: @summary_days

  @doc """
  A time argument as the model sent it: nil when absent, else an ISO 8601 time
  with its offset, or the sentence that says so.
  """
  @spec parse_time(term(), String.t()) :: {:ok, DateTime.t() | nil} | {:error, String.t()}
  def parse_time(nil, _name), do: {:ok, nil}

  def parse_time(value, name) when is_binary(value) and is_binary(name) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, at, _offset} -> {:ok, DateTime.shift_zone!(at, "Etc/UTC")}
      {:error, _reason} -> {:error, time_refusal(name)}
    end
  end

  def parse_time(_value, name) when is_binary(name), do: {:error, time_refusal(name)}

  defp time_refusal(name),
    do: "#{name} must be an ISO 8601 time with its offset, such as 2026-10-17T09:00:00Z."

  # --- reads -------------------------------------------------------------------------

  @doc """
  A page of deliveries, newest first. `filters`: `limit` (1 to 25), and any of
  `watcher_id`, `source_ref`, `state`, `since`, `until`, `before_id`. `more?`
  says an older page exists (ask again with `before_id` set to the last id).
  """
  @spec list(map(), keyword()) ::
          {:ok, %{deliveries: [delivery()], more?: boolean()}} | {:error, term()}
  def list(%{limit: limit} = filters, opts)
      when is_integer(limit) and limit in 1..@page_max and is_list(opts) do
    request = Map.put(filters, :limit, limit + 1)

    with {:ok, rows} <-
           Repo.cues_call(CuesDeliveriesSql, {:list_deliveries, request}, repo_opts(opts)) do
      {:ok, %{deliveries: Enum.take(rows, limit), more?: length(rows) > limit}}
    end
  end

  @doc """
  One watcher's deliveries for `cue_history`, newest first, never older than 30
  days before `now`. `filters`: `limit` (1 to 20), and any of `subject`,
  `since`, `exclude_id` (the run's own delivery).
  """
  @spec history(String.t(), map(), DateTime.t(), keyword()) ::
          {:ok, [delivery()]} | {:error, term()}
  def history(watcher_id, %{limit: limit} = filters, %DateTime{} = now, opts)
      when is_binary(watcher_id) and is_integer(limit) and limit in 1..@history_max and
             is_list(opts) do
    floor = DateTime.add(now, -@history_days * 86_400, :second)

    request = %{
      watcher_id: watcher_id,
      subject: Map.get(filters, :subject),
      since: latest(Map.get(filters, :since), floor),
      exclude_id: Map.get(filters, :exclude_id),
      limit: limit
    }

    Repo.cues_call(CuesDeliveriesSql, {:list_deliveries, request}, repo_opts(opts))
  end

  @doc "Per source and per watcher since `filters.since` (see `CuesDeliveriesSql`)."
  @spec summary(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def summary(%{since: %DateTime{}} = filters, opts) when is_list(opts),
    do: Repo.cues_call(CuesDeliveriesSql, {:cue_summary, filters}, repo_opts(opts))

  @doc "Proposals newest first; `filters` as `CuesDeliveriesSql`'s `:list_proposals`."
  @spec proposals(map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def proposals(%{limit: limit} = filters, opts)
      when is_integer(limit) and limit in 1..@page_max and is_list(opts),
      do: Repo.cues_call(CuesDeliveriesSql, {:list_proposals, filters}, repo_opts(opts))

  @doc """
  Gaps, most recent first. `filters`: `limit`, and `source_ref` and/or
  `watcher_id` (a watcher's own gaps; a source's are listed by source).
  """
  @spec gaps(map(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def gaps(%{limit: limit} = filters, opts)
      when is_integer(limit) and limit in 1..@page_max and is_list(opts) do
    request = Map.reject(filters, fn {_key, value} -> is_nil(value) end)
    Repo.cues_call(CuesSql, {:list_gaps, request}, repo_opts(opts))
  end

  @doc "A watcher by name, with its task's job and memory source."
  @spec watcher(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found | term()}
  def watcher(name, opts) when is_binary(name) and is_list(opts),
    do: Repo.cues_call(CuesDeliveriesSql, {:watcher_ref, name}, repo_opts(opts))

  # --- presentation (JSON-ready; outside text framed) -----------------------------------

  @doc "A delivery as a tool shows it: Fermix's record, and its outside text framed."
  @spec present(delivery()) :: map()
  def present(delivery) when is_map(delivery) do
    %{
      delivery_id: delivery.id,
      cue_id: delivery.cue_id,
      watcher: delivery.watcher_name || delivery.watcher_id,
      source: delivery.source_ref,
      received_at: iso(delivery.received_at),
      occurred_at: iso(delivery.occurred_at),
      state: delivery.state,
      outcome: shown_outcome(delivery.outcome, delivery.watcher_name),
      settled_at: iso(delivery.settled_at),
      filter_attempts: delivery.filter_attempts,
      task_attempts: delivery.task_attempts,
      run: present_run(delivery.run),
      calls: Enum.map(delivery.calls, &present_call/1),
      proposals: Enum.map(delivery.proposals, &present_delivery_proposal/1),
      outside_text: frame(delivery.source_ref, delivery_lines(delivery))
    }
    |> put_count(:more_calls, delivery.more_calls)
    |> put_count(:more_proposals, delivery.more_proposals)
  end

  @doc """
  A stream watcher's recent drop as `list_cues` shows it: Fermix's record, with
  `kept: false` (the item is in memory only, until Fermix restarts) and the
  `drop_key` `manage_watcher` labels it by, and its outside text framed.
  """
  @spec present_drop(RecentDrops.drop()) :: map()
  def present_drop(%{item: item} = drop) do
    lines = [
      {"Type", item.type},
      {"Subject", item.subject},
      {"Snapshot", snapshot_text(item.snapshot)},
      {"Filter's reason", drop.reason}
    ]

    %{
      drop_key: drop.key,
      source: drop.source_ref,
      dropped_at: iso(drop.at),
      occurred_at: iso(item.occurred_at),
      kept: false,
      outside_text: frame(drop.source_ref, lines)
    }
  end

  @doc "A proposal as `list_cues` shows it, its arguments and results framed."
  @spec present_proposal(map()) :: map()
  def present_proposal(proposal) when is_map(proposal) do
    lines = [
      {"Arguments", proposal.args_json},
      {"Refusal", proposal.refusal_reason},
      {"Result", proposal.result_summary}
    ]

    %{
      proposal_id: proposal.id,
      watcher: proposal.watcher_name || proposal.watcher_id,
      source: proposal.source_ref,
      delivery_id: proposal.delivery_id,
      mandate_call_id: proposal.mandate_call_id,
      mandate: proposal.mandate,
      tool: proposal.tool,
      state: proposal.state,
      created_at: iso(proposal.created_at),
      expires_at: iso(proposal.expires_at),
      decided_at: iso(proposal.decided_at),
      result_status: proposal.result_status,
      finished_at: iso(proposal.finished_at),
      outside_text: frame(proposal.source_ref, lines)
    }
  end

  @doc "A gap as `list_cues` shows it: Fermix's own record, nothing framed."
  @spec present_gap(map()) :: map()
  def present_gap(gap) when is_map(gap) do
    %{
      gap_id: gap.id,
      source: gap.source_ref,
      watcher_id: gap.watcher_id,
      reason: gap.reason,
      count: gap.count,
      range_from: gap.range_from,
      range_to: gap.range_to,
      first_at: iso(gap.first_at),
      last_at: iso(gap.last_at),
      reported: not is_nil(gap.reported_at),
      open: is_nil(gap.closed_at)
    }
  end

  @doc """
  The summary as `list_cues` shows it. A source nothing listens to carries
  Fermix's sentence saying so, with what it sent since `since`.
  """
  @spec present_summary(map(), DateTime.t()) :: map()
  def present_summary(%{sources: sources, watchers: watchers}, %DateTime{} = since) do
    %{
      since: iso(since),
      sources: Enum.map(sources, &present_summary_source(&1, since)),
      watchers: Enum.map(watchers, &present_summary_watcher/1)
    }
  end

  # --- private -------------------------------------------------------------------

  defp repo_opts(opts), do: [server: Keyword.get(opts, :repo, Repo)]

  defp latest(nil, floor), do: floor

  defp latest(%DateTime{} = since, floor),
    do: if(DateTime.compare(since, floor) == :gt, do: since, else: floor)

  defp present_run(nil), do: nil
  defp present_run(run), do: %{id: run.id, status: run.status}

  defp present_call(call) do
    %{
      id: call.id,
      mandate: call.mandate,
      tool: call.tool,
      decision: call.decision,
      validator: call.validator,
      proposal_id: call.proposal_id,
      result_status: call.result_status,
      created_at: iso(call.created_at),
      decided_at: iso(call.decided_at),
      finished_at: iso(call.finished_at)
    }
  end

  # A delivery's proposal: its arguments are its call's, framed with the call.
  defp present_delivery_proposal(proposal) do
    %{
      id: proposal.id,
      mandate_call_id: proposal.mandate_call_id,
      tool: proposal.tool,
      state: proposal.state,
      created_at: iso(proposal.created_at),
      expires_at: iso(proposal.expires_at),
      decided_at: iso(proposal.decided_at),
      result_status: proposal.result_status,
      finished_at: iso(proposal.finished_at)
    }
  end

  # The snapshot `Cues.Item` wrote: JSON `{type, subject, text}`.
  defp snapshot_text(snapshot), do: snapshot |> Jason.decode!() |> Map.fetch!("text")

  defp delivery_lines(delivery) do
    [
      {"Type", delivery.type},
      {"Subject", delivery.subject},
      {"Snapshot", delivery.snapshot_text},
      {"Filter's reason", delivery.decision_reason},
      {"Filter's hint", delivery.hint},
      {"Run's reply (first 280 characters)", delivery.run && delivery.run.reply_excerpt}
    ] ++
      Enum.flat_map(delivery.calls, &call_lines/1) ++
      Enum.flat_map(delivery.proposals, &proposal_lines/1)
  end

  defp call_lines(call) do
    [
      {"Call #{call.id} arguments", call.args_json},
      {"Call #{call.id} reason", call.reason},
      {"Call #{call.id} result", call.result_summary}
    ]
  end

  defp proposal_lines(proposal) do
    [
      {"Proposal #{proposal.id} refusal", proposal.refusal_reason},
      {"Proposal #{proposal.id} result", proposal.result_summary}
    ]
  end

  # One frame for every outside field of one row; nil when it has none.
  defp frame(source_ref, lines) do
    case Enum.reject(lines, fn {_label, value} -> is_nil(value) end) do
      [] -> nil
      present -> UntrustedContent.frame(label(source_ref), Enum.map_join(present, "\n", &line/1))
    end
  end

  defp label(nil), do: "cue"
  defp label(source_ref), do: "cue:" <> source_ref

  defp line({label, value}), do: "#{label}: #{value}"

  defp put_count(map, _key, 0), do: map

  defp put_count(map, key, count) when is_integer(count) and count > 0,
    do: Map.put(map, key, count)

  defp present_summary_source(source, since) do
    %{
      source: source.source_ref,
      cues: source.cues,
      routed: source.routed,
      not_routed: source.not_routed,
      self_caused: source.self_caused,
      listening: source.listening,
      paused: source.paused,
      status: source.status,
      last_good_at: iso(source.last_good_at),
      last_accepted_at: iso(source.last_accepted_at),
      open_gaps: source.open_gaps
    }
    |> put_unheard(source, since)
  end

  defp put_unheard(map, %{listening: [], cues: 0}, since),
    do: Map.put(map, :note, "Nothing is listening, and it sent nothing since #{day(since)}.")

  defp put_unheard(map, %{listening: [], cues: cues}, since) do
    Map.put(
      map,
      :note,
      "Nothing is listening: the #{cues} #{plural(cues, "cue", "cues")} it sent since " <>
        "#{day(since)} reached no watcher."
    )
  end

  defp put_unheard(map, _source, _since), do: map

  defp present_summary_watcher(watcher) do
    %{
      watcher: watcher.name,
      enabled: watcher.enabled?,
      deliveries: watcher.deliveries,
      by_state: watcher.by_state,
      by_outcome:
        Map.new(watcher.by_outcome, fn {outcome, n} ->
          {shown_outcome(outcome, watcher.name), n}
        end)
    }
  end

  # Taking a source off a watcher expires that source's waiting items with the
  # outcome a removed watcher's items get, `watcher_removed`: the column's
  # CHECK fixes the set, and widening it means rebuilding the whole deliveries
  # table. A removed watcher's row is gone, so its items show no watcher name;
  # one that still has its name lost a source, and reads `source_removed`, so
  # the owner is not told the watcher was removed.
  defp shown_outcome("watcher_removed", watcher_name) when is_binary(watcher_name),
    do: "source_removed"

  defp shown_outcome(outcome, _watcher_name), do: outcome

  defp plural(1, one, _many), do: one
  defp plural(_count, _one, many), do: many

  defp day(%DateTime{} = at), do: Clock.stated_instant(at)

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
