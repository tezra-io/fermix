defmodule FermixCore.Accessories.AttachTest do
  # Both ends prove their enrolled keys on every attach before any audio, call
  # or accessory control (M91 D11, D14; PROTOCOL.md, *Attach*). Time is the
  # caller's monotonic milliseconds, injected, so no test waits on a clock.
  use ExUnit.Case, async: true

  alias FermixCore.Accessories.Attach
  alias FermixCore.Accessories.HostKey
  alias FermixCore.Accessories.P256
  alias FermixCore.Accessories.Record
  alias FermixCore.Accessories.Transcript

  @now 1_000_000

  setup do
    {:ok, host} = HostKey.from_private(elem(P256.generate(), 1))
    {accessory_pk, accessory_private} = P256.generate()

    record = %Record{
      accessory_id: P256.id(accessory_pk),
      accessory_pk: accessory_pk,
      kind: "stackchan",
      name: "StackChan",
      port_hint: "80:45:6B:54:87:FC",
      enrolled_at: ~U[2026-11-07 22:04:22Z]
    }

    %{host: host, record: record, private: accessory_private}
  end

  # The accessory's side: a hello_ack signed over the transcript of the
  # challenge it was sent, as the firmware builds it.
  defp ack(challenge, record, private, overrides \\ []) do
    fields = %{
      gen: challenge.gen,
      wire: 1,
      kind: "stackchan",
      accessory_id: record.accessory_id,
      firmware: "0.1.0",
      pack: nil,
      caps: 0x7F,
      accessory_nonce: :crypto.strong_rand_bytes(32)
    }

    fields = Map.merge(fields, Map.new(Keyword.get(overrides, :fields, [])))
    signed = Map.merge(fields, Map.new(Keyword.get(overrides, :signed_as, [])))

    transcript =
      Transcript.attach(%{
        host_id: challenge.host_id,
        accessory_id: signed.accessory_id,
        host_nonce: Keyword.get(overrides, :host_nonce, challenge.host_nonce),
        accessory_nonce: signed.accessory_nonce,
        wire: signed.wire,
        host_caps: challenge.host_caps,
        accessory_caps: signed.caps,
        gen: signed.gen,
        kind: signed.kind
      })

    Map.merge(fields, %{type: "hello_ack", sig: P256.sign(transcript, private)})
  end

  test "an enrolled accessory's proof verifies, and the host's proof over the same transcript does too",
       %{host: host, record: record, private: private} do
    challenge = Attach.challenge(host, 4, @now)
    hello = Attach.hello(challenge)

    assert %{type: "hello", gen: 4, wire_min: 1, wire_max: 1, caps: 0x7F} = hello
    assert hello.host_id == host.id and byte_size(hello.host_nonce) == 32

    assert {{:ok, verified}, closed} =
             Attach.verify(challenge, ack(challenge, record, private), [record], @now)

    assert verified.accessory == record
    assert verified.kind == "stackchan" and verified.wire == 1
    assert verified.caps == [:mic, :speaker, :screen, :touch, :pet, :motion, :battery]

    proof = Attach.host_proof(verified, host)
    assert %{type: "host_proof", gen: 4} = proof
    assert P256.verify(verified.transcript, proof.sig, host.public)
    refute closed.open?
  end

  test "the host sends at most one hello a second", %{host: host} do
    assert Attach.may_hello?(nil, @now)
    challenge = Attach.challenge(host, 1, @now)

    refute Attach.may_hello?(challenge, @now + Attach.min_hello_interval_ms() - 1)
    assert Attach.may_hello?(challenge, @now + Attach.min_hello_interval_ms())
  end

  test "a proof signed by another key is bad_proof", %{host: host, record: record} do
    challenge = Attach.challenge(host, 1, @now)
    {_pk, stranger} = P256.generate()

    assert {{:error, :bad_proof}, _closed} =
             Attach.verify(challenge, ack(challenge, record, stranger), [record], @now)
  end

  test "an answer replayed on a later attach fails its signature, and a challenge answers once",
       %{host: host, record: record, private: private} do
    first = Attach.challenge(host, 1, @now)
    old = ack(first, record, private)
    assert {{:ok, _verified}, first} = Attach.verify(first, old, [record], @now)

    # The same answer again, to the challenge it was made for.
    assert {{:error, :stale_generation}, _} = Attach.verify(first, old, [record], @now)

    # Re-labelled with the later attach's generation: the later transcript has a
    # new nonce and generation, so the old signature no longer covers it.
    later = Attach.challenge(host, 2, @now + 50)
    assert {{:error, :bad_proof}, _} = Attach.verify(later, %{old | gen: 2}, [record], @now + 50)
  end

  test "an answer for another generation is dropped and leaves the challenge open",
       %{host: host, record: record, private: private} do
    challenge = Attach.challenge(host, 9, @now)
    stale = ack(challenge, record, private, fields: [gen: 8], signed_as: [gen: 8])

    assert {{:ignored, :stale_generation}, ^challenge} =
             Attach.verify(challenge, stale, [record], @now)

    assert {{:ok, _verified}, _} =
             Attach.verify(challenge, ack(challenge, record, private), [record], @now)
  end

  test "a signature over a different generation than the answer claims is bad_proof",
       %{host: host, record: record, private: private} do
    challenge = Attach.challenge(host, 9, @now)
    forged = ack(challenge, record, private, signed_as: [gen: 10])

    assert {{:error, :bad_proof}, _} = Attach.verify(challenge, forged, [record], @now)
  end

  test "capability bits changed after signing are bad_proof", %{
    host: host,
    record: record,
    private: private
  } do
    challenge = Attach.challenge(host, 3, @now)
    tampered = ack(challenge, record, private, fields: [caps: 0x03], signed_as: [caps: 0x7F])

    assert {{:error, :bad_proof}, _} = Attach.verify(challenge, tampered, [record], @now)
  end

  test "a forgotten accessory is unknown_accessory, before any signature is checked",
       %{host: host, record: record, private: private} do
    challenge = Attach.challenge(host, 1, @now)

    assert {{:error, :unknown_accessory}, closed} =
             Attach.verify(challenge, ack(challenge, record, private), [], @now)

    refute closed.open?
  end

  test "an answer after the ten-second deadline is auth_timeout", %{
    host: host,
    record: record,
    private: private
  } do
    challenge = Attach.challenge(host, 1, @now)
    answer = ack(challenge, record, private)

    assert {{:ok, _}, _} =
             Attach.verify(challenge, answer, [record], @now + Attach.deadline_ms() - 1)

    assert {{:error, :auth_timeout}, _} =
             Attach.verify(challenge, answer, [record], @now + Attach.deadline_ms())
  end

  test "a wire version, kind or capability set the host cannot serve is refused by name",
       %{host: host, record: record, private: private} do
    for {fields, code} <- [
          {[wire: 2], :wire_version},
          {[kind: "lamp"], :unsupported_kind},
          {[caps: 0b1], :capability_missing},
          {[caps: 0b10], :capability_missing}
        ] do
      challenge = Attach.challenge(host, 1, @now)
      answer = ack(challenge, record, private, fields: fields)

      assert {{:error, ^code}, _} = Attach.verify(challenge, answer, [record], @now),
             inspect(fields)
    end
  end

  test "an unenrolled accessory is told apart, so it may only enroll", %{host: host} do
    challenge = Attach.challenge(host, 1, @now)

    answer = %{
      type: "hello_ack",
      gen: 1,
      wire: 1,
      kind: "stackchan",
      accessory_id: nil,
      firmware: "0.1.0",
      pack: nil,
      caps: 0x7F,
      accessory_nonce: :crypto.strong_rand_bytes(32),
      sig: nil
    }

    assert {{:unenrolled, %{kind: "stackchan", firmware: "0.1.0", wire: 1}}, closed} =
             Attach.verify(challenge, answer, [], @now)

    refute closed.open?
  end

  test "an accessory only accepts the host proof of the host it enrolled with",
       %{host: host, record: record, private: private} do
    challenge = Attach.challenge(host, 5, @now)

    {{:ok, verified}, _} =
      Attach.verify(challenge, ack(challenge, record, private), [record], @now)

    {:ok, other_host} = HostKey.from_private(elem(P256.generate(), 1))

    refute P256.verify(
             verified.transcript,
             Attach.host_proof(verified, other_host).sig,
             host.public
           )
  end

  # M91 §04, D23: the kind's pinned metadata beside its attach requirements.
  # A value not decided yet says so; none is invented.
  test "each kind carries its display name, and undecided pins say so" do
    assert Attach.kinds() == ["stackchan"]

    assert {:ok, meta} = Attach.kind_metadata("stackchan")
    assert meta.display_name == "StackChan"
    assert meta.required_capabilities == [:mic, :speaker]
    assert meta.firmware_range == :undecided
    assert meta.install_guide == :undecided

    assert Attach.kind_metadata("toaster") == :error
  end
end
