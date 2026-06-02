---
name: browser_guidance
description: Use when operating websites or local web apps through the built-in browser tool.
allowed_tools: ["browser"]
---

# Browser Guidance

Use the built-in `browser` tool for JavaScript-capable navigation, accessibility snapshots, tabs, screenshots, and bounded page actions. Prefer it over shell, curl, or external browser automation when the user wants a page opened, inspected, or operated.

## Defaults

- Start with `snapshot` after `open` or `navigate`; it is the model-facing read path.
- Do not pass a headless setting. Use the default profile unless there is a concrete reason to choose `fermix_headless`, `fermix_visible`, or a configured existing-session profile.
- If a page appears blocked only under the headless profile, retry once with a visible profile, then stop and report the blocker.
- Treat screenshot and PDF paths as artifacts. Do not claim the model saw screenshot pixels unless the surrounding runtime explicitly feeds image bytes back to the model.

## Actions

- Use refs from the latest snapshot for `act` and `upload`; refs are stale after navigation or a substantial DOM change.
- Use `wait_until: "text"`, `"url"`, `"element"`, or `"load"` after actions that may change the page.
- Use fixed waits only as a last resort and keep `timeout_ms` bounded.
- Use `download` after an action that triggers a download; downloads are captured under Fermix's browser downloads root.

## Stop Conditions

- Stop and report when the page requires CAPTCHA, 2FA, payment confirmation, or credentials the user has not provided.
- Stop and report when navigation is blocked by browser URL policy.
- Stop and report when a JavaScript dialog blocks actions; use `dialog` only when accepting or dismissing is clearly safe.
