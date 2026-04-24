defmodule FermixCore.Memory.ScopeTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Scope

  test "normalizes supported thread scope values" do
    assert Scope.normalize_thread_scope(:root) == "root"
    assert Scope.normalize_thread_scope("thread-1") == "thread-1"
    assert Scope.normalize_thread_scope(42) == "42"
  end

  test "builds conversation scope ids with normalized thread scopes" do
    assert Scope.conversation_scope_id("telegram", "chat-1", :root) == "telegram:chat-1:root"
    assert Scope.conversation_scope_id("discord", "channel-1", 123) == "discord:channel-1:123"
  end

  test "builds legacy conversation scope ids" do
    assert Scope.legacy_scope_id("telegram", "chat-1") == "legacy:telegram:chat-1"
  end
end
