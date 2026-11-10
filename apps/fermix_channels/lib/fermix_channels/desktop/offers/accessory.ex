defmodule FermixChannels.Desktop.Offers.Accessory do
  @moduledoc """
  `accessory` (M97 §3.2): a robot wired to this computer, whose calls take
  the voice path (M97 §9.4, D23). Its device end is built beside the link by
  its own stage, which turns this state on in this one place; until then it
  is unavailable on every computer, whatever its switch says.
  """

  @behaviour FermixCore.Computers.Offer

  @sentence "A robot on this computer reaches your server in a later update of Fermix."

  @impl true
  def id, do: :accessory

  @impl true
  def label, do: "the robot"

  @impl true
  def systems, do: [:macos, :linux]

  @impl true
  def state(switches, facts) when is_list(switches) and is_map(facts),
    do: {:unavailable, @sentence}
end
