defmodule FermixCore.ComputerHistory.RecallMachinesTest do
  # M97 §8.4: every note names the machine it happened on once the home has a
  # computer besides its own; a read can take one machine's notes alone; the
  # audit records which; a home that never had a computer reads as before.
  use ExUnit.Case, async: false

  alias FermixCore.ComputerHistory.Gate
  alias FermixCore.ComputerHistory.Recall
  alias FermixCore.Memory.Repo
  alias FermixCore.Tools.RecallActivity
  alias FermixTestSupport.SafeRm

  @now ~U[2026-11-11 15:00:00.000Z]
  @studio "studio-7f3a"
  @names %{@studio => "studio Mac", "" => "this computer"}

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-ch-recall-machines-#{unique}.db")
    repo = :"ch_recall_machines_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})
    on_exit(fn -> Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &SafeRm.rm/1) end)

    original = Application.get_env(:fermix_core, :computer_history)
    Application.put_env(:fermix_core, :computer_history, enabled: true, summarizer: :local)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:fermix_core, :computer_history)
        value -> Application.put_env(:fermix_core, :computer_history, value)
      end
    end)

    note!(repo, @studio, ~U[2026-11-11 09:00:00.000Z], "Drafted the Juniper lease reply.")
    note!(repo, "", ~U[2026-11-11 10:00:00.000Z], "Filed the gas bill.")
    %{repo: repo, db_path: db_path}
  end

  defp note!(repo, computer, at, summary) do
    ts = DateTime.to_unix(at, :millisecond)

    {:ok, _id} =
      Repo.computer_history_insert_memory(
        %{
          created_at: ts,
          provenance_from_ts: ts,
          provenance_to_ts: ts + 30 * 60_000,
          summary: summary,
          event_count: 3,
          model: "m",
          computer_id: computer
        },
        server: repo
      )
  end

  defp read(repo, opts),
    do: Recall.query("today", [repo: repo, now: @now, timezone: "Etc/UTC"] ++ opts)

  test "each note names its machine", %{repo: repo} do
    assert {:ok, text} = read(repo, machines: @names)
    assert text =~ "[studio Mac, Nov 11 09:00"
    assert text =~ "[this computer, Nov 11 10:00"
  end

  test "a home with no computer besides its own reads as it always has", %{repo: repo} do
    assert {:ok, text} = read(repo, machines: %{})
    assert text =~ "- [Nov 11 09:00"
    refute text =~ "studio Mac"
    refute text =~ "this computer"
  end

  test "one machine's notes alone, and the audit says which", %{repo: repo} = ctx do
    assert {:ok, text} = read(repo, machines: @names, computer: @studio)
    assert text =~ "Juniper lease"
    refute text =~ "gas bill"

    assert {:ok, text} = Recall.search("bill", repo: repo, machines: @names, computer: "")
    assert text =~ "gas bill"
    refute text =~ "Juniper"

    assert {:ok, _text} = read(repo, machines: @names)
    assert audited(ctx.db_path) == [@studio, "", nil]
  end

  defp audited(db_path) do
    {:ok, conn} = Exqlite.Sqlite3.open(db_path)

    try do
      {:ok, stmt} =
        Exqlite.Sqlite3.prepare(
          conn,
          "SELECT computer_id FROM computer_history_access ORDER BY id"
        )

      {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, stmt)
      :ok = Exqlite.Sqlite3.release(conn, stmt)
      List.flatten(rows)
    after
      :ok = Exqlite.Sqlite3.close(conn)
    end
  end

  test "the recent digest names the machine of each sitting", %{repo: repo} do
    digest = Recall.recent_digest(repo: repo, now: @now, timezone: "Etc/UTC", machines: @names)
    assert digest =~ "[studio Mac, Nov 11 09:00"
  end

  describe "recall_activity's computer" do
    defp permitted(repo) do
      context = %{
        agent_name: "main",
        conversation_key: {"cli", "owner", "root"},
        source_trust: :operator,
        computer_use_origin: :interactive,
        ordered_routes: [{%{provider: :ollama, base_url: "http://localhost:11434/v1"}, []}],
        memory_repo: repo,
        computer_history_machines: %{@studio => "studio Mac"}
      }

      Map.put(context, :computer_history_gate, Gate.snapshot(context, surfaces?: true))
    end

    test "names one computer, without case", %{repo: repo} do
      assert {:ok, %{success: true, output: output}} =
               RecallActivity.execute(
                 %{"about" => "lease", "computer" => "Studio MAC"},
                 permitted(repo)
               )

      assert output =~ "studio Mac"
      assert output =~ "Juniper lease"
    end

    test "the home's own machine is this computer", %{repo: repo} do
      assert {:ok, %{success: true, output: output}} =
               RecallActivity.execute(
                 %{"about" => "bill", "computer" => "this computer"},
                 permitted(repo)
               )

      assert output =~ "gas bill"

      assert {:ok, %{success: true, output: none}} =
               RecallActivity.execute(
                 %{"about" => "lease", "computer" => "this computer"},
                 permitted(repo)
               )

      refute none =~ "Juniper"
    end

    test "a computer the home does not have is named back with the ones it has", %{repo: repo} do
      assert {:ok, %{success: false, error: error}} =
               RecallActivity.execute(%{"computer" => "loft Linux"}, permitted(repo))

      assert error =~ "no computer named loft Linux"
      assert error =~ "studio Mac"
    end
  end
end
