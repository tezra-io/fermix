# Browser profiles: the managed browser, and the person's own tab

The `browser` tool drives Chromium over CDP. Which browser it drives is the
`profile` argument, and there are two kinds.

## The managed profile (the default)

`fermix`, `fermix_visible` and `fermix_headless` are Fermix's own browser
instances, in its own profile directory, with its own logins. This is the
default and the right answer for almost everything: it opens and closes tabs, it
redirects downloads into the workspace, it reads and clears cookies, and nobody
else is using it. On a desktop it is a real window the person can see.

## Two backends for `fermix`, decided once

The default profile `fermix` can run on either of two implementations of the
same browser surface: the managed Chrome above, driven over CDP, or the Fermix
app's own browser pane, which the app hosts and the engine drives over a local
wire (`browser_host.sock`). Which one is decided once, when a conversation
starts using the browser: the pane when the app's browser host is connected
and its last report says the pane is ready, the managed Chrome otherwise. When
the app is not connected and `[fermix_core.browser] launch_app` allows it (on
by default for the engine inside the app), the engine opens the app in the
background once and waits a few seconds for its browser to connect and report
before deciding; if that launch never attaches (the person quits the app
before it connects, or it crashes), a short cooldown follows before the engine
tries opening it again, so a burst of tasks in that window all run on Chrome
rather than each opening the app in turn. The choice holds for as long as that
browser use lives. A Chrome task stays in Chrome when the pane appears, and a
pane task that loses its pane mid-task (the app quit, the Mac locked or slept)
answers `host_lost` with the app's reason and ends there; tell the person, and
do not redo the task in another browser on your own. The person can also
cancel a pane task directly, from its own tab in the app ("Cancel task"):
that answers `cancelled` — the pane itself is fine, so say it was cancelled,
not that the browser went away. Every later browser call in the same turn
answers that same sentence too, rather than quietly starting a fresh task on
Chrome — the turn that saw the loss or the cancel stays that way. The next
browser use, in a fresh turn, is decided afresh. `fermix_visible`,
`fermix_headless` and `selected_tab` are never routed to the pane.

Limits of the managed browser:
- Live tabs are capped: each `open` past the cap closes the oldest non-active
  tab, so a long-idle tab may be gone.
- Reads allow only `http`/`https`, `about:blank` and an allowed-origin `blob:`.
- A download is vetted at its source URL too: a refused one is cancelled, any
  partial file deleted, and the tool answers `download_blocked`.
- A URL host must be canonical ASCII (an IDN in its `xn--` form).
- `[fermix_core.browser] allowed_hosts` and `launch_app` are its settings, the
  former the escape hatch for a refused host; timeouts and caps are internal.
- Operating rules (snapshots, `act`, the `page` field, `webmcp`): the `browser`
  tool description and the `browser-guidance` skill.

## Launching Chrome on macOS

Chrome starts through a small `disclaim` exec shim, so it is its own macOS
privacy principal and Fermix needs no App Management permission. A "fermix" row
under System Settings > Privacy & Security > App Management is an inert
leftover, safe to ignore or turn off (`sudo tccutil reset SystemPolicyAppBundles`
would reset every app's grant, so it is rarely worth running). A launch that
cannot disclaim refuses (`shim_missing`, `disclaim_failed`) rather than start
Chrome undisclaimed; `fermix doctor`'s `browser` row reports the shim.

## Where a name points

Both profiles judge where a page actually comes from, not only how its host is
spelled. A hostname is looked up once per browser session, before a navigation
and before a page is read, and one that resolves to a link-local or
cloud-metadata address (169.254.0.0/16, fe80::/10, fd00:ec2::254) or the
unspecified address is refused: `navigation_blocked` before the browser goes
there, `read_blocked` for a page already there, such as a tab a page opened by
itself or a handed-over tab's page. A lookup that fails is left to the browser,
and a page that then does not load answers `navigation_failed`, naming the
browser's network error, never a refusal.
For a page Fermix watched load, the address the browser reports it loaded the
page from is judged the same way, so a name that pointed somewhere public when
it was checked and at the metadata endpoint when the browser fetched it still
returns nothing (`read_blocked`). LAN (RFC 1918), ULA and tailnet (100.64/10)
addresses stay reachable by name, and the recovery for a refused host is still
its `allowed_hosts` entry.

## `selected_tab`: the tab the person handed over

`profile: "selected_tab"` is **one tab of the person's own browser**, signed in
as them. They grant it by clicking the Fermix browser extension on that tab, and
they take it back by clicking again. Chrome shows its own "started debugging
this browser" bar while it is attached, and the extension badges the tab.

Use it only when the person asks for the tab they have open — a page they are
already signed in to, a session they are watching. For a new web task the
managed profile is the simpler workspace, and it does not borrow their browser.

What holds exactly as before: the read gate (a page whose live host the policy
refuses returns nothing, and it is re-asked on every settle poll), the
navigation checks, and the upload path confinement. It is the same CDP
backend with a different transport underneath, not a second implementation.
`navigate` is the one navigation a granted tab may make, and it
hands the page back the same way it does in the managed profile: through the
same settle, the same read gate on the address the page committed to, and the
same `page` field.

What a granted tab cannot do, because the grant is one tab and these are the
whole browser:

| Asked for | Answer |
|---|---|
| `open` (a new tab) | `unsupported_in_attached_tab` — navigate this tab, or use the managed profile |
| `close` | `unsupported_in_attached_tab` — the person closes their own tabs |
| `focus` | `unsupported_in_attached_tab` — the person switches to it if they want to watch |
| `cookies` | `unsupported_in_attached_tab` — cookies are browser-wide |
| `download` | `unsupported_in_attached_tab` — their browser downloads where it always does |

`tabs` reports the granted tab's url and title read LIVE, not what the page was
when the person clicked: on a page the read policy refuses it returns the tab id
and `page: "read_blocked"` and nothing of the page. `console` is a read of the
tab too — a page chooses what it logs — so it faces the same gate, in every
profile.

Commands are limited at the transport boundary to the `Page`, `Runtime`, `DOM`,
`Input` and `Accessibility` CDP domains, plus `Network.enable` so the read gate
learns which address served the page, and anything else is refused before it is
transmitted — so a browser-wide command, a cookie read among them, cannot leak
through this path by accident. Of the `Network` domain the extension relays only
a document's frame, url and serving address: no headers, no cookies.

### When there is no tab

With nothing granted, the tool answers `attached_tab_not_granted`: the right
move is to ask the person to click the Fermix extension on the tab they mean,
not to fall back to the managed profile and pretend it is the same page.

When a granted tab goes away the tool answers `attached_tab_detached` and the
message says which way it went: they clicked again, the tab closed, Chrome's
debugging bar was dismissed, DevTools took the debugger, or the extension
disconnected. That refusal is always delivered before anything else is bound —
a different tab granted in the meantime is never picked up silently, so the
answer after a detach is the detach, and only the step after that may claim a
fresh tab.

`browser_bridge_unavailable` means this process has no browser bridge at all (it
is a daemon surface); use the managed profile here.

### Who may use it

Attended owner turns only. A guest, a scheduled job, a detached background run,
a delegated subagent and a coding-run continuation are all refused with
`attached_tab_not_allowed` and told to use the managed profile. A turn from a
Buzz-wired ACP session is refused the same way before anything reaches the
tab, even when the owner is the one asking there: other people can post in a
Buzz channel, so its turn is not proof the owner is present, and the refusal
names where to ask instead (the Fermix app, their own chat, or voice). The
managed profile still works from Buzz, and an editor client like Zed, with no
Buzz relay, is unaffected. The first
attended conversation to use the profile holds the grant until it releases it —
a second conversation gets `attached_tab_not_granted` rather than sharing the
tab.

The grant is released when the profile stops, when the idle sweep reclaims it,
and when the conversation ends; the extension detaches the debugger and clears
the badge.

## Installing the extension and the bridge

Needs macOS or Linux, Chrome, Chromium, Brave or Edge, a running Fermix, and the
`fermix` command. The Mac app ships none: install the standalone binary and run
it against the app's home (export `FERMIX_HOME` if the app's home is not
`~/.fermix`). The extension is not in the Chrome Web Store:

1. Get the folder from https://github.com/tezra-io/fermix/tree/main/apps/fermix_core/priv/browser_extension
   (clone, or **Code** > **Download ZIP**) and keep it somewhere permanent: the
   extension ID derives from its location.
2. `chrome://extensions` > **Developer mode** on > **Load unpacked** > that
   folder; copy the ID the card shows.
3. `fermix browser bridge install --browser chrome|chromium|brave|edge --extension-id <id>`
   writes a launcher under `$FERMIX_HOME/bin/` and the browser's
   `NativeMessagingHosts` manifest, and prints both paths.
4. Reload the extension, then click it on the tab to hand over.

`fermix browser bridge status` shows what is installed, whether the launcher
still exists, and how many extensions are connected (zero until the extension is
clicked on a tab after the browser starts). `fermix browser bridge uninstall
--browser chrome` removes the pair. After updating Fermix, refresh the folder and
reload the extension: the daemon refuses an extension on an older bridge
protocol. After moving the folder or the `fermix` binary, run the install again
(a moved folder means a new ID).

`fermix browser-bridge` is the pump the browser starts through the launcher; it
is not run by hand. The channel is a `0600` socket at
`$FERMIX_HOME/browser_bridge.sock`: same user, same machine, no network port, no
pairing code. The host manifest's `allowed_origins` decides which extension may
connect, enforced by the browser and again by the pump.
