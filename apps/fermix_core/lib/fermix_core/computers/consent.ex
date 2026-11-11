defmodule FermixCore.Computers.Consent do
  @moduledoc """
  What a computer keeps on for its server (M97 §7.3, O3).

  **A move.** The computer the home moves from keeps what it had: files and
  commands, in the sandbox mode it already has; the browser; and the screen,
  Messages and computer history when they were on here before the move
  (their own settings). The move's review shows it as its own block
  (`keep_on_block/2`): the sentence, one line per offer with whether it
  stays on, and the plain warning of §7.1 where commands stay on while the
  sandbox is open. The owner may untick any line before starting; the move
  records the choice when it is accepted (`home.act move_now`'s
  `keep_offers`, else the block's own, `default_keep/1`), and writes it to
  this computer's switches at its commit (`accept/3`), beside the link and
  before the server is told to commit, so a move that is undone leaves no
  switches behind.

  **A computer that joins later** starts with every offer off (M97 §3.1);
  nothing here is written for it.

  **A computer that moved before M97** has a link and no switches. At its
  first start on this engine its switches are derived as a move would have
  kept them, waiting for the owner's review (`derive_moved/2`): until the
  owner reviews them it offers nothing, and its summary says so with the
  review (`review/3`), which the plain "This computer" settings section can
  also finish (`Switches.save/2`).

  The block lists only offers this system can have, and the decision covers
  only those: the offers whose device end comes later are switched on at
  that computer when they arrive.

  `opts`: `:snapshot` (the settings, `ConfigStore.current_snapshot/0`'s
  shape) and `:os` (`:macos` or `:linux`), so a test names the computer.
  """

  alias FermixCore.Computers.Offers
  alias FermixCore.Computers.Switches
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Setup.ConfigStore

  # The offers a move decides, in the order the block lists them, each with
  # the module that names it.
  @kept [
    Offers.Files,
    Offers.Shell,
    Offers.Browser,
    Offers.ComputerUse,
    Offers.IMessage,
    Offers.History
  ]

  @typedoc "One line of the block: the offer, its words, and whether it stays on."
  @type line :: %{offer: Switches.offer(), label: String.t(), on: boolean()}

  @typedoc "The block a review shows."
  @type block :: %{sentence: String.t(), warning: String.t() | nil, lines: [line()]}

  @doc "Every offer a move decides, in the block's order."
  @spec decided() :: [Switches.offer()]
  def decided, do: Enum.map(@kept, & &1.id())

  @doc """
  The block of a move from this computer (the moduledoc): what it keeps on
  after the move, from its settings now.
  """
  @spec keep_on_block(Path.t(), keyword()) :: block()
  def keep_on_block(home, opts \\ []) when is_binary(home) and is_list(opts),
    do: block(default_keep(opts), opts)

  @doc """
  The block of `keep`, the offers to stay on: its sentence names them, each
  with its words, the commands with the sandbox mode they run in. `kind:`
  `:move` (a move's review, the default) or `:review` (the review of a
  computer that moved before M97).
  """
  @spec block([Switches.offer()], keyword()) :: block()
  def block(keep, opts \\ []) when is_list(keep) and is_list(opts) do
    os = os(opts)
    mode = sandbox_mode(opts)
    machine = machine(os)
    lines = for module <- @kept, os in module.systems(), do: line(module, module.id() in keep)

    %{
      sentence:
        sentence(
          Keyword.get(opts, :kind, :move),
          for(%{on: true} = line <- lines, do: words(line, mode)),
          machine
        ) <> history_clause(:history in keep, machine),
      warning: warning(:shell in keep and mode == :open, machine),
      lines: lines
    }
  end

  @doc "What a move from this computer keeps on unless the owner unticks it."
  @spec default_keep(keyword()) :: [Switches.offer()]
  def default_keep(opts \\ []) when is_list(opts) do
    snapshot = Keyword.get_lazy(opts, :snapshot, &ConfigStore.current_snapshot/0)
    os = os(opts)

    for module <- @kept, os in module.systems(), kept?(module.id(), snapshot), do: module.id()
  end

  @doc """
  `keep` as the offers a move may decide (`decided/0`), each named once, or
  the first that is not one.
  """
  @spec cast([String.t() | atom()]) :: {:ok, [Switches.offer()]} | {:error, String.t()}
  def cast(keep) when is_list(keep) do
    Enum.reduce_while(keep, {:ok, []}, fn offer, {:ok, acc} ->
      case Enum.find(decided(), &(Atom.to_string(&1) == to_string(offer))) do
        nil -> {:halt, {:error, to_string(offer)}}
        id -> {:cont, {:ok, Enum.uniq(acc ++ [id])}}
      end
    end)
  end

  @doc "Writes a move's decision, `keep`, to `home`'s switches: on, and reviewed."
  @spec accept(Path.t(), [Switches.offer()], keyword()) :: :ok | {:error, term()}
  def accept(home, keep, opts \\ []) when is_binary(home) and is_list(keep) and is_list(opts),
    do: Switches.write(home, Switches.only(keep))

  @doc """
  At the first start of a computer that moved before M97 (a link, and no
  switches): its switches as a move would have kept them, waiting for the
  owner's review. Once: a computer with switches, or with no link, is
  `:unchanged`.
  """
  @spec derive_moved(Path.t(), keyword()) ::
          :unchanged | {:derived, Switches.t()} | {:error, term()}
  def derive_moved(home, opts \\ []) when is_binary(home) and is_list(opts) do
    with true <- File.regular?(DesktopLink.path(home)),
         {:ok, []} <- Switches.read(home),
         switches = Switches.only(default_keep(opts), reviewed: false),
         :ok <- Switches.write(home, switches) do
      {:derived, switches}
    else
      {:error, _reason} = error -> error
      _linked_with_switches_or_unlinked -> :unchanged
    end
  end

  @doc "The owner's review: `keep` stays on, everything else this computer offers is off."
  @spec review(Path.t(), [Switches.offer()], keyword()) :: :ok | {:error, term()}
  def review(home, keep, opts \\ []) when is_binary(home) and is_list(keep) and is_list(opts),
    do: Switches.write(home, Switches.only(keep))

  @doc "The offers the switches of a review in wait keep on, for its block."
  @spec proposed(Switches.t()) :: [Switches.offer()]
  def proposed(switches) when is_list(switches),
    do: Enum.filter(Switches.switched_on(switches), &(&1 in decided()))

  @doc "A block as the management wire carries it (`keeps_on`, a review's `review`)."
  @spec view(block()) :: map()
  def view(%{sentence: sentence, warning: warning, lines: lines}) do
    %{
      "sentence" => sentence,
      "warning" => warning,
      "lines" =>
        for(
          line <- lines,
          do: %{"offer" => Atom.to_string(line.offer), "label" => line.label, "on" => line.on}
        )
    }
  end

  @doc "Every sentence this module says, for the copy rules."
  @spec sentences() :: [String.t()]
  def sentences do
    for os <- [:macos, :linux],
        mode <- [:strict, :standard, :open],
        keep <- [decided(), [], [:files]],
        kind <- [:move, :review] do
      block = block(keep, os: os, sandbox_mode: mode, kind: kind)
      [block.sentence, block.warning | Enum.map(block.lines, & &1.label)]
    end
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp line(module, on), do: %{offer: module.id(), label: module.label(), on: on}

  defp words(%{offer: :shell, label: label}, mode), do: "#{label} (#{mode})"
  defp words(%{label: label}, _mode), do: label

  defp sentence(:move, [], machine),
    do:
      "After the move, Fermix on your server can use nothing on this #{machine}. Change this here."

  defp sentence(:move, words, machine),
    do:
      "After the move, Fermix on your server can still use this #{machine} for: " <>
        Enum.join(words, ", ") <> ". Change this here."

  # A review of a computer that moved before M97: what it offers once the
  # owner accepts it.
  defp sentence(:review, [], machine),
    do: "Fermix on your server may use nothing on this #{machine}. Change this here."

  defp sentence(:review, words, machine),
    do:
      "Fermix on your server may use this #{machine} for: " <>
        Enum.join(words, ", ") <> ". Change this here."

  # M97 §8.2: a sitting of history kept on now passes through the server, so
  # the block restates what switching it on agrees to.
  defp history_clause(false, _machine), do: ""

  defp history_clause(true, machine),
    do:
      " Your computer history's raw record stays on this #{machine} for 48 hours; each " <>
        "finished sitting is sent to your Fermix server, which has its summarizer summarize it " <>
        "and keeps the summary."

  defp warning(true, machine),
    do:
      "With commands on and this #{machine}'s sandbox open, a server that is taken over can " <>
        "read and change this account's files on this #{machine}."

  defp warning(false, _machine), do: nil

  # Files, commands and the browser are what every computer had; the screen,
  # Messages and history stay on where their own settings had them on.
  defp kept?(offer, _snapshot) when offer in [:files, :shell, :browser], do: true
  defp kept?(:computer_use, snapshot), do: enabled?(core(snapshot, :computer_use))
  defp kept?(:history, snapshot), do: enabled?(core(snapshot, :computer_history))
  defp kept?(:imessage, snapshot), do: enabled?(channel(snapshot, :imessage))

  defp enabled?(section), do: Keyword.get(section, :enabled, false) == true

  defp core(snapshot, key),
    do: snapshot |> Map.get(:fermix_core, []) |> Keyword.get(key, []) |> List.wrap()

  defp channel(snapshot, key),
    do: snapshot |> Map.get(:fermix_channels, []) |> Keyword.get(key, []) |> List.wrap()

  defp sandbox_mode(opts) do
    Keyword.get_lazy(opts, :sandbox_mode, fn ->
      snapshot = Keyword.get_lazy(opts, :snapshot, &ConfigStore.current_snapshot/0)
      SandboxConfig.normalize(Map.get(snapshot, :sandbox)).mode
    end)
  end

  defp os(opts) do
    Keyword.get_lazy(opts, :os, fn ->
      if :os.type() == {:unix, :darwin}, do: :macos, else: :linux
    end)
  end

  defp machine(:macos), do: "Mac"
  defp machine(_os), do: "computer"
end
