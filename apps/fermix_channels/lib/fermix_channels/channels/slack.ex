defmodule FermixChannels.Channels.Slack do
  @moduledoc """
  Slack direct-message and app-mention channel adapter.

  Uses the Events API for signed webhook ingress and `chat.postMessage` for
  outbound replies. Initial M3 scope is limited to DMs and `app_mention`
  events.
  """

  @behaviour FermixChannels.Gateway.Channel

  require Logger

  alias FermixChannels.Channels.Slack.Mrkdwn
  alias FermixChannels.Gateway.Idempotency
  alias FermixChannels.Gateway.MediaDownload
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.RetryHint
  alias FermixChannels.Outbound.Splitter
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixCore.Net.HttpClient
  alias FermixCore.Telemetry

  @api_base "https://slack.com/api"
  @health_timeout_ms 5_000
  # Slack documents the `chat.postMessage` `text` cap as 40,000 "characters"
  # without saying which unit it counts, so the splitter's grapheme default
  # stands and the uncertainty is named rather than papered over: graphemes
  # undercount codepoints and UTF-16 units on emoji-dense text, but 40,000 is
  # two orders of magnitude above any reply Fermix produces, so the margin
  # absorbs the ambiguity. Unverified.
  @max_message_length 40_000
  @max_signature_age_seconds 300
  @max_media_bytes 100 * 1_024 * 1_024

  # The bounded known set of `chat.postMessage` `ok: false` codes M30 §11.3
  # classifies. Anything outside these three lists is `:remote_rejected` — a new
  # Slack code must never widen the closed vocabulary on its own.
  @invalid_destination_codes ~w(channel_not_found is_archived)
  @authentication_codes ~w(invalid_auth token_revoked account_inactive not_authed)
  @authorization_codes ~w(missing_scope not_in_channel restricted_action)

  # Ceiling for the bounded local diagnostic of a rejection code.
  @error_log_max 200

  @impl true
  @spec parse_webhook(map()) ::
          {:ok, [FermixChannels.Gateway.Channel.message()]} | {:error, term()}
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
    case bot_token() do
      {:ok, token} ->
        # CHANNEL_LONGFORM_PRESENTATION §3.1: a reply longer than Slack's hard
        # truncation bound rides the shared boundary ladder and is delivered as
        # sequential messages; it is never refused. The ladder walks the model's
        # Markdown — that is where headings and section boundaries are still
        # legible — while every candidate chunk is *measured* through the mrkdwn
        # renderer, so the fill condition sees the text Slack receives. Each
        # emitted chunk is then rendered for the wire.
        text
        |> Splitter.split(limit: @max_message_length, measure: &Mrkdwn.rendered_length/1)
        |> Enum.map(&Mrkdwn.render/1)
        |> send_text_chunks(channel_id, token, opts)

      # M30 §11.3: an unconfigured token means there is no Slack client to send
      # through, which is the `:adapter_unavailable` kind of the closed delivery
      # vocabulary — not a bare atom the delivery normalizer would have to guess
      # at, and then log as a contract violation.
      {:error, :not_configured} ->
        {:error, {:permanent, :adapter_unavailable}}
    end
  end

  # Strictly sequential: the first failure aborts the remaining chunks and is
  # the returned reason.
  defp send_text_chunks(chunks, channel_id, token, opts) do
    Enum.reduce_while(chunks, :ok, fn chunk, :ok ->
      halt_on_error(send_text_chunk(chunk, channel_id, token, opts))
    end)
  end

  # One delivered message is one outbound row, emitted here rather than once for
  # the whole reply (design §8): a reply that half-lands then reports truthfully
  # what WAS delivered instead of reporting nothing.
  defp send_text_chunk(chunk, channel_id, token, opts) do
    {result, duration_us} =
      Telemetry.timed_us(fn -> post_text_chunk(chunk, channel_id, token, opts) end)

    emit_outbound(result, duration_us)
  end

  defp halt_on_error(:ok), do: {:cont, :ok}
  defp halt_on_error({:error, _reason} = error), do: {:halt, error}

  defp post_text_chunk(chunk, channel_id, token, opts) do
    body =
      %{channel: channel_id, text: chunk}
      |> maybe_put_thread_ts(opts)

    Req.new(url: "#{@api_base}/chat.postMessage", method: :post, json: body)
    |> Req.Request.put_header("authorization", "Bearer #{token}")
    |> Req.merge(req_options(opts))
    |> HttpClient.request("Slack chat.postMessage")
    |> classify_send_response()
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
  def send_media(channel_id, media_part, opts \\ [])
      when is_binary(channel_id) and is_map(media_part) do
    with {:ok, claim} <- Idempotency.claim_outbound_media(:slack, channel_id, media_part) do
      send_claimed_media(claim, channel_id, media_part, opts)
    end
  end

  @impl true
  @spec build_text_reply(FermixChannels.Gateway.Channel.message()) :: (String.t() ->
                                                                         :ok | {:error, term()})
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

  # -- Reactions (docs/design/EMOJI_REACTION_ACKS.md §9) --

  # Slack's `reactions.add` takes an emoji NAME (shortcode), not a unicode glyph,
  # so the capability is expressed as Slack's shortcode set — the `react` tool's
  # enum is exactly these names, and the model picks one (no unicode→shortcode
  # conversion needed). All are built-in Slack aliases present in every workspace.
  @reaction_shortcodes ~w(thumbsup thumbsdown tada heart fire pray eyes clap 100 rocket
                          white_check_mark joy thinking_face wave ok_hand raised_hands sob
                          sunglasses sparkles smile)

  @impl true
  @spec reaction_capability() :: {:restricted, [String.t()]}
  def reaction_capability, do: {:restricted, @reaction_shortcodes}

  @impl true
  @spec react(FermixChannels.Gateway.Channel.message(), String.t()) :: :ok | {:error, term()}
  def react(message, name, opts \\ [])

  def react(%Message{id: ts, reply_target: channel_id}, name, opts) when is_binary(name) do
    with :ok <- validate_reaction_name(name),
         {:ok, token} <- bot_token() do
      body = %{channel: channel_id, timestamp: ts, name: name}

      Req.new(url: "#{@api_base}/reactions.add", method: :post, json: body)
      |> Req.Request.put_header("authorization", "Bearer #{token}")
      |> Req.merge(req_options(opts))
      |> HttpClient.request("Slack reactions.add")
      |> handle_reaction_response()
    end
  end

  defp validate_reaction_name(name) do
    if name in @reaction_shortcodes, do: :ok, else: {:error, {:unsupported_emoji, name}}
  end

  # Slack returns HTTP 200 even for API errors, gated on the `ok` field. No
  # ChannelTelemetry.emit_message here — a reaction is not an outbound message;
  # the delivery layer already emits the `:reaction` channel-reply event.
  defp handle_reaction_response({:ok, %{status: 200, body: %{"ok" => true}}}), do: :ok

  # `already_reacted` is the desired end state (the reaction is on the message),
  # not a failure — normalize to :ok so it matches the idempotent success of
  # Telegram/Discord. Reachable when HttpClient retries a request whose first
  # attempt landed but whose response was lost (wake-from-sleep pool RST).
  defp handle_reaction_response(
         {:ok, %{status: 200, body: %{"ok" => false, "error" => "already_reacted"}}}
       ),
       do: :ok

  defp handle_reaction_response({:ok, %{status: 200, body: %{"ok" => false} = body}}) do
    Logger.error("Slack reaction failed: #{inspect(body)}")
    {:error, Map.get(body, "error", "slack_api_error")}
  end

  defp handle_reaction_response({:ok, %{status: status, body: body} = response}) do
    Logger.error("Slack reaction failed: #{status} - #{inspect(body)}")
    slack_api_error(response)
  end

  defp handle_reaction_response({:error, reason}) do
    Logger.error("Slack reaction request failed: #{inspect(reason)}")
    {:error, reason}
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

  @impl true
  @spec health_check(keyword()) :: FermixChannels.Gateway.Channel.health_result()
  def health_check(opts \\ []) do
    start = System.monotonic_time(:millisecond)

    with {:ok, token} <- bot_token() do
      Req.new(url: "#{@api_base}/auth.test", method: :post)
      |> Req.Request.put_header("authorization", "Bearer #{token}")
      |> Req.merge(health_req_options(opts))
      |> HttpClient.request("Slack health")
      |> classify_health_response(start)
    else
      {:error, :not_configured} ->
        {:error, {:misconfigured, "slack bot_token is not configured"}}
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

  defp classify_health_response({:ok, %{status: 200, body: %{"ok" => true} = body}}, start) do
    team = Map.get(body, "team") || Map.get(body, "team_id") || "workspace"
    {:ok, %{detail: "Slack #{team} authenticated", latency_ms: elapsed_ms(start)}}
  end

  defp classify_health_response({:ok, %{status: 200, body: %{"error" => error}}}, _start) do
    {:error, {:auth_failed, "Slack auth.test failed: #{error}"}}
  end

  defp classify_health_response({:ok, %{status: status, body: body}}, _start)
       when status in [401, 403] do
    {:error, {:auth_failed, "Slack API HTTP #{status}: #{api_description(body)}"}}
  end

  defp classify_health_response({:ok, %{status: status, body: body}}, _start) do
    {:error, {:server_error, status, body}}
  end

  defp classify_health_response({:error, reason}, _start), do: {:error, {:network, reason}}

  defp api_description(%{"error" => error}) when is_binary(error), do: error
  defp api_description(_body), do: "request rejected"

  defp parse_event(event, payload) do
    if process_event?(event) do
      [build_message(event, payload)]
    else
      []
    end
  end

  defp process_event?(event) do
    not bot_event?(event) and
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

  @impl true
  @spec download_attachment(FermixChannels.Gateway.Channel.message(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def download_attachment(_message, attachment) when is_map(attachment) do
    with :ok <- MediaDownload.preflight_cap(attachment, @max_media_bytes),
         {:ok, url} <- attachment_url(attachment),
         {:ok, token} <- bot_token(),
         {:ok, body} <- fetch_private_media(url, token),
         {:ok, path} <- MediaDownload.write_temp(body, "slack", attachment) do
      {:ok, path}
    end
  end

  defp attachment_url(attachment) do
    case MediaDownload.value(attachment, :url) do
      url when is_binary(url) and url != "" -> {:ok, url}
      _ -> {:error, :missing_attachment_reference}
    end
  end

  # Slack `url_private` requires the bot token as a Bearer header.
  defp fetch_private_media(url, token) do
    Req.new(url: url, method: :get)
    |> Req.Request.put_header("authorization", "Bearer #{token}")
    |> Req.merge(req_options([]))
    |> MediaDownload.get_capped(@max_media_bytes, "Slack media download")
    |> handle_media_response()
  end

  defp handle_media_response({:ok, body}), do: {:ok, body}

  defp handle_media_response({:error, {:http_status, status, _body}}) do
    Logger.error("Slack media download failed: status=#{status}")
    {:error, {:download_failed, status}}
  end

  defp handle_media_response({:error, reason}), do: {:error, reason}

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
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, "Slack upload error: #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, reason}
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

  defp maybe_release_claim(:ok, _claim), do: :ok

  defp maybe_release_claim({:error, _reason} = error, claim) do
    :ok = Idempotency.release_outbound_media_claim(claim)
    error
  end

  defp maybe_put_initial_comment(body, nil), do: body
  defp maybe_put_initial_comment(body, comment), do: Map.put(body, :initial_comment, comment)

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

  defp health_req_options(opts) do
    opts
    |> req_options()
    |> Keyword.put(:receive_timeout, health_timeout_ms(opts))
    |> Keyword.put(:retry, false)
  end

  defp health_timeout_ms(opts) do
    case Keyword.get(opts, :timeout_ms, @health_timeout_ms) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 -> timeout_ms
      _other -> @health_timeout_ms
    end
  end

  defp handle_send_response(result, duration_us) do
    result
    |> classify_send_response()
    |> emit_outbound(duration_us)
  end

  defp emit_outbound(:ok, duration_us) do
    ChannelTelemetry.emit_message(:slack, :outbound, 1, duration_us)
    :ok
  end

  defp emit_outbound({:error, _reason} = error, _duration_us), do: error

  defp classify_send_response({:ok, %{status: 200, body: %{"ok" => true}}}), do: :ok

  # Slack answers 200 for API-level rejections and puts the reason in `ok: false`
  # plus an `error` code. M30 §11.3 maps a bounded known set to permanent kinds
  # and everything else to `:remote_rejected`; the code itself is logged locally
  # (bounded) and never embedded in the returned reason.
  defp classify_send_response({:ok, %{status: 200, body: %{"ok" => false} = body}}) do
    code = Map.get(body, "error", "unknown")

    Logger.warning(
      "Slack send rejected: #{inspect(code)} — " <>
        String.slice(inspect(body), 0, @error_log_max)
    )

    {:error, {:permanent, slack_rejection_kind(code)}}
  end

  defp classify_send_response({:ok, %{status: status, body: body} = response}) do
    Logger.error("Slack send failed: #{status} - #{inspect(body)}")
    slack_api_error(response)
  end

  defp classify_send_response({:error, reason}) do
    Logger.error("Slack request failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp maybe_emit_inbound_message({:ok, messages}, duration_us) when messages != [] do
    ChannelTelemetry.emit_message(:slack, :inbound, length(messages), duration_us)
  end

  defp maybe_emit_inbound_message(_result, _duration_us), do: :ok

  # M30 §11.3: the adapter owns platform knowledge and returns the structured
  # status/rate-limit forms of the closed delivery vocabulary. `RetryHint` stays
  # authoritative whenever Slack supplies a retry-after hint; the response body
  # reaches the local log above, never the returned reason.
  defp slack_api_error(%{status: status} = response) do
    case RetryHint.retry_after_ms(response) do
      {:ok, retry_after_ms} -> {:error, {:rate_limited, retry_after_ms}}
      :error -> {:error, {:http_status, status}}
    end
  end

  defp slack_rejection_kind(code) when code in @invalid_destination_codes,
    do: :invalid_destination

  defp slack_rejection_kind(code) when code in @authentication_codes, do: :authentication
  defp slack_rejection_kind(code) when code in @authorization_codes, do: :authorization
  defp slack_rejection_kind(_code), do: :remote_rejected

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
  defp elapsed_ms(start), do: System.monotonic_time(:millisecond) - start
end
