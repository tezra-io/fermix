defmodule FermixCore.Companion.ProtocolTest do
  use ExUnit.Case, async: true

  alias FermixCore.Companion.Protocol

  test "publishes the version window, the line cap and the ordered catalogs" do
    assert Protocol.protocol_version() == 6
    assert Protocol.supported_version_range() == {5, 6}
    assert Protocol.max_line_bytes() == 65_536

    assert Protocol.client_events() ==
             ~w(client_hello msg command cancel history_pull history_search read_state
                media_fetch media_release proposal_answer checklists_pull checklist_pull
                checklist_edit)

    assert Protocol.server_events() ==
             ~w(server_hello accepted turn_started text_delta tool_event reasoning text_done
                turn_error turn_done row row_updated approval approval_resolved read_state
                history_page search_results media_path media_missing proposal proposal_resolved
                home_status_changed checklists checklist error)
  end

  # M56 §6: a turn that ends with no reply needs a frame an older client would
  # not survive, so it goes only to a connection that declared version 2; the
  # media grant and the changed row (M66) only to one that declared 3; what a
  # turn is reasoning and the owner's lists (M85) only to one that declared 6.
  test "every server event names the version that brought it" do
    later = %{
      "turn_done" => 2,
      "row_updated" => 3,
      "media_path" => 3,
      "media_missing" => 3,
      "proposal" => 4,
      "proposal_resolved" => 4,
      "reasoning" => 6,
      "home_status_changed" => 6,
      "checklists" => 6,
      "checklist" => 6
    }

    for type <- Protocol.server_events() do
      assert Protocol.server_event_version(type) == Map.get(later, type, 1),
             "#{type} names the wrong version"
    end

    for type <- Map.keys(later), do: refute(type in Protocol.shared_server_events())
  end

  test "every client event names the version that brought it: the media grant 3, the answer 4" do
    later = %{
      "media_fetch" => 3,
      "media_release" => 3,
      "proposal_answer" => 4,
      "checklists_pull" => 6,
      "checklist_pull" => 6,
      "checklist_edit" => 6
    }

    for type <- Protocol.client_events() do
      assert Protocol.client_event_version(type) == Map.get(later, type, 1),
             "#{type} names the wrong version"
    end

    refute "media_fetch" in Protocol.shared_client_events()
    refute "proposal_answer" in Protocol.shared_client_events()
    refute "checklist_edit" in Protocol.shared_client_events()
    assert_raise ArgumentError, fn -> Protocol.client_event_version("ping") end
  end

  # Version 6: Always On's state changed, and the client reads `home.status`
  # over management for what it is now, so the notice carries nothing.
  test "home_status_changed carries nothing, and refuses any field" do
    assert {:ok, line} = Protocol.encode_server_event("home_status_changed", %{})
    assert Jason.decode!(line) == %{"type" => "home_status_changed"}

    assert {:error, {:invalid_field, "state"}} =
             Protocol.encode_server_event("home_status_changed", %{"state" => "on"})

    refute "home_status_changed" in Protocol.shared_server_events()
  end

  # M85 §07: the wire holds what a list event is carried in, by the engine's
  # ids; the op itself is the Registry's to judge, with its sentence.
  describe "the owner's lists (version 6)" do
    @list_id "ck_4q8m2x7v1d"
    @row_id "ci_8f3k2m9q1x"

    test "a pull names a list by its id, and removed is a boolean" do
      pull = %{"profile_id" => "main", "list_id" => @list_id}

      assert :ok = Protocol.validate_client_payload("checklist_pull", pull)

      assert :ok =
               Protocol.validate_client_payload("checklist_pull", Map.put(pull, "removed", true))

      for bad <- [
            %{pull | "list_id" => "Groceries"},
            %{pull | "list_id" => @row_id},
            Map.put(pull, "removed", "yes")
          ] do
        assert {:error, {:invalid_field, _field}} =
                 Protocol.validate_client_payload("checklist_pull", bad)
      end
    end

    test "an edit carries one op object, its id bounded as the store keeps it" do
      edit = %{
        "client_msg_id" => "mac-1",
        "profile_id" => "main",
        "list_id" => @list_id,
        "op" => %{"op" => "check", "row_id" => @row_id}
      }

      assert :ok = Protocol.validate_client_payload("checklist_edit", edit)
      assert :ok = Protocol.validate_client_payload("checklist_edit", Map.delete(edit, "list_id"))

      long = String.duplicate("a", Protocol.max_checklist_msg_id() + 1)

      for {field, bad} <- [
            {"op", %{edit | "op" => "check"}},
            {"op", %{edit | "op" => %{"row_id" => @row_id}}},
            {"op", %{edit | "op" => %{"op" => ""}}},
            {"list_id", %{edit | "list_id" => "Groceries"}},
            {"client_msg_id", %{edit | "client_msg_id" => long}}
          ] do
        assert {:error, {:invalid_field, ^field}} =
                 Protocol.validate_client_payload("checklist_edit", bad)
      end
    end

    test "a pushed list is whole, without a null, and a removed row says when" do
      item = %{"row_id" => @row_id, "kind" => "item", "text" => "Bread", "done" => false}
      list = %{"list_id" => @list_id, "title" => "Groceries", "rev" => 3, "rows" => [item]}
      event = %{"profile_id" => "main", "list" => list}

      assert {:ok, _line} = Protocol.encode_server_event("checklist", event)

      removed = Map.put(item, "removed_at", "2031-06-02T14:05:00.000000Z")

      assert {:ok, _line} =
               Protocol.encode_server_event(
                 "checklist",
                 put_in(event, ["list", "removed"], [removed])
               )

      for bad <- [
            put_in(event, ["list", "removed"], [item]),
            put_in(event, ["list", "rows"], [Map.put(item, "note", nil)]),
            put_in(event, ["list", "rows"], [%{item | "kind" => "task"}]),
            put_in(event, ["list", "list_id"], "Groceries")
          ] do
        assert {:error, {:invalid_field, "list"}} = Protocol.encode_server_event("checklist", bad)
      end

      assert {:error, {:invalid_field, "made"}} =
               Protocol.encode_server_event("checklist", Map.put(event, "made", %{}))
    end

    test "the index lists each list by id with its counts" do
      entry = %{
        "list_id" => @list_id,
        "title" => "Groceries",
        "open" => 2,
        "done" => 1,
        "rev" => 7
      }

      assert {:ok, _line} =
               Protocol.encode_server_event("checklists", %{
                 "profile_id" => "main",
                 "lists" => [entry]
               })

      for bad <- [
            Map.delete(entry, "rev"),
            %{entry | "open" => -1},
            Map.put(entry, "folder", nil)
          ] do
        assert {:error, {:invalid_field, "lists"}} =
                 Protocol.encode_server_event("checklists", %{
                   "profile_id" => "main",
                   "lists" => [bad]
                 })
      end
    end
  end

  test "turn_done names the turn it ends and nothing else" do
    assert {:ok, line} = Protocol.encode_server_event("turn_done", %{"turn_id" => "turn-mac-1"})
    assert Jason.decode!(line) == %{"type" => "turn_done", "turn_id" => "turn-mac-1"}

    assert {:error, {:missing_field, "turn_id"}} =
             Protocol.encode_server_event("turn_done", %{})

    assert {:error, {:invalid_field, "turn_id"}} =
             Protocol.encode_server_event("turn_done", %{"turn_id" => ""})
  end

  # Version 6: a tool's start says what the step is, in at most 120 bytes of
  # text, and a stop or a start from an older daemon says nothing.
  test "a tool_event carries an optional activity of at most 120 bytes" do
    start = %{"turn_id" => "t", "tool" => "web_search", "phase" => "start"}
    words = String.duplicate("é", 60)

    assert Protocol.max_activity_bytes() == 120
    assert {:ok, _line} = Protocol.encode_server_event("tool_event", start)

    assert {:ok, line} =
             Protocol.encode_server_event("tool_event", Map.put(start, "activity", words))

    assert %{"activity" => ^words} = Jason.decode!(line)

    for bad <- ["", words <> "a", 1, <<0xFF>>] do
      assert {:error, {:invalid_field, "activity"}} =
               Protocol.encode_server_event("tool_event", Map.put(start, "activity", bad)),
             inspect(bad)
    end
  end

  # Version 6: a step's reasoning summary, nonempty text of at most 4,096 bytes.
  test "reasoning names its turn and carries nonempty text of at most 4,096 bytes" do
    text = String.duplicate("ab", 2_048)

    assert Protocol.max_reasoning_bytes() == 4_096

    assert {:ok, line} =
             Protocol.encode_server_event("reasoning", %{"turn_id" => "t", "text" => text})

    assert Jason.decode!(line) == %{"type" => "reasoning", "turn_id" => "t", "text" => text}

    assert {:error, {:missing_field, "text"}} =
             Protocol.encode_server_event("reasoning", %{"turn_id" => "t"})

    assert {:error, {:missing_field, "turn_id"}} =
             Protocol.encode_server_event("reasoning", %{"text" => "x"})

    for bad <- ["", text <> "a", 1] do
      assert {:error, {:invalid_field, "text"}} =
               Protocol.encode_server_event("reasoning", %{"turn_id" => "t", "text" => bad}),
             inspect(bad)
    end
  end

  test "the shared chat events are a subset of both catalogs" do
    assert Protocol.shared_client_events() -- Protocol.client_events() == []
    assert Protocol.shared_server_events() -- Protocol.server_events() == []
    refute "history_pull" in Protocol.shared_client_events()
    refute "history_page" in Protocol.shared_server_events()
    assert "cancel" in Protocol.shared_client_events()
    assert "row" in Protocol.shared_server_events()
  end

  test "negotiates directionally, version 5 and version 6 both accepted, version 4 too old" do
    assert :ok = Protocol.negotiate(5)
    assert :ok = Protocol.negotiate(6)
    assert {:error, :client_too_old} = Protocol.negotiate(4)
    assert {:error, :client_too_new} = Protocol.negotiate(7)
  end

  test "client_hello refuses a missing or malformed version with the Realtime reasons" do
    assert {:ok, %{type: "client_hello", payload: %{"protocol_version" => 1}}} =
             decode(%{"type" => "client_hello", "protocol_version" => 1})

    assert {:error, :missing_protocol_version} = decode(%{"type" => "client_hello"})

    assert {:error, :invalid_protocol_version} =
             decode(%{"type" => "client_hello", "protocol_version" => "1"})
  end

  # M75 D14: the hellos carry the primary epoch, each optional: a client that
  # has seen none sends none, and a home that has none announces none.
  test "the hellos carry an optional positive primary epoch" do
    assert {:ok, %{payload: %{"primary_epoch" => 3}}} =
             decode(%{"type" => "client_hello", "protocol_version" => 4, "primary_epoch" => 3})

    for bad <- [0, -1, "3", 3.5] do
      assert {:error, {:invalid_field, "primary_epoch"}} =
               decode(%{
                 "type" => "client_hello",
                 "protocol_version" => 4,
                 "primary_epoch" => bad
               }),
             inspect(bad)
    end

    hello = %{"min_version" => 5, "max_version" => 6, "role" => "primary"}

    assert {:ok, line} =
             Protocol.encode_server_event("server_hello", Map.put(hello, "primary_epoch", 2))

    assert %{"primary_epoch" => 2} = Jason.decode!(line)
    assert {:ok, _line} = Protocol.encode_server_event("server_hello", hello)

    for bad <- [0, "2", 2.5] do
      assert {:error, {:invalid_field, "primary_epoch"}} =
               Protocol.encode_server_event("server_hello", Map.put(hello, "primary_epoch", bad)),
             inspect(bad)
    end
  end

  test "a message keeps the mobile shape and carries no attachments on this wire" do
    msg = %{
      "type" => "msg",
      "client_msg_id" => "c-1",
      "profile_id" => "main",
      "text" => "hello",
      "attach_ids" => []
    }

    assert {:ok, %{type: "msg", payload: payload}} = decode(msg)
    refute Map.has_key?(payload, "type")

    assert {:error, {:missing_field, "attach_ids"}} = decode(Map.delete(msg, "attach_ids"))
    assert {:error, {:missing_field, "content"}} = decode(%{msg | "text" => "  "})

    assert {:error, :attachments_unsupported} =
             decode(%{msg | "attach_ids" => ["attach-1"]})
  end

  test "history_pull takes exactly one cursor" do
    base = %{"type" => "history_pull", "profile_id" => "main", "limit" => 50}

    assert {:ok, _event} = decode(Map.put(base, "after_seq", 0))
    assert {:ok, _event} = decode(Map.put(base, "before_seq", 12))
    assert {:error, {:missing_field, "after_seq"}} = decode(base)
    assert {:error, {:invalid_field, "before_seq"}} = decode(Map.put(base, "before_seq", 0))

    assert {:error, {:invalid_field, "before_seq"}} =
             decode(base |> Map.put("after_seq", 0) |> Map.put("before_seq", 3))

    assert {:error, {:invalid_field, "limit"}} =
             decode(base |> Map.put("after_seq", 0) |> Map.put("limit", 201))
  end

  test "history_search bounds its query and page" do
    base = %{"type" => "history_search", "profile_id" => "main", "query" => "plan", "limit" => 20}

    assert {:ok, _event} = decode(base)
    assert {:ok, _event} = decode(Map.put(base, "before_seq", 40))
    assert {:error, {:invalid_field, "query"}} = decode(%{base | "query" => ""})

    assert {:error, {:invalid_field, "query"}} =
             decode(%{base | "query" => String.duplicate("é", 257)})

    assert {:ok, _event} = decode(%{base | "query" => String.duplicate("é", 256)})
    assert {:error, {:invalid_field, "limit"}} = decode(%{base | "limit" => 51})
    assert {:error, {:invalid_field, "before_seq"}} = decode(Map.put(base, "before_seq", 0))
  end

  test "cancel names the request whose turn it stops, and read_state its profile" do
    assert {:ok, _event} =
             decode(%{"type" => "cancel", "profile_id" => "main", "client_msg_id" => "mac-1"})

    assert {:error, {:missing_field, "profile_id"}} = decode(%{"type" => "cancel"})

    assert {:error, {:missing_field, "client_msg_id"}} =
             decode(%{"type" => "cancel", "profile_id" => "main"})

    assert {:ok, _event} =
             decode(%{"type" => "read_state", "profile_id" => "main", "read_up_to_seq" => 4})
  end

  # M56 §4.6, §6: a version 2 cancel may name a task that outlived its call
  # by its three ids instead of a request.
  test "cancel may name a detached voice task by its call, task and revision" do
    task_ref = %{
      "call_uuid" => "3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b",
      "task_id" => "dg_1",
      "revision" => 2
    }

    base = %{"type" => "cancel", "profile_id" => "main", "client_msg_id" => "mac-9"}

    assert {:ok, %{payload: %{"task_ref" => ^task_ref}}} =
             decode(Map.put(base, "task_ref", task_ref))

    for bad <- [
          "dg_1",
          Map.delete(task_ref, "call_uuid"),
          %{task_ref | "call_uuid" => "not-a-uuid"},
          %{task_ref | "task_id" => ""},
          %{task_ref | "revision" => 0},
          %{task_ref | "revision" => "2"},
          Map.put(task_ref, "turn_id", "turn-1")
        ] do
      assert {:error, {:invalid_field, "task_ref"}} = decode(Map.put(base, "task_ref", bad)),
             "accepted task_ref #{inspect(bad)}"
    end
  end

  test "malformed and unknown lines fail loudly" do
    assert {:error, :invalid_json} = Protocol.decode_client_event("{")
    assert {:error, :invalid_event} = Protocol.decode_client_event("[1]")
    assert {:error, :missing_type} = Protocol.decode_client_event(~s({"text":"hi"}))
    assert {:error, {:unknown_event, "ping"}} = decode(%{"type" => "ping"})
  end

  test "the encoder writes one newline-terminated object with its type" do
    assert {:ok, line} =
             Protocol.encode_server_event("server_hello", %{
               min_version: 5,
               max_version: 6,
               role: "primary"
             })

    assert String.ends_with?(line, "\n")

    assert Jason.decode!(line) == %{
             "type" => "server_hello",
             "min_version" => 5,
             "max_version" => 6,
             "role" => "primary"
           }

    assert {:error, {:invalid_field, "version_range"}} =
             Protocol.encode_server_event("server_hello", %{
               min_version: 4,
               max_version: 6,
               role: "primary"
             })
  end

  # M75: the engine names its role on every hello, so a desktop app never
  # compares a device-role engine's epoch against the primary's.
  test "server_hello names the engine's role, primary or device" do
    hello = %{"min_version" => 5, "max_version" => 6}

    for role <- ~w(primary device) do
      assert {:ok, line} =
               Protocol.encode_server_event("server_hello", Map.put(hello, "role", role))

      assert %{"role" => ^role} = Jason.decode!(line)
    end

    assert {:error, {:missing_field, "role"}} =
             Protocol.encode_server_event("server_hello", hello)

    for bad <- ["owner", "", :primary, 1] do
      assert {:error, {:invalid_field, "role"}} =
               Protocol.encode_server_event("server_hello", Map.put(hello, "role", bad)),
             inspect(bad)
    end
  end

  test "the encoder refuses explicit nulls, a written type and unknown events" do
    assert {:error, {:null_field, "detail"}} =
             Protocol.encode_server_event("tool_event", %{
               "turn_id" => "t",
               "tool" => "shell",
               "phase" => "stop",
               "detail" => nil
             })

    assert {:error, {:reserved_field, "type"}} =
             Protocol.encode_server_event("error", %{"type" => "x", "reason" => "r"})

    assert {:error, {:unknown_event, "pong"}} = Protocol.encode_server_event("pong", %{})
  end

  test "history pages and search results carry their cursors" do
    assert {:ok, _line} =
             Protocol.encode_server_event("history_page", %{
               "profile_id" => "main",
               "messages" => [],
               "history_head_seq" => 0,
               "next_after_seq" => 0
             })

    assert {:error, {:missing_field, "history_head_seq"}} =
             Protocol.encode_server_event("history_page", %{
               "profile_id" => "main",
               "messages" => []
             })

    assert {:ok, _line} =
             Protocol.encode_server_event("search_results", %{
               "profile_id" => "main",
               "query" => "plan",
               "hits" => [],
               "next_before_seq" => 9
             })

    assert {:error, {:invalid_field, "next_before_seq"}} =
             Protocol.encode_server_event("search_results", %{
               "profile_id" => "main",
               "query" => "plan",
               "hits" => [],
               "next_before_seq" => 0
             })
  end

  test "a row announces one timeline row, with the sender's id only on a user's" do
    row = %{
      "profile_id" => "main",
      "server_seq" => 12,
      "role" => "user",
      "text" => "What is on my calendar today?",
      "ts" => "2026-09-25T09:00:00Z",
      "media_refs" => []
    }

    assert {:ok, _line} = Protocol.encode_server_event("row", row)

    assert {:ok, _line} =
             Protocol.encode_server_event("row", Map.put(row, "client_msg_id", "mac-1"))

    assert {:ok, _line} = Protocol.encode_server_event("row", %{row | "text" => ""})

    assert {:error, {:invalid_field, "client_msg_id"}} =
             Protocol.encode_server_event("row", Map.put(row, "client_msg_id", ""))

    assert {:error, {:invalid_field, "server_seq"}} =
             Protocol.encode_server_event("row", %{row | "server_seq" => 0})

    assert {:error, {:missing_field, "ts"}} =
             Protocol.encode_server_event("row", Map.delete(row, "ts"))
  end

  # M56 §6: the Mac's row carries a history message's kind and metadata, as
  # the phone's always has.
  test "a row may carry its kind and metadata" do
    row = %{
      "profile_id" => "main",
      "server_seq" => 15,
      "role" => "assistant",
      "text" => "It is at https://x.test/form.",
      "ts" => "2026-10-03T10:00:00Z",
      "kind" => "text",
      "metadata" => %{"call" => shared_call()},
      "media_refs" => []
    }

    assert {:ok, _line} = Protocol.encode_server_event("row", row)

    assert {:error, {:invalid_field, "kind"}} =
             Protocol.encode_server_event("row", %{row | "kind" => ""})

    assert {:error, {:invalid_field, "metadata"}} =
             Protocol.encode_server_event("row", %{row | "metadata" => "call"})
  end

  # M66: a row carries the history message's media refs, always, and its link
  # previews only when it has one, at most four.
  test "a row always carries its media refs, and its link previews only when it has one" do
    preview = %{"url" => "https://shop.test/lamp", "site" => "Shop", "title" => "Lamp"}

    row = %{
      "profile_id" => "main",
      "server_seq" => 21,
      "role" => "user",
      "text" => "",
      "ts" => "2026-10-03T10:00:00Z",
      "kind" => "media",
      "media_refs" => [
        %{"ref" => ref(), "kind" => "audio", "mime" => "audio/ogg", "size_bytes" => 48_213}
      ]
    }

    assert {:ok, _line} = Protocol.encode_server_event("row", row)

    assert {:ok, _line} =
             Protocol.encode_server_event("row", Map.put(row, "link_previews", [preview]))

    assert {:error, {:missing_field, "media_refs"}} =
             Protocol.encode_server_event("row", Map.delete(row, "media_refs"))

    assert {:error, {:invalid_field, "media_refs"}} =
             Protocol.encode_server_event("row", %{row | "media_refs" => %{}})

    for bad <- [[], List.duplicate(preview, 5), ["https://shop.test/lamp"], preview] do
      assert {:error, {:invalid_field, "link_previews"}} =
               Protocol.encode_server_event("row", Map.put(row, "link_previews", bad)),
             "accepted link_previews #{inspect(bad)}"
    end
  end

  test "media_fetch and media_release name a profile and a ref of 64 lowercase hex digits" do
    for type <- ~w(media_fetch media_release) do
      event = %{"type" => type, "profile_id" => "main", "ref" => ref()}

      assert {:ok, %{type: ^type, payload: %{"ref" => _ref}}} = decode(event)
      assert {:error, {:missing_field, "ref"}} = decode(Map.delete(event, "ref"))
      assert {:error, {:missing_field, "profile_id"}} = decode(Map.delete(event, "profile_id"))

      for bad <- [String.upcase(ref()), String.slice(ref(), 1..63), "../etc/passwd", 7] do
        assert {:error, {:invalid_field, "ref"}} = decode(%{event | "ref" => bad}),
               "#{type} accepted ref #{inspect(bad)}"
      end
    end
  end

  test "media_path grants an absolute file whose digest is its ref" do
    grant = %{
      "ref" => ref(),
      "path" => "/Users/me/.fermix/companion/media/#{ref()}.ogg",
      "kind" => "audio",
      "mime" => "audio/ogg",
      "size_bytes" => 48_213,
      "sha256" => ref()
    }

    assert {:ok, _line} = Protocol.encode_server_event("media_path", grant)

    assert {:error, {:invalid_field, "path"}} =
             Protocol.encode_server_event("media_path", %{grant | "path" => "media/x.ogg"})

    assert {:error, {:invalid_field, "sha256"}} =
             Protocol.encode_server_event("media_path", %{
               grant
               | "sha256" => String.duplicate("b", 64)
             })

    assert {:error, {:invalid_field, "size_bytes"}} =
             Protocol.encode_server_event("media_path", %{grant | "size_bytes" => -1})

    assert {:error, {:missing_field, "mime"}} =
             Protocol.encode_server_event("media_path", Map.delete(grant, "mime"))
  end

  test "media_missing names its ref, row_updated its row, and an error may name a ref" do
    assert {:ok, _line} = Protocol.encode_server_event("media_missing", %{"ref" => ref()})

    assert {:error, {:invalid_field, "ref"}} =
             Protocol.encode_server_event("media_missing", %{"ref" => "photo"})

    assert {:ok, line} =
             Protocol.encode_server_event("row_updated", %{profile_id: "main", server_seq: 21})

    assert Jason.decode!(line) == %{
             "type" => "row_updated",
             "profile_id" => "main",
             "server_seq" => 21
           }

    assert {:error, {:invalid_field, "server_seq"}} =
             Protocol.encode_server_event("row_updated", %{profile_id: "main", server_seq: 0})

    failed = %{"reason" => "request_failed", "message" => ":enospc", "ref" => ref()}
    assert {:ok, _line} = Protocol.encode_server_event("error", failed)

    assert {:error, {:invalid_field, "ref"}} =
             Protocol.encode_server_event("error", %{failed | "ref" => ""})
  end

  # M60 app surface §3.7 (D28): a proposal's card, its end, and the owner's answer.
  describe "proposals (version 4)" do
    test "proposal_answer names the proposal and a decision, confirm, deny or always_allow" do
      answer = %{
        "type" => "proposal_answer",
        "client_msg_id" => "mac-9",
        "profile_id" => "main",
        "proposal_id" => "cpr_1",
        "decision" => "confirm"
      }

      assert {:ok, %{type: "proposal_answer"}} = decode(answer)
      assert {:ok, _event} = decode(%{answer | "decision" => "deny"})
      assert {:ok, _event} = decode(%{answer | "decision" => "always_allow"})
      assert {:error, {:invalid_field, "decision"}} = decode(%{answer | "decision" => "maybe"})
      assert {:error, {:invalid_field, "proposal_id"}} = decode(%{answer | "proposal_id" => ""})
      assert {:error, {:missing_field, "decision"}} = decode(Map.delete(answer, "decision"))
    end

    test "a proposal carries its card whole, with no null anywhere in it" do
      assert {:ok, line} =
               Protocol.encode_server_event("proposal", %{
                 profile_id: "main",
                 proposal: proposal_card()
               })

      assert %{"type" => "proposal", "proposal" => %{"proposal_id" => "cpr_1"}} =
               Jason.decode!(line)

      for drift <- [
            Map.delete(proposal_card(), "summary"),
            Map.put(proposal_card(), "watcher", nil),
            put_in(proposal_card(), ["outside", "cue"], nil),
            Map.put(proposal_card(), "state", "pending"),
            put_in(proposal_card(), ["outside", "args_text"], String.duplicate("x", 3_501)),
            Map.delete(proposal_card(), "task"),
            "not a card"
          ] do
        assert {:error, {:invalid_field, "proposal"}} =
                 Protocol.validate_server_payload("proposal", %{
                   "profile_id" => "main",
                   "proposal" => drift
                 }),
               "accepted #{inspect(drift)}"
      end
    end

    # M60_WATCHER_CODING_RUNS.md §6.3: the compact card's lines, additive.
    test "a mandate's card may carry each argument and the filter's reason" do
      compact =
        proposal_card()
        |> put_in(["outside", "args"], [%{"name" => "title", "value" => "Phoenix 2.0"}])
        |> put_in(["outside", "reason"], "a release")

      assert :ok = validate_card(compact)
      assert Protocol.server_payload_version("proposal", %{"proposal" => compact}) == 4

      for drift <- [
            put_in(compact, ["outside", "args"], [%{"name" => "", "value" => "x"}]),
            put_in(compact, ["outside", "args"], [%{"name" => "title", "value" => 2}]),
            put_in(compact, ["outside", "reason"], "")
          ] do
        assert {:error, {:invalid_field, "proposal"}} = validate_card(drift)
      end
    end

    # M60_WATCHER_CODING_RUNS.md §6.2: version 5's follow-up card names the
    # follow-up in place of a mandate's call, and never carries arguments.
    test "a follow-up's card is version 5's, names the follow-up and carries no call" do
      assert :ok = validate_card(follow_up_card())

      assert :ok =
               validate_card(put_in(follow_up_card(), ["follow_up", "offers_always_allow"], true))

      assert Protocol.server_payload_version("proposal", %{"proposal" => follow_up_card()}) == 5
      assert Protocol.server_payload_version("proposal_resolved", %{}) == 4

      for drift <- [
            Map.put(follow_up_card(), "mandate", "release-issues"),
            Map.put(follow_up_card(), "tool", "shell"),
            put_in(follow_up_card(), ["outside", "args_text"], "{}"),
            put_in(follow_up_card(), ["follow_up", "asks"], "maybe"),
            put_in(follow_up_card(), ["follow_up", "tools"], [""]),
            put_in(follow_up_card(), ["follow_up", "asks"], "automatic"),
            put_in(follow_up_card(), ["follow_up", "daily_cap"], 5),
            put_in(follow_up_card(), ["follow_up", "set_off_by"], "x-feed"),
            put_in(follow_up_card(), ["follow_up", "offers_always_allow"], "yes"),
            Map.update!(follow_up_card(), "follow_up", &Map.delete(&1, "instructions"))
          ] do
        assert {:error, {:invalid_field, "proposal"}} = validate_card(drift),
               "accepted #{inspect(drift)}"
      end
    end

    test "proposal_resolved names the proposal, its state and Fermix's sentence" do
      resolved = %{
        "profile_id" => "main",
        "proposal_id" => "cpr_1",
        "state" => "confirmed",
        "result_status" => "ok",
        "sentence" => "Confirmed. github_create_issue ran.",
        "result_text" => ~s({"number":42})
      }

      assert {:ok, _line} = Protocol.encode_server_event("proposal_resolved", resolved)

      minimal = Map.drop(resolved, ["result_status", "result_text"])
      assert :ok = Protocol.validate_server_payload("proposal_resolved", minimal)

      for {field, value} <- [
            {"state", "waiting"},
            {"result_status", "fine"},
            {"sentence", ""},
            {"result_text", String.duplicate("x", 2_001)}
          ] do
        assert {:error, {:invalid_field, ^field}} =
                 Protocol.validate_server_payload(
                   "proposal_resolved",
                   Map.put(resolved, field, value)
                 )
      end
    end
  end

  describe "validate_call_metadata/1" do
    test "a result shown in the chat names the call, the event and its task" do
      assert :ok = Protocol.validate_call_metadata(shared_call())
    end

    test "every key of the design's call map is accepted with its type" do
      done =
        Map.merge(shared_call(), %{"event" => "task_done", "state" => "timed_out"})

      assert :ok = Protocol.validate_call_metadata(ended_call())
      assert :ok = Protocol.validate_call_metadata(%{shared_call() | "event" => "task_running"})
      assert :ok = Protocol.validate_call_metadata(done)
    end

    # M56 §4.2: the call's one row when it ends names its engine, its length,
    # its bill's accounting and what became of its gist; the cost is absent
    # when it is unknown.
    test "a call's ended row names its engine, length, accounting and gist" do
      for gist_status <- ~w(written failed none) do
        assert :ok =
                 Protocol.validate_call_metadata(%{ended_call() | "gist_status" => gist_status})
      end

      assert :ok = Protocol.validate_call_metadata(Map.delete(ended_call(), "voice_cost_cents"))

      for key <- ~w(engine duration_s accounting gist_status) do
        assert {:error, {:missing_field, "call." <> ^key}} =
                 Protocol.validate_call_metadata(Map.delete(ended_call(), key))
      end
    end

    test "the call and the event are required, and the event is one of four" do
      assert {:error, {:missing_field, "call.uuid"}} =
               Protocol.validate_call_metadata(Map.delete(shared_call(), "uuid"))

      assert {:error, {:missing_field, "call.event"}} =
               Protocol.validate_call_metadata(Map.delete(shared_call(), "event"))

      assert {:error, {:invalid_field, "call.event"}} =
               Protocol.validate_call_metadata(%{shared_call() | "event" => "spoken"})

      assert {:error, {:invalid_field, "call.uuid"}} =
               Protocol.validate_call_metadata(%{shared_call() | "uuid" => "call-7"})
    end

    test "a task's event names the task and its revision; a task's end names its state" do
      assert {:error, {:missing_field, "call.task_id"}} =
               Protocol.validate_call_metadata(Map.delete(shared_call(), "task_id"))

      assert {:error, {:missing_field, "call.revision"}} =
               Protocol.validate_call_metadata(Map.delete(shared_call(), "revision"))

      assert {:error, {:missing_field, "call.state"}} =
               Protocol.validate_call_metadata(%{shared_call() | "event" => "task_done"})
    end

    test "each field is refused in a shape other than its own" do
      for {key, value} <- [
            {"task_id", ""},
            {"revision", 0},
            {"state", "running"},
            {"duration_s", -1},
            {"voice_cost_cents", "0.5"},
            {"accounting", "running"},
            {"engine", ""},
            {"gist_status", "pending"}
          ] do
        assert {:error, {:invalid_field, "call." <> ^key}} =
                 Protocol.validate_call_metadata(Map.put(shared_call(), key, value))
      end
    end

    test "a key the call map does not have is refused, and so is anything not a map" do
      assert {:error, {:unknown_field, "call.text"}} =
               Protocol.validate_call_metadata(Map.put(shared_call(), "text", "hi"))

      assert {:error, {:invalid_field, "call"}} = Protocol.validate_call_metadata(nil)
    end
  end

  defp ended_call do
    %{
      "uuid" => "3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b",
      "event" => "ended",
      "engine" => "openai_live",
      "duration_s" => 360,
      "voice_cost_cents" => 30.125,
      "accounting" => "complete",
      "gist_status" => "written"
    }
  end

  defp shared_call do
    %{
      "uuid" => "3f2b8c1e-5a4d-4e6f-9b8a-7c6d5e4f3a2b",
      "event" => "shared",
      "task_id" => "dg_01H9",
      "revision" => 1
    }
  end

  test "payload validation is available to another envelope without the type key" do
    assert :ok =
             Protocol.validate_server_payload("accepted", %{
               "client_msg_id" => "c",
               "duplicate" => true,
               "server_seq" => 3
             })

    assert {:error, {:missing_field, "duplicate"}} =
             Protocol.validate_server_payload("accepted", %{"client_msg_id" => "c"})

    assert {:error, {:unknown_event, "hello"}} = Protocol.validate_client_payload("hello", %{})
  end

  defp proposal_card do
    %{
      "proposal_id" => "cpr_1",
      "state" => "waiting",
      "mandate" => "release-issues",
      "tool" => "github_create_issue",
      "task" => %{"job_id" => "release_issues", "name" => "release issues"},
      "watcher" => "release-watch",
      "source_ref" => "eng-blogs",
      "created_at" => "2026-10-10T12:00:00Z",
      "expires_at" => "2026-10-10T12:30:00Z",
      "received_at" => "2026-10-10T11:59:00Z",
      "status_sentence" => "Waiting for your answer; it runs only if you confirm.",
      "summary" => "A task wants to run github_create_issue under your mandate release-issues.",
      "outside" => %{
        "args_text" => "{\n  \"title\": \"Phoenix 2.0\"\n}",
        "cue" => %{"type" => "release", "subject" => "phoenix", "text" => "Phoenix 2.0 is out."}
      }
    }
  end

  defp follow_up_card do
    %{
      "proposal_id" => "cft_1",
      "state" => "waiting",
      "task" => %{"job_id" => "codex_review", "name" => "Codex review"},
      "watcher" => "codex-limits",
      "source_ref" => "x-feed",
      "created_at" => "2026-10-30T12:00:00Z",
      "expires_at" => "2026-10-30T12:30:00Z",
      "status_sentence" => "Waiting for your answer; it runs only if you confirm.",
      "summary" => "Watcher codex-limits wants to run its follow-up \"Codex review\".",
      "outside" => %{
        "reason" => "the post says usage limits reset",
        "cue" => %{"subject" => "@limits", "text" => "Usage limits have been reset."}
      },
      "follow_up" => %{
        "asks" => "run",
        "name" => "Codex review",
        "instructions" => "Review the last day's commits on dev.",
        "tools" => ["codex_run"],
        "reports_to" => "Telegram (owner-1)"
      }
    }
  end

  defp validate_card(card),
    do:
      Protocol.validate_server_payload("proposal", %{"profile_id" => "main", "proposal" => card})

  defp decode(map), do: map |> Jason.encode!() |> Protocol.decode_client_event()

  defp ref, do: "9879f6d3c9efefe8c4f4aabe9d3269762264be52794e96f62ab8ffa53b7fadec"
end
