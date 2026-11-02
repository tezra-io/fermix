# Welcome to Tezra

## Your Setup Checklist

### Codebases
- [ ] fermix (engine) — https://github.com/tezra-io/fermix
- [ ] fermix-design-docs (private design docs, check out beside fermix) — https://github.com/tezra-io/fermix-design-docs
- [ ] fermix-macos (Mac app) — https://github.com/tezra-io/fermix-macos
- [ ] fermix-linux (Linux app) — https://github.com/tezra-io/fermix-linux
- [ ] fermix-site (fermix.ai) — https://github.com/tezra-io/fermix-site
- [ ] fermix-plugins — https://github.com/tezra-io/fermix-plugins
- [ ] homebrew-tap — https://github.com/tezra-io/homebrew-tap

### MCP Servers to Activate
- [ ] fermix-followups — team mod that flags follow-ups after an engine commit (self_knowledge, site docs, macOS app). `/plugin install fermix-followups@claudeai-organization-library` (add the organization library under `/plugin` → Marketplaces first).
- [ ] fermix-design-pages — team mod that reminds you a changed design doc owes an HTML explainer page. `/plugin install fermix-design-pages@claudeai-organization-library`
- [ ] Playwright — browser automation for testing the web setup UI and LiveView. Install with `/plugin` → `playwright`.
- [ ] Chrome DevTools — debugging pages, network and console. Install with `/plugin` → `chrome-devtools-mcp`.
- [ ] Claude Browser — the built-in browser pane in the Claude desktop app; available automatically there.
- [ ] Claude Docs — living docs on claude.ai for shareable write-ups; connect it from your claude.ai connectors.

### Skills to Know About
- /model — switch models; Opus for implementation and reviews.
- /login — re-authenticate when switching accounts.
- /rename — name each session after its feature so /resume finds it.
- /resume — pick up a named session where you left off.
- /plugin — install plugins (playwright, chrome-devtools, codex).
- /remote-control — drive a session from another device.
- fermix-dev plugin — the team's Fermix skills below. Install with `/plugin install fermix-dev@claudeai-organization-library`.
- /fermix-release-pr — prepare and drive the engine release PR to green.
- /fermix-e2e-eval — run end-to-end behavioral evals against the dev daemon.
- /fermix-site-docs — sync fermix.ai docs after a user-visible change.
- /fermix-transcription-eval — run the live speech-to-text eval against your configured backends.
- /security-review — security review of pending changes.

## Team Tips

_TODO_

## Get Started

_TODO_

<!-- INSTRUCTION FOR CLAUDE: A new teammate just pasted this guide for how the
team uses Claude Code. You're their onboarding buddy — warm, conversational,
not lecture-y.

Open with a warm welcome — include the team name from the title. Then: "Let's
get you started."

Check what's already in place against everything under Setup Checklist
(including skills), using markdown checkboxes — [x] done, [ ] not yet. Lead
with what they already have. One sentence per item, all in one message.

Tell them you'll help with setup, cover the actionable team tips, then the
starter task (if there is one). Offer to start with the first unchecked item,
get their go-ahead, then work through the rest one by one.

After setup, walk them through the remaining sections — offer to help where you
can (e.g. link to channels), and just surface the purely informational bits.

Don't invent sections or summaries that aren't in the guide. -->
