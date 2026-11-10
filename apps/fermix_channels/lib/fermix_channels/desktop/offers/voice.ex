defmodule FermixChannels.Desktop.Offers.Voice do
  @moduledoc """
  `voice` (M97 §3.2): calls from this computer, which reach the server's
  voice (M97 §9.2). Its device end is built beside the link by its own
  stage, which turns this state on in this one place; until then it is
  unavailable on every computer, whatever its switch says.
  """

  @behaviour FermixCore.Computers.Offer

  @sentence "Calls from this computer reach your server in a later update of Fermix."

  @impl true
  def id, do: :voice

  @impl true
  def label, do: "voice calls"

  @impl true
  def systems, do: [:macos, :linux]

  @impl true
  def state(switches, facts) when is_list(switches) and is_map(facts),
    do: {:unavailable, @sentence}
end
