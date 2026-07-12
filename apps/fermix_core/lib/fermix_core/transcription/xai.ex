defmodule FermixCore.Transcription.XAI do
  @moduledoc """
  SpaceXAI (xAI) speech-to-text backend, native to xAI's `POST /v1/stt` endpoint.

  Unlike the OpenAI backend, xAI STT is **not** OpenAI-compatible: it is
  *modelless* (no `model` form field — the endpoint runs a single STT model),
  takes `format=true` plus an optional `language`, and the audio `file` part must
  come **last** in the multipart body. The transcript is read from the top-level
  `text` field of the JSON response.

  xAI STT **requires an API key**: the Grok subscription OAuth token does not work
  for `/v1/stt` (OAuth covers chat + Grok Imagine only; STT is billed via console
  credits). The key resolves in a deterministic order (two valid setups of one
  credential source, not a Rule #12 fallback): the transcription-specific
  `[fermix_core.transcription] xai_api_key` override if set, else the reused `:xai`
  chat-provider key (which must itself be an api_key, not the OAuth token). A
  missing or sentinel key fails loud as `:not_configured`, never a silent degrade.

  xAI also exposes a `wss` streaming STT endpoint; `capabilities().streaming?` is
  `false` here — native streaming lands with the streaming session in a later
  phase, so today this is a batch-only backend.
  """

  @behaviour FermixCore.Transcription.Backend

  require Logger

  alias FermixCore.Net.HttpClient
  alias FermixCore.Net.TimeoutPolicy
  alias FermixCore.Transcription.Support

  @endpoint "https://api.x.ai/v1/stt"
  @provider :xai

  # xAI STT is modelless — the endpoint runs a single fixed model and rejects a
  # `model` form field, so none is ever sent to the API. This constant is used
  # ONLY as the `[:fermix, :provider, :call]` telemetry span's model tag (the span
  # name becomes `llm:xai:grok-stt`), because the shared emitter requires a binary
  # model. It is a stable label, not an API parameter.
  @telemetry_model "grok-stt"

  @impl true
  @spec name() :: atom()
  def name, do: @provider

  @impl true
  @spec capabilities() :: FermixCore.Transcription.Backend.capabilities()
  def capabilities, do: %{streaming?: false, local?: false}

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
    case credential(opts) do
      {:ok, key} ->
        Support.with_provider_call(@provider, @telemetry_model, opts, fn ->
          post_transcription(path, key, opts)
        end)

      {:error, reason} ->
        Support.provider_call_error(@provider, @telemetry_model, opts, reason)
    end
  end

  defp post_transcription(path, key, opts) do
    case multipart_fields(path, opts) do
      {:ok, fields} ->
        Req.new(
          url: @endpoint,
          method: :post,
          form_multipart: fields,
          receive_timeout: TimeoutPolicy.receive_timeout_for(:transcription)
        )
        |> Req.Request.put_header("authorization", "Bearer #{key}")
        |> Req.merge(Keyword.get(opts, :req_options, []))
        |> HttpClient.request("xAI transcription")
        |> handle_response()

      {:error, reason} ->
        {:error, reason}
    end
  end

  # xAI's multipart shape differs from the OpenAI-compatible one: `format=true`
  # asks for the plain-text transcript, `language` is optional (omitted ⇒ xAI
  # auto-detects), and the audio `file` part must be LAST. No `model` field — the
  # endpoint is modelless.
  defp multipart_fields(path, opts) do
    with {:ok, stat} <- File.stat(path) do
      file_part =
        {File.stream!(path, 64_000, []),
         filename: Path.basename(path),
         content_type: Support.infer_mime_type(path, opts),
         size: stat.size}

      fields =
        [format: "true"]
        |> maybe_language(opts)
        |> Kernel.++(file: file_part)

      {:ok, fields}
    end
  end

  defp maybe_language(fields, opts) do
    case normalize_language(Keyword.get(opts, :language)) do
      nil -> fields
      language -> fields ++ [language: language]
    end
  end

  defp normalize_language(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_language(_value), do: nil

  defp handle_response({:ok, %Req.Response{status: 200, body: %{"text" => text}}})
       when is_binary(text) do
    {:ok, text}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    Logger.error("xAI transcription failed: #{status} - #{inspect(body)}")
    {:error, Support.http_error_message(status, body)}
  end

  defp handle_response({:error, reason}) do
    Logger.error("xAI transcription request failed: #{inspect(reason)}")
    {:error, Support.network_error_message(reason)}
  end

  # The `opts[:api_key]` seam short-circuits for tests, then the
  # transcription-specific `xai_api_key` override, then the reused `:xai`
  # chat-provider key (the same key the image backend reuses). A missing/sentinel
  # key fails loud — the Grok OAuth token is not accepted by `/v1/stt`.
  defp credential(opts) do
    with :absent <- Support.opts_key(opts),
         :absent <- Support.block_config_key(:xai_api_key),
         :absent <- Support.provider_key(@provider) do
      {:error, :not_configured}
    end
  end
end
