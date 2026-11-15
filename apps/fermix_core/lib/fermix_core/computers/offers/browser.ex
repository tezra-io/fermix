defmodule FermixCore.Computers.Offers.Browser do
  @moduledoc """
  `browser` (M97 §3.2): this computer's browser profiles, pane and granted
  tabs, on a Mac or a Linux computer. Its switch decides it.
  """

  @behaviour FermixCore.Computers.Offer

  alias FermixCore.Computers.Offers

  @impl true
  def id, do: :browser

  @impl true
  def label, do: "the browser"

  @impl true
  def systems, do: [:macos, :linux]

  @impl true
  def state(switches, %{os: os} = facts) when is_list(switches) do
    if os in systems(),
      do: Offers.switched(switches, id(), facts, nil),
      else: {:unavailable, Offers.no_system_sentence()}
  end
end
