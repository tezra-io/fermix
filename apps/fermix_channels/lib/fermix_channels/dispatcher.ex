defmodule FermixChannels.Dispatcher do
  @moduledoc """
  Routes normalized inbound messages to the configured agent.

  Builds an agent runtime message with a `reply_fn` so the agent can reply without
  knowing which channel it's talking to.
  """

  require Logger

  alias FermixChannels.Gateway.Authorizer
  alias FermixChannels.Gateway.Commands
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.Source
  alias FermixChannels.Gateway.Transcription
  alias FermixCore.Memory.Config
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Reply
  alias FermixCore.Telemetry

  @spec dispatch([Message.t() | map()], keyword()) :: :ok | {:error, term()}
  def dispatch(messages, opts) when is_list(messages) do
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

  defp build_reply_fn(_channel, %Message{} = message, reply_fn) when is_function(reply_fn, 1) do
    fn part ->
      observe_reply(fn -> reply_fn.(part) end, :override, nil, message)
    end
  end

  defp build_reply_fn(channel, %Message{} = message, _reply_fn),
    do: build_reply_fn(channel, message)

  defp build_reply_fn(channel, %Message{} = message) do
    text_reply = text_reply_fn(channel, message)
    media_reply = media_reply_fn(channel, message)

    fn
      {:text, text} when is_binary(text) ->
        observe_reply(fn -> text_reply.(text) end, :text, nil, message)

      {:media, %{kind: kind} = media_part} ->
        observe_reply(fn -> media_reply.(media_part) end, :media, kind, message)

      other ->
        {:error, {:invalid_reply_part, other}}
    end
  end

  defp text_reply_fn(channel, message) do
    channel.build_text_reply(message)
  end

  defp media_reply_fn(channel, message) do
    channel.build_media_reply(message)
  end

  @spec observe_reply(
          (() -> term()),
          :override | :text | :media,
          Reply.media_kind() | nil,
          Message.t()
        ) ::
          :ok | {:error, term()}
  defp observe_reply(fun, reply_type, media_kind, message) when is_function(fun, 0) do
    {result, duration_us} = Telemetry.timed_us(fun)

    emit_channel_reply_telemetry(message, result, reply_type, media_kind, duration_us)
    observe_reply_result(result, reply_type, media_kind)
  end

  defp observe_reply_result(:ok, _reply_type, _media_kind), do: :ok

  defp observe_reply_result({:error, reason} = error, reply_type, media_kind) do
    Logger.error("Channel reply delivery failed: #{inspect(reason)}")

    if reply_type == :media do
      :telemetry.execute(
        [:fermix, :channel, :media_send_error],
        %{count: 1},
        %{kind: media_kind, reason: reason}
      )
    end

    error
  end

  defp observe_reply_result(_other, _reply_type, _media_kind), do: :ok

  defp build_typing_fn(channel, %Message{reply_target: reply_target}) do
    if function_exported?(channel, :start_typing, 1) do
      fn -> channel.start_typing(reply_target) end
    end
  end

  defp to_agent_message(%Message{} = message), do: Map.from_struct(message)

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
    {normalize_result, normalize_duration_us} = Telemetry.timed_us(fn -> normalize_message(message) end)
    emit_normalize_telemetry(message, normalize_result, normalize_duration_us)

    with {:ok, reply_message} <- normalize_result,
         {:ok, authorization} <- authorize(reply_message),
         {:ok, reply_message} <-
           Transcription.maybe_transcribe_message(
             channel,
             reply_message,
             transcription_opts
           ) do
      reply_fn = build_reply_fn(channel, reply_message, reply_fn_override)
      typing_fn = build_typing_fn(channel, reply_message)

      context =
        command_context(
          reply_message,
          authorization,
          conversation_store,
          agent,
          agent_server,
          command_context_opts
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

        :passthrough ->
          deliver_to_agent(reply_message, authorization, agent, agent_server, reply_fn, typing_fn)
      end
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
        Logger.error("Dispatcher transcription failed: #{inspect(reason)}")
        error
    end
  end

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

  defp deliver_to_agent(message, authorization, agent, agent_server, reply_fn, typing_fn) do
    {result, duration_us} =
      Telemetry.timed_us(fn ->
        do_deliver_to_agent(message, authorization, agent, agent_server, reply_fn, typing_fn)
      end)

    emit_agent_delivery_telemetry(message, result, duration_us)
    result
  end

  defp do_deliver_to_agent(message, authorization, agent, agent_server, reply_fn, typing_fn) do
    if agent_alive?(agent_server) do
      agent_message =
        message
        |> to_agent_message()
        |> Map.put(:reply_fn, reply_fn)
        |> Map.put(:source_trust, authorization.trust)
        |> maybe_put_typing_fn(typing_fn)

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

      _ = reply_fn.({:text, "I'm restarting — please send your message again in a moment."})
      :ok
    end
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

  defp conversation_key(%Message{channel: channel, chat_id: chat_id, thread_ts: thread_ts})
       when not is_nil(thread_ts) do
    {channel, chat_id, thread_ts}
  end

  defp conversation_key(%Message{channel: channel, chat_id: chat_id, thread_scope: thread_scope}) do
    {channel, chat_id, thread_scope}
  end

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

  defp maybe_put_typing_fn(message, typing_fn) when is_function(typing_fn, 0) do
    Map.put(message, :typing_fn, typing_fn)
  end

  defp maybe_put_typing_fn(message, _typing_fn), do: message

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

  defp emit_channel_reply_telemetry(message, result, reply_type, media_kind, duration_us) do
    metadata =
      %{
        channel: message.channel,
        reply_type: reply_type,
        status: result_status(result)
      }
      |> maybe_put_metadata(:media_kind, media_kind)

    :telemetry.execute(
      [:fermix, :channel, :reply],
      %{duration_us: duration_us},
      metadata
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
