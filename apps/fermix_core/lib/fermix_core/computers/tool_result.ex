defmodule FermixCore.Computers.ToolResult do
  @moduledoc """
  A tool's result as it crosses the link from a computer to its server (M97
  §6.4), so a tool that ran on a computer answers the model as it does here.
  Pure.

  The result JSON is `{"success", "output", "error"}`: the tool's own words,
  null where the tool has none. A text that is not UTF-8, or whose JSON is
  over #{256} KiB, rides as the answer's part instead (`"text_part"` names
  `output` or `error`), so bytes above 256 KiB ride the bulk lane. A tool's
  images (`view_image`) ride the part one after another, each named in
  `"images"` by its type and size, in the order the tool gave them.

  `encode/1` is the computer's; `decode/2` the server's, which refuses an
  answer that is not a tool result or whose part does not add up.
  """

  alias FermixCore.Capabilities.Builtin.Tool

  @inline_bytes 256 * 1_024

  @doc "The most bytes a text rides in the result JSON."
  @spec inline_bytes() :: pos_integer()
  def inline_bytes, do: @inline_bytes

  @doc "The result JSON of `result` and the part it needs, if any."
  @spec encode(Tool.tool_result()) :: {map(), binary() | nil}
  def encode(%{success: success} = result) when is_boolean(success) do
    case Map.get(result, :images) do
      [_ | _] = images -> with_images(result, images)
      _none -> with_text(result)
    end
  end

  @doc "The tool result an answer carries, or why it is not one."
  @spec decode(map(), binary() | nil) :: {:ok, Tool.tool_result()} | {:error, String.t()}
  def decode(%{"success" => true} = result, part) do
    with {:ok, output} <- text(result, "output", part),
         {:ok, images} <- images(Map.get(result, "images"), part) do
      if images == [],
        do: {:ok, Tool.success(output)},
        else: {:ok, Tool.success_with_images(output, images)}
    end
  end

  def decode(%{"success" => false} = result, part) do
    with {:ok, error} <- text(result, "error", part), do: {:ok, Tool.error(error)}
  end

  def decode(_result, _part), do: {:error, not_a_result()}

  @doc "What the model is told of an answer that is not a tool's result."
  @spec not_a_result() :: String.t()
  def not_a_result, do: "The computer's answer is not a tool's result."

  defp with_text(%{success: true, output: output}) when is_binary(output),
    do: text_field(%{"success" => true, "error" => nil}, "output", output)

  defp with_text(%{success: false, error: error}) when is_binary(error),
    do: text_field(%{"success" => false, "output" => nil}, "error", error)

  defp text_field(base, field, text) do
    if inline?(text),
      do: {Map.put(base, field, text), nil},
      else: {base |> Map.put(field, nil) |> Map.put("text_part", field), text}
  end

  defp inline?(text), do: String.valid?(text) and byte_size(Jason.encode!(text)) <= @inline_bytes

  defp with_images(%{success: true, output: output}, images) do
    named =
      for image <- images, do: %{"mime_type" => image.mime_type, "bytes" => byte_size(image.data)}

    part = images |> Enum.map(& &1.data) |> IO.iodata_to_binary()
    {%{"success" => true, "output" => output, "error" => nil, "images" => named}, part}
  end

  defp text(%{"text_part" => field}, field, part) when is_binary(part), do: {:ok, part}
  defp text(%{"text_part" => field}, field, _no_part), do: {:error, not_a_result()}

  defp text(result, field, _part) do
    case Map.get(result, field) do
      text when is_binary(text) -> {:ok, text}
      _other -> {:error, not_a_result()}
    end
  end

  defp images(nil, _part), do: {:ok, []}

  defp images(named, part) when is_list(named) and is_binary(part) do
    sizes = Enum.map(named, &Map.get(&1, "bytes"))
    mimes = Enum.map(named, &Map.get(&1, "mime_type"))

    if Enum.all?(sizes, &(is_integer(&1) and &1 > 0)) and Enum.all?(mimes, &mime?/1) and
         Enum.sum(sizes) == byte_size(part),
       do: {:ok, split(part, Enum.zip(mimes, sizes))},
       else: {:error, not_a_result()}
  end

  defp images(_named, _part), do: {:error, not_a_result()}

  defp split(part, entries) do
    {images, _rest} =
      Enum.map_reduce(entries, part, fn {mime, size}, rest ->
        <<data::binary-size(size), more::binary>> = rest
        {%{type: :image, mime_type: mime, data: data}, more}
      end)

    images
  end

  defp mime?(mime), do: is_binary(mime) and mime != "" and byte_size(mime) <= 127
end
