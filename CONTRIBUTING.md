# Contributing to Fermix

Thanks for your interest in Fermix — an Elixir-native multi-agent AI platform.

## Prerequisites

- Elixir `~> 1.17` and Erlang/OTP `28` (matches the build constraint in every `mix.exs`)
- Standard build tools (for precompiled native deps such as SQLite via `exqlite`)

## Getting started

```sh
git clone https://github.com/tezra-io/fermix.git
cd fermix
mix deps.get
mix compile
```

See the **Develop** section of the [README](README.md) for running the full
daemon locally with `mix fermix.dev`.

## The gates (must pass before a PR is merged)

CI runs these on every pull request — run them locally first:

```sh
mix compile --warnings-as-errors
mix test
mix credo --strict
mix format --check-formatted
```

Warnings are treated as errors. A behavior change must come with a test.

## Workflow

- Branch off `dev` and open your pull request against `dev`.
- `main` is the released branch; `dev` → `main` happens via PR at release time.
- Keep changes surgical — touch only what the change requires.
- Use [Conventional Commits](https://www.conventionalcommits.org/) prefixes
  (`feat:`, `fix:`, `chore:`, `test:`, `refactor:`, `docs:`) to match the
  existing history.

## Code style

The non-negotiable code rules — linear flow, small functions, bounded loops,
no swallowed errors, no silent fallbacks — live in [CLAUDE.md](CLAUDE.md).
Please read that section before submitting; reviews enforce it.

## Reporting bugs & security issues

- Functional bugs: open a GitHub issue with reproduction steps.
- Security vulnerabilities: **do not** open a public issue — see
  [SECURITY.md](SECURITY.md).
