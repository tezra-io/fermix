defmodule FermixCore.SkillCuration do
  @moduledoc """
  Skill curation facade (MILESTONE_26_SKILL_CURATION): a bounded, evidence-
  gated, owner-approved curation pass that mines recent owner history for
  repeated tasks with no skill/tool coverage, proposes at most a handful of
  skills per cycle, and audits curation-created skills for staleness.

  This module owns the cycle pipeline; satellites are
  `SkillCuration.{Config,Scheduler,Miner,Proposals,Creator,Telemetry}`.
  """

  require Logger

  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.Repo
  alias FermixCore.SkillCuration.Creator
  alias FermixCore.SkillCuration.Delivery
  alias FermixCore.SkillCuration.Miner
  alias FermixCore.SkillCuration.Proposals
  alias FermixCore.SkillCuration.Telemetry

  # Bounds (§10) — internal constants, deliberately not config.
  @cycle_days 15
  @claim_stale_after_ms :timer.hours(1)
  @max_skill_proposals 3
  @max_deferred 3
  @max_archive_proposals 2
  @unused_days_for_archive 30
  @min_age_days_for_archive 30
  @cycle_timeout_ms :timer.minutes(10)
  @window_days 30
  @max_messages 400
  @input_token_budget 24_000
  # Bounded-read backstop for the raw range queries; the stratified caps below
  # do the real limiting.
  @raw_fetch_limit 2_000
  # Fixed per-entry render overhead (index, day, label separators) used when
  # charging entries against the byte budget.
  @entry_overhead_bytes 40

  # Loopback channels whose rows are owner-typed by construction. Mirrors
  # `FermixChannels.Gateway.ChannelRegistry.local?/1` (cli/daemon) — core
  # cannot call into fermix_channels, so the coupling is by literal; `acp` is
  # deliberately absent (remote transport, client-attributed rows).
  @local_channels ["cli", "daemon"]
  # Remote channels that can carry a configured `owner_user_id` — the same
  # closed set `FermixCore.Config.@channel_ingress_keys` names.
  @owner_channels [:telegram, :whatsapp, :discord, :slack, :signal]

  @type history_entry :: %{
          index: String.t(),
          label: String.t(),
          day: Date.t(),
          kind: :message | :checkpoint,
          text: String.t()
        }

  @type history :: %{
          entries: [history_entry()],
          scanned_messages: non_neg_integer(),
          checkpoints_included: non_neg_integer(),
          dropped_unattributed: non_neg_integer(),
          dropped_guest_checkpoints: non_neg_integer(),
          dropped_caps: non_neg_integer(),
          window_truncated: boolean()
        }

  @doc """
  Run one curation cycle (§5): sweep, deliver deferred, assemble history and
  inventory, mine, validate and cap, audit ledger skills, persist, deliver.
  The pipeline runs in a monitored Task so a crash always resolves to a
  terminal recorded status — a crash never silently wedges the feature.

  `trigger: :scheduled` advances the cadence clock on every terminal outcome
  and earns one state-enforced retry; `trigger: :manual` (`/skills review`)
  advances it only on success.
  """
  @spec run_cycle(keyword()) ::
          {:ok, map()} | {:error, :concurrent_run | :disabled | term()}
  def run_cycle(opts \\ []) when is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    trigger = Keyword.get(opts, :trigger, :scheduled)
    repo = Keyword.get(opts, :repo, Repo)

    meta = %{
      session_id: cycle_session_id(),
      stage: :cycle,
      trigger: trigger,
      parent_session: Keyword.get(opts, :parent_session)
    }

    with {:ok, state} <- Repo.ensure_skill_curation_state(now, server: repo),
         {:ok, claimed} <-
           Repo.claim_skill_curation_cycle(now, @claim_stale_after_ms, server: repo) do
      emit_reclaimed_attempt(state, claimed, trigger)
      Telemetry.run_start(meta)
      retry_due? = claimed.retry_at != nil
      result = run_pipeline_task(meta, now, opts)
      finalize_cycle(meta, result, trigger, retry_due?, now, repo)
    end
  end

  # A reclaim means a previous attempt died holding the claim (SIGKILL /
  # power loss); its session id died with it, so the abandoned attempt is
  # surfaced as a run_error under a fresh reclaim session (§9 :stale_claim).
  defp emit_reclaimed_attempt(%{status: "running"}, %{last_status: "error:stale_claim"}, trigger) do
    Telemetry.run_error(
      %{session_id: cycle_session_id(), stage: :cycle, trigger: trigger, parent_session: nil},
      :stale_claim,
      "reclaimed a stale running claim from a crashed cycle"
    )
  end

  defp emit_reclaimed_attempt(_state, _claimed, _trigger), do: :ok

  @doc false
  def cycle_days, do: @cycle_days

  defp cycle_session_id do
    random = 8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    "skill_curation:" <> random
  end

  # -- operator actions (§6.7, called by Gateway.Commands.Skills) ---------

  @doc """
  Look up a proposal by token (origin validation happens in the command
  layer, which sees the inbound message).
  """
  @spec get_proposal(String.t(), keyword()) ::
          {:ok, Repo.skill_curation_proposal_row()} | {:error, :not_found | term()}
  def get_proposal(token, opts \\ []) do
    Repo.get_skill_curation_proposal(token, repo_opts(opts))
  end

  @doc """
  Approve a proposal (single-use). Archive proposals execute synchronously;
  skill creation/update runs as a crash-guarded Task — the caller gets
  `{:ok, :drafting}` immediately and `notify.({:ok, outcome} | {:error,
  reason})` later, so the approving chat can ack "drafting" and then receive
  the outcome.
  """
  @spec approve_proposal(String.t(), keyword()) ::
          {:ok, :drafting | {:archived, String.t()}}
          | {:error, :not_found | {:invalid_status, String.t()} | term()}
  def approve_proposal(token, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, row} <- Proposals.approve(token, now, Keyword.take(opts, [:repo])) do
      Telemetry.proposal_actioned("approve", row.kind, age_ms(row, now))
      execute_approved(row, now, opts)
    end
  end

  @doc "Decline a proposal (recoverable via `/skills unpark`)."
  @spec decline_proposal(String.t(), keyword()) ::
          {:ok, Repo.skill_curation_proposal_row()} | {:error, term()}
  def decline_proposal(token, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, row} <- Proposals.decline(token, now, Keyword.take(opts, [:repo])) do
      Telemetry.proposal_actioned("deny", row.kind, age_ms(row, now))
      {:ok, row}
    end
  end

  @doc """
  The `/skills proposals` view: actionable rows plus answered/buried
  signatures with dates — the operator can always see what was answered and
  what was buried.
  """
  @spec proposals_overview(keyword()) :: {:ok, map()} | {:error, term()}
  def proposals_overview(opts \\ []) do
    repo_opt = repo_opts(opts)

    with {:ok, actionable} <-
           Repo.list_skill_curation_proposals(%{statuses: ["pending", "deferred"]}, repo_opt),
         {:ok, declined} <-
           Repo.list_skill_curation_proposals(%{statuses: ["declined"]}, repo_opt),
         {:ok, expired} <-
           Repo.list_skill_curation_proposals(%{statuses: ["expired"]}, repo_opt) do
      parked =
        expired
        |> Enum.group_by(& &1.task_signature)
        |> Enum.filter(fn {_signature, rows} -> length(rows) >= Proposals.park_expiries() end)
        |> Enum.map(fn {signature, rows} ->
          %{task_signature: signature, expired_count: length(rows)}
        end)

      {:ok, %{actionable: actionable, declined: declined, parked: parked}}
    end
  end

  @doc """
  Clear a declined/parked disposition (§6.7): by token (clears the token's
  whole signature — parking is a signature property) or by unique signature
  prefix. Ambiguity refuses with the candidates.
  """
  @spec unpark(String.t(), keyword()) ::
          {:ok, non_neg_integer()}
          | {:error, :not_found | {:ambiguous, [String.t()]} | term()}
  def unpark(token_or_prefix, opts \\ []) when is_binary(token_or_prefix) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    proposals_opt = Keyword.take(opts, [:repo])

    with {:ok, signature, kind} <- resolve_unpark_signature(token_or_prefix, opts),
         {:ok, cleared} when cleared > 0 <-
           Proposals.unpark(%{task_signature: signature}, now, proposals_opt) do
      Telemetry.proposal_actioned("unpark", kind, 0)
      {:ok, cleared}
    else
      {:ok, 0} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The `/skills list` view (design open question 3, answered): the skill
  inventory grouped by origin — curation-managed (with lifecycle state),
  the operator's own skills, and plugin skills — each joined with its usage
  counters. Pre-bundled skills (seeded from priv/skills) are excluded: they
  ship with Fermix, are not the operator's inventory, and nothing here can
  act on them.
  """
  @spec list_skills(keyword()) ::
          {:ok, %{managed: [map()], local: [map()], plugin: [map()]}} | {:error, term()}
  def list_skills(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    registry = Keyword.get(opts, :skill_registry, SkillRegistry)

    with {:ok, ledger_rows} <- Repo.list_skill_curation_ledger(%{}, server: repo),
         {:ok, usage_rows} <- Repo.list_skill_usage(server: repo) do
      usage = Map.new(usage_rows, &{&1.skill_name, &1})
      managed_names = MapSet.new(ledger_rows, & &1.skill_name)

      bundled = bundled_skill_names()

      {local, plugin} =
        registry
        |> SkillRegistry.list_detailed()
        |> Enum.reject(
          &(MapSet.member?(managed_names, &1.name) or MapSet.member?(bundled, &1.name))
        )
        |> Enum.split_with(&(&1.trust == :operator))

      {:ok,
       %{
         managed: Enum.map(ledger_rows, &inventory_entry(&1.skill_name, usage, &1.status)),
         local: Enum.map(local, &inventory_entry(&1.name, usage, nil)),
         plugin: Enum.map(plugin, &inventory_entry(&1.name, usage, nil))
       }}
    end
  end

  @doc """
  Operator-initiated reversible archive of a curation-managed skill — the
  §6.9 archive move without waiting for the audit to propose it. Hand-authored
  skills are out of curation's scope (decision 3) and refuse here.
  """
  @spec archive_skill(String.t(), keyword()) ::
          {:ok, String.t()}
          | {:error, :not_curation_managed | :already_archived | term()}
  def archive_skill(skill_name, opts \\ []) when is_binary(skill_name) do
    case Repo.get_skill_curation_ledger(skill_name, repo_opts(opts)) do
      {:ok, %{status: "active"}} -> Creator.archive(skill_name, opts)
      {:ok, %{status: "archived"}} -> {:error, :already_archived}
      {:ok, %{status: status}} -> {:error, {:not_archivable, status}}
      {:error, :not_found} -> {:error, :not_curation_managed}
      {:error, reason} -> {:error, reason}
    end
  end

  # Bundled skills are seeded BY COPY into the local skills dir, so their
  # runtime trust/source_path cannot tell them apart from hand-authored ones —
  # the shipped priv/skills frontmatter names are the reliable identity (the
  # dir basename differs: self_knowledge vs self-knowledge).
  defp bundled_skill_names do
    case :code.priv_dir(:fermix_core) do
      {:error, _reason} ->
        MapSet.new()

      priv ->
        priv
        |> to_string()
        |> Path.join("skills/*/SKILL.md")
        |> Path.wildcard()
        |> MapSet.new(&frontmatter_name/1)
    end
  end

  defp frontmatter_name(skill_md) do
    with {:ok, content} <- File.read(skill_md),
         [_full, name] <- Regex.run(~r/^name:\s*(.+?)\s*$/m, content) do
      name
    else
      # Unreadable/nameless shipped file: fall back to the dir basename so the
      # listing filter still has an identity to match on.
      _other -> skill_md |> Path.dirname() |> Path.basename()
    end
  end

  defp inventory_entry(skill_name, usage, status) do
    counters = Map.get(usage, skill_name, %{views: 0, runs: 0, last_used_at: nil})

    %{
      skill_name: skill_name,
      status: status,
      views: counters.views,
      runs: counters.runs,
      last_used_at: counters.last_used_at
    }
  end

  @doc "Two-case restore + bare listing (§6.7), delegated to the Creator."
  @spec restore(String.t() | nil, keyword()) ::
          {:ok, :unarchived | :snapshot_restored | {:restorables, [map()]}} | {:error, term()}
  def restore(nil, opts),
    do: with({:ok, list} <- Creator.list_restorables(opts), do: {:ok, {:restorables, list}})

  def restore(skill_name, opts) when is_binary(skill_name), do: Creator.restore(skill_name, opts)

  defp execute_approved(%{kind: "archive_skill"} = row, now, opts) do
    case Creator.archive(row.skill_name, opts) do
      {:ok, path} ->
        {:ok, {:archived, path}}

      {:error, reason} ->
        mark_failed(row.token, now, opts)
        {:error, reason}
    end
  end

  defp execute_approved(row, _now, opts) do
    task_supervisor = Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor)
    notify = Keyword.get(opts, :notify, fn _result -> :ok end)
    creator_opts = Keyword.drop(opts, [:notify, :task_supervisor])

    {:ok, _pid} =
      Task.Supervisor.start_child(task_supervisor, fn ->
        notify.(guarded_create(row, creator_opts))
      end)

    {:ok, :drafting}
  end

  # The drafting Task is crash-guarded (spawn_monitor, bounded): an abnormal
  # exit marks the proposal failed and reaches the notify fun — a crash never
  # leaves a silently-stuck approval (§6.8); the stale-creating sweep is the
  # ledger's own backstop.
  defp guarded_create(row, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    {pid, ref} = spawn_monitor(fn -> exit({:creator_done, Creator.execute(row, opts)}) end)

    receive do
      {:DOWN, ^ref, :process, ^pid, {:creator_done, result}} ->
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        mark_failed(row.token, now, opts)
        {:error, {:crash, reason}}
    after
      @cycle_timeout_ms ->
        Process.exit(pid, :kill)
        mark_failed(row.token, now, opts)
        {:error, {:crash, :drafting_timeout}}
    end
  end

  defp mark_failed(token, now, opts) do
    case Proposals.fail(token, now, Keyword.take(opts, [:repo])) do
      {:ok, _row} -> :ok
      {:error, reason} -> Logger.warning("could not mark proposal failed: #{inspect(reason)}")
    end
  end

  defp resolve_unpark_signature(token_or_prefix, opts) do
    case Repo.get_skill_curation_proposal(token_or_prefix, repo_opts(opts)) do
      {:ok, row} -> {:ok, row.task_signature, row.kind}
      {:error, :not_found} -> resolve_signature_prefix(token_or_prefix, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_signature_prefix(prefix, opts) do
    with {:ok, rows} <-
           Repo.list_skill_curation_proposals(
             %{statuses: ["declined", "expired"]},
             repo_opts(opts)
           ) do
      matches =
        rows
        |> Enum.filter(&String.starts_with?(&1.task_signature, prefix))
        |> Enum.uniq_by(& &1.task_signature)

      case matches do
        [] -> {:error, :not_found}
        [row] -> {:ok, row.task_signature, row.kind}
        many -> {:error, {:ambiguous, Enum.map(many, & &1.task_signature)}}
      end
    end
  end

  defp age_ms(row, now), do: max(DateTime.diff(now, row.created_at, :millisecond), 0)

  defp repo_opts(opts), do: [server: Keyword.get(opts, :repo, Repo)]

  # The pipeline runs in a monitored Task (bounded by @cycle_timeout_ms) so a
  # crash or hang is converted to a terminal error the caller records, for
  # both triggers; SIGKILL mid-finalize is the stale-claim backstop's job.
  defp run_pipeline_task(meta, now, opts) do
    task_supervisor = Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor)

    task =
      Task.Supervisor.async_nolink(task_supervisor, fn -> execute_cycle(meta, now, opts) end)

    case Task.yield(task, @cycle_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:crash, reason}}
      nil -> {:error, {:crash, :cycle_timeout}}
    end
  end

  defp execute_cycle(meta, now, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, sweep_counts} <- Proposals.sweep(now, @cycle_days, repo: repo),
         {:ok, _stale_creating} <- Creator.sweep_stale_creating(now, opts),
         {:ok, deferred_rows} <- Proposals.deliverable_deferred(repo: repo),
         {:ok, history} <- assemble_history(now, opts),
         {:ok, dispositions} <- Proposals.dispositions(repo: repo),
         {:ok, ledger_all} <- Repo.list_skill_curation_ledger(%{}, server: repo),
         ledger_active = Enum.filter(ledger_all, &(&1.status == "active")),
         inventory = assemble_inventory(opts),
         {:ok, mined} <-
           run_miner(meta, deferred_rows, history, dispositions, inventory, ledger_all, opts),
         {:ok, audit} <- audit_candidates(ledger_active, now, opts),
         {:ok, outcome} <- persist_and_deliver(deferred_rows, mined, audit, meta, now, opts) do
      {:ok, build_counts(sweep_counts, history, mined, audit, outcome)}
    else
      {:error, {kind, _detail} = reason} when kind in [:parse, :provider, :crash] ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:storage, reason}}
    end
  end

  # Mining is skipped entirely when carried-over deferred proposals already
  # fill the cycle cap (§6.4) — no provider spend for output that could not
  # be delivered anyway.
  defp run_miner(meta, deferred_rows, history, dispositions, inventory, ledger_all, opts) do
    if length(deferred_rows) >= @max_skill_proposals do
      {:ok, skipped_mine_result()}
    else
      active = Enum.filter(ledger_all, &(&1.status == "active"))

      inputs = %{
        session_id: meta.session_id,
        history: history,
        inventory: inventory,
        dispositions: dispositions,
        ledger_skills: ledger_all,
        update_candidates: update_candidates(active, opts)
      }

      Miner.mine(inputs, Keyword.take(opts, [:adapter, :route_key, :routes, :adapter_opts]))
    end
  end

  defp skipped_mine_result do
    %{
      cycle_summary: "mining skipped: deferred proposals filled the cycle cap",
      candidates: [],
      dropped_disposition: 0,
      dropped_grounding: 0,
      dropped_invalid_name: 0
    }
  end

  defp assemble_inventory(opts) do
    skill_registry = Keyword.get(opts, :skill_registry, SkillRegistry)
    capability_registry = Keyword.get(opts, :capability_registry, CapabilityRegistry)

    skills =
      skill_registry
      |> SkillRegistry.list_detailed()
      |> Enum.map(&%{name: &1.name, description: &1.description, trust: &1.trust})

    capability_names =
      capability_registry
      |> CapabilityRegistry.list()
      |> Enum.map(& &1.name)

    %{skills: skills, capability_names: capability_names}
  end

  defp update_candidates(ledger_active, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    Enum.map(ledger_active, fn row ->
      last_used =
        case Repo.get_skill_usage(row.skill_name, server: repo) do
          {:ok, usage} -> usage.last_used_at
          {:error, _reason} -> nil
        end

      %{skill_name: row.skill_name, task_signature: row.task_signature, last_used: last_used}
    end)
  end

  # The staleness audit (§6.9): deterministic, code-only. Active ledger skills
  # past the age grace period and unused past the threshold become archive
  # proposals — capped, oldest-unused first, per-skill cool-down respected.
  defp audit_candidates(ledger_active, now, opts) do
    repo = Keyword.get(opts, :repo, Repo)

    candidates =
      ledger_active
      |> Enum.map(&audit_entry(&1, now, repo))
      |> Enum.filter(& &1.eligible?)
      |> Enum.sort_by(& &1.last_used_sort)

    {:ok,
     %{
       proposals: Enum.take(candidates, @max_archive_proposals),
       overflow: max(length(candidates) - @max_archive_proposals, 0)
     }}
  end

  defp audit_entry(row, now, repo) do
    last_used =
      case Repo.get_skill_usage(row.skill_name, server: repo) do
        {:ok, usage} -> usage.last_used_at
        {:error, _reason} -> nil
      end

    blocked? =
      case Proposals.archive_proposal_blocked?(row.skill_name, now, repo: repo) do
        {:ok, blocked?} -> blocked?
        {:error, _reason} -> true
      end

    %{
      skill_name: row.skill_name,
      created_at: row.created_at,
      last_used: last_used,
      last_used_sort: last_used_sort(last_used),
      eligible?:
        not blocked? and old_enough?(row.created_at, now, @min_age_days_for_archive) and
          unused?(last_used, now)
    }
  end

  defp last_used_sort(nil), do: {0, 0}
  defp last_used_sort(%DateTime{} = at), do: {1, DateTime.to_unix(at)}

  defp old_enough?(%DateTime{} = created_at, now, days) do
    DateTime.diff(now, created_at, :second) >= days * 86_400
  end

  defp unused?(nil, _now), do: true

  defp unused?(%DateTime{} = last_used, now) do
    DateTime.diff(now, last_used, :second) >= @unused_days_for_archive * 86_400
  end

  # Cap allocation (§6.4/§6.5): deferred first, then fresh candidates; valid
  # overflow becomes next cycle's deferred (bounded); beyond that dropped and
  # counted. Everything to deliver goes out in one pass.
  defp persist_and_deliver(deferred_rows, mined, audit, meta, now, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    deferred_to_deliver = Enum.take(deferred_rows, @max_skill_proposals)
    room = @max_skill_proposals - length(deferred_to_deliver)
    {fresh, overflow} = Enum.split(mined.candidates, room)

    defer_room = max(@max_deferred - (length(deferred_rows) - length(deferred_to_deliver)), 0)
    {to_defer, dropped_overflow} = Enum.split(overflow, defer_room)

    with {:ok, fresh_rows} <- insert_candidates(fresh, "pending", meta, now, repo),
         {:ok, _deferred_new} <- insert_candidates(to_defer, "deferred", meta, now, repo),
         {:ok, archive_rows} <- insert_archive_proposals(audit.proposals, meta, now, repo),
         {:ok, delivery_status} <-
           Delivery.deliver(
             deferred_to_deliver ++ fresh_rows ++ archive_rows,
             now,
             Keyword.take(opts, [
               :channel_adapter,
               :channels,
               :configured_owners,
               :jobs_config,
               :repo
             ])
           ) do
      {:ok,
       %{
         delivery_status: delivery_status,
         delivered_deferred: length(deferred_to_deliver),
         proposals_new: Enum.count(fresh, &(&1.kind == "new_skill")),
         proposals_update: Enum.count(fresh, &(&1.kind == "update_skill")),
         proposals_archive: length(audit.proposals),
         deferred: length(to_defer),
         dropped_overflow: length(dropped_overflow)
       }}
    end
  end

  defp insert_candidates(candidates, status, meta, now, repo) do
    Enum.reduce_while(candidates, {:ok, []}, fn candidate, {:ok, acc} ->
      attrs = %{
        cycle_session_id: meta.session_id,
        kind: candidate.kind,
        skill_name: candidate.name,
        task_signature: candidate.task_signature,
        summary: Delivery.render_summary(candidate),
        outline_json: Jason.encode!(candidate.outline),
        evidence_json: Jason.encode!(candidate.evidence),
        status: status,
        created_at: now
      }

      case Proposals.insert(attrs, repo: repo) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_archive_proposals(entries, meta, now, repo) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      attrs = %{
        cycle_session_id: meta.session_id,
        kind: "archive_skill",
        skill_name: entry.skill_name,
        task_signature: "archive:" <> entry.skill_name,
        summary:
          Delivery.render_summary(%{
            kind: "archive_skill",
            skill_name: entry.skill_name,
            rationale: archive_rationale(entry)
          }),
        status: "pending",
        created_at: now
      }

      case Proposals.insert(attrs, repo: repo) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp archive_rationale(%{last_used: nil} = entry) do
    "Never used since created #{Date.to_iso8601(DateTime.to_date(entry.created_at))}."
  end

  defp archive_rationale(entry) do
    "Last used #{Date.to_iso8601(DateTime.to_date(entry.last_used))}."
  end

  defp build_counts(sweep_counts, history, mined, audit, outcome) do
    %{
      messages_scanned: history.scanned_messages,
      checkpoints_included: history.checkpoints_included,
      messages_dropped_caps: history.dropped_caps,
      dropped_unattributed: history.dropped_unattributed,
      candidates: length(mined.candidates),
      dropped_disposition: mined.dropped_disposition,
      dropped_grounding: mined.dropped_grounding,
      dropped_invalid_name: mined.dropped_invalid_name,
      dropped_overflow: outcome.dropped_overflow,
      deferred: outcome.deferred,
      delivered_deferred: outcome.delivered_deferred,
      proposals_new: outcome.proposals_new,
      proposals_update: outcome.proposals_update,
      proposals_archive: outcome.proposals_archive,
      archive_overflow: audit.overflow,
      expired_pending: sweep_counts.expired_pending,
      expired_deferred: sweep_counts.expired_deferred,
      window_truncated: history.window_truncated,
      delivery_status: outcome.delivery_status,
      cycle_summary: mined.cycle_summary
    }
  end

  # Terminal state bookkeeping (§6.2). A scheduled cycle advances the cadence
  # clock on every terminal outcome; a cadence-due failure earns exactly one
  # +12h retry, a retry-due failure clears it — at most two attempts per
  # period, enforced by state, not convention. Manual failure touches nothing
  # (the operator will simply re-run).
  defp finalize_cycle(meta, {:ok, counts}, _trigger, _retry_due?, now, repo) do
    updates = %{status: "idle", last_status: "ok", last_cycle_at: now, retry_at: nil}

    # The closer is emitted regardless: a failed state write must not strand
    # the run's trace open (it would only ship via the exporter's TTL sweep).
    case Repo.update_skill_curation_state(updates, now, server: repo) do
      {:ok, _state} ->
        Telemetry.run_complete(meta, Map.delete(counts, :cycle_summary))
        {:ok, counts}

      {:error, reason} ->
        Telemetry.run_error(meta, :storage, reason)
        {:error, {:storage, reason}}
    end
  end

  defp finalize_cycle(meta, {:error, {kind, detail}}, trigger, retry_due?, now, repo) do
    updates =
      %{status: "idle", last_status: "error:#{kind}"}
      |> Map.merge(error_cadence_updates(trigger, retry_due?, now))

    Telemetry.run_error(meta, kind, detail)

    case Repo.update_skill_curation_state(updates, now, server: repo) do
      {:ok, _state} -> {:error, {kind, detail}}
      {:error, reason} -> {:error, {kind, {detail, {:state_write_failed, reason}}}}
    end
  end

  defp error_cadence_updates(:manual, _retry_due?, _now), do: %{}

  defp error_cadence_updates(:scheduled, false, now) do
    %{last_cycle_at: now, retry_at: DateTime.add(now, 12 * 3_600, :second)}
  end

  defp error_cadence_updates(:scheduled, true, now) do
    %{last_cycle_at: now, retry_at: nil}
  end

  @doc false
  # Public (@doc false) so tests can pin the assembly invariants directly; the
  # cycle is the only production caller.
  #
  # Assembles the miner's input window (§6.3): owner turns resolved by channel
  # metadata ids only (never the display-name `sender` column), plus
  # owner-private checkpoint summaries representing compacted spans. Cap
  # eviction is stratified by UTC day so every day keeps representation.
  @spec assemble_history(DateTime.t(), keyword()) :: {:ok, history()} | {:error, term()}
  def assemble_history(%DateTime{} = now, opts \\ []) when is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)
    agent_id = Keyword.get(opts, :agent_id, FermixCore.Memory.Config.agent_id())
    owner_id = Keyword.get(opts, :owner_id, FermixCore.Memory.Config.owner_id())
    owners = Keyword.get_lazy(opts, :configured_owners, &configured_owners/0)
    from = DateTime.add(now, -@window_days * 86_400, :second)

    # Fetch one row past the backstop so a saturated window is DETECTED, not
    # silently truncated (§6.3 "no silent truncation"): the overflow row is
    # dropped and the shortfall surfaces as window_truncated in the counts.
    with {:ok, message_rows} <-
           Repo.get_messages_in_range(
             %{agent_id: agent_id, owner_id: owner_id, kind: "chat_message", role: "user"},
             from,
             now,
             @raw_fetch_limit + 1,
             server: repo
           ),
         {:ok, checkpoint_rows} <-
           Repo.get_messages_in_range(
             %{agent_id: agent_id, owner_id: owner_id, kind: "checkpoint_summary"},
             from,
             now,
             @raw_fetch_limit,
             server: repo
           ) do
      {truncated?, bounded_rows} = drop_overflow_row(message_rows)
      {:ok, build_history(bounded_rows, checkpoint_rows, owners, truncated?)}
    end
  end

  # Rows arrive chronological with the newest @raw_fetch_limit + 1 winning;
  # the overflow row is the OLDEST of that set.
  defp drop_overflow_row(rows) when length(rows) > @raw_fetch_limit, do: {true, tl(rows)}
  defp drop_overflow_row(rows), do: {false, rows}

  @doc false
  def window_days, do: @window_days

  defp build_history(message_rows, checkpoint_rows, owners, truncated?) do
    {owner_messages, dropped_unattributed} = split_owner_messages(message_rows, owners)
    {owner_checkpoints, dropped_guest} = split_owner_checkpoints(checkpoint_rows, owners)

    merged =
      (Enum.map(owner_messages, &entry_from_row(&1, :message)) ++
         Enum.map(owner_checkpoints, &entry_from_row(&1, :checkpoint)))
      |> Enum.sort_by(& &1.sort_key)
      |> Enum.map(&truncate_oversized_entry/1)

    {kept, dropped_caps} = apply_stratified_caps(merged)

    entries =
      kept
      |> Enum.with_index(1)
      |> Enum.map(fn {entry, i} ->
        entry |> Map.delete(:sort_key) |> Map.put(:index, "m#{i}")
      end)

    %{
      entries: entries,
      scanned_messages: length(message_rows),
      checkpoints_included: Enum.count(kept, &(&1.kind == :checkpoint)),
      dropped_unattributed: dropped_unattributed,
      dropped_guest_checkpoints: dropped_guest,
      dropped_caps: dropped_caps,
      window_truncated: truncated?
    }
  end

  # Owner resolution mirrors ingress (`Gateway.Source`): metadata `user_id`
  # falling back to metadata `sender_id`, compared against the channel's
  # configured owner. Rows with no metadata id are excluded — under-mining is
  # the accepted failure direction (§8.2).
  defp split_owner_messages(rows, owners) do
    {kept, dropped} = Enum.split_with(rows, &owner_message?(&1, owners))
    {kept, length(dropped)}
  end

  defp owner_message?(%{channel: channel}, _owners) when channel in @local_channels, do: true

  defp owner_message?(%{channel: channel, metadata: metadata}, owners) do
    case {Map.get(owners, channel), metadata_id(metadata)} do
      {nil, _id} -> false
      {_owner, nil} -> false
      {owner, id} -> owner == id
    end
  end

  # Checkpoint inclusion is conversation-granular: local channels, or the DM
  # shape (chat_id equals the configured owner id). Group checkpoints blend
  # guest content and never reach the miner.
  defp split_owner_checkpoints(rows, owners) do
    {kept, dropped} = Enum.split_with(rows, &owner_checkpoint?(&1, owners))
    {kept, length(dropped)}
  end

  defp owner_checkpoint?(%{channel: channel}, _owners) when channel in @local_channels, do: true

  defp owner_checkpoint?(%{channel: channel, chat_id: chat_id}, owners) do
    case Map.get(owners, channel) do
      nil -> false
      owner -> owner == chat_id
    end
  end

  defp metadata_id(metadata) when is_map(metadata) do
    normalize_metadata_id(Map.get(metadata, "user_id") || Map.get(metadata, :user_id)) ||
      normalize_metadata_id(Map.get(metadata, "sender_id") || Map.get(metadata, :sender_id))
  end

  defp metadata_id(_metadata), do: nil

  defp normalize_metadata_id(nil), do: nil
  defp normalize_metadata_id(value) when is_integer(value), do: Integer.to_string(value)

  defp normalize_metadata_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_metadata_id(_value), do: nil

  defp configured_owners do
    @owner_channels
    |> Enum.map(fn channel ->
      {Atom.to_string(channel), FermixCore.Config.channel_explicit_owner_user_id(channel)}
    end)
    |> Enum.reject(fn {_channel, owner} -> is_nil(owner) end)
    |> Map.new()
  end

  defp entry_from_row(row, kind) do
    %{
      label: "#{row.channel}:#{row.chat_id}/#{row.thread_scope}",
      day: DateTime.to_date(row.created_at),
      kind: kind,
      text: row.content,
      sort_key: {DateTime.to_unix(row.created_at, :millisecond), row.id}
    }
  end

  defp entry_bytes(entry) do
    byte_size(entry.text) + byte_size(entry.label) + @entry_overhead_bytes
  end

  # A single entry larger than the whole byte budget is truncated rather than
  # evicted (the Reviewer's single-message rule), UTF-8-safe.
  defp truncate_oversized_entry(entry) do
    budget = @input_token_budget * 4
    overhead = byte_size(entry.label) + @entry_overhead_bytes

    if entry_bytes(entry) > budget do
      %{entry | text: truncate_to_valid_utf8(entry.text, max(budget - overhead, 1))}
    else
      entry
    end
  end

  # Two stratified passes (§6.3): count cap, then byte budget. Eviction always
  # removes the newest entry of the currently largest UTC-day bucket, so every
  # day of the window keeps representation — a repetition miner must preserve
  # span coverage, not recency.
  defp apply_stratified_caps(entries) do
    {kept, evicted_count} = evict_while(entries, &(length(&1) > @max_messages))

    {kept, evicted_bytes} =
      evict_while(kept, fn remaining ->
        Enum.sum_by(remaining, &entry_bytes/1) > @input_token_budget * 4
      end)

    {kept, evicted_count + evicted_bytes}
  end

  defp evict_while(entries, over_limit?) do
    do_evict_while(entries, over_limit?, 0)
  end

  defp do_evict_while([], _over_limit?, dropped), do: {[], dropped}

  defp do_evict_while(entries, over_limit?, dropped) do
    if over_limit?.(entries) do
      entries
      |> evict_one_from_largest_day()
      |> do_evict_while(over_limit?, dropped + 1)
    else
      {entries, dropped}
    end
  end

  defp evict_one_from_largest_day(entries) do
    {victim_day, _count} =
      entries
      |> Enum.frequencies_by(& &1.day)
      |> Enum.max_by(fn {day, count} -> {count, Date.to_iso8601(day)} end)

    victim_index =
      entries
      |> Enum.with_index()
      |> Enum.filter(fn {entry, _i} -> entry.day == victim_day end)
      |> List.last()
      |> elem(1)

    List.delete_at(entries, victim_index)
  end

  defp truncate_to_valid_utf8(binary, max_bytes) when byte_size(binary) <= max_bytes, do: binary

  defp truncate_to_valid_utf8(binary, max_bytes) do
    binary
    |> binary_part(0, max_bytes)
    |> drop_trailing_partial()
  end

  defp drop_trailing_partial(binary) do
    if String.valid?(binary) do
      binary
    else
      drop_trailing_partial(binary_part(binary, 0, byte_size(binary) - 1))
    end
  end
end
