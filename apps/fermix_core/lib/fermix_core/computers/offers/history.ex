defmodule FermixCore.Computers.Offers.History do
  @moduledoc """
  `history` (M97 §3.2, §8): recording activity on this computer and sending
  sittings to be summarized. A Mac's in this release; a Linux computer's
  recorder comes later (§8.8), so there it is unavailable. It has no switch:
  it is on while this computer's recorder is switched on (`Facts`'
  `recording`, the Computer history section's own setting), the master on
  and the switches reviewed (`Computers.Switches.history_on?/2`, M97 D27).
  """

  @behaviour FermixCore.Computers.Offer

  alias FermixCore.Computers.Offers

  @mac_only_sentence "Fermix records computer history only on a Mac for now."

  @impl true
  def id, do: :history

  @impl true
  def label, do: "your computer history"

  @impl true
  def systems, do: [:macos]

  @impl true
  def state(switches, %{os: os} = facts) when is_list(switches) do
    if os in systems(),
      do: Offers.switched(switches, id(), facts, nil),
      else: {:unavailable, @mac_only_sentence}
  end
end
