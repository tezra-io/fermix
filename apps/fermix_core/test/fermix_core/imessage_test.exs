defmodule FermixCore.IMessageTest do
  use ExUnit.Case, async: true

  alias FermixCore.IMessage

  describe "check_platform/2" do
    test "an enabled section on a Mac is accepted" do
      assert IMessage.check_platform([enabled: true], macos?: true) == :ok
    end

    test "an enabled section anywhere else refuses with the typed error" do
      assert IMessage.check_platform([enabled: true], macos?: false) ==
               {:error, {:unsupported_platform, :imessage}}
    end

    test "a disabled or absent section is accepted everywhere" do
      assert IMessage.check_platform([enabled: false], macos?: false) == :ok
      assert IMessage.check_platform([], macos?: false) == :ok
    end
  end

  test "the refusal names the Mac whose Messages it reads" do
    assert IMessage.error_message({:unsupported_platform, :imessage}) ==
             "imessage runs only on the Mac whose Messages it reads"
  end

  describe "normalize_handle/1" do
    test "a phone number loses its separators and keeps its plus" do
      assert IMessage.normalize_handle(" +1 (555) 123-4567 ") == {:ok, "+15551234567"}
      assert IMessage.normalize_handle("+44.20.7946.0958") == {:ok, "+442079460958"}
    end

    test "an email is lower-cased and trimmed" do
      assert IMessage.normalize_handle("  Owner@Example.COM ") == {:ok, "owner@example.com"}
    end

    test "a number without its country code, a word or a non-string is refused, never guessed" do
      for value <- ["5551234567", "hello", "+1", "owner@", "@example.com", "", nil, 123] do
        assert IMessage.normalize_handle(value) == {:error, :invalid_handle}, inspect(value)
      end
    end

    test "normalize_handle!/1 raises on a handle the loader would have refused" do
      assert IMessage.normalize_handle!("+15551234567") == "+15551234567"

      assert_raise ArgumentError, ~r/not an iMessage handle/, fn ->
        IMessage.normalize_handle!("x")
      end
    end
  end

  describe "policy_handles/1" do
    test "the dedicated posture confirms the owner and every guest, once each" do
      config = [
        posture: :dedicated_account,
        owner_user_id: "+1 555 123 4567",
        allowed_sender_ids: ["Friend@Example.com", "+15551234567"]
      ]

      assert IMessage.policy_handles(config) == ["+15551234567", "friend@example.com"]
    end

    test "the own posture confirms the owner alone" do
      config = [posture: :own_account, owner_user_id: "me@example.com"]

      assert IMessage.policy_handles(config) == ["me@example.com"]
    end

    test "an empty guest list still confirms the owner" do
      config = [
        posture: :dedicated_account,
        owner_user_id: "+15551234567",
        allowed_sender_ids: []
      ]

      assert IMessage.policy_handles(config) == ["+15551234567"]
    end
  end
end
