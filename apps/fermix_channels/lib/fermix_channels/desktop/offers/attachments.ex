defmodule FermixChannels.Desktop.Offers.Attachments do
  @moduledoc """
  `attachments` (M97 §3.2): files attached on this computer, sent to the
  server's turn (M97 §9.3). Its device end is built beside the link by its
  own stage, which turns this state on in this one place; until then it is
  unavailable on every computer, whatever its switch says.
  """

  @behaviour FermixCore.Computers.Offer

  @sentence "Files you attach on this computer reach your server in a later update of Fermix."

  @impl true
  def id, do: :attachments

  @impl true
  def label, do: "attachments"

  @impl true
  def systems, do: [:macos, :linux]

  @impl true
  def state(switches, facts) when is_list(switches) and is_map(facts),
    do: {:unavailable, @sentence}
end
