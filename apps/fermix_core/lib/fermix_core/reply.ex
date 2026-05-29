defmodule FermixCore.Reply do
  @moduledoc """
  Outbound reply contract: the text/media reply shape that core produces
  (agent turns, the `send_attachment` tool) and the channel layer delivers.
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
