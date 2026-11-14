defmodule FermixCore.Management.Settings.CodingMachine do
  @moduledoc """
  The `harness_machine` section (M98 D5): whether coding agents may run on
  this machine, `[fermix_core.harness] approved` in its `machine.toml`
  (`Harness.Config`), under the coding pane and titled for this machine
  ("This Mac" or "This computer"), before the home's own coding section
  (`harness`, `Settings.Tools`), which keeps the preferred tool.

  Published only off the device role. The approval is in force where the
  coding rail runs, and a computer whose home is on its server runs none
  (`Home.Role`). After a move it is the server's (M97 §19.9, D28, revising
  M98 D5): a plain id, so a linked computer sends it to the server, whose
  approval every computer's coding pane draws under the server's name, and
  an Always On server's own words name it "this server". A computer's own
  approval is its Coding agents switch under This computer (M98 D4).
  """

  alias FermixCore.Harness.Config, as: HarnessConfig
  alias FermixCore.Home.Role
  alias FermixCore.Home.ServerPrimary
  alias FermixCore.Management.Settings.Row
  alias FermixCore.Management.Settings.Source
  alias FermixCore.Setup.ConfigStore

  @id "harness_machine"
  @footer "Each tool keeps its own login. Cloud runs are off in this release."

  @doc """
  The section where the coding rail runs, none on a computer whose home is on
  its server. `macos?:` names the host, `computer?:` whether this engine is
  such a computer and `server_primary?:` whether it is an Always On server's
  primary, for a test.
  """
  @spec sections(keyword()) :: [%{id: String.t(), pane: String.t(), title: String.t()}]
  def sections(opts \\ []) when is_list(opts) do
    if computer?(opts),
      do: [],
      else: [%{id: @id, pane: "coding", title: title(machine(opts))}]
  end

  @doc "Whether this module owns the named section here."
  @spec owns?(String.t(), keyword()) :: boolean()
  def owns?(section, opts \\ []) when is_binary(section) and is_list(opts),
    do: section == @id and not computer?(opts)

  @doc "The rows of the owned section, labelled for this machine (`sections/1`'s options)."
  @spec rows(String.t(), Source.snapshot(), keyword()) :: [Row.t()]
  def rows(@id, snapshot, opts \\ []) when is_map(snapshot) and is_list(opts) do
    block = Source.core(snapshot, :harness)

    [
      Row.new("harness_approved", :toggle, label(machine(opts)),
        footer: @footer,
        value: Source.boolean(block, :approved, HarnessConfig.approved?([])),
        restart: Row.restart?(:harness)
      )
    ]
  end

  @doc "Every sentence this section says, on a Mac and elsewhere, for the copy rules."
  @spec sentences() :: [String.t()]
  def sentences do
    labels =
      for machine <- ["Mac", "computer", "server"],
          text <- [title(machine), label(machine)],
          do: text

    [@footer | labels]
  end

  defp title(machine), do: "This #{machine}"
  defp label(machine), do: "Allow coding agents to run on this #{machine}"

  defp machine(opts) do
    cond do
      Keyword.get_lazy(opts, :macos?, fn -> :os.type() == {:unix, :darwin} end) -> "Mac"
      server_primary?(opts) -> "server"
      true -> "computer"
    end
  end

  # An Always On server's primary (`Home.ServerPrimary`), which is never a Mac.
  defp server_primary?(opts) do
    Keyword.get_lazy(opts, :server_primary?, fn ->
      match?(%{role: :primary}, Role.booted()) and
        ServerPrimary.check(ConfigStore.fermix_home(), macos?: false) == :server
    end)
  end

  # An engine in the device role runs no coding agent; a process that booted
  # no engine is none.
  defp computer?(opts),
    do: Keyword.get_lazy(opts, :computer?, fn -> match?(%{role: :device}, Role.booted()) end)
end
