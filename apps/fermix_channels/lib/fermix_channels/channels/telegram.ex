defmodule FermixChannels.Channels.Telegram do
  @moduledoc """
  Telegram Bot API channel integration.

  Parses webhook payloads from Telegram into standard messages,
  sends outbound messages via the Bot API, and verifies webhook
  authenticity via the secret token header.
  """

  @behaviour FermixChannels.Gateway.Channel

  require Logger

  alias FermixChannels.Channels.Telegram.Markdown
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

  @bot_api_base "https://api.telegram.org"
  @health_timeout_ms 5_000
  # Presentation constants (CHANNEL_LONGFORM_PRESENTATION §4.2, §9 decision 4).
  # A reply lands as section-shaped cards, not as 4096-unit walls: @card_limit_units
  # IS the card — one concept, used both when splitting a finished reply and as
  # the streaming engine's rotation threshold (§6). The entity budget is an
  # independent fill condition (hrefs add entities without adding rendered
  # length), and a fenced block bigger than @max_inline_code_units ships as a
  # document instead of being split into two corrupt halves.
  @card_limit_units 1_400
  @entity_budget 90
  @max_inline_code_units 3_800
  # The `format: :plain` dialect is measured in graphemes (no rendering happens),
  # so its limit is the raw-text headroom under Telegram's 4096 cap.
  @plain_limit_units 4_000
  # Draft freeze limit: the largest prefix a single draft message may hold.
  @draft_limit_units 4_000
  @code_caption "Code from this reply"
  @max_caption_chars 1_024
  # Inbound image download cap (≤ Telegram's getFile 20 MB ceiling); the
  # post-receive guard in download_attachment/2 is the hard backstop for a
  # missing/lying declared file_size.
  @max_inbound_media_bytes 20 * 1_024 * 1_024
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
      :ignore -> parse_proposal_callback(callback, data)
    end
  end

  defp parse_callback_query(_callback), do: {:ok, []}

  # A skill-curation proposal tap (`skillcur:a:`/`skillcur:d:`) synthesizes the
  # typed `/skills approve|deny <token>` message the same way — the typed
  # command stays the single code path (MILESTONE_26_SKILL_CURATION §6.6).
  defp parse_proposal_callback(callback, data) do
    case ProposalButton.parse_payload(data) do
      {:ok, action, token} -> {:ok, [synthesize_skills_action(callback, action, token)]}
      :ignore -> {:ok, []}
    end
  end

  defp synthesize_confirm(callback, token) do
    ApprovalButton.confirm_message(Map.put(callback_origin(callback), :token, token))
  end

  defp synthesize_skills_action(callback, action, token) do
    ProposalButton.action_message(
      callback
      |> callback_origin()
      |> Map.merge(%{action: action, token: token})
    )
  end

  defp callback_origin(callback) do
    source = Map.get(callback, "message", %{})

    sender =
      get_in(callback, ["from", "username"]) || get_in(callback, ["from", "first_name"]) ||
        "unknown"

    %{
      id: "callback-#{callback["id"]}",
      sender: sender,
      channel: "telegram",
      chat_id: source |> get_in(["chat", "id"]) |> to_string(),
      thread_ts: source["message_thread_id"],
      user_id: get_in(callback, ["from", "id"])
    }
  end

  @impl true
  @spec send_message(String.t(), String.t()) :: :ok | {:error, term()}
  @spec send_message(String.t(), String.t(), FermixChannels.Gateway.Channel.send_opts()) ::
          :ok | {:error, term()}
  def send_message(chat_id, text, opts \\ []) do
    {{chunks, code_blocks}, render_duration_us} =
      Telemetry.timed_us(fn -> outbound_text_chunks(text, opts) end)

    ChannelTelemetry.emit_render(:telegram, :ok, render_duration_us)

    # The outbound rows are emitted per delivered chunk inside `send_chunk/2`,
    # not once here for the whole reply (design §8).
    case send_chunks(chat_id, chunks) do
      {:ok, _message_ids} -> send_code_documents(chat_id, code_blocks, opts)
      {:error, _reason} = error -> error
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

  # -- Skill-curation proposal buttons (MILESTONE_26_SKILL_CURATION §6.6) --

  @impl true
  @spec send_proposal(map(), String.t(), String.t()) :: :ok | {:error, term()}
  def send_proposal(%{chat_id: chat_id}, text, token)
      when is_binary(chat_id) and is_binary(text) and is_binary(token) do
    # Target-addressed (proactive — no inbound message to reply to). One inline
    # row of two buttons; a tap synthesizes the typed `/skills approve|deny`
    # command, and the poller's callback ack strips both buttons.
    markup = %{
      inline_keyboard: [
        [
          %{text: "✅ Approve", callback_data: ProposalButton.approve_payload(token)},
          %{text: "❌ Deny", callback_data: ProposalButton.deny_payload(token)}
        ]
      ]
    }

    send_message(chat_id, text, reply_markup: markup)
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
  @spec rotation_spec() :: FermixChannels.Gateway.Channel.rotation_spec()
  def rotation_spec do
    %{measure: &Markdown.rendered_utf16_length/1, rotate_at: @card_limit_units}
  end

  @impl true
  @spec open_draft(FermixChannels.Gateway.Channel.message(), String.t()) ::
          {:ok, integer()} | {:error, term()}
  def open_draft(%Message{reply_target: reply_target, thread_ts: thread_ts}, text)
      when is_binary(text) do
    body =
      %{
        chat_id: reply_target,
        text: draft_html(text),
        parse_mode: "HTML",
        link_preview_options: %{is_disabled: true}
      }
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
         :ok <- seal_with_retry(token, reply_target, message_id, Markdown.to_html(prefix), 1) do
      {:ok, remainder}
    end
  end

  @impl true
  @spec discard_draft(FermixChannels.Gateway.Channel.message(), integer()) ::
          :ok | {:error, term()}
  def discard_draft(%Message{reply_target: reply_target}, message_id)
      when is_integer(message_id) do
    with {:ok, token} <- get_bot_token() do
      post_delete_message(token, reply_target, message_id)
    end
  end

  # -- Ephemeral messages (docs/design/CHANNEL_LONGFORM_PRESENTATION.md §5) --

  @impl true
  @spec send_ephemeral(FermixChannels.Gateway.Channel.message(), String.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def send_ephemeral(%Message{reply_target: reply_target, thread_ts: thread_ts}, text)
      when is_binary(text) do
    opts = if thread_ts, do: [message_thread_id: thread_ts], else: []

    with {:ok, chunks} <- ephemeral_chunks(text, opts),
         {:ok, ids} <- send_chunks(reply_target, chunks) do
      collect_message_ids(ids)
    end
  end

  @impl true
  @spec delete_message(FermixChannels.Gateway.Channel.message(), String.t()) ::
          :ok | {:error, term()}
  def delete_message(%Message{reply_target: reply_target}, message_id)
      when is_binary(message_id) do
    with {:ok, id} <- parse_message_id(message_id),
         {:ok, token} <- get_bot_token() do
      post_delete_message(token, reply_target, id)
    end
  end

  # An ephemeral message notifies nobody — including on its first chunk, unlike
  # a reply (§4.3), because a thought must never ring.
  defp ephemeral_chunks(text, opts) do
    case outbound_text_chunks(text, opts) do
      {chunks, []} ->
        {:ok, Enum.map(chunks, fn chunk -> %{chunk | silent?: true} end)}

      # A thought line is far too short to promote a fenced block to a document,
      # and an ephemeral document could not be swept with the text. Refuse the
      # send rather than half-deliver it.
      {_chunks, [_ | _]} ->
        {:error, :ephemeral_code_block}
    end
  end

  # The caller deletes these ids later, so an id-less send is a refusal: it
  # would leave a thought message nothing can sweep.
  defp collect_message_ids(ids) do
    if Enum.all?(ids, &is_integer/1) do
      {:ok, Enum.map(ids, &Integer.to_string/1)}
    else
      Logger.error("Telegram ephemeral send returned no message id: #{inspect(ids)}")
      {:error, :missing_message_id}
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

  defp post_send_message(chat_id, text, opts, silent?) do
    with {:ok, token} <- get_bot_token() do
      url = "#{@bot_api_base}/bot#{token}/sendMessage"

      body =
        %{chat_id: chat_id, text: text, link_preview_options: %{is_disabled: true}}
        |> maybe_put_parse_mode(opts)
        |> maybe_put_reply_to(opts)
        |> maybe_put_message_thread_id(opts)
        |> maybe_put_reply_markup(opts)
        |> maybe_put_silent(silent?)

      result =
        Req.new(url: url, method: :post, json: body)
        |> Req.merge(req_options(opts))
        |> HttpClient.request("Telegram sendMessage")

      case result do
        {:ok, %{status: 200, body: body}} ->
          {:ok, sent_message_id(body)}

        {:ok, %{status: 400, body: %{"description" => description} = response} = api_response}
        when is_binary(description) ->
          Logger.error("Telegram sendMessage failed: 400 - #{inspect(response)}")
          classify_send_400(description, api_response)

        {:ok, %{status: status, body: response} = api_response} ->
          Logger.error("Telegram sendMessage failed: #{status} - #{inspect(response)}")
          telegram_api_error(api_response)

        {:error, reason} ->
          Logger.error("Telegram request failed: #{inspect(reason)}")
          {:error, reason}
      end
    else
      # M30 §11.3: an unconfigured bot token means there is no Telegram client
      # to send through, which is the `:adapter_unavailable` kind of the closed
      # delivery vocabulary — not a bare atom the delivery normalizer would have
      # to guess at, and then log as a contract violation.
      {:error, :not_configured} -> {:error, {:permanent, :adapter_unavailable}}
    end
  end

  # The delivered message's id, or nil when a 200 carried no `result`. A missing
  # id is NOT a send failure — the message reached the chat, and reporting an
  # error here would have the caller deliver it a second time. Only the
  # ephemeral path needs the id (to delete the message later) and it is the one
  # that refuses without it.
  defp sent_message_id(%{"result" => %{"message_id" => id}}) when is_integer(id), do: id
  defp sent_message_id(_body), do: nil

  # A parse failure is the one recoverable send error: the description names the
  # renderer defect, and the caller resends the raw markdown once. Every other
  # 400 keeps the structured platform form.
  defp classify_send_400(description, api_response) do
    if String.contains?(description, "can't parse entities") do
      {:error, {:parse_entities, description}}
    else
      telegram_api_error(api_response)
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
    |> Markdown.to_html()
  end

  # Freeze-at-limit: the draft holds the first ladder chunk and the raw
  # remainder is handed back for normal (chunked) delivery. A draft that opens
  # with a single fenced block bigger than the limit is the one shape the ladder
  # cannot cut — it stays whole, Telegram refuses it, and the engine's
  # seal-failure path discards the draft and re-delivers the reply through
  # send_message/3, which promotes that block to an attachment.
  defp seal_split(text) do
    if Markdown.rendered_utf16_length(text) <= @draft_limit_units do
      {text, nil}
    else
      split_at_draft_limit(text)
    end
  end

  defp split_at_draft_limit(text) do
    [prefix | _rest] =
      Splitter.split(text,
        limit: @draft_limit_units,
        measure: &Markdown.rendered_utf16_length/1
      )

    {prefix, draft_remainder(text, prefix)}
  end

  # The splitter only ever strips from a chunk's edges, so the sealed prefix is a
  # prefix of the trimmed text and the remainder can be cut from the ORIGINAL
  # text — keeping it a verbatim suffix the caller can deliver as-is.
  defp draft_remainder(text, prefix) do
    lead = byte_size(text) - byte_size(String.trim_leading(text))
    assert_draft_prefix!(text, lead, prefix)
    consumed = lead + byte_size(prefix)

    text
    |> binary_part(consumed, byte_size(text) - consumed)
    |> String.trim_leading()
    |> blank_to_nil()
  end

  defp assert_draft_prefix!(text, lead, prefix) do
    rest = binary_part(text, lead, byte_size(text) - lead)

    if String.starts_with?(rest, prefix) do
      :ok
    else
      raise RuntimeError,
            "Telegram draft prefix is not a prefix of the draft text: #{inspect(prefix)}"
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(remainder), do: remainder

  defp post_draft_open(token, body) do
    url = "#{@bot_api_base}/bot#{token}/sendMessage"

    {result, duration_us} =
      Telemetry.timed_us(fn ->
        Req.new(url: url, method: :post, json: body)
        |> Req.merge(req_options([]))
        |> HttpClient.request("Telegram sendMessage (draft)")
      end)

    case result do
      {:ok, %{status: 200, body: %{"result" => %{"message_id" => id}}}} when is_integer(id) ->
        # Every bubble a stream CREATES is one delivered outbound message — the
        # first open and each rotation's fresh open alike (design §8). Without
        # this, an answer that streams and seals in place left zero outbound
        # rows for the whole turn. Edits and seals of an existing bubble emit
        # nothing (see post_draft_edit/4, post_seal_edit/4): they rewrite a
        # message already counted, and are visible as [:fermix, :channel,
        # :stream] phases.
        ChannelTelemetry.emit_message(:telegram, :outbound, 1, duration_us)
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
    case post_edit_message_text(token, chat_id, message_id, html, req_options([])) do
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
  # seal timeout — a longer wait would get the engine hard-killed mid-request,
  # leaving an orphaned draft next to the re-delivered reply. That only holds if
  # each request is itself bounded: without an explicit `receive_timeout` a seal
  # edit inherits Req's own default, and one attempt can outlast the whole
  # budget. So the per-request window is DERIVED from the ladder — every attempt
  # plus every between-attempt sleep fits @seal_budget_ms:
  #
  #   @seal_retry_attempts × @seal_request_timeout_ms
  #     + (@seal_retry_attempts - 1) × @seal_retry_max_wait_ms  ≤  @seal_budget_ms
  #
  # If Telegram demands a longer retry_after than that, retries exhaust and the
  # engine's seal-failure path discards the draft and the full reply goes out as
  # a fresh send — the designed recovery.
  #
  # Read that inequality as the SIZING RULE, not as an enforced total: it bounds
  # the response wait, which is the part that was unbounded, and three things
  # outside a per-request option still add to a ladder run. `HttpClient` re-issues
  # a request once on a transport `:closed`, so an attempt can cost two windows;
  # connection setup happens inside the pool checkout under Mint's own timeout;
  # and `@pool_checkout_timeout_ms` is its own ceiling. The ladder is therefore
  # much tighter than Req's default, not provably inside the engine's deadline.
  @seal_retry_attempts 3
  @seal_retry_base_ms 400
  @seal_retry_max_wait_ms 4_000
  # Mirrors FermixChannels.Gateway.DraftStream's @seal_timeout_ms: the deadline
  # after which the engine is killed. Restated here on purpose — a change to
  # either is a deliberate change to how a seal can fail.
  @seal_budget_ms 15_000
  # Sleeps happen between attempts, so there is one fewer sleep than attempt.
  @seal_sleep_budget_ms @seal_retry_max_wait_ms * (@seal_retry_attempts - 1)
  @seal_request_timeout_ms div(@seal_budget_ms - @seal_sleep_budget_ms, @seal_retry_attempts)

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
    case post_edit_message_text(token, chat_id, message_id, html, seal_req_options()) do
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

  defp post_edit_message_text(token, chat_id, message_id, html, req_opts) do
    url = "#{@bot_api_base}/bot#{token}/editMessageText"

    body = %{
      chat_id: chat_id,
      message_id: message_id,
      text: html,
      parse_mode: "HTML",
      link_preview_options: %{is_disabled: true}
    }

    Req.new(url: url, method: :post, json: body)
    |> Req.merge(req_opts)
    |> HttpClient.request("Telegram editMessageText")
  end

  # Only the seal is bounded: interim edits are best-effort and keep whatever
  # the channel's configured req_options say. The bound wins over a configured
  # receive_timeout — the ladder's deadline is the engine's, not the operator's.
  defp seal_req_options do
    req_options([])
    |> Keyword.put(:receive_timeout, @seal_request_timeout_ms)
  end

  # Shared by `discard_draft/2` (a live draft) and `delete_message/2` (a swept
  # ephemeral thought) — one delete call site, two thin callback wrappers.
  # A delete emits no `channel_msg` row: it is not an outbound message, and the
  # thought it removes was already counted when it was sent. The sweep itself is
  # visible as a [:fermix, :channel, :stream] phase.
  defp post_delete_message(token, chat_id, message_id) do
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
        Logger.warning("Telegram deleteMessage failed: #{status} - #{inspect(response)}")
        telegram_api_error(api_response)

      {:error, reason} ->
        Logger.warning("Telegram deleteMessage request failed: #{inspect(reason)}")
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

  # M30 §11.3: the adapter owns platform knowledge and returns the structured
  # status/rate-limit forms of the closed delivery vocabulary. `RetryHint` stays
  # authoritative whenever Telegram supplies a retry-after hint; the response
  # body reaches the local log above, never the returned reason.
  defp telegram_api_error(%{status: status} = response) do
    case RetryHint.retry_after_ms(response) do
      {:ok, retry_after_ms} -> {:error, {:rate_limited, retry_after_ms}}
      :error -> {:error, {:http_status, status}}
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

  defp maybe_put_silent(body, false), do: body
  defp maybe_put_silent(body, true), do: Map.put(body, :disable_notification, true)

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

  # One reply becomes: N text chunks (sent first, in order) plus the fenced code
  # blocks too big to render inline, promoted to file attachments. Each chunk
  # carries both the HTML it sends and the raw markdown it came from — the raw
  # form is what the parse-failure recovery resends.
  @typep outbound_chunk :: %{
           text: String.t(),
           raw: String.t(),
           opts: keyword(),
           silent?: boolean()
         }

  @spec outbound_text_chunks(String.t(), keyword()) ::
          {[outbound_chunk()], [%{lang: String.t() | nil, body: String.t()}]}
  defp outbound_text_chunks(text, opts) when is_binary(text) and is_list(opts) do
    if telegram_html?(opts) do
      html_chunks(text, opts)
    else
      {plain_chunks(text, opts), []}
    end
  end

  defp html_chunks(text, opts) do
    {text, code_blocks} = Markdown.extract_oversized_code(text, @max_inline_code_units)
    html_opts = Keyword.put(opts, :parse_mode, "HTML")

    chunks =
      text
      |> Splitter.split(
        limit: @card_limit_units,
        measure: &Markdown.rendered_utf16_length/1,
        entity_count: &Markdown.entity_count/1,
        entity_budget: @entity_budget
      )
      |> Enum.map(fn chunk -> {Markdown.to_html(chunk), chunk, html_opts} end)
      |> with_notification()

    {chunks, code_blocks}
  end

  defp plain_chunks(text, opts) do
    text
    |> Splitter.split(limit: @plain_limit_units)
    |> Enum.map(fn chunk -> {chunk, chunk, opts} end)
    |> with_notification()
  end

  # One reply, one ring (§4.3): the first message of the sequence notifies,
  # every later one is silent.
  defp with_notification(rendered) do
    rendered
    |> Enum.with_index()
    |> Enum.map(fn {{text, raw, opts}, index} ->
      %{text: text, raw: raw, opts: opts, silent?: index > 0}
    end)
  end

  defp telegram_html?(opts) do
    not Keyword.has_key?(opts, :parse_mode) and
      Keyword.get(opts, :format, :telegram_html) != :plain
  end

  # Strictly sequential: a failed send aborts the remainder rather than
  # half-delivering a reply out of order. Returns each delivered message's id in
  # send order — what the ephemeral thought path needs to delete them later.
  defp send_chunks(chat_id, chunks) do
    chunks
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, ids} ->
      case send_chunk(chat_id, chunk) do
        {:ok, message_id} -> {:cont, {:ok, [message_id | ids]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_ids()
  end

  defp reverse_ids({:ok, ids}), do: {:ok, Enum.reverse(ids)}
  defp reverse_ids({:error, _reason} = error), do: error

  # One delivered message is one outbound row, emitted here rather than once for
  # the whole reply (design §8): a reply that half-lands then reports truthfully
  # what WAS delivered instead of reporting nothing. The parse-failure resend is
  # inside the timed span on purpose — it is a second attempt at the same one
  # message, so it still emits a single row.
  defp send_chunk(chat_id, chunk) do
    {result, duration_us} = Telemetry.timed_us(fn -> post_chunk(chat_id, chunk) end)
    emit_delivered(result, duration_us)
    result
  end

  defp post_chunk(chat_id, chunk) do
    case post_send_message(chat_id, chunk.text, chunk.opts, chunk.silent?) do
      {:error, {:parse_entities, description}} -> resend_unformatted(chat_id, chunk, description)
      result -> result
    end
  end

  defp emit_delivered({:ok, _message_id}, duration_us),
    do: ChannelTelemetry.emit_message(:telegram, :outbound, 1, duration_us)

  defp emit_delivered({:error, _reason}, _duration_us), do: :ok

  # Sanctioned Rule 12 exception (design §4.3, decision §9.3): a renderer defect
  # must never eat the reply. Exactly one retry, of this chunk only, as the raw
  # markdown with no parse_mode — loud in the log and marked in telemetry so the
  # defect stays visible. A second failure is returned.
  defp resend_unformatted(chat_id, chunk, description) do
    Logger.error("Telegram rejected formatted message (#{description}); resending it unformatted")

    ChannelTelemetry.emit_render(:telegram, {:error, :plain_fallback}, 0)

    chat_id
    |> post_send_message(chunk.raw, Keyword.delete(chunk.opts, :parse_mode), chunk.silent?)
    |> close_recovery()
  end

  # The unformatted resend ends the recovery: a repeat refusal reaches the caller
  # as the platform's structured 400, never as a marker inviting another retry.
  defp close_recovery({:error, {:parse_entities, _description}}),
    do: {:error, {:http_status, 400}}

  defp close_recovery(result), do: result

  defp send_code_documents(_chat_id, [], _opts), do: :ok

  defp send_code_documents(chat_id, code_blocks, opts) do
    code_blocks
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {code_block, index}, :ok ->
      case send_code_document(chat_id, code_block, index, opts) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # The body is uploaded from a temp file the adapter owns: written here,
  # removed on every path (success, send error, write error).
  defp send_code_document(chat_id, %{lang: lang, body: body}, index, opts) do
    path = code_temp_path(index)

    try do
      case File.write(path, body) do
        :ok ->
          send_media(chat_id, code_media_part(path, lang, index), media_opts(opts))

        {:error, reason} ->
          Logger.error("Telegram code attachment write failed (#{path}): #{inspect(reason)}")
          {:error, reason}
      end
    after
      discard_temp_file(path)
    end
  end

  defp code_media_part(path, lang, index) do
    %{
      kind: :document,
      path: path,
      filename: "code-#{index}.txt",
      mime_type: "text/plain",
      caption: code_caption(lang)
    }
  end

  defp code_caption(nil), do: @code_caption

  defp code_caption(lang) when is_binary(lang) do
    String.slice("#{@code_caption} (#{lang})", 0, @max_caption_chars)
  end

  defp code_temp_path(index) do
    unique = System.unique_integer([:positive])
    Path.join(System.tmp_dir!(), "fermix-telegram-code-#{unique}-#{index}.txt")
  end

  defp discard_temp_file(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("Telegram code attachment cleanup failed (#{path}): #{inspect(reason)}")
        :ok
    end
  end

  # Only the transport/threading options belong on the attachment; a reply
  # markup or parse mode meant for the text chunks must not ride along.
  defp media_opts(opts), do: Keyword.take(opts, [:message_thread_id, :req_options])

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
         {:ok, path} <-
           MediaDownload.write_temp_bytes(body, "telegram", temp_extension(attachment, file_path)) do
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
    Req.new(url: "#{@bot_api_base}/file/bot#{token}/#{file_path}", method: :get)
    |> Req.merge(req_options([]))
    |> MediaDownload.get_capped(@max_inbound_media_bytes, "Telegram file download")
    |> handle_file_response()
  end

  defp handle_file_response({:ok, body}), do: {:ok, body}

  defp handle_file_response({:error, {:http_status, status, body}}) do
    Logger.error("Telegram file download failed: #{status} - #{inspect(body)}")
    {:error, {:download_failed, status}}
  end

  defp handle_file_response({:error, reason}), do: {:error, reason}

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
