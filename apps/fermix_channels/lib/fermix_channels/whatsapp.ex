defmodule FermixChannels.WhatsApp do
  @moduledoc """
  WhatsApp Cloud API channel integration.

  Handles Cloud API webhook verification/parsing and text replies via the Graph
  API. Media messages are normalized into attachment metadata and can be
  downloaded on demand for the shared transcription pipeline.
  """

  @behaviour FermixChannels.Channel

  require Logger

  alias FermixChannels.Message
  alias FermixCore.Net.HttpClient

  @graph_api_base "https://graph.facebook.com"
  @default_graph_version "v19.0"

  @impl true
  @spec parse_webhook(map()) :: {:ok, [FermixChannels.Channel.message()]} | {:error, term()}
  def parse_webhook(params) do
    messages =
      if ingress_enabled?() do
        params
        |> Map.get("entry", [])
        |> Enum.flat_map(&parse_entry/1)
      else
        []
      end

    if messages != [] do
      :telemetry.execute(
        [:fermix, :channel, :message],
        %{count: length(messages)},
        %{channel: :whatsapp, direction: :inbound}
      )
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
  @spec send_message(String.t(), String.t(), FermixChannels.Channel.send_opts()) ::
          :ok | {:error, term()}
  def send_message(to, text, opts \\ []) when is_binary(to) and is_binary(text) do
    with {:ok, config} <- send_config(opts) do
      url = "#{@graph_api_base}/#{config.graph_version}/#{config.phone_number_id}/messages"

      body = %{
        messaging_product: "whatsapp",
        recipient_type: "individual",
        to: to,
        type: "text",
        text: %{preview_url: false, body: text}
      }

      result =
        Req.new(url: url, method: :post, json: body, auth: {:bearer, config.access_token})
        |> Req.merge(config.req_options)
        |> HttpClient.request("WhatsApp send")

      handle_send_response(result)
    end
  end

  @impl true
  @spec build_reply(FermixChannels.Channel.message()) :: FermixChannels.Channel.reply_fn()
  def build_reply(%Message{reply_target: reply_target}) do
    fn text -> send_message(reply_target, text, []) end
  end

  @impl true
  @spec download_attachment(FermixChannels.Channel.message(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def download_attachment(_message, attachment) when is_map(attachment) do
    with {:ok, access_token} <- fetch_config_value(:access_token),
         {:ok, media_url} <- media_url(attachment, access_token),
         {:ok, body} <- download_media(media_url, access_token),
         {:ok, path} <- write_temp_file(body, attachment) do
      {:ok, path}
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

  defp parse_message(message, contacts, phone_number_id) do
    sender_id = Map.get(message, "from")

    if authorized_sender?(sender_id) do
      [build_message(message, contacts, phone_number_id)]
    else
      []
    end
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

  defp authorized_sender?(sender_id) do
    allowed = allowed_sender_ids()
    allowed == [] or sender_id in allowed
  end

  defp allowed_sender_ids do
    FermixCore.Config.channel_ingress_user_ids(:whatsapp)
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
        {:ok, body}

      {:ok, %{status: 200, body: body}} ->
        {:ok, IO.iodata_to_binary(body)}

      {:ok, %{status: status, body: body}} ->
        Logger.error("WhatsApp media download failed: #{status} - #{inspect(body)}")
        {:error, "WhatsApp media download error: #{status}"}

      {:error, reason} ->
        Logger.error("WhatsApp media download request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

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

  defp handle_send_response({:ok, %{status: status}}) when status in [200, 201] do
    :telemetry.execute(
      [:fermix, :channel, :message],
      %{count: 1},
      %{channel: :whatsapp, direction: :outbound}
    )

    :ok
  end

  defp handle_send_response({:ok, %{status: status, body: body}}) do
    Logger.error("WhatsApp send failed: #{status} - #{inspect(body)}")
    {:error, "WhatsApp API error: #{status}"}
  end

  defp handle_send_response({:error, reason}) do
    Logger.error("WhatsApp request failed: #{inspect(reason)}")
    {:error, reason}
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
