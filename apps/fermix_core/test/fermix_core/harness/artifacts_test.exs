defmodule FermixCore.Harness.ArtifactsTest do
  # All writes land under per-test SafeRm tmp dirs and nothing touches the real
  # FERMIX_HOME. The free-space probe is injected everywhere EXCEPT the
  # not-yet-existing-root regression test, which must exercise the real `df`
  # path — injecting it everywhere is precisely how that bug escaped.
  use ExUnit.Case, async: true

  import Bitwise, only: [{:&&&, 2}]

  alias FermixCore.Harness.Artifacts

  @gb 1_073_741_824

  setup do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("harness-artifacts")
    runs_root = Path.join(root, "harness/runs")
    File.mkdir_p!(runs_root)
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)
    %{root: root, runs_root: runs_root}
  end

  describe "prepare/2" do
    test "creates the run dir 0700", %{runs_root: runs_root} do
      assert {:ok, %{dir: dir}} = Artifacts.prepare("hr_abc123", runs_root: runs_root)
      assert dir == Path.join(runs_root, "hr_abc123")
      assert File.dir?(dir)
      assert mode(dir) == 0o700
    end

    test "rejects a run id with path separators or traversal", %{runs_root: runs_root} do
      assert {:error, {:invalid_run_id, _}} = Artifacts.prepare("../escape", runs_root: runs_root)
      assert {:error, {:invalid_run_id, _}} = Artifacts.prepare("a/b", runs_root: runs_root)
    end
  end

  describe "0600 file writers" do
    setup %{runs_root: runs_root} do
      {:ok, %{dir: dir}} = Artifacts.prepare("hr_files01", runs_root: runs_root)
      %{dir: dir}
    end

    test "snapshot_prompt writes prompt.md 0600", %{dir: dir} do
      assert {:ok, path} = Artifacts.snapshot_prompt(dir, "the brief")
      assert path == Path.join(dir, "prompt.md")
      assert File.read!(path) == "the brief"
      assert mode(path) == 0o600
    end

    test "write_result writes result.txt 0600", %{dir: dir} do
      assert {:ok, path} = Artifacts.write_result(dir, "final answer")
      assert path == Artifacts.result_path(dir)
      assert File.read!(path) == "final answer"
      assert mode(path) == 0o600
    end

    test "the event spool opens 0600 and appends newline-terminated lines", %{dir: dir} do
      assert {:ok, io} = Artifacts.open_spool(dir)
      assert :ok = Artifacts.append_spool(io, ~s({"type":"a"}))
      assert :ok = Artifacts.append_spool(io, ~s({"type":"b"}))
      assert :ok = Artifacts.close_spool(io)

      path = Path.join(dir, "events.jsonl")
      assert File.read!(path) == ~s({"type":"a"}\n{"type":"b"}\n)
      assert mode(path) == 0o600
    end
  end

  describe "admission_check/1 — quota ceiling" do
    test "refuses when the store meets or exceeds the quota", %{runs_root: runs_root} do
      run_dir = Path.join(runs_root, "hr_big")
      File.mkdir_p!(run_dir)
      File.write!(Path.join(run_dir, "data.bin"), String.duplicate("x", 100))

      assert {:error, {:artifact_quota, detail}} =
               Artifacts.admission_check(runs_root: runs_root, quota_gb: 0, min_free_gb: 0)

      assert detail.kind == :quota_exceeded
      assert detail.used_bytes == 100
      assert detail.quota_bytes == 0
    end

    test "passes under quota when the free floor is disabled", %{runs_root: runs_root} do
      assert :ok = Artifacts.admission_check(runs_root: runs_root, quota_gb: 100, min_free_gb: 0)
    end
  end

  describe "admission_check/1 — free-space floor" do
    test "refuses below the min-free floor", %{runs_root: runs_root} do
      free = fn _root -> {:ok, 500_000_000} end

      assert {:error, {:artifact_quota, detail}} =
               Artifacts.admission_check(
                 runs_root: runs_root,
                 quota_gb: 100,
                 min_free_gb: 1,
                 free_bytes: free
               )

      assert detail.kind == :below_min_free
      assert detail.free_bytes == 500_000_000
      assert detail.min_free_bytes == @gb
    end

    test "passes above the min-free floor", %{runs_root: runs_root} do
      free = fn _root -> {:ok, 5 * @gb} end

      assert :ok =
               Artifacts.admission_check(
                 runs_root: runs_root,
                 quota_gb: 100,
                 min_free_gb: 1,
                 free_bytes: free
               )
    end

    test "an unknown free space fails loud rather than admitting blind", %{runs_root: runs_root} do
      free = fn _root -> {:error, :df_unavailable} end

      assert {:error, {:artifact_quota, %{kind: :free_space_unknown, reason: :df_unavailable}}} =
               Artifacts.admission_check(
                 runs_root: runs_root,
                 quota_gb: 100,
                 min_free_gb: 1,
                 free_bytes: free
               )
    end

    test "the real df probe resolves against a runs root that does not exist yet",
         %{runs_root: runs_root} do
      # Regression: `prepare/2` creates the runs root AFTER admission, so on a
      # fresh FERMIX_HOME the probe target is absent. `df` exits non-zero on a
      # missing path, which failed closed as :free_space_unknown and refused
      # EVERY run — including the machine's first, which would then never create
      # the root. Deliberately uses the REAL probe (no :free_bytes injection);
      # every other test here injects one, which is why this escaped.
      fresh = Path.join(runs_root, "not/created/yet")
      refute File.exists?(fresh)

      result = Artifacts.admission_check(runs_root: fresh, quota_gb: 100, min_free_gb: 1)

      # Host-independent: a real probe either admits or reports a genuinely low
      # disk. Only :free_space_unknown means the probe itself failed.
      refute match?({:error, {:artifact_quota, %{kind: :free_space_unknown}}}, result)

      assert result == :ok or
               match?({:error, {:artifact_quota, %{kind: :below_min_free}}}, result)
    end

    test "a zero floor never consults the probe", %{runs_root: runs_root} do
      free = fn _root -> {:error, :should_not_be_called} end

      assert :ok =
               Artifacts.admission_check(
                 runs_root: runs_root,
                 quota_gb: 100,
                 min_free_gb: 0,
                 free_bytes: free
               )
    end
  end

  describe "gc/2" do
    test "removes run dirs older than retention and keeps fresh ones", %{runs_root: runs_root} do
      {:ok, %{dir: old}} = Artifacts.prepare("hr_old0001", runs_root: runs_root)
      {:ok, %{dir: fresh}} = Artifacts.prepare("hr_new0001", runs_root: runs_root)

      File.write!(Path.join(old, "prompt.md"), "x")
      forty_days_ago = System.os_time(:second) - 40 * 86_400
      File.touch!(old, forty_days_ago)

      assert {:ok, %{removed: 1}} =
               Artifacts.gc(DateTime.utc_now(), runs_root: runs_root, retention_days: 30)

      refute File.exists?(old)
      assert File.dir?(fresh)
    end

    test "never follows a symlink and never deletes a non-directory entry", %{
      runs_root: runs_root
    } do
      target = FermixTestSupport.SafeRm.make_tmp_dir!("harness-gc-target")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(target) end)

      link = Path.join(runs_root, "hr_link0001")
      File.ln_s!(target, link)
      plain = Path.join(runs_root, "stray.txt")
      File.write!(plain, "keep")

      old = System.os_time(:second) - 40 * 86_400
      File.touch!(link, old)
      File.touch!(plain, old)

      assert {:ok, %{removed: 0}} =
               Artifacts.gc(DateTime.utc_now(), runs_root: runs_root, retention_days: 30)

      assert File.dir?(target)
      assert File.exists?(plain)
    end

    test "a missing runs root is a no-op" do
      missing =
        Path.join(FermixTestSupport.SafeRm.make_tmp_dir!("harness-gc-missing"), "nope/runs")

      assert {:ok, %{removed: 0}} =
               Artifacts.gc(DateTime.utc_now(), runs_root: missing, retention_days: 30)
    end
  end

  defp mode(path) do
    {:ok, %File.Stat{mode: mode}} = File.stat(path)
    mode &&& 0o777
  end
end
