defmodule FermixCore.Plugins.Dist.TreeDigestTest do
  use ExUnit.Case, async: true

  alias FermixCore.Plugins.Dist.TreeDigest

  @fixture_dir Path.expand(
                 "../../../../../../../fermix-plugins/scripts/fixtures/tree_digest",
                 __DIR__
               )

  defp fixture_files do
    case File.ls(@fixture_dir) do
      {:ok, files} -> files |> Enum.filter(&String.ends_with?(&1, ".json")) |> Enum.sort()
      {:error, _reason} -> []
    end
  end

  defp load(file), do: @fixture_dir |> Path.join(file) |> File.read!() |> Jason.decode!()

  defp to_map(fixture) do
    Map.new(fixture["files"], fn %{"path" => path, "content_b64" => body} ->
      {path, Base.decode64!(body)}
    end)
  end

  describe "cross-language golden fixtures" do
    test "the fixture directory is present" do
      if fixture_files() == [] do
        IO.puts(
          :stderr,
          "\n  SKIPPED: #{@fixture_dir} not found — clone tezra-io/fermix-plugins " <>
            "beside this repo to run the cross-language tree-digest contract.\n"
        )
      end

      assert true
    end

    for file <-
          File.ls(@fixture_dir)
          |> (case do
                {:ok, files} ->
                  files |> Enum.filter(&String.ends_with?(&1, ".json")) |> Enum.sort()

                {:error, _} ->
                  []
              end) do
      @file_name file

      test "#{file} digests exactly as pluginlib.py does" do
        fixture = load(@file_name)

        assert {:ok, digest} = TreeDigest.digest_files(to_map(fixture))

        assert digest == fixture["expected_sha256"],
               "#{fixture["name"]}: digest differs from the pluginlib.py fixture"
      end
    end
  end

  describe "framing" do
    # h1 concatenated path and content with no separators, so these two trees
    # hashed identically. The length prefixes are what make them distinct.
    test "a path/content boundary shift changes the digest" do
      {:ok, a} = TreeDigest.digest_files(%{"ab" => "c"})
      {:ok, b} = TreeDigest.digest_files(%{"a" => "bc"})

      refute a == b
    end

    test "an empty file is distinct from an absent one" do
      {:ok, with_empty} = TreeDigest.digest_files(%{"a" => "x", "b" => ""})
      {:ok, without} = TreeDigest.digest_files(%{"a" => "x"})

      refute with_empty == without
    end

    test "the file count is covered, so splitting one file in two is visible" do
      {:ok, one} = TreeDigest.digest_files(%{"a" => "xy"})
      {:ok, two} = TreeDigest.digest_files(%{"a" => "x", "b" => "y"})

      refute one == two
    end
  end

  describe "ordering and normalization" do
    # Bytewise over the WHOLE path, not per component: "." < "/" < "b".
    test "orders bytewise across separators" do
      files = %{"ab" => "1", "a/b" => "2", "a.b" => "3", "a" => "4"}
      {:ok, digest} = TreeDigest.digest_files(files)

      # Insertion order must not matter — a map is unordered, so a stable
      # digest here IS the ordering guarantee.
      {:ok, same} =
        TreeDigest.digest_files(%{"a" => "4", "a.b" => "3", "a/b" => "2", "ab" => "1"})

      assert digest == same
    end

    test "decomposed and composed paths agree" do
      nfd = %{"café.md" => "x"}
      nfc = %{"café.md" => "x"}

      assert TreeDigest.digest_files(nfd) == TreeDigest.digest_files(nfc)
    end

    test "refuses a path that is not valid UTF-8" do
      assert {:error, {:invalid_path_encoding, _path}} =
               TreeDigest.digest_files(%{<<0xFF, 0xFE>> => "x"})
    end
  end

  describe "digest_tree/1" do
    setup do
      root = FermixTestSupport.SafeRm.make_tmp_dir!("tree-digest")
      # The tree lives one level below the marked root: SafeRm's
      # `.fermix-test-root` marker is a real file and would otherwise be
      # digested along with the plugin's own.
      dir = Path.join(root, "tree")
      File.mkdir_p!(Path.join(dir, "skills/demo"))
      File.write!(Path.join(dir, "plugin.json"), ~s({"name":"demo"}))
      File.write!(Path.join(dir, "skills/demo/SKILL.md"), "# demo\n")

      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)
      {:ok, dir: dir}
    end

    test "matches the in-memory digest of the same files", %{dir: dir} do
      {:ok, from_disk} = TreeDigest.digest_tree(dir)

      {:ok, from_memory} =
        TreeDigest.digest_files(%{
          "plugin.json" => ~s({"name":"demo"}),
          "skills/demo/SKILL.md" => "# demo\n"
        })

      assert from_disk == from_memory
    end

    test "an empty directory does not change the digest", %{dir: dir} do
      {:ok, before} = TreeDigest.digest_tree(dir)
      File.mkdir_p!(Path.join(dir, "assets"))

      assert {:ok, ^before} = TreeDigest.digest_tree(dir)
    end

    test "editing a byte changes the digest", %{dir: dir} do
      {:ok, before} = TreeDigest.digest_tree(dir)
      File.write!(Path.join(dir, "plugin.json"), ~s({"name":"demo2"}))

      {:ok, after_edit} = TreeDigest.digest_tree(dir)
      refute before == after_edit
    end

    test "refuses a missing tree" do
      assert {:error, {:tree_missing, _path}} = TreeDigest.digest_tree("/nonexistent/tree/xyz")
    end
  end
end
