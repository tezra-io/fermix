# The Fermix desktop app on Linux

The Fermix desktop app is a Flatpak, `io.tezra.Fermix` (GTK and libadwaita, the GNOME runtime). It carries no engine: it is only a client of the host's own Fermix daemon, the package's systemd user unit `fermix.service`, and draws what that daemon publishes. The prompt's `## This Fermix` section says whether it was installed when this Fermix started; one installed later is seen at the next restart.

Answer a Linux app user with the app's labels for anything it has a control for (Settings > <pane>, Home's switches), and with the `fermix` command for what it does not have. The package's `fermix` is the command line; the app adds none of its own.

## What it talks to

- Settings, sign-in and status: `~/.fermix/daemon.sock`, the management protocol the Mac app speaks too. Every row, label and rule in its settings is the daemon's own.
- Chat: `~/.fermix/acp.sock`, as an ACP client. Each **New conversation** is its own conversation with Fermix, at operator trust; it is not the Mac app's chat and does not share the phone's timeline. As on any ACP session there are no slash commands, no approval cards (a sandbox refusal is final) and no origin-mode scheduling. It sends text only; a picture in a reply shows, and a file Fermix sends is named in the reply as not transferable.
- Voice: `~/.fermix/realtime.sock`, from the **Pet** page.
- It reads `~/.fermix` read-only and never touches the config, secrets or memory files there; it asks the systemd user manager (`fermix.service`) and logind (linger) for the background service, and the desktop's tray host for its tray icon.

## Pages

**Chat**, **Pet** (**Begin voice call**), **Home**, **Doctor** and **Logs** in the sidebar, with **Settings** at its foot. The header carries **Restart Fermix…**, **Continue setup** while setup is incomplete, and **New conversation** on Chat.

- **Home**: Fermix's status and details; what needs attention, each with the button that fixes it (the pane that owns it, a provider's sign-in, **Restart Fermix…**, or **Open setup page** for what no pane holds); and the Background switches: **Run in the background** (turns linger on, then enables and starts `fermix.service`; off unregisters and stops it) and **Open at login** (through the desktop's Background portal: the app opens in the tray at login). When the daemon is not running it offers **Start Fermix**.
- **Doctor** runs the daemon's checks (**Run checks**); **Logs** follows the daemon log.
- The tray menu: **Open Fermix**, **Settings**, **Run Doctor**, **Restart Fermix…** (or **Start Fermix** when it is not running), **Show Pet**, **Run in the Background**, **Quit**.

## Settings

Fourteen panes, in this order: Providers, Personality, Memory, Channels, Integrations, Voice, Meetings, Computer, Coding agents, Search, Images, Secrets, Sandbox, Permissions (grouped Assistant, Connections, Capabilities and System). The rows in each are the daemon's, so they match the browser setup page and the Mac app's panes for the same section. In Providers each provider row offers its ways in, most direct first (**Sign in**, **Import from** a sign-in already on the machine, **Paste a setup token…** for Anthropic, **Use an API key…**), and its menu holds **Make primary**, **Replace key…**, **Remove key** and **Sign out**. A setting this copy of the app has no control for says so and asks for an app update.

## What it does not have

- No Phone pane: pairing a phone is `fermix pair` from the owner's own terminal.
- No computer history (a macOS feature), so that section is hidden.
- No bundled engine and no updater of its own: the engine updates with the package (skill_view(name: "self-knowledge", file: "service_unit")), the app through Flatpak.
