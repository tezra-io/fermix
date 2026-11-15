defmodule FermixCore.Sandbox.MachineFileProtectedTest do
  # M97 §4: `machine.toml` holds this computer's own sandbox, so a command or
  # a file tool that could write it could widen its own limits, and in `open`
  # nothing else would stop the write. Neither may read nor write it, in any
  # mode. async: false: the protected paths read FERMIX_HOME from the
  # environment, which each test sets to its own home and restores.
  use ExUnit.Case, async: false

  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.Landlock
  alias FermixCore.Sandbox.OsSandbox
  alias FermixCore.Sandbox.PathPolicy
  alias FermixCore.Setup.MachineFile
  alias FermixCore.Tools.ContentSearch
  alias FermixCore.Tools.FileEdit
  alias FermixCore.Tools.FileRead
  alias FermixCore.Tools.FileWrite
  alias FermixCore.Tools.Shell
  alias FermixTestSupport.SafeRm

  @modes [:strict, :standard, :open]
  @darwin {:unix, :darwin}
  @linux {:unix, :linux}
  @seeded "[sandbox]\nmode = \"strict\"\n# invented-machine-marker\n"

  setup do
    previous = System.get_env("FERMIX_HOME")
    base = SafeRm.make_tmp_dir!("machine-file-protected")
    os_home = Path.join(base, "home")
    fermix_home = Path.join(os_home, ".fermix")
    workspace = Path.join(fermix_home, "workspace")
    File.mkdir_p!(workspace)
    machine = MachineFile.path(fermix_home)
    File.write!(machine, @seeded)
    System.put_env("FERMIX_HOME", fermix_home)

    on_exit(fn ->
      if previous,
        do: System.put_env("FERMIX_HOME", previous),
        else: System.delete_env("FERMIX_HOME")

      SafeRm.rm_rf!(base)
    end)

    %{
      base: base,
      os_home: os_home,
      fermix_home: fermix_home,
      workspace: workspace,
      machine: machine
    }
  end

  defp config(ctx, mode) do
    Config.normalize(
      mode: mode,
      home: ctx.fermix_home,
      os_home: ctx.os_home,
      workspace_root: ctx.workspace
    )
  end

  defp context(ctx, mode) do
    %{
      agent_name: "test_agent",
      conversation_key: :machine_file_protected_test,
      cwd: ctx.workspace,
      sandbox_config: config(ctx, mode),
      os_sandbox: [scratch: []]
    }
  end

  describe "the file tools" do
    test "neither read, write nor edit it, in any mode", ctx do
      for mode <- @modes do
        context = context(ctx, mode)

        assert {:ok, %{success: false, error: read}} =
                 FileRead.execute(%{"path" => ctx.machine}, context)

        assert {:ok, %{success: false, error: written}} =
                 FileWrite.execute(
                   %{"path" => ctx.machine, "content" => "[sandbox]\nmode = \"open\"\n"},
                   context
                 )

        assert {:ok, %{success: false, error: edited}} =
                 FileEdit.execute(
                   %{"path" => ctx.machine, "old_string" => "strict", "new_string" => "open"},
                   context
                 )

        for error <- [read, written, edited],
            do: assert(error =~ "protected", "#{mode}: #{error}")

        refute read =~ "invented-machine-marker"
      end

      assert File.read!(ctx.machine) == @seeded
    end

    test "a search of the home never opens it, in any mode", ctx do
      for mode <- @modes do
        assert {:ok, result} =
                 ContentSearch.execute(
                   %{"pattern" => "invented-machine-marker", "path" => ctx.fermix_home},
                   context(ctx, mode)
                 )

        refute result.output =~ "invented-machine-marker", "#{mode}"
        refute (result.output || "") =~ "machine.toml", "#{mode}"
      end
    end

    test "the protected list names it, and the files named after it", ctx do
      for mode <- @modes, name <- ["machine.toml", "machine.toml.tmp"] do
        assert {:error, {:protected_path, _path}} =
                 PathPolicy.allowed_path?(Path.join(ctx.fermix_home, name), config(ctx, mode)),
               "#{mode}: #{name}"
      end
    end
  end

  describe "a command" do
    test "is held from reading and writing it on macOS and Linux, in any mode", ctx do
      for os <- [@darwin, @linux], mode <- @modes do
        assert {:ok, rules} = OsSandbox.rules(config(ctx, mode), nil, scratch: [], os: os)
        machine = Path.join(rules.fermix_home, "machine.toml")
        at = "#{inspect(os)} #{mode}"

        assert machine in rules.protected, at
        assert {machine, :prefix} in rules.unreadable, at
        assert ("^" <> escaped(machine)) in rules.secret_patterns, at
      end
    end

    # The Landlock rules a Linux command runs under, built here as on Linux:
    # no rule grants a read or a write that reaches the machine file.
    test "gets no Landlock rule that reaches it, in any mode", ctx do
      shim = Path.join(ctx.base, "fermix_landlock")
      File.write!(shim, "")
      {:ok, machine} = PathPolicy.resolve_links(ctx.machine)

      for mode <- @modes do
        opts = [os: @linux, scratch: [], landlock_shim: shim, fs: near(ctx.base)]

        assert {:ok, {^shim, args}} =
                 OsSandbox.wrap("/bin/sh", ["-c", "true"], config(ctx, mode), nil, opts)

        {rules, ["--" | _command]} = Enum.split_while(args, &(&1 != "--"))

        reaching =
          for rule <- rules,
              [access, path] = String.split(rule, ":", parts: 2),
              access =~ ~r/[rw]/,
              machine == path or String.starts_with?(machine, path <> "/"),
              do: rule

        assert reaching == [], "#{mode}: #{inspect(reaching)}"
      end
    end
  end

  describe "a command, enforced by macOS" do
    unless :os.type() == @darwin do
      @describetag skip: "Seatbelt exists only on macOS, this is #{inspect(:os.type())}"
    end

    test "can neither read, write, move nor remove it, in any mode", ctx do
      for mode <- @modes do
        context = context(ctx, mode)

        assert %{success: false, error: error} = shell("cat #{ctx.machine}", context)
        assert error =~ "Operation not permitted", "#{mode}: #{error}"
        refute error =~ "invented-machine-marker"

        for command <- [
              "echo planted >> #{ctx.machine}",
              "mv #{ctx.machine} #{ctx.workspace}/",
              "rm -f #{ctx.machine}"
            ] do
          assert %{success: false} = shell(command, context), "#{mode}: #{command}"
        end
      end

      assert File.read!(ctx.machine) == @seeded
    end
  end

  defp shell(command, context) do
    {:ok, result} = Shell.execute(%{"command" => command}, context)
    result
  end

  defp escaped(path), do: String.replace(path, ~r/[\\.\[\](){}*+?^$|]/, "\\\\\\0")

  # Landlock carves its rules by listing folders; outside the temp folder
  # this test's tree lives in, only the folders on the way to it are listed.
  defp near(base) do
    disk = Landlock.disk()
    {:ok, temp} = PathPolicy.resolve_links(System.tmp_dir!())
    {:ok, base} = PathPolicy.resolve_links(base)
    %{disk | list: &near_list(&1, disk, temp, base)}
  end

  defp near_list(dir, disk, temp, base) do
    with {:ok, names} <- disk.list.(dir) do
      if String.starts_with?(dir <> "/", temp),
        do: {:ok, Enum.filter(names, &on_the_way?(Path.join(dir, &1), base))},
        else: {:ok, names}
    end
  end

  defp on_the_way?(path, base),
    do: String.starts_with?(base <> "/", path <> "/") or String.starts_with?(path, base <> "/")
end
