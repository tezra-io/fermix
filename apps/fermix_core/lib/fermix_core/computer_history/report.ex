defmodule FermixCore.ComputerHistory.Report do
  @moduledoc """
  What a computer tells its home about its own recorder (M97 §8.5), so the
  home's `/history status` can show one block per computer: a state word and a
  few counts, never raw text, app names or addresses. A computer sends it on
  each tick of its history scheduler (`history.report`, at most once per tick,
  in the bulk lane), and the home keeps the latest with when it came
  (`ComputerHistorySql.record_report/4`), shown with its age.

  - `recorder`: `running`, `starting`, `restarting`, `standing_down`,
    `not_running`, `not_answering`, `degraded` (the capturer's own mode,
    `Capturer.status/0`) or `off` (history is switched off there);
  - `events`: the raw events it holds; `unsent` and `oldest_unsent_ts`: those
    not yet sent and the oldest one's stamp; `expired_unsent`: those that
    expired before they were sent (M97 §8.1);
  - `title_only`, `private_unknown`, `ax_refused`: how many apps had each
    coverage gap in the last 48 hours (`Spool.coverage_gaps/2`).
  """

  alias FermixCore.ComputerHistory.Spool

  @version 1
  @states ~w(running starting restarting standing_down not_running not_answering degraded off)
  @counts ~w(events unsent expired_unsent title_only private_unknown ax_refused)
  @keys ["v", "recorder", "oldest_unsent_ts" | @counts]
  @max_count 100_000_000
  @coverage_window_ms :timer.hours(48)
  @modes %{
    capturing: "running",
    handshaking: "starting",
    restarting: "restarting",
    standing_down: "standing_down",
    not_running: "not_running",
    not_answering: "not_answering",
    degraded: "degraded"
  }

  @typedoc "A report as the wire carries it (string keys)."
  @type t :: %{String.t() => term()}

  @doc """
  This machine's report from its store (`spool:`, the `Spool` server), the
  capturer's status (`status:`, `Capturer.status/0`'s shape) and whether
  history records here (`recording?:`), at `now_ms`.
  """
  @spec build(keyword()) :: {:ok, t()} | {:error, term()}
  def build(opts) when is_list(opts) do
    spool = [server: Keyword.fetch!(opts, :spool)]
    now_ms = Keyword.fetch!(opts, :now_ms)

    with {:ok, events} <- Spool.count_events(spool),
         {:ok, {unsent, oldest}} <- Spool.unsent_stats(spool),
         {:ok, %{expired_unsent: expired}} <- Spool.link(spool),
         {:ok, gaps} <- Spool.coverage_gaps(now_ms - @coverage_window_ms, spool) do
      {:ok,
       Map.merge(
         %{
           "v" => @version,
           "recorder" => state(Keyword.fetch!(opts, :recording?), Keyword.fetch!(opts, :status)),
           "events" => events,
           "unsent" => unsent,
           "oldest_unsent_ts" => oldest,
           "expired_unsent" => expired
         },
         coverage(gaps)
       )}
    end
  end

  defp state(false, _status), do: "off"
  defp state(true, %{mode: mode}), do: Map.get(@modes, mode, "not_running")

  # Apps by gap, counted once each, as `/history status` buckets them here.
  defp coverage(gaps) do
    counts =
      gaps
      |> Enum.map(fn {app, reason} -> {app, bucket(reason)} end)
      |> Enum.uniq()
      |> Enum.frequencies_by(&elem(&1, 1))

    Map.new(~w(title_only private_unknown ax_refused), &{&1, Map.get(counts, &1, 0)})
  end

  defp bucket("title_only"), do: "title_only"
  defp bucket("private_unknown"), do: "private_unknown"
  defp bucket("ax_refused" <> _names), do: "ax_refused"
  defp bucket(_other), do: "other"

  @doc "Whether `report` is one the home keeps: `:ok`, or the sentence why not."
  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(report) when is_map(report) do
    cond do
      Map.keys(report) -- @keys != [] or map_size(report) != length(@keys) ->
        {:error, "A report carries exactly its fields."}

      report["v"] != @version ->
        {:error, "A report of another format version."}

      report["recorder"] not in @states ->
        {:error, "A report's recorder state is not one this server knows."}

      not Enum.all?(@counts, &count?(report[&1])) ->
        {:error, "A report's counts are counts."}

      not (is_nil(report["oldest_unsent_ts"]) or is_integer(report["oldest_unsent_ts"])) ->
        {:error, "A report's oldest stamp is a time or nothing."}

      true ->
        :ok
    end
  end

  defp count?(count), do: is_integer(count) and count >= 0 and count <= @max_count

  @doc "Every word `recorder` may be."
  @spec states() :: [String.t()]
  def states, do: @states
end
