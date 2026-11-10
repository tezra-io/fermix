defmodule FermixChannels.Desktop.Offers.Notifications do
  @moduledoc """
  `notifications` (M97 §3.2): the server's notifications shown on this
  computer (M97 §9.6, M88 §6.2). Its device end is built beside the link by
  its own stage, which turns this state on in this one place; until then it
  is unavailable on every computer, whatever its switch says.
  """

  @behaviour FermixCore.Computers.Offer

  @sentence "Notifications from your server reach this computer in a later update of Fermix."

  @impl true
  def id, do: :notifications

  @impl true
  def label, do: "notifications"

  @impl true
  def systems, do: [:macos, :linux]

  @impl true
  def state(switches, facts) when is_list(switches) and is_map(facts),
    do: {:unavailable, @sentence}
end
