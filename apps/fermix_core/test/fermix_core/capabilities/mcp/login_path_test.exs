defmodule FermixCore.Capabilities.MCP.LoginPathTest do
  @moduledoc """
  The PATH owner of operator stdio MCP servers (M74 E3): one reading of the
  login shell per daemon start, the one resolver of a command, and the one
  warning when the shell cannot be read. No test runs a real login shell: the
  reading is injected, and the shell reader's own rules run against an
  injected runner.
  """

  # `async: false`: the read-failure case asserts on a captured log line.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Capabilities.MCP.LoginPath
  alias FermixCore.Capabilities.MCP.LoginPath.Shell
  alias FermixTestSupport.SafeRm

  setup do
    dir = SafeRm.make_tmp_dir!("mcp_login_path")
    on_exit(fn -> SafeRm.rm_rf!(dir) end)

    program = Path.join(dir, "fermix-fake-mcp")
    File.write!(program, "#!/bin/sh\nexit 0\n")
    File.chmod!(program, 0o755)

    %{dir: dir, program: program}
  end

  defp start_owner(read) do
    name = :"mcp_login_path_#{System.unique_integer([:positive])}"
    start_supervised!({LoginPath, name: name, read: read})
    name
  end

  describe "resolve/3" do
    test "a command without a slash is found on the login shell's PATH", ctx do
      owner = start_owner(fn -> {:ok, "/nowhere:#{ctx.dir}"} end)

      assert LoginPath.resolve(owner, "fermix-fake-mcp", nil) == {:ok, ctx.program}
    end

    test "a command it cannot find is named in the not-found answer", ctx do
      owner = start_owner(fn -> {:ok, ctx.dir} end)

      assert LoginPath.resolve(owner, "npx", nil) == {:error, {:command_not_found, "npx"}}
    end

    test "a command with a slash is a path, read relative to the server's folder", ctx do
      owner = start_owner(fn -> {:ok, "/nowhere"} end)

      assert LoginPath.resolve(owner, ctx.program, nil) == {:ok, ctx.program}
      assert LoginPath.resolve(owner, "./fermix-fake-mcp", ctx.dir) == {:ok, ctx.program}

      assert LoginPath.resolve(owner, "./absent", ctx.dir) ==
               {:error, {:command_not_found, "./absent"}}
    end

    test "a file that is not executable is not a program", ctx do
      plain = Path.join(ctx.dir, "notes.txt")
      File.write!(plain, "not a program")
      owner = start_owner(fn -> {:ok, ctx.dir} end)

      assert LoginPath.resolve(owner, "notes.txt", nil) ==
               {:error, {:command_not_found, "notes.txt"}}
    end
  end

  describe "the reading" do
    test "the login shell is read once, the first time it is needed", ctx do
      test = self()

      owner =
        start_owner(fn ->
          send(test, :login_shell_read)
          {:ok, ctx.dir}
        end)

      refute_received :login_shell_read

      assert LoginPath.path(owner) == ctx.dir
      assert {:ok, _program} = LoginPath.resolve(owner, "fermix-fake-mcp", nil)
      assert LoginPath.path(owner) == ctx.dir

      assert_received :login_shell_read
      refute_received :login_shell_read
    end

    test "a shell that cannot be read says why once, and the daemon's PATH is used" do
      owner = start_owner(fn -> {:error, {:timeout, 10_000}} end)

      log =
        capture_log([level: :warning], fn -> assert LoginPath.path(owner) == daemon_path() end)

      assert log =~ "the login shell's PATH could not be read ({:timeout, 10000})"

      assert capture_log([level: :warning], fn -> LoginPath.path(owner) end) == ""
      assert {:ok, _sh} = LoginPath.resolve(owner, "sh", nil)
    end
  end

  describe "the login shell reader" do
    test "runs an interactive login shell and takes the value between its markers" do
      test = self()

      run = fn shell, args ->
        send(test, {:ran, shell, args})
        [_flags, script] = args
        [marker] = Regex.run(~r/__[A-Z_]+__/, script)
        {:ok, "oh-my-zsh says hello\n#{marker}/opt/a:/opt/b#{marker}\nbye\n"}
      end

      assert Shell.read(shell: "/bin/zsh", run: run) == {:ok, "/opt/a:/opt/b"}
      assert_received {:ran, "/bin/zsh", ["-ilc", _script]}
    end

    test "an answer without the value, a timeout and no shell are each a reason" do
      assert Shell.read(shell: "/bin/zsh", run: fn _shell, _args -> {:ok, "banner only"} end) ==
               {:error, :no_path_printed}

      assert Shell.read(shell: "/bin/zsh", run: fn _shell, _args -> {:error, {:timeout, 1}} end) ==
               {:error, {:timeout, 1}}

      run = fn _shell, _args -> flunk("no shell is run without an absolute SHELL") end
      assert Shell.read(shell: nil, run: run) == {:error, :no_shell}
      assert Shell.read(shell: "zsh", run: run) == {:error, {:shell_not_absolute, "zsh"}}
    end
  end

  defp daemon_path, do: System.get_env("PATH", "")
end
