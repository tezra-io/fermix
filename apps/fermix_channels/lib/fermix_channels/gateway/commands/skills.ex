defmodule FermixChannels.Gateway.Commands.Skills do
  @moduledoc """
  The `/skills` command family (MILESTONE_26_SKILL_CURATION §6.7): review,
  approve, deny, proposals, unpark, restore.

  Thin by design: parse + authorize + delegate — every state change lives in
  `FermixCore.SkillCuration`. All subcommands are strict `operator_only`
  (mutating personalization surface; the guest allowlist never applies).
  Button taps synthesize these exact typed commands, so this module is the
  single code path for proposal actions.
  """

  @behaviour FermixChannels.Gateway.Command

  require Logger

  alias FermixChannels.Gateway.ChannelRegistry
  alias FermixChannels.Gateway.Commands.Authorization
  alias FermixCore.Config, as: CoreConfig
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.SkillCuration
  alias FermixCore.SkillCuration.Config, as: SkillCurationConfig
  alias FermixCore.SkillCuration.Proposals

  @impl true
  def name, do: "skills"

  @impl true
  def aliases, do: []

  @impl true
  def description,
    do: "Review, approve, or deny skill-curation proposals; unpark or restore skills."

  @impl true
  def authorize(message, metadata, context),
    do: Authorization.operator_only(message, metadata, context)

  @impl true
  def execute(message, reply_fn, context) do
    dispatch(args(message), message, reply_fn, context)
  end

  defp dispatch(["review" | _rest], message, reply_fn, context),
    do:
      gated(reply_fn, fn ->
        private(message, reply_fn, fn -> run_review(message, reply_fn, context) end)
      end)

  defp dispatch(["approve", token], message, reply_fn, context),
    do: gated(reply_fn, fn -> approve(token, message, reply_fn, context) end)

  defp dispatch(["deny", token], message, reply_fn, context),
    do: deny(token, message, reply_fn, context)

  defp dispatch(["proposals"], message, reply_fn, context),
    do: private(message, reply_fn, fn -> list_proposals(message, reply_fn, context) end)

  defp dispatch(["list"], message, reply_fn, context),
    do: private(message, reply_fn, fn -> list_managed(reply_fn, context) end)

  defp dispatch(["archive", skill_name], _message, reply_fn, context),
    do: archive(skill_name, reply_fn, context)

  defp dispatch(["unpark", token_or_prefix], _message, reply_fn, context),
    do: unpark(token_or_prefix, reply_fn, context)

  defp dispatch(["restore"], _message, reply_fn, context),
    do: restore(nil, reply_fn, context)

  defp dispatch(["restore", skill_name], _message, reply_fn, context),
    do: restore(skill_name, reply_fn, context)

  defp dispatch(_args, _message, reply_fn, _context), do: reply(reply_fn, usage_text())

  # Disabled semantics (§6.1): with curation off, pending proposals stop being
  # actionable except deny; with memory off nothing works at all.
  defp gated(reply_fn, fun) do
    cond do
      not curation_enabled?() -> reply(reply_fn, "Skill curation is disabled in config.")
      not memory_enabled?() -> reply(reply_fn, "Skill curation requires memory persistence.")
      true -> fun.()
    end
  end

  # Guest invisibility (§8.9): review summaries and proposal listings render
  # the owner's mined history, so they only ever render into an owner-private
  # conversation — a local channel, or the owner DM. A group chat gets a
  # redirect, never the content.
  defp private(message, reply_fn, fun) do
    if owner_private_conversation?(message) do
      fun.()
    else
      reply(reply_fn, "This lists your private history — run it in a direct chat or the CLI.")
    end
  end

  defp owner_private_conversation?(message) do
    ChannelRegistry.local?(message.channel) or
      owner_dm?(ChannelRegistry.channel_key(message.channel), message.chat_id)
  end

  defp owner_dm?(nil, _chat_id), do: false

  defp owner_dm?(channel_key, chat_id) do
    CoreConfig.channel_explicit_owner_user_id(channel_key) == chat_id
  end

  # The cycle makes a bounded provider call over a month of history, and
  # commands dispatch inside the transport ingest path — so the review acks
  # immediately and runs as a supervised Task, delivering its outcome to the
  # same chat when it lands (the approve->drafting notify pattern).
  # run_cycle/1 converts pipeline crashes to typed errors itself, so the task
  # body always produces exactly one outcome message.
  defp run_review(message, reply_fn, context) do
    opts =
      core_opts(context) ++
        [
          trigger: :manual,
          parent_session: "command:skills:#{message.channel}:#{message.chat_id}"
        ]

    task_supervisor = Keyword.get(opts, :task_supervisor, FermixCore.TaskSupervisor)
    finish_command = defer_command(context)
    reply(reply_fn, "Reviewing your recent history for repeated tasks — results will land here.")

    {:ok, _pid} =
      Task.Supervisor.start_child(task_supervisor, fn ->
        result = SkillCuration.run_cycle(opts)
        reply_fn.({:text, review_outcome_text(result)})
        settle_command(finish_command, result)
      end)

    :ok
  end

  defp defer_command(context) do
    case Map.get(context, :defer_command_fn) do
      defer when is_function(defer, 0) -> defer.()
      nil -> nil
    end
  end

  defp settle_command(nil, _result), do: :ok
  defp settle_command(finish, {:ok, _counts}), do: finish.(:completed)
  defp settle_command(finish, {:error, reason}), do: finish.({:failed, reason})

  defp review_outcome_text({:ok, counts}), do: review_text(counts)

  defp review_outcome_text({:error, :concurrent_run}),
    do: "A curation cycle is already running."

  defp review_outcome_text({:error, {kind, _detail}}), do: "Curation cycle failed (#{kind})."
  defp review_outcome_text({:error, reason}), do: "Curation cycle failed: #{inspect(reason)}."

  defp approve(token, message, reply_fn, context) do
    with {:ok, row} <- SkillCuration.get_proposal(token, core_opts(context)),
         :ok <- validate_origin(row, message) do
      run_approval(row, token, message, reply_fn, context)
    else
      {:error, :not_found} -> reply(reply_fn, "Unknown proposal token.")
      {:error, :origin_mismatch} -> reply(reply_fn, origin_mismatch_text())
      {:error, reason} -> reply(reply_fn, "Approve failed: #{inspect(reason)}.")
    end
  end

  defp run_approval(row, token, message, reply_fn, context) do
    opts =
      core_opts(context) ++
        [
          notify: outcome_notifier(reply_fn),
          parent_session: "command:skills:#{message.channel}:#{message.chat_id}"
        ]

    case SkillCuration.approve_proposal(token, opts) do
      {:ok, :drafting} ->
        reply(reply_fn, "Approved — drafting #{row.skill_name} now, outcome follows.")

      {:ok, {:archived, _path}} ->
        reply(
          reply_fn,
          "Archived #{row.skill_name}. Reversible: `/skills restore #{row.skill_name}`."
        )

      {:error, {:invalid_status, status}} ->
        reply(reply_fn, "This proposal is no longer pending (status: #{status}).")

      {:error, reason} ->
        reply(reply_fn, "Approve failed: #{format_reason(reason)}")
    end
  end

  defp deny(token, message, reply_fn, context) do
    with {:ok, row} <- SkillCuration.get_proposal(token, core_opts(context)),
         :ok <- validate_origin(row, message),
         {:ok, _row} <- SkillCuration.decline_proposal(token, core_opts(context)) do
      reply(
        reply_fn,
        "Noted — I won't suggest that again. (`/skills unpark #{token}` undoes this.)"
      )
    else
      {:error, :not_found} -> reply(reply_fn, "Unknown proposal token.")
      {:error, :origin_mismatch} -> reply(reply_fn, origin_mismatch_text())
      {:error, {:invalid_status, status}} -> reply(reply_fn, "Already #{status}.")
      {:error, reason} -> reply(reply_fn, "Deny failed: #{inspect(reason)}.")
    end
  end

  defp list_proposals(message, reply_fn, context) do
    case SkillCuration.proposals_overview(core_opts(context)) do
      {:ok, overview} ->
        restamp_listed(overview.actionable, message, context)
        reply(reply_fn, proposals_text(overview))

      {:error, reason} ->
        reply(reply_fn, "Could not list proposals: #{inspect(reason)}.")
    end
  end

  # §6.7: a proposal listed via /skills proposals is actionable from any
  # operator conversation — listing re-stamps the origin to the (owner-private,
  # already gated) listing conversation so the same-origin check passes here.
  defp restamp_listed(rows, message, context) do
    now = DateTime.utc_now()

    rows
    |> Enum.filter(&(&1.status == "pending"))
    |> Enum.each(fn row ->
      case Proposals.stamp_origin(
             row.token,
             message.channel,
             message.chat_id,
             now,
             Keyword.take(core_opts(context), [:repo])
           ) do
        {:ok, _row} -> :ok
        {:error, reason} -> Logger.warning("proposal re-stamp failed: #{inspect(reason)}")
      end
    end)
  end

  defp list_managed(reply_fn, context) do
    case SkillCuration.list_skills(core_opts(context)) do
      {:ok, groups} -> reply(reply_fn, inventory_text(groups))
      {:error, reason} -> reply(reply_fn, "Could not list skills: #{inspect(reason)}.")
    end
  end

  # Tight, mobile-first lines: one usage fragment per skill, no prose.
  defp inventory_text(%{managed: [], local: [], plugin: []}), do: "No skills installed."

  defp inventory_text(groups) do
    [
      section("Curation-managed", groups.managed, &managed_line/1),
      section("Skills", groups.local, &skill_line/1),
      section("Plugin", groups.plugin, &skill_line/1)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp managed_line(entry) do
    "- #{entry.skill_name} (#{entry.status}) · #{usage_fragment(entry)}"
  end

  defp skill_line(entry) do
    "- #{entry.skill_name} · #{usage_fragment(entry)}"
  end

  defp usage_fragment(%{runs: runs, last_used_at: at}) when runs > 0 do
    "runs #{runs} · last #{date(at)}"
  end

  defp usage_fragment(%{views: views, last_used_at: at}) when views > 0 do
    "viewed #{views} · last #{date(at)}"
  end

  defp usage_fragment(_entry), do: "unused"

  defp archive(skill_name, reply_fn, context) do
    case SkillCuration.archive_skill(skill_name, core_opts(context)) do
      {:ok, _path} ->
        reply(
          reply_fn,
          "Archived #{skill_name}. Reversible: `/skills restore #{skill_name}`."
        )

      {:error, :not_curation_managed} ->
        reply(
          reply_fn,
          "#{skill_name} is not curation-managed — only skills curation created " <>
            "can be archived here."
        )

      {:error, :already_archived} ->
        reply(reply_fn, "#{skill_name} is already archived.")

      {:error, {:not_found, _name}} ->
        reply(reply_fn, "The skill directory for #{skill_name} is missing on disk.")

      {:error, reason} ->
        reply(reply_fn, "Archive failed: #{format_reason(reason)}")
    end
  end

  defp unpark(token_or_prefix, reply_fn, context) do
    case SkillCuration.unpark(token_or_prefix, core_opts(context)) do
      {:ok, cleared} ->
        reply(reply_fn, "Cleared #{cleared} answer(s) — the next cycle may re-propose once.")

      {:error, :not_found} ->
        reply(reply_fn, "Nothing declined or parked matches that token or signature.")

      {:error, {:ambiguous, signatures}} ->
        reply(reply_fn, "Ambiguous — matches: #{Enum.join(signatures, " · ")}")

      {:error, reason} ->
        reply(reply_fn, "Unpark failed: #{inspect(reason)}.")
    end
  end

  defp restore(skill_name, reply_fn, context) do
    case SkillCuration.restore(skill_name, core_opts(context)) do
      {:ok, {:restorables, []}} ->
        reply(reply_fn, "Nothing to restore.")

      {:ok, {:restorables, restorables}} ->
        reply(reply_fn, restorables_text(restorables))

      {:ok, :unarchived} ->
        reply(reply_fn, "Restored #{skill_name} from the archive.")

      {:ok, :snapshot_restored} ->
        reply(reply_fn, "Restored #{skill_name} to its previous body (swap is reversible).")

      {:error, :not_curation_managed} ->
        reply(reply_fn, "#{skill_name} is not a curation-managed skill.")

      {:error, {:live_skill_exists, path}} ->
        reply(reply_fn, "Refusing: a live skill already exists at #{path}.")

      {:error, :no_snapshots} ->
        reply(reply_fn, "#{skill_name} has no snapshots to restore.")

      {:error, reason} ->
        reply(reply_fn, "Restore failed: #{format_reason(reason)}")
    end
  end

  # Origin validation (§6.7): a button-delivered proposal is origin-stamped
  # and must be actioned from the same channel + chat; a proposal listed via
  # `/skills proposals` (no stamp yet) is actionable from any operator
  # conversation.
  defp validate_origin(%{origin_channel: nil}, _message), do: :ok

  defp validate_origin(row, message) do
    if row.origin_channel == message.channel and row.origin_chat_id == message.chat_id do
      :ok
    else
      {:error, :origin_mismatch}
    end
  end

  defp outcome_notifier(reply_fn) do
    fn
      {:ok, outcome} -> reply_fn.({:text, outcome_text(outcome)})
      {:error, reason} -> reply_fn.({:text, "Skill drafting failed: #{format_reason(reason)}"})
    end
  end

  defp outcome_text(outcome) do
    warning =
      case outcome.suspect_matches do
        nil -> ""
        matches -> "\n⚠️ Injection scan flagged: #{Enum.join(matches, ", ")} (review the body)."
      end

    "Skill #{outcome.skill_name} is live at #{outcome.path} — #{outcome.description}\n" <>
      "Edit it freely; `/skills restore #{outcome.skill_name}` undoes an update or an archive." <>
      warning
  end

  defp review_text(counts) do
    created =
      counts.proposals_new + counts.proposals_update + counts.proposals_archive +
        counts.delivered_deferred

    cond do
      created == 0 ->
        "Nothing new — no repeated uncovered tasks found this window."

      counts.delivery_status == :delivered ->
        "#{counts.cycle_summary}\nDelivered #{created} proposal(s) " <>
          "(#{counts.proposals_new} new, #{counts.proposals_update} update, " <>
          "#{counts.proposals_archive} archive, #{counts.delivered_deferred} carried over)."

      true ->
        "#{counts.cycle_summary}\nCreated #{created} proposal(s), but delivery " <>
          "reported #{counts.delivery_status} — see /skills proposals."
    end
  end

  defp proposals_text(%{actionable: [], declined: [], parked: []}) do
    "No proposals — pending, declined, or parked."
  end

  defp proposals_text(overview) do
    [
      section("Actionable", overview.actionable, &actionable_line/1),
      section("Declined", overview.declined, &declined_line/1),
      section("Parked (ignored twice)", overview.parked, &parked_line/1)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp section(_title, [], _render), do: nil

  defp section(title, items, render) do
    "#{title}:\n" <> Enum.map_join(items, "\n", render)
  end

  defp actionable_line(row) do
    "- [#{row.token}] #{row.kind}: #{row.skill_name} — #{row.task_signature} (#{row.status})"
  end

  defp declined_line(row) do
    "- #{row.task_signature} (declined #{date(row.actioned_at)}; " <>
      "`/skills unpark #{row.token}` to allow again)"
  end

  defp parked_line(entry) do
    "- #{entry.task_signature} (expired #{entry.expired_count}x; unpark by signature to revive)"
  end

  defp restorables_text(restorables) do
    "Restorable:\n" <>
      Enum.map_join(restorables, "\n", fn
        %{kind: :archived} = item ->
          "- #{item.skill_name} (archived #{date(item.archived_at)})"

        %{kind: :snapshot} = item ->
          "- #{item.skill_name} (has body snapshots)"
      end)
  end

  defp usage_text do
    """
    Usage:
      /skills review — run a curation cycle now
      /skills approve <token> · /skills deny <token>
      /skills proposals — list pending, declined, and parked
      /skills list — curation-managed skills with usage
      /skills archive <name> — reversibly archive a curation-made skill
      /skills unpark <token-or-signature-prefix> — allow a buried idea again
      /skills restore [<name>] — undo an archive or a body update\
    """
  end

  defp origin_mismatch_text do
    "This proposal was delivered to a different chat — action it there, " <>
      "or find it via /skills proposals."
  end

  defp date(nil), do: "unknown date"
  defp date(%DateTime{} = at), do: at |> DateTime.to_date() |> Date.to_iso8601()

  defp format_reason({kind, detail}) when is_atom(kind), do: "#{kind}: #{inspect(detail)}"
  defp format_reason(reason), do: inspect(reason)

  defp args(message) do
    message.content |> String.trim() |> String.split(" ", trim: true)
  end

  defp reply(reply_fn, text) do
    reply_fn.({:text, text})
    :ok
  end

  defp core_opts(context) do
    Keyword.take(Map.get(context, :skill_curation_opts, []), [
      :repo,
      :adapter,
      :adapter_opts,
      :route_key,
      :routes,
      :skills_root,
      :skill_registry,
      :capability_registry,
      :main_agent_server,
      :task_supervisor,
      :channel_adapter,
      :channels,
      :configured_owners,
      :jobs_config,
      :now
    ])
  end

  defp curation_enabled? do
    SkillCurationConfig.enabled?()
  end

  defp memory_enabled? do
    MemoryConfig.enabled?()
  end
end
