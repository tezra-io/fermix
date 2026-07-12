defmodule FermixCore.Transcription.Backend do
  @moduledoc """
  Behaviour for a single speech-to-text backend.

  Mirrors `FermixCore.Tools.Media.Backend`'s capability-declaration stance: a
  backend states in `capabilities/0` whether it speaks streaming and whether it
  runs on-device, and the caller dispatches on that declared fact rather than a
  runtime try/fallback. `transcribe/2` (batch file → text) is the only required
  call in this phase; `open_stream/2` is `@optional_callbacks` and is required
  only of a backend whose `capabilities().streaming?` is true — the streaming
  session (meetings/dictation, a later milestone phase) never calls it otherwise.
  No backend implements `open_stream/2` yet.
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
  session process that accepts pushed PCM and sends transcript segments to
  `consumer`. Unimplemented in every backend this phase.
  """
  @callback open_stream(consumer :: pid(), opts :: keyword()) ::
              {:ok, pid()} | {:error, term()}

  @optional_callbacks open_stream: 2
end
