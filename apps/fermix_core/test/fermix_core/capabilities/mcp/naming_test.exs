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
end
