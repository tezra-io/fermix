defmodule FermixCore.Home.Archive.SealTest do
  use ExUnit.Case, async: true

  alias FermixCore.Home.Archive.Seal

  @passphrase "invented-harbour-lantern"

  test "a sealed blob opens with its passphrase and has the documented layout" do
    {:ok, sealed} = Seal.seal("plain tar bytes", @passphrase)
    sealed = IO.iodata_to_binary(sealed)

    assert <<"FXHOME1\n", _salt::binary-size(16), _nonce::binary-size(12), rest::binary>> = sealed
    assert byte_size(rest) == byte_size("plain tar bytes") + 16
    assert Seal.open(sealed, @passphrase) == {:ok, "plain tar bytes"}
  end

  test "two seals of the same bytes share no salt, nonce or ciphertext" do
    {:ok, first} = Seal.seal("same", @passphrase)
    {:ok, second} = Seal.seal("same", @passphrase)

    refute IO.iodata_to_binary(first) == IO.iodata_to_binary(second)
  end

  test "a passphrase under twelve bytes is refused on both sides" do
    assert Seal.seal("x", "eleven-byte") == {:error, :passphrase_too_short}
    assert Seal.open("anything", "eleven-byte") == {:error, :passphrase_too_short}
  end

  test "a wrong passphrase, bad magic, a short blob or any flipped byte is one answer" do
    {:ok, sealed} = Seal.seal("plain tar bytes", @passphrase)
    sealed = IO.iodata_to_binary(sealed)

    assert Seal.open(sealed, "another-invented-phrase") == {:error, :archive_rejected}

    assert Seal.open("FXHOME2\n" <> binary_part(sealed, 8, byte_size(sealed) - 8), @passphrase) ==
             {:error, :archive_rejected}

    assert Seal.open(binary_part(sealed, 0, 40), @passphrase) == {:error, :archive_rejected}
    assert Seal.open("", @passphrase) == {:error, :archive_rejected}

    for offset <- [8, 30, 40, byte_size(sealed) - 1] do
      assert Seal.open(flip(sealed, offset), @passphrase) == {:error, :archive_rejected},
             "flipping byte #{offset} was not rejected"
    end
  end

  defp flip(binary, offset) do
    <<head::binary-size(offset), byte, tail::binary>> = binary
    <<head::binary, Bitwise.bxor(byte, 1), tail::binary>>
  end
end
