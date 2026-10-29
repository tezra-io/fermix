defmodule FermixCore.Memory.Repo.OpenLoopsSql do
  @moduledoc false
  # Private SQL for `FermixCore.Memory.Repo`'s open-loop operations
  # (MILESTONE_78 §06, §18; MILESTONE_83 §11). Every function that takes a
  # `conn` is invoked only from Repo's `handle_call`s, so the single-writer
  # architecture is unchanged.
  #
  # The `matters_by_*` columns are the loop's anchor (M83 §11): the date it
  # matters by for something to do (`anchor_kind` `matters_by`), or the instant
  # asking first feels natural for something waited on or gone through
  # (`ask_after`, horizon class `after`). `rung1_until` is the close of a due
  # loop's rung 1 window, written when the scan marks it due and cleared by
  # every write that moves it out of due.
  #
  # Normalization (`normalize_*`) runs in the *caller* process, before the
  # GenServer call, so a bad value fails at the boundary with a clear error
  # instead of inside the single writer. Rows are selected by column name and
  # decoded by name: a positional read is the known hazard.
  #
  # What a CHECK cannot say, the WHERE clauses here say: every UPDATE that moves
  # `state` carries `state IN ('open', 'due', 'asked')`, so a closed or expired
  # row is unreachable by any write path and a terminal state never reopens.

  require Logger

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo.TemporalSql
  alias FermixCore.OpenLoops.Defaults
  alias FermixCore.OpenLoops.Lifecycle

  @columns [
    :id,
    :agent_id,
    :owner_id,
    :dedupe_key,
    :intention,
    :why_it_matters,
    :matters_by_kind,
    :matters_by_date,
    :matters_by_time,
    :matters_by_at,
    :anchor_kind,
    :matters_by_source,
    :reach,
    :timezone,
    :horizon_class,
    :said_at,
    :source_channel,
    :source_chat_id,
    :source_thread_scope,
    :state,
    :touches,
    :next_touch_at,
    :rung1_until,
    :claimed_at,
    :last_touch_at,
    :last_touch_rung,
    :last_rung2_at,
    :last_answer,
    :plan_at,
    :last_outcome,
    :last_outcome_at,
    :last_message,
    :delivery_platform,
    :delivery_destination,
    :delivery_thread_scope,
    :closed_at,
    :close_reason,
    :revision,
    :created_at,
    :updated_at,
    :noted_after_outside_content,
    :last_message_after_outside_content
  ]

  @timestamp_columns [
    :matters_by_at,
    :said_at,
    :next_touch_at,
    :rung1_until,
    :claimed_at,
    :last_touch_at,
    :last_rung2_at,
    :plan_at,
    :last_outcome_at,
    :closed_at,
    :created_at,
    :updated_at
  ]

  @states ~w(open due asked closed expired)
  @live_sql "('open', 'due', 'asked')"
  @matters_by_kinds ~w(date datetime)
  @anchor_kinds ~w(matters_by ask_after)
  @sources ~w(owner lookup)
  @reaches Defaults.reaches()
  @horizon_classes ~w(long medium short imminent after)
  @answers ~w(done plan not_yet stop drop moved)
  @outcomes ~w(spoke silent later closed empty delivery_failed timeout error)
  @close_reasons ~w(done stop dropped reported_elsewhere expired)
  @list_states ~w(live closed any)
  @empty_scan %{due: [], expired: [], skipped_to_handback: [], waiting: [], expired_from: %{}}

  # Columns a settle or a check-in's finalising write may set. Identity,
  # provenance, the anchor's kind, the delivery snapshot, the claim and the
  # bookkeeping are owned here, never by a caller's changes. `last_rung2_at`
  # may only be cleared (`change_value/2`): the spend before a send is its one
  # stamp. A dated loop's date moves only whole (`@moved_columns`, a `moved`
  # answer), `rung1_until` is cleared by any write that leaves due, and
  # `last_message` moves only with `last_message_after_outside_content`, what
  # the run that wrote it had read.
  @moved_columns [
    :matters_by_kind,
    :matters_by_date,
    :matters_by_time,
    :matters_by_at,
    :matters_by_source,
    :horizon_class
  ]

  @settle_columns @moved_columns ++
                    [
                      :reach,
                      :rung1_until,
                      :state,
                      :touches,
                      :next_touch_at,
                      :last_touch_at,
                      :last_touch_rung,
                      :last_rung2_at,
                      :last_answer,
                      :plan_at,
                      :last_outcome,
                      :last_outcome_at,
                      :last_message,
                      :last_message_after_outside_content,
                      :closed_at,
                      :close_reason
                    ]

  @id_pattern ~r/\Aloop_[A-Za-z0-9_-]{11}\z/
  @text_max 240
  @live_list_max 100
  @scan_max 500
  # The newest owner messages one active-hours read considers. 28 days of an
  # ordinary owner's messages sit far below it; a bound keeps one resolve from
  # reading an unbounded history.
  @message_hours_max 10_000

  @select Enum.map_join(@columns, ", ", &Atom.to_string/1)
  @insert_placeholders Enum.map_join(@columns, ", ", fn _column -> "?" end)

  @schema_sql """
  CREATE TABLE IF NOT EXISTS open_loops (
    id TEXT PRIMARY KEY,                           -- "loop_" + 11 url-safe chars
    agent_id TEXT NOT NULL DEFAULT 'main',
    owner_id TEXT NOT NULL DEFAULT 'default',
    dedupe_key TEXT NOT NULL,                      -- normalised intention: lowercased, punctuation
                                                   -- stripped, whitespace collapsed
    intention TEXT NOT NULL,
    why_it_matters TEXT,
    matters_by_kind TEXT NOT NULL CHECK (matters_by_kind IN ('date', 'datetime')),
    matters_by_date TEXT NOT NULL,                 -- local YYYY-MM-DD
    matters_by_time TEXT,                          -- local HH:MM:SS, datetime only
    matters_by_at TEXT NOT NULL,                   -- UTC instant the date has passed: the datetime
                                                   -- itself, or the start of the next local day
    timezone TEXT NOT NULL,                        -- IANA zone the dates were resolved in
    horizon_class TEXT NOT NULL CHECK (
      horizon_class IN ('long', 'medium', 'short', 'imminent')
    ),                                             -- fixed at capture; picks the slot table
    said_at TEXT NOT NULL,
    source_channel TEXT NOT NULL,
    source_chat_id TEXT NOT NULL,
    source_thread_scope TEXT NOT NULL DEFAULT 'root',
    state TEXT NOT NULL DEFAULT 'open' CHECK (
      state IN ('open', 'due', 'asked', 'closed', 'expired')
    ),
    touches INTEGER NOT NULL DEFAULT 0 CHECK (touches BETWEEN 0 AND 3),
    next_touch_at TEXT,                            -- the slot now pending; NULL only once terminal
    claimed_at TEXT,                               -- set while a check-in run holds the row
    last_touch_at TEXT,
    last_touch_rung INTEGER CHECK (last_touch_rung IS NULL OR last_touch_rung IN (1, 2)),
    last_rung2_at TEXT,                            -- the owner's daily rung 2 budget, spent by a
                                                   -- check-in's run just before its one send
    last_answer TEXT CHECK (
      last_answer IS NULL OR last_answer IN ('done', 'plan', 'not_yet', 'stop', 'drop')
    ),
    plan_at TEXT,                                  -- UTC instant of the plan the owner named
    last_outcome TEXT CHECK (
      last_outcome IS NULL OR last_outcome IN
        ('spoke', 'silent', 'closed', 'empty', 'delivery_failed', 'timeout', 'error')
    ),                                             -- the last check-in run's decision, sent or not
    last_outcome_at TEXT,
    last_message TEXT,                             -- the text the last run decided to speak
    delivery_platform TEXT NOT NULL,
    delivery_destination TEXT NOT NULL,
    delivery_thread_scope TEXT NOT NULL DEFAULT 'root',
    closed_at TEXT,
    close_reason TEXT CHECK (
      close_reason IS NULL OR close_reason IN
        ('done', 'stop', 'dropped', 'reported_elsewhere', 'expired')
    ),
    revision INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    CHECK ((state IN ('closed', 'expired')) = (closed_at IS NOT NULL)),
    CHECK ((state IN ('closed', 'expired')) = (close_reason IS NOT NULL)),
    CHECK (state != 'expired' OR close_reason = 'expired'),
    CHECK (state != 'closed' OR close_reason != 'expired'),
    CHECK (state IN ('closed', 'expired') OR next_touch_at IS NOT NULL),
    CHECK (claimed_at IS NULL OR state = 'due'),
    CHECK (last_answer IS NULL OR last_answer != 'plan' OR plan_at IS NOT NULL),
    CHECK (last_outcome IS NULL OR last_outcome != 'spoke' OR last_message IS NOT NULL)
  );
  CREATE INDEX IF NOT EXISTS idx_open_loops_due
    ON open_loops(state, next_touch_at);
  CREATE UNIQUE INDEX IF NOT EXISTS idx_open_loops_live_dedupe
    ON open_loops(owner_id, dedupe_key)
    WHERE state IN ('open', 'due', 'asked');
  CREATE INDEX IF NOT EXISTS idx_open_loops_rung2_day
    ON open_loops(owner_id, last_rung2_at);
  """

  @doc "Schema for migration 43 (§18)."
  @spec schema_sql() :: String.t()
  def schema_sql, do: @schema_sql

  @doc """
  The DDL of migration 49 (§08): `noted_after_outside_content`, 1 when the loop
  is known to have been noted on a turn that had read content someone else
  could have written, so its words are framed wherever they come back. Every
  write states it. A row written before the column is 0: it is not known to
  have been, and it keeps coming back as the owner's words, as it always has.
  """
  @spec outside_content_schema_sql() :: String.t()
  def outside_content_schema_sql do
    "ALTER TABLE open_loops ADD COLUMN noted_after_outside_content INTEGER NOT NULL " <>
      "DEFAULT 0 CHECK (noted_after_outside_content IN (0, 1));"
  end

  # Migration 51 (M83 §11). SQLite cannot widen a CHECK in place, so the table
  # is rebuilt in the copy-then-swap pattern migrations 11 and 47 use: a new
  # table with the wider vocabulary and the four new columns, every row copied
  # as a dated loop raised by message with a date the owner gave, its
  # `noted_after_outside_content` stamp (migration 49, which always runs first)
  # copied as it is, the old table dropped, the new one renamed, and every index
  # recreated. A row already due keeps today's window: three hours from its
  # touch, or an imminent loop's date. Its `last_message_after_outside_content`,
  # new here, is 0: what the run that wrote its last message had read was never
  # recorded, so it is not known to have been outside content, as a loop from
  # before 49 is not known to have been noted after it. No table references
  # open_loops, so foreign keys need not be lifted.
  #
  # The same migration creates open_loop_reactions, one row per follow-up and
  # the owner's next message, each marked when it was raised after outside
  # content, as a loop is when noted after it. It has no foreign key: M78 keeps
  # none to messages, which compaction deletes, and one to open_loops would make
  # every later rebuild of that table, this one's pattern, lift foreign keys
  # around it. A drop deletes a loop's reactions explicitly.
  @rung1_window_seconds div(Defaults.rung1_window_ms(), 1_000)
  @columns_43 "id, agent_id, owner_id, dedupe_key, intention, why_it_matters, " <>
                "matters_by_kind, matters_by_date, matters_by_time, matters_by_at, timezone, " <>
                "horizon_class, said_at, source_channel, source_chat_id, source_thread_scope, " <>
                "state, touches, next_touch_at, claimed_at, last_touch_at, last_touch_rung, " <>
                "last_rung2_at, last_answer, plan_at, last_outcome, last_outcome_at, " <>
                "last_message, delivery_platform, delivery_destination, " <>
                "delivery_thread_scope, closed_at, close_reason, revision, created_at, updated_at"
  @columns_49 @columns_43 <> ", noted_after_outside_content"

  @curiosity_schema_sql """
  CREATE TABLE open_loops_51 (
    id TEXT PRIMARY KEY,                           -- "loop_" + 11 url-safe chars
    agent_id TEXT NOT NULL DEFAULT 'main',
    owner_id TEXT NOT NULL DEFAULT 'default',
    dedupe_key TEXT NOT NULL,                      -- normalised intention: lowercased, punctuation
                                                   -- stripped, whitespace collapsed
    intention TEXT NOT NULL,
    why_it_matters TEXT,
    matters_by_kind TEXT NOT NULL CHECK (matters_by_kind IN ('date', 'datetime')),
    matters_by_date TEXT NOT NULL,                 -- local YYYY-MM-DD
    matters_by_time TEXT,                          -- local HH:MM:SS, datetime only
    matters_by_at TEXT NOT NULL,                   -- the anchor, a UTC instant: the instant the
                                                   -- date has passed, or the ask_after instant
    timezone TEXT NOT NULL,                        -- IANA zone the dates were resolved in
    horizon_class TEXT NOT NULL CHECK (
      horizon_class IN ('long', 'medium', 'short', 'imminent', 'after')
    ),                                             -- fixed at capture or by a moved answer
    said_at TEXT NOT NULL,
    source_channel TEXT NOT NULL,
    source_chat_id TEXT NOT NULL,
    source_thread_scope TEXT NOT NULL DEFAULT 'root',
    state TEXT NOT NULL DEFAULT 'open' CHECK (
      state IN ('open', 'due', 'asked', 'closed', 'expired')
    ),
    touches INTEGER NOT NULL DEFAULT 0 CHECK (touches BETWEEN 0 AND 3),
    next_touch_at TEXT,                            -- the slot now pending; NULL only once terminal
    claimed_at TEXT,                               -- set while a check-in run holds the row
    last_touch_at TEXT,
    last_touch_rung INTEGER CHECK (last_touch_rung IS NULL OR last_touch_rung IN (1, 2)),
    last_rung2_at TEXT,                            -- the owner's daily rung 2 budget, spent by a
                                                   -- check-in's run just before its one send
    last_answer TEXT CHECK (
      last_answer IS NULL OR last_answer IN ('done', 'plan', 'not_yet', 'stop', 'drop', 'moved')
    ),
    plan_at TEXT,                                  -- UTC instant of the plan the owner named
    last_outcome TEXT CHECK (
      last_outcome IS NULL OR last_outcome IN
        ('spoke', 'silent', 'later', 'closed', 'empty', 'delivery_failed', 'timeout',
         'error')
    ),                                             -- the last check-in run's decision, sent or not
    last_outcome_at TEXT,
    last_message TEXT,                             -- the text the last run decided to speak
    delivery_platform TEXT NOT NULL,
    delivery_destination TEXT NOT NULL,
    delivery_thread_scope TEXT NOT NULL DEFAULT 'root',
    closed_at TEXT,
    close_reason TEXT CHECK (
      close_reason IS NULL OR close_reason IN
        ('done', 'stop', 'dropped', 'reported_elsewhere', 'expired')
    ),
    revision INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    noted_after_outside_content INTEGER NOT NULL DEFAULT 0 CHECK (
      noted_after_outside_content IN (0, 1)
    ),                                             -- noted on a turn that had read outside
                                                   -- content (migration 49); 0 when not known
    anchor_kind TEXT NOT NULL DEFAULT 'matters_by' CHECK (
      anchor_kind IN ('matters_by', 'ask_after')
    ),                                             -- something to do by a date, or something
                                                   -- waited on or gone through
    matters_by_source TEXT CHECK (
      matters_by_source IS NULL OR matters_by_source IN ('owner', 'lookup')
    ),                                             -- who gave a dated loop's date; NULL for after
    reach TEXT NOT NULL DEFAULT 'message' CHECK (reach IN ('conversation', 'message')),
    rung1_until TEXT,                              -- a due loop's rung 1 window close; NULL unless due
    last_message_after_outside_content INTEGER NOT NULL DEFAULT 0 CHECK (
      last_message_after_outside_content IN (0, 1)
    ),                                             -- last_message written by a check-in run that
                                                   -- had read outside content; 0 when not known
    CHECK ((state IN ('closed', 'expired')) = (closed_at IS NOT NULL)),
    CHECK ((state IN ('closed', 'expired')) = (close_reason IS NOT NULL)),
    CHECK (state != 'expired' OR close_reason = 'expired'),
    CHECK (state != 'closed' OR close_reason != 'expired'),
    CHECK (state IN ('closed', 'expired') OR next_touch_at IS NOT NULL),
    CHECK (claimed_at IS NULL OR state = 'due'),
    CHECK (last_answer IS NULL OR last_answer != 'plan' OR plan_at IS NOT NULL),
    CHECK (last_outcome IS NULL OR last_outcome != 'spoke' OR last_message IS NOT NULL),
    CHECK ((horizon_class = 'after') = (anchor_kind = 'ask_after')),
    CHECK ((anchor_kind = 'ask_after') = (matters_by_source IS NULL)),
    CHECK ((state = 'due') = (rung1_until IS NOT NULL))
  );
  INSERT INTO open_loops_51 (#{@columns_49}, anchor_kind, matters_by_source, reach, rung1_until,
                             last_message_after_outside_content)
    SELECT #{@columns_49}, 'matters_by', 'owner', 'message',
           CASE
             WHEN state != 'due' THEN NULL
             WHEN horizon_class = 'imminent' THEN matters_by_at
             ELSE strftime('%Y-%m-%dT%H:%M:%S', next_touch_at, '+#{@rung1_window_seconds} seconds')
                  || substr(next_touch_at, 20)
           END,
           0
    FROM open_loops;
  DROP TABLE open_loops;
  ALTER TABLE open_loops_51 RENAME TO open_loops;
  CREATE INDEX idx_open_loops_due ON open_loops(state, next_touch_at);
  CREATE UNIQUE INDEX idx_open_loops_live_dedupe
    ON open_loops(owner_id, dedupe_key)
    WHERE state IN ('open', 'due', 'asked');
  CREATE INDEX idx_open_loops_rung2_day ON open_loops(owner_id, last_rung2_at);

  CREATE TABLE open_loop_reactions (
    id TEXT PRIMARY KEY,                           -- "reaction_" + 11 url-safe chars
    owner_id TEXT NOT NULL,
    agent_id TEXT NOT NULL,
    open_loop_id TEXT NOT NULL,
    rung INTEGER NOT NULL CHECK (rung IN (1, 2)),
    raised_at TEXT NOT NULL,
    session_id TEXT,
    source_channel TEXT NOT NULL,
    source_chat_id TEXT NOT NULL,
    source_thread_scope TEXT NOT NULL DEFAULT 'root',
    raised_with TEXT,                              -- what Fermix said, at most 280 characters
    reply_text TEXT,                               -- the owner's next message, at most 280
    reply_at TEXT,
    outcome TEXT CHECK (outcome IS NULL OR outcome IN ('replied', 'no_reply')),
    answer TEXT CHECK (
      answer IS NULL OR answer IN ('done', 'plan', 'not_yet', 'stop', 'drop', 'moved', 'reach')
    ),                                             -- the settle that followed, if any
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    raised_after_outside_content INTEGER NOT NULL DEFAULT 0 CHECK (
      raised_after_outside_content IN (0, 1)
    ),                                             -- raised on a turn or check-in run that had
                                                   -- read outside content; 0 when not known
    raised_history_tainted INTEGER NOT NULL DEFAULT 0 CHECK (
      raised_history_tainted IN (0, 1)
    )                                              -- raised_with is from a reply stamped with
                                                   -- the owner's computer activity (M32 §13.6)
  );
  CREATE INDEX idx_open_loop_reactions_raised
    ON open_loop_reactions(owner_id, agent_id, raised_at);
  CREATE INDEX idx_open_loop_reactions_conversation
    ON open_loop_reactions(owner_id, agent_id, source_channel, source_chat_id,
                           source_thread_scope, outcome);
  """

  @doc """
  Schema for migration 51 (M83 §11): `open_loops` rebuilt with the anchor's
  kind, the reach, the date's source, the rung 1 window, the wider
  vocabularies and `last_message_after_outside_content`, which marks a last
  message written by a check-in run that had read outside content, keeping
  migration 49's `noted_after_outside_content`; and the `open_loop_reactions`
  table, whose `raised_after_outside_content` marks a follow-up raised after
  outside content and whose `raised_history_tainted` marks words from a reply
  stamped with the owner's computer activity.
  """
  @spec curiosity_schema_sql() :: String.t()
  def curiosity_schema_sql, do: @curiosity_schema_sql

  # --- normalization (caller process) --------------------------------------

  @doc """
  Validates a new loop's attributes into stored column values. `anchor_kind`
  defaults to `matters_by` and `reach` to `message`, as their columns do; a
  dated loop's `matters_by_source` defaults to `owner`, and an `ask_after`
  loop has none.
  """
  @spec normalize_create(map()) :: {:ok, map()} | {:error, term()}
  def normalize_create(attrs) when is_map(attrs) do
    with {:ok, identity} <- normalize_identity(attrs),
         {:ok, date} <- normalize_date(attrs),
         {:ok, anchor} <- normalize_anchor(attrs, date.horizon_class),
         {:ok, provenance} <- normalize_provenance(attrs),
         {:ok, stamps} <- normalize_create_stamps(attrs) do
      {:ok,
       identity
       |> Map.merge(date)
       |> Map.merge(anchor)
       |> Map.merge(provenance)
       |> Map.merge(stamps)
       |> Map.merge(initial_ledger())}
    end
  end

  defp normalize_identity(attrs) do
    with {:ok, id} <- loop_id(Map.get(attrs, :id)),
         {:ok, dedupe_key} <- text(attrs, :dedupe_key, 1, Defaults.dedupe_key_max()),
         {:ok, intention} <- text(attrs, :intention, 1, Defaults.intention_max()),
         {:ok, outside?} <- boolean(attrs, :noted_after_outside_content),
         {:ok, why} <- optional_text(attrs, :why_it_matters, Defaults.why_it_matters_max()),
         {:ok, agent_id} <- text(Map.put_new(attrs, :agent_id, "main"), :agent_id, 1, @text_max),
         {:ok, owner_id} <-
           text(Map.put_new(attrs, :owner_id, "default"), :owner_id, 1, @text_max) do
      {:ok,
       %{
         id: id,
         agent_id: agent_id,
         owner_id: owner_id,
         dedupe_key: dedupe_key,
         intention: intention,
         noted_after_outside_content: outside?,
         why_it_matters: why
       }}
    end
  end

  defp normalize_date(attrs) do
    with {:ok, kind} <- enum(attrs, :matters_by_kind, @matters_by_kinds),
         {:ok, date} <- date(attrs, :matters_by_date),
         {:ok, time} <- matters_by_time(kind, Map.get(attrs, :matters_by_time)),
         {:ok, at} <- stamp(Map.get(attrs, :matters_by_at), :matters_by_at),
         {:ok, timezone} <- text(attrs, :timezone, 1, @text_max),
         {:ok, class} <- enum(attrs, :horizon_class, @horizon_classes) do
      {:ok,
       %{
         matters_by_kind: kind,
         matters_by_date: date,
         matters_by_time: time,
         matters_by_at: at,
         timezone: timezone,
         horizon_class: class
       }}
    end
  end

  # The anchor's kind fixes the class family and whether a source exists: an
  # `ask_after` loop is class `after` and has no source, a dated loop has a
  # dated class and one.
  defp normalize_anchor(attrs, class) do
    attrs = Map.put_new(attrs, :anchor_kind, "matters_by")

    with {:ok, kind} <- enum(attrs, :anchor_kind, @anchor_kinds),
         :ok <- class_fits(kind, class),
         {:ok, source} <- anchor_source(kind, Map.get(attrs, :matters_by_source, :unset)),
         {:ok, reach} <- enum(Map.put_new(attrs, :reach, "message"), :reach, @reaches) do
      {:ok, %{anchor_kind: kind, matters_by_source: source, reach: reach}}
    end
  end

  defp class_fits("ask_after", "after"), do: :ok
  defp class_fits("matters_by", class) when class != "after", do: :ok
  defp class_fits(_kind, _class), do: {:error, {:invalid, :horizon_class, :anchor_mismatch}}

  defp anchor_source("ask_after", source) when source in [nil, :unset], do: {:ok, nil}

  defp anchor_source("ask_after", _source),
    do: {:error, {:invalid, :matters_by_source, :ask_after}}

  defp anchor_source("matters_by", :unset), do: {:ok, "owner"}
  defp anchor_source("matters_by", source), do: member(source, :matters_by_source, @sources)

  defp normalize_provenance(attrs) do
    with {:ok, channel} <- text(attrs, :source_channel, 1, @text_max),
         {:ok, chat_id} <- text(attrs, :source_chat_id, 1, @text_max),
         {:ok, source_scope} <- scope(attrs, :source_thread_scope),
         {:ok, platform} <- text(attrs, :delivery_platform, 1, @text_max),
         {:ok, destination} <- text(attrs, :delivery_destination, 1, @text_max),
         {:ok, delivery_scope} <- scope(attrs, :delivery_thread_scope) do
      {:ok,
       %{
         source_channel: channel,
         source_chat_id: chat_id,
         source_thread_scope: source_scope,
         delivery_platform: platform,
         delivery_destination: destination,
         delivery_thread_scope: delivery_scope
       }}
    end
  end

  defp normalize_create_stamps(attrs) do
    with {:ok, said_at} <- stamp(Map.get(attrs, :said_at), :said_at),
         {:ok, next} <- stamp(Map.get(attrs, :next_touch_at), :next_touch_at),
         {:ok, created_at} <- stamp(Map.get(attrs, :created_at), :created_at) do
      {:ok,
       %{said_at: said_at, next_touch_at: next, created_at: created_at, updated_at: created_at}}
    end
  end

  defp initial_ledger do
    %{
      state: "open",
      touches: 0,
      rung1_until: nil,
      claimed_at: nil,
      last_touch_at: nil,
      last_touch_rung: nil,
      last_rung2_at: nil,
      last_answer: nil,
      plan_at: nil,
      last_outcome: nil,
      last_outcome_at: nil,
      last_message: nil,
      last_message_after_outside_content: 0,
      closed_at: nil,
      close_reason: nil,
      revision: 1
    }
  end

  @doc """
  Validates a settle's or a finalising write's column changes. Unknown columns
  are refused; the claim, revision and `updated_at` are set by the write itself.
  A dated loop's date moves only whole, a last message only with whether its
  run had read outside content, and a write that moves the loop out of due
  clears its rung 1 window.
  """
  @spec normalize_changes(map()) :: {:ok, map()} | {:error, term()}
  def normalize_changes(changes) when is_map(changes) and map_size(changes) > 0 do
    with nil <- Enum.find(Map.keys(changes), &(&1 not in @settle_columns)),
         :ok <- moved_whole(changes),
         {:ok, values} <- normalize_change_values(changes),
         :ok <- message_with_provenance(changes),
         {:ok, time} <- moved_time(changes) do
      {:ok, values |> Map.merge(time) |> window_cleared()}
    else
      key when is_atom(key) -> {:error, {:unknown_field, key}}
      {:error, reason} -> {:error, reason}
    end
  end

  def normalize_changes(_changes), do: {:error, :empty_changes}

  defp moved_whole(changes) do
    case Enum.filter(@moved_columns, &Map.has_key?(changes, &1)) do
      [] -> :ok
      @moved_columns -> :ok
      _partial -> {:error, {:invalid, :matters_by, :partial_move}}
    end
  end

  # A message and what its run had read are written together, so a later message
  # never inherits an earlier one's stamp, nor goes out without its own.
  defp message_with_provenance(changes) do
    if Map.has_key?(changes, :last_message) ==
         Map.has_key?(changes, :last_message_after_outside_content),
       do: :ok,
       else: {:error, {:invalid, :last_message_after_outside_content, :apart_from_message}}
  end

  # The date's time follows its kind, as at capture.
  defp moved_time(%{matters_by_kind: kind} = changes),
    do:
      with(
        {:ok, time} <- matters_by_time(kind, changes.matters_by_time),
        do: {:ok, %{matters_by_time: time}}
      )

  defp moved_time(_changes), do: {:ok, %{}}

  defp window_cleared(%{state: state} = changes) when state != "due",
    do: Map.put(changes, :rung1_until, nil)

  defp window_cleared(changes), do: changes

  defp normalize_change_values(changes) do
    Enum.reduce_while(changes, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case change_value(key, value) do
        {:ok, stored} -> {:cont, {:ok, Map.put(acc, key, stored)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp change_value(:state, value), do: member(value, :state, @states)
  defp change_value(:reach, value), do: member(value, :reach, @reaches)

  defp change_value(:matters_by_kind, value),
    do: member(value, :matters_by_kind, @matters_by_kinds)

  defp change_value(:matters_by_date, value),
    do: date(%{matters_by_date: value}, :matters_by_date)

  # Validated with its kind by `moved_time/1`.
  defp change_value(:matters_by_time, value), do: {:ok, value}
  defp change_value(:matters_by_source, value), do: member(value, :matters_by_source, @sources)

  defp change_value(:horizon_class, value) when value != "after",
    do: member(value, :horizon_class, @horizon_classes)

  defp change_value(:horizon_class, _value),
    do: {:error, {:invalid, :horizon_class, :anchor_mismatch}}

  defp change_value(:touches, value) when value in 0..3, do: {:ok, value}
  defp change_value(:touches, _value), do: {:error, {:invalid, :touches, :out_of_range}}
  defp change_value(:last_touch_rung, value) when value in [nil, 1, 2], do: {:ok, value}

  defp change_value(:last_touch_rung, _value),
    do: {:error, {:invalid, :last_touch_rung, :unsupported}}

  defp change_value(:last_rung2_at, nil), do: {:ok, nil}

  defp change_value(:last_rung2_at, _value),
    do: {:error, {:invalid, :last_rung2_at, :unsupported}}

  defp change_value(:last_answer, value), do: optional_member(value, :last_answer, @answers)
  defp change_value(:last_outcome, value), do: optional_member(value, :last_outcome, @outcomes)

  defp change_value(:close_reason, value),
    do: optional_member(value, :close_reason, @close_reasons)

  defp change_value(:last_message, value),
    do: optional_bounded(value, :last_message, Defaults.message_max_bytes())

  defp change_value(:last_message_after_outside_content, value),
    do: boolean(%{last_message_after_outside_content: value}, :last_message_after_outside_content)

  defp change_value(key, nil) when key in @timestamp_columns, do: {:ok, nil}
  defp change_value(key, value) when key in @timestamp_columns, do: stamp(value, key)

  @doc "Validates a listing filter."
  @spec normalize_filter(map()) :: {:ok, map()} | {:error, term()}
  def normalize_filter(filter) when is_map(filter) do
    with {:ok, owner_id} <- text(filter, :owner_id, 1, @text_max),
         {:ok, state} <- member(Map.get(filter, :state, "live"), :state, @list_states) do
      {:ok, %{owner_id: owner_id, state: state}}
    end
  end

  @doc "Serializes an instant to the fixed-width UTC form stored in every column."
  @spec stamp!(DateTime.t()) :: String.t()
  def stamp!(%DateTime{} = at) do
    {:ok, value} = TemporalSql.timestamp(at)
    value
  end

  defp stamp(%DateTime{} = at, _key), do: TemporalSql.timestamp(at)
  defp stamp(_value, key), do: {:error, {:invalid, key, :not_a_datetime}}

  defp loop_id(id) when is_binary(id) do
    if Regex.match?(@id_pattern, id), do: {:ok, id}, else: {:error, {:invalid, :id, :malformed}}
  end

  defp loop_id(_id), do: {:error, {:invalid, :id, :malformed}}

  defp text(attrs, key, min_bytes, max_bytes) do
    case Map.get(attrs, key) do
      value when is_binary(value) and byte_size(value) < min_bytes ->
        {:error, {:invalid, key, :empty}}

      value when is_binary(value) and byte_size(value) > max_bytes ->
        {:error, {:invalid, key, :too_long}}

      value when is_binary(value) ->
        {:ok, value}

      _other ->
        {:error, {:invalid, key, :not_a_string}}
    end
  end

  defp optional_text(attrs, key, max_bytes),
    do: optional_bounded(Map.get(attrs, key), key, max_bytes)

  # Stored as SQLite's 0 or 1; never defaulted, so every write says it.
  defp boolean(attrs, key) do
    case Map.get(attrs, key) do
      true -> {:ok, 1}
      false -> {:ok, 0}
      _other -> {:error, {:invalid, key, :not_a_boolean}}
    end
  end

  defp optional_bounded(nil, _key, _max_bytes), do: {:ok, nil}

  defp optional_bounded(value, key, max_bytes) when is_binary(value) do
    if byte_size(value) > max_bytes, do: {:error, {:invalid, key, :too_long}}, else: {:ok, value}
  end

  defp optional_bounded(_value, key, _max_bytes), do: {:error, {:invalid, key, :not_a_string}}

  defp scope(attrs, key), do: text(Map.put_new(attrs, key, "root"), key, 1, @text_max)

  defp enum(attrs, key, allowed), do: member(Map.get(attrs, key), key, allowed)

  defp member(value, key, allowed) do
    if value in allowed, do: {:ok, value}, else: {:error, {:invalid, key, :unsupported}}
  end

  defp optional_member(nil, _key, _allowed), do: {:ok, nil}
  defp optional_member(value, key, allowed), do: member(value, key, allowed)

  defp date(attrs, key) do
    case Map.get(attrs, key) do
      %Date{} = date -> {:ok, Date.to_iso8601(date)}
      _other -> {:error, {:invalid, key, :not_a_date}}
    end
  end

  defp matters_by_time("date", nil), do: {:ok, nil}
  defp matters_by_time("date", _time), do: {:error, {:invalid, :matters_by_time, :date_only}}

  defp matters_by_time("datetime", %Time{} = time),
    do: {:ok, time |> Time.truncate(:second) |> Time.to_iso8601()}

  defp matters_by_time("datetime", _time), do: {:error, {:invalid, :matters_by_time, :required}}

  # --- writes --------------------------------------------------------------

  @doc """
  Creates a loop in one transaction: a live loop with the same owner, dedupe
  key and anchor kind is returned as it is stored, with no write; one of the
  other anchor kind is `{:kind_conflict, its_id}`, so a thing to do and a thing
  waited on are never silently merged (M83 §11); otherwise the owner's
  live-loop cap is checked and the row inserted.
  """
  @spec create(term(), map()) ::
          {:ok, {:created | :existing, map()}} | {:error, {:kind_conflict, String.t()} | term()}
  def create(conn, row) do
    in_transaction(conn, fn -> create_in_tx(conn, row) end)
  end

  defp create_in_tx(conn, row) do
    case fetch_live_dedupe(conn, row.owner_id, row.dedupe_key) do
      {:ok, nil} ->
        insert_capped(conn, row)

      {:ok, %{anchor_kind: kind} = existing} when kind == row.anchor_kind ->
        {:ok, {:existing, existing}}

      {:ok, existing} ->
        {:error, {:kind_conflict, existing.id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_capped(conn, row) do
    with {:ok, live} <- count_live(conn, row.owner_id),
         :ok <- under_cap(live),
         :ok <- execute(conn, insert_sql(), Enum.map(@columns, &Map.fetch!(row, &1))),
         {:ok, stored} <- fetch(conn, row.id) do
      {:ok, {:created, stored}}
    end
  end

  defp under_cap(live) do
    if live < Defaults.max_live_loops(), do: :ok, else: {:error, :too_many_loops}
  end

  defp insert_sql, do: "INSERT INTO open_loops (#{@select}) VALUES (#{@insert_placeholders})"

  @doc """
  The one write for answers and outcomes: applies `changes` to a live row,
  clears any claim, bumps `revision`. A missing row is `:not_found`, a closed
  or expired one `:not_live`.
  """
  @spec settle(term(), String.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def settle(conn, id, changes, now) do
    in_transaction(conn, fn ->
      with {:ok, _row} <- fetch(conn, id) do
        conn
        |> write_settle("id = ? AND state IN #{@live_sql}", [id], changes, now)
        |> written(conn, id, :not_live)
      end
    end)
  end

  # Exactly one row written is the only success; zero rows is the caller's
  # refusal, so a guard that did not hold can never read as a write.
  defp written({:ok, 1}, conn, id, _refusal), do: fetch(conn, id)
  defp written({:ok, 0}, _conn, _id, refusal), do: {:error, refusal}
  defp written({:error, reason}, _conn, _id, _refusal), do: {:error, reason}

  @doc """
  A check-in's own finalising write, a compare-and-set on `(id, state = 'due',
  claimed_at)`. Zero rows means the owner settled the loop meanwhile, or the
  claim was swept: `:closed_meanwhile`, and the run must not send.
  """
  @spec finalize(term(), String.t(), String.t(), map(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def finalize(conn, id, claimed_at, changes, now) do
    in_transaction(conn, fn ->
      conn
      |> write_settle(
        "id = ? AND state = 'due' AND claimed_at = ?",
        [id, claimed_at],
        changes,
        now
      )
      |> written(conn, id, :closed_meanwhile)
    end)
  end

  @doc """
  The spend before a check-in's one send (§06 caps): stamps `last_rung2_at`
  and `updated_at`, a compare-and-set on `(id, state = 'due', claimed_at)`,
  inside one transaction with the day's check: `:budget_spent` when any row
  of the owner's already carries a stamp since `since`, the owner's local day
  start, so two runs can never both spend one day whatever the scheduler
  above let through. A claim that no longer stands is the first word: the
  owner settled the loop meanwhile, or the claim was swept,
  `:closed_meanwhile`, and the run must not send. The spend records no answer
  and no outcome, so `revision` and the claim stay.
  """
  @spec spend_budget(term(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :closed_meanwhile | :budget_spent | term()}
  def spend_budget(conn, id, claimed_at, since, now) do
    in_transaction(conn, fn ->
      with {:ok, owner_id} <- claimed_owner(conn, id, claimed_at),
           :ok <- budget_unspent(conn, owner_id, since) do
        conn
        |> execute_changes(
          """
          UPDATE open_loops SET last_rung2_at = ?, updated_at = ?
          WHERE id = ? AND state = 'due' AND claimed_at = ?
          """,
          [now, now, id, claimed_at]
        )
        |> written(conn, id, :closed_meanwhile)
      end
    end)
  end

  # The owner of a due row this claim still holds; read inside the spend's own
  # transaction, so the write below sees the same row.
  defp claimed_owner(conn, id, claimed_at) do
    with {:ok, rows} <-
           query_all(
             conn,
             "SELECT owner_id FROM open_loops WHERE id = ? AND state = 'due' AND claimed_at = ?",
             [id, claimed_at]
           ) do
      case rows do
        [[owner_id]] -> {:ok, owner_id}
        [] -> {:error, :closed_meanwhile}
      end
    end
  end

  defp budget_unspent(conn, owner_id, since) do
    case budget_spent_since(conn, owner_id, since) do
      {:ok, false} -> :ok
      {:ok, true} -> {:error, :budget_spent}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_settle(conn, where_sql, where_params, changes, now) do
    keys = Map.keys(changes)
    assignments = Enum.map_join(keys, ", ", &"#{&1} = ?")

    execute_changes(
      conn,
      """
      UPDATE open_loops
      SET #{assignments}, claimed_at = NULL, revision = revision + 1, updated_at = ?
      WHERE #{where_sql}
      """,
      Enum.map(keys, &Map.fetch!(changes, &1)) ++ [now | where_params]
    )
  end

  @doc "Claims a due, unclaimed row for a check-in run; `:not_claimable` otherwise."
  @spec claim(term(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def claim(conn, id, now) do
    in_transaction(conn, fn ->
      conn
      |> execute_changes(
        """
        UPDATE open_loops SET claimed_at = ?, updated_at = ?
        WHERE id = ? AND state = 'due' AND claimed_at IS NULL
        """,
        [now, now, id]
      )
      |> written(conn, id, :not_claimable)
    end)
  end

  @doc "The boot sweep: no run outlives the daemon, so every claim is returned."
  @spec sweep_claims(term()) :: {:ok, [String.t()]} | {:error, term()}
  def sweep_claims(conn) do
    in_transaction(conn, fn ->
      with {:ok, rows} <-
             query_all(
               conn,
               "SELECT id FROM open_loops WHERE claimed_at IS NOT NULL ORDER BY id",
               []
             ),
           :ok <-
             execute(
               conn,
               "UPDATE open_loops SET claimed_at = NULL WHERE claimed_at IS NOT NULL",
               []
             ) do
        {:ok, Enum.map(rows, fn [id] -> id end)}
      end
    end)
  end

  @doc """
  The due scan (§18): each live, unclaimed row whose touch has arrived is
  re-read and decided by `Lifecycle.due_decision/2` inside its own transaction.
  Open and asked rows are read before rows already due, so a page of waiting
  due rows can never starve a newly arrived one.

  Beside the rows it moved, the result carries the due rows it read and left
  as they were (`waiting`, the rows a rung 2 claim may take) and each expired
  row's state before the scan (`expired_from`, by id), which the expiry's
  trace names.
  """
  @spec scan_due(term(), DateTime.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def scan_due(conn, %DateTime{} = now, limit) do
    stamp = stamp!(now)

    with {:ok, ids} <- scan_candidates(conn, stamp, min(limit, @scan_max)) do
      Enum.reduce_while(ids, {:ok, @empty_scan}, &scan_one(conn, &1, &2, {now, stamp}))
    end
  end

  defp scan_one(conn, id, {:ok, acc}, {now, stamp}) do
    case in_transaction(conn, fn -> decide(conn, id, now, stamp) end) do
      {:ok, result} -> {:cont, {:ok, accumulate(acc, result)}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp scan_candidates(conn, stamp, limit) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT id FROM open_loops
             WHERE state IN #{@live_sql} AND claimed_at IS NULL AND next_touch_at <= ?
             ORDER BY CASE state WHEN 'due' THEN 1 ELSE 0 END, next_touch_at, id
             LIMIT ?
             """,
             [stamp, limit]
           ) do
      {:ok, Enum.map(rows, fn [id] -> id end)}
    end
  end

  defp decide(conn, id, now, stamp) do
    with {:ok, row} <- fetch(conn, id) do
      apply_decision(conn, row, decision(row, now), stamp)
    end
  end

  defp decision(%{state: state, claimed_at: nil} = row, now)
       when state in ["open", "due", "asked"],
       do: Lifecycle.due_decision(row, now)

  defp decision(_row, _now), do: :not_yet

  defp apply_decision(_conn, %{state: "due", claimed_at: nil} = row, :not_yet, _stamp),
    do: {:ok, {:waiting, row}}

  defp apply_decision(_conn, _row, :not_yet, _stamp), do: {:ok, :unchanged}

  defp apply_decision(conn, row, {:due, rung1_until}, stamp) do
    move(
      conn,
      row,
      "state = 'due', rung1_until = ?, updated_at = ?",
      [stamp!(rung1_until), stamp],
      :due
    )
  end

  # A conversation loop's window closed unraised and a later one of the same
  # touch opens where it closed: still due, the pending time and the window
  # moved on. Nothing was raised, so the ledger and the revision stay.
  defp apply_decision(conn, row, {:lapse, next_touch_at, rung1_until}, stamp) do
    with {:ok, {:due, moved}} <-
           move(
             conn,
             row,
             "next_touch_at = ?, rung1_until = ?, updated_at = ?",
             [stamp!(next_touch_at), stamp!(rung1_until), stamp],
             :due
           ) do
      {:ok, {:waiting, moved}}
    end
  end

  defp apply_decision(conn, row, {:skip_to_handback, at}, stamp) do
    move(
      conn,
      row,
      "state = CASE state WHEN 'due' THEN 'open' ELSE state END, next_touch_at = ?, " <>
        "rung1_until = NULL, updated_at = ?",
      [stamp!(at), stamp],
      :skipped_to_handback
    )
  end

  defp apply_decision(conn, row, :expire, stamp) do
    with {:ok, {:expired, moved}} <-
           move(
             conn,
             row,
             "state = 'expired', close_reason = 'expired', closed_at = ?, next_touch_at = NULL, " <>
               "rung1_until = NULL, revision = revision + 1, updated_at = ?",
             [stamp, stamp],
             :expired
           ) do
      {:ok, {:expired, moved, row.state}}
    end
  end

  # The row was read live and unclaimed inside this same transaction, so the
  # guard holds; it is still the write's own condition, never assumed.
  defp move(conn, row, set_sql, params, tag) do
    sql =
      "UPDATE open_loops SET #{set_sql} " <>
        "WHERE id = ? AND state IN #{@live_sql} AND claimed_at IS NULL"

    with {:ok, moved} <-
           conn |> execute_changes(sql, params ++ [row.id]) |> written(conn, row.id, :not_live) do
      {:ok, {tag, moved}}
    end
  end

  defp accumulate(acc, :unchanged), do: acc

  defp accumulate(acc, {:expired, row, from}) do
    acc
    |> accumulate({:expired, row})
    |> Map.update!(:expired_from, &Map.put(&1, row.id, from))
  end

  defp accumulate(acc, {tag, row}), do: Map.update!(acc, tag, &(&1 ++ [row]))

  # --- reads ---------------------------------------------------------------

  @doc "Fetches one row by id."
  @spec fetch(term(), String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def fetch(conn, id) do
    with {:ok, rows} <- query_all(conn, "SELECT #{@select} FROM open_loops WHERE id = ?", [id]) do
      case rows do
        [values] -> {:ok, decode(values)}
        [] -> {:error, :not_found}
      end
    end
  end

  @doc "Lists one owner's live loops, the last closed ones, or both."
  @spec list(term(), map()) :: {:ok, [map()]} | {:error, term()}
  def list(conn, %{owner_id: owner_id, state: "live"}), do: list_live(conn, owner_id)
  def list(conn, %{owner_id: owner_id, state: "closed"}), do: list_closed(conn, owner_id)

  def list(conn, %{owner_id: owner_id, state: "any"}) do
    with {:ok, live} <- list_live(conn, owner_id),
         {:ok, closed} <- list_closed(conn, owner_id) do
      {:ok, live ++ closed}
    end
  end

  defp list_live(conn, owner_id) do
    select_rows(
      conn,
      """
      SELECT #{@select} FROM open_loops
      WHERE owner_id = ? AND state IN #{@live_sql}
      ORDER BY matters_by_at, id LIMIT ?
      """,
      [owner_id, @live_list_max]
    )
  end

  defp list_closed(conn, owner_id) do
    select_rows(
      conn,
      """
      SELECT #{@select} FROM open_loops
      WHERE owner_id = ? AND state IN ('closed', 'expired')
      ORDER BY closed_at DESC, id DESC LIMIT ?
      """,
      [owner_id, Defaults.closed_list_limit()]
    )
  end

  @doc "How many live loops one owner holds."
  @spec count_live(term(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count_live(conn, owner_id) do
    with {:ok, [[count]]} <-
           query_all(
             conn,
             "SELECT COUNT(*) FROM open_loops WHERE owner_id = ? AND state IN #{@live_sql}",
             [
               owner_id
             ]
           ) do
      {:ok, count}
    end
  end

  @doc """
  The earliest moment a live, unclaimed row can next move
  (`Lifecycle.next_wake/2`), or nil when none can.
  """
  @spec next_wake(term(), DateTime.t()) :: {:ok, DateTime.t() | nil} | {:error, term()}
  def next_wake(conn, %DateTime{} = now) do
    with {:ok, rows} <-
           select_rows(
             conn,
             """
             SELECT #{@select} FROM open_loops
             WHERE state IN #{@live_sql} AND claimed_at IS NULL
             ORDER BY next_touch_at, id LIMIT ?
             """,
             [@scan_max]
           ) do
      {:ok,
       rows |> Enum.map(&Lifecycle.next_wake(&1, now)) |> Enum.reject(&is_nil/1) |> earliest()}
    end
  end

  defp earliest([]), do: nil
  defp earliest(instants), do: Enum.min(instants, DateTime)

  @doc """
  Due, unclaimed rows of one owner and agent inside their rung 1 window, the
  `rung1_until` the scan wrote when it marked each due (`Lifecycle`): nearest
  anchor first.
  """
  @spec due_for_note(term(), String.t(), String.t(), String.t()) ::
          {:ok, [map()]} | {:error, term()}
  def due_for_note(conn, owner_id, agent_id, now) do
    select_rows(
      conn,
      """
      SELECT #{@select} FROM open_loops
      WHERE owner_id = ? AND agent_id = ? AND state = 'due' AND claimed_at IS NULL
        AND rung1_until > ?
      ORDER BY matters_by_at, id LIMIT ?
      """,
      [owner_id, agent_id, now, @live_list_max]
    )
  end

  @doc """
  Whether the owner's daily rung 2 budget was spent since `since`: the latest
  `last_rung2_at` over every one of the owner's rows, closed and expired ones
  included, since a spent budget is spent whatever became of the loop.
  """
  @spec budget_spent_since(term(), String.t(), String.t()) ::
          {:ok, boolean()} | {:error, term()}
  def budget_spent_since(conn, owner_id, since) do
    with {:ok, [[spent]]} <-
           query_all(
             conn,
             """
             SELECT COALESCE(MAX(last_rung2_at) >= ?, 0) FROM open_loops
             WHERE owner_id = ?
             """,
             [since, owner_id]
           ) do
      {:ok, spent == 1}
    end
  end

  @doc """
  When the owner's own chat messages were written since `since`, newest first
  and bounded. A message a guest sent carries `"guest": true` in its metadata
  and is never selected, exactly as the memory review's input excludes it.
  """
  @spec owner_message_hours(term(), String.t(), String.t(), String.t()) ::
          {:ok, [DateTime.t()]} | {:error, term()}
  def owner_message_hours(conn, agent_id, owner_id, since) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT created_at FROM messages
             WHERE agent_id = ? AND owner_id = ? AND role = 'user' AND kind = 'chat_message'
               AND created_at >= ?
               AND COALESCE(
                     CASE WHEN json_valid(metadata_json)
                          THEN json_extract(metadata_json, '$.guest') END,
                     0
                   ) != 1
             ORDER BY created_at DESC
             LIMIT ?
             """,
             [agent_id, owner_id, since, @message_hours_max]
           ) do
      {:ok, Enum.map(rows, fn [created_at] -> parse_timestamp!(created_at) end)}
    end
  end

  defp fetch_live_dedupe(conn, owner_id, dedupe_key) do
    with {:ok, rows} <-
           select_rows(
             conn,
             """
             SELECT #{@select} FROM open_loops
             WHERE owner_id = ? AND dedupe_key = ? AND state IN #{@live_sql}
             LIMIT 1
             """,
             [owner_id, dedupe_key]
           ) do
      {:ok, List.first(rows)}
    end
  end

  defp select_rows(conn, sql, params) do
    with {:ok, rows} <- query_all(conn, sql, params), do: {:ok, Enum.map(rows, &decode/1)}
  end

  # --- row mapping ---------------------------------------------------------

  defp decode(values) do
    raw = @columns |> Enum.zip(values) |> Map.new()

    @timestamp_columns
    |> Map.new(fn column -> {column, parse_optional_timestamp(Map.fetch!(raw, column))} end)
    |> Map.merge(%{
      matters_by_date: Date.from_iso8601!(raw.matters_by_date),
      matters_by_time: parse_optional_time(raw.matters_by_time),
      noted_after_outside_content: raw.noted_after_outside_content == 1,
      last_message_after_outside_content: raw.last_message_after_outside_content == 1
    })
    |> then(&Map.merge(raw, &1))
  end

  defp parse_timestamp!(value) do
    {:ok, at, _offset} = DateTime.from_iso8601(value)
    at
  end

  defp parse_optional_timestamp(nil), do: nil
  defp parse_optional_timestamp(value), do: parse_timestamp!(value)

  defp parse_optional_time(nil), do: nil
  defp parse_optional_time(value), do: Time.from_iso8601!(value)

  # --- sqlite plumbing -----------------------------------------------------

  # A failed BEGIN (including :busy) leaves no open transaction, so that is the
  # only path allowed to return without ROLLBACK. Every failure after a
  # successful BEGIN — the wrapped work or COMMIT itself — must roll back, or
  # the single writer's one connection is left inside an open BEGIN IMMEDIATE.
  # Public, with `query_all/3` and `execute/3`, for the follow-up record's SQL
  # (`OpenLoopReactionsSql`), so the open-loop family has one plumbing.
  @doc false
  @spec in_transaction(term(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def in_transaction(conn, fun) do
    case execute(conn, "BEGIN IMMEDIATE", []) do
      :ok -> settle_transaction(conn, fun.())
      {:error, reason} -> {:error, reason}
    end
  end

  defp settle_transaction(conn, {:ok, _value} = result) do
    case execute(conn, "COMMIT", []) do
      :ok -> result
      {:error, reason} -> rollback(conn, reason)
    end
  end

  defp settle_transaction(conn, {:error, reason}), do: rollback(conn, reason)

  defp rollback(conn, reason) do
    case execute(conn, "ROLLBACK", []) do
      :ok ->
        {:error, reason}

      {:error, rollback_error} ->
        Logger.error(
          "Open-loop transaction rollback failed: #{inspect(rollback_error)} " <>
            "(original error: #{inspect(reason)})"
        )

        {:error, reason}
    end
  end

  @doc false
  @spec query_all(term(), String.t(), list()) :: {:ok, [list()]} | {:error, term()}
  def query_all(conn, sql, params) do
    with_statement(conn, sql, fn stmt ->
      with :ok <- bind(stmt, params) do
        Sqlite3.fetch_all(conn, stmt)
      end
    end)
  end

  @doc false
  @spec execute(term(), String.t(), list()) :: :ok | {:error, term()}
  def execute(conn, sql, params) do
    with_statement(conn, sql, fn stmt ->
      with :ok <- bind(stmt, params) do
        step_result(Sqlite3.step(conn, stmt))
      end
    end)
  end

  defp execute_changes(conn, sql, params) do
    with :ok <- execute(conn, sql, params) do
      Sqlite3.changes(conn)
    end
  end

  defp bind(_stmt, []), do: :ok
  defp bind(stmt, params), do: Sqlite3.bind(stmt, params)

  defp step_result(:done), do: :ok
  defp step_result(:busy), do: {:error, :busy}
  defp step_result({:row, _row}), do: :ok
  defp step_result({:error, reason}), do: {:error, reason}

  defp with_statement(conn, sql, fun) do
    case Sqlite3.prepare(conn, sql) do
      {:ok, stmt} -> release_after(conn, stmt, fun.(stmt))
      {:error, reason} -> {:error, reason}
    end
  end

  defp release_after(conn, stmt, result) do
    case Sqlite3.release(conn, stmt) do
      :ok -> result
      {:error, reason} -> {:error, reason}
    end
  end
end
