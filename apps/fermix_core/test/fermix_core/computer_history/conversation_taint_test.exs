defmodule FermixCore.ComputerHistory.ConversationTaintTest do
  @moduledoc """
  MILESTONE_32 §13.6 — the load-bearing fix: `ConversationStore` must PRESERVE
  the `history_tainted` marker on read (it previously stripped all metadata), or
  the strict taint would be invisible to compaction/replay.
  """
  # async: false — the end-to-end tests write the global
  # `:fermix_core, :computer_history` app env, which async siblings (Gate reads
  # `Config.current()`) would race (the leaked-app-env pitfall class).
  use ExUnit.Case, async: false

  alias FermixCore.ComputerHistory.Taint
  alias FermixCore.Memory.ConversationStore
  alias FermixTestSupport.ComputerHistoryCanary

  @key {"cli", "owner", :root}

  setup do
    name = :"ch_taint_store_#{System.unique_integer([:positive])}"
    start_supervised!({ConversationStore, name: name, max_messages: 10, repo: nil})
    %{store: name}
  end

  test "a taint-stamped assistant message keeps its marker through get_history", %{store: store} do
    :ok =
      ConversationStore.add_message(@key, "assistant", "You read the Q3 report.",
        server: store,
        metadata: Taint.metadata()
      )

    :ok = ConversationStore.add_message(@key, "user", "what next?", server: store)

    history = ConversationStore.get_history(@key, server: store)

    tainted = Enum.find(history, &(&1.role == "assistant"))
    assert tainted.history_tainted == true

    # A plain message carries no taint field.
    clean = Enum.find(history, &(&1.role == "user"))
    refute Map.has_key?(clean, :history_tainted)
  end

  test "an unstamped assistant message carries no taint marker", %{store: store} do
    :ok = ConversationStore.add_message(@key, "assistant", "ordinary reply", server: store)

    [message] = ConversationStore.get_history(@key, server: store)
    refute Map.has_key?(message, :history_tainted)
  end

  test "end-to-end: a preserved marker is masked on an ungranted-remote chain", %{store: store} do
    Application.put_env(:fermix_core, :computer_history, enabled: true, summarizer: :local)
    on_exit(fn -> Application.delete_env(:fermix_core, :computer_history) end)

    :ok =
      ConversationStore.add_message(@key, "assistant", "You read the Q3 report.",
        server: store,
        metadata: Taint.metadata()
      )

    history = ConversationStore.get_history(@key, server: store)
    remote_chain = [{%{provider: :openai, base_url: "https://api.openai.com/v1"}, []}]

    [masked] = Taint.mask_for_chain(history, remote_chain)
    refute masked.content =~ "Q3 report"
    assert masked.content =~ "omitted"
  end

  test "the marker survives replace_history (compaction's retained tail)", %{store: store} do
    # Pre-fix, `normalize_history_message/1` rebuilt every message as only
    # role/content/timestamp — so ANY auto-compaction erased the marker from
    # the verbatim-retained tail and the turn could later be re-sent unmasked
    # on an ungranted-remote chain.
    :ok =
      ConversationStore.add_message(@key, "assistant", "You read the Q3 report.",
        server: store,
        metadata: Taint.metadata()
      )

    history = ConversationStore.get_history(@key, server: store)
    assert [%{history_tainted: true}] = history

    replacement = history ++ [%{role: "user", content: "and then?"}]
    :ok = ConversationStore.replace_history(@key, replacement, server: store)

    replaced = ConversationStore.get_history(@key, server: store)
    tainted = Enum.find(replaced, &(&1.role == "assistant"))
    assert tainted.history_tainted == true
    refute Map.has_key?(Enum.find(replaced, &(&1.role == "user")), :history_tainted)
  end

  test "canary egress proof (§14.2): a tainted turn's content never reaches an " <>
         "ungranted-remote chain, even after replace_history",
       %{store: store} do
    Application.put_env(:fermix_core, :computer_history, enabled: true, summarizer: :local)
    on_exit(fn -> Application.delete_env(:fermix_core, :computer_history) end)

    canary = ComputerHistoryCanary.token("replay")

    :ok =
      ConversationStore.add_message(@key, "assistant", "You were editing #{canary} in Numbers.",
        server: store,
        metadata: Taint.metadata()
      )

    # Simulate compaction's replace, then build the provider-bound copy for an
    # ungranted-remote chain — the canary must be absent from every byte of it.
    :ok =
      ConversationStore.replace_history(@key, ConversationStore.get_history(@key, server: store),
        server: store
      )

    history = ConversationStore.get_history(@key, server: store)
    assert ComputerHistoryCanary.present?(history, canary)

    remote_chain = [{%{provider: :openai, base_url: "https://api.openai.com/v1"}, []}]
    provider_bound = Taint.mask_for_chain(history, remote_chain)
    assert ComputerHistoryCanary.absent?(provider_bound, canary)

    # And a permitted (local) chain still carries it — masking is chain-scoped.
    local_chain = [{%{provider: :ollama, base_url: "http://localhost:11434/v1"}, []}]
    assert ComputerHistoryCanary.present?(Taint.mask_for_chain(history, local_chain), canary)
  end
end
