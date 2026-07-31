defmodule FermixCore.Tools.FileReadTest do
  use ExUnit.Case, async: true

  alias FermixCore.Tools.FileRead

  setup do
    dir = Path.join(System.tmp_dir!(), "fermix_file_read_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    file = Path.join(dir, "test.txt")
    File.write!(file, "line1\nline2\nline3\nline4\nline5")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

    context = %{
      agent_name: "test_agent",
      conversation_key: :test,
      cwd: dir,
      sandbox_config: %{
        mode: :strict,
        workspace_root: dir,
        allowed_roots: []
      }
    }

    %{dir: dir, test_file: file, context: context}
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
    test "reads entire file", %{test_file: file, context: context} do
      assert {:ok, result} = FileRead.execute(%{"path" => file}, context)
      assert result.success == true
      assert result.output == "line1\nline2\nline3\nline4\nline5"
      assert result.error == nil
    end

    test "reads with offset", %{test_file: file, context: context} do
      assert {:ok, result} = FileRead.execute(%{"path" => file, "offset" => 3}, context)
      assert result.success == true
      assert result.output == "line3\nline4\nline5"
    end

    test "reads with limit", %{test_file: file, context: context} do
      assert {:ok, result} = FileRead.execute(%{"path" => file, "limit" => 2}, context)
      assert result.success == true
      assert result.output == "line1\nline2"
    end

    test "reads with offset and limit", %{test_file: file, context: context} do
      assert {:ok, result} =
               FileRead.execute(%{"path" => file, "offset" => 2, "limit" => 2}, context)

      assert result.success == true
      assert result.output == "line2\nline3"
    end

    test "reads empty file", %{dir: dir, context: context} do
      empty = Path.join(dir, "empty.txt")
      File.write!(empty, "")

      assert {:ok, result} = FileRead.execute(%{"path" => empty}, context)
      assert result.success == true
      assert result.output == ""
    end
  end

  describe "execute/2 - offset/limit validation" do
    test "rejects offset 0 instead of silently dropping the last line",
         %{test_file: file, context: context} do
      assert {:ok, result} = FileRead.execute(%{"path" => file, "offset" => 0}, context)
      assert result.success == false
      assert result.error =~ "offset"
      assert result.error =~ "positive integer"
    end

    test "rejects negative offset", %{test_file: file, context: context} do
      assert {:ok, result} = FileRead.execute(%{"path" => file, "offset" => -2}, context)
      assert result.success == false
      assert result.error =~ "offset"
    end

    test "rejects non-positive limit", %{test_file: file, context: context} do
      assert {:ok, result} = FileRead.execute(%{"path" => file, "limit" => 0}, context)
      assert result.success == false
      assert result.error =~ "limit"
      assert result.error =~ "positive integer"
    end

    test "rejects non-integer offset", %{test_file: file, context: context} do
      assert {:ok, result} = FileRead.execute(%{"path" => file, "offset" => "3"}, context)
      assert result.success == false
      assert result.error =~ "offset"
    end
  end

  describe "execute/2 - output byte cap" do
    test "caps oversized output and points at the continuation offset",
         %{dir: dir, context: context} do
      big = Path.join(dir, "big.txt")
      line = String.duplicate("x", 99)
      File.write!(big, Enum.map_join(1..2_000, "\n", fn _i -> line end))

      assert {:ok, result} = FileRead.execute(%{"path" => big}, context)
      assert result.success == true
      assert result.output =~ "truncated"
      assert [_output, continue_from] = Regex.run(~r/continue with offset (\d+)/, result.output)

      resumed = String.to_integer(continue_from)
      assert resumed > 1 and resumed <= 2_000
      # marker line aside, the emitted content stays within the cap
      assert byte_size(result.output) <= 100_000 + 200
    end

    test "fails loud when a single line exceeds the cap", %{dir: dir, context: context} do
      monster = Path.join(dir, "monster.txt")
      File.write!(monster, String.duplicate("y", 150_000))

      assert {:ok, result} = FileRead.execute(%{"path" => monster}, context)
      assert result.success == false
      assert result.error =~ "exceeds"
      assert result.error =~ "byte"
    end
  end

  describe "execute/2 - error cases" do
    test "returns error for nonexistent file", %{dir: dir, context: context} do
      path = Path.join(dir, "nonexistent.txt")
      assert {:ok, result} = FileRead.execute(%{"path" => path}, context)
      assert result.success == false
      assert result.error =~ "not found"
    end

    test "returns error for directory path", %{dir: dir, context: context} do
      assert {:ok, result} = FileRead.execute(%{"path" => dir}, context)
      assert result.success == false
      assert result.error =~ "directory"
    end

    test "returns error for empty path", %{context: context} do
      assert {:ok, result} = FileRead.execute(%{"path" => ""}, context)
      assert result.success == false
      assert result.error =~ "non-empty"
    end

    test "rejects absolute path outside sandbox roots", %{context: context} do
      assert {:ok, result} = FileRead.execute(%{"path" => "/etc/passwd"}, context)
      assert result.success == false
      assert result.error =~ "protected" or result.error =~ "outside the sandbox"
    end

    test "rejects relative path that escapes the sandbox", %{context: context} do
      assert {:ok, result} = FileRead.execute(%{"path" => "../../etc/passwd"}, context)
      assert result.success == false
      assert result.error =~ "protected" or result.error =~ "outside the sandbox"
    end

    test "rejects fermix-owned config and auth files", %{context: context} do
      tmp_home = Path.join(System.tmp_dir!(), "fermix_home_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_home)
      auth = Path.join(tmp_home, "auth.json")
      File.write!(auth, "{}")
      on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp_home) end)

      protected_context =
        Map.put(context, :sandbox_config, %{
          mode: :strict,
          home: System.user_home!(),
          workspace_root: tmp_home
        })

      assert {:ok, result} =
               FileRead.execute(
                 %{"path" => Path.join(System.user_home!(), ".fermix/auth.json")},
                 protected_context
               )

      assert result.success == false
      assert result.error =~ "protected" or result.error =~ "outside the sandbox"
    end

    test "returns error for null bytes in path", %{context: context} do
      assert {:ok, result} = FileRead.execute(%{"path" => "/tmp/test\0.txt"}, context)
      assert result.success == false
      assert result.error =~ "null bytes"
    end

    test "returns error for missing path parameter", %{context: context} do
      assert {:ok, result} = FileRead.execute(%{}, context)
      assert result.success == false
      assert result.error =~ "Missing"
    end
  end

  describe "telemetry" do
    test "emits [:fermix, :tool, :exec] on success", %{test_file: file, context: context} do
      handler_id = attach_telemetry()

      FileRead.execute(%{"path" => file}, context)

      assert_receive {:telemetry, [:fermix, :tool, :exec], measurements, metadata}
      assert is_integer(measurements.duration_ms)
      assert measurements.duration_ms >= 0
      assert metadata.tool == "file_read"
      assert metadata.agent == "test_agent"
      assert metadata.success == true

      :telemetry.detach(handler_id)
    end

    test "emits [:fermix, :tool, :exec] on failure", %{context: context} do
      handler_id = attach_telemetry()

      FileRead.execute(%{"path" => "/nonexistent_file"}, context)

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
        if self() == test_pid and metadata.tool == "file_read" do
          send(test_pid, {:telemetry, event, measurements, metadata})
        end
      end,
      nil
    )

    handler_id
  end
end
