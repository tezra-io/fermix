defmodule FermixCore.Companion.TimelineSearchTest do
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Companion.Timeline
  alias FermixCore.Memory.Repo

  @now ~U[2026-09-25 12:00:00Z]

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-companion-timeline-#{unique}.db")
    repo_name = :"companion_timeline_repo_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{db_path: db_path, repo: repo_name}
  end

  test "pages backward from a cursor, oldest first, and says when older rows exist", %{
    repo: repo
  } do
    append_all(repo, Enum.map(1..5, &"message #{&1}"))

    assert {:ok, page} = Timeline.history_page("main", opts(repo, before_seq: 5, limit: 2))
    assert Enum.map(page.messages, & &1.server_seq) == [3, 4]
    assert page.next_before_seq == 3
    assert page.history_head_seq == 5

    assert {:ok, older} = Timeline.history_page("main", opts(repo, before_seq: 3, limit: 2))
    assert Enum.map(older.messages, & &1.server_seq) == [1, 2]
    assert older.next_before_seq == nil

    assert {:ok, %{messages: [], next_before_seq: nil}} =
             Timeline.history_page("main", opts(repo, before_seq: 1, limit: 2))
  end

  test "the two history cursors exclude each other and the backward one is positive", %{
    repo: repo
  } do
    assert {:error, :conflicting_history_cursors} =
             Timeline.history_page("main", opts(repo, after_seq: 0, before_seq: 3))

    assert {:error, {:invalid_before_seq, 0}} =
             Timeline.history_page("main", opts(repo, before_seq: 0))

    assert {:ok, %{next_after_seq: 0}} = Timeline.history_page("main", opts(repo))
  end

  test "search finds rows by word prefix, newest first, with the matched ranges", %{repo: repo} do
    append_all(repo, [
      "The quarterly plan is due Friday",
      "Lunch at noon",
      "Revised plans attached for review",
      "Nothing relevant here"
    ])

    assert {:ok, %{hits: hits, next_before_seq: nil}} =
             Timeline.search("main", "plan", opts(repo, limit: 10))

    assert Enum.map(hits, & &1.server_seq) == [3, 1]
    assert [%{role: "assistant", excerpt: excerpt, ranges: [range]} | _rest] = hits
    assert excerpt == "Revised plans attached for review"
    assert String.slice(excerpt, range.start, range.length) == "plans"
    assert %DateTime{} = hd(hits).created_at
  end

  test "search ranges count Unicode scalar values, not bytes", %{repo: repo} do
    append_all(repo, ["Café crème, then the naïve résumé"])

    assert {:ok, %{hits: [hit]}} = Timeline.search("main", "résumé", opts(repo))

    [range] = hit.ranges
    codepoints = String.codepoints(hit.excerpt)
    assert codepoints |> Enum.slice(range.start, range.length) |> Enum.join() == "résumé"
  end

  test "every word of the query must match, and FTS syntax is literal text", %{repo: repo} do
    append_all(repo, ["alpha beta", "alpha gamma", "NEAR(delta) OR \"epsilon\""])

    assert {:ok, %{hits: [%{server_seq: 1}]}} = Timeline.search("main", "alpha beta", opts(repo))
    assert {:ok, %{hits: hits}} = Timeline.search("main", "NEAR(delta) OR", opts(repo))
    assert Enum.map(hits, & &1.server_seq) == [3]
    assert {:ok, %{hits: [%{server_seq: 3}]}} = Timeline.search("main", "\"epsilon", opts(repo))
    assert {:ok, %{hits: []}} = Timeline.search("main", "  ?? !! ", opts(repo))
  end

  test "search pages backward with the same cursor history uses", %{repo: repo} do
    append_all(repo, Enum.map(1..5, &"note number #{&1}"))

    assert {:ok, first} = Timeline.search("main", "note", opts(repo, limit: 2))
    assert Enum.map(first.hits, & &1.server_seq) == [5, 4]
    assert first.next_before_seq == 4

    assert {:ok, second} =
             Timeline.search(
               "main",
               "note",
               opts(repo, limit: 2, before_seq: first.next_before_seq)
             )

    assert Enum.map(second.hits, & &1.server_seq) == [3, 2]

    assert {:ok, last} =
             Timeline.search(
               "main",
               "note",
               opts(repo, limit: 2, before_seq: second.next_before_seq)
             )

    assert Enum.map(last.hits, & &1.server_seq) == [1]
    assert last.next_before_seq == nil
  end

  test "search stays inside its profile and owner", %{repo: repo} do
    append_all(repo, ["shared word"])

    assert {:ok, _row} =
             Timeline.append("work", %{role: "assistant", content: "shared word"}, opts(repo))

    assert {:ok, _row} =
             Timeline.append(
               "main",
               %{role: "assistant", content: "shared word"},
               opts(repo, owner_id: "someone-else")
             )

    assert {:ok, %{hits: [%{server_seq: 1}]}} = Timeline.search("main", "shared", opts(repo))
  end

  test "an enriched user message is searchable by its new content only", %{repo: repo} do
    store = opts(repo, now: @now, transport: "companion")

    assert {:ok, {:claimed, _request}} =
             Timeline.claim_client_request("main", "voice-1", "msg", %{"n" => 1}, store)

    assert {:ok, {:started, %{attempt: 1}}} =
             Timeline.start_client_request("main", "voice-1", "boot-a", store)

    assert {:ok, {:created, _row}} =
             Timeline.append_client_message("main", "voice-1", %{content: "placeholder"}, store)

    assert {:ok, _row} =
             Timeline.update_client_message(
               "main",
               "voice-1",
               1,
               %{content: "transcribed words"},
               store
             )

    assert {:ok, %{hits: [%{server_seq: 1, role: "user"}]}} =
             Timeline.search("main", "transcribed", store)

    assert {:ok, %{hits: []}} = Timeline.search("main", "placeholder", store)
  end

  test "a companion claim names no device and is recovered only by its own transport", %{
    repo: repo
  } do
    companion = opts(repo, now: @now, transport: "companion")
    mobile = opts(repo, now: @now, transport: "mobile", authenticated_device_id: "device-a")

    assert {:ok, {:claimed, claimed}} =
             Timeline.claim_client_request("main", "mac-1", "msg", %{"t" => 1}, companion)

    assert claimed.transport == "companion"
    assert claimed.authenticated_device_id == nil

    assert {:ok, {:claimed, %{transport: "mobile"}}} =
             Timeline.claim_client_request("main", "phone-1", "msg", %{"t" => 2}, mobile)

    assert {:ok, [%{client_msg_id: "mac-1"}]} =
             Timeline.recoverable_client_requests("boot-a", companion)

    assert {:ok, [%{client_msg_id: "phone-1"}]} =
             Timeline.recoverable_client_requests("boot-a", mobile)
  end

  test "a claim names its transport, and the same id from another transport conflicts", %{
    repo: repo
  } do
    companion = opts(repo, now: @now, transport: "companion")

    assert {:error, {:missing_option, :transport}} =
             Timeline.claim_client_request("main", "c-1", "msg", %{}, opts(repo))

    assert {:error, {:invalid_option, :authenticated_device_id, "device-a"}} =
             Timeline.claim_client_request(
               "main",
               "c-1",
               "msg",
               %{},
               Keyword.put(companion, :authenticated_device_id, "device-a")
             )

    assert {:error, {:missing_option, :transport}} =
             Timeline.recoverable_client_requests("boot-a", opts(repo))

    assert {:ok, {:claimed, _request}} =
             Timeline.claim_client_request("main", "c-1", "msg", %{"x" => 1}, companion)

    assert {:ok, {:duplicate, _request}} =
             Timeline.claim_client_request("main", "c-1", "msg", %{"x" => 1}, companion)

    assert {:ok, {:conflict, %{transport: "companion"}}} =
             Timeline.claim_client_request(
               "main",
               "c-1",
               "msg",
               %{"x" => 1},
               opts(repo, now: @now, transport: "mobile", authenticated_device_id: "device-a")
             )
  end

  test "the companion migration indexes rows written before it and marks old claims mobile",
       context do
    %{db_path: db_path, repo: repo} = context
    append_all(repo, ["written before the index"])

    assert {:ok, {:claimed, _request}} =
             Timeline.claim_client_request(
               "main",
               "old-1",
               "msg",
               %{},
               opts(repo, now: @now, transport: "mobile", authenticated_device_id: "device-a")
             )

    stop_supervised!(Repo)
    with_raw_conn(db_path, &rewind_to_before_companion/1)
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    assert {:ok, %{hits: [%{server_seq: 1}]}} = Timeline.search("main", "index", opts(repo))

    assert {:ok, [%{client_msg_id: "old-1", transport: "mobile"}]} =
             Timeline.recoverable_client_requests("boot-a", opts(repo, transport: "mobile"))
  end

  defp rewind_to_before_companion(conn) do
    assert :ok =
             Sqlite3.execute(conn, """
             DROP TRIGGER mobile_timeline_fts_ai;
             DROP TRIGGER mobile_timeline_fts_ad;
             DROP TRIGGER mobile_timeline_fts_au;
             DROP TABLE mobile_timeline_fts;
             ALTER TABLE mobile_client_requests DROP COLUMN transport;
             DELETE FROM schema_migrations WHERE version = 33;
             """)
  end

  defp append_all(repo, contents) do
    Enum.each(contents, fn content ->
      assert {:ok, _row} =
               Timeline.append("main", %{role: "assistant", content: content}, opts(repo))
    end)
  end

  defp opts(repo, extra \\ []) do
    Keyword.merge([repo: repo, agent_id: "agent-a", owner_id: "owner-a"], extra)
  end

  defp with_raw_conn(db_path, operation) do
    {:ok, conn} = Sqlite3.open(db_path, mode: :readwrite)
    :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout = 2000;")

    try do
      operation.(conn)
    after
      Sqlite3.close(conn)
    end
  end
end
