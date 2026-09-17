# Lessons

## API plugin architecture — 2026-09-07

For an OAuth REST integration, start from the existing GitHub, Notion, and X HTTP plugins and their shared authentication/execution path. A hosted MCP integration such as Eden is not the default template for an API plugin. Keep any provider-specific requirement that needs a helper, such as Tesla vehicle-command signing, separate from ordinary REST methods; do not move those methods into a new MCP server unnecessarily.

## General-purpose prompt edits — 2026-09-13

Keep task examples, sample replies, and scripted jokes out of Fermix's general-purpose runtime prompts; use scenarios only in external evaluations. Start prompt surgery with stale and duplicate instructions, replace existing wording, and measure the net token change. Distinguish instructions contradicted by the current runtime from model-specific steering that needs an ablation test; a newer model alone does not justify removing an operating safeguard.

## App-managed production configuration — 2026-09-16

Production Fermix is managed through the macOS app; do not prescribe a user-facing `fermix` CLI for its setup or recovery. Inspect the app's daemon environment and management surface. A sandbox env allowlist grants child-process passthrough; it neither stores credentials nor imports terminal shell exports into the launchd engine. External skill credentials need an app-accessible storage and injection path.
