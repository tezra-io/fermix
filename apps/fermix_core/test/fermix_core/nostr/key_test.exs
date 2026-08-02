defmodule FermixCore.Nostr.KeyTest do
  # Pure crypto/codec: no filesystem, no env, no global state.
  use ExUnit.Case, async: true

  alias FermixCore.Nostr.Key

  # Published NIP-19 vector. The triple below was verified end to end against a
  # reference bech32 implementation pinned by the BIP-173 published vectors:
  # decoding the nsec yields @secret_hex, deriving its secp256k1 x-only public
  # key yields @public_hex, and encoding that under the `npub` HRP reproduces
  # the NIP-19 published npub character for character.
  @nsec "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"
  @secret_hex "67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa"
  @public_hex "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e"
  @npub "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"

  # A second, unrelated identity (secret = sha256("fermix-acp-identity-2")),
  # derived the same way. Used wherever a test needs two distinct agents.
  @nsec2 "nsec1n5kjpk2ulwe25uj4thrr8stmy0xe9hk7f0suw0sdeff34yfv2xkq2etz66"
  @public_hex2 "864a30aeb3401aaa70d4473ddea5eb66cd55e1ee504ada3e9582275025d17a64"
  @npub2 "npub1se9rpt4ngqd25ux5gu7aaf0tvmx4tc0w2p9d5054sgn4qfw30fjqu3z0dq"

  describe "decode_secret/1" do
    test "decodes the published nsec to its 32 raw bytes" do
      assert {:ok, raw} = Key.decode_secret(@nsec)
      assert byte_size(raw) == 32
      assert Base.encode16(raw, case: :lower) == @secret_hex
    end

    test "decodes the 64-char hex form to the same bytes" do
      assert Key.decode_secret(@secret_hex) == Key.decode_secret(@nsec)
    end

    test "accepts an uppercase hex secret (hex carries no case meaning)" do
      assert Key.decode_secret(String.upcase(@secret_hex)) == Key.decode_secret(@nsec)
    end

    test "accepts an all-uppercase bech32 secret (BIP-173 allows it)" do
      assert Key.decode_secret(String.upcase(@nsec)) == Key.decode_secret(@nsec)
    end

    test "rejects a mixed-case bech32 secret" do
      mixed = "Nsec1" <> String.slice(@nsec, 5..-1//1)
      assert {:error, {:invalid_nsec, :mixed_case}} = Key.decode_secret(mixed)
    end

    test "rejects a bad checksum" do
      flipped = String.slice(@nsec, 0..-2//1) <> "4"
      assert {:error, {:invalid_nsec, :bad_checksum}} = Key.decode_secret(flipped)
    end

    test "rejects the right encoding under the wrong HRP" do
      assert {:error, {:invalid_nsec, {:hrp, "npub"}}} = Key.decode_secret(@npub)
    end

    test "rejects a well-formed nsec whose payload is not 32 bytes" do
      # 31 zero-ish bytes under the nsec HRP, with a valid checksum.
      short = "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqyhr2edq"
      assert {:error, {:invalid_nsec, {:length, 31}}} = Key.decode_secret(short)
    end

    test "rejects hex of the wrong length" do
      assert {:error, {:invalid_secret, {:length, 31}}} =
               Key.decode_secret(String.slice(@secret_hex, 0..-3//1))
    end

    test "rejects non-hex, non-bech32 garbage without raising" do
      for garbage <- ["", "not-a-key", "zzzz", "nsec1", String.duplicate("g", 64)] do
        assert {:error, _reason} = Key.decode_secret(garbage)
      end
    end

    test "rejects a bech32-shaped string with no separator" do
      assert {:error, {:invalid_nsec, :missing_separator}} = Key.decode_secret("nsecqqqqqq")
    end

    test "rejects a bech32 string longer than BIP-173 allows" do
      assert {:error, {:invalid_nsec, :too_long}} =
               Key.decode_secret(@nsec <> String.duplicate("q", 40))
    end
  end

  describe "public_hex/1" do
    test "derives the x-only public key of the published vector" do
      {:ok, raw} = Key.decode_secret(@nsec)
      assert {:ok, @public_hex} = Key.public_hex(raw)
    end

    test "derives the second identity's public key" do
      {:ok, raw} = Key.decode_secret(@nsec2)
      assert {:ok, @public_hex2} = Key.public_hex(raw)
    end

    test "is lowercase hex of exactly 32 bytes" do
      {:ok, raw} = Key.decode_secret(@nsec)
      {:ok, hex} = Key.public_hex(raw)
      assert String.length(hex) == 64
      assert hex == String.downcase(hex)
    end

    test "refuses a secret of the wrong size" do
      assert {:error, {:invalid_secret, {:length, 31}}} = Key.public_hex(<<1::248>>)
    end

    test "refuses scalars outside the curve order instead of raising" do
      order =
        Base.decode16!("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141")

      assert {:error, {:invalid_secret, :out_of_range}} = Key.public_hex(<<0::256>>)
      assert {:error, {:invalid_secret, :out_of_range}} = Key.public_hex(order)
    end
  end

  describe "npub/1" do
    test "encodes the published public key to its published npub" do
      assert {:ok, @npub} = Key.npub(@public_hex)
      assert {:ok, @npub2} = Key.npub(@public_hex2)
    end

    test "round-trips nsec -> hex -> npub" do
      {:ok, raw} = Key.decode_secret(@nsec)
      {:ok, hex} = Key.public_hex(raw)
      assert {:ok, @npub} = Key.npub(hex)
    end

    test "refuses input that is not a 32-byte hex public key" do
      assert {:error, {:invalid_public_key, :not_hex}} = Key.npub("nope")

      assert {:error, {:invalid_public_key, {:length, 31}}} =
               Key.npub(String.slice(@public_hex, 0..-3//1))
    end
  end
end
