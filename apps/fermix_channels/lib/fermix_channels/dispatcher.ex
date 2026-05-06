defmodule FermixChannels.Dispatcher do
  @moduledoc """
  Routes normalized inbound messages to the configured agent.

  Builds an agent runtime message with a `reply_fn` so the agent can reply without
  knowing which channel it's talking to.
  """

  require Logger

  alias FermixChannels.Message

  @spec dispatch([Message.t() | map()], keyword()) :: :ok | {:error, term()}
  def dispatch(messages, opts) when is_list(messages) do
    channel = Keyword.fetch!(opts, :channel)
    agent = Keyword.fetch!(opts, :agent)
    agent_server = Keyword.fetch!(opts, :agent_server)
    transcription_opts = Keyword.get(opts, :transcription, [])

    Enum.reduce_while(messages, :ok, fn message, :ok ->
      case dispatch_message(channel, message, agent, agent_server, transcription_opts) do
        :ok ->
          {:cont, :ok}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp build_reply_fn(channel, %Message{} = message) do
    reply_fn = channel.build_reply(message)

    fn text ->
      case reply_fn.(text) do
        :ok ->
          :ok

        {:error, reason} = error ->
          Logger.error("Channel reply delivery failed: #{inspect(reason)}")
          error
      end
    end
  end

  defp build_typing_fn(channel, %Message{reply_target: reply_target}) do
    if function_exported?(channel, :start_typing, 1) do
      fn -> channel.start_typing(reply_target) end
    end
  end

  defp to_agent_message(%{__struct__: _} = message), do: Map.from_struct(message)
  defp to_agent_message(message) when is_map(message), do: message_attrs(message)

  defp dispatch_message(channel, message, agent, agent_server, transcription_opts) do
    with {:ok, message} <-
           FermixCore.Transcription.maybe_transcribe_message(
             channel,
             message,
             transcription_opts
           ),
         {:ok, reply_message} <- normalize_message(message) do
      reply_fn = build_reply_fn(channel, reply_message)
      typing_fn = build_typing_fn(channel, reply_message)

      agent_message =
        message
        |> to_agent_message()
        |> Map.put(:reply_fn, reply_fn)
        |> maybe_put_typing_fn(typing_fn)

      handle_agent_delivery(agent.handle_message(agent_message, agent_server))
    else
      {:error, {:invalid_message, _field}} = error ->
        Logger.error("Dispatcher invalid message failed normalization: #{inspect(error)}")
        error

      {:error, reason} = error ->
        Logger.error("Dispatcher transcription failed: #{inspect(reason)}")
        error
    end
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

  defp message_attrs(message) do
    {:ok, attrs} = required_message_attrs(message)

    Map.merge(attrs, %{
      thread_ts: message_value(message, :thread_ts),
      metadata: normalize_metadata(message_value(message, :metadata)),
      attachments: normalize_attachments(message_value(message, :attachments))
    })
  end

  defp message_value(message, key) do
    Map.get(message, key) || Map.get(message, Atom.to_string(key))
  end

  defp normalize_metadata(value) when is_map(value), do: value
  defp normalize_metadata(_value), do: %{}

  defp normalize_attachments(value) when is_list(value), do: value
  defp normalize_attachments(_value), do: []
end
