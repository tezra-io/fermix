defmodule FermixCore.Browser.ScopeTest do
  use ExUnit.Case, async: true

  alias FermixCore.Browser.Scope

  test "derives stable hashed owner from conversation_key" do
    context = %{conversation_key: {"telegram", "chat-123", :root}}

    assert {:ok, owner} = Scope.owner_key(context)
    assert is_binary(owner)
    assert byte_size(owner) >= 32
    refute owner =~ "telegram"
    refute owner =~ "chat-123"
    assert {:ok, ^owner} = Scope.owner_key(context)
  end

  test "requires conversation_key" do
    assert {:error, error} = Scope.owner_key(%{session_id: "turn-1"})
    assert error.code == "missing_conversation_key"
  end
end
