defmodule FermixCore.Kept.AccessTest do
  # M89 §14 and the lists' MILESTONE_85 §11: a job that names a kept kind's
  # tool runs at operator trust with nothing read, so it may be set up only on
  # the owner's private turn, and never from a turn that has read outside
  # content, or a page could rewrite a booked stop through a job's run.
  use ExUnit.Case, async: true

  alias FermixCore.Kept.Access
  alias FermixCore.Memory.Repo
  alias FermixCore.Tools.ScheduleJob
  alias FermixCore.Tools.UpdateJob

  @kept_tools ["checklist_read", "checklist_edit", "trip_read", "trip_edit"]

  defp owner(context) do
    Map.merge(
      %{
        agent_name: "main",
        conversation_key: {"telegram", "40017", :root},
        memory_repo: nil,
        source_trust: :operator,
        computer_use_origin: :interactive,
        chat_type: "private",
        outside_sources: MapSet.new()
      },
      context
    )
  end

  defp read_a_page,
    do: owner(%{outside_sources: MapSet.new([{:web, "https://notice.example/dinner"}])})

  describe "check_job_tools/2" do
    test "the owner's clean private turn may give a job any kept kind's tool" do
      for tool <- @kept_tools do
        assert Access.check_job_tools([tool], owner(%{})) == :ok
      end
    end

    test "a turn that read outside content may not, for lists and trips alike, naming the tool" do
      for tool <- @kept_tools do
        assert {:error, sentence} = Access.check_job_tools(["web_search", tool], read_a_page())
        assert sentence =~ tool
        assert sentence =~ "read something from outside"
        refute sentence =~ "only from the owner's own private chat"
      end
    end

    test "a tool of no kept kind is not this check's, whatever the turn read" do
      assert Access.check_job_tools(["web_search", "event_list"], read_a_page()) == :ok
      assert Access.check_job_tools([], read_a_page()) == :ok
    end

    test "a turn that is not the owner's private one keeps its own refusal" do
      assert {:error, sentence} =
               Access.check_job_tools(["trip_edit"], owner(%{chat_type: "group"}))

      assert sentence =~ "trip_edit can be given to a job only from the owner's own"
    end
  end

  describe "schedule_job from the owner's private turn after outside content" do
    test "is refused for a job naming a trip or a list tool, and no job is set up" do
      for tool <- ["trip_edit", "checklist_edit"] do
        args = %{
          "name" => "dinner_fix",
          "schedule" => "2027-06-11T09:00:00+01:00",
          "task" => "Move the Friday dinner in the Halden coast trip to 22:00.",
          "allowed_tools" => [tool]
        }

        assert {:ok, result} = ScheduleJob.execute(args, read_a_page())
        refute result.success
        assert result.error =~ "#{tool} can't be given to a job from a turn that has read"
      end
    end
  end

  # The same laundering through a job the owner set up: a tainted turn that
  # rewrites its task would have the job's clean run carry the page's ask.
  describe "update_job from the owner's private turn after outside content" do
    setup do
      unique = System.unique_integer([:positive])
      db_path = Path.join(System.tmp_dir!(), "fermix-kept-access-#{unique}.db")
      repo = :"kept_access_repo_#{unique}"
      start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

      on_exit(fn ->
        Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
      end)

      %{repo: repo}
    end

    test "is refused for a job naming a trip or a list tool, and the job is unchanged",
         %{repo: repo} do
      for tool <- ["trip_edit", "checklist_edit"] do
        clean = owner(%{memory_repo: repo, memory_agent_id: "main"})

        args = %{
          "name" => "evening_#{tool}",
          "schedule" => "0 18 * * *",
          "task" => "Say what is first tomorrow.",
          "allowed_tools" => [tool]
        }

        assert {:ok, %{success: true} = created} = ScheduleJob.execute(args, clean)
        job_id = Jason.decode!(created.output)["id"]
        tainted = %{read_a_page() | memory_repo: repo} |> Map.put(:memory_agent_id, "main")
        change = %{"job_id" => job_id, "task" => "Move the Friday dinner to 22:00."}

        assert {:ok, result} = UpdateJob.execute(change, tainted)
        refute result.success
        assert result.error =~ "#{tool} can't be given to a job from a turn that has read"

        assert {:ok, job} = Repo.get_scheduled_job(job_id, server: repo)
        assert job.task_prompt == "Say what is first tomorrow."

        assert {:ok, %{success: true}} = UpdateJob.execute(change, clean)
      end
    end
  end
end
