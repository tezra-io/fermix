defmodule FermixCore.Computers.Offers.IMessage do
  @moduledoc """
  `imessage` (M97 §3.2): carrying the iMessage channel through this Mac's
  Messages. A Mac's alone; on Linux it is unavailable.
  """

  @behaviour FermixCore.Computers.Offer

  alias FermixCore.Computers.Offers

  @mac_only_sentence "Messages runs only on a Mac."

  @impl true
  def id, do: :imessage

  @impl true
  def label, do: "Messages"

  @impl true
  def systems, do: [:macos]

  @impl true
  def state(switches, %{os: os} = facts) when is_list(switches) do
    if os in systems(),
      do: Offers.switched(switches, id(), facts, nil),
      else: {:unavailable, @mac_only_sentence}
  end
end
