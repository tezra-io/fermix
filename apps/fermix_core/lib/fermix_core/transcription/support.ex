defmodule FermixCore.Transcription.Support do
  @moduledoc """
  Shared helpers for the transcription backends — the analogue of
  `FermixCore.Tools.Media.Support`, narrowed to the speech-to-text domain.

  Two concerns live here:

  1. **Credential resolution.** A hosted backend's key comes from one of a small
     set of valid sources (a dedicated per-backend
     `[fermix_core.transcription] <backend>_api_key` block key, and — for the
     OpenAI/xAI backends — the reused chat-provider key). Each source is checked in
     turn and the first present, non-sentinel value wins; the empty and
     unresolved-`@keyring` sentinels are treated as absent (never sent as a bearer
     token). This is not a Rule #12 fallback — the `opts[:api_key]` seam is the
     same single configured key routed through a test override, and the ordered
     sources are two valid operator setups (a transcription-specific override vs
     the reused chat key), not two paths for one setup.
  2. **Telemetry.** Every backend HTTP round-trip is wrapped in
     `with_provider_call/4`, which times it and emits one `[:fermix, :provider,
     :call]` via the shared emitter — `tokens: %{}` so Opik computes no phantom
     cost, `purpose: :transcription`, and the transcript preview only under
     `capture_content?/0`. A missing-key preflight emits the same errored span via
     `provider_call_error/4`, so the two auth-failure modes are symmetric in the
     trace. A native streaming session is one call in the same vocabulary:
     `emit_stream_call/5` reports it once at its terminal, spanning the whole
     stream.
  """

  require Logger

  alias FermixCore.Config
  alias FermixCore.Providers.Telemetry, as: ProviderTelemetry
  alias FermixCore.Telemetry

  # Cap on the vendor error string folded into a `provider_error` message, so a
  # giant HTML error page never floods a trace.
  @max_error_detail 200

  @doc "The `opts[:api_key]` test/override seam, or `:absent` for a blank/`@keyring` sentinel."
  @spec opts_key(keyword()) :: {:ok, String.t()} | :absent
  def opts_key(opts) when is_list(opts), do: sentinel(Keyword.get(opts, :api_key))

  @doc "A reused chat-provider API key, or `:absent` when that provider is unconfigured."
  @spec provider_key(atom()) :: {:ok, String.t()} | :absent
  def provider_key(provider) when is_atom(provider) do
    case Config.provider_api_key(provider) do
      {:ok, key} -> sentinel(key)
      {:error, _reason} -> :absent
    end
  end

  @doc "The `[fermix_core.transcription] <sub_key>` block key, or `:absent` when unset."
  @spec block_config_key(atom()) :: {:ok, String.t()} | :absent
  def block_config_key(sub_key) when is_atom(sub_key) do
    :fermix_core
    |> Application.get_env(:transcription, [])
    |> Keyword.get(sub_key)
    |> sentinel()
  end

  defp sentinel(value) when is_binary(value) and value not in ["", "@keyring"], do: {:ok, value}
  defp sentinel(_value), do: :absent

  @doc """
  Times `fun` (the backend's HTTP round trip) and emits one `[:fermix, :provider,
  :call]` event for it, then returns `fun`'s result unchanged. Modeled on
  `Media.Support.with_provider_call/5` but for the 2-tuple transcription result:
  `tokens: %{}` (no phantom cost), `adapter: provider` (so the Opik span is the
  adapter-qualified `llm:<provider>:<model>`), `purpose: :transcription`, and on a
  failure `:error_code`/`:error_summary` so the span is flagged red. The failure
  is visible in three places — the log, the errored span, and the caller — never
  silent.
  """
  @spec with_provider_call(atom(), String.t(), keyword(), (-> result)) :: result
        when result: {:ok, String.t()} | {:error, term()}
  def with_provider_call(provider, model, opts, fun)
      when is_atom(provider) and is_binary(model) and is_list(opts) and is_function(fun, 0) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    duration_ms = System.monotonic_time(:millisecond) - start
    emit(provider, model, opts, result, duration_ms)
    result
  end

  @doc """
  Emits a provider-call span for a credential-preflight failure where no HTTP
  request was made (a missing/unresolved key), then returns `{:error, reason}`.
  Routes through `with_provider_call/4` so a missing key produces the SAME errored
  span as a key the vendor rejected.
  """
  @spec provider_call_error(atom(), String.t(), keyword(), term()) :: {:error, term()}
  def provider_call_error(provider, model, opts, reason)
      when is_atom(provider) and is_binary(model) and is_list(opts) do
    with_provider_call(provider, model, opts, fn -> {:error, reason} end)
  end

  @doc """
  Emits the single provider-call span a native streaming session reports at its
  terminal (closed, error, or abort).

  Same metadata shape as `with_provider_call/4` — one span per stream lifetime,
  `duration_ms` being the stream's wall time and `result` being
  `{:ok, preview}` (the bounded concatenation of its segment texts) or
  `{:error, reason}`. A stream is one provider call as far as cost and latency
  are concerned; the chunked adapter emits nothing at this level because its
  per-segment batch spans already account for every call it makes.
  """
  @spec emit_stream_call(
          atom(),
          String.t(),
          keyword(),
          {:ok, String.t()} | {:error, term()},
          non_neg_integer()
        ) :: :ok
  def emit_stream_call(provider, model, opts, result, duration_ms)
      when is_atom(provider) and is_binary(model) and is_list(opts) and is_integer(duration_ms) and
             duration_ms >= 0 do
    emit(provider, model, opts, result, duration_ms)
    :ok
  end

  defp emit(provider, model, opts, result, duration_ms) do
    metadata =
      %{
        provider: provider,
        adapter: provider,
        model: model,
        status: status(result),
        tokens: %{},
        reasoning_effort: nil,
        purpose: :transcription
      }
      |> put_error_metadata(result)

    log_failure(provider, model, result)
    ProviderTelemetry.emit_call(metadata, duration_ms, telemetry_opts(opts, result))
  end

  defp status({:ok, text}) when is_binary(text), do: :ok
  defp status(_error), do: :error

  defp put_error_metadata(metadata, {:error, reason}) do
    {code, summary} = error_info(reason)

    metadata
    |> Map.put(:error_code, code)
    |> Map.put(:error_summary, summary)
  end

  defp put_error_metadata(metadata, _ok), do: metadata

  # Maps a backend error reason to a `{tag, summary}` for the span. Tagged strings
  # (auth_failed/rate_limited/provider_error/network) split on their leading tag;
  # the gateway's not-configured atoms map to the shared auth_failed class.
  defp error_info(:not_configured), do: {"auth_failed", "transcription backend is not configured"}

  defp error_info({:unsupported_auth_mode, mode}),
    do: {"auth_failed", "unsupported auth mode: #{inspect(mode)}"}

  defp error_info(reason) when is_binary(reason), do: {error_tag(reason), reason}
  defp error_info(reason), do: {"provider_error", inspect(reason)}

  defp error_tag(reason), do: reason |> String.split(":", parts: 2) |> hd() |> String.trim()

  defp log_failure(_provider, _model, {:ok, _text}), do: :ok

  defp log_failure(provider, model, {:error, reason}) do
    Logger.warning(
      "transcription provider call failed: #{inspect(reason)} (provider=#{provider} model=#{model})"
    )
  end

  defp telemetry_opts(opts, result) do
    opts
    |> Telemetry.correlation_from_opts()
    |> Map.to_list()
    |> Keyword.merge(output: output_preview(result))
  end

  defp output_preview({:ok, text}) when is_binary(text), do: text
  defp output_preview({:error, reason}), do: elem(error_info(reason), 1)

  @doc """
  Maps a non-2xx provider response to a one-line, tagged error string shared by
  every transcription backend: `auth_failed` (401/403), `rate_limited` (429), else
  `provider_error` with the vendor message folded in. Keeps the error vocabulary
  identical across OpenAI/xAI/Deepgram.
  """
  @spec http_error_message(non_neg_integer(), term()) :: String.t()
  def http_error_message(status, _body) when status in [401, 403],
    do: "auth_failed: HTTP #{status}"

  def http_error_message(429, _body), do: "rate_limited: HTTP 429"

  def http_error_message(status, body) when is_integer(status),
    do: "provider_error: HTTP #{status}#{error_detail(body)}"

  @doc "Maps a transport failure to the shared `network`-tagged error string."
  @spec network_error_message(term()) :: String.t()
  def network_error_message(reason), do: "network: #{inspect(reason)}"

  # OpenAI/xAI nest the message under `error.message`; Deepgram returns a flat
  # `err_msg`. All shapes are surfaced; anything else folds in nothing.
  defp error_detail(%{"error" => %{"message" => message}}) when is_binary(message),
    do: ": " <> truncate(message)

  defp error_detail(%{"error" => message}) when is_binary(message), do: ": " <> truncate(message)

  defp error_detail(%{"err_msg" => message}) when is_binary(message),
    do: ": " <> truncate(message)

  defp error_detail(_body), do: ""

  defp truncate(message) do
    if String.length(message) <= @max_error_detail,
      do: message,
      else: String.slice(message, 0, @max_error_detail) <> "…"
  end

  @doc """
  Builds the `form_multipart` fields for an OpenAI-compatible
  `/audio/transcriptions` request (used by the OpenAI backend): the
  requested `model` plus the audio file streamed from disk with a MIME type
  inferred from the attachment metadata (or the file extension).
  """
  @spec multipart_fields(String.t(), String.t(), keyword()) ::
          {:ok, keyword()} | {:error, term()}
  def multipart_fields(path, model, opts)
      when is_binary(path) and is_binary(model) and is_list(opts) do
    with {:ok, stat} <- File.stat(path) do
      mime_type = infer_mime_type(path, opts)

      {:ok,
       [
         model: model,
         file:
           {File.stream!(path, 64_000, []),
            filename: Path.basename(path), content_type: mime_type, size: stat.size}
       ]}
    end
  end

  @doc "Infers an audio/video MIME type from the attachment metadata in `opts`, or the file extension."
  @spec infer_mime_type(String.t(), keyword()) :: String.t()
  def infer_mime_type(path, opts) when is_binary(path) and is_list(opts) do
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
      ".mp4" -> "video/mp4"
      ".webm" -> "audio/webm"
      _ -> "application/octet-stream"
    end
  end
end
