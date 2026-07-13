defmodule FermixCore.Plugins.Dist.RuntimeProbe.Host.SystemTest do
  # async: false — exercises the real production Host.System (not the stubbed
  # host) and sets a global app-env timeout override, so it must not run
  # concurrently with tests that read the same env.
  use ExUnit.Case, async: false

  alias FermixCore.Plugins.Dist.RuntimeProbe.Host.System, as: HostSystem

  test "version_output returns the command output on success" do
    echo = System.find_executable("echo")

    assert {:ok, output} = HostSystem.version_output(echo)
    assert is_binary(output)
  end

  test "version_output maps a non-zero exit to a probe failure" do
    false_bin = System.find_executable("false")

    assert {:error, {:version_probe_failed, status, _output}} =
             HostSystem.version_output(false_bin)

    assert status != 0
  end

  describe "supervised threading (tree-less CLI verbs vs daemon)" do
    # `fermix plugins install/doctor/status` reach this probe on cli_dispatch's
    # tree-less fall-through — no CommandHost.Supervisor exists — so those entry
    # points thread `supervised: false` and the probe must resolve inline. A
    # daemon call site (Status from the prompt catalog) keeps the default and
    # must fail loud if its supervisor is dead (design §3: never a silent inline
    # run). Both are exercised here with the global host supervisor terminated.
    setup do
      :ok = Supervisor.terminate_child(FermixCore.Supervisor, FermixCore.CommandHost.Supervisor)

      on_exit(fn ->
        {:ok, _pid} =
          Supervisor.restart_child(FermixCore.Supervisor, FermixCore.CommandHost.Supervisor)
      end)

      :ok
    end

    test "supervised: false resolves inline without a CommandHost supervisor" do
      echo = System.find_executable("echo")

      assert {:ok, output} = HostSystem.version_output(echo, supervised: false)
      assert is_binary(output)
    end

    test "the default (daemon) run fails loud when the supervisor is absent" do
      echo = System.find_executable("echo")

      assert_raise RuntimeError, ~r/command host supervisor/, fn ->
        HostSystem.version_output(echo)
      end
    end
  end

  test "version_output is bounded — a wedged runtime cannot hang the render path" do
    # Regression: the probe used raw `System.cmd` with no timeout, so a host
    # runtime that never returns from `--version` hung the setup page (this runs
    # on the dead-render path). It must be bounded and reap the process group.
    Application.put_env(:fermix_core, :runtime_probe_version_timeout_ms, 200)
    on_exit(fn -> Application.delete_env(:fermix_core, :runtime_probe_version_timeout_ms) end)

    dir = FermixTestSupport.SafeRm.make_tmp_dir!("runtime-probe-hang")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

    script = Path.join(dir, "wedged")
    File.write!(script, "#!/bin/sh\nsleep 30\n")
    File.chmod!(script, 0o755)

    started = System.monotonic_time(:millisecond)
    result = HostSystem.version_output(script)
    elapsed = System.monotonic_time(:millisecond) - started

    assert {:error, {:version_probe_failed, _reason}} = result
    assert elapsed < 3_000, "version_output did not return within the bound (took #{elapsed}ms)"
  end
end
