defmodule FermixChannels.Gateway.Command do
  @moduledoc """
  Behaviour for channel-side slash commands handled before agent delivery.
  """

  alias FermixChannels.Gateway.Commands.Authorization
  alias FermixChannels.Gateway.Message
  alias FermixCore.Reply

  @callback name() :: String.t()
  @callback aliases() :: [String.t()]
  @callback description() :: String.t()
  @callback authorize(Message.t(), channel_metadata :: map(), context :: map()) ::
              :ok | {:error, Authorization.refusal()}
  @callback execute(
              Message.t(),
              reply_fn :: Reply.reply_fn(),
              context :: map()
            ) :: :ok | {:error, term()} | {:enqueue, Message.t()}
end
