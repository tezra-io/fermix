# Fermix Roadmap — Post-MVP Features

**Last Updated:** 2026-04-05  
**Status:** Planning

This roadmap organizes features by milestone AFTER the Phase 1 MVP (single-agent Telegram bot with basic tools).

**Priority Legend:**
- **P0**: Critical for production use
- **P1**: High value, should be done soon
- **P2**: Nice to have, can be deferred

**Effort Scale:**
- **S**: Small (1-3 days)
- **M**: Medium (1-2 weeks)
- **L**: Large (2-4 weeks)
- **XL**: Extra Large (1-2 months)

**Type:**
- **Port**: Direct port from RustyClaw Elixir layer
- **Rewrite**: Rewrite from RustyClaw Rust reference
- **New**: Original feature for Fermix
- **Hybrid**: Port with significant changes

---

## Milestone 2: Multi-Agent Orchestration

**Goal:** Main Agent can delegate to ephemeral skill agents with supervision, journals, and parallel execution.

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **AgentServer port** | Port AgentServer GenServer with parent/child tracking | P0 | Port | `elixir/agent_server.ex` | M |
| **AgentSupervisor port** | Port DynamicSupervisor with `:permanent` for Main Agent, `:temporary` for skills | P0 | Port | `elixir/agent_supervisor.ex` | S |
| **AgentDefinition port** | Port with `role: :main \| :sub` field added | P0 | Port | `elixir/agent_definition.ex` | S |
| **AgentCoordinator port** | Port capability matching + ACL | P1 | Port | `elixir/agent_coordinator.ex` | S |
| **Main Agent lifecycle** | New: persistent Main Agent that receives all messages | P0 | New | `docs/MAIN_AGENT_DESIGN.md` | M |
| **Skill templates** | YAML+MD skill definition files loaded from filesystem | P0 | New | `docs/OPTION_B_ORCHESTRATION_DESIGN.md` | M |
| **SkillRegistry** | Load skill templates from `~/.fermix/skills/` | P0 | New | `docs/OPTION_B_ORCHESTRATION_DESIGN.md` | S |
| **invoke_skill tool** | Tool for Main Agent to spawn ephemeral skill agents | P0 | New | `docs/OPTION_B_ORCHESTRATION_DESIGN.md` | M |
| **Skill journals** | Markdown journals per skill instance in `~/.fermix/journals/` | P1 | New | `docs/MAIN_AGENT_DESIGN.md` | M |
| **Parallel skill execution** | Spawn multiple skills concurrently with supervision | P1 | New | `docs/MAIN_AGENT_DESIGN.md` | L |
| **Git worktree isolation** | Isolate parallel coding skills in git worktrees | P2 | New | `docs/MAIN_AGENT_DESIGN.md` | M |
| **ResourceLock port** | Port resource locking for coordinated access | P2 | Port | `elixir/resource_lock.ex` | S |
| **BtwRouter port** | Port side-channel routing (`/btw` commands) | P2 | Port | `elixir/btw_router.ex` | S |
| **MessageProvenance port** | Port message tracking/tracing | P2 | Port | `elixir/message_provenance.ex` | S |
| **TraceStore port** | Port distributed tracing for debugging | P2 | Port | `elixir/trace_store.ex` | S |

**Milestone 2 Total Effort:** ~8-12 weeks

---

## Milestone 3: Onboarding & Channel Coverage

**Goal:** First-run onboarding experience + support for all major messaging platforms.

### Onboarding

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **CLI onboarding wizard** | Interactive `fermix setup` — walks through API keys, provider selection, channel config, workspace init | P0 | New | N/A | M |
| **LiveView onboarding** | Browser-based first-run setup at localhost:4000/setup — same flow as CLI but visual | P1 | New | N/A | M |
| **Config validation** | Validate all config on startup, surface clear errors for missing/invalid keys | P0 | New | N/A | S |
| **Health check endpoint** | /health with provider connectivity, channel status, memory backend health | P1 | New | N/A | S |

### Channels

**Goal:** Support the most popular messaging platforms first. Additional channels deferred to Future milestone.

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **WhatsApp channel** | Cloud API, webhook + signature verification | P0 | Rewrite | `src/channels/whatsapp.rs` | M |
| **Discord channel** | Gateway WebSocket + REST API | P0 | Rewrite | `src/channels/discord.rs` | L |
| **Signal channel** | signal-cli integration via subprocess | P1 | Rewrite | `src/channels/signal.rs` | M |
| **Slack channel** | RTM/Events API + Bot user | P1 | Rewrite | `src/channels/slack.rs` | M |
| **CLI channel** | Interactive CLI for testing | P1 | Rewrite | `src/channels/cli.rs` | S |
| **Transcription support** | Audio transcription for voice messages | P1 | Rewrite | `src/channels/transcription.rs` | M |

**Milestone 3 Total Effort:** ~6-10 weeks

---

## Milestone 4: Advanced Memory

**Goal:** Three-tier memory architecture with intelligent extraction, gist generation, and compaction.

> **Decision Pending:** Evaluate Honcho AI (self-learning + dreaming) and wiki-style memory (lightweight LLM-wiki pattern) as alternatives to Hermes consolidation. If either proves sufficient, skip Hermes consolidation to keep the stack simpler and leaner. See Open Questions #7.

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **Hermes extraction (Phase 1)** | LLM-driven memory extraction with confidence scoring | P0 | Port | `elixir/hermes/` + `docs/hermes-memory-design.md` | L |
| **Hermes consolidation (Phase 2)** | Memory deduplication and merging *(may be replaced by Honcho AI or wiki-style memory)* | P0 | Port | `elixir/hermes/` | M |
| **Hermes decay (Phase 3)** | Confidence decay over time | P1 | Port | `elixir/hermes/` | S |
| **Honcho AI integration** | Self-learning memory with dreaming capability — heavier Docker image but strong autonomous learning | P1 | New | [honcho.dev](https://honcho.dev) | M |
| **Wiki-style memory** | Lightweight LLM-wiki pattern for capturing important bits — integrable from existing skill | P1 | New | `skills/llm-wiki/SKILL.md` | S |
| **Gist generator** | Tier 1 cohesive memory document (always in context) | P0 | New | `docs/MAIN_AGENT_DESIGN.md` | M |
| **Daily memory storage** | Tier 2 structured storage by date | P1 | New | `docs/MAIN_AGENT_DESIGN.md` | S |
| **Context compaction** | Tier 3 compaction with token counting | P0 | New | `docs/MAIN_AGENT_DESIGN.md` | M |
| **SQLite backend** | SQLite storage with FTS5 + embeddings | P0 | Rewrite | `src/memory/` | L |
| **Embedding search** | Vector similarity search for semantic recall | P1 | Rewrite | `src/memory/` | M |
| **Memory hygiene** | Cleanup old/stale memories | P2 | Rewrite | `src/memory/` | S |
| **Memory snapshots** | Backup/restore memory state | P2 | Rewrite | `src/memory/` | S |
| **Loop detection** | Detect runaway tool call loops | P1 | Port | `elixir/loop_detection_hook.ex` | S |
| **Memory recall tool** | Tool for agents to query memory | P0 | Rewrite | `src/tools/memory_recall.rs` | S |

**Milestone 4 Total Effort:** ~10-14 weeks

---

## Milestone 5: Security & Governance

**Goal:** Production-grade security with tool ACLs, approval workflows, and content filtering.

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **Security policy** | Tool ACLs and operation enforcement | P0 | Rewrite | `src/security/policy.rs` | L |
| **Approval manager** | `/approve` commands, auto_approve, always_ask | P0 | Rewrite | `src/security/mod.rs` | M |
| **Sentinel engine** | LLM-based content filtering middleware | P1 | Rewrite | `src/security/sentinel/` | L |
| **Content scanner** | Scan for secrets, PII, malicious content | P0 | Rewrite | `src/security/content_scanner.rs` | M |
| **Leak detector** | Detect credential/secret leaks in agent output | P0 | Rewrite | `src/security/leak_detector.rs` | M |
| **Secrets manager** | Secure credential storage | P1 | Rewrite | `src/security/secrets.rs` | M |
| **Prompt guard** | Prompt injection detection | P1 | Rewrite | `src/security/prompt_guard.rs` | M |
| **Audit logging** | Security event logging | P1 | Rewrite | `src/security/audit.rs` | S |
| **E-stop** | Emergency stop for runaway agents | P1 | Rewrite | `src/security/estop.rs` | M |

**Milestone 5 Total Effort:** ~8-10 weeks

---

## Milestone 6: Developer Experience

**Goal:** LiveView dashboard, CLI tools, hot reload, and excellent debugging.

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **LiveView dashboard** | Real-time agent status monitoring | P0 | New | N/A | L |
| **Agents LiveView** | View/manage running agents | P1 | New | N/A | M |
| **Memory LiveView** | Browse and search memory | P1 | New | N/A | M |
| **Logs LiveView** | Real-time log streaming | P1 | New | N/A | M |
| **Phoenix Channels** | WebSocket for real-time chat | P1 | New | N/A | M |
| **Cron scheduler** | Native GenServer-based scheduler | P0 | New | N/A | M |
| **CLI (`fermix` command)** | Mix tasks or escript for ops | P1 | New | N/A | M |
| **Config migration tool** | Import RustyClaw TOML config | P2 | New | N/A | S |
| **Memory migration tool** | Import RustyClaw SQLite memory | P2 | New | N/A | M |
| **Hot code reload** | Reload agent code without restart | P1 | New | N/A | S |
| **Rich error messages** | Elixir-style helpful errors | P1 | New | N/A | S |
| **GraphQL API** | Alternative to REST for dashboard | P2 | New | N/A | L |

**Milestone 6 Total Effort:** ~10-14 weeks

---

## Milestone 7: Advanced Tools

**Goal:** Port all 47 RustyClaw tools for feature parity.

### File & Code Tools

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **file_edit** | Precise text replacement in files | P0 | Rewrite | `src/tools/file_edit.rs` | M |
| **git_operations** | Git commands (commit, push, branch, etc.) | P1 | Rewrite | `src/tools/git_operations.rs` | M |
| **glob_search** | Fast file pattern matching | P1 | Rewrite | `src/tools/glob_search.rs` | S |
| **content_search** | Grep-like content search | P1 | Rewrite | `src/tools/content_search.rs` | M |

### Web & Network Tools

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **web_fetch** | HTTP fetch + content extraction | P0 | Rewrite | `src/tools/web_fetch.rs` | M |
| **web_search_tool** | DuckDuckGo/web search | P1 | Rewrite | `src/tools/web_search_tool.rs` | M |
| **http_request** | Generic HTTP client tool | P1 | Rewrite | `src/tools/http_request.rs` | M |
| **browser** | Builtin computer-use tool via [agent-browser](https://github.com/vercel-labs/agent-browser) CLI — native Rust, accessibility tree snapshots with refs, no Playwright dependency. Needs auto-update mechanism for external engine | P0 | New | N/A | M |

### Delegation & Orchestration Tools

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **delegate** | Single-turn delegation to another model | P1 | Rewrite | `src/tools/delegate.rs` | M |
| **schedule** | Schedule future tasks | P1 | Rewrite | `src/tools/schedule.rs` | M |

### Cron Management Tools

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **cron_add** | Add cron job | P1 | Rewrite | `src/tools/cron_add.rs` | S |
| **cron_list** | List cron jobs | P1 | Rewrite | `src/tools/cron_list.rs` | S |
| **cron_remove** | Remove cron job | P1 | Rewrite | `src/tools/cron_remove.rs` | S |
| **cron_update** | Update cron job | P1 | Rewrite | `src/tools/cron_update.rs` | S |

### Skill Management Tools

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **skill_create** | Create new skill template | P1 | Rewrite | `src/tools/skill_create.rs` | M |

### Configuration Tools

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **model_routing_config** | Configure model routing | P1 | Rewrite | `src/tools/model_routing_config.rs` | M |

**Milestone 7 Total Effort:** ~8-12 weeks (can parallelize by category)

---

## Milestone 8: Production Readiness

**Goal:** Observability, deployment, clustering, and operational excellence.

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **Telemetry integration** | Prometheus metrics, OpenTelemetry | P0 | New | N/A | M |
| **Structured logging** | JSON logs with correlation IDs | P0 | New | N/A | S |
| **Health checks** | Readiness/liveness endpoints | P0 | New | N/A | S |
| **Clustering support** | Multi-node deployment with libcluster | P1 | New | N/A | L |
| **Database pooling** | Connection pooling for SQLite/Postgres | P1 | New | N/A | S |
| **Rate limiting** | Per-user/per-channel rate limits | P1 | New | N/A | M |
| **Circuit breakers** | Fault tolerance for external APIs | P1 | New | N/A | M |
| **Graceful shutdown** | Drain connections on SIGTERM | P1 | New | N/A | S |
| **Docker images** | Production-ready Docker builds | P1 | New | N/A | M |
| **Fly.io deployment** | Deployment guide for Fly.io | P2 | New | N/A | S |
| **Systemd service** | Linux service integration | P2 | New | N/A | S |
| **Backup automation** | Automated memory/config backups | P1 | New | N/A | M |
| **Performance testing** | Load tests for agent throughput | P2 | New | N/A | M |
| **Benchmarking suite** | Tool execution benchmarks | P2 | New | N/A | M |

**Milestone 8 Total Effort:** ~8-12 weeks

---

## Milestone 9: Differentiators

**Goal:** Features that go beyond RustyClaw/OpenClaw to make Fermix unique.

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **Heartbeat system** | Proactive periodic checks (email, calendar, weather) | P1 | New | OpenClaw AGENTS.md | M |
| **Reaction support** | Emoji reactions for group chats | P1 | New | OpenClaw AGENTS.md | S |
| **Smart presence** | Know when to speak vs stay silent in groups | P1 | New | OpenClaw AGENTS.md | M |
| **Multi-workspace** | Support multiple isolated agent workspaces | P1 | New | `docs/MAIN_AGENT_DESIGN.md` | L |
| **Visual context** | Screenshot analysis, image understanding | P1 | New | N/A | M |
| **Self-knowledge agent** | Persistent subagent with full Fermix codebase knowledge — can modify Fermix itself when user requests platform changes | P1 | New | N/A | L |

**Milestone 9 Total Effort:** ~8-12 weeks

---

## Additional Providers (Ongoing)

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **OpenRouter provider** | Meta-provider for many models | P1 | Rewrite | `src/providers/openrouter.rs` | M |
| **Ollama provider** | Local model support | P1 | Rewrite | `src/providers/ollama.rs` | M |
| **Gemini provider** | Google Gemini API | P1 | Rewrite | `src/providers/gemini.rs` | L |
| **Compatible provider** | Generic OpenAI-compatible provider | P1 | Rewrite | `src/providers/compatible.rs` | L |
| **Reliable wrapper** | Retry/fallback/timeout wrapper | P0 | Rewrite | `src/providers/reliable.rs` | L |
| **Router provider** | Multi-provider routing logic | P1 | Rewrite | `src/providers/router.rs` | M |

**Provider Total Effort:** ~6-8 weeks

---

## Future: Full Ecosystem Expansion

**Goal:** Comprehensive coverage after the core is stable and proven. Bring items forward as needed once corresponding milestones are complete.

### Additional Channels

| Feature | Description | Type | Reference | Effort |
|---------|-------------|------|-----------|--------|
| **IRC channel** | IRC protocol, multi-server support | Rewrite | `src/channels/irc.rs` | M |
| **Matrix channel** | Matrix homeserver client | Rewrite | `src/channels/matrix.rs` | L |
| **Email channel** | IMAP/SMTP for email-based interactions | Rewrite | `src/channels/email_channel.rs` | L |
| **iMessage channel** | iMessage via AppleScript on macOS | Rewrite | `src/channels/imessage.rs` | M |
| **Mattermost channel** | Mattermost API integration | Rewrite | `src/channels/mattermost.rs` | M |
| **Lark/Feishu channel** | ByteDance enterprise messenger | Rewrite | `src/channels/lark.rs` | L |
| **DingTalk channel** | Alibaba enterprise messenger | Rewrite | `src/channels/dingtalk.rs` | M |
| **QQ channel** | Tencent QQ messaging | Rewrite | `src/channels/qq.rs` | M |
| **Nostr channel** | Decentralized protocol | Rewrite | `src/channels/nostr.rs` | M |
| **LINQ channel** | Enterprise communication | Rewrite | `src/channels/linq.rs` | M |
| **MQTT channel** | IoT/lightweight messaging | Rewrite | `src/channels/mqtt.rs` | S |
| **Nextcloud Talk channel** | Self-hosted Nextcloud chat | Rewrite | `src/channels/nextcloud_talk.rs` | M |
| **ClawdTalk channel** | Custom protocol | Rewrite | `src/channels/clawdtalk.rs` | M |
| **WATI channel** | WhatsApp Team Inbox API | Rewrite | `src/channels/wati.rs` | S |
| **WhatsApp Web channel** | Browser-based WhatsApp automation | Rewrite | `src/channels/whatsapp_web.rs` | M |

### Extended Security

| Feature | Description | Type | Reference | Effort |
|---------|-------------|------|-----------|--------|
| **Domain matcher** | URL/domain allowlisting | Rewrite | `src/security/domain_matcher.rs` | S |
| **OTP support** | Two-factor authentication | Rewrite | `src/security/otp.rs` | S |
| **Pairing system** | Device pairing for authorization | Rewrite | `src/security/pairing.rs` | M |
| **Sandboxing (Landlock)** | Linux sandboxing via Landlock LSM | Rewrite | `src/security/landlock.rs` | M |
| **Sandboxing (Bubblewrap)** | Linux sandboxing via bubblewrap | Rewrite | `src/security/bubblewrap.rs` | S |
| **Sandboxing (Firejail)** | Linux sandboxing via firejail | Rewrite | `src/security/firejail.rs` | S |
| **Sandboxing (Docker)** | Docker container isolation | Rewrite | `src/security/docker.rs` | S |

### Extended Tools

| Feature | Description | Type | Reference | Effort |
|---------|-------------|------|-----------|--------|
| **pdf_read** | Read/extract text from PDFs | Rewrite | `src/tools/pdf_read.rs` | M |
| **image_info** | Extract image metadata | Rewrite | `src/tools/image_info.rs` | S |
| **browser_open** | Open URLs in user's browser | Rewrite | `src/tools/browser_open.rs` | S |
| **cron_run** | Manually trigger cron job | Rewrite | `src/tools/cron_run.rs` | S |
| **cron_runs** | List cron execution history | Rewrite | `src/tools/cron_runs.rs` | S |
| **skill_edit** | Edit skill template | Rewrite | `src/tools/skill_edit.rs` | S |
| **skill_patch** | Patch skill template | Rewrite | `src/tools/skill_patch.rs` | S |
| **skill_delete** | Delete skill template | Rewrite | `src/tools/skill_delete.rs` | S |
| **sop_execute** | Execute defined procedure | Rewrite | `src/tools/sop_execute.rs` | M |
| **sop_list** | List available SOPs | Rewrite | `src/tools/sop_list.rs` | S |
| **sop_advance** | Advance SOP to next step | Rewrite | `src/tools/sop_advance.rs` | S |
| **sop_approve** | Approve SOP step | Rewrite | `src/tools/sop_approve.rs` | S |
| **sop_status** | Check SOP execution status | Rewrite | `src/tools/sop_status.rs` | S |
| **composio** | Composio integration (hundreds of integrations) | Rewrite | `src/tools/composio.rs` | L |
| **pushover** | Pushover notification service | Rewrite | `src/tools/pushover.rs` | S |
| **screenshot** | System screenshot capture | Rewrite | `src/tools/screenshot.rs` | M |
| **hardware_board_info** | Board/system info | Rewrite | `src/tools/hardware_board_info.rs` | S |
| **hardware_memory_map** | Memory mapping info | Rewrite | `src/tools/hardware_memory_map.rs` | S |
| **hardware_memory_read** | Read hardware memory | Rewrite | `src/tools/hardware_memory_read.rs` | S |
| **proxy_config** | Configure HTTP/SOCKS proxy | Rewrite | `src/tools/proxy_config.rs` | S |
| **synth_proxy** | API synthesis proxy | Rewrite | `src/tools/synth_proxy.rs` | M |
| **cli_discovery** | Discover available CLI tools | Rewrite | `src/tools/cli_discovery.rs` | S |

### Extended Differentiators

| Feature | Description | Type | Reference | Effort |
|---------|-------------|------|-----------|--------|
| **Voice storytelling** | TTS integration for narratives | New | OpenClaw AGENTS.md | M |
| **Agent personality** | Configurable tone/style per workspace | New | N/A | M |
| **Context awareness** | Time-of-day, location-based behavior | New | N/A | M |
| **Axon integration** | Agent-to-agent mesh protocol | Hybrid | `projects/agent-mesh` | XL |
| **Plugin system** | Third-party tool/channel plugins | New | N/A | L |
| **Proactive suggestions** | Agent suggests optimizations unprompted | New | N/A | L |
| **Learning from feedback** | Improve from user corrections over time | New | N/A | L |
| **Mobile app** | Native iOS/Android apps | New | N/A | XL |
| **Browser extension** | Chrome/Firefox extension for web context | New | N/A | L |
| **Collaborative agents** | Multiple agents working on same task | New | N/A | XL |

### Extended Providers

| Feature | Description | Type | Reference | Effort |
|---------|-------------|------|-----------|--------|
| **Bedrock provider** | AWS Bedrock integration | Rewrite | `src/providers/bedrock.rs` | L |
| **Copilot provider** | GitHub Copilot API | Rewrite | `src/providers/copilot.rs` | M |
| **GLM provider** | ChatGLM integration | Rewrite | `src/providers/glm.rs` | M |
| **Telnyx provider** | Telnyx AI API | Rewrite | `src/providers/telnyx.rs` | M |
| **OpenAI Codex provider** | Codex-specific optimizations | Rewrite | `src/providers/openai_codex.rs` | M |

**Future Total Effort:** ~60+ weeks (demand-driven, not scheduled)

---

## Summary by Priority

### Core Milestones (M2–M9) — ~50-60 weeks total
- Multi-agent orchestration (AgentServer, Supervisor, Main Agent, skill invocation)
- WhatsApp, Discord, Signal, Slack, CLI channels
- Advanced memory (Hermes extraction, Honcho AI/wiki-style, gist, compaction, SQLite)
- Security core (policy, approval, content scanner, leak detector, Sentinel, prompt guard, e-stop)
- LiveView dashboard, CLI, cron scheduler
- Core tools (file_edit, web_fetch, browser, git, delegate, web search, model routing, cron, skill_create)
- Production ops (telemetry, health checks, logging, clustering, rate limiting)
- Core providers (OpenRouter, Ollama, Gemini, Compatible, Reliable, Router)
- Differentiators (heartbeat, reactions, smart presence, multi-workspace, visual context, self-knowledge agent)

### Future Ecosystem — ~60+ weeks (demand-driven)
- 15 additional channels (IRC, Matrix, email, enterprise messengers, niche protocols)
- Extended security (sandboxing variants, OTP, pairing, domain matcher)
- Extended tools (SOP suite, hardware, composio, PDF, screenshots)
- Extended differentiators (Axon, plugins, mobile apps, voice, personality)
- Niche providers (Bedrock, Copilot, GLM, Telnyx, Codex)

---

## Recommended Sequence

**After Phase 1 MVP:**
1. **Milestone 2** (Multi-Agent Orchestration) — unlocks delegation
2. **Milestone 4** (Advanced Memory) — unlocks long-term context
3. **Milestone 3** (WhatsApp, Discord, Signal, Slack, CLI) — core channels
4. **Milestone 5** (Security core: policy, approval, content scanner) — production safety
5. **Milestone 6** (Dashboard + CLI) — operational visibility
6. **Milestone 8** (Production ops) — deployment readiness
7. **Milestone 7** (Core tools) — essential feature parity
8. **Milestone 9** (Differentiators) — unique value
9. **Future** (Extended ecosystem) — demand-driven expansion

**Total estimated time for core (M2–M9):** ~6-9 months full-time with AI assistance. Future items are demand-driven.

---

## Open Questions

1. **PostgreSQL vs SQLite?** — SQLite works for single-node, Postgres needed for clustering
2. **Axon integration strategy?** — Separate project or merge into Fermix?
3. **Open source timing?** — When to release under sixteen.dev?
4. **Mobile-first strategy?** — Native apps or PWA?
5. **Enterprise features?** — RBAC, multi-tenancy, SSO?
6. **Cloud hosting?** — Fermix Cloud as a service offering?
7. **Honcho AI vs Hermes vs Wiki memory?** — Evaluate Honcho AI (self-learning + dreaming, heavy Docker), wiki-style memory (lightweight LLM-wiki), and Hermes consolidation — pick the simplest that meets needs
8. **Browser tool auto-update?** — agent-browser is an external engine; need a mechanism to keep it current

---

## Related Documents

- `docs/PROJECT_PLAN.md` — Overall architecture and Phase 1-5 plan
- `docs/PHASE1_TASKS.md` — Detailed Phase 1 task breakdown
- `docs/MAIN_AGENT_DESIGN.md` — Main Agent architecture (RustyClaw reference)
- `docs/OPTION_B_ORCHESTRATION_DESIGN.md` — Skill orchestration design (RustyClaw reference)
- `docs/hermes-memory-design.md` — Hermes memory extraction (RustyClaw reference)
- `/Users/sujshe/projects/rustyclaw/` — RustyClaw reference implementation
- `/Users/sujshe/.openclaw/workspace/AGENTS.md` — OpenClaw agent behavior patterns

