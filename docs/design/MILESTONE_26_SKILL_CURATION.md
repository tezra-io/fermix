# Milestone 26 — Skill Curation: Repeated-Task Mining & Skill Lifecycle

**Status:** draft (2026-07-26, rev 2 — recon-verified against the working tree; rev 2 folds a five-lens adversarial review: compaction-aware history assembly, stale-claim recovery, metadata-only owner resolution, ChannelSend dispatch seam, deferred proposals, unpark/restore reversibility, derived signature state, single-row usage counters)
**Date:** 2026-07-26
**Author:** Sujeeth
**Depends on:** M7/M7.3 skill machinery (`SkillRegistry`, skill catalog, `skill_view`/`skill_run`/`skill_create`/`skill_reload` — shipped), Memory subsystem (`Memory.Repo`, `ConversationStore` — shipped), `Memory.Reviewer` + `SoulCuration` as architectural templates (shipped), sandbox approval-button flow (shipped), `Delivery.ChannelSend` (shipped), `docs/TELEMETRY_CONTRACT.md`

**References (verified, real today):**

- `apps/fermix_core/lib/fermix_core/agents/skill_registry.ex` — three-root discovery (bundled `priv/skills` seeded by copy into `$FERMIX_HOME/skills` when empty; local dir `:operator`; plugin dirs `:guest`), one-level `*/SKILL.md` glob (`:195-199`), capability-name collision refusal (`:264-271`), structured `reload/1`
- `apps/fermix_core/lib/fermix_core/tools/skill_create.ex` — scaffold writer: `name` + `description` only, **no body argument** (`:18-30`), refuses existing dir, writes `SKILL.md` + `evals/evals.json` (`:87-140`), plain-function callable without the agent loop (`:61-63`)
- `apps/fermix_core/lib/fermix_core/prompt/runtime_sections.ex` — always-injected skill catalog, 16,384-byte cap (`:16,319-330`), guests get none (`:290`)
- `apps/fermix_core/lib/fermix_core/memory/repo.ex` — `messages` table (`:28-42`); **no created_at-range query exists today**; `claim_memory_review` takes `stale_after_ms` and reclaims stale claims (`:914-918`, `:2131-2140`) — the full pattern M26 must copy, including staleness
- `apps/fermix_core/lib/fermix_core/memory/conversation_store.ex` — compaction's `replace_history` deletes the conversation's `chat_message` rows and re-inserts normalized rows that keep only role/content/timestamp — **post-compaction rows have `metadata_json = NULL`, `sender = role string`** (`:294-308`, `:407-426`, `:541-567`, `:643-667`)
- `apps/fermix_core/lib/fermix_core/memory/compactor.ex` — the persisted checkpoint row is `role: "system"`, `kind: "checkpoint_summary"`, `sender: "compactor"` (`:321-341`)
- `apps/fermix_channels/lib/fermix_channels/gateway/source.ex` — ingress identity = metadata `user_id` falling back to metadata `sender_id`, **never the display-name `sender`** (`:37-49`)
- `apps/fermix_core/lib/fermix_core/memory/reviewer.ex` — claim-gated background pass (`:92-114`), message/token input caps (`:225-277`), single low-temperature provider call (`:791-850`), route seams + failover (`:414-469`)
- `apps/fermix_core/lib/fermix_core/soul_curation.ex` — bounded propose (no tools, no writes), strict-JSON fail-loud parse (`:341-402`), one re-prompt retry (`:226-268`), `InjectionScan` advisory (`:471-481`), telemetry run-kind (`soul_curation/telemetry.ex:21-44`)
- `apps/fermix_channels/lib/fermix_channels/gateway/commands/soul.ex` + `commands/soul/confirmations.ex` — propose → token → apply confirmation, origin-bound tokens, owner-only authorization
- `apps/fermix_channels/lib/fermix_channels/gateway/approval_button.ex` — `grant:`-namespaced button payloads, deliberately non-generic (`:6-16`); Telegram `send_approval/3` (`channels/telegram.ex:196-213`), Discord parallel (`channels/discord.ex:108-126`); **no deny button exists anywhere in the repo today**
- `apps/fermix_channels/lib/fermix_channels/gateway/channel.ex` — optional `send_approval/3` behaviour callback (`:157-167`), capability-probed via `function_exported?`; `Delivery.deliver_approval/5` plain-text degradation when absent (`gateway/delivery.ex:40-56`)
- `apps/fermix_core/lib/fermix_core/delivery/channel_send.ex` — the single proactive outbound primitive (jobs + harness); **hardwired to `adapter.send_message/3`** (`:111-117`, `ensure_adapter :209-215`) — button dispatch needs an explicit seam (§6.6)
- `apps/fermix_core/lib/fermix_core/agents/lifecycle_telemetry.ex` + `capabilities/skill.ex:123-131` — `[:fermix, :skill, :invoke]` already carries the skill name as plain (non-content-gated) metadata on every `skill_run` execution; `skill_view` has no equivalent
- `apps/fermix_core/lib/fermix_core/harness/config.ex` — the config-module pattern to copy (`@config_keys` allowlist, fail-loud `normalize/1`, one reader per key)
- `apps/fermix_core/lib/fermix_core/application.ex` — `@compiled_env Mix.env()` compile-time gating of side-effectful children out of `:test` (`:46-47`; "disabled in config/test.exs, never by omission" `:161`, `:335-337`)
- `apps/fermix_channels/lib/fermix_channels/gateway/authorizer.ex` — owner resolution via `channel_explicit_owner_user_id` (`:36-75`)
- `docs/TELEMETRY_CONTRACT.md` — new-run-kind checklist (`:85-99`), fermix_opik touchpoints (`:159-171`)

---

## 1. Problem / Goal

Fermix already self-improves on two axes: **memory** updates automatically (`Memory.Reviewer` runs after turns and folds new durable facts in) and **persona** updates on command (`/soul review` → `/soul apply`). The third axis — **capability** — is still fully manual: when the operator asks for the same not-natively-covered task again and again, nothing notices. The operator must realize the repetition themselves, then hand-author a `SKILL.md` or ask the agent to run `skill_create`.

Other stacks (Hermes-style harness agents) close this loop by silently generating skill files in the background. That is the wrong trade: the skill set grows without bound, every skill costs catalog bytes in the system prompt forever, and stale skills linger because nothing ever audits them.

**Goal of M26:** a scheduled curation pass, shipped with Fermix and on by default, that

1. every 15 days mines the operator's recent conversation history for **repeated tasks with no existing skill/tool coverage**,
2. **proposes** (never silently creates) at most a handful of new skills over the owner's channel with approve/deny buttons,
3. on approval drafts the skill body and creates it through the existing `skill_create` writer into `$FERMIX_HOME/skills/<name>/`, where the registry and catalog pick it up, and
4. audits the skills it previously created for **staleness**, proposing update or reversible archive — again only ever with owner approval.

The design goal opposite to Hermes: **bounded, evidence-gated, owner-approved, reversible.** Every cap in §10 exists to keep the skill inventory small and the catalog cheap.

## 2. Current state, verified

| Mechanism | Today | M26 impact |
|---|---|---|
| Skill discovery | `SkillRegistry` scans bundled + `$FERMIX_HOME/skills` + plugin dirs; one-level `*/SKILL.md` glob; local dir is `:operator` trust | Created skills land in the local dir and are discovered on `reload`; `_archive/<name>/` (two levels deep) is naturally invisible to the glob |
| Skill creation | `skill_create` tool scaffolds frontmatter + placeholder body; **no body argument**; plain-function callable; does not auto-reload; name regex permits `_archive` | Extract a shared scaffold writer that accepts a body (§6.8); reserve leading-underscore names (§6.4, §6.8) |
| Skill usage signal | `skill_run` executions emit `[:fermix, :skill, :invoke]` with the skill name as plain metadata; `skill_view` (the progressive-disclosure read) emits only generic `[:fermix, :tool, :exec]` whose skill identity is content-gated; trace files have no retention contract or query surface | Stage 0 adds durable counts-only usage rows (§6.9) — traces are rejected as the source on retention/queryability grounds, not signal absence (§14.6) |
| History queries | `messages` table with limit/id-cursor reads only; **no time-window query**; trust not persisted on rows; **compaction deletes raw rows, nulls `metadata_json`, rewrites `sender`, and leaves a `role: "system"` / `kind: "checkpoint_summary"` row** | Add one created_at-range query with metadata-only owner resolution **plus a checkpoint-summary select** (§6.3) |
| Background review precedent | `Memory.Reviewer`: atomic claim **with stale-claim recovery**, message/token caps, one low-temp provider call, prose = no-op | The miner copies claim + staleness + caps + route seams |
| Proposal/confirm precedent | `SoulCuration`: propose (no tools/no writes) → ETS token (TTL 300s, origin-bound) → `/soul apply`; strict-JSON fail-loud + one re-prompt; `InjectionScan` advisory | The miner copies the call shape; proposals persist in SQLite instead of ETS because they must survive days, not minutes (§6.5) |
| Approve buttons | Sandbox grants only: `ApprovalButton` (`grant:` namespace, explicitly non-generic), optional `send_approval/3` channel callback (Telegram + Discord), plain-text `/confirm <token>` elsewhere; **no deny button, no proactive (outbound-initiated) button message** | New `ProposalButton` namespace + one optional channel callback, dispatched through a new `ChannelSend` seam (§6.6) |
| Proactive outbound | `Delivery.ChannelSend.send/5` (jobs + harness share it) — invokes `adapter.send_message/3` only; jobs resolve targets via `Jobs.DeliveryDefaults`, which yields mode `"none"` when `[fermix_core.jobs] default_delivery_target` is unset (the default install) | Curation defines its own deterministic target resolution with an owner-privacy check (§6.6) and extends `ChannelSend` with an explicit callback-dispatch seam |
| Scheduling | `Jobs.Scheduler`/`Runner` run **agent-loop tasks** (`task_prompt` → `AgentLoop.run`) with delivery modes; no code-target job kind; no system-seeded job precedent | Curation is a deterministic pipeline with one bounded provider call — it gets its own tiny clock (§6.2), not a `scheduled_jobs` row (§14.2) |
| Config | `Harness.Config` pattern: `@config_keys` allowlist, fail-loud normalize, `enabled` default true precedent; side-effectful children are compile-time gated out of `:test` | `[fermix_core.skill_curation] enabled` (§6.1) with `@compiled_env` + `config/test.exs` gating |

## 3. Decisions locked (operator, 2026-07-26)

1. **Cadence: every 15 days, on by default.** The cadence is an internal constant, not a knob. Enable/disable is the only switch.
2. **Config entry + personalization.** `[fermix_core.skill_curation]` with `enabled` (default `true`) in `config.toml`; surfaced as one yes/no in the setup personalization flow (§6.1). Backend ships first; the setup card is the last stage (backend-before-setup rule).
3. **Staleness audit covers curation-created skills only.** Hand-authored and bundled-seeded skills are never flagged. The ledger (§7) is the authoritative record of what curation created.
4. **Outline at proposal, body after approval.** The proposal message carries name, task pattern, evidence, and an outline. The full `SKILL.md` body is drafted only after approval — no drafting cost for denied proposals.
5. **Archive, never delete.** Approved removals move the skill directory to `$FERMIX_HOME/skills/_archive/<name>/`; restore is one command. Purging the archive is a manual operator action outside Fermix.

## 4. Scope and non-goals

### In scope

- `SkillCuration` subsystem in `fermix_core`: config, 15-day scheduler with crash recovery, history assembly, mining pass, proposal store, creation pass, staleness audit, archive/restore/unpark.
- Gateway surface in `fermix_channels`: `/skills` command family, `ProposalButton`, one optional channel callback for two-button proposal messages (dispatched through `ChannelSend`), Telegram + Discord implementations.
- Skill-usage counters (Stage 0) so staleness is measurable at all.
- Telemetry run-kind `skill_curation` + `fermix_opik` mapping, per contract.
- self_knowledge update, eval-seeder guard, hermetic tests.

### Non-goals

- **No autonomous skill creation.** Nothing is ever written to the skills directory without an explicit owner approval in this cycle. There is no "auto-approve" mode.
- **No audit of hand-authored, bundled, or plugin skills** (decision 3). A later milestone may widen scope; the auditor takes the skill set from the ledger, so widening is additive.
- **No generic confirmation framework.** The sandbox and soul confirmation stores stay as they are; M26's pending state lives in its own SQLite rows following the same per-feature pattern (§14.3).
- **No cross-operator skill sharing, no skill marketplace, no quality scoring.**
- **No mining of guest/group-authored content** as evidence (§8; forwarded-message residual risk named there).
- **No `fermix skills` CLI verbs** (M7.3 §5.8 territory) — M26's operator surface is the chat command + config.
- **No mining of traces or realtime-voice transcripts** — the pass reads persisted history rows (`chat_message` + `checkpoint_summary`) only.
- **No compaction changes.** Preserving per-message sender/metadata through compaction was considered and rejected (§14.10); compacted spans are represented by their checkpoint summaries instead.

## 5. Architecture overview

Two flows share one pipeline skeleton. Everything left of "deliver" is deterministic code except the single bounded miner call; everything right of "approve" is deterministic code except the single bounded drafting call.

```
                     ┌──────────────────────────────────────────────────────┐
 15-day clock ──────▶│ CYCLE (SkillCuration.run_cycle/1)                    │
 /skills review ────▶│                                                      │
                     │ 0 sweep stale state     (stuck claims, stuck         │
                     │                          'creating' rows, expiry)    │
                     │ 1 deliver deferred      (last cycle's overflow,      │
                     │                          counts against the cap)     │
                     │ 2 assemble history      (trailing 30d: owner turns   │
                     │                          + checkpoint summaries)     │
                     │ 3 assemble inventory    (skills + capabilities +     │
                     │                          signature dispositions)     │
                     │ 4 MINE — one provider call, no tools, strict JSON    │
                     │          (skipped when deferred filled the cap)      │
                     │ 5 validate + cap        (m-ref grounding ≥3,         │
                     │                          dedupe, ≤3 new/update)      │
                     │ 6 audit ledger skills   (usage counters, ≤2 archive) │
                     │ 7 persist proposals     (SQLite, tokenized)          │
                     │ 8 deliver               (buttons or /skills text)    │
                     └──────────────────────────────────────────────────────┘
                                          │
              owner taps ✅ / ❌  or types /skills approve|deny <token>
                                          │
                     ┌──────────────────────────────────────────────────────┐
                     │ ACTION (Commands.Skills → SkillCuration)             │
                     │                                                      │
                     │ deny    → proposal declined (recoverable: unpark)    │
                     │ approve (new_skill)    → CREATE: ledger row first,   │
                     │           one drafting call, shared scaffold writer, │
                     │           reload, ledger active, confirmation        │
                     │ approve (update_skill) → same, prior body            │
                     │           snapshotted, atomic rename swap            │
                     │ approve (archive)      → move dir to _archive/,      │
                     │           reload, ledger update, confirmation        │
                     └──────────────────────────────────────────────────────┘
```

Modules (deliberately few — the Reviewer/SoulCuration precedent is one pipeline module plus small satellites): facade `FermixCore.SkillCuration` (owns `run_cycle`, including history assembly and the audit rule as private sections), `SkillCuration.Config`, `SkillCuration.Scheduler` (GenServer), `SkillCuration.Miner` (prompt build + provider call + parse + validation), `SkillCuration.Proposals` (store ops + tokens + derived dispositions), `SkillCuration.Creator`, `SkillCuration.Telemetry`. Channel side: `Gateway.Commands.Skills`, `Gateway.ProposalButton`, adapter `send_proposal/3` implementations.

Supervision: the Scheduler is one GenServer under the core supervision tree (`:permanent`, started only when gated in — §6.1). Cycle and action work run as supervised `Task`s under the existing `FermixCore.TaskSupervisor`; crashes are detected (monitors + the stale-state sweep) and always resolve to a terminal recorded status — a crash never silently wedges the feature (§6.2, §6.8).

## 6. Component design

### 6.1 Config + personalization — `SkillCuration.Config`

Modeled line-for-line on `FermixCore.Harness.Config` (`@config_keys` allowlist so `ConfigStore` rejects typo'd keys at the parse boundary, fail-loud validators, one reader per key, string-or-atom lookup).

```toml
[fermix_core.skill_curation]
enabled = true   # the only key; absent = true
```

- `enabled?/0` default **true** (precedent: harness `enabled`). No `approved` gate: unlike the harness, curation performs no work and spends no tokens until a cycle fires, the first cycle is ≥15 days after install (§6.2), and every mutation already requires an explicit per-proposal approval — a second blanket consent gate would be a knob without a decision behind it (§14.8).
- Everything else — cadence, window, budgets, caps, thresholds, TTLs — is an internal module constant (§10). Tuning is not config (house rule: one enable per feature).
- `ConfigStore` wiring mirrors harness: snapshot, `normalize_skill_curation/1`, replace-style apply. **The key must be added to the ConfigStore allowlists** or TOML edits are silently dropped (M24's warning).
- **Child gating — three conditions, all required:** the Scheduler starts only when (a) `@compiled_env != :test` (compile-time env gate, release-safe — the Opik env-flag-is-not-an-env-gate lesson; `application.ex:46-47` precedent), (b) `SkillCuration.Config.enabled?()`, and (c) memory persistence is on (`Memory.Config.enabled?()` — every M26 surface lives in `memory.db`; with memory off the Scheduler would only churn `run_error` every cycle). Belt and braces: `config/test.exs` also sets `enabled = false` explicitly ("disabled in config, never by omission"). `/skills review` under disabled config replies "skill curation is disabled in config"; under disabled memory, "skill curation requires memory persistence".
- **Personalization:** one yes/no in the setup wizard ("Every couple of weeks, Fermix can look for tasks you repeat and offer to learn them as skills — with your approval each time. Proposals will arrive in <resolved owner channel>. Enable?"), answer key `:skill_curation_enabled`, written via a `put_skill_curation_key/2` writer exactly like `put_harness_key`; declining writes `enabled = false`, accepting writes nothing (default already true). Web-setup parity card follows in the final stage (§13), after the backend exists.
- Disabled semantics: no Scheduler child; pending proposals stop being actionable except `deny`.

### 6.2 Scheduling — `SkillCuration.Scheduler`

A deliberately tiny GenServer. Not a `scheduled_jobs` row (rejection rationale §14.2).

- State row `skill_curation_state` (§7) holds `last_cycle_at`, `retry_at`, `claimed_at`, `status`, `last_status`. On first boot (no row) `last_cycle_at` is initialized to `now` — **the first cycle fires ~15 days after install**, never at first boot: a fresh home has no history worth mining, and this keeps disposable eval homes quiet by construction.
- Check discipline: one `Process.send_after` tick every 6 hours (constant). On tick: due when `now - last_cycle_at >= 15 days`, or `retry_at` has arrived. Missed ticks while the laptop slept simply run at the next tick — at a 15-day cadence there is no staleness-skip concept.
- **Claim with stale recovery** (the *full* `claim_memory_review` pattern, not just the CAS): due → claim by updating the state row to `status = 'running', claimed_at = now` guarded by `status = 'idle' OR (status = 'running' AND claimed_at < now - @claim_stale_after)`. A daemon killed mid-cycle leaves `running` + an old `claimed_at`; the next due tick reclaims it and records `last_status = 'error:stale_claim'` for the abandoned attempt. The Scheduler additionally monitors the cycle Task and, on abnormal DOWN, writes `status = 'idle'`, `last_status = 'error:crash'`, and `retry_at` per the retry rule below — so recovery normally happens in seconds and the stale-claim window is only the SIGKILL/power-loss backstop. One crash can never permanently disable curation (the admission-check pitfall applied).
- **Retry mechanism (bounded, explicit):** a **scheduled** cycle writes `last_cycle_at = now` on *every* terminal outcome, success or error — the cadence clock always advances. `run_error` sets `retry_at = now + 12h` **only when the attempt was cadence-due** (`retry_at` was unset at claim time); a retry-due attempt clears `retry_at` and never sets it again regardless of outcome. Net: at most two attempts per 15-day period, enforced by state transitions, not by convention. (One explicit, visible retry — not a silent chain; the cron-`:timeout` lesson.)
- `/skills review` (operator command, §6.7) calls the same `run_cycle/1` with `trigger: :manual`. Manual success advances `last_cycle_at` (restarting the cadence clock); manual failure does not (the operator will simply re-run). Because the mining window is a fixed trailing 30 days (§6.3) and dedupe is disposition-driven (§6.4), running review twice back-to-back re-mines the same window and correctly reports "nothing new".
- **Cycle-start sweep** (step 0 in §5): expire superseded proposals (§6.5), resolve stuck `creating` ledger rows (§6.8), reclaim stale claims — three bounded UPDATE/scan passes, no sweeper process.

### 6.3 History assembly (private to the facade/Miner)

- **New Repo queries** (the only schema-adjacent read additions), both `created_at`-range over the trailing window:
  1. **Owner turns:** `role = 'user'`, `kind = 'chat_message'`, ordered ascending, owner-resolved per row (below).
  2. **Checkpoint summaries:** `kind = 'checkpoint_summary'`, owner-resolved at *conversation* granularity (below). Compaction deletes raw rows and strips the surviving copies' metadata (`conversation_store.ex:294-308, 643-657`), so summaries are the only durable representation of compacted spans — the busiest conversations would otherwise mine to zero.
- **Owner resolution — metadata ids only, mirroring ingress exactly** (`Gateway.Source`: metadata `user_id`, falling back to metadata `sender_id`; `source.ex:37-49`): a row qualifies when its `metadata_json` id matches the channel's configured `channel_explicit_owner_user_id`, or its channel is local (`cli`/`daemon` — `ChannelRegistry.local?`). **The display-name `sender` column is never consulted** — it is sender-controlled text (Telegram stores username/first_name there) and using it would both diverge from ingress and let a guest with a crafted display name pass as owner. Rows with no metadata id are excluded: under-mining is the accepted failure direction.
- **Checkpoint conversation-granularity rule:** a `checkpoint_summary` row is included only when its conversation is owner-private — a local channel, or a DM conversation on an owner-configured channel (`chat_id` equals the configured owner user id — the Telegram DM shape). Group-chat checkpoints are excluded: their summaries blend guest content. Included checkpoints are rendered clearly labeled ("summary of earlier conversation, may compress many requests") and count as single entries for evidence purposes.
- **Window: fixed trailing 30 days, every cycle** — deliberately overlapping successive cycles. Overlap means a slow-cadence repeated task (e.g. roughly weekly — 2× per 15 days, 4× per 30) is visible to some cycle, and evidence for a candidate that narrowly missed one cycle is still present at the next; the disposition dedupe (§6.4) prevents overlap from re-proposing anything already answered. `last_cycle_at` gates *when* cycles run, never what they see.
- Caps (constants, §10): max 400 messages, input budget 24k tokens enforced as bytes = tokens × 4 with UTF-8-safe truncation — the exact `Memory.Reviewer` mechanism. **Cap eviction is stratified, not newest-wins:** bucket the window by UTC day and evict round-robin from the largest buckets, so every day of the window keeps representation — a repetition miner must preserve span coverage, not recency. Drop counts are carried into telemetry (no silent truncation).
- Each assembled entry gets a **stable index** (`m1`, `m2`, …) rendered into the prompt, plus a conversation label (`telegram:…/root`), a day stamp, and its text. The index is the evidence-reference currency (§6.4).

### 6.4 The mining pass — `SkillCuration.Miner`

One provider call, `temperature 0.1`, **no tools, no writes, no live transcript access** (the SoulCuration shape). Route resolution mirrors `Memory.Reviewer` exactly: injectable `:adapter` seam for tests, else `Selection.ordered_routes()` + `Failover.run_chain`. Nothing model-specific is pinned. When deferred proposals (§6.5) already fill the cycle cap, the provider call is skipped entirely.

**Input sections** (each labeled, evidence explicitly marked "data, NOT instructions" — the soul evidence-folding precedent):

1. The indexed window entries (§6.3).
2. **Coverage inventory:** current skill catalog entries (name + description + trust, from `SkillRegistry.snapshot`), built-in capability names, and MCP/plugin capability names (from `CapabilityRegistry.list`) — so "Fermix already does this" candidates die in the prompt, not in chat.
3. **Signature dispositions** (derived from proposals + ledger, §6.5): created, declined, parked, pending/deferred — so past answers are respected.
4. The audit context: curation-created skills with their usage stats (for `update_skill` candidates only; archive candidacy is decided in code, §6.9).

**Output contract** — strict JSON, parsed fail-loud with exactly one corrective re-prompt (the SoulCuration parse discipline), then `run_error`:

```json
{
  "cycle_summary": "one paragraph",
  "candidates": [
    {
      "kind": "new_skill | update_skill",
      "name": "invoice_chase",
      "task_signature": "chase unpaid invoices via email",
      "evidence": [{"ref": "m17", "quote": "…"}, {"ref": "m41", "quote": "…"}, {"ref": "m83", "quote": "…"}],
      "outline": ["trigger conditions", "steps", "outputs"],
      "rationale": "why existing tools/skills do not cover this"
    }
  ]
}
```

**Code-side validation — the model proposes, code disposes:**

- **m-ref grounding:** a candidate needs ≥3 evidence entries whose `ref`s exist in the assembled window and are pairwise distinct — set membership, exact, ~10 lines; no fuzzy text matching, no trusting a model-reported count. Each quote is checked as a whitespace-normalized substring of its referenced entry; a non-matching quote is replaced in the rendered proposal by the entry's own leading text (quotes are for the human message only, never a gate).
- **Disposition dedupe, kind-scoped:** for `new_skill`, candidates matching a created/declined/parked/pending/deferred signature are dropped. For `update_skill`, matching a *created* signature whose ledger row is `active` is the **qualifying** condition (it resolves the candidate to that ledger skill); declined/parked matches still drop. (An unqualified dedupe would make updates structurally impossible — the candidate's signature *is* the created signature.)
- `name` validated against the skill-name regex, **a leading-underscore reservation** (`_archive` and friends must never become live skills — §6.9), existing skill names, and registered capability names (the registry's own collision rule, applied early).
- Caps: ≤3 `new_skill`+`update_skill` proposals delivered per cycle (deferred first, then fresh); valid fresh candidates beyond the cap become `deferred` proposals for the next cycle (§6.5). Everything dropped or deferred is counted in telemetry metadata.

An empty window, zero candidates, or all-filtered results is a successful cycle (`run_complete` with zero proposals), not an error.

### 6.5 Proposal store + tokens — `SkillCuration.Proposals`

Proposals must survive daemon restarts and stay actionable for days — ETS (the sandbox/soul choice for 60s/300s tokens) is wrong here. Proposals live in `memory.db` (§7). **The proposal rows are the only signature state** — dispositions are derived, never stored twice (rule 5):

- `created(sig)` ⇔ a ledger row carries the signature; `declined(sig)` ⇔ a `declined` proposal row exists (not cleared); `parked(sig)` ⇔ ≥2 `expired` rows exist (not cleared); `pending/deferred(sig)` ⇔ such a row exists. One indexed query family over `proposals.task_signature` + the ledger; the miner's disposition prompt section is built from the same queries.
- Token: 8-char Base32 of 5 random bytes (the shipped token recipe), unique per proposal, stored on the row. The row **is** the pending record; there is no second store.
- States: `pending → approved | declined | expired | failed`, plus `deferred → pending` (next-cycle delivery) — single-use action semantics via a guarded UPDATE (`… WHERE token = ? AND status = 'pending'`), the peek/validate/take discipline in SQL.
- **Deferred carry-over:** valid candidates beyond the per-cycle cap persist as `deferred` (cap 3; beyond that dropped + counted). The next cycle delivers deferred proposals first — already validated, no re-qualification — against its cap. A deferred proposal not delivered within 2 cycles expires.
- TTL: pending proposals from cycle N expire at cycle N+1's sweep (superseded), or after 30 days, whichever first.
- **Decline is an answer, not a death sentence:** a declined signature is never *auto*-re-proposed, but `/skills unpark` (§6.7) clears the disposition — clearing sets `disposition_cleared_at` on the relevant rows, preserving the original status for audit while removing them from the derivation queries. **Ignoring is a signal:** a signature expired twice is parked — visible in `/skills proposals`, never proposed again unless unparked. The anti-spam contract: the same idea can occupy chat at most twice without an explicit operator reset.
- **Archive-proposal cool-down (derived):** at most one `archive_skill` proposal per skill per 60 days — any terminal archive proposal row (declined *or* expired) for that skill inside the window suppresses the next (nobody gets nagged every cycle about the same unused skill).
- Origin fields (`channel`, `chat_id`) are stamped at delivery time and validated on action (§6.7).

### 6.6 Delivery + buttons — `Gateway.ProposalButton`, `ChannelSend` dispatch seam

One proposal = one message: task pattern, evidence count ("asked 4× in the last month"), up to two short verified quotes (≤200 chars, injection-scanned, rendered visibly as quotes), the outline, and the action affordances.

- **Target resolution — one deterministic precedence, evaluated once per cycle:** (1) the configured `[fermix_core.jobs] default_delivery_target` when set **and** it passes the owner-privacy check below; (2) otherwise the derived owner inbox: among channels with a configured `channel_explicit_owner_user_id`, pick in a fixed documented order (telegram, discord, then remaining alphabetically) and target the owner DM (chat_id = owner user id — the Telegram shape; Discord DM-channel derivation is open question 2); (3) nothing resolvable (no owner-configured remote channel at all — e.g. CLI-only installs) → the cycle completes with `delivery_status: no_delivery_target`, proposals stay `pending` and are listed by `/skills proposals` from any owner conversation, and a doctor check names the situation and the fix. This is configuration precedence resolved up front — one send path, not a runtime fallback chain. Without this ladder the default install (which never sets the jobs delivery target) would mine forever and deliver nothing.
- **Owner-privacy check (invariant 9 made real):** the resolved target must be owner-private — a local channel, or a DM whose chat_id equals the channel's configured owner user id. Proposals quote the owner's own private messages; a group target (legitimate for jobs) is treated as unresolvable at step (1) and skipped, never sent to.
- **Buttons.** New module `FermixChannels.Gateway.ProposalButton`, payload namespace `skillcur:` with an action verb — `skillcur:a:<token>` / `skillcur:d:<token>`. `ApprovalButton`'s `grant:` namespace is untouched (its own docs demand exactly this separation). Tap → synthesized inbound message `/skills approve <token>` or `/skills deny <token>` — **the typed command is the single code path; buttons only type it for you** (the sandbox flow's exact convergence property).
- **Channel behaviour:** one new optional callback, `send_proposal(target :: map(), text :: String.t(), token :: String.t())` — target-addressed (proactive: there is no inbound `Message.t()` to reply to, which is why `send_approval/3` cannot be reused), and taking the bare token so each adapter builds its own two-button row via `ProposalButton.approve_payload/1` / `deny_payload/1`, exactly the `send_approval` convention (no generic buttons-list parameter — §14.11).
- **Dispatch through the shared primitive, explicitly:** `ChannelSend` today hardwires `adapter.send_message/3` (`channel_send.ex:111-117`), so M26 adds a narrow seam: `ChannelSend.send/5` accepts `dispatch: {:send_proposal, token}`; `ensure_adapter` then validates `send_proposal/3` is exported and the retry/rescue loop wraps that call instead. Capability is probed *before* composing (`function_exported?(adapter, :send_proposal, 3)` — the shipped probe pattern): button-capable adapters get button text + dispatch; all others get the same message via plain `send_message` with `/skills approve <token> · /skills deny <token>` spelled out. One primitive, capability-branched rendering — the `request_directory_access` precedent, not a second flow.
- Implemented for Telegram (`inline_keyboard` row of two; callback parsing extended to route `skillcur:` payloads; `answerCallbackQuery` + keyboard strip on tap, both buttons vanish — the shipped ack behavior) and Discord (two components).
- This introduces the repo's **first deny button**. Deny must ack visibly and name the recourse: "Noted — I won't suggest that again. (`/skills unpark <token>` undoes this.)"

### 6.7 The `/skills` command — `Gateway.Commands.Skills`

Registered in `Commands.Registry.@default_commands`. All subcommands `Authorization.operator_only/3` (mutating personalization surface; the guest allowlist never applies — the sandbox grant/confirm precedent).

| Subcommand | Effect |
|---|---|
| `/skills review` | Run a cycle now (`trigger: :manual`). Replies with the cycle summary or "nothing new". |
| `/skills approve <token>` | Validate (status `pending`, not expired, origin match when the proposal was button-delivered to a chat — same-origin channel+chat check, soul-style; a proposal listed via `/skills proposals` is actionable from any operator conversation and re-stamps origin) → dispatch the action (§6.8, §6.9). |
| `/skills deny <token>` | Decline (recoverable via unpark). |
| `/skills proposals` | List pending + deferred proposals with tokens, and declined/parked signatures with dates and reasons ("declined 2026-08-02", "expired twice") — the operator can always see what was answered and what was buried. |
| `/skills unpark <token-or-signature-prefix>` | Clear a declined or parked disposition (sets `disposition_cleared_at` on the matching rows) so the next cycle may re-propose once. This is the "unless the operator asks for it by hand" surface. |
| `/skills restore [<name>]` | Bare: list restorables (archived ledger skills with `archived_at`, and updated skills with snapshots). With a name: **archived skill** (ledger `archived`) → move `_archive/<name>/` back, refusing loudly if `skills/<name>/` already exists (hand-created since); **updated skill** (ledger `active` with ≥1 `<name>@<ts>` snapshot) → swap the newest snapshot over the live `SKILL.md`, snapshotting the replaced body first with a fresh timestamp so restore is itself reversible. Both reload the registry. |

Command handlers stay thin: parse + authorize + delegate to `FermixCore.SkillCuration` public functions; all state changes live in core (the one-way `fermix_core ← fermix_channels` rule).

### 6.8 Creation + update — `SkillCuration.Creator`

Runs as a supervised Task after approval; the approving chat gets an immediate "drafting…" ack and then the outcome message. **Ledger-first ordering** so a crash can never orphan a live skill outside curation's records:

1. **Ledger row first**, status `creating` (linked to the proposal). From this instant the skill name is curation-owned even if everything after crashes.
2. **One bounded drafting call** (same seams/discipline as the miner; strict JSON `{description, body_md}`; one re-prompt; fail → proposal `failed` + ledger row removed + loud message with the reason — no retry chain). Input: the proposal (signature, outline, evidence), the coverage inventory, and the SKILL.md contract summary (frontmatter fields, references convention). For `update_skill`: also the current body, with instructions to preserve intent and stay minimal.
3. **Shared scaffold writer.** Extract `FermixCore.Tools.SkillCreate.scaffold/1` (name, description, body, home) out of the tool's `execute/2`; the tool passes its placeholder body, the Creator passes the drafted body. One writer, two callers — the M7.3 §5.8 extraction rule applied. All existing validation (name regex — now with the leading-underscore reservation, existing-dir refusal, filesystem errors surfaced) stays in the shared function. A skill that appeared since proposal time → `already exists` → proposal `failed`, ledger row removed, loud message, no auto-rename (registry collision philosophy).
4. **Update path — never a `SKILL.md`-less instant:** *copy* (not move) the current `SKILL.md` to `_archive/<name>@<utc-ts>/SKILL.md`, write the new body to `SKILL.md.tmp` in the skill dir, then `File.rename` over `SKILL.md` (atomic on the same filesystem), then reload. A failure at any point leaves either the old or the new body in place, never neither.
5. `SkillRegistry`/`MainAgent` reload via the same function `skill_reload` wraps — catalog + runtime-context invalidation in one call. Then ledger row → `active` (update: `last_updated_at` set), proposal → `approved` (terminal).
6. `InjectionScan` runs over the drafted body; matches are advisory and rendered as a warning block in the confirmation (soul diff precedent).
7. Confirmation message: skill name, path, one-line description, "edit it freely; `/skills restore <name>` undoes an update or an archive."

**Crash recovery:** the approving process monitors the Task; on abnormal exit it marks the proposal `failed` and sends the loud failure message. The backstop for SIGKILL is the cycle-start sweep (§6.2): a `creating` ledger row older than `@creating_stale_after` is resolved deterministically — if `skills/<name>/SKILL.md` exists and parses, the creation actually completed and only bookkeeping died → flip to `active`; otherwise remove the partial scaffold (path-validated under the skills root) and mark the proposal `failed`. Either way the ledger stays the authoritative record (decision 3's premise holds even through crashes).

### 6.9 Staleness audit + usage counters (audit rule private to the facade)

**Stage 0 — usage counters (prerequisite, ships first):** one durable counts-only row per skill — `skill_usage(skill_name PK, views, runs, last_used_at)` — upserted via `Memory.Repo` (single-writer, like every other durable write): `views` on successful `skill_view` execution, `runs` at `Capabilities.Skill.finalize_invocation` (the single call site that already computes success for `[:fermix, :skill, :invoke]`). No content, no new telemetry events, table size bounded by the skill inventory by construction. **Failure posture:** a failed upsert logs a warning with the reason and the tool result is returned unchanged (explicit case on the write result — no bare rescue, no silent discard); counter loss degrades only staleness measurement, which the audit rule tolerates. Traces were rejected as the source on retention/queryability grounds (§14.6).

**Audit rule (deterministic, code-only — no LLM involved in deciding candidacy):** during each cycle, for every `active` ledger skill: `created_at` older than 30 days AND (`last_used_at` older than 30 days OR never used) → archive proposal (cap 2 per cycle, oldest-unused first, per-skill 60-day cool-down per §6.5; overflow counted in telemetry). The proposal message names the skill, its last-used date ("never used since created 2026-06-02"), and what archiving does (reversible, `/skills restore`).

**Approve (archive):** move `$FERMIX_HOME/skills/<name>/` → `$FERMIX_HOME/skills/_archive/<name>/` (timestamp-suffix on collision; restore picks the newest match), reload registry, ledger `archived`. The one-level `*/SKILL.md` discovery glob never descends into `_archive/<name>/SKILL.md` — archived skills vanish from the catalog with zero loader changes; a registry test pins this invariant so a future glob change fails loudly. The archive move refuses (fail loud) if a live `skills/_archive/SKILL.md` exists — impossible for curation-created content once the leading-underscore reservation (§6.4, §6.8) is in, but an operator hand-creation is not silently swallowed.

`update_skill` proposals come from the miner (§6.4), not the auditor — "stale because reality drifted" is an evidence question; "stale because unused" is a counter question. Two triggers, one proposal pipeline, one approval UX.

### 6.10 What this design adds beyond the request (improvements folded in)

1. **Usage instrumentation (Stage 0)** — without it "stale" is unmeasurable.
2. **Disposition memory with an escape hatch** — declines and parking cap proposal spam (at most two appearances per idea), while `/skills unpark` keeps every answer reversible.
3. **m-ref evidence grounding** — the model must cite ≥3 real, distinct window entries; counts can't be inflated, quotes are verified before rendering.
4. **Coverage-inventory dedupe in the prompt** — no proposals for things Fermix already does (the "not initially designed to do" clause made executable).
5. **Injection scanning + evidence labeling** — mined history is data, never instructions; drafted bodies are scanned before they can ever steer future turns.
6. **Reversibility everywhere** — archive instead of delete, pre-update snapshots, atomic body swap, two-case `/skills restore`.
7. **`/skills review`** — the same pipeline on demand, so the operator never waits two weeks to test or demo the feature.
8. **Deferred carry-over** — validated candidates beyond the cap surface next cycle instead of vanishing.
9. **Eval-home + test-env guards** (§6.1, §11) — the consent-gate-blocks-evals, env-flag-vs-env-gate, and phantom-noise lessons applied before they bite.

## 7. Data model (memory.db, `Repo.migrate` additions)

```sql
CREATE TABLE IF NOT EXISTS skill_curation_state (   -- singleton row, id = 1
  id INTEGER PRIMARY KEY CHECK (id = 1),
  last_cycle_at TEXT,            -- ISO8601; initialized to first-boot time
  retry_at TEXT,                 -- set once per period on cadence-due run_error
  claimed_at TEXT,               -- stale-claim recovery (§6.2)
  status TEXT NOT NULL DEFAULT 'idle',   -- idle | running
  last_status TEXT,              -- ok | error:<kind> (no_delivery_target is a
                                 --   delivery_status, not an error)
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS skill_curation_proposals (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  token TEXT NOT NULL UNIQUE,            -- 8-char Base32
  cycle_session_id TEXT NOT NULL,
  kind TEXT NOT NULL,                    -- new_skill | update_skill | archive_skill
  skill_name TEXT NOT NULL,
  task_signature TEXT NOT NULL,          -- normalized
  summary TEXT NOT NULL,                 -- rendered proposal text (sans buttons)
  outline_json TEXT,
  evidence_json TEXT,                    -- m-refs + verified quotes (local data)
  status TEXT NOT NULL DEFAULT 'pending',-- pending|deferred|approved|declined|expired|failed
  disposition_cleared_at TEXT,           -- set by /skills unpark; derivation queries
                                         --   ignore cleared rows, audit keeps status
  origin_channel TEXT, origin_chat_id TEXT,  -- stamped at delivery/action
  created_at TEXT NOT NULL, actioned_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_scp_signature ON skill_curation_proposals(task_signature);
CREATE INDEX IF NOT EXISTS idx_scp_status ON skill_curation_proposals(status);

CREATE TABLE IF NOT EXISTS skill_curation_ledger (  -- authoritative "curation owns this"
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  skill_name TEXT NOT NULL UNIQUE,
  task_signature TEXT NOT NULL,
  status TEXT NOT NULL,                  -- creating | active | archived
  created_proposal_id INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  last_updated_at TEXT, archived_at TEXT, archive_path TEXT
);

CREATE TABLE IF NOT EXISTS skill_usage (            -- one row per skill, bounded
  skill_name TEXT PRIMARY KEY,
  views INTEGER NOT NULL DEFAULT 0,      -- skill_view loads
  runs INTEGER NOT NULL DEFAULT 0,       -- skill_run executions
  last_used_at TEXT
);
```

Signature dispositions (`created`/`declined`/`parked`/`pending`/`deferred`) are **derived** from these tables (§6.5) — there is deliberately no separate signatures table (§14.12). No config beyond §6.1. No new files outside `$FERMIX_HOME` (`memory.db`, `skills/`, `skills/_archive/`).

## 8. Safety invariants (non-negotiable)

1. **Owner-approval totality.** No path writes, moves, or archives anything under `skills/` without a `pending → approved` transition caused by an operator-authorized command. There is no batch approve.
2. **Owner-attributed evidence only.** Mining input is rows attributed to the owner by channel metadata ids (the ingress derivation — never display names), plus owner-private checkpoint summaries (§6.3). Guest and unattributable rows never reach the miner; under-collection is the accepted failure direction. **Named residual risk:** text the owner *forwards* is persisted under the owner's id and can reach the miner — accepted, covered by the no-tools call shape, data-not-instructions labeling, m-ref grounding, InjectionScan, and per-proposal approval.
3. **Evidence is data.** Every prompt section carrying history is labeled non-instructional (soul precedent); the miner and drafter run with **no tools**; their output is parsed strictly and then validated/filtered in code.
4. **Injection surfacing.** `InjectionScan` over drafted bodies; advisory, surfaced in the confirmation, never silently blocking (matching soul's posture).
5. **Trust gates stack.** `/skills` is `operator_only`; button taps synthesize the same command and re-enter the same authorization; tokens are single-use, expiring, and origin-checked when chat-delivered.
6. **Bounded loops everywhere.** One miner call + one re-prompt; one drafting call + one re-prompt; at most two cycle attempts per period, enforced by state transitions (§6.2); stale-claim and stale-`creating` recovery constants; caps in §10. No unbounded anything.
7. **Fail loud, single path.** Parse failure, collision, filesystem error, unresolvable delivery target — each ends in a typed status + telemetry + (where a human is waiting) a message. No silent degradation, no alternate mechanism.
8. **Reversibility.** Archive + pre-update snapshots + two-case restore + unpark. The only operation Fermix cannot take back here is having *sent a message*.
9. **Guest invisibility, enforced.** Proposals are delivered only to owner-private targets (the §6.6 privacy check — asserted *and* checked); `/skills` output never renders for guests; curation-created skills inherit the existing catalog trust rules (local dir → `:operator`; guests already see no catalog).
10. **Tests are hermetic; test env is compile-time gated.** The Scheduler is gated out of `:test` via `@compiled_env` plus an explicit `config/test.exs` disable (never by omission). Fake `FERMIX_HOME` (put_env/on_exit dance), `FermixTestSupport.SafeRm` for cleanup, `SecretWriterStub` default untouched, provider calls only through the injectable adapter seam, defaults asserted only after establishing baseline app env (the leaked-env lesson).

## 9. Telemetry (per docs/TELEMETRY_CONTRACT.md)

- **Run kind:** `skill_curation`. Session ids: cycle `skill_curation:<cycle-rand>` (scheduled: `parent_session: nil`, root — the `:scheduled` precedent; manual: `parent_session: "command:skills:<channel>:<chat>"` — the soul precedent). Creation task: its own session `skill_curation:create:<token>` with `parent_session` = the approving command session.
- **Events** (emitted by `SkillCuration.Telemetry`, modeled on `Jobs.Telemetry`):
  - `[:fermix, :skill_curation, :run_start]` — `trigger`, `stage: :cycle | :create`, session ids
  - `[:fermix, :skill_curation, :run_complete]` — counts only: `messages_scanned`, `checkpoints_included`, `messages_dropped_caps`, `candidates`, `dropped_disposition`, `dropped_grounding`, `deferred`, `proposals_new`, `proposals_update`, `proposals_archive`, `delivery_status`
  - `[:fermix, :skill_curation, :run_error]` — `reason_kind` (`:parse`, `:provider`, `:filesystem`, `:crash`, `:stale_claim`, …)
  - `[:fermix, :skill_curation, :proposal_actioned]` — `action` (`approve | deny | unpark | expire`), `kind`, `age_ms`
- Provider calls inside miner/creator go through `Providers.Telemetry.emit_call/3` with the run's session ids (never hand-rolled). Content (evidence, drafted bodies) only under `Telemetry.capture_content?/0`, shaped with `preview/1`.
- **Registration:** events added to `Trace.TelemetryHandler.event_definitions/0` (→ `agent_event` JSONL rows); `FermixOpik.Reporter @events` + `Aggregation.apply_event/5` clauses + `infer_kind("skill_curation:" <> _) → :skill_curation`; mapper metadata allowlist extended with the count fields (allowlist rule — unlisted metadata is dropped, not an error).
- Verify discipline: telemetry assertions written red-first; `fermix_opik/test/.../aggregation_test.exs` extended for the new kind. Telemetry ships in the same stage as the run-type itself (§13 stage 4) — bookends are part of the run-kind definition, not an add-on.

## 10. Bounds (internal constants, `SkillCuration` module attrs)

| Constant | Value | Why |
|---|---|---|
| `@cycle_days` | 15 | Decision 1 |
| `@tick_interval` | 6h | Cheap due-check; sleep-tolerant |
| `@window_days` | 30 | Fixed trailing window, overlapping cycles (§6.3) — catches slow-cadence repeats; dedupe absorbs the overlap |
| `@claim_stale_after` | 1h | Reclaim a `running` claim after a hard crash (§6.2); far above any real cycle |
| `@creating_stale_after` | 1h | Resolve stuck `creating` ledger rows (§6.8) |
| `@max_messages` | 400 | Reviewer-family input cap; stratified per-day eviction |
| `@input_token_budget` | 24_000 | bytes = tokens × 4, UTF-8-safe truncation |
| `@min_evidence_refs` | 3 | "Repeated" means ≥3 distinct grounded refs, checked in code |
| `@max_skill_proposals` | 3 | new + update delivered per cycle (deferred first) |
| `@max_deferred` | 3 | carried to the next cycle; beyond that dropped + counted |
| `@deferred_max_cycles` | 2 | then expired |
| `@max_archive_proposals` | 2 | per cycle, oldest-unused first |
| `@archive_cooldown_days` | 60 | at most one archive proposal per skill per 60 days (derived) |
| `@max_signature_expiries` | 2 | then parked (derived; reset by unpark) |
| `@proposal_ttl_days` | 30 | also superseded at next cycle's sweep |
| `@unused_days_for_archive` | 30 | `last_used_at` older than this (or never) |
| `@min_age_days_for_archive` | 30 | grace period for new skills |
| `@evidence_quotes` | 2 × ≤200 chars | proposal message size + injection surface; substring-verified |
| `@reprompt_retries` | 1 | miner and drafter each |
| `@cycle_error_retry` | 1 × +12h | cadence-due failures only; state-enforced (§6.2) |

Every cap that drops something increments a `dropped_*`/`deferred` count in `run_complete` (no silent caps).

## 11. Eval, benchmark, and fresh-home behavior

- **Fresh home:** state row initialized to first-boot time → first cycle at +15 days; no history → even a manual `/skills review` completes with zero proposals. Nothing fail-closed probes a path that doesn't exist yet (the admission-check lesson): the state row is created by `Repo.migrate` at boot, the skills dir already exists via seeding, `_archive/` is created lazily on first archive.
- **Eval homes:** `benchmark/bin/seed_capability_home.py` (regenerated every `capability-daemon.sh up` — patch the generator, not the output) writes `[fermix_core.skill_curation] enabled = false`. Belt and suspenders: the +15d first cycle already makes firing impossible during an eval window, but a disabled entry also keeps `/skills` inert if a candidate model wanders into it, and keeps suite behavior independent of daemon uptime.
- **`mix test`:** the Scheduler is compile-time gated out of `:test` (`@compiled_env`) *and* disabled in `config/test.exs` (§6.1) — the real-home config-hydration leak cannot start it against a host `memory.db`. Miner/creator tests inject `:adapter` (Reviewer test pattern); no network, no host mutation.

## 12. Docs / self_knowledge updates (Execution Contract)

Shipped in the same stage as the first operator-visible surface (§13 stage 6), not deferred to the end:

- `priv/skills/self_knowledge/SKILL.md`: capability-catalog bullet (skill curation: what it does, that it proposes and never auto-creates), a prose paragraph (cycle cadence "every couple of weeks" — **no version numbers, no exact-day promises**), `/skills` in the commands list, `skill_curation` added to the config-sections line. Optional `references/skill_curation.md` if the prose outgrows a paragraph, with an index entry.
- `docs/TELEMETRY_CONTRACT.md`: add the run-kind row (events + session-id prefix), per its own instruction that new run kinds register there.
- CLAUDE.md Docs list: one line for this doc.
- fermix-site docs sync happens post-merge via the existing skill/hook (not part of this repo change).

## 13. Staged implementation plan (step → verify)

Each stage lands with its tests red-first; gates: `mix compile --warnings-as-errors`, `mix test`, `mix credo --strict`, `mix format --check-formatted`. Stages merge to dev individually; each stage is contract-complete for what it ships (telemetry with the run-type, docs with the visible surface).

| Stage | Change | Verify |
|---|---|---|
| 0 | `skill_usage` single-row table + counts-only upserts (`skill_view` success path; `Capabilities.Skill.finalize_invocation` for runs) with the log-and-continue failure posture; leading-underscore name reservation in `SkillCreate` validation; `_archive/` invisibility test pinning the discovery glob | usage rows upsert on view/run in a fake home; failed upsert logs + tool result unchanged (failing-Repo stub); `skill_create` refuses `_archive`; a skill under `skills/_archive/x/` is not discovered |
| 1 | `SkillCuration.Config` + ConfigStore allowlist wiring + application child gating (`@compiled_env != :test` AND `enabled?` AND memory enabled) + `config/test.exs` explicit disable | TOML round-trip; typo'd key rejected; child absent under `mix test`, under `enabled = false`, and under memory-disabled; default-true asserted against baseline env |
| 2 | Migrations (§7) + `Proposals` store: tokens, guarded action UPDATEs, cycle-start sweep (expiry/supersession), deferred carry, derived disposition queries, unpark clearing, archive cool-down query | state-machine tests incl. double-approve race, park-after-two-expiries, unpark→re-proposable-once, deferred delivered-first then expired after 2 cycles, 60-day archive cool-down |
| 3 | History assembly: two range queries (owner turns + checkpoint summaries) + metadata-only owner resolution + conversation-granularity checkpoint rule + stratified caps + m-indexing | guest row with owner-lookalike display name excluded; metadata-less rows excluded; DM checkpoint included + labeled, group checkpoint excluded; stratified eviction keeps every day represented; drop counts surfaced |
| 4 | `Miner` + m-ref grounding + kind-scoped dedupe + name validation + `Scheduler` (tick, claim **with stale recovery**, state-enforced retry, manual trigger, Task monitor) + `SkillCuration.Telemetry` + Trace registration + fermix_opik mapping | fake-adapter cycle tests: strict-parse + one re-prompt, ≥3 distinct grounded refs, update qualifies via created signature while new dedupes, quote substring verification; crash-mid-cycle reclaim; exactly two attempts per period under persistent failure; first-boot initializes without firing; red-first event assertions + aggregation test for `:skill_curation` |
| 5 | Delivery: target precedence + owner-privacy check, proposal rendering, `ChannelSend` `dispatch:` seam, `ProposalButton`, Telegram + Discord `send_proposal/3`, spelled-out-command text elsewhere | ladder resolution incl. group-target skipped, `no_delivery_target` path; dispatch seam validates the exported callback and wraps retry/rescue; payload parse/synthesis tests; keyboard-strip on tap (adapter-level, mocked) |
| 6 | `Commands.Skills` (review/approve/deny/proposals/unpark/restore) + registry entry + origin validation + doctor line for unresolvable delivery + **self_knowledge + TELEMETRY_CONTRACT + CLAUDE.md docs updates** | authorization tests (operator_only, guest denied); token lifecycle through the command path; proposals listing shows declined/parked with reasons; bare restore lists restorables; self_knowledge evals still pass |
| 7 | `Creator`: scaffold-writer extraction from `SkillCreate` (tool behavior unchanged), ledger-first ordering, drafting call, atomic update swap + snapshots, stale-`creating` sweep, InjectionScan, confirmation | tool regression tests still green; create/update/collision/fs-error paths; crash-between-scaffold-and-ledger resolves deterministically both directions; update→restore round-trip; archived-restore refuses when live dir exists |
| 8 | Audit rule wired into the cycle (deterministic, caps, cool-down) | archive proposals only for ledger skills matching age+unused rule; cap + ordering + cool-down respected |
| 9 | Wizard personalization question (names the resolved proposal channel) + eval-seeder `enabled = false` | wizard answer writes only on decline; seeder output contains the key |
| 10 | (last) web-setup parity card | manual check against the running web setup |

## 14. Rejected alternatives

1. **Hermes-style background auto-creation.** The founding anti-goal: unbounded inventory growth, catalog cost creep, stale-by-default skills, and skills the operator never vetted steering future turns.
2. **Riding `scheduled_jobs`/`Jobs.Runner`.** The runner executes agent-loop tasks (`task_prompt` → `AgentLoop.run` with tools); curation is a deterministic pipeline with exactly one no-tools provider call per stage. Teaching the runner a code-target job kind adds a second dispatch path to a shipped subsystem (rule 12), and job surfaces (`pause_job`/`remove_job`) would let a chat turn silently disable a shipped feature whose one switch is config. The tiny clock + claim is ~a hundred lines and owns nothing it doesn't need. Revisit only if a third code-target schedule appears.
3. **A generic confirmation framework** (unifying sandbox + soul + skills pending stores). Three similar-but-different lifetimes (60s ETS / 300s ETS / 30d SQLite) and payloads; `ApprovalButton` explicitly chose per-feature namespacing. Unification is a refactor milestone of its own; M26 follows the shipped pattern instead of redesigning it en passant.
4. **Frontmatter `origin: curation` marker** as the curation-created record. Survives nothing (any hand edit or copy loses it), requires parser awareness, and splits authority with the DB. The ledger is the single source of truth; the confirmation message tells the human.
5. **Skill versioning via the resource registry** (soul's mechanism). The registry's resource types are a closed single-file set (`soul_md`, …); skills are directories with references and evals. Timestamped snapshots + atomic swap give the needed revert for a fraction of the machinery. Real skill versioning belongs with a future M4.6 extension.
6. **Trace-mining for usage counts.** `skill_run` usage *is* first-class in traces (`[:fermix, :skill, :invoke]` carries the name un-gated), but `skill_view` identity is content-gated (off by default), trace files have no retention contract, and counting requires parsing date-partitioned JSONL. Durable counters are one upsert on an existing single-writer path.
7. **LLM-judged staleness.** "Unused past the thresholds" is a counter, not a judgment call. The LLM only ever proposes *content* (new/updated skills), never decides *lifecycle* — that keeps the audit explainable in one sentence in the proposal message.
8. **An `approved` first-use consent gate** (harness-style). The harness executes vendor CLIs on approval-by-default surfaces; curation's first token spend is ≥15 days out, visible, and every mutation is individually approved. A blanket gate would only re-create the silent-eval-blocker failure mode.
9. **Immediate first cycle at install.** Nothing to mine, guaranteed noise, and eval-home hazards.
10. **Preserving sender/metadata through compaction** so raw compacted rows stay minable. Touches a shipped subsystem (`ConversationStore.replace_history` normalization) for marginal benefit, and pre-change rows would stay unmineable anyway; including the checkpoint summaries (owner-private conversations only) represents compacted spans without modifying compaction.
11. **A generic `buttons` list parameter on the channel callback.** Both shipped `send_approval/3` implementations take the bare token and build their own platform affordance; a buttons-list moves platform rendering out of the adapter and invites arbitrary button rows — speculative generality. `send_proposal/3` takes the token; generalize if a third button kind ever appears.
12. **A `skill_curation_signatures` table.** Every disposition (created/declined/parked/pending/deferred) is derivable from the proposals + ledger rows the design already persists; a second store triplicates state (rule 5) and drifts. Derived queries + `disposition_cleared_at` for unpark keep one source of truth.
13. **Occurrence recounting by quote/text matching against the window.** Quote text never matches verbatim (paraphrase, truncation); fuzzy matching is a subsystem that silently kills honest candidates. m-ref grounding gives the same anti-inflation property exactly, in ~10 lines.

## 15. Open questions

1. **Web-setup module location** for the parity card (recon did not locate the setup page module; resolve at stage 10 — backend is unaffected).
2. **Discord proactive DM targets:** deriving a DM channel from a bare owner user id may need one adapter-side call (`send_proposal` target shape). Resolve during stage 5 against the shipped delivery config shape; until then Discord participates via a guild-channel jobs target only if owner-private (which a guild channel is not — so effectively Telegram-first).
3. **Should `/skills proposals` also show usage stats** for ledger skills ("earning its keep" view)? The single-row `skill_usage` table already holds totals + last-used; still deferred until someone asks.
4. **Signature normalization strength.** v1 is normalized-string equality for the derived-disposition queries; if parked signatures reappear with cosmetic rewording, add a code-side token-set similarity check to the dedupe. Constant-bounded either way.
