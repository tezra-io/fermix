defmodule FermixCore.TestLoadSafetyTest do
  @moduledoc """
  Ratchets on the test-writing rules of the "Tests under load" pitfall in
  AGENTS.md, read off every umbrella test file.

  A test that passes alone can still fail when the suite saturates the machine:
  it slept instead of waiting, gave an arrival a short bound, or saw a global it
  did not pin. Prose did not stop those; these scans do. Each rule keeps a
  budget of today's offenders per file in `test/test_load_safety_budget.exs`, so a
  file may not gain an offender, and a file that loses one must lower its count:
  the budget only shrinks. A file absent from the budget has a budget of zero.

  The work happens once, in `setup_all`: each file is read once, its text rules
  run, and it is parsed once, in parallel with the others, only when its text
  spells something an AST rule looks for. A whole-umbrella scan here once timed
  out on the slowest CI leg.
  """
  use ExUnit.Case, async: true

  alias FermixTestSupport.TestSourceScan

  # Beside test/support at the umbrella root, not under an app's test/: Mix
  # warns about any .exs in a test directory that is not a test or a helper.
  @budget_file Path.join(TestSourceScan.umbrella_root(), "test/test_load_safety_budget.exs")

  # Every test_helper sets `assert_receive_timeout: 2_000`.
  @suite_receive_timeout 2_000
  @sleep_calls ["Process.sleep(", ":timer.sleep("]
  @sleep_lookahead 3
  @wait_words ["await", "wait", "eventually", "until", "poll", "settle"]
  @stderr_devices [:stderr, :standard_error]
  @per_file_timeout 30_000

  @fixes %{
    sleep_then_assert:
      "wait for the effect you assert (assert_receive, a :DOWN, a bounded eventually), " <>
        "never for time; a sleep that is not a wait says why on its line: `# sleep: <reason>`",
    short_assert_receive:
      "drop the timeout for the 2 s suite default, or name a bound of 10 s or more " <>
        "for file, SQLite or process work",
    short_wait_helper_default:
      "default the helper's time bound to the 2 s suite default or more " <>
        "(10 s or more for file, SQLite or process work)",
    unpinned_telemetry_attach:
      "attach through FermixTestSupport.TelemetryCapture with an :emitter or metadata pin",
    async_stderr_capture:
      "capture stderr only in an async: false module; another async test's output lands in it",
    empty_monitors_assert:
      "filter the monitors list to the {:process, pid} entries the test owns before asserting"
  }

  @rules Map.keys(@fixes)

  setup_all do
    files = TestSourceScan.test_files()
    refute files == [], "test-file glob matched nothing — every rule would pass vacuously"

    offenders =
      files
      |> Task.async_stream(&file_offenders/1, ordered: true, timeout: @per_file_timeout)
      |> Enum.flat_map(fn {:ok, found} -> found end)
      |> Enum.group_by(fn {rule, _at} -> rule end, fn {_rule, at} -> at end)

    {budget, _binding} = Code.eval_file(@budget_file)
    %{offenders: offenders, budget: budget}
  end

  test "the budget lists every rule, sorted, with positive counts", %{budget: budget} do
    assert budget |> Map.keys() |> Enum.sort() == Enum.sort(@rules)

    for {rule, counts} <- budget, {path, count} <- counts do
      assert is_binary(path) and is_integer(count) and count > 0,
             "#{rule}: #{inspect(path)} => #{inspect(count)} is not a path with a positive count"
    end

    written = budget_as_written()

    assert written ==
             written |> Enum.map(fn {rule, paths} -> {rule, Enum.sort(paths)} end) |> Enum.sort(),
           "keep #{Path.basename(@budget_file)} sorted by rule, then by path, so diffs stay clean"
  end

  # Rule 1: wait for an event, never for time.
  test "sleep_then_assert: no sleep stands in for waiting on what the test asserts", ctx do
    assert_within_budget(:sleep_then_assert, ctx)
  end

  # Rule 3: arrival waits are generous and named.
  test "short_assert_receive: no assert_receive bound below the suite default", ctx do
    assert_within_budget(:short_assert_receive, ctx)
  end

  test "short_wait_helper_default: no wait helper defaults below the suite default", ctx do
    assert_within_budget(:short_wait_helper_default, ctx)
  end

  # Rule 4: pin identity on every global in async tests.
  test "unpinned_telemetry_attach: async modules attach telemetry only pinned", ctx do
    assert_within_budget(:unpinned_telemetry_attach, ctx)
  end

  test "async_stderr_capture: async modules do not capture the global stderr", ctx do
    assert_within_budget(:async_stderr_capture, ctx)
  end

  # Rule 5: own exits from the start.
  test "empty_monitors_assert: no assertion that a whole monitors list is empty", ctx do
    assert_within_budget(:empty_monitors_assert, ctx)
  end

  # -- the ratchet ------------------------------------------------------------

  defp assert_within_budget(rule, %{offenders: offenders, budget: budget}) do
    found = Map.get(offenders, rule, [])
    allowed = Map.fetch!(budget, rule)
    counts = Enum.frequencies_by(found, fn {path, _line} -> path end)

    case over_budget(rule, found, counts, allowed) ++ under_budget(rule, counts, allowed) do
      [] -> :ok
      report -> flunk(Enum.join(report, "\n"))
    end
  end

  defp over_budget(rule, found, counts, allowed) do
    over = for {path, count} <- counts, count > Map.get(allowed, path, 0), do: path

    case Enum.filter(found, fn {path, _line} -> path in over end) do
      [] ->
        []

      lines ->
        ["#{rule} gained an offender (AGENTS.md, Known Pitfalls, \"Tests under load\")."] ++
          Enum.map(lines, fn {path, line} -> "  #{path}:#{line} — #{@fixes[rule]}" end) ++
          Enum.map(over, &"  (#{&1}: #{counts[&1]} found, budget #{Map.get(allowed, &1, 0)})")
    end
  end

  defp under_budget(rule, counts, allowed) do
    for {path, budget} <- Enum.sort(allowed), Map.get(counts, path, 0) < budget do
      "lower #{rule} for #{path} to #{Map.get(counts, path, 0)} in #{Path.basename(@budget_file)}"
    end
  end

  # The budget's rules and paths in the order the file spells them.
  defp budget_as_written do
    {:%{}, _meta, rules} = @budget_file |> File.read!() |> Code.string_to_quoted!()

    for {rule, {:%{}, _rule_meta, counts}} <- rules do
      {rule, Enum.map(counts, fn {path, _count} -> path end)}
    end
  end

  # -- one file ---------------------------------------------------------------

  defp file_offenders(file) do
    path = TestSourceScan.relative_path(file)
    source = File.read!(file)

    (text_findings(source) ++ ast_findings(file, source))
    |> Enum.uniq()
    |> Enum.map(fn {rule, line} -> {rule, {path, line}} end)
  end

  defp text_findings(source) do
    tag(:sleep_then_assert, sleeps_before_asserts(source)) ++
      tag(:empty_monitors_assert, empty_monitor_asserts(source))
  end

  defp ast_findings(file, source) do
    case Enum.filter(@rules, &spelled?(&1, source)) do
      [] ->
        []

      rules ->
        ast = TestSourceScan.parse!(file, source)
        Enum.flat_map(rules, &tag(&1, ast_rule(&1, ast)))
    end
  end

  defp tag(rule, lines), do: Enum.map(lines, &{rule, &1})

  # A text prefilter per AST rule: a file is parsed only when its text could
  # hold what the AST check matches.
  defp spelled?(:short_assert_receive, source), do: String.contains?(source, "assert_receive")

  defp spelled?(:short_wait_helper_default, source) do
    String.contains?(source, "\\\\") and String.contains?(source, @wait_words)
  end

  defp spelled?(:unpinned_telemetry_attach, source) do
    String.contains?(source, ":telemetry.attach") and String.contains?(source, "async: true")
  end

  defp spelled?(:async_stderr_capture, source) do
    String.contains?(source, "capture_io") and String.contains?(source, "async: true")
  end

  defp spelled?(_text_rule, _source), do: false

  defp ast_rule(:short_assert_receive, ast), do: lines_where(ast, &short_assert_receive?/1)
  defp ast_rule(:short_wait_helper_default, ast), do: lines_where(ast, &short_wait_default?/1)
  defp ast_rule(:unpinned_telemetry_attach, ast), do: in_async_modules(ast, &telemetry_attach?/1)
  defp ast_rule(:async_stderr_capture, ast), do: in_async_modules(ast, &stderr_capture?/1)

  # -- text rules -------------------------------------------------------------

  defp sleeps_before_asserts(source) do
    if String.contains?(source, @sleep_calls), do: sleep_offenders(code_lines(source)), else: []
  end

  # A sleep whose first assertion within the next few statements of its own
  # block is a positive one waits on time for the thing asserted. The block ends
  # where indentation drops below the sleep's. A refute first is a wait for
  # absence, and an assert_receive first already waits.
  defp sleep_offenders(lines) do
    lines
    |> Enum.with_index()
    |> Enum.filter(fn {{text, _line}, index} ->
      waiting_sleep?(text) and
        assert_follows?(text, Enum.slice(lines, index + 1, @sleep_lookahead))
    end)
    |> Enum.map(fn {{_text, line}, _index} -> line end)
  end

  # A sleep inside a one-line `fn` runs wherever that function is called (a
  # stand-in process, a slow fake), not in the test's own flow.
  defp waiting_sleep?(text) do
    case String.split(text, @sleep_calls, parts: 2) do
      [before, _after] ->
        not Regex.match?(~r/\bfn\b/, before) and not String.contains?(text, "# sleep:")

      [_no_sleep] ->
        false
    end
  end

  defp assert_follows?(sleep_text, following) do
    first_assertion =
      following
      |> Enum.take_while(fn {text, _line} -> indent(text) >= indent(sleep_text) end)
      |> Enum.find(fn {text, _line} -> Regex.match?(~r/^\s*(assert|refute)/, text) end)

    case first_assertion do
      {text, _line} -> Regex.match?(~r/^\s*assert(_in_delta)?[\s(]/, text)
      nil -> false
    end
  end

  defp empty_monitor_asserts(source) do
    if String.contains?(source, "{:monitors, []}") do
      for {text, line} <- code_lines(source), String.contains?(text, "{:monitors, []}"), do: line
    else
      []
    end
  end

  defp code_lines(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {text, _line} -> blank_or_comment?(text) end)
  end

  defp blank_or_comment?(text) do
    trimmed = String.trim(text)
    trimmed == "" or String.starts_with?(trimmed, "#")
  end

  defp indent(text), do: byte_size(text) - byte_size(String.trim_leading(text))

  # -- AST rules --------------------------------------------------------------

  defp short_assert_receive?({:assert_receive, _meta, [_pattern, timeout | _]}),
    do: short_literal?(timeout)

  defp short_assert_receive?(_node), do: false

  defp short_wait_default?({kind, _meta, [head | _]}) when kind in [:def, :defp],
    do: short_wait_head?(head)

  defp short_wait_default?(_node), do: false

  defp short_wait_head?({:when, _meta, [call | _guards]}), do: short_wait_head?(call)

  defp short_wait_head?({name, _meta, args}) when is_atom(name) and is_list(args) do
    String.contains?(Atom.to_string(name), @wait_words) and Enum.any?(args, &short_default?/1)
  end

  defp short_wait_head?(_head), do: false

  defp short_default?({:\\, _meta, [{param, _param_meta, _ctx}, default]}) when is_atom(param),
    do: time_param?(param) and short_literal?(default)

  defp short_default?(_arg), do: false

  # Only a parameter named for time is a time bound. An attempt count bounds
  # time only through its poll interval, which the head does not show.
  defp time_param?(param),
    do: Regex.match?(~r/timeout|deadline|within|bound|(^|_)ms$/, Atom.to_string(param))

  defp short_literal?(value), do: is_integer(value) and value < @suite_receive_timeout

  defp telemetry_attach?({{:., _meta, [:telemetry, fun]}, _call_meta, _args}),
    do: fun in [:attach, :attach_many]

  defp telemetry_attach?(_node), do: false

  defp stderr_capture?({:capture_io, _meta, [device | _]}), do: device in @stderr_devices

  defp stderr_capture?(
         {{:., _meta, [{:__aliases__, _alias_meta, [:ExUnit, :CaptureIO]}, :capture_io]},
          _call_meta, [device | _]}
       ),
       do: device in @stderr_devices

  defp stderr_capture?(_node), do: false

  defp in_async_modules(ast, match?) do
    ast
    |> TestSourceScan.modules()
    |> Enum.filter(fn {_name, body} -> TestSourceScan.async_module?(body) end)
    |> Enum.flat_map(fn {_name, body} -> lines_where(body, match?) end)
    |> Enum.uniq()
  end

  defp lines_where(ast, match?) do
    {_ast, lines} =
      Macro.prewalk(ast, [], fn node, acc ->
        if match?.(node), do: {node, [node_line(node) | acc]}, else: {node, acc}
      end)

    Enum.reverse(lines)
  end

  defp node_line({_form, meta, _args}), do: Keyword.fetch!(meta, :line)
end
