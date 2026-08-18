defmodule FermixCore.ComputerHistory.ConversationTaintTest do
  @moduledoc """
  MILESTONE_32 §13.6 — the load-bearing fix: `ConversationStore` must PRESERVE
  the `history_tainted` marker on read (it previously stripped all metadata), or
  the strict taint would be invisible to compaction/replay.
  """
  use ExUnit.Case, async: true

  alias FermixCore.ComputerHistory.Taint
  alias FermixCore.Memory.ConversationStore

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
end
