defmodule FermixChannels.Discord do
  @moduledoc """
  Discord direct-message and app-mention channel adapter.

  Gateway events are normalized into shared channel messages. Outbound replies are
  sent through Discord's REST API as plain text messages with reply context.
  Discord does not expose webhook ingress for Fermix, so webhook entrypoints
  return `{:error, :unsupported_transport}`.
  """

  @behaviour FermixChannels.Channel

  require Logger

  alias FermixChannels.Message

  @api_base "https://discord.com/api/v10"

  @impl true
  def parse_webhook(_params), do: {:error, :unsupported_transport}

  @spec parse_gateway_event(map()) :: {:ok, [FermixChannels.Channel.message()]} | {:error, term()}
  def parse_gateway_event(%{"t" => "MESSAGE_CREATE", "d" => data}) when is_map(data) do
    messages =
      if process_message?(data) do
        [build_message(data)]
      else
        []
      end

    if messages != [] do
      :telemetry.execute(
        [:fermix, :channel, :message],
        %{count: length(messages)},
        %{channel: :discord, direction: :inbound}
      )
    end

    {:ok, messages}
  end

  def parse_gateway_event(%{"t" => "MESSAGE_CREATE"}), do: {:error, :invalid_gateway_payload}

  def parse_gateway_event(_event), do: {:ok, []}

  @impl true
  @spec send_message(String.t(), String.t()) :: :ok | {:error, term()}
  @spec send_message(String.t(), String.t(), FermixChannels.Channel.send_opts()) ::
          :ok | {:error, term()}
  def send_message(channel_id, text, opts \\ []) when is_binary(channel_id) and is_binary(text) do
    with {:ok, token} <- bot_token() do
      url = "#{@api_base}/channels/#{channel_id}/messages"

      body =
        %{content: text, allowed_mentions: %{parse: []}}
        |> maybe_put_message_reference(channel_id, opts)

      result =
        Req.new(url: url, method: :post, json: body)
        |> Req.Request.put_header("authorization", "Bot #{token}")
        |> Req.merge(req_options(opts))
        |> Req.request()

      handle_send_response(result)
    end
  end

  @impl true
  @spec build_reply(FermixChannels.Channel.message()) :: FermixChannels.Channel.reply_fn()
  def build_reply(%Message{id: message_id, reply_target: reply_target}) do
    fn text -> send_message(reply_target, text, reply_to: message_id) end
  end

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

  defp process_message?(data) do
    ingress_enabled?() and not bot_author?(data) and authorized_sender?(data) and
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
        author_id: Map.get(author, "id"),
        guild_id: Map.get(data, "guild_id"),
        message_type: "MESSAGE_CREATE"
      },
      attachments: parse_attachments(Map.get(data, "attachments", []))
    })
  end

  defp direct_message?(data), do: is_nil(Map.get(data, "guild_id"))

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

  defp authorized_sender?(data) do
    author_id = data |> Map.get("author", %{}) |> Map.get("id")
    allowed = allowed_user_ids()
    allowed == [] or author_id in allowed
  end

  defp allowed_user_ids do
    with {:ok, config} <- FermixCore.Config.channel(:discord) do
      config
      |> Keyword.get(:allowed_user_ids, [])
      |> Enum.map(&to_string/1)
    else
      _ -> []
    end
  end

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

  defp attachment_kind("audio/" <> _rest), do: :audio
  defp attachment_kind("image/" <> _rest), do: :image
  defp attachment_kind(_mime_type), do: :file

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

  defp handle_send_response({:ok, %{status: status}}) when status in [200, 201] do
    :telemetry.execute(
      [:fermix, :channel, :message],
      %{count: 1},
      %{channel: :discord, direction: :outbound}
    )

    :ok
  end

  defp handle_send_response({:ok, %{status: status, body: body}}) do
    Logger.error("Discord send failed: #{status} - #{inspect(body)}")
    {:error, "Discord API error: #{status}"}
  end

  defp handle_send_response({:error, reason}) do
    Logger.error("Discord request failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(_value), do: false
end
