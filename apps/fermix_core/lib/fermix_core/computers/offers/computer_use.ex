defmodule FermixCore.Computers.Offers.ComputerUse do
  @moduledoc """
  `computer_use` (M97 §3.2): seeing and controlling this computer's screen,
  on an Apple silicon Mac or a Linux computer on x86-64, with the computer
  use helper installed and, where it is known, the permission to see and
  control the screen. Anything short of that leaves it unavailable, in the
  words of what is missing.

  On, it carries what the server's `computer_use` tool follows (M97 §6.4):
  its detail is the access level this computer's sandbox mode gives
  (`strict`, `standard` or `open`; strict is look only), and its helper what
  this computer's helper offers (`Facts`' `screen`).
  """

  @behaviour FermixCore.Computers.Offer

  alias FermixCore.Computers.Facts
  alias FermixCore.Computers.Offers

  # The processor each system's helper is built for.
  @arches %{macos: "arm64", linux: "x86_64"}
  @arch_sentence "Fermix cannot see or control the screen on this kind of processor."

  @impl true
  def id, do: :computer_use

  @impl true
  def label, do: "your screen"

  @impl true
  def systems, do: [:macos, :linux]

  @impl true
  def state(switches, %{os: os} = facts) when is_list(switches) do
    machine = Facts.machine(facts)

    cond do
      os not in systems() -> {:unavailable, Offers.no_system_sentence()}
      facts.arch != Map.fetch!(@arches, os) -> {:unavailable, @arch_sentence}
      facts.helpers[:computer_use] != true -> {:unavailable, helper_sentence(machine)}
      facts.permissions[:screen] == false -> {:unavailable, permission_sentence(machine)}
      true -> with_helper(Offers.switched(switches, id(), facts, access(facts)), facts)
    end
  end

  defp access(%{sandbox_mode: mode}), do: Atom.to_string(mode)

  defp with_helper({:on, detail}, %{screen: %{actions: [_ | _]} = screen}),
    do: {:on, detail, %{helper: Map.take(screen, [:actions, :input_methods])}}

  defp with_helper(state, _facts), do: state

  @doc "Every sentence this offer says, for the copy rules."
  @spec sentences() :: [String.t()]
  def sentences,
    do: [
      @arch_sentence
      | Enum.flat_map(["Mac", "computer"], &[helper_sentence(&1), permission_sentence(&1)])
    ]

  defp helper_sentence(machine),
    do: "The Fermix Computer Use helper is not installed on this #{machine}."

  defp permission_sentence(machine),
    do: "This #{machine} has not allowed Fermix Computer Use to see and control the screen."
end
