defmodule FermixTestSupport.TestSourceScan do
  @moduledoc """
  Reads the umbrella's own test files for the tests that hold test-writing rules
  as gates (`test_safety_test.exs`, `test_load_safety_test.exs`).

  The corpus is every `apps/*/test/**/*_test.exs`, found from this file's own
  directory rather than the cwd: `mix test` is a recursive umbrella task and
  runs a child app's tests from that app's directory, where a cwd-relative glob
  matches nothing and a gate passes vacuously. The scan tests themselves are
  left out because they spell the very calls they search for.
  """

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
    |> Path.join("apps/*/test/**/*_test.exs")
    |> Path.wildcard()
    |> Enum.reject(&(&1 in scan_tests))
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
