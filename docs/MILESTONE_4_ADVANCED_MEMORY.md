# Milestone 4: Advanced Memory - Functional Design

**Status:** Draft
**Date:** 2026-04-19
**Author:** Sujeeth / Aira
**Depends on:** M3 (shipped), M2 foundations in current repo
**References:** `docs/ROADMAP.md` (M4 section), `docs/PROJECT_PLAN.md`

---

## 1. Problem / Goal

Fermix memory is currently volatile. Every restart erases conversation history and stored facts. The agent has no durable way to:

- remember anything across restarts
- keep a compact always-loaded memory of what matters most
- extract important facts from conversations automatically
- manage long contexts efficiently when conversations grow large
- search past memories and conversations by keyword or phrase

**Current state:**

| Component | Backing | Persistence | Limit |
|-----------|---------|-------------|-------|
| `ConversationStore` | GenServer + in-memory map | None (RAM) | 50 messages per conversation |
| `Store` (facts) | GenServer + ETS | None (RAM) | Unbounded per conversation |
| `AgentLoop` context | Message list | None | Truncates at 100 messages (keeps system + last N) |

**Milestone 4 makes memory durable, bounded, and useful in-context:** persist conversations and extracted memories to SQLite, maintain bounded prompt memory documents (`USER.md`, `MEMORY.md`), compact long contexts before LLM calls, and support keyword/phrase retrieval over stored memories and conversation history.

**What this milestone is and is not:**

- It **does** make Fermix better over time through personalization, continuity, and better recall.
- It **does not** try to do broader procedural learning or skill synthesis yet.

---

## 2. Scope and Non-Goals

### In Scope

| Feature | Priority | Type | Description |
|---------|----------|------|-------------|
| SQLite persistence layer | P0 | New | Durable storage for messages, extracted memories, and searchable history |
| Memory extraction | P0 | New | LLM-driven extraction of durable facts from completed turns |
| Memory admission rules | P0 | New | Deterministic rules for what gets stored, promoted, or ignored |
| Prompt memory documents | P0 | New | Bounded `USER.md` and `MEMORY.md` files always injected into prompt context |
| Context compaction | P0 | New | Token-aware context reduction when over budget |
| Memory recall tool upgrade | P0 | Rewrite | Search across persistent memories and conversation history |
| FTS5 search | P1 | New | Full-text search over memories and messages |
| Loop detection | P1 | Port | Detect and break runaway tool-call loops in `AgentLoop` |

### Non-Goals

| Feature | Reason | When |
|---------|--------|------|
| Procedural skill learning / skill synthesis | Not wanted right now | Later |
| Hermes-style consolidation phases | Useful, but not required to ship durable memory | Later |
| Confidence decay over time | Premature before extraction and prompt docs are proven | Later |
| Honcho AI integration | Heavy external dependency | Later |
| Embedding/vector search | FTS5 is enough for first-pass lexical retrieval | Later |
| Memory hygiene/snapshots | Operational concern after core memory ships | Later |
| Cross-agent migrations | Only one agent exists today | Later |

---

## 3. Design Revisions From Earlier Draft

This draft changes several earlier assumptions. These changes are intentional.

- **Per-sender gist was removed.** Fermix is self-hosted for one human owner, so default long-term memory belongs to the owner, not an arbitrary sender ID.
- **`gists` table was removed.** Prompt memory should behave like bounded living documents, not growing rows in a table. `USER.md` and `MEMORY.md` are rewritten in full under hard token caps.
- **SQLite remains the source of truth.** Files are derived prompt artifacts, not the canonical store.
- **Search language was narrowed.** FTS5 is strong lexical retrieval, not true semantic retrieval. The design now says "keyword/phrase search" instead of overselling semantic recall.
- **Memory admission is now explicit.** A background extraction pass plus deterministic rules decide what gets stored, promoted, or dropped. No separate sub-agent is required.
- **`agent_id` is added now.** Fermix has one agent today, but this avoids painful migrations later if multiple agents with isolated memory are added.

---

## 4. Operating Model / Assumptions

### Product assumptions

1. **Fermix is self-hosted for one human owner.** The default memory owner is the user running Fermix.
2. **There is one agent today.** Memory should still be namespaced by `agent_id`, defaulting to `"main"`.
3. **1:1 chats are owner-scoped by default.** In direct messages, extracted durable facts usually belong to the owner.
4. **Shared chats are conversation-scoped by default.** In group/shared chats, extracted facts stay conversation-scoped unless the user explicitly says to remember them globally or they clearly describe a durable owner preference.

### Technical assumptions

1. **SQLite is the right persistence backend.** Single-user, local-first, no clustering requirement.
2. **OpenAI remains the only LLM provider.** Extraction and compaction prompts use the current provider.
3. **Extraction runs asynchronously after conversation turns.** It must not block the reply path.
4. **Prompt memory documents are bounded.** `USER.md` and `MEMORY.md` are always rewritten under hard token caps.
5. **Compaction is synchronous when over budget.** This is acceptable, but it must be paid at most once per turn and reused across loop iterations.
6. **Hot caches remain in memory.** SQLite is durable storage; in-memory stores remain the fast path for active conversations.

---

## 5. High-Level Design

M4 introduces four layers:

1. **Persistence Layer** - SQLite-backed durable storage for messages and extracted memories, with in-memory caches remaining the hot path.
2. **Extraction + Admission Layer** - Async post-turn LLM extraction plus deterministic rules that decide what is worth remembering and where it belongs.
3. **Prompt Memory Layer** - Bounded `USER.md` and `MEMORY.md` files derived from structured memory and always injected into the prompt.
4. **Compaction Layer** - Token-aware context reduction that replaces naive message-count truncation.

### Core decisions

**Decision:** SQLite via `exqlite` (Ecto-free). The schema is small, controlled, and local-first. Raw SQL keeps the dependency surface small.

**Decision:** Write-through caching. Active conversations stay in memory for speed. Durable writes go to SQLite.

**Decision:** Extraction is fire-and-forget from the reply path. If extraction fails, messages are still persisted and the reply still succeeds.

**Decision:** Prompt memory is file-backed, not table-backed. `USER.md` and `MEMORY.md` are bounded prompt artifacts rewritten atomically from structured memory.

**Decision:** SQLite is canonical; files are derived. Facts and history live in SQLite. Prompt documents are rebuilt from those facts.

**Decision:** FTS5 is the first retrieval backend. It provides lexical search over stored memories and history. A future embedding backend can sit behind the same search API.

**Decision:** Compaction is synchronous only when needed. When it triggers, the result is cached for the duration of one `process_message/2` turn and reused across `AgentLoop` iterations.

---

## 6. Proposed Components

### 6.1 `FermixCore.Memory.Repo`

**Responsibility:** Own the SQLite connection and provide query functions.

**Database location:** `~/.fermix/memory.db`

**Scope model:**

- `owner` - durable facts about the Fermix owner
- `conversation` - facts that only belong to one `{channel, chat_id, thread_scope}`
- `agent` - durable agent/environment memory that should survive across conversations for a specific agent

**Schema:**

```sql
-- Conversation and agent events
CREATE TABLE messages (
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
CREATE INDEX idx_messages_conversation
  ON messages(agent_id, channel, chat_id, thread_scope, created_at);

-- Extracted memory candidates that survive admission
CREATE TABLE memories (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  agent_id TEXT NOT NULL DEFAULT 'main',
  owner_id TEXT NOT NULL DEFAULT 'default',
  scope_type TEXT NOT NULL,           -- owner | conversation | agent
  scope_id TEXT NOT NULL,             -- owner | channel:chat:thread | agent_id
  category TEXT NOT NULL,             -- identity | preference | goal | project | environment | instruction | correction | episode
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  confidence REAL NOT NULL DEFAULT 1.0,
  promote_target TEXT NOT NULL DEFAULT 'none',  -- advisory target: none | user_md | memory_md
  source_message_id INTEGER REFERENCES messages(id),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE UNIQUE INDEX idx_memories_scope_key
  ON memories(agent_id, owner_id, scope_type, scope_id, key);

-- Lexical search over durable memories
CREATE VIRTUAL TABLE memories_fts
USING fts5(category, key, value, content=memories, content_rowid=id);

CREATE TRIGGER memories_ai AFTER INSERT ON memories BEGIN
  INSERT INTO memories_fts(rowid, category, key, value)
  VALUES (new.id, new.category, new.key, new.value);
END;

CREATE TRIGGER memories_ad AFTER DELETE ON memories BEGIN
  INSERT INTO memories_fts(memories_fts, rowid, category, key, value)
  VALUES('delete', old.id, old.category, old.key, old.value);
END;

CREATE TRIGGER memories_au AFTER UPDATE ON memories BEGIN
  INSERT INTO memories_fts(memories_fts, rowid, category, key, value)
  VALUES('delete', old.id, old.category, old.key, old.value);
  INSERT INTO memories_fts(rowid, category, key, value)
  VALUES (new.id, new.category, new.key, new.value);
END;

-- Lexical search over stored message/event history
CREATE VIRTUAL TABLE messages_fts
USING fts5(role, kind, content, content=messages, content_rowid=id);

CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
  INSERT INTO messages_fts(rowid, role, kind, content)
  VALUES (new.id, new.role, new.kind, new.content);
END;

CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
  INSERT INTO messages_fts(messages_fts, rowid, role, kind, content)
  VALUES('delete', old.id, old.role, old.kind, old.content);
END;

CREATE TRIGGER messages_au AFTER UPDATE ON messages BEGIN
  INSERT INTO messages_fts(messages_fts, rowid, role, kind, content)
  VALUES('delete', old.id, old.role, old.kind, old.content);
  INSERT INTO messages_fts(rowid, role, kind, content)
  VALUES (new.id, new.role, new.kind, new.content);
END;
```

**API surface:**

```elixir
# Messages / events
Repo.insert_message(agent_id, owner_id, channel, chat_id, thread_scope, sender, role, kind, content, opts \\ [])
Repo.get_messages(agent_id, channel, chat_id, thread_scope, opts \\ [limit: 50])
Repo.message_count(agent_id, channel, chat_id, thread_scope)

# Memories
Repo.upsert_memory(agent_id, owner_id, scope_type, scope_id, category, key, value, opts)
Repo.get_memory(agent_id, owner_id, scope_type, scope_id, key)
Repo.get_memories(agent_id, owner_id, opts \\ [])
Repo.search_memories(query, opts \\ [limit: 10])
Repo.search_messages(query, opts \\ [limit: 10])
```

**Implementation note:** The design doc shows positional function signatures for readability, but implementation should prefer structs or maps such as `%Memory.MessageEvent{}` and `%Memory.MemoryCandidate{}`. `Repo.insert_message/10` in particular should not be implemented as a brittle 10-argument public API.

**Startup:** `Repo` is a GenServer that opens the SQLite connection on init, enables WAL mode, runs migrations, and holds the connection reference.

### 6.2 `FermixCore.Memory.ConversationStore` (modified)

**Change:** Add write-through persistence to SQLite.

**New behavior:**

- `add_message/4` writes to the in-memory map and `Repo.insert_message/10`
- `get_history/2` checks the in-memory map first; on miss, it backfills from `Repo.get_messages/5`
- the in-memory rolling window remains 50 messages
- SQLite stores full history and important event rows

**Why keep the in-memory map:** Active conversations need fast reads during one request turn. SQLite is the durable layer, not the hot path.

### 6.3 `FermixCore.Memory.Store` (modified)

**Change:** Add write-through persistence to SQLite with explicit scope.

**New behavior:**

- `store/4` remains backward-compatible and defaults to `conversation` scope
- internal calls from extraction can write `owner`, `conversation`, or `agent` scope
- `recall/3` checks ETS first; on miss, loads from `Repo.get_memory/6`
- `recall_all/2` merges ETS and SQLite results, with SQLite authoritative

**Future-proofing:** `agent_id` is always part of the namespace even though Fermix currently has only one agent.

### 6.4 `FermixCore.Memory.Extractor`

**Responsibility:** Extract memory candidates from recent conversation context using the LLM.

**Trigger:** Called asynchronously after `MainAgent` finishes a turn or after a compaction checkpoint is produced.

**Flow:**

1. Receive `{agent_id, owner_id, conversation_key, messages}`
2. Build extraction prompt asking the LLM for durable memory candidates
3. Call provider with no tools and low temperature
4. Parse structured output into candidate objects
5. Pass candidates through `Memory.Admission`
6. Upsert admitted memories into SQLite and hot cache
7. Trigger prompt document rebuild if needed
8. Emit telemetry `[:fermix, :memory, :extraction]`

**Output contract:**

```json
[
  {
    "category": "preference",
    "key": "preferred_backend_language",
    "value": "Elixir",
    "scope_type": "owner",
    "confidence": 0.93,
    "promote_target": "user_md"
  }
]
```

### 6.5 `FermixCore.Memory.Admission`

**Responsibility:** Decide what gets remembered, what gets promoted into prompt memory, and what gets discarded.

**Important:** This is **not** a separate sub-agent. It is a background extraction pass plus deterministic rules.

**Admission rules:**

- Store durable identity, preference, goal, project, environment, and instruction facts
- Store explicit "remember this" requests
- Store corrections that replace prior beliefs
- Reject low-confidence guesses, one-off chit-chat, and obviously transient task steps
- Deduplicate by `{agent_id, scope_type, scope_id, key}`

**Scope rules:**

- In 1:1 chats, durable user facts default to `owner`
- In shared/group chats, durable facts default to `conversation`
- Environment and recurring workflow facts that should survive across conversations can be stored as `agent`

**Promotion rules:**

- Promote to `USER.md` if the fact should be in the model's head almost every turn
- Promote to `MEMORY.md` if it is durable agent/environment/project context that should usually be loaded
- Keep episodic or narrow facts in SQLite only

**Important:** `promote_target` is an advisory annotation produced by extraction/admission, not the final authority. Full prompt-file rebuilds must be allowed to re-evaluate promotion under the latest policy and may choose a different destination or no destination at all.

### 6.6 `FermixCore.Memory.PromptFiles`

**Responsibility:** Maintain bounded prompt memory documents derived from structured memory.

**Files:**

- `~/.fermix/memory/<agent_id>/USER.md`
- `~/.fermix/memory/<agent_id>/MEMORY.md`

For today's product, `<agent_id>` will almost always be `main`.

**Document intent:**

- `USER.md` - owner profile memory
  - durable preferences
  - recurring goals
  - identity/context the agent should almost always know

- `MEMORY.md` - agent/environment/project memory
  - machine/environment facts
  - repository conventions
  - ongoing durable project context
  - recurring instructions or workflow constraints

**Important behavior:**

- files are **bounded**, not append-only
- files are rewritten in full under hard token caps
- stale, contradicted, or low-value items can be dropped
- writes are atomic so the agent never reads a partially written file

**Rebuild trigger:** Rebuild prompt files when:

- new admitted memories were promoted
- a correction invalidates prior prompt memory
- the last rebuild is older than a configured threshold

**Rebuild authority:** Prompt-file rebuild is the final authority on what appears in `USER.md` and `MEMORY.md`. It may merge, rewrite, demote, or drop items even if a stored row still has `promote_target = 'user_md'` or `promote_target = 'memory_md'`.

**API surface:**

```elixir
PromptFiles.user_path(agent_id)
PromptFiles.memory_path(agent_id)
PromptFiles.load(agent_id)
PromptFiles.rebuild(agent_id, owner_id)
```

### 6.7 `FermixCore.Memory.Compactor`

**Responsibility:** Replace naive message truncation with token-aware compaction.

**Current problem:** `AgentLoop.truncate_messages/1` drops old messages by count. This is not token-aware and can discard important context.

**New behavior:**

1. Estimate token count of the full prompt context
2. If under budget, pass messages through unchanged
3. If over budget:
   - keep system prompt and prompt memory documents
   - keep recent messages verbatim
   - summarize older messages into one checkpoint summary
   - return compacted context

**Token estimation:** Use a token counter if the NIF exists. Fall back to `ceil(byte_size(text) / 4)` approximation.

**Latency policy:**

- compaction is synchronous when needed
- at most **one new compaction summary per `process_message/2` turn**
- the same summary is reused across `AgentLoop` iterations inside that turn

**Checkpoint persistence:** The compactor should persist its summary by default as a `checkpoint_summary` message/event. This allows later turns to build on the latest checkpoint instead of repeatedly summarizing the entire old history. Skipping checkpoint persistence should be an opt-out debug/config mode, not the default.

### 6.8 `FermixCore.Memory.Search`

**Responsibility:** Provide a unified lexical search interface over memories and stored history.

**Important:** This is FTS5-backed keyword/phrase retrieval, not embedding-based semantic retrieval.

**API:**

```elixir
Search.query(search_term, opts \\ [])

# opts:
#   source: :memories | :messages | :all
#   scope: :current_conversation | :owner | :all
#   limit: integer
```

**Returns:**

```elixir
[
  %{
    source: :memories,
    key: "preferred_backend_language",
    value: "Elixir",
    category: "preference",
    rank: 0.12
  }
]
```

### 6.9 `FermixCore.Tools.MemoryRecall` (modified)

**New parameters:**

```elixir
%{
  key: "optional exact key lookup in current scope",
  search: "optional keyword/phrase search",
  scope: "current | owner | all",   # default: current
  source: "memories | history | all" # default: memories
}
```

**Behavior change:**

- `key` alone: exact lookup in the current scope
- `search`: FTS5 query across the selected source and scope
- no params: return all memories for the current conversation (backward-compatible)

### 6.10 Loop Detection

**Responsibility:** Detect and break runaway tool-call loops in `AgentLoop`.

**Heuristic:** Track recent tool calls. If the same tool is called with the same arguments repeatedly:

- inject a system warning after the warn threshold
- terminate after the kill threshold

**Configurable thresholds:**

- window size: 10 tool calls
- warn threshold: 3
- kill threshold: 5

### 6.11 `FermixCore.Memory.Scheduler`

**Responsibility:** Run periodic maintenance work for prompt memory and other memory rebuild tasks.

**Important:** This is the "LLM-powered cron" layer. It is not a separate agent. It is a supervised timer-driven worker that schedules bounded background memory jobs.

**Jobs:**

- periodic `USER.md` rebuild
- periodic `MEMORY.md` rebuild
- optional cleanup/reconciliation pass over promoted memories

**Triggers:**

- event-driven: after extraction admits promoted memories or corrections
- periodic: every N hours, even if no new extraction ran

**Why periodic rebuild still matters:** Event-driven rebuilds keep prompt memory fresh after relevant turns. Periodic rebuilds allow the latest prompt policy to re-evaluate older memories, demote stale items, and rewrite the files cleanly under the current token budget.

**Scheduling policy:**

- debounce repeated rebuild requests into one queued job per agent
- never run two rebuild jobs for the same `agent_id` concurrently
- favor fresh event-driven rebuilds over purely periodic ones

### 6.12 LLM Prompt Contracts

This section defines the required prompt behavior for the memory LLM passes.

#### Extraction prompt

**Purpose:** Turn recent conversation context into durable memory candidates.

**Input:**

- recent conversation messages
- optional latest checkpoint summary
- current chat mode (`direct` or `shared`)
- short policy describing allowed categories and scopes

**Output:** Strict JSON array only.

```json
[
  {
    "category": "preference",
    "key": "preferred_backend_language",
    "value": "Elixir",
    "scope_type": "owner",
    "confidence": 0.93,
    "promote_target": "user_md"
  }
]
```

**Prompt rules:**

- extract only durable information worth remembering
- prefer explicit facts over inference
- output nothing for transient chit-chat
- latest correction wins over older beliefs
- do not emit prose outside the JSON array

#### `USER.md` rebuild prompt

**Purpose:** Produce a bounded owner-profile memory document always loaded into prompt context.

**Input:**

- current `USER.md` if it exists
- owner-scoped memories eligible for `USER.md`
- token budget

**Output:** Markdown only.

**Prompt rules:**

- keep only durable owner context the agent should usually know
- merge duplicates and prefer the latest corrected fact
- drop stale, weak, or narrow facts
- rewrite the document in full; do not append blindly
- obey the hard token cap

**Expected shape:**

```md
## Identity
...

## Preferences
...

## Ongoing Goals
...
```

#### `MEMORY.md` rebuild prompt

**Purpose:** Produce a bounded agent/environment/project memory document always loaded into prompt context.

**Input:**

- current `MEMORY.md` if it exists
- `agent` memories plus owner/conversation memories eligible for `MEMORY.md`
- token budget

**Output:** Markdown only.

**Prompt rules:**

- keep durable environment, project, and recurring instruction context
- exclude narrow one-off episodes unless they are repeatedly useful
- merge duplicates and remove outdated items
- rewrite the document in full; do not append blindly
- obey the hard token cap

**Expected shape:**

```md
## Environment
...

## Project Context
...

## Working Rules
...
```

#### Compaction checkpoint prompt

**Purpose:** Summarize old conversation context into one reusable checkpoint.

**Input:**

- older messages being compacted
- optional prior checkpoint summary
- token budget

**Output:** Plain text summary or one markdown block.

**Prompt rules:**

- preserve decisions, unresolved questions, and active context
- preserve durable facts that matter to the current task
- prefer concise state over narrative retelling
- optimize for reuse in future turns

#### Prompt ownership and enforcement

- extraction prompt is authoritative for candidate generation
- admission rules are authoritative for storage decisions
- prompt-file rebuild prompts are authoritative for document contents
- deterministic validation should reject malformed JSON from extraction before admission runs

---

## 7. Prompt / Context Integration

This section makes the prompt-memory integration explicit.

### Prompt assembly order

For each `process_message/2` call, Fermix builds prompt context in this order:

1. Base system prompt
2. `USER.md` contents, if present and non-empty
3. `MEMORY.md` contents, if present and non-empty
4. Skill catalog / tool guidance
5. Conversation history
6. Current user message

### Injection format

Fermix can inject prompt memory either as separate system messages or by joining them into one system prompt. Both are valid with the current provider integration.

**Recommended rendering:**

```md
## USER MEMORY
...contents of USER.md...

## AGENT MEMORY
...contents of MEMORY.md...
```

### Runtime behavior

- if `USER.md` is missing, inject nothing for that block
- if `MEMORY.md` is missing, inject nothing for that block
- prompt memory files should be loaded before history is appended
- prompt memory documents are never treated as the source of truth; they are prompt views derived from SQLite state

### Why this layer exists

The agent should not query SQLite for every important fact. Most turns should run from:

- base system instructions
- `USER.md`
- `MEMORY.md`
- current conversation

Deep memory search should only be used when prompt memory is insufficient.

---

## 8. User and System Flows

### Flow 1: Normal conversation with persistence

```text
User sends message
  -> MainAgent.process_message()
  -> ConversationStore.get_history() - memory hit or SQLite backfill
  -> PromptFiles.load(agent_id) - USER.md + MEMORY.md
  -> Build messages: base prompt + prompt files + history + user message
  -> Compactor.compact(messages, token_budget) - summarize only if over budget
  -> AgentLoop.run(compacted_messages, ...)
  -> ConversationStore.add_message(user) - memory + SQLite
  -> ConversationStore.add_message(assistant) - memory + SQLite
  -> deliver_reply()
  -> spawn async Extractor.extract(...)
```

### Flow 2: Memory extraction and admission

```text
Extractor.extract(agent_id, owner_id, conversation_key, messages)
  -> Build extraction prompt
  -> Call provider
  -> Parse candidate memories
  -> Admission.apply(candidates, chat_mode)
  -> Repo.upsert_memory(...) for admitted items
  -> Trigger PromptFiles.rebuild(...) if promoted memories changed
  -> Emit telemetry
```

### Flow 3: Prompt file rebuild

```text
PromptFiles.rebuild(agent_id, owner_id)
  -> Load owner memories promoted to user_md
  -> Load agent/owner memories promoted to memory_md
  -> Build bounded markdown documents
  -> Rewrite USER.md atomically
  -> Rewrite MEMORY.md atomically
```

### Flow 3b: Periodic memory scheduler

```text
Memory.Scheduler tick
  -> detect overdue prompt-file rebuild for agent_id
  -> enqueue one rebuild job if none is running
  -> PromptFiles.rebuild(agent_id, owner_id)
  -> rewrite USER.md / MEMORY.md under current policy
```

### Flow 4: Agent uses memory recall with search

```text
Agent calls memory_recall(search: "timezone", scope: "owner")
  -> MemoryRecall.execute()
  -> Search.query("timezone", scope: :owner, source: :memories)
  -> FTS5 returns ranked lexical matches
  -> Return results to agent
```

### Flow 5: Context compaction during long conversation

```text
AgentLoop.do_loop()
  -> Compactor.compact(messages, budget)
     -> Estimate tokens
     -> If over budget, summarize old section once
     -> Cache summary for this turn
     -> Persist checkpoint_summary by default
  -> Call provider with compacted messages
```

---

## 9. Supervision and Runtime Model

### Updated supervision tree

```text
FermixCore.Application
  |- Task.Supervisor (existing)
  |- Trace (existing)
  |- SkillRegistry (existing)
  |- Tools.Registry (existing)
  |- Memory.Repo          <- NEW
  |- ConversationStore    (existing, now write-through)
  |- Store                (existing, now write-through)
  |- BootReport (existing)
  `- MainAgent (existing)
```

### Startup order constraint

`Memory.Repo` must start before `ConversationStore` and `Store`. Prompt file directories can be created lazily on first rebuild.

---

## 10. Config

New configuration keys under `:fermix_core`:

```elixir
config :fermix_core, :memory,
  database_path: "~/.fermix/memory.db",
  prompt_files_dir: "~/.fermix/memory",
  owner_id: "default",
  agent_id: "main",
  extraction_enabled: true,
  extraction_debounce_seconds: 60,
  extraction_model: nil,
  compaction_enabled: true,
  compaction_token_budget: 8000,
  checkpoint_persistence_enabled: true,
  user_md_max_tokens: 600,
  memory_md_max_tokens: 800,
  prompt_files_rebuild_hours: 12,
  scheduler_enabled: true,
  loop_detection_window: 10,
  loop_detection_warn_threshold: 3,
  loop_detection_kill_threshold: 5
```

---

## 11. Testing Strategy

### Unit tests

- `Repo`: CRUD operations, FTS5 search, migration idempotency, WAL startup
- `ConversationStore`: write-through persistence, cache miss backfill
- `Store`: scoped writes and reads, backward-compatible conversation defaults
- `Extractor`: prompt construction and JSON parsing
- `Admission`: scope assignment, promotion decisions, duplicate handling
- `PromptFiles`: bounded rewrite behavior, atomic writes, empty-file handling
- `Compactor`: token estimation, one-summary-per-turn cache, checkpoint persistence
- `Search`: memory search, history search, scope filtering
- `LoopDetection`: warning injection and forced termination
- `MemoryRecall` tool: search mode, source parameter, scope parameter

### Integration tests

- send message -> persisted in SQLite -> survives `ConversationStore` restart
- extracted owner memory -> `USER.md` rebuilt -> next turn injects it
- extracted agent/environment memory -> `MEMORY.md` rebuilt -> next turn injects it
- group chat message -> default conversation-scoped memory, not owner-scoped promotion
- long conversation -> compactor summarizes once -> reused across loop iterations
- `memory_recall(search: ...)` returns ranked FTS5 results from memories/history

### Regression anchors

- `MainAgent.handle_message/2` contract unchanged
- `ConversationStore` public API unchanged
- `Store` public API remains backward-compatible
- existing `memory_recall` callers still work without new params

---

## 12. Implementation Order

### Stage 1: SQLite persistence foundation

1. Add `exqlite` dependency to `fermix_core`
2. Implement `Memory.Repo` with migrations and WAL mode
3. Modify `ConversationStore` for write-through persistence
4. Modify `Store` for write-through persistence with scope support
5. Update supervision tree startup order

**Verify:** Messages and memories survive process restart.

### Stage 2: Search

1. Add FTS5 virtual tables and triggers
2. Implement `Memory.Search`
3. Upgrade `MemoryRecall` tool

**Verify:** `memory_recall(search: ...)` returns ranked lexical results.

### Stage 3: Prompt memory documents

1. Implement `Memory.PromptFiles`
2. Define `USER.md` and `MEMORY.md` layout and token caps
3. Modify `MainAgent.system_prompt/1` or prompt assembly to inject file contents

**Verify:** Prompt files load into agent context when present.

**Note:** Stage 3 intentionally lands before extraction. At this point the files may be missing or empty, and that is acceptable. This lets prompt injection and empty-file behavior be tested independently before Stage 5 starts populating them.

### Stage 4: Compaction and loop detection

1. Implement token estimation
2. Implement `Memory.Compactor`
3. Replace `AgentLoop.truncate_messages/1`
4. Add loop detection to `AgentLoop`

**Verify:** Long conversations compact correctly and only summarize once per turn.

### Stage 5: Extraction and admission

1. Implement `Memory.Extractor`
2. Implement `Memory.Admission`
3. Wire async extraction into `MainAgent.process_message/2`
4. Trigger prompt file rebuilds after promoted memories change

**Verify:** Durable facts are extracted, scoped correctly, and promoted into prompt files when appropriate.

---

## 13. Risks and Mitigations

### Risk: SQLite write contention

**Mitigation:** Single `Repo` owner plus WAL mode. Fermix is single-user and write volume is low.

### Risk: Extraction adds cost

**Mitigation:** Async execution, debounce, configurable model, and feature flag.

### Risk: Prompt memory files grow stale or bloated

**Mitigation:** Hard token caps, full rewrites instead of append-only updates, correction-driven rebuilds, and periodic scheduler-triggered rebuilds.

### Risk: Compaction loses important context

**Mitigation:** Keep prompt files and recent messages verbatim. Only summarize the older portion.

### Risk: Compaction latency multiplies inside one turn

**Mitigation:** Cache one summary per `process_message/2` turn and reuse it across `AgentLoop` iterations.

### Risk: Old promotion hints become stale

**Mitigation:** Treat `promote_target` as advisory only. Full rebuilds re-evaluate current policy and are allowed to demote or drop previously promoted memories.

### Risk: FTS5 search is insufficient

**Mitigation:** Keep retrieval behind `Memory.Search` so embeddings or hybrid search can be added later without changing tool contracts.

### Risk: Group chats leak into owner memory

**Mitigation:** Default shared chats to `conversation` scope. Require explicit promotion for global owner memory.

---

## 14. Open Questions

1. **Should `MemoryStore` gain an explicit `scope` parameter in M4?** Extraction can already write owner/agent scope, but the manual tool may need the same power.
2. **How much of `MEMORY.md` should be owner-derived vs agent-derived?** Today one agent exists, so this is mostly a policy question.
3. **Should manual memory tools be allowed to request promotion into prompt files directly, or should only extraction/admission do that?**
4. **When do we add embeddings?** Not required for M4, but the abstraction should remain ready for it.

---

## 15. Summary

Milestone 4 gives Fermix a durable memory architecture without overreaching into broader procedural learning:

- **SQLite** is the canonical store for messages, memories, and search indexes
- **Extraction + admission** decide what is durable enough to remember
- **`USER.md` and `MEMORY.md`** are bounded prompt memory documents always available in context
- **Compaction** replaces naive message-count truncation with token-aware summarization
- **FTS5** provides first-pass keyword/phrase retrieval over memories and history
- **`agent_id`** is introduced now so future multi-agent isolated memory is straightforward

The key architectural decisions are:

- owner-scoped memory by default for a self-hosted single-user Fermix
- conversation scope by default for shared/group chat facts
- file-backed prompt memory, SQLite-backed canonical memory
- no separate memory sub-agent; use extraction plus deterministic admission rules
- compaction latency is acceptable when necessary, but should only be paid once per turn
