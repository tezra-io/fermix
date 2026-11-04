defmodule FermixCore.Memory.Repo.OpenLoopReactionsSql do
  @moduledoc false
  # Private SQL for the open-loop follow-up record (MILESTONE_83 §07, §11):
  # one `open_loop_reactions` row per follow-up Fermix made (rung 1, a raise
  # in conversation; rung 2, a check-in message) and the owner's next message
  # in that conversation, or its absence. Migration 51 creates the table.
  #
  # As in `OpenLoopsSql`, every function that takes a `conn` runs only inside
  # Repo's `handle_call`s, and normalization runs in the caller, so a bad value
  # fails at the boundary. The transaction and statement plumbing is
  # `OpenLoopsSql`'s, one for the family.
  #
  # The table holds the newest `Defaults.reactions_kept/0` rows per owner: an
  # insert prunes the rest in its own transaction. "Newest" is `raised_at`, then
  # insertion order (`rowid`), the order every read here uses.
  #
  # `raised_after_outside_content` is 1 when the turn or check-in run that made
  # the follow-up had read content someone else could have written, so what
  # Fermix said is framed wherever it comes back. Every insert states it, and a
  # rung 1 raise is marked again once its turn's whole read is known.
  #
  # `raised_history_tainted` is 1 when what Fermix said came from a reply
  # stamped with the owner's computer activity (MILESTONE_32 §13.6), so the words
  # come back only where activity may (`OpenLoops.Reactions`). Only the turn's
  # own write of the words sets it: an insert carries no such words, since a
  # rung 1 raise has none yet and a check-in run never sees activity.

  alias FermixCore.Memory.Repo.OpenLoopsSql
  alias FermixCore.OpenLoops.Defaults

  @columns [
    :id,
    :owner_id,
    :agent_id,
    :open_loop_id,
    :rung,
    :raised_at,
    :session_id,
    :source_channel,
    :source_chat_id,
    :source_thread_scope,
    :raised_with,
    :reply_text,
    :reply_at,
    :outcome,
    :answer,
    :created_at,
    :updated_at,
    :raised_after_outside_content,
    :raised_history_tainted
  ]

  @timestamp_columns [:raised_at, :reply_at, :created_at, :updated_at]

  @select Enum.map_join(@columns, ", ", &"r.#{&1}")
  @insert_columns Enum.map_join(@columns, ", ", &Atom.to_string/1)
  @insert_placeholders Enum.map_join(@columns, ", ", fn _column -> "?" end)

  @id_pattern ~r/\Areaction_[A-Za-z0-9_-]{11}\z/
  @loop_id_pattern ~r/\Aloop_[A-Za-z0-9_-]{11}\z/
  @answers ~w(done plan not_yet stop drop moved reach)
  @text_max 240
  @newest "r.raised_at DESC, r.rowid DESC"

  # --- normalization (caller process) --------------------------------------

  @doc """
  Validates a raise into stored column values: who and which loop, the rung,
  when and in which conversation, the session that made it (rung 1), what
  Fermix said, if known yet, and whether it was raised after outside content,
  which every raise states.
  """
  @spec normalize_raise(map()) :: {:ok, map()} | {:error, term()}
  def normalize_raise(attrs) when is_map(attrs) do
    with {:ok, id} <- pattern(attrs, :id, @id_pattern),
         {:ok, scope} <- normalize_scope(attrs),
         {:ok, open_loop_id} <- pattern(attrs, :open_loop_id, @loop_id_pattern),
         {:ok, rung} <- rung(Map.get(attrs, :rung)),
         {:ok, raised_at} <- stamp(attrs, :raised_at),
         {:ok, session_id} <- optional_text(attrs, :session_id),
         {:ok, conversation} <- normalize_conversation(attrs),
         {:ok, raised_with} <- optional_chars(attrs, :raised_with, Defaults.raised_with_max()),
         {:ok, outside} <- boolean(attrs, :raised_after_outside_content) do
      {:ok,
       scope
       |> Map.merge(conversation)
       |> Map.merge(%{
         id: id,
         open_loop_id: open_loop_id,
         rung: rung,
         raised_at: raised_at,
         session_id: session_id,
         raised_with: raised_with,
         raised_after_outside_content: outside,
         raised_history_tainted: 0,
         reply_text: nil,
         reply_at: nil,
         outcome: nil,
         answer: nil,
         created_at: raised_at,
         updated_at: raised_at
       })}
    end
  end

  @doc """
  Validates the owner's message as the reply to the raises pending in its
  conversation: the scope, the conversation, the text (at most
  `Defaults.reply_text_max/0` characters), when it came, and the earliest
  raise it can still answer (`since`, the reply window's start).
  """
  @spec normalize_capture(map()) :: {:ok, map()} | {:error, term()}
  def normalize_capture(attrs) when is_map(attrs) do
    with {:ok, scope} <- normalize_scope(attrs),
         {:ok, conversation} <- normalize_conversation(attrs),
         {:ok, reply_text} <- chars(attrs, :reply_text, Defaults.reply_text_max()),
         {:ok, reply_at} <- stamp(attrs, :reply_at),
         {:ok, since} <- stamp(attrs, :since) do
      {:ok,
       scope
       |> Map.merge(conversation)
       |> Map.merge(%{reply_text: reply_text, reply_at: reply_at, since: since})}
    end
  end

  @doc """
  Validates what Fermix said in the turn that recorded a rung 1 raise: the
  scope, that turn's conversation, when it started, the text, and whether the
  reply it came from was stamped with the owner's computer activity.
  """
  @spec normalize_raised_with(map()) :: {:ok, map()} | {:error, term()}
  def normalize_raised_with(attrs) when is_map(attrs) do
    with {:ok, scope} <- normalize_scope(attrs),
         {:ok, conversation} <- normalize_conversation(attrs),
         {:ok, since} <- stamp(attrs, :since),
         {:ok, now} <- stamp(attrs, :now),
         {:ok, raised_with} <- chars(attrs, :raised_with, Defaults.raised_with_max()),
         {:ok, tainted} <- boolean(attrs, :raised_history_tainted) do
      {:ok,
       scope
       |> Map.merge(conversation)
       |> Map.merge(%{
         since: since,
         now: now,
         raised_with: raised_with,
         raised_history_tainted: tainted
       })}
    end
  end

  @doc """
  Validates the mark a turn that read outside content puts on the rung 1
  raises it recorded: the scope, that turn's conversation, when it started,
  and when it marks them.
  """
  @spec normalize_outside_content(map()) :: {:ok, map()} | {:error, term()}
  def normalize_outside_content(attrs) when is_map(attrs) do
    with {:ok, scope} <- normalize_scope(attrs),
         {:ok, conversation} <- normalize_conversation(attrs),
         {:ok, since} <- stamp(attrs, :since),
         {:ok, now} <- stamp(attrs, :now) do
      {:ok, scope |> Map.merge(conversation) |> Map.merge(%{since: since, now: now})}
    end
  end

  @doc "Validates an answer stamped on a loop's latest follow-up."
  @spec normalize_answer(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def normalize_answer(open_loop_id, answer) do
    with {:ok, _id} <- pattern(%{open_loop_id: open_loop_id}, :open_loop_id, @loop_id_pattern) do
      if answer in @answers, do: {:ok, answer}, else: {:error, {:invalid, :answer, :unsupported}}
    end
  end

  defp normalize_scope(attrs) do
    with {:ok, owner_id} <- text(attrs, :owner_id),
         {:ok, agent_id} <- text(attrs, :agent_id) do
      {:ok, %{owner_id: owner_id, agent_id: agent_id}}
    end
  end

  defp normalize_conversation(attrs) do
    with {:ok, channel} <- text(attrs, :source_channel),
         {:ok, chat_id} <- text(attrs, :source_chat_id),
         {:ok, scope} <- text(attrs, :source_thread_scope) do
      {:ok, %{source_channel: channel, source_chat_id: chat_id, source_thread_scope: scope}}
    end
  end

  defp pattern(attrs, key, regex) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        if Regex.match?(regex, value),
          do: {:ok, value},
          else: {:error, {:invalid, key, :malformed}}

      _other ->
        {:error, {:invalid, key, :malformed}}
    end
  end

  # Stored as SQLite's 0 or 1; never defaulted, so every raise says it.
  defp boolean(attrs, key) do
    case Map.get(attrs, key) do
      true -> {:ok, 1}
      false -> {:ok, 0}
      _other -> {:error, {:invalid, key, :not_a_boolean}}
    end
  end

  defp rung(rung) when rung in [1, 2], do: {:ok, rung}
  defp rung(_rung), do: {:error, {:invalid, :rung, :unsupported}}

  defp stamp(attrs, key) do
    case Map.get(attrs, key) do
      %DateTime{} = at -> {:ok, OpenLoopsSql.stamp!(at)}
      _other -> {:error, {:invalid, key, :not_a_datetime}}
    end
  end

  defp text(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" and byte_size(value) <= @text_max ->
        {:ok, value}

      value when is_binary(value) and value != "" ->
        {:error, {:invalid, key, :too_long}}

      _other ->
        {:error, {:invalid, key, :not_a_string}}
    end
  end

  defp optional_text(attrs, key) do
    case Map.get(attrs, key) do
      nil -> {:ok, nil}
      _value -> text(attrs, key)
    end
  end

  defp chars(attrs, key, max) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" ->
        if String.length(value) <= max,
          do: {:ok, value},
          else: {:error, {:invalid, key, :too_long}}

      _other ->
        {:error, {:invalid, key, :not_a_string}}
    end
  end

  defp optional_chars(attrs, key, max) do
    case Map.get(attrs, key) do
      nil -> {:ok, nil}
      _value -> chars(attrs, key, max)
    end
  end

  # --- writes --------------------------------------------------------------

  @doc """
  Inserts one raise and prunes the owner's record to the newest
  `Defaults.reactions_kept/0`, in one transaction.
  """
  @spec insert(term(), map()) :: {:ok, map()} | {:error, term()}
  def insert(conn, row) do
    OpenLoopsSql.in_transaction(conn, fn ->
      with :ok <- OpenLoopsSql.execute(conn, insert_sql(), Enum.map(@columns, &row[&1])),
           :ok <- prune(conn, row.owner_id) do
        fetch(conn, row.id)
      end
    end)
  end

  defp insert_sql,
    do: "INSERT INTO open_loop_reactions (#{@insert_columns}) VALUES (#{@insert_placeholders})"

  defp prune(conn, owner_id) do
    OpenLoopsSql.execute(
      conn,
      """
      DELETE FROM open_loop_reactions
      WHERE owner_id = ? AND id NOT IN (
        SELECT r.id FROM open_loop_reactions r WHERE r.owner_id = ?
        ORDER BY #{@newest} LIMIT ?
      )
      """,
      [owner_id, owner_id, Defaults.reactions_kept()]
    )
  end

  @doc """
  The owner's message as the reply to every raise still awaiting one in its
  conversation, raised within the window (`since`) and before the message.
  One statement; returns what it answered.
  """
  @spec capture(term(), map()) :: {:ok, [map()]} | {:error, term()}
  def capture(conn, capture) do
    conn
    |> OpenLoopsSql.query_all(
      """
      UPDATE open_loop_reactions
      SET reply_text = ?, reply_at = ?, outcome = 'replied', updated_at = ?
      WHERE owner_id = ? AND agent_id = ? AND source_channel = ? AND source_chat_id = ?
        AND source_thread_scope = ? AND outcome IS NULL AND raised_at >= ? AND raised_at < ?
      RETURNING id, open_loop_id, rung, raised_at, reply_at
      """,
      [
        capture.reply_text,
        capture.reply_at,
        capture.reply_at,
        capture.owner_id,
        capture.agent_id,
        capture.source_channel,
        capture.source_chat_id,
        capture.source_thread_scope,
        capture.since,
        capture.reply_at
      ]
    )
    |> answered_rows()
  end

  defp answered_rows({:ok, rows}) do
    {:ok,
     Enum.map(rows, fn [id, open_loop_id, rung, raised_at, reply_at] ->
       %{
         id: id,
         open_loop_id: open_loop_id,
         rung: rung,
         raised_at: parse!(raised_at),
         reply_at: parse!(reply_at)
       }
     end)}
  end

  defp answered_rows({:error, reason}), do: {:error, reason}

  @doc """
  Stores what Fermix said on the rung 1 raises still without it, raised in a
  turn's conversation since the turn started, with the reply's activity stamp.
  One statement; returns how many it wrote.
  """
  @spec raised_with(term(), map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def raised_with(conn, args) do
    with {:ok, rows} <-
           OpenLoopsSql.query_all(
             conn,
             """
             UPDATE open_loop_reactions
             SET raised_with = ?, raised_history_tainted = ?, updated_at = ?
             WHERE owner_id = ? AND agent_id = ? AND source_channel = ? AND source_chat_id = ?
               AND source_thread_scope = ? AND rung = 1 AND raised_with IS NULL
               AND raised_at >= ?
             RETURNING id
             """,
             [
               args.raised_with,
               args.raised_history_tainted,
               args.now,
               args.owner_id,
               args.agent_id,
               args.source_channel,
               args.source_chat_id,
               args.source_thread_scope,
               args.since
             ]
           ) do
      {:ok, length(rows)}
    end
  end

  @doc """
  Marks the rung 1 raises of a turn's conversation, raised since the turn
  started, as raised after outside content, once the turn is known to have
  read some: a raise recorded before the read was stated clean. The same
  conversation-scoped shape as `raised_with/2`. One statement; returns how many
  it marked.
  """
  @spec raised_after_outside_content(term(), map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def raised_after_outside_content(conn, args) do
    with {:ok, rows} <-
           OpenLoopsSql.query_all(
             conn,
             """
             UPDATE open_loop_reactions SET raised_after_outside_content = 1, updated_at = ?
             WHERE owner_id = ? AND agent_id = ? AND source_channel = ? AND source_chat_id = ?
               AND source_thread_scope = ? AND rung = 1 AND raised_after_outside_content = 0
               AND raised_at >= ?
             RETURNING id
             """,
             [
               args.now,
               args.owner_id,
               args.agent_id,
               args.source_channel,
               args.source_chat_id,
               args.source_thread_scope,
               args.since
             ]
           ) do
      {:ok, length(rows)}
    end
  end

  @doc """
  Marks every raise of the owner's still awaiting a reply and raised before
  `cutoff` (the reply window's start) as `no_reply`. Returns what it marked.
  """
  @spec stamp_no_reply(term(), String.t(), String.t(), String.t()) ::
          {:ok, [map()]} | {:error, term()}
  def stamp_no_reply(conn, owner_id, cutoff, now) do
    with {:ok, rows} <-
           OpenLoopsSql.query_all(
             conn,
             """
             UPDATE open_loop_reactions SET outcome = 'no_reply', updated_at = ?
             WHERE owner_id = ? AND outcome IS NULL AND raised_at < ?
             RETURNING id, open_loop_id, rung
             """,
             [now, owner_id, cutoff]
           ) do
      {:ok,
       Enum.map(rows, fn [id, open_loop_id, rung] ->
         %{id: id, open_loop_id: open_loop_id, rung: rung}
       end)}
    end
  end

  @doc """
  Stamps the answer of the settle that followed on a loop's latest follow-up,
  once: a follow-up that already carries one keeps it. Returns 0 or 1.
  """
  @spec answer(term(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, 0 | 1} | {:error, term()}
  def answer(conn, owner_id, open_loop_id, answer, now) do
    with {:ok, rows} <-
           OpenLoopsSql.query_all(
             conn,
             """
             UPDATE open_loop_reactions SET answer = ?, updated_at = ?
             WHERE answer IS NULL AND id = (
               SELECT r.id FROM open_loop_reactions r
               WHERE r.owner_id = ? AND r.open_loop_id = ?
               ORDER BY #{@newest} LIMIT 1
             )
             RETURNING id
             """,
             [answer, now, owner_id, open_loop_id]
           ) do
      {:ok, length(rows)}
    end
  end

  @doc "Deletes every follow-up of one loop. Returns how many it deleted."
  @spec delete_for_loop(term(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def delete_for_loop(conn, owner_id, open_loop_id) do
    with {:ok, rows} <-
           OpenLoopsSql.query_all(
             conn,
             "DELETE FROM open_loop_reactions WHERE owner_id = ? AND open_loop_id = ? RETURNING id",
             [owner_id, open_loop_id]
           ) do
      {:ok, length(rows)}
    end
  end

  # --- reads ---------------------------------------------------------------

  @doc """
  The owner's whole record, newest first, each row with its loop's
  `intention` and `noted_after_outside_content`, so the words are framed
  wherever they come back: at most `Defaults.reactions_kept/0` rows, the bound
  an insert holds.
  """
  @spec list(term(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list(conn, owner_id) do
    with {:ok, rows} <-
           OpenLoopsSql.query_all(
             conn,
             """
             SELECT #{@select}, l.intention, l.noted_after_outside_content
             FROM open_loop_reactions r
             JOIN open_loops l ON l.id = r.open_loop_id
             WHERE r.owner_id = ?
             ORDER BY #{@newest} LIMIT ?
             """,
             [owner_id, Defaults.reactions_kept()]
           ) do
      {:ok, Enum.map(rows, &decode_with_intention/1)}
    end
  end

  defp fetch(conn, id) do
    with {:ok, rows} <-
           OpenLoopsSql.query_all(
             conn,
             "SELECT #{@select} FROM open_loop_reactions r WHERE r.id = ?",
             [id]
           ) do
      case rows do
        [values] -> {:ok, decode(values)}
        [] -> {:error, :not_found}
      end
    end
  end

  # --- row mapping ---------------------------------------------------------

  defp decode_with_intention(values) do
    {row, [intention, outside]} = Enum.split(values, length(@columns))

    row
    |> decode()
    |> Map.merge(%{intention: intention, noted_after_outside_content: outside == 1})
  end

  defp decode(values) do
    raw = @columns |> Enum.zip(values) |> Map.new()

    @timestamp_columns
    |> Enum.reduce(raw, fn column, row -> Map.update!(row, column, &parse_optional/1) end)
    |> Map.update!(:raised_after_outside_content, &(&1 == 1))
    |> Map.update!(:raised_history_tainted, &(&1 == 1))
  end

  defp parse_optional(nil), do: nil
  defp parse_optional(value), do: parse!(value)

  defp parse!(value) do
    {:ok, at, _offset} = DateTime.from_iso8601(value)
    at
  end
end
