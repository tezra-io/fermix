# Fermix browser extension

Hands **one tab** of your own Chromium browser to Fermix. You click the
extension on a tab; Fermix can then read and act in that tab, with your real
login, until you click again, close the tab, or the task ends. Chrome shows its
own "started debugging this browser" bar for as long as it is attached, and the
extension badges the tab.

There is no pairing code and no network listener. The extension talks to the
Fermix daemon on your own machine through Chrome's native messaging, over a
socket only your account can open.

## Install it

1. Install the native-messaging host, with the extension id the browser gives
   you after step 2 (run this again once you have the id):

   ```sh
   fermix browser bridge install --browser chrome --extension-id <id>
   ```

   `--browser` is one of `chrome`, `chromium`, `brave`, `edge`. The command
   prints the two files it writes: a small launcher under `$FERMIX_HOME/bin/`
   and the host manifest in that browser's `NativeMessagingHosts` directory.

2. Load this directory unpacked: open `chrome://extensions`, turn on **Developer
   mode**, choose **Load unpacked**, and pick this folder. The extensions page
   then shows the extension's id — that is what step 1 wants.

3. Re-run step 1 with that id, then press the reload button on the extension so
   it reconnects.

`fermix browser bridge status` says what is installed for each browser, whether
the launcher it names still exists, and whether an extension is connected to the
running daemon. `fermix browser bridge uninstall --browser chrome` removes the
pair again.

## Use it

Click the extension on the tab you want Fermix to work in. Then ask Fermix for
something about "the tab I have open" — it reaches that tab through the
`selected_tab` browser profile. Click again to take the tab back.

What the granted tab does **not** do, by design: open tabs, close tabs, bring
itself to the front, read or clear cookies, or manage downloads. Those are
browser-wide and the grant covers one tab, so Fermix answers with a sentence
pointing at its own managed browser instead.

If a click does nothing, look at the badge: `!` in red means the debugger could
not attach to that tab, and hovering the icon says why. The service worker also
lets go of every tab it still holds whenever it restarts, so a click after a
restart grants cleanly instead of failing on an attachment nothing is driving.

## What it can see

The extension holds no page content. It relays commands from the daemon to
Chrome's debugger and relays the answers back; the only thing it keeps is the
set of tab ids you granted. It requests three permissions — `debugger`,
`nativeMessaging` and `tabs` — and no host permissions at all, so it has no
access to any site except through a debugger you attached yourself. There are no
content scripts, no remote code and no `eval`.

## The wire

One JSON object per message, native messaging in both directions. The extension
sends `hello`, `grant`, `revoke`, `cdp_result`, `cdp_error` and `event`; the
daemon sends `hello_ack`, `refused`, `cdp` and `release`. The protocol number is
`1` and a mismatch is refused on both sides rather than negotiated, so the
extension and the daemon move together.

The daemon also answers a `status` frame on the same socket, which is how
`fermix browser bridge status` counts connections; nothing in the extension
sends it.

Commands are limited to the `Page`, `Runtime`, `DOM`, `Input` and
`Accessibility` domains, refused by the daemon before it transmits and by
`protocol.js` before anything reaches `chrome.debugger`.

## Developing

`protocol.js` holds the parts with no browser in them — message validation,
frame shapes, Chrome's detach reasons — and has tests:

```sh
cd apps/fermix_core/priv/browser_extension && node --test
```

## Store listing

Publishing is the owner's to do. The listing needs: a name and short
description, at least one 1280x800 screenshot showing a granted tab with the
badge and Chrome's debugging bar, a privacy policy URL, and a justification for
each permission —

- **debugger**: the whole feature. The user grants one tab by clicking the
  action; the extension attaches Chrome's debugger to that tab only.
- **nativeMessaging**: to reach the Fermix daemon running on the same machine.
- **tabs**: to read the granted tab's id, url and title, and to notice when it
  closes.

Single purpose: "attach the user's chosen tab to the Fermix assistant running on
their own computer". The extension collects no data and sends nothing to any
remote server; everything it relays goes to a local process over a Unix socket.

Icons are deliberately absent: the browser shows its default action icon.
Add `icons` and `action.default_icon` to `manifest.json` before submitting, since
the store requires a 128x128 icon.
