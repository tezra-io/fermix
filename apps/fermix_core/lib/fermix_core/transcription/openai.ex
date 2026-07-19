defmodule FermixCore.Transcription.OpenAI do
  @moduledoc """
  OpenAI transcription backend (`gpt-4o-mini-transcribe` by default).

  Multipart `POST /v1/audio/transcriptions`, model from
  `[fermix_core.transcription] model`. The key resolves in a deterministic order
  (two valid setups of one credential source, not a Rule #12 fallback): the
  transcription-specific `[fermix_core.transcription] openai_api_key` override if
  set, else the OpenAI chat-provider key. Both are `api_key` auth only; a
  non-`api_key` auth mode is refused loudly (`{:unsupported_auth_mode, _}`), never
  silently degraded. The HTTP round-trip is wrapped in `[:fermix, :provider,
  :call]` telemetry via `Transcription.Support`.
  """

  @behaviour FermixCore.Transcription.Backend

  require Logger

  alias FermixCore.Net.HttpClient
  alias FermixCore.Net.TimeoutPolicy
  alias FermixCore.Transcription.Support

  @base_url "https://api.openai.com/v1"
  @default_model "gpt-4o-mini-transcribe"
  @provider :openai

  @impl true
  @spec name() :: atom()
  def name, do: @provider

  @impl true
  @spec capabilities() :: FermixCore.Transcription.Backend.capabilities()
  def capabilities, do: %{streaming?: false, local?: false}

  @impl true
  @spec configured?(keyword()) :: :ok | {:error, term()}
  def configured?(opts) when is_list(opts) do
    case resolve_token(opts) do
      {:ok, _token} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec transcribe(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def transcribe(path, opts \\ []) when is_binary(path) do
    model = model()

    case resolve_token(opts) do
      {:ok, token} ->
        Support.with_provider_call(@provider, model, opts, fn ->
          post_transcription(path, token, opts)
        end)

      {:error, reason} ->
        Support.provider_call_error(@provider, model, opts, reason)
    end
  end

  defp post_transcription(path, token, opts) do
    case Support.multipart_fields(path, model(), opts) do
      {:ok, fields} ->
        Req.new(
          url: "#{base_url()}/audio/transcriptions",
          method: :post,
          form_multipart: fields,
          receive_timeout: TimeoutPolicy.receive_timeout_for(:transcription)
        )
        |> Req.Request.put_header("authorization", "Bearer #{token}")
        |> Req.merge(Keyword.get(opts, :req_options, []))
        |> HttpClient.request("OpenAI transcription")
        |> handle_response()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: %{"text" => text}}})
       when is_binary(text) do
    {:ok, text}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    Logger.error("OpenAI transcription failed: #{status} - #{inspect(body)}")
    {:error, Support.http_error_message(status, body)}
  end

  defp handle_response({:error, reason}) do
    Logger.error("OpenAI transcription request failed: #{inspect(reason)}")
    {:error, Support.network_error_message(reason)}
  end

  defp resolve_token(opts) do
    case auth_mode(opts) do
      :api_key -> api_key_token(opts)
      other -> {:error, {:unsupported_auth_mode, other}}
    end
  end

  # Key resolution routes through `Support` so the blank and unresolved-`@keyring`
  # sentinels are rejected as `:absent` (never sent as a bearer token) — identical
  # to xAI/Deepgram (§5.1). The `opts[:api_key]` seam wins first, then the
  # transcription-specific `openai_api_key` override, then the reused OpenAI
  # chat-provider key; a missing key fails loud as `:not_configured`.
  defp api_key_token(opts) do
    with :absent <- Support.opts_key(opts),
         :absent <- Support.block_config_key(:openai_api_key),
         :absent <- Support.provider_key(@provider) do
      {:error, :not_configured}
    end
  end

  defp auth_mode(opts) do
    Keyword.get_lazy(opts, :auth_mode, fn ->
      case FermixCore.Config.provider(:openai) do
        {:ok, config} -> Keyword.get(config, :auth_mode, :api_key)
        _ -> :api_key
      end
    end)
  end

  defp base_url do
    case FermixCore.Config.provider(:openai) do
      {:ok, config} -> Keyword.get(config, :base_url, @base_url)
      _ -> @base_url
    end
  end

  defp model do
    :fermix_core
    |> Application.get_env(:transcription, [])
    |> Keyword.get(:model, @default_model)
  end
end
