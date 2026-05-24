# Milestone 7.4: Default Skill Catalog

**Status:** draft
**Depends on:** M7 (skill files, `SkillRegistry`), M7.3 (skill lifecycle & `fermix skills reload`), M4.7 (setup seeding + wizard), M4.10 (CLI/daemon RPC surface)

## 1. Problem / Goal

Bundled skills ship inside the binary (`apps/fermix_core/priv/skills/`). That works for a tiny curated core, but it does not scale well if every new skill requires a Fermix release.

For the initial release, keep the feature deliberately small:

- Fermix ships and installs only first-party, dependency-free skills.
- A supported catalog skill is a single `SKILL.md` file.
- No Python helpers, no bundled scripts, no external CLIs, and no `xurl` integration in this milestone.
- Skills that require Python packages, system tools, OAuth setup, or service-specific credentials are documented separately as future integrations.

**Goal:** provide a first-party catalog of supported Fermix skills that can be selected during setup and installed through the CLI. Selected skills are written into an existing `SkillRegistry` discovery root and become live after `fermix skills reload` with no daemon restart.

## 2. Design Principles

1. **`SkillRegistry` stays the only disk scanner.** Install means "write a `SKILL.md` directory into a root it already scans"; no new discovery path.
2. **Initial catalog skills are dependency-free.** A catalog entry contains one `SKILL.md` and no scripts, references, Python deps, system deps, or external CLI requirements.
3. **Default skills are supported Fermix skills.** Setup can enable the default set without asking the operator to install tools or configure third-party accounts.
4. **No arbitrary third-party install flow.** `fermix skills install NAME` installs a named skill from the configured Fermix catalog, not a random URL or GitHub repo.
5. **No silent code download.** Every fetched skill is pinned to a catalog ref and checksum-verified. Trust is assigned by catalog source, not self-declared by the manifest.
6. **Setup remains the config-write boundary.** Selected skills persist in config so re-setup or a new host can reproduce the same set.

## 3. Current State

- `SkillRegistry` scans three roots:
  - bundled `priv/skills` -> `:operator`
  - `~/.fermix/skills` -> `:operator`
  - `~/.fermix/skills/_plugins` -> `:guest`
- `SkillRegistry.reload/1` refreshes the registry, Main Agent cache, and prompt caches without a daemon restart.
- `AgentDefinition` frontmatter is a line-based parser supporting fields such as `name`, `description`, `allowed_tools`, and `policy`.
- The setup Skills pane is currently read-only and lists discovered skills.
- Some existing bundled skills (`pdf`, `xlsx`, `pptx`, `docx`, `xurl`) describe Python packages or external CLIs. Those are out of scope for the initial default catalog unless rewritten as dependency-free `SKILL.md`-only guidance.

## 4. Proposed Architecture

### 4.1 Catalog Contract

The first-party catalog is a small manifest plus one `SKILL.md` per supported skill:

```text
catalog.json
skills/<name>/SKILL.md
```

`catalog.json`:

```json
{
  "schema_version": 1,
  "skills": [
    {
      "name": "planning",
      "category": "core",
      "description": "Help break work into clear steps and verification checks.",
      "default": true,
      "path": "skills/planning",
      "sha256": "<skill-md-digest>"
    }
  ]
}
```

Rules:

- `path` points to a directory containing exactly one `SKILL.md`.
- `sha256` is the SHA-256 of the `SKILL.md` content, not a tarball digest.
- `default = true` means setup preselects the skill for the initial supported default set.
- The manifest has no `trust` field. A catalog cannot declare its own trust.
- The manifest has no dependency fields in this milestone. If a skill needs dependencies, it belongs in the future integration document, not this catalog.

### 4.2 Fetch + Verify

Install flow:

1. Fetch `catalog.json` from the configured first-party catalog ref.
2. Find the requested `NAME`.
3. Fetch `SKILL.md` at the entry path.
4. Verify SHA-256 against the manifest.
5. Parse frontmatter and require `name` to equal the requested catalog entry.
6. Write the file atomically to `~/.fermix/skills/<name>/SKILL.md`.
7. Reload skills so the new skill is live with no daemon restart.

Remove flow:

1. Validate `NAME`.
2. Delete `~/.fermix/skills/<name>` if present.
3. Reload skills.

The initial implementation should not extract archives. A single-file `SKILL.md` fetch is enough for the supported default catalog and removes tar traversal, archive layout, and script packaging concerns from this milestone.

### 4.3 Setup Wizard

The setup Skills pane changes from read-only to selectable:

- Render catalog skills grouped by category.
- Preselect skills marked `default = true`.
- Show name and description only; no dependency/status UI is needed.
- On save, install selected skills, remove unselected catalog-managed skills, persist `enabled`, and reload.

If the catalog is unavailable during setup, the wizard should surface a clear error and leave existing installed skills unchanged.

### 4.4 CLI / Daemon RPC

Keep the CLI surface small:

```bash
fermix skills catalog [--json]
fermix skills install NAME [--json]
fermix skills remove NAME [--json]
fermix skills list [--json]
fermix skills view NAME [--json]
fermix skills reload [--json]
```

Behavior:

- `catalog` lists supported catalog skills.
- `install NAME` installs a named catalog skill.
- `remove NAME` removes a local installed skill.
- `list`, `view`, and `reload` continue to operate on `SkillRegistry`.

This milestone does not support `fermix skills install URL`, third-party catalog browsing, or dependency installation.

### 4.5 Config

```toml
[fermix_core.skills]
catalog_url = "https://github.com/<org>/fermix-skills"
catalog_ref = "<commit-sha>"       # pinned release catalog ref
enabled = ["planning", "review"]   # selected supported skills
```

Config rules:

- `catalog_url` and `catalog_ref` identify the first-party Fermix catalog.
- `enabled` is the reproducible selected set.
- No `uv`, Python, CLI, or system dependency config is needed in this milestone.
- If `catalog_url` or `catalog_ref` is absent, catalog commands return `:no_catalog_configured` and existing local skills remain usable.

## 5. Migration

- Keep `self_knowledge` bundled as the zero-dependency core skill.
- Move only dependency-free, `SKILL.md`-only skills into the initial default catalog.
- Do not include `pdf`, `xlsx`, `pptx`, `docx`, or `xurl` in the initial default set while they require Python packages, system tools, external CLIs, OAuth, or service credentials.
- Document those richer integrations separately, including dependency setup, credential handling, sandbox permissions, and security expectations.

## 6. Security

- Fetch only from the configured catalog source.
- Verify every fetched `SKILL.md` with SHA-256 before writing.
- Require `SKILL.md` frontmatter `name` to match the catalog entry.
- Reject manifest entries with unknown fields, missing fields, duplicate names, invalid names, mutable refs where a commit SHA is required, or dependency declarations.
- Do not run installers, scripts, `curl | bash`, `pip`, `uv`, `npm`, `brew`, or external CLIs as part of this milestone.
- Deferred: signing, provenance attestation, third-party catalogs, archive packages, dependency-managed skills.

## 7. Tests

- Manifest parse and schema validation:
  - accepts valid `SKILL.md`-only entries
  - rejects unknown fields, missing fields, duplicate names, invalid names, dependency fields, and malformed checksums
- Installer:
  - fetches `SKILL.md`, verifies checksum, writes atomically
  - rejects checksum mismatch and writes nothing
  - rejects frontmatter name mismatch and writes nothing
  - removes installed skills and reloads
- Daemon/CLI:
  - `skills_catalog`, `skills_install`, and `skills_remove` return JSON-safe replies
  - install/remove trigger `MainAgent.reload_skills()`
- Setup:
  - default catalog skills are preselected
  - saved selections persist to `[fermix_core.skills].enabled`

## 8. Deferred

- Python-backed document skills (`pdf`, `xlsx`, `pptx`, `docx`).
- External CLI-backed skills (`xurl`, `soffice`, browser-specific CLIs, etc.).
- OAuth and API-key setup flows for service-specific skills.
- Multi-file skill packages with `scripts/` or `references/`.
- Third-party catalog federation and public submission flow.
- Skill signing, provenance, and auto-update.

## 9. Success Criteria

- A fresh setup can install the default dependency-free supported skill set.
- `fermix skills install NAME` installs only named skills from the configured Fermix catalog.
- Installed skills are live after reload with no daemon restart.
- A tampered `SKILL.md` is rejected before anything is written.
- Initial release has no Python, external CLI, OAuth, or system-package dependency path in the skill catalog.
