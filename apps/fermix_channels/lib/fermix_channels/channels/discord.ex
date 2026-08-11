defmodule FermixChannels.Channels.Discord do
  @moduledoc """
  Discord direct-message and app-mention channel adapter.

  Gateway events are normalized into shared channel messages. Outbound replies are
  sent through Discord's REST API as plain text messages with reply context.
  Discord does not expose webhook ingress for Fermix, so webhook entrypoints
  return `{:error, :unsupported_transport}`.
  """

  @behaviour FermixChannels.Gateway.Channel

  require Logger

  alias FermixChannels.Gateway.ApprovalButton
  alias FermixChannels.Gateway.Idempotency
  alias FermixChannels.Gateway.MediaDownload
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.ProposalButton
  alias FermixChannels.Gateway.RetryHint
  alias FermixChannels.Outbound.Splitter
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixCore.Net.HttpClient
  alias FermixCore.Telemetry

  @api_base "https://discord.com/api/v10"
  @health_timeout_ms 5_000
  @max_message_length 2_000
  @max_media_bytes 10 * 1_024 * 1_024

  @impl true
  def parse_webhook(_params), do: {:error, :unsupported_transport}

  @spec parse_gateway_event(map()) ::
          {:ok, [FermixChannels.Gateway.Channel.message()]} | {:error, term()}
  def parse_gateway_event(event) do
    {result, duration_us} = Telemetry.timed_us(fn -> do_parse_gateway_event(event) end)
    ChannelTelemetry.emit_parse(:discord, result, duration_us)
    maybe_emit_inbound_message(result, duration_us)
    result
  end

  defp do_parse_gateway_event(%{"t" => "MESSAGE_CREATE", "d" => data}) when is_map(data) do
    messages = if process_message?(data), do: [build_message(data)], else: []
    {:ok, messages}
  end

  defp do_parse_gateway_event(%{"t" => "MESSAGE_CREATE"}), do: {:error, :invalid_gateway_payload}
  defp do_parse_gateway_event(_event), do: {:ok, []}

  @impl true
  @spec send_message(String.t(), String.t()) :: :ok | {:error, term()}
  @spec send_message(String.t(), String.t(), FermixChannels.Gateway.Channel.send_opts()) ::
          :ok | {:error, term()}
  def send_message(channel_id, text, opts \\ []) when is_binary(channel_id) and is_binary(text) do
    case bot_token() do
      {:ok, token} ->
        # CHANNEL_LONGFORM_PRESENTATION §3.1: a reply longer than Discord's
        # content cap rides the shared boundary ladder and is delivered as
        # sequential messages; it is never refused.
        text
        |> Splitter.split(limit: @max_message_length, measure: &codepoint_length/1)
        |> send_text_chunks(channel_id, token, opts)

      # M30 §11.3: an unconfigured bot token means there is no client to send
      # through, which is the `:adapter_unavailable` kind of the closed delivery
      # vocabulary — not a bare atom the delivery normalizer would have to guess
      # at, and then log as a contract violation.
      {:error, :not_configured} ->
        {:error, {:permanent, :adapter_unavailable}}
    end
  end

  # Discord counts its 2,000-character `content` cap in Unicode CODEPOINTS, not
  # grapheme clusters: one 👩‍👩‍👦 is a single grapheme but five codepoints, so the
  # splitter's grapheme default would pass a body Discord rejects with a 400 —
  # emoji-heavy text only, which is exactly the text that never shows up in a
  # local fixture.
  @spec codepoint_length(String.t()) :: non_neg_integer()
  defp codepoint_length(text) when is_binary(text), do: length(String.to_charlist(text))

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
      %{content: chunk, allowed_mentions: %{parse: []}}
      |> maybe_put_message_reference(channel_id, opts)
      |> maybe_put_components(opts)

    Req.new(url: "#{@api_base}/channels/#{channel_id}/messages", method: :post, json: body)
    |> Req.Request.put_header("authorization", "Bot #{token}")
    |> Req.merge(req_options(opts))
    |> HttpClient.request("Discord sendMessage")
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
    with {:ok, claim} <- Idempotency.claim_outbound_media(:discord, channel_id, media_part) do
      send_claimed_media(claim, channel_id, media_part, opts)
    end
  end

  @impl true
  @spec build_text_reply(FermixChannels.Gateway.Channel.message()) :: (String.t() ->
                                                                         :ok | {:error, term()})
  def build_text_reply(%Message{id: message_id, reply_target: reply_target}) do
    fn text -> send_message(reply_target, text, reply_to: message_id) end
  end

  @impl true
  @spec build_media_reply(FermixChannels.Gateway.Channel.message()) ::
          (FermixChannels.Gateway.Channel.media_part() -> :ok | {:error, term()})
  def build_media_reply(%Message{id: message_id, reply_target: reply_target}) do
    fn media_part -> send_media(reply_target, media_part, reply_to: message_id) end
  end

  # -- Owner-approval one-tap button (SANDBOX_ACCESS_APPROVAL_FLOW) --

  @impl true
  @spec send_approval(Message.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def send_approval(%Message{id: message_id, reply_target: reply_target}, text, token)
      when is_binary(text) and is_binary(token) do
    # The prompt rides the normal send path (the backticked `/confirm <token>`
    # still renders as tap-to-copy); the action row is the additive one-tap
    # affordance. custom_id carries the `grant:<token>` payload (well under the
    # 100-char cap); the interaction handler strips the prefix and funnels the
    # tap through the unchanged `/confirm` path.
    send_message(reply_target, text, reply_to: message_id, components: approval_components(token))
  end

  # Action row (type 1) wrapping a success-style button (type 2, style 3).
  defp approval_components(token) do
    [
      %{
        type: 1,
        components: [
          %{type: 2, style: 3, label: "Approve", custom_id: ApprovalButton.payload(token)}
        ]
      }
    ]
  end

  # -- Skill-curation proposal buttons (MILESTONE_26_SKILL_CURATION §6.6) --

  @impl true
  @spec send_proposal(map(), String.t(), String.t()) :: :ok | {:error, term()}
  def send_proposal(%{chat_id: channel_id}, text, token)
      when is_binary(channel_id) and is_binary(text) and is_binary(token) do
    # Target-addressed (proactive — no inbound message to reply to). One action
    # row with approve (style 3, success) and deny (style 4, danger); a tap
    # synthesizes the typed `/skills approve|deny <token>` command.
    send_message(channel_id, text, components: proposal_components(token))
  end

  defp proposal_components(token) do
    [
      %{
        type: 1,
        components: [
          %{
            type: 2,
            style: 3,
            label: "Approve",
            custom_id: ProposalButton.approve_payload(token)
          },
          %{type: 2, style: 4, label: "Deny", custom_id: ProposalButton.deny_payload(token)}
        ]
      }
    ]
  end

  @doc """
  Parse a component-button INTERACTION_CREATE dispatch into the synthesized
  `/confirm` message + the per-interaction id/token the caller acks with. Returns
  `:ignore` for any non-component interaction or a payload that is not a
  `grant:` confirmation tap. `member.user.id` (guild) / `user.id` (DM) is
  Discord-authenticated server-side, so it is the unspoofable tapper identity.
  """
  @spec parse_interaction(map()) :: {:ok, map()} | :ignore | {:error, term()}
  def parse_interaction(%{"t" => "INTERACTION_CREATE", "d" => data}) when is_map(data) do
    if component_interaction?(data) do
      parse_component_interaction(data)
    else
      :ignore
    end
  end

  def parse_interaction(_event), do: :ignore

  # Discord interaction type 3 = MESSAGE_COMPONENT (a button/select click).
  defp component_interaction?(data), do: Map.get(data, "type") == 3

  defp parse_component_interaction(data) do
    custom_id = get_in(data, ["data", "custom_id"])

    case ApprovalButton.parse_payload(custom_id) do
      {:ok, token} -> build_interaction(data, &confirm_tap_message(&1, token))
      :ignore -> parse_proposal_interaction(data, custom_id)
    end
  end

  # A skill-curation proposal tap synthesizes the typed `/skills approve|deny`
  # command (MILESTONE_26_SKILL_CURATION §6.6) — same origin discipline as the
  # `grant:` confirm path.
  defp parse_proposal_interaction(data, custom_id) do
    case ProposalButton.parse_payload(custom_id) do
      {:ok, action, token} ->
        build_interaction(
          data,
          &ProposalButton.action_message(Map.merge(&1, %{action: action, token: token}))
        )

      :ignore ->
        :ignore
    end
  end

  defp confirm_tap_message(origin, token) do
    ApprovalButton.confirm_message(Map.put(origin, :token, token))
  end

  defp build_interaction(data, build_message) do
    with id when is_binary(id) <- Map.get(data, "id"),
         interaction_token when is_binary(interaction_token) <- Map.get(data, "token"),
         user_id when is_binary(user_id) <- interaction_user_id(data),
         channel_id when is_binary(channel_id) <- Map.get(data, "channel_id") do
      message =
        build_message.(%{
          id: "interaction-#{id}",
          sender: interaction_sender(data),
          channel: "discord",
          chat_id: channel_id,
          # Discord threads are their own channels (channel_id), so the tap
          # rides at :root exactly like the message the button was posted on —
          # keeping same-origin with the pending record.
          thread_ts: nil,
          user_id: user_id
        })

      {:ok, %{id: id, token: interaction_token, message: message}}
    else
      _ -> {:error, :invalid_interaction_payload}
    end
  end

  defp interaction_user_id(data) do
    get_in(data, ["member", "user", "id"]) || get_in(data, ["user", "id"])
  end

  defp interaction_sender(data) do
    user = get_in(data, ["member", "user"]) || Map.get(data, "user") || %{}
    sender_name(user)
  end

  @doc """
  Respond to a Discord interaction within its 3s window. Authenticates via the
  per-interaction token in the URL path (NOT the bot token), so this endpoint
  needs no authorization header.
  """
  @spec respond_interaction(String.t(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def respond_interaction(interaction_id, interaction_token, response, opts \\ [])
      when is_binary(interaction_id) and is_binary(interaction_token) and is_map(response) do
    url = "#{@api_base}/interactions/#{interaction_id}/#{interaction_token}/callback"

    case Req.new(url: url, method: :post, json: response)
         |> Req.merge(req_options(opts))
         |> HttpClient.request("Discord interaction callback") do
      {:ok, %{status: status}} when status in [200, 201, 204] ->
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.error("Discord interaction callback failed: #{status} - #{inspect(body)}")
        {:error, {:interaction_ack_failed, status}}

      {:error, reason} ->
        Logger.error("Discord interaction callback request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # -- Reactions (docs/design/EMOJI_REACTION_ACKS.md §9) --

  @impl true
  @spec reaction_capability() :: :any_emoji
  def reaction_capability, do: :any_emoji

  @impl true
  @spec react(FermixChannels.Gateway.Channel.message(), String.t()) :: :ok | {:error, term()}
  def react(message, emoji, opts \\ [])

  def react(%Message{id: message_id, reply_target: channel_id}, emoji, opts)
      when is_binary(emoji) do
    with {:ok, token} <- bot_token() do
      encoded = URI.encode(emoji, &URI.char_unreserved?/1)
      url = "#{@api_base}/channels/#{channel_id}/messages/#{message_id}/reactions/#{encoded}/@me"

      Req.new(url: url, method: :put)
      |> Req.Request.put_header("authorization", "Bot #{token}")
      |> Req.merge(req_options(opts))
      |> HttpClient.request("Discord addReaction")
      |> handle_reaction_response()
    end
  end

  defp handle_reaction_response({:ok, %{status: status}}) when status in [200, 204], do: :ok

  defp handle_reaction_response({:ok, %{status: status, body: body}}),
    do: {:error, {:discord_api_error, status, body}}

  defp handle_reaction_response({:error, reason}), do: {:error, reason}

  @impl true
  def verify_webhook(_conn), do: {:error, :unsupported_transport}

  @doc false
  @spec bot_token() :: {:ok, String.t()} | {:error, :not_configured}
  def bot_token, do: fetch_config_value(:bot_token)

  @doc false
  @spec gateway_url(keyword()) :: {:ok, String.t()} | {:error, term()}
  def gateway_url(opts \\ []) do
    case configured_gateway_url(opts) do
      url when is_binary(url) and url != "" -> {:ok, gateway_websocket_url(url)}
      _other -> fetch_gateway_url(opts)
    end
  end

  @impl true
  @spec health_check(keyword()) :: FermixChannels.Gateway.Channel.health_result()
  def health_check(opts \\ []) do
    start = System.monotonic_time(:millisecond)

    with {:ok, token} <- bot_token(),
         {:ok, expected_id} <- bot_user_id() do
      Req.new(url: "#{@api_base}/users/@me", method: :get)
      |> Req.Request.put_header("authorization", "Bot #{token}")
      |> Req.merge(health_req_options(opts))
      |> HttpClient.request("Discord health")
      |> classify_health_response(expected_id, start)
    else
      {:error, :not_configured} ->
        {:error, {:misconfigured, "discord bot_token or bot_user_id is not configured"}}
    end
  end

  defp process_message?(data) do
    ingress_enabled?() and not bot_author?(data) and
      (direct_message?(data) or app_mention?(data))
  end

  defp build_message(data) do
    author = Map.get(data, "author", %{})
    channel_id = Map.fetch!(data, "channel_id")
    content = data |> Map.get("content", "") |> strip_bot_mention() |> String.trim()

    Message.new!(%{
      id: to_string(Map.fetch!(data, "id")),
      content: content,
      sender: sender_name(author),
      channel: "discord",
      chat_id: channel_id,
      reply_target: channel_id,
      metadata: %{
        user_id: Map.get(author, "id"),
        guild_id: Map.get(data, "guild_id"),
        chat_type: chat_type(data),
        message_type: "MESSAGE_CREATE"
      },
      attachments: parse_attachments(Map.get(data, "attachments", []))
    })
  end

  defp direct_message?(data), do: is_nil(Map.get(data, "guild_id"))

  defp chat_type(data) do
    if direct_message?(data), do: "private", else: "guild"
  end

  defp app_mention?(data) do
    with {:ok, bot_user_id} <- bot_user_id() do
      mentioned_by_payload?(data, bot_user_id) or mentioned_by_content?(data, bot_user_id)
    else
      _ -> false
    end
  end

  defp mentioned_by_payload?(data, bot_user_id) do
    data
    |> Map.get("mentions", [])
    |> Enum.any?(&(Map.get(&1, "id") == bot_user_id))
  end

  defp mentioned_by_content?(data, bot_user_id) do
    content = Map.get(data, "content", "")
    String.contains?(content, ["<@#{bot_user_id}>", "<@!#{bot_user_id}>"])
  end

  defp bot_author?(data), do: data |> Map.get("author", %{}) |> Map.get("bot", false) == true

  # Leave this as a per-message config read. Discord DM/app-mention ingress volume
  # is low, and avoiding a cache keeps runtime enable/disable toggles immediate.
  defp ingress_enabled? do
    case FermixCore.Config.channel(:discord) do
      {:ok, config} -> Keyword.get(config, :enabled, false) == true
      _ -> false
    end
  end

  defp sender_name(author) do
    cond do
      present?(Map.get(author, "global_name")) -> Map.get(author, "global_name")
      present?(Map.get(author, "username")) -> Map.get(author, "username")
      true -> Map.get(author, "id", "unknown")
    end
  end

  defp strip_bot_mention(content) when is_binary(content) do
    case bot_user_id() do
      {:ok, bot_user_id} ->
        content
        |> String.replace("<@#{bot_user_id}>", "")
        |> String.replace("<@!#{bot_user_id}>", "")

      {:error, _reason} ->
        content
    end
  end

  defp parse_attachments(attachments) when is_list(attachments) do
    Enum.map(attachments, fn attachment ->
      mime_type = Map.get(attachment, "content_type")

      %{
        kind: attachment_kind(mime_type),
        url: Map.get(attachment, "url"),
        mime_type: mime_type,
        file_id: Map.get(attachment, "id"),
        size_bytes: Map.get(attachment, "size")
      }
    end)
  end

  @impl true
  @spec download_attachment(FermixChannels.Gateway.Channel.message(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def download_attachment(_message, attachment) when is_map(attachment) do
    with :ok <- MediaDownload.preflight_cap(attachment, @max_media_bytes),
         {:ok, url} <- attachment_url(attachment),
         {:ok, body} <- fetch_cdn_media(url),
         {:ok, path} <- MediaDownload.write_temp(body, "discord", attachment) do
      {:ok, path}
    end
  end

  defp attachment_url(attachment) do
    case MediaDownload.value(attachment, :url) do
      url when is_binary(url) and url != "" -> {:ok, url}
      _ -> {:error, :missing_attachment_reference}
    end
  end

  # Discord CDN attachment URLs are public — no bot token needed. The gateway's
  # declared `size` is the sender's claim, not the CDN's: `get_capped/3` halts
  # the transfer at the cap instead of buffering the whole body and measuring it
  # afterwards, which also removes the gzip amplifier the buffered path had.
  defp fetch_cdn_media(url) do
    Req.new(url: url, method: :get)
    |> Req.merge(req_options([]))
    |> MediaDownload.get_capped(@max_media_bytes, "Discord media download")
    |> handle_media_response()
  end

  defp handle_media_response({:ok, body}), do: {:ok, body}

  defp handle_media_response({:error, {:http_status, status, _body}}) do
    Logger.error("Discord media download failed: status=#{status}")
    {:error, {:download_failed, status}}
  end

  defp handle_media_response({:error, reason}), do: {:error, reason}

  defp attachment_kind("audio/" <> _rest), do: :audio
  defp attachment_kind("image/" <> _rest), do: :image
  defp attachment_kind(_mime_type), do: :file

  defp send_claimed_media(:duplicate, _channel_id, _media_part, _opts), do: :ok

  defp send_claimed_media({:fresh, claim}, channel_id, media_part, opts) do
    result =
      with {:ok, token} <- bot_token(),
           {:ok, request} <- media_request(channel_id, token, media_part, opts) do
        post_media(request)
      end

    maybe_release_claim(result, claim)
  end

  defp media_request(channel_id, token, %{path: path} = media_part, opts) when is_binary(path) do
    with {:ok, stat} <- File.stat(path),
         :ok <- enforce_media_cap(stat.size) do
      url = "#{@api_base}/channels/#{channel_id}/messages"
      filename = Map.get(media_part, :filename) || Path.basename(path)
      mime_type = Map.get(media_part, :mime_type) || "application/octet-stream"

      payload =
        %{allowed_mentions: %{parse: []}}
        |> maybe_put_content(Map.get(media_part, :caption))
        |> maybe_put_message_reference(channel_id, opts)

      fields = [
        payload_json: Jason.encode!(payload),
        "files[0]":
          {File.stream!(path, 64_000, []),
           filename: filename, content_type: mime_type, size: stat.size}
      ]

      {:ok,
       Req.new(url: url, method: :post, form_multipart: fields)
       |> Req.Request.put_header("authorization", "Bot #{token}")
       |> Req.merge(req_options(opts))}
    end
  end

  defp media_request(_channel_id, _token, _media_part, _opts), do: {:error, :invalid_media_part}

  defp post_media(request) do
    {result, duration_us} =
      Telemetry.timed_us(fn -> HttpClient.request(request, "Discord sendMedia") end)

    handle_send_response(result, duration_us)
  end

  defp enforce_media_cap(size) when size <= @max_media_bytes, do: :ok

  defp enforce_media_cap(size) do
    {:error, {:byte_cap_exceeded, size, @max_media_bytes}}
  end

  defp maybe_put_content(body, nil), do: body
  defp maybe_put_content(body, content), do: Map.put(body, :content, content)

  defp maybe_release_claim(:ok, _claim), do: :ok

  defp maybe_release_claim({:error, _reason} = error, claim) do
    :ok = Idempotency.release_outbound_media_claim(claim)
    error
  end

  defp maybe_put_components(body, opts) do
    case Keyword.get(opts, :components) do
      nil -> body
      components when is_list(components) -> Map.put(body, :components, components)
    end
  end

  defp maybe_put_message_reference(body, channel_id, opts) do
    case Keyword.get(opts, :reply_to) do
      nil ->
        body

      message_id ->
        Map.put(body, :message_reference, %{
          message_id: message_id,
          channel_id: channel_id,
          fail_if_not_exists: false
        })
    end
  end

  defp bot_user_id, do: fetch_config_value(:bot_user_id)

  defp classify_health_response(
         {:ok, %{status: 200, body: %{"id" => expected_id}}},
         expected_id,
         start
       ) do
    {:ok, %{detail: "Discord bot #{expected_id} authenticated", latency_ms: elapsed_ms(start)}}
  end

  defp classify_health_response(
         {:ok, %{status: 200, body: %{"id" => actual_id}}},
         expected_id,
         _start
       ) do
    {:error, {:misconfigured, "discord bot_user_id #{expected_id} does not match #{actual_id}"}}
  end

  defp classify_health_response({:ok, %{status: status, body: body}}, _expected_id, _start)
       when status in [401, 403] do
    {:error, {:auth_failed, "Discord API HTTP #{status}: #{api_description(body)}"}}
  end

  defp classify_health_response({:ok, %{status: status, body: body}}, _expected_id, _start) do
    {:error, {:server_error, status, body}}
  end

  defp classify_health_response({:error, reason}, _expected_id, _start) do
    {:error, {:network, reason}}
  end

  defp api_description(%{"message" => message}) when is_binary(message), do: message
  defp api_description(_body), do: "request rejected"

  defp configured_gateway_url(opts) do
    Keyword.get(opts, :gateway_url) || config_value(:gateway_url)
  end

  defp fetch_gateway_url(opts) do
    with {:ok, token} <- bot_token() do
      result =
        Req.new(url: "#{@api_base}/gateway/bot", method: :get)
        |> Req.Request.put_header("authorization", "Bot #{token}")
        |> Req.merge(req_options(opts))
        |> Req.request()

      case result do
        {:ok, %{status: 200, body: %{"url" => url}}} when is_binary(url) ->
          {:ok, gateway_websocket_url(url)}

        {:ok, %{status: status, body: body}} ->
          Logger.error("Discord gateway URL fetch failed: #{status} - #{inspect(body)}")
          {:error, "Discord gateway URL error: #{status}"}

        {:error, reason} ->
          Logger.error("Discord gateway URL request failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp gateway_websocket_url(url) do
    if String.contains?(url, "?") do
      url
    else
      "#{url}/?v=10&encoding=json"
    end
  end

  defp config_value(key) do
    case FermixCore.Config.channel(:discord) do
      {:ok, config} -> Keyword.get(config, key)
      _ -> nil
    end
  end

  defp fetch_config_value(key) do
    with {:ok, config} <- FermixCore.Config.channel(:discord),
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
        case FermixCore.Config.channel(:discord) do
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
    ChannelTelemetry.emit_message(:discord, :outbound, 1, duration_us)
    :ok
  end

  defp emit_outbound({:error, _reason} = error, _duration_us), do: error

  defp classify_send_response({:ok, %{status: status}}) when status in [200, 201], do: :ok

  defp classify_send_response({:ok, %{status: status, body: body} = response}) do
    Logger.error("Discord send failed: #{status} - #{inspect(body)}")
    discord_api_error(response)
  end

  defp classify_send_response({:error, reason}) do
    Logger.error("Discord request failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp maybe_emit_inbound_message({:ok, messages}, duration_us) when messages != [] do
    ChannelTelemetry.emit_message(:discord, :inbound, length(messages), duration_us)
  end

  defp maybe_emit_inbound_message(_result, _duration_us), do: :ok

  # M30 §11.3: the adapter owns platform knowledge and returns the structured
  # status/rate-limit forms of the closed delivery vocabulary. `RetryHint` stays
  # authoritative whenever Discord supplies a retry-after hint; the response
  # body reaches the local log above, never the returned reason.
  defp discord_api_error(%{status: status} = response) do
    case RetryHint.retry_after_ms(response) do
      {:ok, retry_after_ms} -> {:error, {:rate_limited, retry_after_ms}}
      :error -> {:error, {:http_status, status}}
    end
  end

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(_value), do: false
  defp elapsed_ms(start), do: System.monotonic_time(:millisecond) - start
end
