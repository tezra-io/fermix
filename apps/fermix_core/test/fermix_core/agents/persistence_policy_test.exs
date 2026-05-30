defmodule FermixCore.Agents.PersistencePolicyTest do
  use ExUnit.Case, async: true

  alias FermixCore.Agents.PersistencePolicy

  setup do
    suffix = System.unique_integer([:positive])
    base_dir = Path.join(System.tmp_dir!(), "fermix-journals-#{suffix}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(base_dir) end)

    %{base_dir: base_dir}
  end

  describe "skill_journal_policy/0" do
    test "defines mandatory terminal-state persistence with manual retention" do
      assert %{
               mandatory: true,
               write_on_statuses: [:completed, :failed, :timed_out, :crashed],
               write_before_result?: true,
               retention: :retain_until_manual_cleanup,
               mutation: :write_once,
               failure_mode: :fail_closed
             } = PersistencePolicy.skill_journal_policy()
    end
  end

  describe "write_skill_journal/2" do
    test "writes a completed journal to disk", %{base_dir: base_dir} do
      timestamp = DateTime.from_naive!(~N[2026-04-07 07:36:00], "Etc/UTC")

      assert {:ok, path} =
               PersistencePolicy.write_skill_journal(
                 valid_entry(%{
                   session_id: "sess-123",
                   invoked_by: "main-agent",
                   duration_ms: 45_000,
                   context: "Failure came from config_test.exs.",
                   files_changed: ["apps/fermix_core/test/fermix_core/config_test.exs"],
                   result: "Focused test now passes.",
                   timestamp: timestamp
                 }),
                 base_dir: base_dir
               )

      assert path ==
               Path.join([
                 base_dir,
                 "coding-skill",
                 "2026-04-07_07-36-00_fix-failing-config-test.md"
               ])

      assert File.exists?(path)

      assert File.read!(path) =~ "# coding-skill — Fix failing config test"
      assert File.read!(path) =~ "**Status:** completed"
      assert File.read!(path) =~ "## Files Changed"
      assert File.read!(path) =~ "Focused test now passes."
    end

    test "writes a failed journal instead of skipping persistence on skill errors", %{
      base_dir: base_dir
    } do
      assert {:ok, path} =
               PersistencePolicy.write_skill_journal(
                 valid_entry(%{
                   skill: "review-skill",
                   task: "Audit crash path",
                   summary: "The skill crashed while reading the repo state.",
                   status: :failed,
                   failure: "tool exited with status 1"
                 }),
                 base_dir: base_dir
               )

      contents = File.read!(path)

      assert contents =~ "**Status:** failed"
      assert contents =~ "## Failure"
      assert contents =~ "tool exited with status 1"
      refute contents =~ "## Result"
    end

    test "enforces write_once by rejecting later writes to the same journal path", %{
      base_dir: base_dir
    } do
      timestamp = DateTime.from_naive!(~N[2026-04-07 07:36:00], "Etc/UTC")

      assert {:ok, path} =
               PersistencePolicy.write_skill_journal(
                 valid_entry(%{timestamp: timestamp}),
                 base_dir: base_dir
               )

      assert {:error, {:journal_write_failed, :completed, :eexist}} =
               PersistencePolicy.write_skill_journal(
                 valid_entry(%{
                   summary: "A later invocation should not overwrite the first journal.",
                   result: "This should never hit disk.",
                   timestamp: timestamp
                 }),
                 base_dir: base_dir
               )

      contents = File.read!(path)
      assert contents =~ "Updated the config lookup and reran the focused test."
      refute contents =~ "This should never hit disk."
    end

    test "fails closed when the journal cannot be written", %{base_dir: base_dir} do
      File.mkdir_p!(Path.dirname(base_dir))
      File.write!(base_dir, "occupied")

      assert {:error, {:journal_write_failed, :completed, reason}} =
               PersistencePolicy.write_skill_journal(
                 valid_entry(),
                 base_dir: base_dir
               )

      assert reason in [:eexist, :enotdir]
    end
  end

  describe "write_skill_journal/2 validation" do
    test "rejects missing required fields", %{base_dir: base_dir} do
      assert {:error, {:invalid_journal_entry, {:missing_or_invalid, :skill}}} =
               PersistencePolicy.write_skill_journal(
                 valid_entry() |> Map.delete(:skill),
                 base_dir: base_dir
               )

      assert {:error, {:invalid_journal_entry, {:missing_or_invalid, :task}}} =
               PersistencePolicy.write_skill_journal(
                 valid_entry() |> Map.delete(:task),
                 base_dir: base_dir
               )

      assert {:error, {:invalid_journal_entry, {:missing_or_invalid, :summary}}} =
               PersistencePolicy.write_skill_journal(
                 valid_entry() |> Map.delete(:summary),
                 base_dir: base_dir
               )
    end

    test "rejects invalid required field values", %{base_dir: base_dir} do
      assert {:error, {:invalid_journal_entry, {:missing_or_invalid, :skill}}} =
               PersistencePolicy.write_skill_journal(
                 valid_entry(%{skill: ""}),
                 base_dir: base_dir
               )

      assert {:error, {:invalid_journal_entry, {:missing_or_invalid, :task}}} =
               PersistencePolicy.write_skill_journal(
                 valid_entry(%{task: 123}),
                 base_dir: base_dir
               )

      assert {:error, {:invalid_journal_entry, {:missing_or_invalid, :summary}}} =
               PersistencePolicy.write_skill_journal(
                 valid_entry(%{summary: nil}),
                 base_dir: base_dir
               )
    end

    test "rejects invalid status", %{base_dir: base_dir} do
      assert {:error, {:invalid_journal_entry, {:invalid_status, :running}}} =
               PersistencePolicy.write_skill_journal(
                 valid_entry(%{status: :running}),
                 base_dir: base_dir
               )
    end

    test "rejects invalid optional string fields", %{base_dir: base_dir} do
      assert {:error, {:invalid_journal_entry, {:invalid, :context}}} =
               PersistencePolicy.write_skill_journal(
                 valid_entry(%{context: :not_a_string}),
                 base_dir: base_dir
               )

      assert {:error, {:invalid_journal_entry, {:invalid, :failure}}} =
               PersistencePolicy.write_skill_journal(
                 valid_entry(%{failure: 42}),
                 base_dir: base_dir
               )

      assert {:error, {:invalid_journal_entry, {:invalid, :invoked_by}}} =
               PersistencePolicy.write_skill_journal(
                 valid_entry(%{invoked_by: %{agent: "main-agent"}}),
                 base_dir: base_dir
               )

      assert {:error, {:invalid_journal_entry, {:invalid, :result}}} =
               PersistencePolicy.write_skill_journal(
                 valid_entry(%{result: [:not, :a, :string]}),
                 base_dir: base_dir
               )

      assert {:error, {:invalid_journal_entry, {:invalid, :session_id}}} =
               PersistencePolicy.write_skill_journal(
                 valid_entry(%{session_id: 99}),
                 base_dir: base_dir
               )
    end

    test "rejects invalid duration and files_changed values", %{base_dir: base_dir} do
      assert {:error, {:invalid_journal_entry, {:invalid, :duration_ms}}} =
               PersistencePolicy.write_skill_journal(
                 valid_entry(%{duration_ms: -1}),
                 base_dir: base_dir
               )

      assert {:error, {:invalid_journal_entry, {:invalid, :files_changed}}} =
               PersistencePolicy.write_skill_journal(
                 valid_entry(%{files_changed: ["ok.md", 12]}),
                 base_dir: base_dir
               )

      assert {:error, {:invalid_journal_entry, {:invalid, :files_changed}}} =
               PersistencePolicy.write_skill_journal(
                 valid_entry(%{files_changed: "apps/fermix_core/test/example.exs"}),
                 base_dir: base_dir
               )
    end

    test "rejects invalid timestamp values", %{base_dir: base_dir} do
      assert {:error, {:invalid_journal_entry, {:invalid, :timestamp}}} =
               PersistencePolicy.write_skill_journal(
                 valid_entry(%{timestamp: ~N[2026-04-07 07:36:00]}),
                 base_dir: base_dir
               )
    end
  end

  describe "telemetry" do
    test "emits [:fermix, :skill, :journal_write] on success", %{base_dir: base_dir} do
      handler_id = attach_telemetry()

      assert {:ok, path} =
               PersistencePolicy.write_skill_journal(
                 valid_entry(%{session_id: "sess-telemetry"}),
                 base_dir: base_dir
               )

      assert_receive {:telemetry, [:fermix, :skill, :journal_write], measurements, metadata}
      assert measurements.bytes == byte_size(File.read!(path))
      assert metadata.skill == "coding-skill"
      assert metadata.session_id == "sess-telemetry"
      assert metadata.path == path

      :telemetry.detach(handler_id)
    end
  end

  describe "agent_snapshot_policy/0" do
    test "defines snapshot persistence as disabled in M2" do
      assert %{
               enabled?: false,
               mandatory: false,
               write_on_statuses: [],
               restore_on_restart?: false,
               retention: :none,
               failure_mode: :reject_attempt
             } = PersistencePolicy.agent_snapshot_policy()
    end
  end

  describe "snapshot persistence" do
    test "rejects explicit snapshot persistence and restore attempts" do
      assert {:error, :snapshot_persistence_disabled} =
               PersistencePolicy.persist_agent_snapshot(%{agent: "main-agent"})

      assert {:error, :snapshot_persistence_disabled} =
               PersistencePolicy.restore_agent_snapshot("main-agent")
    end
  end

  defp valid_entry(overrides \\ %{}) do
    Map.merge(
      %{
        skill: "coding-skill",
        task: "Fix failing config test",
        summary: "Updated the config lookup and reran the focused test.",
        status: :completed
      },
      overrides
    )
  end

  defp attach_telemetry do
    handler_id = "test-skill-journal-write-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:fermix, :skill, :journal_write],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    handler_id
  end
end
