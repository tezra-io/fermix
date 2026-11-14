defmodule FermixCore.Computers.Offers.Places do
  @moduledoc """
  `places` (M89 D13 D, M97 §3.2): looking places up in Apple Maps for the
  home's place search, on a Mac whose Fermix carries the Apple Maps helper
  (the Fermix app's engine, `PlaceSearch.Backend.carries_helper?/1`, which
  `Computers.Facts` reads as its `apple_maps` helper), however the app was
  installed, the Homebrew cask included. Anywhere else, Linux and the
  standalone Homebrew formula on a Mac among them, it is unavailable.

  Its own switch decides it (`places`, `Computers.Switches`), set at this
  computer: in its This computer settings section, or a move's or a review's
  line (`Computers.Consent`). Where nothing is stored for it, it is on, by the
  one line in `Computers.Switches` that says so (`@places_on_by_default`).
  The master switch off or a review in wait keeps it off as every offer
  (`Computers.Offers.switched/4`).
  """

  @behaviour FermixCore.Computers.Offer

  alias FermixCore.Computers.Offers

  @needs_mac_app "Looking places up in Apple Maps needs the Fermix app on a Mac."

  @impl true
  def id, do: :places

  @impl true
  def label, do: "Apple Maps"

  @impl true
  def systems, do: [:macos]

  @impl true
  def state(switches, %{os: os, helpers: helpers} = facts) when is_list(switches) do
    if os in systems() and Map.get(helpers, :apple_maps) == true,
      do: Offers.switched(switches, id(), facts, nil),
      else: {:unavailable, @needs_mac_app}
  end

  @doc "The offer's sentence where this build carries no Apple Maps helper."
  @spec needs_mac_app_sentence() :: String.t()
  def needs_mac_app_sentence, do: @needs_mac_app
end
