defmodule FermixChannels.Mobile.NoiseVectorsTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Noise

  @vectors_path Application.app_dir(:fermix_core, "priv/mobile/noise_vectors.json")

  test "locked preludes select exactly one handshake mode" do
    assert Noise.paired_prelude() == <<"FXM1", 1>>
    assert Noise.pairing_prelude() == <<"FXM1", 2>>
    assert {:ok, :ik, <<"rest">>} = Noise.parse_prelude(<<"FXM1", 1, "rest">>, :ik)
    assert {:ok, :ikpsk2, <<>>} = Noise.parse_prelude(<<"FXM1", 2>>, :ikpsk2)
    assert {:error, :handshake_mode_mismatch} = Noise.parse_prelude(<<"FXM1", 2>>, :ik)
    assert {:error, :unknown_handshake_mode} = Noise.parse_prelude(<<"FXM1", 9>>, :any)
    assert {:error, :invalid_prelude} = Noise.parse_prelude(<<"bad">>, :any)
  end

  test "IK and IKpsk2 match deterministic cross-implementation vectors" do
    vectors = @vectors_path |> File.read!() |> Jason.decode!()

    assert vectors["source"] == "Noise Protocol Framework vectors plus Fermix prologue/prelude"
    assert vectors["suite"] == "Noise_{IK,IKpsk2}_25519_ChaChaPoly_SHA256"

    for vector <- vectors["vectors"] do
      assert_vector(vector)
    end
  end

  test "a responder validates the prelude before initializing symmetric state" do
    {initiator, responder} = initial_pair(:ik)
    assert responder.symmetric == nil
    assert {:ok, wire, _initiator} = Noise.write_handshake(initiator, <<>>)

    <<_prelude::binary-size(4), _mode, body::binary>> = wire
    mismatched = Noise.pairing_prelude() <> body

    assert {:error, :handshake_mode_mismatch} = Noise.read_handshake(responder, mismatched)
    assert responder.symmetric == nil
  end

  test "tampered handshakes and transport messages fail authentication" do
    {initiator, responder} = initial_pair(:ik)
    {:ok, first, initiator} = Noise.write_handshake(initiator, "one")
    {:ok, "one", responder} = Noise.read_handshake(responder, first)
    {:ok, second, responder} = Noise.write_handshake(responder, "two")

    assert {:error, :authentication_failed} =
             Noise.read_handshake(initiator, flip_last_byte(second))

    {:ok, "two", initiator} = Noise.read_handshake(initiator, second)
    {:ok, ciphertext, _initiator} = Noise.encrypt(initiator, "secret")
    assert {:error, :authentication_failed} = Noise.decrypt(responder, flip_last_byte(ciphertext))
  end

  test "rekeying corresponding transport directions keeps peers synchronized" do
    {initiator, responder} = complete_pair(:ik)
    assert {:ok, first, initiator} = Noise.encrypt(initiator, "before-rekey")
    assert {:ok, "before-rekey", responder} = Noise.decrypt(responder, first)
    send_nonce = initiator.send_cipher.nonce
    receive_nonce = responder.receive_cipher.nonce

    assert {:ok, initiator} = Noise.rekey(initiator, :send)
    assert {:ok, responder} = Noise.rekey(responder, :receive)
    assert initiator.send_cipher.nonce == send_nonce
    assert responder.receive_cipher.nonce == receive_nonce
    assert {:ok, ciphertext, _initiator} = Noise.encrypt(initiator, "after-rekey")
    assert {:ok, "after-rekey", _responder} = Noise.decrypt(responder, ciphertext)
  end

  test "public boundaries reject malformed keys, PSKs, and oversized plaintext" do
    keypair = deterministic_keypair(0x11)
    remote = deterministic_keypair(0x22)

    assert {:error, :invalid_keypair} =
             Noise.initialize(:initiator, :ik,
               static_keypair: %{private: <<1>>, public: <<2>>},
               remote_static: remote.public
             )

    assert {:error, :invalid_psk} =
             Noise.initialize(:initiator, :ikpsk2,
               static_keypair: keypair,
               remote_static: remote.public,
               psk: <<1>>
             )

    {initiator, _responder} = complete_pair(:ik)
    oversized = :binary.copy(<<0>>, 65_520)
    assert {:error, {:plaintext_too_large, 65_520, 65_519}} = Noise.encrypt(initiator, oversized)
  end

  defp assert_vector(vector) do
    pattern = String.to_existing_atom(vector["pattern"])
    initiator_static = keypair(vector, "init_static")
    responder_static = keypair(vector, "resp_static")
    initiator_ephemeral = keypair(vector, "init_ephemeral")
    responder_ephemeral = keypair(vector, "resp_ephemeral")
    psk = optional_hex(vector["psk"])

    assert {:ok, initiator} =
             Noise.initialize(:initiator, pattern,
               static_keypair: initiator_static,
               remote_static: responder_static.public,
               ephemeral_keypair: initiator_ephemeral,
               psk: psk
             )

    assert {:ok, responder} =
             Noise.initialize(:responder, pattern,
               static_keypair: responder_static,
               ephemeral_keypair: responder_ephemeral,
               psk: psk
             )

    [first, second] = vector["handshake_messages"]
    assert {:ok, first_wire, initiator} = Noise.write_handshake(initiator, hex(first["payload"]))
    assert Base.encode16(first_wire, case: :lower) == first["wire"]
    assert {:ok, first_payload, responder} = Noise.read_handshake(responder, first_wire)
    assert first_payload == hex(first["payload"])

    assert {:ok, second_wire, responder} =
             Noise.write_handshake(responder, hex(second["payload"]))

    assert Base.encode16(second_wire, case: :lower) == second["wire"]
    assert {:ok, second_payload, initiator} = Noise.read_handshake(initiator, second_wire)
    assert second_payload == hex(second["payload"])

    assert Noise.complete?(initiator)
    assert Noise.complete?(responder)

    for state <- [initiator, responder] do
      assert state.static_keypair == nil
      assert state.ephemeral_keypair == nil
      assert state.psk == nil
      assert state.symmetric == nil
      assert state.remote_ephemeral == nil
    end

    assert Base.encode16(Noise.handshake_hash(initiator), case: :lower) ==
             vector["handshake_hash"]

    assert Noise.handshake_hash(responder) == Noise.handshake_hash(initiator)
    assert Noise.sas(initiator) == vector["sas"]

    {initiator, responder} = assert_transport(vector, initiator, responder)
    assert_rekey(vector["rekey"], initiator, responder)
  end

  # More than one message per direction is the point: every handshake AEAD call
  # and the first transport frame all run at nonce 0, where the three plausible
  # ChaChaPoly nonce encodings are byte-identical. Only the second frame pins
  # 4 zero bytes followed by a little-endian counter, which is what a separate
  # Swift implementation has to agree with.
  defp assert_transport(vector, initiator, responder) do
    messages = vector["transport_messages"]

    Enum.reduce(messages, {initiator, responder}, fn message, {sender, receiver} ->
      assert sender.send_cipher.nonce == message["nonce"]
      assert {:ok, ciphertext, sender} = Noise.encrypt(sender, hex(message["plaintext"]))
      assert Base.encode16(ciphertext, case: :lower) == message["ciphertext"]
      assert {:ok, plaintext, receiver} = Noise.decrypt(receiver, ciphertext)
      assert plaintext == hex(message["plaintext"])
      {sender, receiver}
    end)
  end

  # Rekeying both ends with the same code round-trips even when the derivation
  # is wrong, because both ends are wrong identically — only the iOS client
  # would break, and only after 2^20 frames. So pin the derived key itself
  # against the cross-implementation vector, not just the round trip.
  defp assert_rekey(rekey, initiator, responder) do
    assert initiator.send_cipher.nonce == rekey["nonce"]

    assert {:ok, initiator} = Noise.rekey(initiator, :send)
    assert {:ok, responder} = Noise.rekey(responder, :receive)

    assert Base.encode16(initiator.send_cipher.key, case: :lower) == rekey["key"]
    assert initiator.send_cipher.nonce == rekey["nonce"]
    assert responder.receive_cipher.nonce == rekey["nonce"]

    assert {:ok, ciphertext, _initiator} = Noise.encrypt(initiator, hex(rekey["plaintext"]))
    assert Base.encode16(ciphertext, case: :lower) == rekey["ciphertext"]
    assert {:ok, plaintext, _responder} = Noise.decrypt(responder, ciphertext)
    assert plaintext == hex(rekey["plaintext"])
  end

  defp keypair(vector, prefix) do
    %{
      private: hex(vector[prefix <> "_private"]),
      public: hex(vector[prefix <> "_public"])
    }
  end

  defp optional_hex(nil), do: nil
  defp optional_hex(value), do: hex(value)

  defp hex(value), do: Base.decode16!(value, case: :mixed)

  defp initial_pair(pattern) do
    initiator_static = deterministic_keypair(0x11)
    responder_static = deterministic_keypair(0x22)
    psk = if pattern == :ikpsk2, do: :binary.copy(<<0x55>>, 32), else: nil
    options = if is_nil(psk), do: [], else: [psk: psk]

    {:ok, initiator} =
      Noise.initialize(
        :initiator,
        pattern,
        [
          static_keypair: initiator_static,
          remote_static: responder_static.public,
          ephemeral_keypair: deterministic_keypair(0x33)
        ] ++ options
      )

    {:ok, responder} =
      Noise.initialize(
        :responder,
        pattern,
        [
          static_keypair: responder_static,
          ephemeral_keypair: deterministic_keypair(0x44)
        ] ++ options
      )

    {initiator, responder}
  end

  defp complete_pair(pattern) do
    {initiator, responder} = initial_pair(pattern)
    {:ok, first, initiator} = Noise.write_handshake(initiator, <<>>)
    {:ok, <<>>, responder} = Noise.read_handshake(responder, first)
    {:ok, second, responder} = Noise.write_handshake(responder, <<>>)
    {:ok, <<>>, initiator} = Noise.read_handshake(initiator, second)
    {initiator, responder}
  end

  defp deterministic_keypair(byte) do
    {:ok, keypair} = Noise.keypair_from_private(:binary.copy(<<byte>>, 32))
    keypair
  end

  defp flip_last_byte(bytes) do
    size = byte_size(bytes) - 1
    <<prefix::binary-size(size), last>> = bytes
    prefix <> <<Bitwise.bxor(last, 1)>>
  end
end
