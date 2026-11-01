defmodule FermixCore.Cues.Overview do
  @moduledoc """
  What the setup page and the management socket (`cues.*`, M60 app surface
  §3.3) show about the cue subsystem beside its settings (M60 §15): the
  door's state, each source's status row and its counts over the last day,
  the watchers with their counts, each mandate's calls over the last day, and
  the jobs that run on cues. Reads only.

  Nothing here carries cue text: a watcher is its ids, switches and counts, and
  a source is Fermix's own status columns. Watchers are made in chat (design
  §8.1), so the page lists them and changes nothing but a follow-up's Always
  allow, which it only takes back (`Cues.Watchers.ask_first/3`).

  A stream keeps only what passes (M60_CUE_INTAKE_AT_SCALE.md §3.4), so what it
  received and what its watchers were offered or judged without keeping are
  hourly counts (`cue_counts`, `counted/3`); the delivery rows still count
  every pass and everything a feed, webhook or local push sent.

  Every read takes `:repo` (default `Memory.Repo`) or a door server, so a test
  names its own; `:cues_config` (the `[fermix_core.cues]` keyword, default the
  application's) names the stream sources a watcher's state reads;
  `:mandate_opts` carries the `Cues.Mandates` and `Cues.Pins` seams, and
  `:follow_up_opts` the `Cues.FollowUpReadiness` seams a watcher's follow-up
  reads. Memory switched off answers `{:error, :memory_off}`.
  """

  alias FermixCore.Cues.Deliveries
  alias FermixCore.Cues.Door
  alias FermixCore.Cues.Filter.Decision
  alias FermixCore.Cues.FollowUps
  alias FermixCore.Cues.Mandates
  alias FermixCore.Cues.Pins
  alias FermixCore.Cues.Watchers
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
  # What a stream source counted that reached no watcher, and what a stream
  # watcher counted as dropped and as failed, without a row.
  @unrouted_phases ~w(unmatched rate_limited over_budget invalid stale)
  @failed_phases ~w(filter_failed write_failed)
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
          task_job_id: String.t() | nil,
          task_name: String.t() | nil,
          follow_up: follow_up() | nil,
          enabled?: boolean(),
          held?: boolean(),
          held_sentence: String.t() | nil,
          needs_update: Watchers.update_needed(),
          offered: non_neg_integer(),
          waiting: non_neg_integer(),
          passed: non_neg_integer(),
          dropped: non_neg_integer(),
          acted: non_neg_integer(),
          failed: non_neg_integer(),
          daily_cap: non_neg_integer(),
          filter_budget: non_neg_integer(),
          task_notes?: boolean(),
          task_paused?: boolean(),
          instruction_count: non_neg_integer(),
          created_at: DateTime.t() | nil
        }

  @typedoc """
  A watcher's follow-up (M60_WATCHER_CODING_RUNS.md §3.5): its job and name,
  whether the owner's Always allow lets it run with no card for what it runs
  and what sets it off now (else it asks first), and Fermix's sentence while
  it is held (`Cues.FollowUps.held/2`), else nil.
  """
  @type follow_up :: %{
          job_id: String.t(),
          name: String.t() | nil,
          always_allowed?: boolean(),
          held: String.t() | nil,
          paused?: boolean()
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
  `not_routed`, `open_gaps`, and the enabled and paused watchers listening. A
  stream keeps only what passes, so its `cues`, `routed` and `not_routed` are
  its counts (`counted/3`, scope `source`, which only a stream writes):
  `received`, less what reached no watcher.
  """
  @spec source_summary(DateTime.t(), keyword()) ::
          {:ok, %{String.t() => map()}} | {:error, :memory_off | term()}
  def source_summary(%DateTime{} = now, opts) when is_list(opts) do
    since = DateTime.add(now, -@window_s, :second)

    result =
      with :ok <- running(opts),
           {:ok, summary} <- Deliveries.summary(%{since: since}, repo: repo(opts)),
           {:ok, counted} <- counted("source", now, opts) do
        {:ok, Map.new(summary.sources, &{&1.source_ref, stream_arrivals(&1, counted)})}
      end

    memory_off(result)
  end

  @doc """
  What streams counted rather than stored (M60_CUE_INTAKE_AT_SCALE.md §3.4), by
  ref, over the hours of the day before `now`, summed across process
  incarnations: per `"source"`, `received`, `unmatched`, `rate_limited`,
  `over_budget`, `invalid` and `stale`; per `"watcher"` (by id), `offered`,
  `overflow`, `over_budget`, `dropped`, `filter_failed`, `write_failed` and
  `passed`. A phase never counted is absent.
  """
  @spec counted(String.t(), DateTime.t(), keyword()) ::
          {:ok, %{String.t() => %{String.t() => non_neg_integer()}}}
          | {:error, :memory_off | term()}
  def counted(scope, %DateTime{} = now, opts)
      when scope in ["source", "watcher"] and is_list(opts) do
    since = DateTime.add(now, -@window_s, :second)
    call(CuesSql, {:counts_window, scope, since}, opts)
  end

  defp stream_arrivals(source, counted) do
    case Map.fetch(counted, source.source_ref) do
      :error ->
        source

      {:ok, counts} ->
        received = Map.get(counts, "received", 0)
        unrouted = count(counts, @unrouted_phases)
        %{source | cues: received, routed: max(received - unrouted, 0), not_routed: unrouted}
    end
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
  its follow-up (`t:follow_up/0`), whether its filter is held by provider
  failures and, for a hold whose cause is the screen's decision model, Fermix's
  sentence naming it (`held_sentence`, `filter_hold/2`), the update it needs to keep
  the rules (`Cues.Watchers.update_needed/2`), its budgets and instruction
  count, and what it received in the day before `now`: `offered` (every item
  its words let through, kept or not), `waiting` (pending or being filtered),
  `passed`, `dropped`, and the ones whose task `acted` or that `failed`. A
  stream watcher's offers, drops and failures are counted, not stored
  (`counted/3`).
  """
  @spec watchers(DateTime.t(), keyword()) :: {:ok, [watcher()]} | {:error, :memory_off | term()}
  def watchers(%DateTime{} = now, opts) when is_list(opts) do
    since = DateTime.add(now, -@window_s, :second)

    result =
      with {:ok, watchers} <- call(CuesWatchersSql, {:list_watchers}, opts),
           {:ok, held} <- call(CuesFilterSql, {:held_watchers}, opts),
           {:ok, summary} <- Deliveries.summary(%{since: since}, repo: repo(opts)),
           {:ok, counted} <- counted("watcher", now, opts),
           {:ok, jobs} <- all_jobs(opts),
           {:ok, follow_ups} <- follow_ups(watchers, jobs, opts) do
        facts = %{
          held_ids: MapSet.new(held, & &1.watcher_id),
          screen_hold: Decision.no_route_sentence(cues_config(opts)),
          stored: Map.new(summary.watchers, &{&1.watcher_id, &1}),
          counted: counted,
          jobs: Map.new(jobs, &{&1.id, job_view(&1)}),
          follow_ups: follow_ups,
          streams: Watchers.stream_refs(opts)
        }

        {:ok, Enum.map(watchers, &watcher_view(&1, facts))}
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
    with {:ok, jobs} <- all_jobs(opts),
         do: {:ok, jobs |> Enum.filter(keep?) |> Enum.map(&job_view/1)}
  end

  defp all_jobs(opts) do
    result = with :ok <- running(opts), do: JobRegistry.list_jobs(repo: repo(opts))
    memory_off(result)
  end

  # Each follow-up, by watcher id: its job's name, how it runs, and whether it is
  # held now. A follow-up whose job is gone has no row.
  defp follow_ups(watchers, jobs, opts) do
    by_id = Map.new(jobs, &{&1.id, &1})
    held_opts = Keyword.take(opts, [:cues_config]) ++ Keyword.get(opts, :follow_up_opts, [])

    watchers
    |> Enum.filter(&Map.has_key?(by_id, &1.follow_up_job_id))
    |> Enum.reduce_while({:ok, %{}}, fn watcher, {:ok, acc} ->
      case follow_up_view(watcher, Map.fetch!(by_id, watcher.follow_up_job_id), held_opts, opts) do
        {:ok, view} -> {:cont, {:ok, Map.put(acc, watcher.id, view)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp follow_up_view(watcher, job, held_opts, opts) do
    with {:ok, allowed?} <- Watchers.always_allowed(watcher, repo: repo(opts)) do
      {:ok,
       %{
         job_id: job.id,
         name: job.name,
         always_allowed?: allowed?,
         held: held_sentence(FollowUps.held(job, held_opts)),
         paused?: Map.get(job, :enabled?) == false
       }}
    end
  end

  defp held_sentence(nil), do: nil
  defp held_sentence({_label, sentence}), do: sentence

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

  # A stream's pass is both a stored delivery and a counted offer, so
  # `offered` takes the stored deliveries from every other source plus what
  # the streams counted as offered.
  defp watcher_view(watcher, facts) do
    stored = Map.get(facts.stored, watcher.id, %{})
    by_state = Map.get(stored, :by_state, %{})
    by_outcome = Map.get(stored, :by_outcome, %{})
    live = Map.get(facts.counted, watcher.id, %{})
    job = Map.get(facts.jobs, watcher.task_job_id, %{})
    not_streamed = stored |> Map.get(:by_source, %{}) |> Map.drop(facts.streams)

    %{
      id: watcher.id,
      name: watcher.name,
      filter: watcher.filter,
      sources: watcher.sources,
      task_job_id: watcher.task_job_id,
      task_name: Map.get(job, :name),
      follow_up: Map.get(facts.follow_ups, watcher.id),
      enabled?: watcher.enabled?,
      held?: MapSet.member?(facts.held_ids, watcher.id),
      held_sentence: held_sentence(MapSet.member?(facts.held_ids, watcher.id), facts.screen_hold),
      needs_update: Watchers.update_needed(watcher, facts.streams),
      offered: Enum.sum(Map.values(not_streamed)) + count(live, ["offered"]),
      waiting: count(by_state, @waiting_states),
      passed: count(by_state, @passed_states),
      dropped: count(by_state, ["dropped"]) + count(live, ["dropped"]),
      acted: count(by_outcome, ["acted"]),
      failed: count(by_outcome, @failed_outcomes) + count(live, @failed_phases),
      daily_cap: watcher.daily_cap,
      filter_budget: watcher.filter_budget,
      task_notes?: watcher.task_notes?,
      task_paused?: Map.get(job, :paused?, false),
      instruction_count: Map.get(watcher, :active_instructions, 0),
      created_at: watcher.created_at
    }
  end

  # A held filter's every call meets the screen first, so while the screen's
  # decision model cannot run, that is what holds it. Any other hold is a
  # provider's failure, whose words reach no surface.
  defp held_sentence(true, screen_hold), do: screen_hold
  defp held_sentence(false, _screen_hold), do: nil

  @doc """
  Watcher `id`'s filter hold in Fermix's own words: the screen's sentence
  (`Cues.Filter.Decision.no_route_sentence/1`) while its filter is held and the
  screen's decision model cannot run, else nil. Takes `:repo` and
  `:cues_config`.
  """
  @spec filter_hold(String.t(), keyword()) ::
          {:ok, String.t() | nil} | {:error, :memory_off | term()}
  def filter_hold(id, opts) when is_binary(id) and is_list(opts) do
    with {:ok, held} <- call(CuesFilterSql, {:held_watchers}, opts) do
      held? = Enum.any?(held, &(&1.watcher_id == id))
      {:ok, held_sentence(held?, Decision.no_route_sentence(cues_config(opts)))}
    end
  end

  defp cues_config(opts),
    do:
      Keyword.get_lazy(opts, :cues_config, fn -> Application.get_env(:fermix_core, :cues, []) end)

  defp count(counts, keys), do: keys |> Enum.map(&Map.get(counts, &1, 0)) |> Enum.sum()

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
