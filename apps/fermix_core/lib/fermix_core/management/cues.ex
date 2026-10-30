defmodule FermixCore.Management.Cues do
  @moduledoc """
  The `cues.*` methods of the management socket (M60 app surface §3.1 to
  §3.6): the cue subsystem's status, its sources, watchers and mandates, and
  the proposals waiting for the owner.

  **Every build publishes them** (D1), and every build has cues, so
  `cues.status` always answers `available: true`. With memory off,
  `cues.status` says so (`needs_memory`), the lists are drawn from
  configuration, and the reads that need rows (watchers, proposals, the
  mandate choices) answer `unavailable` with the daemon's sentence.

  **One write path.** Every write calls the `Cues.Settings` function the
  setup page calls (and a webhook's address `Cues.Webhook.ensure_path_secret/2`),
  so the outside-edit refusal, the baseline re-record, the secret take-back
  and `Cues.SourceManager.reconcile/0` apply identically from either door.
  Nothing here writes `config.toml`.

  **Two values handed out.** A new local push source's first token
  (`cues.sources.add`) and a fresh one (`cues.sources.token.new`) are returned
  once and never logged, traced or kept; a webhook's address is returned by
  `cues.sources.url.get` alone, on every ask. Neither is on a list.

  Watchers are read-only here: changing what a watcher reads is a consent
  turn in chat. Which callers may write is the daemon socket's owner check
  (`Fermix.CLI.Daemon`), not this module's.

  Seams (opts): `:memory?`, `:running?` (booleans for memory and the cue
  tree), `:config` (the normalized
  `[fermix_core.cues]` keyword a read uses in place of the applied one),
  `:repo`, `:door`, `:now` (zero-arity, a
  `DateTime`), `:mandate_opts` (the `Cues.Mandates` and `Cues.Pins` seams),
  `:plugins` and `:enabled_plugins` (zero-arity: the plugin list and the
  enabled names the mandate choices read), `:proposals` (the module that
  answers `records/2`, `card/2` and `decide/4`, default `Cues.Proposals`), and
  `:follow_up_opts` (the `Cues.FollowUpReadiness` seams a watcher's follow-up
  reads).
  """

  require Logger

  alias FermixCore.Cues
  alias FermixCore.Cues.Config, as: CuesConfig
  alias FermixCore.Cues.Deliveries
  alias FermixCore.Cues.Overview
  alias FermixCore.Cues.Settings, as: CueSettings
  alias FermixCore.Cues.Webhook
  alias FermixCore.Management.Cues.MandateRow
  alias FermixCore.Management.Cues.SourceForm
  alias FermixCore.Management.Cues.SourceRow
  alias FermixCore.Management.Cues.WatcherRow
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesWatchersSql
  alias FermixCore.Plugins.Config, as: PluginsConfig
  alias FermixCore.Plugins.Registry, as: PluginRegistry
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.SecretWriter

  @capability "cues"
  @memory_off_sentence "Cues keep their records in memory, which is off."
  @owner_sentence "Only the owner can change cues: use the Fermix app or your own terminal."
  @door FermixCore.Cues.Door
  @max_watchers 200
  @max_gaps 20
  @max_tools 200
  @approved_from "Fermix app"
  @management_origin %{surface: :management, device_id: nil}

  @type error ::
          {:unavailable, String.t(), String.t()}
          | {:invalid_params, String.t(), String.t()}
          | {:external_change, [String.t()]}
          | {:config_unreadable, String.t()}
          | {:secret_store_failed, String.t(), String.t()}

  @doc "The capability every refusal of this family names."
  @spec capability() :: String.t()
  def capability, do: @capability

  @doc "The sentence a caller the daemon does not place as the owner is refused with."
  @spec owner_only_sentence() :: String.t()
  def owner_only_sentence, do: @owner_sentence

  @doc "The sentence a read that needs rows answers with memory off."
  @spec memory_off_sentence() :: String.t()
  def memory_off_sentence, do: @memory_off_sentence

  # --- status ------------------------------------------------------------------

  @doc """
  `cues.status`: the switches, the cue tree,
  memory, the door, and the counts the pane's header and the menu bar read.
  """
  @spec status(keyword()) :: {:ok, map()}
  def status(opts \\ []) when is_list(opts) do
    facts = facts(opts)
    {state, sentence} = state(facts)

    {:ok,
     %{
       "available" => true,
       "enabled" => facts.enabled?,
       "running" => facts.running?,
       "memory_enabled" => facts.memory?,
       "mandates_enabled" => CuesConfig.mandates_enabled?(cue_config(opts)),
       "state" => state,
       "status_sentence" => sentence,
       "door" => door(opts),
       "counts" => counts(facts, opts)
     }}
  end

  defp state(%{enabled?: true, memory?: false}), do: {"needs_memory", @memory_off_sentence}
  defp state(%{enabled?: true, running?: true}), do: {"running", "Cues are running."}
  defp state(%{enabled?: false, running?: false}), do: {"off", "Cues are off."}
  defp state(%{enabled?: true}), do: {"needs_restart", "Restart Fermix to start cues."}
  defp state(_running_but_off), do: {"needs_restart", "Restart Fermix to stop cues."}

  defp door(opts) do
    port = CuesConfig.door_port(cue_config(opts))

    case door_state(opts) do
      {:listening, _ip, listening} ->
        door_view("listening", listening, nil, "The door is listening on this Mac.")

      {:unavailable, failure} ->
        door_view("unavailable", port, Atom.to_string(failure), door_failure(failure, port))

      :not_running ->
        door_view("not_running", port, nil, "The door is not running.")
    end
  end

  defp door_state(opts), do: Overview.door(Keyword.get(opts, :door, @door))

  defp door_view(state, port, reason, sentence),
    do: %{"state" => state, "port" => port, "reason" => reason, "sentence" => sentence}

  defp door_failure(:address_in_use, port),
    do: "The door could not listen: another program uses port #{port}."

  defp door_failure(:permission_denied, port),
    do: "The door could not listen: this account may not use port #{port}."

  defp door_failure(:address_unavailable, _port),
    do: "The door could not listen: this Mac's own address is not available."

  defp door_failure(_listen_failed, port), do: "The door could not listen on port #{port}."

  defp counts(facts, opts) do
    sources = source_rows(facts, opts)
    watchers = watcher_rows(facts, opts)
    mandates = mandate_rows(facts, opts)

    %{
      "sources" => length(sources),
      "sources_attention" => Enum.count(sources, &(&1["state"] in SourceRow.attention_states())),
      "watchers" => readable_length(watchers),
      "watchers_held" => readable_count(watchers, &(&1["state"] == "held")),
      "mandates" => length(mandates),
      "mandates_attention" => Enum.count(mandates, &mandate_attention?/1),
      "proposals_waiting" => waiting_count(facts, opts)
    }
  end

  defp readable_length({:ok, rows}), do: length(rows)
  defp readable_length({:error, _reason}), do: 0
  defp readable_count({:ok, rows}, keep?), do: Enum.count(rows, keep?)
  defp readable_count({:error, _reason}, _keep?), do: 0

  defp mandate_attention?(row),
    do: row["load"]["state"] == "inactive" or row["primary_action"] == "approve"

  defp waiting_count(%{memory?: false}, _opts), do: 0

  defp waiting_count(_facts, opts) do
    case proposals(opts).records(:waiting, proposal_opts(opts)) do
      {:ok, records} ->
        length(records)

      {:error, reason} ->
        Logger.warning("cues.status could not count waiting proposals: #{inspect(reason)}")
        0
    end
  end

  # --- sources -------------------------------------------------------------------

  @doc "`cues.sources.list`: every source's row, whether one more can be added, and the bound."
  @spec sources_list(keyword()) :: {:ok, map()} | {:error, error()}
  def sources_list(opts \\ []) when is_list(opts) do
    rows = source_rows(facts(opts), opts)
    max = CuesConfig.max_sources()

    {:ok,
     %{
       "sources" => Enum.take(rows, max),
       "can_add" => length(rows) < max,
       "limits" => %{"max_sources" => max}
     }}
  end

  @doc """
  `cues.sources.get`: one source's row, its editable fields as settings rows,
  its open gaps (at most 20) and its refused requests by reason.
  """
  @spec sources_get(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def sources_get(ref, opts \\ []) when is_binary(ref) and is_list(opts) do
    with {:ok, source} <- fetch_source(ref, opts),
         {:ok, section} <- values_section(ref, opts) do
      facts = facts(opts)
      db_row = Map.get(readable(Overview.sources(repo_opts(opts)), "sources"), ref)

      {:ok,
       %{
         "source" => source_row(source, db_row, facts, opts),
         "values" => SourceForm.values(section, source),
         "gaps" => gaps(ref, facts, opts),
         "rejected" => rejected(db_row)
       }}
    end
  end

  @doc "`cues.sources.form`: the add form for a kind, preset and verification method."
  @spec sources_form(String.t() | nil, String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, error()}
  def sources_form(kind, preset, verify, opts \\ []) when is_list(opts) do
    kind |> SourceForm.form(preset, verify) |> refused_field()
  end

  @doc """
  `cues.sources.add`: saves a new source from its form values and answers its
  row, plus the first token of a new local push source, returned once.
  """
  @spec sources_add(String.t(), String.t() | nil, String.t() | nil, map(), keyword()) ::
          {:ok, map()} | {:error, error()}
  def sources_add(ref, kind, preset, values, opts \\ [])
      when is_binary(ref) and is_map(values) and is_list(opts) do
    with {:ok, section} <- kind |> SourceForm.new_section(preset, values) |> refused_field(),
         {:ok, %{token: token}} <-
           save(CueSettings.save_source(ref, section, %{}, :create), "ref"),
         {:ok, source} <- fetch_source(ref, opts) do
      {:ok, %{"source" => source_row(source, opts), "token" => token}}
    end
  end

  @doc "`cues.sources.update`: changes the fields `values` names and answers the row."
  @spec sources_update(String.t(), map(), keyword()) :: {:ok, map()} | {:error, error()}
  def sources_update(ref, values, opts \\ []) when is_binary(ref) and is_map(values) do
    with {:ok, source} <- fetch_source(ref, opts),
         {:ok, section} <- saved_section(:sources, ref, "ref"),
         kept = drop_secrets(section),
         {:ok, merged} <-
           section |> drop_secrets() |> SourceForm.merge(source, values) |> refused_field(),
         {:ok, _saved} <- save_changed(ref, kept, merged) do
      source_answer(ref, opts)
    end
  end

  # An update that changes nothing writes nothing.
  defp save_changed(_ref, same, same), do: {:ok, :unchanged}

  defp save_changed(ref, _kept, merged),
    do: save(CueSettings.save_source(ref, merged, %{}, :update), "ref")

  @doc """
  `cues.sources.remove`: removes a source and its stored secrets, and answers
  any secret that could not be deleted (`left`) and the watchers that
  listened to it.
  """
  @spec sources_remove(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def sources_remove(ref, opts \\ []) when is_binary(ref) and is_list(opts) do
    with {:ok, _source} <- fetch_source(ref, opts) do
      watchers = listeners(ref, opts)

      with {:ok, %{left: left}} <- save(CueSettings.remove_source(ref), "ref") do
        {:ok, %{"ref" => ref, "removed" => true, "left" => left, "watchers" => watchers}}
      end
    end
  end

  @doc "`cues.sources.enable` / `.disable`: turns a source on or off and answers its row."
  @spec sources_switch(String.t(), boolean(), keyword()) :: {:ok, map()} | {:error, error()}
  def sources_switch(ref, enabled?, opts \\ []) when is_binary(ref) and is_boolean(enabled?) do
    with {:ok, _source} <- fetch_source(ref, opts),
         {:ok, _saved} <- save(CueSettings.set_enabled(:sources, ref, enabled?), "ref") do
      source_answer(ref, opts)
    end
  end

  @doc """
  `cues.sources.token.new`: a fresh token for a local push source, returned
  once. The old one stops working within a minute.
  """
  @spec sources_token_new(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def sources_token_new(ref, opts \\ []) when is_binary(ref) and is_list(opts) do
    with {:ok, _source} <- fetch_source(ref, opts),
         {:ok, token} <- save(CueSettings.new_token(ref), "ref") do
      {:ok, %{"ref" => ref, "token" => token}}
    end
  end

  @doc """
  `cues.sources.url.get`: a webhook source's address on the door, made on the
  first call and the same on every later one. Never on a list.
  """
  @spec sources_url_get(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def sources_url_get(ref, opts \\ []) when is_binary(ref) and is_list(opts) do
    with {:ok, _source} <- fetch_source(ref, opts) do
      case Webhook.ensure_path_secret(ref) do
        {:ok, path} -> {:ok, %{"ref" => ref, "url" => door_url(opts) <> path, "path" => path}}
        {:error, sentence} when is_binary(sentence) -> invalid("ref", sentence)
        {:error, refusal} -> save({:error, refusal}, "ref")
      end
    end
  end

  defp door_url(opts) do
    port =
      case door_state(opts) do
        {:listening, _ip, port} -> port
        _not_listening -> CuesConfig.door_port(cue_config(opts))
      end

    "http://127.0.0.1:#{port}"
  end

  defp source_answer(ref, opts) do
    with {:ok, source} <- fetch_source(ref, opts),
         do: {:ok, %{"source" => source_row(source, opts)}}
  end

  defp source_rows(facts, opts) do
    db_rows = readable(Overview.sources(repo_opts(opts)), "sources")
    summary = readable(Overview.source_summary(facts.now, repo_opts(opts)), "source counts")

    Enum.map(CuesConfig.sources(cue_config(opts)), fn source ->
      SourceRow.build(source, source_facts(Map.get(db_rows, source.ref), summary, source, facts))
    end)
  end

  defp source_row(source, opts), do: source_row(source, :read, facts(opts), opts)

  defp source_row(source, db_row, facts, opts) do
    db_row =
      if db_row == :read,
        do: Map.get(readable(Overview.sources(repo_opts(opts)), "sources"), source.ref),
        else: db_row

    summary = readable(Overview.source_summary(facts.now, repo_opts(opts)), "source counts")
    SourceRow.build(source, source_facts(db_row, summary, source, facts))
  end

  defp source_facts(db_row, summary, source, facts) do
    %{
      row: db_row,
      summary: Map.get(summary, source.ref),
      running?: facts.running?,
      cues_on?: facts.enabled?,
      memory?: facts.memory?,
      window_s: Overview.window_s()
    }
  end

  defp gaps(_ref, %{memory?: false}, _opts), do: []

  defp gaps(ref, _facts, opts) do
    filters = %{limit: @max_gaps, source_ref: ref, open: true}

    case Deliveries.gaps(filters, repo_opts(opts)) do
      {:ok, gaps} -> Enum.map(gaps, &gap_view/1)
      {:error, reason} -> unreadable("gaps", reason, [])
    end
  end

  defp gap_view(gap) do
    %{
      "reason" => gap.reason,
      "count" => gap.count,
      "range_from" => gap.range_from,
      "range_to" => gap.range_to,
      "first_at" => stamp(gap.first_at),
      "sentence" => gap_sentence(gap.count, gap.reason)
    }
  end

  @doc "The sentence for an open gap of `count` items missed for `reason`."
  @spec gap_sentence(pos_integer(), String.t()) :: String.t()
  def gap_sentence(1, reason) when is_binary(reason),
    do: "One item was not delivered: #{gap_reason(reason)}."

  def gap_sentence(count, reason) when is_integer(count) and is_binary(reason),
    do: "#{count} items were not delivered: #{gap_reason(reason)}."

  defp gap_reason("disconnect"), do: "the connection dropped"
  defp gap_reason("inbox_full"), do: "the inbox was full"
  defp gap_reason("rate_limited"), do: "they came faster than the rate limit"
  defp gap_reason("budget"), do: "the source was over its daily limit"
  defp gap_reason("expired"), do: "they waited too long"
  defp gap_reason("stale"), do: "they were too old when they arrived"
  defp gap_reason("identity_conflict"), do: "they reused an id with other content"
  defp gap_reason("watcher_removed"), do: "their watcher was removed"
  defp gap_reason(_limit), do: "catching up after a break reached its limit"

  defp rejected(nil), do: []

  defp rejected(db_row) do
    db_row
    |> Map.get(:reject_counts, %{})
    |> Enum.sort()
    |> Enum.map(fn {reason, count} ->
      %{"reason" => reason, "count" => count, "sentence" => rejected_sentence(count, reason)}
    end)
  end

  @doc "The sentence for `count` requests the door refused for `reason`."
  @spec rejected_sentence(pos_integer(), String.t()) :: String.t()
  def rejected_sentence(count, reason) when is_integer(count) and is_binary(reason),
    do: "#{count} #{rejected_why(reason)}."

  defp rejected_why("unauthorized"), do: "refused without a valid signature or token"
  defp rejected_why("rate_limited"), do: "refused over the rate limit"
  defp rejected_why("busy"), do: "refused while the door was busy"
  defp rejected_why("too_large"), do: "refused as too large"
  defp rejected_why("malformed"), do: "refused as malformed"
  defp rejected_why("unsupported_media_type"), do: "refused for the wrong content type"
  defp rejected_why("timeout"), do: "refused because the body arrived too slowly"
  defp rejected_why("unavailable"), do: "refused while its secret could not be read"
  defp rejected_why("invalid"), do: "refused as not a valid item"
  defp rejected_why("stale"), do: "refused as too old"
  defp rejected_why("over_budget"), do: "refused over its daily limit"
  defp rejected_why(_other), do: "refused"

  defp listeners(ref, opts) do
    summary = readable(Overview.source_summary(now(opts), repo_opts(opts)), "source counts")

    case Map.get(summary, ref) do
      nil -> []
      entry -> Map.get(entry, :listening, []) ++ Map.get(entry, :paused, [])
    end
  end

  defp fetch_source(ref, opts) do
    case CuesConfig.source(ref, cue_config(opts)) do
      {:ok, source} -> {:ok, source}
      :error -> invalid("ref", "There is no source named #{ref}.")
    end
  end

  defp drop_secrets(section), do: Keyword.drop(section, SecretWriter.cue_secret_fields())

  # --- watchers ------------------------------------------------------------------

  @doc "`cues.watchers.list`: every watcher's row, oldest first, at most 200."
  @spec watchers_list(keyword()) :: {:ok, map()} | {:error, error()}
  def watchers_list(opts \\ []) when is_list(opts) do
    with :ok <- memory(opts),
         {:ok, rows} <- watcher_rows(facts(opts), opts) do
      {:ok,
       %{
         "watchers" => Enum.take(rows, @max_watchers),
         "window_s" => Overview.window_s(),
         "truncated" => length(rows) > @max_watchers
       }}
    end
  end

  @doc """
  `cues.watchers.get`: one watcher's row with its purpose, its instructions
  and how many of its recent examples are marked each way.
  """
  @spec watchers_get(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def watchers_get(name, opts \\ []) when is_binary(name) and is_list(opts) do
    with :ok <- memory(opts),
         {:ok, rows} <- watcher_rows(facts(opts), opts),
         {:ok, row} <- find_watcher(rows, name),
         {:ok, stored} <- stored_watcher(name, opts) do
      {:ok, %{"watcher" => WatcherRow.detail(row, stored)}}
    end
  end

  defp watcher_rows(%{memory?: false}, _opts), do: {:error, :memory_off}

  defp watcher_rows(facts, opts) do
    case Overview.watchers(facts.now, watcher_opts(opts)) do
      {:ok, watchers} ->
        watcher_facts = %{window_s: Overview.window_s()}

        {:ok,
         watchers
         |> Enum.sort_by(&{stamp(&1.created_at) || "", &1.name})
         |> Enum.map(&WatcherRow.build(&1, watcher_facts))}

      {:error, reason} ->
        rows_error("watchers", reason)
    end
  end

  defp find_watcher(rows, name) do
    case Enum.find(rows, &(&1["name"] == name)) do
      nil -> invalid("name", "There is no watcher named #{name}.")
      row -> {:ok, row}
    end
  end

  defp stored_watcher(name, opts) do
    case Repo.cues_call(CuesWatchersSql, {:get_watcher, {:name, name}}, server: repo(opts)) do
      {:ok, stored} -> {:ok, stored}
      {:error, :not_found} -> invalid("name", "There is no watcher named #{name}.")
      {:error, reason} -> rows_error("watcher", reason)
    end
  end

  # --- mandates --------------------------------------------------------------------

  @doc "`cues.mandates.list`: every mandate's row, whether one more can be added, and the bound."
  @spec mandates_list(keyword()) :: {:ok, map()} | {:error, error()}
  def mandates_list(opts \\ []) when is_list(opts) do
    rows = mandate_rows(facts(opts), opts)
    max = CuesConfig.max_mandates()

    {:ok,
     %{
       "mandates" => Enum.take(rows, max),
       "can_add" => length(rows) < max,
       "limits" => %{"max_mandates" => max}
     }}
  end

  @doc """
  `cues.mandates.choices`: what a mandate form offers: the jobs that run on
  cues, each with the watcher that wakes it and the mandate that names it,
  and the installed, enabled `http`-rail plugin tools (`Cues.Mandates`' rule).
  """
  @spec mandates_choices(keyword()) :: {:ok, map()} | {:error, error()}
  def mandates_choices(opts \\ []) when is_list(opts) do
    with :ok <- memory(opts),
         {:ok, jobs} <- choice_jobs(opts) do
      {:ok, %{"jobs" => jobs, "tools" => choice_tools(opts)}}
    end
  end

  @doc "`cues.mandates.add`: saves a new mandate from its form values and answers its row."
  @spec mandates_add(String.t(), map(), keyword()) :: {:ok, map()} | {:error, error()}
  def mandates_add(name, values, opts \\ []) when is_binary(name) and is_map(values) do
    with {:ok, section} <- [] |> MandateRow.section(values) |> refused_field(),
         {:ok, _saved} <- save(CueSettings.save_mandate(name, section, :create), "name") do
      mandate_answer(name, opts)
    end
  end

  @doc """
  `cues.mandates.update`: changes the fields `values` names and answers the
  row. Its approval covers the section, so a changed mandate reads `changed`
  until approved again.
  """
  @spec mandates_update(String.t(), map(), keyword()) :: {:ok, map()} | {:error, error()}
  def mandates_update(name, values, opts \\ []) when is_binary(name) and is_map(values) do
    with {:ok, section} <- saved_section(:mandates, name, "name"),
         {:ok, merged} <- section |> MandateRow.section(values) |> refused_field(),
         {:ok, _saved} <- save(CueSettings.save_mandate(name, merged, :update), "name") do
      mandate_answer(name, opts)
    end
  end

  @doc "`cues.mandates.remove`: removes a mandate."
  @spec mandates_remove(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def mandates_remove(name, opts \\ []) when is_binary(name) and is_list(opts) do
    with {:ok, _saved} <- save(CueSettings.remove_mandate(name), "name") do
      {:ok, %{"name" => name, "removed" => true}}
    end
  end

  @doc "`cues.mandates.enable` / `.disable`: turns a mandate on or off and answers its row."
  @spec mandates_switch(String.t(), boolean(), keyword()) :: {:ok, map()} | {:error, error()}
  def mandates_switch(name, enabled?, opts \\ []) when is_binary(name) and is_boolean(enabled?) do
    with {:ok, _saved} <- save(CueSettings.set_enabled(:mandates, name, enabled?), "name") do
      mandate_answer(name, opts)
    end
  end

  @doc """
  `cues.mandates.approve`: records the owner's approval of a mandate as it is
  now, from the Fermix app, and answers its row. An inactive mandate is
  refused with its load sentence.
  """
  @spec mandates_approve(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def mandates_approve(name, opts \\ []) when is_binary(name) and is_list(opts) do
    with :ok <- memory(opts),
         {:ok, _section} <- saved_section(:mandates, name, "name"),
         mandate_opts = Overview.mandate_opts(live_cues(opts), mandate_seams(opts)),
         {:ok, _status} <-
           save(
             CueSettings.approve_mandate(name, @approved_from, now(opts), mandate_opts),
             "name"
           ) do
      mandate_answer(name, opts)
    end
  end

  defp mandate_answer(name, opts) do
    case Enum.find(mandate_rows(facts(opts), opts), &(&1["name"] == name)) do
      nil -> invalid("name", "There is no mandate named #{name}.")
      row -> {:ok, %{"mandate" => row}}
    end
  end

  defp mandate_rows(facts, opts) do
    counts =
      if facts.memory?,
        do: readable(Overview.mandate_counts(facts.now, repo_opts(opts)), "mandate counts"),
        else: %{}

    row_facts = %{counts: counts, window_s: Overview.window_s()}

    opts
    |> live_cues()
    |> Overview.mandates(mandate_seams(opts))
    |> Enum.map(&MandateRow.build(&1, row_facts))
  end

  defp choice_jobs(opts) do
    with {:ok, jobs} <- Overview.cue_jobs(repo_opts(opts)),
         {:ok, watchers} <- Overview.watchers(now(opts), watcher_opts(opts)) do
      wakes = Map.new(watchers, &{&1.task_job_id, &1.name})
      named = Map.new(CuesConfig.mandates(cue_config(opts)), &{&1.job, &1.name})

      {:ok,
       Enum.map(jobs, fn job ->
         %{
           "id" => job.id,
           "name" => job.name,
           "watcher" => Map.get(wakes, job.id),
           "mandate" => Map.get(named, job.id)
         }
       end)}
    else
      {:error, reason} -> rows_error("jobs", reason)
    end
  end

  defp choice_tools(opts) do
    case Keyword.get(opts, :plugins, &PluginRegistry.list/0).() do
      {:ok, plugins} ->
        enabled = Keyword.get(opts, :enabled_plugins, &PluginsConfig.enabled_plugins/0).()

        plugins
        |> Enum.filter(&(&1.name in enabled))
        |> Enum.flat_map(&http_tools/1)
        |> Enum.take(@max_tools)

      {:error, reason} ->
        unreadable("plugin tools", reason, [])
    end
  end

  # `Cues.Mandates.http_tool/2`'s rule, read from the one plugin list: a
  # declarative `request` template off the MCP rail. The mandate's load check
  # applies the same rule to whatever the form saves.
  defp http_tools(plugin) do
    for %{"name" => name, "request" => request} = tool <- plugin.tools,
        is_map(request) and Map.get(tool, "rail") != "mcp" do
      %{
        "name" => name,
        "plugin" => plugin.name,
        "title" => Map.get(tool, "title"),
        "read_only" => Map.get(tool, "read_only") == true
      }
    end
  end

  # --- proposals -------------------------------------------------------------------

  @doc """
  `cues.proposals.list`: Fermix's record of each waiting proposal (`waiting`,
  oldest first) or of the last 7 days (`recent`, at most 50), and how many
  wait. Never a proposal's arguments or cue text.
  """
  @spec proposals_list(:waiting | :recent, keyword()) :: {:ok, map()} | {:error, error()}
  def proposals_list(state, opts \\ []) when state in [:waiting, :recent] and is_list(opts) do
    with :ok <- memory(opts),
         {:ok, records} <- records(state, opts),
         {:ok, waiting} <- waiting_records(state, records, opts) do
      {:ok, %{"proposals" => Enum.map(records, &wire/1), "waiting" => length(waiting)}}
    end
  end

  @doc "`cues.proposals.get`: one proposal's record and its card, outside text apart."
  @spec proposals_get(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def proposals_get(proposal_id, opts \\ []) when is_binary(proposal_id) and is_list(opts) do
    with :ok <- memory(opts) do
      case proposals(opts).card(proposal_id, proposal_opts(opts)) do
        {:ok, card} -> {:ok, %{"proposal" => wire(card)}}
        {:error, :not_found} -> invalid("proposal_id", "There is no proposal with that id.")
        {:error, reason} -> rows_error("proposal", reason)
      end
    end
  end

  @doc """
  `cues.proposals.decide`: the owner's answer from the management socket. The
  first answer from any surface wins; this one answers the record once the
  decision is recorded (`confirmed` with a null `result_status` while the
  call runs).
  """
  @spec proposals_decide(String.t(), :confirm | :deny, keyword()) ::
          {:ok, map()} | {:error, error()}
  def proposals_decide(proposal_id, decision, opts \\ [])
      when is_binary(proposal_id) and decision in [:confirm, :deny] and is_list(opts) do
    with :ok <- memory(opts) do
      proposal_id
      |> proposals(opts).decide(decision, @management_origin, proposal_opts(opts))
      |> decided()
    end
  end

  defp decided({:ok, record}), do: {:ok, %{"proposal" => wire(record)}}
  defp decided({:error, sentence}) when is_binary(sentence), do: invalid("proposal_id", sentence)
  defp decided({:error, reason}), do: rows_error("proposal", reason)

  defp records(state, opts) do
    case proposals(opts).records(state, proposal_opts(opts)) do
      {:ok, records} -> {:ok, records}
      {:error, reason} -> rows_error("proposals", reason)
    end
  end

  defp waiting_records(:waiting, records, _opts), do: {:ok, records}
  defp waiting_records(:recent, _records, opts), do: records(:waiting, opts)

  defp proposals(opts), do: Keyword.get(opts, :proposals, FermixCore.Cues.Proposals)
  defp proposal_opts(opts), do: Keyword.take(opts, [:repo])

  # A record's keys and values as the wire carries them: string keys, times in
  # RFC 3339, every other atom spelled out.
  defp wire(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp wire(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), wire(v)} end)

  defp wire(value) when is_list(value), do: Enum.map(value, &wire/1)

  defp wire(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp wire(value), do: value

  # --- shared ------------------------------------------------------------------------

  defp facts(opts) do
    %{
      enabled?: CuesConfig.enabled?(cue_config(opts)),
      running?: Keyword.get_lazy(opts, :running?, &Cues.running?/0),
      memory?: Keyword.get_lazy(opts, :memory?, &MemoryConfig.enabled?/0),
      now: now(opts)
    }
  end

  defp memory(opts) do
    if Keyword.get_lazy(opts, :memory?, &MemoryConfig.enabled?/0),
      do: :ok,
      else: {:error, {:unavailable, @capability, @memory_off_sentence}}
  end

  # What an edit form starts from: the section as the settings file holds it,
  # or as the settings a caller names spell it.
  defp values_section(ref, opts) do
    case Keyword.fetch(opts, :config) do
      {:ok, config} ->
        sources = config |> CuesConfig.to_keyword() |> Keyword.get(:sources, %{})
        {:ok, Map.get(sources, ref, [])}

      :error ->
        saved_section(:sources, ref, "ref")
    end
  end

  # The section as the settings file holds it, read through `Cues.Settings`.
  defp saved_section(table, name, field) do
    case CueSettings.section(table, name) do
      {:ok, section} -> {:ok, section}
      {:error, {:invalid, sentence}} -> invalid(field, sentence)
    end
  end

  # The cue settings as the daemon applied them, or the ones a caller names.
  defp cue_config(opts),
    do: Keyword.get_lazy(opts, :config, fn -> Application.get_env(:fermix_core, :cues, []) end)

  # The cue settings as a mandate call reads them now: the live snapshot,
  # normalized, never a copy a read made earlier; or the ones a caller names.
  defp live_cues(opts) do
    Keyword.get_lazy(opts, :config, fn ->
      CuesConfig.normalize(Keyword.get(ConfigStore.current_snapshot().fermix_core, :cues, []))
    end)
  end

  # Every refusal `Cues.Settings` answers, in the management error vocabulary.
  # A source's sentence is filed under the source form's field it names, a
  # mandate's under the mandate form's; else under `ref` or `name`.
  defp save({:ok, result}, _field), do: {:ok, result}

  defp save({:error, {:invalid, sentence}}, "ref"),
    do: invalid(SourceForm.field_of(sentence, "ref"), sentence)

  defp save({:error, {:invalid, sentence}}, "name"),
    do: invalid(MandateRow.field_of(sentence, "name"), sentence)

  defp save({:error, {:secret_store_failed, id, sentence}}, _field) do
    Logger.warning("cue secret #{id} was not stored: #{sentence}")
    {:error, {:secret_store_failed, id, "unavailable"}}
  end

  defp save({:error, {:external_change, sections}}, _field),
    do: {:error, {:external_change, sections}}

  defp save({:error, {:config_unreadable, sentence}}, _field),
    do: {:error, {:config_unreadable, sentence}}

  defp save({:error, reason}, field) do
    Logger.error("cue settings could not be saved: #{inspect(reason)}")
    invalid(field, "The change could not be saved. See the daemon log.")
  end

  defp refused_field({:ok, value}), do: {:ok, value}
  defp refused_field({:error, {field, sentence}}), do: invalid(field, sentence)

  defp invalid(field, sentence), do: {:error, {:invalid_params, field, sentence}}

  defp rows_error(_what, :memory_off),
    do: {:error, {:unavailable, @capability, @memory_off_sentence}}

  defp rows_error(what, reason) do
    Logger.error("cues: the #{what} could not be read: #{inspect(reason)}")

    {:error,
     {:unavailable, @capability, "Fermix could not read its cue records. See the daemon log."}}
  end

  # A read for a row's facts that cannot answer leaves those facts empty: the
  # row still draws from configuration. Memory switched off, or a Repo that is
  # not running, is expected; anything else is logged.
  defp readable({:ok, value}, _what), do: value
  defp readable({:error, reason}, _what) when reason in [:memory_off, :repo_not_running], do: %{}
  defp readable({:error, reason}, what), do: unreadable(what, reason, %{})

  defp unreadable(what, reason, empty) do
    Logger.warning("cues: the #{what} could not be read: #{inspect(reason)}")
    empty
  end

  defp repo_opts(opts), do: [repo: repo(opts)]
  defp repo(opts), do: Keyword.get(opts, :repo, Repo)

  # A watcher's state reads the stream sources in the cue settings a read uses,
  # and its follow-up's readiness its seams.
  defp watcher_opts(opts),
    do: [
      repo: repo(opts),
      cues_config: cue_config(opts),
      follow_up_opts: Keyword.get(opts, :follow_up_opts, [])
    ]

  defp mandate_seams(opts),
    do: [repo: repo(opts), mandate_opts: Keyword.get(opts, :mandate_opts, [])]

  defp now(opts), do: Keyword.get(opts, :now, &DateTime.utc_now/0).()

  defp stamp(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp stamp(_absent), do: nil
end
