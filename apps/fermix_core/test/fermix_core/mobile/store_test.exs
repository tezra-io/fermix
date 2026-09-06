defmodule FermixCore.Mobile.StoreTest do
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.Memory.Repo
  alias FermixCore.Mobile.Store

  @now ~U[2026-08-12 12:00:00Z]
  @day_seconds 86_400
  @media_ref String.duplicate("b", 64)

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
             Store.append(
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
             Store.append(
               "main",
               %{role: "assistant", content: "done", in_reply_to: "client-1"},
               store_opts(repo)
             )

    assert second.server_seq == 2
    assert second.in_reply_to == "client-1"

    assert {:ok, other_profile} =
             Store.append("work", %{role: "assistant", content: "separate"}, store_opts(repo))

    assert other_profile.server_seq == 1

    restart_repo(repo, db_path)

    assert {:ok, page} = Store.history_page("main", store_opts(repo, limit: 10))
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

          Store.append_client_message(
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
             Store.append("main", %{role: "assistant", content: "reply"}, store_opts(repo))

    assert assistant.server_seq == 2
    assert {:ok, %{messages: messages}} = Store.history_page("main", store_opts(repo))
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
             Store.append(
               "main",
               %{role: "assistant", content: "older", media_refs: [older]},
               store_opts(repo)
             )

    assert {:ok, %{server_seq: 2}} =
             Store.append(
               "main",
               %{role: "assistant", content: "unrelated", media_refs: []},
               store_opts(repo)
             )

    assert {:ok, %{server_seq: 3}} =
             Store.append(
               "main",
               %{role: "assistant", content: "newer", media_refs: [newer]},
               store_opts(repo)
             )

    assert {:ok, %{server_seq: 3, media: ^newer}} =
             Store.media_descriptor("main", @media_ref, store_opts(repo))
  end

  test "media descriptor lookup isolates profiles and reports missing refs", %{repo: repo} do
    descriptor = media_descriptor()

    assert {:ok, _row} =
             Store.append(
               "work",
               %{role: "user", content: "", media_refs: [descriptor]},
               store_opts(repo)
             )

    assert {:error, :not_found} =
             Store.media_descriptor("main", @media_ref, store_opts(repo))

    assert {:ok, %{server_seq: 1, media: ^descriptor}} =
             Store.media_descriptor("work", @media_ref, store_opts(repo))

    missing_ref = String.duplicate("c", 64)
    assert {:error, :not_found} = Store.media_descriptor("work", missing_ref, store_opts(repo))
  end

  test "media descriptor fails loud when the latest matching metadata is malformed", %{repo: repo} do
    valid = media_descriptor()
    malformed = Map.delete(valid, "mime")

    assert {:ok, _row} =
             Store.append(
               "main",
               %{role: "assistant", content: "valid", media_refs: [valid]},
               store_opts(repo)
             )

    assert {:ok, _row} =
             Store.append(
               "main",
               %{role: "assistant", content: "bad", media_refs: [malformed]},
               store_opts(repo)
             )

    assert {:error, {:malformed_media_descriptor, {:missing_field, "mime"}}} =
             Store.media_descriptor("main", @media_ref, store_opts(repo))
  end

  test "media descriptor remains readable across the v20 to v21 migration", context do
    %{db_path: db_path, repo: repo} = context
    descriptor = media_descriptor()

    assert {:ok, %{server_seq: 1}} =
             Store.append(
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
             Store.media_descriptor("main", @media_ref, store_opts(repo))

    assert :ok = Repo.migrate(server: repo)

    assert {:ok, %{server_seq: 1, media: ^descriptor}} =
             Store.media_descriptor("main", @media_ref, store_opts(repo))
  end

  test "pages forward by server sequence and refuses limits above 200", %{repo: repo} do
    Enum.each(1..5, fn index ->
      assert {:ok, _row} =
               Store.append(
                 "main",
                 %{role: "assistant", content: "message-#{index}"},
                 store_opts(repo)
               )
    end)

    assert {:ok, page} = Store.history_page("main", store_opts(repo, after_seq: 1, limit: 2))
    assert Enum.map(page.messages, & &1.server_seq) == [2, 3]
    assert page.next_after_seq == 3
    assert page.history_head_seq == 5

    assert {:ok, tail} =
             Store.history_page(
               "main",
               store_opts(repo, after_seq: page.next_after_seq, limit: 10)
             )

    assert Enum.map(tail.messages, & &1.server_seq) == [4, 5]
    assert tail.next_after_seq == 5
    assert tail.history_head_seq == 5

    assert {:ok, empty} = Store.history_page("empty", store_opts(repo))
    assert empty == %{history_head_seq: 0, messages: [], next_after_seq: 0}

    assert {:error, {:invalid_history_limit, 201}} =
             Store.history_page("main", store_opts(repo, limit: 201))
  end

  test "read frontier max-merges and remains durable across a repo restart", context do
    %{db_path: db_path, repo: repo} = context

    assert {:ok, 8} = Store.advance_read_frontier("main", 8, store_opts(repo))
    assert {:ok, 8} = Store.advance_read_frontier("main", 3, store_opts(repo))
    assert {:ok, 11} = Store.advance_read_frontier("main", 11, store_opts(repo))

    restart_repo(repo, db_path)

    assert {:ok, 11} = Store.read_frontier("main", store_opts(repo))
  end

  test "client request claims distinguish duplicate and conflicting payloads for 24 hours", %{
    repo: repo
  } do
    payload = %{"content" => "hello", "attach_ids" => []}

    assert {:ok, {:claimed, claimed}} =
             Store.claim_client_request(
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
             Store.claim_client_request(
               "main",
               "client-1",
               "msg",
               %{"attach_ids" => [], "content" => "hello"},
               store_opts(repo, now: DateTime.add(@now, 60, :second))
             )

    assert duplicate.payload_digest == claimed.payload_digest

    assert {:ok, {:conflict, conflict}} =
             Store.claim_client_request(
               "main",
               "client-1",
               "msg",
               %{"content" => "different"},
               store_opts(repo, now: DateTime.add(@now, 120, :second))
             )

    assert conflict.payload == payload

    expired_at = DateTime.add(@now, @day_seconds, :second)

    assert {:ok, {:claimed, replacement}} =
             Store.claim_client_request(
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
             Store.start_client_request(
               "main",
               "client-resend",
               "boot-a",
               store_opts(repo, now: at(1))
             )

    assert {:ok, {:created, stale}} =
             Store.append_client_output(
               "main",
               "client-resend",
               1,
               "text:final",
               %{content: "first generation", kind: "text"},
               store_opts(repo, now: at(2))
             )

    expired_at = at(@day_seconds)

    assert {:ok, {:claimed, reclaimed}} =
             Store.claim_client_request(
               "main",
               "client-resend",
               "msg",
               %{"content" => "same"},
               store_opts(repo, now: expired_at)
             )

    assert reclaimed.attempt == 1

    assert {:ok, {:started, %{attempt: 2}}} =
             Store.start_client_request(
               "main",
               "client-resend",
               "boot-b",
               store_opts(repo, now: DateTime.add(expired_at, 1, :second))
             )

    assert {:ok, {:created, fresh}} =
             Store.append_client_output(
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
             Store.get_client_request("main", "client-resend", store_opts(repo))

    assert result_seq == fresh.server_seq
  end

  test "abandoning a running attempt returns the claim to the startable state", %{repo: repo} do
    assert {:ok, {:claimed, _request}} = claim_request(repo, "client-abandon")
    assert {:ok, {:started, %{attempt: 1}}} = start_request(repo, "client-abandon")

    assert {:error, :stale_attempt} =
             Store.abandon_client_request(
               "main",
               "client-abandon",
               2,
               store_opts(repo, now: at(1))
             )

    assert {:ok, abandoned} =
             Store.abandon_client_request(
               "main",
               "client-abandon",
               1,
               store_opts(repo, now: at(2))
             )

    assert abandoned.status == "accepted"
    assert abandoned.attempt == 1
    assert is_nil(abandoned.runner_epoch)

    assert {:ok, {:started, restarted}} =
             Store.start_client_request(
               "main",
               "client-abandon",
               "boot-a",
               store_opts(repo, now: at(3))
             )

    assert restarted.attempt == 2
    assert restarted.runner_epoch == "boot-a"

    assert {:error, :stale_attempt} =
             Store.abandon_client_request(
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
             Store.complete_client_request(
               "main",
               "client-settled",
               1,
               %{},
               store_opts(repo, now: at(1))
             )

    assert {:error, :stale_attempt} =
             Store.abandon_client_request(
               "main",
               "client-settled",
               1,
               store_opts(repo, now: at(2))
             )

    assert {:ok, %{status: "completed"}} =
             Store.get_client_request("main", "client-settled", store_opts(repo))
  end

  test "new request claims require an authenticated device id", %{repo: repo} do
    opts =
      repo
      |> store_opts()
      |> Keyword.delete(:authenticated_device_id)

    assert {:error, {:missing_option, :authenticated_device_id}} =
             Store.claim_client_request(
               "main",
               "client-no-device",
               "msg",
               %{"content" => "denied"},
               opts
             )

    assert {:error, :not_found} =
             Store.get_client_request("main", "client-no-device", store_opts(repo))
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

          Store.start_client_request(
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
             Store.settle_client_request(
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
             Store.get_client_request("main", "client-concurrent", store_opts(repo))

    assert persisted.status == "completed"
    assert persisted.result_server_seq == 7
  end

  test "a new boot epoch recovers running work and fences stale callbacks", %{repo: repo} do
    assert {:ok, {:claimed, _request}} = claim_request(repo, "client-recover")

    assert {:ok, {:started, first}} =
             Store.start_client_request(
               "main",
               "client-recover",
               "boot-a",
               store_opts(repo, now: at(1))
             )

    assert first.attempt == 1

    assert {:ok, []} =
             Store.recoverable_client_requests("boot-a", store_opts(repo, limit: 20, now: at(2)))

    assert {:ok, [recoverable]} =
             Store.recoverable_client_requests("boot-b", store_opts(repo, limit: 20, now: at(2)))

    assert recoverable.client_msg_id == "client-recover"
    assert recoverable.payload == %{"content" => "same"}
    assert recoverable.authenticated_device_id == "device-a"

    assert {:ok, {:started, second}} =
             Store.start_client_request(
               "main",
               "client-recover",
               "boot-b",
               store_opts(repo, now: at(3))
             )

    assert second.attempt == 2
    assert second.runner_epoch == "boot-b"

    assert {:error, :stale_attempt} =
             Store.append_client_output(
               "main",
               "client-recover",
               1,
               "text:final",
               %{content: "stale"},
               store_opts(repo, now: at(4))
             )

    assert {:error, :stale_attempt} =
             Store.fail_client_request(
               "main",
               "client-recover",
               1,
               %{error: %{"code" => "late"}},
               store_opts(repo, now: at(4))
             )

    assert {:error, :stale_attempt} =
             Store.update_client_message(
               "main",
               "client-recover",
               1,
               %{content: "late transcript"},
               store_opts(repo, now: at(4))
             )

    assert {:ok, %{messages: []}} = Store.history_page("main", store_opts(repo))

    assert {:ok, %{status: "running", attempt: 2}} =
             Store.get_client_request("main", "client-recover", store_opts(repo))
  end

  test "recoverable request scan is bounded and stably ordered across profiles", %{repo: repo} do
    Enum.each([{"work", "client-z"}, {"main", "client-b"}, {"main", "client-a"}], fn
      {profile, client_id} ->
        assert {:ok, {:claimed, _row}} =
                 Store.claim_client_request(
                   profile,
                   client_id,
                   "msg",
                   %{"content" => client_id},
                   store_opts(repo, now: @now)
                 )
    end)

    assert {:ok, rows} =
             Store.recoverable_client_requests("boot-a", store_opts(repo, limit: 2, now: at(1)))

    assert Enum.map(rows, &{&1.profile_id, &1.client_msg_id}) == [
             {"main", "client-a"},
             {"main", "client-b"}
           ]
  end

  test "client outputs are multi-part, fenced, and idempotent by output key", %{repo: repo} do
    assert {:ok, {:claimed, _request}} = claim_request(repo, "client-output")

    assert {:ok, {:started, %{attempt: 1}}} =
             Store.start_client_request(
               "main",
               "client-output",
               "boot-a",
               store_opts(repo, now: at(1))
             )

    assert {:ok, {:created, text}} =
             Store.append_client_output(
               "main",
               "client-output",
               1,
               "text:final",
               %{content: "answer", kind: "text"},
               store_opts(repo, now: at(2))
             )

    assert {:ok, {:existing, same_text}} =
             Store.append_client_output(
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
             Store.append_client_output(
               "main",
               "client-output",
               1,
               "media:#{@media_ref}",
               %{content: "file", kind: "media", media_refs: [media_descriptor()]},
               store_opts(repo, now: at(4))
             )

    assert media.server_seq == text.server_seq + 1

    assert {:ok, %{result_server_seq: result_seq, status: "running"}} =
             Store.get_client_request("main", "client-output", store_opts(repo))

    assert result_seq == media.server_seq

    assert {:ok, {:started, retry}} =
             Store.start_client_request(
               "main",
               "client-output",
               "boot-b",
               store_opts(repo, now: at(5))
             )

    assert retry.attempt == 2

    assert {:error, :stale_attempt} =
             Store.append_client_output(
               "main",
               "client-output",
               1,
               "text:final",
               %{content: "stale retry"},
               store_opts(repo, now: at(6))
             )

    assert {:ok, {:created, retried_text}} =
             Store.append_client_output(
               "main",
               "client-output",
               2,
               "text:final",
               %{content: "retry answer", kind: "text"},
               store_opts(repo, now: at(7))
             )

    assert {:ok, completed} =
             Store.complete_client_request(
               "main",
               "client-output",
               2,
               %{},
               store_opts(repo, now: at(8))
             )

    assert completed.status == "completed"
    assert completed.result_server_seq == retried_text.server_seq

    assert {:ok, %{messages: messages}} = Store.history_page("main", store_opts(repo))
    assert Enum.map(messages, & &1.content) == ["answer", "file", "retry answer"]
  end

  test "single response append and completion commit atomically", %{repo: repo} do
    assert {:ok, {:claimed, _request}} = claim_request(repo, "client-response")

    assert {:ok, {:started, %{attempt: 1}}} =
             Store.start_client_request(
               "main",
               "client-response",
               "boot-a",
               store_opts(repo, now: at(1))
             )

    assert {:ok, {:created, response}} =
             Store.append_client_response(
               "main",
               "client-response",
               1,
               %{content: "done", metadata: %{"turn_id" => "turn-1"}},
               store_opts(repo, now: at(2))
             )

    assert response.server_seq == 1
    assert response.in_reply_to == "client-response"

    assert {:ok, request} =
             Store.get_client_request("main", "client-response", store_opts(repo))

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
             Store.append_client_message(
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
             Store.update_client_message(
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
             Store.update_client_message(
               "main",
               "client-audio",
               1,
               attrs,
               store_opts(repo)
             )

    assert same == enriched
  end

  test "timeline media attachment authorizes a thumbnail without changing its parent row", %{
    repo: repo
  } do
    assert {:ok, {:created, parent}} =
             Store.append_proactive(
               "main",
               "cron:preview",
               %{role: "assistant", content: "https://example.test"},
               store_opts(repo)
             )

    thumbnail =
      media_descriptor(%{
        "kind" => "image",
        "mime" => "image/webp",
        "filename" => "preview.webp"
      })

    assert {:ok, attached} =
             Store.attach_timeline_media(
               "main",
               parent.server_seq,
               thumbnail,
               store_opts(repo)
             )

    assert attached.server_seq == parent.server_seq
    assert attached.content == parent.content
    assert attached.media_refs == [thumbnail]

    assert {:ok, same} =
             Store.attach_timeline_media(
               "main",
               parent.server_seq,
               thumbnail,
               store_opts(repo)
             )

    assert same == attached

    assert {:ok, %{server_seq: seq, media: ^thumbnail}} =
             Store.media_descriptor("main", @media_ref, store_opts(repo))

    assert seq == parent.server_seq
  end

  test "timeline media attachment rejects a request output from an older attempt", %{repo: repo} do
    assert {:ok, {:claimed, _request}} = claim_request(repo, "client-preview")
    assert {:ok, {:started, %{attempt: 1}}} = start_request(repo, "client-preview")

    assert {:ok, {:created, output}} =
             Store.append_client_output(
               "main",
               "client-preview",
               1,
               "text:final",
               %{content: "preview me"},
               store_opts(repo, now: at(1))
             )

    assert {:ok, {:started, %{attempt: 2}}} =
             Store.start_client_request(
               "main",
               "client-preview",
               "boot-b",
               store_opts(repo, now: at(2))
             )

    assert {:error, :stale_attempt} =
             Store.attach_timeline_media(
               "main",
               output.server_seq,
               media_descriptor(),
               store_opts(repo)
             )

    assert {:error, :not_found} =
             Store.media_descriptor("main", @media_ref, store_opts(repo))
  end

  test "terminal requests never recover or restart", %{repo: repo} do
    assert {:ok, {:claimed, _request}} = claim_request(repo, "client-completed")
    assert {:ok, {:started, %{attempt: 1}}} = start_request(repo, "client-completed")

    assert {:ok, %{status: "completed"}} =
             Store.complete_client_request(
               "main",
               "client-completed",
               1,
               %{},
               store_opts(repo, now: at(1))
             )

    assert {:ok, {:completed, %{attempt: 1}}} =
             Store.start_client_request(
               "main",
               "client-completed",
               "boot-b",
               store_opts(repo, now: at(2))
             )

    assert {:ok, {:claimed, _request}} = claim_request(repo, "client-failed")
    assert {:ok, {:started, %{attempt: 1}}} = start_request(repo, "client-failed")

    assert {:ok, %{status: "failed"}} =
             Store.settle_client_request(
               "main",
               "client-failed",
               :failed,
               %{attempt: 1, error: %{"code" => "gateway_failed"}},
               store_opts(repo, now: at(3))
             )

    assert {:ok, {:failed, %{attempt: 1}}} =
             Store.start_client_request(
               "main",
               "client-failed",
               "boot-b",
               store_opts(repo, now: at(4))
             )

    assert {:ok, []} =
             Store.recoverable_client_requests("boot-b", store_opts(repo, limit: 200, now: at(5)))

    assert {:error, {:invalid_recovery_limit, 201}} =
             Store.recoverable_client_requests("boot-b", store_opts(repo, limit: 201, now: at(5)))
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

          Store.append_proactive(
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
             Store.append_proactive(
               "main",
               "cron:daily:2026-08-12",
               %{role: "assistant", content: "daily summary", created_at: @now},
               opts
             )

    assert {:ok, second} =
             Store.append_proactive(
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
        authenticated_device_id: "device-a"
      ],
      extra
    )
  end

  defp at(offset_seconds) when is_integer(offset_seconds) do
    DateTime.add(@now, offset_seconds, :second)
  end

  defp claim_request(repo, client_msg_id) do
    Store.claim_client_request(
      "main",
      client_msg_id,
      "msg",
      %{"content" => "same"},
      store_opts(repo, now: @now)
    )
  end

  defp start_request(repo, client_msg_id) do
    Store.start_client_request("main", client_msg_id, "boot-a", store_opts(repo, now: @now))
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
