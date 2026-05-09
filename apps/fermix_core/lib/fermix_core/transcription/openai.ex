defmodule FermixCore.Transcription.OpenAI do
  @moduledoc false

  require Logger

  alias FermixCore.Net.HttpClient

  @base_url "https://api.openai.com/v1"
  @default_model "whisper-1"

  @spec transcribe(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def transcribe(path, opts \\ []) when is_binary(path) do
    case {resolve_token(opts), multipart_fields(path, opts)} do
      {{:ok, token}, {:ok, fields}} ->
        url = "#{base_url()}/audio/transcriptions"

        result =
          Req.new(url: url, method: :post, form_multipart: fields)
          |> Req.Request.put_header("authorization", "Bearer #{token}")
          |> Req.merge(Keyword.get(opts, :req_options, []))
          |> HttpClient.request("OpenAI Whisper")

        handle_response(result)

      {{:error, reason}, _fields} ->
        {:error, reason}

      {_token, {:error, reason}} ->
        {:error, reason}
    end
  end

  defp handle_response({:ok, %Req.Response{status: 200, body: %{"text" => text}}})
       when is_binary(text) do
    {:ok, text}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    Logger.error("OpenAI transcription failed: #{status} - #{inspect(body)}")
    {:error, "OpenAI transcription error: #{status}"}
  end

  defp handle_response({:error, reason}) do
    Logger.error("OpenAI transcription request failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp multipart_fields(path, opts) do
    with {:ok, stat} <- File.stat(path) do
      mime_type = infer_mime_type(path, opts)
      filename = Path.basename(path)

      {:ok,
       [
         model: model(),
         file:
           {File.stream!(path, 64_000, []),
            filename: filename, content_type: mime_type, size: stat.size}
       ]}
    end
  end

  defp infer_mime_type(path, opts) do
    opts
    |> Keyword.get(:metadata, %{})
    |> Map.get(:attachment, %{})
    |> then(fn attachment ->
      Map.get(attachment, :mime_type) || Map.get(attachment, "mime_type") ||
        mime_from_extension(path)
    end)
  end

  defp mime_from_extension(path) do
    case Path.extname(path) do
      ".ogg" -> "audio/ogg"
      ".mp3" -> "audio/mpeg"
      ".wav" -> "audio/wav"
      ".m4a" -> "audio/mp4"
      ".webm" -> "audio/webm"
      _ -> "application/octet-stream"
    end
  end

  defp resolve_token(opts) do
    case auth_mode(opts) do
      :api_key ->
        api_key_token(opts)

      other ->
        {:error, {:unsupported_auth_mode, other}}
    end
  end

  defp api_key_token(opts) do
    case api_key(opts) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :not_configured}
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

  defp api_key(opts) do
    Keyword.get_lazy(opts, :api_key, fn ->
      case FermixCore.Config.provider_api_key(:openai) do
        {:ok, key} -> key
        {:error, _reason} -> nil
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
    Application.get_env(:fermix_core, :transcription, [])
    |> Keyword.get(:model, @default_model)
  end
end
