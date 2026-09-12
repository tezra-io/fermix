---
name: browser-guidance
description: Use when operating websites or local web apps through the built-in browser tool.
allowed_tools: ["browser", "web_fetch", "web_search"]
---

# Browser Guidance

Use `browser` for JavaScript-capable pages. Choose the right web tool once, read with `snapshot`, act with current refs, then verify with `wait`/`get`.

## Tool Routing

- `web_search`: static facts, no known URL.
- `web_fetch`: one known URL with readable server HTML.
- `browser`: JavaScript-rendered pages, forms, clicks, login checks, live/interactive data, dashboards, seat maps — in `browser`'s OWN managed instance, NOT the page/app the user has open on their screen.
- `computer_use`: when the task is about the user's OWN live screen or a session they are watching (a page/app/game they already have open) — `browser` can't see or act on that (separate context; it desyncs). One carve-out: when the live state is SERVER-synced under the same account (a live game, a shared doc), driving the same page here acts on the very state the user is watching — the element rails then beat screen pixels; for anything not server-synced, a second copy silently desyncs from their view. Reserve `computer_use` for live-screen work; a nameable URL is still `web_fetch`/`browser`.
- Never shell-scrape JavaScript sites. Empty/partial `web_search` or `web_fetch` output on dynamic content means switch to `browser`.
- To wait for a page to change (a result to load, live content to update, the other side of a shared session to move), use the browser's `act` action with `kind: "wait"` (and a `wait_until` target) on THIS session — there is no top-level `wait` action; don't switch to `computer_use` to watch a page you are already driving here.

## Operating Loop

1. Use the default profile unless login state, user observation, or a headless-only blocker requires another.
2. `open`/`navigate`, then `snapshot`; snapshot refs are valid only for that page state.
3. Pass the intended `target` when multiple tabs exist.
4. After page-changing actions, verify with `wait`/`get`; snapshot again only when refs or structure changed.

## Actions

- `fill` sets a field value; `type` appends.
- `submit` uses a field ref from the form and clicks the primary submit/search control.
- `click`/`submit` may return sampled `url`; `fill`/`type` may return sampled `value`. Receipts are immediate observations, not proof that async navigation or rendering finished.
- Use `wait` for expected URL/text/element/load changes; use `get` for cheap URL/title/text/ready-state reads.

## Tab And Ref Hygiene

- Reuse one tab target per flow. If popups or retries create extras, use `tabs`, then `focus` or `close`.
- On stale/missing refs: snapshot the same target, retry once with the new ref, then report the blocker.
- Avoid snapshot churn; do not snapshot after every successful `fill`.
- The `screenshot` action returns the page as an image the model actually sees — use it to inspect rendered/visual state. Treat PDFs and downloads as saved artifacts (a path, not seen); read them with `file_read`. A download past the size ceiling is canceled and its partial deleted (`download_too_large`); if the browser refuses the cancel you get `download_too_large_cancel_failed` instead, meaning the transfer may still be writing — close the tab rather than retrying.
- Reads are checked at the URL the page has actually committed to, against a policy of their own — stricter than navigation on the scheme, identical on the host. Three distinct refusals, three different fixes: `read_blocked` (the live host is refused — navigate somewhere allowed and read again), `read_origin_blocked` (the document is not something this tool reads at all), `read_url_unavailable` (the live URL could not be read, so no policy could be applied — retry; usually a page that just navigated).
- Only `http`/`https` pages are readable, plus `about:blank` and a `blob:` URL whose inner origin is allowed. `file:`, `view-source:`, `filesystem:`, `data:`, `blob:null/` and `chrome:`-family documents are refused — read local files with `file_read`, not by opening them in a tab.
- Hosts ending `.internal`, `.local` or `.localhost` are refused outright unless the operator listed them in `allowed_hosts`, so an mDNS name like `printer.local` is not reachable by default. That list is the recovery for every host refusal on this page, and the operator sets it in `config.toml` under `[fermix_core.browser]` (`allowed_hosts = ["printer.local"]`), then restarts the daemon; an entry that is not spelled in the canonical ASCII form is refused at config load rather than silently never matching. Loopback (`localhost`, `127.0.0.1`, `::1`) stays allowed under every `allowed_hosts` setting — inspecting your own dev server is the point.
- Spell hosts in ASCII: letters, digits, `-`, `.`, `_`, or an IP address. A percent-escape, a backslash, a space, or any non-ASCII character in the host refuses the navigation as an ambiguous spelling, because the browser rewrites it before the request and the check would have run against a different machine. For an internationalised domain, pass its punycode (`xn--`) form.

## Stop Conditions

Stop and report for CAPTCHA, 2FA, payment confirmation, missing credentials, URL-policy blocks, unsafe dialogs, repeated launch/profile errors, or the same action failing twice with no new information.
