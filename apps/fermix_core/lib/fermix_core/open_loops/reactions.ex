defmodule FermixCore.OpenLoops.Reactions do
  @moduledoc """
  The open-loop follow-up record (MILESTONE_83 §07): each time Fermix followed
  a loop up, what it said, and what the owner said next in that conversation
  within a day, or that they said nothing. Written by code, never by the model;
  read back as the owner's own words with the delay, never as a score or a
  label.

  Writes, each a visible call at its one call site:

    * `record_asked/4` — rung 1, from `OpenLoops.Registry`'s `asked` settle:
      the settling turn's conversation and session; what Fermix said is
      filled after the run by `record_raised_with/4`, from `Agents.TurnRunner`;
      never on a voice call, where the spoken reply cannot be captured;
    * `record_raised_after_outside_content/3` — from `Agents.TurnRunner` when
      the run ends: a turn that read outside content marks the rung 1 raises
      it recorded, one recorded before the read among them;
    * `record_sent/4` — rung 2, from `OpenLoops.CheckIn`'s confirmed send: the
      delivery target's conversation and the sent text, no session; only on an
      inbox where the owner's reply can be captured;
    * `capture/3` — from `Agents.TurnRunner` before the run: what the owner
      typed (`UntrustedContent.owner_text/1`, nothing for a forwarded
      message), its first `Defaults.reply_text_max/0` characters, as the reply
      to every follow-up still awaiting one in that conversation and raised
      within `Defaults.reply_window_ms/0`;
    * `stamp_answer/4` and `forget/2` — from the Registry's other settles: the
      answer goes on the loop's latest follow-up, and a drop deletes the
      loop's record (loops are never deleted, so this is what "drop that"
      removes).

  Reads (`recent/5`, `by_loop/2`) first mark every follow-up past its window
  `no_reply`, so silence is recorded when it is next looked at. Each reply
  or silence recorded is traced once, `[:fermix, :open_loop, :reaction]`.

  What Fermix said has a provenance, as a loop's words do: a follow-up made by
  a turn or check-in run that had read content someone else could have
  written (`raised_after_outside_content`) may carry that content's words, so
  they come back framed as outside content (`line/2`, `follow_up/2`), and a
  due note or check-in that shows one counts it as an outside source
  (`outside_content?/1`).

  What Fermix said on a turn that could see the owner's computer activity is
  activity-derived as a whole (MILESTONE_32 §13.6, the strict taint), so it is
  stored marked (`raised_history_tainted`) and the reads hold it back unless
  the caller says the turn may carry activity (`opts[:activity_allowed]`, the
  Recent Activity section's own decision, which also stamps that turn's
  reply). Held back, a follow-up reads as raised with no words: a check-in run,
  which never sees activity, always reads it so.

  The turn-side calls (`capture/3`, `record_raised_with/4`,
  `record_raised_after_outside_content/3`) do nothing on a turn the due note
  would not carry (`noted_turn?/1`): a guest's turn, a group chat or a Slack
  channel mention, an unattended run, or open loops off. Rendering (`pick/3`,
  `line/2`, `follow_up/2`, `closing_sentences/1`, `delay/1`) is pure.

  Every Repo call is bounded by `Timeouts.repo_call/0` and a timeout is an
  error tuple, so a slow store never crashes a turn or a tool. A store that is
  disabled holds no record, and the calls do nothing.
  """

  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.Clock
  alias FermixCore.Delivery.OwnerInbox
  alias FermixCore.Memory.Repo
  alias FermixCore.OpenLoops.Access
  alias FermixCore.OpenLoops.Config
  alias FermixCore.OpenLoops.Defaults
  alias FermixCore.OpenLoops.Registry
  alias FermixCore.OpenLoops.Telemetry
  alias FermixCore.Timeouts

  @type reaction :: Repo.open_loop_reaction_row()
  @type conversation :: {String.t(), String.t(), String.t()}

  # A sentence ends at terminal punctuation, with any closing quotes or
  # brackets, before whitespace; a line break also starts one.
  @sentence_break ~r/[.!?…]["'”’)\]]*\s+|\n\s*/u

  # --- the turn ----------------------------------------------------------------

  @doc """
  Whether a turn is one the record follows: open loops on, and the owner's
  attended turn in a private chat (`OpenLoops.Access.private_owner_turn?/1`).
  The due note's predicate.
  """
  @spec noted_turn?(map()) :: boolean()
  def noted_turn?(context) when is_map(context),
    do: Config.enabled?() and Access.private_owner_turn?(context)

  @doc """
  Takes the owner's message as the reply to every follow-up awaiting one in
  this turn's conversation, raised within the reply window and before `now`.
  `message_text` is what the owner typed (`UntrustedContent.owner_text/1`):
  empty for a forwarded message or a voice hand-off, which answer nothing.
  Returns how many it answered; 0 on a turn the record does not follow.
  """
  @spec capture(map(), String.t(), DateTime.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def capture(context, message_text, %DateTime{} = now)
      when is_map(context) and is_binary(message_text) do
    case {turn_repo(context), reply_text(message_text)} do
      {nil, _text} -> {:ok, 0}
      {_repo, nil} -> {:ok, 0}
      {repo, text} -> capture_reply(repo, context, text, now)
    end
  end

  defp capture_reply(repo, context, text, now) do
    with {:ok, conversation} <- conversation(context) do
      context
      |> scope()
      |> Map.merge(conversation_attrs(conversation))
      |> Map.merge(%{reply_text: text, reply_at: now, since: window_start(now)})
      |> Repo.capture_open_loop_replies(call_opts(repo))
      |> traced_replies(session_id(context))
    end
  end

  defp traced_replies({:ok, answered}, session_id) do
    Enum.each(answered, fn row ->
      after_ms = DateTime.diff(row.reply_at, row.raised_at, :millisecond)
      Telemetry.reaction(row.open_loop_id, row.rung, "replied", after_ms, session_id)
    end)

    {:ok, length(answered)}
  end

  defp traced_replies({:error, :disabled}, _session_id), do: {:ok, 0}
  defp traced_replies({:error, reason}, _session_id), do: {:error, reason}

  @doc """
  Stores what Fermix said on the rung 1 follow-ups raised in this turn's
  conversation since `since` (the turn's start) and still without it: the
  closing sentences of the turn's final reply (`closing_sentences/1`), with
  `history_tainted`, whether that reply was stamped with the owner's computer
  activity. The conversation is single-flight, so those are this turn's.
  Returns how many it wrote; 0 on a turn the record does not follow, or a
  blank reply.
  """
  @spec record_raised_with(map(), String.t(), DateTime.t(), boolean()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def record_raised_with(context, reply, %DateTime{} = since, history_tainted)
      when is_map(context) and is_binary(reply) and is_boolean(history_tainted) do
    case {turn_repo(context), closing_sentences(reply)} do
      {nil, _text} -> {:ok, 0}
      {_repo, nil} -> {:ok, 0}
      {repo, text} -> store_raised_with(repo, context, text, since, history_tainted)
    end
  end

  defp store_raised_with(repo, context, text, since, history_tainted) do
    with {:ok, conversation} <- conversation(context) do
      context
      |> scope()
      |> Map.merge(conversation_attrs(conversation))
      |> Map.merge(%{
        since: since,
        now: now(context),
        raised_with: text,
        raised_history_tainted: history_tainted
      })
      |> Repo.record_open_loop_raised_with(call_opts(repo))
      |> nothing_when_disabled()
    end
  end

  @doc """
  Marks the rung 1 follow-ups raised in this turn's conversation since `since`
  (the turn's start) as raised after outside content, when `read`, the run's
  whole `outside_sources`, holds any. A raise is stamped from what its turn had
  read when the model recorded it; a page read after that is known only when
  the run ends, and this catches it. Returns how many it marked; 0 on a turn
  that read nothing or one the record does not follow.
  """
  @spec record_raised_after_outside_content(map(), MapSet.t(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def record_raised_after_outside_content(context, %MapSet{} = read, %DateTime{} = since)
      when is_map(context) do
    case {turn_repo(context), MapSet.size(read)} do
      {nil, _count} -> {:ok, 0}
      {_repo, 0} -> {:ok, 0}
      {repo, _count} -> mark_outside_content(repo, context, since)
    end
  end

  defp mark_outside_content(repo, context, since) do
    with {:ok, conversation} <- conversation(context) do
      context
      |> scope()
      |> Map.merge(conversation_attrs(conversation))
      |> Map.merge(%{since: since, now: now(context)})
      |> Repo.record_open_loop_raised_after_outside_content(call_opts(repo))
      |> nothing_when_disabled()
    end
  end

  # --- the registry and the check-in -------------------------------------------

  @doc """
  Records a rung 1 follow-up: the loop raised in this turn's conversation and
  recorded as asked in its session, stamped when the turn had read outside
  content by then (`OpenLoops.Access.read_outside?/1`; the run's end marks a
  later read, `record_raised_after_outside_content/3`). What Fermix said is
  filled after the run. `opts[:repo]` names the Repo.

  Never on a voice call (`OpenLoops.Access.voice_call?/1`): a Live or Grok
  hand-off runs in the chat's conversation, but the owner answers out loud and
  its text is not what they typed, so their reply is never captured and the
  follow-up would only read as silence, or take an unrelated typed message as
  the reply. It is `{:skipped, :reply_uncapturable}`, as `record_sent/4` is for
  such an inbox, and nothing is written.
  """
  @spec record_asked(Repo.open_loop_row(), map(), DateTime.t(), keyword()) ::
          {:ok, reaction()} | {:skipped, :reply_uncapturable} | {:error, term()}
  def record_asked(%{id: _id} = loop, context, %DateTime{} = now, opts)
      when is_map(context) and is_list(opts) do
    if Access.voice_call?(context),
      do: {:skipped, :reply_uncapturable},
      else: record_raise(loop, context, now, opts)
  end

  defp record_raise(loop, context, now, opts) do
    with {:ok, conversation} <- conversation(context) do
      raise_spec = %{
        rung: 1,
        session_id: session_id(context),
        raised_with: nil,
        raised_after_outside_content: Access.read_outside?(context)
      }

      record(loop, raise_spec, conversation, now, opts)
    end
  end

  @doc """
  Records a rung 2 follow-up: a check-in message confirmed sent to the loop's
  delivery target, with its closing sentences as what Fermix said, and
  `opts[:raised_after_outside_content]`, whether the run that wrote it had
  read outside content, which every send states.

  Only where the owner's reply can be captured: an inbox keyed by the owner's
  own id (`Delivery.OwnerInbox.dm_origin/1`), where their DM arrives under the
  conversation the follow-up is recorded in. A Slack or Discord DM arrives
  under its DM channel's id and a CLI turn under its session id, so a follow-up
  there would only ever read as silence; it is `{:skipped,
  :reply_uncapturable}`, and nothing is written.
  """
  @spec record_sent(Repo.open_loop_row(), String.t(), DateTime.t(), keyword()) ::
          {:ok, reaction()} | {:skipped, :reply_uncapturable} | {:error, term()}
  def record_sent(%{id: _id} = loop, text, %DateTime{} = now, opts)
      when is_binary(text) and is_list(opts) do
    inbox = %{platform: loop.delivery_platform, destination: loop.delivery_destination}

    case OwnerInbox.dm_origin(inbox) do
      {:ok, _origin} -> record_sent_text(loop, text, now, opts)
      :error -> {:skipped, :reply_uncapturable}
    end
  end

  defp record_sent_text(loop, text, now, opts) do
    conversation = {loop.delivery_platform, loop.delivery_destination, loop.delivery_thread_scope}

    raise_spec = %{
      rung: 2,
      session_id: nil,
      raised_with: closing_sentences(text),
      raised_after_outside_content: Keyword.get(opts, :raised_after_outside_content)
    }

    record(loop, raise_spec, conversation, now, opts)
  end

  defp record(loop, raise_spec, {channel, chat_id, thread}, now, opts) do
    raise_spec
    |> Map.merge(%{
      id: new_id(),
      owner_id: loop.owner_id,
      agent_id: loop.agent_id,
      open_loop_id: loop.id,
      raised_at: now,
      source_channel: channel,
      source_chat_id: chat_id,
      source_thread_scope: thread
    })
    |> Repo.record_open_loop_reaction(call_opts(Keyword.get(opts, :repo, Repo)))
  end

  @doc """
  Stamps a settle's answer on the loop's latest follow-up, once. Returns 0 when
  the loop has none, or its latest already carries one.
  """
  @spec stamp_answer(Repo.open_loop_row(), String.t(), DateTime.t(), keyword()) ::
          {:ok, 0 | 1} | {:error, term()}
  def stamp_answer(%{id: id, owner_id: owner_id}, answer, %DateTime{} = now, opts)
      when is_binary(answer) and is_list(opts) do
    opts = opts |> Keyword.get(:repo, Repo) |> call_opts() |> Keyword.put(:now, now)
    Repo.answer_open_loop_reaction(owner_id, id, answer, opts)
  end

  @doc "Deletes the loop's whole follow-up record, as a drop does. Returns how many."
  @spec forget(Repo.open_loop_row(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def forget(%{id: id, owner_id: owner_id}, opts) when is_list(opts) do
    Repo.delete_open_loop_reactions(owner_id, id, call_opts(Keyword.get(opts, :repo, Repo)))
  end

  # --- reads ---------------------------------------------------------------------

  @doc """
  The answered follow-ups of one owner and agent, relevance first (`pick/3`):
  each of `loop_ids`' latest `replies.this_loop`, then the most recent
  `replies.others` not already shown. Each row carries its loop's
  `intention`.

  `opts`: `:repo`, `:now` (the clock), `:session_id` (the observing
  turn's, carried by the `no_reply` traces this read records) and
  `:activity_allowed`, true only on a turn the Computer History Gate lets
  carry the owner's activity; otherwise what Fermix said on a turn that could
  see it is held back (`hold_back_activity/2`).
  """
  @spec recent(String.t(), String.t(), [String.t()], Defaults.replies(), keyword()) ::
          {:ok, [reaction()]} | {:error, term()}
  def recent(owner_id, agent_id, loop_ids, %{this_loop: _n, others: _m} = replies, opts \\ [])
      when is_binary(owner_id) and is_binary(agent_id) and is_list(loop_ids) and is_list(opts) do
    with {:ok, rows} <- read(owner_id, opts) do
      rows
      |> hold_back_activity(Keyword.get(opts, :activity_allowed, false))
      |> Enum.filter(&(&1.agent_id == agent_id and not is_nil(&1.outcome)))
      |> pick(loop_ids, replies)
      |> then(&{:ok, &1})
    end
  end

  @doc """
  The owner's whole record by loop id, each loop's follow-ups newest first,
  awaiting ones included: what `open_loop_list` shows. `opts` as `recent/5`.
  """
  @spec by_loop(String.t(), keyword()) :: {:ok, %{String.t() => [reaction()]}} | {:error, term()}
  def by_loop(owner_id, opts \\ []) when is_binary(owner_id) and is_list(opts) do
    with {:ok, rows} <- read(owner_id, opts) do
      rows
      |> hold_back_activity(Keyword.get(opts, :activity_allowed, false))
      |> Enum.group_by(& &1.open_loop_id)
      |> then(&{:ok, &1})
    end
  end

  defp read(owner_id, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    call = opts |> Keyword.get(:repo, Repo) |> call_opts() |> Keyword.put(:now, now)

    with {:ok, stamped} <- Repo.stamp_open_loop_no_replies(owner_id, window_start(now), call) do
      Enum.each(stamped, fn row ->
        Telemetry.reaction(row.open_loop_id, row.rung, "no_reply", nil, opts[:session_id])
      end)

      Repo.list_open_loop_reactions(owner_id, call)
    end
  end

  # The rows as a reader that may not carry the owner's computer activity sees
  # them: what Fermix said on a turn that could see it is dropped, with its
  # outside-content mark, which was about those words alone. The follow-up, its
  # loop and the owner's reply stay.
  defp hold_back_activity(rows, true), do: rows

  defp hold_back_activity(rows, false) do
    Enum.map(rows, fn
      %{raised_history_tainted: true} = row ->
        %{row | raised_with: nil, raised_after_outside_content: false}

      row ->
        row
    end)
  end

  # --- rendering (pure) ------------------------------------------------------------

  @doc """
  Relevance first, from rows newest first: each loop's latest `this_loop`,
  in `loop_ids`' order, then the most recent `others` not already picked.
  """
  @spec pick([reaction()], [String.t()], Defaults.replies()) :: [reaction()]
  def pick(rows, loop_ids, %{this_loop: this_loop, others: others})
      when is_list(rows) and is_list(loop_ids) and is_integer(this_loop) and is_integer(others) do
    own =
      Enum.flat_map(loop_ids, fn id ->
        rows |> Enum.filter(&(&1.open_loop_id == id)) |> Enum.take(this_loop)
      end)

    shown = MapSet.new(own, & &1.id)
    own ++ (rows |> Enum.reject(&MapSet.member?(shown, &1.id)) |> Enum.take(others))
  end

  @doc """
  Whether a follow-up shows words that may be someone else's: what Fermix said
  after outside content, or its loop's words, noted after it. A due note or a
  check-in that shows one counts it as an outside source.
  """
  @spec outside_content?(reaction()) :: boolean()
  def outside_content?(%{raised_after_outside_content: raised} = reaction)
      when is_boolean(raised),
      do: raised or Map.get(reaction, :noted_after_outside_content, false)

  @doc """
  One answered follow-up as the due note and a check-in read it: the day,
  what the loop is about, how it was raised, what Fermix said, and the
  owner's reply with its delay, or that none came within a day. The day is
  on `FermixCore.Clock`, in the owner's zone (`opts[:personalization]`).

  Every text is data, re-read at system priority, so each is JSON-quoted and
  none can end its quotation: what Fermix said, what the owner replied, and
  the loop's words, which for a loop noted after outside content are framed
  as `OpenLoops.Registry.framed_intention/1` frames them everywhere else.
  What Fermix said after outside content is framed the same way.
  """
  @spec line(reaction(), keyword()) :: String.t()
  def line(%{intention: intention} = reaction, opts \\ [])
      when is_binary(intention) and is_list(opts) do
    "#{day(reaction.raised_at, opts)}, about #{about(reaction)}, #{how(reaction.rung)}: " <>
      said(reaction) <> "; " <> answered(reaction)
  end

  @doc """
  One follow-up as `open_loop_list` shows it under its loop: `line/2` without
  the loop's words, and a follow-up still inside its window says so.
  """
  @spec follow_up(reaction(), keyword()) :: String.t()
  def follow_up(reaction, opts \\ []) when is_map(reaction) and is_list(opts) do
    "#{day(reaction.raised_at, opts)}, #{how(reaction.rung)}: " <>
      said(reaction) <> "; " <> answered(reaction)
  end

  defp day(at, opts),
    do: at |> DateTime.shift_zone!(Clock.shown_zone(opts)) |> Calendar.strftime("%A, %B %-d")

  defp about(%{noted_after_outside_content: true} = reaction),
    do: Registry.framed_intention(reaction)

  defp about(%{intention: intention}), do: Jason.encode!(intention)

  defp how(1), do: "in conversation"
  defp how(2), do: "by message"

  defp said(%{raised_with: nil}), do: "Fermix raised it"

  defp said(%{raised_with: text, raised_after_outside_content: false}),
    do: "Fermix said #{Jason.encode!(text)}"

  # Raised after outside content, the words may be that content's: JSON-quoted
  # inside the frame, as a stamped loop's words are.
  defp said(%{raised_with: text, raised_after_outside_content: true}) do
    "Fermix said, after reading content someone else could have written, " <>
      UntrustedContent.frame("open_loop_raise", Jason.encode!(text))
  end

  defp answered(%{outcome: "replied"} = reaction) do
    after_ms = DateTime.diff(reaction.reply_at, reaction.raised_at, :millisecond)
    "the owner replied #{delay(after_ms)} later: #{Jason.encode!(reaction.reply_text)}"
  end

  defp answered(%{outcome: "no_reply"}), do: "no reply within a day."
  defp answered(%{outcome: nil}), do: "no reply yet."

  @doc """
  A delay as a person says it: under a minute, whole minutes under an hour,
  else hours to the nearest.
  """
  @spec delay(non_neg_integer()) :: String.t()
  def delay(ms) when is_integer(ms) and ms >= 0 do
    minutes = div(ms, 60_000)

    cond do
      minutes == 0 -> "under a minute"
      minutes < 60 -> count(minutes, "minute")
      true -> count(div(minutes + 30, 60), "hour")
    end
  end

  defp count(1, unit), do: "1 #{unit}"
  defp count(n, unit), do: "#{n} #{unit}s"

  @doc """
  What Fermix said, from a reply or a sent message: the whole text when it
  fits `Defaults.raised_with_max/0` characters, else the longest run of its
  closing sentences that fits, cut at a sentence start. A closing sentence
  longer than the bound alone keeps its last words, cut at a word start and
  marked with a leading ellipsis. Nil for a blank text.
  """
  @spec closing_sentences(String.t()) :: String.t() | nil
  def closing_sentences(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> fit_closing(trimmed, Defaults.raised_with_max())
    end
  end

  defp fit_closing(text, max) do
    if String.length(text) <= max, do: text, else: closing_tail(text, max)
  end

  defp closing_tail(text, max) do
    fitting =
      @sentence_break
      |> Regex.scan(text, return: :index)
      |> Enum.map(fn [{start, length}] ->
        binary_part(text, start + length, byte_size(text) - start - length)
      end)
      |> Enum.find(&(&1 != "" and String.length(&1) <= max))

    fitting || last_words(text, max)
  end

  defp last_words(text, max) do
    tail = String.slice(text, -(max - 1), max - 1)

    case String.split(tail, ~r/\s+/u, parts: 2) do
      [_partial_word, rest] when rest != "" -> "…" <> rest
      _one_word -> "…" <> tail
    end
  end

  # --- plumbing ----------------------------------------------------------------------

  defp reply_text(message) do
    case String.trim(message) do
      "" -> nil
      text -> String.slice(text, 0, Defaults.reply_text_max())
    end
  end

  defp turn_repo(context) do
    if noted_turn?(context), do: Map.get(context, :memory_repo, Repo)
  end

  defp scope(context) do
    %{
      owner_id: Map.get(context, :memory_owner_id, "default"),
      agent_id: Map.get(context, :memory_agent_id, "main")
    }
  end

  # The conversation as every open-loop row stores it (`OpenLoops.Registry`'s
  # source): strings, the root thread as "root".
  defp conversation(%{conversation_key: {channel, chat_id, scope}})
       when (is_binary(channel) or is_atom(channel)) and not is_nil(channel) and
              (is_binary(chat_id) or is_integer(chat_id)) do
    case thread(scope) do
      {:ok, thread} -> {:ok, {to_string(channel), to_string(chat_id), thread}}
      :error -> {:error, :no_conversation}
    end
  end

  defp conversation(_context), do: {:error, :no_conversation}

  defp thread(:root), do: {:ok, "root"}
  defp thread(scope) when is_binary(scope) and scope != "", do: {:ok, scope}
  defp thread(scope) when is_integer(scope), do: {:ok, Integer.to_string(scope)}
  defp thread(_scope), do: :error

  defp conversation_attrs({channel, chat_id, thread}),
    do: %{source_channel: channel, source_chat_id: chat_id, source_thread_scope: thread}

  defp session_id(%{session_id: id}) when is_binary(id) and id != "", do: id
  defp session_id(_context), do: nil

  defp now(%{now_fn: now_fn}) when is_function(now_fn, 0), do: now_fn.()
  defp now(_context), do: DateTime.utc_now()

  defp window_start(now), do: DateTime.add(now, -Defaults.reply_window_ms(), :millisecond)

  defp call_opts(repo), do: Repo.periodic_opts(repo, Timeouts.repo_call())

  defp nothing_when_disabled({:error, :disabled}), do: {:ok, 0}
  defp nothing_when_disabled(result), do: result

  defp new_id,
    do: "reaction_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
end
