defmodule FermixTestSupport.TestSourceScan do
  @moduledoc """
  Reads the umbrella's own test files for the tests that hold test-writing rules
  as gates (`test_safety_test.exs`, `test_load_safety_test.exs`). `files_under/2`
  and `read!/1` also serve the tests that scan the apps' own source.

  The corpus is every `apps/*/test/**/*_test.exs`, found from this file's own
  directory rather than the cwd: `mix test` is a recursive umbrella task and
  runs a child app's tests from that app's directory, where a cwd-relative glob
  matches nothing and a gate passes vacuously. The scan tests themselves are
  left out because they spell the very calls they search for.
  """

  @max_depth 32

  @scan_tests [
    "apps/fermix_core/test/fermix_core/test_safety_test.exs",
    "apps/fermix_core/test/fermix_core/test_load_safety_test.exs"
  ]

  @doc "The umbrella root; this file compiles from `<root>/test/support`."
  @spec umbrella_root() :: String.t()
  def umbrella_root, do: Path.expand("../..", __DIR__)

  @doc "Absolute paths of every umbrella test file except the scan tests, sorted."
  @spec test_files() :: [String.t()]
  def test_files do
    root = umbrella_root()
    scan_tests = Enum.map(@scan_tests, &Path.join(root, &1))

    root
    |> Path.join("apps/*/test")
    |> Path.wildcard()
    |> Enum.flat_map(&files_under(&1, ["_test.exs"]))
    |> Enum.reject(&(&1 in scan_tests))
  end

  @doc """
  Every regular file under `dir`, at any depth, whose name ends with one of
  `suffixes`, sorted; names that start with a dot are left out, as
  `Path.wildcard/1` leaves them. A test that reads a whole tree lists it here.

  `Path.wildcard/1` asks the VM's file server about every entry it meets, and
  every such call queues on that one process behind the whole suite's file
  calls: with the server kept busy, listing the apps' test files that way took
  89 s here, past the 60 s test timeout. This asks the server once for each
  directory and reads what an entry is without it, and took 5 s. A link is
  never followed, and a tree nested deeper than #{@max_depth} folders raises.
  """
  @spec files_under(String.t(), [String.t(), ...]) :: [String.t()]
  def files_under(dir, [_ | _] = suffixes) when is_binary(dir),
    do: dir |> walk(suffixes, 0) |> Enum.sort()

  defp walk(dir, _suffixes, depth) when depth > @max_depth,
    do: raise("#{dir} is nested deeper than #{@max_depth} folders")

  defp walk(dir, suffixes, depth) do
    case :file.list_dir(dir) do
      {:ok, names} ->
        names
        |> Enum.map(&List.to_string/1)
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.flat_map(&entry(Path.join(dir, &1), suffixes, depth))

      {:error, reason} ->
        raise File.Error, reason: reason, action: "list directory", path: dir
    end
  end

  defp entry(path, suffixes, depth) do
    case kind(path) do
      :directory -> walk(path, suffixes, depth + 1)
      :regular -> if String.ends_with?(path, suffixes), do: [path], else: []
      _link_or_other -> []
    end
  end

  # `raw` reads the entry without the file server, and a link is not followed.
  defp kind(path) do
    case :file.read_link_info(path, [:raw]) do
      {:ok, info} -> File.Stat.from_record(info).type
      {:error, reason} -> raise File.Error, reason: reason, action: "read file stats", path: path
    end
  end

  @doc """
  A source file's text, read without the VM's file server. Every `File.read/1`
  in the VM queues on that one process, and a scan of every test file through
  it outlasted the 60 s test timeout on the loaded Intel runner; with the
  server busy it took 2.5 s here against 55 ms raw. A test that reads a whole
  tree reads each file through this, once.
  """
  @spec read!(String.t()) :: String.t()
  def read!(path) when is_binary(path) do
    case :file.read_file(path, [:raw]) do
      {:ok, source} -> source
      {:error, reason} -> raise File.Error, reason: reason, action: "read file", path: path
    end
  end

  @doc "A path relative to the umbrella root, as reports print it."
  @spec relative_path(String.t()) :: String.t()
  def relative_path(path) when is_binary(path), do: Path.relative_to(path, umbrella_root())

  @doc """
  Parses a test file's source. `unescape: false` keeps a quoted call name as its
  source spells it, so an AST check matches only what a text prefilter kept.
  """
  @spec parse!(String.t(), String.t()) :: Macro.t()
  def parse!(path, source) when is_binary(path) and is_binary(source) do
    Code.string_to_quoted!(source, file: path, unescape: false)
  end

  @doc "Every `defmodule` in `ast`, nested ones included, as `{name, body}`."
  @spec modules(Macro.t()) :: [{String.t(), Macro.t()}]
  def modules(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [name, [{{:__block__, _, [:do]}, body}]]} = node, acc ->
          {node, [{module_name(name), body} | acc]}

        {:defmodule, _meta, [name, [do: body]]} = node, acc ->
          {node, [{module_name(name), body} | acc]}

        node, acc ->
          {node, acc}
      end)

    found
  end

  @doc """
  Whether a module body runs concurrently. `use ExUnit.Case` defaults to
  async: false, so only an explicit `async: true` makes a module concurrent, and
  the case template may be a wrapper such as ConnCase, so this keys on the
  option rather than on the module being used.
  """
  @spec async_module?(Macro.t()) :: boolean()
  def async_module?(body) do
    {_ast, async?} =
      Macro.prewalk(body, false, fn
        {:use, _meta, [_case, opts]} = node, acc when is_list(opts) ->
          {node, acc or Keyword.get(opts, :async) == true}

        node, acc ->
          {node, acc}
      end)

    async?
  end

  defp module_name({:__aliases__, _meta, parts}) when is_list(parts) do
    Enum.map_join(parts, ".", &to_string/1)
  end

  defp module_name(other), do: Macro.to_string(other)
end
