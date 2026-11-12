defmodule FermixCore.Computers.Consent do
  @moduledoc """
  What a computer keeps on for its server (M97 §7.3, O3, D27).

  **The lines.** A move's review and the review of a computer that moved
  before M97 show the same block, one line for each switch this system can
  have (`Computers.Switches`: files and commands as one line, the browser,
  the screen, Messages) and, on a Mac, one for computer history, whose
  consent is its recorder's own setting (`decided/0`).

  **A move.** The computer the home moves from keeps what it had: files and
  commands, in the sandbox mode it already has; the browser; and the screen,
  Messages and computer history when they were on here before the move
  (their own settings). The move's review shows it as its own block
  (`keep_on_block/2`): the sentence, one line each with whether it stays
  on, and the plain warning of §7.1 where files and commands stay on while
  the sandbox is open. The owner may untick any line before starting; the
  move records the choice when it is accepted (`home.act move_now`'s
  `keep_offers`, else the block's own, `default_keep/1`), and writes it at
  its commit (`accept/3`), beside the link and before the server is told to
  commit, so a move that is undone leaves no switches behind: the history
  line sets the recorder, written first, then the switches, which mark the
  decision written.

  **What an earlier app or engine sends.** Within the version window (M97
  §3.4) a surface or a move request from before D27 names files and
  commands as two lines, `files` and `shell`: they keep `files_and_shell` on
  only when both are named, one alone keeping it off, the reading the
  file's own upgrade makes (`known/1`).

  **A computer that joins later** starts with every switch off and its
  recorder off (M97 §3.1, `none/2`): a recorder switched on while the
  computer was its own home kept its history there, and from the join it
  would go to the server, so it is switched on again at the computer, where
  the history section says so.

  **A computer that moved before M97** has a link and no switches. At its
  first start on this engine its switches are derived as a move would have
  kept them, waiting for the owner's review (`derive_moved/2`): until the
  owner reviews them it offers nothing, and its summary says so with the
  review (`review/3`, the history line deciding the recorder as at a move),
  which the plain "This computer" settings section can also finish
  (`Switches.save/2`). Its recorder is left as it is: whether the review
  proposes history is the recorder's setting (`proposed/2`).

  Where computer history stays on, the block restates what switching it on
  agrees to (M97 §8.2), from the one function that says it
  (`ComputerHistory.Promise.sentence/2`), as it will hold after the move: the
  sitting goes to the server, or, where this computer makes its own notes,
  only the summary does.

  `opts`: `:snapshot` (the settings, `ConfigStore.current_snapshot/0`'s
  shape) and `:os` (`:macos` or `:linux`), so a test names the computer;
  `accept/3` and `review/3` pass `:recorder?` and `:controller` on to the
  recorder's switch (`ComputerHistory.switch_off/1`).
  """

  require Logger

  alias FermixCore.ComputerHistory
  alias FermixCore.ComputerHistory.Config, as: HistoryConfig
  alias FermixCore.ComputerHistory.Promise
  alias FermixCore.Computers.Offers
  alias FermixCore.Computers.Switches
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Setup.ConfigStore

  # The two lines an engine before D27 listed for files and commands.
  @halves ["files", "shell"]
  @history_table "fermix_core.computer_history"

  @typedoc "One line a move or a review decides: a switch, or `:history` (its recorder)."
  @type decision :: Switches.switch() | :history

  @typedoc "One line of the block: what it decides, its words, and whether it stays on."
  @type line :: %{offer: decision(), label: String.t(), on: boolean()}

  @typedoc "The block a review shows."
  @type block :: %{sentence: String.t(), warning: String.t() | nil, lines: [line()]}

  @doc "Every line a move or a review decides, in the block's order."
  @spec decided() :: [decision()]
  def decided, do: Switches.switches() ++ [:history]

  @doc """
  The block of a move from this computer (the moduledoc): what it keeps on
  after the move, from its settings now.
  """
  @spec keep_on_block(Path.t(), keyword()) :: block()
  def keep_on_block(home, opts \\ []) when is_binary(home) and is_list(opts),
    do: block(default_keep(opts), opts)

  @doc """
  The block of `keep`, the lines to stay on: its sentence names them, each
  with its words, files and commands with the sandbox mode they run in.
  `kind:` `:move` (a move's review, the default) or `:review` (the review of
  a computer that moved before M97). `history_local?:` says whether this
  computer makes its own history notes, in place of its settings. A line
  that is not one of `decided/0` raises `ArgumentError`.
  """
  @spec block([decision()], keyword()) :: block()
  def block(keep, opts \\ []) when is_list(keep) and is_list(opts) do
    for line <- keep,
        line not in decided(),
        do: raise(ArgumentError, "#{inspect(line)} is no line")

    os = os(opts)
    mode = sandbox_mode(opts)
    machine = machine(os)
    lines = for decision <- lines(os), do: line(decision, decision in keep)

    %{
      sentence:
        sentence(
          Keyword.get(opts, :kind, :move),
          for(%{on: true} = line <- lines, do: words(line, mode)),
          machine
        ) <> history_clause(:history in keep, machine, opts),
      warning: warning(:files_and_shell in keep and mode == :open, machine),
      lines: lines
    }
  end

  @doc "What a move from this computer keeps on unless the owner unticks it."
  @spec default_keep(keyword()) :: [decision()]
  def default_keep(opts \\ []) when is_list(opts) do
    snapshot = Keyword.get_lazy(opts, :snapshot, &ConfigStore.current_snapshot/0)
    for decision <- lines(os(opts)), kept?(decision, snapshot), do: decision
  end

  @doc """
  `keep` as the lines a move or a review decides, in the block's order, or
  the first name that is none (`known/1`).
  """
  @spec cast([String.t() | atom()]) :: {:ok, [decision()]} | {:error, String.t()}
  def cast(keep) when is_list(keep) do
    case known(keep) do
      {lines, []} -> {:ok, lines}
      {_lines, [name | _more]} -> {:error, name}
    end
  end

  @doc """
  The lines `names` keeps on, in the block's order, and the names that are
  none, each once. `files` and `shell`, an earlier engine's two lines for
  files and commands, keep `files_and_shell` on only when both are named
  (the moduledoc).
  """
  @spec known([String.t() | atom()]) :: {[decision()], [String.t()]}
  def known(names) when is_list(names) do
    names = Enum.map(names, &to_string/1)
    both_halves? = Enum.all?(@halves, &(&1 in names))

    lines =
      for decision <- decided(),
          Atom.to_string(decision) in names or (decision == :files_and_shell and both_halves?),
          do: decision

    words = Enum.map(decided(), &Atom.to_string/1) ++ @halves
    {lines, names |> Enum.reject(&(&1 in words)) |> Enum.uniq()}
  end

  @doc """
  Writes a move's decision, `keep`, to `home` (the moduledoc): the history
  line sets the recorder, then the switches are written on, and reviewed.
  """
  @spec accept(Path.t(), [decision()], keyword()) :: :ok | {:error, term()}
  def accept(home, keep, opts \\ []) when is_binary(home) and is_list(keep) and is_list(opts),
    do: write_keep(home, keep, opts)

  @doc """
  What a computer that joins a home starts with (the moduledoc): nothing on,
  its recorder off, its switches off and reviewed, written as a move's
  decision is (`accept/3`).
  """
  @spec none(Path.t(), keyword()) :: :ok | {:error, term()}
  def none(home, opts \\ []) when is_binary(home) and is_list(opts),
    do: write_keep(home, [], opts)

  @doc """
  At the first start of a computer that moved before M97 (a link, and no
  switches): its switches as a move would have kept them, waiting for the
  owner's review. Once: a computer with switches, or with no link, is
  `:unchanged`. Its recorder is not touched.
  """
  @spec derive_moved(Path.t(), keyword()) ::
          :unchanged | {:derived, Switches.t()} | {:error, term()}
  def derive_moved(home, opts \\ []) when is_binary(home) and is_list(opts) do
    with true <- File.regular?(DesktopLink.path(home)),
         {:ok, []} <- Switches.read(home),
         switches = Switches.only(default_keep(opts) -- [:history], reviewed: false),
         :ok <- Switches.write(home, switches) do
      {:derived, switches}
    else
      {:error, _reason} = error -> error
      _linked_with_switches_or_unlinked -> :unchanged
    end
  end

  @doc """
  The owner's review: `keep` stays on, every other line this computer has is
  off, the history line setting the recorder, as a move's decision is
  written (`accept/3`).
  """
  @spec review(Path.t(), [decision()], keyword()) :: :ok | {:error, term()}
  def review(home, keep, opts \\ []) when is_binary(home) and is_list(keep) and is_list(opts),
    do: write_keep(home, keep, opts)

  @doc """
  The lines the switches of a review in wait keep on, for its block: the
  switches on, and history where the recorder is on (`opts`' `:snapshot`).
  """
  @spec proposed(Switches.t(), keyword()) :: [decision()]
  def proposed(switches, opts \\ []) when is_list(switches) and is_list(opts) do
    snapshot = Keyword.get_lazy(opts, :snapshot, &ConfigStore.current_snapshot/0)
    on = Switches.switched_on(switches)

    for decision <- lines(os(opts)),
        decision in on or (decision == :history and kept?(:history, snapshot)),
        do: decision
  end

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
        keep <- [decided(), [], [:files_and_shell]],
        kind <- [:move, :review],
        local? <- [false, true] do
      block = block(keep, os: os, sandbox_mode: mode, kind: kind, history_local?: local?)
      [block.sentence, block.warning | Enum.map(block.lines, & &1.label)]
    end
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # The lines this system can have: a line's offers all on its system.
  defp lines(os), do: for(decision <- decided(), os in systems(decision), do: decision)

  defp offers(:history), do: [Offers.module(:history)]
  defp offers(switch), do: Enum.map(Switches.decides(switch), &Offers.module/1)

  defp systems(decision) do
    decision
    |> offers()
    |> Enum.map(&MapSet.new(&1.systems()))
    |> Enum.reduce(&MapSet.intersection/2)
  end

  # Its offers' own words: "files and commands", "the browser".
  defp line(decision, on),
    do: %{offer: decision, label: Enum.map_join(offers(decision), " and ", & &1.label()), on: on}

  defp words(%{offer: :files_and_shell, label: label}, mode), do: "#{label} (#{mode})"
  defp words(%{label: label}, _mode), do: label

  # The history line sets the recorder first; the switches, written after,
  # mark the decision written (`FermixChannels.Home.MoveWorker` resumes on
  # them).
  defp write_keep(home, keep, opts) do
    for line <- keep,
        line not in decided(),
        do: raise(ArgumentError, "#{inspect(line)} is no line")

    with :ok <- recorder(home, :history in keep, opts) do
      Switches.write(home, Switches.only(keep -- [:history]))
    end
  end

  defp recorder(home, on?, opts) do
    case ConfigStore.machine_table(home, @history_table) do
      {:ok, table} ->
        if Map.get(table || %{}, "enabled", false) == on?,
          do: :ok,
          else: switch_recorder(on?, Keyword.put(opts, :home, home))

      {:error, _reason} = error ->
        error
    end
  end

  # The setting must be saved; a recorder that could not follow now takes it
  # at the next start, which the log says.
  defp switch_recorder(true, opts) do
    %{start: start, save: save} = ComputerHistory.switch_on(recorder_seams(opts))
    settled(save, start, "on")
  end

  defp switch_recorder(false, opts) do
    %{stop: stop, save: save} = ComputerHistory.switch_off(recorder_seams(opts))
    settled(save, stop, "off")
  end

  defp recorder_seams(opts), do: Keyword.take(opts, [:home, :recorder?, :controller])

  defp settled({:error, _reason} = error, _runtime, _word), do: error
  defp settled(:ok, :ok, _word), do: :ok

  defp settled(:ok, {:error, reason}, word) do
    Logger.error(
      "this computer's recorder is saved #{word} but did not follow now; it does at the " <>
        "next start: #{inspect(reason)}"
    )
  end

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
  # the block restates what switching it on agrees to. After the move this
  # computer reads only its own keys (`HistoryConfig.for_role/2`), so whether
  # it makes its own notes is its machine file's choice, never the home's route.
  defp history_clause(false, _machine, _opts), do: ""

  defp history_clause(true, machine, opts) do
    local? = Keyword.get_lazy(opts, :history_local?, fn -> history_local?(opts) end)
    Promise.sentence(:clause, %{server?: true, local?: local?, provider: nil, machine: machine})
  end

  defp history_local?(opts) do
    snapshot = Keyword.get_lazy(opts, :snapshot, &ConfigStore.current_snapshot/0)

    snapshot
    |> core(:computer_history)
    |> HistoryConfig.normalize()
    |> HistoryConfig.for_role(:device)
    |> HistoryConfig.summarizer() == :local
  end

  defp warning(true, machine),
    do:
      "With files and commands on and this #{machine}'s sandbox open, a server that is taken " <>
        "over can read and change this account's files on this #{machine}."

  defp warning(false, _machine), do: nil

  # Files and commands and the browser are what every computer had; the
  # screen, Messages and history stay on where their own settings had them on.
  defp kept?(decision, _snapshot) when decision in [:files_and_shell, :browser], do: true
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
