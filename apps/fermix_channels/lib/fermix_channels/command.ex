defmodule FermixChannels.Command do
  @moduledoc """
  Behaviour for channel-side slash commands handled before agent delivery.
  """

  alias FermixChannels.Message
  alias FermixCore.Channels.Outbound

  @callback name() :: String.t()
  @callback aliases() :: [String.t()]
  @callback description() :: String.t()
  @callback authorize(Message.t(), channel_metadata :: map(), context :: map()) ::
              :ok | {:error, :unauthorized}
  @callback execute(
              Message.t(),
              reply_fn :: Outbound.reply_fn(),
              context :: map()
            ) :: :ok | {:error, term()}
end
