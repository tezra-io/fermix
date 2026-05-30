# Security Policy

## Supported versions

Fermix is pre-1.0 (alpha). Security fixes land on `main` and ship in the next
release. Always run the latest release.

| Version       | Supported |
| ------------- | --------- |
| latest `0.x`  | ✅        |
| older `0.x`   | ❌        |

## Reporting a vulnerability

**Please do not open a public issue for security vulnerabilities.**

Report privately through GitHub's [private vulnerability reporting][gh-pvr]:
open the repository's **Security** tab and click **"Report a vulnerability."**

Please include:

- a description of the issue and its impact,
- steps to reproduce (or a proof of concept),
- the affected version / commit, and
- any suggested remediation.

We aim to acknowledge reports within a few days and will coordinate a fix and
disclosure timeline with you. Never include real secrets (API keys, tokens) in
a report — redact them.

## Scope

Fermix runs as a local daemon that holds provider API keys and bot tokens,
executes a workspace-rooted command/path sandbox, and bridges external chat
channels. Areas of particular interest:

- secret handling (config, env passthrough, `auth.json`),
- the sandbox and its allow/deny policy,
- inbound/outbound MCP and channel ingress authorization,
- the signed `fermix upgrade` path.

[gh-pvr]: https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability
