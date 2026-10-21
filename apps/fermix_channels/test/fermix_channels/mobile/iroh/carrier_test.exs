defmodule FermixChannels.Mobile.Iroh.CarrierTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Iroh.Carrier

  test "a message frame carries one whole Noise message, up to 65,535 bytes" do
    biggest = :binary.copy(<<7>>, 65_535)
    frame = biggest |> Carrier.message() |> IO.iodata_to_binary()

    assert byte_size(frame) == Carrier.max_frame_bytes()
    assert {:message, ^biggest} = Carrier.decode(frame)
    assert {:message, "x"} = Carrier.decode(<<1, "x">>)
  end

  test "a close frame carries the code and a reason cut to 123 bytes on a character boundary" do
    frame = 1000 |> Carrier.close("Noise session lifetime reached") |> IO.iodata_to_binary()
    assert {:close, 1000, "Noise session lifetime reached"} = Carrier.decode(frame)

    long = String.duplicate("é", 100)
    cut = 1002 |> Carrier.close(long) |> IO.iodata_to_binary()
    assert {:close, 1002, reason} = Carrier.decode(cut)
    assert byte_size(reason) == 122 and String.valid?(reason)
  end

  test "an empty message, an oversized or short close, an unknown type and bad UTF-8 are refused" do
    assert {:error, :invalid_frame_length} = Carrier.decode(<<1>>)
    assert {:error, :invalid_frame_length} = Carrier.decode(<<2, 3>>)

    assert {:error, :invalid_frame_length} =
             Carrier.decode(<<2, 1000::16, :binary.copy("a", 124)::binary>>)

    assert {:error, :unknown_frame_type} = Carrier.decode(<<3, "x">>)
    assert {:error, :invalid_close_reason} = Carrier.decode(<<2, 1000::16, 0xFF>>)
    assert {:error, :empty_frame} = Carrier.decode(<<>>)
  end
end
