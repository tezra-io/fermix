defmodule FermixCore.Browser.DisclaimShimTest do
  use ExUnit.Case, async: true

  # Pins the process contract ChromeLauncher depends on when spawning Chrome
  # through the disclaim shim: SETEXEC keeps the pid the Port observed, the
  # stdio pipes survive the exec, and :exit_status is still delivered. The shim
  # is macOS-only (built by fermix_nif's Makefile on darwin, cross-compiled per
  # macOS target in release), so this module compiles to nothing elsewhere.
  if match?({:unix, :darwin}, :os.type()) do
    test "--check resolves the disclaim API and exits 0" do
      assert {out, 0} = System.cmd(shim!(), ["--check"], stderr_to_stdout: true)
      assert out =~ "disclaim: ok"
    end

    # The child holds on its stdin until the pid has been read: one that exits
    # first closes the port, and `Port.info/2` then answers nil. Releasing it
    # through the pipe also proves stdin survived the exec.
    test "SETEXEC keeps the pid, inherits stdio, and delivers exit_status" do
      port =
        Port.open({:spawn_executable, shim!()}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, ["/bin/sh", "-c", "echo pid=$$; echo shim-stderr >&2; read go; exit 7"]}
        ])

      {:os_pid, os_pid} = Port.info(port, :os_pid)
      true = Port.command(port, "go\n")
      {output, exit_status} = collect(port, "")

      assert exit_status == 7
      assert output =~ "pid=#{os_pid}"
      assert output =~ "shim-stderr"
    end

    test "a target that cannot exec fails loud with the disclaim prefix" do
      port =
        Port.open({:spawn_executable, shim!()}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, ["/nonexistent/never-a-browser"]}
        ])

      {output, exit_status} = collect(port, "")

      assert exit_status == 72
      assert output =~ "disclaim: exec of /nonexistent/never-a-browser failed"
    end

    defp shim! do
      path = Application.app_dir(:fermix_nif, "priv/disclaim")
      assert File.regular?(path), "disclaim shim not built — run mix compile"
      path
    end

    defp collect(port, acc) do
      receive do
        {^port, {:data, data}} -> collect(port, acc <> data)
        {^port, {:exit_status, status}} -> {acc, status}
      after
        5_000 -> flunk("shim never exited; output so far: #{acc}")
      end
    end
  end
end
