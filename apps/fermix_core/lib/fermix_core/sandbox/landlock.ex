defmodule FermixCore.Sandbox.Landlock do
  @moduledoc """
  The Landlock rules that hold a command to the sandbox on Linux
  (OS_SANDBOX_ENFORCEMENT stage B), and the `fermix_landlock` exec shim that
  applies them.

  Landlock only grants: whatever no rule covers is refused, and a rule on a
  folder reaches everything beneath it. So the rules are carved folder by
  folder around what a command may not reach. A folder with nothing protected
  beneath it is granted whole. A folder that holds a protected path gets no
  write rule of its own and only `l` (list) to read, and each of its entries is
  decided the same way, so the protected entry is the one left without a rule.
  An entry that appears later in a carved folder therefore gets nothing but
  `l`: commands cannot create entries directly in a carved folder (in `open`,
  the OS home and `/` among them), and cannot read what the daemon writes there
  afterwards (`auth.json.tmp.N`), which is what holds the names-alike rules.

  One thing Landlock cannot express stays open: a name in a read-denied folder
  can be listed (`l` on a carved folder reaches every folder beneath it; the
  contents stay unreadable). Every read-denied region is held, so nothing
  Fermix keeps secret may sit in a temp folder: a rule there would close the
  temp folder to every new file (`secret_writer` stages a key being saved
  under the home's `secrets/` for that reason).

  `grants/2` is pure over an injected filesystem (`disk/0` is the real one), so
  it is unit-tested on a fake tree; symlinks are never granted (every path the
  rules name is resolved, and a symlink is checked at its target), and an entry
  that disappears while the folder is read is skipped.

  The shim's access letters: `x` execute, `r` read a file, `l` list a folder,
  `w` write (and truncate) a file, `c` create, remove, rename and link entries,
  `i` use a device's ioctl commands (only the terminals get it, so a pty
  works; the kernel holds the rest from Landlock ABI 5).
  """

  alias FermixCore.Sandbox.OsSandbox

  @shim "fermix_landlock"
  # Every rule is one argument of the shim, so the rules stay far below the
  # kernel's argument space (`ARG_MAX`). A carve this wide means a folder with
  # tens of thousands of entries holds a protected path (a Fermix home inside a
  # busy temp folder): the command refuses rather than fail to start.
  @max_rules 8_192
  @letters ~w(x r l w c i)
  # The lowest Landlock ABI that holds commands: ABI 2 (Linux 6.1 and before)
  # cannot refuse `truncate(2)`, so a command could empty a file it may only
  # read. The shim refuses below it too; this keeps a shim that answers lower
  # from being taken at its word.
  @floor 3
  @unavailable "This computer can't sandbox commands (Landlock is unavailable), so Fermix won't run them"

  @typedoc "One rule: a resolved path and the access letters it grants beneath it."
  @type grant :: {String.t(), String.t()}

  @typedoc """
  The filesystem `grants/2` reads: `list` a folder's entry names, and the
  `type` of a path without following a link.
  """
  @type fs :: %{
          list: (String.t() -> {:ok, [String.t()]} | {:error, term()}),
          type: (String.t() -> :directory | :regular | :symlink | :other | :missing)
        }

  @typedoc """
  The resolved path sets of `OsSandbox.rules/3`: the writable roots,
  Fermix's home and what stays writable inside it,
  what is never writable (`protected` trees, and the owner's `credentials`
  with the files named after them), what is never readable, the folders never
  run from, and the device files a command writes with the letters each gets.
  """
  @type input :: %{
          writable: [String.t()],
          fermix_home: String.t(),
          fermix_writable: [String.t()],
          protected: [String.t()],
          credentials: [String.t()],
          unreadable: [OsSandbox.unreadable()],
          no_exec: [String.t()],
          devices: [grant()]
        }

  @typedoc "Why the shim cannot hold commands here."
  @type probe_error ::
          {:shim_missing, String.t()}
          | {:unavailable, String.t()}
          | {:failed, integer() | atom(), String.t()}

  @doc "Where the release carries the shim."
  @spec shim_path() :: String.t()
  def shim_path, do: Application.app_dir(:fermix_nif, "priv/" <> @shim)

  @doc """
  The rules for `input`, read from `fs`: `{:ok, grants}` sorted by path, or
  `{:error, {:unlistable, folder, reason}}` when a folder that holds a
  protected path cannot be listed (the command then refuses rather than run
  with that folder closed or open), or `{:error, {:too_many_rules, count,
  max}}` past `max_rules/0`.
  """
  @spec grants(input(), fs()) :: {:ok, [grant()]} | {:error, term()}
  def grants(%{} = input, %{list: list, type: type} = fs)
      when is_function(list, 1) and is_function(type, 1) do
    ctx = context(input, fs)
    roots = Enum.reject(input.writable, &(fs.type.(&1) == :missing))

    with {:ok, reads} <- read_grants("/", ctx),
         {:ok, writes} <- each(roots, &write_grants(&1, ctx)) do
      bounded(merge(reads ++ writes ++ device_grants(input.devices, fs)))
    end
  end

  @doc "The most rules one command carries."
  @spec max_rules() :: pos_integer()
  def max_rules, do: @max_rules

  defp bounded(grants) when length(grants) <= @max_rules, do: {:ok, grants}
  defp bounded(grants), do: {:error, {:too_many_rules, length(grants), @max_rules}}

  @doc "The shim's rule arguments for `grants`, one `ACCESS:PATH` each."
  @spec args([grant()]) :: [String.t()]
  def args(grants) when is_list(grants),
    do: Enum.map(grants, fn {path, access} -> "#{access}:#{path}" end)

  @doc "The real filesystem, read in the calling process (as `PathPolicy` reads it)."
  @spec disk() :: fs()
  def disk, do: %{list: &list_dir/1, type: &type_of/1}

  @doc """
  Whether the kernel can hold commands here, asked of the shim itself
  (`fermix_landlock --abi`): `{:ok, abi}` from ABI 3 (Linux 6.2), or why not.
  Runs one short process; the shim makes the same check before every command.
  """
  @spec probe(String.t()) :: {:ok, pos_integer()} | {:error, probe_error()}
  def probe(shim) when is_binary(shim) do
    if File.regular?(shim), do: run_probe(shim), else: {:error, {:shim_missing, shim}}
  end

  @doc "The sentence for a `probe/1` error, which refuses every command."
  @spec describe(probe_error()) :: String.t()
  def describe({:shim_missing, shim}),
    do: "Commands can't run: Fermix's Landlock shim is missing at #{shim}; reinstall Fermix."

  def describe({:unavailable, line}), do: "#{@unavailable}: #{detail(line)}."

  def describe({:failed, status, output}),
    do: "Commands can't run: Fermix's Landlock shim failed its check (#{status}): #{output}"

  @doc """
  The sentence for a command the shim itself refused (its exit code with its
  own `fermix_landlock:` line), or nil when the exit is the command's.
  """
  @spec refusal(integer(), String.t()) :: String.t() | nil
  def refusal(69, "fermix_landlock: " <> _rest = output),
    do: "#{@unavailable}: #{detail(first_line(output))}."

  def refusal(exit_code, "fermix_landlock: " <> _rest = output) when exit_code in [64, 65, 71],
    do: "The command could not start inside Fermix's sandbox: #{first_line(output)}"

  def refusal(exit_code, output) when is_integer(exit_code) and is_binary(output), do: nil

  # ── carving ────────────────────────────────────────────────────────────────

  # Every rule is a region: a `:tree` covers its path and what is beneath it;
  # `:named` also the files named after it (`credentials.db-wal`), and
  # `:prefix` every entry of its folder whose name begins with its own.
  defp context(input, fs) do
    held = input.unreadable
    no_exec = Enum.map(input.no_exec, &{&1, :tree})

    deny_write =
      Enum.map(input.protected, &{&1, :tree}) ++
        Enum.map(input.credentials, &{&1, :named}) ++ held

    %{
      fs: fs,
      deny_read: held,
      read_carvers: held ++ no_exec,
      no_exec: no_exec,
      deny_write: deny_write,
      write_carvers: [{input.fermix_home, :tree} | deny_write],
      fermix_home: input.fermix_home,
      fermix_writable: input.fermix_writable
    }
  end

  defp read_grants(path, ctx) do
    cond do
      Enum.any?(ctx.deny_read, &covers?(&1, path)) ->
        {:ok, []}

      Enum.any?(ctx.read_carvers, &carves?(&1, path)) ->
        carve(path, "l", &read_grants(&1, ctx), ctx.fs)

      Enum.any?(ctx.no_exec, &covers?(&1, path)) ->
        {:ok, [{path, "rl"}]}

      true ->
        {:ok, [{path, "xrl"}]}
    end
  end

  # Inside Fermix's home only the workspace, the skills folder and a grant are
  # writable; the home itself is carved down to them.
  defp write_grants(path, ctx) do
    locked? = home_locked?(path, ctx)

    cond do
      Enum.any?(ctx.deny_write, &covers?(&1, path)) ->
        {:ok, []}

      locked? and not Enum.any?(ctx.fermix_writable, &below?(&1, path)) ->
        {:ok, []}

      locked? ->
        carve(path, nil, &write_grants(&1, ctx), ctx.fs)

      Enum.any?(ctx.write_carvers, &carves?(&1, path)) ->
        carve(path, nil, &write_grants(&1, ctx), ctx.fs)

      true ->
        {:ok, [{path, "wc"}]}
    end
  end

  defp home_locked?(path, ctx) do
    covers?({ctx.fermix_home, :tree}, path) and
      not Enum.any?(ctx.fermix_writable, &covers?({&1, :tree}, path))
  end

  # A carved folder's own grant (`l` to read, none to write), then each entry's.
  defp carve(dir, own, decide, fs) do
    case fs.list.(dir) do
      {:ok, names} ->
        entries =
          names |> Enum.sort() |> Enum.map(&join(dir, &1)) |> Enum.filter(&grantable?(&1, fs))

        with {:ok, grants} <- each(entries, decide) do
          {:ok, if(own, do: [{dir, own} | grants], else: grants)}
        end

      {:error, reason} ->
        {:error, {:unlistable, dir, reason}}
    end
  end

  # Folders and files only. A symlink is never a rule (its target is judged at
  # its own path), an entry gone since the listing needs none, and a socket,
  # pipe or device inside a carved folder gets none either (a unix socket's
  # connect is not something Landlock decides).
  defp grantable?(path, fs), do: fs.type.(path) in [:directory, :regular]

  defp each(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, grants} -> {:cont, {:ok, [grants | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, acc |> Enum.reverse() |> Enum.concat()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp device_grants(devices, fs) do
    for {device, access} <- devices,
        fs.type.(device) not in [:symlink, :missing],
        do: {device, access}
  end

  # Whether a region covers `path`.
  defp covers?({root, :tree}, path), do: path == root or below?(path, root)

  defp covers?({root, reach}, path) do
    case first_below(path, Path.dirname(root)) do
      nil -> false
      name -> named?(name, Path.basename(root), reach)
    end
  end

  # Whether `dir` must be carved for a region: the region lies beneath it, or,
  # for a named or prefix region, its folder is `dir` or beneath it, where an
  # entry with that name can still appear.
  defp carves?({root, :tree}, dir), do: below?(root, dir)

  defp carves?({root, _reach}, dir) do
    folder = Path.dirname(root)
    folder == dir or below?(folder, dir)
  end

  defp named?(name, base, :prefix), do: String.starts_with?(name, base)

  defp named?(name, base, :named),
    do:
      name == base or String.starts_with?(name, base <> ".") or
        String.starts_with?(name, base <> "-")

  defp below?(path, "/"), do: path != "/"
  defp below?(path, dir), do: String.starts_with?(path, dir <> "/")

  defp first_below(path, dir) do
    if below?(path, dir) do
      prefix = if dir == "/", do: "/", else: dir <> "/"
      path |> String.replace_prefix(prefix, "") |> String.split("/", parts: 2) |> hd()
    end
  end

  defp join("/", name), do: "/" <> name
  defp join(dir, name), do: dir <> "/" <> name

  # One rule per path, its letters merged in a fixed order.
  defp merge(grants) do
    grants
    |> Enum.reduce(%{}, fn {path, access}, acc ->
      Map.update(acc, path, access, &(&1 <> access))
    end)
    |> Enum.map(fn {path, access} ->
      {path, Enum.filter(@letters, &String.contains?(access, &1)) |> Enum.join()}
    end)
    |> Enum.sort()
  end

  # ── the real filesystem and the shim ───────────────────────────────────────

  defp list_dir(dir) do
    case :prim_file.list_dir(dir) do
      {:ok, names} -> {:ok, Enum.map(names, &IO.chardata_to_string/1)}
      {:error, _reason} = error -> error
    end
  end

  # An entry that cannot be looked at (gone, or behind a folder this account
  # cannot search) is one a command cannot reach either: no rule.
  defp type_of(path) do
    case :file.read_link_info(path, [:raw]) do
      {:ok, info} -> info |> File.Stat.from_record() |> Map.fetch!(:type) |> known_type()
      {:error, _reason} -> :missing
    end
  end

  defp known_type(type) when type in [:directory, :regular, :symlink], do: type
  defp known_type(_device_or_other), do: :other

  defp run_probe(shim) do
    case System.cmd(shim, ["--abi"], stderr_to_stdout: true) do
      {"fermix_landlock: abi " <> abi, 0} = answer -> abi(Integer.parse(abi), answer)
      {output, 69} -> {:error, {:unavailable, first_line(output)}}
      {output, status} -> {:error, {:failed, status, first_line(output)}}
    end
  rescue
    error in ErlangError -> {:error, {:failed, error.original, "could not run #{shim}"}}
  end

  defp abi({abi, "\n"}, _answer) when abi >= @floor, do: {:ok, abi}
  defp abi(_parsed, {output, status}), do: {:error, {:failed, status, first_line(output)}}

  defp first_line(output), do: output |> String.split("\n", parts: 2) |> hd() |> String.trim()
  defp detail(line), do: String.replace_prefix(line, "fermix_landlock: ", "")
end
