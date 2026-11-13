defmodule FermixCore.ComputerHistory.Promise do
  @moduledoc """
  What switching computer history on agrees to (M97 §8.2), said the same way
  wherever it is said: the history switch's footer in settings
  (`Management.Settings.Tools`) and the clause a move's review of what a
  computer keeps on adds (`Computers.Consent`). `sentence/2` is the one
  function that decides it, from four facts:

    * whether this computer's history goes to a server (`on_server?/1`):
      Always On is offered (`Home.AlwaysOnRelease`) and this engine is a
      computer linked to its server (`Home.DesktopLink.linked?/2`, the
      device role with its link) or the server itself
      (`Home.Candidate.server?/1`). A Mac that never moved, or moved back,
      has none;
    * whether this computer makes its own notes (`ComputerHistory.Config`'s
      summarizer in force is `:local`);
    * the provider that summarizes, where there is no server: the one the
      status line names (`Config.default_summarizer_provider/0` for the
      default, the pinned one otherwise), by its label. With a server, the
      route is the home's, which a computer never reads, so no provider is
      named there;
    * the machine's word, "Mac" or "computer".

  The raw record stays on the computer that recorded it for 48 hours in
  every case (`ComputerHistory.Retention`). The words name no version.
  """

  alias FermixCore.ComputerHistory.Config
  alias FermixCore.Home.AlwaysOnRelease
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Role
  alias FermixCore.Providers.Descriptor
  alias FermixCore.Setup.ConfigStore

  @unresolved_provider "your default provider"

  @type form :: :footer | :clause
  @type facts :: %{
          server?: boolean(),
          local?: boolean(),
          provider: String.t() | nil,
          machine: String.t()
        }

  @doc """
  The promise for `facts`: as the switch's `:footer`, or as the `:clause` a
  move's review appends to its sentence (which opens with a space).
  """
  @spec sentence(form(), facts()) :: String.t()
  def sentence(:footer, %{machine: machine} = facts) when is_binary(machine) do
    "Fermix records what you do in the apps you choose on this #{machine}. The " <>
      where(facts) <> "." <> recall(facts)
  end

  # A move's review says only where the history goes once the line is
  # ticked (the Always On pane's R1): how long the raw record stays is the
  # switch's footer and the docs page's.
  def sentence(:clause, %{machine: machine, local?: true}) when is_binary(machine),
    do: " Ticked, only the summary of each sitting of your computer history goes to your server."

  def sentence(:clause, %{machine: machine, local?: false}) when is_binary(machine),
    do:
      " Ticked, each sitting of your computer history goes to your server, which keeps its summary."

  defp where(%{machine: machine} = facts),
    do: "raw record stays on this #{machine} for 48 hours; each finished sitting is " <> to(facts)

  defp to(%{server?: true, local?: true, machine: machine}),
    do:
      "summarized on this #{machine}, and only the summary is sent to your Fermix server, " <>
        "which keeps it"

  defp to(%{server?: true, local?: false}),
    do: "sent to your Fermix server, which has its summarizer summarize it and keeps the summary"

  defp to(%{server?: false, local?: true, machine: machine}),
    do: "summarized on this #{machine}, and Fermix keeps the summary"

  defp to(%{server?: false, local?: false, provider: provider}) when is_binary(provider),
    do: "summarized by #{provider}, and Fermix keeps the summary"

  defp to(%{server?: false, local?: false, provider: nil}),
    do: "summarized by #{@unresolved_provider}, and Fermix keeps the summary"

  defp recall(%{server?: true}), do: " Summaries from all your computers can be recalled in chat."
  defp recall(%{server?: false}), do: ""

  @doc """
  The facts for `config` (this machine's history settings as its engine
  holds them, `Config.current/0`'s shape). `opts`: `:on_server?` in place of
  `on_server?/1` (or its own seams, `:home`, `:record`, `:always_on?`), and
  `:os` (`:macos` or `:linux`) in place of this host's.
  """
  @spec facts(keyword(), keyword()) :: facts()
  def facts(config, opts \\ []) when is_list(config) and is_list(opts) do
    server? = Keyword.get_lazy(opts, :on_server?, fn -> on_server?(opts) end)
    summarizer = Config.summarizer(config)

    %{
      server?: server?,
      local?: summarizer == :local,
      provider: if(server?, do: nil, else: provider(summarizer)),
      machine: machine(Keyword.get_lazy(opts, :os, &host_os/0))
    }
  end

  defp provider(:local), do: nil
  defp provider({:provider, id}), do: label(id)

  defp provider(:default_provider) do
    case Config.default_summarizer_provider() do
      {:ok, id} -> label(id)
      {:error, _unresolved} -> nil
    end
  end

  defp label(id) do
    case Descriptor.fetch(id) do
      {:ok, descriptor} -> descriptor.label
      :error -> Atom.to_string(id)
    end
  end

  @doc """
  Whether this computer's history goes to a server (the moduledoc): Always
  On is offered, and this engine is a computer linked to its server or the
  server itself. `opts` (seams): `:home`, `:record` (`Role.booted/0`'s),
  `:always_on?`.
  """
  @spec on_server?(keyword()) :: boolean()
  def on_server?(opts \\ []) when is_list(opts) do
    home = Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)

    Keyword.get_lazy(opts, :always_on?, &AlwaysOnRelease.available?/0) and
      (linked?(Keyword.get_lazy(opts, :record, &Role.booted/0), home) or Candidate.server?(home))
  end

  # A process that booted no engine is no computer of a server.
  defp linked?(nil, _home), do: false
  defp linked?(record, home), do: DesktopLink.linked?(record, home)

  @doc "Every sentence `sentence/2` says, one provider label standing for all, for the copy rules."
  @spec sentences() :: [String.t()]
  def sentences do
    for form <- [:footer, :clause],
        server? <- [true, false],
        local? <- [true, false],
        provider <- ["Anthropic", nil],
        machine <- ["Mac", "computer"],
        uniq: true,
        do:
          sentence(form, %{server?: server?, local?: local?, provider: provider, machine: machine})
  end

  defp machine(:macos), do: "Mac"
  defp machine(:linux), do: "computer"

  defp host_os, do: if(:os.type() == {:unix, :darwin}, do: :macos, else: :linux)
end
