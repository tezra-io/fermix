defmodule FermixChannels.Bench.ReplyChannel do
  @moduledoc false

  def build_text_reply(_message) do
    fn _text -> :ok end
  end

  def build_media_reply(_message) do
    fn _media_part -> :ok end
  end
end
