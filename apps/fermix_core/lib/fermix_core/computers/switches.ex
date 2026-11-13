defmodule FermixCore.Computers.Switches do
  @moduledoc """
  What Fermix on the server may use on this computer (M97 §7.2, D27): the
  `[fermix_core.computer]` section of this computer's `machine.toml`
  (`Setup.MachineFile`), one master switch and one switch for each thing the
  owner decides.

      [fermix_core.computer]
      enabled = true            # the master: false refuses everything
      reviewed = true           # false only on a computer that moved before M97
      files_and_shell = false   # files and commands, in this computer's sandbox
      browser = false
      computer_use = false      # the screen
      imessage = false          # Messages

  Every value is a boolean. An absent switch is off, an absent `enabled` and
  `reviewed` are on, so a computer with no section offers nothing a switch
  decides (every linked computer has one: a join, a move and the first start
  after a move before M97 write it). An unknown key or a value that is not a boolean refuses the load by name
  (`normalize/1`), as every section does; `to_keyword/1` is its inverse, the
  shape the settings file holds (the config round-trip rule).

  **One rule.** A switch decides the offers it names (`decides/1`):
  `files_and_shell` both `files` and `shell`, since a command reads the same
  files under the same sandbox, and each other switch the offer of its name.
  An offer is on only while the master is on, the switches were reviewed and
  its switch is on (`on?/2`). Computer history has no switch here: its
  consent is its recorder's own setting (`[fermix_core.computer_history]
  enabled`, the Computer history section's), and it is offered only while that
  is on, the master on and the switches reviewed (`history_on?/2`). Every
  reader asks one of these two: the offers this computer reports
  (`Computers.Offers`), its admission of a request
  (`FermixChannels.Desktop.Invoke.Admission`), its screen and browser
  listeners, and its sending of history (`FermixChannels.Desktop.HistoryUplink`).
  What reaches the server from this computer (calls, attachments, a robot,
  notifications) is no offer and has no switch: it follows its feature's own
  setting.

  **A section an earlier engine wrote.** An engine before D27 wrote a switch
  for `files` and one for `shell`, one for `history`, and four for offers that
  never came (`voice`, `attachments`, `accessory`, `notifications`).
  `upgrade/2` rewrites such a section once, in the boot's machine-file
  migration (`ConfigStore.migrate_machine_file/2`), the only reader of those
  keys, conservatively: nothing the server could not have before is shared
  after. `files_and_shell` is on only where both `files` and `shell` were.
  `history` goes; on a computer linked to its server, where that switch was
  off (`false`, or absent while the switches are reviewed) and the recorder
  is on, the recorder goes off in the same write, since the server never took
  that history (HS-5), and the log says once to turn Computer history on at
  this computer to share it; a recorder that was off stays off; an absent
  `history` while the review still waits is left to that review, which shows
  the history line as the recorder has it; and a computer that is its own
  home (no link) keeps its recorder as it was. The four go; `enabled` and
  `reviewed` stay as they were. A section that already names
  `files_and_shell` keeps it and loses the old keys beside it. Any other load
  that meets an old key refuses it by name.

  The section is a machine section: it never travels with the home, and
  `settings.apply` for it is answered only on this computer
  (`Management.Placement`), so the server can never widen it.

  **Writers.** `forget/1` removes the section (a computer that
  disconnects). `write/2` sets the whole section in a home's `machine.toml`,
  every other line of the file kept, under the config lock: a move's commit
  (`FermixChannels.Home.MoveWorker`), the first boot of a computer that moved
  before M97 (`Computers.Consent.derive_moved/2`) and the review
  (`Consent.review/3`). `save/2` is the settings door's (the `computer`
  section, `Management.Settings`), refused while the settings file changed
  outside Fermix; the review is never one of its keys. Each write to the
  running engine's own home is put into application environment at once, so
  a later settings save renders the same switches, and tells this computer's
  offers reporter (`FermixChannels.Desktop.Offers`, registered as
  `listener/0`) to send its offers again, its invocations
  (`invoke_listener/0`) to read the master switch again, its screen
  (`screen_listener/0`) to let go of the server when the master or the
  screen switch went off, and its browser (`browser_listener/0`) to end the
  server's turns it holds when the master or the browser switch went off.
  `offers_changed/0` tells the offers reporter alone, for a fact an offer
  rests on that is no switch: the recorder's setting.
  """

  alias FermixCore.Home.Archive.ConfigText
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState

  @table "fermix_core.computer"
  @section "machine.toml [#{@table}]"
  # Each switch, in the order the section lists them, with the offers it
  # decides (the moduledoc's one rule).
  @decides [
    files_and_shell: [:files, :shell],
    browser: [:browser],
    computer_use: [:computer_use],
    imessage: [:imessage]
  ]
  @switches Keyword.keys(@decides)
  @switch_of for {switch, offers} <- @decides, offer <- offers, into: %{}, do: {offer, switch}
  @flags [:enabled, :reviewed]
  @keys @flags ++ @switches
  @key_names Map.new(@keys, &{Atom.to_string(&1), &1})
  # The keys an engine before D27 wrote that this one has not (`upgrade/2`).
  @retired ~w(files shell history voice attachments accessory notifications)
  @history_table "fermix_core.computer_history"
  @share_history "Turn Computer history on at this computer to share it with your server."
  @listener :fermix_computer_offers
  @invoke_listener :fermix_computer_invoke
  @screen_listener :fermix_computer_screen
  @browser_listener :fermix_computer_browser

  @typedoc "The normalized section: a keyword of booleans, each key at most once."
  @type t :: [{atom(), boolean()}]

  @typedoc "One switch of the section, besides the master and the review."
  @type switch :: :files_and_shell | :browser | :computer_use | :imessage

  @typedoc "One thing a computer may offer its server (`Computers.Offer`)."
  @type offer :: :files | :shell | :browser | :computer_use | :imessage | :history

  @doc "Every switch besides the master and the review, in the order the section lists them."
  @spec switches() :: [switch()]
  def switches, do: @switches

  @doc "The offers `switch` decides."
  @spec decides(switch()) :: [offer(), ...]
  def decides(switch) when switch in @switches, do: Keyword.fetch!(@decides, switch)

  @doc "The section's table in `machine.toml`."
  @spec table() :: String.t()
  def table, do: @table

  @doc "The registered name of the process told when the switches change."
  @spec listener() :: atom()
  def listener, do: @listener

  @doc """
  The registered name of this computer's invocations
  (`FermixChannels.Desktop.Invoke`'s Admission), told as well when the
  switches change: the master switch off ends what runs there.
  """
  @spec invoke_listener() :: atom()
  def invoke_listener, do: @invoke_listener

  @doc """
  The registered name of this computer's screen while its server drives it
  (`FermixCore.ComputerUse.Seat`), told as well: the master or the screen
  switch off ends that at once (M97 §7.4).
  """
  @spec screen_listener() :: atom()
  def screen_listener, do: @screen_listener

  @doc """
  The registered name of the server's turns this computer's browser holds
  (`FermixCore.Browser.HeldTurnListener`), told as well: the master or the
  browser switch off ends every one of them at once, with what it runs.
  """
  @spec browser_listener() :: atom()
  def browser_listener, do: @browser_listener

  @doc """
  The section as application environment holds it: accepts the parsed file
  (string keys), a keyword and its own output, nil as no section. Raises
  `ArgumentError` naming the key on an unknown key or a value that is not a
  boolean.
  """
  @spec normalize(map() | keyword() | nil) :: t()
  def normalize(nil), do: []

  def normalize(section) when is_map(section) or is_list(section) do
    section
    |> Enum.map(&entry!/1)
    |> Enum.sort_by(fn {key, _value} -> Enum.find_index(@keys, &(&1 == key)) end)
  end

  def normalize(other),
    do: raise(ArgumentError, "#{@section} is not a table: #{inspect(other)}")

  @doc "The inverse of `normalize/1`, in the spellings the file holds: each a boolean already."
  @spec to_keyword(map() | keyword() | nil) :: t()
  def to_keyword(section) when is_map(section) or is_list(section) or is_nil(section),
    do: normalize(section)

  @doc """
  Whether this computer offers `offer`, one a switch decides: the master on,
  reviewed, and that switch on.
  """
  @spec on?(t(), offer()) :: boolean()
  def on?(switches, offer) when is_list(switches) and is_map_key(@switch_of, offer),
    do: open?(switches) and Keyword.get(switches, Map.fetch!(@switch_of, offer), false)

  @doc """
  Whether this computer offers its history: its recorder switched on
  (`recording?`, the Computer history section's own setting), the master on,
  and reviewed.
  """
  @spec history_on?(t(), boolean()) :: boolean()
  def history_on?(switches, recording?) when is_list(switches) and is_boolean(recording?),
    do: open?(switches) and recording?

  defp open?(switches), do: enabled?(switches) and reviewed?(switches)

  @doc "Whether the master switch is on (an absent one is)."
  @spec enabled?(t()) :: boolean()
  def enabled?(switches) when is_list(switches), do: Keyword.get(switches, :enabled, true)

  @doc "Whether the switches were reviewed (absent: yes; false only after `derive_moved`)."
  @spec reviewed?(t()) :: boolean()
  def reviewed?(switches) when is_list(switches), do: Keyword.get(switches, :reviewed, true)

  @doc """
  The whole section with exactly the switches `on` switched on, the master
  on and reviewed unless `flags` say otherwise. Anything in `on` that is no
  switch (an offer such as `files`, or `history`) raises `ArgumentError`.
  """
  @spec only([switch()], keyword()) :: t()
  def only(on, flags \\ []) when is_list(on) and is_list(flags) do
    for key <- on, key not in @switches, do: raise(ArgumentError, "#{inspect(key)} is no switch")

    [enabled: Keyword.get(flags, :enabled, true), reviewed: Keyword.get(flags, :reviewed, true)] ++
      for(switch <- @switches, do: {switch, switch in on})
  end

  @doc "The switches `switches` has on, whatever the master and the review say."
  @spec switched_on(t()) :: [switch()]
  def switched_on(switches) when is_list(switches),
    do: for(switch <- @switches, Keyword.get(switches, switch, false), do: switch)

  @doc "The switches of the running engine, from application environment."
  @spec current() :: t()
  def current, do: Application.get_env(:fermix_core, :computer, [])

  @doc """
  The section in `home`'s `machine.toml`: `{:ok, switches}`, `{:ok, []}` when
  the file or the section is absent, or the read's refusal.
  """
  @spec read(Path.t()) :: {:ok, t()} | {:error, term()}
  def read(home) when is_binary(home) and home != "" do
    with {:ok, section} <- ConfigStore.machine_table(home, @table) do
      {:ok, normalize(section)}
    end
  rescue
    error in ArgumentError -> {:error, {:config, Path.join(home, "machine.toml"), error.message}}
  end

  @doc """
  Sets the whole section in `home`'s `machine.toml` (the moduledoc's
  *Writers*): every key written, every other line of the file kept.
  """
  @spec write(Path.t(), t()) :: :ok | {:error, term()}
  def write(home, switches) when is_binary(home) and home != "" and is_list(switches) do
    whole = normalize(Keyword.merge(only([]), normalize(switches)))
    pairs = for {key, value} <- whole, do: {Atom.to_string(key), to_string(value)}

    with :ok <- ConfigStore.put_machine_table(home, @table, pairs) do
      if running_home?(home), do: Application.put_env(:fermix_core, :computer, whole)
      notify()
    end
  end

  @doc """
  Removes the section from `home`'s `machine.toml` (M97 §3.3: a computer
  that disconnects offers nothing to any server), every other line kept,
  and tells the offers reporter as `write/2` does.
  """
  @spec forget(Path.t()) :: :ok | {:error, term()}
  def forget(home) when is_binary(home) and home != "" do
    with :ok <- ConfigStore.drop_machine_table(home, @table) do
      if running_home?(home), do: Application.put_env(:fermix_core, :computer, [])
      notify()
    end
  end

  @doc """
  The settings door's write of the `computer` section (`answers`: its keys as
  atoms, `enabled` and each switch): refused while the settings file changed
  outside Fermix, as every settings write is. Any write is the owner's review
  of these switches, so it leaves them reviewed. The review is this
  computer's state, never one of the door's keys: `reviewed`, or any key this
  section does not have, raises `ArgumentError`. `opts`: `:home` and
  `:restart_state` (the `RestartState` server's name), for a test.
  """
  @spec save(keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  def save(answers, opts \\ []) when is_list(answers) and is_list(opts) do
    changes = normalize(answers)

    if Keyword.has_key?(changes, :reviewed),
      do: raise(ArgumentError, "#{@section} reviewed is written by a review, never by a save")

    with :ok <- RestartState.writable(server: Keyword.get(opts, :restart_state, RestartState)),
         merged = Keyword.merge(current(), changes) |> Keyword.put(:reviewed, true),
         :ok <- write(Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0), merged) do
      {:ok, %{}}
    end
  end

  @doc """
  The offers reporter alone is told to work its offers out again, for a fact
  an offer rests on that is no switch: this computer's recorder setting,
  which its history offer follows (`ComputerHistory.switch_off/1`).
  """
  @spec offers_changed() :: :ok
  def offers_changed do
    case Process.whereis(@listener) do
      nil -> :ok
      pid -> GenServer.cast(pid, :switches_changed)
    end
  end

  @doc """
  What the boot's machine-file migration does with a section an engine
  before D27 wrote (the moduledoc), given the machine file's `text`
  (`:absent` when there is none) and whether this computer is linked to its
  server (`linked?`, its link file present): `%{machine: new_text, notice:
  {level, sentence}}`, or both nil when there is nothing to rewrite, or
  `{:error, sentence}` for an old key whose value is not a boolean, as a load
  refuses one. The notice is a warning where the rewrite turned something off
  that was on (one of files and commands, or the recorder) or changed whether
  history is offered, else information. Pure: the migration writes
  `machine`, atomically, and logs `notice` once.
  """
  @spec upgrade(String.t() | :absent, boolean()) ::
          %{machine: String.t() | nil, notice: {:info | :warning, String.t()} | nil}
          | {:error, String.t()}
  def upgrade(:absent, linked?) when is_boolean(linked?), do: %{machine: nil, notice: nil}

  def upgrade(text, linked?) when is_binary(text) and is_boolean(linked?) do
    old = for key <- @retired, {:ok, raw} <- [ConfigText.value(text, @table, key)], do: {key, raw}

    case Enum.find(old, fn {_key, raw} -> raw not in ["true", "false"] end) do
      nil when old == [] -> %{machine: nil, notice: nil}
      nil -> upgraded(text, Map.new(old), linked?)
      {key, raw} -> {:error, "#{@section} #{key} takes true or false, and #{raw} is not."}
    end
  end

  defp upgraded(text, old, linked?) do
    merged =
      case ConfigText.value(text, @table, "files_and_shell") do
        {:ok, raw} -> {:kept, raw}
        :absent -> {:merged, to_string(old["files"] == "true" and old["shell"] == "true")}
      end

    without = Enum.reduce(Map.keys(old), text, &elem(ConfigText.drop(&2, @table, &1), 0))
    recorder = ConfigText.value(text, @history_table, "enabled") == {:ok, "true"}
    history = if linked?, do: history_switch(old["history"], text), else: :own_home

    halved? = merged == {:merged, "false"} and "true" in [old["files"], old["shell"]]
    said = history_sentence(history, recorder)
    level = if halved? or said != [], do: :warning, else: :info

    %{
      machine: without |> with_merged(merged) |> with_recorder(history, recorder),
      notice: {level, Enum.join([merged_sentence(merged) | said], " ")}
    }
  end

  # What the old `history` switch said on a linked computer: on, off, or
  # absent while its review waits, which that review decides. Absent was off
  # (an absent offer was off) once the switches were reviewed.
  defp history_switch("true", _text), do: :on
  defp history_switch("false", _text), do: :off

  defp history_switch(nil, text) do
    if ConfigText.value(text, @table, "reviewed") == {:ok, "false"},
      do: :review_decides,
      else: :off
  end

  # History the server never took stays out of its reach (HS-5).
  defp with_recorder(text, :off, true),
    do: ConfigText.put(text, @history_table, "enabled", "false")

  defp with_recorder(text, _history, _recorder), do: text

  defp with_merged(text, {:kept, _raw}), do: text
  defp with_merged(text, {:merged, raw}), do: ConfigText.put(text, @table, "files_and_shell", raw)

  defp merged_sentence({how, raw}) do
    "#{@section} was written by an earlier Fermix and is rewritten once: files and commands " <>
      "are one switch, files_and_shell = #{raw}" <>
      if(how == :merged, do: " (on only where both files and shell were)", else: "") <>
      ", and history, voice, attachments, accessory and notifications are no switches here."
  end

  # What the rewrite did to computer history, where it changed anything the
  # server can have, in words the owner can act on.
  defp history_sentence(:off, true),
    do: [
      "Computer history was not shared with your server before this update, so it is " <>
        "switched off on this computer now and nothing it recorded is sent. " <> @share_history
    ]

  defp history_sentence(:on, false),
    do: [
      "Computer history was shared with your server before this update but was not " <>
        "recording on this computer, and it stays off. " <> @share_history
    ]

  defp history_sentence(_history, _recorder), do: []

  # The offers reporter re-sends what this computer offers, the invocations
  # read the master switch again, the screen lets go of the server and the
  # browser ends the server's turns it holds when their switch went off; none
  # of the first two runs on an engine that is no linked computer.
  defp notify do
    for name <- [@listener, @invoke_listener, @screen_listener, @browser_listener] do
      case Process.whereis(name) do
        nil -> :ok
        pid -> GenServer.cast(pid, :switches_changed)
      end
    end

    :ok
  end

  defp running_home?(home), do: Path.expand(home) == Path.expand(ConfigStore.fermix_home())

  defp entry!({key, value}) when is_binary(key) and is_map_key(@key_names, key),
    do: entry!({Map.fetch!(@key_names, key), value})

  defp entry!({key, value}) when key in @keys and is_boolean(value), do: {key, value}

  defp entry!({key, value}) when key in @keys do
    raise ArgumentError,
          "#{@section} #{key} takes true or false, and #{inspect(value)} is not. Fix it and " <>
            "save again."
  end

  defp entry!({key, _value}) when is_binary(key) or is_atom(key) do
    raise ArgumentError,
          "#{@section} has unknown key(s): #{key}. Allowed keys: " <>
            "#{Enum.map_join(@keys, ", ", &Atom.to_string/1)}. Remove or fix the key; the " <>
            "daemon will not boot until this is fixed."
  end

  defp entry!(other), do: raise(ArgumentError, "#{@section} is not a table: #{inspect(other)}")
end
