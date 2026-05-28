# Milestone 7.6: Memory Review — Cadence, Consolidation, Render-on-Write

**Status:** Draft (rev 3 — folds in external review on ctx invalidation, add() scope/category mapping, owner_id key, scope metadata in reviewer input, failure-non-advance semantics)
**Date:** 2026-05-27
**Author:** Sujeeth / Aira
**Depends on:** M4 (`Memory.Extractor`, `Memory.Admission`, `Memory.Store`, `Memory.PromptFiles`, `Memory.ConversationStore`), M7.1 (post-turn hook lives next to auto-compaction in `MainAgent.run_message_loop`)
**Blocks / informs:** future "heartbeat" work (per-task cheap-model knob; would also unlock a signal-gated turn cadence — see §5 Q2)
**References:** `apps/fermix_core/lib/fermix_core/memory/config.ex`, `apps/fermix_core/lib/fermix_core/memory/extraction_debouncer.ex`, `apps/fermix_core/lib/fermix_core/memory/extractor.ex`, `apps/fermix_core/lib/fermix_core/memory/admission.ex`, `apps/fermix_core/lib/fermix_core/memory/store.ex`, `apps/fermix_core/lib/fermix_core/memory/prompt_files.ex`, `apps/fermix_core/lib/fermix_core/memory/scheduler.ex`, `apps/fermix_core/lib/fermix_core/memory/prompt_composer.ex`, `apps/fermix_core/lib/fermix_core/memory/repo.ex`, `apps/fermix_core/lib/fermix_core/agents/runtime_context.ex`, `apps/fermix_core/lib/fermix_core/agents/main_agent.ex`, `config/config.exs`

---

## 1. Problem / Goal

Fermix maintains a prompt-facing memory **gist** — `USER.md` (who the user is) and `MEMORY.md` (the agent's working notes) — injected into every turn as a fenced `system` block (`prompt_composer.ex:205-224`). Critically, these files are **not** an edit target: they are a *rendered projection* of the SQLite `memories` table. `memory_store` and the background extractor write *rows*; `PromptFiles.rebuild/4` re-renders the two files from those rows. The rendered gist then becomes part of `MainAgent`'s cached `RuntimeContext`, reused across turns until the GenServer rebuilds it.

Two defects in how that projection is maintained today:

1. **Writes accumulate; they never consolidate.** Extraction emits candidate facts that `Admission` upserts into the DB **by key**. A *rephrased* fact gets a **new key → a new row beside the old one**, and nothing removes a superseded entry. This is the root cause of the "agent re-answers an already-resolved question / re-asks for info it was given" behavior: stale rows linger in the gist and the model acts on them.

2. **Maintenance is time-based, blind, and split.** Background extraction runs at most **once per 24h per conversation** (`@extraction_debounce_seconds 86_400`, `config.ex:16`, enforced by `ExtractionDebouncer`), reads the full history with no "new-since-last" awareness, and the files re-render on a separate **12h timer** (`@prompt_files_rebuild_hours 12`, `config.ex:17`, driven by `Memory.Scheduler`). Two independent clocks for one pipeline, and a rebuilt `.md` only reaches the live prompt when `MainAgent`'s cached `RuntimeContext` is invalidated (which today happens on restart).

**Goal of M7.6:** the **primary fix is consolidation** — the reviewer targets memory rows by **id**, with **add / replace / archive** (no hard delete). The cadence stays time-based (still 24h interval by default, now **configurable** as `review_interval_hours`), but is upgraded to **DB-backed review state** (survives restart and compaction), with **bounded input** that drains busy backlogs across passes. Render becomes event-driven (the 12h timer is removed), and a successful rebuild **invalidates the per-agent runtime context** so the next turn actually sees the updated gist — without that step the consolidation never reaches the live prompt. SQLite remains the source of truth; `memory_recall` and job-scoped memory are untouched.

The trigger is intentionally implemented as a **swappable predicate** (§5 Q2) so a future signal-gated turn cadence can drop in without rework when a cheap reviewer model arrives under heartbeat.

## 2. References

- Cadence config + accessors: `memory/config.ex` (`@extraction_debounce_seconds`, `@prompt_files_rebuild_hours`, `extraction_debounce_ms/1`, `prompt_files_rebuild_interval_ms/1`).
- Post-turn hook: `MainAgent.run_message_loop` → `maybe_start_extraction/4` (`main_agent.ex:1171`), currently routed through `ExtractionDebouncer.request/2` (`main_agent.ex:1198`).
- Extraction LLM + candidate shape: `Memory.Extractor`, gated by `Memory.Admission`, persisted via `Memory.Store` (`Store.remember`, keyed upsert; `Store.delete/4` exists but no turn path calls it).
- `messages` schema + conversation index: `repo.ex:23-38` (`id INTEGER PRIMARY KEY AUTOINCREMENT`, `idx_messages_conversation(agent_id, channel, chat_id, thread_scope, created_at, id)`); deletes via `repo.ex:1261` `delete_message_rows`.
- Render: `PromptFiles.rebuild/4` (re-derives `USER.md`/`MEMORY.md` from DB rows, keyed by `agent_id` + `owner_id`); periodic re-render by `Memory.Scheduler`.
- Gist injection + cache: `PromptComposer` (`<memory-context>` block) + the per-epoch cache in `RuntimeContext.build/1` (held by `MainAgent`, reused across turns until invalidated).
- Compaction's failure-backoff pattern (mirrored here): `@auto_compaction_failure_backoff_ms` in `MainAgent`.
- Char/token caps: `@prompt_user_token_cap 800`, `@prompt_memory_token_cap 1600` (`config.ex:11-12`); rendered char budget ≈ `cap * 4` (`prompt_composer.ex` `memory_max_chars/1`).

## 3. Scope and Non-Goals

### In Scope
- **Time-based interval**: `review_interval_hours` (default **24**, `0` disables). Per-`(agent, owner, conversation)`. **Activity-gated**: skip when there are no new user messages since the last review. **Failure-backoff-gated**: skip while a recent failure is still in cooldown.
- **DB-backed review state** (`memory_review_state`, keyed by `(agent_id, owner_id, channel, chat_id, thread_scope)`): `last_reviewed_message_id`, `last_reviewed_at`, `last_review_started_at`, `last_review_completed_at`, `last_review_status`, `last_review_failed_at`, `failure_count`. Survives restart and compaction.
- **Success/failure asymmetry on the pointer**: `:ok` and `:nothing_to_save` advance `last_reviewed_message_id` + `last_reviewed_at` and reset `failure_count` to 0; `:failed` leaves both pointers untouched and increments `failure_count` + sets `last_review_failed_at`. The next pass retries the same window.
- **Bounded reviewer input**: only user messages with `id > last_reviewed_message_id` for this `(agent, owner, conversation)`, capped by message count and a token budget; **raw tool outputs excluded** (summarized or omitted). Pointer advances by what was actually reviewed, so busy backlogs drain across passes.
- **Combined reviewer** (covers both `USER.md` and `MEMORY.md`), on the **main model**, forked in the background after a successful, non-interrupted reply.
- **Scope-aware reviewer input**: each rendered entry surfaces `(id, bucket, scope_type, scope_id, category, key, value)` so the reviewer knows what it's about to mutate.
- **Operations target exact row ids** — `replace(id, value)` and `archive(id, reason)` inherit the row's existing scope/category. `add(target, category, value)` writes to a deterministic scope per bucket (§4.5).
- **Archive, not hard-delete**: `memories` gains `archived_at`, `archived_by`, `archive_reason`. Default render and `memory_recall` exclude archived rows. `fermix memory restore <id>` debug command undoes an archive.
- **Render-on-write + runtime-context invalidation**: re-render the `.md` files when the reviewer changes rows, then invalidate `MainAgent`'s per-agent `RuntimeContext` so the **next turn** rebuilds the cached prompt with the new gist. Without this step the rebuild only updates disk. **Retire** the 12h `Memory.Scheduler` periodic re-render.
- **Manual trigger**: `fermix memory review --now [--conversation <key>]` bypasses the interval and backoff gates (still respects activity).
- Rewritten reviewer prompt (§4.4).
- Config swap (§4.9): remove `extraction_debounce_seconds` and `prompt_files_rebuild_hours`; add `review_interval_hours`, `review_max_messages`, `review_input_token_budget`, `review_failure_backoff_ms`.

### Non-Goals
- **Not** removing SQLite, `memory_recall` (FTS search), or scope isolation (owner/conversation/agent/**job**). Scheduled-job memory scoping stays exactly as-is.
- **Not** making the `.md` files the source of truth (no file-native/Hermes-exact model). Writes still go through the DB; files render from it. If a rollback is needed, restore DB rows then rebuild the projection — **never treat the rendered `.md` as a rollback source of truth**.
- **Not** changing the char caps (keep current ~3200/6400 chars).
- **Not** adding a separate reviewer-model config (deferred to heartbeat).
- **Not** turn-based triggering in v1. The trigger is implemented as a swappable predicate so a signal-gated turn cadence can be added later under heartbeat without rework.
- **Not** touching M7.1 conversation compaction (`Memory.Compactor`) — that is a separate, history-level mechanism.
- **Not** changing the `memory_store` foreground tool (the agent can still save mid-turn).

## 4. Core Design

### 4.1 What we are replacing

```
today:   per turn  → maybe_start_extraction → ExtractionDebouncer (≤1/24h)
                   → Extractor (LLM emits candidate facts)
                   → Admission (keyed UPSERT, "correction" overwrites same key)
                   → Store.remember (new key ⇒ NEW row; no removal)
         every 12h → Memory.Scheduler → PromptFiles.rebuild   (disk only — cached
                                                              RuntimeContext stays stale
                                                              until daemon restart)
```

All three pieces — the debounce, blind keyed upsert, and the 12h timer — are removed, and the live-prompt invalidation gap is closed.

### 4.2 Time-based trigger + DB review state

A new per-`(agent_id, owner_id, conversation_key)` row in `memory_review_state` holds the cadence pointer:

```sql
CREATE TABLE IF NOT EXISTS memory_review_state (
  agent_id                  TEXT NOT NULL,
  owner_id                  TEXT NOT NULL,
  channel                   TEXT NOT NULL,
  chat_id                   TEXT NOT NULL,
  thread_scope              TEXT NOT NULL,
  last_reviewed_message_id  INTEGER,
  last_reviewed_at          TEXT,
  last_review_started_at    TEXT,
  last_review_completed_at  TEXT,
  last_review_status        TEXT,        -- 'ok' | 'nothing_to_save' | 'failed'
  last_review_failed_at     TEXT,        -- NULL on success; set on :failed
  failure_count             INTEGER NOT NULL DEFAULT 0,
  updated_at                TEXT NOT NULL,
  PRIMARY KEY (agent_id, owner_id, channel, chat_id, thread_scope)
);
```

The hook at `main_agent.ex:1171` evaluates a **swappable trigger predicate** after each successful, non-interrupted reply. The v1 predicate:

> **Fire** when all three hold:
> 1. `last_reviewed_at` is `NULL` **or** `(now − last_reviewed_at) ≥ review_interval_hours`;
> 2. there exists at least one user message in this `(agent, owner, conversation)` with `id > last_reviewed_message_id`;
> 3. `last_review_failed_at` is `NULL` **or** `(now − last_review_failed_at) ≥ review_failure_backoff_ms`.

Both rate gates are essential: the time gate keeps cost bounded; the failure gate prevents retry storms on a flapping reviewer. The activity check rides `idx_messages_conversation` filtered to one conversation + `id > last_reviewed_id` — **table-size-independent**.

**Pointer-advance semantics — success vs. failure asymmetry:**

- On `:ok` or `:nothing_to_save`: set `last_reviewed_message_id ← max(id of rows actually reviewed)`, `last_reviewed_at ← now`, `last_review_completed_at ← now`, `last_review_status` accordingly, `failure_count ← 0`, `last_review_failed_at ← NULL`.
- On `:failed`: **leave** `last_reviewed_message_id` and `last_reviewed_at` unchanged. Set `last_review_failed_at ← now`, `failure_count ← failure_count + 1`, `last_review_status ← 'failed'`. The next eligible pass retries the same window.

This is what "advance only by what was reviewed" actually means in practice: failed windows are not skipped silently.

When the predicate fires, the reviewer runs in a background `Task` (non-blocking, matches today's extraction fork). Concurrent triggers for the same key coalesce: a second arrival while a run is in flight is skipped with `reason: :concurrent_run`.

`review_interval_hours: 0` disables the background reviewer entirely. The foreground `memory_store` tool and the manual `--now` CLI remain available.

**Compaction safety.** `messages` rows can be deleted (compaction's `replace_history` and `/clear` both call `delete_message_rows`, `repo.ex:1261`), but `id` is `AUTOINCREMENT` so ids are **never reused**. `last_reviewed_message_id` referring to a now-deleted row is harmless — the `id >` comparison still correctly identifies any newer rows. Counts of rows would be non-monotonic and unsafe; ids are not.

### 4.3 Bounded reviewer input

The reviewer never sees full history. Input is built as:

1. Fetch user-role messages where `agent_id = ? AND owner_id = ? AND (channel, chat_id, thread_scope) = ? AND id > last_reviewed_message_id` (index range on `idx_messages_conversation`, ordered by `created_at`), capped at `review_max_messages` (default **40**) and `review_input_token_budget` (default **4_000 tokens**).
2. **Exclude raw tool outputs** (filtered by `role`/`kind`, or summarized to a one-line note before inclusion).
3. Include the **current gist entries with full metadata** — each entry is rendered as `(id, bucket, scope_type, scope_id, category, key, value)` so the reviewer knows what it's about to mutate (e.g., distinguishing an owner-scoped preference from an agent-scoped working note).
4. Include the **remaining char budget** for each store.

If the available window is smaller than what's fetched, the input is truncated to the **oldest unreviewed messages first**, and the pointer advances by what was actually packed — so the next pass continues from the unscanned tail rather than skipping ahead. This drains busy backlogs without per-turn cost.

Cost note: the fetch query rides `idx_messages_conversation` — an index range scan over **only this conversation's new tail**. Table-size-independent. (A blanket `COUNT(*)` or unindexed filter would grow with the table — we use neither.)

### 4.4 Reviewer prompt

One background pass on the **main model**, with a restricted tool surface (only `memory_review.*` — see §4.5). The prompt:

```
You maintain {agent}'s long-term memory from the recent conversation. Two stores:
- USER.md   — who the user is: identity, durable preferences, and how they want you to work.
- MEMORY.md — your working notes: stable facts about their projects, environment, and
              decisions worth carrying across sessions.

Current memory — each entry shows its row id, bucket, scope, and category. Reuse a row id to
replace it, archive ids that are now stale; do NOT duplicate:

<user_md used="{u}/{u_cap} chars">
{USER_ENTRIES}   # one per line: (id=123, user, scope=owner, preference) key: "value"
</user_md>
<memory_md used="{m}/{m_cap} chars">
{MEMORY_ENTRIES} # one per line: (id=456, memory, scope=agent, project) key: "value"
</memory_md>

New conversation excerpts since the last review:
{NEW_TURNS}

Save only what is durable and reusable in future sessions. Capture the user's genuine, stated
preferences and intent — prefer their own words; do not infer beyond what they actually expressed.
Skip: one-off task details, transient state, completed-work logs, transient errors,
anything already captured, secrets/credentials, and anything you are not confident about.

Evolve, don't accumulate: if new information updates, contradicts, or refines something already
saved, REPLACE the old row id or ARCHIVE it with a reason — never add a second version.
Stay within each store's character budget by consolidating.

Use the memory_review tools (add / replace / archive). If nothing durable stands out, reply
"Nothing to save." and stop.
```

The reviewer *sees* scope/category for context but never *chooses* them for `replace`/`archive` — those inherit the existing row's metadata. `add` picks bucket + category from a constrained enum (§4.5).

### 4.5 Consolidation by exact row id (add / replace / archive)

The reviewer emits operations against **row ids**, not keys — eliminating ambiguous key-only mutation. Three operations exposed via a new restricted tool surface, all `policy_class: :read_write`:

- **`memory_review.add(target, category, value)`** — insert a new row. `target ∈ {"user","memory"}` and `category` is a constrained enum scoped to the target:
  - `target="user"` → `scope_type="owner"`, `scope_id = <owner_id from context>`, `category ∈ {identity, preference, goal}`.
  - `target="memory"` → `scope_type="agent"`, `scope_id = <agent_id from context>`, `category ∈ {project, environment, instruction}`.

  The internal write maps to `Store.remember` with a freshly-allocated key (Q6); the row's `id` is returned to the reviewer for any same-pass follow-up. The 8-category schema is intentionally narrowed for the reviewer: `correction` and `episode` are not in the enum (corrections are implied by `replace`/`archive`; episodes are event-shaped, not durable gist content).

- **`memory_review.replace(id, value)`** — overwrite the value of an existing row, **preserving its id, scope, and bucket/category**.
- **`memory_review.archive(id, reason)`** — soft-delete: set `archived_at = now()`, `archived_by = 'memory_reviewer'`, `archive_reason = reason`. Row is excluded from `PromptFiles.rebuild` and from `memory_recall` results.

`Admission` continues to gate writes for trust (it refuses promoting `instruction`/`correction` from low-trust channels) and now also gates `replace`/`archive`. Cross-scope safety is enforced at fetch time: the reviewer's input only contains rows for the current `(agent_id, owner_id)`, so it cannot target rows it does not own.

Schema delta on `memories`:

```sql
ALTER TABLE memories ADD COLUMN archived_at TEXT;
ALTER TABLE memories ADD COLUMN archived_by TEXT;
ALTER TABLE memories ADD COLUMN archive_reason TEXT;
```

Render and recall add `WHERE archived_at IS NULL`. `fermix memory restore <id>` clears the three columns.

### 4.6 Render-on-write + runtime-context invalidation

After the reviewer applies its operations, if at least one op succeeded:

1. Trigger `PromptFiles.rebuild/4` for the affected `(agent_id, owner_id)`.
2. **Invalidate `MainAgent`'s per-agent `RuntimeContext` cache** so the next user turn rebuilds the cached prompt from the new gist on disk. Without this step, the rebuilt `.md` only updates disk and the live prompt continues to use the stale cached context until the daemon restarts.

The invalidation reuses Fermix's existing context-reload mechanism for skill/plugin changes (if a unified path doesn't yet exist, M7.6 introduces one — `RuntimeContext.invalidate(agent_id)` or equivalent broadcast). It is **lazy**: the next user turn pays a context-rebuild cost; intermediate turns are not affected because the reviewer runs in the background after a reply, not mid-turn.

**Retire `Memory.Scheduler`'s periodic timer** and `prompt_files_rebuild_hours` outright (no fallback). No clock-based re-render.

Prefix-cache impact: invalidating the runtime context will cause one provider prefix-cache miss on the next turn after a successful review (the cached prefix changes when memory changes). Acceptable at the cadence we're targeting (≤ 1 invalidation/day per active conversation).

### 4.7 Archived rows: render & recall filters

- `PromptFiles.load_memories` adds `WHERE archived_at IS NULL` to the row fetch.
- `memory_recall` (`tools/memory_recall.ex`) appends the same filter to its FTS query.
- Job-scoped memory reads (`memory_recall` invoked from a scheduled-job runner) also exclude archived rows by default.

This is the single biggest robustness win: a mis-archived row is **recoverable** (the data is still in the DB) and audit-traceable via `archived_by`, `archive_reason`, `archived_at`.

### 4.8 Caps

Keep current caps (`prompt_user_token_cap` 800, `prompt_memory_token_cap` 1600 → ≈3200/6400 chars). The reviewer is told the remaining budget and must consolidate to fit; render-time trimming (`fitting_item_count`) stays as a backstop but should rarely fire once the reviewer is budget-aware.

### 4.9 Config changes (`config/config.exs` + `memory/config.ex`)

```diff
 config :fermix_core, :memory,
   ...
-  extraction_debounce_seconds: 86_400,
+  review_interval_hours: 24,             # 0 disables the background reviewer
   ...
-  prompt_files_rebuild_hours: 12,
   ...
+  review_max_messages: 40,               # input cap (messages per pass)
+  review_input_token_budget: 4_000,      # input cap (tokens per pass)
+  review_failure_backoff_ms: 300_000,    # 5 min cooldown after a failed review
```

Delete the `extraction_debounce_*` and `prompt_files_rebuild_*` accessors (no fallback retained). Add `review_interval_hours/1` (default 24, validated non-negative integer), `review_max_messages/1`, `review_input_token_budget/1`, and `review_failure_backoff_ms/1` (default 5 minutes, mirroring the compaction backoff pattern). **Keep** `extraction_timeout_ms` and `extraction_min_confidence`. The setup wizard/web UI is **unaffected** — the cadence was config-only.

### 4.10 Manual trigger

```
fermix memory review --now [--conversation <channel>:<chat_id>[:<thread>]] [--agent <agent_id>] [--owner <owner_id>]
```

Runs the reviewer once for the specified scope (or all `(agent, owner, conversation)` rows with unreviewed messages, if omitted), **bypassing both the interval and failure-backoff gates** but **still respecting the activity gate** (no run when there's nothing new). Wired through the same code path as the background trigger (one review function, two entry points).

### 4.11 Two gist buckets

The reviewer thinks in **two buckets** (`user-profile` vs `working-notes`), which map onto a constrained subset of the existing DB category set per §4.5. We do **not** flatten the 8 categories in v1 — they remain as DB metadata; only the gist-rendering uses the bucket split, and only 6 of the 8 categories are reachable through `memory_review.add`.

### 4.12 Telemetry
- `[:fermix, :memory, :review]` — `%{duration_us, ops_added, ops_replaced, ops_archived, input_messages, input_tokens}`, metadata `%{agent, owner, conversation_key, interval_hours, fired: true, status}`.
- `[:fermix, :memory, :review_skipped]` — `%{count: 1}`, metadata `%{reason: :no_new_messages | :under_interval | :in_failure_backoff | :disabled | :concurrent_run}`.
- `[:fermix, :memory, :runtime_context_invalidated]` — `%{count: 1}`, metadata `%{agent, owner, trigger: :memory_review}`.
- Per-op audit log entries record before/after row ids (not raw values where avoidable) for `archive`/`replace`.

## 5. Open Decisions
- **Q1. Flatten DB categories?** Recommend *no* for M7.6 — keep the 8 categories as metadata, render via the two buckets. Revisit separately.
- **Q2. Trigger predicate is swappable.** v1 is `(elapsed ≥ interval) ∧ has_new_messages ∧ not_in_failure_backoff`. A future signal-gated turn predicate (cheap salience gate over new messages) lands when heartbeat introduces a cheap reviewer model. Decision: keep the predicate behind a single function so the swap is one site.
- **Q3. Reviewer model.** Main model for now (decided). A per-task model knob is deferred to heartbeat.
- **Q4. Fate of `extraction_model`.** With the reviewer on the main model, the existing `extraction_model` knob is unused — recommend: leave inert and documented; heartbeat will give it a home.
- **Q5. Restore path.** Ship `fermix memory restore <id>` with v1 (small surface, completes the archive story).
- **Q6. `add` row identity.** Today `Store.remember` upserts by key. For reviewer `add`, derive a fresh key from value content + timestamp suffix so two `add`s never collide. Confirm key-derivation strategy at implementation.
- **Q7. Runtime-context invalidation API.** If Fermix already has a unified reload path for skill/plugin changes, reuse it; otherwise M7.6 introduces `RuntimeContext.invalidate(agent_id)` (or per-`(agent, owner)`). Confirm at the start of Stage 4.

## 6. Stages
1. **Schema + config swap** — `ALTER TABLE memories ADD ...` × 3; `CREATE TABLE memory_review_state` with `(agent_id, owner_id, channel, chat_id, thread_scope)` PK and the failure columns; in `config.exs` add `review_interval_hours` / `review_max_messages` / `review_input_token_budget` / `review_failure_backoff_ms`, delete `extraction_debounce_seconds` and `prompt_files_rebuild_hours`; in `memory/config.ex` add the new accessors, delete the old ones. Tests: defaults, validation, schema migration.
2. **Review state + trigger predicate** — `MemoryReviewState` Repo accessors; replace `ExtractionDebouncer.request` at `main_agent.ex:1171` with the new predicate (time + activity + failure-backoff, behind a swappable function). Tests: fires when all three conditions hold; skips with each `:reason`; `0` disables; pointer advances only on `:ok`/`:nothing_to_save`; pointer untouched on `:failed`, `failure_count` increments + backoff applies; survives restart.
3. **Reviewer + restricted tool surface** — `memory_review.{add,replace,archive}` tools registered with `policy_class: :read_write`; constrained-enum categories per bucket (§4.5); bounded input builder with full per-entry metadata (`(id, bucket, scope, category, key, value)`); raw tool outputs excluded; `Admission` gates `replace`/`archive` and validates the `add` enum. Tests: id-targeted ops, `replace` preserves id/scope/category, `archive` sets tombstone, `add(user, …)` writes to owner scope with allowed category, `add(memory, …)` writes to agent scope with allowed category, "Nothing to save".
4. **Archive filters + render-on-write + ctx invalidation** — `PromptFiles.load_memories` and `memory_recall` filter `archived_at IS NULL`; on successful ops, rebuild then invalidate the per-agent runtime context (reuse existing reload path or introduce `RuntimeContext.invalidate/1`, per Q7); remove `Memory.Scheduler` periodic timer. Tests: archived rows excluded from gist and recall; rebuild fires only on changes; **the very next user turn's prompt to the provider contains the updated memory** (no daemon restart required); no periodic rebuild scheduled.
5. **Manual CLI + restore + telemetry + docs** — `fermix memory review --now`, `fermix memory restore <id>`; telemetry events; CHANGELOG; update `MILESTONE_4_ADVANCED_MEMORY.md` cross-ref.

## 7. Test Plan
- **Cadence:** interval not elapsed → skip (`reason: :under_interval`); interval elapsed but no new messages → skip (`reason: :no_new_messages`); in failure backoff → skip (`reason: :in_failure_backoff`); all gates pass → review fires once per pass; `0` disables; `--now` bypasses interval + backoff but still respects activity.
- **Failure semantics:** stub the reviewer to return `:failed` → `last_reviewed_message_id` and `last_reviewed_at` unchanged, `failure_count` incremented, `last_review_failed_at` set; next eligible time gated by `review_failure_backoff_ms`. A subsequent `:ok` resets `failure_count` to 0.
- **Review state durability:** state survives a simulated restart; `last_reviewed_message_id` advances only by reviewed-count on success; backlogs > `review_max_messages` drain across passes (oldest first); concurrent triggers for the same key coalesce (`reason: :concurrent_run`).
- **Owner isolation:** two different `owner_id`s on the same `(channel, chat_id, thread_scope)` keep independent review pointers; one owner's review never advances the other's.
- **Scope safety:** reviewer input includes only rows for the current `(agent_id, owner_id)`; the reviewer cannot target rows outside its scope (Admission would refuse, but the fetch boundary makes attempts impossible to construct).
- **Add mapping:** `add("user", "preference", v)` writes a row with `scope_type="owner"`, `scope_id=<owner_id>`, `category="preference"`; `add("memory", "project", v)` writes `scope_type="agent"`, `scope_id=<agent_id>`, `category="project"`; an out-of-enum category (e.g. `"correction"`) is rejected before the DB write.
- **Consolidation:** `replace(id, ...)` preserves id/scope/bucket/category; `archive(id, reason)` sets tombstone; archived rows excluded from `PromptFiles` render and `memory_recall` results; `restore <id>` clears tombstone and the row reappears.
- **Selectivity/accuracy (stubbed reviewer):** "Nothing to save" → no DB writes, no render, no ctx invalidation; raw tool outputs not present in reviewer input; secrets/transient details not persisted.
- **Render-on-write + ctx invalidation:** after a successful op the next user turn's request body to the provider contains the updated `USER.md`/`MEMORY.md` content **without a daemon restart**. With the scheduler removed, no periodic rebuild is scheduled.
- **No regression:** foreground `memory_store`, `memory_recall` (now archive-aware), job-scoped memory, and the existing setup UI all behave as before.

## 8. Risk
- **Up-to-24h delay on durable corrections.** Mitigated by (i) the foreground `memory_store` tool (urgent saves immediate), (ii) `fermix memory review --now` (manual force), and (iii) the actual bug fix is consolidation, not cadence — stale rows don't survive even one pass once the reviewer is supersession-aware.
- **Reviewer mis-archives a still-valid row.** Mitigated by archive-not-delete (recoverable), `Admission` trust gating, audit telemetry on every op, and the `fermix memory restore` debug path.
- **Bounded input misses content in busy periods.** Mitigated by **incremental pointer advancement** — the next pass continues from the unscanned tail rather than skipping. Failed windows are retried, not skipped.
- **Flapping reviewer (consistent failures).** Mitigated by `review_failure_backoff_ms` (default 5 min) + `failure_count` telemetry for observability. Pointer is never advanced on `:failed`, so no window is lost — the next successful pass picks up where the last good run left off.
- **Prefix-cache miss on ctx invalidation.** One miss per successful review per active conversation (~1/day under default cadence). Acceptable trade for the consolidation actually reaching the live prompt.
- **One-way config cut.** Deleting `extraction_debounce_*` and `prompt_files_rebuild_*` (per project rules: no fallback) is staged after the new path is in place; Stage ordering enforces this.
- **Schema migration.** `ALTER TABLE memories ADD COLUMN` × 3 and one new table — small, additive, no data movement.

## 9. CHANGELOG (planned, on ship)

### Added — M7.6
- Time-based background memory reviewer (`review_interval_hours`, default 24, `0` = off; activity-gated; failure-backoff-gated; per-`(agent, owner, conversation)`).
- `memory_review_state` table keyed by `(agent_id, owner_id, channel, chat_id, thread_scope)` with `last_reviewed_message_id`, `last_reviewed_at`, `last_review_failed_at`, `failure_count`, statuses, and start/complete timestamps.
- Bounded reviewer input with incremental pointer advancement; raw tool outputs excluded; full per-entry metadata `(id, bucket, scope, category, key, value)` surfaced to the reviewer.
- `memory_review.{add,replace,archive}` restricted tool surface; ops target exact row ids; `add` constrained to per-bucket category enums.
- Archive (`archived_at` / `archived_by` / `archive_reason`) on `memories`; render and `memory_recall` filter archived; `fermix memory restore <id>` debug path.
- **Render-on-write + per-agent `RuntimeContext` invalidation** so the next user turn sees updated memory without a daemon restart.
- `fermix memory review --now` manual trigger.
- `review_failure_backoff_ms` config (default 5 minutes).
- `[:fermix, :memory, :review]`, `[:fermix, :memory, :review_skipped]`, and `[:fermix, :memory, :runtime_context_invalidated]` telemetry.

### Changed — M7.6
- Reviewer targets memory rows by **exact id**, not key — eliminates ambiguous key-only mutation.
- Reviewer input is "new since last review," not full history; raw tool outputs filtered out.
- `USER.md`/`MEMORY.md` are explicitly projections; rollback is a DB-restore operation, never an `.md` file edit.
- `last_reviewed_message_id` / `last_reviewed_at` advance only on `:ok`/`:nothing_to_save`; `:failed` increments `failure_count` and applies backoff without losing the window.

### Removed — M7.6
- `extraction_debounce_seconds` (24h debounce) and `prompt_files_rebuild_hours` (12h render timer); `Memory.Scheduler` periodic re-render.
