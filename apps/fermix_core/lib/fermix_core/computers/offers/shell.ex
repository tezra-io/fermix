defmodule FermixCore.Computers.Offers.Shell do
  @moduledoc """
  `shell` (M97 §3.2): commands confined by this computer's sandbox, on a Mac
  (Seatbelt) or on Linux where the kernel holds commands to the sandbox
  (Landlock); a Linux kernel that does not leaves it unavailable. The one
  switch for files and commands decides it (`files_and_shell`, M97 D27). On,
  its detail is the sandbox mode commands run in (`strict`, `standard` or
  `open`).
  """

  @behaviour FermixCore.Computers.Offer

  alias FermixCore.Computers.Offers

  @no_kernel_sentence "Commands need the kernel to hold them to the sandbox, and this " <>
                        "computer's kernel does not."

  @impl true
  def id, do: :shell

  @impl true
  def label, do: "commands"

  @impl true
  def systems, do: [:macos, :linux]

  @impl true
  def state(switches, %{os: os} = facts) when is_list(switches) do
    cond do
      os not in systems() -> {:unavailable, Offers.no_system_sentence()}
      os == :linux and facts.landlock != :ok -> {:unavailable, @no_kernel_sentence}
      true -> Offers.switched(switches, id(), facts, Atom.to_string(facts.sandbox_mode))
    end
  end
end
