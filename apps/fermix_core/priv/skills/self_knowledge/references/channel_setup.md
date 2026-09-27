# Connecting a chat channel

The answer to "how do I connect Telegram / Discord / Slack / WhatsApp / Signal?": what each needs, where each value comes from, where it is entered, and what to send first. Every channel needs the platform credentials plus the owner's own id on that platform.

## Where the values go

- **Mac app** (production on a Mac): Settings > Channels > the channel's row > **Set up…** (**Change…** once set). Paste each token and click **Store** beside it (or press Return): closing the sheet first discards the token, whatever the sheet's "Saved as you type" says. Other fields save on Return or when you leave them. Make sure the switch beside the row is on (storing a token does not turn it on), then **Restart to apply** > **Restart…**. Never send a Mac app user to `fermix setup` (on an app-managed Mac it only opens the app), or to `config.toml` for anything the app has a field for.
- **Linux or dev install**: browser setup (`fermix setup`) > Channels tab > the channel's card > **Save channel**, then **Apply & restart**. Headless: the `fermix setup --<channel>-…` flags below, then `fermix restart` (a token passed as a flag lands in shell history; the Channels tab avoids that). Or the `[fermix_channels.<name>]` keys in `config.toml`. Browser and terminal setup have no on/off switch: saving a credential turns the channel on.
- Tokens and secrets go to the OS keychain/keyring (or the file store); `config.toml` holds only `@keyring`/`@file`. Ids and phone numbers are plain `config.toml` text and must be quoted strings: an unquoted `owner_user_id`, `bot_user_id`, `phone_number_id` or Signal `account` is silently dropped.
- A restart is always needed: channels start only at boot. No channel starts until setup is complete (provider, name, time zone, style).

## Telegram

No public URL: Fermix polls Telegram.

- **Bot token**: in Telegram open @BotFather, send `/newbot`, give a display name and a username ending in `bot`, copy the token (`123456789:AA…`) exactly, with no `bot` prefix. `/token` in @BotFather issues a new one. Mac **Bot token**; browser **Bot token**; `--telegram-bot-token`; `bot_token`. Never read from the environment.
- **Your numeric user id** (not your @username, not your phone number): open @userinfobot, press **Start**, copy the number. Mac **Your Telegram user ID**; browser **Owner user ID**; `--telegram-owner-user-id`; `owner_user_id = "123456789"`.
- **First message**: after the restart, open `https://t.me/<bot_username>` and press **Start** (it sends `/start`); Fermix answers, and `/whoami` then echoes the id you entered. Messages sent before the restart are discarded. Pressing Start once is also what lets reminders reach you: Telegram refuses a bot's first message to a user who never started it.
- **Groups**: direct messages are the main path. In a group, privacy mode hides ordinary messages from the bot: @BotFather `/setprivacy` > Disable, then re-add the bot, or make it an admin.

Failures:
- No owner id → Telegram never starts, nothing answers, the app still says Connected, the boot log says "Refusing to start the telegram adapter" → enter the id, restart.
- @username or phone number as owner → every message dropped, log `Dispatcher ingress denied telegram message (unauthorized)` → use the numeric id.
- Token with a `bot` prefix or truncated → Doctor network check shows `invalid bot token (Telegram API HTTP 404 …)` → paste the exact @BotFather string. Revoked token → HTTP 401.
- Two pollers on one token (a dev and a prod home, another bot framework) or a webhook left on it by an earlier tool → `409` poll errors, channel degraded → one bot per install; open `https://api.telegram.org/bot<TOKEN>/deleteWebhook` once.

## Discord

No public URL: Fermix connects out over Discord's Gateway.

- **Bot token**: create an application at https://discord.com/developers/applications, then **Bot** > **Reset Token** > copy (shown once). Mac **Bot token**; `--discord-bot-token`; `bot_token`.
- **Bot user ID**: the app's **Application ID** (General Information); the same number. Mac **Bot user ID**; `--discord-bot-user-id`; `bot_user_id`.
- **Your Discord user ID**: User Settings > Advanced > **Developer Mode** on, then right-click your own name > **Copy User ID**. Mac **Your Discord user ID**; browser **Owner user ID**; `--discord-owner-user-id`; `owner_user_id`.
- **Portal settings**: Bot page > Privileged Gateway Intents > **Message Content Intent** on > Save. Leave General Information > **Interactions Endpoint URL** empty: with a URL set every Approve/Deny tap fails, and a server-channel prompt shows no token to type instead.
- **Invite**: `https://discord.com/oauth2/authorize?client_id=<APPLICATION_ID>&scope=bot&permissions=274878008384` (View Channels, Send Messages, Send Messages in Threads, Attach Files, Read Message History, Add Reactions). You need a server shared with the bot to open a DM with it; a private test server is enough.
- **First message**: after the restart, click the bot in the member list > Message, send `hi`. In a server channel, @mention the bot user (not a role with its name); un-mentioned server messages are ignored.

Failures:
- Message Content Intent off → the bot never comes online and no error is logged (the log even says `Discord gateway socket connected`), while Doctor and the app still look fine → turn it on, Save, restart. Left off for long, the reconnect loop can use up Discord's 1,000 daily identifies, and Discord then resets the token and emails you → **Reset Token** too.
- Owner id blank → the adapter refuses to start (boot log) → fill it, restart.
- Wrong owner id (often the bot's) → every message dropped silently → copy your own id.
- Bot user ID wrong → DMs work, server mentions are ignored; Doctor shows `bot_user_id <x> does not match <y>` with the right value. Blank → the same, the app shows **Needs setup**, and Doctor says `discord bot_token or bot_user_id is not configured`.
- Read Message History missing in a channel → no reply, log `Discord send failed: 403` (every reply is a Discord reply).
- Token reset in the portal → log `Discord gateway URL fetch failed: 401` → paste the new token, restart.

## Slack

Needs a public HTTPS URL (Events API webhook; Socket Mode is not supported).

- **Bot token** (`xoxb-…`): https://api.slack.com/apps > Create New App > From a manifest (below) > OAuth & Permissions > **Install to Workspace** > copy the **Bot User OAuth Token**. Mac **Bot token**; `--slack-bot-token`; `bot_token`.
- **Signing Secret**: Basic Information > App Credentials > **Signing Secret**. Mac **Signing secret**; `--slack-signing-secret`; `signing_secret`.
- **Your member ID** (`U…`, or `W…` on Enterprise Grid; not a name or email): your Slack profile > More (⋮) > **Copy member ID**. Mac **Your Slack user ID**; browser **Owner user ID**; `--slack-owner-user-id`; `owner_user_id`.

Manifest (bot scopes, DMs allowed, rotation and Socket Mode off):

```yaml
display_information:
  name: Fermix
features:
  app_home:
    home_tab_enabled: false
    messages_tab_enabled: true
    messages_tab_read_only_enabled: false
  bot_user:
    display_name: Fermix
    always_online: true
oauth_config:
  scopes:
    bot: [app_mentions:read, chat:write, files:read, files:write, im:history, reactions:write]
settings:
  org_deploy_enabled: false
  socket_mode_enabled: false
  token_rotation_enabled: false
```

Order matters: save the token and signing secret in Fermix and restart first, because Fermix answers Slack's URL check only after verifying its signature. Then Event Subscriptions > Enable Events > Request URL `https://<public-host>/webhook/slack` > wait for **Verified** > Subscribe to bot events: `app_mention` and `message.im` > Save Changes (reinstall if Slack asks).

- **First message**: DM: Apps > the app > Messages tab > `hi`. Channel: `/invite @Fermix`, then `@Fermix hello`; the reply lands in a thread. Slack treats a leading `/` as its own slash command: in a channel send `@Fermix /new`; in a DM start with a space (` /new`), because a mention is not stripped in a DM.

Failures:
- Request URL entered before the secret was saved → "Your URL didn't respond with the value of the challenge parameter" → save the secret, restart, retry the URL.
- `http://`, a wrong path, or `127.0.0.1` as the Request URL → Slack cannot verify it → an HTTPS tunnel URL ending `/webhook/slack`.
- Owner id empty or not a member ID → the app says Connected, nothing answers → Copy member ID.
- "Sending messages to this app has been turned off." → App Home > Messages Tab on, allow sending messages.
- Mentioned in a channel the app is not in, or a channel message without the mention → ignored → `/invite`, and @mention every time, thread replies included.
- Token rotation on → the token dies within 12 hours and rotation cannot be turned off → create a new app with it off.
- `missing_scope` in the log → add the scopes, reinstall.
- Clock more than 5 minutes off → every event fails `:stale_timestamp`.
- Tunnel down or Mac asleep for long → Slack disables event delivery and emails the app owner → stable hostname, re-enable under the Slack app's Event Subscriptions.

## WhatsApp

Meta's WhatsApp Cloud API. Needs a public HTTPS URL. All values come from the Meta App Dashboard (developers.facebook.com) for an app created with the "Connect with customers through WhatsApp" use case.

- **Access token**: a permanent system-user token: Business Settings > System users > Add > Assign assets (the app and the WhatsApp account, full control) > Generate token with `whatsapp_business_messaging`, `whatsapp_business_management`, `business_management`. The API Setup page's **Generate access token** expires within 24 hours; test only. Mac **Access token**; `--whatsapp-access-token`; `access_token`.
- **Phone number ID**: WhatsApp > API Setup > the ID under **From** (not the WhatsApp Business Account ID). Mac **Phone number ID**; `--whatsapp-phone-number-id`; `phone_number_id`.
- **Verify token**: any string you make up; the same string goes into Meta's Configuration > Verify token. Mac **Verify token**; `--whatsapp-verify-token`; `verify_token`.
- **App secret**: App settings > Basic > App secret. Mac **App secret**; `--whatsapp-app-secret`; `app_secret`.
- **Your WhatsApp number**: the personal number you message from, digits only with country code, no `+`, spaces or `00` (`15551234567`). Mac **Your WhatsApp ID**; browser **Owner user ID**; `--whatsapp-owner-user-id`; `owner_user_id`.
- The business number is Meta's free test number or a registered one; it cannot be the number you chat from. With the test number, add your own number under API Setup > To > Manage phone number list.

Order: save the values, restart, start the tunnel; then WhatsApp > Configuration > Callback URL `https://<public-host>/webhook/whatsapp` + the Verify token > **Verify and save**, and subscribe the `messages` webhook field.

- **First message**: from your personal WhatsApp, message the business number. `/whoami` answering with your number proves the webhook, the signature, the owner match and sending. Direct messages only; no groups.

Failures:
- Temporary token expired → messages arrive, no replies, log `WhatsApp send failed: 401` → system-user token.
- Owner number with `+` or spaces → every message dropped, log `Dispatcher ingress denied whatsapp message (unauthorized)` → digits only.
- WhatsApp Business Account ID used as Phone number ID → Doctor network check fails with HTTP 400 → the ID under From.
- **Verify and save** refused → tunnel down, Fermix not restarted, or the strings differ; log `WhatsApp webhook verification auth failed: :invalid_token`.
- Wrong app secret → log `WhatsApp webhook auth failed: :invalid_signature`.
- `messages` field not subscribed → nothing arrives and nothing is logged.
- Channel switched off → Meta still gets `200` and the messages are dropped silently → turn it on, restart.
- A reminder or job sent more than 24 hours after your last message → not delivered: outside that window Meta accepts only template messages, which Fermix does not send → message it daily, or deliver to Telegram.

## Signal

No public URL: Fermix runs `signal-cli` on the same machine.

**Fermix cannot receive Signal messages.** Its `signal-cli receive` call fails, so nothing you send arrives and the log shows `Signal listener error: …` every 5 seconds (by default `signal-cli executable not found at signal-cli`, even with signal-cli installed), while Doctor and the app look fine. Sending to your number (reminders, jobs) works. Say so before any Signal walkthrough and offer Telegram.

- **Signal account**: a separate number used only by Fermix, in `+E.164` (`+15551230000`), registered or linked in signal-cli by the same OS user that runs Fermix. Install with `brew install signal-cli` on a Mac or signal-cli's release build on Linux. Register a spare number: solve https://signalcaptchas.org/registration/generate.html, copy the `signalcaptcha://…` link, run `signal-cli -a +15551230000 register --captcha '<link>'`, then `signal-cli -a +15551230000 verify <code>`. Or link a spare phone's account: `signal-cli link -n Fermix` prints a `sgnl://linkdevice…` link; turn it into a QR code (for example with `qrencode`) and scan that in Signal > Settings > Linked devices. Never register your personal number: that logs your phone out of Signal. Mac **Signal account**; browser **Account**; `--signal-account`; `account`.
- **Your Signal number**, in `+E.164` (`+15557654321`). Mac **Your Signal number**; browser **Owner user ID**; `--signal-owner-user-id`; `owner_user_id`.
- Nothing is secret: both are plain `config.toml` text. `cli_path` (an absolute path to signal-cli) has no app or browser field: set it in `config.toml` (or `SIGNAL_CLI_PATH` on a Linux or dev install).
- **First message**: from your phone, message the Fermix number `hi`. Direct messages only; group messages are ignored.
- A number without the `+` or with spaces never matches the sender. Keep signal-cli current (`brew upgrade signal-cli`); old releases stop working.

## Who may talk: owner and allow lists

- `owner_user_id` is the operator: full tools and owner commands. With no allow list, the owner is the only sender let in.
- Guests: `allowed_user_ids` (Telegram, Discord, Slack) or `allowed_sender_ids` (WhatsApp, Signal), a list of quoted ids in `config.toml`; neither the app nor browser setup has a field. Guests get read-only chat. Setting a list replaces the owner-only default (the owner still gets in); an empty list (`[]`, or an empty `*_ALLOWED_*_IDS` variable on a Linux or dev install) keeps Telegram, Discord and Signal from starting even with an owner set.
- `command_allowlist` lets listed guests run owner-tier commands such as `/new` and `/compact`; each must also be on the guest list, or they never reach Fermix.
- With neither an owner nor a list, Telegram, Discord and Signal refuse to start ("Refusing to start the <channel> adapter" in the boot log) and the Slack and WhatsApp webhooks drop every sender. A sender who is not allowed gets no reply at all.
- Reminders and skill proposals go to `[fermix_core.jobs] default_delivery_target` when set, else to the owner on the first of Telegram, Signal and WhatsApp with an `owner_user_id`; a Discord or Slack owner needs that target. A scheduled job delivers only where it was told to (its origin, an explicit target, or that default), never to an owner id on its own.

## Finding an id

| Channel | Owner id | Where |
|---|---|---|
| Telegram | numeric user id | @userinfobot > Start |
| Discord | numeric user id | Developer Mode > right-click yourself > Copy User ID |
| Slack | member ID `U…` (`W…` on Enterprise Grid) | profile > More > Copy member ID |
| WhatsApp | your number, digits with country code | your own number |
| Signal | your number in `+E.164` | your own number |

`/whoami` replies "Your user id on this channel: <id>", but only to a sender already allowed in, so it confirms an id and can never discover one. The boot log's "Run /whoami" advice does not work on a first setup.

## Checking a connection

- The app's **Connected** means the switch is on and the credentials are stored. It ignores the owner id and says nothing about whether the platform reaches Fermix; **Needs setup** means a credential is missing.
- Doctor > **Run network checks** in the app (`fermix doctor --full` on Linux or dev): the `channel health` row checks only the token (plus Discord's bot user ID and WhatsApp's Phone number ID), not intents, webhook secrets, the public URL or the owner id; `command owners` warns when `owner_user_id` is missing.
- A reply to the first message is the real proof. Logs: the app's Logs, or `~/.fermix/logs/fermix.log`.

## The public URL (Slack, WhatsApp)

Fermix serves plain HTTP on `127.0.0.1:4030` (`[fermix_web] port`); Slack and Meta call only HTTPS URLs with a valid certificate. Run an HTTPS tunnel or reverse proxy on the same machine (Cloudflare Tunnel, ngrok, Tailscale Funnel) that forwards to `http://127.0.0.1:4030`, and give the platform `https://<public-host>/webhook/slack` or `/webhook/whatsapp`. Forward only those paths if the tool allows it: the listener also serves the status page and `/health`. No `FERMIX_HTTP_BIND` change is needed, and on an app-managed Mac a same-machine tunnel or proxy is the only route. Those tunnels send `X-Forwarded-Proto: https` themselves; a hand-built reverse proxy must send it too (or forward with host `127.0.0.1`), or Fermix answers with a redirect to HTTPS and the platform's URL check fails. Fermix ships no tunnel. When the tunnel's hostname changes, update the Request or Callback URL.
