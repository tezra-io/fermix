defmodule FermixChannels.Dispatcher do
  @moduledoc """
  Routes normalized inbound messages to the configured agent.

  Builds an agent runtime message with a `reply_fn` so the agent can reply without
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

      agent_message =
        message
        |> Map.from_struct()
        |> Map.put(:reply_fn, reply_fn)

      agent.handle_message(agent_message, agent_server)
    end)

    :ok
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
end
