defmodule FermixCore.ComputerHistory.Sittings do
  @moduledoc """
  The machine's half of computer history after the recorder (M97 §8.1): on
  every engine that records, a Mac that is its own home included, each closed
  sitting in this machine's store (`ComputerHistory.Spool`) is sent to the home
  to be summarized, and the cursor moves on the home's answer. One cycle
  (`run/1`), at most #{6} sittings:

  - the events past the cursor are split into sittings (`Summarizer.Sessions`);
    the trailing open one waits, and its first stamp is recorded so
    `/history status` can say what is waiting;
  - a sitting with no signal (`Summarizer.signal?/2`) is never sent: the cursor
    passes it as `no_signal`, and a run of sleep, lock or switch markers with no
    sitting around them is passed too;
  - a sitting is rendered by the code the summarizer has always read
    (`EventRender.render/2`, after Ingest's scrubbing, at most #{60_000}
    characters), with its apps, sites, titles, addresses, event count and time
    range, and keyed by its first and last event and its first stamp, so a
    sitting sent twice makes one note;
  - a machine whose summarizer is `local` makes the note itself on its own
    model (`Summarizer.summarize/4`, guarded against its own field text) and
    sends only the note: no raw text leaves it;
  - the uplink (`:uplink`, a function of the sitting's map) sends it: in
    process on a home that records itself, over the link with `history.submit`
    from a computer.

  The answer decides the cursor: `summarized`, `abstained` and `no_signal` move
  it past the sitting; `refused` for a purge or pause applies the intervals the
  home named here first, under the home store the answer names
  (`Spool.apply_intervals/4`), and forms the sitting again from what is left;
  `refused` as `invalid` or `expired` moves past it, loudly, since it can never
  be taken; any other refusal, and no answer at all, holds it to be sent again
  on a later cycle. Each sitting carries this machine's mark and the home store
  it belongs to (`home`). Raw events expire after 48 hours (`Retention`),
  counted when they were never sent, and each cycle takes the expired ones
  first, so nothing older than that is ever sent.

  Events stamped while this computer's server drove its screen or used its
  browser are marked as Fermix's own in the sitting (`by=fermix`, M97 §8.7),
  from the records under this computer's home (`:home`).

  Options: `:uplink` (required), `:spool`, `:home`, `:config` (this machine's history
  settings), `:now`, `:timezone`, `:limit`, `:budget`, and a local summary's
  test `:adapter` and `:route_opts`.
  """

  require Logger

  alias FermixCore.ComputerHistory.Config
  alias FermixCore.ComputerHistory.Gate
  alias FermixCore.ComputerHistory.Retention
  alias FermixCore.ComputerHistory.Spool
  alias FermixCore.ComputerHistory.Submission
  alias FermixCore.ComputerHistory.Summarizer
  alias FermixCore.ComputerHistory.Summarizer.EventRender
  alias FermixCore.ComputerHistory.Summarizer.Sessions
  alias FermixCore.ComputerUse.ServerControl
  alias FermixCore.Setup.ConfigStore

  @batch_limit 500
  @max_sittings_per_cycle 6

  @type uplink :: (map() -> {:ok, Submission.answer()} | {:error, term()})
  @type result :: %{
          sittings: non_neg_integer(),
          sent: non_neg_integer(),
          notes: non_neg_integer(),
          events: non_neg_integer()
        }

  @doc """
  One cycle. `{:ok, result}` once nothing closed is left or the bound is
  reached, `{:held, reason}` when the home's answer or its absence holds a
  sitting back, `{:error, reason}` when this machine's store or its local
  summarizer refused.
  """
  @spec run(keyword()) :: {:ok, result()} | {:held, term()} | {:error, term()}
  def run(opts) when is_list(opts) do
    ctx = context(opts)

    # Nothing older than the retention window is ever sent (M97 §8.1): the
    # home keeps its intervals no longer than that, so it goes first, as the
    # hourly sweep would take it, counted when it was never sent.
    with {:ok, _swept} <- Retention.sweep(ctx.now_ms, Retention.window_ms(), ctx.spool) do
      Enum.reduce_while(
        1..@max_sittings_per_cycle//1,
        {:ok, %{sittings: 0, sent: 0, notes: 0, events: 0}},
        fn _sitting, {:ok, acc} -> step(ctx, acc) end
      )
    end
  end

  defp context(opts) do
    config = Keyword.get_lazy(opts, :config, &Config.current/0)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    %{
      uplink: Keyword.fetch!(opts, :uplink),
      spool: [server: Keyword.get(opts, :spool, Spool)],
      config: config,
      local?: Config.summarizer(config) == :local,
      now: now,
      now_ms: DateTime.to_unix(now, :millisecond),
      timezone: Config.timezone(opts),
      limit: Keyword.get(opts, :limit, @batch_limit),
      budget: Keyword.get(opts, :budget, EventRender.default_budget()),
      adapter: Keyword.get(opts, :adapter),
      route_opts: Keyword.get(opts, :route_opts, []),
      own: own_stretches(Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0), now)
    }
  end

  # M97 §8.7, D11: the stretches Fermix on this computer's server drove its
  # screen or used its browser (`ComputerUse.ServerControl`, one reader of
  # both records), as epoch-ms ranges; one still open runs to now. An event
  # stamped inside one is Fermix's own, and the sitting says so (`by=fermix`),
  # so the summary never reports the agent's clicks or browsing as the
  # owner's. A record that cannot be read marks nothing, loudly.
  defp own_stretches(home, now) do
    case ServerControl.stretches(home) do
      {:ok, stretches} ->
        Enum.map(stretches, &{ms(&1.started_at), ms(&1.ended_at || now)})

      {:error, reason} ->
        Logger.warning(
          "computer_history: the record of the server's control is unreadable: #{inspect(reason)}"
        )

        []
    end
  end

  defp ms(%DateTime{} = at), do: DateTime.to_unix(at, :millisecond)

  defp mark_own(%{ts: ts} = event, own) when is_integer(ts) do
    if Enum.any?(own, fn {from, to} -> ts >= from and ts <= to end),
      do: Map.put(event, :by_fermix, true),
      else: event
  end

  defp mark_own(event, _own), do: event

  # The mark of the home's intervals this machine applied, and the home store
  # it belongs to, are read before the events: a sitting read after them holds
  # no event stamped inside any of them.
  defp step(ctx, acc) do
    with {:ok, %{home_mark: mark, home: store}} <- Spool.link(ctx.spool),
         {:ok, %{last_summarized_id: cursor}} <- Spool.state(ctx.spool),
         {:ok, events} <- Spool.events_after(cursor || 0, ctx.limit, ctx.spool) do
      {decision, open} = Sessions.next_closed(events, ctx.now_ms, length(events) == ctx.limit)
      record_open(open, ctx)
      dispatch(decision, Map.merge(ctx, %{cursor: cursor || 0, mark: mark, store: store}), acc)
    else
      {:error, _reason} = error -> {:halt, error}
    end
  end

  # A diagnostic, never a gate: a failed write is logged and the cycle goes on.
  defp record_open(:unknown, _ctx), do: :ok
  defp record_open(:none, ctx), do: open_since(nil, ctx)
  defp record_open({:open, ts}, ctx), do: open_since(ts, ctx)

  defp open_since(ts, ctx) do
    case Spool.set_open_since(ts, ctx.spool) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("computer_history open-sitting mark: #{inspect(reason)}")
    end
  end

  defp dispatch(:wait, _ctx, acc), do: {:halt, {:ok, acc}}

  # Sleep, lock and switch markers with no sitting around them are not activity:
  # the cursor passes them and keeps the last real outcome.
  defp dispatch({:boundaries, ids}, ctx, acc),
    do: advanced(Spool.advance(Enum.max(ids), ctx.now, nil, ctx.spool), acc)

  defp dispatch({:session, session}, ctx, acc) do
    log_overtaken(session)
    {fields, titles} = Summarizer.signal_counts(session.events)

    if Summarizer.signal?(fields, titles),
      do: render(session, ctx, acc),
      else: no_signal(session, ctx, acc)
  end

  defp no_signal(session, ctx, acc) do
    advance = Spool.advance(Enum.max(session.consumed_ids), ctx.now, "no_signal", ctx.spool)
    advanced(advance, count(acc, session.events, :no_signal))
  end

  defp advanced(:ok, acc), do: {:cont, {:ok, acc}}
  defp advanced({:error, _reason} = error, _acc), do: {:halt, error}

  # An id the cursor passes without its event having been sent: only reachable
  # when the store received a newer-stamped event before an older one.
  defp log_overtaken(%{overtaken_ids: []}), do: :ok

  defp log_overtaken(%{overtaken_ids: ids}) do
    Logger.warning(
      "computer_history: #{length(ids)} raw event(s) are older by id than the sitting " <>
        "being sent and will not be summarized: #{inspect(Enum.take(ids, 20))}"
    )
  end

  # -- one sitting -------------------------------------------------------------------

  defp render(session, ctx, acc) do
    events = Enum.map(session.events, &mark_own(&1, ctx.own))

    case EventRender.render(events, timezone: ctx.timezone, budget: ctx.budget) do
      {_input, []} -> unrenderable(session, ctx)
      {input, rendered} -> send_sitting(input, rendered, cursor_past(session, rendered), ctx, acc)
    end
  end

  # Unreachable while both of the renderer's bounds hold; if either breaks, the
  # cycle stops loudly, naming the event, rather than send an empty sitting.
  defp unrenderable(%{events: [%{id: id} | _rest]}, ctx) do
    Logger.error("computer_history renderer produced no line for event #{id}; holding it")
    _ = Spool.set_paused_reason("unrenderable_event", ctx.spool)
    {:halt, {:error, {:unrenderable_event, id}}}
  end

  defp send_sitting(input, rendered, last_id, ctx, acc) do
    case sitting(input, rendered, ctx) do
      {:ok, payload} -> settle(ctx.uplink.(payload), last_id, rendered, ctx, acc)
      {:advance, status} -> settled(status, last_id, rendered, ctx, acc)
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp sitting(input, rendered, ctx) do
    {fields, _titles} = Summarizer.signal_counts(rendered)
    stamps = Enum.map(rendered, & &1.ts)
    ids = Enum.map(rendered, & &1.id)

    base =
      rendered
      |> Summarizer.artifacts()
      |> Map.merge(%{
        "v" => Submission.version(),
        "sitting" => "#{Enum.min(ids)}-#{Enum.max(ids)}:#{Enum.min(stamps)}",
        "from_ts" => Enum.min(stamps),
        "to_ts" => Enum.max(stamps),
        "event_count" => length(rendered),
        "field_values" => fields,
        "mark" => ctx.mark,
        "home" => ctx.store
      })

    if ctx.local?,
      do: local_note(base, input, rendered, ctx),
      else: {:ok, Map.put(base, "text", input)}
  end

  # The note made here, on this machine's own model; only it leaves (M97 §8.1).
  defp local_note(base, input, rendered, ctx) do
    with {:ok, {route_key, _adapter_opts} = route} <- local_route(ctx),
         {:ok, summary, _redactions} <-
           Summarizer.summarize(route, input, texts(rendered), local_opts(ctx)) do
      {:ok, Map.put(base, "note", %{"summary" => summary, "model" => route_key.model})}
    else
      {:empty, _kind} -> {:advance, "abstained"}
      {:error, reason} -> held_locally(reason, ctx)
    end
  end

  defp local_route(ctx) do
    case Summarizer.route(:local, ctx.route_opts) do
      {:ok, route} ->
        if Gate.summarizer_permitted?(route, ctx.config),
          do: {:ok, route},
          else: {:error, :route_not_permitted}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp local_opts(ctx) do
    [now: ctx.now] |> then(&if(ctx.adapter, do: [{:adapter, ctx.adapter} | &1], else: &1))
  end

  defp held_locally(reason, ctx) do
    Logger.error("computer_history local summarizer: #{inspect(reason)}")
    _ = Spool.set_paused_reason(reason_word(reason), ctx.spool)
    {:error, {:local_summarizer, reason}}
  end

  defp texts(rendered),
    do: rendered |> Enum.map(&Map.get(&1, :text)) |> Enum.filter(&is_binary/1) |> Enum.uniq()

  # -- the home's answer ----------------------------------------------------------------

  defp settle({:ok, %{status: status}}, last_id, rendered, ctx, acc)
       when status in [:summarized, :abstained, :no_signal] do
    record(Atom.to_string(status), nil, ctx)
    _ = Spool.set_paused_reason(nil, ctx.spool)
    settled(Atom.to_string(status), last_id, rendered, ctx, %{acc | sent: acc.sent + 1})
  end

  # The intervals belong to the home store the answer names, which may not be
  # the one this machine's mark did (`Spool.apply_intervals/4`).
  defp settle(
         {:ok, %{status: :refused, reason: reason, intervals: intervals, home: home}},
         _last_id,
         _r,
         ctx,
         acc
       )
       when reason in [:purged, :paused] and is_binary(home) do
    record("refused", Atom.to_string(reason), ctx)

    case Spool.apply_intervals(intervals, home, ctx.now, ctx.spool) do
      :ok -> {:cont, {:ok, %{acc | sent: acc.sent + 1}}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp settle({:ok, %{status: :refused, reason: :invalid}}, last_id, rendered, ctx, acc) do
    Logger.error("computer_history: the home cannot read a sitting from here; it is skipped")
    record("refused", "invalid", ctx)
    settled("refused:invalid", last_id, rendered, ctx, acc)
  end

  # Older than the home keeps intervals for, by the home's clock: never taken,
  # so passed, as the sweep here takes such events.
  defp settle({:ok, %{status: :refused, reason: :expired}}, last_id, rendered, ctx, acc) do
    Logger.warning("computer_history: the home found a sitting from here too old; it is skipped")
    record("refused", "expired", ctx)
    settled("refused:expired", last_id, rendered, ctx, acc)
  end

  defp settle({:ok, %{status: :refused, reason: reason}}, _last_id, _rendered, ctx, _acc) do
    record("refused", reason_word(reason), ctx)
    held(reason_word(reason), ctx)
  end

  defp settle({:error, reason}, _last_id, _rendered, ctx, _acc) do
    Logger.info("computer_history: a sitting was not answered (#{inspect(reason)}); held")
    held("unanswered", ctx)
  end

  # A budget cut that leaves the cursor where it was would read the same cut
  # again, so the cycle stops there and the next tick goes on.
  defp settled(status, last_id, rendered, ctx, acc) do
    acc = count(acc, rendered, status)

    case advanced(Spool.advance(last_id, ctx.now, status, ctx.spool), acc) do
      {:cont, {:ok, acc}} when last_id <= ctx.cursor -> {:halt, {:ok, acc}}
      other -> other
    end
  end

  defp held(reason, ctx) do
    _ = Spool.set_paused_reason(reason, ctx.spool)
    {:halt, {:held, reason}}
  end

  defp record(answer, reason, ctx) do
    case Spool.record_answer(answer, reason, ctx.now_ms, ctx.spool) do
      :ok -> :ok
      {:error, error} -> Logger.warning("computer_history answer not recorded: #{inspect(error)}")
    end
  end

  defp count(acc, events, status) do
    %{
      acc
      | sittings: acc.sittings + 1,
        events: acc.events + length(events),
        notes: acc.notes + if(status == "summarized", do: 1, else: 0)
    }
  end

  defp reason_word(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_word(reason) when is_binary(reason), do: reason
  defp reason_word(reason), do: inspect(reason)

  # -- the cursor -------------------------------------------------------------------

  # The cursor passes the whole sitting — its boundary event included — only when
  # the renderer took all of it. A budget-cut sitting advances only past what was
  # rendered, and the remainder becomes the next sitting.
  defp cursor_past(session, rendered) when length(rendered) == length(session.events),
    do: Enum.max(session.consumed_ids)

  # A cut sitting is a ts-order prefix, and ids need not agree with ts order: the
  # cursor is clamped below every id left behind, so nothing is skipped. The price
  # is that the rendered events may be read again and sent twice; the home keys
  # a note by its sitting, and the ids are named.
  defp cursor_past(session, rendered) do
    written = Enum.map(rendered, & &1.id)
    remainder = Enum.map(session.events, & &1.id) -- written
    clamped = min(Enum.max(written), Enum.min(remainder) - 1)
    re_read = Enum.filter(written, &(&1 > clamped))

    if re_read != [] do
      Logger.warning(
        "computer_history: the input budget cut a sitting whose ids are out of ts order; " <>
          "the cursor stays at #{clamped}, so event(s) #{inspect(Enum.take(re_read, 20))} " <>
          "will be re-read and may be sent twice"
      )
    end

    clamped
  end
end
