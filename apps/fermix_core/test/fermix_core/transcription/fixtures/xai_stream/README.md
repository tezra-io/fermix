# xAI streaming STT fixtures — provenance

Every field name and value spelling in these files comes from xAI's streaming
speech-to-text reference, retrieved 2026-08-17:

- https://docs.x.ai/developers/model-capabilities/audio/speech-to-text
- https://docs.x.ai/developers/rest-api-reference/inference/voice

What the docs pin, and what the codec therefore encodes:

- connection is configured by query parameters only, no setup message:
  `encoding=pcm` (signed 16-bit little-endian), `sample_rate`, `channels`,
  `interim_results`
- the WebSocket upgrade authenticates with `Authorization: Bearer <key>`
- server events are `transcript.created` (ready — wait for it before sending
  audio), `transcript.partial` (`text`, `words`, `is_final`, `speech_final`,
  `start`, `duration`), `transcript.done` (`text`, `duration`) and `error`
  (`message`)
- the client's end-of-audio control frame is `{"type":"audio.done"}`

Still owed, and not something a fixture can supply: one live capture against a
real `XAI_API_KEY`. Push a clip through `FermixCore.Transcription.open_stream/2`
with the xai backend, confirm segments arrive, and replace these files with the
captured bytes if anything on the wire differs from the reference above.
