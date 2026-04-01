defmodule FermixChannels.Telegram do
  @moduledoc """
  Telegram Bot API channel integration.

  Parses webhook payloads from Telegram into standard messages,
  sends outbound messages via the Bot API, and verifies webhook
  authenticity via the secret token header.
  """

  @behaviour FermixChannels.Channel

  require Logger

  @bot_api_base "https://api.telegram.org"
  @max_message_length 4096

  # -- Behaviour Callbacks --

  @impl true
  @spec parse_webhook(map()) :: {:ok, [FermixChannels.Channel.message()]} | {:error, term()}
  def parse_webhook(params) do
    result =
      cond do
        Map.has_key?(params, "message") ->
          parse_message(params["message"])

        Map.has_key?(params, "edited_message") ->
          parse_message(params["edited_message"])

        true ->
          {:ok, []}
      end

    with {:ok, messages} when messages != [] <- result do
      :telemetry.execute(
        [:fermix, :channel, :message],
        %{count: length(messages)},
        %{channel: :telegram, direction: :inbound}
      )

      {:ok, messages}
    end
  end

  @impl true
  @spec send_message(String.t(), String.t(), FermixChannels.Channel.send_opts()) ::
          :ok | {:error, term()}
  def send_message(chat_id, text, opts \\ []) do
    chunks = split_message(text)

    results =
      Enum.map(chunks, fn chunk ->
        post_send_message(chat_id, chunk, opts)
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        :telemetry.execute(
          [:fermix, :channel, :message],
          %{count: length(chunks)},
          %{channel: :telegram, direction: :outbound}
        )

        :ok

      error ->
        error
    end
  end

  @impl true
  @spec verify_webhook(Plug.Conn.t()) :: :ok | {:error, term()}
  def verify_webhook(conn) do
    {:ok, config} = FermixCore.Config.channel(:telegram)
    expected = Keyword.fetch!(config, :webhook_secret)

    case Plug.Conn.get_req_header(conn, "x-telegram-bot-api-secret-token") do
      [^expected] -> :ok
      [_wrong] -> {:error, :invalid_token}
      [] -> {:error, :missing_token}
    end
  end

  @impl true
  @spec start_typing(String.t()) :: :ok
  def start_typing(chat_id, opts \\ []) do
    token = get_bot_token()
    url = "#{@bot_api_base}/bot#{token}/sendChatAction"
    body = %{chat_id: chat_id, action: "typing"}

    Req.new(url: url, method: :post, json: body)
    |> Req.merge(req_options(opts))
    |> Req.request!()

    :ok
  end

  # -- Internals --

  defp post_send_message(chat_id, text, opts) do
    token = get_bot_token()
    url = "#{@bot_api_base}/bot#{token}/sendMessage"

    body =
      %{
        chat_id: chat_id,
        text: text,
        parse_mode: Keyword.get(opts, :parse_mode, "MarkdownV2")
      }
      |> maybe_put_reply_to(opts)

    result =
      Req.new(url: url, method: :post, json: body)
      |> Req.merge(req_options(opts))
      |> Req.request()

    case result do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status, body: response}} ->
        Logger.error("Telegram sendMessage failed: #{status} - #{inspect(response)}")
        {:error, "Telegram API error: #{status}"}

      {:error, reason} ->
        Logger.error("Telegram request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp maybe_put_reply_to(body, opts) do
    case Keyword.get(opts, :reply_to) do
      nil -> body
      reply_id -> Map.put(body, :reply_to_message_id, reply_id)
    end
  end

  defp parse_message(msg) do
    chat_id = to_string(msg["chat"]["id"])
    sender = msg["from"]["username"] || msg["from"]["first_name"] || "unknown"
    content = msg["text"] || msg["caption"] || ""

    message = %{
      id: to_string(msg["message_id"]),
      content: content,
      sender: sender,
      channel: "telegram",
      chat_id: chat_id,
      reply_target: chat_id,
      thread_ts: nil
    }

    {:ok, [message]}
  end

  defp split_message(text) when is_binary(text) do
    if String.length(text) <= @max_message_length do
      [text]
    else
      do_split(text, [])
    end
  end

  defp do_split("", acc), do: Enum.reverse(acc)

  defp do_split(remaining, acc) do
    if String.length(remaining) <= @max_message_length do
      Enum.reverse([remaining | acc])
    else
      {chunk, rest} = String.split_at(remaining, @max_message_length)
      do_split(rest, [chunk | acc])
    end
  end

  defp get_bot_token do
    {:ok, config} = FermixCore.Config.channel(:telegram)
    Keyword.fetch!(config, :bot_token)
  end

  defp req_options(opts) do
    case Keyword.get(opts, :req_options) do
      nil -> []
      req_opts -> req_opts
    end
  end
end
