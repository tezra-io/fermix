defmodule FermixCore.Companion.OriginBackfill do
  @moduledoc """
  Says where a message came from on the timeline rows written before
  `metadata.origin` existed (`priv/companion/PROTOCOL.md`, *Where a message
  came from*).

  At each start of the primary this task reads the timeline rows a scheduled
  job's or a cue's run sent that carry no `origin` yet (an assistant row
  under `job:<run id>`, the run's text, or `job:<run id>:<part id>`, a
  picture or file it sent), oldest first, a bounded batch at a time, and
  gives each the origin its run gives a row today (`Jobs.Delivery.put_origin/3`,
  checked by `Companion.Protocol.validate_origin_metadata/1` before it is
  written):

    * a run its schedule or Run now started (`schedule`, `manual`): `job` and
      the job's name as the run recorded it, else as the job reads now;
    * a cue run (`cue`): `cue` and the name of the watcher its delivery went
      to;
    * a follow-up's run (`watcher`): `cue` and the name of the watcher whose
      trigger started it.

  Every other key of the row's metadata stays, and the row stores what a row
  written today stores. A row whose run, delivery, trigger or watcher is no
  longer on record, or whose run any other trigger started, is left as it
  was: a name is never made up. A watcher's notice was written with no key,
  so nothing ties it to its watcher and it is never read; neither is a row
  that names an origin already, so a second pass writes nothing.

  Each batch is one read and, when it fills a row, one short write
  transaction through the Repo, and the boot does not wait for any of it. A
  pass reads a bounded number of batches; one stopped there carries on at the
  next start. One line says how many rows it filled in. A history page reads
  the stored metadata, so a client sees the origin the next time it reads
  those rows; nothing is announced.

  `:temporary`: under the core tree's `:rest_for_one` a crash restarts nothing
  after it, and the next start reads again. `start_link/1` takes `:enabled`
  (off under `mix test`); `run/1` takes `:repo`, `:batch_size` and
  `:max_batches`.
  """

  use Task, restart: :temporary

  require Logger

  alias FermixCore.Companion.Protocol
  alias FermixCore.Jobs.Delivery
  alias FermixCore.Memory.Repo

  @batch_size 200
  @max_batches 500

  @type summary :: %{filled: non_neg_integer(), left: non_neg_integer()}

  @spec start_link(keyword()) :: {:ok, pid()} | :ignore
  def start_link(opts) when is_list(opts) do
    if Keyword.fetch!(opts, :enabled),
      do: Task.start_link(__MODULE__, :run, [opts]),
      else: :ignore
  end

  @doc """
  Fills in the origin of every row it can, at most `:max_batches` batches of
  `:batch_size` rows: how many it `filled` and how many it read and `left`
  without one.
  """
  @spec run(keyword()) :: {:ok, summary()} | {:error, term()}
  def run(opts \\ []) when is_list(opts) do
    pass = %{
      repo_opts: [server: Keyword.get(opts, :repo, Repo), on_timeout: :error],
      batch_size: Keyword.get(opts, :batch_size, @batch_size),
      max_batches: Keyword.get(opts, :max_batches, @max_batches)
    }

    pass |> walk(0, 0, %{filled: 0, left: 0}) |> report(pass)
  end

  # --- the walk ------------------------------------------------------------------

  defp walk(%{max_batches: max}, _after_rowid, max, summary), do: {:capped, summary}

  defp walk(pass, after_rowid, batches, summary) do
    with {:ok, candidates} <-
           Repo.mobile_origin_candidates(after_rowid, pass.batch_size, pass.repo_opts),
         {:ok, fills} <- fills(candidates),
         {:ok, filled} <- write(fills, pass.repo_opts) do
      left = length(candidates) - filled
      summary = %{filled: summary.filled + filled, left: summary.left + left}
      next(pass, candidates, batches + 1, summary)
    else
      {:error, reason} -> {:error, reason, summary}
    end
  end

  # A batch shorter than asked for was the last.
  defp next(pass, candidates, _batches, summary) when length(candidates) < pass.batch_size,
    do: {:done, summary}

  defp next(pass, candidates, batches, summary),
    do: walk(pass, List.last(candidates).rowid, batches, summary)

  defp write([], _repo_opts), do: {:ok, 0}
  defp write(fills, repo_opts), do: Repo.fill_mobile_origins(fills, repo_opts)

  # --- one row -------------------------------------------------------------------

  defp fills(candidates) do
    Enum.reduce_while(candidates, {:ok, []}, fn candidate, {:ok, fills} ->
      case fill(candidate) do
        {:ok, fill} -> {:cont, {:ok, [fill | fills]}}
        :none -> {:cont, {:ok, fills}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fill(candidate) do
    with {:ok, origin} <- origin(candidate),
         {:ok, metadata} <- metadata(candidate.metadata_json),
         :ok <- validate(origin, candidate) do
      {:ok,
       candidate
       |> Map.take([:agent_id, :owner_id, :profile_id, :server_seq, :metadata_json])
       |> Map.put(:metadata, Map.put(metadata, "origin", origin))}
    end
  end

  # The origin a run of each trigger gives its messages today (`Jobs.Runner`'s
  # send options): a schedule's or Run now's run names its job, a cue run and
  # a follow-up's run their watcher. Any other trigger, or no run, names none.
  defp origin(%{trigger: trigger} = candidate) when trigger in ["schedule", "manual"],
    do: named(:job, job_name(candidate))

  defp origin(%{trigger: trigger, watcher_name: name}) when trigger in ["cue", "watcher"],
    do: named(:cue, name)

  defp origin(_candidate), do: :none

  # The name the run recorded is what the job was called when it ran.
  defp job_name(%{recorded_job_name: name}) when is_binary(name) and name != "", do: name
  defp job_name(%{job_name: name}), do: name

  defp named(kind, name) do
    case [] |> Delivery.put_origin(kind, name) |> Keyword.fetch(:origin) do
      {:ok, origin} -> {:ok, origin}
      :error -> :none
    end
  end

  # The read keeps only rows with no metadata or an object of it.
  defp metadata(nil), do: {:ok, %{}}

  defp metadata(json) do
    case Jason.decode(json) do
      {:ok, %{} = metadata} -> {:ok, metadata}
      _not_an_object -> :none
    end
  end

  defp validate(origin, candidate) do
    case Protocol.validate_origin_metadata(origin) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_origin, candidate.server_seq, reason}}
    end
  end

  # --- the line ------------------------------------------------------------------

  # Memory off: there is no timeline to fill.
  defp report({:error, :disabled, _summary}, _pass), do: {:ok, %{filled: 0, left: 0}}

  defp report({:done, summary}, _pass) do
    Logger.info("Timeline origins: " <> said(summary))
    {:ok, summary}
  end

  defp report({:capped, summary}, pass) do
    Logger.warning(
      "Timeline origins: " <>
        said(summary) <>
        "; stopped at its cap of #{pass.max_batches} batches, the next start carries on"
    )

    {:ok, summary}
  end

  defp report({:error, reason, summary}, _pass) do
    Logger.error("Timeline origins: stopped (#{inspect(reason)}); " <> said(summary))
    {:error, reason}
  end

  defp said(%{filled: filled, left: left}) do
    "said where #{messages(filled)} from a job or a cue came from; " <>
      "#{left} left without a run, watcher or name on record"
  end

  defp messages(1), do: "1 earlier message"
  defp messages(count), do: "#{count} earlier messages"
end
