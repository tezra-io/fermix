defmodule FermixCore.Management.Settings.ThisComputer do
  @moduledoc """
  The `computer` section (M97 §7.2, §7.4): what Fermix on the server may use
  on this computer, `[fermix_core.computer]` in its `machine.toml`
  (`Computers.Switches`), under the `always_on` pane, titled "This
  computer". One switch that turns everything off, one per offer, and
  whether the owner has reviewed them.

  Published only on a computer linked to its server where Always On is
  offered (`Home.AlwaysOnRelease`): an install that never moved sees no new
  section. It is a machine section (`Management.Placement`), so it is
  answered on this computer alone and the server refuses a forwarded write;
  the server never publishes it.

  **The review.** A computer that moved before M97 starts with its switches
  waiting for the owner's review, offering nothing until then
  (`Computers.Consent.derive_moved/2`). Any write to this section is that
  review (`Switches.save/2`): a released app that knows no review notice
  draws this section generically, so the review is never stuck behind an
  older app. While it waits, the `computer_reviewed` row says so and is the
  one to turn on to accept the switches as they are; once done it is shown
  and not written.

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
  @offer_labels [
    files: "Files",
    shell: "Commands",
    browser: "The browser",
    computer_use: "Your screen",
    imessage: "Messages",
    history: "Your computer history",
    voice: "Voice calls",
    attachments: "Attachments",
    accessory: "The robot",
    notifications: "Notifications"
  ]

  if Keyword.keys(@offer_labels) != Switches.offers() do
    raise CompileError, description: "ThisComputer: one row per offer, in the switches' order"
  end

  @enabled_footer "Off stops everything Fermix on your server does here, from its next request."
  @reviewed_footer "Turn this on, or change any switch here, to let Fermix on your server use " <>
                     "what is switched on."
  @reviewed_done_footer "You reviewed what Fermix on your server may use here."

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

  @doc "The rows of the owned section."
  @spec rows(String.t(), Source.snapshot()) :: [Row.t()]
  def rows("computer", snapshot) when is_map(snapshot) do
    switches = Switches.normalize(Source.core(snapshot, :computer))
    reviewed = Switches.reviewed?(switches)

    [
      Row.new("computer_enabled", :toggle, "Fermix on your server may use this computer",
        footer: @enabled_footer,
        value: Switches.enabled?(switches),
        restart: false
      ),
      Row.new("computer_reviewed", :toggle, "Reviewed",
        footer: reviewed_footer(reviewed),
        value: reviewed,
        read_only: reviewed,
        restart: false
      )
    ] ++
      for {offer, label} <- @offer_labels do
        Row.new("computer_#{offer}", :toggle, label,
          value: Keyword.get(switches, offer, false),
          restart: false
        )
      end
  end

  @doc "Every sentence this section says, for the copy rules."
  @spec sentences() :: [String.t()]
  def sentences, do: [@enabled_footer, @reviewed_done_footer | reviewed_footers()]

  defp reviewed_footer(true), do: @reviewed_done_footer

  defp reviewed_footer(false),
    do: Offers.waiting_sentence(machine()) <> " " <> @reviewed_footer

  defp reviewed_footers,
    do:
      for(
        machine <- ["Mac", "computer"],
        do: Offers.waiting_sentence(machine) <> " " <> @reviewed_footer
      )

  defp machine, do: if(:os.type() == {:unix, :darwin}, do: "Mac", else: "computer")

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
