defmodule FermixCore.Realtime.RecentCallsTest do
  # The "Recent voice calls" note a chat turn is given (M56 §4.2). Mutates the
  # Computer History config, which the taint mask reads, so it runs alone.
  use ExUnit.Case, async: false

  alias FermixCore.Memory.Repo
  alias FermixCore.Realtime.CallRecord
  alias FermixCore.Realtime.RecentCalls

  @openai [
    {%{
       provider: :openai,
       model: "gpt-test",
       auth_mode: :api_key,
       base_url: "https://api.openai.com/v1"
     }, []}
  ]

  setup do
    original = Application.get_env(:fermix_core, :computer_history)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:fermix_core, :computer_history)
        value -> Application.put_env(:fermix_core, :computer_history, value)
      end
    end)

    # History on, OpenAI not granted: a tainted gist may not ride OpenAI.
    Application.put_env(:fermix_core, :computer_history, enabled: true, summarizer: :local)

    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-recent-calls-#{unique}.db")
    repo = :"recent_calls_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo}
  end

  test "the last three gists, newest first, with their dates, framed as data", %{repo: repo} do
    gisted!(
      repo,
      "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d",
      ~U[2026-09-30 08:00:00Z],
      "Oldest call."
    )

    gisted!(
      repo,
      "6f1c2a4e-9b3d-4c5e-8a7f-0123456789ab",
      ~U[2026-10-01 09:15:00Z],
      "Booked the dentist."
    )

    gisted!(
      repo,
      "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
      ~U[2026-10-02 18:40:00Z],
      "Planned the trip."
    )

    gisted!(
      repo,
      "3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b",
      ~U[2026-10-03 14:05:00Z],
      "Read the lease."
    )

    note = RecentCalls.note(repo, @openai, [])

    assert note =~ "Recent voice calls"
    assert note =~ "not a request"
    assert note =~ ~s(<untrusted_tool_result source="voice_call_gists">)

    assert note =~
             "- 2026-10-03 14:05 UTC: Read the lease.\n" <>
               "- 2026-10-02 18:40 UTC: Planned the trip.\n" <>
               "- 2026-10-01 09:15 UTC: Booked the dentist."

    refute note =~ "Oldest call."
  end

  test "about a kilobyte: each gist is cut to a few hundred bytes at a sentence", %{repo: repo} do
    long = String.duplicate("The owner asked about the trip and it was planned. ", 40)

    for {uuid, at} <- [
          {"0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d", ~U[2026-10-01 09:00:00Z]},
          {"6f1c2a4e-9b3d-4c5e-8a7f-0123456789ab", ~U[2026-10-02 09:00:00Z]},
          {"3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b", ~U[2026-10-03 09:00:00Z]}
        ] do
      gisted!(repo, uuid, at, long)
    end

    note = RecentCalls.note(repo, @openai, [])
    assert byte_size(note) <= 1_600
    assert note =~ "planned. \n" or note =~ "planned.\n"
  end

  test "with no earlier call, memory off or no repo there is no note", %{repo: repo} do
    assert RecentCalls.note(repo, @openai, []) == nil
    assert RecentCalls.note(nil, @openai, []) == nil

    off = :"recent_calls_off_#{System.unique_integer([:positive])}"
    start_supervised!({Repo, name: off, enabled: false}, id: off)
    assert RecentCalls.note(off, @openai, []) == nil
  end

  # M56 §9: a gist drawn from Computer History is noted only on a turn whose
  # route chain may carry history, the mask a turn's own history gets.
  test "a gist drawn from Computer History is left out unless the turn's chain may carry it", %{
    repo: repo
  } do
    gisted!(
      repo,
      "6f1c2a4e-9b3d-4c5e-8a7f-0123456789ab",
      ~U[2026-10-01 09:15:00Z],
      "Booked the dentist."
    )

    gisted!(
      repo,
      "3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b",
      ~U[2026-10-03 14:05:00Z],
      "You read the Q3 report.",
      true
    )

    note = RecentCalls.note(repo, @openai, [])
    refute note =~ "Q3"
    assert note =~ "Booked the dentist."

    Application.put_env(:fermix_core, :computer_history,
      enabled: true,
      summarizer: :local,
      remote_summaries: [:openai]
    )

    assert RecentCalls.note(repo, @openai, []) =~ "You read the Q3 report."
  end

  defp gisted!(repo, uuid, started_at, gist, tainted? \\ false) do
    opts = CallRecord.repo_opts(repo)
    record = CallRecord.new(uuid, "openai_live")
    :ok = CallRecord.open(record, started_at, opts)
    usage = %{voice_cost_cents: 5.0, accounting: "complete"}
    ended_at = DateTime.add(started_at, 300, :second)
    :ok = CallRecord.close(record, :call_stop, usage, ended_at, opts, :gist)
    :ok = CallRecord.record_gist(uuid, {:ok, gist, tainted?}, opts)
  end
end
