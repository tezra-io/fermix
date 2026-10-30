# Browser profiles: the managed browser, and the person's own tab

The `browser` tool drives Chromium over CDP. Which browser it drives is the
`profile` argument, and there are two kinds.

## The managed profile (the default)

`fermix`, `fermix_visible`, `fermix_headless` and `fermix_chrome` are Fermix's
own browser instances, in its own profile directory, with its own logins. This
is the default and the right answer for almost everything: it opens and closes
tabs, it redirects downloads into the workspace, it reads and clears cookies,
and nobody else is using it.

Whose profile a call uses follows who is asking. Every conversation of the
owner's on this Fermix shares one set of managed profiles: a chat on any
channel, a scheduled job's runs, a cue run and a delegated worker all use the
same browser, so a site signed in once stays signed in for all of them, and a
scheduled job no longer starts signed out on every run. A guest's conversation
keeps its own profiles, shared with neither the owner nor another
conversation, and so does a plugin skill, which runs at guest trust, in the
conversation it runs in. A call whose run carries no trust is refused with
`missing_trust`. Profiles belong to the device: a sign-in on one Fermix (the
Mac) does not sign another (a VM) in. Profiles used to be kept per
conversation and are not carried over: the owner signs in once more, a guest
conversation starts signed out once, and the old per-conversation folders
under the home's `browser/profiles/` stay on disk unused until deleted.

The owner's conversations share one browser but not its current tab. A call
that names no `target` acts on its own conversation's tab: the last one it
opened or focused that is still open. Each chat, each scheduled job run and
each cue run is a conversation of its own; a delegated worker works in its
parent's tab. A conversation with no tab of its own is never handed another's:
its `navigate` opens a new tab, and anything else answers `no_tab`, so `open`
the page first. `target` names any tab in the shared browser, `tabs` lists
them all and marks the caller's own (`this_conversation`), and the tab cap
counts every conversation's tabs. The owner's browser is not closed when a
one-shot `fermix ask` finishes; it closes after a period with no use.

Which of the first three a call without `profile` uses is `[fermix_core.browser]
default_profile`, the person's "how tasks run" choice: `fermix` (the shipped
default) runs in a window wherever there is a display and in the background on
a server without one, `fermix_headless` always runs in the background, and
`fermix_visible` always opens a window they can watch. Each profile keeps its own
logins, so a site signed in under one is signed out under the others. A call can
still name a profile for one task, such as `fermix_visible` when the person asks
to watch. `max_tabs` (default 10) is how many tabs a managed browser keeps open
before closing the oldest one a task is not using; it applies from the browser's
next start. `allowed_hosts` and `launch_app` (both below) are the section's
other keys; `default_profile` refuses `selected_tab` and any name no profile
carries.

`fermix_chrome` is not one of those choices, and Settings does not offer it: it
is the managed Chrome a task names for what only Chrome can do, which today is
a page's WebMCP tools and a download while the default profile runs in the
Fermix app's pane (below). Like `fermix`, it opens a window where there is a display, and it is
never routed to the pane. It keeps its own logins like every profile, so a
site signed in to in the pane is signed out there.

## Which browser the managed profiles launch

The launcher takes the first of these that exists: the profile's own
`executable_path`, then `CHROME_PATH`, then Chrome or Chromium on `PATH`
(`google-chrome-stable`, `google-chrome`, `chromium`, `chromium-browser`,
`chrome`), then Google Chrome, Chromium and Google Chrome Canary in
`/Applications`, and last Google Chrome for Testing from Playwright's cache: the
Chromium the meeting notetaker's `install-browser` step downloads, found as the
newest complete `chromium-<revision>` under `PLAYWRIGHT_BROWSERS_PATH`, or else
`~/Library/Caches/ms-playwright` on macOS and `~/.cache/ms-playwright` on Linux.
So a machine with no browser of its own runs tasks once that download has run.
With none of them a launch refuses `chrome_missing`. `fermix doctor`'s `browser`
row names the browser in force and its path ("Tasks use Google Chrome."), or
says "No Chrome or Chromium is installed."

## Two backends for `fermix` and `fermix_visible`, decided once

The default profile `fermix`, and `fermix_visible`, can each run on either of
two implementations of the same browser surface: the managed Chrome above,
driven over CDP, or the Fermix app's own browser pane, which the app hosts
and the engine drives over a local wire (`browser_host.sock`) and shows in its
own window for a `fermix_visible` task, and for a `fermix` task too unless an
explicit headless override says otherwise, the same as the managed Chrome
above. The pane is decided per conversation and Chrome per profile: a
conversation's browser use runs in its own pane task while one is live, else
in the owner's shared Chrome while that is live, and only with neither is it
decided afresh, for that conversation alone: the pane when the app's
browser host is connected and its last report says the pane is ready, the
managed Chrome otherwise. A pane task belongs to the conversation that
started it and ends with that conversation's turn, so one conversation's pane
task never ends, moves or fails another's, while every owner conversation that
lands on Chrome shares the one Chrome and its sign-ins. When
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
Chrome — the turn that saw the loss or the cancel stays that way, and no
other conversation is touched. The next browser use, in a fresh turn, is
routed afresh by the rule above. `fermix_headless`,
`fermix_chrome` and `selected_tab` are never routed to the pane.

The pane runs no WebMCP tools and saves no downloads: `webmcp` and `download`
there answer `unsupported_in_fermix_app`. On the app's current wire a
download's start carries no source address and there is no way to cancel one,
so the engine could vet it neither by where it comes from nor by its size, as
it vets Chrome's, and the app refuses every download a task's page starts.
`open`, `navigate` and `status` say which browser answered in `backend`
(`fermix_app` for the pane, `cdp` for Chrome), so when a page offers WebMCP
tools or a file is needed from it and the browser is the pane, the move is to
open the page with `profile: "fermix_chrome"` rather than to try in the pane.
That opens a second profile beside the pane task, it does not re-route it: the
pane task keeps its browser, and a pane lost mid-task still ends that task with
`host_lost`.

Limits of the managed browser:
- Live tabs are capped: each `open` past the cap closes the oldest tab other
  than the one it just opened, whichever conversation opened it, so a
  long-idle tab may be gone.
- Reads allow only `http`/`https`, `about:blank` and an allowed-origin `blob:`.
- A download is vetted at its source URL too: a refused one is cancelled, any
  partial file deleted, and the tool answers `download_blocked`.
- A URL host must be canonical ASCII (an IDN in its `xn--` form).
- `default_profile`, `max_tabs` (above), `allowed_hosts` and `launch_app` are
  `[fermix_core.browser]`'s four settable keys; `allowed_hosts` is the escape
  hatch for a refused host; timeouts and caps are internal.
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
Buzz relay, is unaffected. The grant is the owner's, not one conversation's: any attended owner
conversation can use the handed-over tab.

The grant is released when the profile stops or when the idle sweep reclaims
it; the extension detaches the debugger and clears the badge.

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

## Handing a signed-in session to the server (Always On)

After an Always On move the server runs the tasks, in its own browser
profile, which no site has signed in to. The owner can hand it the sessions
of chosen sites from the desktop the home left, without typing a password on
the server and without the agent ever asking for one:

1. On the desktop, `fermix browser signin URL` opens Chrome, in a window, on
   the desktop's own Fermix profile (the default managed profile, never the
   person's everyday Chrome). Sign in there. Keep that window open until the
   hand-off is sent: a cookie the site set only for the session ends when
   Chrome closes. The window closes on its own after an hour.
2. `fermix browser handoff SITE... [--expires DURATION]
   [--allow-identity-provider]` reads that profile's cookies for exactly the
   named sites and sends them to the server over the encrypted session, which
   stores them in its own Fermix profile and says how many it stored and
   until when. `--json` prints the result for scripts.

- **A site** is a host and its subdomains (`github.com` covers
  `gist.github.com`), named exactly: no wildcard, scheme, port or path, and
  not a public suffix such as `co.uk`. At most 64 per hand-off.
- **Identity providers** sign the owner in to everything else, so their
  sessions move only when named with `--allow-identity-provider`:
  `accounts.google.com`, `login.microsoftonline.com`, `appleid.apple.com`,
  `login.live.com`, `github.com` (its sign-in is `github.com/login`), Okta
  and Auth0 hosts, and any site that covers one (`google.com`) or lies under
  one.
- **Expiry**: 7 days unless `--expires` says (`12h`, `3d`, `90m`), at most 30
  days. The server stores each cookie to expire by then at the latest, deletes
  the hand-off's cookies when it expires (within a minute while its Chrome
  runs, else as its Chrome next starts), and deletes again at the next start
  what it deleted from a Chrome that was already running, in case that Chrome
  stopped before writing the deletion.
- **What never moves**: passwords (none are read), the cookies of any site
  not named, cookies a site set inside another site's frame (partitioned
  cookies), and anything but cookies: a site that keeps its session in local
  storage needs signing in on the server. Nothing else of the desktop's
  profile (history, extensions, saved passwords) leaves it.
- **Listing and wiping**: `fermix browser handoffs` lists what the server
  stores (from either machine: on the desktop it asks the server), each with
  its sites, how many cookies, where it came from and until when; never a
  cookie's name or value, which the server's record
  (`<home>/browser/handoffs.json`, kept on the server) never holds.
  `fermix browser handoffs wipe [SITE...]` deletes those sites' hand-offs, or
  every one, now: on the server directly, from the desktop by asking the
  server, which answers how many cookies it deleted (the desktop waits up to
  a minute for that answer).
- **Only the owner** starts, lists or wipes a hand-off, at a terminal on the
  desktop: no tool does, and Fermix refuses these commands from any process
  it started itself. When a task on the server needs a site it is not signed
  in to, the agent asks the owner to hand that site off; it never asks for a
  password.

