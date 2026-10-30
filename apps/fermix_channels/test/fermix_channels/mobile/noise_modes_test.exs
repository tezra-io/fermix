defmodule FermixChannels.Mobile.NoiseModesTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Noise

  # The two M75 modes run the IKpsk2 and IK patterns under their own preludes,
  # so a handshake made for one mode can never be read as another.

  test "each mode has its own prelude and prologue" do
    assert Noise.prelude(:ik) == <<"FXM1", 1>>
    assert Noise.prelude(:ikpsk2) == <<"FXM1", 2>>
    assert Noise.prelude(:ikpsk2_enroll) == <<"FXM1", 3>>
    assert Noise.prelude(:ik_move) == <<"FXM1", 4>>
    assert Noise.prologue(:ikpsk2_enroll) == "fermix-mobile-v1" <> <<"FXM1", 3>>
    assert Noise.prologue(:ik_move) == "fermix-mobile-v1" <> <<"FXM1", 4>>
  end

  test "a prelude is parsed against one mode, a list of modes, or any" do
    assert {:ok, :ikpsk2_enroll, "x"} = Noise.parse_prelude(<<"FXM1", 3, "x">>, :ikpsk2_enroll)
    assert {:ok, :ik_move, ""} = Noise.parse_prelude(<<"FXM1", 4>>, [:ik_move])
    assert {:ok, :ik_move, ""} = Noise.parse_prelude(<<"FXM1", 4>>, :any)

    assert {:error, :handshake_mode_mismatch} =
             Noise.parse_prelude(<<"FXM1", 3>>, [:ik, :ikpsk2])

    assert {:error, :handshake_mode_mismatch} = Noise.parse_prelude(<<"FXM1", 4>>, :ik)
  end

  test "an enrollment handshake completes under the code's secret and agrees on its SAS" do
    psk = :crypto.strong_rand_bytes(32)
    {initiator, responder} = pair(:ikpsk2_enroll, psk: psk)

    {initiator, responder} = handshake(initiator, responder)

    assert Noise.handshake_hash(initiator) == Noise.handshake_hash(responder)
    assert Noise.sas(initiator) == Noise.sas(responder)
    assert_transport(initiator, responder)
  end

  test "an enrollment handshake under another secret fails at the responder" do
    responder_keys = Noise.generate_keypair()

    {:ok, initiator} =
      Noise.initialize(:initiator, :ikpsk2_enroll,
        static_keypair: Noise.generate_keypair(),
        remote_static: responder_keys.public,
        psk: :crypto.strong_rand_bytes(32)
      )

    {:ok, responder} =
      Noise.initialize(:responder, :ikpsk2_enroll,
        static_keypair: responder_keys,
        psk: :crypto.strong_rand_bytes(32)
      )

    {:ok, wire, initiator} = Noise.write_handshake(initiator, <<>>)
    {:ok, <<>>, responder} = Noise.read_handshake(responder, wire)
    {:ok, reply, _responder} = Noise.write_handshake(responder, <<>>)

    # IKpsk2 mixes the secret into the second message: the initiator holding
    # another secret cannot read the responder's reply.
    assert {:error, :authentication_failed} = Noise.read_handshake(initiator, reply)
  end

  test "a move handshake completes and proves the initiator's static key" do
    {initiator, responder} = pair(:ik_move, [])
    initiator_public = initiator.static_keypair.public

    {initiator, responder} = handshake(initiator, responder)

    assert {:ok, ^initiator_public} = Noise.remote_static(responder)
    assert_transport(initiator, responder)
  end

  test "a move handshake is refused by a responder that serves the paired mode" do
    {initiator, _responder} = pair(:ik_move, [])
    {_other, responder} = pair(:ik, [])

    {:ok, wire, _initiator} = Noise.write_handshake(initiator, <<>>)

    assert {:error, :handshake_mode_mismatch} = Noise.read_handshake(responder, wire)
  end

  test "the IK move mode takes no secret and the enrollment mode needs one" do
    keys = Noise.generate_keypair()
    remote = Noise.generate_keypair().public

    assert {:error, :psk_not_allowed} =
             Noise.initialize(:initiator, :ik_move,
               static_keypair: keys,
               remote_static: remote,
               psk: :crypto.strong_rand_bytes(32)
             )

    assert {:error, :invalid_psk} =
             Noise.initialize(:initiator, :ikpsk2_enroll,
               static_keypair: keys,
               remote_static: remote,
               psk: <<1, 2, 3>>
             )
  end

  defp pair(mode, opts) do
    initiator_keys = Noise.generate_keypair()
    responder_keys = Noise.generate_keypair()

    {:ok, initiator} =
      Noise.initialize(
        :initiator,
        mode,
        [static_keypair: initiator_keys, remote_static: responder_keys.public] ++ opts
      )

    {:ok, responder} =
      Noise.initialize(:responder, mode, [static_keypair: responder_keys] ++ opts)

    {initiator, responder}
  end

  defp handshake(initiator, responder) do
    {:ok, wire, initiator} = Noise.write_handshake(initiator, <<>>)
    {:ok, <<>>, responder} = Noise.read_handshake(responder, wire)
    {:ok, reply, responder} = Noise.write_handshake(responder, <<>>)
    {:ok, <<>>, initiator} = Noise.read_handshake(initiator, reply)
    {initiator, responder}
  end

  defp assert_transport(initiator, responder) do
    {:ok, ciphertext, _initiator} = Noise.encrypt(initiator, "hello")
    assert {:ok, "hello", _responder} = Noise.decrypt(responder, ciphertext)
  end
end
