defmodule FermixChannels.Slack do
  @moduledoc """
  Slack direct-message and app-mention channel adapter.

  Uses the Events API for signed webhook ingress and `chat.postMessage` for
  outbound replies. Initial M3 scope is limited to DMs and `app_mention`
  events.
  """

  @behaviour FermixChannels.Channel

  require Logger

  alias FermixChannels.Message
  alias FermixCore.Net.HttpClient

  @api_base "https://slack.com/api"
  @max_signature_age_seconds 300

  @impl true
  @spec parse_webhook(map()) :: {:ok, [FermixChannels.Channel.message()]} | {:error, term()}
  def parse_webhook(%{"type" => "event_callback", "event" => event} = payload)
      when is_map(event) and is_map(payload) do
    messages =
      if ingress_enabled?() do
        parse_event(event, payload)
      else
        []
      end

    if messages != [] do
      :telemetry.execute(
        [:fermix, :channel, :message],
        %{count: length(messages)},
        %{channel: :slack, direction: :inbound}
      )
    end

    {:ok, messages}
  end

  def parse_webhook(%{"type" => "url_verification"}), do: {:ok, []}
  def parse_webhook(%{"type" => "event_callback"}), do: {:error, :invalid_webhook_payload}
  def parse_webhook(_payload), do: {:ok, []}

  @impl true
  @spec send_message(String.t(), String.t()) :: :ok | {:error, term()}
  @spec send_message(String.t(), String.t(), FermixChannels.Channel.send_opts()) ::
          :ok | {:error, term()}
  def send_message(channel_id, text, opts \\ []) when is_binary(channel_id) and is_binary(text) do
    with {:ok, token} <- bot_token() do
      body =
        %{channel: channel_id, text: text}
        |> maybe_put_thread_ts(opts)

      result =
        Req.new(url: "#{@api_base}/chat.postMessage", method: :post, json: body)
        |> Req.Request.put_header("authorization", "Bearer #{token}")
        |> Req.merge(req_options(opts))
        |> HttpClient.request("Slack chat.postMessage")

      handle_send_response(result)
    end
  end

  @impl true
  @spec build_reply(FermixChannels.Channel.message()) :: FermixChannels.Channel.reply_fn()
  def build_reply(%Message{reply_target: reply_target, thread_ts: thread_ts}) do
    opts = if thread_ts, do: [thread_ts: thread_ts], else: []

    fn text -> send_message(reply_target, text, opts) end
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
    user_id = Map.get(event, "user")
    allowed = allowed_user_ids()
    allowed == [] or user_id in allowed
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

  defp handle_send_response({:ok, %{status: 200, body: %{"ok" => true}}}) do
    :telemetry.execute(
      [:fermix, :channel, :message],
      %{count: 1},
      %{channel: :slack, direction: :outbound}
    )

    :ok
  end

  defp handle_send_response({:ok, %{status: 200, body: %{"ok" => false} = body}}) do
    Logger.error("Slack send failed: #{inspect(body)}")
    {:error, Map.get(body, "error", "slack_api_error")}
  end

  defp handle_send_response({:ok, %{status: status, body: body}}) do
    Logger.error("Slack send failed: #{status} - #{inspect(body)}")
    {:error, "Slack API error: #{status}"}
  end

  defp handle_send_response({:error, reason}) do
    Logger.error("Slack request failed: #{inspect(reason)}")
    {:error, reason}
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
