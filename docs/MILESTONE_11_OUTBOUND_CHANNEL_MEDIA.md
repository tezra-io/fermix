# Milestone 11: Outbound Media on Channels — Functional Design

**Status:** Draft
**Date:** 2026-05-18
**Author:** Sujeeth / Aira
**Depends on:** M3 (channel coverage and `FermixChannels.Channel` behaviour), M4.9 (`Capability` + `Capabilities.Builtin.Tool` surface), M5 (`Sandbox.read_path/3` floor)
**Blocks:** any agent workflow that has to deliver an image, voice note, document, or audio file to a channel user. Today the agent's only egress is text, so it falls back to writing to disk and pasting the local path — which is what the operator observed on Telegram, and which reproduces identically on Discord, Slack, WhatsApp, and Signal.
**Defers to other milestones:** outbound media generation (image / TTS) tools — M11 ships the egress pipe, not new producers; the LLM attaches files the agent has already written via `file_write` or fetched via `web_fetch`. Voice-companion media (M9.x) stays in its own realtime path — M11 does not route Realtime audio through channels.
**References:** `apps/fermix_channels/lib/fermix_channels/channel.ex`, `apps/fermix_channels/lib/fermix_channels/message.ex`, `apps/fermix_channels/lib/fermix_channels/dispatcher.ex`, `apps/fermix_channels/lib/fermix_channels/telegram.ex`, `apps/fermix_channels/lib/fermix_channels/discord.ex`, `apps/fermix_channels/lib/fermix_channels/slack.ex`, `apps/fermix_channels/lib/fermix_channels/whatsapp.ex`, `apps/fermix_channels/lib/fermix_channels/signal.ex`, `apps/fermix_channels/lib/fermix_channels/idempotency.ex`, `apps/fermix_core/lib/fermix_core/agents/main_agent.ex`, `apps/fermix_core/lib/fermix_core/capabilities/builtin/tool.ex`, `apps/fermix_core/lib/fermix_core/tools/file_write.ex`, `apps/fermix_core/lib/fermix_core/tools/file_read.ex`, `apps/fermix_core/lib/fermix_core/sandbox.ex`, [Telegram Bot API — `sendPhoto` / `sendDocument` / `sendVoice` / `sendAudio` / `sendVideo`](https://core.telegram.org/bots/api#sendphoto), [Discord REST — message attachments](https://discord.com/developers/docs/resources/channel#create-message), [Slack Web API — `files.completeUploadExternal`](https://api.slack.com/methods/files.completeUploadExternal), [WhatsApp Cloud API — Media](https://developers.facebook.com/docs/whatsapp/cloud-api/reference/media), [`signal-cli send --attachment`](https://github.com/AsamK/signal-cli/wiki/Send-and-Receive-Messages).

---

## 1. Problem / Goal

Every channel adapter today implements `send_message(chat_id, text, opts)` and nothing else (`apps/fermix_channels/lib/fermix_channels/channel.ex:35`). The dispatcher builds a single-arg reply hook of type `(String.t() -> :ok | {:error, term()})` (`channel.ex:18`) and passes it to the main agent. The main agent's typespec confirms the shape:

```
:reply_fn => (String.t() -> any())
```

`apps/fermix_core/lib/fermix_core/agents/main_agent.ex:55`, used at `main_agent.ex:896` as `msg.reply_fn.(response)` with `response` being the LLM's final text.

The result: when the agent decides to send a chart, a photo, an audio clip, or even a generated PDF, the best it can do is `file_write` to disk inside the sandbox and emit the *path* as part of its text reply. The user on Telegram gets a string they can't open; the user on Slack sees a worker-machine path; the user on WhatsApp sees the same. The inbound side is already structured (`Message.attachments` at `message.ex:24`; Slack/Signal/WhatsApp populate it; WhatsApp implements `download_attachment/2`), but there is no outbound symmetry.

**Goal of M11:** widen the channel outbound contract to carry structured media, implement the channel-side endpoints for the five existing channels, and add a single built-in tool (`send_attachment`) that lets the LLM emit a media intent through the same reply port the agent already owns. After this milestone:

1. The `FermixChannels.Channel` behaviour declares `send_media/3` alongside `send_message/3`. The two are siblings, not alternatives — both required, both `{:ok, _} | {:error, term()}` returning.
2. The dispatcher's reply hook is widened to a single multiplexed function `(outbound() -> :ok | {:error, term()})` where `outbound :: {:text, String.t()} | {:media, media_part()}`. Bare-string replies are dropped during the migration — every call site is updated; no string sugar (CLAUDE.md rule 12).
3. Telegram routes `:image` → `sendPhoto`, `:voice` → `sendVoice`, `:audio` → `sendAudio`, `:video` → `sendVideo`, `:document` → `sendDocument`. Discord routes everything through multipart `POST /channels/{id}/messages`. Slack routes through `files.getUploadURLExternal` → PUT → `files.completeUploadExternal`. WhatsApp routes through `/{phone-id}/media` upload → `/{phone-id}/messages` reference. Signal routes through `signal-cli send --attachment <path>`.
4. The LLM gets one new tool — `send_attachment(path, kind, caption?)` — that validates the path against the sandbox, enforces a per-channel byte cap, and dispatches through the agent's reply port. The tool returns `{:ok, %{success: true, kind: ..., bytes: ...}}` or `{:error, tag}` with a tag the LLM can read and react to.
5. Failure is loud, structured, and the LLM's to handle. If a channel returns `{:error, :media_unsupported}` (e.g. a future stdio channel that has no media transport), the tool surfaces that tag verbatim. The agent does **not** silently degrade to "paste the path as text" — that decision belongs to the LLM, at the prompt layer, not to the system.

**Non-goal in this milestone:**

- Media generation. M11 does not add an image-generation tool, a TTS tool, or a chart renderer. `send_attachment` consumes paths that already exist on disk (written by `file_write`, fetched by `web_fetch`, etc.).
- Inbound→outbound forwarding ("re-send the user's photo back"). The shape supports it (the inbound attachment's `path` after `download_attachment` could be the `send_attachment` input), but no built-in capability does the forwarding automatically.
- Realtime / voice-companion media. M9.x owns the Realtime audio path and ships its own egress. M11 keeps channels orthogonal to Realtime.
- Streaming uploads or chunked transfer. Every channel's upload is a single multipart POST in v1. Streaming is a per-channel follow-on once a real workflow needs it.
- Web LiveView attachment surface (M10). LiveView has its own out-of-band file delivery story; M11 does not touch it.

---

## 2. References

- `apps/fermix_channels/lib/fermix_channels/channel.ex:18,35,47,54` — the current behaviour: `reply_fn` typed as `(String.t() -> _)`, `send_message/3` text-only, `download_attachment/2` already shows the inbound media pattern this milestone mirrors.
- `apps/fermix_channels/lib/fermix_channels/message.ex:24,41` — `attachments: [map()]` field, already used by inbound.
- `apps/fermix_channels/lib/fermix_channels/dispatcher.ex:46-75` — `build_reply_fn/3` is the only place in the codebase that constructs the agent's reply port.
- `apps/fermix_channels/lib/fermix_channels/telegram.ex:101-130` — `post_send_message/3` shape we mirror for `post_send_media/3`.
- `apps/fermix_channels/lib/fermix_channels/whatsapp.ex:23,94-101,256-308` — existing media path on the *inbound* side: `@max_media_bytes 25 * 1_024 * 1_024`, `download_attachment/2`, `media_url/2`, `download_media/2`. M11 reuses the same byte-cap discipline for outbound and the same two-step (resolve → transfer) shape.
- `apps/fermix_core/lib/fermix_core/agents/main_agent.ex:55,121,127,896` — every reply-related typespec, guard, and call site; all change in lockstep.
- `apps/fermix_core/lib/fermix_core/capabilities/builtin/tool.ex` — the behaviour `send_attachment` implements (`name/0`, `description/0`, `parameters/0`, `when_to_use/0`, `examples/0`, `failure_modes/0`, `requires_setup/0`, `category/0`, `execute/2`).
- `apps/fermix_core/lib/fermix_core/tools/file_write.ex:6-9,69-80` — exact module shape and telemetry pattern `send_attachment` follows.
- `apps/fermix_core/lib/fermix_core/tools/file_read.ex:89` — `Sandbox.read_path(path, :file_read, context)` is the sandbox gate; `send_attachment` calls it with action `:send_attachment`.
- `apps/fermix_channels/lib/fermix_channels/idempotency.ex` — existing idempotency table; outbound media sends register here under `{channel, chat_id, content_hash}` to prevent duplicate sends on retry.
- Telegram Bot API: `sendPhoto`, `sendDocument`, `sendVoice`, `sendAudio`, `sendVideo`. All multipart with `chat_id` + the file part named after the kind, plus optional `caption`, `parse_mode`, `message_thread_id`.
- Discord REST v10: `POST /channels/{channel.id}/messages` with `multipart/form-data`, `files[n]` parts and a JSON `payload_json` field.
- Slack Web API v2 upload flow: `files.getUploadURLExternal` → HTTP PUT to the returned URL → `files.completeUploadExternal` with the file ID and a channel reference. `files.upload` (v1) is being deprecated; we go straight to v2.
- WhatsApp Cloud API: `POST /{version}/{phone-id}/media` → returns `id` → `POST /{version}/{phone-id}/messages` with `{ type: "image" | "audio" | "video" | "document", "image": {id: ...} }`.
- `signal-cli`: `signal-cli -a <account> send -m "" --attachment /abs/path <recipient>`.

---

## 3. Current State Audit

Verified by reading the dev branch at the time this draft was written.

### 3.1 The channel behaviour is text-only

`channel.ex:30-35`:

```
@callback send_message(String.t(), String.t(), send_opts()) :: :ok | {:error, term()}
```

`send_opts` is `[reply_to | parse_mode | message_thread_id]` (`channel.ex:13-16`). There is no media-shaped option, no MIME type, no file path, no byte payload. `reply_fn` is `(String.t() -> :ok | {:error, term()})` (`channel.ex:18`). Both are pinned to strings.

### 3.2 Every channel honors text-only

- `telegram.ex:48,103` — only `POST /sendMessage`. `sendPhoto` etc. do not appear anywhere in the file.
- `discord.ex:51` — `def send_message(channel_id, text, opts \\ [])`, body is JSON `{content: text}`. No multipart, no attachments parameter.
- `slack.ex:50` — `chat.postMessage` only.
- `whatsapp.ex:66` — `messages` endpoint with `type: "text"`. Inbound media is parsed and downloadable (`whatsapp.ex:94-101`); outbound has no equivalent.
- `signal.ex:55` — `signal-cli send -m <text>`. No `--attachment`.

Every channel's `build_reply/1` returns the same `(text -> :ok | err)` shape.

### 3.3 The agent treats the reply hook as a string port

`main_agent.ex:55` types it as `(String.t() -> any())`. The guard at `main_agent.ex:127` is `is_function(reply_fn, 1)`. The delivery call at `main_agent.ex:896` is `msg.reply_fn.(response)` — `response` is the LLM's stitched-together final text.

There is one reply path, it carries one string, and it fires once at end-of-loop.

### 3.4 No built-in tool produces media

Catalog: `apps/fermix_core/lib/fermix_core/tools/`. `file_write` writes to disk, `web_fetch` retrieves bytes (which it then writes to disk via the caller), `browser` returns text, `memory_*` are text. There is no "send this to the user" tool — the LLM has no surface to express the intent. Even if the channel could carry media, the LLM has no syntax to ask for it.

### 3.5 Inbound attachments are first-class, outbound has no symmetric structure

- `Message.attachments :: [map()]` (`message.ex:24,41`).
- Slack populates it from `files` array (`slack.ex:157,184-202`).
- Signal populates it from `attachments` array (`signal.ex:108,118-136`).
- WhatsApp populates it and implements `download_attachment/2` with a 25 MiB cap (`whatsapp.ex:23,94-101,192-210`).

Outbound has none of this — no `media_part` type, no `send_media` callback, no `[map()]` carrier on the reply side. The asymmetry is the entire bug.

### 3.6 The sandbox floor is already in place for path inputs

`Sandbox.read_path/3` is the gate `file_read` uses (`file_read.ex:89`): `{:ok, resolved_abs_path} | {:error, :sandbox_denied | ...}`. M11's `send_attachment` calls the same function with a new action atom; no new sandbox surface is required.

### 3.7 Idempotency exists for one direction

`apps/fermix_channels/lib/fermix_channels/idempotency.ex` handles inbound dedup keyed by webhook payload identity. Outbound has no idempotency wrapper today — retries of `send_message` on a transient HTTP error would, if they happened, double-post. They mostly don't, because most channels return idempotent enough HTTP semantics on retry, but a media upload that succeeds-but-times-out is a real risk and M11 has to address it explicitly.

---

## 4. Scope and Non-Goals

### In Scope

| Feature | Priority | Type | Description |
|---------|----------|------|-------------|
| `FermixChannels.Channel.send_media/3` callback | P0 | New | Required behaviour callback: `@callback send_media(String.t(), media_part(), send_media_opts()) :: :ok \| {:error, term()}`. Channels that genuinely cannot transport media implement it as `{:error, :media_unsupported}`. Not `@optional_callbacks` — every channel module must answer, even if the answer is "no". |
| `FermixChannels.Channel.media_part/0` type | P0 | New | `%{required(:kind) => kind, required(:path) => String.t(), optional(:caption) => String.t(), optional(:filename) => String.t(), optional(:mime_type) => String.t()}` where `kind :: :image \| :voice \| :audio \| :video \| :document`. Declared on the behaviour module so every channel and the agent share one type. |
| Widened `reply_fn` type | P0 | Breaking | `@type outbound :: {:text, String.t()} \| {:media, media_part()}` and `@type reply_fn :: (outbound() -> :ok \| {:error, term()})`. Bare-string replies are removed in the same change set — no sugar branch. Every existing call site is updated mechanically (§8). |
| `Dispatcher.build_reply_fn/2,3` rewrite | P0 | Modified | The single point where the reply hook is constructed (`dispatcher.ex:46-75`). Becomes a one-arg function that pattern-matches `{:text, _}` → `channel.send_message/3` and `{:media, _}` → `channel.send_media/3`. Both branches log on `{:error, _}` exactly like today. No silent fallback between branches. |
| Main agent reply typing | P0 | Modified | `main_agent.ex:55` typespec widens. The end-of-loop call at `main_agent.ex:896` becomes `msg.reply_fn.({:text, response})`. The guard at `main_agent.ex:127` stays `is_function(reply_fn, 1)`. |
| Telegram media impl | P0 | New | `post_send_media/3` private, mirroring `post_send_message/3` (`telegram.ex:101-130`) but with `Req.new(method: :post, url: ..., form_multipart: [...])`. Five endpoints: `sendPhoto`, `sendDocument`, `sendVoice`, `sendAudio`, `sendVideo`. `kind`→endpoint map at module-attr level. `caption` and `message_thread_id` plumbed through. |
| Discord media impl | P0 | New | Multipart `POST /channels/{id}/messages` with `payload_json` (content + flags) and a single `files[0]` part. `kind` is informational on Discord (no per-kind endpoint) but used to derive filename + content-type defaults. |
| Slack media impl | P0 | New | Three-call sequence: `files.getUploadURLExternal` (returns `upload_url`, `file_id`) → `PUT` to `upload_url` → `files.completeUploadExternal` with `[{id, title}]` + `channel_id` + optional `thread_ts` + `initial_comment` (= caption). Failure at any step propagates the underlying error untouched. |
| WhatsApp media impl | P0 | New | Two-call sequence: `POST /{version}/{phone-id}/media` multipart → returns `id` → `POST /{version}/{phone-id}/messages` with `type: <kind>` + `{<kind>: {id: <id>, caption?: <caption>}}`. Reuses the existing `whatsapp.ex` config + access-token plumbing. |
| Signal media impl | P0 | New | `signal-cli -a <account> send -m <caption-or-empty> --attachment <abs-path> <recipient>`. Reuses the existing `Signal.send_message/4` (`signal.ex:263`) shell-invocation shape; the new branch adds the `--attachment` flag. No multipart, no temp files — Signal reads from the on-disk path directly. |
| `FermixCore.Tools.SendAttachment` | P0 | New | New built-in tool implementing `FermixCore.Capabilities.Builtin.Tool`. `name: "send_attachment"`, `category: :channel`, three parameters: `path` (required), `kind` (required, enum), `caption` (optional). `execute/2` resolves `path` via `Sandbox.read_path(path, :send_attachment, context)`, checks the per-channel byte cap, invokes `context.reply_fn.({:media, media_part})`, and returns `{:ok, %{success: true, kind: ..., bytes: ...}}` or `{:error, tag}`. |
| Per-channel byte caps | P0 | New | `Channel.media_byte_cap(kind)` informational helper on each adapter (Telegram photo 10 MiB / doc 50 MiB / voice 1 MiB / video 50 MiB, Discord 25 MiB any, Slack 1 GiB any (we cap at 100 MiB practical), WhatsApp 16 MiB any except video at 100 MiB, Signal 100 MiB any). `SendAttachment.execute/2` calls this via `Dispatcher.media_byte_cap/2` and rejects oversize before any upload. Mirrors `whatsapp.ex:23`. |
| Outbound idempotency | P0 | New | `Idempotency` extension: outbound media sends compute a content hash (`:crypto.hash(:sha256, channel <> chat_id <> path <> caption)`) and register it for 60 s. Within the window, a duplicate send is a no-op returning `:ok` — same as the inbound dedup contract. Text sends are not retroactively wrapped — this milestone adds the cover for media only, where the failure cost is higher. |
| Telemetry | P0 | New | `[:fermix, :channel, :message]` already exists (`telegram.ex:58-63`). Extended: metadata gains `:kind :: :text \| :media` and `:media_kind :: kind \| nil`. New event `[:fermix, :channel, :media_send_error]` for failed media sends, with `%{channel, chat_id, kind, reason, bytes}`. Every channel's media path emits both on success and failure paths. |
| Tests | P0 | New | See §7. Behaviour-conformance test (every channel module passes a shared media-callback contract suite), per-channel HTTP fixture tests (Telegram `sendPhoto`, Slack three-step, WhatsApp upload→send, Discord multipart, Signal CLI), `SendAttachment` happy path + 6 failure modes, dispatcher reply-port routing, sandbox denial, byte-cap rejection, idempotency dedup. |
| Documentation | P0 | Docs | This file. Plus a short README snippet next to `apps/fermix_channels/README.md` showing the `send_attachment` tool usage and the cap matrix. No CLAUDE.md change. |

### Non-Goals

| Feature | Reason | When |
|---------|--------|------|
| Media-generation tools (image, TTS, chart) | M11 ships the egress pipe. Producers are independent — they can ship before or after as separate, smaller PRs. Bundling would expand scope by 5x. | Separate tools per producer, owned by their respective domains (M7 advanced tools, M9.x voice). |
| Inbound→outbound forwarding helper | The shape allows it (`download_attachment` returns a path; `send_attachment` consumes a path), but no built-in capability does it automatically. Operators / LLM workflows compose the two. | If a real workflow needs it. |
| Streaming / chunked uploads | Every channel's v1 path is a single multipart POST. Streaming adds a second code path per channel for marginal benefit at the M11 file sizes. | Per-channel follow-on if the byte cap proves limiting. |
| Bare-string `reply_fn` sugar / back-compat | Rule 12: no fallbacks, one code path per behavior. The migration is mechanical (one grep, ~15 call sites — §8). | Never. |
| Web LiveView attachment surface | M10 owns LiveView. LiveView's egress is HTTP, not channel-shaped; the abstraction doesn't fit `Channel`. | M10 or its successor. |
| Channel-side caption Markdown rendering across all kinds | Telegram `sendPhoto.caption` accepts `parse_mode`, but Discord/Slack/WhatsApp/Signal treat captions as plain text. v1 sends captions as plain text everywhere for consistency; Telegram's existing markdown→HTML pass is reserved for `:text` parts only. | Per-channel follow-on; low value vs. complexity. |
| Media replies via `reply_to` / threading on Slack/Discord | Threading semantics already plumbed for text (`send_opts.message_thread_id`, Slack `thread_ts`). The same opts pass through `send_media_opts` unchanged, so this is in scope — but threading-edge behavior across channels (Discord forum posts, Slack canvas threads) is not exhaustively tested in v1. | Per-channel follow-on if a workflow surfaces a regression. |
| Voice / Realtime audio routed through `send_attachment` | M9.x has its own egress and its own latency budget. Forcing it through the channel path would double-buffer and re-encode. Out of scope. | Never — orthogonal domains. |
| Replacing `file_write`'s on-disk artifact with an in-memory blob | Sandbox-rooted on-disk artifacts are auditable; in-memory blobs aren't. The path-based shape also matches every channel's wire shape (all five do multipart from a path). | Never as primary; in-memory blob support is a future optional `media_part.bytes` key if a producer warrants it. |
| Per-recipient consent / opt-out for media | Channel-platform terms-of-service issues (WhatsApp media policy, etc.) belong to a future governance milestone, not the egress mechanism. | M10 / governance follow-on. |

---

## 5. Design

### 5.1 The reply contract widens to a tagged-tuple multiplex

`FermixChannels.Channel` declares the new types and callbacks:

```elixir
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

@callback send_media(String.t(), media_part(), send_media_opts()) ::
            :ok | {:error, term()}
```

Bare-string replies are gone. Every existing producer of an `outbound` value wraps in `{:text, _}` explicitly (§8). The widened `reply_fn` is the only port the agent sees; the channel module remains hidden behind the dispatcher's wrapper.

Rationale for one wrapper vs. two separate hooks (text-only + media-only):

- The agent already passes around `msg.reply_fn` as a single value. A second hook would double the surface and force every internal helper that accepts `reply_fn` to accept two.
- The tagged-tuple shape mirrors the inbound `Message.attachments` direction: inbound is "one message struct with a list of parts," outbound is "one reply port with one part per call." Both directions speak structured parts.
- Pattern-matching on `{:text, _}` / `{:media, _}` at the dispatcher boundary is one short `case` (§5.3) — cheaper than two hooks plus call-site logic to pick the right one.

### 5.2 `Channel.send_media/3` is required, not optional

`@optional_callbacks [start_typing: 1, download_attachment: 2]` stays as-is. `send_media/3` is **not** added to the optional list. Every channel module must implement it. A channel that genuinely cannot send media (e.g. a future stdio CLI channel that prints to a terminal) implements it as:

```elixir
@impl true
def send_media(_chat_id, _media_part, _opts), do: {:error, :media_unsupported}
```

This is the **only** correct shape for "we don't support this" — explicit, named, surfaceable as a tool error to the LLM. We do not catch the error inside the dispatcher and silently degrade to a text path mentioning the file. That would be a textbook rule-12 fallback: same observable end-state ("user got something"), two paths to one configuration, with no way to tell which fired.

### 5.3 Dispatcher reply wrapper is a one-arg multiplexer

`dispatcher.ex:62` becomes:

```elixir
defp build_reply_fn(channel, %Message{} = message) do
  text_send = channel.build_reply(message)         # existing reply_fn shape
  media_send = build_media_send(channel, message)  # new sibling

  fn
    {:text, text} when is_binary(text) ->
      observe_send(text_send.(text), :text, channel, message, nil)

    {:media, %{kind: kind} = part} ->
      observe_send(media_send.(part), :media, channel, message, kind)
  end
end

defp build_media_send(channel, %Message{reply_target: reply_target, thread_ts: thread_ts}) do
  opts = if thread_ts, do: [message_thread_id: thread_ts], else: []
  fn media_part -> channel.send_media(reply_target, media_part, opts) end
end
```

`observe_send/5` is a new private helper that handles the existing logger.error branch on `{:error, _}` and emits the new `[:fermix, :channel, :media_send_error]` telemetry on the `:media` failure path. The structure of the existing `text` branch is preserved unchanged.

### 5.4 Per-channel implementations

Each channel adapter implements `send_media/3` as a thin public function that delegates to a private `post_send_media/3` (mirroring `telegram.ex:101-130`'s `post_send_message/3`). The five implementations:

**Telegram** (`apps/fermix_channels/lib/fermix_channels/telegram.ex`):

```elixir
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

@impl true
def send_media(chat_id, %{kind: kind, path: path} = part, opts \\ []) do
  with {:ok, token} <- get_bot_token(),
       :ok <- ensure_path_readable(path),
       {:ok, endpoint} <- Map.fetch(@media_endpoint, kind),
       {:ok, field} <- Map.fetch(@media_field, kind) do
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
```

`handle_telegram_response/2` mirrors the existing 200/error pattern at `telegram.ex:117-128`. `ensure_path_readable/1` is a strict precondition (the sandbox already guaranteed the path is allowed for the agent; this guard just confirms the OS can `File.stat/1` it before opening multipart).

**Discord** (`apps/fermix_channels/lib/fermix_channels/discord.ex`): one endpoint, multipart with `payload_json`:

```elixir
@impl true
def send_media(channel_id, %{kind: kind, path: path} = part, opts \\ []) do
  with {:ok, token} <- get_bot_token() do
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

`kind` is informational on Discord — the wire request is identical for every kind. We still receive `kind` so per-kind metadata (filename default, content-type) can be set, and so the byte-cap helper at §5.7 picks the right cap.

**Slack** (`apps/fermix_channels/lib/fermix_channels/slack.ex`): the new v2 three-call sequence. Each call uses `HttpClient.request/2`. The intermediate steps' errors are propagated untouched — no merge into a single opaque `:slack_upload_failed` tag.

```elixir
@impl true
def send_media(channel_id, %{path: path} = part, opts \\ []) do
  with {:ok, %File.Stat{size: size}} <- File.stat(path),
       {:ok, %{"upload_url" => upload_url, "file_id" => file_id}} <-
         get_upload_url_external(part, size),
       :ok <- put_upload(upload_url, path),
       :ok <- complete_upload_external(channel_id, file_id, part, opts) do
    :ok
  end
end
```

`get_upload_url_external/2`, `put_upload/2`, and `complete_upload_external/4` each emit `Logger.error` with the step name and return the underlying `{:error, _}` unchanged on failure.

**WhatsApp** (`apps/fermix_channels/lib/fermix_channels/whatsapp.ex`): two-call upload→messages. Cap enforcement reuses `@max_media_bytes`.

```elixir
@impl true
def send_media(to, %{kind: kind, path: path} = part, opts \\ []) do
  with :ok <- preflight_outbound_size_cap(path),
       {:ok, access_token, phone_id, version} <- whatsapp_creds(),
       {:ok, media_id} <- upload_media(path, kind, phone_id, version, access_token),
       :ok <- send_media_message(to, media_id, kind, part, phone_id, version, access_token, opts) do
    :ok
  end
end
```

`preflight_outbound_size_cap/1` mirrors `preflight_size_cap/1` at `whatsapp.ex:106-110` — same constant, same hard reject, no fallback.

**Signal** (`apps/fermix_channels/lib/fermix_channels/signal.ex`): the existing CLI shell-out at `signal.ex:263` already takes `account`, `recipient`, `text`, `opts`. We add an attachment branch:

```elixir
@impl true
def send_media(recipient, %{path: path} = part, opts \\ []) do
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
```

`signal_cli_binary/0` and `signal_account/1` are reused from the existing text path.

### 5.5 `SendAttachment` is one tool, six failure modes

```elixir
defmodule FermixCore.Tools.SendAttachment do
  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Sandbox

  @valid_kinds ~w(image voice audio video document)a

  @impl true
  def name, do: "send_attachment"

  @impl true
  def description do
    "Send a file from the workspace to the current channel as an attachment. " <>
      "The user sees the actual image/audio/document, not the path. " <>
      "Use after producing a file with file_write or web_fetch."
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
        caption: %{type: "string", description: "Optional caption shown alongside the media"}
      }
    }
  end

  @impl true
  def when_to_use do
    "When the user expects to receive a file, image, voice note, or document directly in " <>
      "the channel — not a path. Always prefer this over pasting a local path into the reply."
  end

  @impl true
  def examples do
    [
      %{
        args: %{"path" => "/tmp/chart.png", "kind" => "image", "caption" => "weekly revenue"},
        note: "send a chart you just wrote"
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
      %{tag: "send_failed", description: "channel upload returned an error"}
    ]
  end

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :channel

  @impl true
  @spec execute(map(), Tool.context()) :: {:ok, Tool.tool_result()} | {:error, atom()}
  def execute(args, context) when is_map(args) and is_map(context) do
    start = System.monotonic_time(:millisecond)

    result =
      with {:ok, path, kind, caption} <- normalize_args(args),
           {:ok, resolved} <- Sandbox.read_path(path, :send_attachment, context),
           {:ok, %File.Stat{size: size}} <- File.stat(resolved),
           :ok <- enforce_cap(context, kind, size),
           :ok <- dispatch(context, resolved, kind, caption) do
        {:ok, %{success: true, kind: kind, bytes: size}}
      end

    emit_telemetry(result, args, context, start)
    result
  end

  defp normalize_args(args) do
    # ...
  end

  defp dispatch(%{reply_fn: reply_fn}, path, kind, caption) when is_function(reply_fn, 1) do
    part =
      %{kind: kind, path: path}
      |> maybe_put(:caption, caption)

    case reply_fn.({:media, part}) do
      :ok -> :ok
      {:error, :media_unsupported} -> {:error, :media_unsupported}
      {:error, reason} ->
        Logger.error("send_attachment dispatch failed: #{inspect(reason)}")
        {:error, :send_failed}
    end
  end
end
```

Key invariants:

1. **Reply fn comes from the context, not the registry.** The tool does not import `FermixChannels` and does not know which channel it's talking to. It only knows that the agent runtime gave it a one-arg fn that accepts `outbound()`. This keeps `FermixCore` from gaining a dependency on `FermixChannels`.
2. **Sandbox first.** Every code path goes through `Sandbox.read_path(path, :send_attachment, context)` before the file is opened. Adding `:send_attachment` to the action vocabulary is a one-line patch in `sandbox.ex` (action atom only; the policy class is `:read_only` — sending a file requires only reading it).
3. **Byte cap second, dispatch third.** Cap is enforced before the channel module sees the path. Channel-specific 413 / "too large" rejections from the wire are still possible (different platforms have soft caps), and they propagate as `:send_failed`.
4. **One failure tag per code path.** No tag is reused across branches; the LLM gets unambiguous feedback.

### 5.6 The agent loop is unchanged

The main agent does not change shape. `msg.reply_fn` is still a one-arg function. The only edits to `main_agent.ex` are:

- Typespec at `:55` widens from `(String.t() -> any())` to `(FermixChannels.Channel.outbound() -> any())`.
- The call at `:896` becomes `msg.reply_fn.({:text, response})`.
- Cross-app type reference: `apps/fermix_core/mix.exs` already depends on `fermix_channels` (verify; if not, declare it for the typespec alias).

The tool execution context already includes `reply_fn` — `SendAttachment` reads it the same way every other tool reads `context.agent_name` (`file_write.ex:72`). No new plumbing through the agent loop is needed.

### 5.7 Per-channel byte caps live on the adapter

Each channel module defines an informational helper:

```elixir
@spec media_byte_cap(FermixChannels.Channel.media_kind()) :: pos_integer()
def media_byte_cap(:image), do: 10 * 1_024 * 1_024
def media_byte_cap(:voice), do: 1 * 1_024 * 1_024
def media_byte_cap(:audio), do: 50 * 1_024 * 1_024
def media_byte_cap(:video), do: 50 * 1_024 * 1_024
def media_byte_cap(:document), do: 50 * 1_024 * 1_024
```

(Numbers shown for Telegram; per-channel constants live next to each adapter and reflect each platform's documented limits.)

The cap is enforced **before** the channel HTTP call, in `SendAttachment.enforce_cap/3`, which looks up the active channel via `context.channel` (a binary like `"telegram"` already present in the agent message) and dispatches:

```elixir
defp enforce_cap(%{channel: "telegram"}, kind, size),
  do: cap_check(FermixChannels.Telegram.media_byte_cap(kind), size)
# ... etc
defp enforce_cap(%{channel: channel}, _kind, _size),
  do: {:error, {:unknown_channel, channel}}
```

A future channel adds two lines: a `media_byte_cap/1` clause and an `enforce_cap/3` clause. No registry indirection in v1 — five adapters; a behaviour-level `@callback media_byte_cap/1` is added so the typespec is uniform, but enforcement is the direct dispatch above to keep the call-site explicit.

### 5.8 Outbound idempotency

`FermixChannels.Idempotency` gains an outbound bucket:

```elixir
@spec register_outbound_media(String.t(), String.t(), media_part()) :: :fresh | :duplicate
def register_outbound_media(channel, chat_id, %{path: path} = part) do
  caption = Map.get(part, :caption, "")
  hash = :crypto.hash(:sha256, [channel, chat_id, path, caption]) |> Base.encode16(case: :lower)
  # Same ETS table pattern as inbound dedup, 60-second TTL
  # ...
end
```

`SendAttachment.execute/2` calls `register_outbound_media/3` before `dispatch/4`. On `:duplicate`, the tool returns `{:ok, %{success: true, kind: kind, bytes: size, deduplicated: true}}` and does **not** invoke the channel. The LLM sees the `deduplicated: true` flag and can choose to inform the user (or not).

This is *not* a fallback: it is a single explicit path with two terminal states (`:fresh` → upload, `:duplicate` → skip), not two paths to "deliver the file." The duplicate skip is the correct behavior — re-uploading the same content within 60 s is a bug class we prevent, not a feature.

### 5.9 Telemetry

Existing event `[:fermix, :channel, :message]` (today fired at `telegram.ex:58-63` and equivalents on other channels) is extended:

```elixir
:telemetry.execute(
  [:fermix, :channel, :message],
  %{count: chunks_or_1, bytes: byte_size_or_nil},
  %{channel: :telegram, direction: :outbound, kind: :text | :media, media_kind: kind | nil}
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

`SendAttachment` adds its own tool-level event via the existing `[:fermix, :tool, :exec]` channel — same shape as every other tool, so tool-latency dashboards pick it up without change.

`Trace.record/3` is called from `SendAttachment.execute/2` with the same `:agent_event` action as other tools so the JSONL trace files (`~/.fermix/traces/YYYY-MM-DD/`) include outbound media intents.

---

## 6. Failure Modes

Every failure surfaces to the LLM as an `{:error, atom}` it can react to. No silent degradation, no "try again as text."

| Failure | Where caught | Tool error tag | LLM-visible message |
|---------|--------------|----------------|---------------------|
| `path` or `kind` missing from args | `SendAttachment.normalize_args/1` | `:missing_parameters` | "send_attachment requires both path and kind" |
| `kind` not in `~w(image voice audio video document)a` | `SendAttachment.normalize_args/1` | `:invalid_kind` | "kind must be one of image/voice/audio/video/document" |
| Path outside sandbox roots | `Sandbox.read_path/3` | `:sandbox_denied` | sandbox's standard denied-path message |
| Path does not exist / unreadable | `File.stat/1` | `:file_not_found` | "no such file or path is unreadable" |
| File larger than channel cap | `enforce_cap/3` | `:byte_cap_exceeded` | "file (X bytes) exceeds <channel>'s <kind> cap (Y bytes)" |
| Channel returned `{:error, :media_unsupported}` | `dispatch/4` | `:media_unsupported` | "the active channel does not support media egress" |
| Channel HTTP / CLI error | `dispatch/4` | `:send_failed` | "channel rejected the upload" + log line with underlying reason |
| Channel cap mismatched with platform's actual cap (413 on the wire after our pre-check passes) | `dispatch/4` | `:send_failed` | same as above; this is the operator-tuning path |
| Duplicate within 60 s window | `Idempotency.register_outbound_media/3` | (not an error — `{:ok, %{deduplicated: true}}`) | "(idempotency dedup; not re-sent)" — LLM-visible flag |

The `:send_failed` collision is intentional — from the LLM's perspective, "the wire rejected this" is one outcome; the log line carries the discriminator for the operator. We deliberately do not expose the underlying tag (Slack's `not_in_channel`, Discord's `30007`, etc.) as an LLM-visible error code in v1 because each channel's error surface is too noisy to be useful in-prompt. Operators read traces.

---

## 7. Test Plan

| Test | Location | Asserts |
|------|----------|---------|
| Behaviour contract | `test/fermix_channels/channel_contract_test.exs` (new) | Every channel module (`Telegram`, `Discord`, `Slack`, `WhatsApp`, `Signal`) exports `send_media/3` with the expected typespec and returns `{:error, :media_unsupported}` for an unsupported-kind probe (or `:ok` for the supported kind, against a `Req.Test`-stubbed transport). |
| Telegram `sendPhoto` | `test/fermix_channels/telegram_test.exs` | Stub Bot API; assert multipart body has `chat_id` + `photo` + `caption`; status 200 returns `:ok`; 400 returns `{:error, _}` and emits `media_send_error` telemetry. |
| Telegram per-kind routing | same file | `:voice` → `sendVoice`, `:document` → `sendDocument`, etc. — five assertions. |
| Discord multipart | `test/fermix_channels/discord_test.exs` | Stub REST; assert `payload_json` JSON + `files[0]` part; filename defaults to `Path.basename/1` when not given. |
| Slack three-step | `test/fermix_channels/slack_test.exs` | Stub three calls in order; assert intermediate failure at step 2 propagates step-2's `{:error, _}` (not a merged tag); assert `initial_comment` carries `caption`. |
| WhatsApp upload→send | `test/fermix_channels/whatsapp_test.exs` | Stub `/media` upload returning `id`; assert `/messages` body has `type: <kind>` and `<kind>.id`; oversize file rejected at `preflight_outbound_size_cap/1`. |
| Signal CLI | `test/fermix_channels/signal_test.exs` | Inject a fake `signal_cli_binary/0` that records argv; assert `--attachment <path>` appears; exit code 0 → `:ok`, exit code 1 → `{:error, {:signal_send_failed, 1}}`. |
| Dispatcher routing | `test/fermix_channels/dispatcher_test.exs` | `reply_fn.({:text, "hi"})` calls `channel.send_message/3`; `reply_fn.({:media, %{...}})` calls `channel.send_media/3`; unknown tuple shape raises. |
| `SendAttachment` happy path | `test/fermix_core/tools/send_attachment_test.exs` (new) | With a sandboxed tmp file and a recording reply_fn, `execute/2` returns `{:ok, %{success: true, kind: :image, bytes: <n>}}` and the reply_fn was called with `{:media, %{kind: :image, path: <resolved>, caption: <c>}}`. |
| `SendAttachment` failure modes | same file | Six tests, one per tag in the §6 table. |
| Sandbox denial | same file | Path outside sandbox returns `:sandbox_denied`; reply_fn is **not** called. |
| Byte cap | same file | File 1 byte over the cap returns `:byte_cap_exceeded`; reply_fn not called. |
| Idempotency dedup | `test/fermix_channels/idempotency_test.exs` | Same `(channel, chat_id, path, caption)` within 60 s returns `:duplicate` and skips the channel call; after 60 s, returns `:fresh`. |
| Telemetry on success | `test/fermix_core/tools/send_attachment_test.exs` | `[:fermix, :channel, :message]` event fires with `kind: :media, media_kind: :image, bytes: <n>`. |
| Telemetry on failure | same file | `[:fermix, :channel, :media_send_error]` fires on a stubbed 400; tool emits its own `[:fermix, :tool, :exec]` with `success: false`. |
| `SafeRm` discipline | new tests' `on_exit` | Every test that creates a tmp file routes cleanup through `FermixCore.TestSupport.SafeRm.rm_rf!/1` per `CLAUDE.md` §"Known Pitfalls". |

Test isolation: every channel test stubs HTTP via `Req.Test` (already used elsewhere in the repo) — no real network calls. Signal tests inject a fake binary. WhatsApp's access-token plumbing reuses the existing config stub pattern (`whatsapp.ex` test setup).

---

## 8. Rollout / Migration

The change is cross-cutting but mechanical. Single PR, single change-set:

1. **`channel.ex`** — add types, declare `send_media/3` callback, widen `reply_fn` type.
2. **Each channel module** — implement `send_media/3`, add `media_byte_cap/1`, keep `send_message/3` and `build_reply/1` unchanged in shape.
3. **`dispatcher.ex`** — rewrite `build_reply_fn/3` to multiplex; remove the bare-string branch.
4. **`main_agent.ex`** — widen typespec at `:55`; rewrite the call site at `:896` to wrap in `{:text, _}`.
5. **Call-site sweep** — `grep -rnE 'reply_fn\.\("|reply_fn\.\(text\)'` across the umbrella, update each to `reply_fn.({:text, _})`. Expected hits: the main agent (1), the channel tests' fake reply_fns (~5), the realtime/CLI shims (verify). No production call site outside these.
6. **`SendAttachment`** module, registered in `BuiltinSeeder` so it appears in `CapabilityRegistry` after `mix fermix.setup` or first daemon start.
7. **`Sandbox`** — add `:send_attachment` to the action vocabulary (one match clause; `:read_only` policy class).
8. **`Idempotency`** — add `register_outbound_media/3` and a separate ETS bucket.
9. **Telemetry handlers** — extend any existing handlers that read `kind` metadata to know about `:media` (probably zero handlers, since today only `:text` is emitted).

No data migration. No config migration. Existing `~/.fermix/config.toml` is unchanged.

No backwards-compatibility shim for the bare-string reply: rule 12 is explicit, and the call sites are countable on one hand.

---

## 9. Open Questions

1. **Should `send_attachment` accept a remote URL?** Today it accepts only an on-disk path. A `url` parameter would let the LLM forward a `web_fetch` result without writing it to disk first. Pro: shorter LLM chains. Con: bypasses the sandbox path check and introduces a second code path (URL → in-memory bytes → multipart). Recommend: defer; the `web_fetch → file_write → send_attachment` chain is two extra tool calls but keeps every byte audit-able via the on-disk artifact. Revisit if the chain proves too expensive in practice.
2. **Should the LLM be able to send multiple attachments per reply?** Telegram has `sendMediaGroup` (up to 10), Discord allows `files[0..9]`, WhatsApp does not, Slack does not in one message. Today's `media_part` shape is singular. Plural support would be a new `media_part_list :: [media_part()]` shape carried via `{:media_group, [media_part()]}`, plus channel-side fan-out for non-supporting platforms (loop + N sends). Defer to a follow-on; v1 is one-at-a-time.
3. **Should `caption` support markdown?** Telegram does (via `parse_mode`); others treat caption as plain text. v1 sends plain text everywhere for consistency. If we add markdown support later, it's a per-channel `caption_parse_mode` opt — same shape as today's text `parse_mode`.
4. **Should we expose the channel-specific underlying error tag to the LLM?** Trade-off in §6. Current answer: no; operators read traces. Revisit if a real workflow needs the LLM to react to (e.g.) `not_in_channel` specifically.
5. **Naming.** `send_attachment` vs. `send_media` for the tool. `send_attachment` matches inbound's `attachments` field; `send_media` matches the channel callback. Picking `send_attachment` for the tool keeps inbound/outbound terminology symmetric *from the LLM's vantage point* (it sees attachments coming in, attachments going out) and reserves `send_media` for the wire callback. Recommend: keep as proposed.

---

## 10. Verification Checklist

Before calling M11 done:

- [ ] `mix deps.get && mix compile` clean with zero warnings (rule 11).
- [ ] `mix test` green; new tests included.
- [ ] `mix credo --strict` clean.
- [ ] `mix format --check-formatted` clean.
- [ ] All five channel adapters' `send_media/3` exercised by tests against `Req.Test` / injected-binary stubs.
- [ ] `SendAttachment` exercised end-to-end with `Telegram` adapter against a `Req.Test` stub returning the canonical Bot API success body.
- [ ] One manual smoke against a real Telegram bot (operator's test bot) sending a `:image` and a `:voice` part — recorded in the PR description, not automated.
- [ ] No `File.rm_rf` direct calls in any new test file (`grep -rn 'File\.rm_rf' apps/*/test/` returns zero new hits; `SafeRm.rm_rf!/1` everywhere).
- [ ] `mix fermix.setup` round-trip: `send_attachment` appears in `fermix capabilities` after seeding.
- [ ] Trace JSONL inspection: an outbound media send produces a `:agent_event` entry with `tool: "send_attachment"` and a `:channel, :message` entry with `direction: :outbound, kind: :media`.

---

_Update this doc when reality teaches the design something new._
