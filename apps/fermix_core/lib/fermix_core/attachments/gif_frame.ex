defmodule FermixCore.Attachments.GifFrame do
  @moduledoc """
  A GIF file's first frame, cut from its blocks with no pixel decoding (M67 D2).

  A GIF is a header, a logical screen descriptor and an optional global colour
  table, then a run of blocks: extensions (`0x21`), images (`0x2C`, each with an
  optional local colour table and LZW data in length-prefixed sub-blocks) and a
  trailer (`0x3B`). The cut keeps the header, the screen, the global table, the
  graphic control extension that governs the first image (its transparency),
  that image's blocks, and a trailer. Every other extension goes, the NETSCAPE
  loop among them, so the result is a still GIF every picture-reading model
  takes as it is.

  Pure and bounded: each walk stops after `@max_blocks` blocks and each
  sub-block run after `@max_sub_blocks` sub-blocks, past which the file is
  refused as unreadable rather than walked further.
  """

  import Bitwise

  @max_blocks 10_000
  # A sub-block holds at most 255 bytes: this walks about 25 MB of image data,
  # past every attachment cap.
  @max_sub_blocks 100_000
  @trailer 0x3B

  @doc "The first frame as a still GIF, or `:error` when the file is not a GIF it can walk."
  @spec first(binary()) :: {:ok, binary()} | :error
  def first(bytes) when is_binary(bytes) do
    with {:ok, head, blocks} <- screen(bytes),
         {:image, gce, image, _rest} <- next_image(blocks, <<>>, @max_blocks) do
      {:ok, IO.iodata_to_binary([head, gce, image, @trailer])}
    else
      _unreadable -> :error
    end
  end

  @doc "Whether the GIF holds a second image, which makes it an animation."
  @spec animated?(binary()) :: boolean()
  def animated?(bytes) when is_binary(bytes) do
    with {:ok, _head, blocks} <- screen(bytes),
         {:image, _gce, _image, rest} <- next_image(blocks, <<>>, @max_blocks),
         {:image, _gce, _image, _rest} <- next_image(rest, <<>>, @max_blocks) do
      true
    else
      _one_or_none -> false
    end
  end

  defp screen(<<"GIF8", version, "a", screen::binary-size(7), rest::binary>>)
       when version in [?7, ?9] do
    <<_size::binary-size(4), packed, _background, _aspect>> = screen
    table = color_table_bytes(packed)

    case rest do
      <<global::binary-size(table), blocks::binary>> ->
        {:ok, <<"GIF8", version, "a", screen::binary, global::binary>>, blocks}

      _truncated ->
        :error
    end
  end

  defp screen(_bytes), do: :error

  defp color_table_bytes(packed) when (packed &&& 0x80) != 0,
    do: 3 * (1 <<< ((packed &&& 0x07) + 1))

  defp color_table_bytes(_packed), do: 0

  # The next image block, with the graphic control extension that precedes it.
  defp next_image(_blocks, _gce, 0), do: :error
  defp next_image(<<@trailer, _rest::binary>>, _gce, _left), do: :trailer

  defp next_image(<<0x21, 0xF9, body::binary>>, _gce, left) do
    with {:ok, length, rest} <- skip_sub_blocks(body) do
      next_image(rest, <<0x21, 0xF9, binary_part(body, 0, length)::binary>>, left - 1)
    end
  end

  defp next_image(<<0x21, _label, body::binary>>, gce, left) do
    with {:ok, _length, rest} <- skip_sub_blocks(body) do
      next_image(rest, gce, left - 1)
    end
  end

  defp next_image(<<0x2C, descriptor::binary-size(9), body::binary>>, gce, _left),
    do: image(descriptor, body, gce)

  defp next_image(_blocks, _gce, _left), do: :error

  defp image(descriptor, body, gce) do
    <<_placement::binary-size(8), packed>> = descriptor
    table = color_table_bytes(packed)

    with <<_local::binary-size(table), _lzw_size, data::binary>> <- body,
         {:ok, length, rest} <- skip_sub_blocks(data) do
      image = <<0x2C, descriptor::binary, binary_part(body, 0, table + 1 + length)::binary>>
      {:image, gce, image, rest}
    else
      _truncated -> :error
    end
  end

  # The length of a sub-block run up to and including its zero terminator.
  defp skip_sub_blocks(bytes), do: skip_sub_blocks(bytes, 0, @max_sub_blocks)

  defp skip_sub_blocks(_bytes, _length, 0), do: :error
  defp skip_sub_blocks(<<0, rest::binary>>, length, _left), do: {:ok, length + 1, rest}

  defp skip_sub_blocks(<<size, _data::binary-size(size), rest::binary>>, length, left),
    do: skip_sub_blocks(rest, length + 1 + size, left - 1)

  defp skip_sub_blocks(_truncated, _length, _left), do: :error
end
