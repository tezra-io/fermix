defmodule FermixCore.Harness.MachineStoreProtectedTest do
  # M98 G3a: `device/coding.db` is this machine's coding store. Like
  # `device/history.db` it sits under `device/`, which no file tool and no
  # command may read in any mode. async: false: the protected paths read
  # FERMIX_HOME from the environment, which each test sets to its own home and
  # restores.
  use ExUnit.Case, async: false

  alias FermixCore.Harness.MachineStore
  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.OsSandbox
  alias FermixCore.Sandbox.PathPolicy
  alias FermixCore.Tools.FileRead
  alias FermixCore.Tools.Shell
  alias FermixTestSupport.SafeRm

  @modes [:strict, :standard, :open]
  @darwin {:unix, :darwin}
  @linux {:unix, :linux}

  setup do
    previous = System.get_env("FERMIX_HOME")
    base = SafeRm.make_tmp_dir!("machine-store-protected")
    os_home = Path.join(base, "home")
    fermix_home = Path.join(os_home, ".fermix")
    workspace = Path.join(fermix_home, "workspace")
    File.mkdir_p!(workspace)
    store = MachineStore.path(fermix_home)
    {:ok, conn} = MachineStore.open(store)
    :ok = Exqlite.Sqlite3.close(conn)
    System.put_env("FERMIX_HOME", fermix_home)

    on_exit(fn ->
      if previous,
        do: System.put_env("FERMIX_HOME", previous),
        else: System.delete_env("FERMIX_HOME")

      SafeRm.rm_rf!(base)
    end)

    %{os_home: os_home, fermix_home: fermix_home, workspace: workspace, store: store}
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
      conversation_key: :machine_store_protected_test,
      cwd: ctx.workspace,
      sandbox_config: config(ctx, mode),
      os_sandbox: [scratch: []]
    }
  end

  test "a file tool cannot read it or its write-ahead log, in any mode", ctx do
    for mode <- @modes, name <- [ctx.store, ctx.store <> "-wal"] do
      assert {:error, {:protected_path, _path}} =
               PathPolicy.allowed_path?(name, config(ctx, mode)),
             "#{mode}: #{name}"

      assert {:ok, %{success: false, error: error}} =
               FileRead.execute(%{"path" => name}, context(ctx, mode))

      assert error =~ "protected", "#{mode}: #{error}"
    end
  end

  test "a command's rules keep it unreadable on macOS and Linux, in any mode", ctx do
    for os <- [@darwin, @linux], mode <- @modes do
      assert {:ok, rules} = OsSandbox.rules(config(ctx, mode), nil, scratch: [], os: os)
      device = Path.join(rules.fermix_home, "device")

      assert {device, :tree} in rules.unreadable, "#{inspect(os)} #{mode}"
    end
  end

  describe "enforced by macOS" do
    unless :os.type() == @darwin do
      @describetag skip: "Seatbelt exists only on macOS, this is #{inspect(:os.type())}"
    end

    test "a command cannot read it, in any mode", ctx do
      for mode <- @modes do
        {:ok, result} = Shell.execute(%{"command" => "cat #{ctx.store}"}, context(ctx, mode))

        assert %{success: false, error: error} = result
        assert error =~ "Operation not permitted", "#{mode}: #{error}"
      end
    end
  end
end
