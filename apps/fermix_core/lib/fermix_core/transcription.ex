defmodule FermixCore.Transcription do
  @moduledoc """
  Speech-to-text engine: dispatches an audio file to the configured backend
  (default `FermixCore.Transcription.OpenAI`).

  Channel-agnostic. The ingress orchestration that decides *when* to transcribe
  an inbound message — detecting an audio attachment, downloading it through the
  channel, and forwarding the transcript — lives in
  `FermixChannels.Gateway.Transcription`.
  """

  @type backend :: module()

  @spec transcribe(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def transcribe(path, opts \\ []) when is_binary(path) do
    backend = Keyword.get(opts, :backend, default_backend())
    backend.transcribe(path, opts)
  end

  @spec default_backend() :: backend()
  def default_backend do
    :fermix_core
    |> Application.get_env(:transcription, [])
    |> Keyword.get(:backend, FermixCore.Transcription.OpenAI)
  end
end
