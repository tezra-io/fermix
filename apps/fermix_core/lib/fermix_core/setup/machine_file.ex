defmodule FermixCore.Setup.MachineFile do
  @moduledoc """
  `machine.toml`, beside `config.toml` in every home (M97 §4): the settings
  that describe the computer an engine runs on rather than the home. They are
  the sections only this machine configures
  (`Management.Placement.device_sections/0`: its sandbox, computer use, screen
  history, this Mac's Messages and the accessory link), whole, and one key of
  a home table, `[fermix_core.plugins] dev_local`, the dev plugin folder,
  which names this machine's own checkouts.

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
  """

  alias FermixCore.Home.Archive.ConfigText

  @name "machine.toml"
  # Each machine section, as `Management.Placement` names it, by its table.
  @sections %{
    "sandbox" => "sandbox",
    "computer_use" => "fermix_core.computer_use",
    "computer_history" => "fermix_core.computer_history",
    "channels.imessage" => "fermix_channels.imessage",
    "accessories" => "fermix_channels.accessories"
  }
  @tables ~w(sandbox fermix_core.computer_use fermix_core.computer_history
             fermix_channels.imessage fermix_channels.accessories)
  # The keys of a home table that are this machine's, as table and key.
  @keys [{"fermix_core.plugins", "dev_local"}]
  @server_sandbox_mode :open
  @header "# This computer's own settings, which stay on it when the home moves. Managed by " <>
            "Fermix:\n# the app, the setup page, fermix setup and fermix settings rewrite this file."

  if Enum.sort(Map.values(@sections)) != Enum.sort(@tables) do
    raise CompileError, description: "machine file: every section names one of its tables"
  end

  @typedoc """
  What one boot's migration writes: the new `machine.toml` (nil to leave it
  as it is), the new `config.toml` (nil likewise), the dotted names it removed
  from `config.toml`, and whether the machine file is an Always On server's
  own default.
  """
  @type plan :: %{
          machine: String.t() | nil,
          config: String.t() | nil,
          removed: [String.t()],
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

  @doc "The text of an Always On server's new machine file."
  @spec server_default() :: String.t()
  def server_default, do: @header <> "\n\n[sandbox]\nmode = \"#{@server_sandbox_mode}\"\n"

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
    {text, Enum.reverse(tables) ++ Enum.reverse(keys)}
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
  written (comments included); `""` when it holds none.
  """
  @spec extract(String.t()) :: String.t()
  def extract(text) when is_binary(text) do
    case Enum.flat_map(@tables, &ConfigText.tables(text, &1)) ++
           Enum.flat_map(@keys, &key(text, &1)) do
      [] -> ""
      blocks -> Enum.map_join([@header | blocks], "\n\n", &String.trim_trailing/1) <> "\n"
    end
  end

  defp key(text, {table, key}) do
    case ConfigText.value(text, table, key) do
      {:ok, raw} -> ["[#{table}]\n#{key} = #{raw}"]
      :absent -> []
    end
  end

  # -- migration -----------------------------------------------------------------

  @doc """
  What one boot does with `config` (`config.toml`'s text, `""` when there is
  none) and `machine` (`machine.toml`'s, or `:absent`) on a machine that is an
  Always On server or not (`server?`), in the moduledoc's order: a machine
  file that exists is kept and `config.toml` loses its machine settings; one
  that does not is written from them, or on a server from the server's
  default, before `config.toml` loses them.
  """
  @spec migration(String.t(), String.t() | :absent, boolean()) :: plan()
  def migration(config, machine, server?)
      when is_binary(config) and (is_binary(machine) or machine == :absent) and
             is_boolean(server?) do
    {stripped, removed} = strip(config)

    %{
      machine: new_machine(config, machine, server?),
      config: if(removed == [], do: nil, else: stripped),
      removed: removed,
      server_default?: server? and machine == :absent
    }
  end

  defp new_machine(_config, machine, _server?) when is_binary(machine), do: nil
  defp new_machine(_config, :absent, true), do: server_default()

  defp new_machine(config, :absent, false) do
    case extract(config) do
      "" -> nil
      text -> text
    end
  end

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

  def notice(%{machine: machine, removed: removed}) when is_binary(machine),
    do: {:info, "This computer's own settings moved to #{@name}: #{Enum.join(removed, ", ")}."}

  def notice(%{machine: nil, removed: removed}) do
    {:warning,
     "config.toml held settings #{@name} already holds, so they were removed from it: " <>
       "#{Enum.join(removed, ", ")}."}
  end
end
