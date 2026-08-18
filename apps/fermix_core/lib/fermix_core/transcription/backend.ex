defmodule FermixCore.Transcription.Backend do
  @moduledoc """
  Behaviour for a single speech-to-text backend.

  Mirrors `FermixCore.Tools.Media.Backend`'s capability-declaration stance: a
  backend states in `capabilities/0` whether it speaks streaming and whether it
  runs on-device, and the caller dispatches on that declared fact rather than a
  runtime try/fallback. `transcribe/2` (batch file → text) is the only required
  call; `open_stream/2` is `@optional_callbacks` and is required only of a
  backend whose `capabilities().streaming?` is true.

  `FermixCore.Transcription.open_stream/2` is what reads that declaration: a
  streaming backend (Deepgram and xAI natively, the local sidecar on-device)
  gets its own `open_stream/2`, and a batch-only backend is wrapped by
  `FermixCore.Transcription.ChunkedStream`, which segments pushed audio and
  drives `transcribe/2` file by file. Either way the caller talks to one
  session contract — the messages, lifecycle, and error vocabulary documented in
  `FermixCore.Transcription.StreamSession`.
  """

  @typedoc "What a backend can do: whether it speaks streaming, and whether it runs on-device."
  @type capabilities :: %{streaming?: boolean(), local?: boolean()}

  @callback name() :: atom()
  @callback configured?(opts :: keyword()) :: :ok | {:error, term()}
  @callback capabilities() :: capabilities()
  @callback transcribe(path :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Streaming entrypoint (required only when `capabilities().streaming?`). Starts a
  session process that accepts pushed s16le/16 kHz/mono PCM and sends transcript
  segments to `consumer`, per `FermixCore.Transcription.StreamSession`.
  """
  @callback open_stream(consumer :: pid(), opts :: keyword()) ::
              {:ok, pid()} | {:error, term()}

  @optional_callbacks open_stream: 2
end
