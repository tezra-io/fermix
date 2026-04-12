defmodule FermixChannels.Dispatcher do
  @moduledoc """
  Routes normalized inbound messages to the configured agent.

  Attaches a `reply_fn` to each message so the agent can reply without
  knowing which channel it's talking to.
  """

  require Logger

  alias FermixChannels.Message

  @spec dispatch([Message.t()], keyword()) :: :ok
  def dispatch(messages, opts) when is_list(messages) do
    channel = Keyword.fetch!(opts, :channel)
    agent = Keyword.fetch!(opts, :agent)
    agent_server = Keyword.fetch!(opts, :agent_server)

    Enum.each(messages, fn message ->
      reply_fn = build_reply_fn(channel, message)
      agent_message = Map.put(message, :reply_fn, reply_fn)
      agent.handle_message(agent_message, agent_server)
    end)

    :ok
  end

  defp build_reply_fn(channel, %Message{reply_target: target, thread_ts: thread_ts}) do
    fn text ->
      send_opts = if thread_ts, do: [message_thread_id: thread_ts], else: []

      case channel.send_message(target, text, send_opts) do
        :ok ->
          :ok

        {:error, reason} = error ->
          Logger.error("Channel reply delivery failed: #{inspect(reason)}")
          error
      end
    end
  end
end
