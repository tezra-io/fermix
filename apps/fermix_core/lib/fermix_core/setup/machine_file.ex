defmodule FermixCore.Setup.MachineFile do
  @moduledoc """
  `machine.toml`, beside `config.toml` in every home (M97 §4): the settings
  that describe the computer an engine runs on rather than the home. They are
  the sections only this machine configures
  (`Management.Placement.machine_sections/0`, and `computer`: its sandbox,
  computer use, the accessory link, and what Fermix on its server may use on
  it, `Computers.Switches`, whose `imessage` switch says this Mac carries
  Messages), whole, and some keys of a home table: `[fermix_core.plugins]
  dev_local`, the dev plugin folder, which names this machine's own
  checkouts, and of `[fermix_core.computer_history]`, whose screen history
  section splits by key (§4, `ComputerHistory.Config`): `enabled` and `apps`
  are this machine's, `remote_summaries` the home's, and `summarizer` the
  home's route, except that `summarizer = "local"` is this machine's own
  choice too (it makes its own notes), so it is copied here and never taken
  out of `config.toml`, and only that value is read here.
  `[fermix_channels.imessage]` is the home's: that the home uses iMessage,
  its owner and its guests travel with it, so a server knows them (§4), and
  the helper's own state is files under `imessage/` that never leave the Mac
  (`Home.DeviceLocal`).

  The file never travels: it is device-local (`Home.DeviceLocal`), so no
  archive, snapshot or move carries it, a restore leaves these settings out
  of the `config.toml` it writes (`Home.Archive.RestoredConfig`), and a move
  back keeps this computer's own file. `Setup.ConfigStore` reads and writes
  it beside `config.toml` with the same decoder, normalizers and renderer,
  and takes each setting from its own file only (`join/2`).

  **Migration.** A home an earlier engine wrote keeps these settings in
  `config.toml`. `migration/3` says what one boot does about that, and
  `ConfigStore.migrate_machine_file/2` does it under the config lock before
  any setting is read: it writes `machine.toml`, then removes the settings
  from `config.toml`, each write atomic. A boot that finds both files
  finishes the removal and the machine file wins, since it was written
  first. A home with neither is left as it is, except on an Always On server
  (`Home.Candidate.server?/1`): a server's new machine file starts from the
  server's own default (`server_default/0`: the sandbox `open`, the agent free
  inside the server's account, Fermix's secrets unreadable in every mode),
  and the settings a server inherited from the computer its home came from
  are left out, which `notice/1` says once.

  Computer history's keys follow the same steps: `enabled` and `apps` move,
  a local `summarizer` is copied (`copied/1`) and stays in `config.toml` as
  the home's route, and the home's `remote_summaries` stays. A server takes
  none of the computer's (its machine file is its own default) and keeps the
  home's route and grants.

  **The coding agents' keys (M98 D5).** `[fermix_core.harness]` splits by key
  too (`Harness.Config`): `approved`, `codex_home` and `claude_config_dir` are
  this machine's, every other key the home's. A machine file an earlier engine
  wrote has none of them, and the rule above would drop them from
  `config.toml` with nothing taking them. So every machine file this engine
  writes holds the table, `approved` written even when off (`@markers`), and
  a machine file without it, while `config.toml` holds one of those keys,
  takes them from `config.toml` once (`generated`): written into the machine
  file first, then removed from `config.toml`, after which the rule above
  holds. A machine file without the table and a `config.toml` without the
  keys are left as they are.

  **The browser's keys (M97 D28d).** Every key a person sets in
  `[fermix_core.browser]` (`Browser.Config.config_keys/0`: the private hosts
  it may open, how tasks run, the most open tabs, whether it may open the
  app) is this machine's, so a server's browser and a computer's are each set
  on their own machine, and no move or backup carries them. They move as the
  coding agents' keys did, with `default_profile` as the table's marker,
  written even at its default, `"fermix"`, which is how tasks run with no
  setting at all (`Browser.Config.to_keyword/1`). A server with no machine
  file starts from its default, its browser at the shipped defaults, and
  leaves out the computer's; one whose machine file exists takes the keys in
  force there, as it takes a sign-in folder.

  **Back to the home.** An engine of this milestone's stage 0 wrote
  `[fermix_channels.imessage]`, and the whole `[fermix_core.computer_history]`,
  into `machine.toml`. `homeward/2` says what one boot does about that,
  before the step above: `config.toml` takes the iMessage section and the
  home's history keys (`remote_summaries`, and a `summarizer` that is not
  `"local"`) from the machine file, replacing any copy of them there, then the
  machine file loses them, each write atomic. A local `summarizer` stays
  here, and `config.toml` takes it as the home's route only where it names
  none, so a later edit of the route there is never undone. A boot stopped
  between the two finds them in both and does the same again, which changes
  nothing in `config.toml`.
  """

  alias FermixCore.Browser.Config, as: BrowserConfig
  alias FermixCore.Harness.Config, as: HarnessConfig
  alias FermixCore.Home.Archive.ConfigText

  @name "machine.toml"
  # Each machine section, as `Management.Placement` names it, by its table.
  @sections %{
    "sandbox" => "sandbox",
    "computer_use" => "fermix_core.computer_use",
    "computer_history" => "fermix_core.computer_history",
    "accessories" => "fermix_channels.accessories",
    "computer" => "fermix_core.computer",
    "harness_machine" => "fermix_core.harness",
    "browser" => "fermix_core.browser"
  }
  @tables ~w(sandbox fermix_core.computer_use fermix_channels.accessories fermix_core.computer)
  # Tables an earlier engine kept here that are the home's (`homeward/2`).
  @homeward ~w(fermix_channels.imessage)
  # The coding agents' keys that are this machine's (`Harness.Config`).
  @harness_keys for key <- HarnessConfig.machine_keys(),
                    do: {"fermix_core.harness", Atom.to_string(key)}
  # Every settable browser key is this machine's (`Browser.Config`, D28d).
  @browser_keys for key <- BrowserConfig.config_keys(),
                    do: {"fermix_core.browser", Atom.to_string(key)}
  # The keys of a home table that are this machine's, as table and key.
  @keys [
    {"fermix_core.plugins", "dev_local"},
    {"fermix_core.computer_history", "enabled"},
    {"fermix_core.computer_history", "apps"}
    | @harness_keys ++ @browser_keys
  ]
  # The tables whose machine keys an earlier machine file never held, each
  # with the key every machine file this engine writes sets there and that
  # key's value when nothing gives one: a machine file without the table was
  # written before those keys were this machine's (`migration/3`). Each
  # value is what the engine does with the key unset, so writing it changes
  # nothing (`Browser.Config.to_keyword/1` writes the browser's the same).
  @markers [
    {"fermix_core.harness", "approved", "false"},
    {"fermix_core.browser", "default_profile", ~s("fermix")}
  ]
  # A key of a home table that is this machine's own only with one value,
  # which is then both: copied here, never taken out of config.toml.
  @local_summarizer {"fermix_core.computer_history", "summarizer", "local"}
  # Keys an earlier engine kept here that are the home's (`homeward/2`).
  @homeward_keys [
    {"fermix_core.computer_history", "remote_summaries"},
    {"fermix_core.computer_history", "summarizer"}
  ]
  @server_sandbox_mode :open
  @header "# This computer's own settings, which stay on it when the home moves. Managed by " <>
            "Fermix:\n# the app, the setup page, fermix setup and fermix settings rewrite this file."

  if Map.values(@sections) -- (@tables ++ Enum.map(@keys, &elem(&1, 0))) != [] do
    raise CompileError,
      description: "machine file: every section names one of its tables, whole or by key"
  end

  @typedoc """
  What one boot's migration writes: the new `machine.toml` (nil to leave it
  as it is), the new `config.toml` (nil likewise), the dotted names it removed
  from `config.toml`, those it copied into the new machine file and left in
  `config.toml` (`copied/1`), those it took from `config.toml` into a machine
  file that exists (`generated`, the moduledoc's coding agents' and
  browser's keys), and whether the machine file is an Always On server's own
  default.
  """
  @type plan :: %{
          machine: String.t() | nil,
          config: String.t() | nil,
          removed: [String.t()],
          copied: [String.t()],
          generated: [String.t()],
          server_default?: boolean()
        }

  @doc "The machine file of `home`."
  @spec path(Path.t()) :: Path.t()
  def path(home) when is_binary(home) and home != "", do: Path.join(home, @name)

  @doc "Each machine section, as `Management.Placement` names it, with its table."
  @spec sections() :: %{String.t() => String.t()}
  def sections, do: @sections

  @doc "The sandbox mode an Always On server's new machine file starts with."
  @spec server_sandbox_mode() :: :open
  def server_sandbox_mode, do: @server_sandbox_mode

  @doc """
  The text of an Always On server's new machine file: coding agents not
  approved, and its browser at the shipped defaults.
  """
  @spec server_default() :: String.t()
  def server_default,
    do: with_markers(@header <> "\n\n[sandbox]\nmode = \"#{@server_sandbox_mode}\"\n")

  @doc "The header a rendered machine file starts with."
  @spec header() :: String.t()
  def header, do: @header

  # -- decoded documents ---------------------------------------------------------

  @doc """
  One settings document from a decoded `config.toml` and a decoded
  `machine.toml` (nested string-keyed maps): every machine setting from the
  machine file only, and everything else from `config.toml` only.
  """
  @spec join(map(), map()) :: map()
  def join(config, machine) when is_map(config) and is_map(machine) do
    Enum.reduce(paths(), drop(config), fn path, acc ->
      case fetch_path(machine, path) do
        {:ok, value} -> put_path(acc, path, value)
        :error -> acc
      end
    end)
  end

  @doc "A decoded settings document without its machine settings."
  @spec drop(map()) :: map()
  def drop(document) when is_map(document), do: Enum.reduce(paths(), document, &drop_path(&2, &1))

  defp paths do
    Enum.map(@tables, &String.split(&1, ".")) ++
      Enum.map(@keys, fn {table, key} -> String.split(table, ".") ++ [key] end)
  end

  defp fetch_path(document, [key]), do: Map.fetch(document, key)

  defp fetch_path(document, [key | rest]) do
    case Map.fetch(document, key) do
      {:ok, %{} = inner} -> fetch_path(inner, rest)
      _absent_or_value -> :error
    end
  end

  defp drop_path(document, [key]), do: Map.delete(document, key)

  defp drop_path(document, [key | rest]) do
    case Map.fetch(document, key) do
      {:ok, %{} = inner} -> Map.put(document, key, drop_path(inner, rest))
      _absent_or_value -> document
    end
  end

  defp put_path(document, [key], value), do: Map.put(document, key, value)

  defp put_path(document, [key | rest], value) do
    inner =
      case Map.get(document, key) do
        %{} = inner -> inner
        _absent -> %{}
      end

    Map.put(document, key, put_path(inner, rest, value))
  end

  # -- text ----------------------------------------------------------------------

  @doc """
  `config.toml`'s `text` without its machine settings, every other line kept
  (`Home.Archive.ConfigText`), and the dotted name of each it held: a table
  with every table beneath it, and a key alone.
  """
  @spec strip(String.t()) :: {String.t(), [String.t()]}
  def strip(text) when is_binary(text) do
    {text, tables} = Enum.reduce(@tables, {text, []}, &strip_table/2)
    {text, keys} = Enum.reduce(@keys, {text, []}, &strip_key/2)
    keys = Enum.reverse(keys)
    {drop_emptied(text, keys), Enum.reverse(tables) ++ keys}
  end

  # A home table whose keys here were all this machine's is left as a bare
  # header; it goes too, where no table beneath it holds a key either.
  defp drop_emptied(text, stripped) do
    for({table, key} <- @keys, "#{table}.#{key}" in stripped, uniq: true, do: table)
    |> Enum.reduce(text, fn table, acc ->
      blocks = ConfigText.tables(acc, table)
      if Enum.all?(blocks, &keyless?/1), do: ConfigText.drop_tables(acc, table), else: acc
    end)
  end

  defp keyless?(block) do
    block
    |> String.split("\n")
    |> Enum.drop(1)
    |> Enum.all?(&(String.trim(&1) == "" or String.starts_with?(String.trim(&1), "#")))
  end

  defp strip_table(table, {text, removed}) do
    case ConfigText.tables(text, table) do
      [] -> {text, removed}
      _blocks -> {ConfigText.drop_tables(text, table), [table | removed]}
    end
  end

  defp strip_key({table, key}, {text, removed}) do
    case ConfigText.drop(text, table, key) do
      {text, true} -> {text, ["#{table}.#{key}" | removed]}
      {text, false} -> {text, removed}
    end
  end

  @doc """
  The machine settings `config.toml`'s `text` holds, as a machine file, as
  written (comments included), with a local summarizer copied (`copied/1`)
  and each marker table (the moduledoc's coding agents' and browser's keys);
  `""` when it holds none. Keys of one table are one table here.
  """
  @spec extract(String.t()) :: String.t()
  def extract(text) when is_binary(text) do
    case Enum.flat_map(@tables, &ConfigText.tables(text, &1)) ++ key_blocks(text) do
      [] ->
        ""

      blocks ->
        with_markers(Enum.map_join([@header | blocks], "\n\n", &String.trim_trailing/1) <> "\n")
    end
  end

  # Every machine file this engine writes holds each marker table, its key
  # written even at its default (`@markers`).
  defp with_markers(text) do
    Enum.reduce(@markers, text, fn {table, key, default}, acc ->
      if ConfigText.value(acc, table, key) == :absent,
        do: ConfigText.put(acc, table, key, default),
        else: acc
    end)
  end

  # This machine's keys of each marker table `machine` lacks, as `config`
  # sets them, each as table, key and raw value: what the generation step
  # takes into a machine file that exists.
  defp ungenerated(_config, :absent), do: []

  defp ungenerated(config, machine) do
    for {table, _key, _default} <- @markers,
        ConfigText.tables(machine, table) == [],
        {^table, key} <- @keys,
        {:ok, raw} <- [ConfigText.value(config, table, key)],
        do: {table, key, raw}
  end

  defp key_blocks(text) do
    lines = for {table, key, raw} <- machine_values(text), do: {table, "#{key} = #{raw}"}

    for table <- lines |> Enum.map(&elem(&1, 0)) |> Enum.uniq(),
        do: Enum.join(["[#{table}]" | for({^table, line} <- lines, do: line)], "\n")
  end

  # This machine's keys `text` sets, each as table, key and raw value: the
  # ones it owns, then a local summarizer.
  defp machine_values(text) do
    owned =
      for {table, key} <- @keys,
          {:ok, raw} <- [ConfigText.value(text, table, key)],
          do: {table, key, raw}

    owned ++ local_summarizer(text)
  end

  defp local_summarizer(text) do
    {table, key, _local} = @local_summarizer

    case ConfigText.value(text, table, key) do
      {:ok, raw} -> if local?({table, key, raw}), do: [{table, key, raw}], else: []
      :absent -> []
    end
  end

  defp local?({table, key, raw}) do
    {local_table, local_key, local} = @local_summarizer
    {table, key, ConfigText.string(raw)} == {local_table, local_key, {:ok, local}}
  end

  @doc """
  The dotted names `extract/1` copies from `config.toml`'s `text` without
  `strip/1` removing them: a summarizer that says `"local"`, which is this
  machine's choice and the home's route both.
  """
  @spec copied(String.t()) :: [String.t()]
  def copied(text) when is_binary(text),
    do: for({table, key, _raw} <- local_summarizer(text), do: "#{table}.#{key}")

  # -- migration -----------------------------------------------------------------

  @doc """
  What one boot does with `config` (`config.toml`'s text, `""` when there is
  none) and `machine` (`machine.toml`'s, or `:absent`) on a machine that is an
  Always On server or not (`server?`), in the moduledoc's order: a machine
  file that exists is kept and `config.toml` loses its machine settings,
  after the machine file takes the keys of a marker table it lacks from
  `config.toml` (`generated`); one that does not is written from them, or on
  a server from the server's default, before `config.toml` loses them.
  """
  @spec migration(String.t(), String.t() | :absent, boolean()) :: plan()
  def migration(config, machine, server?)
      when is_binary(config) and (is_binary(machine) or machine == :absent) and
             is_boolean(server?) do
    {stripped, removed} = strip(config)
    extracted? = machine == :absent and not server?
    generated = ungenerated(config, machine)

    %{
      machine: new_machine(config, machine, server?, generated),
      config: if(removed == [], do: nil, else: stripped),
      removed: removed,
      copied: if(extracted?, do: copied(config), else: []),
      generated: for({table, key, _raw} <- generated, do: "#{table}.#{key}"),
      server_default?: server? and machine == :absent
    }
  end

  defp new_machine(_config, machine, _server?, []) when is_binary(machine), do: nil

  defp new_machine(_config, machine, _server?, generated) when is_binary(machine) do
    generated
    |> Enum.reduce(machine, fn {table, key, raw}, acc -> ConfigText.put(acc, table, key, raw) end)
    |> with_markers()
  end

  defp new_machine(_config, :absent, true, _generated), do: server_default()

  defp new_machine(config, :absent, false, _generated) do
    case extract(config) do
      "" -> nil
      text -> text
    end
  end

  @doc """
  What one boot does with the home's tables and keys an earlier engine wrote
  into the machine file (the moduledoc's "Back to the home"): from `config`
  (`config.toml`'s text, `""` when there is none) and `machine`
  (`machine.toml`'s, or `:absent`), the new `config.toml`, written first, and
  the new `machine.toml`, nil for either when it changes nothing; and the
  dotted name of each it gave `config.toml`.
  """
  @spec homeward(String.t(), String.t() | :absent) ::
          %{config: String.t() | nil, machine: String.t() | nil, moved: [String.t()]}
  def homeward(config, machine) when is_binary(config) and is_binary(machine) do
    tables = Enum.filter(@homeward, &(ConfigText.tables(machine, &1) != []))

    start =
      if tables == [],
        do: %{config: config, machine: machine, out: [], copied: []},
        else: %{
          config: home_with(config, machine, tables),
          machine: without(machine, tables),
          out: tables,
          copied: []
        }

    done = Enum.reduce(@homeward_keys, start, &homeward_key/2)

    %{
      config: if(done.out == [] and done.copied == [], do: nil, else: done.config),
      machine: if(done.out == [], do: nil, else: done.machine),
      moved: done.out ++ done.copied
    }
  end

  def homeward(config, :absent) when is_binary(config),
    do: %{config: nil, machine: nil, moved: []}

  defp homeward_key({table, key}, acc) do
    case ConfigText.value(acc.machine, table, key) do
      {:ok, raw} -> homeward_value({table, key, raw}, acc)
      :absent -> acc
    end
  end

  # A home key goes to config.toml, replacing its copy there, and leaves the
  # machine file; a local summarizer is this machine's too, so it stays, and
  # config.toml takes it only where it names no route of its own.
  defp homeward_value({table, key, raw}, acc) do
    name = "#{table}.#{key}"

    cond do
      not local?({table, key, raw}) ->
        {machine, true} = ConfigText.drop(acc.machine, table, key)
        config = ConfigText.put(acc.config, table, key, raw)
        %{acc | config: config, machine: machine, out: acc.out ++ [name]}

      ConfigText.value(acc.config, table, key) == :absent ->
        %{acc | config: ConfigText.put(acc.config, table, key, raw), copied: acc.copied ++ [name]}

      true ->
        acc
    end
  end

  # The machine file's copy of each table replaces any in config.toml.
  defp home_with(config, machine, tables) do
    blocks = Enum.flat_map(tables, &ConfigText.tables(machine, &1))
    rest = config |> without(tables) |> String.trim_trailing()

    Enum.map_join(Enum.reject([rest | blocks], &(&1 == "")), "\n\n", &String.trim_trailing/1) <>
      "\n"
  end

  defp without(text, tables), do: Enum.reduce(tables, text, &ConfigText.drop_tables(&2, &1))

  @doc "What `homeward/2`'s `moved` is said with once it is done, or nil when it moved none."
  @spec homeward_notice([String.t()]) :: String.t() | nil
  def homeward_notice([]), do: nil

  def homeward_notice(moved),
    do:
      "These settings are the home's, so they moved from #{@name} back to config.toml: " <>
        Enum.join(moved, ", ") <> "."

  @doc """
  What `plan` is said with once it is done, as a level and a sentence, or nil
  when it changes nothing.
  """
  @spec notice(plan()) :: {:info | :warning, String.t()} | nil
  def notice(%{machine: nil, config: nil}), do: nil

  def notice(%{server_default?: true, removed: []}),
    do: {:info, "This server uses its own sandbox setting: #{@server_sandbox_mode}."}

  def notice(%{server_default?: true, removed: removed}) do
    {:warning,
     "This server now uses its own sandbox setting: #{@server_sandbox_mode}. The settings it " <>
       "inherited from the computer its home came from were left out: #{Enum.join(removed, ", ")}."}
  end

  # The generation step: what it took into the machine file moved; any other
  # machine setting config.toml held is dropped, since the machine file wins.
  def notice(%{generated: [_ | _] = generated, removed: removed}) do
    case removed -- generated do
      [] -> {:info, moved_sentence(generated)}
      dropped -> {:warning, moved_sentence(generated) <> " " <> elem(dropped_notice(dropped), 1)}
    end
  end

  def notice(%{machine: machine, removed: removed, copied: copied}) when is_binary(machine),
    do: {:info, moved_sentence(removed ++ copied)}

  # A boot stopped between the two writes, or a section written into
  # config.toml by hand since: either way the machine file is what is read.
  def notice(%{machine: nil, removed: removed}), do: dropped_notice(removed)

  defp moved_sentence(names),
    do: "This computer's own settings moved to #{@name}: #{Enum.join(names, ", ")}."

  @doc """
  What removing machine settings from `config.toml` is said with (`names`, as
  `strip/1` names them): at a start (`notice/1`), and at a settings save,
  which writes `config.toml` from what runs and so never keeps one written
  there by hand (`Setup.ConfigStore.save_snapshot/2`).
  """
  @spec dropped_notice([String.t(), ...]) :: {:warning, String.t()}
  def dropped_notice([_ | _] = names) do
    {:warning,
     "config.toml held this computer's own settings, which Fermix reads only from #{@name}, " <>
       "so they were removed from it: #{Enum.join(names, ", ")}."}
  end

  @doc """
  What a settings reload says when `config.toml` holds machine settings
  (`names`, as `strip/1` names them): someone wrote them there by hand since
  the boot moved them. Nothing reads them there, so the sentence says where
  they belong and what the next save or start does with them.
  """
  @spec misplaced_notice([String.t(), ...]) :: String.t()
  def misplaced_notice([_ | _] = names) do
    "config.toml holds this computer's own settings, which Fermix reads only from #{@name}, " <>
      "so they are ignored: #{Enum.join(names, ", ")}. Move them to #{@name}; the next " <>
      "settings save or start removes them from config.toml."
  end
end
