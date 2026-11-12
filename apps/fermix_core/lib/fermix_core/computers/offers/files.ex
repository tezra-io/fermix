defmodule FermixCore.Computers.Offers.Files do
  @moduledoc """
  `files` (M97 §3.2): reading, writing, editing and searching files inside
  this computer's sandbox roots, on a Mac or a Linux computer. The one switch
  for files and commands decides it (`files_and_shell`,
  `Computers.Offers.switched/4`, M97 D27).
  """

  @behaviour FermixCore.Computers.Offer

  alias FermixCore.Computers.Offers

  @impl true
  def id, do: :files

  @impl true
  def label, do: "files"

  @impl true
  def systems, do: [:macos, :linux]

  @impl true
  def state(switches, %{os: os} = facts) when is_list(switches) do
    if os in systems(),
      do: Offers.switched(switches, id(), facts, nil),
      else: {:unavailable, Offers.no_system_sentence()}
  end
end
