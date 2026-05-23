---
name: self_knowledge
description: Use when the user asks what Fermix is, what it can do, or how agents, jobs, memory, channels, built-ins, and skills fit together.
allowed_tools: []
---

# Fermix self-knowledge

Fermix is an Elixir-native multi-agent platform that runs as a single OS daemon. It receives messages from channels, routes them to a persistent main agent, executes approved capabilities, and sends replies back through the originating channel.

## How it fits together

- Channels deliver user messages into Fermix.
- The main agent owns the conversation and calls provider adapters for model turns.
- The agent loop executes capabilities from one registry: Fermix built-in tools and MCP tools.
- Skills are instruction packages loaded from `SKILL.md` files. The runtime prompt shows a compact Skill Catalog; use `skill_view` to load full instructions and `skill_run` when a skill should execute as a delegated sub-agent.
- Memory stores owner-scoped durable facts and source-aware job memories.
- Scheduled jobs run isolated bounded agent loops and can write job-scoped memory.
- Prompt bootstrap files provide identity, operating rules, user context, memory context, and generated runtime state.

## Built-in tools

Built-in tools ship inside Fermix and are registered at boot. They cover local files, search, git inspection and mutation, public web fetch/search, scheduling, memory, model delegation, skill scaffolding, routing config, and on-demand tool help.

Use `tool_help` when exact parameters, examples, or failure modes for one built-in are needed. Use the generated built-in capability catalog in the runtime prompt for quick routing decisions.

## Skills vs built-ins

Built-ins ship with the binary and do not need installation. They are always present unless a future built-in explicitly requires setup and is not configured.

Skills live under the Fermix skills directories. Core skills ship under `priv/skills`; local operator skills live under `~/.fermix/skills`; plugin skills live under `~/.fermix/skills/_plugins`. Skills can have their own instructions and allowed-tool boundaries.

## What Fermix can do

- Answer through configured provider adapters, including OpenAI, Codex, and Anthropic-compatible routes.
- Use built-in tools for common operating verbs instead of falling back to shell.
- Use the Skill Catalog to discover specialized instructions, then load them with `skill_view` or delegate execution with `skill_run`.
- Schedule durable future work with `schedule_job` and manage those jobs with the job tools.
- Store and recall durable memory with source provenance.
- Expose status, health, logs, traces, and setup through the CLI and daemon surfaces.

## Boundaries

Fermix should prefer the narrowest built-in capability that owns a task. Shell remains available for work that has no Fermix-owned verb, but file search, public web work, git read/write, scheduling, memory, skill scaffolding, and routing config all have first-class built-ins.
