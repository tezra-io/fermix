defmodule FermixChannels.Channels.Telegram do
  @moduledoc """
  Telegram Bot API channel integration.

  Parses webhook payloads from Telegram into standard messages,
  sends outbound messages via the Bot API, and verifies webhook
  authenticity via the secret token header.
  """

  @behaviour FermixChannels.Gateway.Channel

  require Logger

  alias FermixChannels.Gateway.ApprovalButton
  alias FermixChannels.Gateway.Idempotency
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.RetryHint
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixCore.Net.HttpClient
  alias FermixCore.Telemetry

  @bot_api_base "https://api.telegram.org"
  @health_timeout_ms 5_000
  @max_message_length 4096
  # Inbound image download cap (≤ Telegram's getFile 20 MB ceiling); the
  # post-receive guard in download_attachment/2 is the hard backstop for a
  # missing/lying declared file_size.
  @max_inbound_media_bytes 20 * 1_024 * 1_024
  @bullet_markdown_pattern ~r/^(\s*)[-*]\s+/u
  @heading_markdown_pattern ~r/^([ ]{0,3})\#{1,6}[ \t]+(.+?)(?:[ \t]+\#+[ \t]*)?$/u
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

  @spec parse_update(map()) ::
          {:ok, [FermixChannels.Gateway.Channel.message()]} | {:error, term()}
  def parse_update(update) do
    {result, duration_us} = Telemetry.timed_us(fn -> do_parse_update(update) end)
    ChannelTelemetry.emit_parse(:telegram, result, duration_us)
    maybe_emit_inbound_message(:telegram, result, duration_us)
    result
  end

  # Album policy for `Gateway.AlbumBuffer`: Telegram delivers a media group as
  # separate updates sharing a `media_group_id`, so coalesce by that id. A single
  # message has no group id and can never collide with an album key, so it passes
  # straight through.
  @impl true
  @spec album_classify(FermixChannels.Gateway.Channel.message()) ::
          FermixChannels.Gateway.Channel.album_classification()
  def album_classify(message) do
    case message |> Map.get(:metadata, %{}) |> Map.get(:media_group_id) do
      nil -> :passthrough
      group_id -> {:coalesce, group_id}
    end
  end

  defp do_parse_update(update) do
    cond do
      Map.has_key?(update, "message") ->
        parse_message(update["message"])

      Map.has_key?(update, "edited_message") ->
        parse_message(update["edited_message"])

      Map.has_key?(update, "callback_query") ->
        parse_callback_query(update["callback_query"])

      true ->
        {:ok, []}
    end
  end

  # An inline-button tap (SANDBOX_ACCESS_APPROVAL_FLOW) synthesizes the exact
  # inbound message a typed `/confirm <token>` would produce, so the tap funnels
  # through the unchanged Gateway.ingest -> Commands.parse -> Sandbox.confirm path
  # (single-use take, owner-only + same-origin validation, auto-resume). The
  # payload is namespaced `grant:<token>`; a payload without that prefix is not a
  # confirmation tap and is ignored. The origin fields are taken from the
  # callback: `from.id` is Telegram-authenticated, and chat/thread come from the
  # message the button rides on. The callback ids are stashed so the poller can
  # answer the query and strip the used button.
  defp parse_callback_query(%{"data" => data} = callback) when is_binary(data) do
    case ApprovalButton.parse_payload(data) do
      {:ok, token} -> {:ok, [synthesize_confirm(callback, token)]}
      :ignore -> {:ok, []}
    end
  end

  defp parse_callback_query(_callback), do: {:ok, []}

  defp synthesize_confirm(callback, token) do
    source = Map.get(callback, "message", %{})

    sender =
      get_in(callback, ["from", "username"]) || get_in(callback, ["from", "first_name"]) ||
        "unknown"

    ApprovalButton.confirm_message(%{
      id: "callback-#{callback["id"]}",
      sender: sender,
      channel: "telegram",
      chat_id: source |> get_in(["chat", "id"]) |> to_string(),
      thread_ts: source["message_thread_id"],
      user_id: get_in(callback, ["from", "id"]),
      token: token
    })
  end

  @impl true
  @spec send_message(String.t(), String.t()) :: :ok | {:error, term()}
  @spec send_message(String.t(), String.t(), FermixChannels.Gateway.Channel.send_opts()) ::
          :ok | {:error, term()}
  def send_message(chat_id, text, opts \\ []) do
    {chunks, render_duration_us} =
      Telemetry.timed_us(fn -> outbound_text_chunks(text, opts) end)

    ChannelTelemetry.emit_render(:telegram, :ok, render_duration_us)

    {results, send_duration_us} =
      Telemetry.timed_us(fn ->
        Enum.map(chunks, fn {chunk, chunk_opts} ->
          post_send_message(chat_id, chunk, chunk_opts)
        end)
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        ChannelTelemetry.emit_message(:telegram, :outbound, length(chunks), send_duration_us)
        :ok

      error ->
        error
    end
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
  def send_media(chat_id, media_part, opts \\ [])
      when is_binary(chat_id) and is_map(media_part) do
    with {:ok, claim} <- Idempotency.claim_outbound_media(:telegram, chat_id, media_part) do
      send_claimed_media(claim, chat_id, media_part, opts)
    end
  end

  @impl true
  @spec build_text_reply(FermixChannels.Gateway.Channel.message()) :: (String.t() ->
                                                                         :ok | {:error, term()})
  def build_text_reply(%Message{reply_target: reply_target, thread_ts: thread_ts}) do
    opts = if thread_ts, do: [message_thread_id: thread_ts], else: []

    fn text -> send_message(reply_target, text, opts) end
  end

  @impl true
  @spec build_media_reply(FermixChannels.Gateway.Channel.message()) ::
          (FermixChannels.Gateway.Channel.media_part() -> :ok | {:error, term()})
  def build_media_reply(%Message{reply_target: reply_target, thread_ts: thread_ts}) do
    opts = if thread_ts, do: [message_thread_id: thread_ts], else: []

    fn media_part -> send_media(reply_target, media_part, opts) end
  end

  # -- Owner-approval one-tap button (SANDBOX_ACCESS_APPROVAL_FLOW) --

  @impl true
  @spec send_approval(Message.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def send_approval(%Message{reply_target: reply_target, thread_ts: thread_ts}, text, token)
      when is_binary(text) and is_binary(token) do
    # The prompt rides the normal send path (markdown->HTML, so the backticked
    # `/confirm <token>` fallback still renders as a tap-to-copy code span); the
    # inline keyboard is the additive one-tap affordance. callback_data carries
    # the `grant:<token>` payload (the callback handler strips the prefix and
    # prepends `/confirm `); an 8-char token is far under Telegram's 64-byte
    # callback_data cap.
    markup = %{
      inline_keyboard: [[%{text: "✅ Approve", callback_data: ApprovalButton.payload(token)}]]
    }

    opts = [reply_markup: markup]
    opts = if thread_ts, do: Keyword.put(opts, :message_thread_id, thread_ts), else: opts
    send_message(reply_target, text, opts)
  end

  @doc """
  Acknowledge an inline-button tap: clear the client spinner
  (`answerCallbackQuery`) and strip the used button (`editMessageReplyMarkup`) so
  it can't be re-tapped. Best-effort UI cleanup fired by the poller on every tap —
  the confirmation token is single-use regardless, and the confirm outcome reaches
  the owner through the normal `/confirm` text reply. Failures are logged, not
  raised, so a spinner/edit hiccup never crashes the poll loop.
  """
  @spec acknowledge_callback(map(), keyword()) :: :ok | {:error, :not_configured}
  def acknowledge_callback(callback, opts \\ []) when is_map(callback) do
    with {:ok, token} <- get_bot_token() do
      answer_callback_query(token, Map.get(callback, "id"), opts)
      strip_callback_button(token, Map.get(callback, "message"), opts)
      :ok
    end
  end

  defp answer_callback_query(_token, nil, _opts), do: :ok

  defp answer_callback_query(token, callback_id, opts) do
    url = "#{@bot_api_base}/bot#{token}/answerCallbackQuery"
    post_callback_ack(url, %{callback_query_id: callback_id}, opts, "answerCallbackQuery")
  end

  defp strip_callback_button(
         token,
         %{"message_id" => message_id, "chat" => %{"id" => chat_id}},
         opts
       ) do
    url = "#{@bot_api_base}/bot#{token}/editMessageReplyMarkup"

    body = %{
      chat_id: to_string(chat_id),
      message_id: message_id,
      reply_markup: %{inline_keyboard: []}
    }

    post_callback_ack(url, body, opts, "editMessageReplyMarkup")
  end

  defp strip_callback_button(_token, _message, _opts), do: :ok

  defp post_callback_ack(url, body, opts, label) do
    case Req.new(url: url, method: :post, json: body)
         |> Req.merge(req_options(opts))
         |> HttpClient.request("Telegram #{label}") do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status, body: response}} ->
        Logger.warning("Telegram #{label} failed: #{status} - #{inspect(response)}")
        :ok

      {:error, reason} ->
        Logger.warning("Telegram #{label} request failed: #{inspect(reason)}")
        :ok
    end
  end

  @impl true
  @spec verify_webhook(Plug.Conn.t()) :: {:error, :unsupported_transport}
  def verify_webhook(_conn), do: {:error, :unsupported_transport}

  @impl true
  @spec health_check(keyword()) :: FermixChannels.Gateway.Channel.health_result()
  def health_check(opts \\ []) do
    start = System.monotonic_time(:millisecond)

    with {:ok, token} <- get_bot_token() do
      Req.new(url: "#{@bot_api_base}/bot#{token}/getMe", method: :post, json: %{})
      |> Req.merge(health_req_options(opts))
      |> HttpClient.request("Telegram health")
      |> classify_health_response(start)
    else
      {:error, :not_configured} ->
        {:error, {:misconfigured, "telegram bot_token is not configured"}}
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
           |> HttpClient.request("Telegram sendChatAction") do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # -- Reactions (docs/design/EMOJI_REACTION_ACKS.md §9) --

  # Telegram's setMessageReaction accepts only a fixed set of standard emoji.
  # This mirrors the common, unambiguous entries of Telegram's documented
  # reaction set; VS16/ZWJ-ambiguous glyphs (❤, ⚡, 🕊, ✍, ☃) are omitted so
  # every entry round-trips as an exact string, pending a live smoke test. The
  # gateway turns this into the `react` tool's emoji enum, so the model can only
  # propose a supported glyph; `react/2` re-validates at the boundary and fails
  # loud on anything off-set — input validation, not a rule-#12 fallback.
  @reaction_emoji ~w(👍 👎 🔥 🥰 👏 😁 🤔 🤯 😱 🎉 🤩 🙏 👌 💯 🤣 😢 😍 🙈 🤝 👀 🫡 🤗 😎 😭)

  @impl true
  @spec reaction_capability() :: {:restricted, [String.t()]}
  def reaction_capability, do: {:restricted, @reaction_emoji}

  @impl true
  @spec react(Message.t(), String.t()) :: :ok | {:error, term()}
  def react(message, emoji, opts \\ [])

  def react(%Message{id: message_id, reply_target: chat_id}, emoji, opts) when is_binary(emoji) do
    with :ok <- validate_reaction_emoji(emoji),
         {:ok, message_id_int} <- parse_message_id(message_id),
         {:ok, token} <- get_bot_token() do
      url = "#{@bot_api_base}/bot#{token}/setMessageReaction"

      body = %{
        chat_id: chat_id,
        message_id: message_id_int,
        reaction: [%{type: "emoji", emoji: emoji}]
      }

      case Req.new(url: url, method: :post, json: body)
           |> Req.merge(req_options(opts))
           |> HttpClient.request("Telegram setMessageReaction") do
        {:ok, %{status: 200}} -> :ok
        {:ok, api_response} -> telegram_api_error(api_response)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp validate_reaction_emoji(emoji) do
    if emoji in @reaction_emoji, do: :ok, else: {:error, {:unsupported_emoji, emoji}}
  end

  defp parse_message_id(message_id) do
    case Integer.parse(message_id) do
      {int, ""} -> {:ok, int}
      _ -> {:error, {:invalid_message_id, message_id}}
    end
  end

  # -- Draft streaming (docs/design/CHANNEL_STREAMING.md §6) --

  @impl true
  @spec stream_capability() :: :draft_edit
  def stream_capability, do: :draft_edit

  @impl true
  @spec open_draft(FermixChannels.Gateway.Channel.message(), String.t()) ::
          {:ok, integer()} | {:error, term()}
  def open_draft(%Message{reply_target: reply_target, thread_ts: thread_ts}, text)
      when is_binary(text) do
    body =
      %{chat_id: reply_target, text: draft_html(text), parse_mode: "HTML"}
      |> maybe_put_draft_thread(thread_ts)

    with {:ok, token} <- get_bot_token() do
      post_draft_open(token, body)
    end
  end

  @impl true
  @spec edit_draft(FermixChannels.Gateway.Channel.message(), integer(), String.t()) ::
          :ok | {:error, term()}
  def edit_draft(%Message{reply_target: reply_target}, message_id, text)
      when is_integer(message_id) and is_binary(text) do
    with {:ok, token} <- get_bot_token() do
      post_draft_edit(token, reply_target, message_id, draft_html(text))
    end
  end

  @impl true
  @spec seal_draft(FermixChannels.Gateway.Channel.message(), integer(), String.t()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def seal_draft(%Message{reply_target: reply_target}, message_id, text)
      when is_integer(message_id) and is_binary(text) do
    {prefix, remainder} = seal_split(text)

    with {:ok, token} <- get_bot_token(),
         :ok <-
           seal_with_retry(token, reply_target, message_id, basic_markdown_to_html(prefix), 1) do
      {:ok, remainder}
    end
  end

  @impl true
  @spec discard_draft(FermixChannels.Gateway.Channel.message(), integer()) ::
          :ok | {:error, term()}
  def discard_draft(%Message{reply_target: reply_target}, message_id)
      when is_integer(message_id) do
    with {:ok, token} <- get_bot_token() do
      post_draft_delete(token, reply_target, message_id)
    end
  end

  # -- Internals --

  defp classify_health_response(
         {:ok, %{status: 200, body: %{"ok" => true, "result" => result}}},
         start
       ) do
    username = Map.get(result, "username")
    detail = if present?(username), do: "bot @#{username} authenticated", else: "Bot API ok"
    {:ok, %{detail: detail, latency_ms: elapsed_ms(start)}}
  end

  defp classify_health_response({:ok, %{status: status, body: body}}, _start) do
    {:error, telegram_health_error(status, body)}
  end

  defp classify_health_response({:error, reason}, _start), do: {:error, {:network, reason}}

  defp telegram_health_error(404, body) do
    {:auth_failed,
     "invalid bot token (Telegram API HTTP 404: #{api_description(body)}); " <>
       "paste the BotFather token without a bot prefix"}
  end

  defp telegram_health_error(status, body) when status in [401, 403] do
    {:auth_failed, "Telegram API HTTP #{status}: #{api_description(body)}"}
  end

  defp telegram_health_error(status, body), do: {:server_error, status, body}

  defp api_description(%{"description" => description}) when is_binary(description),
    do: description

  defp api_description(_body), do: "request rejected"

  defp post_send_message(chat_id, text, opts) do
    with {:ok, token} <- get_bot_token() do
      url = "#{@bot_api_base}/bot#{token}/sendMessage"

      body =
        %{chat_id: chat_id, text: text}
        |> maybe_put_parse_mode(opts)
        |> maybe_put_reply_to(opts)
        |> maybe_put_message_thread_id(opts)
        |> maybe_put_reply_markup(opts)

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

  # Render the largest prefix of the cumulative draft text that fits the
  # message limit. Re-rendering the full prefix each tick keeps partial
  # markdown structurally balanced; mid-stream overflow holds the draft at
  # the prefix — authoritative multi-chunk delivery happens once, at seal.
  defp draft_html(text) do
    text
    |> seal_split()
    |> elem(0)
    |> basic_markdown_to_html()
  end

  defp seal_split(text) do
    if telegram_rendered_length(text) <= @max_message_length do
      {text, nil}
    else
      {prefix, rest} = take_rendered_prefix(text)
      {prefix, rest}
    end
  end

  defp post_draft_open(token, body) do
    url = "#{@bot_api_base}/bot#{token}/sendMessage"

    result =
      Req.new(url: url, method: :post, json: body)
      |> Req.merge(req_options([]))
      |> HttpClient.request("Telegram sendMessage (draft)")

    case result do
      {:ok, %{status: 200, body: %{"result" => %{"message_id" => id}}}} when is_integer(id) ->
        {:ok, id}

      {:ok, %{status: 200, body: response}} ->
        Logger.error("Telegram draft open returned no message_id: #{inspect(response)}")
        {:error, :missing_message_id}

      {:ok, %{status: status, body: response} = api_response} ->
        Logger.error("Telegram draft open failed: #{status} - #{inspect(response)}")
        telegram_api_error(api_response)

      {:error, reason} ->
        Logger.error("Telegram draft open request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Interim edits are best-effort by contract: no retry, warnings not errors —
  # the engine counts failures and freezes the preview; the seal still lands.
  defp post_draft_edit(token, chat_id, message_id, html) do
    case post_edit_message_text(token, chat_id, message_id, html) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status, body: response} = api_response} ->
        Logger.warning("Telegram draft edit failed: #{status} - #{inspect(response)}")
        telegram_api_error(api_response)

      {:error, reason} ->
        Logger.warning("Telegram draft edit request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # The seal is the one reliable draft write: bounded retries honoring
  # Telegram's retry_after; an idempotent no-op ("message is not modified")
  # counts as success — the desired final state already holds.
  # The whole retry budget (sleeps + requests) must stay inside the engine's
  # 15 s seal timeout — a longer wait would get the engine hard-killed
  # mid-sleep, leaving an orphaned draft. Worst case here: 2 × 4 s sleeps +
  # 3 requests ≈ 11 s. If Telegram demands a longer retry_after than that,
  # retries exhaust and the engine's seal-failure path discards the draft and
  # the full reply goes out as a fresh send — the designed recovery.
  @seal_retry_attempts 3
  @seal_retry_base_ms 400
  @seal_retry_max_wait_ms 4_000

  defp seal_with_retry(token, chat_id, message_id, html, attempt) do
    case post_seal_edit(token, chat_id, message_id, html) do
      :ok -> :ok
      {:error, reason} -> retry_seal(token, chat_id, message_id, html, attempt, reason)
    end
  end

  defp retry_seal(_token, _chat_id, _message_id, _html, @seal_retry_attempts, reason) do
    Logger.error("Telegram draft seal exhausted retries: #{inspect(reason)}")
    {:error, reason}
  end

  defp retry_seal(token, chat_id, message_id, html, attempt, reason) do
    Process.sleep(seal_backoff_ms(attempt, reason))
    seal_with_retry(token, chat_id, message_id, html, attempt + 1)
  end

  defp seal_backoff_ms(_attempt, {:rate_limited, retry_after_ms}),
    do: min(retry_after_ms, @seal_retry_max_wait_ms)

  defp seal_backoff_ms(attempt, _reason), do: @seal_retry_base_ms * attempt

  defp post_seal_edit(token, chat_id, message_id, html) do
    case post_edit_message_text(token, chat_id, message_id, html) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: 400, body: %{"description" => description}}}
      when is_binary(description) ->
        classify_seal_400(description)

      {:ok, %{status: status, body: response} = api_response} ->
        Logger.warning("Telegram draft seal attempt failed: #{status} - #{inspect(response)}")
        telegram_api_error(api_response)

      {:error, reason} ->
        Logger.warning("Telegram draft seal request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp classify_seal_400(description) do
    if String.contains?(description, "message is not modified") do
      :ok
    else
      {:error, "Telegram API error: 400 - #{description}"}
    end
  end

  defp post_edit_message_text(token, chat_id, message_id, html) do
    url = "#{@bot_api_base}/bot#{token}/editMessageText"
    body = %{chat_id: chat_id, message_id: message_id, text: html, parse_mode: "HTML"}

    Req.new(url: url, method: :post, json: body)
    |> Req.merge(req_options([]))
    |> HttpClient.request("Telegram editMessageText")
  end

  defp post_draft_delete(token, chat_id, message_id) do
    url = "#{@bot_api_base}/bot#{token}/deleteMessage"
    body = %{chat_id: chat_id, message_id: message_id}

    result =
      Req.new(url: url, method: :post, json: body)
      |> Req.merge(req_options([]))
      |> HttpClient.request("Telegram deleteMessage")

    case result do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status, body: response} = api_response} ->
        Logger.warning("Telegram draft delete failed: #{status} - #{inspect(response)}")
        telegram_api_error(api_response)

      {:error, reason} ->
        Logger.warning("Telegram draft delete request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp maybe_put_draft_thread(body, nil), do: body
  defp maybe_put_draft_thread(body, thread_ts), do: Map.put(body, :message_thread_id, thread_ts)

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

      {:ok,
       Req.new(url: url, method: :post, form_multipart: fields) |> Req.merge(req_options(opts))}
    else
      :error -> {:error, {:unsupported_media_kind, kind}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp media_request(_token, _chat_id, _media_part, _opts), do: {:error, :invalid_media_part}

  defp post_media(request) do
    {result, duration_us} =
      Telemetry.timed_us(fn -> HttpClient.request(request, "Telegram sendMedia") end)

    case result do
      {:ok, %{status: 200}} ->
        ChannelTelemetry.emit_message(:telegram, :outbound, 1, duration_us)
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
    case render_heading_line(line) do
      {:ok, html} ->
        html

      :error ->
        line
        |> normalize_bullet_marker()
        |> render_inline_markdown()
    end
  end

  defp render_heading_line(line) do
    case Regex.run(@heading_markdown_pattern, line) do
      [_, indent, content] ->
        {:ok, indent <> "<b>" <> render_heading_content(content) <> "</b>"}

      nil ->
        :error
    end
  end

  defp render_heading_content(content) do
    content
    |> remove_heading_bold_markers()
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

  defp remove_heading_bold_markers(text) do
    Regex.replace(~r/\*\*([^*\n]+?)\*\*/u, text, "\\1")
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

  defp maybe_put_reply_markup(body, opts) do
    case Keyword.get(opts, :reply_markup) do
      nil -> body
      markup when is_map(markup) -> Map.put(body, :reply_markup, markup)
    end
  end

  # Ingress authorization is centralized in the gateway dispatcher
  # (`FermixChannels.Gateway.Authorizer`); the adapter parses every message and
  # records the sender id in `metadata.user_id` so the gateway can authorize.
  defp parse_message(msg) do
    user_id = get_in(msg, ["from", "id"])
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
        metadata:
          %{chat_type: get_in(msg, ["chat", "type"]), user_id: to_string(user_id)}
          |> maybe_put_media_group(msg["media_group_id"]),
        attachments: parse_attachments(msg)
      })

    {:ok, [message]}
  end

  # Inbound photos arrive as a list of PhotoSize (file_id only — no URL); the
  # bytes are fetched lazily by download_attachment/2 at the gateway media-ingest
  # step. Audio-bearing messages (voice/audio/audio-MIME document/video note)
  # parse to a single `:audio` attachment the gateway transcription step consumes
  # (M21 §5.2/D17). A message carries at most one of these media keys, so clause
  # order among them is irrelevant — each must precede the catch-all.
  defp parse_attachments(%{"photo" => sizes}) when is_list(sizes) and sizes != [] do
    case largest_photo(sizes) do
      %{"file_id" => file_id} = size when is_binary(file_id) ->
        [
          %{
            kind: :image,
            file_id: file_id,
            url: nil,
            mime_type: "image/jpeg",
            size_bytes: Map.get(size, "file_size")
          }
        ]

      _ ->
        []
    end
  end

  # Voice note = OGG/Opus; Telegram fixes the container, so the mime is constant.
  defp parse_attachments(%{"voice" => %{"file_id" => file_id} = voice}) when is_binary(file_id) do
    [audio_attachment_ref(file_id, "audio/ogg", Map.get(voice, "file_size"))]
  end

  # Audio file (music/clip): carries its own declared mime type.
  defp parse_attachments(%{"audio" => %{"file_id" => file_id} = audio}) when is_binary(file_id) do
    [audio_attachment_ref(file_id, Map.get(audio, "mime_type"), Map.get(audio, "file_size"))]
  end

  # Round video note (≤1 min): the payload has no mime field — hosted backends
  # take the MP4 container directly (D17), so the mime is fixed to video/mp4.
  defp parse_attachments(%{"video_note" => %{"file_id" => file_id} = note})
       when is_binary(file_id) do
    [audio_attachment_ref(file_id, "video/mp4", Map.get(note, "file_size"))]
  end

  # A document is transcribable only when it declares an audio mime type; any
  # other document falls through to the catch-all (unparsed, as before).
  defp parse_attachments(%{
         "document" => %{"file_id" => file_id, "mime_type" => "audio/" <> _ = mime} = doc
       })
       when is_binary(file_id) do
    [audio_attachment_ref(file_id, mime, Map.get(doc, "file_size"))]
  end

  defp parse_attachments(_msg), do: []

  defp audio_attachment_ref(file_id, mime_type, size_bytes) do
    %{kind: :audio, file_id: file_id, url: nil, mime_type: mime_type, size_bytes: size_bytes}
  end

  # A multi-attachment message ("album") shares a media_group_id across the
  # separate updates Telegram delivers it as; the poller buffers by this id so
  # the album becomes one turn. Single messages have no media_group_id.
  defp maybe_put_media_group(metadata, group_id) when is_binary(group_id) and group_id != "",
    do: Map.put(metadata, :media_group_id, group_id)

  defp maybe_put_media_group(metadata, _group_id), do: metadata

  # Prefer the largest variant whose declared file_size is under the cap so we
  # never request an over-limit original; if none declares a size under the cap,
  # fall back to the highest-resolution variant and let the download cap decide.
  defp largest_photo(sizes) do
    candidates =
      case Enum.filter(sizes, &photo_under_cap?/1) do
        [] -> sizes
        under_cap -> under_cap
      end

    Enum.max_by(candidates, &photo_pixels/1, fn -> nil end)
  end

  defp photo_under_cap?(size) do
    case Map.get(size, "file_size") do
      n when is_integer(n) -> n <= @max_inbound_media_bytes
      _ -> true
    end
  end

  defp photo_pixels(%{"width" => w, "height" => h}) when is_integer(w) and is_integer(h),
    do: w * h

  defp photo_pixels(_size), do: 0

  defp maybe_emit_inbound_message(channel, {:ok, messages}, duration_us) when messages != [] do
    ChannelTelemetry.emit_message(channel, :inbound, length(messages), duration_us)
  end

  defp maybe_emit_inbound_message(_channel, _result, _duration_us), do: :ok

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
    not Keyword.has_key?(opts, :parse_mode) and
      Keyword.get(opts, :format, :telegram_html) != :plain
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

  @impl true
  @spec download_attachment(FermixChannels.Gateway.Channel.message(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def download_attachment(_message, attachment) when is_map(attachment) do
    with :ok <- preflight_size_cap(attachment),
         {:ok, token} <- get_bot_token(),
         {:ok, file_path} <- resolve_file_path(attachment_value(attachment, :file_id), token),
         {:ok, body} <- download_file(token, file_path),
         {:ok, path} <- write_temp_file(body, attachment, file_path) do
      {:ok, path}
    end
  end

  defp preflight_size_cap(attachment) do
    case attachment_value(attachment, :size_bytes) do
      size when is_integer(size) and size > @max_inbound_media_bytes ->
        {:error, {:byte_cap_exceeded, size, @max_inbound_media_bytes}}

      _ ->
        :ok
    end
  end

  # file_path is ~1h ephemeral, so resolve it fresh on every download — never
  # cache the resulting token-bearing URL.
  defp resolve_file_path(file_id, token) when is_binary(file_id) and file_id != "" do
    result =
      Req.new(
        url: "#{@bot_api_base}/bot#{token}/getFile",
        method: :post,
        json: %{file_id: file_id}
      )
      |> Req.merge(req_options([]))
      |> HttpClient.request("Telegram getFile")

    case result do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => %{"file_path" => file_path}}}}
      when is_binary(file_path) ->
        {:ok, file_path}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Telegram getFile failed: #{status} - #{inspect(body)}")
        {:error, {:getfile_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_file_path(_missing, _token), do: {:error, :missing_attachment_reference}

  # The download URL carries the bot token — never log it.
  defp download_file(token, file_path) do
    result =
      Req.new(url: "#{@bot_api_base}/file/bot#{token}/#{file_path}", method: :get)
      |> Req.merge(req_options([]))
      |> HttpClient.request("Telegram file download")

    case result do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        enforce_inbound_cap(body)

      {:ok, %{status: 200, body: body}} ->
        enforce_inbound_cap(IO.iodata_to_binary(body))

      {:ok, %{status: status, body: body}} ->
        Logger.error("Telegram file download failed: #{status} - #{inspect(body)}")
        {:error, {:download_failed, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enforce_inbound_cap(body) when byte_size(body) > @max_inbound_media_bytes do
    Logger.error("Telegram inbound media exceeded #{@max_inbound_media_bytes}-byte cap; refusing")
    {:error, {:byte_cap_exceeded, byte_size(body), @max_inbound_media_bytes}}
  end

  defp enforce_inbound_cap(body), do: {:ok, body}

  defp write_temp_file(body, attachment, file_path) do
    path =
      Path.join(
        System.tmp_dir!(),
        "fermix-telegram-#{System.unique_integer([:positive])}#{temp_extension(attachment, file_path)}"
      )

    case File.write(path, body) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  # Prefer the attachment's declared mime for the temp extension. Telegram makes
  # the Audio `mime_type` optional, so when it is absent, use the real extension
  # from the getFile `file_path` (the authoritative filename) — otherwise a
  # mime-less audio clip lands in a `.bin` temp file and the hosted backends
  # reject the `application/octet-stream` upload with a 400.
  defp temp_extension(attachment, file_path) do
    case attachment_value(attachment, :mime_type) do
      mime when is_binary(mime) and mime != "" -> normalize_extension(mime)
      _absent -> extension_from_path(file_path)
    end
  end

  defp extension_from_path(file_path) do
    case Path.extname(file_path) do
      "" -> ".bin"
      ext -> ext
    end
  end

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

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
  defp elapsed_ms(start), do: System.monotonic_time(:millisecond) - start
end
