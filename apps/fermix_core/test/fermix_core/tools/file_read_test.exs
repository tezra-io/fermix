defmodule FermixCore.Tools.FileReadTest do
  use ExUnit.Case, async: true

  alias FermixCore.Tools.FileRead

  @context %{agent_name: "test_agent", conversation_key: :test}

  setup do
    dir = Path.join(System.tmp_dir!(), "fermix_file_read_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    file = Path.join(dir, "test.txt")
    File.write!(file, "line1\nline2\nline3\nline4\nline5")

    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir, test_file: file}
  end

  describe "name/0" do
    test "returns file_read" do
      assert FileRead.name() == "file_read"
    end
  end

  describe "description/0" do
    test "returns a non-empty string" do
      desc = FileRead.description()
      assert is_binary(desc)
      assert byte_size(desc) > 0
    end
  end

  describe "parameters/0" do
    test "returns JSON Schema with path as required" do
      params = FileRead.parameters()
      assert params.type == "object"
      assert "path" in params.required
      assert Map.has_key?(params.properties, :path)
    end

    test "includes optional offset and limit" do
      params = FileRead.parameters()
      assert Map.has_key?(params.properties, :offset)
      assert Map.has_key?(params.properties, :limit)
    end
  end

  describe "execute/2 - happy path" do
    test "reads entire file", %{test_file: file} do
      assert {:ok, result} = FileRead.execute(%{"path" => file}, @context)
      assert result.success == true
      assert result.output == "line1\nline2\nline3\nline4\nline5"
      assert result.error == nil
    end

    test "reads with offset", %{test_file: file} do
      assert {:ok, result} = FileRead.execute(%{"path" => file, "offset" => 3}, @context)
      assert result.success == true
      assert result.output == "line3\nline4\nline5"
    end

    test "reads with limit", %{test_file: file} do
      assert {:ok, result} = FileRead.execute(%{"path" => file, "limit" => 2}, @context)
      assert result.success == true
      assert result.output == "line1\nline2"
    end

    test "reads with offset and limit", %{test_file: file} do
      assert {:ok, result} =
               FileRead.execute(%{"path" => file, "offset" => 2, "limit" => 2}, @context)

      assert result.success == true
      assert result.output == "line2\nline3"
    end

    test "reads empty file", %{dir: dir} do
      empty = Path.join(dir, "empty.txt")
      File.write!(empty, "")

      assert {:ok, result} = FileRead.execute(%{"path" => empty}, @context)
      assert result.success == true
      assert result.output == ""
    end
  end

  describe "execute/2 - error cases" do
    test "returns error for nonexistent file", %{dir: dir} do
      path = Path.join(dir, "nonexistent.txt")
      assert {:ok, result} = FileRead.execute(%{"path" => path}, @context)
      assert result.success == false
      assert result.error =~ "not found"
    end

    test "returns error for directory path", %{dir: dir} do
      assert {:ok, result} = FileRead.execute(%{"path" => dir}, @context)
      assert result.success == false
      assert result.error =~ "directory"
    end

    test "returns error for empty path" do
      assert {:ok, result} = FileRead.execute(%{"path" => ""}, @context)
      assert result.success == false
      assert result.error =~ "non-empty"
    end

    test "returns error for path traversal" do
      assert {:ok, result} = FileRead.execute(%{"path" => "/tmp/../etc/passwd"}, @context)
      assert result.success == false
      assert result.error =~ "traversal"
    end

    test "returns error for relative path traversal" do
      assert {:ok, result} = FileRead.execute(%{"path" => "../../etc/passwd"}, @context)
      assert result.success == false
      assert result.error =~ "traversal"
    end

    test "returns error for null bytes in path" do
      assert {:ok, result} = FileRead.execute(%{"path" => "/tmp/test\0.txt"}, @context)
      assert result.success == false
      assert result.error =~ "null bytes"
    end

    test "returns error for missing path parameter" do
      assert {:ok, result} = FileRead.execute(%{}, @context)
      assert result.success == false
      assert result.error =~ "Missing"
    end
  end

  describe "telemetry" do
    test "emits [:fermix, :tool, :exec] on success", %{test_file: file} do
      handler_id = attach_telemetry()

      FileRead.execute(%{"path" => file}, @context)

      assert_receive {:telemetry, [:fermix, :tool, :exec], measurements, metadata}
      assert is_integer(measurements.duration_ms)
      assert measurements.duration_ms >= 0
      assert metadata.tool == "file_read"
      assert metadata.agent == "test_agent"
      assert metadata.success == true

      :telemetry.detach(handler_id)
    end

    test "emits [:fermix, :tool, :exec] on failure" do
      handler_id = attach_telemetry()

      FileRead.execute(%{"path" => "/nonexistent_file"}, @context)

      assert_receive {:telemetry, [:fermix, :tool, :exec], measurements, metadata}
      assert is_integer(measurements.duration_ms)
      assert metadata.tool == "file_read"
      assert metadata.success == false

      :telemetry.detach(handler_id)
    end
  end

  defp attach_telemetry do
    handler_id = "test-file-read-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:fermix, :tool, :exec],
      fn event, measurements, metadata, _config ->
        if metadata.tool == "file_read" do
          send(test_pid, {:telemetry, event, measurements, metadata})
        end
      end,
      nil
    )

    handler_id
  end
end
