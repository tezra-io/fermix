defmodule FermixCore.Plugins.Dist.SafeRmTest do
  use ExUnit.Case, async: true

  alias FermixCore.Plugins.Dist.SafeRm

  setup do
    tmp = FermixTestSupport.SafeRm.make_tmp_dir!("fermix-dist-saferm")
    root = Path.join(tmp, "plugins")
    File.mkdir_p!(Path.join([root, "installed", "github", "1.0.0"]))
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf(tmp) end)
    %{tmp: tmp, root: root}
  end

  describe "check/2" do
    test "accepts a deep path strictly under the root", %{root: root} do
      target = Path.join([root, "installed", "github", "1.0.0"])
      assert {:ok, ^target} = SafeRm.check(target, root)
    end

    test "rejects the root itself", %{root: root} do
      assert {:error, {:outside_plugins_root, _}} = SafeRm.check(root, root)
    end

    test "rejects a path outside the root", %{root: root, tmp: tmp} do
      assert {:error, {:outside_plugins_root, _}} =
               SafeRm.check(Path.join(tmp, "elsewhere"), root)
    end

    test "rejects a traversal component", %{root: root} do
      assert {:error, {:traversal, _}} =
               SafeRm.check(Path.join(root, "installed/../../../etc"), root)
    end

    test "rejects an empty or non-binary path", %{root: root} do
      assert {:error, :invalid_path} = SafeRm.check("", root)
      assert {:error, :invalid_path} = SafeRm.check(nil, root)
    end
  end

  describe "rm_rf/2" do
    test "removes a valid target under the root", %{root: root} do
      target = Path.join([root, "installed", "github", "1.0.0"])
      assert File.exists?(target)
      assert :ok = SafeRm.rm_rf(target, root)
      refute File.exists?(target)
    end

    test "refuses and does not remove an unsafe target", %{root: root} do
      assert {:error, {:outside_plugins_root, _}} = SafeRm.rm_rf(root, root)
      assert File.exists?(root)
    end
  end
end
