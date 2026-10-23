defmodule FermixCore.Cues.Overview do
  @moduledoc """
  What the setup page and the management socket (`cues.*`, M60 app surface
  §3.3) show about the cue subsystem beside its settings (M60 §15): the
  door's state, each source's status row and its counts over the last day,
  the watchers with their counts, each mandate's calls over the last day, and
  the jobs that run on cues. Reads only.

  Nothing here carries cue text: a watcher is its ids, switches and counts, and
  a source is Fermix's own status columns. Watchers are made in chat (design
  §8.1), so the page lists them and changes nothing.

  Every read takes `:repo` (default `Memory.Repo`) or a door server, so a test
  names its own; `:mandate_opts` carries the `Cues.Mandates` and `Cues.Pins`
  seams. Memory switched off answers `{:error, :memory_off}`.
  """

  alias FermixCore.Cues.Deliveries
  alias FermixCore.Cues.Door
  alias FermixCore.Cues.Mandates
  alias FermixCore.Cues.Pins
  alias FermixCore.Jobs.Registry, as: JobRegistry
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesDeliveriesSql
  alias FermixCore.Memory.Repo.CuesFilterSql
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixCore.Memory.Repo.CuesWatchersSql

  @window_s 86_400
  # Delivery states counted as waiting for the filter and as passed by it.
  @waiting_states ~w(pending filtering)
  @passed_states ~w(passed claimed acked)
  # Delivery outcomes counted as a task that acted, and as a failure.
  @failed_outcomes ~w(filter_failed task_failed failed_after_action)
  @mandate_decisions %{"allow" => :allowed, "propose" => :proposed, "refuse" => :refused}

  @type door ::
          {:listening, String.t(), :inet.port_number()}
          | {:unavailable, Door.failure()}
          | :not_running

  @type watcher :: %{
          id: String.t(),
          name: String.t(),
          filter: String.t(),
          sources: [String.t()],
          task_job_id: String.t(),
          task_name: String.t() | nil,
          enabled?: boolean(),
          held?: boolean(),
          waiting: non_neg_integer(),
          passed: non_neg_integer(),
          dropped: non_neg_integer(),
          acted: non_neg_integer(),
          failed: non_neg_integer(),
          filter_provider: String.t() | nil,
          filter_model: String.t() | nil,
          daily_cap: non_neg_integer(),
          filter_budget: non_neg_integer(),
          task_notes?: boolean(),
          task_paused?: boolean(),
          instruction_count: non_neg_integer(),
          created_at: DateTime.t() | nil
        }

  @type mandate_counts :: %{
          allowed: non_neg_integer(),
          proposed: non_neg_integer(),
          refused: non_neg_integer()
        }

  @doc "How long the watcher counts look back."
  @spec window_s() :: pos_integer()
  def window_s, do: @window_s

  @doc """
  The door's state: listening with its address, unavailable with the reason,
  or `:not_running` when no door process runs (cues off, or not yet restarted).
  """
  @spec door(GenServer.server()) :: door()
  def door(server) do
    case GenServer.whereis(server) do
      nil -> :not_running
      _pid -> door_status(Door.status(server))
    end
  end

  defp door_status({:listening, {ip, port}}), do: {:listening, ip_text(ip), port}
  defp door_status({:unavailable, failure}), do: {:unavailable, failure}

  defp ip_text(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()

  @doc "Every `cue_sources` row, by source ref."
  @spec sources(keyword()) :: {:ok, %{String.t() => map()}} | {:error, :memory_off | term()}
  def sources(opts) when is_list(opts) do
    with {:ok, rows} <- call(CuesSql, {:list_sources}, opts) do
      {:ok, Map.new(rows, &{&1.source_ref, &1})}
    end
  end

  @doc """
  Every source's counts over the day before `now`, by source ref, from
  `Cues.Deliveries.summary/2`: `cues` received, `routed` to a watcher,
  `not_routed`, `open_gaps`, and the enabled and paused watchers listening.
  """
  @spec source_summary(DateTime.t(), keyword()) ::
          {:ok, %{String.t() => map()}} | {:error, :memory_off | term()}
  def source_summary(%DateTime{} = now, opts) when is_list(opts) do
    since = DateTime.add(now, -@window_s, :second)

    result =
      with :ok <- running(opts),
           {:ok, summary} <- Deliveries.summary(%{since: since}, repo: repo(opts)) do
        {:ok, Map.new(summary.sources, &{&1.source_ref, &1})}
      end

    memory_off(result)
  end

  @doc """
  How many mandate calls each mandate decided in the day before `now`, by
  mandate name: `allowed`, `proposed` and `refused`.
  """
  @spec mandate_counts(DateTime.t(), keyword()) ::
          {:ok, %{String.t() => mandate_counts()}} | {:error, :memory_off | term()}
  def mandate_counts(%DateTime{} = now, opts) when is_list(opts) do
    since = DateTime.add(now, -@window_s, :second)

    with {:ok, groups} <- call(CuesDeliveriesSql, {:mandate_summary, since}, opts) do
      {:ok, Enum.reduce(groups, %{}, &add_mandate_group/2)}
    end
  end

  defp add_mandate_group(%{mandate: name, decision: decision, count: count}, acc) do
    key = Map.fetch!(@mandate_decisions, decision)
    counts = Map.get(acc, name, %{allowed: 0, proposed: 0, refused: 0})
    Map.put(acc, name, Map.update!(counts, key, &(&1 + count)))
  end

  @doc """
  Every watcher, by name, with its task's name and whether the task is paused,
  whether its filter is held by provider failures, its filter model, budgets
  and instruction count, and its deliveries received in the day before `now`:
  `waiting` (pending or being filtered), `passed`, `dropped`, and the ones
  whose task `acted` or that `failed`.
  """
  @spec watchers(DateTime.t(), keyword()) :: {:ok, [watcher()]} | {:error, :memory_off | term()}
  def watchers(%DateTime{} = now, opts) when is_list(opts) do
    since = DateTime.add(now, -@window_s, :second)

    result =
      with {:ok, watchers} <- call(CuesWatchersSql, {:list_watchers}, opts),
           {:ok, held} <- call(CuesFilterSql, {:held_watchers}, opts),
           {:ok, summary} <- Deliveries.summary(%{since: since}, repo: repo(opts)),
           {:ok, jobs} <- cue_jobs(opts, & &1) do
        held_ids = MapSet.new(held, & &1.watcher_id)
        counts = Map.new(summary.watchers, &{&1.watcher_id, &1})
        jobs = Map.new(jobs, &{&1.id, &1})

        {:ok, Enum.map(watchers, &watcher_view(&1, held_ids, counts, jobs))}
      end

    memory_off(result)
  end

  @doc """
  The jobs that run on cues (a mandate's possible jobs), as `id`, `name` and
  whether the job is paused.
  """
  @spec cue_jobs(keyword()) ::
          {:ok, [%{id: String.t(), name: String.t(), paused?: boolean()}]} | {:error, term()}
  def cue_jobs(opts) when is_list(opts), do: cue_jobs(opts, &JobRegistry.cue_job?/1)

  defp cue_jobs(opts, keep?) do
    result =
      with :ok <- running(opts),
           {:ok, jobs} <- JobRegistry.list_jobs(repo: repo(opts)) do
        {:ok, jobs |> Enum.filter(keep?) |> Enum.map(&job_view/1)}
      end

    memory_off(result)
  end

  defp job_view(job), do: %{id: job.id, name: job.name, paused?: Map.get(job, :enabled?) == false}

  @doc """
  Every mandate in `cues` (the `[fermix_core.cues]` keyword), with its load
  status from `Cues.Mandates` (active, or inactive with the reason) and where
  its approval stands (`Cues.Pins.status/2`), or the error that kept it unread.
  """
  @spec mandates(keyword(), keyword()) :: [
          %{mandate: Mandates.t(), approval: {:ok, Pins.status()} | {:error, term()}}
        ]
  def mandates(cues, opts) when is_list(cues) and is_list(opts) do
    mandate_opts = mandate_opts(cues, opts)

    mandate_opts
    |> Mandates.load()
    |> Enum.map(&%{mandate: &1, approval: approval(&1.name, mandate_opts)})
  end

  @doc "The options `Cues.Mandates` and `Cues.Pins` take for `cues`, with the page's seams."
  @spec mandate_opts(keyword(), keyword()) :: keyword()
  def mandate_opts(cues, opts) when is_list(cues) and is_list(opts),
    do: [config: cues, repo: repo(opts)] ++ Keyword.get(opts, :mandate_opts, [])

  defp approval(name, opts) do
    result = with :ok <- running(opts), do: Pins.status(name, opts)
    memory_off(result)
  end

  defp watcher_view(watcher, held_ids, counts, jobs) do
    summary = Map.get(counts, watcher.id, %{})
    by_state = Map.get(summary, :by_state, %{})
    by_outcome = Map.get(summary, :by_outcome, %{})
    job = Map.get(jobs, watcher.task_job_id, %{})

    %{
      id: watcher.id,
      name: watcher.name,
      filter: watcher.filter,
      sources: watcher.sources,
      task_job_id: watcher.task_job_id,
      task_name: Map.get(job, :name),
      enabled?: watcher.enabled?,
      held?: MapSet.member?(held_ids, watcher.id),
      waiting: count(by_state, @waiting_states),
      passed: count(by_state, @passed_states),
      dropped: count(by_state, ["dropped"]),
      acted: count(by_outcome, ["acted"]),
      failed: count(by_outcome, @failed_outcomes),
      filter_provider: watcher.filter_provider,
      filter_model: watcher.filter_model,
      daily_cap: watcher.daily_cap,
      filter_budget: watcher.filter_budget,
      task_notes?: watcher.task_notes?,
      task_paused?: Map.get(job, :paused?, false),
      instruction_count: Map.get(watcher, :active_instructions, 0),
      created_at: watcher.created_at
    }
  end

  defp count(by_state, states), do: states |> Enum.map(&Map.get(by_state, &1, 0)) |> Enum.sum()

  defp call(module, request, opts) do
    result =
      with :ok <- running(opts), do: Repo.cues_call(module, request, server: repo(opts))

    memory_off(result)
  end

  # A Repo that is not running at all is not memory switched off: it is named.
  defp running(opts) do
    case GenServer.whereis(repo(opts)) do
      nil -> {:error, :repo_not_running}
      _pid -> :ok
    end
  end

  defp memory_off({:error, :disabled}), do: {:error, :memory_off}
  defp memory_off(result), do: result

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)
end
