defmodule FermixChannels.Gateway do
  @moduledoc """
  The gateway ingress facade: `ingest/2` is the single production entry point
  for inbound channel messages.

  It normalizes each message, authorizes it (dropping denied senders before
  transcription), transcribes audio, dispatches slash commands, and otherwise
  hands the turn to the queue via the agent delivery seam (building an outbound
  `reply_fn` so core replies without knowing the channel). Channel transports
  (pollers, webhooks, CLI) all route through here; `FermixChannels.Dispatcher`
  is a thin compatibility alias.
  """

  require Logger

  alias FermixChannels.Gateway.Authorizer
  alias FermixChannels.Gateway.ChannelRegistry
  alias FermixChannels.Gateway.Commands
  alias FermixChannels.Gateway.Delivery
  alias FermixChannels.Gateway.DraftStream
  alias FermixChannels.Gateway.MediaIngest
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.ReplyContext
  alias FermixChannels.Gateway.Source
  alias FermixChannels.Gateway.Transcription
  alias FermixCore.Agents.ConversationKey
  alias FermixCore.Memory.Config
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Telemetry

  @spec ingest([Message.t() | map()], keyword()) :: :ok | {:error, term()}
  def ingest(messages, opts) when is_list(messages) do
    channel = Keyword.fetch!(opts, :channel)
    agent = Keyword.fetch!(opts, :agent)
    agent_server = Keyword.fetch!(opts, :agent_server)
    transcription_opts = Keyword.get(opts, :transcription, [])
    reply_fn_override = Keyword.get(opts, :reply_fn)
    conversation_store = Keyword.get(opts, :conversation_store, ConversationStore)
    command_context_opts = command_context_opts(opts)

    Enum.reduce_while(messages, :ok, fn message, :ok ->
      case dispatch_message(
             channel,
             message,
             agent,
             agent_server,
             transcription_opts,
             reply_fn_override,
             conversation_store,
             command_context_opts
           ) do
        :ok ->
          {:cont, :ok}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp build_typing_fn(channel, %Message{reply_target: reply_target}) do
    if function_exported?(channel, :start_typing, 1) do
      fn -> channel.start_typing(reply_target) end
    end
  end

  # Reaction capability resolved once per turn (EMOJI_REACTION_ACKS §5.4): the
  # gateway is the only layer holding the channel module, so it flattens the
  # capability to plain data (the allowed emoji set) here and hands that to core.
  # `nil` ⇒ the `react` tool is not advertised; the model just sends a short text
  # ack. Never a runtime react-then-degrade branch — this is the one computed
  # decision (CLAUDE.md #12).
  defp build_reaction_spec(channel) do
    if function_exported?(channel, :reaction_capability, 0) do
      reaction_spec_for(channel.reaction_capability())
    end
  end

  defp reaction_spec_for(:any_emoji), do: %{emoji_set: :any}
  defp reaction_spec_for({:restricted, set}) when is_list(set), do: %{emoji_set: set}
  defp reaction_spec_for(:none), do: nil

  # Streaming eligibility (docs/design/CHANNEL_STREAMING.md §5.6): resolved
  # once per turn, HERE — the only layer holding the channel module. Returns a
  # closure spec the queue's turn task drives, or nil (typing-only, today's
  # exact path). Degradation is this one computed decision, never a runtime
  # retry-with-different-mechanism.
  #
  # "draft" needs a draft-capable channel (in-place edits); "block" sends
  # completed chunks as ordinary replies, so every channel qualifies.
  #
  # The `:raw` tier (M29 §8.4) is decided BEFORE the config consult: a machine
  # surface appends exact deltas to its own wire, so the chat-shaped streaming
  # knob does not apply to it. Its spec is a deliberately plain map — the queue
  # matches on it and drives the callback with no DraftStream engine.
  defp build_stream_spec(channel, %Message{} = message, reply_fn) do
    if raw_stream?(channel) do
      %{mode: :raw, callback: channel.build_raw_stream_callback(message)}
    else
      configured_stream_spec(channel, message, reply_fn)
    end
  end

  defp configured_stream_spec(channel, %Message{} = message, reply_fn) do
    case streaming_config(ChannelRegistry.channel_key(message.channel)) do
      "draft" ->
        if draft_capable?(channel), do: DraftStream.build_spec(channel, message)

      "block" ->
        DraftStream.build_block_spec(message.channel, fn text -> reply_fn.({:text, text}) end)

      _off ->
        nil
    end
  end

  defp raw_stream?(channel) do
    function_exported?(channel, :stream_capability, 0) and
      channel.stream_capability() == :raw
  end

  defp draft_capable?(channel) do
    function_exported?(channel, :stream_capability, 0) and
      channel.stream_capability() == :draft_edit
  end

  # Optional per-turn callbacks (M29 §4), built here for the same reason as
  # typing/reaction/stream: the gateway is the only layer holding the channel
  # module. An unimplemented callback yields nil and the key never appears on
  # the agent message, so core's checks stay one-sided.
  defp build_activity_callback(channel, %Message{} = message) do
    if function_exported?(channel, :build_activity_callback, 1) do
      channel.build_activity_callback(message)
    end
  end

  defp build_turn_result_fn(channel, %Message{} = message) do
    if function_exported?(channel, :build_turn_result, 1) do
      channel.build_turn_result(message)
    end
  end

  # A configured channel streams by default ("block" works on every channel and
  # is a no-op for non-streaming providers); an unknown or unconfigured channel
  # carries no live turns, so it stays off. Opt out per channel with
  # `streaming = "off"`.
  defp streaming_config(nil), do: "off"

  defp streaming_config(config_key) when is_atom(config_key) do
    case FermixCore.Config.channel(config_key) do
      {:ok, config} -> Keyword.get(config, :streaming, "block")
      {:error, :not_configured} -> "off"
    end
  end

  defp to_agent_message(%Message{} = message), do: Map.from_struct(message)

  @empty_inbound_reply "Your message looks empty — send some text or media I can read."

  # An empty inbound message (no text, no media — a sticker, poll, blank) is not
  # something the agent can act on. Reply once and short-circuit: returning
  # anything other than `:actionable` drops out of the dispatch `with` into the
  # `:replied_empty` branch, so NO turn is scheduled and the queue stays free.
  # Provider-agnostic — no LLM is touched. Runs AFTER authorization, so an
  # unauthorized sender is already dropped and never receives this reply.
  defp ensure_actionable(%Message{} = message, reply_fn) when is_function(reply_fn, 1) do
    if Message.actionable?(message) do
      :actionable
    else
      :telemetry.execute(
        [:fermix, :dispatcher, :empty_inbound],
        %{count: 1},
        %{channel: message.channel}
      )

      Logger.info(
        "Dispatcher: empty #{message.channel} message (no text, no media); replied without scheduling a turn"
      )

      _ = reply_fn.({:text, @empty_inbound_reply})
      :replied_empty
    end
  end

  # Fail-loud ingress replies (M21 §5.2/D14): a transcription or attachment
  # download failure replies to the sender with a reason-specific message instead
  # of the old silent drop. Built only after authorization (an unauthorized
  # sender is dropped first and never sees these) and NO turn is scheduled.
  @not_configured_reply "I couldn't transcribe your voice note — no transcription " <>
                          "backend is configured. Run `fermix setup` to add one."
  @transcription_failed_reply "I couldn't transcribe your voice note — the " <>
                                "transcription failed. Please try again."
  @download_failed_reply "I couldn't download your attachment to transcribe it. " <>
                           "Please try again."

  defp dispatch_message(
         channel,
         message,
         agent,
         agent_server,
         transcription_opts,
         reply_fn_override,
         conversation_store,
         command_context_opts
       ) do
    {normalize_result, normalize_duration_us} =
      Telemetry.timed_us(fn -> normalize_message(message) end)

    emit_normalize_telemetry(message, normalize_result, normalize_duration_us)

    with {:ok, reply_message} <- normalize_result,
         {:ok, authorization} <- authorize(reply_message) do
      reply_fn =
        Delivery.build_deliver(ReplyContext.new(channel, reply_message), reply_fn_override)

      deps = %{
        agent: agent,
        agent_server: agent_server,
        transcription_opts: transcription_opts,
        conversation_store: conversation_store,
        command_context_opts: command_context_opts
      }

      ingest_authorized(channel, reply_message, authorization, reply_fn, deps)
    else
      {:error, {:invalid_message, _field}} = error ->
        Logger.error("Dispatcher invalid message failed normalization: #{inspect(error)}")
        error

      {:error, reason} when reason in [:unauthorized, :unknown_channel] ->
        Logger.warning(
          "Dispatcher ingress denied #{channel} message (#{reason}); sender not authorized"
        )

        :ok

      {:error, reason} = error ->
        Logger.error("Dispatcher ingress failed (authorize): #{inspect(reason)}")
        error
    end
  end

  # Transcription materialization + fail-loud replies. Runs with the delivery
  # `reply_fn` already built, so a failure can reply to the sender. Building
  # reply_fn ahead of transcription is behavior-identical to building it after:
  # the channel reply closures read only routing fields (reply_target, thread_ts,
  # channel), which transcription/media-ingest never touch.
  #
  # Speech intake (D14) is the only ingress step with fail-loud sender replies: a
  # transcription failure — including the audio-download failure the transcription
  # step wraps as `{:attachment_download_failed, _}` — replies to the sender. Image
  # media-ingest keeps its pre-D14 log-only behavior (its download failures wrap
  # the same tuple, but are handled in `attach_images_and_deliver`, never here), so
  # a failed photo download never gets the transcription-worded reply.
  defp ingest_authorized(channel, reply_message, authorization, reply_fn, deps) do
    case Transcription.maybe_transcribe_message(
           channel,
           reply_message,
           deps.transcription_opts
         ) do
      {:ok, reply_message} ->
        attach_images_and_deliver(channel, reply_message, authorization, reply_fn, deps)

      {:error, {:transcription_failed, _reason} = wrapped} ->
        reply_ingress_failure(reply_message.channel, reply_fn, wrapped)

      {:error, {:attachment_download_failed, _reason} = wrapped} ->
        reply_ingress_failure(reply_message.channel, reply_fn, wrapped)

      {:error, reason} = error ->
        Logger.error("Dispatcher ingress failed (transcription): #{inspect(reason)}")
        error
    end
  end

  # Image materialization is not part of speech intake, so its download/read
  # failures stay log-only (pre-D14 behavior) — no sender reply, and the turn is
  # not scheduled.
  defp attach_images_and_deliver(channel, reply_message, authorization, reply_fn, deps) do
    with {:ok, reply_message} <- MediaIngest.maybe_attach_images(channel, reply_message),
         :actionable <- ensure_actionable(reply_message, reply_fn) do
      run_commands_or_deliver(channel, reply_message, authorization, reply_fn, deps)
    else
      :replied_empty ->
        :ok

      {:error, reason} = error ->
        Logger.error("Dispatcher ingress failed (media): #{inspect(reason)}")
        error
    end
  end

  # Channels the registry marks `commands?: false` never see the slash-command
  # pipeline: no parse, no dispatch, content reaches the model as ordinary text
  # (M29 §4). Every other channel keeps today's exact path.
  defp run_commands_or_deliver(channel, reply_message, authorization, reply_fn, deps) do
    closures = build_closures(channel, reply_message, reply_fn)

    if ChannelRegistry.commands?(reply_message.channel) do
      run_commands(reply_message, authorization, reply_fn, closures, deps)
    else
      deliver_to_agent(reply_message, authorization, deps.agent, deps.agent_server, closures)
    end
  end

  defp build_closures(channel, %Message{} = message, reply_fn) do
    %{
      reply_fn: reply_fn,
      typing_fn: build_typing_fn(channel, message),
      stream_spec: build_stream_spec(channel, message, reply_fn),
      reaction_spec: build_reaction_spec(channel),
      approval_button?: function_exported?(channel, :send_approval, 3),
      activity_callback: build_activity_callback(channel, message),
      turn_result_fn: build_turn_result_fn(channel, message)
    }
  end

  defp run_commands(reply_message, authorization, reply_fn, closures, deps) do
    context =
      command_context(
        reply_message,
        authorization,
        deps.conversation_store,
        deps.agent,
        deps.agent_server,
        deps.command_context_opts
      )

    case Commands.dispatch(
           Commands.parse(reply_message, bot_name: bot_name_for(reply_message.channel)),
           reply_fn,
           context
         ) do
      :ok ->
        :ok

      {:error, :unauthorized} ->
        :ok

      {:error, _reason} = error ->
        error

      # A command (e.g. /ultra) handled parsing/auth but wants the agent to run
      # a turn on a modified message (prefix stripped, run_profile tagged).
      {:enqueue, agent_message} ->
        deliver_to_agent(agent_message, authorization, deps.agent, deps.agent_server, closures)

      :passthrough ->
        deliver_to_agent(reply_message, authorization, deps.agent, deps.agent_server, closures)
    end
  end

  # The turn is never scheduled: reply once and return `:ok` (handled, like the
  # empty-inbound path), so the ingest batch continues to the next message.
  defp reply_ingress_failure(channel, reply_fn, wrapped) do
    Logger.error("Dispatcher ingress failed (transcription/media): #{inspect(wrapped)}")

    :telemetry.execute(
      [:fermix, :dispatcher, :ingress_failed],
      %{count: 1},
      %{channel: channel, reason: elem(wrapped, 0)}
    )

    _ = reply_fn.({:text, ingress_failure_copy(wrapped)})
    :ok
  end

  defp ingress_failure_copy({:transcription_failed, reason}),
    do: transcription_failure_copy(reason)

  defp ingress_failure_copy({:attachment_download_failed, reason}),
    do: download_failure_copy(reason)

  defp transcription_failure_copy(:not_configured), do: @not_configured_reply
  defp transcription_failure_copy({:unsupported_auth_mode, _mode}), do: @not_configured_reply

  defp transcription_failure_copy({:file_too_large, size_mb, cap_mb}) do
    "I couldn't transcribe your voice note — it's #{size_mb} MB, over the " <>
      "#{cap_mb} MB limit. Send a shorter clip."
  end

  defp transcription_failure_copy(_reason), do: @transcription_failed_reply

  defp download_failure_copy({:byte_cap_exceeded, _size, max_bytes}) do
    "I couldn't download that to transcribe — it's over the " <>
      "#{div(max_bytes, 1_048_576)} MB limit. Send a shorter clip."
  end

  defp download_failure_copy(_reason), do: @download_failed_reply

  defp authorize(%Message{} = message) do
    {result, duration_us} =
      Telemetry.timed_us(fn ->
        message
        |> Map.from_struct()
        |> Source.from_message()
        |> Authorizer.resolve()
      end)

    emit_authorize_telemetry(message, result, duration_us)
    result
  end

  defp deliver_to_agent(message, authorization, agent, agent_server, closures) do
    {result, duration_us} =
      Telemetry.timed_us(fn ->
        do_deliver_to_agent(message, authorization, agent, agent_server, closures)
      end)

    emit_agent_delivery_telemetry(message, result, duration_us)
    result
  end

  defp do_deliver_to_agent(message, authorization, agent, agent_server, closures) do
    if agent_alive?(agent_server) do
      agent_message = build_agent_message(message, authorization, closures)
      handle_agent_delivery(agent.handle_message(agent_message, agent_server))
    else
      # `MainAgent.handle_message/2` is a `GenServer.cast`, which silently
      # no-ops if the named server is not registered (or the registered
      # pid is dead). Without this check, messages arriving during a
      # supervisor restart would be dropped without any user-visible
      # signal. Surface a restart-in-progress reply instead.
      Logger.error(
        "Dispatcher: agent server #{inspect(agent_server)} unavailable; surfacing restart reply"
      )

      :telemetry.execute(
        [:fermix, :dispatcher, :agent_unavailable],
        %{count: 1},
        %{channel: message.channel}
      )

      _ =
        closures.reply_fn.(
          {:text, "I'm restarting — please send your message again in a moment."}
        )

      :ok
    end
  end

  defp build_agent_message(message, authorization, closures) do
    message
    |> to_agent_message()
    |> Map.put(:reply_fn, closures.reply_fn)
    |> Map.put(:source_trust, authorization.trust)
    |> maybe_put_approval_fn(message, authorization)
    |> maybe_put_approval_button(authorization, closures.approval_button?)
    |> maybe_put_typing_fn(closures.typing_fn)
    |> maybe_put_stream_spec(closures.stream_spec)
    |> maybe_put_reaction_spec(closures.reaction_spec)
    |> maybe_put_callback(:activity_callback, closures.activity_callback)
    |> maybe_put_callback(:turn_result_fn, closures.turn_result_fn)
  end

  defp agent_alive?(pid) when is_pid(pid), do: Process.alive?(pid)

  defp agent_alive?(name) when is_atom(name) do
    case GenServer.whereis(name) do
      nil -> false
      pid when is_pid(pid) -> Process.alive?(pid)
    end
  end

  defp agent_alive?({:via, _registry, _key} = via) do
    case GenServer.whereis(via) do
      nil -> false
      pid when is_pid(pid) -> Process.alive?(pid)
    end
  end

  defp agent_alive?(_other), do: false

  defp command_context(message, authorization, conversation_store, agent, agent_server, opts) do
    %{
      conversation_key: conversation_key(message),
      conversation_store: conversation_store,
      agent: agent,
      agent_server: agent_server,
      authorization: authorization
    }
    |> Map.merge(opts)
  end

  defp command_context_opts(opts) do
    %{
      memory_repo: Keyword.get(opts, :memory_repo, Config.repo_server()),
      memory_agent_id: Keyword.get(opts, :memory_agent_id, Config.agent_id()),
      memory_owner_id: Keyword.get(opts, :memory_owner_id, Config.owner_id())
    }
    |> maybe_put_context_opt(:route, Keyword.get(opts, :route))
    |> maybe_put_context_opt(:context_window, Keyword.get(opts, :context_window))
  end

  defp maybe_put_context_opt(context, _key, nil), do: context
  defp maybe_put_context_opt(context, key, value), do: Map.put(context, key, value)

  # The command surface must key the SAME conversation the queue and the turn key
  # (`/compact`, `/clear` operate on that history), so this derives it from the one
  # canonical helper instead of re-deriving the tuple here.
  defp conversation_key(%Message{} = message), do: ConversationKey.from(message)

  defp bot_name_for(channel) when is_binary(channel) do
    channel
    |> channel_atom()
    |> then(&Application.get_env(:fermix_channels, &1, []))
    |> Keyword.get(:bot_name)
  end

  defp channel_atom(channel) do
    String.to_existing_atom(channel)
  rescue
    ArgumentError -> :unknown
  end

  # The grant-approval seam (SANDBOX_ACCESS_APPROVAL_FLOW §6.1): an injected
  # closure — mirroring reply_fn — so core never depends on the channels layer.
  # Attached only for an operator turn; the `request_directory_access` tool
  # additionally gates on it, so a guest/unattended turn has no approval path.
  # Calling it binds a pending grant to THIS owner conversation's origin and, on a
  # re-ingestable channel, captures the verbatim request for auto-resume.
  #
  # Operator trust is necessary but not sufficient: a grant is answered with
  # `/confirm <token>`, so a channel the registry marks `commands?: false` has no
  # path back and the approval could never be completed (M29 §11). Withholding
  # the closure is what makes `request_directory_access` self-hide there.
  defp maybe_put_approval_fn(agent_message, %Message{channel: channel} = message, %{
         trust: :operator
       }) do
    if ChannelRegistry.commands?(channel) do
      Map.put(agent_message, :approval_fn, build_approval_fn(message))
    else
      agent_message
    end
  end

  defp maybe_put_approval_fn(agent_message, _message, _authorization), do: agent_message

  # Whether this channel renders a private one-tap approval button that carries the
  # confirmation token (SANDBOX_ACCESS_APPROVAL_FLOW). Core-facing plain data (like
  # `reaction_spec`, never the channel module): `request_directory_access` reads it
  # to decide whether it may drop the tap-to-copy `/confirm <token>` from a
  # shared-chat prompt. Attached only for an operator turn — the sole turn that can
  # reach the tool — mirroring `maybe_put_approval_fn`.
  defp maybe_put_approval_button(agent_message, %{trust: :operator}, approval_button?)
       when is_boolean(approval_button?) do
    Map.put(agent_message, :private_approval_button?, approval_button?)
  end

  defp maybe_put_approval_button(agent_message, _authorization, _approval_button?),
    do: agent_message

  defp build_approval_fn(%Message{} = message) do
    origin = %{
      channel: message.channel,
      chat_id: message.chat_id,
      thread_ts: message.thread_ts,
      user_id: approval_user_id(message.metadata),
      resume: resume_intent(message)
    }

    fn request -> Commands.Sandbox.store_pending_grant(request, origin) end
  end

  # A one-shot loopback origin (CLI, daemon) cannot be re-ingested — its reply
  # surface dies with the invocation — so it carries no resume intent (confirm
  # persists and asks the owner to re-run). A re-ingestable chat channel captures
  # the verbatim original request so confirm can auto-resume it.
  defp resume_intent(%Message{channel: channel} = message) when is_binary(channel) do
    if ChannelRegistry.local?(channel) do
      nil
    else
      %{content: message.content, reply_target: message.reply_target, sender: message.sender}
    end
  end

  defp approval_user_id(metadata) when is_map(metadata),
    do: Map.get(metadata, :user_id) || Map.get(metadata, "user_id")

  defp approval_user_id(_metadata), do: nil

  defp maybe_put_typing_fn(message, typing_fn) when is_function(typing_fn, 0) do
    Map.put(message, :typing_fn, typing_fn)
  end

  defp maybe_put_typing_fn(message, _typing_fn), do: message

  # Reaction spec is core-facing plain data (unlike the closures/stream spec,
  # which the queue strips before building `core_msg`) — the `react` tool reads
  # it from the turn context. Attached only when the channel resolved a
  # capability; absent otherwise, so `advertise?/1` sees `nil` and hides the tool.
  defp maybe_put_reaction_spec(message, nil), do: message

  defp maybe_put_reaction_spec(message, reaction_spec) when is_map(reaction_spec) do
    Map.put(message, :reaction_spec, reaction_spec)
  end

  defp maybe_put_stream_spec(message, %DraftStream.Spec{} = stream_spec) do
    Map.put(message, :stream_spec, stream_spec)
  end

  # The `:raw` tier's spec is a plain map by design (M29 §8.4): the queue
  # matches it and drives the callback directly, with no DraftStream engine.
  defp maybe_put_stream_spec(message, %{mode: :raw, callback: callback} = stream_spec)
       when is_function(callback, 1) do
    Map.put(message, :stream_spec, stream_spec)
  end

  defp maybe_put_stream_spec(message, _stream_spec), do: message

  # Optional channel-built turn callbacks: absent callback ⇒ absent key.
  defp maybe_put_callback(message, _key, nil), do: message

  defp maybe_put_callback(message, key, callback) when is_function(callback, 1) do
    Map.put(message, key, callback)
  end

  defp handle_agent_delivery(:ok), do: :ok

  defp handle_agent_delivery({:error, reason} = error) do
    Logger.error("Dispatcher agent delivery failed: #{inspect(reason)}")
    error
  end

  defp handle_agent_delivery(other) do
    Logger.error("Dispatcher agent delivery returned unexpected result: #{inspect(other)}")
    {:error, {:unexpected_agent_result, other}}
  end

  defp normalize_message(%Message{} = message), do: {:ok, message}

  defp normalize_message(message) when is_map(message) do
    with {:ok, attrs} <- required_message_attrs(message) do
      {:ok,
       Message.new!(
         Map.merge(attrs, %{
           thread_ts: message_value(message, :thread_ts),
           metadata: normalize_metadata(message_value(message, :metadata)),
           attachments: normalize_attachments(message_value(message, :attachments))
         })
       )}
    end
  end

  defp required_message_attrs(message) do
    Enum.reduce_while(
      [:id, :content, :sender, :channel, :chat_id, :reply_target],
      {:ok, %{}},
      fn key, {:ok, acc} ->
        case message_value(message, key) do
          value when is_binary(value) ->
            {:cont, {:ok, Map.put(acc, key, value)}}

          _ ->
            {:halt, {:error, {:invalid_message, key}}}
        end
      end
    )
  end

  defp message_value(message, key) do
    Map.get(message, key) || Map.get(message, Atom.to_string(key))
  end

  defp normalize_metadata(value) when is_map(value), do: value
  defp normalize_metadata(_value), do: %{}

  defp normalize_attachments(value) when is_list(value), do: value
  defp normalize_attachments(_value), do: []

  defp emit_normalize_telemetry(message, result, duration_us) do
    :telemetry.execute(
      [:fermix, :dispatcher, :normalize],
      %{duration_us: duration_us},
      %{
        channel: message_channel(message),
        status: result_status(result)
      }
    )
  end

  defp emit_authorize_telemetry(message, result, duration_us) do
    metadata =
      %{channel: message.channel, status: result_status(result)}
      |> maybe_put_metadata(:trust, authorization_trust(result))

    :telemetry.execute(
      [:fermix, :ingress, :authorize],
      %{duration_us: duration_us},
      metadata
    )
  end

  defp emit_agent_delivery_telemetry(message, result, duration_us) do
    :telemetry.execute(
      [:fermix, :dispatcher, :agent_delivery],
      %{duration_us: duration_us},
      %{channel: message.channel, status: result_status(result)}
    )
  end

  defp message_channel(%Message{channel: channel}), do: channel
  defp message_channel(message) when is_map(message), do: message_value(message, :channel)

  defp authorization_trust({:ok, authorization}), do: authorization.trust
  defp authorization_trust(_result), do: nil

  defp result_status(:ok), do: :ok
  defp result_status({:ok, _value}), do: :ok
  defp result_status({:error, :unauthorized}), do: :unauthorized
  defp result_status({:error, :unknown_channel}), do: :unknown_channel
  defp result_status({:error, _reason}), do: :error
  defp result_status(_other), do: :ok

  defp maybe_put_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_metadata(metadata, key, value), do: Map.put(metadata, key, value)
end
