defmodule FermixCore.Memory.Repo do
  @moduledoc """
  SQLite-backed durable memory owner for conversation history and stored facts.
  """

  use GenServer

  alias Exqlite.Sqlite3
  alias FermixCore.Agents.IterationLimits
  alias FermixCore.Memory.Config
  alias FermixCore.Memory.Scope

  @base_migration_version 1
  @fts_migration_version 2
  @resource_migration_version 3
  @jobs_migration_version 4
  @job_expiry_migration_version 5
  @job_creator_trust_migration_version 6
  @trust_rename_migration_version 7
  @fermix_md_rename_migration_version 8
  @memory_review_migration_version 9
  @taxonomy_migration_version 10
  @trust_check_migration_version 11
  @harness_runs_migration_version 12
  @harness_continuation_migration_version 13
  @harness_client_origin_migration_version 14
  @sqlite_open_intent :readwritecreate

  @base_schema_sql """
  CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    agent_id TEXT NOT NULL DEFAULT 'main',
    owner_id TEXT NOT NULL DEFAULT 'default',
    channel TEXT NOT NULL,
    chat_id TEXT NOT NULL,
    thread_scope TEXT NOT NULL DEFAULT 'root',
    sender TEXT NOT NULL,
    role TEXT NOT NULL,
    kind TEXT NOT NULL DEFAULT 'chat_message',
    content TEXT NOT NULL,
    metadata_json TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
  );
  CREATE INDEX IF NOT EXISTS idx_messages_conversation
    ON messages(agent_id, channel, chat_id, thread_scope, created_at, id);

  CREATE TABLE IF NOT EXISTS memories (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    agent_id TEXT NOT NULL DEFAULT 'main',
    owner_id TEXT NOT NULL DEFAULT 'default',
    scope_type TEXT NOT NULL,
    scope_id TEXT NOT NULL,
    category TEXT NOT NULL,
    key TEXT NOT NULL,
    value TEXT NOT NULL,
    confidence REAL NOT NULL DEFAULT 1.0,
    promote_target TEXT NOT NULL DEFAULT 'none',
    source_message_id INTEGER REFERENCES messages(id),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
  );
  CREATE UNIQUE INDEX IF NOT EXISTS idx_memories_scope_key
    ON memories(agent_id, owner_id, scope_type, scope_id, key);
  """

  @fts_schema_sql """
  CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts
  USING fts5(category, key, value, content=memories, content_rowid=id);

  CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN
    INSERT INTO memories_fts(rowid, category, key, value)
    VALUES (new.id, new.category, new.key, new.value);
  END;

  CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN
    INSERT INTO memories_fts(memories_fts, rowid, category, key, value)
    VALUES('delete', old.id, old.category, old.key, old.value);
  END;

  CREATE TRIGGER IF NOT EXISTS memories_au AFTER UPDATE ON memories BEGIN
    INSERT INTO memories_fts(memories_fts, rowid, category, key, value)
    VALUES('delete', old.id, old.category, old.key, old.value);
    INSERT INTO memories_fts(rowid, category, key, value)
    VALUES (new.id, new.category, new.key, new.value);
  END;

  CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts
  USING fts5(role, kind, content, content=messages, content_rowid=id);

  CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
    INSERT INTO messages_fts(rowid, role, kind, content)
    VALUES (new.id, new.role, new.kind, new.content);
  END;

  CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
    INSERT INTO messages_fts(messages_fts, rowid, role, kind, content)
    VALUES('delete', old.id, old.role, old.kind, old.content);
  END;

  CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages BEGIN
    INSERT INTO messages_fts(messages_fts, rowid, role, kind, content)
    VALUES('delete', old.id, old.role, old.kind, old.content);
    INSERT INTO messages_fts(rowid, role, kind, content)
    VALUES (new.id, new.role, new.kind, new.content);
  END;
  """

  @resource_schema_sql """
  CREATE TABLE IF NOT EXISTS resources (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    agent_id TEXT NOT NULL DEFAULT 'main',
    resource_type TEXT NOT NULL,
    scope_id TEXT NOT NULL DEFAULT 'global',
    resource_path TEXT,
    current_revision INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
  );

  CREATE UNIQUE INDEX IF NOT EXISTS idx_resources_type_scope
    ON resources(agent_id, resource_type, scope_id);

  CREATE TABLE IF NOT EXISTS resource_revisions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    agent_id TEXT NOT NULL DEFAULT 'main',
    resource_type TEXT NOT NULL,
    scope_id TEXT NOT NULL DEFAULT 'global',
    revision INTEGER NOT NULL,
    parent_revision INTEGER,
    content_hash TEXT NOT NULL,
    content TEXT NOT NULL,
    byte_size INTEGER NOT NULL,
    mutation_source TEXT NOT NULL,
    provenance_json TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
  );

  CREATE UNIQUE INDEX IF NOT EXISTS idx_revisions_resource_version
    ON resource_revisions(agent_id, resource_type, scope_id, revision);

  CREATE INDEX IF NOT EXISTS idx_revisions_latest
    ON resource_revisions(agent_id, resource_type, scope_id, created_at DESC);
  """

  @jobs_schema_sql_template """
  ALTER TABLE memories ADD COLUMN source_id TEXT;
  ALTER TABLE memories ADD COLUMN source_type TEXT;
  ALTER TABLE memories ADD COLUMN source_name TEXT;
  ALTER TABLE memories ADD COLUMN source_description TEXT;
  ALTER TABLE memories ADD COLUMN session_id TEXT;
  ALTER TABLE memories ADD COLUMN run_id TEXT;

  CREATE TABLE IF NOT EXISTS scheduled_jobs (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    schedule_kind TEXT NOT NULL,
    schedule_expr TEXT NOT NULL,
    timezone TEXT NOT NULL,
    next_run_at TEXT,
    task_prompt TEXT NOT NULL,
    skill_name TEXT,
    session_mode TEXT NOT NULL DEFAULT 'isolated',
    provider TEXT,
    model TEXT,
    max_iterations INTEGER NOT NULL DEFAULT {{max_iterations_default}},
    timeout_seconds INTEGER,
    inactivity_timeout_seconds INTEGER,
    capability_policy_json TEXT,
    allowed_tools_json TEXT,
    memory_source_id TEXT NOT NULL REFERENCES memory_sources(id) ON DELETE RESTRICT,
    memory_read_scopes_json TEXT,
    memory_write_scope TEXT,
    main_visible INTEGER NOT NULL DEFAULT 1,
    delivery_mode TEXT NOT NULL DEFAULT 'none',
    delivery_target_json TEXT,
    silent_marker TEXT NOT NULL DEFAULT '[SILENT]',
    enabled INTEGER NOT NULL DEFAULT 1,
    state TEXT NOT NULL DEFAULT 'scheduled',
    last_run_at TEXT,
    last_status TEXT,
    last_error TEXT,
    created_by_agent_id TEXT NOT NULL DEFAULT 'main',
    created_by_session_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
  );

  CREATE INDEX IF NOT EXISTS idx_scheduled_jobs_state_next_run
    ON scheduled_jobs(enabled, state, next_run_at);
  CREATE INDEX IF NOT EXISTS idx_scheduled_jobs_creator_state
    ON scheduled_jobs(created_by_agent_id, state);

  CREATE TABLE IF NOT EXISTS job_runs (
    id TEXT PRIMARY KEY,
    job_id TEXT NOT NULL REFERENCES scheduled_jobs(id) ON DELETE CASCADE,
    session_id TEXT NOT NULL,
    trigger TEXT NOT NULL,
    status TEXT NOT NULL,
    claimed_at TEXT,
    started_at TEXT,
    completed_at TEXT,
    prompt_snapshot TEXT,
    job_config_snapshot_json TEXT,
    capability_policy_snapshot_json TEXT,
    output_ref TEXT,
    final_response TEXT,
    error TEXT,
    delivery_status TEXT NOT NULL DEFAULT 'none',
    delivery_error TEXT,
    iterations INTEGER,
    token_usage_json TEXT,
    latency_json TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
  );

  CREATE INDEX IF NOT EXISTS idx_job_runs_job_created
    ON job_runs(job_id, created_at DESC);
  CREATE INDEX IF NOT EXISTS idx_job_runs_status_created
    ON job_runs(status, created_at DESC);

  CREATE TABLE IF NOT EXISTS memory_sources (
    id TEXT PRIMARY KEY,
    source_type TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT,
    owner_agent_id TEXT NOT NULL DEFAULT 'main',
    visibility TEXT NOT NULL DEFAULT 'main_visible',
    schedule_summary TEXT,
    status TEXT NOT NULL DEFAULT 'enabled',
    last_run_at TEXT,
    last_status TEXT,
    memory_scope TEXT NOT NULL,
    output_scope TEXT,
    metadata_json TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
  );

  CREATE INDEX IF NOT EXISTS idx_memory_sources_owner_visibility
    ON memory_sources(owner_agent_id, visibility, status);
  """

  @job_expiry_schema_sql """
  ALTER TABLE scheduled_jobs ADD COLUMN expires_at TEXT;
  CREATE INDEX IF NOT EXISTS idx_scheduled_jobs_expires_at
    ON scheduled_jobs(enabled, state, expires_at);
  """

  # Audit F-08: capture the channel + trust the job was created from so the
  # runner can intersect any stored capability_policy with the creator's
  # ceiling at run time. Existing rows get NULL channel and "core" trust —
  # legacy jobs run with full main-agent surface (their original semantics)
  # until they are recreated; new jobs created from remote channels are
  # scoped at creation.
  @job_creator_trust_schema_sql """
  ALTER TABLE scheduled_jobs ADD COLUMN created_by_channel TEXT;
  ALTER TABLE scheduled_jobs ADD COLUMN created_by_trust TEXT NOT NULL DEFAULT 'core';
  """

  # Trust vocabulary collapse: `:owner_remote`, `:local`, and `:core`
  # all merge into `:operator` (the human owner's surface);
  # `:third_party` is renamed to `:guest`. Existing scheduled job rows
  # are rewritten in place so the runner's `effective_trust/1` only
  # needs to recognise the new strings.
  @trust_rename_schema_sql """
  UPDATE scheduled_jobs SET created_by_trust = 'operator'
    WHERE created_by_trust IN ('owner_remote', 'local', 'core');
  UPDATE scheduled_jobs SET created_by_trust = 'guest'
    WHERE created_by_trust = 'third_party';
  """

  # Prompt-resource rename: the agent operating-rules file moved from
  # `AGENTS.md` to `FERMIX.md` to avoid collision with the workspace
  # `AGENTS.md` convention. Existing resource rows and revision history are
  # rewritten in place so versioning continues unbroken. The stored
  # `resource_path` basename is rewritten too (both basenames are 9 chars):
  # `BootstrapRename` renames the file with identical content, so the loader's
  # next commit returns `:unchanged` and skips the resource upsert — leaving a
  # stale `AGENTS.md` path that `Registry.rollback/5` would resolve and recreate
  # on disk. The on-disk file rename is handled separately by `BootstrapRename`.
  @fermix_md_rename_schema_sql """
  UPDATE resources SET resource_type = 'fermix_md' WHERE resource_type = 'agents_md';
  UPDATE resource_revisions SET resource_type = 'fermix_md' WHERE resource_type = 'agents_md';
  UPDATE resources
    SET resource_path = substr(resource_path, 1, length(resource_path) - 9) || 'FERMIX.md'
    WHERE resource_type = 'fermix_md' AND resource_path LIKE '%/AGENTS.md';
  """

  # Memory taxonomy redesign: the category vocabulary moved to a general-assistant
  # spine. Existing rows are rewritten in place — `project`/`environment` fold
  # into `context`, `instruction`/`correction` fold into `directive` — preserving
  # each row's promote_target (both predecessor and successor resolve to the same
  # prompt file). `episode` is retired: those rows are tombstoned rather than
  # deleted, so a misclassification can still be restored. The UPDATE triggers
  # keep the FTS mirror consistent; `key`/scope are untouched, so the
  # scope-key UNIQUE index is never violated. Conversation-cache `fact` rows are
  # a separate namespace and intentionally left alone.
  @taxonomy_schema_sql """
  UPDATE memories SET category = 'context'
    WHERE category IN ('project', 'environment');
  UPDATE memories SET category = 'directive'
    WHERE category IN ('instruction', 'correction');
  UPDATE memories
    SET archived_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
        archived_by = 'taxonomy_migration',
        archive_reason = 'retired_category:episode',
        updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
    WHERE category = 'episode' AND archived_at IS NULL;
  """

  # Trust vocabulary is now enforced by the schema. The `created_by_trust`
  # column still carried `NOT NULL DEFAULT 'core'` with no CHECK, so a
  # rolled-back binary (or any stray writer) could mint an out-of-vocabulary
  # row that the runner's raising `effective_trust/1` would brick at run time.
  # The standard SQLite 12-step rebuild drops the column default and adds a
  # CHECK constraint, rewriting the last `'core'` rows (minted since the v7
  # rename) to `'operator'` in the copy. Foreign keys are disabled around the
  # rebuild so dropping the parent `scheduled_jobs` does not cascade-delete
  # `job_runs`; the copy preserves every id, so integrity holds. The column
  # order matches the pre-rebuild table exactly, keeping `SELECT *` reads
  # (`scheduled_job_row/1`) unaffected.
  @trust_check_schema_sql_template """
  CREATE TABLE scheduled_jobs_new (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    schedule_kind TEXT NOT NULL,
    schedule_expr TEXT NOT NULL,
    timezone TEXT NOT NULL,
    next_run_at TEXT,
    task_prompt TEXT NOT NULL,
    skill_name TEXT,
    session_mode TEXT NOT NULL DEFAULT 'isolated',
    provider TEXT,
    model TEXT,
    max_iterations INTEGER NOT NULL DEFAULT {{max_iterations_default}},
    timeout_seconds INTEGER,
    inactivity_timeout_seconds INTEGER,
    capability_policy_json TEXT,
    allowed_tools_json TEXT,
    memory_source_id TEXT NOT NULL REFERENCES memory_sources(id) ON DELETE RESTRICT,
    memory_read_scopes_json TEXT,
    memory_write_scope TEXT,
    main_visible INTEGER NOT NULL DEFAULT 1,
    delivery_mode TEXT NOT NULL DEFAULT 'none',
    delivery_target_json TEXT,
    silent_marker TEXT NOT NULL DEFAULT '[SILENT]',
    enabled INTEGER NOT NULL DEFAULT 1,
    state TEXT NOT NULL DEFAULT 'scheduled',
    last_run_at TEXT,
    last_status TEXT,
    last_error TEXT,
    created_by_agent_id TEXT NOT NULL DEFAULT 'main',
    created_by_session_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    expires_at TEXT,
    created_by_channel TEXT,
    created_by_trust TEXT NOT NULL CHECK (created_by_trust IN ('operator', 'guest'))
  );

  INSERT INTO scheduled_jobs_new
  SELECT
    id, name, description, schedule_kind, schedule_expr, timezone, next_run_at,
    task_prompt, skill_name, session_mode, provider, model, max_iterations,
    timeout_seconds, inactivity_timeout_seconds, capability_policy_json,
    allowed_tools_json, memory_source_id, memory_read_scopes_json,
    memory_write_scope, main_visible, delivery_mode, delivery_target_json,
    silent_marker, enabled, state, last_run_at, last_status, last_error,
    created_by_agent_id, created_by_session_id, created_at, updated_at,
    expires_at, created_by_channel,
    CASE WHEN created_by_trust = 'core' THEN 'operator' ELSE created_by_trust END
  FROM scheduled_jobs;

  DROP TABLE scheduled_jobs;
  ALTER TABLE scheduled_jobs_new RENAME TO scheduled_jobs;

  CREATE INDEX IF NOT EXISTS idx_scheduled_jobs_state_next_run
    ON scheduled_jobs(enabled, state, next_run_at);
  CREATE INDEX IF NOT EXISTS idx_scheduled_jobs_creator_state
    ON scheduled_jobs(created_by_agent_id, state);
  CREATE INDEX IF NOT EXISTS idx_scheduled_jobs_expires_at
    ON scheduled_jobs(enabled, state, expires_at);
  """

  @memory_review_schema_sql """
  ALTER TABLE memories ADD COLUMN archived_at TEXT;
  ALTER TABLE memories ADD COLUMN archived_by TEXT;
  ALTER TABLE memories ADD COLUMN archive_reason TEXT;

  CREATE TABLE IF NOT EXISTS memory_review_state (
    agent_id TEXT NOT NULL,
    owner_id TEXT NOT NULL,
    channel TEXT NOT NULL,
    chat_id TEXT NOT NULL,
    thread_scope TEXT NOT NULL,
    last_reviewed_message_id INTEGER,
    last_reviewed_at TEXT,
    last_review_started_at TEXT,
    last_review_completed_at TEXT,
    last_review_status TEXT,
    last_review_failed_at TEXT,
    failure_count INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (agent_id, owner_id, channel, chat_id, thread_scope)
  );

  CREATE INDEX IF NOT EXISTS idx_messages_review_tail
    ON messages(agent_id, owner_id, channel, chat_id, thread_scope, role, id);
  """

  @harness_runs_schema_sql """
  CREATE TABLE IF NOT EXISTS harness_runs (
    id TEXT PRIMARY KEY,
    vendor TEXT NOT NULL CHECK (vendor IN ('codex', 'claude', 'codex_cloud')),
    rail TEXT NOT NULL CHECK (rail IN ('local', 'cloud')),
    status TEXT NOT NULL CHECK (status IN (
      'starting', 'submitting', 'running', 'polling',
      'completed', 'failed', 'blocked', 'cancelled', 'interrupted'
    )),
    reason TEXT,
    cwd TEXT NOT NULL,
    worktree_root TEXT NOT NULL,
    lock_roots_json TEXT NOT NULL,
    artifacts_dir TEXT NOT NULL,
    resumable INTEGER NOT NULL DEFAULT 1,
    vendor_session_id TEXT,
    exit_code INTEGER,
    framing_errors INTEGER NOT NULL DEFAULT 0,
    artifact_truncated INTEGER NOT NULL DEFAULT 0,
    usage_json TEXT,
    diagnostics_tail TEXT,
    origin_kind TEXT NOT NULL CHECK (origin_kind IN ('chat', 'scheduled')),
    origin_session_id TEXT NOT NULL,
    parent_job_id TEXT,
    delivery_mode TEXT NOT NULL,
    platform TEXT,
    destination TEXT,
    thread TEXT,
    send_opts_json TEXT,
    delivery_status TEXT NOT NULL DEFAULT 'pending'
      CHECK (delivery_status IN ('pending', 'delivered', 'dead_letter')),
    delivery_attempts INTEGER NOT NULL DEFAULT 0,
    next_delivery_at TEXT,
    last_delivery_error TEXT,
    task_id TEXT,
    task_url TEXT,
    next_poll_at TEXT,
    poll_deadline TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    started_at TEXT,
    first_event_at TEXT,
    last_event_at TEXT,
    completed_at TEXT,
    delivered_at TEXT
  );

  CREATE INDEX IF NOT EXISTS idx_harness_runs_status
    ON harness_runs(status, created_at DESC);
  CREATE INDEX IF NOT EXISTS idx_harness_runs_delivery_status
    ON harness_runs(delivery_status, created_at DESC);
  """

  # Completion-continuation chain depth (CODING_HARNESS_ORCHESTRATION §23.2): the
  # depth of the turn that launched the run (0 for an owner-typed request), read
  # at terminalization to bound the chain. Appended by ALTER so a migrated and a
  # freshly created database share one column order (`SELECT *` is positional).
  @harness_continuation_schema_sql """
  ALTER TABLE harness_runs ADD COLUMN continuation_depth INTEGER NOT NULL DEFAULT 0;
  """

  # The launching client's origin snapshot for a client-owned surface
  # (MILESTONE_29_ACP_AGENT_SURFACE §17.4): `{identity, cwd, reply_context}`,
  # frozen at launch so a continuation minutes later rebuilds the turn env from
  # the durable identity record instead of a session that no longer exists.
  # Appended by ALTER for the same reason `continuation_depth` was: a migrated and
  # a freshly created database must share one column order (`SELECT *` is
  # positional), and these are exactly the rows a continuation reads.
  @harness_client_origin_schema_sql """
  ALTER TABLE harness_runs ADD COLUMN client_origin_json TEXT;
  """

  # Active statuses hold workspace locks and count against `max_active`. The
  # literal is inlined into WHERE clauses only (never interpolated with data),
  # so it is safe as a SQL fragment.
  @harness_active_status_sql "'starting', 'submitting', 'running', 'polling'"

  # Column classes for the dynamic UPDATE set-clause builder. Every settable
  # column is allowlisted here by type; an unknown key raises (no silent drop).
  @harness_run_timestamp_cols [
    :started_at,
    :first_event_at,
    :last_event_at,
    :completed_at,
    :delivered_at,
    :next_delivery_at,
    :next_poll_at,
    :poll_deadline
  ]
  @harness_run_bool_cols [:resumable, :artifact_truncated]
  # `:status` is deliberately absent: the only legitimate status writer is
  # `terminalize_harness_run_row/4`, which prepends the status assignment itself
  # under an active-status guard. The generic UPDATE path rejects `:status` up
  # front (`update_harness_run_row/3`), so record_progress/record_session/
  # mark_delivery can never resurrect a terminal row to an active status.
  @harness_run_plain_cols [
    :reason,
    :vendor_session_id,
    :exit_code,
    :framing_errors,
    :diagnostics_tail,
    :delivery_status,
    :delivery_attempts,
    :last_delivery_error,
    :task_id,
    :task_url
  ]

  @type message_attrs :: %{
          required(:agent_id) => String.t(),
          required(:owner_id) => String.t(),
          required(:channel) => String.t(),
          required(:chat_id) => String.t(),
          required(:thread_scope) => String.t() | atom() | integer(),
          required(:sender) => String.t(),
          required(:role) => String.t(),
          required(:kind) => String.t(),
          required(:content) => String.t(),
          optional(:metadata) => map() | nil,
          optional(:created_at) => DateTime.t()
        }

  @type message_selector :: %{
          required(:agent_id) => String.t(),
          required(:channel) => String.t(),
          required(:chat_id) => String.t(),
          required(:thread_scope) => String.t() | atom() | integer(),
          optional(:owner_id) => String.t(),
          optional(:role) => String.t(),
          optional(:kind) => String.t()
        }

  @type memory_attrs :: %{
          required(:agent_id) => String.t(),
          required(:owner_id) => String.t(),
          required(:scope_type) => String.t(),
          required(:scope_id) => String.t(),
          required(:category) => String.t(),
          required(:key) => String.t(),
          required(:value) => String.t(),
          optional(:confidence) => float(),
          optional(:promote_target) => String.t(),
          optional(:source_message_id) => integer() | nil,
          optional(:source_id) => String.t() | nil,
          optional(:source_type) => String.t() | nil,
          optional(:source_name) => String.t() | nil,
          optional(:source_description) => String.t() | nil,
          optional(:session_id) => String.t() | nil,
          optional(:run_id) => String.t() | nil,
          optional(:created_at) => DateTime.t(),
          optional(:updated_at) => DateTime.t()
        }

  @type memory_selector :: %{
          required(:agent_id) => String.t(),
          required(:owner_id) => String.t(),
          optional(:scope_type) => String.t(),
          optional(:scope_id) => String.t(),
          optional(:category) => String.t(),
          optional(:source_id) => String.t(),
          optional(:source_type) => String.t(),
          optional(:session_id) => String.t(),
          optional(:run_id) => String.t(),
          optional(:key) => String.t(),
          optional(:id) => pos_integer(),
          optional(:archived?) => boolean()
        }

  @type memory_review_selector :: %{
          required(:agent_id) => String.t(),
          required(:owner_id) => String.t(),
          required(:channel) => String.t(),
          required(:chat_id) => String.t(),
          required(:thread_scope) => String.t() | atom() | integer()
        }

  @type memory_review_state_row :: %{
          agent_id: String.t(),
          owner_id: String.t(),
          channel: String.t(),
          chat_id: String.t(),
          thread_scope: String.t(),
          last_reviewed_message_id: integer() | nil,
          last_reviewed_at: DateTime.t() | nil,
          last_review_started_at: DateTime.t() | nil,
          last_review_completed_at: DateTime.t() | nil,
          last_review_status: String.t() | nil,
          last_review_failed_at: DateTime.t() | nil,
          failure_count: non_neg_integer(),
          updated_at: DateTime.t()
        }

  @type memory_key_selector :: %{
          required(:agent_id) => String.t(),
          required(:owner_id) => String.t(),
          optional(:scope_type) => String.t(),
          optional(:scope_id) => String.t(),
          optional(:category) => String.t(),
          optional(:source_id) => String.t(),
          optional(:source_type) => String.t(),
          optional(:session_id) => String.t(),
          optional(:run_id) => String.t(),
          required(:key) => String.t()
        }

  @type resource_attrs :: %{
          required(:agent_id) => String.t(),
          required(:resource_type) => String.t(),
          required(:scope_id) => String.t(),
          required(:current_revision) => non_neg_integer(),
          optional(:resource_path) => String.t() | nil
        }

  @type resource_selector :: %{
          required(:agent_id) => String.t(),
          required(:resource_type) => String.t(),
          required(:scope_id) => String.t()
        }

  @type revision_attrs :: %{
          required(:agent_id) => String.t(),
          required(:resource_type) => String.t(),
          required(:scope_id) => String.t(),
          required(:revision) => pos_integer(),
          required(:parent_revision) => pos_integer() | nil,
          required(:content_hash) => String.t(),
          required(:content) => String.t(),
          required(:byte_size) => non_neg_integer(),
          required(:mutation_source) => String.t(),
          optional(:provenance) => map() | nil
        }

  @type scheduled_job_attrs :: map()
  @type job_run_attrs :: map()
  @type memory_source_attrs :: map()

  @type message_row :: %{
          id: integer(),
          agent_id: String.t(),
          owner_id: String.t(),
          channel: String.t(),
          chat_id: String.t(),
          thread_scope: String.t(),
          sender: String.t(),
          role: String.t(),
          kind: String.t(),
          content: String.t(),
          metadata: map() | nil,
          created_at: DateTime.t()
        }

  @type message_search_row :: %{
          id: integer(),
          agent_id: String.t(),
          owner_id: String.t(),
          channel: String.t(),
          chat_id: String.t(),
          thread_scope: String.t(),
          sender: String.t(),
          role: String.t(),
          kind: String.t(),
          content: String.t(),
          metadata: map() | nil,
          created_at: DateTime.t(),
          rank: float()
        }

  @type message_search_selector :: %{
          required(:agent_id) => String.t(),
          optional(:owner_id) => String.t(),
          optional(:channel) => String.t(),
          optional(:chat_id) => String.t(),
          optional(:thread_scope) => String.t() | atom() | integer(),
          optional(:role) => String.t(),
          optional(:kind) => String.t()
        }

  @type memory_row :: %{
          id: integer(),
          agent_id: String.t(),
          owner_id: String.t(),
          scope_type: String.t(),
          scope_id: String.t(),
          category: String.t(),
          key: String.t(),
          value: String.t(),
          confidence: float(),
          promote_target: String.t(),
          source_message_id: integer() | nil,
          source_id: String.t() | nil,
          source_type: String.t() | nil,
          source_name: String.t() | nil,
          source_description: String.t() | nil,
          session_id: String.t() | nil,
          run_id: String.t() | nil,
          archived_at: DateTime.t() | nil,
          archived_by: String.t() | nil,
          archive_reason: String.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @type memory_search_row :: %{
          id: integer(),
          agent_id: String.t(),
          owner_id: String.t(),
          scope_type: String.t(),
          scope_id: String.t(),
          category: String.t(),
          key: String.t(),
          value: String.t(),
          confidence: float(),
          promote_target: String.t(),
          source_message_id: integer() | nil,
          source_id: String.t() | nil,
          source_type: String.t() | nil,
          source_name: String.t() | nil,
          source_description: String.t() | nil,
          session_id: String.t() | nil,
          run_id: String.t() | nil,
          archived_at: DateTime.t() | nil,
          archived_by: String.t() | nil,
          archive_reason: String.t() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          rank: float()
        }

  @type resource_row :: %{
          id: integer(),
          agent_id: String.t(),
          resource_type: String.t(),
          scope_id: String.t(),
          resource_path: String.t() | nil,
          current_revision: non_neg_integer(),
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @type resource_revision_row :: %{
          id: integer(),
          agent_id: String.t(),
          resource_type: String.t(),
          scope_id: String.t(),
          revision: pos_integer(),
          parent_revision: pos_integer() | nil,
          content_hash: String.t(),
          content: String.t(),
          byte_size: non_neg_integer(),
          mutation_source: String.t(),
          provenance: map() | nil,
          created_at: DateTime.t()
        }

  @type scheduled_job_row :: map()
  @type job_run_row :: map()
  @type memory_source_row :: map()
  @type harness_run_attrs :: map()
  @type harness_run_row :: map()

  @type state :: %{
          enabled: boolean(),
          conn: reference() | nil,
          database_path: String.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, :enabled?)
  end

  @spec enabled_server(pid() | atom()) :: pid() | atom() | nil
  def enabled_server(server) when is_pid(server), do: server

  def enabled_server(server) when is_atom(server) do
    if safely_enabled?(server) do
      server
    end
  end

  defp safely_enabled?(server) do
    enabled?(server: server)
  catch
    :exit, {:noproc, _call} -> false
    :exit, {:normal, _call} -> false
    :exit, {:shutdown, _call} -> false
  end

  @spec insert_message(message_attrs(), keyword()) :: {:ok, message_row()} | {:error, term()}
  def insert_message(attrs, opts \\ []) when is_map(attrs) do
    call({:insert_message, attrs}, opts)
  end

  @spec get_messages(message_selector(), keyword()) :: {:ok, [message_row()]} | {:error, term()}
  def get_messages(selector, opts \\ []) when is_map(selector) do
    call({:get_messages, selector, Keyword.get(opts, :limit, 50)}, opts)
  end

  @spec message_count(message_selector(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def message_count(selector, opts \\ []) when is_map(selector) do
    call({:message_count, selector}, opts)
  end

  @spec delete_messages(message_selector(), keyword()) :: :ok | {:error, term()}
  def delete_messages(selector, opts \\ []) when is_map(selector) do
    call({:delete_messages, selector}, opts)
  end

  @spec upsert_memory(memory_attrs(), keyword()) :: {:ok, memory_row()} | {:error, term()}
  def upsert_memory(attrs, opts \\ []) when is_map(attrs) do
    call({:upsert_memory, attrs}, opts)
  end

  @spec get_memory(memory_selector(), keyword()) ::
          {:ok, memory_row()} | {:error, :not_found | term()}
  def get_memory(selector, opts \\ []) when is_map(selector) do
    call({:get_memory, selector}, opts)
  end

  @spec get_memories(memory_selector(), keyword()) :: {:ok, [memory_row()]} | {:error, term()}
  def get_memories(selector, opts \\ []) when is_map(selector) do
    call({:get_memories, selector}, opts)
  end

  @doc """
  Deletes one memory selected by key and scope.

  Use `delete_memories/2` for bulk deletes by scope or category.
  """
  @spec delete_memory(memory_key_selector(), keyword()) :: :ok | {:error, term()}
  def delete_memory(selector, opts \\ []) when is_map(selector) do
    with {:ok, selector} <- require_memory_key(selector) do
      call({:delete_memory, selector}, opts)
    end
  end

  @doc """
  Deletes all memories matching the selector.
  """
  @spec delete_memories(memory_selector(), keyword()) :: :ok | {:error, term()}
  def delete_memories(selector, opts \\ []) when is_map(selector) do
    call({:delete_memories, selector}, opts)
  end

  @spec update_memory_value(memory_selector(), String.t(), keyword()) ::
          {:ok, memory_row()} | {:error, :not_found | term()}
  def update_memory_value(selector, value, opts \\ [])
      when is_map(selector) and is_binary(value) do
    call({:update_memory_value, selector, value}, opts)
  end

  @spec archive_memory(memory_selector(), String.t(), String.t(), DateTime.t(), keyword()) ::
          {:ok, memory_row()} | {:error, :not_found | term()}
  def archive_memory(selector, archived_by, reason, %DateTime{} = now, opts \\ [])
      when is_map(selector) and is_binary(archived_by) and is_binary(reason) do
    call({:archive_memory, selector, archived_by, reason, now}, opts)
  end

  @spec restore_memory(pos_integer(), keyword()) ::
          {:ok, memory_row()} | {:error, :not_found | term()}
  def restore_memory(id, opts \\ []) when is_integer(id) and id > 0 do
    call({:restore_memory, id}, opts)
  end

  @spec search_memories(String.t(), keyword()) :: {:ok, [memory_search_row()]} | {:error, term()}
  def search_memories(query, opts \\ []) when is_binary(query) do
    call(
      {:search_memories, query, Keyword.get(opts, :selector, %{}), Keyword.get(opts, :limit, 10)},
      opts
    )
  end

  @spec search_messages(String.t(), keyword()) :: {:ok, [message_search_row()]} | {:error, term()}
  def search_messages(query, opts \\ []) when is_binary(query) do
    call(
      {:search_messages, query, Keyword.get(opts, :selector, %{}), Keyword.get(opts, :limit, 10)},
      opts
    )
  end

  @spec get_user_messages_after(
          memory_review_selector(),
          non_neg_integer() | nil,
          pos_integer(),
          keyword()
        ) ::
          {:ok, [message_row()]} | {:error, term()}
  def get_user_messages_after(selector, last_id, limit, opts \\ [])
      when is_map(selector) and (is_nil(last_id) or (is_integer(last_id) and last_id >= 0)) and
             is_integer(limit) and limit > 0 do
    call({:get_user_messages_after, selector, last_id || 0, limit}, opts)
  end

  @spec list_review_conversations(map(), keyword()) ::
          {:ok, [memory_review_selector()]} | {:error, term()}
  def list_review_conversations(selector \\ %{}, opts \\ []) when is_map(selector) do
    call({:list_review_conversations, selector}, opts)
  end

  @spec get_memory_review_state(memory_review_selector(), keyword()) ::
          {:ok, memory_review_state_row()} | {:error, :not_found | term()}
  def get_memory_review_state(selector, opts \\ []) when is_map(selector) do
    call({:get_memory_review_state, selector}, opts)
  end

  @spec claim_memory_review(memory_review_selector(), DateTime.t(), non_neg_integer(), keyword()) ::
          {:ok, memory_review_state_row()} | {:error, :concurrent_run | term()}
  def claim_memory_review(selector, %DateTime{} = now, stale_after_ms, opts \\ [])
      when is_map(selector) and is_integer(stale_after_ms) and stale_after_ms >= 0 do
    call({:claim_memory_review, selector, now, stale_after_ms}, opts)
  end

  @spec complete_memory_review(
          memory_review_selector(),
          :ok | :nothing_to_save,
          non_neg_integer(),
          DateTime.t(),
          keyword()
        ) ::
          {:ok, memory_review_state_row()} | {:error, term()}
  def complete_memory_review(
        selector,
        status,
        last_reviewed_message_id,
        %DateTime{} = now,
        opts \\ []
      )
      when is_map(selector) and status in [:ok, :nothing_to_save] and
             is_integer(last_reviewed_message_id) and last_reviewed_message_id >= 0 do
    call({:complete_memory_review, selector, status, last_reviewed_message_id, now}, opts)
  end

  @spec fail_memory_review(memory_review_selector(), DateTime.t(), keyword()) ::
          {:ok, memory_review_state_row()} | {:error, term()}
  def fail_memory_review(selector, %DateTime{} = now, opts \\ []) when is_map(selector) do
    call({:fail_memory_review, selector, now}, opts)
  end

  @spec upsert_resource(resource_attrs(), keyword()) :: {:ok, resource_row()} | {:error, term()}
  def upsert_resource(attrs, opts \\ []) when is_map(attrs) do
    call({:upsert_resource, attrs}, opts)
  end

  @spec get_resource(resource_selector(), keyword()) ::
          {:ok, resource_row()} | {:error, :not_found | term()}
  def get_resource(selector, opts \\ []) when is_map(selector) do
    call({:get_resource, selector}, opts)
  end

  @spec list_resources(map(), keyword()) :: {:ok, [resource_row()]} | {:error, term()}
  def list_resources(selector \\ %{}, opts \\ []) when is_map(selector) do
    call({:list_resources, selector}, opts)
  end

  @spec insert_revision(revision_attrs(), keyword()) ::
          {:ok, resource_revision_row()} | {:error, term()}
  def insert_revision(attrs, opts \\ []) when is_map(attrs) do
    call({:insert_revision, attrs}, opts)
  end

  @spec commit_resource_revision(map(), keyword()) ::
          {:ok, resource_revision_row() | :unchanged} | {:error, term()}
  def commit_resource_revision(attrs, opts \\ []) when is_map(attrs) do
    call({:commit_resource_revision, attrs}, opts)
  end

  @spec get_revision(map(), keyword()) ::
          {:ok, resource_revision_row()} | {:error, :not_found | term()}
  def get_revision(selector, opts \\ []) when is_map(selector) do
    call({:get_revision, selector}, opts)
  end

  @spec get_latest_revision(resource_selector(), keyword()) ::
          {:ok, resource_revision_row()} | {:error, :not_found | term()}
  def get_latest_revision(selector, opts \\ []) when is_map(selector) do
    call({:get_latest_revision, selector}, opts)
  end

  @spec list_revisions(resource_selector(), keyword()) ::
          {:ok, [resource_revision_row()]} | {:error, term()}
  def list_revisions(selector, opts \\ []) when is_map(selector) do
    call(
      {:list_revisions, selector, Keyword.get(opts, :limit, 20), Keyword.get(opts, :offset, 0)},
      opts
    )
  end

  @spec revision_count(resource_selector(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def revision_count(selector, opts \\ []) when is_map(selector) do
    call({:revision_count, selector}, opts)
  end

  @spec create_job_with_source(scheduled_job_attrs(), memory_source_attrs(), keyword()) ::
          {:ok, scheduled_job_row()} | {:error, term()}
  def create_job_with_source(job_attrs, source_attrs, opts \\ [])
      when is_map(job_attrs) and is_map(source_attrs) do
    call({:create_job_with_source, job_attrs, source_attrs}, opts)
  end

  @spec due_scheduled_jobs(DateTime.t(), keyword()) ::
          {:ok, [scheduled_job_row()]} | {:error, term()}
  def due_scheduled_jobs(%DateTime{} = now, opts \\ []) do
    call({:due_scheduled_jobs, now, Keyword.get(opts, :limit, 20)}, opts)
  end

  @spec next_scheduled_job(keyword()) :: {:ok, scheduled_job_row() | nil} | {:error, term()}
  def next_scheduled_job(opts \\ []) do
    call(:next_scheduled_job, opts)
  end

  @spec claim_due_job(String.t(), scheduled_job_attrs(), job_run_attrs(), DateTime.t(), keyword()) ::
          {:ok, {scheduled_job_row(), job_run_row()}} | {:error, term()}
  def claim_due_job(id, job_attrs, run_attrs, %DateTime{} = now, opts \\ [])
      when is_binary(id) and is_map(job_attrs) and is_map(run_attrs) do
    call({:claim_due_job, id, job_attrs, run_attrs, now}, opts)
  end

  @spec claim_job_now(String.t(), scheduled_job_attrs(), job_run_attrs(), keyword()) ::
          {:ok, {scheduled_job_row(), job_run_row()}} | {:error, term()}
  def claim_job_now(id, job_attrs, run_attrs, opts \\ [])
      when is_binary(id) and is_map(job_attrs) and is_map(run_attrs) do
    call({:claim_job_now, id, job_attrs, run_attrs}, opts)
  end

  @spec upsert_scheduled_job(scheduled_job_attrs(), keyword()) ::
          {:ok, scheduled_job_row()} | {:error, term()}
  def upsert_scheduled_job(attrs, opts \\ []) when is_map(attrs) do
    call({:upsert_scheduled_job, attrs}, opts)
  end

  @spec get_scheduled_job(String.t(), keyword()) ::
          {:ok, scheduled_job_row()} | {:error, :not_found | term()}
  def get_scheduled_job(id, opts \\ []) when is_binary(id) do
    call({:get_scheduled_job, id}, opts)
  end

  @spec list_scheduled_jobs(map(), keyword()) :: {:ok, [scheduled_job_row()]} | {:error, term()}
  def list_scheduled_jobs(selector \\ %{}, opts \\ []) when is_map(selector) do
    call({:list_scheduled_jobs, selector}, opts)
  end

  @spec delete_scheduled_job(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_scheduled_job(id, opts \\ []) when is_binary(id) do
    call({:delete_scheduled_job, id}, opts)
  end

  @spec delete_scheduled_job_if_idle(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_scheduled_job_if_idle(id, opts \\ []) when is_binary(id) do
    call({:delete_scheduled_job_if_idle, id}, opts)
  end

  @spec upsert_job_run(job_run_attrs(), keyword()) :: {:ok, job_run_row()} | {:error, term()}
  def upsert_job_run(attrs, opts \\ []) when is_map(attrs) do
    call({:upsert_job_run, attrs}, opts)
  end

  @spec get_job_run(String.t(), keyword()) :: {:ok, job_run_row()} | {:error, :not_found | term()}
  def get_job_run(id, opts \\ []) when is_binary(id) do
    call({:get_job_run, id}, opts)
  end

  @spec list_job_runs(map(), keyword()) :: {:ok, [job_run_row()]} | {:error, term()}
  def list_job_runs(selector \\ %{}, opts \\ []) when is_map(selector) do
    call({:list_job_runs, selector, Keyword.get(opts, :limit, 20)}, opts)
  end

  @doc """
  Atomically admits a coding-harness run.

  Runs inside a single `BEGIN IMMEDIATE` transaction: it refuses when
  `max_active` active runs already exist (`{:error, :max_active}`) or when any
  active run already holds one of `attrs.lock_roots`
  (`{:error, {:workspace_locked, root}}`), otherwise inserts the row. The Repo
  is config-free: the caller (`FermixCore.Harness.Ledger`) reads `max_active`
  and passes it in.
  """
  @spec admit_harness_run(harness_run_attrs(), pos_integer(), keyword()) ::
          {:ok, harness_run_row()}
          | {:error, :max_active | {:workspace_locked, String.t()} | term()}
  def admit_harness_run(attrs, max_active, opts \\ [])
      when is_map(attrs) and is_integer(max_active) and max_active > 0 do
    call({:admit_harness_run, attrs, max_active}, opts)
  end

  @doc """
  Transitions an active run to a terminal `status`, setting `completed_at` and
  releasing its workspace locks (only active rows hold locks).

  Guarded on the current status still being active: a second terminalize of the
  same run returns `{:error, :already_terminal}`; an unknown id returns
  `{:error, :not_found}`.
  """
  @spec terminalize_harness_run(String.t(), String.t(), map(), keyword()) ::
          {:ok, harness_run_row()} | {:error, :already_terminal | :not_found | term()}
  def terminalize_harness_run(id, status, fields, opts \\ [])
      when is_binary(id) and is_binary(status) and is_map(fields) do
    call({:terminalize_harness_run, id, status, fields}, opts)
  end

  @spec update_harness_run(String.t(), map(), keyword()) ::
          {:ok, harness_run_row()} | {:error, :not_found | term()}
  def update_harness_run(id, fields, opts \\ [])
      when is_binary(id) and is_map(fields) and map_size(fields) > 0 do
    call({:update_harness_run, id, fields}, opts)
  end

  @doc """
  Transitions a local run `starting` → `running` on its first stream event via a
  single guarded UPDATE. A terminal or already-`running` row is left untouched
  (the current row is returned); an unknown id is `{:error, :not_found}`.
  """
  @spec mark_harness_run_running(String.t(), keyword()) ::
          {:ok, harness_run_row()} | {:error, :not_found | term()}
  def mark_harness_run_running(id, opts \\ []) when is_binary(id) do
    call({:mark_harness_run_running, id}, opts)
  end

  @doc """
  Transitions a cloud run `submitting` → `polling` once its task id lands, setting
  the poll schedule (`task_id`, `task_url`, `next_poll_at`, `poll_deadline`) in the
  same guarded UPDATE. A terminal or already-`polling` row is left untouched (its
  current state is returned, the poll fields NOT re-applied); an unknown id is
  `{:error, :not_found}`. Like `mark_harness_run_running/2`, this is a guarded
  status writer distinct from the generic update path (which rejects `:status`).
  """
  @spec promote_harness_run_polling(String.t(), map(), keyword()) ::
          {:ok, harness_run_row()} | {:error, :not_found | term()}
  def promote_harness_run_polling(id, fields, opts \\ [])
      when is_binary(id) and is_map(fields) do
    call({:promote_harness_run_polling, id, fields}, opts)
  end

  @spec get_harness_run(String.t(), keyword()) ::
          {:ok, harness_run_row()} | {:error, :not_found | term()}
  def get_harness_run(id, opts \\ []) when is_binary(id) do
    call({:get_harness_run, id}, opts)
  end

  @spec list_harness_runs(map(), keyword()) :: {:ok, [harness_run_row()]} | {:error, term()}
  def list_harness_runs(selector \\ %{}, opts \\ []) when is_map(selector) do
    call({:list_harness_runs, selector, Keyword.get(opts, :limit, 50)}, opts)
  end

  @spec active_harness_runs(keyword()) :: {:ok, [harness_run_row()]} | {:error, term()}
  def active_harness_runs(opts \\ []) do
    call(:active_harness_runs, opts)
  end

  @spec pending_harness_deliveries(DateTime.t(), keyword()) ::
          {:ok, [harness_run_row()]} | {:error, term()}
  def pending_harness_deliveries(%DateTime{} = now, opts \\ []) do
    call({:pending_harness_deliveries, now}, opts)
  end

  @spec upsert_memory_source(memory_source_attrs(), keyword()) ::
          {:ok, memory_source_row()} | {:error, term()}
  def upsert_memory_source(attrs, opts \\ []) when is_map(attrs) do
    call({:upsert_memory_source, attrs}, opts)
  end

  @spec get_memory_source(String.t(), keyword()) ::
          {:ok, memory_source_row()} | {:error, :not_found | term()}
  def get_memory_source(id, opts \\ []) when is_binary(id) do
    call({:get_memory_source, id}, opts)
  end

  @spec list_memory_sources(map(), keyword()) :: {:ok, [memory_source_row()]} | {:error, term()}
  def list_memory_sources(selector \\ %{}, opts \\ []) when is_map(selector) do
    call({:list_memory_sources, selector}, opts)
  end

  @spec migrate(keyword()) :: :ok | {:error, term()}
  def migrate(opts \\ []) do
    call(:migrate, opts)
  end

  @spec migration_versions(keyword()) :: {:ok, [integer()]} | {:error, term()}
  def migration_versions(opts \\ []) do
    call(:migration_versions, opts)
  end

  @spec journal_mode(keyword()) :: {:ok, String.t()} | {:error, term()}
  def journal_mode(opts \\ []) do
    call(:journal_mode, opts)
  end

  @impl true
  def init(opts) do
    enabled = Config.enabled?(opts)
    database_path = Config.database_path(opts)

    case open_connection(enabled, database_path) do
      {:ok, conn} ->
        {:ok, %{enabled: true, conn: conn, database_path: database_path}}

      :disabled ->
        {:ok, %{enabled: false, conn: nil, database_path: database_path}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{conn: nil}), do: :ok

  def terminate(_reason, %{conn: conn}) do
    case Sqlite3.close(conn) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  @impl true
  def handle_call(:enabled?, _from, state) do
    {:reply, state.enabled, state}
  end

  def handle_call(:migrate, _from, state) do
    {:reply, with_connection(state, &run_migrations/1), state}
  end

  def handle_call(:migration_versions, _from, state) do
    {:reply, with_connection(state, &migration_versions_for_conn/1), state}
  end

  def handle_call(:journal_mode, _from, state) do
    {:reply, with_connection(state, &journal_mode_for_conn/1), state}
  end

  def handle_call({:insert_message, attrs}, _from, state) do
    reply = with_connection(state, &insert_message_row(&1, attrs))
    {:reply, reply, state}
  end

  def handle_call({:get_messages, selector, limit}, _from, state) do
    reply = with_connection(state, &fetch_messages(&1, selector, limit))
    {:reply, reply, state}
  end

  def handle_call({:message_count, selector}, _from, state) do
    reply = with_connection(state, &count_messages(&1, selector))
    {:reply, reply, state}
  end

  def handle_call({:delete_messages, selector}, _from, state) do
    reply = with_connection(state, &delete_message_rows(&1, selector))
    {:reply, reply, state}
  end

  def handle_call({:upsert_memory, attrs}, _from, state) do
    reply = with_connection(state, &upsert_memory_row(&1, attrs))
    {:reply, reply, state}
  end

  def handle_call({:get_memory, selector}, _from, state) do
    reply = with_connection(state, &fetch_memory(&1, selector))
    {:reply, reply, state}
  end

  def handle_call({:get_memories, selector}, _from, state) do
    reply = with_connection(state, &fetch_memories(&1, selector))
    {:reply, reply, state}
  end

  def handle_call({:delete_memory, selector}, _from, state) do
    reply = with_connection(state, &delete_memory_row(&1, selector))
    {:reply, reply, state}
  end

  def handle_call({:delete_memories, selector}, _from, state) do
    reply = with_connection(state, &delete_memory_row(&1, selector))
    {:reply, reply, state}
  end

  def handle_call({:update_memory_value, selector, value}, _from, state) do
    reply = with_connection(state, &update_memory_value_row(&1, selector, value))
    {:reply, reply, state}
  end

  def handle_call({:archive_memory, selector, archived_by, reason, now}, _from, state) do
    reply = with_connection(state, &archive_memory_row(&1, selector, archived_by, reason, now))
    {:reply, reply, state}
  end

  def handle_call({:restore_memory, id}, _from, state) do
    reply = with_connection(state, &restore_memory_row(&1, id))
    {:reply, reply, state}
  end

  def handle_call({:search_memories, query, selector, limit}, _from, state) do
    reply = with_connection(state, &search_memory_rows(&1, query, selector, limit))
    {:reply, reply, state}
  end

  def handle_call({:search_messages, query, selector, limit}, _from, state) do
    reply = with_connection(state, &search_message_rows(&1, query, selector, limit))
    {:reply, reply, state}
  end

  def handle_call({:get_user_messages_after, selector, last_id, limit}, _from, state) do
    reply = with_connection(state, &fetch_user_messages_after(&1, selector, last_id, limit))
    {:reply, reply, state}
  end

  def handle_call({:list_review_conversations, selector}, _from, state) do
    reply = with_connection(state, &fetch_review_conversations(&1, selector))
    {:reply, reply, state}
  end

  def handle_call({:get_memory_review_state, selector}, _from, state) do
    reply = with_connection(state, &fetch_memory_review_state(&1, selector))
    {:reply, reply, state}
  end

  def handle_call({:claim_memory_review, selector, now, stale_after_ms}, _from, state) do
    reply = with_connection(state, &claim_memory_review_row(&1, selector, now, stale_after_ms))
    {:reply, reply, state}
  end

  def handle_call({:complete_memory_review, selector, status, last_id, now}, _from, state) do
    reply =
      with_connection(state, &complete_memory_review_row(&1, selector, status, last_id, now))

    {:reply, reply, state}
  end

  def handle_call({:fail_memory_review, selector, now}, _from, state) do
    reply = with_connection(state, &fail_memory_review_row(&1, selector, now))
    {:reply, reply, state}
  end

  def handle_call({:upsert_resource, attrs}, _from, state) do
    reply = with_connection(state, &upsert_resource_row(&1, attrs))
    {:reply, reply, state}
  end

  def handle_call({:get_resource, selector}, _from, state) do
    reply = with_connection(state, &fetch_resource(&1, selector))
    {:reply, reply, state}
  end

  def handle_call({:list_resources, selector}, _from, state) do
    reply = with_connection(state, &fetch_resources(&1, selector))
    {:reply, reply, state}
  end

  def handle_call({:insert_revision, attrs}, _from, state) do
    reply = with_connection(state, &insert_revision_row(&1, attrs))
    {:reply, reply, state}
  end

  def handle_call({:commit_resource_revision, attrs}, _from, state) do
    reply = with_connection(state, &commit_resource_revision_tx(&1, attrs))
    {:reply, reply, state}
  end

  def handle_call({:get_revision, selector}, _from, state) do
    reply = with_connection(state, &fetch_revision(&1, selector))
    {:reply, reply, state}
  end

  def handle_call({:get_latest_revision, selector}, _from, state) do
    reply = with_connection(state, &fetch_latest_revision(&1, selector))
    {:reply, reply, state}
  end

  def handle_call({:list_revisions, selector, limit, offset}, _from, state) do
    reply = with_connection(state, &fetch_revisions(&1, selector, limit, offset))
    {:reply, reply, state}
  end

  def handle_call({:revision_count, selector}, _from, state) do
    reply = with_connection(state, &count_revisions(&1, selector))
    {:reply, reply, state}
  end

  def handle_call({:create_job_with_source, job_attrs, source_attrs}, _from, state) do
    reply = with_connection(state, &create_job_with_source_tx(&1, job_attrs, source_attrs))
    {:reply, reply, state}
  end

  def handle_call({:due_scheduled_jobs, now, limit}, _from, state) do
    reply = with_connection(state, &fetch_due_scheduled_jobs(&1, now, limit))
    {:reply, reply, state}
  end

  def handle_call(:next_scheduled_job, _from, state) do
    reply = with_connection(state, &fetch_next_scheduled_job/1)
    {:reply, reply, state}
  end

  def handle_call({:claim_due_job, id, job_attrs, run_attrs, now}, _from, state) do
    reply = with_connection(state, &claim_due_job_tx(&1, id, job_attrs, run_attrs, now))
    {:reply, reply, state}
  end

  def handle_call({:claim_job_now, id, job_attrs, run_attrs}, _from, state) do
    reply = with_connection(state, &claim_job_now_tx(&1, id, job_attrs, run_attrs))
    {:reply, reply, state}
  end

  def handle_call({:upsert_scheduled_job, attrs}, _from, state) do
    reply = with_connection(state, &upsert_scheduled_job_row(&1, attrs))
    {:reply, reply, state}
  end

  def handle_call({:get_scheduled_job, id}, _from, state) do
    reply = with_connection(state, &fetch_scheduled_job(&1, id))
    {:reply, reply, state}
  end

  def handle_call({:list_scheduled_jobs, selector}, _from, state) do
    reply = with_connection(state, &fetch_scheduled_jobs(&1, selector))
    {:reply, reply, state}
  end

  def handle_call({:delete_scheduled_job, id}, _from, state) do
    reply = with_connection(state, &delete_scheduled_job_row(&1, id))
    {:reply, reply, state}
  end

  def handle_call({:delete_scheduled_job_if_idle, id}, _from, state) do
    reply = with_connection(state, &delete_scheduled_job_if_idle_tx(&1, id))
    {:reply, reply, state}
  end

  def handle_call({:upsert_job_run, attrs}, _from, state) do
    reply = with_connection(state, &upsert_job_run_row(&1, attrs))
    {:reply, reply, state}
  end

  def handle_call({:get_job_run, id}, _from, state) do
    reply = with_connection(state, &fetch_job_run(&1, id))
    {:reply, reply, state}
  end

  def handle_call({:list_job_runs, selector, limit}, _from, state) do
    reply = with_connection(state, &fetch_job_runs(&1, selector, limit))
    {:reply, reply, state}
  end

  def handle_call({:admit_harness_run, attrs, max_active}, _from, state) do
    reply = with_connection(state, &admit_harness_run_tx(&1, attrs, max_active))
    {:reply, reply, state}
  end

  def handle_call({:terminalize_harness_run, id, status, fields}, _from, state) do
    reply = with_connection(state, &terminalize_harness_run_row(&1, id, status, fields))
    {:reply, reply, state}
  end

  def handle_call({:update_harness_run, id, fields}, _from, state) do
    reply = with_connection(state, &update_harness_run_row(&1, id, fields))
    {:reply, reply, state}
  end

  def handle_call({:mark_harness_run_running, id}, _from, state) do
    reply = with_connection(state, &mark_harness_run_running_row(&1, id))
    {:reply, reply, state}
  end

  def handle_call({:promote_harness_run_polling, id, fields}, _from, state) do
    reply = with_connection(state, &promote_harness_run_polling_row(&1, id, fields))
    {:reply, reply, state}
  end

  def handle_call({:get_harness_run, id}, _from, state) do
    reply = with_connection(state, &fetch_harness_run(&1, id))
    {:reply, reply, state}
  end

  def handle_call({:list_harness_runs, selector, limit}, _from, state) do
    reply = with_connection(state, &fetch_harness_runs(&1, selector, limit))
    {:reply, reply, state}
  end

  def handle_call(:active_harness_runs, _from, state) do
    reply = with_connection(state, &fetch_active_harness_runs/1)
    {:reply, reply, state}
  end

  def handle_call({:pending_harness_deliveries, now}, _from, state) do
    reply = with_connection(state, &fetch_pending_harness_deliveries(&1, now))
    {:reply, reply, state}
  end

  def handle_call({:upsert_memory_source, attrs}, _from, state) do
    reply = with_connection(state, &upsert_memory_source_row(&1, attrs))
    {:reply, reply, state}
  end

  def handle_call({:get_memory_source, id}, _from, state) do
    reply = with_connection(state, &fetch_memory_source(&1, id))
    {:reply, reply, state}
  end

  def handle_call({:list_memory_sources, selector}, _from, state) do
    reply = with_connection(state, &fetch_memory_sources(&1, selector))
    {:reply, reply, state}
  end

  defp call(request, opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, request)
  end

  defp open_connection(false, _database_path), do: :disabled

  defp open_connection(true, database_path) do
    with :ok <- ensure_database_dir(database_path),
         {:ok, conn} <- Sqlite3.open(database_path, sqlite_open_opts(@sqlite_open_intent)),
         :ok <- configure_connection(conn),
         :ok <- run_migrations(conn) do
      {:ok, conn}
    end
  end

  defp sqlite_open_opts(:readwritecreate) do
    # Exqlite exposes SQLite READWRITE | CREATE as :readwrite.
    [mode: :readwrite]
  end

  defp ensure_database_dir(":memory:"), do: :ok

  defp ensure_database_dir(database_path) do
    database_path
    |> Path.dirname()
    |> File.mkdir_p()
  end

  defp configure_connection(conn) do
    Sqlite3.execute(
      conn,
      "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;"
    )
  end

  defp with_connection(%{enabled: false}, _fun), do: {:error, :disabled}
  defp with_connection(%{conn: conn}, fun), do: fun.(conn)

  defp run_migrations(conn) do
    with :ok <- ensure_schema_migrations_table(conn),
         {:ok, versions} <- migration_versions_for_conn(conn),
         :ok <- apply_base_migration(conn, versions),
         :ok <- apply_fts_migration(conn, versions),
         :ok <- apply_resource_migration(conn, versions),
         :ok <- apply_jobs_migration(conn, versions),
         :ok <- apply_job_expiry_migration(conn, versions),
         :ok <- apply_job_creator_trust_migration(conn, versions),
         :ok <- apply_trust_rename_migration(conn, versions),
         :ok <- apply_fermix_md_rename_migration(conn, versions),
         :ok <- apply_memory_review_migration(conn, versions),
         :ok <- apply_taxonomy_migration(conn, versions),
         :ok <- apply_trust_check_migration(conn, versions),
         :ok <- apply_harness_runs_migration(conn, versions),
         :ok <- apply_harness_continuation_migration(conn, versions),
         :ok <- apply_harness_client_origin_migration(conn, versions) do
      :ok
    end
  end

  defp ensure_schema_migrations_table(conn) do
    Sqlite3.execute(
      conn,
      """
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version INTEGER PRIMARY KEY,
        inserted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
      );
      """
    )
  end

  defp apply_base_migration(conn, versions) do
    if Enum.member?(versions, @base_migration_version) do
      :ok
    else
      Sqlite3.execute(
        conn,
        """
        BEGIN;
        #{@base_schema_sql}
        INSERT INTO schema_migrations(version) VALUES (#{@base_migration_version});
        COMMIT;
        """
      )
    end
  end

  defp apply_fts_migration(conn, versions) do
    if Enum.member?(versions, @fts_migration_version) do
      :ok
    else
      Sqlite3.execute(
        conn,
        """
        BEGIN;
        #{@fts_schema_sql}
        INSERT INTO memories_fts(memories_fts) VALUES('rebuild');
        INSERT INTO messages_fts(messages_fts) VALUES('rebuild');
        INSERT INTO schema_migrations(version) VALUES (#{@fts_migration_version});
        COMMIT;
        """
      )
    end
  end

  defp apply_resource_migration(conn, versions) do
    if Enum.member?(versions, @resource_migration_version) do
      :ok
    else
      Sqlite3.execute(
        conn,
        """
        BEGIN;
        #{@resource_schema_sql}
        INSERT INTO schema_migrations(version) VALUES (#{@resource_migration_version});
        COMMIT;
        """
      )
    end
  end

  defp jobs_schema_sql do
    default = Integer.to_string(IterationLimits.scheduled_job_default())
    String.replace(@jobs_schema_sql_template, "{{max_iterations_default}}", default)
  end

  defp apply_jobs_migration(conn, versions) do
    if Enum.member?(versions, @jobs_migration_version) do
      :ok
    else
      Sqlite3.execute(
        conn,
        """
        BEGIN;
        #{jobs_schema_sql()}
        INSERT INTO schema_migrations(version) VALUES (#{@jobs_migration_version});
        COMMIT;
        """
      )
    end
  end

  defp apply_job_expiry_migration(conn, versions) do
    if Enum.member?(versions, @job_expiry_migration_version) do
      :ok
    else
      Sqlite3.execute(
        conn,
        """
        BEGIN;
        #{@job_expiry_schema_sql}
        INSERT INTO schema_migrations(version) VALUES (#{@job_expiry_migration_version});
        COMMIT;
        """
      )
    end
  end

  defp apply_job_creator_trust_migration(conn, versions) do
    if Enum.member?(versions, @job_creator_trust_migration_version) do
      :ok
    else
      Sqlite3.execute(
        conn,
        """
        BEGIN;
        #{@job_creator_trust_schema_sql}
        INSERT INTO schema_migrations(version) VALUES (#{@job_creator_trust_migration_version});
        COMMIT;
        """
      )
    end
  end

  defp apply_trust_rename_migration(conn, versions) do
    if Enum.member?(versions, @trust_rename_migration_version) do
      :ok
    else
      Sqlite3.execute(
        conn,
        """
        BEGIN;
        #{@trust_rename_schema_sql}
        INSERT INTO schema_migrations(version) VALUES (#{@trust_rename_migration_version});
        COMMIT;
        """
      )
    end
  end

  defp apply_fermix_md_rename_migration(conn, versions) do
    if Enum.member?(versions, @fermix_md_rename_migration_version) do
      :ok
    else
      Sqlite3.execute(
        conn,
        """
        BEGIN;
        #{@fermix_md_rename_schema_sql}
        INSERT INTO schema_migrations(version) VALUES (#{@fermix_md_rename_migration_version});
        COMMIT;
        """
      )
    end
  end

  defp apply_memory_review_migration(conn, versions) do
    if Enum.member?(versions, @memory_review_migration_version) do
      :ok
    else
      Sqlite3.execute(
        conn,
        """
        BEGIN;
        #{@memory_review_schema_sql}
        INSERT INTO schema_migrations(version) VALUES (#{@memory_review_migration_version});
        COMMIT;
        """
      )
    end
  end

  defp apply_taxonomy_migration(conn, versions) do
    if Enum.member?(versions, @taxonomy_migration_version) do
      :ok
    else
      Sqlite3.execute(
        conn,
        """
        BEGIN;
        #{@taxonomy_schema_sql}
        INSERT INTO schema_migrations(version) VALUES (#{@taxonomy_migration_version});
        COMMIT;
        """
      )
    end
  end

  defp trust_check_schema_sql do
    default = Integer.to_string(IterationLimits.scheduled_job_default())
    String.replace(@trust_check_schema_sql_template, "{{max_iterations_default}}", default)
  end

  # The scheduled_jobs rebuild drops the parent of job_runs' foreign key, so
  # foreign keys are disabled around the transaction to prevent the implicit
  # DELETE from cascading. Toggled outside BEGIN/COMMIT — a PRAGMA is a no-op
  # inside a transaction. A migration failure stops the GenServer and discards
  # the connection, so a left-off pragma cannot leak to real traffic.
  defp apply_trust_check_migration(conn, versions) do
    if Enum.member?(versions, @trust_check_migration_version) do
      :ok
    else
      with :ok <- Sqlite3.execute(conn, "PRAGMA foreign_keys=OFF;"),
           :ok <-
             Sqlite3.execute(
               conn,
               """
               BEGIN;
               #{trust_check_schema_sql()}
               INSERT INTO schema_migrations(version) VALUES (#{@trust_check_migration_version});
               COMMIT;
               """
             ) do
        Sqlite3.execute(conn, "PRAGMA foreign_keys=ON;")
      end
    end
  end

  defp apply_harness_runs_migration(conn, versions) do
    if Enum.member?(versions, @harness_runs_migration_version) do
      :ok
    else
      Sqlite3.execute(
        conn,
        """
        BEGIN;
        #{@harness_runs_schema_sql}
        INSERT INTO schema_migrations(version) VALUES (#{@harness_runs_migration_version});
        COMMIT;
        """
      )
    end
  end

  defp apply_harness_continuation_migration(conn, versions) do
    if Enum.member?(versions, @harness_continuation_migration_version) do
      :ok
    else
      Sqlite3.execute(
        conn,
        """
        BEGIN;
        #{@harness_continuation_schema_sql}
        INSERT INTO schema_migrations(version) VALUES (#{@harness_continuation_migration_version});
        COMMIT;
        """
      )
    end
  end

  defp apply_harness_client_origin_migration(conn, versions) do
    if Enum.member?(versions, @harness_client_origin_migration_version) do
      :ok
    else
      Sqlite3.execute(
        conn,
        """
        BEGIN;
        #{@harness_client_origin_schema_sql}
        INSERT INTO schema_migrations(version) VALUES (#{@harness_client_origin_migration_version});
        COMMIT;
        """
      )
    end
  end

  defp migration_versions_for_conn(conn) do
    with {:ok, rows} <-
           query_all(conn, "SELECT version FROM schema_migrations ORDER BY version ASC", []),
         do: {:ok, Enum.map(rows, fn [version] -> version end)}
  end

  defp journal_mode_for_conn(conn) do
    with {:ok, [[mode]]} <- query_all(conn, "PRAGMA journal_mode", []) do
      {:ok, String.downcase(mode)}
    end
  end

  defp insert_message_row(conn, attrs) do
    message = normalize_message_attrs(attrs)

    with :ok <-
           execute(
             conn,
             """
             INSERT INTO messages (
               agent_id,
               owner_id,
               channel,
               chat_id,
               thread_scope,
               sender,
               role,
               kind,
               content,
               metadata_json,
               created_at
             )
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             """,
             message_insert_params(message)
           ),
         {:ok, [row]} <-
           query_all(conn, "SELECT * FROM messages WHERE id = last_insert_rowid()", []) do
      {:ok, message_row(row)}
    end
  end

  defp fetch_messages(conn, selector, limit) do
    with {:ok, {where_sql, params}} <- message_fetch_where_clause(selector),
         {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM messages
             WHERE #{where_sql}
             ORDER BY created_at DESC, id DESC
             LIMIT ?
             """,
             params ++ [limit]
           ) do
      {:ok, rows |> Enum.map(&message_row/1) |> Enum.reverse()}
    end
  end

  defp count_messages(conn, selector) do
    message_selector = normalize_message_selector(selector)

    with {:ok, [[count]]} <-
           query_all(
             conn,
             """
             SELECT COUNT(*)
             FROM messages
             WHERE agent_id = ? AND channel = ? AND chat_id = ? AND thread_scope = ?
             """,
             [
               message_selector.agent_id,
               message_selector.channel,
               message_selector.chat_id,
               message_selector.thread_scope
             ]
           ) do
      {:ok, count}
    end
  end

  defp delete_message_rows(conn, selector) do
    message_selector = normalize_message_selector(selector)

    execute(
      conn,
      """
      DELETE FROM messages
      WHERE agent_id = ? AND channel = ? AND chat_id = ? AND thread_scope = ?
      """,
      [
        message_selector.agent_id,
        message_selector.channel,
        message_selector.chat_id,
        message_selector.thread_scope
      ]
    )
  end

  defp upsert_memory_row(conn, attrs) do
    memory = normalize_memory_attrs(attrs)

    with :ok <-
           execute(
             conn,
             """
             INSERT INTO memories (
               agent_id,
               owner_id,
               scope_type,
               scope_id,
               category,
               key,
               value,
               confidence,
               promote_target,
               source_message_id,
               source_id,
               source_type,
               source_name,
               source_description,
               session_id,
               run_id,
               created_at,
               updated_at
             )
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(agent_id, owner_id, scope_type, scope_id, key)
             DO UPDATE SET
               category = excluded.category,
               value = excluded.value,
               confidence = excluded.confidence,
               promote_target = excluded.promote_target,
               source_message_id = excluded.source_message_id,
               source_id = excluded.source_id,
               source_type = excluded.source_type,
               source_name = excluded.source_name,
               source_description = excluded.source_description,
               session_id = excluded.session_id,
               run_id = excluded.run_id,
               archived_at = NULL,
               archived_by = NULL,
               archive_reason = NULL,
               updated_at = excluded.updated_at
             """,
             memory_insert_params(memory)
           ),
         {:ok, row} <- fetch_memory(conn, memory_lookup(memory)) do
      {:ok, row}
    end
  end

  defp fetch_memory(conn, selector) do
    {where_sql, params} = memory_where_clause(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM memories
             WHERE #{where_sql}
             ORDER BY updated_at DESC, id DESC
             LIMIT 1
             """,
             params
           ) do
      case rows do
        [row] -> {:ok, memory_row(row)}
        [] -> {:error, :not_found}
      end
    end
  end

  defp fetch_memories(conn, selector) do
    {where_sql, params} = memory_where_clause(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM memories
             WHERE #{where_sql}
             ORDER BY updated_at DESC, id DESC
             """,
             params
           ) do
      {:ok, Enum.map(rows, &memory_row/1)}
    end
  end

  defp delete_memory_row(conn, selector) do
    {where_sql, params} = memory_where_clause(selector)
    execute(conn, "DELETE FROM memories WHERE #{where_sql}", params)
  end

  defp update_memory_value_row(conn, selector, value) do
    {where_sql, params} = memory_where_clause(selector)
    now = timestamp_string(DateTime.utc_now())

    with :ok <-
           execute(
             conn,
             "UPDATE memories SET value = ?, updated_at = ? WHERE #{where_sql}",
             [value, now | params]
           ) do
      fetch_memory(conn, selector)
    end
  end

  defp archive_memory_row(conn, selector, archived_by, reason, now) do
    {where_sql, params} = memory_where_clause(selector)
    archived_at = timestamp_string(now)

    with :ok <-
           execute(
             conn,
             """
             UPDATE memories
             SET archived_at = ?, archived_by = ?, archive_reason = ?, updated_at = ?
             WHERE #{where_sql}
             """,
             [archived_at, archived_by, reason, archived_at | params]
           ) do
      fetch_memory(conn, Map.delete(selector, :archived?))
    end
  end

  defp restore_memory_row(conn, id) do
    now = timestamp_string(DateTime.utc_now())

    with :ok <-
           execute(
             conn,
             """
             UPDATE memories
             SET archived_at = NULL, archived_by = NULL, archive_reason = NULL, updated_at = ?
             WHERE id = ?
             """,
             [now, id]
           ) do
      fetch_memory(conn, %{id: id})
    end
  end

  defp fetch_user_messages_after(conn, selector, last_id, limit) do
    review_selector = normalize_memory_review_selector(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM messages
             WHERE agent_id = ?
               AND owner_id = ?
               AND channel = ?
               AND chat_id = ?
               AND thread_scope = ?
               AND role = 'user'
               AND id > ?
             ORDER BY id ASC
             LIMIT ?
             """,
             [
               review_selector.agent_id,
               review_selector.owner_id,
               review_selector.channel,
               review_selector.chat_id,
               review_selector.thread_scope,
               last_id,
               limit
             ]
           ) do
      {:ok, Enum.map(rows, &message_row/1)}
    end
  end

  defp fetch_review_conversations(conn, selector) do
    {where_sql, params} = review_conversation_where_clause(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT DISTINCT agent_id, owner_id, channel, chat_id, thread_scope
             FROM messages
             WHERE role = 'user' AND #{where_sql}
             ORDER BY agent_id ASC, owner_id ASC, channel ASC, chat_id ASC, thread_scope ASC
             """,
             params
           ) do
      {:ok, Enum.map(rows, &review_conversation_row/1)}
    end
  end

  defp fetch_memory_review_state(conn, selector) do
    review_selector = normalize_memory_review_selector(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM memory_review_state
             WHERE agent_id = ? AND owner_id = ? AND channel = ? AND chat_id = ? AND thread_scope = ?
             LIMIT 1
             """,
             memory_review_selector_params(review_selector)
           ) do
      case rows do
        [row] -> {:ok, memory_review_state_row(row)}
        [] -> {:error, :not_found}
      end
    end
  end

  defp claim_memory_review_row(conn, selector, now, stale_after_ms) do
    review_selector = normalize_memory_review_selector(selector)

    case fetch_memory_review_state(conn, review_selector) do
      {:ok, row} ->
        if active_review?(row, now, stale_after_ms) do
          {:error, :concurrent_run}
        else
          upsert_memory_review_started(conn, review_selector, row, now)
        end

      {:error, :not_found} ->
        upsert_memory_review_started(conn, review_selector, empty_review_state(), now)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp complete_memory_review_row(conn, selector, status, last_id, now) do
    review_selector = normalize_memory_review_selector(selector)
    now_string = timestamp_string(now)

    with :ok <-
           execute(
             conn,
             """
             UPDATE memory_review_state
             SET last_reviewed_message_id = ?,
                 last_reviewed_at = ?,
                 last_review_completed_at = ?,
                 last_review_status = ?,
                 last_review_failed_at = NULL,
                 failure_count = 0,
                 updated_at = ?
             WHERE agent_id = ? AND owner_id = ? AND channel = ? AND chat_id = ? AND thread_scope = ?
             """,
             [last_id, now_string, now_string, Atom.to_string(status), now_string] ++
               memory_review_selector_params(review_selector)
           ) do
      fetch_memory_review_state(conn, review_selector)
    end
  end

  defp fail_memory_review_row(conn, selector, now) do
    review_selector = normalize_memory_review_selector(selector)
    now_string = timestamp_string(now)

    with :ok <-
           execute(
             conn,
             """
             UPDATE memory_review_state
             SET last_review_status = 'failed',
                 last_review_failed_at = ?,
                 failure_count = failure_count + 1,
                 updated_at = ?
             WHERE agent_id = ? AND owner_id = ? AND channel = ? AND chat_id = ? AND thread_scope = ?
             """,
             [now_string, now_string] ++ memory_review_selector_params(review_selector)
           ) do
      fetch_memory_review_state(conn, review_selector)
    end
  end

  defp search_memory_rows(conn, query, selector, limit) do
    {where_sql, params} = search_memory_where_clause(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT
               memories.*,
               bm25(memories_fts) AS rank
             FROM memories_fts
             JOIN memories ON memories.id = memories_fts.rowid
             WHERE memories_fts MATCH ? AND #{where_sql}
             ORDER BY bm25(memories_fts), memories.updated_at DESC, memories.id DESC
             LIMIT ?
             """,
             [query | params] ++ [limit]
           ) do
      {:ok, Enum.map(rows, &memory_search_row/1)}
    end
  end

  defp search_message_rows(conn, query, selector, limit) do
    {where_sql, params} = message_where_clause(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT
               messages.*,
               bm25(messages_fts) AS rank
             FROM messages_fts
             JOIN messages ON messages.id = messages_fts.rowid
             WHERE messages_fts MATCH ? AND #{where_sql}
             ORDER BY bm25(messages_fts), messages.created_at DESC, messages.id DESC
             LIMIT ?
             """,
             [query | params] ++ [limit]
           ) do
      {:ok, Enum.map(rows, &message_search_row/1)}
    end
  end

  defp upsert_resource_row(conn, attrs) do
    resource = normalize_resource_attrs(attrs)

    with :ok <-
           execute(
             conn,
             """
             INSERT INTO resources (
               agent_id,
               resource_type,
               scope_id,
               resource_path,
               current_revision,
               updated_at
             )
             VALUES (?, ?, ?, ?, ?, ?)
             ON CONFLICT(agent_id, resource_type, scope_id)
             DO UPDATE SET
               resource_path = COALESCE(excluded.resource_path, resources.resource_path),
               current_revision = excluded.current_revision,
               updated_at = excluded.updated_at
             """,
             resource_upsert_params(resource)
           ),
         {:ok, row} <- fetch_resource(conn, resource_selector(resource)) do
      {:ok, row}
    end
  end

  defp fetch_resource(conn, selector) do
    resource = normalize_resource_selector(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM resources
             WHERE agent_id = ? AND resource_type = ? AND scope_id = ?
             LIMIT 1
             """,
             [resource.agent_id, resource.resource_type, resource.scope_id]
           ) do
      case rows do
        [row] -> {:ok, resource_row(row)}
        [] -> {:error, :not_found}
      end
    end
  end

  defp fetch_resources(conn, selector) do
    selector
    |> normalize_resource_list_selector()
    |> resource_list_query()
    |> then(fn {sql, params} ->
      with {:ok, rows} <- query_all(conn, sql, params) do
        {:ok, Enum.map(rows, &resource_row/1)}
      end
    end)
  end

  defp insert_revision_row(conn, attrs) do
    revision = normalize_revision_attrs(attrs)

    with :ok <-
           execute(
             conn,
             """
             INSERT INTO resource_revisions (
               agent_id,
               resource_type,
               scope_id,
               revision,
               parent_revision,
               content_hash,
               content,
               byte_size,
               mutation_source,
               provenance_json,
               created_at
             )
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             """,
             revision_insert_params(revision)
           ),
         {:ok, [row]} <-
           query_all(conn, "SELECT * FROM resource_revisions WHERE id = last_insert_rowid()", []) do
      {:ok, resource_revision_row(row)}
    end
  end

  defp commit_resource_revision_tx(conn, attrs) do
    revision = normalize_commit_revision_attrs(attrs)

    with :ok <- execute(conn, "BEGIN IMMEDIATE", []),
         result <- commit_resource_revision_in_tx(conn, revision),
         :ok <- finish_resource_commit(conn, result) do
      result
    else
      {:error, :busy} -> {:error, :busy}
      {:error, reason} -> rollback_resource_commit(conn, reason)
    end
  end

  defp commit_resource_revision_in_tx(conn, revision) do
    with {:ok, current} <- fetch_resource_current(conn, revision),
         false <- current.content_hash == revision.content_hash,
         attrs <- revision_attrs_for_commit(revision, current),
         {:ok, inserted} <- insert_revision_row(conn, attrs),
         {:ok, _resource} <-
           upsert_resource_row(conn, resource_attrs_for_commit(revision, inserted)) do
      {:ok, inserted}
    else
      true -> {:ok, :unchanged}
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish_resource_commit(conn, {:ok, _result}) do
    execute(conn, "COMMIT", [])
  end

  defp finish_resource_commit(_conn, {:error, reason}), do: {:error, reason}

  defp rollback_resource_commit(conn, reason) do
    _rollback_result = execute(conn, "ROLLBACK", [])
    {:error, reason}
  end

  defp fetch_resource_current(conn, selector) do
    resource = normalize_resource_selector(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT resources.current_revision, resource_revisions.content_hash
             FROM resources
             LEFT JOIN resource_revisions
               ON resource_revisions.agent_id = resources.agent_id
              AND resource_revisions.resource_type = resources.resource_type
              AND resource_revisions.scope_id = resources.scope_id
              AND resource_revisions.revision = resources.current_revision
             WHERE resources.agent_id = ?
               AND resources.resource_type = ?
               AND resources.scope_id = ?
             LIMIT 1
             """,
             [resource.agent_id, resource.resource_type, resource.scope_id]
           ) do
      case rows do
        [[current_revision, content_hash]] ->
          {:ok, %{current_revision: current_revision, content_hash: content_hash}}

        [] ->
          {:ok, %{current_revision: 0, content_hash: nil}}
      end
    end
  end

  defp fetch_revision(conn, selector) do
    revision = normalize_revision_selector(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM resource_revisions
             WHERE agent_id = ? AND resource_type = ? AND scope_id = ? AND revision = ?
             LIMIT 1
             """,
             [revision.agent_id, revision.resource_type, revision.scope_id, revision.revision]
           ) do
      case rows do
        [row] -> {:ok, resource_revision_row(row)}
        [] -> {:error, :not_found}
      end
    end
  end

  defp fetch_latest_revision(conn, selector) do
    resource = normalize_resource_selector(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM resource_revisions
             WHERE agent_id = ? AND resource_type = ? AND scope_id = ?
             ORDER BY revision DESC
             LIMIT 1
             """,
             [resource.agent_id, resource.resource_type, resource.scope_id]
           ) do
      case rows do
        [row] -> {:ok, resource_revision_row(row)}
        [] -> {:error, :not_found}
      end
    end
  end

  defp fetch_revisions(conn, selector, limit, offset) do
    resource = normalize_resource_selector(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM resource_revisions
             WHERE agent_id = ? AND resource_type = ? AND scope_id = ?
             ORDER BY revision DESC
             LIMIT ? OFFSET ?
             """,
             [resource.agent_id, resource.resource_type, resource.scope_id, limit, offset]
           ) do
      {:ok, Enum.map(rows, &resource_revision_row/1)}
    end
  end

  defp count_revisions(conn, selector) do
    resource = normalize_resource_selector(selector)

    with {:ok, [[count]]} <-
           query_all(
             conn,
             """
             SELECT COUNT(*)
             FROM resource_revisions
             WHERE agent_id = ? AND resource_type = ? AND scope_id = ?
             """,
             [resource.agent_id, resource.resource_type, resource.scope_id]
           ) do
      {:ok, count}
    end
  end

  defp create_job_with_source_tx(conn, job_attrs, source_attrs) do
    with :ok <- execute(conn, "BEGIN IMMEDIATE", []),
         result <- create_job_with_source_in_tx(conn, job_attrs, source_attrs),
         :ok <- finish_job_create(conn, result) do
      result
    else
      {:error, :busy} -> {:error, :busy}
      {:error, reason} -> rollback_job_create(conn, reason)
    end
  end

  defp create_job_with_source_in_tx(conn, job_attrs, source_attrs) do
    with {:ok, _source} <- upsert_memory_source_row(conn, source_attrs),
         {:ok, job} <- upsert_scheduled_job_row(conn, job_attrs) do
      {:ok, job}
    end
  end

  defp finish_job_create(conn, {:ok, _job}) do
    execute(conn, "COMMIT", [])
  end

  defp finish_job_create(_conn, {:error, reason}), do: {:error, reason}

  defp rollback_job_create(conn, reason) do
    _rollback_result = execute(conn, "ROLLBACK", [])
    {:error, reason}
  end

  defp fetch_due_scheduled_jobs(conn, now, limit) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM scheduled_jobs
             WHERE enabled = 1
               AND state = 'scheduled'
               AND (
                 (next_run_at IS NOT NULL AND next_run_at <= ?)
                 OR (expires_at IS NOT NULL AND expires_at <= ?)
               )
             ORDER BY
               CASE
                 WHEN next_run_at IS NULL THEN expires_at
                 WHEN expires_at IS NULL THEN next_run_at
                 WHEN expires_at < next_run_at THEN expires_at
                 ELSE next_run_at
               END ASC,
               id ASC
             LIMIT ?
             """,
             [timestamp_string(now), timestamp_string(now), limit]
           ) do
      {:ok, Enum.map(rows, &scheduled_job_row/1)}
    end
  end

  defp fetch_next_scheduled_job(conn) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM scheduled_jobs
             WHERE enabled = 1
               AND state = 'scheduled'
               AND (next_run_at IS NOT NULL OR expires_at IS NOT NULL)
             ORDER BY
               CASE
                 WHEN next_run_at IS NULL THEN expires_at
                 WHEN expires_at IS NULL THEN next_run_at
                 WHEN expires_at < next_run_at THEN expires_at
                 ELSE next_run_at
               END ASC,
               id ASC
             LIMIT 1
             """,
             []
           ) do
      case rows do
        [row] -> {:ok, scheduled_job_row(row)}
        [] -> {:ok, nil}
      end
    end
  end

  defp claim_due_job_tx(conn, id, job_attrs, run_attrs, now) do
    transact_claim(conn, fn ->
      claim_in_tx(conn, id, job_attrs, run_attrs, fetch_claimable_due_job(conn, id, now))
    end)
  end

  # A manual ("run now") claim is identical to a due claim except it skips the
  # due-time gate — the same single-flight guard and atomic upserts still apply.
  defp claim_job_now_tx(conn, id, job_attrs, run_attrs) do
    transact_claim(conn, fn ->
      claim_in_tx(conn, id, job_attrs, run_attrs, fetch_claimable_job(conn, id))
    end)
  end

  defp transact_claim(conn, claim_fun) do
    with :ok <- execute(conn, "BEGIN IMMEDIATE", []),
         result <- claim_fun.(),
         :ok <- finish_job_claim(conn, result) do
      result
    else
      {:error, :busy} -> {:error, :busy}
      {:error, reason} -> rollback_job_claim(conn, reason)
    end
  end

  defp claim_in_tx(conn, id, job_attrs, run_attrs, fetch_result) do
    with {:ok, job} <- fetch_result,
         :ok <- ensure_no_active_job_run(conn, id),
         {:ok, claimed_job} <- upsert_scheduled_job_row(conn, Map.merge(job, job_attrs)),
         {:ok, run} <- upsert_job_run_row(conn, run_attrs) do
      {:ok, {claimed_job, run}}
    end
  end

  defp fetch_claimable_due_job(conn, id, now) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM scheduled_jobs
             WHERE id = ?
               AND enabled = 1
               AND state = 'scheduled'
               AND (
                 (next_run_at IS NOT NULL AND next_run_at <= ?)
                 OR (expires_at IS NOT NULL AND expires_at <= ?)
               )
             LIMIT 1
             """,
             [id, timestamp_string(now), timestamp_string(now)]
           ) do
      case rows do
        [row] -> {:ok, scheduled_job_row(row)}
        [] -> {:error, :not_due}
      end
    end
  end

  defp fetch_claimable_job(conn, id) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM scheduled_jobs
             WHERE id = ?
               AND enabled = 1
               AND state = 'scheduled'
             LIMIT 1
             """,
             [id]
           ) do
      case rows do
        [row] -> {:ok, scheduled_job_row(row)}
        [] -> {:error, :not_runnable}
      end
    end
  end

  defp ensure_no_active_job_run(conn, id) do
    with {:ok, [[count]]} <-
           query_all(
             conn,
             """
             SELECT COUNT(*)
             FROM job_runs
             WHERE job_id = ?
               AND status IN ('queued', 'running')
             """,
             [id]
           ) do
      if count == 0 do
        :ok
      else
        {:error, :already_running}
      end
    end
  end

  defp finish_job_claim(conn, {:ok, {_job, _run}}) do
    execute(conn, "COMMIT", [])
  end

  defp finish_job_claim(_conn, {:error, reason}), do: {:error, reason}

  defp rollback_job_claim(conn, reason) do
    _rollback_result = execute(conn, "ROLLBACK", [])
    {:error, reason}
  end

  defp delete_scheduled_job_if_idle_tx(conn, id) do
    with :ok <- execute(conn, "BEGIN IMMEDIATE", []),
         result <- delete_scheduled_job_if_idle_in_tx(conn, id),
         :ok <- finish_scheduled_job_delete(conn, result) do
      result
    else
      {:error, :busy} -> {:error, :busy}
      {:error, reason} -> rollback_scheduled_job_delete(conn, reason)
    end
  end

  defp delete_scheduled_job_if_idle_in_tx(conn, id) do
    with {:ok, _job} <- fetch_scheduled_job(conn, id),
         :ok <- ensure_job_idle_for_delete(conn, id) do
      delete_scheduled_job_row(conn, id)
    end
  end

  defp ensure_job_idle_for_delete(conn, id) do
    case ensure_no_active_job_run(conn, id) do
      :ok -> :ok
      {:error, :already_running} -> {:error, :job_running}
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish_scheduled_job_delete(conn, :ok) do
    execute(conn, "COMMIT", [])
  end

  defp finish_scheduled_job_delete(_conn, {:error, reason}), do: {:error, reason}

  defp rollback_scheduled_job_delete(conn, reason) do
    _rollback_result = execute(conn, "ROLLBACK", [])
    {:error, reason}
  end

  defp upsert_scheduled_job_row(conn, attrs) do
    job = normalize_scheduled_job_attrs(attrs)

    with :ok <-
           execute(
             conn,
             """
             INSERT INTO scheduled_jobs (
               id,
               name,
               description,
               schedule_kind,
               schedule_expr,
               timezone,
               next_run_at,
               task_prompt,
               skill_name,
               session_mode,
               provider,
               model,
               max_iterations,
               timeout_seconds,
               inactivity_timeout_seconds,
               capability_policy_json,
               allowed_tools_json,
               memory_source_id,
               memory_read_scopes_json,
               memory_write_scope,
               main_visible,
               delivery_mode,
               delivery_target_json,
               silent_marker,
               enabled,
               state,
               last_run_at,
               last_status,
               last_error,
               created_by_agent_id,
               created_by_session_id,
               expires_at,
               created_by_channel,
               created_by_trust,
               created_at,
               updated_at
             )
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(id)
             DO UPDATE SET
               name = excluded.name,
               description = excluded.description,
               schedule_kind = excluded.schedule_kind,
               schedule_expr = excluded.schedule_expr,
               timezone = excluded.timezone,
               next_run_at = excluded.next_run_at,
               task_prompt = excluded.task_prompt,
               skill_name = excluded.skill_name,
               session_mode = excluded.session_mode,
               provider = excluded.provider,
               model = excluded.model,
               max_iterations = excluded.max_iterations,
               timeout_seconds = excluded.timeout_seconds,
               inactivity_timeout_seconds = excluded.inactivity_timeout_seconds,
               capability_policy_json = excluded.capability_policy_json,
               allowed_tools_json = excluded.allowed_tools_json,
               memory_source_id = excluded.memory_source_id,
               memory_read_scopes_json = excluded.memory_read_scopes_json,
               memory_write_scope = excluded.memory_write_scope,
               main_visible = excluded.main_visible,
               delivery_mode = excluded.delivery_mode,
               delivery_target_json = excluded.delivery_target_json,
               silent_marker = excluded.silent_marker,
               enabled = excluded.enabled,
               state = excluded.state,
               last_run_at = excluded.last_run_at,
               last_status = excluded.last_status,
               last_error = excluded.last_error,
               created_by_agent_id = excluded.created_by_agent_id,
               created_by_session_id = excluded.created_by_session_id,
               expires_at = excluded.expires_at,
               created_by_channel = excluded.created_by_channel,
               created_by_trust = excluded.created_by_trust,
               updated_at = excluded.updated_at
             """,
             scheduled_job_upsert_params(job)
           ),
         {:ok, row} <- fetch_scheduled_job(conn, job.id) do
      {:ok, row}
    end
  end

  defp fetch_scheduled_job(conn, id) do
    with {:ok, rows} <-
           query_all(
             conn,
             "SELECT * FROM scheduled_jobs WHERE id = ? LIMIT 1",
             [id]
           ) do
      case rows do
        [row] -> {:ok, scheduled_job_row(row)}
        [] -> {:error, :not_found}
      end
    end
  end

  defp fetch_scheduled_jobs(conn, selector) do
    {where_sql, params} = scheduled_job_where_clause(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM scheduled_jobs
             WHERE #{where_sql}
             ORDER BY created_at DESC, id ASC
             """,
             params
           ) do
      {:ok, Enum.map(rows, &scheduled_job_row/1)}
    end
  end

  defp delete_scheduled_job_row(conn, id) do
    execute(conn, "DELETE FROM scheduled_jobs WHERE id = ?", [id])
  end

  defp upsert_job_run_row(conn, attrs) do
    run = normalize_job_run_attrs(attrs)

    with :ok <-
           execute(
             conn,
             """
             INSERT INTO job_runs (
               id,
               job_id,
               session_id,
               trigger,
               status,
               claimed_at,
               started_at,
               completed_at,
               prompt_snapshot,
               job_config_snapshot_json,
               capability_policy_snapshot_json,
               output_ref,
               final_response,
               error,
               delivery_status,
               delivery_error,
               iterations,
               token_usage_json,
               latency_json,
               created_at,
               updated_at
             )
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(id)
             DO UPDATE SET
               job_id = excluded.job_id,
               session_id = excluded.session_id,
               trigger = excluded.trigger,
               status = excluded.status,
               claimed_at = excluded.claimed_at,
               started_at = excluded.started_at,
               completed_at = excluded.completed_at,
               prompt_snapshot = excluded.prompt_snapshot,
               job_config_snapshot_json = excluded.job_config_snapshot_json,
               capability_policy_snapshot_json = excluded.capability_policy_snapshot_json,
               output_ref = excluded.output_ref,
               final_response = excluded.final_response,
               error = excluded.error,
               delivery_status = excluded.delivery_status,
               delivery_error = excluded.delivery_error,
               iterations = excluded.iterations,
               token_usage_json = excluded.token_usage_json,
               latency_json = excluded.latency_json,
               updated_at = excluded.updated_at
             """,
             job_run_upsert_params(run)
           ),
         {:ok, row} <- fetch_job_run(conn, run.id) do
      {:ok, row}
    end
  end

  defp fetch_job_run(conn, id) do
    with {:ok, rows} <- query_all(conn, "SELECT * FROM job_runs WHERE id = ? LIMIT 1", [id]) do
      case rows do
        [row] -> {:ok, job_run_row(row)}
        [] -> {:error, :not_found}
      end
    end
  end

  defp fetch_job_runs(conn, selector, limit) do
    {where_sql, params} = job_run_where_clause(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM job_runs
             WHERE #{where_sql}
             ORDER BY created_at DESC, id ASC
             LIMIT ?
             """,
             params ++ [limit]
           ) do
      {:ok, Enum.map(rows, &job_run_row/1)}
    end
  end

  # Atomic admission: BEGIN IMMEDIATE -> capacity gate -> lock gate -> INSERT ->
  # COMMIT. Mirrors `transact_claim/2`; a `:busy` on BEGIN never opened the tx so
  # it passes through without a ROLLBACK, every other error rolls back.
  defp admit_harness_run_tx(conn, attrs, max_active) do
    run = normalize_harness_run_attrs(attrs)

    with :ok <- execute(conn, "BEGIN IMMEDIATE", []),
         result <- admit_harness_run_in_tx(conn, run, max_active),
         :ok <- finish_harness_admit(conn, result) do
      result
    else
      {:error, :busy} -> {:error, :busy}
      {:error, reason} -> rollback_harness_admit(conn, reason)
    end
  end

  defp admit_harness_run_in_tx(conn, run, max_active) do
    with :ok <- ensure_harness_capacity(conn, max_active),
         :ok <- ensure_harness_lock_free(conn, run.lock_roots) do
      insert_harness_run_row(conn, run)
    end
  end

  defp ensure_harness_capacity(conn, max_active) do
    with {:ok, [[count]]} <-
           query_all(
             conn,
             "SELECT COUNT(*) FROM harness_runs WHERE status IN (#{@harness_active_status_sql})",
             []
           ) do
      if count < max_active, do: :ok, else: {:error, :max_active}
    end
  end

  defp ensure_harness_lock_free(conn, lock_roots) do
    with {:ok, rows} <-
           query_all(
             conn,
             "SELECT lock_roots_json FROM harness_runs WHERE status IN (#{@harness_active_status_sql})",
             []
           ) do
      held = Enum.flat_map(rows, fn [json] -> Jason.decode!(json) end)
      harness_lock_conflict(lock_roots, held)
    end
  end

  defp harness_lock_conflict(lock_roots, held) do
    case Enum.find(lock_roots, fn root -> root in held end) do
      nil -> :ok
      root -> {:error, {:workspace_locked, root}}
    end
  end

  defp finish_harness_admit(conn, {:ok, _run}), do: execute(conn, "COMMIT", [])
  defp finish_harness_admit(_conn, {:error, reason}), do: {:error, reason}

  defp rollback_harness_admit(conn, reason) do
    _rollback_result = execute(conn, "ROLLBACK", [])
    {:error, reason}
  end

  defp insert_harness_run_row(conn, run) do
    with :ok <-
           execute(
             conn,
             """
             INSERT INTO harness_runs (
               id,
               vendor,
               rail,
               status,
               reason,
               cwd,
               worktree_root,
               lock_roots_json,
               artifacts_dir,
               resumable,
               vendor_session_id,
               exit_code,
               framing_errors,
               artifact_truncated,
               usage_json,
               diagnostics_tail,
               origin_kind,
               origin_session_id,
               parent_job_id,
               delivery_mode,
               platform,
               destination,
               thread,
               send_opts_json,
               delivery_status,
               delivery_attempts,
               next_delivery_at,
               last_delivery_error,
               task_id,
               task_url,
               next_poll_at,
               poll_deadline,
               created_at,
               started_at,
               first_event_at,
               last_event_at,
               completed_at,
               delivered_at,
               continuation_depth,
               client_origin_json
             )
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             """,
             harness_run_insert_params(run)
           ),
         {:ok, row} <- fetch_harness_run(conn, run.id) do
      {:ok, row}
    end
  end

  # Terminal transition: a single guarded UPDATE (`WHERE status IN active`) so a
  # re-terminalize touches zero rows. `Sqlite3.changes/1` after the UPDATE tells
  # a real transition (1) from a rejected one (0), which is then classified as
  # `:not_found` vs `:already_terminal`.
  defp terminalize_harness_run_row(conn, id, status, fields) do
    # `status` is written here and nowhere else (it is not in the generic
    # updatable-column allowlist). Prepend it to the set clause so the terminal
    # transition is the single status writer; `completed_at` defaults to now.
    set_fields = Map.put_new(fields, :completed_at, DateTime.utc_now())
    {set_sql, params} = harness_run_set_clause(set_fields)

    with :ok <-
           execute(
             conn,
             "UPDATE harness_runs SET status = ?, #{set_sql} " <>
               "WHERE id = ? AND status IN (#{@harness_active_status_sql})",
             [status | params] ++ [id]
           ) do
      interpret_harness_terminalize(conn, id)
    end
  end

  defp interpret_harness_terminalize(conn, id) do
    case Sqlite3.changes(conn) do
      {:ok, 1} -> fetch_harness_run(conn, id)
      {:ok, 0} -> harness_terminalize_rejection(conn, id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp harness_terminalize_rejection(conn, id) do
    case fetch_harness_run(conn, id) do
      {:ok, _row} -> {:error, :already_terminal}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # `status` transitions only through `terminalize_harness_run_row/4` (the single
  # guarded writer). The generic update path must never carry `:status`, or a
  # terminal row could be silently resurrected to an active status — re-acquiring
  # a phantom workspace lock and capacity outside admission.
  defp update_harness_run_row(_conn, _id, %{status: _status}) do
    {:error, :status_not_updatable}
  end

  defp update_harness_run_row(conn, id, fields) do
    {set_sql, params} = harness_run_set_clause(fields)

    with :ok <-
           execute(conn, "UPDATE harness_runs SET #{set_sql} WHERE id = ?", params ++ [id]) do
      fetch_harness_run(conn, id)
    end
  end

  # `starting` → `running` on first event: a single guarded UPDATE so a terminal
  # or already-`running` row is never resurrected to an active status out of band.
  # `status` is written only here and in `terminalize_harness_run_row/4` (the
  # generic update path rejects it). The row is fetched regardless of whether the
  # guard matched, so a no-op flip returns the current row rather than an error.
  defp mark_harness_run_running_row(conn, id) do
    with :ok <-
           execute(
             conn,
             "UPDATE harness_runs SET status = 'running' WHERE id = ? AND status = 'starting'",
             [id]
           ) do
      fetch_harness_run(conn, id)
    end
  end

  # `submitting` → `polling` once the task id lands: a single guarded UPDATE
  # prepending the status assignment (the single-status-writer discipline, like
  # `mark_harness_run_running_row/2`) and setting the poll schedule in the same
  # statement. `status` is written only here, in `mark_harness_run_running_row/2`,
  # and in `terminalize_harness_run_row/4`; the generic update path rejects it. The
  # row is fetched regardless of the guard so a no-op flip returns the current row.
  defp promote_harness_run_polling_row(conn, id, fields) do
    {set_sql, params} = harness_run_set_clause(fields)

    with :ok <-
           execute(
             conn,
             "UPDATE harness_runs SET status = 'polling', #{set_sql} " <>
               "WHERE id = ? AND status = 'submitting'",
             params ++ [id]
           ) do
      fetch_harness_run(conn, id)
    end
  end

  defp fetch_harness_run(conn, id) do
    with {:ok, rows} <- query_all(conn, "SELECT * FROM harness_runs WHERE id = ? LIMIT 1", [id]) do
      case rows do
        [row] -> {:ok, harness_run_row(row)}
        [] -> {:error, :not_found}
      end
    end
  end

  defp fetch_harness_runs(conn, selector, limit) do
    {where_sql, params} = harness_run_where_clause(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM harness_runs
             WHERE #{where_sql}
             ORDER BY created_at DESC, id ASC
             LIMIT ?
             """,
             params ++ [limit]
           ) do
      {:ok, Enum.map(rows, &harness_run_row/1)}
    end
  end

  defp fetch_active_harness_runs(conn) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM harness_runs
             WHERE status IN (#{@harness_active_status_sql})
             ORDER BY created_at ASC, id ASC
             """,
             []
           ) do
      {:ok, Enum.map(rows, &harness_run_row/1)}
    end
  end

  defp fetch_pending_harness_deliveries(conn, now) do
    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM harness_runs
             WHERE delivery_status = 'pending'
               AND status NOT IN (#{@harness_active_status_sql})
               AND (next_delivery_at IS NULL OR next_delivery_at <= ?)
             ORDER BY created_at ASC, id ASC
             """,
             [timestamp_string(now)]
           ) do
      {:ok, Enum.map(rows, &harness_run_row/1)}
    end
  end

  defp upsert_memory_source_row(conn, attrs) do
    source = normalize_memory_source_attrs(attrs)

    with :ok <-
           execute(
             conn,
             """
             INSERT INTO memory_sources (
               id,
               source_type,
               name,
               description,
               owner_agent_id,
               visibility,
               schedule_summary,
               status,
               last_run_at,
               last_status,
               memory_scope,
               output_scope,
               metadata_json,
               created_at,
               updated_at
             )
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(id)
             DO UPDATE SET
               source_type = excluded.source_type,
               name = excluded.name,
               description = excluded.description,
               owner_agent_id = excluded.owner_agent_id,
               visibility = excluded.visibility,
               schedule_summary = excluded.schedule_summary,
               status = excluded.status,
               last_run_at = excluded.last_run_at,
               last_status = excluded.last_status,
               memory_scope = excluded.memory_scope,
               output_scope = excluded.output_scope,
               metadata_json = excluded.metadata_json,
               updated_at = excluded.updated_at
             """,
             memory_source_upsert_params(source)
           ),
         {:ok, row} <- fetch_memory_source(conn, source.id) do
      {:ok, row}
    end
  end

  defp fetch_memory_source(conn, id) do
    with {:ok, rows} <-
           query_all(conn, "SELECT * FROM memory_sources WHERE id = ? LIMIT 1", [id]) do
      case rows do
        [row] -> {:ok, memory_source_row(row)}
        [] -> {:error, :not_found}
      end
    end
  end

  defp fetch_memory_sources(conn, selector) do
    {where_sql, params} = memory_source_where_clause(selector)

    with {:ok, rows} <-
           query_all(
             conn,
             """
             SELECT *
             FROM memory_sources
             WHERE #{where_sql}
             ORDER BY source_type ASC, name ASC, id ASC
             """,
             params
           ) do
      {:ok, Enum.map(rows, &memory_source_row/1)}
    end
  end

  defp query_all(conn, sql, params) do
    with_statement(conn, sql, fn stmt ->
      with :ok <- bind(stmt, params),
           {:ok, rows} <- Sqlite3.fetch_all(conn, stmt) do
        {:ok, rows}
      end
    end)
  end

  defp execute(conn, sql, params) do
    with_statement(conn, sql, fn stmt ->
      with :ok <- bind(stmt, params),
           result <- Sqlite3.step(conn, stmt) do
        step_result(result)
      end
    end)
  end

  defp bind(_stmt, []), do: :ok
  defp bind(stmt, params), do: Sqlite3.bind(stmt, params)

  defp step_result(:done), do: :ok
  defp step_result(:busy), do: {:error, :busy}
  defp step_result({:row, _row}), do: :ok
  defp step_result({:error, reason}), do: {:error, reason}

  defp with_statement(conn, sql, fun) do
    case Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        result = fun.(stmt)

        case Sqlite3.release(conn, stmt) do
          :ok -> result
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_message_attrs(attrs) do
    %{
      agent_id: fetch_string!(attrs, :agent_id),
      owner_id: fetch_string!(attrs, :owner_id),
      channel: fetch_string!(attrs, :channel),
      chat_id: fetch_string!(attrs, :chat_id),
      thread_scope: Scope.normalize_thread_scope(Map.fetch!(attrs, :thread_scope)),
      sender: fetch_string!(attrs, :sender),
      role: fetch_string!(attrs, :role),
      kind: fetch_string!(attrs, :kind),
      content: fetch_string!(attrs, :content),
      metadata: Map.get(attrs, :metadata),
      created_at: timestamp_string(Map.get(attrs, :created_at, DateTime.utc_now()))
    }
  end

  defp normalize_memory_attrs(attrs) do
    %{
      agent_id: fetch_string!(attrs, :agent_id),
      owner_id: fetch_string!(attrs, :owner_id),
      scope_type: fetch_string!(attrs, :scope_type),
      scope_id: fetch_string!(attrs, :scope_id),
      category: fetch_string!(attrs, :category),
      key: fetch_string!(attrs, :key),
      value: fetch_string!(attrs, :value),
      confidence: Map.get(attrs, :confidence, 1.0),
      promote_target: Map.get(attrs, :promote_target, "none"),
      source_message_id: Map.get(attrs, :source_message_id),
      source_id: optional_string!(attrs, :source_id),
      source_type: optional_string!(attrs, :source_type),
      source_name: optional_string!(attrs, :source_name),
      source_description: optional_string!(attrs, :source_description),
      session_id: optional_string!(attrs, :session_id),
      run_id: optional_string!(attrs, :run_id),
      created_at: timestamp_string(Map.get(attrs, :created_at, DateTime.utc_now())),
      updated_at: timestamp_string(Map.get(attrs, :updated_at, DateTime.utc_now()))
    }
  end

  defp normalize_resource_attrs(attrs) do
    %{
      agent_id: fetch_string!(attrs, :agent_id),
      resource_type: fetch_string!(attrs, :resource_type),
      scope_id: fetch_string!(attrs, :scope_id),
      resource_path: optional_string!(attrs, :resource_path),
      current_revision: fetch_non_negative_integer!(attrs, :current_revision),
      updated_at: timestamp_string(Map.get(attrs, :updated_at, DateTime.utc_now()))
    }
  end

  defp normalize_resource_selector(selector) do
    %{
      agent_id: fetch_string!(selector, :agent_id),
      resource_type: fetch_string!(selector, :resource_type),
      scope_id: fetch_string!(selector, :scope_id)
    }
  end

  defp normalize_resource_list_selector(selector) do
    selector
    |> Map.take([:agent_id])
    |> Enum.into(%{}, fn {key, value} -> {key, fetch_string_value!(key, value)} end)
  end

  defp normalize_revision_attrs(attrs) do
    %{
      agent_id: fetch_string!(attrs, :agent_id),
      resource_type: fetch_string!(attrs, :resource_type),
      scope_id: fetch_string!(attrs, :scope_id),
      revision: fetch_positive_integer!(attrs, :revision),
      parent_revision: optional_positive_integer!(attrs, :parent_revision),
      content_hash: fetch_string!(attrs, :content_hash),
      content: fetch_string!(attrs, :content),
      byte_size: fetch_non_negative_integer!(attrs, :byte_size),
      mutation_source: fetch_string!(attrs, :mutation_source),
      provenance: Map.get(attrs, :provenance),
      created_at: timestamp_string(Map.get(attrs, :created_at, DateTime.utc_now()))
    }
  end

  defp normalize_scheduled_job_attrs(attrs) do
    %{
      id: fetch_string!(attrs, :id),
      name: fetch_string!(attrs, :name),
      description: optional_string!(attrs, :description),
      schedule_kind: fetch_string!(attrs, :schedule_kind),
      schedule_expr: fetch_string!(attrs, :schedule_expr),
      timezone: fetch_string!(attrs, :timezone),
      next_run_at: optional_timestamp_string(Map.get(attrs, :next_run_at)),
      task_prompt: fetch_string!(attrs, :task_prompt),
      skill_name: optional_string!(attrs, :skill_name),
      session_mode: string_with_default!(attrs, :session_mode, "isolated"),
      provider: optional_string!(attrs, :provider),
      model: optional_string!(attrs, :model),
      max_iterations:
        positive_integer_with_default!(
          attrs,
          :max_iterations,
          IterationLimits.scheduled_job_default()
        ),
      timeout_seconds: optional_positive_integer!(attrs, :timeout_seconds),
      inactivity_timeout_seconds: optional_positive_integer!(attrs, :inactivity_timeout_seconds),
      capability_policy:
        list_of_strings!(Map.get(attrs, :capability_policy, []), :capability_policy),
      allowed_tools: list_of_strings!(Map.get(attrs, :allowed_tools, []), :allowed_tools),
      memory_source_id: fetch_string!(attrs, :memory_source_id),
      memory_read_scopes:
        list_of_strings!(Map.get(attrs, :memory_read_scopes, []), :memory_read_scopes),
      memory_write_scope: optional_string!(attrs, :memory_write_scope),
      main_visible?: bool_with_default!(attrs, :main_visible?, true),
      delivery_mode: string_with_default!(attrs, :delivery_mode, "none"),
      delivery_target: Map.get(attrs, :delivery_target),
      silent_marker: string_with_default!(attrs, :silent_marker, "[SILENT]"),
      enabled?: bool_with_default!(attrs, :enabled?, true),
      state: string_with_default!(attrs, :state, "scheduled"),
      last_run_at: optional_timestamp_string(Map.get(attrs, :last_run_at)),
      last_status: optional_string!(attrs, :last_status),
      last_error: optional_string!(attrs, :last_error),
      created_by_agent_id: string_with_default!(attrs, :created_by_agent_id, "main"),
      created_by_session_id: optional_string!(attrs, :created_by_session_id),
      created_by_channel: optional_string!(attrs, :created_by_channel),
      created_by_trust: fetch_string!(attrs, :created_by_trust),
      expires_at: optional_timestamp_string(Map.get(attrs, :expires_at)),
      created_at: timestamp_string(Map.get(attrs, :created_at, DateTime.utc_now())),
      updated_at: timestamp_string(Map.get(attrs, :updated_at, DateTime.utc_now()))
    }
  end

  defp normalize_job_run_attrs(attrs) do
    %{
      id: fetch_string!(attrs, :id),
      job_id: fetch_string!(attrs, :job_id),
      session_id: fetch_string!(attrs, :session_id),
      trigger: fetch_string!(attrs, :trigger),
      status: fetch_string!(attrs, :status),
      claimed_at: optional_timestamp_string(Map.get(attrs, :claimed_at)),
      started_at: optional_timestamp_string(Map.get(attrs, :started_at)),
      completed_at: optional_timestamp_string(Map.get(attrs, :completed_at)),
      prompt_snapshot: optional_string!(attrs, :prompt_snapshot),
      job_config_snapshot: Map.get(attrs, :job_config_snapshot),
      capability_policy_snapshot: Map.get(attrs, :capability_policy_snapshot),
      output_ref: optional_string!(attrs, :output_ref),
      final_response: optional_string!(attrs, :final_response),
      error: optional_string!(attrs, :error),
      delivery_status: string_with_default!(attrs, :delivery_status, "none"),
      delivery_error: optional_string!(attrs, :delivery_error),
      iterations: optional_non_negative_integer!(attrs, :iterations),
      token_usage: Map.get(attrs, :token_usage),
      latency: Map.get(attrs, :latency),
      created_at: timestamp_string(Map.get(attrs, :created_at, DateTime.utc_now())),
      updated_at: timestamp_string(Map.get(attrs, :updated_at, DateTime.utc_now()))
    }
  end

  defp normalize_harness_run_attrs(attrs) do
    %{
      id: fetch_string!(attrs, :id),
      vendor: fetch_string!(attrs, :vendor),
      rail: fetch_string!(attrs, :rail),
      status: fetch_string!(attrs, :status),
      reason: optional_string!(attrs, :reason),
      cwd: fetch_string!(attrs, :cwd),
      worktree_root: fetch_string!(attrs, :worktree_root),
      lock_roots: fetch_lock_roots!(attrs),
      artifacts_dir: fetch_string!(attrs, :artifacts_dir),
      resumable: bool_with_default!(attrs, :resumable, true),
      vendor_session_id: optional_string!(attrs, :vendor_session_id),
      exit_code: optional_non_negative_integer!(attrs, :exit_code),
      framing_errors: non_negative_integer_with_default!(attrs, :framing_errors, 0),
      artifact_truncated: bool_with_default!(attrs, :artifact_truncated, false),
      usage: Map.get(attrs, :usage),
      diagnostics_tail: optional_string!(attrs, :diagnostics_tail),
      origin_kind: fetch_string!(attrs, :origin_kind),
      origin_session_id: fetch_string!(attrs, :origin_session_id),
      continuation_depth: non_negative_integer_with_default!(attrs, :continuation_depth, 0),
      client_origin: Map.get(attrs, :client_origin),
      parent_job_id: optional_string!(attrs, :parent_job_id),
      delivery_mode: fetch_string!(attrs, :delivery_mode),
      platform: optional_string!(attrs, :platform),
      destination: optional_string!(attrs, :destination),
      thread: optional_string!(attrs, :thread),
      send_opts: Map.get(attrs, :send_opts),
      delivery_status: string_with_default!(attrs, :delivery_status, "pending"),
      delivery_attempts: non_negative_integer_with_default!(attrs, :delivery_attempts, 0),
      next_delivery_at: optional_timestamp_string(Map.get(attrs, :next_delivery_at)),
      last_delivery_error: optional_string!(attrs, :last_delivery_error),
      task_id: optional_string!(attrs, :task_id),
      task_url: optional_string!(attrs, :task_url),
      next_poll_at: optional_timestamp_string(Map.get(attrs, :next_poll_at)),
      poll_deadline: optional_timestamp_string(Map.get(attrs, :poll_deadline)),
      created_at: timestamp_string(Map.get(attrs, :created_at, DateTime.utc_now())),
      started_at: optional_timestamp_string(Map.get(attrs, :started_at)),
      first_event_at: optional_timestamp_string(Map.get(attrs, :first_event_at)),
      last_event_at: optional_timestamp_string(Map.get(attrs, :last_event_at)),
      completed_at: optional_timestamp_string(Map.get(attrs, :completed_at)),
      delivered_at: optional_timestamp_string(Map.get(attrs, :delivered_at))
    }
  end

  defp normalize_memory_source_attrs(attrs) do
    %{
      id: fetch_string!(attrs, :id),
      source_type: fetch_string!(attrs, :source_type),
      name: fetch_string!(attrs, :name),
      description: optional_string!(attrs, :description),
      owner_agent_id: string_with_default!(attrs, :owner_agent_id, "main"),
      visibility: string_with_default!(attrs, :visibility, "main_visible"),
      schedule_summary: optional_string!(attrs, :schedule_summary),
      status: string_with_default!(attrs, :status, "enabled"),
      last_run_at: optional_timestamp_string(Map.get(attrs, :last_run_at)),
      last_status: optional_string!(attrs, :last_status),
      memory_scope: fetch_string!(attrs, :memory_scope),
      output_scope: optional_string!(attrs, :output_scope),
      metadata: Map.get(attrs, :metadata),
      created_at: timestamp_string(Map.get(attrs, :created_at, DateTime.utc_now())),
      updated_at: timestamp_string(Map.get(attrs, :updated_at, DateTime.utc_now()))
    }
  end

  defp normalize_commit_revision_attrs(attrs) do
    attrs
    |> Map.put(:revision, 1)
    |> Map.put(:parent_revision, nil)
    |> normalize_revision_attrs()
    |> Map.put(:resource_path, optional_string!(attrs, :resource_path))
  end

  defp normalize_revision_selector(selector) do
    selector
    |> normalize_resource_selector()
    |> Map.put(:revision, fetch_positive_integer!(selector, :revision))
  end

  defp normalize_message_selector(selector) do
    %{
      agent_id: fetch_string!(selector, :agent_id),
      owner_id: optional_string!(selector, :owner_id),
      channel: fetch_string!(selector, :channel),
      chat_id: fetch_string!(selector, :chat_id),
      thread_scope: Scope.normalize_thread_scope(Map.fetch!(selector, :thread_scope))
    }
  end

  defp normalize_memory_review_selector(selector) do
    %{
      agent_id: fetch_string!(selector, :agent_id),
      owner_id: fetch_string!(selector, :owner_id),
      channel: fetch_string!(selector, :channel),
      chat_id: fetch_string!(selector, :chat_id),
      thread_scope: Scope.normalize_thread_scope(Map.fetch!(selector, :thread_scope))
    }
  end

  defp normalize_message_search_selector(selector) do
    selector
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{}, fn
      {:thread_scope, value} -> {:thread_scope, Scope.normalize_thread_scope(value)}
      {key, value} -> {key, fetch_string_value!(key, value)}
    end)
  end

  defp normalize_message_fetch_selector(selector) do
    with {:ok, required} <- required_message_selector(selector) do
      {:ok, Map.merge(required, optional_message_fetch_filters(selector))}
    end
  end

  defp required_message_selector(selector) do
    Enum.reduce_while([:agent_id, :channel, :chat_id, :thread_scope], {:ok, %{}}, fn key,
                                                                                     {:ok, acc} ->
      case Map.fetch(selector, key) do
        {:ok, nil} ->
          {:halt, {:error, {:missing_required_message_selector_key, key}}}

        {:ok, value} ->
          {:cont, {:ok, Map.put(acc, key, normalize_message_selector_value!(key, value))}}

        :error ->
          {:halt, {:error, {:missing_required_message_selector_key, key}}}
      end
    end)
  end

  defp optional_message_fetch_filters(selector) do
    [:owner_id, :sender, :role, :kind]
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.fetch(selector, key) do
        {:ok, nil} -> acc
        {:ok, value} -> Map.put(acc, key, fetch_string_value!(key, value))
        :error -> acc
      end
    end)
  end

  defp normalize_message_selector_value!(:thread_scope, value) do
    Scope.normalize_thread_scope(value)
  end

  defp normalize_message_selector_value!(key, value), do: fetch_string_value!(key, value)

  defp message_insert_params(message) do
    [
      message.agent_id,
      message.owner_id,
      message.channel,
      message.chat_id,
      message.thread_scope,
      message.sender,
      message.role,
      message.kind,
      message.content,
      encode_metadata(message.metadata),
      message.created_at
    ]
  end

  defp memory_insert_params(memory) do
    [
      memory.agent_id,
      memory.owner_id,
      memory.scope_type,
      memory.scope_id,
      memory.category,
      memory.key,
      memory.value,
      memory.confidence,
      memory.promote_target,
      memory.source_message_id,
      memory.source_id,
      memory.source_type,
      memory.source_name,
      memory.source_description,
      memory.session_id,
      memory.run_id,
      memory.created_at,
      memory.updated_at
    ]
  end

  defp resource_upsert_params(resource) do
    [
      resource.agent_id,
      resource.resource_type,
      resource.scope_id,
      resource.resource_path,
      resource.current_revision,
      resource.updated_at
    ]
  end

  defp revision_insert_params(revision) do
    [
      revision.agent_id,
      revision.resource_type,
      revision.scope_id,
      revision.revision,
      revision.parent_revision,
      revision.content_hash,
      revision.content,
      revision.byte_size,
      revision.mutation_source,
      encode_metadata(revision.provenance),
      revision.created_at
    ]
  end

  defp scheduled_job_upsert_params(job) do
    [
      job.id,
      job.name,
      job.description,
      job.schedule_kind,
      job.schedule_expr,
      job.timezone,
      job.next_run_at,
      job.task_prompt,
      job.skill_name,
      job.session_mode,
      job.provider,
      job.model,
      job.max_iterations,
      job.timeout_seconds,
      job.inactivity_timeout_seconds,
      encode_metadata(job.capability_policy),
      encode_metadata(job.allowed_tools),
      job.memory_source_id,
      encode_metadata(job.memory_read_scopes),
      job.memory_write_scope,
      bool_to_int(job.main_visible?),
      job.delivery_mode,
      encode_metadata(job.delivery_target),
      job.silent_marker,
      bool_to_int(job.enabled?),
      job.state,
      job.last_run_at,
      job.last_status,
      job.last_error,
      job.created_by_agent_id,
      job.created_by_session_id,
      job.expires_at,
      job.created_by_channel,
      job.created_by_trust,
      job.created_at,
      job.updated_at
    ]
  end

  defp job_run_upsert_params(run) do
    [
      run.id,
      run.job_id,
      run.session_id,
      run.trigger,
      run.status,
      run.claimed_at,
      run.started_at,
      run.completed_at,
      run.prompt_snapshot,
      encode_metadata(run.job_config_snapshot),
      encode_metadata(run.capability_policy_snapshot),
      run.output_ref,
      run.final_response,
      run.error,
      run.delivery_status,
      run.delivery_error,
      run.iterations,
      encode_metadata(run.token_usage),
      encode_metadata(run.latency),
      run.created_at,
      run.updated_at
    ]
  end

  defp harness_run_insert_params(run) do
    [
      run.id,
      run.vendor,
      run.rail,
      run.status,
      run.reason,
      run.cwd,
      run.worktree_root,
      Jason.encode!(run.lock_roots),
      run.artifacts_dir,
      bool_to_int(run.resumable),
      run.vendor_session_id,
      run.exit_code,
      run.framing_errors,
      bool_to_int(run.artifact_truncated),
      encode_metadata(run.usage),
      run.diagnostics_tail,
      run.origin_kind,
      run.origin_session_id,
      run.parent_job_id,
      run.delivery_mode,
      run.platform,
      run.destination,
      run.thread,
      encode_metadata(run.send_opts),
      run.delivery_status,
      run.delivery_attempts,
      run.next_delivery_at,
      run.last_delivery_error,
      run.task_id,
      run.task_url,
      run.next_poll_at,
      run.poll_deadline,
      run.created_at,
      run.started_at,
      run.first_event_at,
      run.last_event_at,
      run.completed_at,
      run.delivered_at,
      run.continuation_depth,
      encode_metadata(run.client_origin)
    ]
  end

  # Dynamic UPDATE set-clause. Column names come only from the allowlisted key
  # classes (never from data), so the interpolated fragment is injection-safe;
  # an unlisted key raises rather than silently dropping.
  defp harness_run_set_clause(fields) do
    {clauses, params} =
      fields
      |> Enum.map(&harness_run_set_entry/1)
      |> Enum.unzip()

    {Enum.join(clauses, ", "), params}
  end

  defp harness_run_set_entry({key, value}) when key in @harness_run_timestamp_cols do
    {"#{key} = ?", optional_timestamp_string(value)}
  end

  defp harness_run_set_entry({key, value}) when key in @harness_run_bool_cols do
    {"#{key} = ?", bool_to_int(value)}
  end

  defp harness_run_set_entry({:usage, value}) do
    {"usage_json = ?", encode_metadata(value)}
  end

  defp harness_run_set_entry({key, value}) when key in @harness_run_plain_cols do
    {"#{key} = ?", value}
  end

  defp harness_run_set_entry({key, _value}) do
    raise ArgumentError, "harness_runs column #{inspect(key)} is not updatable"
  end

  defp memory_source_upsert_params(source) do
    [
      source.id,
      source.source_type,
      source.name,
      source.description,
      source.owner_agent_id,
      source.visibility,
      source.schedule_summary,
      source.status,
      source.last_run_at,
      source.last_status,
      source.memory_scope,
      source.output_scope,
      encode_metadata(source.metadata),
      source.created_at,
      source.updated_at
    ]
  end

  defp memory_lookup(memory) do
    %{
      agent_id: memory.agent_id,
      owner_id: memory.owner_id,
      scope_type: memory.scope_type,
      scope_id: memory.scope_id,
      key: memory.key
    }
  end

  defp resource_selector(resource) do
    %{
      agent_id: resource.agent_id,
      resource_type: resource.resource_type,
      scope_id: resource.scope_id
    }
  end

  defp resource_list_query(%{agent_id: agent_id}) do
    {
      """
      SELECT *
      FROM resources
      WHERE agent_id = ?
      ORDER BY resource_type ASC, scope_id ASC
      """,
      [agent_id]
    }
  end

  defp resource_list_query(%{}) do
    {
      """
      SELECT *
      FROM resources
      ORDER BY agent_id ASC, resource_type ASC, scope_id ASC
      """,
      []
    }
  end

  defp scheduled_job_where_clause(selector) do
    selector
    |> Enum.filter(fn {_key, value} -> not is_nil(value) end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_reduce([], fn
      {:enabled?, value}, params ->
        {"enabled = ?", params ++ [bool_to_int(value)]}

      {key, value}, params ->
        {"#{scheduled_job_column_name(key)} = ?", params ++ [value]}
    end)
    |> join_where_clause()
  end

  defp job_run_where_clause(selector) do
    selector
    |> Enum.filter(fn {_key, value} -> not is_nil(value) end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_reduce([], fn {key, value}, params ->
      {"#{job_run_column_name(key)} = ?", params ++ [value]}
    end)
    |> join_where_clause()
  end

  defp harness_run_where_clause(selector) do
    selector
    |> Enum.filter(fn {_key, value} -> not is_nil(value) end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_reduce([], fn {key, value}, params ->
      {"#{harness_run_column_name(key)} = ?", params ++ [value]}
    end)
    |> join_where_clause()
  end

  defp memory_source_where_clause(selector) do
    selector
    |> Enum.filter(fn {_key, value} -> not is_nil(value) end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_reduce([], fn {key, value}, params ->
      {"#{memory_source_column_name(key)} = ?", params ++ [value]}
    end)
    |> join_where_clause()
  end

  defp revision_attrs_for_commit(revision, current) do
    revision
    |> Map.put(:revision, current.current_revision + 1)
    |> Map.put(:parent_revision, parent_revision(current.current_revision))
  end

  defp resource_attrs_for_commit(revision, inserted) do
    %{
      agent_id: revision.agent_id,
      resource_type: revision.resource_type,
      scope_id: revision.scope_id,
      resource_path: revision.resource_path,
      current_revision: inserted.revision
    }
  end

  defp parent_revision(0), do: nil
  defp parent_revision(revision), do: revision

  defp require_memory_key(selector) do
    case Map.fetch(selector, :key) do
      {:ok, value} when is_binary(value) -> {:ok, selector}
      {:ok, _value} -> {:error, {:invalid_memory_selector_key, :key}}
      :error -> {:error, {:missing_required_memory_selector_key, :key}}
    end
  end

  defp memory_where_clause(selector) do
    selector
    |> Enum.filter(fn {_key, value} -> not is_nil(value) end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_reduce([], &memory_where_term/2)
    |> join_where_clause()
  end

  defp search_memory_where_clause(selector) do
    selector
    |> Enum.filter(fn {_key, value} -> not is_nil(value) end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_reduce([], &search_memory_where_term/2)
    |> join_where_clause()
  end

  defp review_conversation_where_clause(selector) do
    selector
    |> Enum.filter(fn {_key, value} -> not is_nil(value) end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_reduce([], fn
      {:thread_scope, value}, params ->
        {"thread_scope = ?", params ++ [Scope.normalize_thread_scope(value)]}

      {key, value}, params ->
        {"#{message_column_name(key)} = ?", params ++ [fetch_string_value!(key, value)]}
    end)
    |> join_where_clause()
  end

  defp memory_where_term({:archived?, false}, params), do: {"archived_at IS NULL", params}
  defp memory_where_term({:archived?, true}, params), do: {"archived_at IS NOT NULL", params}
  defp memory_where_term({key, value}, params), do: {"#{column_name(key)} = ?", params ++ [value]}

  defp search_memory_where_term({:archived?, false}, params),
    do: {"memories.archived_at IS NULL", params}

  defp search_memory_where_term({:archived?, true}, params),
    do: {"memories.archived_at IS NOT NULL", params}

  defp search_memory_where_term({key, value}, params),
    do: {"memories.#{search_memory_column_name(key)} = ?", params ++ [value]}

  defp message_where_clause(selector) do
    selector
    |> normalize_message_search_selector()
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_reduce([], fn {key, value}, params ->
      {"messages.#{message_column_name(key)} = ?", params ++ [value]}
    end)
    |> join_where_clause()
  end

  defp message_fetch_where_clause(selector) do
    with {:ok, normalized} <- normalize_message_fetch_selector(selector) do
      clause =
        normalized
        |> Enum.sort_by(fn {key, _value} -> key end)
        |> Enum.map_reduce([], fn {key, value}, params ->
          {"messages.#{message_column_name(key)} = ?", params ++ [value]}
        end)
        |> join_where_clause()

      {:ok, clause}
    end
  end

  defp join_where_clause({[], params}), do: {"1 = 1", params}

  defp join_where_clause({clauses, params}) do
    {Enum.join(clauses, " AND "), params}
  end

  defp column_name(:key), do: "\"key\""
  defp column_name(:id), do: "id"

  defp column_name(key)
       when key in [
              :agent_id,
              :owner_id,
              :scope_type,
              :scope_id,
              :category,
              :source_id,
              :source_type,
              :session_id,
              :run_id,
              :archived_by
            ] do
    Atom.to_string(key)
  end

  defp search_memory_column_name(:key), do: "\"key\""
  defp search_memory_column_name(:id), do: "id"

  defp search_memory_column_name(key)
       when key in [
              :agent_id,
              :owner_id,
              :scope_type,
              :scope_id,
              :category,
              :source_id,
              :source_type,
              :session_id,
              :run_id,
              :archived_by
            ] do
    Atom.to_string(key)
  end

  defp scheduled_job_column_name(key)
       when key in [
              :id,
              :state,
              :schedule_kind,
              :created_by_agent_id,
              :memory_source_id,
              :delivery_mode
            ] do
    Atom.to_string(key)
  end

  defp job_run_column_name(key) when key in [:id, :job_id, :session_id, :trigger, :status] do
    Atom.to_string(key)
  end

  defp harness_run_column_name(key)
       when key in [
              :id,
              :vendor,
              :rail,
              :status,
              :origin_kind,
              :origin_session_id,
              :parent_job_id,
              :delivery_status,
              :task_id
            ] do
    Atom.to_string(key)
  end

  defp memory_source_column_name(key)
       when key in [:id, :source_type, :owner_agent_id, :visibility, :status] do
    Atom.to_string(key)
  end

  defp message_column_name(key)
       when key in [
              :agent_id,
              :owner_id,
              :channel,
              :chat_id,
              :thread_scope,
              :sender,
              :role,
              :kind
            ] do
    Atom.to_string(key)
  end

  defp memory_review_selector_params(selector) do
    [
      selector.agent_id,
      selector.owner_id,
      selector.channel,
      selector.chat_id,
      selector.thread_scope
    ]
  end

  defp empty_review_state do
    %{
      last_reviewed_message_id: nil,
      last_reviewed_at: nil,
      last_review_started_at: nil,
      last_review_completed_at: nil,
      last_review_status: nil,
      last_review_failed_at: nil,
      failure_count: 0
    }
  end

  defp active_review?(row, now, stale_after_ms) do
    started = row.last_review_started_at
    completed = row.last_review_completed_at
    failed = row.last_review_failed_at

    not is_nil(started) and newer_than?(started, completed) and newer_than?(started, failed) and
      DateTime.diff(now, started, :millisecond) < stale_after_ms
  end

  defp newer_than?(_started, nil), do: true
  defp newer_than?(started, other), do: DateTime.compare(started, other) == :gt

  defp upsert_memory_review_started(conn, selector, existing, now) do
    now_string = timestamp_string(now)

    with :ok <-
           execute(
             conn,
             """
             INSERT INTO memory_review_state (
               agent_id,
               owner_id,
               channel,
               chat_id,
               thread_scope,
               last_reviewed_message_id,
               last_reviewed_at,
               last_review_started_at,
               last_review_completed_at,
               last_review_status,
               last_review_failed_at,
               failure_count,
               updated_at
             )
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(agent_id, owner_id, channel, chat_id, thread_scope)
             DO UPDATE SET
               last_review_started_at = excluded.last_review_started_at,
               updated_at = excluded.updated_at
             """,
             memory_review_selector_params(selector) ++
               [
                 existing.last_reviewed_message_id,
                 optional_timestamp_string(existing.last_reviewed_at),
                 now_string,
                 optional_timestamp_string(existing.last_review_completed_at),
                 existing.last_review_status,
                 optional_timestamp_string(existing.last_review_failed_at),
                 existing.failure_count,
                 now_string
               ]
           ) do
      fetch_memory_review_state(conn, selector)
    end
  end

  defp message_row([
         id,
         agent_id,
         owner_id,
         channel,
         chat_id,
         thread_scope,
         sender,
         role,
         kind,
         content,
         metadata_json,
         created_at
       ]) do
    %{
      id: id,
      agent_id: agent_id,
      owner_id: owner_id,
      channel: channel,
      chat_id: chat_id,
      thread_scope: thread_scope,
      sender: sender,
      role: role,
      kind: kind,
      content: content,
      metadata: decode_metadata(metadata_json),
      created_at: parse_timestamp!(created_at)
    }
  end

  defp memory_row([
         id,
         agent_id,
         owner_id,
         scope_type,
         scope_id,
         category,
         key,
         value,
         confidence,
         promote_target,
         source_message_id,
         created_at,
         updated_at,
         source_id,
         source_type,
         source_name,
         source_description,
         session_id,
         run_id,
         archived_at,
         archived_by,
         archive_reason
       ]) do
    %{
      id: id,
      agent_id: agent_id,
      owner_id: owner_id,
      scope_type: scope_type,
      scope_id: scope_id,
      category: category,
      key: key,
      value: value,
      confidence: confidence * 1.0,
      promote_target: promote_target,
      source_message_id: source_message_id,
      source_id: source_id,
      source_type: source_type,
      source_name: source_name,
      source_description: source_description,
      session_id: session_id,
      run_id: run_id,
      archived_at: parse_optional_timestamp(archived_at),
      archived_by: archived_by,
      archive_reason: archive_reason,
      created_at: parse_timestamp!(created_at),
      updated_at: parse_timestamp!(updated_at)
    }
  end

  defp message_search_row([
         id,
         agent_id,
         owner_id,
         channel,
         chat_id,
         thread_scope,
         sender,
         role,
         kind,
         content,
         metadata_json,
         created_at,
         rank
       ]) do
    message_row([
      id,
      agent_id,
      owner_id,
      channel,
      chat_id,
      thread_scope,
      sender,
      role,
      kind,
      content,
      metadata_json,
      created_at
    ])
    |> Map.put(:rank, rank * 1.0)
  end

  defp memory_search_row([
         id,
         agent_id,
         owner_id,
         scope_type,
         scope_id,
         category,
         key,
         value,
         confidence,
         promote_target,
         source_message_id,
         created_at,
         updated_at,
         source_id,
         source_type,
         source_name,
         source_description,
         session_id,
         run_id,
         archived_at,
         archived_by,
         archive_reason,
         rank
       ]) do
    memory_row([
      id,
      agent_id,
      owner_id,
      scope_type,
      scope_id,
      category,
      key,
      value,
      confidence,
      promote_target,
      source_message_id,
      created_at,
      updated_at,
      source_id,
      source_type,
      source_name,
      source_description,
      session_id,
      run_id,
      archived_at,
      archived_by,
      archive_reason
    ])
    |> Map.put(:rank, rank * 1.0)
  end

  defp review_conversation_row([agent_id, owner_id, channel, chat_id, thread_scope]) do
    %{
      agent_id: agent_id,
      owner_id: owner_id,
      channel: channel,
      chat_id: chat_id,
      thread_scope: thread_scope
    }
  end

  defp memory_review_state_row([
         agent_id,
         owner_id,
         channel,
         chat_id,
         thread_scope,
         last_reviewed_message_id,
         last_reviewed_at,
         last_review_started_at,
         last_review_completed_at,
         last_review_status,
         last_review_failed_at,
         failure_count,
         updated_at
       ]) do
    %{
      agent_id: agent_id,
      owner_id: owner_id,
      channel: channel,
      chat_id: chat_id,
      thread_scope: thread_scope,
      last_reviewed_message_id: last_reviewed_message_id,
      last_reviewed_at: parse_optional_timestamp(last_reviewed_at),
      last_review_started_at: parse_optional_timestamp(last_review_started_at),
      last_review_completed_at: parse_optional_timestamp(last_review_completed_at),
      last_review_status: last_review_status,
      last_review_failed_at: parse_optional_timestamp(last_review_failed_at),
      failure_count: failure_count,
      updated_at: parse_timestamp!(updated_at)
    }
  end

  defp resource_row([
         id,
         agent_id,
         resource_type,
         scope_id,
         resource_path,
         current_revision,
         created_at,
         updated_at
       ]) do
    %{
      id: id,
      agent_id: agent_id,
      resource_type: resource_type,
      scope_id: scope_id,
      resource_path: resource_path,
      current_revision: current_revision,
      created_at: parse_timestamp!(created_at),
      updated_at: parse_timestamp!(updated_at)
    }
  end

  defp resource_revision_row([
         id,
         agent_id,
         resource_type,
         scope_id,
         revision,
         parent_revision,
         content_hash,
         content,
         byte_size,
         mutation_source,
         provenance_json,
         created_at
       ]) do
    %{
      id: id,
      agent_id: agent_id,
      resource_type: resource_type,
      scope_id: scope_id,
      revision: revision,
      parent_revision: parent_revision,
      content_hash: content_hash,
      content: content,
      byte_size: byte_size,
      mutation_source: mutation_source,
      provenance: decode_metadata(provenance_json),
      created_at: parse_timestamp!(created_at)
    }
  end

  defp scheduled_job_row([
         id,
         name,
         description,
         schedule_kind,
         schedule_expr,
         timezone,
         next_run_at,
         task_prompt,
         skill_name,
         session_mode,
         provider,
         model,
         max_iterations,
         timeout_seconds,
         inactivity_timeout_seconds,
         capability_policy_json,
         allowed_tools_json,
         memory_source_id,
         memory_read_scopes_json,
         memory_write_scope,
         main_visible,
         delivery_mode,
         delivery_target_json,
         silent_marker,
         enabled,
         state,
         last_run_at,
         last_status,
         last_error,
         created_by_agent_id,
         created_by_session_id,
         created_at,
         updated_at,
         expires_at,
         created_by_channel,
         created_by_trust
       ]) do
    %{
      id: id,
      name: name,
      description: description,
      schedule_kind: schedule_kind,
      schedule_expr: schedule_expr,
      timezone: timezone,
      next_run_at: parse_optional_timestamp(next_run_at),
      task_prompt: task_prompt,
      skill_name: skill_name,
      session_mode: session_mode,
      provider: provider,
      model: model,
      max_iterations: max_iterations,
      timeout_seconds: timeout_seconds,
      inactivity_timeout_seconds: inactivity_timeout_seconds,
      capability_policy: decode_metadata(capability_policy_json) || [],
      allowed_tools: decode_metadata(allowed_tools_json) || [],
      memory_source_id: memory_source_id,
      memory_read_scopes: decode_metadata(memory_read_scopes_json) || [],
      memory_write_scope: memory_write_scope,
      main_visible?: int_to_bool(main_visible),
      delivery_mode: delivery_mode,
      delivery_target: decode_metadata(delivery_target_json),
      silent_marker: silent_marker,
      enabled?: int_to_bool(enabled),
      state: state,
      last_run_at: parse_optional_timestamp(last_run_at),
      last_status: last_status,
      last_error: last_error,
      created_by_agent_id: created_by_agent_id,
      created_by_session_id: created_by_session_id,
      created_by_channel: created_by_channel,
      created_by_trust: created_by_trust,
      expires_at: parse_optional_timestamp(expires_at),
      created_at: parse_timestamp!(created_at),
      updated_at: parse_timestamp!(updated_at)
    }
  end

  defp job_run_row([
         id,
         job_id,
         session_id,
         trigger,
         status,
         claimed_at,
         started_at,
         completed_at,
         prompt_snapshot,
         job_config_snapshot_json,
         capability_policy_snapshot_json,
         output_ref,
         final_response,
         error,
         delivery_status,
         delivery_error,
         iterations,
         token_usage_json,
         latency_json,
         created_at,
         updated_at
       ]) do
    %{
      id: id,
      job_id: job_id,
      session_id: session_id,
      trigger: trigger,
      status: status,
      claimed_at: parse_optional_timestamp(claimed_at),
      started_at: parse_optional_timestamp(started_at),
      completed_at: parse_optional_timestamp(completed_at),
      prompt_snapshot: prompt_snapshot,
      job_config_snapshot: decode_metadata(job_config_snapshot_json),
      capability_policy_snapshot: decode_metadata(capability_policy_snapshot_json),
      output_ref: output_ref,
      final_response: final_response,
      error: error,
      delivery_status: delivery_status,
      delivery_error: delivery_error,
      iterations: iterations,
      token_usage: decode_metadata(token_usage_json),
      latency: decode_metadata(latency_json),
      created_at: parse_timestamp!(created_at),
      updated_at: parse_timestamp!(updated_at)
    }
  end

  defp harness_run_row([
         id,
         vendor,
         rail,
         status,
         reason,
         cwd,
         worktree_root,
         lock_roots_json,
         artifacts_dir,
         resumable,
         vendor_session_id,
         exit_code,
         framing_errors,
         artifact_truncated,
         usage_json,
         diagnostics_tail,
         origin_kind,
         origin_session_id,
         parent_job_id,
         delivery_mode,
         platform,
         destination,
         thread,
         send_opts_json,
         delivery_status,
         delivery_attempts,
         next_delivery_at,
         last_delivery_error,
         task_id,
         task_url,
         next_poll_at,
         poll_deadline,
         created_at,
         started_at,
         first_event_at,
         last_event_at,
         completed_at,
         delivered_at,
         continuation_depth,
         client_origin_json
       ]) do
    %{
      id: id,
      vendor: vendor,
      rail: rail,
      status: status,
      reason: reason,
      cwd: cwd,
      worktree_root: worktree_root,
      lock_roots: Jason.decode!(lock_roots_json),
      artifacts_dir: artifacts_dir,
      resumable: int_to_bool(resumable),
      vendor_session_id: vendor_session_id,
      exit_code: exit_code,
      framing_errors: framing_errors,
      artifact_truncated: int_to_bool(artifact_truncated),
      usage: decode_metadata(usage_json),
      diagnostics_tail: diagnostics_tail,
      origin_kind: origin_kind,
      origin_session_id: origin_session_id,
      continuation_depth: continuation_depth,
      client_origin: decode_metadata(client_origin_json),
      parent_job_id: parent_job_id,
      delivery_mode: delivery_mode,
      platform: platform,
      destination: destination,
      thread: thread,
      send_opts: decode_metadata(send_opts_json),
      delivery_status: delivery_status,
      delivery_attempts: delivery_attempts,
      next_delivery_at: parse_optional_timestamp(next_delivery_at),
      last_delivery_error: last_delivery_error,
      task_id: task_id,
      task_url: task_url,
      next_poll_at: parse_optional_timestamp(next_poll_at),
      poll_deadline: parse_optional_timestamp(poll_deadline),
      created_at: parse_timestamp!(created_at),
      started_at: parse_optional_timestamp(started_at),
      first_event_at: parse_optional_timestamp(first_event_at),
      last_event_at: parse_optional_timestamp(last_event_at),
      completed_at: parse_optional_timestamp(completed_at),
      delivered_at: parse_optional_timestamp(delivered_at)
    }
  end

  defp memory_source_row([
         id,
         source_type,
         name,
         description,
         owner_agent_id,
         visibility,
         schedule_summary,
         status,
         last_run_at,
         last_status,
         memory_scope,
         output_scope,
         metadata_json,
         created_at,
         updated_at
       ]) do
    %{
      id: id,
      source_type: source_type,
      name: name,
      description: description,
      owner_agent_id: owner_agent_id,
      visibility: visibility,
      schedule_summary: schedule_summary,
      status: status,
      last_run_at: parse_optional_timestamp(last_run_at),
      last_status: last_status,
      memory_scope: memory_scope,
      output_scope: output_scope,
      metadata: decode_metadata(metadata_json),
      created_at: parse_timestamp!(created_at),
      updated_at: parse_timestamp!(updated_at)
    }
  end

  defp encode_metadata(nil), do: nil
  defp encode_metadata(metadata), do: Jason.encode!(metadata)

  defp decode_metadata(nil), do: nil
  defp decode_metadata(metadata_json), do: Jason.decode!(metadata_json)

  defp timestamp_string(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp_string(value) when is_binary(value), do: value

  defp optional_timestamp_string(nil), do: nil
  defp optional_timestamp_string(value), do: timestamp_string(value)

  defp parse_timestamp!(value) do
    {:ok, timestamp, _offset} = DateTime.from_iso8601(value)
    timestamp
  end

  defp parse_optional_timestamp(nil), do: nil
  defp parse_optional_timestamp(value), do: parse_timestamp!(value)

  defp fetch_string!(attrs, key) do
    value = Map.fetch!(attrs, key)

    fetch_string_value!(key, value)
  end

  defp fetch_string_value!(key, value) do
    if is_binary(value) do
      value
    else
      raise ArgumentError, "expected #{inspect(key)} to be a string, got: #{inspect(value)}"
    end
  end

  defp optional_string!(attrs, key) do
    case Map.get(attrs, key) do
      nil -> nil
      value -> fetch_string_value!(key, value)
    end
  end

  defp fetch_non_negative_integer!(attrs, key) do
    value = Map.fetch!(attrs, key)
    non_negative_integer_value!(key, value)
  end

  defp fetch_positive_integer!(attrs, key) do
    value = Map.fetch!(attrs, key)
    positive_integer_value!(key, value)
  end

  defp optional_positive_integer!(attrs, key) do
    case Map.get(attrs, key) do
      nil -> nil
      value -> positive_integer_value!(key, value)
    end
  end

  defp optional_non_negative_integer!(attrs, key) do
    case Map.get(attrs, key) do
      nil -> nil
      value -> non_negative_integer_value!(key, value)
    end
  end

  defp positive_integer_with_default!(attrs, key, default) do
    case Map.get(attrs, key, default) do
      nil -> default
      value -> positive_integer_value!(key, value)
    end
  end

  defp non_negative_integer_with_default!(attrs, key, default) do
    case Map.get(attrs, key, default) do
      nil -> default
      value -> non_negative_integer_value!(key, value)
    end
  end

  defp fetch_lock_roots!(attrs) do
    attrs
    |> Map.fetch!(:lock_roots)
    |> list_of_strings!(:lock_roots)
  end

  defp string_with_default!(attrs, key, default) do
    case Map.get(attrs, key, default) do
      nil -> default
      value -> fetch_string_value!(key, value)
    end
  end

  defp bool_with_default!(attrs, key, default) do
    case Map.get(attrs, key, default) do
      nil ->
        default

      value when is_boolean(value) ->
        value

      value ->
        raise ArgumentError, "expected #{inspect(key)} to be a boolean, got: #{inspect(value)}"
    end
  end

  defp non_negative_integer_value!(_key, value) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer_value!(key, value) do
    raise ArgumentError,
          "expected #{inspect(key)} to be a non-negative integer, got: #{inspect(value)}"
  end

  defp positive_integer_value!(_key, value) when is_integer(value) and value > 0, do: value

  defp positive_integer_value!(key, value) do
    raise ArgumentError,
          "expected #{inspect(key)} to be a positive integer, got: #{inspect(value)}"
  end

  defp list_of_strings!(values, _key) when is_list(values) do
    Enum.map(values, fn
      value when is_binary(value) -> value
      other -> raise ArgumentError, "expected list of strings, got: #{inspect(other)}"
    end)
  end

  defp list_of_strings!(value, key) do
    raise ArgumentError,
          "expected #{inspect(key)} to be a list of strings, got: #{inspect(value)}"
  end

  defp bool_to_int(true), do: 1
  defp bool_to_int(false), do: 0

  defp bool_to_int(value) do
    raise ArgumentError, "expected boolean, got: #{inspect(value)}"
  end

  defp int_to_bool(0), do: false
  defp int_to_bool(1), do: true
end
