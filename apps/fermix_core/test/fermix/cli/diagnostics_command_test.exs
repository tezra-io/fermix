defmodule Fermix.CLI.DiagnosticsCommandTest do
  @moduledoc """
  `fermix diagnostics export` (M38 §4.6).

  The collector is injected, so the verb's argv handling, its envelope and its
  refusals are provable without reading a journal or a log file.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Fermix.CLI.DiagnosticsCommand

  @report %{
    "schema_version" => 1,
    "generated_at" => "2026-09-13T10:00:00Z",
    "mode" => "offline",
    "sources" => %{
      "engine" => %{"status" => "available", "observed_at" => "t", "data" => %{}},
      "doctor" => %{"status" => "unavailable", "observed_at" => "t", "reason" => "no daemon"}
    }
  }

  test "--json prints the shared envelope and nothing else on stdout" do
    stdout = capture_io(fn -> assert run(["export", "--offline", "--json"], answering()) == 0 end)

    assert Jason.decode!(String.trim(stdout)) == %{
             "schema_version" => 1,
             "ok" => true,
             "result" => @report
           }
  end

  test "human mode names every source and its status" do
    stdout = capture_io(fn -> assert run(["export", "--offline"], answering()) == 0 end)

    assert stdout =~ "engine:"
    assert stdout =~ "available"
    assert stdout =~ "doctor:"
    assert stdout =~ "unavailable (no daemon)"
  end

  # A live export is a different collector against a running daemon, and quietly
  # answering with the offline one under the same name is the retry M38 §4.6
  # forbids.
  test "without --offline the verb refuses and names the mode it has" do
    stderr = capture_io(:stderr, fn -> assert run(["export"], refusing()) == 2 end)

    assert stderr =~ "--offline"
    assert stderr =~ "Fermix application"
  end

  test "an unknown subcommand and a stray argument are usage errors" do
    stderr = capture_io(:stderr, fn -> assert run(["collect"], refusing()) == 2 end)
    assert stderr =~ "unknown subcommand: collect"

    stderr =
      capture_io(:stderr, fn -> assert run(["export", "--offline", "now"], refusing()) == 2 end)

    assert stderr =~ "unexpected argument: now"

    stderr = capture_io(:stderr, fn -> assert run([], refusing()) == 2 end)
    assert stderr =~ "fermix diagnostics export --offline"
  end

  # A bundle that could not be collected is an error: a claimed bundle missing
  # the half that explains the fault is worse than a refusal.
  describe "a collection that fails" do
    test "the deadline is a refusal with its own sentence" do
      stdout =
        capture_io(fn ->
          assert run(["export", "--offline", "--json"], failing(:deadline_exceeded)) == 1
        end)

      envelope = Jason.decode!(String.trim(stdout))

      assert envelope["ok"] == false
      assert envelope["error"]["code"] == "diagnostics_unavailable"
      assert envelope["error"]["sentence"] =~ "took too long"
    end

    test "the size ceiling says so rather than shipping a truncated bundle" do
      stdout =
        capture_io(fn ->
          assert run(["export", "--offline", "--json"], failing(:too_large)) == 1
        end)

      assert Jason.decode!(String.trim(stdout))["error"]["sentence"] =~ "size"
    end

    test "human mode prints the same sentence on stderr" do
      stderr =
        capture_io(:stderr, fn ->
          assert run(["export", "--offline"], failing(:deadline_exceeded)) == 1
        end)

      assert stderr =~ "could not collect the diagnostic bundle"
      assert stderr =~ "took too long"
    end
  end

  defp run(argv, deps), do: DiagnosticsCommand.run(argv, deps)

  defp answering, do: [builder: fn _opts -> {:ok, @report} end]
  defp failing(reason), do: [builder: fn _opts -> {:error, reason} end]

  defp refusing do
    [builder: fn _opts -> raise "the collector must not run" end]
  end
end
