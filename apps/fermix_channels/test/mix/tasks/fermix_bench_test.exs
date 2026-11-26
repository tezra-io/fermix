defmodule Mix.Tasks.FermixBenchTest do
  @moduledoc """
  `mix fermix.bench` run as a developer runs it: a fresh OS process from the
  umbrella root.

  The suite's VM booted the engine, so it holds the boot facts and the
  processes a turn calls by name before any test starts; the task reads the
  configuration and starts no application, so it holds none of them unless the
  benchmark makes them. A test inside the suite inspects the first world and
  passed while every run of the CLI exited before its first sample (M107). Only
  a subprocess reproduces the second.

  Each run warms up and makes two passes in one VM, as `--runs` does, so a
  sample identity that repeats across the warmup, the samples or the passes
  fails here. The first test is the invocation people run, with no
  `--scenarios`, which is every shared scenario; the second covers the channel
  families that set leaves out: end to end, a media send and webhook ingress.

  Tagged `:subprocess` (`mix test --exclude subprocess` skips it).
  """

  use ExUnit.Case, async: false

  alias FermixChannels.Bench.AdapterRunner
  alias FermixChannels.Bench.Runner
  alias FermixCore.Agents.IterationLimits
  alias FermixTestSupport.SafeRm

  @moduletag :subprocess
  # A child `mix` boots inside each test. With every core busy that boot alone
  # takes about a minute, so the default 60 s would fail a run that is only
  # slow; this is the bound on a child that hangs.
  @moduletag timeout: 300_000

  @samples 2
  @warmup 1
  @runs 2
  @counts [
    "--samples",
    "#{@samples}",
    "--warmup",
    "#{@warmup}",
    "--runs",
    "#{@runs}"
  ]
  @channel_scenarios ["telegram_e2e_text", "telegram_send_media", "webhook_ingress_idempotency"]
  @alarm_lines ~r/\[(emergency|alert|critical|error|warning)\]|^\s*warning:|^\*\* \(/

  setup do
    root = SafeRm.make_tmp_dir!("fermix-bench-cli")
    on_exit(fn -> SafeRm.rm_rf!(root) end)
    home = Path.join(root, "home")
    File.mkdir!(home)
    %{home: home, output: Path.join(root, "current.json")}
  end

  test "the default run processes every sample of every shared scenario",
       %{home: home, output: output} do
    {out, report} = bench!(home, output, @counts)

    shared = Runner.list_scenarios() -- AdapterRunner.list_scenarios()
    assert report["scenarios"] |> Map.keys() |> Enum.sort() == Enum.sort(shared)
    assert report["config"]["runs"] == @runs

    for {name, scenario} <- report["scenarios"] do
      assert {name, scenario["messages_dispatched"], scenario["messages_processed"]} ==
               {name, @samples, @samples}
    end

    # The max-iteration scenario's turns run into the iteration cap by design,
    # each logging the loop's error once; nothing else may log one.
    cap_error =
      ~s|Agent loop failed: "Maximum iterations (#{IterationLimits.interactive()}) reached"|

    assert Enum.reject(alarm_lines(out), &String.contains?(&1, cap_error)) == [], out
    assert length(alarm_lines(out)) == (@warmup + @samples) * @runs, out

    assert before?(out, "  dispatcher_normalize:", "  ingress_authorize:")
    assert before?(out, "  ingress_authorize:", "  agent_mailbox:")
    assert File.ls!(home) == [], "the run wrote into the caller's FERMIX_HOME"
  end

  test "channel scenarios process every sample across the warmup and both passes",
       %{home: home, output: output} do
    {out, report} =
      bench!(home, output, ["--scenarios", Enum.join(@channel_scenarios, ",") | @counts])

    assert report["scenarios"] |> Map.keys() |> Enum.sort() == Enum.sort(@channel_scenarios)

    for {name, scenario} <- report["scenarios"] do
      assert {name, scenario["messages_dispatched"], scenario["messages_processed"]} ==
               {name, @samples, @samples}
    end

    assert alarm_lines(out) == [], out
    assert File.ls!(home) == [], "the run wrote into the caller's FERMIX_HOME"
  end

  defp bench!(home, output, args) do
    {out, status} =
      System.cmd("mix", ["fermix.bench", "--output", output | args],
        cd: umbrella_root(),
        env: [{"MIX_ENV", "test"}, {"FERMIX_HOME", home}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    {out, output |> File.read!() |> Jason.decode!()}
  end

  defp alarm_lines(out) do
    out |> String.split("\n") |> Enum.filter(&Regex.match?(@alarm_lines, &1))
  end

  defp before?(text, left, right) do
    lines = String.split(text, "\n")
    index = &Enum.find_index(lines, fn line -> String.starts_with?(line, &1) end)
    is_integer(index.(left)) and is_integer(index.(right)) and index.(left) < index.(right)
  end

  # `mix test` runs with cwd set to the app directory; a developer runs the
  # benchmark from the umbrella root.
  defp umbrella_root do
    Mix.Project.build_path() |> Path.dirname() |> Path.dirname()
  end
end
