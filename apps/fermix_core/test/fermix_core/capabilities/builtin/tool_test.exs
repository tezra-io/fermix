defmodule FermixCore.Capabilities.Builtin.ToolTest do
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Builtin.Tool

  describe "success/1" do
    test "wraps text output and carries no :images key" do
      result = Tool.success("hi")
      assert result == %{success: true, output: "hi", error: nil}
      refute Map.has_key?(result, :images)
    end
  end

  describe "success_with_images/2" do
    test "carries the text summary plus the image content parts" do
      png = %{type: :image, mime_type: "image/png", data: <<137, 80, 78, 71>>}

      assert Tool.success_with_images("captured", [png]) ==
               %{success: true, output: "captured", error: nil, images: [png]}
    end

    test "rejects an empty image list with a clear error (callers with no image use success/1)" do
      assert_raise ArgumentError, ~r/requires at least one image/, fn ->
        Tool.success_with_images("x", [])
      end
    end

    test "fails loud on a malformed image part — missing mime_type" do
      assert_raise ArgumentError, ~r/invalid image part/, fn ->
        Tool.success_with_images("x", [%{type: :image, data: "no mime"}])
      end
    end

    test "fails loud on a malformed image part — blank mime_type" do
      assert_raise ArgumentError, ~r/invalid image part/, fn ->
        Tool.success_with_images("x", [%{type: :image, mime_type: "", data: "x"}])
      end
    end
  end

  describe "error/1" do
    test "wraps an error message with empty output" do
      assert Tool.error("boom") == %{success: false, output: "", error: "boom"}
    end
  end
end
