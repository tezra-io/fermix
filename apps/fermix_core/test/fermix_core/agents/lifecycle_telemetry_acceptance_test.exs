defmodule FermixCore.Agents.LifecycleTelemetryAcceptanceTest do
  use ExUnit.Case, async: false

  alias FermixCore.Agents.LifecycleTelemetry
  alias FermixCore.Agents.PersistencePolicy
  alias FermixCore.Trace
  alias FermixCore.Trace.TelemetryHandler

  @moduletag :acceptance

  setup do
    suffix = System.unique_integer([:positive])
    trace_dir = Path.join(System.tmp_dir!(), "fermix_lifecycle_trace_#{suffix}")
    journal_dir = Path.join(System.tmp_dir!(), "fermix_lifecycle_journals_#{suffix}")
    server = :"lifecycle_trace_#{suffix}"
    prefix = "lifecycle-#{suffix}"

    start_supervised!({Trace, base_dir: trace_dir, name: server})
    TelemetryHandler.attach(trace_server: server, handler_prefix: prefix)

    on_exit(fn ->
      TelemetryHandler.detach(prefix)
      FermixTestSupport.SafeRm.rm_rf!(trace_dir)
      FermixTestSupport.SafeRm.rm_rf!(journal_dir)
    end)

    %{journal_dir: journal_dir, trace_dir: trace_dir, server: server}
  end

  test "writes the full delegated skill lifecycle to agent_event traces", %{
    journal_dir: journal_dir,
    trace_dir: trace_dir,
    server: server
  } do
    parent_session = "main-session-316"
    skill_session = "skill-session-316"

    LifecycleTelemetry.skill_invoke(
      "coding-skill",
      skill_session,
      "Read README",
      true,
      18,
      parent_session,
      parent: "main"
    )

    LifecycleTelemetry.agent_start(
      "coding-skill",
      :skill,
      skill_session,
      parent: "main",
      parent_session: parent_session
    )

    LifecycleTelemetry.agent_task_start(
      "coding-skill",
      :skill,
      skill_session,
      "Read README",
      parent: "main",
      parent_session: parent_session
    )

    assert {:ok, journal_path} =
             PersistencePolicy.write_skill_journal(
               %{
                 skill: "coding-skill",
                 task: "Read README",
                 summary: "Read the README and returned a short summary.",
                 status: :completed,
                 result: "README contents summarized.",
                 session_id: skill_session
               },
               base_dir: journal_dir
             )

    LifecycleTelemetry.agent_task_complete(
      "coding-skill",
      :skill,
      skill_session,
      true,
      18,
      2,
      parent: "main",
      parent_session: parent_session
    )

    LifecycleTelemetry.agent_stop(
      "coding-skill",
      :skill,
      skill_session,
      :normal,
      18,
      parent: "main",
      parent_session: parent_session
    )

    sync(server)

    session_entries =
      trace_dir
      |> read_entries(:agent_event)
      |> entries_for_session(skill_session)

    invoke_entry =
      find_entry!(session_entries, fn entry ->
        entry["event"] == "skill_invoke" and entry["task_summary"] == "Read README"
      end)

    start_entry = find_entry!(session_entries, &(&1["event"] == "agent_start"))

    task_start_entry =
      find_entry!(session_entries, fn entry ->
        entry["event"] == "agent_task_start" and entry["task_summary"] == "Read README"
      end)

    journal_entry =
      find_entry!(session_entries, fn entry ->
        entry["event"] == "skill_journal_write" and entry["path"] == journal_path
      end)

    task_complete_entry = find_entry!(session_entries, &(&1["event"] == "agent_task_complete"))
    stop_entry = find_entry!(session_entries, &(&1["event"] == "agent_stop"))

    assert_entries_in_order(session_entries, [
      invoke_entry,
      start_entry,
      task_start_entry,
      journal_entry,
      task_complete_entry,
      stop_entry
    ])

    assert Enum.map(session_entries, & &1["event"]) == [
             "skill_invoke",
             "agent_start",
             "agent_task_start",
             "skill_journal_write",
             "agent_task_complete",
             "agent_stop"
           ]

    assert invoke_entry == %{
             "agent" => "coding-skill",
             "duration_ms" => 18,
             "event" => "skill_invoke",
             "parent" => "main",
             "parent_session" => parent_session,
             "session_id" => skill_session,
             "skill" => "coding-skill",
             "success" => true,
             "task_summary" => "Read README",
             "ts" => invoke_entry["ts"],
             "type" => "agent_event"
           }

    assert start_entry == %{
             "agent" => "coding-skill",
             "event" => "agent_start",
             "name" => "coding-skill",
             "parent" => "main",
             "parent_session" => parent_session,
             "role" => "skill",
             "session_id" => skill_session,
             "ts" => start_entry["ts"],
             "type" => "agent_event"
           }

    assert task_start_entry == %{
             "agent" => "coding-skill",
             "event" => "agent_task_start",
             "name" => "coding-skill",
             "parent" => "main",
             "parent_session" => parent_session,
             "role" => "skill",
             "session_id" => skill_session,
             "task_summary" => "Read README",
             "ts" => task_start_entry["ts"],
             "type" => "agent_event"
           }

    assert journal_entry == %{
             "agent" => "coding-skill",
             "bytes" => byte_size(File.read!(journal_path)),
             "event" => "skill_journal_write",
             "path" => journal_path,
             "session_id" => skill_session,
             "skill" => "coding-skill",
             "ts" => journal_entry["ts"],
             "type" => "agent_event"
           }

    assert task_complete_entry == %{
             "agent" => "coding-skill",
             "duration_ms" => 18,
             "event" => "agent_task_complete",
             "iterations" => 2,
             "name" => "coding-skill",
             "parent" => "main",
             "parent_session" => parent_session,
             "role" => "skill",
             "session_id" => skill_session,
             "success" => true,
             "ts" => task_complete_entry["ts"],
             "type" => "agent_event"
           }

    assert stop_entry == %{
             "agent" => "coding-skill",
             "duration_ms" => 18,
             "event" => "agent_stop",
             "name" => "coding-skill",
             "parent" => "main",
             "parent_session" => parent_session,
             "reason" => "normal",
             "role" => "skill",
             "session_id" => skill_session,
             "ts" => stop_entry["ts"],
             "type" => "agent_event"
           }
  end

  defp sync(server), do: :sys.get_state(server)

  defp read_entries(base_dir, type) do
    Path.join([base_dir, Date.utc_today() |> Date.to_iso8601(), "#{type}.jsonl"])
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp entries_for_session(entries, session_id) do
    Enum.filter(entries, &(&1["session_id"] == session_id))
  end

  defp find_entry!(entries, matcher) do
    Enum.find(entries, matcher) ||
      flunk("expected matching trace entry, got: #{inspect(entries, pretty: true)}")
  end

  defp assert_entries_in_order(entries, expected_entries) do
    indexes =
      Enum.map(expected_entries, fn entry ->
        Enum.find_index(entries, &(&1 == entry)) ||
          flunk("expected trace entry in ordered list, got: #{inspect(entry, pretty: true)}")
      end)

    assert indexes == Enum.sort(indexes)
    assert length(indexes) == length(Enum.uniq(indexes))
  end
end
