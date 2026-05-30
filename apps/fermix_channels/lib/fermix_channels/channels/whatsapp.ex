defmodule FermixChannels.Channels.WhatsApp do
  @moduledoc """
  WhatsApp Cloud API channel integration.

  Handles Cloud API webhook verification/parsing and text replies via the Graph
  API. Media messages are normalized into attachment metadata and can be
  downloaded on demand for the shared transcription pipeline.
  """

  @behaviour FermixChannels.Gateway.Channel

  require Logger

  alias FermixChannels.Gateway.Idempotency
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.RetryHint
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixCore.Net.HttpClient
  alias FermixCore.Telemetry

  @graph_api_base "https://graph.facebook.com"
  @default_graph_version "v19.0"
  # Free-form Cloud API text messages. Templates and interactive message
  # fields have separate platform limits and should stay adapter-local.
  @max_text_length 4_096
  # Audit F-06: cap media downloads so a hostile or buggy upstream can't
  # exhaust memory/disk. 25 MB is the practical ceiling for WhatsApp's
  # own media types; anything larger is rejected before the body lands
  # in memory or on tmp.
  @max_media_bytes 25 * 1_024 * 1_024
  @outbound_caps %{
    image: 5 * 1_024 * 1_024,
    audio: 16 * 1_024 * 1_024,
    video: 16 * 1_024 * 1_024,
    voice: 16 * 1_024 * 1_024,
    document: 100 * 1_024 * 1_024
  }
  @mime_by_extension %{
    ".gif" => "image/gif",
    ".jpeg" => "image/jpeg",
    ".jpg" => "image/jpeg",
    ".mp3" => "audio/mpeg",
    ".mp4" => "video/mp4",
    ".ogg" => "audio/ogg",
    ".pdf" => "application/pdf",
    ".png" => "image/png"
  }

  @impl true
  @spec parse_webhook(map()) ::
          {:ok, [FermixChannels.Gateway.Channel.message()]} | {:error, term()}
  def parse_webhook(params) do
    {result, duration_us} = Telemetry.timed_us(fn -> do_parse_webhook(params) end)
    ChannelTelemetry.emit_parse(:whatsapp, result, duration_us)
    maybe_emit_inbound_message(result, duration_us)
    result
  end

  defp do_parse_webhook(params) do
    messages =
      if ingress_enabled?() do
        params
        |> Map.get("entry", [])
        |> Enum.flat_map(&parse_entry/1)
      else
        []
      end

    {:ok, messages}
  end

  @spec verify_challenge(map()) :: {:ok, String.t()} | {:error, term()}
  def verify_challenge(params) when is_map(params) do
    with {:ok, expected} <- fetch_config_value(:verify_token),
         "subscribe" <- Map.get(params, "hub.mode"),
         provided when is_binary(provided) <- Map.get(params, "hub.verify_token"),
         true <- secure_compare(provided, expected),
         challenge when is_binary(challenge) <- Map.get(params, "hub.challenge") do
      {:ok, challenge}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_token}
    end
  end

  @impl true
  @spec send_message(String.t(), String.t()) :: :ok | {:error, term()}
  @spec send_message(String.t(), String.t(), FermixChannels.Gateway.Channel.send_opts()) ::
          :ok | {:error, term()}
  def send_message(to, text, opts \\ []) when is_binary(to) and is_binary(text) do
    with :ok <- enforce_text_cap(text),
         {:ok, config} <- send_config(opts) do
      url = "#{@graph_api_base}/#{config.graph_version}/#{config.phone_number_id}/messages"

      body = %{
        messaging_product: "whatsapp",
        recipient_type: "individual",
        to: to,
        type: "text",
        text: %{preview_url: false, body: text}
      }

      {result, duration_us} =
        Telemetry.timed_us(fn ->
          Req.new(url: url, method: :post, json: body, auth: {:bearer, config.access_token})
          |> Req.merge(config.req_options)
          |> HttpClient.request("WhatsApp send")
        end)

      handle_send_response(result, duration_us)
    end
  end

  @impl true
  @spec send_media(String.t(), FermixChannels.Gateway.Channel.media_part()) ::
          :ok | {:error, term()}
  @spec send_media(
          String.t(),
          FermixChannels.Gateway.Channel.media_part(),
          FermixChannels.Gateway.Channel.send_opts()
        ) ::
          :ok | {:error, term()}
  def send_media(to, media_part, opts \\ []) when is_binary(to) and is_map(media_part) do
    with {:ok, claim} <- Idempotency.claim_outbound_media(:whatsapp, to, media_part) do
      send_claimed_media(claim, to, media_part, opts)
    end
  end

  @impl true
  @spec build_text_reply(FermixChannels.Gateway.Channel.message()) :: (String.t() ->
                                                                         :ok | {:error, term()})
  def build_text_reply(%Message{reply_target: reply_target}) do
    fn text -> send_message(reply_target, text, []) end
  end

  @impl true
  @spec build_media_reply(FermixChannels.Gateway.Channel.message()) ::
          (FermixChannels.Gateway.Channel.media_part() -> :ok | {:error, term()})
  def build_media_reply(%Message{reply_target: reply_target}) do
    fn media_part -> send_media(reply_target, media_part, []) end
  end

  @impl true
  @spec download_attachment(FermixChannels.Gateway.Channel.message(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def download_attachment(_message, attachment) when is_map(attachment) do
    with :ok <- preflight_size_cap(attachment),
         {:ok, access_token} <- fetch_config_value(:access_token),
         {:ok, media_url} <- media_url(attachment, access_token),
         {:ok, body} <- download_media(media_url, access_token),
         {:ok, path} <- write_temp_file(body, attachment) do
      {:ok, path}
    end
  end

  defp preflight_size_cap(attachment) do
    case attachment_value(attachment, :size_bytes) do
      size when is_integer(size) and size > @max_media_bytes ->
        {:error,
         "WhatsApp media #{size} bytes exceeds the #{@max_media_bytes}-byte cap; not downloading"}

      _ ->
        :ok
    end
  end

  @impl true
  @spec verify_webhook(Plug.Conn.t()) :: :ok | {:error, term()}
  def verify_webhook(conn) do
    with {:ok, app_secret} <- fetch_config_value(:app_secret),
         {:ok, raw_body} <- raw_body(conn),
         {:ok, signature} <- signature_header(conn) do
      expected = hmac_signature(app_secret, raw_body)

      if secure_compare(signature, expected) do
        :ok
      else
        {:error, :invalid_signature}
      end
    end
  end

  defp parse_entry(entry) do
    entry
    |> Map.get("changes", [])
    |> Enum.flat_map(&parse_change/1)
  end

  defp parse_change(%{"value" => value}) when is_map(value) do
    contacts = contacts_by_wa_id(Map.get(value, "contacts", []))
    phone_number_id = get_in(value, ["metadata", "phone_number_id"])

    value
    |> Map.get("messages", [])
    |> Enum.flat_map(&parse_message(&1, contacts, phone_number_id))
  end

  defp parse_change(_change), do: []

  # Ingress authorization is centralized in the gateway dispatcher; the adapter
  # parses every message and records the sender id in metadata for the gateway.
  defp parse_message(message, contacts, phone_number_id) do
    [build_message(message, contacts, phone_number_id)]
  end

  defp build_message(message, contacts, phone_number_id) do
    sender_id = Map.fetch!(message, "from")
    type = Map.get(message, "type", "unknown")

    Message.new!(%{
      id: to_string(Map.fetch!(message, "id")),
      content: content(message, type),
      sender: sender_name(sender_id, contacts),
      channel: "whatsapp",
      chat_id: sender_id,
      reply_target: sender_id,
      metadata: %{
        phone_number_id: phone_number_id,
        sender_id: sender_id,
        user_id: sender_id,
        chat_type: "private",
        timestamp: Map.get(message, "timestamp"),
        message_type: type
      },
      attachments: attachments(message, type)
    })
  end

  defp content(%{"text" => %{"body" => text}}, "text") when is_binary(text), do: text

  defp content(message, type) do
    case get_in(message, [type, "caption"]) do
      caption when is_binary(caption) -> caption
      _ -> ""
    end
  end

  defp attachments(message, type) when type in ["audio", "voice", "image", "document", "file"] do
    media = Map.get(message, type, %{})

    [
      %{
        kind: attachment_kind(type),
        url: Map.get(media, "url"),
        mime_type: Map.get(media, "mime_type"),
        file_id: Map.get(media, "id"),
        size_bytes: Map.get(media, "size")
      }
    ]
  end

  defp attachments(_message, _type), do: []

  defp attachment_kind(type) when type in ["audio", "voice"], do: :audio
  defp attachment_kind("image"), do: :image
  defp attachment_kind(_type), do: :file

  defp contacts_by_wa_id(contacts) when is_list(contacts) do
    Map.new(contacts, fn contact ->
      {Map.get(contact, "wa_id"), get_in(contact, ["profile", "name"])}
    end)
  end

  defp sender_name(sender_id, contacts) do
    case Map.get(contacts, sender_id) do
      name when is_binary(name) and name != "" -> name
      _ -> sender_id
    end
  end

  defp ingress_enabled? do
    case FermixCore.Config.channel(:whatsapp) do
      {:ok, config} -> Keyword.get(config, :enabled, false) == true
      _ -> false
    end
  end

  defp send_config(opts) do
    with {:ok, access_token} <- fetch_config_value(:access_token),
         {:ok, phone_number_id} <- fetch_config_value(:phone_number_id) do
      {:ok,
       %{
         access_token: access_token,
         phone_number_id: phone_number_id,
         graph_version: graph_version(),
         req_options: req_options(opts)
       }}
    end
  end

  defp validate_outbound_media(%{kind: kind, path: path} = media_part) when is_binary(path) do
    with cap when is_integer(cap) <- Map.get(@outbound_caps, kind),
         {:ok, stat} <- File.stat(path),
         :ok <- enforce_outbound_cap(stat.size, cap, kind),
         :ok <- validate_voice_mime(kind, Map.get(media_part, :mime_type)) do
      {:ok, stat}
    else
      nil -> {:error, {:unsupported_media_kind, kind}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_outbound_media(_media_part), do: {:error, :invalid_media_part}

  defp send_claimed_media(:duplicate, _to, _media_part, _opts), do: :ok

  defp send_claimed_media({:fresh, claim}, to, media_part, opts) do
    result =
      with {:ok, config} <- send_config(opts),
           {:ok, stat} <- validate_outbound_media(media_part),
           {:ok, media_id} <- upload_outbound_media(media_part, stat, config) do
        send_media_message(to, media_part, media_id, config)
      end

    maybe_release_claim(result, claim)
  end

  defp upload_outbound_media(%{path: path} = media_part, stat, config) do
    url = "#{@graph_api_base}/#{config.graph_version}/#{config.phone_number_id}/media"
    filename = Map.get(media_part, :filename) || Path.basename(path)
    mime_type = Map.get(media_part, :mime_type) || mime_from_path(path)

    fields = [
      messaging_product: "whatsapp",
      file:
        {File.stream!(path, 64_000, []),
         filename: filename, content_type: mime_type, size: stat.size}
    ]

    result =
      Req.new(
        url: url,
        method: :post,
        form_multipart: fields,
        auth: {:bearer, config.access_token}
      )
      |> Req.merge(config.req_options)
      |> HttpClient.request("WhatsApp media upload")

    case result do
      {:ok, %{status: status, body: %{"id" => id}}} when status in [200, 201] ->
        {:ok, id}

      {:ok, %{status: status, body: body}} ->
        Logger.error("WhatsApp media upload failed: #{status} - #{inspect(body)}")
        {:error, "WhatsApp media upload error: #{status}"}

      {:error, reason} ->
        Logger.error("WhatsApp media upload request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp send_media_message(to, media_part, media_id, config) do
    wa_type = whatsapp_media_type(media_part.kind)

    body =
      %{
        messaging_product: "whatsapp",
        recipient_type: "individual",
        to: to,
        type: wa_type
      }
      |> Map.put(wa_type, media_payload(wa_type, media_part, media_id))

    {result, duration_us} =
      Telemetry.timed_us(fn ->
        Req.new(
          url: "#{@graph_api_base}/#{config.graph_version}/#{config.phone_number_id}/messages",
          method: :post,
          json: body,
          auth: {:bearer, config.access_token}
        )
        |> Req.merge(config.req_options)
        |> HttpClient.request("WhatsApp send media")
      end)

    handle_send_response(result, duration_us)
  end

  defp media_payload(wa_type, media_part, media_id) do
    payload = %{id: media_id}

    if wa_type in ["image", "video", "document"] do
      payload
      |> maybe_put_caption(Map.get(media_part, :caption))
      |> maybe_put_filename(wa_type, Map.get(media_part, :filename))
    else
      payload
    end
  end

  defp whatsapp_media_type(:voice), do: "audio"
  defp whatsapp_media_type(kind), do: Atom.to_string(kind)

  defp enforce_outbound_cap(size, cap, _kind) when size <= cap, do: :ok

  defp enforce_outbound_cap(size, cap, _kind) do
    {:error, {:byte_cap_exceeded, size, cap}}
  end

  defp enforce_text_cap(text) do
    length = String.length(text)

    if length <= @max_text_length do
      :ok
    else
      {:error, {:text_cap_exceeded, length, @max_text_length}}
    end
  end

  defp validate_voice_mime(:voice, "audio/ogg; codecs=opus"), do: :ok

  defp validate_voice_mime(:voice, _mime) do
    {:error, "WhatsApp voice attachments must be audio/ogg; codecs=opus"}
  end

  defp validate_voice_mime(_kind, _mime), do: :ok

  defp maybe_put_caption(payload, nil), do: payload
  defp maybe_put_caption(payload, caption), do: Map.put(payload, :caption, caption)

  defp maybe_put_filename(payload, "document", filename)
       when is_binary(filename) and filename != "" do
    Map.put(payload, :filename, filename)
  end

  defp maybe_put_filename(payload, _wa_type, _filename), do: payload

  defp maybe_release_claim(:ok, _claim), do: :ok

  defp maybe_release_claim({:error, _reason} = error, claim) do
    :ok = Idempotency.release_outbound_media_claim(claim)
    error
  end

  defp mime_from_path(path) do
    Map.get(@mime_by_extension, Path.extname(path), "application/octet-stream")
  end

  defp media_url(attachment, access_token) do
    case attachment_value(attachment, :url) do
      url when is_binary(url) and url != "" ->
        {:ok, url}

      _ ->
        resolve_media_url(attachment_value(attachment, :file_id), access_token)
    end
  end

  defp resolve_media_url(file_id, access_token) when is_binary(file_id) and file_id != "" do
    url = "#{@graph_api_base}/#{graph_version()}/#{file_id}"

    result =
      Req.new(url: url, method: :get)
      |> Req.Request.put_header("authorization", "Bearer #{access_token}")
      |> Req.merge(req_options([]))
      |> Req.request()

    case result do
      {:ok, %{status: 200, body: %{"url" => media_url}}} when is_binary(media_url) ->
        {:ok, media_url}

      {:ok, %{status: status, body: body}} ->
        Logger.error("WhatsApp media lookup failed: #{status} - #{inspect(body)}")
        {:error, "WhatsApp media lookup error: #{status}"}

      {:error, reason} ->
        Logger.error("WhatsApp media lookup request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp resolve_media_url(_missing_file_id, _access_token),
    do: {:error, :missing_attachment_reference}

  defp download_media(url, access_token) do
    result =
      Req.new(url: url, method: :get)
      |> Req.Request.put_header("authorization", "Bearer #{access_token}")
      |> Req.merge(req_options([]))
      |> Req.request()

    case result do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        enforce_size_cap(body)

      {:ok, %{status: 200, body: body}} ->
        enforce_size_cap(IO.iodata_to_binary(body))

      {:ok, %{status: status, body: body}} ->
        Logger.error("WhatsApp media download failed: #{status} - #{inspect(body)}")
        {:error, "WhatsApp media download error: #{status}"}

      {:error, reason} ->
        Logger.error("WhatsApp media download request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Audit F-06: cap the in-memory body so a lying upstream can't blow
  # past the size_bytes preflight. Body streaming via Req's `:into`
  # collector is the ideal path, but Req's option validation rejects
  # unknown adapters in test plug mode — we keep the post-receive cap
  # here and rely on `preflight_size_cap/1` to drop oversized payloads
  # before the request even leaves Fermix.
  defp enforce_size_cap(body) when byte_size(body) > @max_media_bytes do
    Logger.error(
      "WhatsApp media download exceeded #{@max_media_bytes}-byte cap; refusing payload"
    )

    {:error, "WhatsApp media download exceeded #{@max_media_bytes}-byte cap"}
  end

  defp enforce_size_cap(body), do: {:ok, body}

  defp write_temp_file(body, attachment) do
    path =
      Path.join(
        System.tmp_dir!(),
        "fermix-whatsapp-#{System.unique_integer([:positive])}#{attachment_extension(attachment)}"
      )

    case File.write(path, body) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp attachment_extension(attachment) do
    attachment
    |> attachment_value(:mime_type)
    |> normalize_extension()
  end

  defp normalize_extension(nil), do: ".bin"

  defp normalize_extension(mime_type) when is_binary(mime_type) do
    mime_type
    |> String.split(";", parts: 2)
    |> hd()
    |> String.split("/", parts: 2)
    |> case do
      [_type, subtype] when subtype != "" ->
        "." <> String.replace(subtype, ~r/[^a-zA-Z0-9]+/, "_")

      _ ->
        ".bin"
    end
  end

  defp attachment_value(attachment, key) when is_map(attachment) do
    Map.get(attachment, key) || Map.get(attachment, Atom.to_string(key))
  end

  defp fetch_config_value(key) do
    with {:ok, config} <- FermixCore.Config.channel(:whatsapp),
         value when is_binary(value) and value != "" <- Keyword.get(config, key) do
      {:ok, value}
    else
      _ -> {:error, :not_configured}
    end
  end

  defp graph_version do
    case FermixCore.Config.channel(:whatsapp) do
      {:ok, config} -> Keyword.get(config, :graph_version, @default_graph_version)
      _ -> @default_graph_version
    end
  end

  defp req_options(opts) do
    case Keyword.fetch(opts, :req_options) do
      {:ok, req_opts} ->
        req_opts

      :error ->
        case FermixCore.Config.channel(:whatsapp) do
          {:ok, config} -> Keyword.get(config, :req_options, [])
          _ -> []
        end
    end
  end

  defp handle_send_response({:ok, %{status: status}}, duration_us) when status in [200, 201] do
    ChannelTelemetry.emit_message(:whatsapp, :outbound, 1, duration_us)
    :ok
  end

  defp handle_send_response({:ok, %{status: status, body: body} = response}, _duration_us) do
    Logger.error("WhatsApp send failed: #{status} - #{inspect(body)}")
    whatsapp_api_error(response)
  end

  defp handle_send_response({:error, reason}, _duration_us) do
    Logger.error("WhatsApp request failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp maybe_emit_inbound_message({:ok, messages}, duration_us) when messages != [] do
    ChannelTelemetry.emit_message(:whatsapp, :inbound, length(messages), duration_us)
  end

  defp maybe_emit_inbound_message(_result, _duration_us), do: :ok

  defp whatsapp_api_error(%{status: status} = response) do
    case RetryHint.retry_after_ms(response) do
      {:ok, retry_after_ms} -> {:error, {:rate_limited, retry_after_ms}}
      :error -> {:error, "WhatsApp API error: #{status}"}
    end
  end

  defp raw_body(conn) do
    case conn.assigns[:raw_body] do
      body when is_binary(body) and body != "" -> {:ok, body}
      _ -> {:error, :missing_raw_body}
    end
  end

  defp signature_header(conn) do
    case Plug.Conn.get_req_header(conn, "x-hub-signature-256") do
      [signature] when is_binary(signature) -> {:ok, signature}
      [] -> {:error, :missing_signature}
      _ -> {:error, :invalid_signature}
    end
  end

  defp hmac_signature(app_secret, raw_body) do
    digest = :crypto.mac(:hmac, :sha256, app_secret, raw_body)
    "sha256=" <> Base.encode16(digest, case: :lower)
  end

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_left, _right), do: false
end
