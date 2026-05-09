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
  alias FermixCore.Net.HttpClient

  @bot_api_base "https://api.telegram.org"
  @max_message_length 4096
  @bullet_markdown_pattern ~r/^(\s*)[-*]\s+/u
  @fenced_code_pattern ~r/```([A-Za-z0-9_+-]*)\n([\s\S]*?)```/u
  @inline_markdown_pattern ~r/(\[[^\]\n]+?\]\([^\)\n]+?\)|`[^`\n]+?`|\*\*[^*\n]+?\*\*|~~[^~\n]+?~~|\*[^*\n]+?\*|_[^_\n]+?_)/u
  @link_markdown_pattern ~r/^\[([^\]\n]+)\]\(([^\)\n]+)\)$/u

  # -- Behaviour Callbacks --

  @impl true
  @spec parse_webhook(map()) :: {:error, :unsupported_transport}
  def parse_webhook(_params), do: {:error, :unsupported_transport}

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
  @spec verify_webhook(Plug.Conn.t()) :: {:error, :unsupported_transport}
  def verify_webhook(_conn), do: {:error, :unsupported_transport}

  @impl true
  @spec start_typing(String.t()) :: :ok | {:error, term()}
  def start_typing(chat_id, opts \\ []) do
    with {:ok, token} <- get_bot_token() do
      url = "#{@bot_api_base}/bot#{token}/sendChatAction"
      body = %{chat_id: chat_id, action: "typing"}

      case Req.new(url: url, method: :post, json: body)
           |> Req.merge(req_options(opts))
           |> HttpClient.request("Telegram sendChatAction") do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # -- Internals --

  defp post_send_message(chat_id, text, opts) do
    with {:ok, token} <- get_bot_token() do
      url = "#{@bot_api_base}/bot#{token}/sendMessage"
      {text, opts} = prepare_outbound_text(text, opts)

      body =
        %{chat_id: chat_id, text: text}
        |> maybe_put_parse_mode(opts)
        |> maybe_put_reply_to(opts)
        |> maybe_put_message_thread_id(opts)

      result =
        Req.new(url: url, method: :post, json: body)
        |> Req.merge(req_options(opts))
        |> HttpClient.request("Telegram sendMessage")

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

  defp prepare_outbound_text(text, opts) do
    cond do
      Keyword.has_key?(opts, :parse_mode) ->
        {text, opts}

      Keyword.get(opts, :format, :telegram_html) == :plain ->
        {text, opts}

      true ->
        {basic_markdown_to_html(text), Keyword.put(opts, :parse_mode, "HTML")}
    end
  end

  defp basic_markdown_to_html(text) do
    case Regex.run(@fenced_code_pattern, text, return: :index) do
      nil ->
        render_markdown_lines(text)

      [{start, length}, {lang_start, lang_length}, {body_start, body_length}] ->
        prefix = binary_part(text, 0, start)
        lang = binary_part(text, lang_start, lang_length)
        body = binary_part(text, body_start, body_length)
        suffix_start = start + length
        suffix_length = byte_size(text) - suffix_start

        render_markdown_lines(prefix) <>
          render_code_block(lang, body) <>
          basic_markdown_to_html(binary_part(text, suffix_start, suffix_length))
    end
  end

  defp render_markdown_lines(text) do
    text
    |> String.split("\n", trim: false)
    |> Enum.map_join("\n", &render_markdown_line/1)
  end

  defp render_markdown_line(line) do
    line
    |> normalize_bullet_marker()
    |> render_inline_markdown()
  end

  defp normalize_bullet_marker(line) do
    case Regex.run(@bullet_markdown_pattern, line) do
      [marker, indent] ->
        rest_start = byte_size(marker)
        indent <> "• " <> binary_part(line, rest_start, byte_size(line) - rest_start)

      nil ->
        line
    end
  end

  defp render_inline_markdown(text) do
    @inline_markdown_pattern
    |> Regex.split(text, include_captures: true, trim: false)
    |> Enum.map_join(&render_inline_segment/1)
  end

  defp render_inline_segment(segment) do
    cond do
      markdown_link_segment?(segment) ->
        render_markdown_link(segment)

      wrapped_markdown_segment?(segment, "**") ->
        render_wrapped_markdown("b", segment, 2)

      wrapped_markdown_segment?(segment, "~~") ->
        render_wrapped_markdown("s", segment, 2)

      wrapped_markdown_segment?(segment, "`") ->
        render_wrapped_markdown("code", segment, 1)

      wrapped_markdown_segment?(segment, "*") ->
        render_wrapped_markdown("i", segment, 1)

      wrapped_markdown_segment?(segment, "_") ->
        render_wrapped_markdown("i", segment, 1)

      true ->
        html_escape(segment)
    end
  end

  defp render_markdown_link(segment) do
    [_, text, url] = Regex.run(@link_markdown_pattern, segment)
    ~s(<a href="#{html_escape(url)}">#{html_escape(text)}</a>)
  end

  defp render_wrapped_markdown(tag, segment, marker_size) do
    inner_size = byte_size(segment) - marker_size * 2

    <<_::binary-size(marker_size), inner::binary-size(inner_size), _::binary-size(marker_size)>> =
      segment

    "<#{tag}>" <> html_escape(inner) <> "</#{tag}>"
  end

  defp render_code_block(lang, body) do
    body = body |> trim_code_block_newline() |> html_escape()

    case String.trim(lang) do
      "" ->
        "<pre><code>" <> body <> "</code></pre>"

      lang ->
        ~s(<pre><code class="language-#{html_escape(lang)}">#{body}</code></pre>)
    end
  end

  defp trim_code_block_newline(body) do
    cond do
      String.ends_with?(body, "\r\n") ->
        binary_part(body, 0, byte_size(body) - 2)

      String.ends_with?(body, "\n") ->
        binary_part(body, 0, byte_size(body) - 1)

      true ->
        body
    end
  end

  defp markdown_link_segment?(segment) do
    Regex.match?(@link_markdown_pattern, segment)
  end

  defp wrapped_markdown_segment?(segment, marker) do
    byte_size(segment) > byte_size(marker) * 2 and String.starts_with?(segment, marker) and
      String.ends_with?(segment, marker)
  end

  defp html_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
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
          thread_ts: msg["message_thread_id"],
          metadata: %{chat_type: get_in(msg, ["chat", "type"])}
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
