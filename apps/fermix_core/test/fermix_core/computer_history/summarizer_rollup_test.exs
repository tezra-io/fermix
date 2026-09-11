defmodule FermixCore.ComputerHistory.Summarizer.RollupTest do
  @moduledoc """
  MILESTONE_32 §24.3 — the daily roll-up that rewrites the active thread set.

  Driven through `Summarizer.run_cycle/1` so the roll-up rides the same resolved
  route and the same Gate check the sittings do: a fake adapter records the call
  and returns a canned block list, the spool is empty (so the sitting loop has
  nothing to do), and the session notes are seeded directly.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.ComputerHistory.Summarizer
  alias FermixCore.Memory.Repo

  defmodule FakeAdapter do
    @behaviour FermixCore.Providers.Adapter

    alias FermixCore.Memory.Repo

    @impl true
    def chat(messages, _capabilities, opts) do
      call = %{
        messages: messages,
        model: opts[:model],
        agent: opts[:agent],
        session_id: opts[:session_id],
        parent_session: opts[:parent_session]
      }

      Process.put(:rollup_calls, [call | calls()])
      purge_mid_call(Process.get(:rollup_purge))

      case Process.get(:rollup_behavior, :ok) do
        :ok -> {:ok, turn(Process.get(:rollup_content, ""), opts[:model])}
        :error -> {:error, :provider_unavailable}
      end
    end

    # The read-infer-write race, reproduced exactly: the owner purges while this
    # call is in flight, so the reply describes notes the store no longer holds.
    defp purge_mid_call(nil), do: :ok

    defp purge_mid_call({repo, to_ts}) do
      {:ok, _counts} = Repo.computer_history_purge_window(0, to_ts, server: repo)
      :ok
    end

    @impl true
    def continue(_state, _results, _opts), do: {:error, :not_supported}
    @impl true
    def to_provider_tools(_caps), do: []
    @impl true
    def parse_tool_calls(_response), do: []
    @impl true
    def parse_response(response), do: response

    defp calls, do: Process.get(:rollup_calls, [])

    defp turn(content, model) do
      %{
        content: content,
        tool_calls: [],
        provider_state: nil,
        usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
        model: model
      }
    end
  end

  @now ~U[2026-09-10 18:00:00Z]

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-ch-rollup-#{unique}.db")
    repo_name = :"ch_rollup_repo_#{unique}"
    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    original = Application.get_env(:fermix_core, :computer_history)
    Application.put_env(:fermix_core, :computer_history, enabled: true, summarizer: :local)
    Process.delete(:rollup_calls)
    Process.delete(:rollup_content)
    Process.delete(:rollup_behavior)
    Process.delete(:rollup_purge)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:fermix_core, :computer_history)
        value -> Application.put_env(:fermix_core, :computer_history, value)
      end

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo_name}
  end

  defp ms(datetime), do: DateTime.to_unix(datetime, :millisecond)

  defp run(repo, opts \\ []) do
    Summarizer.run_cycle(
      opts ++
        [
          repo: repo,
          macos?: true,
          adapter: FakeAdapter,
          route_opts: [model: "llama3"],
          timezone: "Etc/UTC",
          now: @now
        ]
    )
  end

  defp calls, do: Process.get(:rollup_calls, []) |> Enum.reverse()

  defp reply(content), do: Process.put(:rollup_content, content)

  defp note(repo, attrs) do
    base = %{
      created_at: ms(~U[2026-09-10 09:00:00Z]),
      provenance_from_ts: ms(~U[2026-09-10 08:30:00Z]),
      provenance_to_ts: ms(~U[2026-09-10 09:00:00Z]),
      summary: "worked on the plan",
      model: "llama3",
      event_count: 4
    }

    {:ok, id} = Repo.computer_history_insert_memory(Map.merge(base, attrs), server: repo)
    id
  end

  defp thread(repo, subject, attrs) do
    base = %{
      kind: "thread",
      subject: subject,
      summary: "state of #{subject}",
      source_ids: Jason.encode!([1]),
      last_touched_ts: ms(~U[2026-09-09 17:00:00Z]),
      created_at: ms(~U[2026-09-09 17:00:00Z]),
      provenance_from_ts: ms(~U[2026-09-09 16:00:00Z]),
      provenance_to_ts: ms(~U[2026-09-09 17:00:00Z]),
      model: "llama3",
      event_count: 0
    }

    {:ok, id} = Repo.computer_history_insert_memory(Map.merge(base, attrs), server: repo)
    id
  end

  defp threads(repo) do
    {:ok, rows} = Repo.computer_history_active_threads(8, server: repo)
    rows
  end

  defp state(repo) do
    {:ok, state} = Repo.computer_history_ensure_state(server: repo)
    state
  end

  describe "the active set" do
    test "is written from the new notes, with citations, artifacts and provenance", %{repo: repo} do
      first =
        note(repo, %{
          summary: "drafted the Apollo migration plan",
          titles: Jason.encode!(["Apollo migration plan"]),
          urls: Jason.encode!(["https://docs.example.com/apollo"]),
          apps: Jason.encode!(["com.apple.Safari"]),
          sites: Jason.encode!(["docs.example.com"])
        })

      second =
        note(repo, %{
          created_at: ms(~U[2026-09-10 14:00:00Z]),
          provenance_from_ts: ms(~U[2026-09-10 13:00:00Z]),
          provenance_to_ts: ms(~U[2026-09-10 14:00:00Z]),
          summary: "chased the restore check",
          titles: Jason.encode!(["Restore runbook"])
        })

      reply("""
      ## Apollo migration
      The plan is drafted and the restore check is still open.
      sources: #{first}, #{second}
      """)

      assert {:ok, _cycle} = run(repo)

      assert [thread] = threads(repo)
      assert thread.kind == "thread"
      assert thread.subject == "Apollo migration"
      assert thread.summary == "The plan is drafted and the restore check is still open."
      assert Jason.decode!(thread.source_ids) == [first, second]
      assert thread.last_touched_ts == ms(~U[2026-09-10 14:00:00Z])
      assert thread.provenance_from_ts == ms(~U[2026-09-10 08:30:00Z])
      assert thread.provenance_to_ts == ms(~U[2026-09-10 14:00:00Z])
      assert thread.created_at == ms(@now)
      assert thread.model == "llama3"

      # Artifacts are carried from the cited notes, not re-derived from events.
      assert Jason.decode!(thread.titles) == ["Apollo migration plan", "Restore runbook"]
      assert Jason.decode!(thread.urls) == ["https://docs.example.com/apollo"]
      assert Jason.decode!(thread.apps) == ["com.apple.Safari"]
      assert Jason.decode!(thread.sites) == ["docs.example.com"]

      assert state(repo).last_rollup_ts == ms(@now)

      # The journal underneath is untouched: threads never supersede notes.
      assert {:ok, 2} = Repo.computer_history_count_memories(server: repo, kind: :session)
    end

    test "a prior thread the model does not re-emit retires", %{repo: repo} do
      id = note(repo, %{summary: "chased the restore check"})
      retired_id = thread(repo, "Finished cleanup", %{})

      reply("""
      ## Apollo migration
      The restore check is the open question.
      sources: #{id}
      """)

      assert {:ok, _cycle} = run(repo)

      assert Enum.map(threads(repo), & &1.subject) == ["Apollo migration"]

      # Retired, never deleted.
      assert {:ok, rows} =
               Repo.computer_history_memories_in_window(0, 9_999_999_999_999, 10,
                 server: repo,
                 kind: :thread
               )

      assert Enum.map(rows, & &1.subject) == ["Apollo migration"]
      assert {:ok, 1} = Repo.computer_history_count_memories(server: repo, kind: :thread)

      # Retired means superseded, never deleted: the row is still there, stamped.
      assert {:ok, 2} =
               Repo.computer_history_count_memories(server: repo, kind: :thread, scope: :all)

      assert {:ok, [retired]} =
               Repo.computer_history_memories_by_ids([retired_id], server: repo, kind: :thread)

      assert retired.subject == "Finished cleanup"
      assert is_integer(retired.superseded_at)
    end

    # S2: the reviewer's Apollo case. A thread with nothing new said about it must
    # survive the day, so the input has to carry its own citations and they have to
    # resolve against the store, not only against this roll-up's new notes.
    test "a thread with no new note survives when it re-emits its own sources", %{repo: repo} do
      old_note =
        note(repo, %{
          created_at: ms(~U[2026-09-08 10:00:00Z]),
          provenance_from_ts: ms(~U[2026-09-08 09:00:00Z]),
          provenance_to_ts: ms(~U[2026-09-08 10:00:00Z]),
          summary: "drafted the Apollo migration plan",
          titles: Jason.encode!(["Apollo migration plan"])
        })

      # Yesterday's roll-up put the mark PAST that note, so today's input cannot
      # see it among the new notes — only the thread's own citation reaches it.
      reply("## Apollo migration\nWaiting on the restore check.\nsources: #{old_note}")
      assert {:ok, _first} = run(repo, now: ~U[2026-09-08 18:00:00Z])
      assert [_apollo] = threads(repo)

      # The only NEW note is about something else entirely.
      new_note =
        note(repo, %{
          created_at: ms(~U[2026-09-09 19:00:00Z]),
          provenance_from_ts: ms(~U[2026-09-09 18:00:00Z]),
          provenance_to_ts: ms(~U[2026-09-09 19:00:00Z]),
          summary: "reviewed the invoice spreadsheet"
        })

      reply("""
      ## Apollo migration
      Still waiting on the restore check.
      sources: #{old_note}

      ## Invoices
      Reviewing the spreadsheet.
      sources: #{new_note}
      """)

      assert {:ok, _cycle} = run(repo, now: ~U[2026-09-09 20:00:00Z])

      threads = threads(repo)
      assert Enum.sort(Enum.map(threads, & &1.subject)) == ["Apollo migration", "Invoices"]

      apollo = Enum.find(threads, &(&1.subject == "Apollo migration"))
      assert Jason.decode!(apollo.source_ids) == [old_note]
      # Provenance and last-touched come from the prior note the thread still cites.
      assert apollo.last_touched_ts == ms(~U[2026-09-08 10:00:00Z])
      assert apollo.provenance_from_ts == ms(~U[2026-09-08 09:00:00Z])
      assert Jason.decode!(apollo.titles) == ["Apollo migration plan"]
    end

    test "the input carries each current thread's own citations", %{repo: repo} do
      old_note = note(repo, %{created_at: ms(~U[2026-09-08 10:00:00Z]), summary: "drafted it"})
      note(repo, %{summary: "chased the restore check"})

      thread(repo, "Apollo migration", %{source_ids: Jason.encode!([old_note])})
      reply("nothing usable")

      assert {:ok, _cycle} = run(repo)

      assert [call] = calls()
      user = call.messages |> Enum.at(1) |> Map.fetch!(:content)
      assert user =~ "## Apollo migration"
      assert user =~ "sources: #{old_note}"
    end

    test "a citation the store no longer holds drops with its block", %{repo: repo} do
      purged_note =
        note(repo, %{
          created_at: ms(~U[2026-09-08 10:00:00Z]),
          provenance_from_ts: ms(~U[2026-09-08 09:00:00Z]),
          provenance_to_ts: ms(~U[2026-09-08 10:00:00Z]),
          summary: "drafted the Apollo migration plan"
        })

      reply("## Apollo migration\nWaiting on the restore check.\nsources: #{purged_note}")
      assert {:ok, _first} = run(repo, now: ~U[2026-09-08 18:00:00Z])

      # The owner purges that day. The thread still cites the note; the store does
      # not hold it any more, so re-emitting it must not resurrect it.
      assert {:ok, _purged} =
               Repo.computer_history_purge_window(0, ms(~U[2026-09-08 23:00:00Z]), server: repo)

      new_note =
        note(repo, %{
          created_at: ms(~U[2026-09-09 19:00:00Z]),
          provenance_from_ts: ms(~U[2026-09-09 18:00:00Z]),
          provenance_to_ts: ms(~U[2026-09-09 19:00:00Z]),
          summary: "reviewed the invoice spreadsheet"
        })

      reply("""
      ## Apollo migration
      Still waiting on the restore check.
      sources: #{purged_note}

      ## Invoices
      Reviewing the spreadsheet.
      sources: #{new_note}
      """)

      assert {:ok, _cycle} = run(repo, now: ~U[2026-09-09 20:00:00Z])
      assert Enum.map(threads(repo), & &1.subject) == ["Invoices"]
    end

    test "the input carries the current threads and the new notes", %{repo: repo} do
      id = note(repo, %{summary: "chased the restore check"})
      thread(repo, "Apollo migration", %{summary: "Waiting on the restore check."})
      reply("## Apollo migration\nStill waiting.\nsources: #{id}")

      assert {:ok, _cycle} = run(repo)

      assert [call] = calls()
      [system, user] = Enum.map(call.messages, & &1.content)

      assert system =~ "## <subject>"
      assert system =~ "sources:"
      assert user =~ "## Apollo migration"
      assert user =~ "Waiting on the restore check."
      assert user =~ "last touched Sep 9"
      assert user =~ "[s#{id}]"
      assert user =~ "chased the restore check"
    end

    # S9: the roll-up is a different kind of run from a sitting summary — its own
    # session id, under the cycle's, so a trace reader can tell the two apart and
    # still see which cycle produced it.
    test "the call is its own run, parented to the cycle", %{repo: repo} do
      id = note(repo, %{summary: "chased the restore check"})
      reply("## Apollo migration\nOpen.\nsources: #{id}")

      assert {:ok, _cycle} = run(repo)

      assert [call] = calls()
      assert call.agent == "computer_history_rollup"
      assert call.session_id == "computer_history_rollup:#{ms(@now)}"
      assert call.parent_session == "computer_history_summarize:#{ms(@now)}"
    end

    test "an uncited block is dropped", %{repo: repo} do
      id = note(repo, %{summary: "chased the restore check"})

      reply("""
      ## Invented work
      Something with no evidence behind it.

      ## Apollo migration
      The restore check is the open question.
      sources: #{id}
      """)

      assert {:ok, _cycle} = run(repo)
      assert Enum.map(threads(repo), & &1.subject) == ["Apollo migration"]
    end

    test "an unknown id is dropped and the block keeps its real citation", %{repo: repo} do
      id = note(repo, %{summary: "chased the restore check"})

      reply("""
      ## Apollo migration
      The restore check is the open question.
      sources: #{id}, 9999
      """)

      assert {:ok, _cycle} = run(repo)
      assert [thread] = threads(repo)
      assert Jason.decode!(thread.source_ids) == [id]
    end

    test "a block citing only unknown ids is dropped", %{repo: repo} do
      id = note(repo, %{summary: "chased the restore check"})

      reply("""
      ## Invented work
      Cites a note that does not exist.
      sources: 9999

      ## Apollo migration
      The restore check is the open question.
      sources: #{id}
      """)

      assert {:ok, _cycle} = run(repo)
      assert Enum.map(threads(repo), & &1.subject) == ["Apollo migration"]
    end

    test "the set is capped at eight, keeping the most recently touched", %{repo: repo} do
      ids =
        Enum.map(1..10, fn index ->
          note(repo, %{
            summary: "note-#{index}",
            created_at: ms(~U[2026-09-10 09:00:00Z]) + index,
            provenance_from_ts: ms(~U[2026-09-10 09:00:00Z]) + index,
            provenance_to_ts: ms(~U[2026-09-10 09:00:00Z]) + index
          })
        end)

      blocks =
        ids
        |> Enum.with_index(1)
        |> Enum.map_join("\n\n", fn {id, index} ->
          "## Thread #{index}\nState #{index}.\nsources: #{id}"
        end)

      reply(blocks)

      assert {:ok, _cycle} = run(repo)

      subjects = Enum.map(threads(repo), & &1.subject)
      assert length(subjects) == 8
      # Threads 9 and 10 cite the newest notes, so the two oldest fall off.
      assert "Thread 10" in subjects
      refute "Thread 1" in subjects
      refute "Thread 2" in subjects
    end

    # S7: two blocks with the same subject are one thread. Storing both would show
    # the owner the same work twice and spend two of the eight slots on it.
    test "a subject emitted twice becomes one thread", %{repo: repo} do
      first = note(repo, %{summary: "drafted the plan"})

      second =
        note(repo, %{
          created_at: ms(~U[2026-09-10 14:00:00Z]),
          provenance_from_ts: ms(~U[2026-09-10 13:00:00Z]),
          provenance_to_ts: ms(~U[2026-09-10 14:00:00Z]),
          summary: "chased the restore check"
        })

      reply("""
      ## Apollo migration
      The restore check is the open question.
      sources: #{second}

      ## Apollo migration
      Duplicate block with an older citation.
      sources: #{first}
      """)

      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      log = capture_log([level: :info], fn -> assert {:ok, _cycle} = run(repo) end)

      assert [thread] = threads(repo)
      # The most recently touched of the two blocks wins.
      assert thread.summary == "The restore check is the open question."
      assert log =~ "computer_history rollup: 1 thread(s) (0 retired, 1 new)"
    end

    test "the state is bounded and verbatim spool text is redacted out of it", %{repo: repo} do
      id = note(repo, %{summary: "chased the restore check"})
      echoed = "the quarterly revenue projection deck for next year"

      {:ok, _inserted} =
        Repo.computer_history_insert_events(
          [
            %{
              boot_id: "b1",
              source_seq: 1,
              ts: ms(~U[2026-09-10 09:00:00Z]),
              type: "field.value",
              bundle_id: "com.apple.TextEdit",
              text: echoed
            }
          ],
          server: repo
        )

      reply("""
      ## Apollo migration
      The owner keeps editing #{echoed} while the restore check waits.
      sources: #{id}
      """)

      # The spool event is inside an open sitting (it is minutes old relative to
      # `now`), so the sitting loop leaves it alone and only the roll-up runs.
      assert {:ok, %{sessions: 0}} = run(repo, now: ~U[2026-09-10 09:05:00Z])

      assert [thread] = threads(repo)
      assert thread.summary =~ "[…]"
      refute thread.summary =~ echoed
    end
  end

  describe "when the roll-up runs" do
    test "not at all without a session note since the mark", %{repo: repo} do
      assert {:ok, _cycle} = run(repo)
      assert calls() == []
      assert state(repo).last_rollup_ts == nil
    end

    test "not again inside twenty-four hours, and again after them", %{repo: repo} do
      first = note(repo, %{summary: "chased the restore check"})
      reply("## Apollo migration\nOpen.\nsources: #{first}")

      assert {:ok, _cycle} = run(repo)
      assert length(calls()) == 1

      # A new note, but only an hour later: not due.
      second =
        note(repo, %{
          created_at: ms(~U[2026-09-10 19:00:00Z]),
          summary: "reviewed the runbook"
        })

      reply("## Apollo migration\nStill open.\nsources: #{second}")
      assert {:ok, _cycle} = run(repo, now: ~U[2026-09-10 19:30:00Z])
      assert length(calls()) == 1

      # A day later it is due again, and it reads the note written since.
      assert {:ok, _cycle} = run(repo, now: ~U[2026-09-11 19:00:00Z])
      assert length(calls()) == 2

      assert calls() |> List.last() |> Map.fetch!(:messages) |> Enum.at(1) |> Map.get(:content) =~
               "[s#{second}]"
    end

    # S3: a day with more notes than the input bound keeps the NEWEST ones, and
    # renders them oldest-first so the section still reads forward in time.
    test "with more notes than fit, the newest reach the input", %{repo: repo} do
      ids =
        Enum.map(1..100, fn index ->
          note(repo, %{
            created_at: ms(~U[2026-09-10 09:00:00Z]) + index,
            summary: "note-#{index}"
          })
        end)

      reply("nothing usable")

      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      log = capture_log([level: :info], fn -> assert {:ok, _cycle} = run(repo) end)

      assert [call] = calls()
      user = call.messages |> Enum.at(1) |> Map.fetch!(:content)

      # The 80 newest are in; the 20 oldest are not.
      assert user =~ "[s#{Enum.at(ids, 99)}]"
      assert user =~ "[s#{Enum.at(ids, 20)}]"
      refute user =~ "[s#{Enum.at(ids, 19)}]"

      # Rendered oldest-first inside the input.
      assert :binary.match(user, "note-21") < :binary.match(user, "note-100")
      assert log =~ "the newest 80 of 100 session note(s)"
    end

    # S5: a model that keeps returning garbage must not be retried every tick.
    test "an unusable reply is retried once a day, not once a tick", %{repo: repo} do
      note(repo, %{summary: "chased the restore check"})
      reply("I could not identify any threads.")

      assert {:ok, _first} = run(repo)
      assert length(calls()) == 1
      assert state(repo).last_rollup_attempt_ts == ms(@now)
      assert state(repo).last_rollup_ts == nil

      # Two more cycles inside the day: the attempt mark holds them off.
      assert {:ok, _second} = run(repo, now: ~U[2026-09-10 19:00:00Z])
      assert {:ok, _third} = run(repo, now: ~U[2026-09-11 10:00:00Z])
      assert length(calls()) == 1
    end

    test "the day after a failed attempt it reads the notes since the last real write", %{
      repo: repo
    } do
      first_note = note(repo, %{summary: "chased the restore check"})
      reply("I could not identify any threads.")
      assert {:ok, _failed} = run(repo)
      assert length(calls()) == 1

      second_note =
        note(repo, %{
          created_at: ms(~U[2026-09-11 09:00:00Z]),
          summary: "reviewed the invoice spreadsheet"
        })

      reply("## Apollo migration\nOpen.\nsources: #{first_note}, #{second_note}")
      assert {:ok, _retried} = run(repo, now: ~U[2026-09-11 19:00:00Z])
      assert length(calls()) == 2

      # The notes cursor is the last real WRITE, so the note the failed attempt
      # already saw is offered again rather than lost.
      user = calls() |> List.last() |> Map.fetch!(:messages) |> Enum.at(1) |> Map.fetch!(:content)
      assert user =~ "[s#{first_note}]"
      assert user =~ "[s#{second_note}]"

      assert state(repo).last_rollup_ts == ms(~U[2026-09-11 19:00:00Z])
    end

    test "a reply with no valid thread writes nothing and leaves the mark", %{repo: repo} do
      note(repo, %{summary: "chased the restore check"})
      thread(repo, "Still current", %{})
      reply("I could not identify any threads.")

      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      log = capture_log([level: :info], fn -> assert {:ok, _cycle} = run(repo) end)

      assert log =~ "computer_history rollup: no usable threads"
      # Nothing was superseded: "the model said nothing" is not "nothing is current".
      assert Enum.map(threads(repo), & &1.subject) == ["Still current"]
      assert state(repo).last_rollup_ts == nil
    end

    # S1: the owner purged the window while the roll-up call was in flight.
    test "a purge during the call writes nothing and leaves the mark", %{repo: repo} do
      id = note(repo, %{summary: "chased the restore check"})

      # The prior thread's own window is AFTER the purge horizon, so the purge
      # leaves it alone and only the roll-up could have removed it.
      thread(repo, "Still current", %{
        provenance_from_ts: ms(~U[2026-09-10 13:00:00Z]),
        provenance_to_ts: ms(~U[2026-09-10 14:00:00Z]),
        last_touched_ts: ms(~U[2026-09-10 14:00:00Z])
      })

      reply("## Apollo migration\nOpen.\nsources: #{id}")
      Process.put(:rollup_purge, {repo, ms(~U[2026-09-10 12:00:00Z])})

      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      log = capture_log([level: :info], fn -> assert {:ok, _cycle} = run(repo) end)

      assert log =~
               "computer_history rollup: every thread drew on a window purged during the call"

      # The prior thread is outside the purged window, so it is untouched.
      assert Enum.map(threads(repo), & &1.subject) == ["Still current"]
      assert state(repo).last_rollup_ts == nil
    end

    test "a route down refuses loudly without a second vendor", %{repo: repo} do
      note(repo, %{summary: "chased the restore check"})
      Process.put(:rollup_behavior, :error)

      assert {:error, :provider_unavailable} = run(repo)
      assert length(calls()) == 1
      assert threads(repo) == []
      assert state(repo).last_rollup_ts == nil
      assert state(repo).paused_reason == "route_down"
    end

    test "one info line names the counts", %{repo: repo} do
      id = note(repo, %{summary: "chased the restore check"})
      thread(repo, "Finished cleanup", %{})

      reply("""
      ## Apollo migration
      Open.
      sources: #{id}
      """)

      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      log = capture_log([level: :info], fn -> assert {:ok, _cycle} = run(repo) end)

      assert log =~ "computer_history rollup: 1 thread(s) (1 retired, 1 new)"
    end
  end
end
