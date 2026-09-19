defmodule FermixCore.TestSafetyTest do
  @moduledoc """
  Umbrella-wide test-hygiene invariants, read off every `apps/*/test` file.

  Each one exists because the repo learned it the hard way and because prose in
  CLAUDE.md is not a gate: a rule nothing checks is a rule the next test breaks.
  Both scan the whole umbrella, not this app — `mix test` runs every child in
  one VM, so the hazards are umbrella-wide.
  """
  use ExUnit.Case, async: true

  test "tests do not call destructive file cleanup APIs directly" do
    files = test_files()

    # The glob is anchored on __DIR__, not on the cwd: `mix test` is a recursive
    # umbrella task and runs this from apps/fermix_core, where a cwd-relative
    # "apps/*/..." matches nothing. This gate spent its life scanning zero files
    # and passing vacuously; assert the corpus before asserting about it.
    refute files == [], "test-file glob matched nothing — the gate would pass vacuously"

    offenders = Enum.flat_map(files, &direct_cleanup_calls/1)

    assert offenders == []
  end

  defp test_files do
    "../../../../apps/*/test/**/*_test.exs"
    |> Path.expand(__DIR__)
    |> Path.wildcard()
    |> Enum.reject(&String.ends_with?(&1, "test_safety_test.exs"))
  end

  defp direct_cleanup_calls(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _line_no} -> direct_cleanup_call?(line) end)
    |> Enum.map(fn {_line, line_no} -> "#{path}:#{line_no}" end)
  end

  defp direct_cleanup_call?(line) do
    String.contains?(line, cleanup_prefixes())
  end

  # Application env is one VM-global map. An `async: true` module that writes it
  # races every concurrently running test that reads the same key, and the
  # damage outlives the test whenever the restore is partial — which is how a
  # leaked `:routing` value surfaced as a LiveView crash in another app, and how
  # a leaked plugin secret failed a test about Discord. `async: false` does not
  # make a write safe forever, but it removes the overlap, which is the half
  # that cannot be found by reading the failing test.
  #
  # Deliberately not covered: `System.put_env`. The one async module that calls
  # it names a variable no production code reads (the test points config at that
  # name), so a blanket rule would only buy an allowlist. Add that half here if
  # an async module ever writes a variable lib/ reads, FERMIX_HOME above all.
  test "async test modules do not write global application configuration" do
    files = test_files()

    refute files == [], "test-file glob matched nothing — the gate would pass vacuously"

    offenders = Enum.flat_map(files, &async_app_env_writers/1)

    assert offenders == [],
           """
           These test modules write Application env while running concurrently,
           so any other async test reading the same key sees a value its own
           setup never chose:

           #{Enum.map_join(offenders, "\n", &"  - #{&1}")}

           Either make the module async: false and restore the previous value
           exactly (delete only if the key was absent), or inject the setting
           through the seam under test instead of writing global config.
           """
  end

  defp async_app_env_writers(file) do
    file
    |> File.read!()
    |> Code.string_to_quoted!(file: file)
    |> modules()
    |> Enum.filter(fn {_name, body} -> async_module?(body) and writes_app_env?(body) end)
    |> Enum.map(fn {name, _body} -> "#{Path.relative_to(file, umbrella_root())} (#{name})" end)
  end

  defp modules(ast) do
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

  defp module_name({:__aliases__, _meta, parts}) when is_list(parts) do
    Enum.map_join(parts, ".", &to_string/1)
  end

  defp module_name(other), do: Macro.to_string(other)

  # `use ExUnit.Case` defaults to async: false, so only an explicit `async: true`
  # makes a module concurrent — and the case template may be a wrapper such as
  # ConnCase, so key on the option rather than on the module being used.
  defp async_module?(body) do
    {_ast, async?} =
      Macro.prewalk(body, false, fn
        {:use, _meta, [_case, opts]} = node, acc when is_list(opts) ->
          {node, acc or Keyword.get(opts, :async) == true}

        node, acc ->
          {node, acc}
      end)

    async?
  end

  defp writes_app_env?(body) do
    {_ast, found} =
      Macro.prewalk(body, false, fn
        {{:., _meta, [{:__aliases__, _alias_meta, [:Application]}, fun]}, _call_meta, _args} =
            node,
        _acc
        when fun in [:put_env, :delete_env] ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp umbrella_root, do: Path.expand("../../../..", __DIR__)

  defp cleanup_prefixes do
    file = "File."

    [
      file <> "rm(",
      file <> "rm!(",
      file <> "rm_rf(",
      file <> "rm_rf!(",
      "&" <> file <> "rm/1",
      "&" <> file <> "rm!/1",
      "&" <> file <> "rm_rf/1",
      "&" <> file <> "rm_rf!/1"
    ]
  end
end
