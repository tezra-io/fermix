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
  - `apps`: how many apps are chosen there (its `machine.toml`'s allowlist,
    which never travels), never which: none chosen records nothing, which the
    state alone does not say (M102 N15);
  - `events`: the raw events it holds; `unsent` and `oldest_unsent_ts`: those
    not yet sent and the oldest one's stamp; `expired_unsent`: those that
    expired before they were sent (M97 §8.1);
  - `title_only`, `private_unknown`, `ax_refused`: how many apps had each
    coverage gap in the last 48 hours (`Spool.coverage_gaps/2`).

  This is version 2, which added `apps` (D8). A computer can be older than
  its server, so the home keeps exactly a version 1 report (no `apps`) or
  exactly a version 2 one; a server older than this report refuses it until
  it updates, and shows the last one it kept, with its age.
  """

  alias FermixCore.ComputerHistory.Spool

  @version 2
  @states ~w(running starting restarting standing_down not_running not_answering degraded off)
  # The counts of each version the home keeps.
  @counts %{
    1 => ~w(events unsent expired_unsent title_only private_unknown ax_refused),
    2 => ~w(apps events unsent expired_unsent title_only private_unknown ax_refused)
  }
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
  capturer's status (`status:`, `Capturer.status/0`'s shape), whether
  history records here (`recording?:`) and how many apps are chosen here
  (`apps:`, a count), at `now_ms`.
  """
  @spec build(keyword()) :: {:ok, t()} | {:error, term()}
  def build(opts) when is_list(opts) do
    spool = [server: Keyword.fetch!(opts, :spool)]
    now_ms = Keyword.fetch!(opts, :now_ms)
    apps = count!(Keyword.fetch!(opts, :apps))

    with {:ok, events} <- Spool.count_events(spool),
         {:ok, {unsent, oldest}} <- Spool.unsent_stats(spool),
         {:ok, %{expired_unsent: expired}} <- Spool.link(spool),
         {:ok, gaps} <- Spool.coverage_gaps(now_ms - @coverage_window_ms, spool) do
      {:ok,
       Map.merge(
         %{
           "v" => @version,
           "recorder" => state(Keyword.fetch!(opts, :recording?), Keyword.fetch!(opts, :status)),
           "apps" => apps,
           "events" => events,
           "unsent" => unsent,
           "oldest_unsent_ts" => oldest,
           "expired_unsent" => expired
         },
         coverage(gaps)
       )}
    end
  end

  defp count!(apps) when is_integer(apps) and apps >= 0, do: apps

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

  @doc """
  Whether `report` is one the home keeps, exactly a version 1 or exactly a
  version 2 report: `:ok`, or the sentence why not.
  """
  @spec validate(map()) :: :ok | {:error, String.t()}
  def validate(report) when is_map(report) do
    case Map.fetch(@counts, report["v"]) do
      {:ok, counts} -> validate(report, counts)
      :error -> {:error, "A report of another format version."}
    end
  end

  defp validate(report, counts) do
    keys = ["v", "recorder", "oldest_unsent_ts" | counts]

    cond do
      Map.keys(report) -- keys != [] or map_size(report) != length(keys) ->
        {:error, "A report carries exactly its fields."}

      report["recorder"] not in @states ->
        {:error, "A report's recorder state is not one this server knows."}

      not Enum.all?(counts, &count?(report[&1])) ->
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
