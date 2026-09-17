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

Each provider encodes an image at its own edge from one neutral content part, and
the text-only request shape is unchanged, so prompt caching is unaffected. A tool
result carries an image the same way an inbound message does: an Anthropic
`tool_result` content array, or a placeholder tool message plus a following user
image turn on the OpenAI-shaped wires. A route with no vision fails loud rather
than dropping the image.

## Making an image (`generate_image`)

`operation` is `generate` (the default) or `edit`. An edit's `input_image` is a
sandbox path or `inbound:last` — the image just sent in this chat. Optional
`mask` (a PNG-alpha mask whose transparent regions are the only parts edited;
OpenAI backend only), `size` and `model` round out the arguments.

The operator's config (`[fermix_core.tools.generate_image] backend`) picks the
provider — `openai`, `xai`, `google`, or `openai_codex`. `edit` and `mask` are
gated against the chosen backend's declared capabilities and rejected loudly
when unsupported, never silently dropped. The backend reuses the OpenAI or
SpaceXAI chat key, or `GEMINI_API_KEY` for Google.

The **`openai_codex`** backend is different: it needs no API key and generates
`gpt-image-2` through the ChatGPT-subscription Codex OAuth connection (billed to
the subscription, not the platform API), via the built-in image tool on the
Codex responses endpoint — an **experimental, undocumented** surface gated to
ChatGPT auth (a plan that does not entitle it returns `auth_failed`). It
supports generate and edit but no `mask`; a `router_model` config key names the
GPT-5.x model that carries the image tool.

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
URLs are never fetched, and inbound images arriving in chat are materialized by
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
