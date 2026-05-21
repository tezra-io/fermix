defmodule FermixChannels.Telegram do
  @moduledoc """
  Telegram Bot API channel integration.

  Parses webhook payloads from Telegram into standard messages,
  sends outbound messages via the Bot API, and verifies webhook
  authenticity via the secret token header.
  """

  @behaviour FermixChannels.Channel

  require Logger

  alias FermixChannels.Idempotency
  alias FermixChannels.Message
  alias FermixChannels.RetryHint
  alias FermixCore.Net.HttpClient

  @bot_api_base "https://api.telegram.org"
  @max_message_length 4096
  @bullet_markdown_pattern ~r/^(\s*)[-*]\s+/u
  @fenced_code_pattern ~r/```([A-Za-z0-9_+-]*)\n([\s\S]*?)```/u
  @inline_markdown_pattern ~r/(\[[^\]\n]+?\]\([^\)\n]+?\)|`[^`\n]+?`|\*\*[^*\n]+?\*\*|~~[^~\n]+?~~|\*[^*\n]+?\*|_[^_\n]+?_)/u
  @link_markdown_pattern ~r/^\[([^\]\n]+)\]\(([^\)\n]+)\)$/u
  @media_methods %{
    image: {"sendPhoto", :photo, 10 * 1_024 * 1_024},
    document: {"sendDocument", :document, 50 * 1_024 * 1_024},
    audio: {"sendAudio", :audio, 50 * 1_024 * 1_024},
    video: {"sendVideo", :video, 50 * 1_024 * 1_024},
    voice: {"sendVoice", :voice, 1 * 1_024 * 1_024}
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
    chunks = outbound_text_chunks(text, opts)

    results =
      Enum.map(chunks, fn {chunk, chunk_opts} ->
        post_send_message(chat_id, chunk, chunk_opts)
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
  @spec send_media(String.t(), FermixChannels.Channel.media_part()) :: :ok | {:error, term()}
  @spec send_media(String.t(), FermixChannels.Channel.media_part(), FermixChannels.Channel.send_opts()) ::
          :ok | {:error, term()}
  def send_media(chat_id, media_part, opts \\ []) when is_binary(chat_id) and is_map(media_part) do
    with {:ok, claim} <- Idempotency.claim_outbound_media(:telegram, chat_id, media_part) do
      send_claimed_media(claim, chat_id, media_part, opts)
    end
  end

  @impl true
  @spec build_text_reply(FermixChannels.Channel.message()) :: (String.t() -> :ok | {:error, term()})
  def build_text_reply(%Message{reply_target: reply_target, thread_ts: thread_ts}) do
    opts = if thread_ts, do: [message_thread_id: thread_ts], else: []

    fn text -> send_message(reply_target, text, opts) end
  end

  @impl true
  @spec build_media_reply(FermixChannels.Channel.message()) ::
          (FermixChannels.Channel.media_part() -> :ok | {:error, term()})
  def build_media_reply(%Message{reply_target: reply_target, thread_ts: thread_ts}) do
    opts = if thread_ts, do: [message_thread_id: thread_ts], else: []

    fn media_part -> send_media(reply_target, media_part, opts) end
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

        {:ok, %{status: status, body: response} = api_response} ->
          Logger.error("Telegram sendMessage failed: #{status} - #{inspect(response)}")
          telegram_api_error(api_response)

        {:error, reason} ->
          Logger.error("Telegram request failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp send_claimed_media(:duplicate, _chat_id, _media_part, _opts), do: :ok

  defp send_claimed_media({:fresh, claim}, chat_id, media_part, opts) do
    result =
      with {:ok, token} <- get_bot_token(),
           {:ok, request} <- media_request(token, chat_id, media_part, opts) do
        post_media(request)
      end

    maybe_release_claim(result, claim)
  end

  defp media_request(token, chat_id, %{kind: kind, path: path} = media_part, opts)
       when is_binary(path) do
    with {:ok, {method, field, cap}} <- Map.fetch(@media_methods, kind),
         {:ok, stat} <- File.stat(path),
         :ok <- enforce_media_cap(stat.size, cap, kind) do
      url = "#{@bot_api_base}/bot#{token}/#{method}"
      filename = Map.get(media_part, :filename) || Path.basename(path)
      mime_type = Map.get(media_part, :mime_type) || mime_from_path(path)

      fields =
        [
          {:chat_id, chat_id},
          {field,
           {File.stream!(path, 64_000, []),
            filename: filename, content_type: mime_type, size: stat.size}}
        ]
        |> maybe_put_form(:caption, Map.get(media_part, :caption))
        |> maybe_put_form(:message_thread_id, Keyword.get(opts, :message_thread_id))

      {:ok, Req.new(url: url, method: :post, form_multipart: fields) |> Req.merge(req_options(opts))}
    else
      :error -> {:error, {:unsupported_media_kind, kind}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp media_request(_token, _chat_id, _media_part, _opts), do: {:error, :invalid_media_part}

  defp post_media(request) do
    case HttpClient.request(request, "Telegram sendMedia") do
      {:ok, %{status: 200}} ->
        :telemetry.execute(
          [:fermix, :channel, :message],
          %{count: 1},
          %{channel: :telegram, direction: :outbound}
        )

        :ok

      {:ok, %{status: status, body: response} = api_response} ->
        Logger.error("Telegram sendMedia failed: #{status} - #{inspect(response)}")
        telegram_api_error(api_response)

      {:error, reason} ->
        Logger.error("Telegram sendMedia request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp enforce_media_cap(size, cap, _kind) when size <= cap, do: :ok

  defp enforce_media_cap(size, cap, _kind) do
    {:error, {:byte_cap_exceeded, size, cap}}
  end

  defp telegram_api_error(%{status: status} = response) do
    case RetryHint.retry_after_ms(response) do
      {:ok, retry_after_ms} -> {:error, {:rate_limited, retry_after_ms}}
      :error -> {:error, "Telegram API error: #{status}"}
    end
  end

  defp maybe_release_claim(:ok, _claim), do: :ok

  defp maybe_release_claim({:error, _reason} = error, claim) do
    :ok = Idempotency.release_outbound_media_claim(claim)
    error
  end

  defp maybe_put_form(fields, _key, nil), do: fields
  defp maybe_put_form(fields, key, value), do: Keyword.put(fields, key, value)

  defp mime_from_path(path) do
    Map.get(@mime_by_extension, Path.extname(path), "application/octet-stream")
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
          metadata: %{chat_type: get_in(msg, ["chat", "type"]), user_id: to_string(user_id)}
        })

      {:ok, [message]}
    else
      {:ok, []}
    end
  end

  defp authorized_user?(user_id) do
    allowed = FermixCore.Config.channel_ingress_user_ids(:telegram)

    # Audit F-02: empty allowlist now denies everyone (was fail-open).
    # Operators must configure owner_user_id (auto-populates the allowlist)
    # or set fermix_channels.telegram.allowed_user_ids explicitly.
    to_string(user_id) in allowed
  end

  defp outbound_text_chunks(text, opts) when is_binary(text) do
    if telegram_html?(opts) do
      html_opts = Keyword.put(opts, :parse_mode, "HTML")
      split_markdown_for_telegram(text, [])
      |> Enum.map(fn chunk -> {basic_markdown_to_html(chunk), html_opts} end)
    else
      {text, opts} = prepare_outbound_text(text, opts)
      Enum.map(split_text_by_length(text), fn chunk -> {chunk, opts} end)
    end
  end

  defp telegram_html?(opts) do
    not Keyword.has_key?(opts, :parse_mode) and Keyword.get(opts, :format, :telegram_html) != :plain
  end

  defp split_markdown_for_telegram("", acc), do: Enum.reverse(acc)

  defp split_markdown_for_telegram(text, acc) do
    if telegram_rendered_length(text) <= @max_message_length do
      Enum.reverse([text | acc])
    else
      {chunk, rest} = take_rendered_prefix(text)
      split_markdown_for_telegram(rest, [chunk | acc])
    end
  end

  defp take_rendered_prefix(text) do
    graphemes = String.graphemes(text)
    count = rendered_prefix_count(graphemes, 1, length(graphemes), 1)
    String.split_at(text, semantic_split_count(graphemes, count))
  end

  defp rendered_prefix_count(graphemes, low, high, best) when low <= high do
    mid = div(low + high, 2)
    candidate = graphemes |> Enum.take(mid) |> Enum.join()

    if telegram_rendered_length(candidate) <= @max_message_length do
      rendered_prefix_count(graphemes, mid + 1, high, mid)
    else
      rendered_prefix_count(graphemes, low, mid - 1, best)
    end
  end

  defp rendered_prefix_count(_graphemes, _low, _high, best), do: best

  defp semantic_split_count(graphemes, count) do
    graphemes
    |> Enum.take(count)
    |> Enum.with_index(1)
    |> Enum.reverse()
    |> Enum.find_value(count, &semantic_split_at(&1, count))
  end

  defp semantic_split_at({grapheme, index}, count) do
    min_index = max(count - 512, 1)

    if index >= min_index and String.match?(grapheme, ~r/\s/u) do
      index
    end
  end

  defp telegram_rendered_length(text) do
    text
    |> basic_markdown_to_html()
    |> strip_html_tags()
    |> html_unescape()
    |> String.length()
  end

  defp split_text_by_length(text) do
    if String.length(text) <= @max_message_length do
      [text]
    else
      do_split_text_by_length(text, [])
    end
  end

  defp do_split_text_by_length("", acc), do: Enum.reverse(acc)

  defp do_split_text_by_length(text, acc) do
    {chunk, rest} = String.split_at(text, @max_message_length)
    do_split_text_by_length(rest, [chunk | acc])
  end

  defp strip_html_tags(text), do: Regex.replace(~r/<[^>]*>/u, text, "")

  defp html_unescape(text) do
    text
    |> String.replace("&quot;", "\"")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
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
