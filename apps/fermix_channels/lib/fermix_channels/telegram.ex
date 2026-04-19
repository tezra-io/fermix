defmodule FermixChannels.Telegram do
  @moduledoc """
  Telegram Bot API channel integration.

  Parses webhook payloads from Telegram into standard messages,
  sends outbound messages via the Bot API, and verifies webhook
  authenticity via the secret token header.
  """

  @behaviour FermixChannels.Channel

  require Logger

  alias FermixChannels.Message

  @bot_api_base "https://api.telegram.org"
  @max_message_length 4096

  # -- Behaviour Callbacks --

  @impl true
  @spec parse_webhook(map()) :: {:ok, [FermixChannels.Channel.message()]} | {:error, term()}
  def parse_webhook(params) do
    with {:ok, messages} when messages != [] <- parse_update(params) do
      :telemetry.execute(
        [:fermix, :channel, :message],
        %{count: length(messages)},
        %{channel: :telegram, direction: :inbound}
      )

      {:ok, messages}
    end
  end

  @spec parse_update(map()) :: {:ok, [FermixChannels.Channel.message()]} | {:error, term()}
  def parse_update(update) do
    cond do
      Map.has_key?(update, "message") ->
        parse_message(update["message"])

      Map.has_key?(update, "edited_message") ->
        parse_message(update["edited_message"])

      true ->
        {:ok, []}
    end
  end

  @impl true
  @spec send_message(String.t(), String.t()) :: :ok | {:error, term()}
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
  @spec build_reply(FermixChannels.Channel.message()) :: FermixChannels.Channel.reply_fn()
  def build_reply(%Message{reply_target: reply_target, thread_ts: thread_ts}) do
    opts = if thread_ts, do: [message_thread_id: thread_ts], else: []

    fn text -> send_message(reply_target, text, opts) end
  end

  @impl true
  @spec verify_webhook(Plug.Conn.t()) :: :ok | {:error, term()}
  def verify_webhook(conn) do
    with {:ok, config} <- FermixCore.Config.channel(:telegram),
         expected when is_binary(expected) and expected != "" <-
           Keyword.get(config, :webhook_secret) do
      verify_token(conn, expected)
    else
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  defp verify_token(conn, expected) do
    case Plug.Conn.get_req_header(conn, "x-telegram-bot-api-secret-token") do
      [provided] when is_binary(provided) ->
        if Plug.Crypto.secure_compare(provided, expected) do
          :ok
        else
          {:error, :invalid_token}
        end

      [] ->
        {:error, :missing_token}

      _ ->
        {:error, :invalid_token}
    end
  end

  @impl true
  @spec start_typing(String.t()) :: :ok | {:error, term()}
  def start_typing(chat_id, opts \\ []) do
    with {:ok, token} <- get_bot_token() do
      url = "#{@bot_api_base}/bot#{token}/sendChatAction"
      body = %{chat_id: chat_id, action: "typing"}

      case Req.new(url: url, method: :post, json: body)
           |> Req.merge(req_options(opts))
           |> Req.request() do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # -- Internals --

  defp post_send_message(chat_id, text, opts) do
    with {:ok, token} <- get_bot_token() do
      url = "#{@bot_api_base}/bot#{token}/sendMessage"

      body =
        %{chat_id: chat_id, text: text}
        |> maybe_put_parse_mode(opts)
        |> maybe_put_reply_to(opts)
        |> maybe_put_message_thread_id(opts)

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
  end

  defp maybe_put_parse_mode(body, opts) do
    case Keyword.get(opts, :parse_mode) do
      nil -> body
      mode -> Map.put(body, :parse_mode, mode)
    end
  end

  defp maybe_put_reply_to(body, opts) do
    case Keyword.get(opts, :reply_to) do
      nil -> body
      reply_id -> Map.put(body, :reply_to_message_id, reply_id)
    end
  end

  defp maybe_put_message_thread_id(body, opts) do
    case Keyword.get(opts, :message_thread_id) do
      nil -> body
      thread_id -> Map.put(body, :message_thread_id, thread_id)
    end
  end

  defp parse_message(msg) do
    user_id = get_in(msg, ["from", "id"])

    if authorized_user?(user_id) do
      chat_id = msg |> get_in(["chat", "id"]) |> to_string()

      sender =
        get_in(msg, ["from", "username"]) || get_in(msg, ["from", "first_name"]) || "unknown"

      content = msg["text"] || msg["caption"] || ""

      message =
        Message.new!(%{
          id: to_string(msg["message_id"]),
          content: content,
          sender: sender,
          channel: "telegram",
          chat_id: chat_id,
          reply_target: chat_id,
          thread_ts: msg["message_thread_id"]
        })

      {:ok, [message]}
    else
      {:ok, []}
    end
  end

  defp authorized_user?(user_id) do
    allowed =
      case FermixCore.Config.channel(:telegram) do
        {:ok, config} -> Keyword.get(config, :allowed_user_ids, [])
        _ -> []
      end

    allowed == [] or user_id in allowed
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

  @doc false
  @spec get_bot_token() :: {:ok, String.t()} | {:error, :not_configured}
  def get_bot_token do
    with {:ok, config} <- FermixCore.Config.channel(:telegram),
         {:ok, token} when is_binary(token) and token != "" <- Keyword.fetch(config, :bot_token) do
      {:ok, token}
    else
      _ -> {:error, :not_configured}
    end
  end

  defp req_options(opts) do
    case Keyword.fetch(opts, :req_options) do
      {:ok, req_opts} ->
        req_opts

      :error ->
        case FermixCore.Config.channel(:telegram) do
          {:ok, config} -> Keyword.get(config, :req_options, [])
          _error -> []
        end
    end
  end
end
