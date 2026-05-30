defmodule FermixCore.Tools.FileWriteTest do
  use ExUnit.Case, async: true

  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.PathPolicy
  alias FermixCore.Tools.FileWrite

  @context %{agent_name: "test_agent", conversation_key: :test}

  setup do
    dir = Path.join(System.tmp_dir!(), "fermix_file_write_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

    %{
      dir: dir,
      context:
        Map.put(
          @context,
          :sandbox_config,
          Config.normalize(mode: :strict, workspace_root: dir)
        )
    }
  end

  describe "name/0" do
    test "returns file_write" do
      assert FileWrite.name() == "file_write"
    end
  end

  describe "description/0" do
    test "returns a non-empty string" do
      desc = FileWrite.description()
      assert is_binary(desc)
      assert byte_size(desc) > 0
    end
  end

  describe "parameters/0" do
    test "returns JSON Schema with path and content as required" do
      params = FileWrite.parameters()
      assert params.type == "object"
      assert "path" in params.required
      assert "content" in params.required
      assert Map.has_key?(params.properties, :path)
      assert Map.has_key?(params.properties, :content)
    end

    test "includes optional mkdir" do
      params = FileWrite.parameters()
      assert Map.has_key?(params.properties, :mkdir)
    end
  end

  describe "execute/2 - happy path" do
    test "writes content to new file", %{dir: dir, context: context} do
      path = Path.join(dir, "output.txt")

      assert {:ok, result} =
               FileWrite.execute(%{"path" => path, "content" => "hello world"}, context)

      assert result.success == true
      assert result.output =~ "11 bytes"
      assert File.read!(path) == "hello world"
    end

    test "overwrites existing file", %{dir: dir, context: context} do
      path = Path.join(dir, "existing.txt")
      File.write!(path, "old content")

      assert {:ok, result} =
               FileWrite.execute(%{"path" => path, "content" => "new content"}, context)

      assert result.success == true
      assert File.read!(path) == "new content"
    end

    test "creates parent directories when mkdir is true", %{dir: dir, context: context} do
      path = Path.join([dir, "nested", "deep", "file.txt"])

      assert {:ok, result} =
               FileWrite.execute(
                 %{"path" => path, "content" => "nested", "mkdir" => true},
                 context
               )

      assert result.success == true
      assert File.read!(path) == "nested"
    end

    test "creates parent directories by default", %{dir: dir, context: context} do
      path = Path.join([dir, "auto", "dirs", "file.txt"])

      assert {:ok, result} =
               FileWrite.execute(%{"path" => path, "content" => "auto"}, context)

      assert result.success == true
      assert File.read!(path) == "auto"
    end

    test "writes empty content", %{dir: dir, context: context} do
      path = Path.join(dir, "empty.txt")

      assert {:ok, result} =
               FileWrite.execute(%{"path" => path, "content" => ""}, context)

      assert result.success == true
      assert result.output =~ "0 bytes"
      assert File.read!(path) == ""
    end
  end

  describe "execute/2 - mkdir false" do
    test "fails when parent directory does not exist and mkdir is false", %{
      dir: dir,
      context: context
    } do
      path = Path.join([dir, "no_such_dir", "file.txt"])

      assert {:ok, result} =
               FileWrite.execute(
                 %{"path" => path, "content" => "test", "mkdir" => false},
                 context
               )

      assert result.success == false
      assert result.error =~ "Failed to write"
    end
  end

  describe "execute/2 - error cases" do
    test "returns error for empty path", %{context: context} do
      assert {:ok, result} =
               FileWrite.execute(%{"path" => "", "content" => "test"}, context)

      assert result.success == false
      assert result.error =~ "non-empty"
    end

    test "allows parent traversal when resolved target stays inside root", %{
      dir: dir,
      context: context
    } do
      child = Path.join(dir, "child")
      File.mkdir_p!(child)
      path = Path.join([child, "..", "sibling.txt"])

      assert {:ok, result} =
               FileWrite.execute(%{"path" => path, "content" => "inside"}, context)

      assert result.success == true
      assert File.read!(Path.join(dir, "sibling.txt")) == "inside"
    end

    test "returns error for traversal that resolves outside roots", %{context: context} do
      assert {:ok, result} =
               FileWrite.execute(
                 %{"path" => "/tmp/../etc/evil.txt", "content" => "bad"},
                 context
               )

      assert result.success == false
      assert result.error =~ "Sandbox denied"
    end

    test "returns error for paths outside sandbox roots", %{context: context} do
      outside = FermixTestSupport.SafeRm.make_tmp_dir!("file-write-outside")
      path = Path.join(outside, "blocked.txt")

      assert {:ok, result} =
               FileWrite.execute(%{"path" => path, "content" => "blocked"}, context)

      assert result.success == false
      assert result.error =~ "outside roots"
      assert result.error =~ "fermix grant path #{PathPolicy.canonical_path(outside)}"
      refute File.exists?(path)

      FermixTestSupport.SafeRm.rm_rf!(outside)
    end
  end

  describe "telemetry" do
    test "emits [:fermix, :tool, :exec] on success", %{dir: dir, context: context} do
      handler_id = attach_telemetry()
      path = Path.join(dir, "telem.txt")

      FileWrite.execute(%{"path" => path, "content" => "telemetry"}, context)

      assert_receive {:telemetry, [:fermix, :tool, :exec], measurements, metadata}
      assert is_integer(measurements.duration_ms)
      assert measurements.duration_ms >= 0
      assert metadata.tool == "file_write"
      assert metadata.agent == "test_agent"
      assert metadata.success == true

      :telemetry.detach(handler_id)
    end

    test "emits [:fermix, :tool, :exec] on failure", %{context: context} do
      handler_id = attach_telemetry()

      FileWrite.execute(%{"path" => "", "content" => "test"}, context)

      assert_receive {:telemetry, [:fermix, :tool, :exec], measurements, metadata}
      assert is_integer(measurements.duration_ms)
      assert metadata.tool == "file_write"
      assert metadata.success == false

      :telemetry.detach(handler_id)
    end
  end

  defp attach_telemetry do
    handler_id = "test-file-write-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:fermix, :tool, :exec],
      fn event, measurements, metadata, _config ->
        if metadata.tool == "file_write" do
          send(test_pid, {:telemetry, event, measurements, metadata})
        end
      end,
      nil
    )

    handler_id
  end
end
