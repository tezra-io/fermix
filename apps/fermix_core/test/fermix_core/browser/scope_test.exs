defmodule FermixCore.Browser.ScopeTest do
  # async: false — the profile-directory test points FERMIX_HOME, which is
  # process-global, at a home of its own.
  use ExUnit.Case, async: false

  alias FermixCore.Browser.Error
  alias FermixCore.Browser.Scope

  # The owner's tool calls, wherever they come from. A delegated worker's
  # `source_trust` is stripped and its loop stamps the trust it runs at
  # (`effective_trust`); every other run carries both.
  @owner_contexts [
    {"a Telegram chat",
     %{
       conversation_key: {"telegram", "chat-123", :root},
       source_trust: :operator,
       effective_trust: :operator
     }},
    {"a CLI ask", %{conversation_key: {"cli", "sess-9", :root}, source_trust: :operator}},
    {"a scheduled job's run",
     %{
       conversation_key: {:scheduled_job, "job-1", "run-1"},
       source_trust: :operator,
       effective_trust: :operator
     }},
    {"the same job's next run",
     %{
       conversation_key: {:scheduled_job, "job-1", "run-2"},
       source_trust: :operator,
       effective_trust: :operator
     }},
    {"a cue run",
     %{
       conversation_key: {:scheduled_job, "job-2", "run-7"},
       source_trust: :operator,
       effective_trust: :operator,
       trigger: "cue"
     }},
    {"a worker the owner delegated to",
     %{conversation_key: {"telegram", "chat-123", :root}, effective_trust: :operator}}
  ]

  test "every owner conversation, scheduled and cue runs included, shares one key" do
    for {label, context} <- @owner_contexts do
      assert Scope.owner_key(context) == {:ok, "owner"}, "#{label} left the owner's profile"
    end
  end

  test "two guest conversations get two keys, each stable and neither the owner's" do
    first = %{conversation_key: {"telegram", "guest-chat-1", :root}, source_trust: :guest}
    second = %{conversation_key: {"telegram", "guest-chat-2", :root}, source_trust: :guest}

    assert {:ok, first_key} = Scope.owner_key(first)
    assert {:ok, second_key} = Scope.owner_key(second)

    assert first_key != second_key
    refute "owner" in [first_key, second_key]
    assert Scope.owner_key(first) == {:ok, first_key}
    assert first_key == Scope.guest_key(first.conversation_key)
  end

  # A plugin skill runs at guest under the owner's turn, and a turn whose
  # trust was never set runs its loop at guest: both are guests in that
  # conversation, never the owner.
  test "a run below operator trust in an owner's conversation gets that conversation's guest key" do
    conversation_key = {"telegram", "chat-123", :root}

    for context <- [
          %{conversation_key: conversation_key, source_trust: :operator, effective_trust: :guest},
          %{conversation_key: conversation_key, effective_trust: :guest},
          %{conversation_key: conversation_key, source_trust: :guest, effective_trust: :operator}
        ] do
      assert Scope.owner_key(context) == {:ok, Scope.guest_key(conversation_key)}
    end
  end

  test "a guest-created scheduled job keeps a profile per run, as any guest conversation" do
    first = %{conversation_key: {:scheduled_job, "job-g", "run-1"}, source_trust: :guest}
    second = %{conversation_key: {:scheduled_job, "job-g", "run-2"}, source_trust: :guest}

    assert {:ok, first_key} = Scope.owner_key(first)
    assert {:ok, second_key} = Scope.owner_key(second)
    assert first_key != second_key
    refute "owner" in [first_key, second_key]
  end

  test "a context that carries no trust is refused by name, never given the owner's profile" do
    for context <- [
          %{conversation_key: {"telegram", "chat-123", :root}},
          %{conversation_key: {"telegram", "chat-123", :root}, effective_trust: nil},
          %{session_id: "turn-1"}
        ] do
      assert {:error, %Error{code: "missing_trust", message: message}} = Scope.owner_key(context)
      assert message =~ "trust"
    end
  end

  test "a guest context without a conversation key is refused by name" do
    for context <- [%{source_trust: :guest}, %{source_trust: :guest, conversation_key: "chat-1"}] do
      assert {:error, %Error{code: "missing_conversation_key"}} = Scope.owner_key(context)
    end
  end

  # The profile is shared; the tab a call acts on by default is its
  # conversation's own.
  test "a call's tab affinity is its conversation key, for the owner and a guest alike" do
    for {_label, context} <- @owner_contexts do
      assert Scope.tab_affinity(context) == {:ok, context.conversation_key}
    end

    guest = %{conversation_key: {"telegram", "guest-chat-1", :root}, source_trust: :guest}
    assert Scope.tab_affinity(guest) == {:ok, guest.conversation_key}

    for context <- [%{source_trust: :operator}, %{conversation_key: "chat-1"}] do
      assert {:error, %Error{code: "missing_conversation_key"}} = Scope.tab_affinity(context)
    end
  end

  # A pane task ends with the turn that started it, so the app's pane is never
  # shared: the owner's pane profiles are one per conversation, and a guest's
  # is its conversation's own key, as its Chrome profile is.
  test "the owner's pane key is per conversation; a guest's pane key is its own key" do
    chat_a = {"telegram", "chat-a", :root}
    chat_b = {"companion", "chat-b", :root}

    pane_a = Scope.pane_key("owner", chat_a)
    assert "owner-" <> digest = pane_a
    assert String.match?(digest, ~r/\A[A-Za-z0-9_-]{43}\z/)
    assert Scope.pane_key("owner", chat_a) == pane_a
    refute pane_a == Scope.pane_key("owner", chat_b)
    refute pane_a in ["owner", Scope.guest_key(chat_a), legacy_digest(chat_a)]

    guest = Scope.guest_key(chat_a)
    assert Scope.pane_key(guest, chat_a) == guest
  end

  # A guest key is "guest-" and 43 characters of unpadded url-safe Base64, so it
  # is 49 long; the owner's is 5; a profile kept before this scheme is the bare
  # 43-character digest. Three lengths, so no key can name another's directory.
  test "guest keys are namespaced: never the owner's, never a profile kept before this scheme" do
    conversation_key = {"telegram", "chat-123", :root}
    key = Scope.guest_key(conversation_key)

    assert "guest-" <> digest = key
    assert String.match?(digest, ~r/\A[A-Za-z0-9_-]{43}\z/)
    refute key =~ "telegram"
    refute key =~ "chat-123"
    assert Scope.guest_key(conversation_key) == key

    assert byte_size(digest) == byte_size(legacy_digest(conversation_key))
    refute key == legacy_digest(conversation_key)
    refute "owner" == legacy_digest(conversation_key)
  end

  test "the profile directory sits under <home>/browser and is the same on every call" do
    home = Path.join(System.tmp_dir!(), "fermix-scope-home-#{System.unique_integer([:positive])}")
    previous = System.get_env("FERMIX_HOME")
    System.put_env("FERMIX_HOME", home)
    on_exit(fn -> restore_home(previous) end)

    guest = Scope.guest_key({"telegram", "guest-chat-1", :root})

    assert Scope.profile_dir("owner", "fermix") ==
             Path.join([home, "browser", "profiles", "owner", "fermix"])

    assert Scope.profile_dir(guest, "fermix_chrome") ==
             Path.join([home, "browser", "profiles", guest, "fermix_chrome"])

    assert Scope.profile_dir("owner", "fermix") == Scope.profile_dir("owner", "fermix")
    refute File.exists?(home)
  end

  # The key every conversation had before this scheme, recomputed here so the
  # test states what an old profile directory is called without asking the code.
  defp legacy_digest(conversation_key) do
    conversation_key
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp restore_home(nil), do: System.delete_env("FERMIX_HOME")
  defp restore_home(previous), do: System.put_env("FERMIX_HOME", previous)
end
