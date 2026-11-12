defmodule FermixCore.Management.Settings.ThisComputer do
  @moduledoc """
  The `computer` section (M97 §7.2, §7.4, D27): what Fermix on the server may
  use on this computer, `[fermix_core.computer]` in its `machine.toml`
  (`Computers.Switches`), under the `always_on` pane, titled "This
  computer". Five rows on a Mac: the switch that turns everything off, then
  one per switch this system can have (files and commands as one, the
  browser, the screen, Messages, only where Messages runs). Nothing else is a
  row: the review is this computer's state, computer history's consent is
  its recorder in the Computer history section, and what reaches the server
  from this computer has no switch.

  Published only on a computer linked to its server where Always On is
  offered (`Home.AlwaysOnRelease`): an install that never moved sees no new
  section. It is a machine section (`Management.Placement`), so it is
  answered on this computer alone and the server refuses a forwarded write;
  the server never publishes it.

  **The review.** A computer that moved before M97 starts with its switches
  waiting for the owner's review, offering nothing until then
  (`Computers.Consent.derive_moved/2`). Any write to this section is that
  review (`Switches.save/2`), so it is never stuck behind an app that draws
  this section generically; while it waits, the master row's footer says so.

  Every switch is live: the next request reads it, and this computer sends
  its offers again at once.
  """

  alias FermixCore.Computers.Offers
  alias FermixCore.Computers.Switches
  alias FermixCore.Home.AlwaysOnRelease
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Role
  alias FermixCore.Management.Settings.Row
  alias FermixCore.Management.Settings.Source
  alias FermixCore.Setup.ConfigStore

  @section %{id: "computer", pane: "always_on", title: "This computer"}
  # Each switch's row label, in the switches' order.
  @labels [
    files_and_shell: "Files and commands",
    browser: "The browser",
    computer_use: "Your screen",
    imessage: "Messages"
  ]

  if Keyword.keys(@labels) != Switches.switches() do
    raise CompileError, description: "ThisComputer: one row per switch, in the switches' order"
  end

  @enabled_footer "Off stops everything Fermix on your server does here, from its next request."
  @review_footer "Change any switch here to let Fermix on your server use what is switched on."

  @doc """
  The section on a linked computer where Always On is offered, none
  elsewhere. `computer?:` says which for a test.
  """
  @spec sections(keyword()) :: [%{id: String.t(), pane: String.t(), title: String.t()}]
  def sections(opts \\ []) when is_list(opts),
    do: if(computer?(opts), do: [@section], else: [])

  @doc "Whether this module owns the named section here."
  @spec owns?(String.t(), keyword()) :: boolean()
  def owns?(section, opts \\ []) when is_binary(section) and is_list(opts),
    do: section == @section.id and computer?(opts)

  @doc """
  The rows of the owned section, for a Mac or another system (`macos?:`,
  this host's by default): the master, then each switch whose offers this
  system can have.
  """
  @spec rows(String.t(), Source.snapshot(), keyword()) :: [Row.t()]
  def rows("computer", snapshot, opts \\ []) when is_map(snapshot) and is_list(opts) do
    switches = Switches.normalize(Source.core(snapshot, :computer))
    os = if Keyword.get_lazy(opts, :macos?, &macos?/0), do: :macos, else: :linux

    [
      Row.new("computer_enabled", :toggle, "Fermix on your server may use this computer",
        footer: master_footer(Switches.reviewed?(switches), os),
        value: Switches.enabled?(switches),
        restart: false
      )
    ] ++
      for {switch, label} <- @labels, here?(switch, os) do
        Row.new("computer_#{switch}", :toggle, label,
          value: Keyword.get(switches, switch, false),
          restart: false
        )
      end
  end

  @doc "Every sentence this section says, for the copy rules."
  @spec sentences() :: [String.t()]
  def sentences, do: [@enabled_footer | Enum.map([:macos, :linux], &master_footer(false, &1))]

  # A switch is a row where every offer it decides can work on this system.
  defp here?(switch, os),
    do: Enum.all?(Switches.decides(switch), &(os in Offers.module(&1).systems()))

  # While the review waits, the master's footer says so: any change here is
  # the review.
  defp master_footer(true, _os), do: @enabled_footer

  defp master_footer(false, os),
    do:
      Offers.waiting_sentence(if(os == :macos, do: "Mac", else: "computer")) <>
        " " <> @review_footer

  defp macos?, do: :os.type() == {:unix, :darwin}

  defp computer?(opts), do: Keyword.get_lazy(opts, :computer?, &linked_computer?/0)

  # A device-role engine whose home holds its link, where Always On is
  # offered; a process that booted no engine is no computer.
  defp linked_computer? do
    case Role.booted() do
      nil ->
        false

      record ->
        AlwaysOnRelease.available?() and DesktopLink.linked?(record, ConfigStore.fermix_home())
    end
  end
end
