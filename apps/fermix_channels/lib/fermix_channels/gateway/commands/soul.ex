defmodule FermixChannels.Gateway.Commands.Soul do
  @moduledoc """
  Owner-only `/soul` command: review, apply, revert, or reset the agent's
  persona (`SOUL.md`).

  Mutations are gated behind a propose -> token -> `/soul apply <token>`
  confirmation (mirroring `/sandbox`), so every persona change requires a
  second, explicit owner action. All writes go through
  `FermixCore.SoulCuration`, which versions them in the resource registry.
  """

  @behaviour FermixChannels.Gateway.Command

  alias FermixChannels.Gateway.Commands.Authorization
  alias FermixChannels.Gateway.Commands.Soul.Confirmations
  alias FermixCore.Agents.MainAgent
  alias FermixCore.Memory.Compactor
  alias FermixCore.Memory.Repo
  alias FermixCore.Resource.Revision
  alias FermixCore.SoulCuration
  alias FermixCore.SoulCuration.Proposal

  # Reviewing a persona diff is a deliberate human task (read the diff, weigh it,
  # copy the apply command back) — a 60s window timed out mid-review, so the
  # confirmation token lives 5 minutes. The reply text derives its expiry note
  # from this constant so the two never drift.
  @ttl_ms 300_000
  @ttl_minutes div(@ttl_ms, 60_000)

  # `--with-context` evidence read (§5, Stage 1b): the most recent owner-authored
  # messages in this conversation, hard-bounded so a long thread can't blow up
  # the draft prompt. The owner-only command plus a `sender` filter keep guest
  # turns out of the evidence entirely.
  @evidence_limit 40
  @evidence_token_budget 1_500
  @context_flag "--with-context"

  @impl true
  def name, do: "soul"

  @impl true
  def aliases, do: []

  @impl true
  def description, do: "Review, apply, revert, or reset the agent's persona (SOUL.md)."

  @impl true
  def authorize(message, metadata, context),
    do: Authorization.owner_only(message, metadata, context)

  @impl true
  def execute(message, reply_fn, context) do
    dispatch(args(message), message, reply_fn, context)
  end

  defp dispatch([], _message, reply_fn, context), do: reply(reply_fn, overview_text(context))

  defp dispatch(["history"], _message, reply_fn, context),
    do: reply(reply_fn, history_text(context))

  defp dispatch(["review" | instruction_words], message, reply_fn, context),
    do: propose_curation(instruction_words, message, reply_fn, context)

  defp dispatch(["diff", token], message, reply_fn, context),
    do: show_diff(token, message, reply_fn, context)

  defp dispatch(["revert", revision], message, reply_fn, _context),
    do: propose_revert(revision, message, reply_fn)

  defp dispatch(["reset"], message, reply_fn, _context),
    do: propose_reset(message, reply_fn)

  defp dispatch(["apply", token], message, reply_fn, context),
    do: apply_token(token, message, reply_fn, context)

  defp dispatch(_args, _message, reply_fn, _context), do: reply(reply_fn, usage_text())

  # `/soul review` (no instruction) = subtle voice-preserving review; `/soul
  # review <instruction>` = an explicit ask. `--with-context` opts a bounded
  # window of the owner's own recent messages into the draft as evidence. The
  # draft is one bounded provider call (`SoulCuration.propose/2`); it never
  # writes — the owner still confirms via `/soul apply <token>`.
  defp propose_curation(instruction_words, message, reply_fn, context) do
    {with_context?, instruction} = parse_review_args(instruction_words)

    case resolve_evidence(with_context?, message, context) do
      {:ok, evidence} ->
        run_proposal(instruction, evidence, message, reply_fn, context)

      {:error, reason} ->
        reply(reply_fn, "Could not read recent context: #{format_error(reason)}")
    end
  end

  defp run_proposal(instruction, evidence, message, reply_fn, context) do
    mode = if instruction, do: :suggest, else: :review
    reply(reply_fn, drafting_ack(mode))

    case SoulCuration.propose(mode, propose_opts(instruction, evidence, message, context)) do
      {:ok, %Proposal{} = proposal} -> present_proposal(proposal, message, reply_fn)
      {:ok, :no_change} -> reply(reply_fn, no_change_text(mode))
      {:error, reason} -> reply(reply_fn, "Drafting failed: #{format_error(reason)}")
    end
  end

  defp parse_review_args(words) do
    {flags, rest} = Enum.split_with(words, &(&1 == @context_flag))
    {flags != [], join_instruction(rest)}
  end

  defp resolve_evidence(false, _message, _context), do: {:ok, []}

  defp resolve_evidence(true, message, context) do
    case Map.get(context, :memory_repo) do
      nil -> {:error, :memory_unavailable}
      repo -> read_owner_evidence(repo, message, context)
    end
  end

  # Owner-scoped: the `sender` filter restricts evidence to the command issuer
  # (already owner-gated), so guest turns in a shared chat never leak in. Rows
  # come back oldest-first; we keep the most recent within the token budget.
  defp read_owner_evidence(repo, message, context) do
    {channel, chat_id, thread_scope} = Map.fetch!(context, :conversation_key)

    selector = %{
      agent_id: agent_id(context),
      channel: channel,
      chat_id: chat_id,
      thread_scope: thread_scope,
      role: "user",
      sender: message.sender
    }

    case Repo.get_messages(selector, server: repo, limit: @evidence_limit) do
      {:ok, rows} -> {:ok, rows |> Enum.map(& &1.content) |> bound_evidence()}
      {:error, reason} -> {:error, reason}
    end
  end

  # Newest-first accumulation under the token budget, then restored to
  # chronological order. Always keeps at least one message so a single long
  # turn still produces evidence rather than silently nothing.
  defp bound_evidence(contents) do
    contents
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn content, {acc, tokens} ->
      next = tokens + Compactor.estimate_tokens(content)

      if next > @evidence_token_budget and acc != [] do
        {:halt, {acc, tokens}}
      else
        {:cont, {[content | acc], next}}
      end
    end)
    |> elem(0)
  end

  defp present_proposal(proposal, message, reply_fn) do
    token = store_pending(%{kind: :proposal, proposal: proposal}, message)
    reply(reply_fn, proposal_text(proposal, token))
  end

  defp show_diff(token, message, reply_fn, _context) do
    case peek_pending(token, message) do
      {:ok, %{kind: :proposal, proposal: proposal}} ->
        reply(reply_fn, proposal_text(proposal, token))

      {:ok, _other} ->
        reply(reply_fn, "Token #{token} is not a pending SOUL.md proposal.")

      {:error, reason} ->
        reply(reply_fn, "Cannot show diff: #{format_error(reason)}")
    end
  end

  defp propose_revert(revision, message, reply_fn) do
    case parse_revision(revision) do
      {:ok, number} ->
        token = store_pending(%{kind: :revert, revision: number}, message)

        reply(
          reply_fn,
          "Confirm reverting SOUL.md to revision #{number}. Tap the command below to copy it, " <>
            "then send:\n" <> apply_command(token)
        )

      :error ->
        reply(reply_fn, "Revision must be a positive integer. Usage: /soul revert N")
    end
  end

  defp propose_reset(message, reply_fn) do
    token = store_pending(%{kind: :reset}, message)

    reply(
      reply_fn,
      "Confirm resetting SOUL.md to the shipped default (itself versioned and revertable). " <>
        "Tap the command below to copy it, then send:\n" <> apply_command(token)
    )
  end

  defp apply_token(token, message, reply_fn, context) do
    case take_pending(token, message) do
      {:ok, record} -> run_pending(record, reply_fn, context)
      {:error, reason} -> reply(reply_fn, "Confirmation failed: #{format_error(reason)}")
    end
  end

  defp run_pending(%{kind: :proposal, proposal: proposal}, reply_fn, context) do
    case SoulCuration.apply(agent_id(context), proposal, soul_opts(context)) do
      {:ok, %Revision{revision: rev}} ->
        reply(reply_fn, "Applied the SOUL.md edit (new revision #{rev}).")

      {:ok, :unchanged} ->
        reply(reply_fn, "SOUL.md already matches the proposal; nothing changed.")

      {:error, reason} ->
        reply(reply_fn, "Apply failed: #{format_error(reason)}")
    end
  end

  defp run_pending(%{kind: :revert, revision: number}, reply_fn, context) do
    case SoulCuration.revert(agent_id(context), number, soul_opts(context)) do
      {:ok, %Revision{revision: rev}} ->
        reply(reply_fn, "Reverted SOUL.md to revision #{number} (new revision #{rev}).")

      {:ok, :already_at_target} ->
        reply(reply_fn, "SOUL.md is already at revision #{number}; nothing changed.")

      {:error, reason} ->
        reply(reply_fn, "Revert failed: #{format_error(reason)}")
    end
  end

  defp run_pending(%{kind: :reset}, reply_fn, context) do
    case SoulCuration.reset(agent_id(context), soul_opts(context)) do
      {:ok, %Revision{revision: rev}} ->
        reply(reply_fn, "Reset SOUL.md to the shipped default (new revision #{rev}).")

      {:ok, :unchanged} ->
        reply(reply_fn, "SOUL.md already matches the shipped default; nothing changed.")

      {:error, reason} ->
        reply(reply_fn, "Reset failed: #{format_error(reason)}")
    end
  end

  defp overview_text(context) do
    case SoulCuration.revisions(agent_id(context), soul_opts(context)) do
      {:ok, [latest | _rest] = revisions} ->
        "SOUL.md: revision #{latest.revision} (#{latest.mutation_source}), " <>
          "#{length(revisions)} revision(s) on record.\n\n" <> usage_text()

      {:ok, []} ->
        "SOUL.md: no revisions on record yet.\n\n" <> usage_text()

      {:error, reason} ->
        "SOUL.md status unavailable: #{format_error(reason)}\n\n" <> usage_text()
    end
  end

  defp history_text(context) do
    case SoulCuration.revisions(agent_id(context), soul_opts(context)) do
      {:ok, []} ->
        "No SOUL.md revisions on record yet."

      {:ok, revisions} ->
        "SOUL.md revisions (newest first):\n" <>
          Enum.map_join(revisions, "\n", &revision_line/1)

      {:error, reason} ->
        "Could not list SOUL.md history: #{format_error(reason)}"
    end
  end

  defp revision_line(%Revision{} = revision) do
    "#{revision.revision}. #{revision.mutation_source} — #{format_timestamp(revision.created_at)}"
  end

  defp usage_text do
    "Usage: /soul (status), /soul review [instruction] [--with-context], " <>
      "/soul diff TOKEN, /soul history, /soul revert N, /soul reset, /soul apply TOKEN"
  end

  defp join_instruction([]), do: nil
  defp join_instruction(words), do: Enum.join(words, " ")

  defp drafting_ack(:suggest), do: "Drafting a SOUL.md edit from your instruction…"
  defp drafting_ack(:review), do: "Reviewing SOUL.md for a subtle update…"

  defp no_change_text(:suggest),
    do: "No SOUL.md change drafted for that instruction; nothing to apply."

  defp no_change_text(:review),
    do: "No SOUL.md change warranted right now; leaving the persona as-is."

  # Mirror `/compact`: thread the gateway-supplied primary route (which may
  # carry a bound `:adapter`) when present, else let `propose/2` resolve the
  # configured chain. Drop nils so absent context keys fall through to defaults.
  defp propose_opts(instruction, evidence, message, context) do
    [
      instruction: instruction,
      evidence: evidence,
      parent_session: parent_session(message),
      repo: Map.get(context, :memory_repo),
      agent_id: agent_id(context)
    ]
    |> maybe_put_routes(context)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp maybe_put_routes(opts, %{route: {_route_key, _adapter_opts} = route}),
    do: Keyword.put(opts, :routes, [route])

  defp maybe_put_routes(opts, _context), do: opts

  defp parent_session(message), do: "command:soul:#{message.channel}:#{message.chat_id}"

  defp proposal_text(%Proposal{} = proposal, token) do
    [
      "Proposed SOUL.md edit (route: #{route_display(proposal.route_key)}):",
      diff_block(proposal.diff),
      rationale_block(proposal.rationale),
      suspect_block(proposal.provenance),
      "Re-preview with `/soul diff #{token}`. To apply (expires in #{@ttl_minutes} min), " <>
        "tap the command below to copy it, then send:\n" <> apply_command(token)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp diff_block(nil), do: "(no textual diff available)"
  defp diff_block(diff), do: String.trim_trailing(diff)

  # Render the confirmation command as an inline-code span, kept alone on its own
  # line. Telegram mobile (notably Android) shows NO copy button on fenced `<pre>`
  # code blocks, but a single TAP on any inline `<code>` span copies it instantly —
  # so inline code is the reliable one-tap-copy primitive for a token/command. The
  # callers place it on its own final line, and the surrounding prose says "tap to
  # copy", so the tap target is obvious and never buried mid-sentence.
  defp apply_command(token), do: "`/soul apply #{token}`"

  defp rationale_block(nil), do: ""
  defp rationale_block(rationale), do: "Why: #{rationale}"

  defp suspect_block(provenance) do
    case Map.get(provenance, :suspect_matches) do
      nil ->
        ""

      matches ->
        "⚠ Possible prompt-injection markers in source memory (#{Enum.join(matches, ", ")}). " <>
          "Review the diff before applying."
    end
  end

  defp route_display(%{provider: provider, model: model}), do: "#{provider}/#{model}"
  defp route_display(nil), do: "unknown"
  defp route_display(other), do: inspect(other)

  defp store_pending(payload, message) do
    token = token()
    :ok = Confirmations.store(token, pending_record(payload, message))
    token
  end

  defp take_pending(token, message) do
    case Confirmations.take(token) do
      {:ok, record} -> validate_pending(record, message)
      :error -> {:error, :unknown_token}
    end
  end

  defp peek_pending(token, message) do
    case Confirmations.peek(token) do
      {:ok, record} -> validate_pending(record, message)
      :error -> {:error, :unknown_token}
    end
  end

  defp validate_pending(record, message) do
    cond do
      record.expires_at < now_ms() -> {:error, :expired}
      same_origin?(record, message) -> {:ok, record}
      true -> {:error, :origin_mismatch}
    end
  end

  defp pending_record(payload, message) do
    Map.merge(payload, %{
      channel: message.channel,
      chat_id: message.chat_id,
      thread_ts: message.thread_ts,
      user_id: stable_user_id(message.metadata || %{}),
      expires_at: now_ms() + @ttl_ms
    })
  end

  defp same_origin?(record, message) do
    record.channel == message.channel and record.chat_id == message.chat_id and
      record.thread_ts == message.thread_ts and
      record.user_id == stable_user_id(message.metadata || %{})
  end

  defp token do
    5 |> :crypto.strong_rand_bytes() |> Base.encode32(padding: false) |> binary_part(0, 8)
  end

  defp parse_revision(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> {:ok, number}
      _other -> :error
    end
  end

  defp agent_id(context), do: Map.get(context, :memory_agent_id, "main")

  # `:agent_server` in the command context is this conversation's Gateway.Queue,
  # not the persona-owning agent. Invalidation must reach the MainAgent (the named
  # `:permanent` GenServer that holds the runtime context), so address it the same
  # way the skill_reload tool does — explicit override, else the registered name.
  defp soul_opts(context) do
    [
      repo: Map.get(context, :memory_repo),
      main_agent_server: Map.get(context, :main_agent_server, MainAgent)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp args(message), do: String.split(message.content, ~r/\s+/, trim: true)
  defp stable_user_id(metadata), do: Map.get(metadata, :user_id) || Map.get(metadata, "user_id")
  defp now_ms, do: System.monotonic_time(:millisecond)

  defp format_timestamp(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S")

  defp format_timestamp(_other), do: "unknown time"

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp reply(reply_fn, text) do
    reply_fn.({:text, text})
    :ok
  end
end
