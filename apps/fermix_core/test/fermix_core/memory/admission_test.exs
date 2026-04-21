defmodule FermixCore.Memory.AdmissionTest do
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Admission

  @candidate %{
    category: "preference",
    key: "preferred_editor",
    value: "neovim",
    scope_type: "owner",
    confidence: 0.97,
    promote_target: "user_md"
  }

  test "direct chats default durable owner facts into owner scope" do
    result =
      Admission.apply([@candidate],
        agent_id: "main",
        owner_id: "default",
        conversation_key: {"telegram", "chat_1", :root},
        chat_mode: :direct
      )

    assert [%{scope_type: "owner", scope_id: "default", promote_target: "user_md"}] =
             result.admitted

    assert result.rebuild?
    refute result.corrective?
  end

  test "policy-derived promotion is not suppressed by advisory none" do
    result =
      Admission.apply([Map.put(@candidate, :promote_target, "none")],
        agent_id: "main",
        owner_id: "default",
        conversation_key: {"telegram", "chat_1", :root},
        chat_mode: :direct
      )

    assert [%{scope_type: "owner", scope_id: "default", promote_target: "user_md"}] =
             result.admitted

    assert result.rebuild?
  end

  test "shared chats demote owner-scoped user facts into conversation scope" do
    result =
      Admission.apply([@candidate],
        agent_id: "main",
        owner_id: "default",
        conversation_key: {"slack", "C123", :root},
        chat_mode: :shared
      )

    assert [
             %{
               scope_type: "conversation",
               scope_id: "slack:C123:root",
               promote_target: "none"
             }
           ] = result.admitted

    refute result.rebuild?
  end

  test "shared chats default environment facts into agent scope" do
    candidate = %{
      category: "environment",
      key: "workspace_root",
      value: "/srv/fermix",
      scope_type: "conversation",
      confidence: 0.91,
      promote_target: "none"
    }

    result =
      Admission.apply([candidate],
        agent_id: "main",
        owner_id: "default",
        conversation_key: {"slack", "C123", :root},
        chat_mode: :shared
      )

    assert [%{scope_type: "agent", scope_id: "main", promote_target: "memory_md"}] =
             result.admitted

    assert result.rebuild?
  end

  test "rejects low-confidence candidates" do
    result =
      Admission.apply([Map.put(@candidate, :confidence, 0.5)],
        agent_id: "main",
        owner_id: "default",
        conversation_key: {"telegram", "chat_1", :root},
        chat_mode: :direct
      )

    assert result.admitted == []
    refute result.rebuild?
    refute result.corrective?
  end

  test "episode memories remain sqlite-only even when extractor suggests promotion" do
    candidate = %{
      category: "episode",
      key: "last_small_talk_topic",
      value: "weekend plans",
      scope_type: "owner",
      confidence: 0.96,
      promote_target: "user_md"
    }

    result =
      Admission.apply([candidate],
        agent_id: "main",
        owner_id: "default",
        conversation_key: {"telegram", "chat_1", :root},
        chat_mode: :direct
      )

    assert [%{scope_type: "owner", scope_id: "default", promote_target: "none"}] =
             result.admitted

    refute result.rebuild?
  end

  test "corrections replace prior beliefs cleanly and preserve the prior category" do
    existing = %{
      {"main", "owner", "default", "preferred_editor"} => %{
        agent_id: "main",
        owner_id: "default",
        scope_type: "owner",
        scope_id: "default",
        category: "preference",
        key: "preferred_editor",
        value: "vim",
        confidence: 0.91,
        promote_target: "user_md"
      }
    }

    correction = %{
      category: "correction",
      key: "preferred_editor",
      value: "helix",
      scope_type: "owner",
      confidence: 0.99,
      promote_target: "user_md"
    }

    result =
      Admission.apply([correction],
        agent_id: "main",
        owner_id: "default",
        conversation_key: {"telegram", "chat_1", :root},
        chat_mode: :direct,
        existing_memories: existing
      )

    assert [
             %{
               category: "preference",
               key: "preferred_editor",
               value: "helix",
               scope_type: "owner",
               scope_id: "default",
               promote_target: "user_md"
             }
           ] = result.admitted

    assert result.corrective?
    assert result.rebuild?
  end

  test "dedupes by final scope and key with the latest candidate winning" do
    result =
      Admission.apply(
        [
          Map.put(@candidate, :value, "vim"),
          Map.put(@candidate, :value, "helix")
        ],
        agent_id: "main",
        owner_id: "default",
        conversation_key: {"telegram", "chat_1", :root},
        chat_mode: :direct
      )

    assert [%{value: "helix"}] = result.admitted
  end
end
