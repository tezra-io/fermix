defmodule FermixChannels.Gateway.Commands.HistoryTest do
  @moduledoc "MILESTONE_32 §5.3 — the /history owner management command."
  use ExUnit.Case, async: false

  alias FermixChannels.Gateway.Authorization, as: IngressAuthorization
  alias FermixChannels.Gateway.Commands.History
  alias FermixChannels.Gateway.Message
  alias FermixCore.ComputerHistory.Config, as: ComputerHistoryConfig
  alias FermixCore.Memory.Repo

  defp message(content) do
    Message.new!(%{
      id: "m1",
      content: content,
      sender: "a",
      channel: "telegram",
      chat_id: "c1",
      reply_target: "c1"
    })
  end

  defp reply_fn(pid), do: fn {:text, text} -> send(pid, {:reply, text}) end

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-history-cmd-#{unique}.db")
    repo_name = :"history_cmd_repo_#{unique}"
    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    original = Application.get_env(:fermix_core, :computer_history)
    Application.put_env(:fermix_core, :computer_history, enabled: true)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:fermix_core, :computer_history)
        value -> Application.put_env(:fermix_core, :computer_history, value)
      end

      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{ctx: %{computer_history_repo: repo_name}, repo: repo_name}
  end

  test "metadata: owner-only, no aliases" do
    assert History.name() == "history"
    assert History.aliases() == []
    ctx = %{authorization: %IngressAuthorization{role: :operator, trust: :operator}}
    assert :ok = History.authorize(message(""), %{}, ctx)
    assert {:error, :unauthorized} = History.authorize(message(""), %{}, %{})
  end

  test "status replies with a non-empty overview", %{ctx: ctx} do
    assert :ok = History.execute(message("status"), reply_fn(self()), ctx)
    assert_receive {:reply, text}
    assert is_binary(text) and text != ""
  end

  test "pause persists a pause horizon", %{ctx: ctx, repo: repo} do
    assert :ok = History.execute(message("pause 30m"), reply_fn(self()), ctx)
    assert_receive {:reply, text}
    assert text =~ "paused until"

    {:ok, state} = Repo.computer_history_fetch_state(server: repo)
    assert is_binary(state.pause_until)
  end

  test "pause without a duration shows usage", %{ctx: ctx} do
    assert :ok = History.execute(message("pause"), reply_fn(self()), ctx)
    assert_receive {:reply, text}
    assert text =~ "Usage"
  end

  test "purge erases the spool and acknowledges what it cannot reach", %{ctx: ctx, repo: repo} do
    events = [%{boot_id: "b1", source_seq: 1, ts: 1_000, type: "app.activated"}]
    {:ok, 1} = Repo.computer_history_insert_events(events, server: repo)

    assert :ok = History.execute(message("purge all"), reply_fn(self()), ctx)
    assert_receive {:reply, text}
    assert text =~ "Purged"
    assert text =~ "cannot reach"

    assert {:ok, 0} = Repo.computer_history_count_events(server: repo)
  end

  test "purge with a bad window shows usage", %{ctx: ctx} do
    assert :ok = History.execute(message("purge forever"), reply_fn(self()), ctx)
    assert_receive {:reply, text}
    assert text =~ "Usage"
  end

  test "off flips the enable bit (un-advertises next turn)", %{ctx: ctx} do
    assert :ok = History.execute(message("off"), reply_fn(self()), ctx)
    assert_receive {:reply, text}
    assert text =~ "disabled"

    refute ComputerHistoryConfig.enabled?()
  end

  test "an unknown subcommand shows usage", %{ctx: ctx} do
    assert :ok = History.execute(message("wat"), reply_fn(self()), ctx)
    assert_receive {:reply, text}
    assert text =~ "Usage"
  end
end
