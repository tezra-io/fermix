defmodule FermixCore.Computers.Offers.History do
  @moduledoc """
  `history` (M97 §3.2, §8): recording activity on this computer and sending
  sittings to be summarized. Offered where this computer has a recorder
  (`Facts`' `recorder`, `ComputerHistory.recorder?/1`: a Mac, and a Linux
  computer through its accessibility bus, §8.8), unavailable elsewhere. It has
  no switch: it is on while this computer's recorder is switched on (`Facts`'
  `recording`, the Computer history section's own setting), the master on and
  the switches reviewed (`Computers.Switches.history_on?/2`, M97 D27).
  """

  @behaviour FermixCore.Computers.Offer

  alias FermixCore.Computers.Offers

  @no_recorder_sentence "This computer has no recorder for computer history."

  @impl true
  def id, do: :history

  @impl true
  def label, do: "your computer history"

  @impl true
  def systems, do: [:macos, :linux]

  @impl true
  def state(switches, %{recorder: recorder?} = facts) when is_list(switches) do
    if recorder?,
      do: Offers.switched(switches, id(), facts, nil),
      else: {:unavailable, @no_recorder_sentence}
  end
end
