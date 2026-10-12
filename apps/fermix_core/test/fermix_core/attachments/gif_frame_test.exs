defmodule FermixCore.Attachments.GifFrameTest do
  use ExUnit.Case, async: true

  alias FermixCore.Attachments.GifFrame
  alias FermixTestSupport.AttachmentFixtures, as: Fixtures

  test "cuts the first frame: header, screen, colour table, its control block, its image, a trailer" do
    assert GifFrame.first(Fixtures.animated_gif()) == {:ok, Fixtures.animated_gif_first_frame()}
  end

  test "the cut drops the NETSCAPE loop and every other extension" do
    {:ok, frame} = GifFrame.first(Fixtures.animated_gif())

    refute frame =~ "NETSCAPE2.0"
    refute frame =~ "hello"
    refute GifFrame.animated?(frame)
  end

  test "a one-frame GIF cuts to itself" do
    assert GifFrame.first(Fixtures.still_gif()) == {:ok, Fixtures.still_gif()}
  end

  test "animated? counts a second image" do
    assert GifFrame.animated?(Fixtures.animated_gif())
    refute GifFrame.animated?(Fixtures.still_gif())
  end

  test "a file that is not a GIF, or stops inside its first image, is refused" do
    assert GifFrame.first(Fixtures.png()) == :error
    assert GifFrame.first("GIF89a") == :error

    truncated = binary_part(Fixtures.still_gif(), 0, byte_size(Fixtures.still_gif()) - 4)
    assert GifFrame.first(truncated) == :error
    refute GifFrame.animated?(truncated)
  end

  test "a GIF with no image before its trailer has no first frame" do
    empty = <<"GIF89a", 1::little-16, 1::little-16, 0, 0, 0, 0x3B>>
    assert GifFrame.first(empty) == :error
  end

  test "a local colour table rides with its image" do
    local =
      <<0x2C, 0::16, 0::16, 1::little-16, 1::little-16, 0x80, 1, 2, 3, 4, 5, 6, 2, 2, 0x44, 0x01,
        0>>

    gif = <<"GIF89a", 1::little-16, 1::little-16, 0, 0, 0, local::binary, 0x3B>>

    assert GifFrame.first(gif) == {:ok, gif}
  end
end
