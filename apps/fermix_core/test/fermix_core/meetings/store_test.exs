defmodule FermixCore.Meetings.StoreTest do
  use ExUnit.Case, async: true

  alias FermixCore.Meetings.Store
  alias FermixCore.Memory.Repo

  @now ~U[2026-08-17 10:15:00Z]

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-meetings-store-#{unique}.db")
    repo_name = :"memory_repo_meetings_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], fn path ->
        FermixTestSupport.SafeRm.rm(path)
      end)
    end)

    %{repo: repo_name}
  end

  describe "insert/2" do
    test "records a requested meeting", %{repo: repo} do
      assert {:ok, meeting} = Store.insert(attrs(), server: repo)

      assert meeting.id == "mtg_AbCdEfGhIjK"
      assert meeting.platform == "meet"
      assert meeting.status == "requested"
      assert meeting.requested_by == "operator"
      assert meeting.origin_session_id == "telegram:123:root"
      assert meeting.started_at == nil
      assert meeting.artifact_dir == nil
      assert meeting.created_at == "2026-08-17T10:15:00.000000Z"
    end

    test "refuses an id that is not the minted shape", %{repo: repo} do
      assert {:error, {:invalid, :id, :malformed}} =
               Store.insert(attrs(id: "meeting-1"), server: repo)
    end

    test "refuses an unknown platform", %{repo: repo} do
      assert {:error, {:invalid, :platform, :unknown}} =
               Store.insert(attrs(platform: "teams"), server: repo)
    end

    test "refuses an oversize url or title", %{repo: repo} do
      assert {:error, {:invalid, :url, :too_long}} =
               Store.insert(attrs(url: String.duplicate("u", 2_001)), server: repo)

      assert {:error, {:invalid, :title, :too_long}} =
               Store.insert(attrs(title: String.duplicate("t", 241)), server: repo)
    end

    test "refuses a caller that is not the operator", %{repo: repo} do
      assert {:error, {:invalid, :requested_by, :not_operator}} =
               Store.insert(attrs(requested_by: "guest"), server: repo)
    end

    test "refuses a timestamp that is not fixed-width UTC", %{repo: repo} do
      assert {:error, {:invalid, :created_at, :not_fixed_width}} =
               Store.insert(attrs(created_at: "2026-08-17"), server: repo)
    end
  end

  describe "update_status/4" do
    test "writes the status and its side fields", %{repo: repo} do
      {:ok, _meeting} = Store.insert(attrs(), server: repo)

      assert {:ok, updated} =
               Store.update_status(
                 "mtg_AbCdEfGhIjK",
                 "capturing",
                 %{started_at: @now, artifact_dir: "/tmp/meetings/mtg_AbCdEfGhIjK"},
                 server: repo
               )

      assert updated.status == "capturing"
      assert updated.started_at == "2026-08-17T10:15:00.000000Z"
      assert updated.artifact_dir == "/tmp/meetings/mtg_AbCdEfGhIjK"
    end

    test "refuses an unknown field rather than dropping it", %{repo: repo} do
      {:ok, _meeting} = Store.insert(attrs(), server: repo)

      assert {:error, {:invalid, :fields, {:unknown_key, :end_reason}}} =
               Store.update_status("mtg_AbCdEfGhIjK", "failed", %{end_reason: :alone},
                 server: repo
               )
    end

    test "refuses an unknown status and an oversize error", %{repo: repo} do
      {:ok, _meeting} = Store.insert(attrs(), server: repo)

      assert {:error, {:invalid, :status, :unknown}} =
               Store.update_status("mtg_AbCdEfGhIjK", "wandering", %{}, server: repo)

      assert {:error, {:invalid, :error, :too_long}} =
               Store.update_status(
                 "mtg_AbCdEfGhIjK",
                 "failed",
                 %{error: String.duplicate("e", 501)},
                 server: repo
               )
    end

    test "is :not_found for an unknown meeting", %{repo: repo} do
      assert {:error, :not_found} =
               Store.update_status("mtg_zzzzzzzzzzz", "failed", %{}, server: repo)
    end
  end

  describe "get/2 and list/2" do
    test "get returns the row, or :not_found", %{repo: repo} do
      {:ok, _meeting} = Store.insert(attrs(), server: repo)

      assert {:ok, %{id: "mtg_AbCdEfGhIjK"}} = Store.get("mtg_AbCdEfGhIjK", server: repo)
      assert {:error, :not_found} = Store.get("mtg_zzzzzzzzzzz", server: repo)
    end

    test "the active scope sees only live rows, newest first", %{repo: repo} do
      seed(repo, "mtg_00000000001", "2026-08-17T10:00:00.000000Z", "capturing")
      seed(repo, "mtg_00000000002", "2026-08-17T11:00:00.000000Z", "joining")
      seed(repo, "mtg_00000000003", "2026-08-17T12:00:00.000000Z", "delivered")

      assert {:ok, active} = Store.list(%{scope: :active}, server: repo)
      assert Enum.map(active, & &1.id) == ["mtg_00000000002", "mtg_00000000001"]

      assert {:ok, recent} = Store.list(%{scope: :recent}, server: repo)

      assert Enum.map(recent, & &1.id) == [
               "mtg_00000000003",
               "mtg_00000000002",
               "mtg_00000000001"
             ]
    end

    test "the limit is clamped to the list maximum", %{repo: repo} do
      seed(repo, "mtg_00000000001", "2026-08-17T10:00:00.000000Z", "delivered")
      seed(repo, "mtg_00000000002", "2026-08-17T11:00:00.000000Z", "delivered")

      assert {:ok, [%{id: "mtg_00000000002"}]} = Store.list(%{limit: 1}, server: repo)
      assert {:ok, both} = Store.list(%{limit: 5_000}, server: repo)
      assert length(both) == 2

      assert {:error, {:invalid, :limit, :not_a_positive_integer}} =
               Store.list(%{limit: 0}, server: repo)

      assert {:error, {:invalid, :scope, :unknown}} =
               Store.list(%{scope: :everything}, server: repo)
    end
  end

  describe "sweep_live/2" do
    test "fails exactly the live rows and returns their ids", %{repo: repo} do
      seed(repo, "mtg_00000000001", "2026-08-17T10:00:00.000000Z", "capturing")
      seed(repo, "mtg_00000000002", "2026-08-17T11:00:00.000000Z", "summarizing")
      seed(repo, "mtg_00000000003", "2026-08-17T12:00:00.000000Z", "delivered")
      seed(repo, "mtg_00000000004", "2026-08-17T13:00:00.000000Z", "denied")

      assert {:ok, ids} = Store.sweep_live("daemon_restarted", server: repo)
      assert Enum.sort(ids) == ["mtg_00000000001", "mtg_00000000002"]

      assert {:ok, swept} = Store.get("mtg_00000000001", server: repo)
      assert swept.status == "failed"
      assert swept.error == "daemon_restarted"
      assert is_binary(swept.ended_at)

      assert {:ok, %{status: "delivered", error: nil}} =
               Store.get("mtg_00000000003", server: repo)

      assert {:ok, %{status: "denied"}} = Store.get("mtg_00000000004", server: repo)
      assert {:ok, []} = Store.sweep_live("daemon_restarted", server: repo)
    end
  end

  test "live_statuses/0 names every status a Session can hold" do
    statuses = Store.live_statuses()

    assert "requested" in statuses
    assert "capturing" in statuses
    assert "summarizing" in statuses
    refute "delivered" in statuses
    refute "failed" in statuses
  end

  defp attrs(overrides \\ []) do
    %{
      id: "mtg_AbCdEfGhIjK",
      platform: "meet",
      url: "https://meet.google.com/abc-defg-hij",
      title: "Weekly sync",
      requested_by: "operator",
      origin_session_id: "telegram:123:root",
      created_at: @now
    }
    |> Map.merge(Map.new(overrides))
  end

  defp seed(repo, id, created_at, status) do
    {:ok, _meeting} = Store.insert(attrs(id: id, created_at: created_at), server: repo)
    {:ok, row} = Store.update_status(id, status, %{}, server: repo)
    row
  end
end
