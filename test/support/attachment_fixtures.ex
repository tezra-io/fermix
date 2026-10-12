defmodule FermixTestSupport.AttachmentFixtures do
  @moduledoc """
  Byte-exact inbound attachment fixtures (M67): the smallest files each
  signature the classifier reads, built in memory so no test touches a file it
  did not make.
  """

  @screen <<"GIF89a", 1::little-16, 1::little-16, 0x80, 0, 0>>
  @global_table <<0xFF, 0xFF, 0xFF, 0, 0, 0>>
  @netscape_loop <<0x21, 0xFF, 11, "NETSCAPE2.0", 3, 1, 0, 0, 0>>
  @comment <<0x21, 0xFE, 5, "hello", 0>>
  # A 1×1 image: descriptor, LZW minimum code size 2, one data sub-block.
  @image <<0x2C, 0::16, 0::16, 1::little-16, 1::little-16, 0, 2, 2, 0x44, 0x01, 0>>

  @doc "A one-frame GIF."
  @spec still_gif() :: binary()
  def still_gif,
    do: <<@screen::binary, @global_table::binary, gce(0)::binary, @image::binary, 0x3B>>

  @doc "A three-frame looping GIF with a comment, a NETSCAPE loop and a delay per frame."
  @spec animated_gif() :: binary()
  def animated_gif do
    frames = for delay <- [10, 20, 30], into: <<>>, do: <<gce(delay)::binary, @image::binary>>

    <<@screen::binary, @global_table::binary, @netscape_loop::binary, @comment::binary,
      frames::binary, 0x3B>>
  end

  @doc "What `FermixCore.Attachments.GifFrame.first/1` must cut from `animated_gif/0`."
  @spec animated_gif_first_frame() :: binary()
  def animated_gif_first_frame,
    do: <<@screen::binary, @global_table::binary, gce(10)::binary, @image::binary, 0x3B>>

  @spec png() :: binary()
  def png, do: <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "png-body">>

  @spec jpeg() :: binary()
  def jpeg, do: <<0xFF, 0xD8, 0xFF, 0xE0, "jpeg-body">>

  @spec pdf() :: binary()
  def pdf, do: "%PDF-1.4\n% fixture lease 7731\n%%EOF\n"

  @spec mp4() :: binary()
  def mp4, do: <<0, 0, 0, 24, "ftyp", "isom", 0, 0, 2, 0, "isomiso2">>

  @spec ogg() :: binary()
  def ogg, do: <<"OggS", 0, 2, "ogg-body">>

  # A graphic control extension: block size 4, no disposal, `delay` hundredths.
  defp gce(delay), do: <<0x21, 0xF9, 4, 0, delay::little-16, 0, 0>>
end
