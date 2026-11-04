# The Fermix desktop app on Linux

The Fermix desktop app, `io.tezra.Fermix` (GTK and libadwaita), installs as its own `.deb` or `.rpm` package or, earlier, as a Flatpak. Either way it is only a client of the host's own Fermix daemon, the package's systemd user unit `fermix.service`, and draws what that daemon publishes. The prompt's `## This Fermix` section says whether it was installed when this Fermix started; one installed later is seen at the next restart.

Answer a Linux app user with the app's labels for anything it has a control for (Settings > <pane>, Home's switches), and with the `fermix` command for what it does not have. The package's `fermix` is the command line; the app adds none of its own.

## What it talks to

- Settings, sign-in and status: `~/.fermix/daemon.sock`, the management protocol the Mac app speaks too. Every row, label and rule in its settings is the daemon's own.
- Chat: `~/.fermix/companion.sock`, the chat the Mac app speaks too (skill_view(name: "self-knowledge", file: "companion")): one conversation and one timeline with the phone's channel, at operator trust. Slash commands work there, and there is no button for a fresh start: `/new` starts the conversation afresh for the app and the phone and never clears what either shows. An approval (a directory grant, an access-sensitive plugin command) is a card with **Approve** and **Deny**, and a task's proposal is a card with **Deny** and **Confirm**, each answered in place. A task's request the app cannot show appears in Chat as **Something needs your answer**: the owner answers it in their own chat with Fermix (Telegram, Signal or WhatsApp), where Fermix sent it too, never from a paired phone, which is sent none; with no such chat it expires and nothing runs. An approval the app cannot show only expires, since no other chat can answer it. The chat draws the pictures and voice notes the timeline holds; what is typed there is text, and it attaches no files.
- Voice: `~/.fermix/realtime.sock`, from the **Pet** page.
- It reads `~/.fermix` read-only and never touches the config, secrets or memory files there; it asks the systemd user manager (`fermix.service`) and logind (linger) for the background service, and the desktop's tray host for its tray icon.

## Pages

**Chat**, **Pet** (**Begin voice call**), **Home**, **Doctor** and **Logs** in the sidebar, with **Settings** at its foot. The header carries **Restart Fermix…** and, while setup is incomplete, **Continue Setup…**.

- **Home**: Fermix's status and details; what needs attention, each with the button that fixes it (the pane that owns it, a provider's sign-in, **Restart Fermix…**, or **Open setup page** for what no pane holds); and the Background switches: **Run in the background** (turns linger on, then enables and starts `fermix.service`; off unregisters and stops it) and **Open at login** (the app keeps its own login entry, which the desktop reads when the owner logs in, and opens in the tray). When the daemon is not running it offers **Start Fermix**.
- **Doctor** runs the daemon's checks (**Run checks**); **Logs** follows the daemon log.
- The tray menu: its top line says how Fermix is, or **A task is waiting for your decision** while a task's proposal waits, which opens Chat at it; then **Open Fermix**, **Settings**, **Run Doctor**, the update row (**Check for Updates…**, **Update to** and the version once one is found, or **Restart to Finish Updating…**), **Restart Fermix…** (or **Start Fermix** when it is not running), **Show Pet**, **Run in the Background**, **Quit**.

## Settings

Its panes, in this order: Providers, Personality, Memory, Channels, Integrations, Cues, Voice, Meetings, Computer, Coding agents, Search, Images, Secrets, Sandbox, Permissions, Updates (grouped Assistant, Connections, Capabilities and System). Cues shows only where this Fermix serves cues; Updates is the app's own and shows even while Fermix is down. The rows in every other pane are the daemon's, so they match the browser setup page and the Mac app's panes for the same section. In Providers each provider row offers its ways in, most direct first (**Sign in**, **Import from** a sign-in already on the machine, **Paste a setup token…** for Anthropic, **Use an API key…**), and its menu holds **Make primary**, **Replace key…**, **Remove key** and **Sign out**. A setting this copy of the app has no control for says so and asks for an app update. Channels holds the **Phone** row: **Pair a phone…** turns the channel on where it is off, shows the code to scan, then the six digits to compare with **Approve** and **Deny**; once a phone is paired the row opens **Change…**, which lists the phones with **Forget…** and carries Reach from anywhere and the advanced rows.

## Reminders on this computer

Nothing in the app: a reminder or timer that rings on this computer is a desktop notification the daemon posts itself on the session bus while a desktop session is running, named Fermix and drawn with this app's name and icon when it is installed. Linux holds no grant for it, so Permissions shows nothing new, and it carries no Snooze button: "snooze that" in the app's chat snoozes it.

## Updates

The app's package carries the engine and replaces the engine-only package, so the app updates both; the engine-only package's installer is not how this host updates. **Check for Updates…**, in the main menu and the tray, or **Check Now** in Settings > Updates (the app's own pane) looks for a newer release in Fermix's signed update feed, and **Check for updates automatically** there checks when Fermix starts, then once a day. An update installs only when the owner asks: the system's package installer (PackageKit) asks for the password, and may call the package untrusted because it does not come from the system's software sources (Fermix has already checked it is the package Fermix released); then it restarts what the update changed (the window, and Fermix too when the engine changed), or the tray offers **Restart to Finish Updating…** while that restart is owed. A development build does not update itself.

## What it does not have

- No computer history (a macOS feature), so that section is hidden.

## The earlier Flatpak

The earlier Flatpak app had no bundled engine and no updater of its own: beside it the engine updates with the engine-only package (skill_view(name: "self-knowledge", file: "service_unit")), and the app through Flatpak. Installing the package does not remove the Flatpak: both are `io.tezra.Fermix`, so remove the Flatpak once the package is installed (`flatpak uninstall --user io.tezra.Fermix`).
