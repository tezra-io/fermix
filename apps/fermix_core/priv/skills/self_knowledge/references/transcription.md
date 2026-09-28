# Transcription (speech to text)

Inbound audio is transcribed before the agent sees it on every media channel: Telegram (voice notes, audio files, round video notes), WhatsApp, Slack, Discord and Signal. A voice note with a caption delivers both, the caption first, then the transcript under `[voice note transcript]`. The meeting notetaker uses the same backends.

## Choosing a backend

- **Mac app**: Settings > Voice, section **Voice notes**: **Transcribe with**, **Model**, and the backend's key row.
- **Linux and dev installs**: browser setup's **Voice notes** tab, or `fermix setup --transcription-backend`, `--transcription-model`, `--transcription-api-key` (stored under the selected backend's key).
- Config: `[fermix_core.transcription]` `backend`, `model` (one shared key, reset to the new backend's default on a switch), `max_file_mb`, per-backend keys (in the keychain). An unknown backend or a non-positive `max_file_mb` fails config load.
- `fermix doctor`'s `transcription` row reports the backend and whether what it needs resolves, without transcribing anything.

| Backend | Models | Key |
|---|---|---|
| `openai` (default) | `gpt-4o-mini-transcribe` (default), `gpt-transcribe`, `gpt-4o-transcribe`, `whisper-1` | `openai_api_key` overrides the chat provider's OpenAI key, else reuses it |
| `xai` (SpaceXAI) | none to pick | `xai_api_key` overrides the chat key, else reuses it; an API key is required, because a Grok subscription sign-in does not work for speech to text |
| `deepgram` | `nova-3` (default), `nova-2` | `deepgram_api_key`, required |
| `local` (on-device) | the installed speech model | none |

## The on-device `local` backend

- It runs a `fermix-stt` helper over a locally installed model: audio never leaves the machine. It needs both the helper and the model, and names the missing half rather than falling back to a hosted backend.
- **Setup does not offer it**: no picker lists it (Voice notes, either app, or the notetaker's choice), because its model download has not been walked end to end. A configuration that already names it keeps working and shows it, disabled; the Mac app's install refuses too. `local_offered = true` under `[fermix_core.transcription]` puts the choice back.
- Writing `backend = "local"` by hand installs nothing: every call fails naming the missing half, and boot never downloads. Builds exist for Apple Silicon macOS, Linux x86_64 and Linux arm64; on any other machine (an Intel Mac) it is unavailable, and an older Linux C library can install it but not start it. There, `fermix doctor` says it is not available and a voice note gets a reply to choose another backend.

## Live streams

A voice note is one round trip. A meeting is a live stream of 16 kHz mono s16le PCM: `deepgram`, `xai` and `local` stream natively (lower latency, word timings), and `openai` is driven in short spoken chunks, so every backend can feed a live listener. Each transcription is a traced provider call (`purpose: :transcription`, no token cost).

## When it cannot transcribe

The sender gets a reply and no turn is scheduled:

| Condition | Reply | Fix on a Mac |
|---|---|---|
| No backend configured | "…no transcription backend is configured. Run `fermix setup` to add one." | Settings > Voice > **Voice notes** |
| File over `max_file_mb` | the size limit | send a shorter clip |
| On-device helper or model missing | "…Install it from `fermix setup` → Transcription." | choose a hosted backend in **Transcribe with** |
| No on-device build for this machine | choose another backend | **Transcribe with** |
| Provider error | "transcription failed. Please try again." | try again; check the key |

The replies name `fermix setup`; translate them for a Mac app user.
