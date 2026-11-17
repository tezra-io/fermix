defmodule FermixCore.ComputerHistory.ReportTest do
  # M97 §8.5, M102 N15 (D8): a computer's report of its recorder. Version 2
  # adds `apps`, how many apps are chosen there (never which), so the home
  # can say a recorder with none records nothing. A computer can be older
  # than its server, so the home keeps exactly a version 1 report or exactly
  # a version 2 one; a server older than the report refuses it until it
  # updates, and shows the last one it kept, with its age.
  use ExUnit.Case, async: true

  alias FermixCore.ComputerHistory.Report

  @v1 %{
    "v" => 1,
    "recorder" => "running",
    "events" => 4,
    "unsent" => 1,
    "oldest_unsent_ts" => 1_900_000_000_000,
    "expired_unsent" => 0,
    "title_only" => 0,
    "private_unknown" => 0,
    "ax_refused" => 0
  }
  @v2 Map.merge(@v1, %{"v" => 2, "apps" => 0})

  test "exactly a version 1 report and exactly a version 2 one are kept" do
    assert Report.validate(@v1) == :ok
    assert Report.validate(@v2) == :ok
    assert Report.validate(%{@v2 | "apps" => 12}) == :ok
  end

  test "a report whose fields are not its version's own is refused" do
    assert Report.validate(Map.delete(@v2, "apps")) ==
             {:error, "A report carries exactly its fields."}

    assert Report.validate(Map.put(@v1, "apps", 3)) ==
             {:error, "A report carries exactly its fields."}

    assert Report.validate(%{@v2 | "v" => 3}) == {:error, "A report of another format version."}
  end

  test "its apps are a count" do
    for apps <- [-1, 1.5, "3", ["com.apple.Safari"]],
        do:
          assert(
            Report.validate(%{@v2 | "apps" => apps}) == {:error, "A report's counts are counts."}
          )
  end
end
