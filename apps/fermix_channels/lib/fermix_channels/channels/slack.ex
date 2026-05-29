defmodule FermixChannels.Channels.Slack do
  @moduledoc """
  Slack direct-message and app-mention channel adapter.

  Uses the Events API for signed webhook ingress and `chat.postMessage` for
  outbound replies. Initial M3 scope is limited to DMs and `app_mention`
  events.
  """

  @behaviour FermixChannels.Gateway.Channel

  require Logger

  alias FermixChannels.Gateway.Idempotency
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.RetryHint
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixCore.Net.HttpClient
  alias FermixCore.Telemetry

  @api_base "https://slack.com/api"
  @max_message_length 40_000
  @max_signature_age_seconds 300
  @max_media_bytes 100 * 1_024 * 1_024

  @impl true
  @spec parse_webhook(map()) :: {:ok, [FermixChannels.Gateway.Channel.message()]} | {:error, term()}
  def parse_webhook(payload) do
    {result, duration_us} = Telemetry.timed_us(fn -> do_parse_webhook(payload) end)
    ChannelTelemetry.emit_parse(:slack, result, duration_us)
    maybe_emit_inbound_message(result, duration_us)
    result
  end

  defp do_parse_webhook(%{"type" => "event_callback", "event" => event} = payload)
       when is_map(event) and is_map(payload) do
    messages = if ingress_enabled?(), do: parse_event(event, payload), else: []
    {:ok, messages}
  end

  defp do_parse_webhook(%{"type" => "url_verification"}), do: {:ok, []}
  defp do_parse_webhook(%{"type" => "event_callback"}), do: {:error, :invalid_webhook_payload}
  defp do_parse_webhook(_payload), do: {:ok, []}

  @impl true
  @spec send_message(String.t(), String.t()) :: :ok | {:error, term()}
  @spec send_message(String.t(), String.t(), FermixChannels.Gateway.Channel.send_opts()) ::
          :ok | {:error, term()}
  def send_message(channel_id, text, opts \\ []) when is_binary(channel_id) and is_binary(text) do
    with :ok <- enforce_text_cap(text),
         {:ok, token} <- bot_token() do
      body =
        %{channel: channel_id, text: text}
        |> maybe_put_thread_ts(opts)

      {result, duration_us} =
        Telemetry.timed_us(fn ->
          Req.new(url: "#{@api_base}/chat.postMessage", method: :post, json: body)
          |> Req.Request.put_header("authorization", "Bearer #{token}")
          |> Req.merge(req_options(opts))
          |> HttpClient.request("Slack chat.postMessage")
        end)

      handle_send_response(result, duration_us)
    end
  end

  @impl true
  @spec send_media(String.t(), FermixChannels.Gateway.Channel.media_part()) :: :ok | {:error, term()}
  @spec send_media(String.t(), FermixChannels.Gateway.Channel.media_part(), FermixChannels.Gateway.Channel.send_opts()) ::
          :ok | {:error, term()}
  def send_media(channel_id, media_part, opts \\ [])
      when is_binary(channel_id) and is_map(media_part) do
    with {:ok, claim} <- Idempotency.claim_outbound_media(:slack, channel_id, media_part) do
      send_claimed_media(claim, channel_id, media_part, opts)
    end
  end

  @impl true
  @spec build_text_reply(FermixChannels.Gateway.Channel.message()) :: (String.t() -> :ok | {:error, term()})
  def build_text_reply(%Message{reply_target: reply_target, thread_ts: thread_ts}) do
    opts = if thread_ts, do: [thread_ts: thread_ts], else: []

    fn text -> send_message(reply_target, text, opts) end
  end

  @impl true
  @spec build_media_reply(FermixChannels.Gateway.Channel.message()) ::
          (FermixChannels.Gateway.Channel.media_part() -> :ok | {:error, term()})
  def build_media_reply(%Message{reply_target: reply_target, thread_ts: thread_ts}) do
    opts = if thread_ts, do: [thread_ts: thread_ts], else: []

    fn media_part -> send_media(reply_target, media_part, opts) end
  end

  @impl true
  @spec verify_webhook(Plug.Conn.t()) :: :ok | {:error, term()}
  def verify_webhook(conn) do
    with {:ok, signing_secret} <- signing_secret(),
         {:ok, raw_body} <- raw_body(conn),
         {:ok, timestamp} <- timestamp_header(conn),
         :ok <- verify_timestamp(timestamp),
         {:ok, signature} <- signature_header(conn) do
      expected = request_signature(signing_secret, timestamp, raw_body)

      if secure_compare(signature, expected) do
        :ok
      else
        {:error, :invalid_signature}
      end
    end
  end

  @doc false
  @spec url_verification_challenge(map()) ::
          {:ok, String.t()} | :ignore | {:error, :invalid_webhook_payload}
  def url_verification_challenge(%{"type" => "url_verification", "challenge" => challenge})
      when is_binary(challenge) and challenge != "" do
    {:ok, challenge}
  end

  def url_verification_challenge(%{"type" => "url_verification"}),
    do: {:error, :invalid_webhook_payload}

  def url_verification_challenge(_payload), do: :ignore

  defp parse_event(event, payload) do
    if process_event?(event) do
      [build_message(event, payload)]
    else
      []
    end
  end

  defp process_event?(event) do
    not bot_event?(event) and authorized_sender?(event) and
      (direct_message_event?(event) or app_mention_event?(event))
  end

  defp direct_message_event?(%{"type" => "message", "channel_type" => "im"} = event) do
    Map.get(event, "subtype") in [nil, ""]
  end

  defp direct_message_event?(_event), do: false

  defp app_mention_event?(%{"type" => "app_mention"}), do: true
  defp app_mention_event?(_event), do: false

  defp bot_event?(event) do
    is_binary(Map.get(event, "bot_id")) or Map.get(event, "subtype") == "bot_message"
  end

  defp authorized_sender?(event) do
    {allowed?, duration_us} =
      Telemetry.timed_us(fn ->
        # Audit F-02: empty allowlist denies everyone. Operators must configure
        # owner_user_id (auto-populates the allowlist) or set
        # fermix_channels.slack.allowed_user_ids explicitly.
        user_id = Map.get(event, "user")
        user_id in allowed_user_ids()
      end)

    ChannelTelemetry.emit_authorize(:slack, allowed?, duration_us)
    allowed?
  end

  defp build_message(event, payload) do
    channel_id = Map.fetch!(event, "channel")

    Message.new!(%{
      id: Map.fetch!(event, "ts"),
      content: content(event),
      sender: sender_name(event),
      channel: "slack",
      chat_id: channel_id,
      reply_target: channel_id,
      thread_ts: thread_ts(event),
      metadata: %{
        team_id: Map.get(payload, "team_id"),
        user_id: Map.get(event, "user"),
        channel_type: Map.get(event, "channel_type"),
        chat_type: Map.get(event, "channel_type"),
        message_type: Map.get(event, "type")
      },
      attachments: parse_attachments(Map.get(event, "files", []))
    })
  end

  defp content(%{"type" => "app_mention"} = event) do
    event
    |> Map.get("text", "")
    |> String.replace(~r/<@[A-Z0-9]+>/, "")
    |> String.trim()
  end

  defp content(event), do: Map.get(event, "text", "")

  defp thread_ts(%{"type" => "app_mention"} = event) do
    Map.get(event, "thread_ts") || Map.get(event, "ts")
  end

  defp thread_ts(_event), do: nil

  defp sender_name(event) do
    cond do
      present?(Map.get(event, "username")) -> Map.get(event, "username")
      present?(Map.get(event, "user")) -> Map.get(event, "user")
      true -> "unknown"
    end
  end

  defp parse_attachments(files) when is_list(files) do
    Enum.map(files, fn file ->
      mime_type = Map.get(file, "mimetype")

      %{
        kind: attachment_kind(mime_type),
        url: Map.get(file, "url_private"),
        mime_type: mime_type,
        file_id: Map.get(file, "id"),
        size_bytes: Map.get(file, "size")
      }
    end)
  end

  defp parse_attachments(_files), do: []

  defp attachment_kind("audio/" <> _rest), do: :audio
  defp attachment_kind("image/" <> _rest), do: :image
  defp attachment_kind(_mime_type), do: :file

  defp maybe_put_thread_ts(body, opts) do
    case Keyword.get(opts, :thread_ts) do
      nil -> body
      thread_ts -> Map.put(body, :thread_ts, thread_ts)
    end
  end

  defp send_claimed_media(:duplicate, _channel_id, _media_part, _opts), do: :ok

  defp send_claimed_media({:fresh, claim}, channel_id, media_part, opts) do
    result =
      with {:ok, token} <- bot_token(),
           {:ok, upload} <- slack_upload_request(media_part, token, opts),
           :ok <- upload_file(upload, media_part, opts) do
        complete_upload(channel_id, upload, media_part, token, opts)
      end

    maybe_release_claim(result, claim)
  end

  defp slack_upload_request(%{path: path} = media_part, token, opts) when is_binary(path) do
    with {:ok, stat} <- File.stat(path),
         :ok <- enforce_media_cap(stat.size) do
      filename = Map.get(media_part, :filename) || Path.basename(path)

      body = %{filename: filename, length: stat.size}

      result =
        Req.new(url: "#{@api_base}/files.getUploadURLExternal", method: :post, json: body)
        |> Req.Request.put_header("authorization", "Bearer #{token}")
        |> Req.merge(req_options(opts))
        |> HttpClient.request("Slack files.getUploadURLExternal")

      case result do
        {:ok, %{status: 200, body: %{"ok" => true, "upload_url" => url, "file_id" => file_id}}} ->
          {:ok, %{upload_url: url, file_id: file_id, filename: filename, size: stat.size}}

        {:ok, %{status: 200, body: %{"ok" => false} = body}} ->
          Logger.error("Slack upload URL failed: #{inspect(body)}")
          {:error, Map.get(body, "error", "slack_api_error")}

        {:ok, %{status: status, body: body}} ->
          Logger.error("Slack upload URL failed: #{status} - #{inspect(body)}")
          {:error, "Slack API error: #{status}"}

        {:error, reason} ->
          Logger.error("Slack upload URL request failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp slack_upload_request(_media_part, _token, _opts), do: {:error, :invalid_media_part}

  defp upload_file(%{upload_url: upload_url, size: size}, %{path: path} = media_part, opts) do
    mime_type = Map.get(media_part, :mime_type) || "application/octet-stream"

    result =
      Req.new(url: upload_url, method: :post, body: File.stream!(path, 64_000, []))
      |> Req.Request.put_header("content-type", mime_type)
      |> Req.Request.put_header("content-length", Integer.to_string(size))
      |> Req.merge(req_options(opts))
      |> HttpClient.request("Slack external file upload")

    case result do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, "Slack upload error: #{status}: #{inspect(body)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp complete_upload(channel_id, upload, media_part, token, opts) do
    body =
      %{
        files: [%{id: upload.file_id, title: upload.filename}],
        channel_id: channel_id
      }
      |> maybe_put_initial_comment(Map.get(media_part, :caption))
      |> maybe_put_thread_ts(opts)

    {result, duration_us} =
      Telemetry.timed_us(fn ->
        Req.new(url: "#{@api_base}/files.completeUploadExternal", method: :post, json: body)
        |> Req.Request.put_header("authorization", "Bearer #{token}")
        |> Req.merge(req_options(opts))
        |> HttpClient.request("Slack files.completeUploadExternal")
      end)

    handle_send_response(result, duration_us)
  end

  defp enforce_media_cap(size) when size <= @max_media_bytes, do: :ok

  defp enforce_media_cap(size) do
    {:error, {:byte_cap_exceeded, size, @max_media_bytes}}
  end

  defp enforce_text_cap(text) do
    length = String.length(text)

    if length <= @max_message_length do
      :ok
    else
      {:error, {:text_cap_exceeded, length, @max_message_length}}
    end
  end

  defp maybe_release_claim(:ok, _claim), do: :ok

  defp maybe_release_claim({:error, _reason} = error, claim) do
    :ok = Idempotency.release_outbound_media_claim(claim)
    error
  end

  defp maybe_put_initial_comment(body, nil), do: body
  defp maybe_put_initial_comment(body, comment), do: Map.put(body, :initial_comment, comment)

  defp allowed_user_ids do
    FermixCore.Config.channel_ingress_user_ids(:slack)
  end

  defp ingress_enabled? do
    case FermixCore.Config.channel(:slack) do
      {:ok, config} -> Keyword.get(config, :enabled, false) == true
      _ -> false
    end
  end

  defp bot_token, do: fetch_config_value(:bot_token)
  defp signing_secret, do: fetch_config_value(:signing_secret)

  defp fetch_config_value(key) do
    with {:ok, config} <- FermixCore.Config.channel(:slack),
         value when is_binary(value) and value != "" <- Keyword.get(config, key) do
      {:ok, value}
    else
      _ -> {:error, :not_configured}
    end
  end

  defp req_options(opts) do
    case Keyword.fetch(opts, :req_options) do
      {:ok, req_opts} ->
        req_opts

      :error ->
        case FermixCore.Config.channel(:slack) do
          {:ok, config} -> Keyword.get(config, :req_options, [])
          _ -> []
        end
    end
  end

  defp handle_send_response({:ok, %{status: 200, body: %{"ok" => true}}}, duration_us) do
    ChannelTelemetry.emit_message(:slack, :outbound, 1, duration_us)
    :ok
  end

  defp handle_send_response({:ok, %{status: 200, body: %{"ok" => false} = body}}, _duration_us) do
    Logger.error("Slack send failed: #{inspect(body)}")
    {:error, Map.get(body, "error", "slack_api_error")}
  end

  defp handle_send_response({:ok, %{status: status, body: body} = response}, _duration_us) do
    Logger.error("Slack send failed: #{status} - #{inspect(body)}")
    slack_api_error(response)
  end

  defp handle_send_response({:error, reason}, _duration_us) do
    Logger.error("Slack request failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp maybe_emit_inbound_message({:ok, messages}, duration_us) when messages != [] do
    ChannelTelemetry.emit_message(:slack, :inbound, length(messages), duration_us)
  end

  defp maybe_emit_inbound_message(_result, _duration_us), do: :ok

  defp slack_api_error(%{status: status} = response) do
    case RetryHint.retry_after_ms(response) do
      {:ok, retry_after_ms} -> {:error, {:rate_limited, retry_after_ms}}
      :error -> {:error, "Slack API error: #{status}"}
    end
  end

  defp raw_body(conn) do
    case conn.assigns[:raw_body] do
      body when is_binary(body) and body != "" -> {:ok, body}
      _ -> {:error, :missing_raw_body}
    end
  end

  defp timestamp_header(conn) do
    case Plug.Conn.get_req_header(conn, "x-slack-request-timestamp") do
      [timestamp] when is_binary(timestamp) and timestamp != "" -> {:ok, timestamp}
      _ -> {:error, :missing_timestamp}
    end
  end

  defp signature_header(conn) do
    case Plug.Conn.get_req_header(conn, "x-slack-signature") do
      [signature] when is_binary(signature) and signature != "" -> {:ok, signature}
      [] -> {:error, :missing_signature}
      _ -> {:error, :invalid_signature}
    end
  end

  defp verify_timestamp(timestamp) do
    with {sent_at, ""} <- Integer.parse(timestamp),
         skew when skew <= @max_signature_age_seconds <-
           abs(System.os_time(:second) - sent_at) do
      :ok
    else
      :error -> {:error, :invalid_signature}
      _ -> {:error, :stale_timestamp}
    end
  end

  defp request_signature(signing_secret, timestamp, raw_body) do
    digest = :crypto.mac(:hmac, :sha256, signing_secret, "v0:#{timestamp}:#{raw_body}")
    "v0=" <> Base.encode16(digest, case: :lower)
  end

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_left, _right), do: false

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(_value), do: false
end
