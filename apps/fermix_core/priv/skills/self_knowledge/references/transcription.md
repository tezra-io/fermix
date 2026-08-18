# Transcription (speech to text)

Inbound audio on every media-capable channel is transcribed before the agent sees
it — Telegram (voice notes, audio files, and round video notes), WhatsApp, Slack,
Discord, and Signal — and the meeting notetaker listens through the same engine.
When a voice note also carries a caption, both are delivered: the caption first,
then the transcript under a `[voice note transcript]` delimiter. One config
section serves both: `[fermix_core.transcription]` (`backend`, `model`,
`max_file_mb`, per-backend key slots), set from the Transcription card, from `fermix
setup --transcription-backend`/`--transcription-model`/`--transcription-api-key`,
or by hand. `fermix doctor`'s `transcription` row reports the active backend and
whether what it needs resolves — offline, it never transcribes to find out.

## Backends and their credentials

Each hosted backend has its own optional key slot, always settable in the
Transcription card (and `--transcription-api-key` stores under the selected
backend's slot): `openai` (default, `gpt-4o-mini-transcribe`) and `xai`
(SpaceXAI, Grok STT — modelless, so it has no model to pick and the card hides
that field) take a transcription key that OVERRIDES the reused chat-provider key,
or reuse that chat key if none is set. SpaceXAI STT REQUIRES an API key — the
Grok subscription OAuth token does not work for `/v1/stt` — so paste one when the
SpaceXAI provider is on OAuth. `deepgram` (`nova-3`) has no chat provider to
reuse, so its `deepgram_api_key` is required. All three keys keychain as
`@keyring`. OpenAI's list also offers `gpt-transcribe` beside the default mini
model. `model` is a single shared key, so setup snaps it to the chosen backend's
default on a backend switch (an unknown backend or non-positive `max_file_mb`
fails config load loudly).

## The on-device `local` backend

`local` runs a `fermix-stt` sidecar over a locally installed speech model: audio
never leaves the machine and there is no key to configure. What it needs instead
is an installed binary AND an installed model, and it reports which half is
missing rather than degrading to a hosted backend.

Installing is a deliberate act, done from the Transcription card when `local` is
selected. Writing `backend = "local"` into `config.toml` by hand installs
nothing — every call then fails naming the missing half, and boot never
downloads. No `fermix-stt` release is pinned in this build yet, so an install
attempt refuses honestly on both halves (the sidecar has no pinned release; the
model's checksums are not in this build) instead of fetching an unverified binary
or unverified weights.

## Files versus live streams

A voice note is one file, transcribed in one round trip. A meeting is a live
stream, and the same backend set serves it two ways: `deepgram`, `xai`, and
`local` speak a streaming protocol natively, while a batch-only backend
(`openai`) is driven by a chunked adapter that transcribes short spoken spans in
order — so every backend can feed a live listener, with the streaming ones giving
lower latency and word timings. A stream speaks exactly one audio format, 16 kHz
mono s16le PCM, and callers convert before pushing.

Every backend routes its round trip through the shared provider-call telemetry
(`purpose: :transcription`, no token cost), so a transcription shows up in traces
like any other provider call.

## When it can't transcribe

When transcription isn't configured, the file is over the size cap, or the
provider errors, the sender gets a specific reply instead of a silent drop — not
configured → run `fermix setup`; too large → the size-cap limit; other failures →
transcription failed, try again — and no turn is scheduled.
