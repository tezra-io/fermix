defmodule FermixCore.Channels.Outbound do
  @moduledoc """
  Shared outbound reply contract for channel adapters and channel-aware tools.
  """

  @type media_kind :: :image | :document | :audio | :video | :voice

  @type media_part :: %{
          required(:kind) => media_kind(),
          required(:path) => String.t(),
          optional(:caption) => String.t(),
          optional(:filename) => String.t(),
          optional(:mime_type) => String.t()
        }

  @type outbound :: {:text, String.t()} | {:media, media_part()}
  @type reply_fn :: (outbound() -> :ok | {:error, term()})
end
