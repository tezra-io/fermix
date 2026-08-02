defmodule FermixCore.Capabilities.MCP.NamingTest do
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.MCP.Naming

  setup do
    Naming.init()

    on_exit(fn ->
      case :ets.whereis(Naming) do
        :undefined -> :ok
        tid -> :ets.delete_all_objects(tid)
      end
    end)

    :ok
  end

  describe "candidate/2" do
    test "preserves alphanumeric server and tool names" do
      assert Naming.candidate("github", "create_issue") == "mcp_github_create_issue"
    end

    test "replaces dots in the server name with underscores" do
      assert Naming.candidate("fs.local", "read_file") == "mcp_fs_local_read_file"
    end

    test "sanitizes both segments — dots in tool name and dashes in server" do
      assert Naming.candidate("gh-actions", "workflow.dispatch") ==
               "mcp_gh_actions_workflow_dispatch"
    end

    test "downcases unicode/uppercase characters" do
      assert Naming.candidate("Notion", "ReadPage") == "mcp_notion_readpage"
    end

    test "collapses runs of underscores after sanitization" do
      assert Naming.candidate("server", "weird...name///here") == "mcp_server_weird_name_here"
    end

    test "truncates names over 64 bytes and appends an 8-char hash" do
      original =
        "search_pages_by_title_or_content_with_pagination_support_and_extras"

      candidate = Naming.candidate("notion", original)
      assert byte_size(candidate) <= 64
      assert String.starts_with?(candidate, "mcp_notion_search_pages_by_title")
      assert String.match?(candidate, ~r/_[0-9a-f]{8}$/)
    end

    test "raises when sanitization yields an empty tool name" do
      assert_raise ArgumentError, fn ->
        Naming.candidate("server", "____")
      end
    end
  end

  describe "candidate/3 with an explicit prefix (plugin-owned servers)" do
    test "uses the supplied prefix instead of mcp_<server>_" do
      assert Naming.candidate("obsidian", "search_notes", prefix: "obsidian_") ==
               "obsidian_search_notes"
    end

    test "a nil prefix keeps the operator-server default" do
      assert Naming.candidate("github", "create_issue", prefix: nil) ==
               "mcp_github_create_issue"
    end

    test "caps prefixed names at 64 bytes with a hash suffix" do
      original = "search_pages_by_title_or_content_with_pagination_support_and_extras"
      candidate = Naming.candidate("obsidian", original, prefix: "obsidian_")
      assert byte_size(candidate) <= 64
      assert String.starts_with?(candidate, "obsidian_search_pages")
      assert String.match?(candidate, ~r/_[0-9a-f]{8}$/)
    end
  end

  describe "register/3 collision handling" do
    test "round-trips a single registration through lookup/1" do
      sanitized = Naming.candidate("github", "create_issue")
      final = Naming.register("github", "create_issue", sanitized)
      assert final == sanitized
      assert {:ok, {"github", "create_issue"}} = Naming.lookup(final)
    end

    test "is idempotent for the same {server, original} pair" do
      sanitized = Naming.candidate("github", "create_issue")
      first = Naming.register("github", "create_issue", sanitized)
      second = Naming.register("github", "create_issue", sanitized)
      assert first == second
    end

    test "appends a hash suffix and emits telemetry on a true collision" do
      handler_id = :"mcp_collision_#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:fermix, :capability, :mcp_name_collision],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:collision, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      first_sanitized = Naming.candidate("fs.local", "read_file")
      first = Naming.register("fs.local", "read_file", first_sanitized)
      assert first == "mcp_fs_local_read_file"

      collide_sanitized = Naming.candidate("fs-local", "read_file")
      assert collide_sanitized == first

      collided_final = Naming.register("fs-local", "read_file", collide_sanitized)

      refute collided_final == first
      assert String.match?(collided_final, ~r/_[0-9a-f]{8}$/)

      assert {:ok, {"fs-local", "read_file"}} = Naming.lookup(collided_final)
      assert {:ok, {"fs.local", "read_file"}} = Naming.lookup(first)

      assert_receive {:collision, %{server: "fs-local", original: "read_file"}}
    end

    test "lookup/1 returns :error for unknown names" do
      assert Naming.lookup("mcp_unknown_tool") == :error
    end

    test "unregister/1 removes a known mapping" do
      sanitized = Naming.candidate("github", "create_issue")
      _ = Naming.register("github", "create_issue", sanitized)
      :ok = Naming.unregister(sanitized)
      assert Naming.lookup(sanitized) == :error
    end
  end

  describe "mode: :preserve" do
    test "keeps the exact upstream name, never a second prefix" do
      assert Naming.candidate("eden", "eden_get_note", mode: :preserve) == "eden_get_note"
    end

    test "does not sanitize case or punctuation away" do
      assert Naming.candidate("eden", "eden_getNote-v2", mode: :preserve) == "eden_getNote-v2"
    end

    test "raises rather than repairing a name that fails validation" do
      assert_raise ArgumentError, fn ->
        Naming.candidate("eden", "eden get note", mode: :preserve)
      end
    end

    test "existing prefix mode is unchanged" do
      assert Naming.candidate("eden", "eden_get_note", prefix: "eden_") ==
               "eden_eden_get_note"
    end
  end

  describe "validate_name/1" do
    test "accepts the capability charset up to 64 bytes" do
      assert :ok = Naming.validate_name("eden_get_note")
      assert :ok = Naming.validate_name(String.duplicate("a", 64))
    end

    test "refuses empty, over-long, and out-of-charset names" do
      assert {:error, {:empty_capability_name, _}} = Naming.validate_name("")

      assert {:error, {:capability_name_too_long, _}} =
               Naming.validate_name(String.duplicate("a", 65))

      assert {:error, {:invalid_capability_name, _}} = Naming.validate_name("eden get note")
    end
  end

  describe "reserve/3" do
    test "refuses a taken name instead of hash-renaming it" do
      assert {:ok, "eden_get_note"} = Naming.reserve("eden", "eden_get_note", "eden_get_note")

      assert {:error, {:capability_conflict, "eden_get_note"}} =
               Naming.reserve("other", "get_note", "eden_get_note")
    end

    test "re-reserving the same pair is idempotent" do
      assert {:ok, name} = Naming.reserve("eden", "eden_get_note", "eden_get_note")
      assert {:ok, ^name} = Naming.reserve("eden", "eden_get_note", "eden_get_note")
    end
  end
end
