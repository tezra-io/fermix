# Images — looking at them, making them, sending them

## Looking at a local image (`view_image`)

`view_image` is the only way to actually see a picture that is already on the
machine; `file_read` is a text reader and returns nothing useful for one. Give
it `paths`: one to six local paths, in the order you want to refer to them
("reference 1", "reference 2", …). One image is a one-element list.

- JPEG, PNG and WebP only. The type is identified from the file's leading bytes,
  not from its name, so a `.png` that is really something else is refused rather
  than misread. GIF and every other container is refused as
  `image_type_unsupported`.
- 10 MiB per file, 24 MiB for the whole call, six files maximum.
- All or nothing: one unreadable, missing, empty, oversized or wrong-typed path
  fails the whole call and names the offending reference, so you never get a
  partial reference set while believing it is complete.
- No URLs, no globs, no directories, and no base64 argument. The paths go
  through the same sandbox read policy as `file_read`, so a file outside the
  allowed roots is refused before any bytes are read.
- The images reach the model on the next step. A model route without vision
  fails loud instead of dropping them, so an answer is never produced as though
  a picture had been inspected when it was not.
- A successful call proves the bytes were supplied. It does not prove that any
  conclusion drawn from them is right.

## How an image reaches the model

Inbound pictures, `view_image` results and images a tool returns (a `browser`
screenshot) all reach the model as image content. Anthropic, OpenAI and OpenAI
Codex (the Responses wire) take JPEG, PNG, WebP and GIF; Grok takes JPEG and
PNG only. OpenRouter, Mistral, Venice and Ollama depend on the model: a model
the built-in catalog marks text-only (Ollama's three default models, Venice's
GLM 5.3) is refused before the call, any other model is sent the image and the
provider refuses it if it cannot see. Fermix converts no picture. A route that
cannot take one fails over to the next route that can; when none can, the reply
says so. An image is never silently dropped. Prompt caching is unaffected.

## Inbound attachments

Every channel (Telegram, WhatsApp, Slack, Discord, Signal, iMessage, the phone)
and `fermix ask --attach` hand attachments to one gateway pipeline. It fetches
up to ten per message, four at a time, names each one's kind from its bytes
(not its name or the platform's label), and renders it:

| Kind | Reaches the model as |
|---|---|
| Picture (JPEG, PNG, WebP, GIF) | the picture, up to 10 MB |
| GIF, animation, video | one still: a GIF file's own first frame (cut from the file, no conversion), or the preview the sender's app made (Telegram's thumbnail, Slack's video thumbnail, the phone's poster) |
| PDF | a document, on Anthropic, OpenAI, OpenAI Codex, OpenRouter and Venice (OpenRouter is pinned to the model's own PDF reading, so no paid OCR runs) |
| Text file | inlined under the attachment list; all the text files of one message share 32 KB |
| Voice note, audio, Telegram video note | its transcript (see `transcription`) |

The user text then carries an `[attachments]` list: each attachment's name,
kind, size and what reached the model ("attached as image 1", "one still frame
of it attached as image 2", "attached as document 1", "inlined below") or why
not ("not readable: …"). History keeps that list, never the bytes, so a later
turn knows what was sent but cannot reopen it; a voice note is not listed,
because its transcript is already the text.

What it cannot read is named, never dropped and never called empty:

- a video with no still to read: reading its frames takes ffmpeg, and the reply
  gives the install command (macOS: `brew install ffmpeg`; Linux: the `ffmpeg`
  package) or asks for a screenshot; an animated picture (an animated WebP or
  sticker) with no still, or a video whose still could not be fetched, asks for
  a screenshot;
- a file of another type (a Word file, a ZIP): send it as a PDF, a picture or
  plain text;
- a HEIC, TIFF or other picture format models do not take: send a JPEG or PNG
  (iMessage converts HEIC itself, so it arrives as a JPEG);
- over 20 MB, or a picture over 10 MB, or past what one message carries
  together (20 MB) or past ten attachments: send it in its own message;
- a file that is not what the channel called it (a "PNG" that is a web page,
  which a channel without access to the file sends): named as such;
- a download from the channel that failed: send it again.

With a caption, the turn runs and the list names what it could not read. With
no text and nothing readable, the gateway answers by naming each attachment and
its reason, and no turn runs.

## Making an image (`generate_image`)

`operation` is `generate` (the default) or `edit`. An edit's `input_image` is a
sandbox path or `inbound:last` — the image just sent in this chat. Optional
`mask` (a PNG-alpha mask whose transparent regions are the only parts edited;
OpenAI backend only), `size` and `model` round out the arguments.

The backend is `[fermix_core.tools.generate_image] backend` (Mac: Settings >
Images): `openai`, `xai` or `google`, plus optional `model` and `size`. `edit`
and `mask` are refused loudly on a backend that lacks them. OpenAI and SpaceXAI
reuse their chat key; Google takes `google_api_key` in that
section (the Mac Images pane's key row), with `GEMINI_API_KEY` as the fallback.
Any other key in the section stops the daemon from booting.

An older config's `backend = "openai_codex"` is dropped at load with a warning
naming those three, which leaves image generation off until one is chosen.
Signing in to OpenAI Codex with ChatGPT does not generate images: its route has
no image tool.

### Save, look, then send

`delivery` decides what happens after the picture exists:

| Value | What happens |
|---|---|
| `"save"` | Written under the sandbox `media/` floor and not sent anywhere |
| `"send"` | Refused before the provider call when this run has no chat destination; otherwise saved and sent |
| omitted | Sent when this run has a chat channel, saved only when it does not |

Use `"save"` whenever the picture is meant to be checked before anyone sees it:
save it, `view_image` the saved file, then `send_attachment` once it looks
right. A requested send the channel rejects is reported as a failure that still
names the saved path, so the same file can be attached again without paying to
generate it a second time.

## Sending a file (`send_attachment`)

`send_attachment` sends a local sandbox file out through the active channel.
URLs are never fetched, and inbound attachments arriving in chat are rendered by
the gateway rather than by a tool.

It also works inside a scheduled job:

- The job must deliver to a chat — `delivery_mode` `origin` or `channel`, with a
  destination that resolves and a channel that can carry files. The destination
  is the one captured when the run started; it cannot be retargeted from the
  task text or from a tool argument.
- `local` and `none` delivery, an unresolvable destination, and a text-only
  channel all refuse the send. The run's own instructions say which of the two
  is true before any tool is called, so a job never starts work it cannot
  deliver.
- A run may send at most sixteen attachments, failed attempts included, and each
  send is bounded by whatever is left of the run's time budget. Once the run
  ends, its destination stops accepting.
- The final response is still written and delivered once by the scheduler
  itself. Attachments are extra; do not try to send the final text this way.

Only **one** channel send executes per model step. If a step asks for two, the
first one runs and the second comes back as an error result telling you to call
it again on the next step — the run itself is unaffected, and everything else in
that step still runs.
