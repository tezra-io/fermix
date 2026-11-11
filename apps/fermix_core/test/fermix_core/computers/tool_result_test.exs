defmodule FermixCore.Computers.ToolResultTest do
  # M97 §6.4: a tool's result crosses the link whole. A text that does not fit
  # 256 KiB of JSON, or is not UTF-8, and a tool's images ride the part.
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Computers.ToolResult

  defp round_trip(result) do
    {json, part} = ToolResult.encode(result)
    # The JSON the wire carries, read back as the server reads it.
    {:ok, decoded} = json |> Jason.encode!() |> Jason.decode!() |> ToolResult.decode(part)
    {decoded, json, part}
  end

  test "a short answer rides the result JSON, success or error" do
    assert {%{success: true, output: "hello"}, %{"output" => "hello"}, nil} =
             round_trip(Tool.success("hello"))

    assert {%{success: false, error: "File not found"}, _json, nil} =
             round_trip(Tool.error("File not found"))
  end

  test "a text over 256 KiB of JSON rides the part, and comes back whole" do
    output = String.duplicate("a", ToolResult.inline_bytes() + 1)

    {decoded, json, part} = round_trip(Tool.success(output))

    assert json["text_part"] == "output"
    assert json["output"] == nil
    assert part == output
    assert decoded.output == output
  end

  test "a text at the bound stays inline" do
    # Two quote bytes in the JSON.
    output = String.duplicate("a", ToolResult.inline_bytes() - 2)
    assert {%{output: ^output}, %{"output" => ^output}, nil} = round_trip(Tool.success(output))
  end

  test "bytes that are not UTF-8 ride the part" do
    error = "Command failed (exit code 1):\n" <> <<0xFF, 0xFE, 0x41>>

    assert {%{success: false, error: ^error}, %{"text_part" => "error"}, ^error} =
             round_trip(Tool.error(error))
  end

  test "images ride the part in order, each with its type" do
    images = [
      %{type: :image, mime_type: "image/png", data: <<1, 2, 3>>},
      %{type: :image, mime_type: "image/jpeg", data: <<4, 5>>}
    ]

    {decoded, json, part} = round_trip(Tool.success_with_images("two pictures", images))

    assert part == <<1, 2, 3, 4, 5>>

    assert json["images"] == [
             %{"mime_type" => "image/png", "bytes" => 3},
             %{"mime_type" => "image/jpeg", "bytes" => 2}
           ]

    assert decoded == Tool.success_with_images("two pictures", images)
  end

  test "an answer that is not a tool result, or whose part does not add up, is refused" do
    sentence = "The computer's answer is not a tool's result."

    assert {:error, ^sentence} = ToolResult.decode(%{"kind" => "picture"}, nil)

    assert {:error, ^sentence} =
             ToolResult.decode(%{"success" => true, "text_part" => "output"}, nil)

    images = %{
      "success" => true,
      "output" => "x",
      "images" => [%{"mime_type" => "image/png", "bytes" => 4}]
    }

    assert {:error, ^sentence} = ToolResult.decode(images, <<1, 2, 3>>)
  end
end
