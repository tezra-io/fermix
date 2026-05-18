# Milestone 11: Outbound Media on Channels — Functional Design

**Status:** Draft (rev 3 — adds category-based tool visibility so non-channel agents do not see `send_attachment`)
**Date:** 2026-05-18
**Author:** Sujeeth / Aira
**Depends on:** M3 (channel coverage and `FermixChannels.Channel` behaviour), M4.9 (`Capability` + `Capabilities.Builtin.Tool` surface), M5 (`Sandbox.read_path/3` floor)
**Blocks:** any agent workflow that has to deliver an image, voice note, document, or audio file to a channel user.
**Defers to other milestones:** outbound media generation tools — M11 ships the egress pipe, not new producers; the LLM attaches files that already exist on disk. URLs remain ordinary text replies so the channel platform can render or preview them itself. Voice-companion media (M9.x) stays in its own Realtime path.
**References:** `apps/fermix_channels/lib/fermix_channels/channel.ex`, `apps/fermix_channels/lib/fermix_channels/message.ex`, `apps/fermix_channels/lib/fermix_channels/dispatcher.ex`, `apps/fermix_channels/lib/fermix_channels/telegram.ex`, `apps/fermix_channels/lib/fermix_channels/discord.ex`, `apps/fermix_channels/lib/fermix_channels/slack.ex`, `apps/fermix_channels/lib/fermix_channels/whatsapp.ex`, `apps/fermix_channels/lib/fermix_channels/signal.ex`, `apps/fermix_channels/lib/fermix_channels/cli.ex`, `apps/fermix_channels/lib/fermix_channels/command.ex`, `apps/fermix_channels/lib/fermix_channels/commands.ex`, `apps/fermix_channels/lib/fermix_channels/commands/*`, `apps/fermix_channels/lib/fermix_channels/idempotency.ex`, `apps/fermix_channels/mix.exs`, `apps/fermix_core/lib/fermix_core/agents/main_agent.ex`, `apps/fermix_core/lib/fermix_core/agent_loop.ex`, `apps/fermix_core/lib/fermix_core/capabilities/builtin/tool.ex`, `apps/fermix_core/lib/fermix_core/tools/file_write.ex`, `apps/fermix_core/lib/fermix_core/tools/file_read.ex`, `apps/fermix_core/lib/fermix_core/sandbox.ex`, `apps/fermix_core/mix.exs`, [Telegram Bot API §"Sending files"](https://core.telegram.org/bots/api#sending-files), [Telegram `sendPhoto`](https://core.telegram.org/bots/api#sendphoto), [Telegram `sendVoice`](https://core.telegram.org/bots/api#sendvoice), [Discord File Attachments FAQ](https://support.discord.com/hc/en-us/articles/25444343291031-File-Attachments-FAQ), [Discord create-message](https://docs.discord.com/developers/reference), [Slack `files.getUploadURLExternal`](https://docs.slack.dev/reference/methods/files.getUploadURLExternal), [Slack `files.completeUploadExternal`](https://docs.slack.dev/reference/methods/files.completeUploadExternal), [WhatsApp Cloud Media](https://developers.facebook.com/docs/whatsapp/cloud-api/reference/media), [`signal-cli send --attachment`](https://github.com/AsamK/signal-cli/wiki/Send-and-Receive-Messages).

---

## Revision History

- **rev 2 (2026-05-18).** Addresses code-review findings on rev 1:
  - F1 (blocking): rev 1 put `FermixChannels.*` references inside a `fermix_core` tool, which would create an umbrella cycle (`apps/fermix_channels/mix.exs:28` already lists `fermix_core` as a dep). Rev 2 introduces a types-only module `FermixCore.Channels.Outbound` in core and moves *all* channel-specific runtime (caps, idempotency, MIME mapping) into each channel adapter. Core has zero compile-time reference to `FermixChannels`.
  - F2 (blocking): rev 1's `SendAttachment` returned `%{success: true, kind: ..., bytes: ...}`, which does not match `FermixCore.Capabilities.Builtin.Tool.tool_result()` (`tool.ex:16-20`) and would break the `AgentLoop` tool-result handler at `agent_loop.ex:265-281`. Rev 2 uses `Tool.success/1` / `Tool.error/1` returning the canonical `%{success, output, error}` shape.
  - F3 (blocking): the tool context at `main_agent.ex:559-576` does not currently expose `reply_fn` or `channel`. Rev 2 specifies the exact diff to `process_message/2` and constrains the new context surface to the minimum SendAttachment needs.
  - F4 (high): rev 1 simultaneously widened `Channel.reply_fn` *and* kept `build_reply/1` text-shaped, which contradicts the existing typespec. Rev 2 renames `build_reply/1` → `build_text_reply/1`, adds `build_media_reply/1`, and has the dispatcher compose them into one multiplexed reply fn.
  - F5 (high): rev 1 missed the channel-side command surface. Production calls `reply_fn.("…")` happen in `dispatcher.ex`, `commands.ex`, `commands/help.ex`, `commands/whoami.ex` (×2), `commands/compact.ex` (×4), `commands/sandbox.ex`, `commands/new.ex`, and `main_agent.ex`. The `Command` callback at `command.ex:13-17` types `reply_fn` as string-only. Rev 2 enumerates every site and widens the Command callback type.
  - F6 (high): rev 1 listed five channels and missed `FermixChannels.CLI` (`cli.ex:9` declares the behaviour). Rev 2 includes CLI: its `send_media/3` returns `{:error, :media_unsupported}` (CLI is a terminal stdout pipe; pretending it has a media transport is the kind of fallback rule 12 forbids).
  - F7 (high): rev 1 specified PUT for the Slack upload-URL step. Slack's docs say POST. Rev 2 corrects this and lists `files.completeUploadExternal`'s actual parameter names (`files`, `channel_id`, `thread_ts`, `initial_comment`).
  - F8 (medium): rev 1's cap matrix was guessed. Rev 2 uses researched values per §5.7 — Telegram photo 10 MB / voice-render 1 MB / others 50 MB, Discord 10 MiB default with server-boost notes, Slack 1 GiB platform max (we ship a 100 MiB conservative cap), WhatsApp image 5 MB / audio 16 MB / video 16 MB / doc 100 MB, Signal 100 MB. WhatsApp does not have a `voice` message type; `:voice` is mapped to WhatsApp `audio` with required MIME `audio/ogg; codecs=opus`.

- **rev 3 (2026-05-18).** Two additions:
  - Author copy-edit pass on §1, §5.6 description, and §9.1 to make the URL stance explicit: `send_attachment` is local-files-only; URLs ride as text so the channel platform renders/previews them natively. No `web_fetch` chain implied. Remote-URL acceptance moves from §9 "deferred" to §1 non-goal.
  - New mechanism — **category-based tool visibility** (§3.13, §5.12). Tool `category/0` metadata already exists (`tool.ex:35`) but is not read for filtering today. M11 introduces `CapabilityRegistry.list_for/1` with an `excluded_categories` option, and has each agent runtime declare its exclusions once (main agent: none; voice agent: `[:channel]`). This prevents `send_attachment` from polluting the voice-agent prompt context, and gives every future cross-cutting tool (e.g. a future `image_gen` with category `:media_producer`) a one-line opt-out per agent instead of per-name allowlist bookkeeping that scales as `O(tools × agents)`.

---

## 1. Problem / Goal

Every channel adapter today implements `send_message(chat_id, text, opts)` and nothing else (`apps/fermix_channels/lib/fermix_channels/channel.ex:35`). The dispatcher builds a single-arg reply hook of type `(String.t() -> :ok | {:error, term()})` (`channel.ex:18`) and passes it to the main agent. The agent's typespec confirms the shape (`apps/fermix_core/lib/fermix_core/agents/main_agent.ex:55`), and the delivery call at `main_agent.ex:896` is `msg.reply_fn.(response)` with `response` being the LLM's final text. The result: when the agent decides to send a chart, a photo, an audio clip, or a generated PDF, the best it can do is `file_write` to disk and emit the *path* as part of the text reply. The user sees a path they can't open.

The inbound side is already structured (`Message.attachments` at `message.ex:24`; Slack/Signal/WhatsApp populate it; WhatsApp implements `download_attachment/2`). Outbound has no symmetric structure. The asymmetry is the bug.

**Goal of M11:** widen the channel outbound contract to carry structured media, implement the channel-side endpoints for all six existing channels, and add a single built-in tool (`send_attachment`) that lets the LLM emit a media intent through the same reply port the agent already owns — **without** introducing a `fermix_core` → `fermix_channels` dependency. After this milestone:

1. A new types-only module `FermixCore.Channels.Outbound` declares `media_kind`, `media_part`, `outbound`, `send_media_opts`, `reply_fn`. `FermixChannels.Channel` and `FermixCore.Tools.SendAttachment` both reference these types. The existing dep direction (`fermix_channels` → `fermix_core`) is preserved; the inverse is never introduced.
2. `FermixChannels.Channel` declares `send_media/3` as a required callback, plus a new `build_media_reply/1` companion to the renamed `build_text_reply/1` (was `build_reply/1`). `send_message/3` keeps its current shape and contract.
3. The dispatcher's reply hook is widened to a single multiplexed function `(outbound() -> :ok | {:error, term()})`. The dispatcher builds it by composing both per-channel reply builders. Bare-string replies are dropped in the same change set — every call site updated; no string sugar (CLAUDE.md rule 12).
4. Telegram routes `:image` → `sendPhoto`, `:voice` → `sendVoice`, `:audio` → `sendAudio`, `:video` → `sendVideo`, `:document` → `sendDocument`. Discord uses multipart `POST /channels/{id}/messages`. Slack uses `files.getUploadURLExternal` → **POST** to the upload URL → `files.completeUploadExternal`. WhatsApp uses `POST /{phone-id}/media` → `POST /{phone-id}/messages`, mapping `:voice` to type `audio` with `audio/ogg; codecs=opus`. Signal uses `signal-cli send --attachment <path>`. CLI returns `{:error, :media_unsupported}` — terminal output has no media transport.
5. The LLM gets one new tool — `send_attachment(path, kind, caption?)` — that returns the canonical `Tool.tool_result()` shape (`%{success, output, error}`). Each channel adapter owns its own size cap, MIME mapping, and idempotency. SendAttachment does not import `FermixChannels`; it only sees `context.reply_fn`.
6. Failure is loud and structured. The LLM sees a string error (per the existing `Tool.error/1` convention); operators read traces. No silent degradation to "paste the path as text."

**Non-goal in this milestone:**

- Media generation. M11 does not add image-gen, TTS, or chart tools. `send_attachment` consumes paths that already exist on disk.
- Remote URL fetching/re-uploading. If the agent has a link, it sends the link as text. `send_attachment` is only for an actual local attachment that would otherwise be exposed as a file path.
- Inbound→outbound forwarding helper. The shape allows it; no built-in capability does it automatically.
- Realtime / voice-companion media. M9.x owns Realtime egress.
- Streaming or chunked uploads. v1 is one multipart per send.
- Web LiveView attachment surface (M10). LiveView has its own out-of-band path.

---

## 2. References

- `apps/fermix_channels/lib/fermix_channels/channel.ex:18,35,47,54` — the current behaviour: `reply_fn` typed as `(String.t() -> _)`, `send_message/3` text-only, `download_attachment/2` already shows the inbound media pattern.
- `apps/fermix_channels/lib/fermix_channels/message.ex:24,41` — `attachments: [map()]` field, used by inbound.
- `apps/fermix_channels/lib/fermix_channels/dispatcher.ex:46-75` — `build_reply_fn/3` is the only place in the codebase that constructs the agent's reply port. Two production text-reply call sites (`:48`, `:66`).
- `apps/fermix_channels/lib/fermix_channels/command.ex:13-17` — the `Command` behaviour: `execute(Message.t(), reply_fn :: (String.t() -> :ok | {:error, term()}), context :: map())`. Widening this is part of the migration.
- `apps/fermix_channels/lib/fermix_channels/commands.ex:54` — `reply_fn.("This command requires owner permissions.")`.
- `apps/fermix_channels/lib/fermix_channels/commands/help.ex:32` — `reply_fn.("Available commands:\n#{body}")`.
- `apps/fermix_channels/lib/fermix_channels/commands/whoami.ex:21,27` — two text reply call sites.
- `apps/fermix_channels/lib/fermix_channels/commands/compact.ex:59,64,70,75` — four text reply call sites.
- `apps/fermix_channels/lib/fermix_channels/commands/sandbox.ex:185` — one text reply call site.
- `apps/fermix_channels/lib/fermix_channels/commands/new.ex:28` — one text reply call site.
- `apps/fermix_channels/lib/fermix_channels/cli.ex:9,79,108-110` — CLI channel declaration, in-process `dispatch_input_sync/2` reply closure, `build_reply/1` shape.
- `apps/fermix_channels/lib/fermix_channels/telegram.ex:48,101-130` — `send_message/3` plus `post_send_message/3`, the shape we mirror for media.
- `apps/fermix_channels/lib/fermix_channels/whatsapp.ex:23,94-101,256-308` — existing inbound media path; same byte-cap discipline and two-step (resolve → transfer) shape for outbound.
- `apps/fermix_channels/lib/fermix_channels/idempotency.ex` — extant inbound dedup module; outbound media uses a sibling bucket.
- `apps/fermix_channels/mix.exs:28` — declares `{:fermix_core, in_umbrella: true}`. The existing dep direction.
- `apps/fermix_core/mix.exs:26` — does **not** declare `fermix_channels`. M11 preserves this.
- `apps/fermix_core/lib/fermix_core/agents/main_agent.ex:55,121,127,559-576,896` — reply typespec, guard, context construction, delivery call.
- `apps/fermix_core/lib/fermix_core/agent_loop.ex:265-281` — `dispatch_capability/3` consumes `{:ok, %{success, output, error}}` only; any other return shape becomes `inspect(other)` to the LLM.
- `apps/fermix_core/lib/fermix_core/capabilities/builtin/tool.ex:16-52` — the `tool_result` type and `success/1` / `error/1` helpers.
- `apps/fermix_core/lib/fermix_core/tools/file_write.ex:6-9,69-80` — module shape, telemetry pattern.
- `apps/fermix_core/lib/fermix_core/tools/file_read.ex:89` — `Sandbox.read_path/3` is the gate; SendAttachment calls it with action `:send_attachment`.
- Telegram Bot API §"Sending files" — `sendPhoto` 10 MB photo cap; `sendVoice` must be `audio/ogg` and ≤1 MB to render as a voice note (1-20 MB files sent via sendVoice render as documents); other multipart endpoints cap at 50 MB.
- Discord File Attachments FAQ — default per-message attachment cap 10 MiB; Server Boost Tier 2 raises to 50 MiB, Tier 3 to 100 MiB; Nitro user limit 500 MiB. Whichever is higher applies, but the platform default for bots/free users is 10 MiB.
- Slack `files.getUploadURLExternal` — call returns `{ok, file_id, upload_url}`; the binary body is uploaded via **POST** (not PUT) to `upload_url`; finalized via `files.completeUploadExternal` with `files: [{id, title}]`, `channel_id`, optional `thread_ts`, optional `initial_comment`. Slack's general per-file limit is 1 GiB; M11 ships a conservative 100 MiB cap.
- WhatsApp Cloud Media — supported message types: `image`, `video`, `audio`, `document`, `sticker`. There is no `voice` type. Voice messages render correctly when sent as `audio` with MIME `audio/ogg; codecs=opus`. Caps: image 5 MB, audio 16 MB, video 16 MB, document 100 MB, sticker 100 KB.
- `signal-cli` — `signal-cli -a <account> send -m <text> --attachment /abs/path <recipient>`. `SIGNAL_MAX_ATTACHMENT_SIZE = 100 MiB`.

---

## 3. Current State Audit

Verified by reading the dev branch at the time this draft was written.

### 3.1 The channel behaviour is text-only

`channel.ex:30-35`:

```
@callback send_message(String.t(), String.t(), send_opts()) :: :ok | {:error, term()}
```

`send_opts` is `[reply_to | parse_mode | message_thread_id]` (`channel.ex:13-16`). No media key. `reply_fn` is `(String.t() -> :ok | {:error, term()})` (`channel.ex:18`). Both string-pinned.

### 3.2 Every channel honors text-only

- `telegram.ex:48,103` — only `POST /sendMessage`. No `sendPhoto`/`sendVoice`/`sendDocument`/`sendAudio`/`sendVideo`.
- `discord.ex:51` — `def send_message(channel_id, text, opts \\ [])`, JSON `{content: text}`. No multipart.
- `slack.ex:50` — `chat.postMessage` only.
- `whatsapp.ex:66` — `messages` endpoint, `type: "text"`. Inbound media parsed and downloadable; outbound has no equivalent.
- `signal.ex:55,263` — `signal-cli send -m <text>`. No `--attachment`.
- `cli.ex:95-105` — `IO.puts(text)`. No notion of media.

Every channel's `build_reply/1` returns `(text -> :ok | err)`.

### 3.3 Production `reply_fn` call sites

`grep -rnE 'reply_fn\.\(' apps/ | grep -v '_test'` — 13 production call sites:

| File | Line | Site |
|------|------|------|
| `dispatcher.ex` | 48 | inside `build_reply_fn` override branch |
| `dispatcher.ex` | 66 | inside `build_reply_fn` channel branch |
| `commands.ex` | 54 | "This command requires owner permissions." |
| `commands/help.ex` | 32 | available commands list |
| `commands/whoami.ex` | 21 | cli user id |
| `commands/whoami.ex` | 27 | remote channel user id |
| `commands/compact.ex` | 59 | compaction summary |
| `commands/compact.ex` | 64 | "Conversation changed while compacting" |
| `commands/compact.ex` | 70 | "Nothing to compact" |
| `commands/compact.ex` | 75 | "Compaction failed" |
| `commands/sandbox.ex` | 185 | sandbox command output |
| `commands/new.ex` | 28 | "Started a fresh session" |
| `main_agent.ex` | 896 | end-of-agent-loop final response |

Plus one in-process closure at `cli.ex:79` (`dispatch_input_sync/2`'s reply override).

### 3.4 The `Command` callback is string-only

`command.ex:13-17`:

```
@callback execute(
            Message.t(),
            reply_fn :: (String.t() -> :ok | {:error, term()}),
            context :: map()
          ) :: :ok | {:error, term()}
```

Six command handlers (`authorization`, `compact`, `help`, `new`, `sandbox`, `whoami`) match this signature.

### 3.5 The agent treats the reply hook as a string port

`main_agent.ex:55` types it as `(String.t() -> any())`. The guard at `main_agent.ex:127` is `is_function(reply_fn, 1)`. The delivery call at `main_agent.ex:896` is `msg.reply_fn.(response)`.

### 3.6 Tool context exposes `source_channel` but not the reply port

`main_agent.ex:559-576` constructs the tool context. Today's fields include `agent_name`, `conversation_key`, `session_id`, `capability_registry`, `provider`, `skill_registry`, `agent_supervisor`, `task_supervisor`, `journal_base_dir`, `memory_store`, `memory_repo`, `memory_agent_id`, `memory_owner_id`, `prompt_accounting`, `source_channel`, `source_trust`. `msg.reply_fn`, `msg.channel`, `msg.chat_id`, `msg.reply_target` are **not** in the context map — they are top-level fields on the agent message, accessible only inside `deliver_reply/2`.

### 3.7 Tool result shape is `%{success, output, error}`

`tool.ex:16-20`:

```
@type tool_result :: %{
        success: boolean(),
        output: String.t(),
        error: String.t() | nil
      }
```

`agent_loop.ex:265-281` pattern-matches `{:ok, %{success: true, output: output}}` and forwards `output` (a binary) to the LLM. `{:ok, %{success: false, error: error}}` becomes `"Error: #{error}"`. Any other shape becomes `inspect(other)`. Returning a map keyed by `:kind` and `:bytes` (rev 1's mistake) would surface to the LLM as a literal Elixir-inspect string.

### 3.8 No built-in tool produces media

`apps/fermix_core/lib/fermix_core/tools/`: `file_write`, `file_read`, `web_fetch`, `browser`, `memory_*`, etc. — all text. No tool currently emits a media intent.

### 3.9 Inbound attachments are first-class, outbound has no symmetric structure

`Message.attachments :: [map()]` (`message.ex:24,41`); Slack/Signal/WhatsApp populate it; WhatsApp implements `download_attachment/2`. No outbound equivalent.

### 3.10 Sandbox floor is already in place for path inputs

`Sandbox.read_path/3` (`file_read.ex:89`) is the gate. M11 adds a new action atom `:send_attachment`; no new sandbox surface required.

### 3.11 Idempotency exists for inbound only

`apps/fermix_channels/lib/fermix_channels/idempotency.ex` handles inbound dedup. M11 adds a sibling bucket for outbound media.

### 3.12 Dependency direction is fermix_channels → fermix_core

`apps/fermix_channels/mix.exs:28` declares `{:fermix_core, in_umbrella: true}`. `apps/fermix_core/mix.exs:26` does **not** declare `fermix_channels`. Any module under `fermix_core` that references a `FermixChannels.*` symbol creates an umbrella cycle. Rev 1 had three such references; rev 2 eliminates them.

### 3.13 Tool `category` metadata exists but is not read for filtering

`FermixCore.Capabilities.Builtin.Tool` declares `@callback category() :: atom()` (`tool.ex:35`) and lists it in `@optional_callbacks` (`tool.ex:38-42`). Every built-in tool today declares a category — `file_write` is `:file`, `file_read` is `:file`, `web_fetch` is `:web`, `memory_recall` is `:memory`, etc. The capability registry stores the category in `metadata`.

No runtime currently reads `category` to filter tool visibility. The only filtering primitive is a per-name allowlist at `agent_loop.ex:248-263` (`capability_allowed?(name, allowed)` checks `name in allowed`). That primitive is fine at three tools but accrues debt linearly: a per-name allowlist on agent A requires a bookkeeping decision every time a new tool ships in core, and the same for agents B, C, D. The cost is `O(tools × agents)`.

M11 is the first milestone where this matters in practice: `send_attachment` is meaningful only in channel-bound conversations, so the voice agent (M9.x Realtime) should not see it in its prompt context. Solving the problem with `hidden_from_agent?: true` or a per-name allowlist re-introduces the `O(tools × agents)` shape. Solving it with category-based visibility costs `O(1)` per new tool (set its category, already happening) and `O(1)` per new agent (declare excluded categories once at runtime init).

---

## 4. Scope and Non-Goals

### In Scope

| Feature | Priority | Type | Description |
|---------|----------|------|-------------|
| `FermixCore.Channels.Outbound` types module | P0 | New | New module in `fermix_core` carrying `media_kind`, `media_part`, `outbound`, `send_media_opts`, `reply_fn` types. Pure types — no runtime, no callbacks. This is the shared vocabulary both `FermixChannels.Channel` (channels-side) and `FermixCore.Tools.SendAttachment` (core-side) reference, preserving the existing dep direction. |
| `FermixChannels.Channel.send_media/3` callback | P0 | New | Required behaviour callback: `@callback send_media(String.t(), FermixCore.Channels.Outbound.media_part(), FermixCore.Channels.Outbound.send_media_opts()) :: :ok \| {:error, term()}`. Channels that cannot transport media implement `{:error, :media_unsupported}`. Not optional. |
| `FermixChannels.Channel.build_text_reply/1` rename | P0 | Renamed | Existing `build_reply/1` (which returns the string-only `reply_fn`) is renamed to `build_text_reply/1`. Same shape, same contract. Renaming makes room for `build_media_reply/1` and prevents the F4 inconsistency rev 1 had. |
| `FermixChannels.Channel.build_media_reply/1` callback | P0 | New | `@callback build_media_reply(Message.t()) :: (media_part() -> :ok \| {:error, term()})`. Each channel constructs the media-side closure analogously to `build_text_reply/1`. |
| Widened `reply_fn` type in core | P0 | Breaking | `FermixCore.Channels.Outbound.outbound :: {:text, String.t()} \| {:media, media_part()}` and `reply_fn :: (outbound() -> :ok \| {:error, term()})`. Bare-string replies are removed in the same change set — every existing production call site (the 13 listed in §3.3 plus `cli.ex:79`) is updated. |
| `Dispatcher.build_reply_fn/2,3` rewrite | P0 | Modified | Becomes the one place that composes the text-reply closure and the media-reply closure into a single multiplexed `outbound -> :ok\|err` function. Two production text-reply branches (`dispatcher.ex:48,66`) are rewritten to wrap inputs as `{:text, _}`. |
| `FermixChannels.Command` callback widening | P0 | Breaking | `command.ex:13-17`'s `reply_fn` type changes from `(String.t() -> :ok \| {:error, term()})` to `FermixCore.Channels.Outbound.reply_fn()`. Every command handler (6 modules, 9 call sites — §3.3) is updated to wrap text in `{:text, _}`. |
| Main agent reply typing | P0 | Modified | `main_agent.ex:55` typespec widens to `FermixCore.Channels.Outbound.reply_fn()`. `main_agent.ex:896` becomes `msg.reply_fn.({:text, response})`. Guard at `:127` stays `is_function(reply_fn, 1)`. |
| Tool context plumbing | P0 | New | `main_agent.ex:559-576` gains exactly two fields: `reply_fn: msg.reply_fn` and `channel: msg.channel`. Nothing else. SendAttachment does not need `chat_id` / `reply_target` — those are baked into the dispatcher-built reply closure. Documented at §5.6 so the context surface stays minimal. |
| Telegram media impl | P0 | New | `send_media/3` private dispatcher to five endpoints (`sendPhoto` / `sendVoice` / `sendAudio` / `sendVideo` / `sendDocument`), multipart via `Req.new(form_multipart: ...)`. Per-kind cap enforced *inside* the adapter (§5.7). |
| Discord media impl | P0 | New | Single endpoint multipart `POST /channels/{id}/messages` with `payload_json` + `files[0]`. Default 10 MiB cap; operator-configurable via `[fermix_channels.discord] media_byte_cap_mib`. |
| Slack media impl | P0 | New | Three-call sequence: `files.getUploadURLExternal` → **POST** body to returned `upload_url` → `files.completeUploadExternal` with `files: [{id, title}]` + `channel_id` + optional `thread_ts` + optional `initial_comment`. Conservative 100 MiB cap; Slack platform allows up to 1 GiB. |
| WhatsApp media impl | P0 | New | Two-call: `POST /{version}/{phone-id}/media` → `id` → `POST /{version}/{phone-id}/messages` with `type: <whatsapp_type>` + `{<whatsapp_type>: {id, caption?}}`. `:voice` is mapped to type `audio` with `mime_type: "audio/ogg; codecs=opus"`. Caps per kind (§5.7). |
| Signal media impl | P0 | New | `signal-cli -a <account> send -m <caption> --attachment <abs-path> <recipient>`. 100 MiB cap. |
| CLI media impl | P0 | New | `def send_media(_, _, _), do: {:error, :media_unsupported}` + `def build_media_reply(_msg), do: fn _ -> {:error, :media_unsupported} end`. CLI's stdout pipe has no media transport; the explicit `:media_unsupported` error surfaces to the LLM rather than silently degrading. |
| `FermixCore.Tools.SendAttachment` | P0 | New | New built-in tool in `fermix_core`. References `FermixCore.Channels.Outbound` for types only; **no** import of `FermixChannels`. Returns canonical `Tool.tool_result()` via `Tool.success/1` / `Tool.error/1`. Parameters: `path`, `kind`, `caption?`. `execute/2` calls `Sandbox.read_path/3` then `context.reply_fn.({:media, part})`. |
| Per-channel byte caps (owned by adapters) | P0 | New | Each channel adapter declares its own `media_byte_cap/1` (private or module-attr) and enforces it inside `send_media/3`. Core never knows the matrix — it just sees `{:error, :byte_cap_exceeded}` and forwards. Eliminates the rev-1 cross-app cap registry. |
| MIME mapping (owned by adapters) | P0 | New | WhatsApp's `:voice → audio` translation and the `audio/ogg; codecs=opus` MIME injection live inside the WhatsApp adapter, not in core. Other channels with simpler 1:1 mappings declare them analogously. |
| Outbound idempotency | P0 | New | `FermixChannels.Idempotency` gains `claim_outbound_media/4` and `release_outbound_media_claim/2`. Channel adapters atomically claim before the wire call; duplicate returns `:ok` without re-uploading. The key includes channel, chat id, media metadata, and SHA-256 of file contents; 60 s TTL. Failed sends release the claim so a later retry can send. |
| Telemetry | P0 | New | `[:fermix, :channel, :message]` already exists. Metadata extended with `:kind :: :text \| :media` and `:media_kind :: media_kind \| nil`. New event `[:fermix, :channel, :media_send_error]` with `%{channel, chat_id, kind, reason, bytes}`. |
| `CapabilityRegistry.list_for/1` category filter | P0 | New | Single filtering primitive in core: `list_for(opts)` accepts `excluded_categories: [atom()] \| nil`, `excluded_names: [String.t()] \| nil`, `policy_classes: [atom()] \| nil`. Default `nil` for every key preserves today's behavior. Capabilities whose `metadata.category` is unset are never filtered by category (preserves behavior for any tool that hasn't been annotated yet). One mechanism; threads to every agent runtime (AgentLoop today, voice/Realtime tomorrow). |
| Agent-level `excluded_categories` declaration | P0 | New | Each agent runtime declares its exclusions once at init. Main agent: `excluded_categories: nil` (accepts all — no behavioral change vs. today). Voice agent (M9.x Realtime session bootstrap): `excluded_categories: [:channel]`. `send_attachment` declares `category :: :channel` so the exclusion catches it automatically; no per-name list to maintain. |
| Tests | P0 | New | See §7. Behaviour-conformance test covers all six channels (including CLI's `:media_unsupported` return). Per-channel HTTP-fixture tests. SendAttachment tool tests against a recording reply_fn. Dependency-cycle test (`mix xref graph --label compile` from `fermix_core` does not include `FermixChannels.*`). Command-handler regression tests. |
| Documentation | P0 | Docs | This file. A `apps/fermix_channels/README.md` snippet showing the cap matrix and the WhatsApp voice-to-audio mapping. No CLAUDE.md change. |

### Non-Goals

| Feature | Reason | When |
|---------|--------|------|
| Media-generation tools (image, TTS, chart) | M11 ships the egress pipe. Producers are independent. | Separate per-domain follow-ons. |
| Inbound→outbound forwarding helper | Shape supports it; no built-in does it automatically. | If a real workflow needs it. |
| Streaming / chunked uploads | One multipart per send in v1. | Per-channel follow-on. |
| Bare-string `reply_fn` sugar / back-compat | Rule 12: no fallbacks. Migration is mechanical (~14 sites). | Never. |
| Web LiveView attachment surface | M10 owns LiveView; its egress is HTTP, not channel-shaped. | M10 or successor. |
| Caption Markdown rendering for `:media` | Telegram supports `caption.parse_mode`; others treat caption as plain text. v1 sends plain text everywhere for consistency. | Per-channel follow-on. |
| Multi-attachment per reply (Telegram `sendMediaGroup`, Discord `files[0..9]`) | `media_part` is singular in v1. Plural would be a new `{:media_group, [media_part()]}` shape plus per-channel fan-out. | Follow-on. |
| Server-boost-aware Discord cap | Discord caps vary by guild boost tier. v1 ships a 10 MiB default with operator-configurable override. Dynamic boost-tier discovery is a separate concern. | Operator config in v1; runtime discovery later. |
| Re-routing Realtime audio through `send_attachment` | M9.x has its own latency-tuned egress. | Never. |
| Server-side conversion (auto-transcode MP3→OGG for WhatsApp voice rendering) | WhatsApp requires `audio/ogg; codecs=opus` for voice-message rendering. The adapter validates the MIME and rejects mismatched files; transcoding is producer-side work. | Out of scope; producer's responsibility. |
| In-memory blob (`media_part.bytes`) instead of on-disk path | Path-based shape matches every channel's wire shape and stays audit-able. | Future optional `:bytes` key if a producer warrants it. |

---

## 5. Design

### 5.1 Shared types live in fermix_core

New module:

```elixir
defmodule FermixCore.Channels.Outbound do
  @moduledoc """
  Shared type vocabulary for channel egress.

  Types only — no runtime, no callbacks. Lives in fermix_core so the
  existing dep direction (fermix_channels → fermix_core) is preserved:
  channels references these types; core's SendAttachment references
  these types; neither side reaches across the apps boundary at runtime.
  """

  @type media_kind :: :image | :voice | :audio | :video | :document

  @type media_part :: %{
          required(:kind) => media_kind(),
          required(:path) => String.t(),
          optional(:caption) => String.t(),
          optional(:filename) => String.t(),
          optional(:mime_type) => String.t()
        }

  @type outbound :: {:text, String.t()} | {:media, media_part()}

  @type send_media_opts :: [
          reply_to: String.t(),
          message_thread_id: integer()
        ]

  @type reply_fn :: (outbound() -> :ok | {:error, term()})
end
```

`FermixChannels.Channel` references these types in its `@callback` declarations. `FermixCore.Tools.SendAttachment` references them when constructing the `media_part` map and the `{:media, _}` tuple. No `FermixChannels.*` symbol appears anywhere under `apps/fermix_core/`.

A `mix xref graph --label compile --source apps/fermix_core/lib` check is added to the §7 test plan to prove this at CI time.

### 5.2 Channel behaviour changes

`FermixChannels.Channel`:

```elixir
defmodule FermixChannels.Channel do
  alias FermixCore.Channels.Outbound

  @type message :: FermixChannels.Message.t()
  @type send_opts :: [reply_to: String.t(), parse_mode: String.t(), message_thread_id: integer()]

  @callback parse_webhook(map()) :: {:ok, [message()]} | {:error, term()}
  @callback send_message(String.t(), String.t(), send_opts()) :: :ok | {:error, term()}
  @callback send_media(String.t(), Outbound.media_part(), Outbound.send_media_opts()) ::
              :ok | {:error, term()}
  @callback build_text_reply(message()) :: (String.t() -> :ok | {:error, term()})
  @callback build_media_reply(message()) ::
              (Outbound.media_part() -> :ok | {:error, term()})
  @callback verify_webhook(Plug.Conn.t()) :: :ok | {:error, term()}
  @callback download_attachment(message(), map()) :: {:ok, String.t()} | {:error, term()}
  @callback start_typing(String.t()) :: :ok

  @optional_callbacks [start_typing: 1, download_attachment: 2]
end
```

Notes:

- `build_reply/1` is renamed to `build_text_reply/1`. Every channel's current `build_reply/1` is renamed in place (six occurrences). No call sites outside `dispatcher.ex` reference it directly.
- `send_media/3` and `build_media_reply/1` are **not** in `@optional_callbacks`. Every channel (including CLI) must implement both. The reviewer's F6 point applies: implicit unsupported-media handling is a fallback.
- The legacy `reply_fn` type alias on `Channel` is removed; the type now lives in core and channels imports it.

### 5.3 CLI explicitly returns `:media_unsupported`

CLI's stdout pipe has no media transport. Pretending otherwise (e.g. printing the path with a tag like `[attachment: image] /tmp/chart.png`) would be a textbook fallback: a second visible side effect that *looks* like media delivery but isn't, and that would mask "the operator is using a channel that can't deliver media" as a normal-looking success.

```elixir
# apps/fermix_channels/lib/fermix_channels/cli.ex
@impl true
def send_media(_chat_id, _media_part, _opts), do: {:error, :media_unsupported}

@impl true
def build_media_reply(_message) do
  fn _part -> {:error, :media_unsupported} end
end
```

The LLM sees the error tag through SendAttachment's normal failure path and can adjust its reply (e.g. "I generated /tmp/chart.png — open it in your file manager"). That adjustment is the LLM's prompt-layer decision, not a system-layer fallback.

### 5.4 Dispatcher composes one multiplexed reply

`dispatcher.ex:46-75` is rewritten:

```elixir
defp build_reply_fn(channel, %Message{} = message) do
  text_send = channel.build_text_reply(message)   # (String.t() -> :ok | err)
  media_send = channel.build_media_reply(message) # (media_part() -> :ok | err)

  fn
    {:text, text} when is_binary(text) ->
      observe(text_send.(text), :text, channel, message, nil)

    {:media, %{kind: kind} = part} ->
      observe(media_send.(part), :media, channel, message, kind)
  end
end

defp build_reply_fn(_channel, %Message{} = _message, reply_fn) when is_function(reply_fn, 1),
  do: wrap_with_logging(reply_fn)
```

`observe/5` is a new private helper: logs `{:error, _}` results and emits the new `[:fermix, :channel, :media_send_error]` telemetry on the `:media` failure branch. The text branch keeps the existing logger.error line.

The `reply_fn`-override arity-3 path (used by `cli.ex:79` for `dispatch_input_sync/2`) is unchanged in spec — it accepts an already-built tuple-aware fn from the caller, who must wrap text in `{:text, _}` themselves. `cli.ex:79`'s closure is updated as part of the rev-2 migration.

### 5.5 Per-channel implementations

Each channel adapter owns its own `send_media/3` and its own `build_media_reply/1`. Caps, MIME mapping, and idempotency live inside the adapter — not in core.

**Telegram** (`apps/fermix_channels/lib/fermix_channels/telegram.ex`):

```elixir
alias FermixCore.Channels.Outbound

@media_endpoint %{
  image: "sendPhoto",
  voice: "sendVoice",
  audio: "sendAudio",
  video: "sendVideo",
  document: "sendDocument"
}

@media_field %{
  image: "photo",
  voice: "voice",
  audio: "audio",
  video: "video",
  document: "document"
}

# Per-kind caps. Voice cap is the voice-message-rendering threshold;
# files larger than 1 MB sent via sendVoice would still upload but
# would render as documents in the recipient's chat, defeating the
# `:voice` intent. We reject early.
@media_byte_cap %{
  image: 10 * 1024 * 1024,
  voice: 1 * 1024 * 1024,
  audio: 50 * 1024 * 1024,
  video: 50 * 1024 * 1024,
  document: 50 * 1024 * 1024
}

@impl true
def send_media(chat_id, %{kind: kind, path: path} = part, opts \\ []) do
  with {:ok, token} <- get_bot_token(),
       :ok <- ensure_kind_supported(kind),
       :ok <- ensure_size_within_cap(path, kind),
       :ok <- maybe_check_idempotency("telegram", chat_id, part),
       endpoint <- @media_endpoint[kind],
       field <- @media_field[kind] do
    url = "#{@bot_api_base}/bot#{token}/#{endpoint}"
    form =
      [
        {"chat_id", chat_id},
        {field, {:file, path}}
      ]
      |> maybe_add_caption(part)
      |> maybe_add_thread_id(opts)

    Req.new(url: url, method: :post, form_multipart: form)
    |> Req.merge(req_options(opts))
    |> HttpClient.request("Telegram #{endpoint}")
    |> handle_telegram_response(endpoint)
  end
end

@impl true
def build_media_reply(%Message{reply_target: reply_target, thread_ts: thread_ts}) do
  opts = if thread_ts, do: [message_thread_id: thread_ts], else: []
  fn part -> send_media(reply_target, part, opts) end
end

defp ensure_size_within_cap(path, kind) do
  cap = Map.fetch!(@media_byte_cap, kind)

  case File.stat(path) do
    {:ok, %File.Stat{size: size}} when size <= cap -> :ok
    {:ok, %File.Stat{size: size}} -> {:error, {:byte_cap_exceeded, size, cap}}
    {:error, reason} -> {:error, {:file_stat_failed, reason}}
  end
end
```

(`ensure_kind_supported/1` and `maybe_check_idempotency/3` shown elsewhere; voice format validation is per the existing Bot API contract — `audio/ogg` is the bot's responsibility to produce, not the adapter's. The adapter does not transcode.)

**Discord** (`apps/fermix_channels/lib/fermix_channels/discord.ex`): single endpoint, multipart with `payload_json`. Default cap 10 MiB; operators with Tier-2/Tier-3 boosted guilds set `[fermix_channels.discord] media_byte_cap_mib = 50` (or 100) in their config.

```elixir
@impl true
def send_media(channel_id, %{kind: kind, path: path} = part, opts \\ []) do
  with {:ok, token} <- get_bot_token(),
       :ok <- ensure_size_within_cap(path),
       :ok <- maybe_check_idempotency("discord", channel_id, part) do
    url = "#{@api_base}/channels/#{channel_id}/messages"
    filename = Map.get(part, :filename) || Path.basename(path)
    payload = build_message_payload(part, opts) |> Jason.encode!()

    form = [
      {"payload_json", payload, [{"content-type", "application/json"}]},
      {"files[0]", {:file, path}, [{"filename", filename}]}
    ]

    Req.new(url: url, method: :post, form_multipart: form, auth: {:bearer, token})
    |> Req.merge(req_options(opts))
    |> HttpClient.request("Discord createMessage(media)")
    |> handle_discord_response()
  end
end
```

**Slack** (`apps/fermix_channels/lib/fermix_channels/slack.ex`): three-call sequence, **POST** to the upload URL (not PUT — F7). Cap 100 MiB conservative default.

```elixir
@impl true
def send_media(channel_id, %{path: path} = part, opts \\ []) do
  with {:ok, %File.Stat{size: size}} <- File.stat(path),
       :ok <- ensure_size_within_cap(size),
       :ok <- maybe_check_idempotency("slack", channel_id, part),
       {:ok, %{"upload_url" => upload_url, "file_id" => file_id}} <-
         get_upload_url_external(part, size),
       :ok <- post_upload(upload_url, path),
       :ok <- complete_upload_external(channel_id, file_id, part, opts) do
    :ok
  end
end

defp get_upload_url_external(%{filename: filename}, size) do
  # POST https://slack.com/api/files.getUploadURLExternal
  # body: filename=...&length=<bytes>
  # returns: %{"ok" => true, "upload_url" => ..., "file_id" => ...}
end

defp post_upload(upload_url, path) do
  # POST <upload_url>
  # body: binary file contents (or multipart with the file part)
  # No Slack auth header here — the URL is presigned.
end

defp complete_upload_external(channel_id, file_id, part, opts) do
  # POST https://slack.com/api/files.completeUploadExternal
  # body: files=[{id: <file_id>, title: <filename>}], channel_id, thread_ts?, initial_comment?
  caption = Map.get(part, :caption)
  body =
    %{
      "files" => [%{"id" => file_id, "title" => Map.get(part, :filename) || Path.basename(part.path)}],
      "channel_id" => channel_id
    }
    |> maybe_put("thread_ts", Keyword.get(opts, :thread_ts))
    |> maybe_put("initial_comment", caption)
  # ...
end
```

**WhatsApp** (`apps/fermix_channels/lib/fermix_channels/whatsapp.ex`): two-call upload→messages. **`:voice` is mapped to type `audio` with `audio/ogg; codecs=opus`** inside the adapter.

```elixir
# WhatsApp has no `voice` message type. Voice messages render correctly
# only when sent as `audio` with mime_type "audio/ogg; codecs=opus".
@whatsapp_type %{
  image: "image",
  voice: "audio",
  audio: "audio",
  video: "video",
  document: "document"
}

@media_byte_cap %{
  image: 5 * 1024 * 1024,
  voice: 16 * 1024 * 1024,
  audio: 16 * 1024 * 1024,
  video: 16 * 1024 * 1024,
  document: 100 * 1024 * 1024
}

@impl true
def send_media(to, %{kind: kind, path: path} = part, opts \\ []) do
  with :ok <- ensure_size_within_cap(path, kind),
       :ok <- maybe_check_idempotency("whatsapp", to, part),
       {:ok, access_token, phone_id, version} <- whatsapp_creds(),
       :ok <- validate_voice_mime(part),
       wa_type <- @whatsapp_type[kind],
       {:ok, media_id} <- upload_media(path, wa_type, phone_id, version, access_token, part),
       :ok <- send_media_message(to, media_id, wa_type, part, phone_id, version, access_token, opts) do
    :ok
  end
end

defp validate_voice_mime(%{kind: :voice, mime_type: "audio/ogg; codecs=opus"}), do: :ok
defp validate_voice_mime(%{kind: :voice, mime_type: other}),
  do: {:error, {:invalid_voice_mime, other}}
defp validate_voice_mime(%{kind: :voice}),
  do: {:error, {:invalid_voice_mime, "(mime_type required for :voice; expected audio/ogg; codecs=opus)"}}
defp validate_voice_mime(_part), do: :ok
```

For voice, the LLM (or upstream producer tool) must supply a `mime_type` field on the `media_part`. If absent or wrong, the WhatsApp adapter rejects loudly. The other channels ignore `mime_type` (Telegram inspects file content via libmagic anyway; Discord, Slack, Signal do not care for media-render purposes).

**Signal** (`apps/fermix_channels/lib/fermix_channels/signal.ex`):

```elixir
@media_byte_cap 100 * 1024 * 1024

@impl true
def send_media(recipient, %{path: path} = part, opts \\ []) do
  with :ok <- ensure_size_within_cap(path),
       :ok <- maybe_check_idempotency("signal", recipient, part) do
    caption = Map.get(part, :caption, "")
    account = signal_account(opts)
    args = ["-a", account, "send", "-m", caption, "--attachment", path, recipient]

    case System.cmd(signal_cli_binary(), args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, exit_code} ->
        Logger.error("signal-cli send --attachment exit #{exit_code}: #{output}")
        {:error, {:signal_send_failed, exit_code}}
    end
  end
end
```

**CLI** — see §5.3.

### 5.6 `SendAttachment` returns the canonical Tool result shape

`FermixCore.Tools.SendAttachment` is a built-in tool. Its return shape is `{:ok, tool_result()}` per `tool.ex:36`, and the `tool_result` map has only `success`, `output`, `error` keys (`tool.ex:16-20`). The LLM sees `output` (or `"Error: #{error}"`) — it does not see structured Elixir maps.

```elixir
defmodule FermixCore.Tools.SendAttachment do
  @behaviour FermixCore.Capabilities.Builtin.Tool

  require Logger

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Channels.Outbound
  alias FermixCore.Sandbox

  @valid_kinds ~w(image voice audio video document)a

  @impl true
  def name, do: "send_attachment"

  @impl true
  def description do
    "Send a file from the workspace to the current channel as an attachment. " <>
      "The user sees the actual image/audio/document, not the path. " <>
      "Use only for a file that already exists on disk; send URLs as text."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      required: ["path", "kind"],
      properties: %{
        path: %{type: "string", description: "Path to a file already on disk in the workspace"},
        kind: %{
          type: "string",
          enum: ["image", "voice", "audio", "video", "document"],
          description: "What kind of media this is. Determines the channel endpoint used."
        },
        caption: %{type: "string", description: "Optional caption shown alongside the media"},
        mime_type: %{
          type: "string",
          description:
            "Required for :voice on WhatsApp (must be 'audio/ogg; codecs=opus'). " <>
              "Optional otherwise."
        }
      }
    }
  end

  @impl true
  def when_to_use,
    do:
      "When the user expects to receive a file, image, voice note, or document directly in " <>
        "the channel — not a path. Always prefer this over pasting a local path into the reply."

  @impl true
  def examples do
    [
      %{
        args: %{"path" => "/tmp/chart.png", "kind" => "image", "caption" => "weekly revenue"},
        note: "send a chart you just wrote"
      },
      %{
        args: %{
          "path" => "/tmp/note.ogg",
          "kind" => "voice",
          "mime_type" => "audio/ogg; codecs=opus"
        },
        note: "send a voice note (WhatsApp requires the mime_type)"
      }
    ]
  end

  @impl true
  def failure_modes do
    [
      %{tag: "missing_parameters", description: "path or kind is absent"},
      %{tag: "invalid_kind", description: "kind is not one of image/voice/audio/video/document"},
      %{tag: "sandbox_denied", description: "resolved path is outside sandbox roots"},
      %{tag: "file_not_found", description: "path does not exist or is unreadable"},
      %{tag: "byte_cap_exceeded", description: "file is larger than the channel's outbound media cap"},
      %{tag: "media_unsupported", description: "the active channel does not support media egress"},
      %{tag: "invalid_voice_mime", description: ":voice on WhatsApp requires audio/ogg; codecs=opus"},
      %{tag: "send_failed", description: "channel upload returned an error"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :channel

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()}
  def execute(args, context) when is_map(args) and is_map(context) do
    start = System.monotonic_time(:millisecond)

    result =
      with {:ok, path_raw, kind, caption, mime} <- normalize_args(args),
           {:ok, resolved} <- Sandbox.read_path(path_raw, :send_attachment, context),
           {:ok, %File.Stat{size: size}} <- File.stat(resolved),
           {:ok, reply_fn} <- fetch_reply_fn(context),
           part <- build_part(resolved, kind, caption, mime),
           :ok <- dispatch(reply_fn, part) do
        Tool.success(success_line(kind, size, Map.get(context, :channel, "unknown")))
      else
        {:error, :missing_parameters} ->
          Tool.error("send_attachment requires both 'path' and 'kind'")

        {:error, :invalid_kind} ->
          Tool.error("kind must be one of: image, voice, audio, video, document")

        {:error, :sandbox_denied} ->
          Tool.error("path is outside the sandbox roots")

        {:error, :enoent} ->
          Tool.error("file_not_found: path does not exist or is unreadable")

        {:error, :no_reply_fn} ->
          Tool.error(
            "send_attachment is only usable in a channel-bound conversation " <>
              "(no reply_fn in tool context)"
          )

        {:error, :media_unsupported} ->
          Tool.error("the active channel does not support media egress")

        {:error, {:byte_cap_exceeded, actual, allowed}} ->
          Tool.error(
            "byte_cap_exceeded: file is #{actual} bytes; channel cap is #{allowed} bytes"
          )

        {:error, {:invalid_voice_mime, given}} ->
          Tool.error(
            "invalid_voice_mime: voice on WhatsApp requires 'audio/ogg; codecs=opus', got #{inspect(given)}"
          )

        {:error, reason} ->
          Logger.error("send_attachment failed: #{inspect(reason)}")
          Tool.error("send_failed: #{format_reason(reason)}")
      end

    emit_telemetry(result, args, context, start)
    {:ok, result}
  end

  defp fetch_reply_fn(%{reply_fn: reply_fn}) when is_function(reply_fn, 1), do: {:ok, reply_fn}
  defp fetch_reply_fn(_context), do: {:error, :no_reply_fn}

  defp dispatch(reply_fn, %{} = part) do
    case reply_fn.({:media, part}) do
      :ok -> :ok
      {:error, :media_unsupported} -> {:error, :media_unsupported}
      {:error, {:byte_cap_exceeded, _, _} = err} -> {:error, err}
      {:error, {:invalid_voice_mime, _} = err} -> {:error, err}
      {:error, reason} -> {:error, reason}
    end
  end

  defp success_line(kind, size, channel),
    do: "sent #{kind} (#{size} bytes) to #{channel}"
end
```

Key invariants (post-revision):

1. **No `FermixChannels.*` reference.** SendAttachment only knows core's `Outbound` types and the `context.reply_fn` closure. Compile-time graph: `fermix_core` does not depend on `fermix_channels`.
2. **Sandbox first.** `Sandbox.read_path(path, :send_attachment, context)` runs before stat, before reply_fn. Adding `:send_attachment` to the sandbox action vocabulary is a one-line patch (`:read_only` policy class — sending requires reading).
3. **Tool returns `Tool.tool_result()`.** Success becomes a one-line `output` string the LLM sees. Failure becomes a one-line `error` string the LLM sees as `"Error: …"`. The agent_loop dispatcher at `agent_loop.ex:265-281` consumes this directly.
4. **Channel-side cap.** The adapter rejects with `{:error, {:byte_cap_exceeded, actual, allowed}}`. SendAttachment surfaces it through the `error` channel. Cap matrix is never read in core.
5. **WhatsApp voice MIME check is channel-side.** SendAttachment accepts an optional `mime_type` arg and threads it through the `media_part`. The adapter rejects mismatches.

### 5.7 Cap matrix (researched, May 2026)

Sourced from current platform documentation; each row links the upstream constraint that determines the cap.

| Channel | Kind | Cap | Source / rationale |
|---------|------|-----|---------------------|
| Telegram | `:image` | 10 MB | [`sendPhoto`](https://core.telegram.org/bots/api#sendphoto): photo ≤ 10 MB; dims ≤ 10000 combined; aspect ≤ 20:1. |
| Telegram | `:voice` | 1 MB | [`sendVoice`](https://core.telegram.org/bots/api#sendvoice): voice messages render as voice notes only when ≤ 1 MB and `audio/ogg`. Files 1-20 MB sent via `sendVoice` render as documents — defeats the `:voice` intent. We reject early. |
| Telegram | `:audio` | 50 MB | Bot API standard multipart limit. |
| Telegram | `:video` | 50 MB | Bot API standard multipart limit. |
| Telegram | `:document` | 50 MB | Bot API standard multipart limit. Local Bot API server supports 2000 MB; not used by default. |
| Discord | any | 10 MiB | [Discord File Attachments FAQ](https://support.discord.com/hc/en-us/articles/25444343291031): default 10 MiB per attachment. Server Boost Tier 2 → 50 MiB, Tier 3 → 100 MiB; Nitro user → 500 MiB. Operator-configurable via `[fermix_channels.discord] media_byte_cap_mib`. |
| Slack | any | 100 MiB (v1) | Platform limit is ~1 GiB but Slack also imposes per-workspace storage quotas. 100 MiB is the v1 conservative default; operator can raise. |
| WhatsApp | `:image` | 5 MB | Cloud API: image (JPEG/PNG) ≤ 5 MB. |
| WhatsApp | `:voice`/`:audio` | 16 MB | Cloud API: audio ≤ 16 MB. `:voice` is mapped to type `audio` with required MIME `audio/ogg; codecs=opus`. |
| WhatsApp | `:video` | 16 MB | Cloud API: video ≤ 16 MB. |
| WhatsApp | `:document` | 100 MB | Cloud API: document ≤ 100 MB. |
| Signal | any | 100 MB | `signal-cli` ships `SIGNAL_MAX_ATTACHMENT_SIZE = 100 MiB`. Matches Signal Desktop/iOS/Android client caps. |
| CLI | any | n/a | `{:error, :media_unsupported}` regardless of size. |

These constants live as module attributes inside each channel adapter (see §5.5 snippets). Core never sees them. A future channel adds the matrix to its own adapter; no central registry edit.

### 5.8 Main agent context plumbing (the F3 fix)

The reviewer correctly noted that rev 1 assumed `context.reply_fn` and `context.channel` already existed in the tool context. They do not (`main_agent.ex:559-576`). Rev 2 adds exactly two fields:

```elixir
context = %{
  agent_name: "main",
  conversation_key: conversation_key,
  session_id: "main-#{System.unique_integer([:positive, :monotonic])}",
  capability_registry: state.capability_registry,
  provider: state.provider,
  skill_registry: state.skill_registry,
  agent_supervisor: state.agent_supervisor,
  task_supervisor: state.task_supervisor,
  journal_base_dir: state.journal_base_dir,
  memory_store: state.memory_store,
  memory_repo: state.memory_repo,
  memory_agent_id: state.memory_agent_id,
  memory_owner_id: state.memory_owner_id,
  prompt_accounting: prompt_context.accounting,
  source_channel: msg.channel,
  source_trust: source_trust,
  # ADDED FOR M11:
  reply_fn: msg.reply_fn,
  channel: msg.channel
}
```

`msg.reply_fn` is the already-multiplexed `(outbound() -> :ok | err)` function the dispatcher built. `msg.channel` is the binary like `"telegram"` already present on the agent message.

Not added (deliberately):

- `chat_id`, `reply_target`: baked into the dispatcher-built reply closure; no tool needs them as separate fields.
- `metadata`, `thread_ts`: same reason.
- `typing_fn`: a separate `maybe_put_typing_fn/2` already exists at `dispatcher.ex:198-202`; orthogonal concern.

This is the minimum surface SendAttachment needs. Other future channel-bound tools (e.g. a `mark_read` or `set_typing` tool) can add fields when they ship; M11 does not preemptively expose them.

Note: `source_channel` and `channel` carry the same value in the current dispatcher. `source_channel` predates M11 and is read by trust gating; the new `channel` field is semantically "the channel I'm replying to" and is the field SendAttachment reads. They alias today but may diverge if cross-channel routing is added later — a forward-compatible naming.

### 5.9 Command behaviour widening (the F5 fix)

`apps/fermix_channels/lib/fermix_channels/command.ex` is updated:

```elixir
defmodule FermixChannels.Command do
  alias FermixCore.Channels.Outbound
  alias FermixChannels.Message

  @callback name() :: String.t()
  @callback aliases() :: [String.t()]
  @callback description() :: String.t()
  @callback authorize(Message.t(), channel_metadata :: map(), context :: map()) ::
              :ok | {:error, :unauthorized}
  @callback execute(
              Message.t(),
              reply_fn :: Outbound.reply_fn(),
              context :: map()
            ) :: :ok | {:error, term()}
end
```

Every existing command handler is updated to wrap its text replies in `{:text, _}`. Concrete diff per file:

| File | Existing call | Replacement |
|------|---------------|-------------|
| `commands.ex:54` | `reply_fn.("This command requires owner permissions.")` | `reply_fn.({:text, "This command requires owner permissions."})` |
| `commands/help.ex:32` | `reply_fn.("Available commands:\n#{body}")` | `reply_fn.({:text, "Available commands:\n#{body}"})` |
| `commands/whoami.ex:21` | `reply_fn.("Your user id on this channel: cli")` | `reply_fn.({:text, "Your user id on this channel: cli"})` |
| `commands/whoami.ex:27` | `reply_fn.("Your user id on this channel: #{user_id || "unknown"}")` | `reply_fn.({:text, "Your user id on this channel: #{user_id || "unknown"}"})` |
| `commands/compact.ex:59` | `reply_fn.(summary)` | `reply_fn.({:text, summary})` |
| `commands/compact.ex:64` | `reply_fn.("Conversation changed …")` | `reply_fn.({:text, "Conversation changed …"})` |
| `commands/compact.ex:70` | `reply_fn.("Nothing to compact …")` | `reply_fn.({:text, "Nothing to compact …"})` |
| `commands/compact.ex:75` | `reply_fn.("Compaction failed: #{inspect(reason)}.")` | `reply_fn.({:text, "Compaction failed: #{inspect(reason)}."})` |
| `commands/sandbox.ex:185` | `reply_fn.(text)` | `reply_fn.({:text, text})` |
| `commands/new.ex:28` | `reply_fn.("Started a fresh session. Long-term memory is preserved.")` | `reply_fn.({:text, "Started a fresh session. Long-term memory is preserved."})` |

Plus the two dispatcher internal call sites (`dispatcher.ex:48,66`) and `main_agent.ex:896` and `cli.ex:79`.

13 production sites total. Not "~5" as rev 1 claimed.

### 5.10 Outbound idempotency

`FermixChannels.Idempotency` gains:

```elixir
@spec claim_outbound_media(atom(), String.t(), Outbound.media_part()) ::
        {:ok, {:fresh, claim}} | {:ok, :duplicate} | {:error, term()}

@spec release_outbound_media_claim(claim) :: :ok
```

Channel adapters call `claim_outbound_media/3` themselves inside `send_media/3` before the wire call. The claim is a single GenServer call, using the same serialized ETS pattern as inbound dedup, so two concurrent sends for the same key cannot both observe `:fresh`.

The key includes `channel`, `chat_id`, `kind`, `caption`, `filename`, `mime_type`, and a SHA-256 digest of the file contents. This intentionally costs one bounded file read per attempted send, but avoids suppressing a changed file that reused the same path and filename.

On `:duplicate`, the adapter returns `:ok` without re-uploading, and the `media_send_error` telemetry is **not** emitted (no error to report; dedup is the correct behavior). On `{:fresh, claim}`, the adapter performs the upload/send. If that send returns an error, the adapter calls `release_outbound_media_claim/1` so a later retry can claim the key again; on success, the claim remains until its TTL expires.

SendAttachment does not know about idempotency — it just sees `:ok` from the reply_fn, same as for a fresh send. The LLM sees the same success line either way.

This avoids the rev-1 "tool surfaces `deduplicated: true` flag" surface, which would have required a custom tool-result shape outside `Tool.tool_result()`.

### 5.11 Telemetry

Existing event `[:fermix, :channel, :message]` (e.g. `telegram.ex:58-63`) extended with `kind :: :text | :media` and `media_kind :: media_kind() | nil`:

```elixir
:telemetry.execute(
  [:fermix, :channel, :message],
  %{count: count, bytes: bytes_or_nil},
  %{channel: :telegram, direction: :outbound, kind: :media, media_kind: :image}
)
```

New event `[:fermix, :channel, :media_send_error]`:

```elixir
:telemetry.execute(
  [:fermix, :channel, :media_send_error],
  %{count: 1, bytes: size},
  %{channel: :telegram, chat_id: chat_id, kind: kind, reason: reason}
)
```

SendAttachment emits its tool-level event via the existing `[:fermix, :tool, :exec]` channel — same shape as every other tool. `Trace.record/3` is called from `SendAttachment.execute/2` with `:agent_event` action so JSONL trace files include outbound media intents.

### 5.12 Category-based tool visibility (avoiding per-tool-per-agent bookkeeping)

`send_attachment` is the first tool with a cross-cutting visibility concern: the main agent should see it; the voice agent (M9.x) should not, because voice has no channel reply port and seeing the tool would just pollute the Realtime session prompt with a description the LLM cannot meaningfully act on.

The wrong fix is `hidden_from_agent?: true` on the tool, or a per-name allowlist on the voice agent. Both re-introduce `O(tools × agents)` bookkeeping: every future tool with cross-cutting visibility (e.g. a future `image_gen` of category `:media_producer`, a future `mark_read` of category `:channel`) means re-asking the visibility question for every existing agent.

The right fix is one-time mechanism plus per-agent declaration:

**Three additions:**

1. **Tool already declares its category.** `category/0` is in the `FermixCore.Capabilities.Builtin.Tool` behaviour (`tool.ex:35`); every built-in declares one. `send_attachment` declares `:channel`. Nothing new on the tool side — §5.6 already specifies this.

2. **`CapabilityRegistry` exposes a filtered query.**

   ```elixir
   defmodule FermixCore.Capabilities.Registry do
     @type list_opts :: [
             excluded_categories: [atom()] | nil,
             excluded_names: [String.t()] | nil,
             policy_classes: [atom()] | nil
           ]

     @spec list_for(list_opts()) :: [Capability.t()]
     def list_for(opts \\ []) do
       list()
       |> Enum.reject(&excluded_by_category?(&1, Keyword.get(opts, :excluded_categories)))
       |> Enum.reject(&excluded_by_name?(&1, Keyword.get(opts, :excluded_names)))
       |> Enum.reject(&excluded_by_policy?(&1, Keyword.get(opts, :policy_classes)))
     end

     defp excluded_by_category?(_capability, nil), do: false
     defp excluded_by_category?(_capability, []), do: false

     defp excluded_by_category?(%Capability{metadata: %{category: c}}, excluded)
          when is_atom(c) and is_list(excluded),
          do: c in excluded

     defp excluded_by_category?(_capability, _excluded), do: false
   end
   ```

   The third clause (tool has a category, exclusion list is a list) is the only filtering path. The fourth clause (no category set on the tool) is a no-op: tools without a declared category are never filtered out by category exclusion. Existing tools that lack `category/0` (none today, but possible) survive unchanged.

3. **Each agent runtime declares its excluded categories once.**

   - **Main agent** (`main_agent.ex`, where it queries the registry to build `loop_opts`): switches from `Registry.list/0` to `Registry.list_for(excluded_categories: nil)`. Explicit-nil is documentation, not behavior; the result is identical to today.
   - **Voice agent** (M9.x Realtime session bootstrap, where it loads the tool catalog before opening the session): `Registry.list_for(excluded_categories: [:channel])`. `send_attachment` is invisible to the voice LLM; its description never lands in the Realtime session prompt. M9.x's session module is the one place that knows it.

**The scaling property:**

| Scenario | Per-event cost |
|----------|----------------|
| Add a new built-in tool with category `:file` | Set the tool's `category/0`. Voice and main both already accept `:file`. No agent changes. |
| Add a future `image_gen` tool with category `:media_producer` | Set the tool's `category/0`. Decide once whether voice should see it; flip its one-line `excluded_categories` list if not. Main is automatic. |
| Add a third agent (e.g. a future scheduler agent) | One-line `excluded_categories` declaration at its runtime init. |
| Rename a category | One sweep through agent runtimes. Tool modules and registry are unaffected. |

Per-name allowlists do not have this shape — every new tool means re-asking the visibility question for every existing agent, and the answers diffuse across modules.

**What this does not try to solve:**

- **Cross-cutting context preconditions** (e.g. "this tool needs `context.memory_store`"). Category is coarse visibility, not a replacement for per-tool sandbox / context checks at execute time. `SendAttachment` still validates `context.reply_fn` at execute time (§5.6); category filtering is belt-and-suspenders, not the only line of defense. The execute-time check is what catches an explicit `Capability.execute/3` call from outside any agent runtime (e.g. tests, a future cron-runner) where the category filter never had a chance to run.
- **Per-user / per-conversation visibility.** Policy-class territory (M4.9 `policy_class`) and stays separate. `list_for/1` carries a `policy_classes` filter for symmetry but M11 only exercises the `excluded_categories` path.
- **Hot-reload of exclusions.** Each agent reads its categories at runtime init; changes take effect on agent restart. Same lifecycle as today's `allowed_tools`.

**Implementation cost in M11:** ~20 lines in `CapabilityRegistry` (`list_for/1` + the three private predicates), one call-site change in `MainAgent.run_message_loop/2` (switch from `list/0` to `list_for/1`), one call-site change in the voice agent's tool-loader to set `excluded_categories: [:channel]`. The voice-agent file is identified at implementation time against the M9.x layout; the contract above is the touchpoint.

---

## 6. Failure Modes

Every failure surfaces to the LLM as a string `error` per `Tool.error/1`. The agent_loop wraps it as `"Error: #{error}"` (`agent_loop.ex:271`). No silent degradation.

| Failure | Where caught | LLM-visible message |
|---------|--------------|---------------------|
| `path` or `kind` missing | `SendAttachment.normalize_args/1` | `"send_attachment requires both 'path' and 'kind'"` |
| `kind` not in `~w(image voice audio video document)a` | `SendAttachment.normalize_args/1` | `"kind must be one of: image, voice, audio, video, document"` |
| Path outside sandbox | `Sandbox.read_path/3` | `"path is outside the sandbox roots"` |
| Path missing/unreadable | `File.stat/1` | `"file_not_found: path does not exist or is unreadable"` |
| No reply_fn in context (e.g. an out-of-channel cron run) | `SendAttachment.fetch_reply_fn/1` | `"send_attachment is only usable in a channel-bound conversation (no reply_fn in tool context)"` |
| Channel returned `:media_unsupported` (CLI today, future stdio channels) | `SendAttachment.dispatch/2` | `"the active channel does not support media egress"` |
| File larger than channel cap | adapter's `ensure_size_within_cap/2` | `"byte_cap_exceeded: file is N bytes; channel cap is M bytes"` |
| `:voice` on WhatsApp without correct MIME | WhatsApp adapter's `validate_voice_mime/1` | `"invalid_voice_mime: voice on WhatsApp requires 'audio/ogg; codecs=opus', got …"` |
| Channel HTTP / CLI error | adapter's response handler | `"send_failed: <reason>"` + logger.error line for operators |
| Duplicate within 60 s window | channel adapter via `Idempotency.claim_outbound_media/4` | Not surfaced — adapter returns `:ok`; LLM sees normal success line. |

The `"Error: …"` prefix is added by `agent_loop.ex:271`, not by SendAttachment.

---

## 7. Test Plan

| Test | Location | Asserts |
|------|----------|---------|
| Dependency direction | `test/fermix_core/dependency_direction_test.exs` (new) | `mix xref graph --source apps/fermix_core/lib --label compile` returns zero edges to `FermixChannels.*`. Encodes F1. |
| Behaviour contract (all 6 channels) | `test/fermix_channels/channel_contract_test.exs` (new) | Each module in `[Telegram, Discord, Slack, WhatsApp, Signal, CLI]` exports `send_media/3`, `build_text_reply/1`, `build_media_reply/1` with the expected arities and typespecs. CLI returns `{:error, :media_unsupported}` for any `media_part`. |
| `Tool` result shape | `test/fermix_core/tools/send_attachment_test.exs` (new) | Every `execute/2` return matches `{:ok, %{success: _, output: _, error: _}}`. `agent_loop.ex:265-281` round-trip: success produces a string the LLM sees, failure produces `"Error: …"`. Encodes F2. |
| Tool context fields | `test/fermix_core/agents/main_agent_test.exs` (extend) | After M11, the context passed to `AgentLoop.run/1` includes `reply_fn` (a 1-arity function) and `channel` (binary). Encodes F3. |
| Reply contract — `build_text_reply` rename | `test/fermix_channels/channel_contract_test.exs` | No channel exports `build_reply/1` anymore; all expose `build_text_reply/1`. Encodes F4. |
| Dispatcher routing | `test/fermix_channels/dispatcher_test.exs` (extend) | `reply_fn.({:text, "hi"})` calls `channel.send_message/3` via the text closure; `reply_fn.({:media, %{...}})` calls `channel.send_media/3` via the media closure; bare strings raise FunctionClauseError. |
| Command behaviour widening | each `test/fermix_channels/commands/*_test.exs` | Every command-handler test wraps reply assertions in `{:text, _}`. Encodes F5. |
| CLI `:media_unsupported` | `test/fermix_channels/cli_test.exs` (extend) | `CLI.send_media/3` and `CLI.build_media_reply/1` both return `{:error, :media_unsupported}`. End-to-end: SendAttachment invoked through a CLI-bound conversation produces `"Error: the active channel does not support media egress"`. Encodes F6. |
| Telegram per-kind routing | `test/fermix_channels/telegram_test.exs` | `Req.Test`-stubbed Bot API; assert multipart body contains the right field (`photo` / `voice` / etc.) and goes to the right endpoint. Five assertions. |
| Telegram voice cap | same file | A 1.5 MB file with `kind: :voice` rejected with `{:error, {:byte_cap_exceeded, …}}` before any HTTP call. Encodes F8 voice-render constraint. |
| Discord multipart | `test/fermix_channels/discord_test.exs` | Stub REST; assert `payload_json` JSON + `files[0]` part; default 10 MiB cap rejects oversize. |
| Slack three-step | `test/fermix_channels/slack_test.exs` | Stub three calls; assert step 2 is **POST** (not PUT) to the upload URL; step 3 (`files.completeUploadExternal`) carries `files`, `channel_id`, `thread_ts`, `initial_comment` per the [Slack docs](https://docs.slack.dev/reference/methods/files.completeUploadExternal). Encodes F7. |
| WhatsApp voice→audio mapping | `test/fermix_channels/whatsapp_test.exs` | A `media_part` with `kind: :voice, mime_type: "audio/ogg; codecs=opus"` produces a `/messages` body with `type: "audio"` and `audio.id`. A `kind: :voice` without the correct MIME returns `{:error, {:invalid_voice_mime, _}}`. Encodes F8 WhatsApp constraint. |
| WhatsApp upload→send | same file | Stub `/media` returning `id`; assert `/messages` body has `type: <wa_type>` and `<wa_type>.id`; oversize rejected at `ensure_size_within_cap/2`. |
| Signal CLI | `test/fermix_channels/signal_test.exs` | Inject fake `signal_cli_binary/0` recording argv; assert `--attachment <path>` appears; exit 0 → `:ok`, exit 1 → `{:error, {:signal_send_failed, 1}}`. |
| `SendAttachment` happy path | `test/fermix_core/tools/send_attachment_test.exs` | Sandboxed tmp file + recording reply_fn; assert tool returns `Tool.success(_)` and the reply_fn was called with `{:media, %{kind: :image, path: <resolved>, caption: <c>}}`. |
| `SendAttachment` failure modes | same file | Eight tests, one per row in §6. |
| Sandbox denial | same file | Path outside sandbox → `Tool.error("path is outside the sandbox roots")`; reply_fn not called. |
| Idempotency dedup | `test/fermix_channels/idempotency_test.exs` (extend) | Same `(channel, chat_id, kind, caption, filename, mime_type, file-content SHA-256)` within 60 s returns `:duplicate`; concurrent claims produce exactly one `:fresh`; released failed-send claims can be retried. |
| Telemetry success | `test/fermix_core/tools/send_attachment_test.exs` | `[:fermix, :channel, :message]` event fires with `kind: :media, media_kind: :image, bytes: <n>`. |
| Telemetry failure | same file | `[:fermix, :channel, :media_send_error]` fires on a stubbed 400; tool emits `[:fermix, :tool, :exec]` with `success: false`. |
| Category filter — happy path | `test/fermix_core/capabilities/registry_test.exs` (extend) | `Registry.list_for(excluded_categories: [:channel])` returns the full list minus capabilities whose `metadata.category == :channel`. `list_for([])` and `list_for(excluded_categories: nil)` both equal `list/0`. Tools without a declared category survive every form. |
| Category filter — composition | same file | `list_for(excluded_categories: [:channel], excluded_names: ["file_read"])` excludes both `send_attachment` (by category) and `file_read` (by name). The three predicates compose; rejecting via any one is sufficient. |
| Main agent sees `send_attachment` | `test/fermix_core/agents/main_agent_test.exs` (extend) | After M11, main agent's tool list as presented to the LLM contains `send_attachment`. The context map carries `excluded_categories: nil`. |
| Voice agent excludes `:channel` | voice-agent-side test (M9.x location, identified at impl time) | The voice runtime's loaded tool list does not contain `send_attachment` even when it is seeded in the registry. Tool description is absent from the Realtime session prompt. |
| `SafeRm` discipline | every new test that creates a tmp file | `on_exit` cleanup routes through `FermixCore.TestSupport.SafeRm.rm_rf!/1` per CLAUDE.md §"Known Pitfalls". |

Test isolation: every channel test stubs HTTP via `Req.Test`. Signal tests inject a fake binary. WhatsApp's access-token plumbing reuses the existing config-stub pattern. CLI tests exercise `IO.puts` redirection via `ExUnit.CaptureIO`.

---

## 8. Rollout / Migration

Single change-set, single PR. Order matters because the type module must compile before anything that references it:

1. **`apps/fermix_core/lib/fermix_core/channels/outbound.ex`** (new) — declare types. Pure-Elixir compile cost ~zero.
2. **`apps/fermix_core/lib/fermix_core/sandbox.ex`** — add `:send_attachment` to the action vocabulary (one clause, `:read_only` policy class).
3. **`apps/fermix_channels/lib/fermix_channels/channel.ex`** — alias `Outbound`; declare new callbacks; rename `build_reply/1` → `build_text_reply/1`; remove the local `reply_fn` type alias.
4. **Each channel adapter** (`telegram.ex`, `discord.ex`, `slack.ex`, `whatsapp.ex`, `signal.ex`, `cli.ex`):
   - Rename `build_reply/1` → `build_text_reply/1`.
   - Add `build_media_reply/1`.
   - Add `send_media/3` (or `{:error, :media_unsupported}` for CLI).
   - Add per-channel cap module-attrs and `ensure_size_within_cap/_` private.
   - Add MIME mapping (WhatsApp only in v1).
5. **`apps/fermix_channels/lib/fermix_channels/idempotency.ex`** — add atomic outbound media claim/release calls plus their ETS bucket.
6. **`apps/fermix_channels/lib/fermix_channels/dispatcher.ex`** — rewrite `build_reply_fn/2` to compose the two channel-side closures; rewrite `build_reply_fn/3` and update logging branches.
7. **`apps/fermix_channels/lib/fermix_channels/command.ex`** — widen `execute/3` callback's `reply_fn` type.
8. **`apps/fermix_channels/lib/fermix_channels/commands.ex` + `commands/*.ex`** — 10 call-site updates per the §5.9 table.
9. **`apps/fermix_channels/lib/fermix_channels/cli.ex:79`** — update `dispatch_input_sync/2`'s reply override closure to accept `{:text, _}`.
10. **`apps/fermix_core/lib/fermix_core/agents/main_agent.ex`**:
    - Widen `:reply_fn` typespec at `:55` to `Outbound.reply_fn()`.
    - Add `reply_fn: msg.reply_fn` and `channel: msg.channel` to the context map at `:559-576`.
    - Rewrite `deliver_reply/2` call at `:896` to `msg.reply_fn.({:text, response})`.
11. **`apps/fermix_core/lib/fermix_core/tools/send_attachment.ex`** (new) — implement per §5.6.
12. **`apps/fermix_core/lib/fermix_core/capabilities/builtin/seeder.ex`** — register `SendAttachment` so it appears in `CapabilityRegistry` after `mix fermix.setup`.
13. **`apps/fermix_core/lib/fermix_core/capabilities/registry.ex`** — add `list_for/1` with the three exclusion options (`excluded_categories`, `excluded_names`, `policy_classes`). Preserve `list/0` for any callers that want the unfiltered set. Per §5.12.
14. **`apps/fermix_core/lib/fermix_core/agents/main_agent.ex`** (visibility wiring) — switch the capability query in `run_message_loop/2` from `Registry.list/0` to `Registry.list_for(excluded_categories: nil)`. Explicit-nil documents intent; behavior is unchanged.
15. **Voice agent runtime** (M9.x — exact module identified at implementation time against the current M9.x layout) — at session bootstrap, set `excluded_categories: [:channel]` on the registry query. This is the single touchpoint that makes `send_attachment` invisible to voice; no per-tool flag, no per-agent name allowlist.
16. **Telemetry handlers** — extend existing consumers that read `kind` metadata to know about `:media` (probably zero handlers, since today only `:text` is emitted).

No data migration. No config migration (Discord boost-tier override is opt-in). Existing `~/.fermix/config.toml` is unchanged for operators on the default cap.

Migration check: `mix xref graph --source apps/fermix_core/lib --label compile | grep FermixChannels` should return zero matches.

---

## 9. Open Questions

1. **Should `send_attachment` accept a remote URL?** No for v1. Links should stay in normal text replies; Telegram and other platforms can resolve previews/download affordances according to their own rules. `send_attachment` is only for local files the agent intentionally attaches instead of pasting a path. Revisit only if a real workflow needs server-side fetch-and-reupload semantics.
2. **Should the LLM be able to send multiple attachments per reply?** Telegram has `sendMediaGroup` (≤10); Discord allows `files[0..9]`; WhatsApp and Slack don't (one media per message). Today's `media_part` is singular. Plural would be `{:media_group, [media_part()]}` plus per-channel fan-out. Defer; v1 is one-at-a-time.
3. **Should `caption` support markdown?** Telegram does (via `caption.parse_mode`); others don't. v1 is plain text everywhere for consistency. If we add later, it's a per-channel `caption_parse_mode` opt.
4. **Should the WhatsApp adapter auto-transcode MP3→OGG/Opus for voice?** Doing so requires `ffmpeg` as a runtime dep. Producer-side concern. Reject in v1.
5. **Should we expose channel-specific underlying error tags to the LLM?** Trade-off in §6. v1 collapses everything to `"send_failed: …"` with operator-visible logs. Revisit if a real workflow needs the LLM to react to e.g. Slack `not_in_channel` specifically.
6. **Naming.** `send_attachment` vs. `send_media` for the tool. `send_attachment` matches inbound's `attachments` field; `send_media` matches the channel callback. Keeping `send_attachment` for the tool preserves inbound/outbound symmetry from the LLM's vantage point; `send_media` is reserved for the wire callback. Recommend: keep.

---

## 10. Verification Checklist

Before calling M11 done:

- [ ] `mix deps.get && mix compile` clean with zero warnings (rule 11).
- [ ] `mix xref graph --source apps/fermix_core/lib --label compile | grep -i FermixChannels` returns zero lines (F1).
- [ ] `mix test` green; new tests included.
- [ ] `mix credo --strict` clean.
- [ ] `mix format --check-formatted` clean.
- [ ] All six channel adapters' `send_media/3` and `build_media_reply/1` exercised by tests against `Req.Test` / injected-binary stubs.
- [ ] `SendAttachment` exercised end-to-end with a Telegram adapter against a `Req.Test` stub returning the canonical Bot API success body.
- [ ] `SendAttachment` failure-mode tests cover all 8 rows of §6.
- [ ] WhatsApp `:voice → audio` mapping test passes (correct MIME → success, wrong MIME → `invalid_voice_mime` error).
- [ ] Slack three-step test asserts **POST** at step 2 and the documented `files.completeUploadExternal` parameter names at step 3.
- [ ] Manual smoke against a real Telegram bot: send an image + a 1 MB ogg/opus voice note. Recorded in the PR description.
- [ ] No `File.rm_rf` direct calls in any new test file (`grep -rn 'File\.rm_rf' apps/*/test/`); `SafeRm.rm_rf!/1` everywhere per CLAUDE.md.
- [ ] `mix fermix.setup` round-trip: `send_attachment` appears in `fermix capabilities` after seeding.
- [ ] Trace JSONL inspection: an outbound media send produces a `:agent_event` entry with `tool: "send_attachment"` and a `:channel, :message` entry with `direction: :outbound, kind: :media`.
- [ ] `Registry.list_for(excluded_categories: [:channel])` excludes `send_attachment`; main-agent prompt context contains it; voice-agent prompt context (M9.x Realtime session) does not.

---

_Update this doc when reality teaches the design something new._
