defmodule FermixCore.ComputerHistory.Purge do
  @moduledoc """
  Owner purge executor (MILESTONE_32 §12; M97 §8.5). `/history purge
  10m|1h|24h|all` runs on the home: in one transaction it deletes the notes and
  threads whose provenance window intersects the window (for every machine, or
  one) and records the window as a purge interval. Then this machine, on a home
  that records itself, applies every interval it has not yet applied, this one
  included (`Delivery.apply_here/1`), which deletes and fences its own raw
  events in each. The interval reaches every other machine: the home refuses
  any sitting of theirs that touches the window, with the interval, until they
  have applied it (`ComputerHistory.Submission`), so a purged window never
  gains a note in whichever order the purge and a late sitting arrive; a
  connected computer is told at once (`ComputerHistory.Delivery`).

  The two stores are separate databases with no transaction across them, so
  the act is answered in two parts, and the reply says which stood. The home's
  transaction either commits or changes nothing. Once it commits, the interval
  stands and is never taken back: undoing it would leave the notes deleted with
  nothing refusing a late sitting in the window. When this machine's own apply
  then fails, the home still takes nothing from that window, and this machine
  applies it at the scheduler's next tick (`here: {:failed, reason}`).

  Purge is **logical deletion**: rows leave every query, but each store runs in
  WAL mode with no `secure_delete`, so raw bytes may linger in the `-wal` file
  and the SQLite freelist until overwritten — bounded against an offline
  attacker by disk encryption, not zeroed on purge (§12, §14 T14). It also
  cannot reach already-delivered replies, any remote vendor copies, the
  owner's own backups or the server's.
  """

  require Logger

  alias FermixCore.ComputerHistory.Delivery
  alias FermixCore.Memory.Repo

  @type window :: :all | {:last, non_neg_integer()}
  @typedoc """
  What a purge did: on the home, the notes deleted and the interval recorded;
  here, the raw events deleted and whether this machine applied it (`:none`
  where it keeps no store).
  """
  @type result :: %{
          events: non_neg_integer(),
          memories: non_neg_integer(),
          from_ts: integer(),
          to_ts: integer(),
          interval: pos_integer(),
          here: :ok | :none | {:failed, term()}
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
  the home's own). `{:ok, result}` once the home's transaction committed,
  whatever this machine's apply did (`result.here`); `{:error, reason}` when it
  did not, and nothing changed.
  """
  @spec purge(window(), keyword()) :: {:ok, result()} | {:error, term()}
  def purge(window, opts \\ []) do
    now = Keyword.get(opts, :now, System.system_time(:millisecond))
    repo = Keyword.get(opts, :repo, Repo)
    scope = Keyword.get(opts, :computer, :all)
    {from_ts, to_ts} = bounds(window, now)

    case Repo.computer_history_home(:purge_notes, [from_ts, to_ts, now, scope], server: repo) do
      {:ok, %{memories: memories, interval: id}} ->
        {events, here} = apply_here(Keyword.get(opts, :spool), repo, now)

        Logger.info(
          "computer_history purge removed #{memories} memory(ies) in [#{from_ts}, #{to_ts}] " <>
            "and #{events} event(s) here (#{inspect(here)})"
        )

        {:ok,
         %{
           events: events,
           memories: memories,
           from_ts: from_ts,
           to_ts: to_ts,
           interval: id,
           here: here
         }}

      {:error, reason} = error ->
        Logger.error("computer_history purge failed, nothing changed: #{inspect(reason)}")
        error
    end
  end

  # This machine's own raw events: every interval it has not applied, this one
  # among them, as any machine applies what it is told of.
  defp apply_here(nil, _repo, _now), do: {0, :none}

  defp apply_here(spool, repo, now) do
    case Delivery.apply_here(
           spool: spool,
           repo: repo,
           now: DateTime.from_unix!(now, :millisecond)
         ) do
      {:ok, events} ->
        {events, :ok}

      {:error, reason} ->
        Logger.error("computer_history purge was not applied here yet: #{inspect(reason)}")
        {0, {:failed, reason}}
    end
  end

  # `all` is everything up to now, never a far-future ceiling: an interval that
  # reached past now would fence every later event and refuse every later note.
  # A row stamped in the future (a backwards clock step) is therefore not
  # covered; the retention sweep deletes it 48 h after its stamp.
  defp bounds(:all, now), do: {0, now}
  defp bounds({:last, ms}, now), do: {now - ms, now}
end
