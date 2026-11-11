defmodule FermixCore.ComputerHistory.Purge do
  @moduledoc """
  Owner purge executor (MILESTONE_32 §12; M97 §8.5). `/history purge
  10m|1h|24h|all` runs on the home: it deletes the notes and threads whose
  provenance window intersects the window (for every machine, or one) and
  records the window as a purge interval, then fences this machine's own raw
  events in it (`ComputerHistory.Spool`). The interval reaches every other
  machine: the home refuses any sitting of theirs that touches the window, with
  the interval, until they have applied it (`ComputerHistory.Submission`), so a
  purged window never gains a note in whichever order the purge and a late
  sitting arrive; a connected computer is told at once
  (`ComputerHistory.Delivery`).

  Purge is **logical deletion**: rows leave every query, but each store runs in
  WAL mode with no `secure_delete`, so raw bytes may linger in the `-wal` file
  and the SQLite freelist until overwritten — bounded against an offline
  attacker by disk encryption, not zeroed on purge (§12, §14 T14). It also
  cannot reach already-delivered replies, any remote vendor copies, the
  owner's own backups or the server's.
  """

  require Logger

  alias FermixCore.ComputerHistory.Spool
  alias FermixCore.Memory.Repo

  @type window :: :all | {:last, non_neg_integer()}
  @type result :: %{
          events: non_neg_integer(),
          memories: non_neg_integer(),
          from_ts: integer(),
          to_ts: integer(),
          interval: pos_integer()
        }

  @doc """
  Parse a `/history purge` argument into a window. Accepts `"all"`, `"<n>m"`,
  and `"<n>h"` (so `10m`, `1h`, `24h` all resolve). Anything else is rejected.
  """
  @spec parse_window(String.t()) :: {:ok, window()} | {:error, :invalid_window}
  def parse_window("all"), do: {:ok, :all}

  def parse_window(spec) when is_binary(spec) do
    case Regex.run(~r/^(\d+)(m|h)$/, spec) do
      [_whole, n, "m"] -> {:ok, {:last, String.to_integer(n) * 60_000}}
      [_whole, n, "h"] -> {:ok, {:last, String.to_integer(n) * 3_600_000}}
      _no_match -> {:error, :invalid_window}
    end
  end

  @doc """
  Execute a purge over `window`. `opts`: `:now` (epoch ms, injected for tests),
  `:repo` (the home's store), `:spool` (this machine's, nil when this engine
  keeps none), `:computer` (`:all`, the default, or one machine's id, `""` for
  the home's own). Returns the deleted counts plus the resolved bounds and the
  interval's id, or the error.
  """
  @spec purge(window(), keyword()) :: {:ok, result()} | {:error, term()}
  def purge(window, opts \\ []) do
    now = Keyword.get(opts, :now, System.system_time(:millisecond))
    repo = Keyword.get(opts, :repo, Repo)
    scope = Keyword.get(opts, :computer, :all)
    {from_ts, to_ts} = bounds(window, now)

    with {:ok, %{memories: memories, interval: id}} <-
           Repo.computer_history_home(:purge_notes, [from_ts, to_ts, now, scope], server: repo),
         {:ok, events} <-
           fence_here(Keyword.get(opts, :spool, Spool), scope, {id, from_ts, to_ts}, now) do
      Logger.info(
        "computer_history purge removed #{events} event(s) here, " <>
          "#{memories} memory(ies) in [#{from_ts}, #{to_ts}]"
      )

      {:ok, %{events: events, memories: memories, from_ts: from_ts, to_ts: to_ts, interval: id}}
    else
      {:error, reason} = error ->
        Logger.error("computer_history purge failed: #{inspect(reason)}")
        error
    end
  end

  # This machine's own raw events, when the purge reaches it: counted, then
  # fenced as any machine applies an interval it is told of.
  defp fence_here(nil, _scope, _interval, _now), do: {:ok, 0}

  defp fence_here(spool, scope, {id, from_ts, to_ts}, now) when scope in [:all, ""] do
    interval = %{id: id, from_ts: from_ts, to_ts: to_ts, issued_at: now, kind: "purge"}

    with {:ok, before} <- Spool.count_events(server: spool),
         :ok <-
           Spool.apply_intervals([interval], DateTime.from_unix!(now, :millisecond),
             server: spool
           ),
         {:ok, left} <- Spool.count_events(server: spool) do
      {:ok, max(before - left, 0)}
    end
  end

  defp fence_here(_spool, _computer, _interval, _now), do: {:ok, 0}

  # `all` is everything up to now, never a far-future ceiling: an interval that
  # reached past now would fence every later event and refuse every later note.
  # A row stamped in the future (a backwards clock step) is therefore not
  # covered; the retention sweep deletes it 48 h after its stamp.
  defp bounds(:all, now), do: {0, now}
  defp bounds({:last, ms}, now), do: {now - ms, now}
end
