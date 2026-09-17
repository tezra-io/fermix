defmodule FermixCore.Tools.ViewImageTest do
  use ExUnit.Case, async: true

  alias FermixCore.Tools.ViewImage

  # Real magic bytes: the reader identifies the type from the leading bytes, not
  # from the filename, so a fixture must actually start like the format it claims.
  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>> <> :binary.copy("p", 64)
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0>> <> :binary.copy("j", 64)
  @webp "RIFF" <> <<0, 0, 0, 0>> <> "WEBP" <> :binary.copy("w", 64)
  @gif "GIF89a" <> :binary.copy("g", 64)

  setup do
    dir = FermixTestSupport.SafeRm.make_tmp_dir!("fermix-view-image")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(dir) end)

    context = %{
      agent_name: "test_agent",
      conversation_key: :test,
      cwd: dir,
      sandbox_config: %{mode: :strict, workspace_root: dir, allowed_roots: [dir]}
    }

    %{dir: dir, context: context}
  end

  describe "metadata" do
    test "is a read-only file-category builtin needing no setup block" do
      assert ViewImage.name() == "view_image"
      assert ViewImage.category() == :file
      assert ViewImage.requires_setup() == nil
      assert "paths" in ViewImage.parameters().required
      assert ViewImage.parameters().properties.paths.maxItems == 6
      assert is_binary(ViewImage.when_to_use())
      assert length(ViewImage.examples()) == 2
      assert Enum.any?(ViewImage.failure_modes(), &(&1.tag == "image_type_unsupported"))
    end
  end

  describe "execute/2 — reading" do
    test "V01: one JPEG in an allowed root returns one image part and a filename map", %{
      dir: dir,
      context: context
    } do
      write(dir, "top.jpg", @jpeg)

      assert {:ok, result} = ViewImage.execute(%{"paths" => [Path.join(dir, "top.jpg")]}, context)
      assert result.success
      assert [%{type: :image, mime_type: "image/jpeg", data: @jpeg}] = result.images
      assert result.output =~ "Reference 1: top.jpg"
      assert result.output =~ "image/jpeg"
      refute result.output =~ "jjjj"
    end

    test "V02: three photos reach the model in order, and none becomes text", %{
      dir: dir,
      context: context
    } do
      write(dir, "a.jpg", @jpeg)
      write(dir, "b.png", @png)
      write(dir, "c.webp", @webp)

      paths = Enum.map(["a.jpg", "b.png", "c.webp"], &Path.join(dir, &1))

      assert {:ok, result} = ViewImage.execute(%{"paths" => paths}, context)
      assert Enum.map(result.images, & &1.mime_type) == ["image/jpeg", "image/png", "image/webp"]
      assert Enum.map(result.images, & &1.data) == [@jpeg, @png, @webp]

      assert result.output =~ "Reference 1: a.jpg"
      assert result.output =~ "Reference 2: b.png"
      assert result.output =~ "Reference 3: c.webp"
      refute result.output =~ Base.encode64(@png)
    end

    test "supports the PNG and WebP magic byte families", %{dir: dir, context: context} do
      write(dir, "one.png", @png)

      assert {:ok, %{images: [%{mime_type: "image/png"}]}} =
               ViewImage.execute(%{"paths" => [Path.join(dir, "one.png")]}, context)
    end
  end

  describe "execute/2 — refusals" do
    test "V03: a path outside the sandbox roots is refused before any bytes are read", %{
      context: context
    } do
      outside = FermixTestSupport.SafeRm.make_tmp_dir!("fermix-view-image-outside")

      try do
        write(outside, "secret.png", @png)

        assert {:ok, result} =
                 ViewImage.execute(%{"paths" => [Path.join(outside, "secret.png")]}, context)

        refute result.success
        assert result.error =~ "Reference 1 (secret.png)"
        assert result.error =~ "outside the sandbox roots"
        refute Map.has_key?(result, :images)
      after
        FermixTestSupport.SafeRm.rm_rf!(outside)
      end
    end

    test "V04: a directory, a missing file and an empty file each fail specifically", %{
      dir: dir,
      context: context
    } do
      File.mkdir_p!(Path.join(dir, "folder"))
      write(dir, "empty.png", "")

      assert {:ok, %{success: false, error: dir_error}} =
               ViewImage.execute(%{"paths" => [Path.join(dir, "folder")]}, context)

      assert dir_error =~ "not a regular file"

      assert {:ok, %{success: false, error: missing_error}} =
               ViewImage.execute(%{"paths" => [Path.join(dir, "nope.png")]}, context)

      assert missing_error =~ "not found"

      assert {:ok, %{success: false, error: empty_error}} =
               ViewImage.execute(%{"paths" => [Path.join(dir, "empty.png")]}, context)

      assert empty_error =~ "empty"
    end

    test "V04: an unsupported image type is refused and nothing partial comes back", %{
      dir: dir,
      context: context
    } do
      write(dir, "good.png", @png)
      write(dir, "animated.gif", @gif)

      paths = [Path.join(dir, "good.png"), Path.join(dir, "animated.gif")]

      assert {:ok, result} = ViewImage.execute(%{"paths" => paths}, context)
      refute result.success
      assert result.error =~ "Reference 2 (animated.gif)"
      assert result.error =~ "image_type_unsupported"
      # All-or-error: the good first reference is NOT returned on its own.
      refute Map.has_key?(result, :images)
    end

    test "V04: bytes that are not an image at all are refused despite the extension", %{
      dir: dir,
      context: context
    } do
      write(dir, "notreally.png", "this is plain text, not a PNG")

      assert {:ok, %{success: false, error: error}} =
               ViewImage.execute(%{"paths" => [Path.join(dir, "notreally.png")]}, context)

      assert error =~ "image_type_unsupported"
    end

    test "V05: more than six paths is refused before any read", %{dir: dir, context: context} do
      paths =
        for index <- 1..7 do
          name = "img#{index}.png"
          write(dir, name, @png)
          Path.join(dir, name)
        end

      assert {:ok, %{success: false, error: error}} =
               ViewImage.execute(%{"paths" => paths}, context)

      assert error =~ "at most 6 images"
    end

    test "V05: a file over the per-file cap is refused and the descriptor is released", %{
      dir: dir,
      context: context
    } do
      big = Path.join(dir, "big.png")
      File.write!(big, @png <> :binary.copy("x", 10 * 1024 * 1024))

      assert {:ok, %{success: false, error: error}} =
               ViewImage.execute(%{"paths" => [big]}, context)

      assert error =~ "per-file limit"

      # The refused read left no descriptor behind: the same file is still
      # openable, and a legal read in the same call path still succeeds.
      write(dir, "small.png", @png)

      assert {:ok, %{success: true}} =
               ViewImage.execute(%{"paths" => [Path.join(dir, "small.png")]}, context)
    end

    test "V05: the aggregate cap halts the batch", %{dir: dir, context: context} do
      # Four files of ~7 MiB each: each is under the 10 MiB per-file cap, and the
      # fourth crosses the 24 MiB aggregate.
      chunk = :binary.copy("x", 7 * 1024 * 1024)

      paths =
        for index <- 1..4 do
          name = "part#{index}.png"
          File.write!(Path.join(dir, name), @png <> chunk)
          Path.join(dir, name)
        end

      assert {:ok, %{success: false, error: error}} =
               ViewImage.execute(%{"paths" => paths}, context)

      assert error =~ "Reference 4 (part4.png)"
      assert error =~ "the batch would reach"
    end

    test "rejects a missing, empty, non-list or URL paths argument", %{context: context} do
      assert {:ok, %{success: false, error: missing}} = ViewImage.execute(%{}, context)
      assert missing =~ "Missing required parameter: paths"

      assert {:ok, %{success: false, error: empty}} =
               ViewImage.execute(%{"paths" => []}, context)

      assert empty =~ "at least one image path"

      assert {:ok, %{success: false, error: not_list}} =
               ViewImage.execute(%{"paths" => "a.png"}, context)

      assert not_list =~ "must be an array"

      assert {:ok, %{success: false, error: url}} =
               ViewImage.execute(%{"paths" => ["https://example.com/a.png"]}, context)

      assert url =~ "URLs are not supported"
    end
  end

  describe "telemetry" do
    test "emits one exec event carrying counts and mime types but never the bytes", %{
      dir: dir,
      context: context
    } do
      write(dir, "a.jpg", @jpeg)
      write(dir, "b.png", @png)
      attach_tool_exec()

      paths = [Path.join(dir, "a.jpg"), Path.join(dir, "b.png")]
      assert {:ok, %{success: true}} = ViewImage.execute(%{"paths" => paths}, context)

      assert_received {:tool_exec, _measurements, metadata}
      assert metadata.tool == "view_image"
      assert metadata.success
      assert metadata.count == 2
      assert metadata.bytes == byte_size(@jpeg) + byte_size(@png)
      assert Enum.sort(metadata.mime_types) == ["image/jpeg", "image/png"]

      refute metadata |> inspect(limit: :infinity) |> String.contains?("jjjj")
      refute_received {:tool_exec, _measurements, _metadata}
    end

    test "a failed read emits one event with the refusal in metadata.error", %{context: context} do
      attach_tool_exec()

      assert {:ok, %{success: false}} = ViewImage.execute(%{"paths" => []}, context)

      assert_received {:tool_exec, _measurements, metadata}
      assert metadata.tool == "view_image"
      refute metadata.success
      assert metadata.error =~ "at least one image path"
      assert metadata.count == 0
    end
  end

  defp write(dir, name, bytes), do: File.write!(Path.join(dir, name), bytes)

  # The handler is process-global and runs in the emitting process, so forward
  # only events this test itself produced (a concurrently running async module
  # emits the same event name).
  defp attach_tool_exec do
    test_pid = self()
    handler_id = "view-image-tool-exec-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:fermix, :tool, :exec],
      fn _event, measurements, metadata, _config ->
        if self() == test_pid, do: send(test_pid, {:tool_exec, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
