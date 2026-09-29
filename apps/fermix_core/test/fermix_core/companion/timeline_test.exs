defmodule FermixCore.Companion.TimelineTest do
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Companion.Timeline
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.MobileSql

  @now ~U[2026-08-12 12:00:00Z]
  @max_i64 9_223_372_036_854_775_807
  @max_u64 18_446_744_073_709_551_615
  @day_seconds 86_400
  @media_ref String.duplicate("b", 64)

  # Takes a database back to the shape it had before migration 36: every object
  # the migration adds, and its version row.
  @rewind_media_index_migration """
  DROP TRIGGER mobile_timeline_media_ai;
  DROP TRIGGER mobile_timeline_media_au;
  DROP TABLE mobile_timeline_link_previews;
  DROP TABLE mobile_timeline_media;
  DELETE FROM schema_migrations WHERE version = 36;
  """

  # The append of every engine before migration 36, verbatim.
  @legacy_timeline_insert """
  INSERT INTO mobile_timeline (
    agent_id, owner_id, profile_id, server_seq, kind, role, content,
    client_msg_id, in_reply_to, media_refs_json, metadata_json, proactive_key, created_at,
    request_client_msg_id, request_attempt, output_key
  ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  """

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-mobile-store-#{unique}.db")
    repo_name = :"mobile_store_repo_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{db_path: db_path, repo: repo_name}
  end

  test "appends a profile-local timeline with durable media refs and metadata", context do
    %{db_path: db_path, repo: repo} = context

    media_refs = [
      %{
        "kind" => "image",
        "mime_type" => "image/jpeg",
        "sha256" => String.duplicate("a", 64),
        "size_bytes" => 123
      }
    ]

    assert {:ok, first} =
             Timeline.append(
               "main",
               %{
                 role: "user",
                 content: "",
                 client_msg_id: "client-1",
                 media_refs: media_refs,
                 metadata: %{"caption" => nil},
                 created_at: @now
               },
               store_opts(repo)
             )

    assert first.server_seq == 1
    assert first.content == ""
    assert first.client_msg_id == "client-1"
    assert first.media_refs == media_refs
    assert first.metadata == %{"caption" => nil}

    assert {:ok, second} =
             Timeline.append(
               "main",
               %{role: "assistant", content: "done", in_reply_to: "client-1"},
               store_opts(repo)
             )

    assert second.server_seq == 2
    assert second.in_reply_to == "client-1"

    assert {:ok, other_profile} =
             Timeline.append("work", %{role: "assistant", content: "separate"}, store_opts(repo))

    assert other_profile.server_seq == 1

    restart_repo(repo, db_path)

    assert {:ok, page} = Timeline.history_page("main", store_opts(repo, limit: 10))
    assert Enum.map(page.messages, & &1.server_seq) == [1, 2]
    assert hd(page.messages).media_refs == media_refs
    assert hd(page.messages).metadata == %{"caption" => nil}
  end

  test "client message append is exact-once across concurrent repo connections", context do
    %{db_path: db_path, repo: repo} = context
    peer_repo = start_peer_repo(db_path)

    results =
      1..16
      |> Task.async_stream(
        fn index ->
          selected_repo = if rem(index, 2) == 0, do: repo, else: peer_repo

          Timeline.append_client_message(
            "main",
            "client-timeline-once",
            %{content: "hello", media_refs: [], created_at: @now},
            store_opts(selected_repo)
          )
        end,
        max_concurrency: 16,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, {:created, _row}}, &1)) == 1
    assert Enum.count(results, &match?({:ok, {:existing, _row}}, &1)) == 15

    rows = Enum.map(results, fn {:ok, {_outcome, row}} -> row end)
    assert Enum.uniq_by(rows, & &1.server_seq) |> length() == 1
    assert hd(rows).role == "user"
    assert hd(rows).client_msg_id == "client-timeline-once"

    assert {:ok, assistant} =
             Timeline.append("main", %{role: "assistant", content: "reply"}, store_opts(repo))

    assert assistant.server_seq == 2
    assert {:ok, %{messages: messages}} = Timeline.history_page("main", store_opts(repo))
    assert Enum.map(messages, & &1.server_seq) == [1, 2]
  end

  test "media descriptor selects the latest profile-local timeline reference", %{repo: repo} do
    older = media_descriptor(%{"kind" => "image", "mime" => "image/jpeg"})

    newer =
      media_descriptor(%{
        "kind" => "document",
        "mime" => "application/pdf",
        "filename" => "answer.pdf"
      })

    assert {:ok, %{server_seq: 1}} =
             Timeline.append(
               "main",
               %{role: "assistant", content: "older", media_refs: [older]},
               store_opts(repo)
             )

    assert {:ok, %{server_seq: 2}} =
             Timeline.append(
               "main",
               %{role: "assistant", content: "unrelated", media_refs: []},
               store_opts(repo)
             )

    assert {:ok, %{server_seq: 3}} =
             Timeline.append(
               "main",
               %{role: "assistant", content: "newer", media_refs: [newer]},
               store_opts(repo)
             )

    assert {:ok, %{server_seq: 3, media: ^newer}} =
             Timeline.media_descriptor("main", @media_ref, store_opts(repo))
  end

  test "media descriptor lookup isolates profiles and reports missing refs", %{repo: repo} do
    descriptor = media_descriptor()

    assert {:ok, _row} =
             Timeline.append(
               "work",
               %{role: "user", content: "", media_refs: [descriptor]},
               store_opts(repo)
             )

    assert {:error, :not_found} =
             Timeline.media_descriptor("main", @media_ref, store_opts(repo))

    assert {:ok, %{server_seq: 1, media: ^descriptor}} =
             Timeline.media_descriptor("work", @media_ref, store_opts(repo))

    missing_ref = String.duplicate("c", 64)
    assert {:error, :not_found} = Timeline.media_descriptor("work", missing_ref, store_opts(repo))
  end

  test "media descriptor fails loud when the latest matching metadata is malformed", %{repo: repo} do
    valid = media_descriptor()
    malformed = Map.delete(valid, "mime")

    assert {:ok, _row} =
             Timeline.append(
               "main",
               %{role: "assistant", content: "valid", media_refs: [valid]},
               store_opts(repo)
             )

    assert {:ok, _row} =
             Timeline.append(
               "main",
               %{role: "assistant", content: "bad", media_refs: [malformed]},
               store_opts(repo)
             )

    assert {:error, {:malformed_media_descriptor, {:missing_field, "mime"}}} =
             Timeline.media_descriptor("main", @media_ref, store_opts(repo))
  end

  test "media descriptor remains readable across the v20 to v21 migration", context do
    %{db_path: db_path, repo: repo} = context
    descriptor = media_descriptor()

    assert {:ok, %{server_seq: 1}} =
             Timeline.append(
               "main",
               %{role: "assistant", content: "durable", media_refs: [descriptor]},
               store_opts(repo)
             )

    with_raw_conn(db_path, fn conn ->
      assert :ok =
               Sqlite3.execute(conn, """
               DROP INDEX IF EXISTS idx_mobile_timeline_client_message;
               DELETE FROM schema_migrations WHERE version = 21;
               """)
    end)

    assert {:ok, %{server_seq: 1, media: ^descriptor}} =
             Timeline.media_descriptor("main", @media_ref, store_opts(repo))

    assert :ok = Repo.migrate(server: repo)

    assert {:ok, %{server_seq: 1, media: ^descriptor}} =
             Timeline.media_descriptor("main", @media_ref, store_opts(repo))
  end

  test "pages forward by server sequence and refuses limits above 200", %{repo: repo} do
    Enum.each(1..5, fn index ->
      assert {:ok, _row} =
               Timeline.append(
                 "main",
                 %{role: "assistant", content: "message-#{index}"},
                 store_opts(repo)
               )
    end)

    assert {:ok, page} = Timeline.history_page("main", store_opts(repo, after_seq: 1, limit: 2))
    assert Enum.map(page.messages, & &1.server_seq) == [2, 3]
    assert page.next_after_seq == 3
    assert page.history_head_seq == 5

    assert {:ok, tail} =
             Timeline.history_page(
               "main",
               store_opts(repo, after_seq: page.next_after_seq, limit: 10)
             )

    assert Enum.map(tail.messages, & &1.server_seq) == [4, 5]
    assert tail.next_after_seq == 5
    assert tail.history_head_seq == 5

    assert {:ok, empty} = Timeline.history_page("empty", store_opts(repo))
    assert empty == %{history_head_seq: 0, messages: [], next_after_seq: 0}

    assert {:error, {:invalid_history_limit, 201}} =
             Timeline.history_page("main", store_opts(repo, limit: 201))
  end

  test "read frontier max-merges and remains durable across a repo restart", context do
    %{db_path: db_path, repo: repo} = context
    append_rows(repo, 12)

    assert {:ok, 8} = Timeline.advance_read_frontier("main", 8, store_opts(repo))
    assert {:ok, 8} = Timeline.advance_read_frontier("main", 3, store_opts(repo))
    assert {:ok, 11} = Timeline.advance_read_frontier("main", 11, store_opts(repo))

    restart_repo(repo, db_path)

    assert {:ok, 11} = Timeline.read_frontier("main", store_opts(repo))
  end

  # A frontier past the newest row would suppress every later push and unread
  # count, and it could never come back down: it is clamped to the head.
  test "read frontier never passes the history head", %{repo: repo} do
    assert {:ok, 0} = Timeline.advance_read_frontier("main", 5, store_opts(repo))

    append_rows(repo, 3)
    assert {:ok, 3} = Timeline.advance_read_frontier("main", 99, store_opts(repo))
    assert {:ok, 3} = Timeline.read_frontier("main", store_opts(repo))

    append_rows(repo, 2)
    assert {:ok, 5} = Timeline.advance_read_frontier("main", 5, store_opts(repo))
  end

  # A frontier an older daemon stored past the head heals on the next report.
  test "a stored frontier past the head comes back to it", %{db_path: db_path, repo: repo} do
    append_rows(repo, 2)

    with_raw_conn(db_path, fn conn ->
      :ok =
        Sqlite3.execute(conn, "UPDATE mobile_profile_state SET read_up_to_seq = 40;")
    end)

    assert {:ok, 2} = Timeline.advance_read_frontier("main", 1, store_opts(repo))
  end

  # The wire types every cursor as u64 and SQLite integers are i64: a cursor
  # past every row means nothing after it, and never reaches the Repo process.
  test "cursors beyond SQLite's integer range answer, and the Repo stays up", %{repo: repo} do
    append_rows(repo, 3)
    repo_pid = Process.whereis(repo)

    for cursor <- [@max_i64, @max_i64 + 1, @max_u64] do
      assert {:ok, %{messages: [], next_after_seq: next, history_head_seq: 3}} =
               Timeline.history_page("main", store_opts(repo, after_seq: cursor, limit: 5))

      assert next == cursor

      assert {:ok, %{messages: messages}} =
               Timeline.history_page("main", store_opts(repo, before_seq: cursor, limit: 5))

      assert Enum.map(messages, & &1.server_seq) == [1, 2, 3]

      assert {:ok, %{hits: [_ | _]}} =
               Timeline.search("main", "row", store_opts(repo, before_seq: cursor))

      assert {:ok, 3} = Timeline.advance_read_frontier("main", cursor, store_opts(repo))
    end

    assert Process.whereis(repo) == repo_pid
  end

  test "the Repo refuses an out-of-range integer in the caller", %{repo: repo} do
    repo_pid = Process.whereis(repo)
    selector = %{agent_id: "agent-a", owner_id: "owner-a", profile_id: "main"}

    assert_raise FunctionClauseError, fn ->
      Repo.get_mobile_history(selector, @max_i64 + 1, 5, server: repo)
    end

    assert_raise FunctionClauseError, fn ->
      Repo.advance_mobile_read_frontier(selector, @max_u64, @now, server: repo)
    end

    assert_raise FunctionClauseError, fn ->
      Repo.search_mobile_timeline(selector, "row", @max_i64 + 1, 5, server: repo)
    end

    assert Process.whereis(repo) == repo_pid
  end

  # A claim reads the high-water mark of earlier attempts inside the write
  # transaction; over the whole timeline that is a scan per message, so the
  # query must stay on the request-output index.
  test "a claim's prior-attempt lookup uses the output index", %{db_path: db_path, repo: repo} do
    append_rows(repo, 1)

    plan =
      with_raw_conn(db_path, fn conn ->
        {:ok, stmt} =
          Sqlite3.prepare(conn, "EXPLAIN QUERY PLAN " <> MobileSql.prior_attempt_high_water_sql())

        :ok = Sqlite3.bind(stmt, ["agent-a", "owner-a", "main", "client-1"])
        {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
        :ok = Sqlite3.release(conn, stmt)
        Enum.map_join(rows, "\n", &List.last/1)
      end)

    assert plan =~ "USING COVERING INDEX idx_mobile_request_outputs"
  end

  test "revoking a device marks every unsettled request it claimed", %{repo: repo} do
    assert {:ok, {:claimed, _request}} = claim_request(repo, "revoked-waiting")
    assert {:ok, {:claimed, _request}} = claim_request(repo, "revoked-running")
    assert {:ok, {:started, _request}} = start_request(repo, "revoked-running")
    assert {:ok, {:claimed, _request}} = claim_request(repo, "revoked-done")
    assert {:ok, {:started, _request}} = start_request(repo, "revoked-done")

    assert {:ok, _request} =
             Timeline.complete_client_request("main", "revoked-done", 1, %{}, store_opts(repo))

    other = store_opts(repo, authenticated_device_id: "device-b", now: @now)

    assert {:ok, {:claimed, _request}} =
             Timeline.claim_client_request("main", "kept", "msg", %{"a" => 1}, other)

    assert {:ok, marked} =
             Timeline.cancel_device_requests("device-a", store_opts(repo, now: at(5)))

    assert marked |> Enum.map(& &1.client_msg_id) |> Enum.sort() ==
             ["revoked-running", "revoked-waiting"]

    assert Enum.all?(marked, &(DateTime.compare(&1.cancelled_at, at(5)) == :eq))

    assert {:ok, %{cancelled_at: nil}} =
             Timeline.get_client_request("main", "kept", store_opts(repo))

    assert {:ok, %{status: "completed", cancelled_at: nil}} =
             Timeline.get_client_request("main", "revoked-done", store_opts(repo))
  end

  test "client request claims distinguish duplicate and conflicting payloads for 24 hours", %{
    repo: repo
  } do
    payload = %{"content" => "hello", "attach_ids" => []}

    assert {:ok, {:claimed, claimed}} =
             Timeline.claim_client_request(
               "main",
               "client-1",
               "msg",
               payload,
               store_opts(repo, now: @now)
             )

    assert claimed.status == "accepted"
    assert claimed.payload == payload
    assert claimed.authenticated_device_id == "device-a"
    assert claimed.attempt == 0
    assert is_nil(claimed.runner_epoch)
    assert DateTime.compare(claimed.expires_at, DateTime.add(@now, @day_seconds, :second)) == :eq

    assert {:ok, {:duplicate, duplicate}} =
             Timeline.claim_client_request(
               "main",
               "client-1",
               "msg",
               %{"attach_ids" => [], "content" => "hello"},
               store_opts(repo, now: DateTime.add(@now, 60, :second))
             )

    assert duplicate.payload_digest == claimed.payload_digest

    assert {:ok, {:conflict, conflict}} =
             Timeline.claim_client_request(
               "main",
               "client-1",
               "msg",
               %{"content" => "different"},
               store_opts(repo, now: DateTime.add(@now, 120, :second))
             )

    assert conflict.payload == payload

    expired_at = DateTime.add(@now, @day_seconds, :second)

    assert {:ok, {:claimed, replacement}} =
             Timeline.claim_client_request(
               "main",
               "client-1",
               "msg",
               %{"content" => "after-expiry"},
               store_opts(repo, now: expired_at)
             )

    assert replacement.payload == %{"content" => "after-expiry"}
    assert DateTime.compare(replacement.claimed_at, expired_at) == :eq
  end

  test "a re-claim after expiry resumes the attempt sequence above stale outputs", %{repo: repo} do
    assert {:ok, {:claimed, %{attempt: 0}}} = claim_request(repo, "client-resend")

    assert {:ok, {:started, %{attempt: 1}}} =
             Timeline.start_client_request(
               "main",
               "client-resend",
               "boot-a",
               store_opts(repo, now: at(1))
             )

    assert {:ok, {:created, stale}} =
             Timeline.append_client_output(
               "main",
               "client-resend",
               1,
               "text:final",
               %{content: "first generation", kind: "text"},
               store_opts(repo, now: at(2))
             )

    expired_at = at(@day_seconds)

    assert {:ok, {:claimed, reclaimed}} =
             Timeline.claim_client_request(
               "main",
               "client-resend",
               "msg",
               %{"content" => "same"},
               store_opts(repo, now: expired_at)
             )

    assert reclaimed.attempt == 1

    assert {:ok, {:started, %{attempt: 2}}} =
             Timeline.start_client_request(
               "main",
               "client-resend",
               "boot-b",
               store_opts(repo, now: DateTime.add(expired_at, 1, :second))
             )

    assert {:ok, {:created, fresh}} =
             Timeline.append_client_output(
               "main",
               "client-resend",
               2,
               "text:final",
               %{content: "second generation", kind: "text"},
               store_opts(repo, now: DateTime.add(expired_at, 2, :second))
             )

    assert fresh.server_seq == stale.server_seq + 1
    assert fresh.content == "second generation"

    assert {:ok, %{result_server_seq: result_seq}} =
             Timeline.get_client_request("main", "client-resend", store_opts(repo))

    assert result_seq == fresh.server_seq
  end

  test "abandoning a running attempt returns the claim to the startable state", %{repo: repo} do
    assert {:ok, {:claimed, _request}} = claim_request(repo, "client-abandon")
    assert {:ok, {:started, %{attempt: 1}}} = start_request(repo, "client-abandon")

    assert {:error, :stale_attempt} =
             Timeline.abandon_client_request(
               "main",
               "client-abandon",
               2,
               store_opts(repo, now: at(1))
             )

    assert {:ok, abandoned} =
             Timeline.abandon_client_request(
               "main",
               "client-abandon",
               1,
               store_opts(repo, now: at(2))
             )

    assert abandoned.status == "accepted"
    assert abandoned.attempt == 1
    assert is_nil(abandoned.runner_epoch)

    assert {:ok, {:started, restarted}} =
             Timeline.start_client_request(
               "main",
               "client-abandon",
               "boot-a",
               store_opts(repo, now: at(3))
             )

    assert restarted.attempt == 2
    assert restarted.runner_epoch == "boot-a"

    assert {:error, :stale_attempt} =
             Timeline.abandon_client_request(
               "main",
               "client-abandon",
               1,
               store_opts(repo, now: at(4))
             )
  end

  test "a settled request is never abandoned back into flight", %{repo: repo} do
    assert {:ok, {:claimed, _request}} = claim_request(repo, "client-settled")
    assert {:ok, {:started, %{attempt: 1}}} = start_request(repo, "client-settled")

    assert {:ok, %{status: "completed"}} =
             Timeline.complete_client_request(
               "main",
               "client-settled",
               1,
               %{},
               store_opts(repo, now: at(1))
             )

    assert {:error, :stale_attempt} =
             Timeline.abandon_client_request(
               "main",
               "client-settled",
               1,
               store_opts(repo, now: at(2))
             )

    assert {:ok, %{status: "completed"}} =
             Timeline.get_client_request("main", "client-settled", store_opts(repo))
  end

  test "a cancel marks an unsettled request once and leaves a settled one as it was", %{
    repo: repo
  } do
    assert {:ok, {:claimed, _request}} = claim_request(repo, "client-cancel")

    assert {:ok, {:marked, %{status: "accepted", cancelled_at: first}}} =
             Timeline.cancel_client_request(
               "main",
               "client-cancel",
               store_opts(repo, now: at(1))
             )

    assert DateTime.compare(first, at(1)) == :eq

    assert {:ok, {:started, %{attempt: 1, cancelled_at: ^first}}} =
             start_request(repo, "client-cancel")

    # A second cancel keeps the first mark.
    assert {:ok, {:marked, %{status: "running", cancelled_at: ^first}}} =
             Timeline.cancel_client_request(
               "main",
               "client-cancel",
               store_opts(repo, now: at(2))
             )

    # Boot recovery reads the mark on the request it would rerun.
    assert {:ok, [%{client_msg_id: "client-cancel", cancelled_at: ^first}]} =
             Timeline.recoverable_client_requests("boot-b", store_opts(repo, now: at(3)))

    assert {:ok, {:claimed, _request}} = claim_request(repo, "client-done")
    assert {:ok, {:started, %{attempt: 1}}} = start_request(repo, "client-done")

    assert {:ok, %{status: "completed"}} =
             Timeline.complete_client_request("main", "client-done", 1, %{}, store_opts(repo))

    assert {:ok, {:settled, %{status: "completed", cancelled_at: nil}}} =
             Timeline.cancel_client_request("main", "client-done", store_opts(repo))

    assert {:error, :not_found} =
             Timeline.cancel_client_request("main", "client-unknown", store_opts(repo))
  end

  test "new request claims require an authenticated device id", %{repo: repo} do
    opts =
      repo
      |> store_opts()
      |> Keyword.delete(:authenticated_device_id)

    assert {:error, {:missing_option, :authenticated_device_id}} =
             Timeline.claim_client_request(
               "main",
               "client-no-device",
               "msg",
               %{"content" => "denied"},
               opts
             )

    assert {:error, :not_found} =
             Timeline.get_client_request("main", "client-no-device", store_opts(repo))
  end

  test "concurrent request starts have one winner and the same epoch remains active", context do
    %{db_path: db_path, repo: repo} = context
    peer_repo = start_peer_repo(db_path)

    assert {:ok, {:claimed, _request}} = claim_request(repo, "client-concurrent")

    starts =
      1..16
      |> Task.async_stream(
        fn index ->
          selected_repo = if rem(index, 2) == 0, do: repo, else: peer_repo

          Timeline.start_client_request(
            "main",
            "client-concurrent",
            "boot-a",
            store_opts(selected_repo, now: @now)
          )
        end,
        max_concurrency: 16,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(starts, &match?({:ok, {:started, _row}}, &1)) == 1
    assert Enum.count(starts, &match?({:ok, {:active, _row}}, &1)) == 15

    rows = Enum.map(starts, fn {:ok, {_state, row}} -> row end)
    assert Enum.all?(rows, &(&1.attempt == 1 and &1.runner_epoch == "boot-a"))

    assert {:ok, settled} =
             Timeline.settle_client_request(
               "main",
               "client-concurrent",
               :completed,
               %{attempt: 1, turn_id: "turn-1", result_server_seq: 7},
               store_opts(repo, now: DateTime.add(@now, 5, :second))
             )

    assert settled.status == "completed"
    assert settled.turn_id == "turn-1"
    assert settled.result_server_seq == 7

    restart_repo(repo, db_path)

    assert {:ok, persisted} =
             Timeline.get_client_request("main", "client-concurrent", store_opts(repo))

    assert persisted.status == "completed"
    assert persisted.result_server_seq == 7
  end

  test "a new boot epoch recovers running work and fences stale callbacks", %{repo: repo} do
    assert {:ok, {:claimed, _request}} = claim_request(repo, "client-recover")

    assert {:ok, {:started, first}} =
             Timeline.start_client_request(
               "main",
               "client-recover",
               "boot-a",
               store_opts(repo, now: at(1))
             )

    assert first.attempt == 1

    assert {:ok, []} =
             Timeline.recoverable_client_requests(
               "boot-a",
               store_opts(repo, limit: 20, now: at(2))
             )

    assert {:ok, [recoverable]} =
             Timeline.recoverable_client_requests(
               "boot-b",
               store_opts(repo, limit: 20, now: at(2))
             )

    assert recoverable.client_msg_id == "client-recover"
    assert recoverable.payload == %{"content" => "same"}
    assert recoverable.authenticated_device_id == "device-a"

    assert {:ok, {:started, second}} =
             Timeline.start_client_request(
               "main",
               "client-recover",
               "boot-b",
               store_opts(repo, now: at(3))
             )

    assert second.attempt == 2
    assert second.runner_epoch == "boot-b"

    assert {:error, :stale_attempt} =
             Timeline.append_client_output(
               "main",
               "client-recover",
               1,
               "text:final",
               %{content: "stale"},
               store_opts(repo, now: at(4))
             )

    assert {:error, :stale_attempt} =
             Timeline.fail_client_request(
               "main",
               "client-recover",
               1,
               %{error: %{"code" => "late"}},
               store_opts(repo, now: at(4))
             )

    assert {:error, :stale_attempt} =
             Timeline.update_client_message(
               "main",
               "client-recover",
               1,
               %{content: "late transcript"},
               store_opts(repo, now: at(4))
             )

    assert {:ok, %{messages: []}} = Timeline.history_page("main", store_opts(repo))

    assert {:ok, %{status: "running", attempt: 2}} =
             Timeline.get_client_request("main", "client-recover", store_opts(repo))
  end

  test "recoverable request scan is bounded and stably ordered across profiles", %{repo: repo} do
    Enum.each([{"work", "client-z"}, {"main", "client-b"}, {"main", "client-a"}], fn
      {profile, client_id} ->
        assert {:ok, {:claimed, _row}} =
                 Timeline.claim_client_request(
                   profile,
                   client_id,
                   "msg",
                   %{"content" => client_id},
                   store_opts(repo, now: @now)
                 )
    end)

    assert {:ok, rows} =
             Timeline.recoverable_client_requests(
               "boot-a",
               store_opts(repo, limit: 2, now: at(1))
             )

    assert Enum.map(rows, &{&1.profile_id, &1.client_msg_id}) == [
             {"main", "client-a"},
             {"main", "client-b"}
           ]
  end

  test "client outputs are multi-part, fenced, and idempotent by output key", %{repo: repo} do
    assert {:ok, {:claimed, _request}} = claim_request(repo, "client-output")

    assert {:ok, {:started, %{attempt: 1}}} =
             Timeline.start_client_request(
               "main",
               "client-output",
               "boot-a",
               store_opts(repo, now: at(1))
             )

    assert {:ok, {:created, text}} =
             Timeline.append_client_output(
               "main",
               "client-output",
               1,
               "text:final",
               %{content: "answer", kind: "text"},
               store_opts(repo, now: at(2))
             )

    assert {:ok, {:existing, same_text}} =
             Timeline.append_client_output(
               "main",
               "client-output",
               1,
               "text:final",
               %{content: "ignored retry", kind: "text"},
               store_opts(repo, now: at(3))
             )

    assert same_text.server_seq == text.server_seq
    assert same_text.content == "answer"

    assert {:ok, {:created, media}} =
             Timeline.append_client_output(
               "main",
               "client-output",
               1,
               "media:#{@media_ref}",
               %{content: "file", kind: "media", media_refs: [media_descriptor()]},
               store_opts(repo, now: at(4))
             )

    assert media.server_seq == text.server_seq + 1

    assert {:ok, %{result_server_seq: result_seq, status: "running"}} =
             Timeline.get_client_request("main", "client-output", store_opts(repo))

    assert result_seq == media.server_seq

    assert {:ok, {:started, retry}} =
             Timeline.start_client_request(
               "main",
               "client-output",
               "boot-b",
               store_opts(repo, now: at(5))
             )

    assert retry.attempt == 2

    assert {:error, :stale_attempt} =
             Timeline.append_client_output(
               "main",
               "client-output",
               1,
               "text:final",
               %{content: "stale retry"},
               store_opts(repo, now: at(6))
             )

    assert {:ok, {:created, retried_text}} =
             Timeline.append_client_output(
               "main",
               "client-output",
               2,
               "text:final",
               %{content: "retry answer", kind: "text"},
               store_opts(repo, now: at(7))
             )

    assert {:ok, completed} =
             Timeline.complete_client_request(
               "main",
               "client-output",
               2,
               %{},
               store_opts(repo, now: at(8))
             )

    assert completed.status == "completed"
    assert completed.result_server_seq == retried_text.server_seq

    assert {:ok, %{messages: messages}} = Timeline.history_page("main", store_opts(repo))
    assert Enum.map(messages, & &1.content) == ["answer", "file", "retry answer"]
  end

  test "single response append and completion commit atomically", %{repo: repo} do
    assert {:ok, {:claimed, _request}} = claim_request(repo, "client-response")

    assert {:ok, {:started, %{attempt: 1}}} =
             Timeline.start_client_request(
               "main",
               "client-response",
               "boot-a",
               store_opts(repo, now: at(1))
             )

    assert {:ok, {:created, response}} =
             Timeline.append_client_response(
               "main",
               "client-response",
               1,
               %{content: "done", metadata: %{"turn_id" => "turn-1"}},
               store_opts(repo, now: at(2))
             )

    assert response.server_seq == 1
    assert response.in_reply_to == "client-response"

    assert {:ok, request} =
             Timeline.get_client_request("main", "client-response", store_opts(repo))

    assert request.status == "completed"
    assert request.result_server_seq == response.server_seq
  end

  test "running attempt enriches an audio-only user row without changing its identity", %{
    repo: repo
  } do
    assert {:ok, {:claimed, _request}} = claim_request(repo, "client-audio")

    audio_ref =
      media_descriptor(%{
        "kind" => "audio",
        "mime" => "audio/mp4",
        "filename" => "note.m4a"
      })

    assert {:ok, {:created, original}} =
             Timeline.append_client_message(
               "main",
               "client-audio",
               %{content: "", kind: "media", media_refs: [audio_ref]},
               store_opts(repo)
             )

    assert {:ok, {:started, %{attempt: 1}}} = start_request(repo, "client-audio")

    attrs = %{
      content: "[voice note transcript]\nbook the flight",
      metadata: %{"transcription" => %{"backend" => "openai"}}
    }

    assert {:ok, enriched} =
             Timeline.update_client_message(
               "main",
               "client-audio",
               1,
               attrs,
               store_opts(repo)
             )

    assert enriched.server_seq == original.server_seq
    assert enriched.role == "user"
    assert enriched.client_msg_id == "client-audio"
    assert enriched.content == attrs.content
    assert enriched.media_refs == [audio_ref]
    assert enriched.metadata == attrs.metadata

    assert {:ok, same} =
             Timeline.update_client_message(
               "main",
               "client-audio",
               1,
               attrs,
               store_opts(repo)
             )

    assert same == enriched
  end

  # STB-11: a link preview is the row's own card, stored with the row and
  # delivered by history, never an attachment the user did not send.
  test "a link preview is stored on its row, delivered by history, and authorizes its image", %{
    repo: repo
  } do
    assert {:ok, {:created, parent}} =
             Timeline.append_proactive(
               "main",
               "cron:preview",
               %{role: "assistant", content: "https://example.test"},
               store_opts(repo)
             )

    preview = link_preview()

    assert {:ok, attached} =
             Timeline.attach_link_preview("main", parent.server_seq, preview, store_opts(repo))

    assert attached.server_seq == parent.server_seq
    assert attached.content == parent.content
    assert attached.media_refs == []
    assert attached.link_previews == [preview]

    assert {:ok, same} =
             Timeline.attach_link_preview("main", parent.server_seq, preview, store_opts(repo))

    assert same == attached

    assert {:ok, %{messages: [row]}} =
             Timeline.history_page("main", store_opts(repo, after_seq: 0, limit: 1))

    assert row.link_previews == [preview]
    assert row.media_refs == []

    image = preview["image"]
    seq = parent.server_seq

    assert {:ok, %{server_seq: ^seq, media: ^image}} =
             Timeline.media_descriptor("main", @media_ref, store_opts(repo))
  end

  test "a link preview names a url, a site and a title, and a well-formed image", %{repo: repo} do
    assert {:ok, parent} =
             Timeline.append("main", %{role: "assistant", content: "x"}, store_opts(repo))

    for broken <- [
          Map.delete(link_preview(), "title"),
          Map.put(link_preview(), "site", ""),
          Map.put(link_preview(), "description", nil),
          put_in(link_preview(), ["image", "ref"], "not-a-digest")
        ] do
      assert {:error, {:invalid_link_preview, _reason}} =
               Timeline.attach_link_preview("main", parent.server_seq, broken, store_opts(repo))
    end

    without_image = Map.delete(link_preview(), "image")

    assert {:ok, %{link_previews: [^without_image]}} =
             Timeline.attach_link_preview(
               "main",
               parent.server_seq,
               without_image,
               store_opts(repo)
             )
  end

  test "a link preview on a request output from an older attempt is refused", %{repo: repo} do
    assert {:ok, {:claimed, _request}} = claim_request(repo, "client-preview")
    assert {:ok, {:started, %{attempt: 1}}} = start_request(repo, "client-preview")

    assert {:ok, {:created, output}} =
             Timeline.append_client_output(
               "main",
               "client-preview",
               1,
               "text:final",
               %{content: "preview me"},
               store_opts(repo, now: at(1))
             )

    assert {:ok, {:started, %{attempt: 2}}} =
             Timeline.start_client_request(
               "main",
               "client-preview",
               "boot-b",
               store_opts(repo, now: at(2))
             )

    assert {:error, :stale_attempt} =
             Timeline.attach_link_preview(
               "main",
               output.server_seq,
               link_preview(),
               store_opts(repo)
             )

    assert {:error, :not_found} =
             Timeline.media_descriptor("main", @media_ref, store_opts(repo))
  end

  # PERF-4: media_fetch authorizes a ref on every image the phone opens; it
  # must be one index lookup, never a scan of the profile's whole timeline.
  test "a media ref is authorized through the media index, never a timeline scan", %{
    db_path: db_path,
    repo: repo
  } do
    assert {:ok, _row} =
             Timeline.append(
               "main",
               %{role: "user", content: "", media_refs: [media_descriptor()]},
               store_opts(repo)
             )

    plan =
      with_raw_conn(db_path, fn conn ->
        {:ok, stmt} =
          Sqlite3.prepare(conn, "EXPLAIN QUERY PLAN " <> MobileSql.media_descriptor_sql())

        :ok = Sqlite3.bind(stmt, ["agent-a", "owner-a", "main", @media_ref])
        {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
        :ok = Sqlite3.release(conn, stmt)
        Enum.map_join(rows, "\n", &List.last/1)
      end)

    assert plan =~ "USING COVERING INDEX idx_mobile_timeline_media_ref"
    refute plan =~ "TEMP B-TREE"
    refute plan =~ "SCAN"
  end

  test "a user row whose media refs are rewritten answers for its new refs only", %{repo: repo} do
    assert {:ok, {:claimed, _request}} = claim_request(repo, "client-swap")
    old_ref = String.duplicate("c", 64)

    assert {:ok, {:created, original}} =
             Timeline.append_client_message(
               "main",
               "client-swap",
               %{
                 content: "",
                 kind: "media",
                 media_refs: [media_descriptor(%{"ref" => old_ref, "sha256" => old_ref})]
               },
               store_opts(repo)
             )

    assert {:ok, %{server_seq: seq}} =
             Timeline.media_descriptor("main", old_ref, store_opts(repo))

    assert seq == original.server_seq
    assert {:ok, {:started, %{attempt: 1}}} = start_request(repo, "client-swap")

    assert {:ok, _updated} =
             Timeline.update_client_message(
               "main",
               "client-swap",
               1,
               %{media_refs: [media_descriptor()]},
               store_opts(repo)
             )

    assert {:error, :not_found} = Timeline.media_descriptor("main", old_ref, store_opts(repo))

    assert {:ok, %{server_seq: ^seq}} =
             Timeline.media_descriptor("main", @media_ref, store_opts(repo))
  end

  # Migration 36 runs on every install: the index is backfilled from the rows
  # already written, and every row reads an empty preview list.
  test "the media index migration backfills a database written before it", context do
    %{db_path: db_path, repo: repo} = context
    descriptor = media_descriptor()

    assert {:ok, %{server_seq: 1}} =
             Timeline.append(
               "main",
               %{role: "assistant", content: "before", media_refs: [descriptor]},
               store_opts(repo)
             )

    stop_supervised!(Repo)
    refs_json = Jason.encode!([%{"kind" => "image"}, 7, "text", descriptor])

    with_raw_conn(db_path, fn conn ->
      assert :ok =
               Sqlite3.execute(conn, """
               #{@rewind_media_index_migration}
               INSERT INTO mobile_timeline (
                 agent_id, owner_id, profile_id, server_seq, kind, role, content,
                 media_refs_json, created_at
               ) VALUES (
                 'agent-a', 'owner-a', 'main', 2, 'media', 'user', '',
                 '#{refs_json}',
                 '2026-08-12T12:00:01.000000Z'
               );
               UPDATE mobile_profile_state SET next_server_seq = 3;
               """)
    end)

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    assert {:ok, versions} = Repo.migration_versions(server: repo)
    assert 36 in versions

    assert {:ok, %{server_seq: 2, media: ^descriptor}} =
             Timeline.media_descriptor("main", @media_ref, store_opts(repo))

    assert {:ok, %{messages: rows}} = Timeline.history_page("main", store_opts(repo))
    assert Enum.map(rows, & &1.link_previews) == [[], []]

    with_raw_conn(db_path, fn conn ->
      assert {:ok, [[2]]} = fetch_all(conn, "SELECT COUNT(*) FROM mobile_timeline_media")
    end)

    assert :ok = Repo.migrate(server: repo)

    with_raw_conn(db_path, fn conn ->
      assert {:ok, [[2]]} = fetch_all(conn, "SELECT COUNT(*) FROM mobile_timeline_media")
    end)
  end

  # R5-2: every engine before migration 36 decodes a timeline row by position,
  # from `SELECT *` and `RETURNING *`, into exactly sixteen columns, and a
  # request row into nineteen. After a rollback it opens the database this
  # engine migrated, so the migration adds no column to either table.
  test "a database migrated to 36 is still read by an engine that decodes the old columns",
       context do
    %{db_path: db_path, repo: repo} = context

    assert {:ok, parent} =
             Timeline.append(
               "main",
               %{role: "assistant", content: "https://example.test/post"},
               store_opts(repo)
             )

    assert {:ok, _row} =
             Timeline.attach_link_preview(
               "main",
               parent.server_seq,
               link_preview(),
               store_opts(repo)
             )

    assert {:ok, {:claimed, _request}} = claim_request(repo, "client-legacy")

    assert {:ok, {:created, _row}} =
             Timeline.append_client_message(
               "main",
               "client-legacy",
               %{content: "", kind: "media", media_refs: [media_descriptor()]},
               store_opts(repo)
             )

    assert legacy_rows(db_path) == {[1, 2], ["client-legacy"]}

    # A database written before migration 36, upgraded by this engine.
    with_raw_conn(db_path, fn conn ->
      assert :ok = Sqlite3.execute(conn, @rewind_media_index_migration)

      assert :ok =
               raw_execute(conn, @legacy_timeline_insert, legacy_row(3, [media_descriptor()]))

      assert :ok = Sqlite3.execute(conn, "UPDATE mobile_profile_state SET next_server_seq = 4;")
    end)

    assert :ok = Repo.migrate(server: repo)
    assert legacy_rows(db_path) == {[1, 2, 3], ["client-legacy"]}

    assert {:ok, %{messages: [%{link_previews: []} | _rest]}} =
             Timeline.history_page("main", store_opts(repo))
  end

  # R5-2: the media index is kept in the statement that writes a row's refs,
  # so the rows an older engine writes after a rollback are indexed as they are
  # written, and an upgrade back finds every ref it named.
  test "media an older engine writes after the migration stays authorized", context do
    %{db_path: db_path, repo: repo} = context
    replaced = String.duplicate("c", 64)
    written = String.duplicate("d", 64)

    assert {:ok, %{server_seq: 1}} =
             Timeline.append(
               "main",
               %{
                 role: "user",
                 content: "",
                 media_refs: [media_descriptor(%{"ref" => replaced, "sha256" => replaced})]
               },
               store_opts(repo)
             )

    with_raw_conn(db_path, fn conn ->
      written_refs = [media_descriptor(%{"ref" => written, "sha256" => written})]
      assert :ok = raw_execute(conn, @legacy_timeline_insert, legacy_row(2, written_refs))
      assert :ok = Sqlite3.execute(conn, "UPDATE mobile_profile_state SET next_server_seq = 3;")

      # The older engine's link-preview path rewrote a row's media refs in place.
      assert {:ok, [row]} =
               raw_query(
                 conn,
                 """
                 UPDATE mobile_timeline SET media_refs_json = ?
                 WHERE agent_id = 'agent-a' AND owner_id = 'owner-a' AND profile_id = 'main'
                   AND server_seq = 1
                 RETURNING *
                 """,
                 [Jason.encode!([media_descriptor()])]
               )

      assert length(row) == 16
    end)

    assert {:ok, %{server_seq: 2}} = Timeline.media_descriptor("main", written, store_opts(repo))

    assert {:ok, %{server_seq: 1}} =
             Timeline.media_descriptor("main", @media_ref, store_opts(repo))

    assert {:error, :not_found} = Timeline.media_descriptor("main", replaced, store_opts(repo))
  end

  test "terminal requests never recover or restart", %{repo: repo} do
    assert {:ok, {:claimed, _request}} = claim_request(repo, "client-completed")
    assert {:ok, {:started, %{attempt: 1}}} = start_request(repo, "client-completed")

    assert {:ok, %{status: "completed"}} =
             Timeline.complete_client_request(
               "main",
               "client-completed",
               1,
               %{},
               store_opts(repo, now: at(1))
             )

    assert {:ok, {:completed, %{attempt: 1}}} =
             Timeline.start_client_request(
               "main",
               "client-completed",
               "boot-b",
               store_opts(repo, now: at(2))
             )

    assert {:ok, {:claimed, _request}} = claim_request(repo, "client-failed")
    assert {:ok, {:started, %{attempt: 1}}} = start_request(repo, "client-failed")

    assert {:ok, %{status: "failed"}} =
             Timeline.settle_client_request(
               "main",
               "client-failed",
               :failed,
               %{attempt: 1, error: %{"code" => "gateway_failed"}},
               store_opts(repo, now: at(3))
             )

    assert {:ok, {:failed, %{attempt: 1}}} =
             Timeline.start_client_request(
               "main",
               "client-failed",
               "boot-b",
               store_opts(repo, now: at(4))
             )

    assert {:ok, []} =
             Timeline.recoverable_client_requests(
               "boot-b",
               store_opts(repo, limit: 200, now: at(5))
             )

    assert {:error, {:invalid_recovery_limit, 201}} =
             Timeline.recoverable_client_requests(
               "boot-b",
               store_opts(repo, limit: 201, now: at(5))
             )
  end

  test "proactive output dedupe inserts one durable row and returns it thereafter", context do
    %{db_path: db_path, repo: repo} = context
    peer_repo = start_peer_repo(db_path)
    opts = store_opts(repo)

    results =
      1..12
      |> Task.async_stream(
        fn index ->
          selected_repo = if rem(index, 2) == 0, do: repo, else: peer_repo

          Timeline.append_proactive(
            "main",
            "cron:daily:2026-08-12",
            %{role: "assistant", content: "daily summary", created_at: @now},
            store_opts(selected_repo)
          )
        end,
        max_concurrency: 12,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, {:created, _row}}, &1)) == 1
    assert Enum.count(results, &match?({:ok, {:existing, _row}}, &1)) == 11

    rows = Enum.map(results, fn {:ok, {_result, row}} -> row end)
    assert Enum.uniq_by(rows, & &1.server_seq) |> length() == 1

    restart_repo(repo, db_path)

    assert {:ok, {:existing, %{server_seq: 1}}} =
             Timeline.append_proactive(
               "main",
               "cron:daily:2026-08-12",
               %{role: "assistant", content: "daily summary", created_at: @now},
               opts
             )

    assert {:ok, second} =
             Timeline.append_proactive(
               "main",
               "cron:daily:2026-08-13",
               %{role: "assistant", content: "next summary", created_at: @now},
               opts
             )

    assert {:created, %{server_seq: 2}} = second
  end

  defp store_opts(repo, extra \\ []) do
    Keyword.merge(
      [
        repo: repo,
        agent_id: "agent-a",
        owner_id: "owner-a",
        transport: "mobile",
        authenticated_device_id: "device-a"
      ],
      extra
    )
  end

  defp append_rows(repo, count) do
    Enum.each(1..count, fn index ->
      assert {:ok, _row} =
               Timeline.append(
                 "main",
                 %{role: "assistant", content: "row #{index}"},
                 store_opts(repo)
               )
    end)
  end

  defp at(offset_seconds) when is_integer(offset_seconds) do
    DateTime.add(@now, offset_seconds, :second)
  end

  defp claim_request(repo, client_msg_id) do
    Timeline.claim_client_request(
      "main",
      client_msg_id,
      "msg",
      %{"content" => "same"},
      store_opts(repo, now: @now)
    )
  end

  defp start_request(repo, client_msg_id) do
    Timeline.start_client_request("main", client_msg_id, "boot-a", store_opts(repo, now: @now))
  end

  defp restart_repo(repo, db_path) do
    stop_supervised(Repo)
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})
  end

  defp start_peer_repo(db_path) do
    unique = System.unique_integer([:positive])
    repo = :"mobile_store_peer_repo_#{unique}"

    {Repo, name: repo, enabled: true, database_path: db_path}
    |> Supervisor.child_spec(id: repo)
    |> start_supervised!()

    repo
  end

  defp link_preview do
    %{
      "url" => "https://example.test/post",
      "site" => "Example",
      "title" => "A post",
      "description" => "What it says",
      "image" => media_descriptor(%{"kind" => "image", "mime" => "image/webp", "size_bytes" => 9})
    }
  end

  defp fetch_all(conn, sql) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    result = Sqlite3.fetch_all(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    result
  end

  defp media_descriptor(overrides \\ %{}) do
    Map.merge(
      %{
        "ref" => @media_ref,
        "sha256" => @media_ref,
        "kind" => "image",
        "mime" => "image/jpeg",
        "size_bytes" => 123
      },
      overrides
    )
  end

  # A row as the pre-36 engine's append binds it, for `@legacy_timeline_insert`.
  defp legacy_row(server_seq, media_refs) do
    ["agent-a", "owner-a", "main", server_seq, "media", "user", "", nil, nil] ++
      [Jason.encode!(media_refs), nil, nil, "2026-08-12T12:00:0#{server_seq}.000000Z"] ++
      [nil, nil, nil]
  end

  # Every row as the pre-36 engine reads it: `SELECT *` decoded by one clause
  # of exactly sixteen timeline columns, and of nineteen request columns.
  defp legacy_rows(db_path) do
    with_raw_conn(db_path, fn conn ->
      {:ok, timeline} = fetch_all(conn, "SELECT * FROM mobile_timeline ORDER BY server_seq")
      {:ok, requests} = fetch_all(conn, "SELECT * FROM mobile_client_requests")
      {Enum.map(timeline, &legacy_timeline_seq/1), Enum.map(requests, &legacy_request_id/1)}
    end)
  end

  defp legacy_timeline_seq([
         _agent_id,
         _owner_id,
         _profile_id,
         server_seq,
         _kind,
         _role,
         _content,
         _client_msg_id,
         _in_reply_to,
         media_refs_json,
         _metadata_json,
         _proactive_key,
         _created_at,
         _request_client_msg_id,
         _request_attempt,
         _output_key
       ]) do
    _media_refs = Jason.decode!(media_refs_json)
    server_seq
  end

  defp legacy_request_id([
         _agent_id,
         _owner_id,
         _profile_id,
         client_msg_id,
         _request_type,
         _status,
         _payload_digest,
         _payload_json,
         _turn_id,
         _result_server_seq,
         _error_json,
         _claimed_at,
         _expires_at,
         _updated_at,
         _authenticated_device_id,
         _runner_epoch,
         _attempt,
         _transport,
         _cancelled_at
       ]),
       do: client_msg_id

  defp raw_execute(conn, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    :ok = Sqlite3.bind(stmt, params)
    result = Sqlite3.step(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    if result == :done, do: :ok, else: result
  end

  defp raw_query(conn, sql, params) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    :ok = Sqlite3.bind(stmt, params)
    result = Sqlite3.fetch_all(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    result
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
