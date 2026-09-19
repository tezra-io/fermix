# Browser profiles: the managed browser, and the person's own tab

The `browser` tool drives Chromium over CDP. Which browser it drives is the
`profile` argument, and there are two kinds.

## The managed profile (the default)

`fermix`, `fermix_visible` and `fermix_headless` are Fermix's own browser
instances, in its own profile directory, with its own logins. This is the
default and the right answer for almost everything: it opens and closes tabs, it
redirects downloads into the workspace, it reads and clears cookies, and nobody
else is using it. On a desktop it is a real window the person can see.

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
navigation checks, and the upload path confinement. It is the same
`ProfileServer` with a different transport underneath, not a second
implementation.

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
`Input` and `Accessibility` CDP domains, and anything else is refused before it
is transmitted — so a browser-wide command cannot leak through this path by
accident.

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
`attached_tab_not_allowed` and told to use the managed profile. The first
attended conversation to use the profile holds the grant until it releases it —
a second conversation gets `attached_tab_not_granted` rather than sharing the
tab.

The grant is released when the profile stops, when the idle sweep reclaims it,
and when the conversation ends; the extension detaches the debugger and clears
the badge.

## Installing the bridge

The extension reaches the daemon through a native-messaging host:

```
fermix browser bridge install --browser chrome|chromium|brave|edge --extension-id <id>
fermix browser bridge status
fermix browser bridge uninstall --browser chrome
```

`install` writes a small launcher under `$FERMIX_HOME/bin/` and the host
manifest in that browser's `NativeMessagingHosts` directory, and prints both
paths. `status` says what is installed, whether the launcher it names still
exists, and whether an extension is connected. The extension itself is
unpublished: it loads unpacked from `apps/fermix_core/priv/browser_extension/`,
whose README has the steps.

`fermix browser-bridge` is the pump the browser starts through that launcher. It
is not run by hand.

The channel is a `0600` socket at `$FERMIX_HOME/browser_bridge.sock` — same user,
same machine, no network port and no pairing code. Which extension may connect is
the host manifest's `allowed_origins`, enforced by the browser and again by the
pump.
