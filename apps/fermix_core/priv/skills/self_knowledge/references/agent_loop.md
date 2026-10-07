# The agent loop: context budget, caps, and deferred tool schemas

## Context budget inside a turn

- Every tool result is kept for the whole run. When a turn's results near the model's context window, older ones are compressed in place into task-guided digests; the step being answered and the two before it stay raw.
- A digest names its call id, and `tool_result_recall` reads the original back (search a phrase, or a line range). Nothing is dropped or cut.
- If the provider still refuses the request as too large, the loop compresses more and re-issues the call, at most three times, and never re-runs a tool.
- A request that still does not fit fails the turn with a sentence saying so; a scheduled job's notice carries the same sentence and the raw reason. A run that never nears its window is unchanged.
- Between turns, auto-compaction summarizes the conversation at a threshold (default 0.85; Mac Settings > Memory > **Compact a conversation at**); `/compact` forces it.

## Caps and fan-out

| Run | Cap |
|---|---|
| Main turn, new scheduled job | 100 iterations |
| `subagents` | up to 10 tasks, 4 at once by default (max 8), 100 iterations each |
| `/ultra` | up to about 50 narrow probes, 12 at once, with less depth per probe |

- `/ultra` is a run mode of the normal turn, not a separate orchestrator: it tags the turn and adds an exhaustive-mode prompt that drives breadth (many narrow probes) and best-of-N depth (independent `subagents` on the same hard sub-problem, keeping the best-supported answer). Workers nest under the parent trace and stay brief by instruction.
- `subagents` takes a one-shot `model`; the main agent never changes its own model.
- Repeated identical tool calls trip the loop detector: the fifth identical call in a row ends the turn. A page's WebMCP tool (`browser` `webmcp` `call`) counts its repeats only since it last returned something new, so following a page's own wait (watching a game) goes on while each answer is new; an unchanged answer, a repeated timeout included, still counts.
- These caps are internal constants, not `config.toml` settings.

## Deferred tool schemas

On by default: `[fermix_core.tools.tool_search] enabled` absent means `true`; `false` turns it off. When on, plugin and MCP tool schemas leave the provider request (their names stay listed under `## Plugins`) and three bridges register: `tool_search` (BM25 over the deferred tools), `tool_describe` (one tool's full schema), `tool_call` (invoke a deferred tool; traces and policy see the real tool name, and calling it directly by name also works). Off: no bridges, every schema inline.
