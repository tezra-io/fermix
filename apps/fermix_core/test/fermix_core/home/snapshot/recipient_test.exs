defmodule FermixCore.Home.Snapshot.RecipientTest do
  use ExUnit.Case, async: true

  alias FermixCore.Home.Snapshot.Recipient

  @passphrase "invented-quarry-semaphore"
  @salt <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>

  # PBKDF2 at the seal's 600,000 rounds is the slow part, so the derivations
  # the module's tests compare are made once.
  setup_all do
    {:ok, first} = Recipient.derive(@passphrase, @salt)
    {:ok, again} = Recipient.derive(@passphrase, @salt)
    {:ok, other_salt} = Recipient.derive(@passphrase, :binary.copy(<<9>>, 16))
    %{first: first, again: again, other_salt: other_salt}
  end

  test "one passphrase and salt always derive the same pair", %{first: first, again: again} do
    assert first == again
    assert first.salt == @salt
    assert byte_size(first.public_key) == 32
    assert byte_size(first.secret_key) == 32
    assert Recipient.matches?(first, Recipient.public(again))
  end

  test "another salt derives another key", %{first: first, other_salt: other_salt} do
    refute first.public_key == other_salt.public_key
    refute Recipient.matches?(first, other_salt)
  end

  test "a passphrase under twelve bytes derives nothing" do
    assert Recipient.derive("eleven-byte", @salt) == {:error, :passphrase_too_short}
    assert Recipient.from_passphrase("short") == {:error, :passphrase_too_short}
  end

  test "the encoding round-trips and carries the salt, never the private half", %{first: first} do
    text = Recipient.encode(first)

    assert ["fxsnap1", salt64, public64] = String.split(text, ".")
    assert Base.url_decode64!(salt64, padding: false) == @salt
    assert Base.url_decode64!(public64, padding: false) == first.public_key
    refute String.contains?(text, Base.url_encode64(first.secret_key, padding: false))
    assert Recipient.decode(text) == {:ok, Recipient.public(first)}
  end

  test "anything but the encoding is refused by name" do
    good = Recipient.encode(Recipient.generate())
    [_prefix, salt64, public64] = String.split(good, ".")

    for bad <- [
          "",
          "fxsnap2." <> salt64 <> "." <> public64,
          "fxsnap1." <> salt64,
          "fxsnap1." <> salt64 <> "." <> public64 <> ".extra",
          "fxsnap1.!!!." <> public64,
          "fxsnap1." <> salt64 <> "." <> binary_part(public64, 0, 20),
          nil,
          42
        ] do
      assert Recipient.decode(bad) == {:error, :invalid_recipient}, inspect(bad)
    end
  end

  test "a one-time pair is fresh every time and has the one shape" do
    one = Recipient.generate()
    two = Recipient.generate()

    refute one.secret_key == two.secret_key
    assert {:ok, _recipient} = Recipient.decode(Recipient.encode(one))
    assert byte_size(Recipient.key_id(one.public_key)) == 8
    refute Recipient.key_id(one.public_key) == Recipient.key_id(two.public_key)
  end
end
