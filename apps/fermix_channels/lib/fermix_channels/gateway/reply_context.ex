defmodule FermixChannels.Gateway.ReplyContext do
  @moduledoc """
  Where an outbound reply goes: the channel adapter module plus the normalized
  inbound `Message` it answers (the adapter's `build_text_reply`/
  `build_media_reply` close over the message's reply_target + thread).

  Built by the gateway from an authorized inbound message and handed to
  `FermixChannels.Gateway.Delivery` to render + send. Core never sees it — it
  receives only the opaque delivery closure `Delivery.build_deliver/1` returns.
  """

  alias FermixChannels.Gateway.Message

  @enforce_keys [:channel, :message]
  defstruct [:channel, :message]

  @type t :: %__MODULE__{channel: module(), message: Message.t()}

  @spec new(module(), Message.t()) :: t()
  def new(channel, %Message{} = message) when is_atom(channel) do
    %__MODULE__{channel: channel, message: message}
  end
end
