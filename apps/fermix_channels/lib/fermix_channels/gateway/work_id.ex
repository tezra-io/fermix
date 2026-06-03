defmodule FermixChannels.Gateway.WorkId do
  @moduledoc false

  @spec generate() :: String.t()
  def generate do
    "bg-" <> (5 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false))
  end
end
