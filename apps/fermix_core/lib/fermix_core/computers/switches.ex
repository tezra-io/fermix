defmodule FermixCore.Computers.Switches do
  @moduledoc """
  What Fermix on the server may use on this computer (M97 §7.2): the
  `[fermix_core.computer]` section of this computer's `machine.toml`
  (`Setup.MachineFile`), one master switch and one switch per offer.

      [fermix_core.computer]
      enabled = true        # the master: false refuses everything
      reviewed = true       # false only on a computer that moved before M97
      files = false
      shell = false
      ...

  Every value is a boolean. An absent offer is off, an absent `enabled` and
  `reviewed` are on, so a computer with no section offers nothing. An unknown
  key or a value that is not a boolean refuses the load by name
  (`normalize/1`), as every section does; `to_keyword/1` is its inverse, the
  shape the settings file holds (the config round-trip rule).

  The section is a machine section: it never travels with the home, and
  `settings.apply` for it is answered only on this computer
  (`Management.Placement`), so the server can never widen it. A computer
  offers an offer only while the master is on, the offer is on and the
  switches were reviewed (`on?/2`).

  **Writers.** `forget/1` removes the section (a computer that
  disconnects). `write/2` sets the whole section in a home's `machine.toml`,
  every other line of the file kept, under the config lock: a move's commit
  (`FermixChannels.Home.MoveWorker`), the first boot of a computer that moved
  before M97 (`Computers.Consent.derive_moved/2`) and the review
  (`Consent.review/3`). `save/2` is the settings door's (the `computer`
  section, `Management.Settings`), refused while the settings file changed
  outside Fermix. Each write to the running engine's own home is put into
  application environment at once, so a later settings save renders the same
  switches, and tells this computer's offers reporter
  (`FermixChannels.Desktop.Offers`, registered as `listener/0`) to send its
  offers again, its invocations (`invoke_listener/0`) to read the master
  switch again, and its screen (`screen_listener/0`) to let go of the server
  when the master or the screen switch went off.
  """

  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState

  @table "fermix_core.computer"
  @section "machine.toml [#{@table}]"
  @offers [
    :files,
    :shell,
    :browser,
    :computer_use,
    :imessage,
    :history,
    :voice,
    :attachments,
    :accessory,
    :notifications
  ]
  @flags [:enabled, :reviewed]
  @keys @flags ++ @offers
  @key_names Map.new(@keys, &{Atom.to_string(&1), &1})
  @listener :fermix_computer_offers
  @invoke_listener :fermix_computer_invoke
  @screen_listener :fermix_computer_screen
  @review_kept_sentence "A review cannot be taken back. Switch off what Fermix on your server " <>
                          "may use instead."

  @typedoc "The normalized section: a keyword of booleans, each key at most once."
  @type t :: [{atom(), boolean()}]

  @typedoc "One offer this section has a switch for."
  @type offer ::
          :files
          | :shell
          | :browser
          | :computer_use
          | :imessage
          | :history
          | :voice
          | :attachments
          | :accessory
          | :notifications

  @doc "Every offer this section has a switch for, in the order it lists them."
  @spec offers() :: [offer()]
  def offers, do: @offers

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

  @doc "Whether this computer offers `offer`: the master on, the offer on, and reviewed."
  @spec on?(t(), offer()) :: boolean()
  def on?(switches, offer) when is_list(switches) and offer in @offers,
    do: enabled?(switches) and reviewed?(switches) and Keyword.get(switches, offer, false)

  @doc "Whether the master switch is on (an absent one is)."
  @spec enabled?(t()) :: boolean()
  def enabled?(switches) when is_list(switches), do: Keyword.get(switches, :enabled, true)

  @doc "Whether the switches were reviewed (absent: yes; false only after `derive_moved`)."
  @spec reviewed?(t()) :: boolean()
  def reviewed?(switches) when is_list(switches), do: Keyword.get(switches, :reviewed, true)

  @doc "The whole section with exactly `on` switched on, the master on and reviewed."
  @spec only([offer()], keyword()) :: t()
  def only(on, flags \\ []) when is_list(on) and is_list(flags) do
    [enabled: Keyword.get(flags, :enabled, true), reviewed: Keyword.get(flags, :reviewed, true)] ++
      for(offer <- @offers, do: {offer, offer in on})
  end

  @doc "The offers `switches` has on, whatever the master and the review say."
  @spec switched_on(t()) :: [offer()]
  def switched_on(switches) when is_list(switches),
    do: for(offer <- @offers, Keyword.get(switches, offer, false), do: offer)

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
  atoms, `enabled`, `reviewed` and each offer): refused while the settings
  file changed outside Fermix, as every settings write is. Any write is the
  owner's review of these switches, so it leaves them reviewed; a review is
  never taken back. A key this section does not have raises `ArgumentError`.
  `opts`: `:home` and `:restart_state` (the `RestartState` server's name),
  for a test.
  """
  @spec save(keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  def save(answers, opts \\ []) when is_list(answers) and is_list(opts) do
    changes = normalize(answers)

    if Keyword.get(changes, :reviewed) == false, do: raise(ArgumentError, @review_kept_sentence)

    with :ok <- RestartState.writable(server: Keyword.get(opts, :restart_state, RestartState)),
         merged = Keyword.merge(current(), changes) |> Keyword.put(:reviewed, true),
         :ok <- write(Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0), merged) do
      {:ok, %{}}
    end
  end

  @doc "Every sentence this module says, for the copy rules."
  @spec sentences() :: [String.t()]
  def sentences, do: [@review_kept_sentence]

  # The offers reporter re-sends what this computer offers, the invocations
  # read the master switch again, and the screen lets go of the server when its
  # switch went off; none of the first two runs on an engine that is no linked
  # computer.
  defp notify do
    for name <- [@listener, @invoke_listener, @screen_listener] do
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
