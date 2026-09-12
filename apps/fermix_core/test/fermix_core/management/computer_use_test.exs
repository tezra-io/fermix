defmodule FermixCore.Management.ComputerUseTest do
  @moduledoc """
  The `computer_use.grant.start` refusal sentences (M34 native setup §7.3).

  The grant is injected, so nothing here spawns the sidecar or raises a macOS
  dialog: what is under test is the sentence a person reads when the grant is
  refused, and the daemon log line that keeps the diagnosis.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Management.ComputerUse
  alias FermixCore.Management.Jobs

  setup context do
    tasks = :"computer_use_tasks_#{:erlang.phash2(context.test)}"
    start_supervised!({Task.Supervisor, name: tasks}, id: tasks)

    server =
      start_supervised!(
        {Jobs, name: :"computer_use_jobs_#{:erlang.phash2(context.test)}", task_supervisor: tasks}
      )

    %{jobs: [server: server]}
  end

  describe "computer_use.grant.start" do
    # A helper the engine cannot speak to is not a broken prompt: the two halves
    # ship together, so the person is told they are from different releases and
    # that an update is the cure. The two versions stay in the daemon log, where
    # they are a diagnosis rather than copy.
    test "a helper from another release is named, with an update as the cure", %{jobs: jobs} do
      grant = fn -> {:error, {:protocol_mismatch, %{library: 6, sidecar: 5}}} end

      log =
        capture_log(fn ->
          assert {:ok, view} = ComputerUse.grant_start(jobs: jobs, grant: grant)
          done = await(view, jobs)

          assert done["status"] == "failed"
          assert done["failure"]["code"] == "unavailable"

          assert done["failure"]["sentence"] ==
                   "Fermix Computer Use on this Mac is from a different Fermix release. " <>
                     "Update Fermix to raise the prompts."
        end)

      assert log =~ "protocol_mismatch"
      assert log =~ "library: 6"
      assert log =~ "sidecar: 5"
    end

    # The residue is still the residue: a reason with no sentence of its own
    # carries the sidecar's words and the path it was spawned from, so the
    # published sentence stays fixed and the term goes to the log.
    test "an unnamed refusal keeps the fixed sentence and logs the term", %{jobs: jobs} do
      grant = fn -> {:error, {:driver_failed, "/Users/example/.fermix/computer_use/compux"}} end

      log =
        capture_log(fn ->
          assert {:ok, view} = ComputerUse.grant_start(jobs: jobs, grant: grant)

          assert await(view, jobs)["failure"]["sentence"] ==
                   "The permission prompts could not be raised. See the daemon log."
        end)

      assert log =~ "driver_failed"
      assert log =~ "/Users/example/.fermix/computer_use/compux"
    end
  end

  defp await(view, jobs), do: await(view["job_id"], jobs, 50)

  defp await(job_id, jobs, 0) do
    {:ok, view} = Jobs.get(job_id, jobs)
    flunk("job #{job_id} never finished: #{inspect(view)}")
  end

  defp await(job_id, jobs, attempts) do
    {:ok, view} = Jobs.get(job_id, jobs)

    if view["status"] == "running" do
      Process.sleep(10)
      await(job_id, jobs, attempts - 1)
    else
      view
    end
  end
end
