defmodule FermixCore.ComputerHistory.RetentionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.ComputerHistory.Retention
  alias FermixTestSupport.StalledRepo

  # A Repo stuck behind a long operation must cost a sweep, not a restart: the
  # next tick sweeps again, and every sweep is idempotent.
  test "a tick whose Repo does not answer is skipped and retention keeps running" do
    stalled = start_supervised!(StalledRepo)
    name = :"retention_stalled_#{System.unique_integer([:positive])}"

    {pid, log} =
      with_log(fn ->
        start_supervised!(
          {Retention, name: name, repo: stalled, timer_enabled: false, repo_timeout_ms: 50}
        )

        pid = Process.whereis(name)
        send(pid, :tick)
        _state = :sys.get_state(pid)
        pid
      end)

    assert Process.whereis(name) == pid

    for site <- ["retention sweep", "byte-ceiling sweep", "access-audit cap"] do
      assert log =~ "computer_history #{site} failed: :repo_timeout"
    end
  end
end
