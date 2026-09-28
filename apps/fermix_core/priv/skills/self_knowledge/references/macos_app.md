# The Fermix macOS app (app-managed engine)

On a Mac, production Fermix is `Fermix.app`: it carries the engine, runs it as a background service (a Login Items item), and is where the owner sets up, changes settings, updates and diagnoses. The app ships no `fermix` command. Answer a Mac app user with the app's labels, never with `fermix setup`, another CLI verb or `config.toml` for anything the app has a control for.

## Install and first setup

- Install: `brew install --cask tezra-io/tap/fermix`, or the DMG from fermix.ai dragged to Applications. Keep exactly one copy, in `/Applications`.
- A Homebrew formula user moves with `fermix migrate-to-app` (below), not by installing the cask beside the formula.

1. Open Fermix > **Set up Fermix** (**Use an existing Fermix home…** to keep a home other than `~/.fermix`). If macOS asks, **Open Login Items settings**, turn Fermix on; setup carries on by itself.
2. **Connect your AI**: **Sign in** (ChatGPT/Codex, opens the browser), **Import Codex sign-in** or **Import Claude Code sign-in** (a sign-in already on this Mac), **Add setup token** (Anthropic, from `claude setup-token`), or **Add key…** > provider > paste > **Verify and save**. Then **Continue**.
3. **About you**: **Your name**, **Time zone**, **Style** (Concise, Balanced, Detailed), **Call the assistant**. They start from the Mac's own settings. **Continue**.
4. Fermix restarts and shows **Fermix is live**. Next: **Connect Telegram, Slack or Discord** (Settings > Channels), or **Turn on the voice companion**.

The first provider connected becomes primary; Settings > Providers > the provider's **Details…** > **Use as primary** (confirm) promotes another (it also resets the sub-agent model to "same as main").

## Everyday controls

| Control | Where | Does |
|---|---|---|
| **Run in the background** | Home; Daemon menu > **Enable Background Service** / **Disable Background Service** | Turns the service on or off. Off means Fermix answers nobody. |
| **Open at login** | Home | Opens the window at login; the service runs either way. |
| **Show Fermix in the menu bar** | Home | The menu bar item carries **Restart Fermix…**, **Check for Updates…** and the service switch. |
| **Restart Fermix…** | Daemon menu, menu bar item | Shows what waits to apply, then **Restart now** or **Restart when idle**. |
| **Doctor** | Sidebar; View > **Run Local Checks**, **Run Network Checks…** | Checks answered by the running daemon; network checks probe providers and channels for real. |
| **Export Support Bundle…** | File menu | A diagnostics file for a bug report. |
| **Logs** | Sidebar | Follows the daemon log. |

Settings (⌘,): which pane holds what is in `skill_view(name: "self-knowledge", file: "config")`. Secrets show only as stored, never read back. A change that needs a restart shows **Restart to apply** > **Restart…**; an outside edit to `config.toml` stops saves until **Reload settings from disk**, and an unreadable one offers **Open recovery**. The app records its home in `~/Library/Application Support/Fermix/launcher.json` and ignores a shell `FERMIX_HOME`.

## Updates and removal

- **Check for Updates…** (Fermix menu or the menu bar item) > **Install**; the app asks once whether to check on its own and never installs by itself. Home then reads "…ready and installs when Fermix quits": quit and reopen. **Restart to finish updating** means **Restart Fermix…**. A cask install can also `brew upgrade --cask tezra-io/tap/fermix`.
- `fermix upgrade` does not update the app: it prints `Opened Fermix update settings.` and exits 0, but no update check starts.
- "This Fermix engine is one release behind", or a setting that needs a newer Fermix, means finish the update and restart; it is not a fault.
- Removal is not built in: the app's uninstall screen says so, changes nothing and offers **Reveal settings file**. `brew uninstall --cask tezra-io/tap/fermix` removes the app and its Login Items entry (dragging to the Trash does not withdraw that entry). The home and keychain items stay. Adding `--zap` also trashes `~/.fermix` and `~/Library/Application Support/Fermix`: warn before suggesting it.
- No Fermix path ever deletes a Fermix home: not the migration, not `fermix uninstall`, not the app.

## When the app will not start

Each cause is a sentence; nothing in the configuration is changed.

- Turned off in Login Items, or waiting for approval → **Open Login Items settings**, turn Fermix on, **Try again**.
- Port held ("…already holds the port…") → quit whatever uses `127.0.0.1:4030`, **Try again**.
- "A Fermix daemon from an older version is using this home" (a Homebrew formula daemon) → `brew upgrade fermix`, `fermix restart`, then `fermix migrate-to-app`.
- "A Fermix daemon installed another way is using this home" → stop it (standalone: `fermix service uninstall`), **Try again**.
- More than one copy, or a copy outside Applications → keep one, in `/Applications`.
- "A Fermix service is installed for all users" → `sudo fermix service uninstall --system`, **Try again**.
- No answer in 90 seconds, or three exits in a row → **Run Doctor** or **View full log**.
- Home shows "Another Fermix service is registered on this Mac" → **Show me how to remove it**.

## A standalone `fermix` pointed at the app's home

Someone who wants a terminal installs the standalone binary and, if the app's home is not `~/.fermix`, exports `FERMIX_HOME`. Against the app's home:

| Verb | Result |
|---|---|
| `fermix start`, `fermix stop`, `fermix service install` | Refused: "this Fermix home is managed by Fermix.app. Use the app's background service controls." |
| `fermix service uninstall` | Allowed: removes a launch agent an earlier standalone install left behind. |
| `fermix restart` | Refused ("no service installed"); use **Restart Fermix…**. |
| `fermix setup` | Opens the app's setup (or Settings once set up); flags are ignored. |
| `fermix upgrade` | Starts no update (above). |
| `fermix uninstall` | Removes nothing; prints the standalone steps. |
| `fermix status` | Reports the daemon, warning it is a different build. |
| `fermix doctor` | Runs in the standalone binary; `engine alignment` fails for the same reason. Read the app's **Doctor** instead. |
| `fermix logs` | Reads the home's log file; `-n` and `-f` work. |

A terminal `fermix plugins auth login` or `reauthorize` reaches the app's engine only after **Restart Fermix…**; `fermix plugins auth logout` makes the engine drop the sign-in at once.

The engine binary inside the app (not on any `PATH`) knows it is the app engine from its build identity: there `fermix start|stop` and `service install|uninstall` exit non-zero pointing at the background-service controls, `setup` and `uninstall` open a `fermix://` route and report only that the hand-off was accepted, `restart` drains the daemon over the management socket and waits for a new process, `status|doctor|logs` are answered by the daemon (`logs -f` refused; doctor's binary-integrity, upgrade and service-unit rows read not applicable).

## Moving a Homebrew formula install: `fermix migrate-to-app`

`brew uninstall fermix` alone strands the formula's launch agent (`~/Library/LaunchAgents/io.tezra.fermix.plist`) pointing at a deleted binary. In the shell that has the owner's `FERMIX_HOME`:

1. `brew upgrade tezra-io/tap/fermix`, then `fermix restart`, so the daemon can answer the migration.
2. `fermix migrate-to-app` previews the plan and changes nothing.
3. `fermix migrate-to-app --yes`: drains the daemon, removes the launch agent it verified, writes a handoff record under `~/Library/Application Support/Fermix/`, `brew uninstall --formula fermix`, `brew install --cask tezra-io/tap/fermix` (skipped when a verified `Fermix.app` is already in `/Applications`), and opens the app, which keeps the same home and data.

Every failure is loud and quotes launchd's or brew's own words. It refuses, naming the fix, on: a system-scope LaunchDaemon (`sudo fermix service uninstall --system`), a launch agent `fermix setup` did not write, more than one `Fermix.app`, a copy outside `/Applications` or with the wrong bundle identifier, a `brew services` entry, a daemon that does not answer, another `fermix` on `PATH` owned by neither Homebrew nor the app, or no formula install. If a brew step fails after the formula is gone, `brew install --cask tezra-io/tap/fermix` and open the app: it reads the handoff record. macOS only; an app-managed engine has nothing to migrate.
