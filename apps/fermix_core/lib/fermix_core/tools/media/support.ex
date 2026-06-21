defmodule FermixCore.Tools.Media.Support do
  @moduledoc """
  Shared helpers for the media-generation backends and tools — the analogue of
  `web_search/backends/support.ex`, extended for the media domain.

  Covers the cross-backend concerns: resolving a vendor credential, decoding the
  base64 image payload every image provider returns, wrapping the generation HTTP
  call in `[:fermix, :provider, :call]` telemetry (image gen is modeled as a
  provider call, §12), resolving an edit's source image (a sandbox path, or a
  this-turn inbound channel image ingested to the sandbox floor, §7), and writing
  artifact bytes under the workspace sandbox.
  """

  require Logger

  alias FermixCore.Config
  alias FermixCore.Net.HttpClient
  alias FermixCore.Net.TimeoutPolicy
  alias FermixCore.Providers.Telemetry, as: ProviderTelemetry
  alias FermixCore.Sandbox
  alias FermixCore.Telemetry

  # Sandbox action atom for all media reads/writes. A free-form telemetry label
  # (the sandbox vocabulary is open), so write/read deny events are attributable
  # to media generation rather than a generic file op.
  @action :generate_media

  # Hard ceiling on an eagerly-materialized provider image (xAI temp URL, Veo
  # result). Guards the sandbox against an unexpectedly huge download; a trusted
  # provider CDN stays well under this.
  @max_materialize_bytes 25 * 1024 * 1024

  # Cap on the vendor error string folded into a `provider_error` message, so a
  # giant HTML error page never floods a tool result or a trace.
  @max_error_detail 200

  # Hard cap on how many this-turn inbound images an edit may index into. Channel
  # album coalescing already bounds a turn to @default_max_parts (10) attachments,
  # but Rule #2 wants the bound declared and enforced here, at the point of use —
  # not left implicit in each channel's buffer.
  @max_inbound_images 10

  @typedoc "A source image resolved for an edit: bytes in hand plus its MIME and a filename."
  @type source_image :: %{bytes: binary(), mime: String.t(), filename: String.t()}

  @doc """
  Resolves a chat provider's configured API key for reuse by its media backend
  (OpenAI/xAI image reuse the provider key — §11.3). `opts[:api_key]` is honored
  first purely as a test/override seam; it is the same single configured key, not
  a Rule #12 fallback to a second source.
  """
  @spec provider_credential(keyword(), atom(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def provider_credential(opts, provider, label)
      when is_list(opts) and is_atom(provider) and is_binary(label) do
    case Keyword.get(opts, :api_key) do
      key when is_binary(key) and key not in ["", "@keyring"] -> {:ok, key}
      _ -> configured_provider_key(provider, label)
    end
  end

  @doc """
  Resolves a tool-block credential by keyword (the Google path — its key lives in
  `[fermix_core.tools.generate_image]` since Gemini is not a chat provider).
  Rejects the empty and unresolved-`@keyring` sentinels loudly.
  """
  @spec config_credential(keyword(), atom(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def config_credential(opts, key, label)
      when is_list(opts) and is_atom(key) and is_binary(label) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value not in ["", "@keyring"] -> {:ok, value}
      _ -> {:error, "auth_failed: #{label} is not set. Run `fermix setup` to add it."}
    end
  end

  defp configured_provider_key(provider, label) do
    case Config.provider_api_key(provider) do
      {:ok, key} ->
        {:ok, key}

      {:error, _reason} ->
        {:error, "auth_failed: #{label} is not set. Run `fermix setup` to add it."}
    end
  end

  @doc "Decodes a provider base64 image payload to raw bytes, refusing empty/invalid data."
  @spec decode_base64(term()) :: {:ok, binary()} | {:error, String.t()}
  def decode_base64(value) when is_binary(value) and value != "" do
    case Base.decode64(value) do
      {:ok, bytes} when byte_size(bytes) > 0 -> {:ok, bytes}
      {:ok, _empty} -> {:error, "parser_changed: provider returned zero image bytes"}
      :error -> {:error, "parser_changed: provider returned invalid base64 image data"}
    end
  end

  def decode_base64(_value), do: {:error, "parser_changed: provider response had no image data"}

  @doc """
  Times `fun` (the backend's HTTP round trip) and emits one
  `[:fermix, :provider, :call]` event for it, then returns `fun`'s result
  unchanged. The generation call is modeled as a provider call (§12): `tokens: %{}`
  so Opik computes no phantom cost, `output` a byte-size string (never raw bytes),
  correlation pulled from `context` so the span nests under the turn's trace.

  On a failure result the metadata carries `:adapter` (so the Opik span is the
  adapter-qualified `llm:<provider>:<model>`) and `:error_code`/`:error_summary`
  (so the span is flagged red, matching how chat providers surface errors via
  `Providers.Error.telemetry_metadata/1`), and a warning is logged. The failure
  is therefore visible in three places — the log, the errored span, and the tool
  span — never silent.
  """
  @spec with_provider_call(atom(), String.t(), map(), map(), (-> result)) :: result
        when result: {:ok, map(), map()} | {:error, String.t(), map()}
  def with_provider_call(provider, model, request, context, fun)
      when is_atom(provider) and is_binary(model) and is_map(request) and is_map(context) and
             is_function(fun, 0) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    duration_ms = System.monotonic_time(:millisecond) - start

    metadata =
      %{
        provider: provider,
        adapter: provider,
        model: model,
        status: status(result),
        tokens: %{},
        reasoning_effort: nil
      }
      |> maybe_put(:agent, Map.get(context, :agent_name))
      |> put_error_metadata(result)

    log_failure(provider, model, result)
    ProviderTelemetry.emit_call(metadata, duration_ms, telemetry_opts(context, request, result))

    result
  end

  @doc """
  Emits a provider-call span for a credential-preflight failure where no HTTP
  request was made (a missing/unresolved key), then returns the `{:error, reason,
  %{}}` the backend would have returned. Routes through `with_provider_call/5` so
  a missing key produces the SAME errored, adapter-qualified span as a key the
  vendor rejected — the two auth-failure modes are no longer asymmetric in the
  trace. Mirrors the chat path emitting telemetry for a preflight
  `Providers.Error.auth/3` (status nil, no exchange).
  """
  @spec provider_call_error(atom(), String.t(), map(), map(), String.t()) ::
          {:error, String.t(), map()}
  def provider_call_error(provider, model, request, context, reason)
      when is_atom(provider) and is_binary(model) and is_map(request) and is_map(context) and
             is_binary(reason) do
    with_provider_call(provider, model, request, context, fn -> {:error, reason, %{}} end)
  end

  defp status({:ok, _artifact, _trace}), do: :ok
  defp status(_error), do: :error

  # The shared media error strings are "tag: detail" (auth_failed: HTTP 401,
  # rate_limited: HTTP 429, network: ..., provider_error: HTTP 500: ...,
  # parser_changed: ...). The tag becomes the span's error_info exception_type so
  # Opik flags and groups the failure like a chat-provider error.
  defp put_error_metadata(metadata, {:error, reason, _trace}) when is_binary(reason) do
    metadata
    |> Map.put(:error_code, error_tag(reason))
    |> Map.put(:error_summary, reason)
  end

  defp put_error_metadata(metadata, _ok), do: metadata

  defp error_tag(reason) do
    reason |> String.split(":", parts: 2) |> hd() |> String.trim()
  end

  defp log_failure(_provider, _model, {:ok, _artifact, _trace}), do: :ok

  defp log_failure(provider, model, {:error, reason, _trace}) do
    Logger.warning("media provider call failed: #{reason} (provider=#{provider} model=#{model})")
  end

  defp maybe_put(metadata, _key, nil), do: metadata
  defp maybe_put(metadata, key, value), do: Map.put(metadata, key, value)

  defp telemetry_opts(context, request, result) do
    context
    |> Telemetry.correlation()
    |> Map.to_list()
    |> Keyword.merge(input: request_prompt(request), output: output_summary(result))
  end

  defp request_prompt(%{prompt: prompt}) when is_binary(prompt), do: prompt
  defp request_prompt(_request), do: nil

  defp output_summary({:ok, %{bytes: bytes, mime: mime}, _trace}),
    do: "#{mime} #{byte_size(bytes)} bytes"

  defp output_summary({:error, reason, _trace}) when is_binary(reason), do: reason
  defp output_summary(_result), do: nil

  @doc """
  Resolves an edit's source image to bytes-in-hand. A `"inbound:last"` /
  `"inbound:N"` / `"inbound"` reference pulls a this-turn channel image from
  `context.inbound_images` and ingests it to the sandbox floor (so it becomes a
  normal artifact, §7); any other string is a sandbox path read through
  `Sandbox.read_path/3`.
  """
  @spec resolve_edit_image(String.t(), map()) :: {:ok, source_image()} | {:error, String.t()}
  def resolve_edit_image("inbound", context) when is_map(context),
    do: resolve_inbound("last", context)

  def resolve_edit_image("inbound:" <> selector, context) when is_map(context),
    do: resolve_inbound(selector, context)

  def resolve_edit_image(path, context) when is_binary(path) and is_map(context),
    do: resolve_sandbox_path(path, context)

  defp resolve_inbound(selector, context) do
    images = Map.get(context, :inbound_images, [])

    with {:ok, %{mime_type: mime, data: bytes}} <- select_inbound(images, selector),
         {:ok, _abs} <- write_bytes(inbound_rel(mime), bytes, context) do
      {:ok, %{bytes: bytes, mime: mime, filename: "inbound.#{ext_for_mime(mime)}"}}
    end
  end

  defp select_inbound([], _selector),
    do: {:error, "no inbound image is attached to this message to edit"}

  defp select_inbound(images, _selector) when length(images) > @max_inbound_images,
    do:
      {:error,
       "too many inbound images attached (#{length(images)}); maximum is #{@max_inbound_images}"}

  defp select_inbound(images, selector) when selector in ["last", ""],
    do: {:ok, List.last(images)}

  defp select_inbound(images, selector) do
    case Integer.parse(selector) do
      {n, ""} when n >= 1 and n <= length(images) ->
        {:ok, Enum.at(images, n - 1)}

      {_n, ""} ->
        {:error, "inbound image #{selector} is out of range (#{length(images)} attached)"}

      _ ->
        {:error, "invalid inbound reference #{inspect(selector)}; use inbound:last or inbound:N"}
    end
  end

  defp resolve_sandbox_path(path, context) do
    with {:ok, abs} <- read_via_sandbox(path, context),
         {:ok, bytes} <- read_file(abs) do
      {:ok, %{bytes: bytes, mime: image_mime_for_path(abs), filename: Path.basename(abs)}}
    end
  end

  defp read_via_sandbox(path, context) do
    case Sandbox.read_path(path, @action, context) do
      {:ok, abs} -> {:ok, abs}
      {:error, reason} -> {:error, sandbox_error(reason)}
    end
  end

  defp read_file(abs) do
    case File.read(abs) do
      {:ok, bytes} when byte_size(bytes) > 0 -> {:ok, bytes}
      {:ok, _empty} -> {:error, "source image is empty: #{abs}"}
      {:error, reason} -> {:error, "could not read source image: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Writes media bytes to `rel` under the workspace sandbox floor (action
  `:generate_media`), creating the parent directory. Returns the absolute path.
  Used by both `Media.Output` (generated artifacts) and the inbound ingest above.
  """
  @spec write_bytes(String.t(), binary(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def write_bytes(rel, bytes, context)
      when is_binary(rel) and is_binary(bytes) and is_map(context) do
    with {:ok, abs} <- resolve_write_path(rel, context),
         :ok <- ensure_parent_dir(abs),
         :ok <- write_file(abs, bytes) do
      {:ok, abs}
    end
  end

  defp resolve_write_path(rel, context) do
    case Sandbox.write_path(rel, @action, context) do
      {:ok, abs} -> {:ok, abs}
      {:error, reason} -> {:error, sandbox_error(reason)}
    end
  end

  defp ensure_parent_dir(abs) do
    case abs |> Path.dirname() |> File.mkdir_p() do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "could not create media directory: #{:file.format_error(reason)}"}
    end
  end

  defp write_file(abs, bytes) do
    case File.write(abs, bytes) do
      :ok -> :ok
      {:error, reason} -> {:error, "could not write media file: #{:file.format_error(reason)}"}
    end
  end

  defp inbound_rel(mime), do: Path.join("media", "inbound-#{token()}.#{ext_for_mime(mime)}")

  @doc "A short, URL-safe random token for artifact filenames."
  @spec token() :: String.t()
  def token, do: 8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc """
  Eagerly downloads a provider image URL into bytes. Some backends return a
  short-lived URL instead of inline base64 (xAI when `b64_json` is not honored,
  Veo results) and those URLs 404 within minutes (§428) — so the bytes are
  pulled to local storage immediately, before delivery. Streams the body through
  a bounded collector that halts the moment it would exceed the byte cap (so a
  hostile or compromised CDN can never buffer 25 MB+ into the daemon), refuses a
  zero-byte body, and sniffs the image MIME from the bytes rather than trusting
  the response header. `req_options` carries the test plug seam.
  """
  @spec materialize_url(String.t(), keyword()) ::
          {:ok, %{bytes: binary(), mime: String.t()}} | {:error, String.t()}
  def materialize_url(url, req_options \\ []) when is_binary(url) and is_list(req_options) do
    [
      url: url,
      method: :get,
      retry: false,
      decode_body: false,
      receive_timeout: TimeoutPolicy.receive_timeout_for(:media_download),
      into: &stream_body/2
    ]
    |> Req.new()
    |> Req.merge(req_options)
    |> HttpClient.request("materialize media URL")
    |> handle_materialize()
  end

  defp handle_materialize({:ok, %Req.Response{private: %{fermix_body_cap: :too_large}}}),
    do: {:error, "provider_error: image exceeds the #{@max_materialize_bytes}-byte cap"}

  defp handle_materialize({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 and is_binary(body),
       do: validate_materialized(body)

  defp handle_materialize({:ok, %Req.Response{status: status}}),
    do: {:error, "network: image URL returned HTTP #{status}"}

  defp handle_materialize({:error, reason}), do: {:error, network_error_message(reason)}

  # Bounded streaming collector (mirrors web_fetch's stream_body/2): accumulates
  # chunks until the next one would cross @max_materialize_bytes, then flags the
  # response and halts before the over-cap chunk is ever appended — the cap is
  # enforced pre-buffering, not after the whole body lands in memory.
  defp stream_body({:data, data}, {req, %{body: body} = response})
       when is_binary(data) and is_binary(body) do
    if byte_size(body) + byte_size(data) > @max_materialize_bytes do
      {:halt, {req, Req.Response.put_private(response, :fermix_body_cap, :too_large)}}
    else
      {:cont, {req, %{response | body: body <> data}}}
    end
  end

  defp stream_body({:data, data}, {req, response}) when is_binary(data),
    do: stream_body({:data, data}, {req, %{response | body: ""}})

  defp validate_materialized(body) when byte_size(body) == 0,
    do: {:error, "parser_changed: provider image URL returned zero bytes"}

  defp validate_materialized(body), do: {:ok, %{bytes: body, mime: sniff_image_mime(body)}}

  defp sniff_image_mime(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>>), do: "image/png"
  defp sniff_image_mime(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: "image/jpeg"
  defp sniff_image_mime(<<"GIF8", _rest::binary>>), do: "image/gif"

  defp sniff_image_mime(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>),
    do: "image/webp"

  defp sniff_image_mime(_bytes), do: "application/octet-stream"

  @doc """
  Maps a non-2xx provider response to a one-line, tagged error string shared by
  every image backend: `auth_failed` (401/403), `rate_limited` (429), else
  `provider_error` with the vendor message folded in. Keeps the error vocabulary
  identical across OpenAI/xAI/Google so the tool's `failure_modes` tags hold.
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

  # OpenAI/Google nest the message under `error.message`; xAI may return a flat
  # `error` string. Both shapes are surfaced; anything else folds in nothing.
  defp error_detail(%{"error" => %{"message" => message}}) when is_binary(message),
    do: ": " <> truncate(message)

  defp error_detail(%{"error" => message}) when is_binary(message), do: ": " <> truncate(message)
  defp error_detail(_body), do: ""

  defp truncate(message) do
    if String.length(message) <= @max_error_detail,
      do: message,
      else: String.slice(message, 0, @max_error_detail) <> "…"
  end

  @doc "Maps a file path's extension to an image MIME type (octet-stream when unknown)."
  @spec image_mime_for_path(String.t()) :: String.t()
  def image_mime_for_path(path) when is_binary(path) do
    case path |> Path.extname() |> String.downcase() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".webp" -> "image/webp"
      ".gif" -> "image/gif"
      _ -> "application/octet-stream"
    end
  end

  @doc "Maps an image MIME type to a file extension (`bin` when unknown)."
  @spec ext_for_mime(String.t()) :: String.t()
  def ext_for_mime("image/png"), do: "png"
  def ext_for_mime("image/jpeg"), do: "jpg"
  def ext_for_mime("image/webp"), do: "webp"
  def ext_for_mime("image/gif"), do: "gif"
  def ext_for_mime(_mime), do: "bin"

  @doc "Renders a sandbox denial reason (or an already-string reason) as one line."
  @spec sandbox_error(term()) :: String.t()
  def sandbox_error({:protected_path, path}), do: "path is protected by the sandbox: #{path}"
  def sandbox_error({:outside_root, path}), do: "path is outside the sandbox roots: #{path}"
  def sandbox_error({:blocked_root, path}), do: "path is under a blocked root: #{path}"

  def sandbox_error({:too_many_symlinks, path}),
    do: "path resolved through too many symlinks: #{path}"

  def sandbox_error(reason) when is_binary(reason), do: reason
  def sandbox_error(reason), do: "sandbox denied: #{inspect(reason)}"
end
