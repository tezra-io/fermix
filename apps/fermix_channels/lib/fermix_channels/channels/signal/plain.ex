defmodule FermixChannels.Channels.Signal.Plain do
  @moduledoc """
  Signal's plain-text dialect: `FermixChannels.Outbound.Plain`, which Signal
  shares with iMessage (MILESTONE_54 §8.1).
  """

  alias FermixChannels.Outbound.Plain

  @doc "See `FermixChannels.Outbound.Plain.render/1`."
  @spec render(String.t()) :: String.t()
  defdelegate render(text), to: Plain

  @doc "See `FermixChannels.Outbound.Plain.rendered_length/1`."
  @spec rendered_length(String.t()) :: non_neg_integer()
  defdelegate rendered_length(text), to: Plain
end
