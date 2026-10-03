# Configuration: where settings live, secrets, and the config file

## Where to change a setting

- **Mac app** (production on a Mac): Settings (⌘,). A change that needs a restart shows **Restart to apply** > **Restart…**. Never send a Mac app user to `fermix setup`, the CLI or `config.toml` for anything a pane has a control for.

| Pane | Holds |
|---|---|
| Providers | each provider's sign-in or key, **Model**, **Reasoning effort**, **Fast mode**, **Details…** > **Use as primary**; Model behavior > **Sub-agent model** |
| Personality | About you: **Your name**, **Time zone**, **Style**, **Call the assistant**; **Suggest new skills from tasks you repeat** |
| Memory | **Compact a conversation at**, **Review memory every** |
| Channels | each chat channel; Editors > **Accept editor connections** (ACP) |
| Integrations | plugins, MCP servers, plugin sign-in clients |
| Voice, Meetings | the voice companion; the notetaker |
| Computer | **Computer use** (**Work inside one window**), **Computer history** (**Apps**, **Summarize with**) |
| Coding agents | **Allow coding agents to run on this Mac**, **Preferred tool** |
| Search | **Web search** backend and its key (the Brave key also powers place search) |
| Images | **Images** backend, **Model**, its key |
| Sandbox | **Sandbox** mode, **Command profile**, **Allowed environment variables** |
| Browser | which browser tasks run in (read-only), **Run tasks**, **Most open tabs**, **Private hosts the browser may open**; downloads Chromium when none is installed |
| Permissions | macOS permissions |

- **Linux and dev installs**: browser setup (`fermix setup` opens it with a one-time `/setup?t=…` link; the durable setup token never goes in a URL), the terminal wizard (`fermix setup --terminal`), `fermix setup --<flag>` for headless values, or `config.toml`, then `fermix restart`.
- **Needs a restart** (read at boot): providers, routing, the outbound proxy, voice, channels, ACP, sandbox (except `[sandbox.env]`, read per command), coding harness, skill curation, meetings, computer use, computer history. Setup and the app say which change is waiting.

## `config.toml`

`$FERMIX_HOME/config.toml`. An unknown key in a strictly checked section (every provider block, `[fermix_core.tools.generate_image]`) stops the daemon from booting, naming the key. String values are TOML basic strings: a line break or tab is stored as `\n`/`\t` and reads back unchanged, and a list entry holding a comma stays one entry.

| Section | Keys |
|---|---|
| `[fermix_core]` | `profile` (keyring namespace), `secret_store` (`keyring` or `file`) |
| `[fermix_core.agent]` | `name` (the assistant's name); legacy `provider` |
| `[fermix_core.personalization]` | `user_name`, `timezone`, `communication_style` |
| `[fermix_core.providers.<name>]` | see the `providers` reference |
| `[fermix_core.routing]` | `subagent_*`, `cron_*`, `meeting_*` (`model`, `provider`, `reasoning_effort`) |
| `[fermix_core.tools.web_search]` | backend and its keys |
| `[fermix_core.tools.tool_search]` | `enabled` (tool-schema deferral; on when absent) |
| `[fermix_core.tools.generate_image]` | `backend` (`openai`, `xai`, `google`, `openai_codex`), `model`, `size`, `google_api_key`; nothing else |
| `[fermix_core.browser]` | `allowed_hosts`, `default_profile` (how tasks run), `max_tabs`, `launch_app` (may the engine open the Fermix app for its browser pane; on by default only inside the app) |
| `[fermix_core.compaction]` | `enabled`, `threshold`, `reasoning_effort` |
| `[fermix_core.network]` | `proxy` (`http://host:port`), `proxy_bypass` (list of hosts or `.suffix` entries); nothing else, see Outbound proxy below. Set with `fermix setup --proxy` on Linux |
| `[fermix_core.transcription]` | `backend` (`openai`, `xai`, `deepgram`, `local`), `model`, `max_file_mb`, `openai_api_key`/`xai_api_key` (override the chat key), `deepgram_api_key` (required for Deepgram), all in the keychain; `local_offered` (puts the unshipped on-device choice back in setup) |
| `[fermix_core.meetings]` | `enabled` (off by default), `bot_name`, `announce`, `announce_message`, `transcription_backend`, `retain_audio`, the Zoom RTMS values `zoom_account_id`, `zoom_client_id`, `zoom_client_secret` (kept in the keychain) and `zoom_ws_subscription_id` |
| `[fermix_core.harness]` | `enabled`, `approved`, `default_vendor`, `cloud_enabled` |
| `[fermix_core.skill_curation]` | `enabled` |
| `[fermix_core.computer_use]` | includes `background` (experimental, off) |
| `[fermix_core.jobs\|memory\|realtime\|computer_history\|plugins]` | per-feature settings |
| `[fermix_core.oauth.<provider>]` | plugin sign-in clients (`google`, `github`, `notion`, `x`, `slack`, `tesla`): `client_id`, `client_secret` (keychain) |
| `[fermix_core.plugin_secrets]` | api_key plugin tokens, keyed by plugin name (keychain) |
| `[fermix_web]` | `port` (default 4030) |
| `[sandbox]`, `[sandbox.env]`, `[sandbox.commands]` | mode and roots; child environment; command profiles |
| `[mcp.servers.<name>]` | outbound MCP servers |
| `[mcp.inbound]` | parsed but reserved: no inbound MCP server is started |
| `[fermix_channels.<name>]` | chat channels, ACP, mobile |

**Edits made outside Fermix** stop writes rather than lose them: the daemon keeps two baselines (what it booted from, what it last wrote) to tell its own writes apart. While an outside change stands, every save refuses naming the changed sections, setup shows a banner, and the one action is **Reload settings from disk** (Mac and browser setup). An unreadable file is a different state, reported in the parser's words with no reload offered; fix the file first (the Mac app says "The settings file cannot be read" and offers **Open recovery**, which shows the file and the copy from before).

## Outbound proxy

For a host that may only reach the internet through an HTTP proxy. On Linux and dev installs, `fermix setup --proxy http://host:port [--proxy-bypass host,.suffix]` writes it (`--proxy ""` removes it); it can also be set in `config.toml`. There is no Mac Settings pane for it yet. It is read when Fermix starts, so restart after changing it (`fermix doctor` shows the setting in the file, not what a running daemon started on).

```toml
[fermix_core.network]
proxy = "http://proxy.corp.example:3128"
proxy_bypass = ["ollama.internal", ".corp.example"]
```

- `proxy` is an `http://host:port` URL (the host a name or an IPv4 address) with no credentials, path or query; anything else stops the daemon from booting, and the message never prints the value. A proxy that demands a sign-in is not supported: it answers 407 and the reply says so. An unknown key in the section also stops the boot, so a misspelt `proxy` is not silently ignored.
- Fermix does not read `HTTP_PROXY`, `HTTPS_PROXY` or `NO_PROXY`. `fermix doctor` (row `network`) warns when the environment sets one and the section is empty.
- Direct without being listed: `localhost`, and address literals on this machine or its own networks (loopback, private ranges, link-local). Every other name goes to the proxy, `.localhost` names included. `proxy_bypass` adds exact host names and suffixes written with a leading dot. There is no wildcard.
- What goes through it: provider calls, channel APIs, web search and fetch, plugin HTTP calls, sign-in and token refresh, downloads (upgrades, sidecars, the computer-use helper), the doctor probes and trace export. HTTPS is tunnelled with `CONNECT`, so TLS is verified end to end and the proxy sees no plaintext. A connect gets the same time budget as a direct one, shared across reaching the proxy, opening the tunnel and the TLS handshake.
- `web_fetch` and link previews still look the name up on this machine first (they need working DNS here) and refuse a private address as always. Over HTTPS they then tunnel to the address they validated, so the proxy is never handed a name to resolve again. A plain `http://` page cannot keep that guarantee through a proxy and is refused; the `https://` address of the same page works.
- If the proxy refuses or cannot be reached, the request fails. Nothing falls back to a direct connection, and another provider is not tried, because every route leaves through the same proxy. A turn's reply says the proxy was the failure (a proxy that wants a sign-in answers 407, which Fermix does not send); an unreachable proxy is tried again briefly first, and the daemon log has the status the proxy gave. A proxy that drops a connection midway can still read as a timeout.
- What cannot use it and refuses a proxied host: voice, the Discord gateway, Zoom meeting capture, streaming transcription, remote MCP plugins and phone push. They work only for hosts listed in `proxy_bypass` that this machine reaches directly.
- Not configured by it: programs Fermix starts make their own connections (commands the agent runs, coding agents, the browser, sidecars).

## Secrets

- A secret is written as plaintext, `@keyring`, `@file`, or an env var. Two stores, chosen by `[fermix_core] secret_store`: the OS keyring (default: macOS keychain, Linux Secret Service via `secret-tool`) or one `0600` file per secret under `$FERMIX_HOME/secrets/` (`0700`, readable only by that account, not encrypted at rest, like `auth.json`). New secrets go to the configured store; each sentinel is read from the store it names, so a home can hold both. An unchanged plaintext value is kept as it is.
- **Choosing and moving** (Linux, standalone): `fermix setup --secret-store file|keyring`. When the keyring cannot be used, the terminal wizard asks once: on a host with no display (a server over SSH) it asks first, before any other question, with the file store as the default answer; on a desktop it asks when a save is refused, with the keyring kept unless the answer is yes. `fermix setup --migrate-secrets` moves every secret not in the configured store into it, one confirmation each, and refuses up front when the store it must leave cannot be read. On a Mac the app saves every key to the keychain from its panes.
- **Profiles.** `[fermix_core] profile` (default `general`) namespaces keyring entries (account `fermix`, service `fermix:<ENV>` for the default, `fermix:<profile>:<ENV>` otherwise) so two homes (`~/.fermix`, `~/.fermix-dev`) do not overwrite each other. Set it before saving secrets: changing it later orphans the old entries until they are saved again.
- **Locked Linux keyring.** Before any write or boot-time read the store is probed with three read-only `busctl --user` questions, so a locked GNOME keyring is reported as `locked` instead of raising an unlock dialog from the daemon. Fingerprint or automatic login leaves the login keyring locked. A save the person makes on a locked keyring waits up to two minutes for them to answer the unlock prompt; a cancelled or unanswered prompt is refused with the file-store hint. With no keyring service, session bus or `secret-tool`, the save is refused before writing. At boot, sentinels of an unusable store stay put with one log line.
- **macOS keychain.** Every save deletes and re-adds the item with an open ACL (`security -A`), so the daemon reads it with no prompt. An older item that keeps raising "security wants to use the login keychain" heals when it is saved again: store that key again in the app's pane (Linux or standalone: re-run `fermix setup`).
- `fermix doctor`'s `secret store` row names the configured store, its state and how many secrets each store holds.
