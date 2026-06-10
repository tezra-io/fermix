defmodule FermixCore.Plugins.Dist.RuntimeProbeTest do
  use ExUnit.Case, async: true

  alias FermixCore.Plugins.Dist.RuntimeProbe

  @node_runtime %{
    "kind" => "node",
    "min_version" => "20",
    "command" => "node",
    "args" => ["src/index.js"],
    "vendored" => false
  }

  describe "host runtime (vendored: false)" do
    test "missing executable refuses with missing_host_runtime" do
      assert {:error, {:missing_host_runtime, "node", "20"}} =
               RuntimeProbe.probe(@node_runtime, "/nonexistent",
                 find_executable: fn "node" -> nil end,
                 version_fetch: fn _cmd -> flunk("must not fetch a version without a binary") end
               )
    end

    test "version below min_version refuses with missing_host_runtime" do
      assert {:error, {:missing_host_runtime, "node", "20"}} =
               RuntimeProbe.probe(@node_runtime, "/nonexistent",
                 find_executable: fn "node" -> "/usr/bin/node" end,
                 version_fetch: fn "/usr/bin/node" -> {:ok, "v18.19.0\n"} end
               )
    end

    test "version at or above min_version passes" do
      assert :ok =
               RuntimeProbe.probe(@node_runtime, "/nonexistent",
                 find_executable: fn "node" -> "/usr/bin/node" end,
                 version_fetch: fn "/usr/bin/node" -> {:ok, "v20.11.1\n"} end
               )
    end

    test "no min_version skips the version check" do
      runtime = Map.delete(@node_runtime, "min_version")

      assert :ok =
               RuntimeProbe.probe(runtime, "/nonexistent",
                 find_executable: fn "node" -> "/usr/bin/node" end,
                 version_fetch: fn _cmd -> flunk("must not fetch a version") end
               )
    end

    test "binary kind checks existence only" do
      runtime = %{"kind" => "binary", "command" => "vaultd", "vendored" => false}

      assert :ok =
               RuntimeProbe.probe(runtime, "/nonexistent",
                 find_executable: fn "vaultd" -> "/usr/local/bin/vaultd" end,
                 version_fetch: fn _cmd -> flunk("binary kind must not version-check") end
               )
    end

    test "a failed or unparseable version probe refuses" do
      assert {:error, {:missing_host_runtime, "node", "20"}} =
               RuntimeProbe.probe(@node_runtime, "/nonexistent",
                 find_executable: fn "node" -> "/usr/bin/node" end,
                 version_fetch: fn _cmd -> {:error, :spawn_failed} end
               )

      assert {:error, {:missing_host_runtime, "node", "20"}} =
               RuntimeProbe.probe(@node_runtime, "/nonexistent",
                 find_executable: fn "node" -> "/usr/bin/node" end,
                 version_fetch: fn _cmd -> {:ok, "no digits here"} end
               )
    end
  end

  describe "vendored runtime (vendored: true)" do
    setup do
      dir = FermixTestSupport.SafeRm.make_tmp_dir!("fermix-runtime-probe")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "passes when the command is executable under bin/<target>/", %{dir: dir} do
      runtime = %{"kind" => "binary", "command" => "vaultd", "vendored" => true}
      path = Path.join([dir, "bin", "linux-x86_64", "vaultd"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "#!/bin/sh\n")
      File.chmod!(path, 0o755)

      assert :ok = RuntimeProbe.probe(runtime, dir, target: "linux-x86_64")

      assert {:ok, ^path} =
               RuntimeProbe.vendored_command_path(runtime, dir, target: "linux-x86_64")
    end

    test "missing vendored command refuses", %{dir: dir} do
      runtime = %{"kind" => "binary", "command" => "vaultd", "vendored" => true}

      assert {:error, {:missing_host_runtime, "binary", nil}} =
               RuntimeProbe.probe(runtime, dir, target: "linux-x86_64")
    end

    test "a non-executable vendored command refuses", %{dir: dir} do
      runtime = %{"kind" => "binary", "command" => "vaultd", "vendored" => true}
      path = Path.join([dir, "bin", "linux-x86_64", "vaultd"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "data")
      File.chmod!(path, 0o644)

      assert {:error, {:missing_host_runtime, "binary", nil}} =
               RuntimeProbe.probe(runtime, dir, target: "linux-x86_64")
    end
  end
end
