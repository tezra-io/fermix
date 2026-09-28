# Skills and skill curation

## Skills

- A skill is a `SKILL.md` instruction package, not a provider-visible tool. `skill_view` loads a body (and a named reference file); `skill_run` delegates it to a sub-agent (recursion cap 4); `skill_list` enumerates.
- Sources: bundled skills and `~/.fermix/skills` load at operator trust; plugin skills load at guest trust (capability-restricted) whoever calls them. A skill's `allowed_tools` narrows its trust default (`[]` = none; absent = the default).
- `skill_create` writes to `~/.fermix/skills`. `skill_reload` re-scans the skill directories and refreshes the running agent in place (no restart) after a `SKILL.md` is created or edited on disk, reporting added, removed and changed names and load errors.
- CLI: `fermix skills list | view NAME | reload`.

## Skill curation

- On by default: `[fermix_core.skill_curation] enabled`; Mac Settings > Personality > **Suggest new skills from tasks you repeat** (its footer names where suggestions arrive); a yes/no in browser and terminal setup. Changing it takes a restart.
- Every 15 days a background pass reads the owner's own messages from the last 30 days for repeated tasks no skill or tool covers, and **proposes**; it never creates anything on its own. Proposals arrive in the owner's private channel with approve/deny buttons, or `/skills approve|deny TOKEN`. Approved, the skill is drafted and written under `~/.fermix/skills/`, where it loads like any hand-made skill. With no channel owner configured, suggestions wait.
- The same pass audits only skills curation created: one unused long enough earns a reversible archive proposal (moved to `skills/_archive/`, never deleted). A declined idea is buried; an idea ignored twice stops being suggested.
- `/skills` (owner-only, every subcommand):

| Subcommand | Does |
|---|---|
| `review` | runs a pass now; acks at once and delivers the result to the same chat |
| `proposals` | pending, declined and parked ideas |
| `list` | inventory by origin (curation-made with lifecycle state, your own, plugin skills; bundled excluded) with usage counts |
| `archive NAME` | archives a curation-made skill now |
| `restore NAME` | brings one back, and undoes a body update from its snapshot |
| `unpark` | revives a declined idea |
| `approve` / `deny TOKEN` | answers a proposal |

- Runs emit `[:fermix, :skill_curation, :run_start|:run_complete|:run_error|:proposal_actioned]` under their own `session_id`; `fermix doctor` has a `skill curation` row.
