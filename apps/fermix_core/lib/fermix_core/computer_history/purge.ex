defmodule FermixCore.ComputerHistory.Purge do
  @moduledoc """
  Owner purge executor (MILESTONE_32 §12). `/history purge 10m|1h|24h|all`
  erases a recent window from the spool **and** the activity memories whose
  provenance window intersects it, and advances a purge watermark that blocks
  an in-flight summarizer write from re-materializing just-purged events.

  Purge is **logical deletion**: rows leave every query, but `memory.db` runs
  in WAL mode with no `secure_delete`, so raw bytes may linger in the `-wal`
  file and the SQLite freelist until overwritten — bounded against an offline
  attacker by FileVault, not zeroed on purge (§12, §14 T14). It also cannot
  reach already-delivered replies, any remote vendor copies, or the operator's
  own backups; the acknowledgment (Stage 6) states this plainly.

  Runs in the daemon process so it shares the summarizer's in-flight-purge
  watermark check (§15.3) — the CLI routes mutations here over the control
  socket rather than opening `memory.db` in a second tree.
  """

  require Logger

  alias FermixCore.Memory.Repo

  # Everything up to "now" for an `all` purge — a far-future ceiling so no real
  # (past-dated) event escapes the window.
  @max_ts 9_999_999_999_999

  @type window :: :all | {:last, non_neg_integer()}
  @type result :: %{
          events: non_neg_integer(),
          memories: non_neg_integer(),
          from_ts: integer(),
          to_ts: integer()
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
  `:repo`. Returns the deleted counts plus the resolved bounds, or the error.
  """
  @spec purge(window(), keyword()) :: {:ok, result()} | {:error, term()}
  def purge(window, opts \\ []) do
    now = Keyword.get(opts, :now, System.system_time(:millisecond))
    repo = Keyword.get(opts, :repo, Repo)
    {from_ts, to_ts} = bounds(window, now)

    case Repo.computer_history_purge_window(from_ts, to_ts, server: repo) do
      {:ok, counts} ->
        Logger.info(
          "computer_history purge removed #{counts.events} event(s), " <>
            "#{counts.memories} memory(ies) in [#{from_ts}, #{to_ts}]"
        )

        {:ok, Map.merge(counts, %{from_ts: from_ts, to_ts: to_ts})}

      {:error, reason} = error ->
        Logger.error("computer_history purge failed: #{inspect(reason)}")
        error
    end
  end

  defp bounds(:all, _now), do: {0, @max_ts}
  defp bounds({:last, ms}, now), do: {now - ms, now}
end
