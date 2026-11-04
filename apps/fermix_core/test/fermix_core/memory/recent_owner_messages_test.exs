defmodule FermixCore.Memory.RecentOwnerMessagesTest do
  @moduledoc """
  `Repo.recent_owner_messages/4`: the owner's newest words in one conversation
  since an instant, oldest first, read with the memory review's filter, so a
  guest's, a forwarded, a spoken or a coding run's message is never among them.
  """
  use ExUnit.Case, async: true

  alias FermixCore.Memory.Repo

  # Every value here is invented.
  @selector %{
    agent_id: "main",
    owner_id: "default",
    channel: "telegram",
    chat_id: "52017",
    thread_scope: "root"
  }

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-recent-owner-messages-#{unique}.db")
    repo = :"recent_owner_messages_repo_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo}
  end

  test "the newest messages since the instant come back oldest first, at most the limit", %{
    repo: repo
  } do
    insert!(repo, ~U[2031-03-01 08:00:00Z], "before the window")
    insert!(repo, ~U[2031-03-03 08:00:00Z], "first in the window")
    insert!(repo, ~U[2031-03-03 09:00:00Z], "second in the window")
    insert!(repo, ~U[2031-03-03 10:00:00Z], "third in the window")

    assert {:ok, rows} =
             Repo.recent_owner_messages(@selector, ~U[2031-03-02 00:00:00Z], 2, server: repo)

    assert Enum.map(rows, & &1.content) == ["second in the window", "third in the window"]
    assert [%{created_at: ~U[2031-03-03 09:00:00Z]} | _] = rows
  end

  test "only the owner's own words in this conversation", %{repo: repo} do
    insert!(repo, ~U[2031-03-03 08:00:00Z], "owner")
    insert!(repo, ~U[2031-03-03 08:01:00Z], "assistant", %{}, role: "assistant")
    insert!(repo, ~U[2031-03-03 08:02:00Z], "guest", %{guest: true})
    insert!(repo, ~U[2031-03-03 08:03:00Z], "forwarded", %{forwarded: true})
    insert!(repo, ~U[2031-03-03 08:04:00Z], "coding run", %{harness_continuation: true})
    insert!(repo, ~U[2031-03-03 08:05:00Z], "spoken", %{spoken: true, call_uuid: "call-2b9d"})
    insert!(repo, ~U[2031-03-03 08:06:00Z], "other chat", %{}, chat_id: "52018")
    insert!(repo, ~U[2031-03-03 08:07:00Z], "other thread", %{}, thread_scope: "7")

    assert {:ok, [%{content: "owner"}]} =
             Repo.recent_owner_messages(@selector, ~U[2031-03-02 00:00:00Z], 10, server: repo)
  end

  defp insert!(repo, at, content, metadata \\ %{}, overrides \\ []) do
    attrs =
      Map.merge(
        Map.merge(@selector, %{
          sender: "owner",
          role: "user",
          kind: "chat_message",
          content: content,
          metadata: metadata,
          created_at: at
        }),
        Map.new(overrides)
      )

    {:ok, _row} = Repo.insert_message(attrs, server: repo)
  end
end
