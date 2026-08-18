defmodule FermixCore.Transcription.Deepgram do
  @moduledoc """
  Deepgram transcription backend (`nova-3` by default), batch and native
  streaming.

  Deepgram's pre-recorded endpoint takes the raw audio as the request body:
  `POST /v1/listen?model=<model>&smart_format=true` with `Authorization: Token
  <key>` and the audio's own content type (`smart_format` is requested so the
  transcript is punctuated/capitalized like the OpenAI/xAI backends, rather than
  Deepgram's default unpunctuated word stream). The transcript is read from
  `results.channels[0].alternatives[0].transcript`. The key is the dedicated
  `[fermix_core.transcription] deepgram_api_key` block key (Deepgram is not a chat
  provider, so there is nothing to reuse); a missing key fails loud as
  `:not_configured`.

  The model comes from the caller's `model:` opt when it carries one (a caller
  that selected this backend explicitly — a per-meeting override — brings its
  own id, because the shared `[fermix_core.transcription] model` key is snapped
  to the GLOBAL backend's family and a cross-family id is refused), else that
  shared key.

  `capabilities().streaming?` is `true`: `open_stream/2` hands the same key and
  the resolved model to `FermixCore.Transcription.DeepgramStream`, which
  speaks Deepgram's live WebSocket endpoint and serves the
  `FermixCore.Transcription.StreamSession` contract.
  """

  @behaviour FermixCore.Transcription.Backend

  require Logger

  alias FermixCore.Net.HttpClient
  alias FermixCore.Net.TimeoutPolicy
  alias FermixCore.Transcription.DeepgramStream
  alias FermixCore.Transcription.Support

  @base_url "https://api.deepgram.com/v1/listen"
  @default_model "nova-3"
  @provider :deepgram

  @impl true
  @spec name() :: atom()
  def name, do: @provider

  @impl true
  @spec capabilities() :: FermixCore.Transcription.Backend.capabilities()
  def capabilities, do: %{streaming?: true, local?: false}

  @impl true
  @spec configured?(keyword()) :: :ok | {:error, term()}
  def configured?(opts) when is_list(opts) do
    case credential(opts) do
      {:ok, _key} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec transcribe(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def transcribe(path, opts \\ []) when is_binary(path) do
    model = model(opts)

    case credential(opts) do
      {:ok, key} ->
        Support.with_provider_call(@provider, model, opts, fn ->
          post_transcription(path, model, key, opts)
        end)

      {:error, reason} ->
        Support.provider_call_error(@provider, model, opts, reason)
    end
  end

  @impl true
  @spec open_stream(pid(), keyword()) :: {:ok, pid()} | {:error, term()}
  def open_stream(consumer, opts) when is_pid(consumer) and is_list(opts) do
    case credential(opts) do
      {:ok, key} -> DeepgramStream.open(consumer, key, model(opts), opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp post_transcription(path, model, key, opts) do
    case File.read(path) do
      {:ok, bytes} ->
        Req.new(
          url: @base_url,
          method: :post,
          # `smart_format` is off by default at Deepgram, which would return an
          # unpunctuated, uncapitalized word stream — a quality regression versus
          # the OpenAI/xAI backends, which emit punctuated prose. Turn it on so
          # all three backends deliver comparable transcripts.
          params: [model: model, smart_format: true],
          body: bytes,
          receive_timeout: TimeoutPolicy.receive_timeout_for(:transcription)
        )
        |> Req.Request.put_header("authorization", "Token #{key}")
        |> Req.Request.put_header("content-type", Support.infer_mime_type(path, opts))
        |> Req.merge(Keyword.get(opts, :req_options, []))
        |> HttpClient.request("Deepgram transcription")
        |> handle_response()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}),
    do: extract_transcript(body)

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    Logger.error("Deepgram transcription failed: #{status} - #{inspect(body)}")
    {:error, Support.http_error_message(status, body)}
  end

  defp handle_response({:error, reason}) do
    Logger.error("Deepgram transcription request failed: #{inspect(reason)}")
    {:error, Support.network_error_message(reason)}
  end

  defp extract_transcript(%{
         "results" => %{
           "channels" => [%{"alternatives" => [%{"transcript" => transcript} | _]} | _]
         }
       })
       when is_binary(transcript) do
    {:ok, transcript}
  end

  defp extract_transcript(_body) do
    {:error,
     "parser_changed: Deepgram response had no results.channels[0].alternatives[0].transcript"}
  end

  defp credential(opts) do
    with :absent <- Support.opts_key(opts),
         :absent <- Support.block_config_key(:deepgram_api_key) do
      {:error, :not_configured}
    end
  end

  # The caller's `model:` wins over the shared `[fermix_core.transcription]`
  # key: that key is snapped to whichever backend is the GLOBAL choice, so a
  # caller that selected this backend for one job must carry the matching id.
  # A non-binary `model:` matches no clause and raises rather than reaching the
  # API as a bogus id.
  defp model(opts) do
    case Keyword.get(opts, :model) do
      nil -> configured_model()
      model when is_binary(model) -> model
    end
  end

  defp configured_model do
    :fermix_core
    |> Application.get_env(:transcription, [])
    |> Keyword.get(:model, @default_model)
  end
end
