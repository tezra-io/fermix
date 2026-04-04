# Fermix Roadmap — Post-MVP Features

**Last Updated:** 2026-03-30  
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

**Goal:** Support all major messaging platforms that RustyClaw supports.

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **WhatsApp channel** | Cloud API, webhook + signature verification | P0 | Rewrite | `src/channels/whatsapp.rs` | M |
| **Discord channel** | Gateway WebSocket + REST API | P0 | Rewrite | `src/channels/discord.rs` | L |
| **Signal channel** | signal-cli integration via subprocess | P1 | Rewrite | `src/channels/signal.rs` | M |
| **Slack channel** | RTM/Events API + Bot user | P1 | Rewrite | `src/channels/slack.rs` | M |
| **IRC channel** | IRC protocol, multi-server support | P1 | Rewrite | `src/channels/irc.rs` | M |
| **Matrix channel** | Matrix homeserver client | P1 | Rewrite | `src/channels/matrix.rs` | L |
| **Email channel** | IMAP/SMTP for email-based interactions | P2 | Rewrite | `src/channels/email_channel.rs` | L |
| **iMessage channel** | iMessage via AppleScript on macOS | P2 | Rewrite | `src/channels/imessage.rs` | M |
| **Mattermost channel** | Mattermost API integration | P2 | Rewrite | `src/channels/mattermost.rs` | M |
| **Lark/Feishu channel** | ByteDance enterprise messenger | P2 | Rewrite | `src/channels/lark.rs` | L |
| **DingTalk channel** | Alibaba enterprise messenger | P2 | Rewrite | `src/channels/dingtalk.rs` | M |
| **QQ channel** | Tencent QQ messaging | P2 | Rewrite | `src/channels/qq.rs` | M |
| **Nostr channel** | Decentralized protocol | P2 | Rewrite | `src/channels/nostr.rs` | M |
| **LINQ channel** | Enterprise communication | P2 | Rewrite | `src/channels/linq.rs` | M |
| **MQTT channel** | IoT/lightweight messaging | P2 | Rewrite | `src/channels/mqtt.rs` | S |
| **Nextcloud Talk channel** | Self-hosted Nextcloud chat | P2 | Rewrite | `src/channels/nextcloud_talk.rs` | M |
| **ClawdTalk channel** | Custom protocol | P2 | Rewrite | `src/channels/clawdtalk.rs` | M |
| **WATI channel** | WhatsApp Team Inbox API | P2 | Rewrite | `src/channels/wati.rs` | S |
| **WhatsApp Web channel** | Browser-based WhatsApp automation | P2 | Rewrite | `src/channels/whatsapp_web.rs` | M |
| **CLI channel** | Interactive CLI for testing | P1 | Rewrite | `src/channels/cli.rs` | S |
| **Transcription support** | Audio transcription for voice messages | P1 | Rewrite | `src/channels/transcription.rs` | M |

**Milestone 3 Total Effort:** ~16-24 weeks (can parallelize)

---

## Milestone 4: Advanced Memory

**Goal:** Three-tier memory architecture with Hermes extraction, gist generation, and compaction.

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **Hermes extraction (Phase 1)** | LLM-driven memory extraction with confidence scoring | P0 | Port | `elixir/hermes/` + `docs/hermes-memory-design.md` | L |
| **Hermes consolidation (Phase 2)** | Memory deduplication and merging | P0 | Port | `elixir/hermes/` | M |
| **Hermes decay (Phase 3)** | Confidence decay over time | P1 | Port | `elixir/hermes/` | S |
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
| **Domain matcher** | URL/domain allowlisting | P2 | Rewrite | `src/security/domain_matcher.rs` | S |
| **E-stop** | Emergency stop for runaway agents | P1 | Rewrite | `src/security/estop.rs` | M |
| **OTP support** | Two-factor authentication | P2 | Rewrite | `src/security/otp.rs` | S |
| **Pairing system** | Device pairing for authorization | P2 | Rewrite | `src/security/pairing.rs` | M |
| **Sandboxing (Landlock)** | Linux sandboxing via Landlock LSM | P2 | Rewrite | `src/security/landlock.rs` | M |
| **Sandboxing (Bubblewrap)** | Linux sandboxing via bubblewrap | P2 | Rewrite | `src/security/bubblewrap.rs` | S |
| **Sandboxing (Firejail)** | Linux sandboxing via firejail | P2 | Rewrite | `src/security/firejail.rs` | S |
| **Sandboxing (Docker)** | Docker container isolation | P2 | Rewrite | `src/security/docker.rs` | S |

**Milestone 5 Total Effort:** ~12-16 weeks

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
| **pdf_read** | Read/extract text from PDFs | P2 | Rewrite | `src/tools/pdf_read.rs` | M |
| **image_info** | Extract image metadata | P2 | Rewrite | `src/tools/image_info.rs` | S |

### Web & Network Tools

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **web_fetch** | HTTP fetch + content extraction | P0 | Rewrite | `src/tools/web_fetch.rs` | M |
| **web_search_tool** | DuckDuckGo/web search | P1 | Rewrite | `src/tools/web_search_tool.rs` | M |
| **http_request** | Generic HTTP client tool | P1 | Rewrite | `src/tools/http_request.rs` | M |
| **browser** | Browser automation via [agent-browser](https://github.com/vercel-labs/agent-browser) CLI — native Rust, accessibility tree snapshots with refs, no Playwright dependency | P1 | New | N/A | M |
| **browser_open** | Open URLs in user's browser | P2 | Rewrite | `src/tools/browser_open.rs` | S |

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
| **cron_run** | Manually trigger cron job | P2 | Rewrite | `src/tools/cron_run.rs` | S |
| **cron_runs** | List cron execution history | P2 | Rewrite | `src/tools/cron_runs.rs` | S |

### Skill Management Tools

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **skill_create** | Create new skill template | P1 | Rewrite | `src/tools/skill_create.rs` | M |
| **skill_edit** | Edit skill template | P2 | Rewrite | `src/tools/skill_edit.rs` | S |
| **skill_patch** | Patch skill template | P2 | Rewrite | `src/tools/skill_patch.rs` | S |
| **skill_delete** | Delete skill template | P2 | Rewrite | `src/tools/skill_delete.rs` | S |

### SOP (Standard Operating Procedure) Tools

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **sop_execute** | Execute defined procedure | P2 | Rewrite | `src/tools/sop_execute.rs` | M |
| **sop_list** | List available SOPs | P2 | Rewrite | `src/tools/sop_list.rs` | S |
| **sop_advance** | Advance SOP to next step | P2 | Rewrite | `src/tools/sop_advance.rs` | S |
| **sop_approve** | Approve SOP step | P2 | Rewrite | `src/tools/sop_approve.rs` | S |
| **sop_status** | Check SOP execution status | P2 | Rewrite | `src/tools/sop_status.rs` | S |

### Integration & External Tools

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **composio** | Composio integration (hundreds of integrations) | P2 | Rewrite | `src/tools/composio.rs` | L |
| **pushover** | Pushover notification service | P2 | Rewrite | `src/tools/pushover.rs` | S |
| **screenshot** | System screenshot capture | P2 | Rewrite | `src/tools/screenshot.rs` | M |

### Hardware & Low-level Tools

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **hardware_board_info** | Board/system info | P2 | Rewrite | `src/tools/hardware_board_info.rs` | S |
| **hardware_memory_map** | Memory mapping info | P2 | Rewrite | `src/tools/hardware_memory_map.rs` | S |
| **hardware_memory_read** | Read hardware memory | P2 | Rewrite | `src/tools/hardware_memory_read.rs` | S |

### Configuration Tools

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **model_routing_config** | Configure model routing | P1 | Rewrite | `src/tools/model_routing_config.rs` | M |
| **proxy_config** | Configure HTTP/SOCKS proxy | P2 | Rewrite | `src/tools/proxy_config.rs` | S |
| **synth_proxy** | API synthesis proxy | P2 | Rewrite | `src/tools/synth_proxy.rs` | M |

### Discovery & Metadata Tools

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **cli_discovery** | Discover available CLI tools | P2 | Rewrite | `src/tools/cli_discovery.rs` | S |

**Milestone 7 Total Effort:** ~16-20 weeks (can parallelize by category)

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
| **Voice storytelling** | TTS integration for narratives | P2 | New | OpenClaw AGENTS.md | M |
| **Agent personality** | Configurable tone/style per workspace | P2 | New | N/A | M |
| **Context awareness** | Time-of-day, location-based behavior | P2 | New | N/A | M |
| **Multi-workspace** | Support multiple isolated agent workspaces | P1 | New | `docs/MAIN_AGENT_DESIGN.md` | L |
| **Axon integration** | Agent-to-agent mesh protocol | P2 | Hybrid | `projects/agent-mesh` | XL |
| **Plugin system** | Third-party tool/channel plugins | P2 | New | N/A | L |
| **Visual context** | Screenshot analysis, image understanding | P1 | New | N/A | M |
| **Proactive suggestions** | Agent suggests optimizations unprompted | P2 | New | N/A | L |
| **Learning from feedback** | Improve from user corrections over time | P2 | New | N/A | L |
| **Mobile app** | Native iOS/Android apps | P2 | New | N/A | XL |
| **Browser extension** | Chrome/Firefox extension for web context | P2 | New | N/A | L |
| **Collaborative agents** | Multiple agents working on same task | P2 | New | N/A | XL |

**Milestone 9 Total Effort:** ~20-30 weeks

---

## Additional Providers (Ongoing)

| Feature | Description | Priority | Type | Reference | Effort |
|---------|-------------|----------|------|-----------|--------|
| **OpenRouter provider** | Meta-provider for many models | P1 | Rewrite | `src/providers/openrouter.rs` | M |
| **Ollama provider** | Local model support | P1 | Rewrite | `src/providers/ollama.rs` | M |
| **Gemini provider** | Google Gemini API | P1 | Rewrite | `src/providers/gemini.rs` | L |
| **Bedrock provider** | AWS Bedrock integration | P2 | Rewrite | `src/providers/bedrock.rs` | L |
| **Copilot provider** | GitHub Copilot API | P2 | Rewrite | `src/providers/copilot.rs` | M |
| **GLM provider** | ChatGLM integration | P2 | Rewrite | `src/providers/glm.rs` | M |
| **Telnyx provider** | Telnyx AI API | P2 | Rewrite | `src/providers/telnyx.rs` | M |
| **OpenAI Codex provider** | Codex-specific optimizations | P2 | Rewrite | `src/providers/openai_codex.rs` | M |
| **Compatible provider** | Generic OpenAI-compatible provider | P1 | Rewrite | `src/providers/compatible.rs` | L |
| **Reliable wrapper** | Retry/fallback/timeout wrapper | P0 | Rewrite | `src/providers/reliable.rs` | L |
| **Router provider** | Multi-provider routing logic | P1 | Rewrite | `src/providers/router.rs` | M |

**Provider Total Effort:** ~10-14 weeks

---

## Summary by Priority

### P0 Features (Critical — ~30 weeks total)
- Multi-agent orchestration core (AgentServer, Supervisor, Main Agent, skill invocation)
- WhatsApp + Discord channels
- Advanced memory (Hermes, gist, compaction, SQLite)
- Security (policy, approval, content scanner, leak detector)
- LiveView dashboard
- Cron scheduler
- Core tools (file_edit, web_fetch)
- Production ops (telemetry, health checks, logging)
- Key providers (OpenAI already in Phase 1, + Reliable wrapper)

### P1 Features (High Value — ~50 weeks total)
- Skill journals, parallel execution
- Signal, Slack, IRC, Matrix channels
- Memory (embedding search, loop detection)
- Security (Sentinel, prompt guard, secrets, audit, e-stop)
- All LiveView pages, Phoenix Channels, CLI
- Most tools (git, delegate, browser, web search, model routing, cron tools, skill tools)
- Clustering, rate limiting, circuit breakers
- OpenRouter, Ollama, Gemini providers
- Heartbeat system, reactions, smart presence

### P2 Features (Nice to Have — ~60 weeks total)
- Git worktree isolation, ResourceLock, BtwRouter, tracing
- Remaining channels (email, iMessage, enterprise messengers, niche protocols)
- Memory hygiene/snapshots
- All sandboxing options, OTP, pairing, domain matcher
- Migration tools, GraphQL API
- Remaining tools (PDF, image, SOP, composio, hardware, screenshots)
- Voice storytelling, agent personality, visual context
- Axon integration, plugins, mobile apps, browser extension

---

## Recommended Sequence

**After Phase 1 MVP:**
1. **Milestone 2** (Multi-Agent Orchestration) — unlocks delegation
2. **Milestone 4** (Advanced Memory) — unlocks long-term context
3. **Milestone 3** (WhatsApp + Discord only) — critical channels
4. **Milestone 5** (Security core: policy, approval, content scanner) — production safety
5. **Milestone 6** (Dashboard + CLI) — operational visibility
6. **Milestone 8** (Production ops) — deployment readiness
7. **Milestone 7** (Tools, prioritized) — feature parity
8. **Milestone 3** (remaining channels) — full coverage
9. **Milestone 9** (Differentiators) — unique value

**Total estimated time:** ~2-3 years at evenings/weekends pace, or 8-12 months full-time with AI assistance.

---

## Open Questions

1. **PostgreSQL vs SQLite?** — SQLite works for single-node, Postgres needed for clustering
2. **Axon integration strategy?** — Separate project or merge into Fermix?
3. **Open source timing?** — When to release under sixteen.dev?
4. **Mobile-first strategy?** — Native apps or PWA?
5. **Enterprise features?** — RBAC, multi-tenancy, SSO?
6. **Cloud hosting?** — Fermix Cloud as a service offering?

---

## Related Documents

- `docs/PROJECT_PLAN.md` — Overall architecture and Phase 1-5 plan
- `docs/PHASE1_TASKS.md` — Detailed Phase 1 task breakdown
- `docs/MAIN_AGENT_DESIGN.md` — Main Agent architecture (RustyClaw reference)
- `docs/OPTION_B_ORCHESTRATION_DESIGN.md` — Skill orchestration design (RustyClaw reference)
- `docs/hermes-memory-design.md` — Hermes memory extraction (RustyClaw reference)
- `/Users/sujshe/projects/rustyclaw/` — RustyClaw reference implementation
- `/Users/sujshe/.openclaw/workspace/AGENTS.md` — OpenClaw agent behavior patterns
