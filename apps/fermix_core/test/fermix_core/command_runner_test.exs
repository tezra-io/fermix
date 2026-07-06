defmodule FermixCore.CommandRunnerTest do
  use ExUnit.Case, async: true

  alias FermixCore.CommandRunner

  setup do
    sh = System.find_executable("sh") || "/bin/sh"
    %{sh: sh}
  end

  test "captures stdout on a successful command", %{sh: sh} do
    assert {:ok, %{exit: 0, stdout: "hello\n", truncated?: false}} =
             CommandRunner.run(sh, ["-c", "echo hello"], timeout_ms: 2_000)
  end

  test "surfaces non-zero exit codes", %{sh: sh} do
    assert {:ok, %{exit: 7, stdout: "", truncated?: false}} =
             CommandRunner.run(sh, ["-c", "exit 7"], timeout_ms: 2_000)
  end

  test "captures stderr alongside stdout", %{sh: sh} do
    assert {:ok, %{exit: 0, stdout: out, truncated?: false}} =
             CommandRunner.run(sh, ["-c", "echo to-stdout; echo to-stderr 1>&2"],
               timeout_ms: 2_000
             )

    assert out =~ "to-stdout"
    assert out =~ "to-stderr"
  end

  test "returns executable_not_found for a missing path" do
    path = "/no/such/binary-#{System.unique_integer([:positive])}"
    assert {:error, {:executable_not_found, ^path}} = CommandRunner.run(path, [])
  end

  test "honours cwd by listing the requested directory", %{sh: sh} do
    dir = Path.join(System.tmp_dir!(), "fermix_runner_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "marker.txt"), "x")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

    assert {:ok, %{exit: 0, stdout: out}} =
             CommandRunner.run(sh, ["-c", "ls"], cwd: dir, timeout_ms: 2_000)

    assert out =~ "marker.txt"
  end

  test "passes env entries through verbatim", %{sh: sh} do
    assert {:ok, %{exit: 0, stdout: "abc\n"}} =
             CommandRunner.run(sh, ["-c", "echo \"$FERMIX_TEST_VAR\""],
               env: [{"FERMIX_TEST_VAR", "abc"}],
               timeout_ms: 2_000
             )
  end

  test "kills the OS child on timeout and returns :timeout", %{sh: sh} do
    marker =
      Path.join(System.tmp_dir!(), "fermix_runner_kill_#{System.unique_integer([:positive])}")

    on_exit(fn -> FermixTestSupport.SafeRm.rm(marker) end)

    assert {:error, {:timeout, 100}} =
             CommandRunner.run(sh, ["-c", "sleep 5; touch #{marker}"], timeout_ms: 100)

    Process.sleep(500)
    refute File.exists?(marker), "child outlived the BEAM task — sleep ran to completion"
  end

  test "discards late child output on timeout so it never leaks to the caller", %{sh: sh} do
    # Regression: a secret helper (`security`) that finishes just after the
    # timeout used to leave its output — the raw secret — in the caller's mailbox,
    # which crashed a GenServer caller (SetupLive/BootReport) and wrote the secret
    # to the crash log. The child here ignores SIGTERM and prints during the kill
    # grace, then exits; the runner must drain that output, leaving the caller's
    # mailbox with no stray port message.
    assert {:error, {:timeout, 20}} =
             CommandRunner.run(sh, ["-c", "trap '' TERM; sleep 0.05; printf LEAKED"],
               timeout_ms: 20,
               kill_grace_ms: 500
             )

    refute_received {_port, {:data, _}}
    refute_received {_port, {:exit_status, _}}
  end

  test "truncates output once max_output_bytes is exceeded", %{sh: sh} do
    assert {:ok, %{exit: 124, stdout: out, truncated?: true}} =
             CommandRunner.run(sh, ["-c", "yes x | head -c 8192"],
               timeout_ms: 5_000,
               max_output_bytes: 128
             )

    assert byte_size(out) <= 256
  end
end
